import AVFoundation
import Flutter
import UIKit
import YUVideoPlayerIOS

/// 一个原生播放器实例，**不依赖任何 view**。
///
/// 与旧结构的区别：以前 `AVPlayer` 长在 PlatformView 里，view 没了播放就没了；
/// 现在由 Dart 控制器通过 `createPlayer` 单独创建，view 只决定「画面画在哪」，
/// 随时可以 attach / detach。
///
/// 所以没有画面时照样拉流、出声 —— 与官方 video_player 的分层一致。
/// item 仍由 `YUVideoCache.playerItem` 生成，播放时走磁盘前缀。
final class YUPlayerInstance: NSObject {

    // MARK: - 注册表

    private static let lock = NSLock()
    private static var registry: [Int: YUPlayerInstance] = [:]
    private static var views: [Int64: YUPlayerPlatformView] = [:]
    private static var nextId = 1

    /// 建一个播放器实例，返回它的 id（通道地址的一部分）
    static func create(messenger: FlutterBinaryMessenger) -> Int {
        lock.lock()
        let id = nextId
        nextId += 1
        lock.unlock()
        let instance = YUPlayerInstance(playerId: id, messenger: messenger)
        lock.lock()
        registry[id] = instance
        lock.unlock()
        return id
    }

    static func find(_ id: Int) -> YUPlayerInstance? {
        lock.lock()
        defer { lock.unlock() }
        return registry[id]
    }

    /// 按 id 销毁。找不到说明已经被释放，幂等
    static func release(_ id: Int) {
        lock.lock()
        let instance = registry.removeValue(forKey: id)
        lock.unlock()
        instance?.teardown(reason: "Dart 主动释放")
    }

    /// 引擎卸载时把所有播放器收掉
    static func releaseAll() {
        lock.lock()
        let all = registry.values
        registry.removeAll()
        views.removeAll()
        lock.unlock()
        for instance in all {
            instance.teardown(reason: "引擎卸载")
        }
    }

    static func register(view: YUPlayerPlatformView, viewId: Int64) {
        lock.lock()
        views[viewId] = view
        lock.unlock()
    }

    static func unregister(viewId: Int64) {
        lock.lock()
        views.removeValue(forKey: viewId)
        lock.unlock()
    }

    static func findView(_ viewId: Int64) -> YUPlayerPlatformView? {
        lock.lock()
        defer { lock.unlock() }
        return views[viewId]
    }

    /// 视图被回收时调用：把挂在该视图上的播放器画面摘掉。
    static func detachViews(_ viewId: Int64) {
        lock.lock()
        let all = Array(registry.values)
        lock.unlock()
        for instance in all { instance.detachIfAttached(to: viewId) }
    }

    // MARK: - 状态

    /// 播放器 id：既是通道地址，也是日志里的编号，和 Dart 侧一对一对上
    let playerId: Int
    private let player: AVPlayer
    private let methods: FlutterMethodChannel
    private let events: FlutterEventChannel
    /// 当前片源的缓存主键，换源后会变（对应的使用计数在 loadSource 里换手）
    private var vid = ""

    private let createdAt = CFAbsoluteTimeGetCurrent()
    /// 本次片源开始装配的时刻，换源时重置；用来算「起播耗时」
    private var sourceStartedAt = CFAbsoluteTimeGetCurrent()

    private var sink: FlutterEventSink?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var released = false
    private var readySent = false
    /// 当前倍速。AVPlayer 没有「默认速率」概念（play() 恒为 1.0），
    /// 只能自己记住，在每次起播后补一次 rate
    private var speed: Double = 1.0
    /// 是否已播到结尾。state 事件里不能硬编码 false，否则播完再暂停会把
    /// 「已结束」冲掉
    private var completed = false
    /// 当前 item 是否走了缓存通道，换源时跟着重新判定
    private var usingCache = false
    /// 上一次推给 Dart 的 position / buffered（毫秒，-1 表示还没推过）。
    ///
    /// 200ms 的采样节拍照旧，但值没变就不发：卡在缓冲、seek 后暂停这类
    /// 位置不动的场景，原来每拍都往通道塞一条内容完全相同的消息。
    private var lastSentPositionMs: Int64 = -1
    private var lastSentBufferedMs: Int64 = -1

