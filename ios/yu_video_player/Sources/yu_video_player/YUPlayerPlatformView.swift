import AVFoundation
import Flutter
import UIKit
import YUVideoPlayerIOS

/// 画面层。**只管显示**，不持有播放器。
///
/// 原生播放器在 `YUPlayerInstance` 里，由 Dart 控制器通过 `createPlayer`
/// 单独创建。这个 view 的唯一职责是把某个播放器的画面接到自己的
/// `AVPlayerLayer` 上；解挂之后播放器继续出声。
///
/// 两边创建顺序任意：view 先建就等播放器 attach，播放器先建就由它在
/// `attachView` 里回头找这个 view。
final class YUPlayerPlatformView: NSObject, FlutterPlatformView {

    let container: YUPlayerContainerView
    private let viewId: Int64
    private let playerId: Int
    private let logId = YULog.nextId()
    private let createdAt = CFAbsoluteTimeGetCurrent()

    init(frame: CGRect,
         viewId: Int64,
         args: Any?,
         messenger: FlutterBinaryMessenger) {
        let params = args as? [String: Any] ?? [:]
        let pid = (params["playerId"] as? NSNumber)?.intValue ?? 0
        self.viewId = viewId
        self.playerId = pid

        container = YUPlayerContainerView(frame: frame)
        container.playerLayer.videoGravity = .resizeAspect

        super.init()

        // 先登记再挂载：播放器的 attachView 靠 viewId 在这张表里找画面层
        YUPlayerInstance.register(view: self, viewId: viewId)
        YULog.birth("视图", logId, "viewId=\(viewId) playerId=\(pid)")

        if pid <= 0 {
            YULog.log("[连接] 视图#\(viewId) 先建好，等播放器 attach")
            return
        }
        if let instance = YUPlayerInstance.find(pid) {
            instance.attach(container, viewId: viewId)
        } else {
            YULog.log("[连接] 视图#\(viewId) 找不到播放器#\(pid)，等它上来")
        }
    }

    deinit {
        YUPlayerInstance.unregister(viewId: viewId)
        // 只摘画面，不碰播放器：声音继续
        if playerId > 0 {
            YUPlayerInstance.find(playerId)?.detach(container)
        }
        YULog.death("视图", logId,
                    "\(YULog.alive(since: createdAt)) 触发=Flutter 回收 playerId=\(playerId)")
    }

    func view() -> UIView {
        container
    }
}

// MARK: - 承载层

final class YUPlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

// MARK: - 工厂

final class YUPlayerViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }

    func create(withFrame frame: CGRect,
                viewIdentifier viewId: Int64,
                arguments args: Any?) -> FlutterPlatformView {
        YUPlayerPlatformView(frame: frame, viewId: viewId, args: args, messenger: messenger)
    }
}
