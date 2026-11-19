import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../yu_log.dart';
import '../yu_channels.dart';
import 'yu_player_bridge.dart';
import 'yu_player_event.dart';
import 'yu_player_source.dart';
import 'yu_player_value.dart';

/// 控制一个原生播放器实例。
///
/// 分层与官方 `video_player` 一致：**播放器归控制器，画面归组件**。
///
/// - 控制器 `initialize()` 时向原生要一个播放器实例（`createPlayer`），
///   拿到 [playerId] 后自己拉流、自己收事件；
/// - [YUVideoPlayer] 只是个显示层，挂上就把画面接过去，摘掉就只剩声音。
///
/// 所以下面这些都是合法的：
///
/// ```dart
/// final c = YUPlayerController(vid: vid, url: url, autoPlay: true);
/// await c.initialize();   // 没有 YUVideoPlayer 也能走完，有声音没画面
/// await c.play();
/// ```
///
/// 职责边界：对外是播放指令与状态快照，对内把指令交给 [YUPlayerBridge]、
/// 把事件折算交给 `applyPlayerEvent`。通道细节不在这里。
class YUPlayerController extends ValueNotifier<YUPlayerValue> {
  /// 只记录片源，不产生任何副作用 —— 建原生播放器要等 [initialize]。
  ///
  /// [autoPlay] 默认 `false`：就绪后停在首帧，由业务调 [play] 开始。
  ///
  /// 构造是同步的，返回时 [YUPlayerValue.isInitialized] 一定是 `false`；
  /// 要等首帧就绪用 [initialize]。
  YUPlayerController({
    required String vid,
    required String url,
    bool autoPlay = false,
    double volume = 1.0,
    double speed = 1.0,
  })  : _source = YUPlayerSource(vid: vid, url: url, autoPlay: autoPlay),
        super(YUPlayerValue(
          volume: _clampVolume(volume),
          speed: _clampSpeed(speed),
        )) {
    YUPlayerLog.birth('控制器', _logId, 'vid=$vid 自动播放=$autoPlay');
  }

  static double _clampVolume(double v) => v.clamp(0.0, 1.0).toDouble();

  static double _clampSpeed(double v) => v.clamp(0.25, 4.0).toDouble();

  /// 当前片源，可用 [setSource] 在播放中替换
  YUPlayerSource get source => _source;
  YUPlayerSource _source;

  /// 缓存主键，与 [url] 解耦
  String get vid => _source.vid;

  /// 当前播放地址
  String get url => _source.url;

  /// 最近一次请求的自动播放行为。
  ///
  /// 不用构造时那个值：`setSource(autoPlay: false)` 之后 view 若被重建，
  /// 不应该又自己播起来。
  bool get autoPlay => _source.autoPlay;

  /// 日志里的身份标识，形如 `控制器#3`，创建与销毁靠同一个号配对
  String get logTag => '控制器#$_logId';

  final int _logId = YUPlayerLog.nextId();
  final int _bornAt = DateTime.now().microsecondsSinceEpoch;

  YUPlayerBridge? _bridge;
  int? _playerId;
  int? _viewId;
  bool _disposed = false;

  /// 是否已经进入「真正开始播」的流程（[initialize] 或 [setSource]）
  bool _started = false;

  /// 当前片源是否已经下发给原生。重复 [initialize] 靠它避免重复拉流。
  bool _sourceDispatched = false;

  /// 等首帧的挂起者。原生 `ready` / `error` 事件到达时一次性全部唤醒；
  /// 换源、销毁、创建失败时也唤醒（把当时的状态交出去，不让 await 永远悬着）。
  final List<Completer<YUPlayerValue>> _readyWaiters = [];

  /// 原生播放器实例的 id，[initialize] 之前为 null
  int? get playerId => _playerId;

  /// 已挂上的原生 view 的 id，没有画面时为 null
  int? get viewId => _viewId;

  /// 是否已经 [initialize]（或 [setSource]）过。`false` 时没有拉过任何流。
  bool get isStarted => _started;

  bool get isInitialized => value.isInitialized;

  /// 创建原生播放器并开始拉流，返回首帧就绪时的状态快照。
  ///
  /// **不需要任何 `YUVideoPlayer` 在场**：播放器、事件通道都在控制器这边，
  /// 没有 view 时正常出声、只是没画面。把 `YUVideoPlayer` 挂上再摘掉，
  /// 播放不中断。
  ///
  /// **不调它（也不调 [setSource]）就什么都不发生**：不建播放器、不占缓存
  /// 计数、不发请求。
  ///
  /// 重复调用是幂等的：已经启动过就只等，不会再下发一次 `setSource`。
  /// 已就绪则立刻返回当前快照。
  ///
  /// 桌面上跑（没有原生实现）不会挂死：`createPlayer` 立刻失败，返回的
  /// 快照里 [YUPlayerValue.error] 是「当前平台没有原生播放器实现」。
  Future<YUPlayerValue> initialize({Duration? timeout}) async {
    if (_disposed || value.isInitialized) return value;
    if (!_started) {
      _started = true;
      YUPlayerLog.log('[初始化] $logTag vid=${_source.vid} '
          '自动播放=${_source.autoPlay}');
    }
    return _start(timeout: timeout);
  }

