import 'package:flutter/foundation.dart';

/// 生命周期日志，用来排查"播放器到底有没有被释放"。
///
/// 排查时看三条线：
/// 1. `[创建]` 与 `[销毁]` 是否成对：只有创建没有销毁就是泄漏；
/// 2. 行尾 `xxx存活` 是否回到 0；
/// 3. 原生侧同一时刻的「视图存活」/「播放项存活」有没有一起归零。
///
/// Dart 这边的「控制器存活」归零而原生「视图存活」不归零，说明 controller
/// 已经 dispose 但 PlatformView 被引擎留着（原生泄漏）；
/// 反过来「控制器存活」不归零，说明业务层漏了 `controller.dispose()`。
///
/// 关掉：`YUPlayerLog.enabled = false`。
class YUPlayerLog {
  YUPlayerLog._();

  /// 总开关，默认开
  static bool enabled = true;

  /// 三端统一的 tag，与 Android 的 `Log` TAG 同名，过滤时搜这一串即可
  static const String _tag = '[YUPlayer][Flutter]';

  static int _seq = 0;
  static final Map<String, int> _live = <String, int>{};

  /// 每创建一个对象取一个号，销毁时用同一个号打印，方便配对
  static int nextId() => ++_seq;

  /// 当前存活数量
  static int count(String kind, int delta) {
    final next = (_live[kind] ?? 0) + delta;
    _live[kind] = next < 0 ? 0 : next;
    return _live[kind]!;
  }

  static void log(String message) {
    if (!enabled) return;
    debugPrint('$_tag ${_stamp()} $message');
  }

  /// 创建打点：`[创建] 控制器#1 vid=xx 控制器存活=1`
  static void birth(String kind, int id, String detail) {
    if (!enabled) return;
    log('[创建] $kind#$id $detail $kind存活=${count(kind, 1)}');
  }

  /// 销毁打点：`[销毁] 控制器#1 存活=4.32s ... 控制器存活=0`
  static void death(String kind, int id, String detail) {
    if (!enabled) return;
    log('[销毁] $kind#$id $detail $kind存活=${count(kind, -1)}');
  }

  /// 存活时长，形如 `存活=4.32s`
  static String alive(int sinceMicros) {
    final elapsed = DateTime.now().microsecondsSinceEpoch - sinceMicros;
    return '存活=${(elapsed / 1000000).toStringAsFixed(2)}s';
  }

  static String _stamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}'
        '.${now.millisecond.toString().padLeft(3, '0')}';
  }
}
