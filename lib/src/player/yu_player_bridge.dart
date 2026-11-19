import 'dart:async';

import 'package:flutter/services.dart';

import '../yu_channels.dart';

/// 一个原生播放器实例的通道外壳。
///
/// 只做传输，不做解释：
/// - 方法通道把指令下发到 `yu_video_player/player/<playerId>`；
/// - 事件通道把 `yu_video_player/events/<playerId>` 的原始数据转成 Map 抛给上层；
/// - 关掉时把两条通道一起收掉，并顺手通知原生释放这个播放器。
///
/// 事件字段的含义、播放状态怎么变，都不在这里，见 `applyPlayerEvent`。
///
/// 和旧版的关键差别：地址里的 id 是**播放器**的，不是 view 的。view 可以
/// 晚于播放器创建、也可以提前销毁，两条通道都不受影响 —— 没画面也有声音。
class YUPlayerBridge {
  YUPlayerBridge({
    required this.playerId,
    required void Function(Map<String, dynamic> event) onEvent,
    required void Function(String method, String message) onCallFailed,
    required void Function(Object error) onStreamError,
  })  : _onEvent = onEvent,
        _onCallFailed = onCallFailed,
        _onStreamError = onStreamError {
    _events = yuPlayerEvents(playerId)
        .receiveBroadcastStream()
        .listen(_handleEvent, onError: _handleError);
  }

  /// 原生播放器实例的 id，也是两条通道的地址组成部分
  final int playerId;

  late final MethodChannel _methods = yuPlayerChannel(playerId);

  final void Function(Map<String, dynamic> event) _onEvent;
  final void Function(String method, String message) _onCallFailed;
  final void Function(Object error) _onStreamError;

  StreamSubscription<dynamic>? _events;
  bool _closed = false;

  /// 下发一条指令。通道还没接上或已经关掉时静默返回，调用方不必判空；
  /// 原生侧抛的 [PlatformException] 转成 `onCallFailed` 回调，不往外冒。
  Future<void> invoke(String method, [Map<String, dynamic>? args]) async {
    if (_closed) return;
    try {
      await _methods.invokeMethod<void>(method, args);
    } on PlatformException catch (e) {
      if (_closed) return;
      _onCallFailed(method, e.message ?? e.code);
    } on MissingPluginException {
      if (_closed) return;
      _onCallFailed(method, '当前平台没有原生播放器实现');
    }
  }

  /// 关掉通道，只执行一次。
  ///
  /// 顺手发一次 `release` 主动告诉原生「这个播放器不要了」，原生立刻放掉
  /// item / loader / URLSession，不等引擎回收。不等它返回也不看结果：
  /// 原生侧 teardown 是幂等的。
  void dispose() {
    if (_closed) return;
    _closed = true;
    final methods = _methods;
    unawaited(() async {
      try {
        await methods.invokeMethod<void>('release');
      } catch (_) {
        // 播放器已经没了，忽略
      }
    }());
    _events?.cancel();
    _events = null;
  }

  void _handleEvent(dynamic raw) {
    if (_closed || raw is! Map) return;
    _onEvent(Map<String, dynamic>.from(raw));
  }

  void _handleError(Object error) {
    if (_closed) return;
    _onStreamError(error);
  }
}
