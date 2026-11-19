import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

/// 播放器状态快照。
///
/// 不可变：每次变化都由控制器换一个新实例，UI 直接比对引用即可。
@immutable
class YUPlayerValue {
  const YUPlayerValue({
    this.isInitialized = false,
    this.isPlaying = false,
    this.isBuffering = false,
    this.isCompleted = false,
    this.position = Duration.zero,
    this.bufferedPosition = Duration.zero,
    this.duration = Duration.zero,
    this.size = Size.zero,
    this.volume = 1.0,
    this.speed = 1.0,
    this.usingCache = false,
    this.error,
  });

  /// 换源 / 重新拉流时的干净状态。
  ///
  /// 只保留播放器级设置（音量、倍速），**其余全部回默认值**：时长、分辨率、
  /// 进度、缓冲、缓存标记、错误都清零。否则 UI 上一条片源的时长会挂在新片源
  /// 上，看起来像"换了源但没生效"。
  ///
  /// 与 `copyWith` 的区别：那个是「只改指定字段」，这个是「整块重来」。
  const YUPlayerValue.reset({double volume = 1.0, double speed = 1.0})
      : this(volume: volume, speed: speed);

  /// 首帧已就绪（时长、分辨率已知）
  final bool isInitialized;

  final bool isPlaying;

  final bool isBuffering;

  final bool isCompleted;

  final Duration position;

  /// 已缓冲到的位置，即播放器手上已备好多少数据。
  ///
  /// 注意与磁盘前缀缓存区分：这个来自播放器的 buffered position
  /// （iOS `loadedTimeRanges` / Android `getBufferedPosition`），
  /// 只表示"能连续播到哪"；磁盘落了多少要看
  /// `YUVideoPrefixCache.entries()` 里的 `downloaded`。
  final Duration bufferedPosition;

  final Duration duration;

  /// 视频分辨率，未知时为 [Size.zero]
  final Size size;

  /// 音量，0~1。0 表示静音（但仍继续播放，不是暂停）
  final double volume;

  /// 播放倍速，1.0 为原速
  final double speed;

  /// 本次播放是否走了缓存链路。
  ///
  /// 只表示"命中缓存通道"，不代表前缀已经下满：有 meta 就会走这条链路，
  /// 边播边把前缀补齐。
  final bool usingCache;

  /// 播放失败的原因，正常时为 null
  final String? error;

  double get aspectRatio {
    if (size.width <= 0 || size.height <= 0) return 16 / 9;
    return size.width / size.height;
  }

  /// 缓冲进度 0~1。时长未知时为 0。
  ///
  /// 已经缓冲到结尾时等于 1，可以据此显示"已全部缓冲"。
  double get bufferedProgress {
    if (duration.inMilliseconds <= 0) return 0;
    final ratio = bufferedPosition.inMilliseconds / duration.inMilliseconds;
    return ratio.clamp(0.0, 1.0).toDouble();
  }

  YUPlayerValue copyWith({
    bool? isInitialized,
    bool? isPlaying,
    bool? isBuffering,
    bool? isCompleted,
    Duration? position,
    Duration? bufferedPosition,
    Duration? duration,
    Size? size,
    double? volume,
    double? speed,
    bool? usingCache,
    String? error,
  }) {
    return YUPlayerValue(
      isInitialized: isInitialized ?? this.isInitialized,
      isPlaying: isPlaying ?? this.isPlaying,
      isBuffering: isBuffering ?? this.isBuffering,
      isCompleted: isCompleted ?? this.isCompleted,
      position: position ?? this.position,
      bufferedPosition: bufferedPosition ?? this.bufferedPosition,
      duration: duration ?? this.duration,
      size: size ?? this.size,
      volume: volume ?? this.volume,
      speed: speed ?? this.speed,
      usingCache: usingCache ?? this.usingCache,
      error: error ?? this.error,
    );
  }

  @override
  String toString() => 'YUPlayerValue(init: $isInitialized, playing: $isPlaying, '
      'buffering: $isBuffering, pos: $position, '
      'buffered: $bufferedPosition, dur: $duration, '
      'volume: $volume, speed: $speed, '
      'cache: $usingCache, error: $error)';
}
