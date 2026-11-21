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

  /// 预取开关的 Dart 侧镜像，用于在过通道之前就短路。
  ///
  /// 真值在原生侧（[enable] / [disable] 下发），这里只是记一份，省掉关闭
  /// 状态下每次预取的一次通道往返。默认关闭，冷启动两端都回到 `false`。
  static bool _enabled = false;

  /// 预取是否开启。默认 `false`。
  ///
  /// 开启后才会探测总长、下载片头；关闭时**已经落到磁盘的前缀照常命中**，
  /// 播放仍走缓存链路，只是不再往后续写。
  static bool get enabled => _enabled;

  /// 配置容量上限。两个参数都可省略，省略表示不修改。
  ///
  /// [maxTotalBytes] 全部缓存合计上限，默认 1GB。
  /// [maxBytesPerVideo] 单条视频上限，默认 6MB；建条目时固化进 meta，
  /// 改小只对新 vid 生效。
  ///
  /// 预取开关不在这里，见 [enable] / [disable]。
  static Future<void> configure({
    int? maxTotalBytes,
    int? maxBytesPerVideo,
  }) {
    return yuPluginChannel.invokeMethod<void>('configure', {
      if (maxTotalBytes != null) 'maxTotalBytes': maxTotalBytes,
      if (maxBytesPerVideo != null) 'maxBytesPerVideo': maxBytesPerVideo,
    });
  }

  /// 打开预取：详情页曝光就预热片头，首次播放也会顺带建好 meta。
  ///
  /// 默认**关闭**：不调它就不会有任何预取，缓存也就不会建立。需要在
  /// 每次启动后主动调一次（开关不持久化）。
  static Future<void> enable() => _setEnabled(true);

  /// 关闭预取：不再探测总长、不再下载片头，连首次播放时原生内部那次隐式
  /// 预取也一起停掉。已经缓存好的前缀照常命中，播放不受影响。
  ///
  /// 不删除任何缓存；要腾空间用 [clear] / [clearAll]。
  static Future<void> disable() => _setEnabled(false);

  static Future<void> _setEnabled(bool enabled) {
    // 先改镜像再发指令：桌面 / Web 没有原生实现时会把异常抛给调用方，
    // 但这里改的只是本地状态，不影响任何已发生的行为。
    _enabled = enabled;
    return yuPluginChannel
        .invokeMethod<void>('setEnabled', {'enabled': enabled});
  }

  /// 预取片头到磁盘。立即返回，实际下载在原生后台线程进行。
  ///
  /// [vid] 是缓存 key，与 URL 无关；同一个视频换签名地址仍然命中。
  ///
  /// 开关关闭（[disable]）时直接返回，连通道都不进。
  static Future<void> prefetch(String vid, String url) {
    if (!_enabled) return Future<void>.value();
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
