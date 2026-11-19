import 'package:flutter/foundation.dart';

/// 一次播放请求的片源快照。
///
/// [vid] 是缓存主键，与 [url] 解耦：同一个视频换签名地址仍然命中同一份缓存。
///
/// 抽成值对象有两个用处：一是 [YUPlayerController.setSource] 的入参，二是在
/// 播放器的 `setSource` 通道里统一字段名（`vid` / `url` / `autoPlay`）。
/// 画面层不碰片源 —— 它只认 `playerId`。
@immutable
class YUPlayerSource {
  const YUPlayerSource({
    required this.vid,
    required this.url,
    this.autoPlay = false,
  });

  /// 缓存主键
  final String vid;

  /// 播放地址，签名过期时换一条新的即可
  final String url;

  /// 这条片源是否自动开始播放
  final bool autoPlay;

  /// 交给原生 `setSource` 的形态，两端字段名一致。
  Map<String, dynamic> toMap() => <String, dynamic>{
        'vid': vid,
        'url': url,
        'autoPlay': autoPlay,
      };

  @override
  String toString() => 'YUPlayerSource(vid: $vid, autoPlay: $autoPlay)';
}