  /// 真正干活的启动路径：[initialize] 与 [setSource] 共用。
  ///
  /// 两者只差「要不要重新下发片源」：[setSource] 会把 [_sourceDispatched]
  /// 置回 `false`，走到这里必然下发；重复 [initialize] 则只等。
  Future<YUPlayerValue> _start({Duration? timeout}) async {
    final needDispatch = !_sourceDispatched;
    // 先登记等待者再下发：原生 `ready` 有可能比 invoke 的 await 先回来
    final pending = ready(timeout: timeout);
    if (!await _ensurePlayer()) return pending;
    if (needDispatch) {
      _sourceDispatched = true;
      await _invoke('setSource', _source.toMap());
    }
    return pending;
  }

  /// 等首帧就绪，返回完成那一刻的状态快照。
  ///
  /// 只负责「等」，不会启动播放：没调过 [initialize] / [setSource] 的话，
  /// 没有任何东西会就绪，这个 future 永远不完成。日常用 [initialize] 就够。
  ///
  /// 正常路径下 `isInitialized == true`，时长和分辨率都已填好。播放失败、
  /// 创建失败、控制器销毁时是 `false`，原因看 [YUPlayerValue.error]。
  /// 所以别假设只要 await 完就一定成功。
  ///
  /// 已经就绪时立即返回，不会多等一个事件循环。生产代码建议带 [timeout]，
  /// 避免拉流卡死时页面一直转圈。
  Future<YUPlayerValue> ready({Duration? timeout}) {
    // 已就绪 / 已销毁都没什么可等的，直接把当前快照交出去
    if (_disposed || value.isInitialized) return Future.value(value);
    final waiter = Completer<YUPlayerValue>();
    _readyWaiters.add(waiter);
    if (timeout == null) return waiter.future;
    return waiter.future.timeout(timeout, onTimeout: () {
      // 超时后要主动摘掉，否则换源/销毁时还会往这个死 completer 上写
      _readyWaiters.remove(waiter);
      throw TimeoutException('等待首帧超时（${timeout.inMilliseconds}ms）', timeout);
    });
  }

  /// 向原生要一个播放器实例（只建一次）。
  ///
  /// 失败时把原因写进 [value] 并唤醒等待者 —— 桌面 / Web 上没有原生实现，
  /// 这一步会立刻失败，不会让上层永远等下去。
  Future<bool> _ensurePlayer() async {
    if (_bridge != null) return true;
    final int? id;
    try {
      id = await yuPluginChannel.invokeMethod<int>('createPlayer');
    } on PlatformException catch (e) {
      _fail(e.message ?? e.code);
      return false;
    } on MissingPluginException {
      _fail('当前平台没有原生播放器实现');
      return false;
    }
    if (_disposed) return false;
    if (id == null) {
      _fail('原生播放器创建失败');
      return false;
    }
    _playerId = id;
    _bridge = YUPlayerBridge(
      playerId: id,
      onEvent: _onEvent,
      onCallFailed: _onCallFailed,
      onStreamError: _onStreamError,
    );
    YUPlayerLog.log('[连接] $logTag 拿到播放器 playerId=$id');
    // 把构造时指定的音量/倍速同步给原生（默认值也发，覆盖原生侧默认）
    _invoke('setVolume', {'volume': value.volume});
    _invoke('setSpeed', {'speed': value.speed});
    // 没有 view 也照常；有的话把画面接上
    final viewId = _viewId;
    if (viewId != null) _invoke('attachView', {'viewId': viewId});
    return true;
  }

  void _fail(String message) {
    if (_disposed) return;
    YUPlayerLog.log('[错误] $logTag 创建播放器失败 $message');
    value = value.copyWith(error: message);
    _flushReady();
  }