    /// 当前画面画在哪个视图上，没有画面时为 nil
    private weak var attachedContainer: YUPlayerContainerView?
    private var attachedViewId: Int64 = 0

    init(playerId: Int,
         messenger: FlutterBinaryMessenger) {
        self.playerId = playerId
        player = AVPlayer()

        methods = FlutterMethodChannel(name: "yu_video_player/player/\(playerId)",
                                       binaryMessenger: messenger)
        events = FlutterEventChannel(name: "yu_video_player/events/\(playerId)",
                                     binaryMessenger: messenger)

        super.init()

        YULog.birth("播放器", playerId, "playerId=\(playerId)")

        methods.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }

        events.setStreamHandler(StreamHandler(
            onListen: { [weak self] sink in
                guard let self else { return }
                self.sink = sink
                // Dart 订阅上来的那一刻补一次快照，避免早于订阅丢失状态
                self.sendState()
                if self.readySent { self.sendReady() }
                // 断线期间的位置推送丢了，去重表作废，恢复推送后第一拍必发
                self.lastSentPositionMs = -1
                self.lastSentBufferedMs = -1
            },
            onCancel: { [weak self] in
                self?.sink = nil
            }))

        YUAudioSession.shared.register(player)
        observePlayer()
    }

    deinit {
        // 只看到 [销毁]、没有 [回收] => 还有别的强引用抓着这个实例（泄漏）
        YULog.log("[回收] 播放器#\(playerId) \(YULog.alive(since: createdAt)) 内存=\(YULog.memText())")
        teardown(reason: "对象释放")
    }

    // MARK: - 画面挂载

    /// 把画面接到指定的 view 上。播放器可能比 view 先建、也可能后建，
    /// 两边谁先到都行：后到的一方主动调这个方法。
    func attachView(_ viewId: Int64) {
        guard !released else { return }
        guard let view = YUPlayerInstance.findView(viewId) else {
            YULog.log("[连接] 播放器#\(playerId) 视图#\(viewId) 还没建好，等它上来")
            return
        }
        attach(view.container, viewId: viewId)
    }

    func attach(_ container: YUPlayerContainerView, viewId: Int64) {
        guard !released else { return }
        if attachedContainer === container { return }
        attachedContainer = container
        attachedViewId = viewId
        container.playerLayer.player = player
        YULog.log("[连接] 播放器#\(playerId) <-> 视图#\(viewId)")
    }

    /// 摘掉画面，播放器继续跑 —— 这是「关掉画面还有声音」的关键。
    ///
    /// 只清 playerLayer，不动 player 与 item，也不减缓存计数（计数归播放器）。
    func detach(_ container: YUPlayerContainerView) {
        guard !released, attachedContainer === container else { return }
        container.playerLayer.player = nil
        attachedContainer = nil
        YULog.log("[连接] 播放器#\(playerId) 摘掉 视图#\(attachedViewId)（继续出声）")
        attachedViewId = 0
    }

    func detachView(_ viewId: Int64) {
        guard !released else { return }
        if let view = YUPlayerInstance.findView(viewId) {
            detach(view.container)
        } else if let container = attachedContainer, attachedViewId == viewId {
            detach(container)
        }
    }

    /// 若画面正挂在这个 viewId 上就摘掉，供 `detachViews` 遍历调用。
    func detachIfAttached(to viewId: Int64) {
        guard !released, attachedViewId == viewId, let container = attachedContainer else { return }
        detach(container)
    }

    // MARK: - 方法

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard !released else {
            result(FlutterError(code: "released", message: "player already released", details: nil))
            return
        }
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "play":
            // 播完后再点播放，从 0 重新开始，而不是卡在最后一帧
            startPlayback(restartIfCompleted: true)
            result(nil)
        case "pause":
            player.pause()
            result(nil)
        case "seekTo":
            let ms = (args?["positionMs"] as? NSNumber)?.int64Value ?? 0
            let target = CMTime(value: max(0, ms), timescale: 1000)
            // 拖走了就不再算「已播完」
            completed = false
            player.seek(to: target,
                        toleranceBefore: .zero,
                        toleranceAfter: .zero)
            result(nil)
        case "setVolume":
            let volume = (args?["volume"] as? NSNumber)?.doubleValue ?? 1.0
            player.volume = Float(min(max(volume, 0.0), 1.0))
            result(nil)
        case "setSpeed":
            let value = (args?["speed"] as? NSNumber)?.doubleValue ?? 1.0
            // 暂停中只记录下来，起播后再应用（暂停时设 rate 会被系统丢弃）
            speed = min(max(value, 0.25), 4.0)
            applySpeed()
            result(nil)
        case "setSource":
            // 播放中换源 / 换签名：只替换 item，player 与画面层都保留
            let newVid = args?["vid"] as? String ?? ""
            guard !newVid.isEmpty else {
                result(FlutterError(code: "bad_args", message: "vid is empty", details: nil))
                return
            }
            let urlString = args?["url"] as? String ?? ""
            let autoPlay = args?["autoPlay"] as? Bool ?? true
            loadSource(vid: newVid,
                       url: URL(string: urlString) ?? URL(string: "about:blank")!,
                       autoPlay: autoPlay)
            result(nil)
        case "attachView":
            // 接上画面层。viewId 由 Flutter 分配，0 是合法编号
            if let viewId = (args?["viewId"] as? NSNumber)?.int64Value {
                attachView(viewId)
            }
            result(nil)
        case "detachView":
            // 摘掉画面层
            if let viewId = (args?["viewId"] as? NSNumber)?.int64Value {
                detachView(viewId)
            }
            result(nil)
        case "release":
            YUPlayerInstance.release(playerId)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// 起播：按当前倍速播放；已播到结尾时先回到开头。
    private func startPlayback(restartIfCompleted: Bool) {
        if restartIfCompleted, completed {
            completed = false
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        applySpeed()
    }

    /// play() 会把 rate 重置为 1，这里把倍速补回去。
    ///
    /// item 尚未 ready 时设置 rate 会被系统丢掉，所以 ready 与
    /// timeControlStatus 变化时都会再调一次。
    private func applySpeed() {
        guard player.timeControlStatus == .playing else { return }
        guard player.rate != Float(speed) else { return }
        player.rate = Float(speed)
    }

    // MARK: - 换源

    /// 装配一份片源：生成 item（会占一个使用计数）→ 替换 → 重新挂监听。
    ///
    /// 换源与首次播放走同一条路径。计数换手顺序是「先加新的、再减旧的」，
    /// 中间不会出现零引用被淘汰掉目录。播放器实例、画面层、音量、倍速都保留。
    private func loadSource(vid newVid: String, url: URL, autoPlay: Bool) {
        sourceStartedAt = CFAbsoluteTimeGetCurrent()
        let item = YUVideoCache.playerItem(vid: newVid, realURL: url)
        let oldVid = vid
        let oldWasCache = usingCache

        vid = newVid
        usingCache = YUVideoCache.isCachedItem(item)
        readySent = false
        completed = false
        // 换了 item，上一份片源的进度不能拿来比对，否则新片从 0 开始会被吞掉
        lastSentPositionMs = -1
        lastSentBufferedMs = -1

        // 先摘掉旧 item 的监听，否则替换瞬间旧 item 的 failed 状态还会往上报
        stopObservingItem()
        player.replaceCurrentItem(with: item)
        // 旧 item 此刻没人持有 → YUPlayerItem.deinit 会 cancel 它独占的 loader
        observeItem(item)

        // 纯网络的老 item 是系统类，没有 deinit 可打点，这里补一条与创建时那条
        // `[事件] 纯网络播放项` 配对（缓存版的由播放项自己打 [销毁]）
        if !oldVid.isEmpty && !oldWasCache {
            YULog.log("[事件] 纯网络播放项释放 vid=\(oldVid)")
        }

        if !oldVid.isEmpty { YUVideoCache.release(vid: oldVid) }

        YULog.log("[换源] 播放器#\(playerId) -> vid=\(newVid) "
                  + "命中缓存=\(usingCache) 自动播放=\(autoPlay) "
                  + "画面=\(attachedContainer != nil ? "有" : "无")")

        sendState()
        if autoPlay {
            startPlayback(restartIfCompleted: false)
        } else {
            player.pause()
        }
    }

    // MARK: - 监听

    /// 播放器级监听：整个实例生命周期只挂一次
    private func observePlayer() {
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            // play() 会把 rate 重置为 1，真正开始播时补回用户选的倍速
            self.applySpeed()
            self.sendState()
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            // 暂停时不再推送；缓冲中（waitingToPlayAtSpecifiedRate）仍要推，
            // 否则缓冲进度条会停住不动
            guard let self, self.player.timeControlStatus != .paused else { return }
            self.sendPosition(time)
        }
    }

    /// item 级监听：换源时先 `stopObservingItem`，再对新的 item 重新挂
    private func observeItem(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self else { return }
            switch item.status {
            case .readyToPlay:
                if !self.readySent { self.sendReady() }
                // 起播时的 rate 设置可能因未就绪被丢弃，这里补一次
                self.applySpeed()
                self.sendState()
            case .failed:
                let reason = item.error?.localizedDescription ?? "播放失败"
                YULog.log("[错误] 播放器#\(self.playerId) vid=\(self.vid) 原因=\(reason)")
                self.send("error", ["message": reason])
                self.sendState()
            default:
                self.sendState()
            }
        }

        // 分辨率可能在 ready 之后才确定（HLS / 部分封装），变化时补发
        sizeObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            guard let self, self.readySent else { return }
            let size = item.presentationSize
            guard size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { return }
            self.send("size", [
                "width": Int(size.width),
                "height": Int(size.height),
            ])
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.completed = true
            YULog.log("[播完] 播放器#\(self.playerId) vid=\(self.vid)")
            self.send("completed", nil)
            self.sendState()
        }
    }

    /// 摘掉 item 级监听。NSKeyValueObservation 失效时会释放掉对 item 的引用，
    /// 所以必须显式置 nil，否则换下来的 item 会一直活着（连带它的 loader 与 session）
    private func stopObservingItem() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation = nil
        sizeObservation = nil
    }

    // MARK: - 事件

    private func sendReady() {
        readySent = true
        let durationMs: Int64
        let duration = player.currentItem?.duration ?? .indefinite
        durationMs = duration.isNumeric ? Int64(CMTimeGetSeconds(duration) * 1000) : 0

        let size = player.currentItem?.presentationSize ?? .zero
        // 起播耗时 = 装配片源到首帧就绪，换源时基准会重置
        YULog.log("[就绪] 播放器#\(playerId) vid=\(vid) 时长=\(durationMs)ms "
                  + "分辨率=\(Int(size.width))x\(Int(size.height)) "
                  + "命中缓存=\(usingCache) \(YULog.cost(since: sourceStartedAt))")
        send("ready", [
            "durationMs": durationMs,
            "width": size.width.isFinite ? Int(size.width) : 0,
            "height": size.height.isFinite ? Int(size.height) : 0,
            "usingCache": usingCache,
        ])
    }

    private func sendState() {
        guard !released else { return }
        // 还没装配 item 时不算缓冲：空播放器没有东西在等，
        // 报 true 会让上层刚建好就以为在转圈
        let item = player.currentItem
        let buffering = item != nil
            && (item?.status != .readyToPlay
                || player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        send("state", [
            "isPlaying": player.timeControlStatus == .playing,
            "isBuffering": buffering,
            "isCompleted": completed,
        ])
    }

    private func sendPosition(_ time: CMTime) {
        let seconds = CMTimeGetSeconds(time)
        let positionMs = seconds.isFinite ? Int64(seconds * 1000) : 0
        let bufferedMs = bufferedMs()
        // 采到的两个值都没动就不发：Dart 侧不会因此少任何信息，只是少收空包
        guard positionMs != lastSentPositionMs || bufferedMs != lastSentBufferedMs else {
            return
        }
        lastSentPositionMs = positionMs
        lastSentBufferedMs = bufferedMs
        send("position", [
            "positionMs": positionMs,
            "bufferedMs": bufferedMs,
        ])
    }

    /// 已缓冲到的位置：取最后一个已加载区间的末尾。
    ///
    /// `loadedTimeRanges` 在 item 未就绪时是空的，此时返回 0；
    /// 回到开头之后区间也可能出现空洞，取最后一个即可覆盖"能连续播到哪"。
    private func bufferedMs() -> Int64 {
        guard let ranges = player.currentItem?.loadedTimeRanges as? [NSValue],
              let last = ranges.last?.timeRangeValue else { return 0 }
        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(last))
        return end.isFinite ? Int64(end * 1000) : 0
    }

    private func send(_ type: String, _ payload: [String: Any]?) {
        guard !released, let sink else { return }
        var map: [String: Any] = ["type": type]
        if let payload { map.merge(payload) { _, new in new } }
        sink(map)
    }

    // MARK: - 销毁

    private func teardown(reason: String) {
        guard !released else { return }
        released = true

        YULog.death("播放器", playerId,
                    "\(YULog.alive(since: createdAt)) 触发=\(reason) "
                    + "vid=\(vid) 命中缓存=\(usingCache) "
                    + "画面=\(attachedContainer != nil ? "有" : "无")")

        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        stopObservingItem()
        rateObservation = nil

        player.pause()
        attachedContainer?.playerLayer.player = nil
        attachedContainer = nil
        YUAudioSession.shared.unregister(player)

        // 先记一份弱引用，用来在释放之后确认 item 真的死了。
        // 纯网络 item 是系统类，没有 deinit 可打点，只能这样看它的生死。
        let itemBox = player.currentItem.map { WeakRef($0) }

        // 立刻放掉 item：YUPlayerItem 的 deinit 会 cancel 掉它独占的 loader
        // （URLSession 强引用 delegate，不 cancel 就永远不断开）。
        player.replaceCurrentItem(with: nil)

        methods.setMethodCallHandler(nil)
        events.setStreamHandler(nil)
        sink = nil
        // 与创建时那条 `[事件] 纯网络播放项` 配对，让时间线闭环
        if !usingCache && !vid.isEmpty {
            YULog.log("[事件] 纯网络播放项释放 vid=\(vid)")
        }
        if !vid.isEmpty { YUVideoCache.release(vid: vid) }

        // 「关掉之后到底回落到多少」：上面 release 的 player / item
        // 要到下一轮 runloop 才真的还回去，[销毁] 那条打的是释放前，只能看峰值。
        //
        // 采三个点：解码器 / IOSurface 的回收是延迟的，0.5s 不掉不代表泄漏。
        // 连续进出几次，看同一时点是否逐轮抬升，才是判断泄漏的口径。
        let id = playerId
        for delay in [0.5, 2.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let alive = itemBox?.value == nil ? "已释放" : "还活着"
                YULog.log("[内存] 播放器#\(id) 释放后 \(delay)s 内存=\(YULog.memText())"
                          + " 播放项\(alive)")
            }
        }
    }
}

/// 弱引用盒子：局部 weak 变量不能被闭包安全捕获，用这个包一层
final class WeakRef {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
}

// MARK: - StreamHandler 包装

final class StreamHandler: NSObject, FlutterStreamHandler {
    private let onListenBlock: (@escaping FlutterEventSink) -> Void
    private let onCancelBlock: () -> Void

    init(onListen: @escaping (@escaping FlutterEventSink) -> Void,
         onCancel: @escaping () -> Void) {
        onListenBlock = onListen
        onCancelBlock = onCancel
    }

    func onListen(withArguments arguments: Any?,
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        onListenBlock(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        onCancelBlock()
        return nil
    }
}
