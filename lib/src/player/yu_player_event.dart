import 'dart:ui' show Size;

import '../../yu_log.dart';
import 'yu_player_value.dart';

/// 把原生事件通道推上来的一条事件折算成新的状态快照。
///
/// 纯映射：入参是当前快照，出参是新快照，既不碰通道也不持有状态，
/// 所以可以脱离 Flutter 环境单独测。事件类型由原生侧定义：
///
/// - `ready`：首帧就绪，带 `durationMs` / `width` / `height` / `usingCache`
/// - `state`：播放中 / 缓冲中 / 播完
/// - `position`：进度与已缓冲位置
/// - `size`：就绪之后补发的分辨率（Android 常见）
/// - `completed`：播放结束
/// - `error`：播放失败，带 `message`
///
/// [tag] 用于日志前缀（形如 `控制器#3`），[vid] 用于日志里标注片源。
YUPlayerValue applyPlayerEvent(
  YUPlayerValue current,
  Map<String, dynamic> event, {
  String tag = '',
  String vid = '',
}) {
  switch (event['type']) {
    case 'ready':
      final durationMs = _readInt(event['durationMs']);
      final width = _readInt(event['width']);
      final height = _readInt(event['height']);
      final cache = event['usingCache'] == true;
      YUPlayerLog.log('[就绪] $tag vid=$vid '
          '时长=${durationMs}ms 分辨率=${width}x$height 命中缓存=$cache');
      return current.copyWith(
        isInitialized: true,
        duration: Duration(milliseconds: durationMs),
        size: Size(width.toDouble(), height.toDouble()),
        usingCache: cache,
      );
    case 'state':
      return current.copyWith(
        isPlaying: event['isPlaying'] == true,
        isBuffering: event['isBuffering'] == true,
        isCompleted: event['isCompleted'] == true,
      );
    case 'position':
      final pos = Duration(milliseconds: _readInt(event['positionMs']));
      final buffered = Duration(milliseconds: _readInt(event['bufferedMs']));
      return current.copyWith(
        position: pos,
        // seek 之后原生还没重算缓冲点，不能让缓冲指示落在播放点之前
        bufferedPosition: buffered < pos ? pos : buffered,
      );
    case 'size':
      // Android 在 ready 之后才确定分辨率时会补发，iOS 侧 presentationSize
      // 变化时也会补发。尺寸无效时忽略，避免把已知值冲成 0
      final width = _readInt(event['width']);
      final height = _readInt(event['height']);
      if (width <= 0 || height <= 0) return current;
      return current.copyWith(
        size: Size(width.toDouble(), height.toDouble()),
      );
    case 'completed':
      return current.copyWith(isCompleted: true, isPlaying: false);
    case 'error':
      final message = event['message']?.toString() ?? '播放失败';
      YUPlayerLog.log('[错误] $tag vid=$vid 原因=$message');
      return current.copyWith(error: message);
    default:
      // 未知事件直接忽略：原生侧加字段不应该让 Dart 侧炸
      return current;
  }
}

int _readInt(dynamic v) => v is num ? v.toInt() : 0;
