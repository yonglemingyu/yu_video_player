import 'dart:async';

import '../yu_channels.dart';

/// 全局音频会话策略，影响此后创建的所有播放器。
///
/// 不配置时插件按「独占媒体」处理：会打断用户正在播放的音乐，
/// 这也是大多数短视频 App 的默认行为。
class YUPlayerAudio {
  YUPlayerAudio._();

  /// 配置音频会话，App 启动时调一次即可。
  ///
  /// [mixWithOthers] 为 true 时不打断正在播放的音乐，代价是不独占音频焦点
  /// （两边声音会混在一起）；[duckOthers] 为 true 时压低其它 App 的音量而非
  /// 完全抢占，与 [mixWithOthers] 同时为 true 时以 [mixWithOthers] 为准。
  ///
  /// [resumeAfterInterruption] 为 true 时，来电、闹钟等中断结束后自动继续播放。
  ///
  /// 两端差异：Android 只认 [mixWithOthers]（直接决定是否申请音频焦点），
  /// 另两个参数被忽略；且 Android 在创建播放器时读取一次，之后再调只影响新建的。
  static Future<void> configure({
    bool mixWithOthers = false,
    bool duckOthers = false,
    bool resumeAfterInterruption = true,
  }) {
    return yuPluginChannel.invokeMethod<void>('configureAudio', {
      'mixWithOthers': mixWithOthers,
      'duckOthers': duckOthers && !mixWithOthers,
      'resumeAfterInterruption': resumeAfterInterruption,
    });
  }
}
