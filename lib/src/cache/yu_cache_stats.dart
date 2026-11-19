/// 缓存用量快照。
///
/// 纯数据：不依赖 Flutter，也不持有通道，可脱离环境单测。
class YUCacheStats {
  const YUCacheStats({
    required this.count,
    required this.totalBytes,
    required this.maxTotalBytes,
    required this.maxBytesPerVideo,
  });

  /// 由原生回包构造。
  ///
  /// 插件内部使用：业务层应通过 `YUVideoPrefixCache.stats()` 获取，
  /// 不要自己拿一份 map 来造。
  factory YUCacheStats.fromMap(Map<dynamic, dynamic> map) {
    return YUCacheStats(
      count: (map['count'] as num?)?.toInt() ?? 0,
      totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
      maxTotalBytes: (map['maxTotalBytes'] as num?)?.toInt() ?? 0,
      maxBytesPerVideo: (map['maxBytesPerVideo'] as num?)?.toInt() ?? 0,
    );
  }

  /// 缓存条目数。
  final int count;

  /// 已占用字节数。
  final int totalBytes;

  /// 全部缓存合计上限。
  final int maxTotalBytes;

  /// 单条视频上限。
  final int maxBytesPerVideo;

  @override
  String toString() => 'YUCacheStats(count: $count, total: $totalBytes, '
      'maxTotal: $maxTotalBytes, maxPerVideo: $maxBytesPerVideo)';
}
