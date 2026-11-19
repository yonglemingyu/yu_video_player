/// 一条缓存的可读快照。
///
/// 纯数据：不依赖 Flutter，也不持有通道，可脱离环境单测。
class YUCacheEntry {
  const YUCacheEntry({
    required this.key,
    required this.bytes,
    required this.downloaded,
    required this.limit,
    required this.totalLength,
    required this.progress,
    required this.updatedAt,
  });

  /// 由原生回包构造。
  ///
  /// 插件内部使用：业务层应通过 `YUVideoPrefixCache.entries()` 获取。
  factory YUCacheEntry.fromMap(Map<dynamic, dynamic> map) {
    final millis = (map['updatedAt'] as num?)?.toInt() ?? 0;
    return YUCacheEntry(
      key: map['key'] as String? ?? '',
      bytes: (map['bytes'] as num?)?.toInt() ?? 0,
      downloaded: (map['downloaded'] as num?)?.toInt() ?? 0,
      limit: (map['limit'] as num?)?.toInt() ?? 0,
      totalLength: (map['totalLength'] as num?)?.toInt() ?? 0,
      progress: (map['progress'] as num?)?.toDouble() ?? 0,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(millis),
    );
  }

  /// 缓存 key，即目录名（vid 中非字母数字字符会被替换成 `_`）。
  final String key;

  /// 实际占用字节。
  final int bytes;

  /// 已写入前缀的字节数。
  final int downloaded;

  /// 前缀上限（字节）。
  final int limit;

  /// 整片总字节数。
  final int totalLength;

  /// 前缀完成度 0~1。
  final double progress;

  /// 最后使用时间。
  final DateTime updatedAt;

  @override
  String toString() => 'YUCacheEntry($key, ${bytes ~/ 1024}KB, '
      '${(progress * 100).toStringAsFixed(0)}%)';
}
