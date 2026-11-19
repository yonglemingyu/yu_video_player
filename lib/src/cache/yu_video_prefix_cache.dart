import 'dart:async';

import '../yu_channels.dart';
import 'yu_cache_entry.dart';
import 'yu_cache_stats.dart';

/// 缓存管理的唯一入口：预热、用量、清理。
///
/// 全部静态方法，无实例状态 —— 真正的缓存在原生侧，这里只做指令转发与回包转换。
/// 只用缓存管理时不需要挂播放器；要播放且吃到缓存，用 `YUVideoPlayer`。
class YUVideoPrefixCache {
  YUVideoPrefixCache._();

  /// 配置容量上限。两个参数都可省略，省略表示不修改。
  ///
  /// [maxTotalBytes] 全部缓存合计上限，默认 1GB。
  /// [maxBytesPerVideo] 单条视频上限，默认 16MB。
  static Future<void> configure({
    int? maxTotalBytes,
    int? maxBytesPerVideo,
  }) {
    return yuPluginChannel.invokeMethod<void>('configure', {
      if (maxTotalBytes != null) 'maxTotalBytes': maxTotalBytes,
      if (maxBytesPerVideo != null) 'maxBytesPerVideo': maxBytesPerVideo,
    });
  }

  /// 预取片头到磁盘。立即返回，实际下载在原生后台线程进行。
  ///
  /// [vid] 是缓存 key，与 URL 无关；同一个视频换签名地址仍然命中。
  static Future<void> prefetch(String vid, String url) {
    return yuPluginChannel.invokeMethod<void>('prefetch', {
      'vid': vid,
      'url': url,
    });
  }

  /// 当前用量与上限。
  static Future<YUCacheStats> stats() async {
    final map = await yuPluginChannel.invokeMapMethod<String, dynamic>('stats');
    return YUCacheStats.fromMap(map ?? const {});
  }

  /// 全部缓存条目，按最后使用时间倒序。
  static Future<List<YUCacheEntry>> entries() async {
    final list =
        await yuPluginChannel.invokeListMethod<dynamic>('entries') ?? const [];
    return list
        .whereType<Map<dynamic, dynamic>>()
        .map(YUCacheEntry.fromMap)
        .toList();
  }

  /// 删除某一条缓存。
  static Future<void> clear(String vid) {
    return yuPluginChannel.invokeMethod<void>('clear', {'vid': vid});
  }

  /// 清空全部缓存。
  static Future<void> clearAll() {
    return yuPluginChannel.invokeMethod<void>('clearAll');
  }

  /// 超过全局上限时按最久未使用淘汰，建议启动/回前台调用。
  ///
  /// 不调也不会失控：预取完成与每次播放结束时原生都会自动检查一次。
  /// 手动调的价值是清掉上次进程被杀时留下的尾巴。
  static Future<void> enforceLimit() {
    return yuPluginChannel.invokeMethod<void>('enforceLimit');
  }
}