  /// 唤醒所有等待者，把当前快照交出去
  void _flushReady() {
    if (_readyWaiters.isEmpty) return;
    final waiters = List<Completer<YUPlayerValue>>.of(_readyWaiters);
    _readyWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete(value);
    }
  }

  /// 接上刚建好的原生画面层。**内部接口**：由 [YUVideoPlayer] 在
  /// PlatformView 创建回调里调用，业务层不要直接调。
  ///
  /// 播放器可能还没创建（先挂 view、后 initialize），也可能早就创建好了
  /// （先 initialize、后挂 view）；两种顺序都能把画面接上。
  void attachView(int viewId) {
    if (_disposed) return;
    _viewId = viewId;
    YUPlayerLog.log('[连接] 画面 视图#$viewId -> $logTag');
    if (_bridge != null) _invoke('attachView', {'viewId': viewId});
  }

  /// 画面层要销毁了。**内部接口**：由 [YUVideoPlayer] 在 `dispose` 里调用。
  ///
  /// 只是把画面摘掉，[playerId] 对应的播放器继续存在 —— 声音不断。
  void detachView(int viewId) {
    if (_viewId != viewId) return;
    _viewId = null;
    if (!_disposed && _bridge != null) {
      _invoke('detachView', {'viewId': viewId});
    }
  }

  /// 播放中换源（也能只换签名地址，[vid] 不变时继续命中同一份缓存）。
  ///
  /// 原生侧只替换 item / MediaSource，播放器实例、音量与倍速都保留，
  /// 因此不会有"整块重建"的黑屏空档。切换瞬间 [value] 会回到
  /// [YUPlayerValue.reset] 的干净状态（时长、分辨率、进度清零），等原生
  /// `ready` 事件回来再填。
  ///
  /// **不需要另外调 [initialize]**：这里已经含了它的全部动作（建播放器、
  /// 下发片源），`await` 返回时 `size` / `duration` 就是新片源的值。
  ///
  /// 传入与当前完全相同的 vid/url 表示"重新拉流"，等价于重试；
  /// 不做去重，需要去重请在业务层判断。
  Future<YUPlayerValue> setSource({
    required String vid,
    required String url,
    bool autoPlay = false,
    Duration? timeout,
  }) async {
    if (_disposed) return value;
    _source = YUPlayerSource(vid: vid, url: url, autoPlay: autoPlay);
    // 换源隐含「开始播放」：没 initialize 过也能直接 setSource 拉起播放
    _started = true;
    _sourceDispatched = false;
    YUPlayerLog.log('[换源] $logTag -> vid=$vid 自动播放=$autoPlay');
    // 保留音量/倍速：这两个是播放器级设置，换源不影响；
    // 其余字段全部清零，别让上一份的时长/分辨率/进度挂在新片源上
    value = YUPlayerValue.reset(volume: value.volume, speed: value.speed);
    return _start(timeout: timeout);
  }

  Future<void> play() => _invoke('play');

  Future<void> pause() => _invoke('pause');

  /// 拖动到指定位置。前缀之外的部分不落盘。
  Future<void> seekTo(Duration position) async {
    final target = position < Duration.zero ? Duration.zero : position;
    value = value.copyWith(position: target, isCompleted: false);
    await _invoke('seekTo', {'positionMs': target.inMilliseconds});
  }

  /// 设置音量，范围 0~1。0 为静音，但仍继续播放。
  ///
  /// 先本地更新 [value] 再下发，UI 开关不会等一次通道往返。
  Future<void> setVolume(double volume) async {
    final target = _clampVolume(volume);
    value = value.copyWith(volume: target);
    await _invoke('setVolume', {'volume': target});
  }

  /// 设置播放倍速，1.0 为原速，允许 0.25~4.0。
  ///
  /// iOS 侧 `play()` 会把 rate 重置为 1，原生实现里已做补偿；
  /// 暂停状态下设置只记录，恢复播放时生效。
  Future<void> setSpeed(double speed) async {
    final target = _clampSpeed(speed);
    value = value.copyWith(speed: target);
    await _invoke('setSpeed', {'speed': target});
  }

  Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    final bridge = _bridge;
    if (bridge == null || _disposed) return;
    await bridge.invoke(method, args);
  }

  void _onEvent(Map<String, dynamic> event) {
    if (_disposed) return;
    value = applyPlayerEvent(
      value,
      event,
      tag: logTag,
      vid: _source.vid,
    );
    // 首帧就绪、播放失败都是"有了结论"，两头都要唤醒等待者，
    // 否则失败时 await 会一直挂到超时
    switch (event['type']) {
      case 'ready':
      case 'error':
        _flushReady();
    }
  }

  void _onCallFailed(String method, String message) {
    if (_disposed) return;
    YUPlayerLog.log('[错误] $logTag vid=${_source.vid} 调用 $method 失败 $message');
    value = value.copyWith(error: message);
  }

  void _onStreamError(Object error) {
    if (_disposed) return;
    YUPlayerLog.log('[错误] $logTag 事件通道异常 '
        '${error.toString()}');
    value = value.copyWith(error: error.toString());
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // playerId 为 null 说明原生播放器从没建起来
    YUPlayerLog.death('控制器', _logId,
        '${YUPlayerLog.alive(_bornAt)} vid=${_source.vid} '
        'playerId=${_playerId ?? "null"} viewId=${_viewId ?? "null"}');
    // bridge 关掉时会向原生发 release，播放器实例跟着销毁
    _bridge?.dispose();
    _bridge = null;
    // 还有人在 await ready：把当前快照交出去（此时 isInitialized=false），
    // 别让它们的 await 永远悬着
    _flushReady();
    super.dispose();
  }
}
