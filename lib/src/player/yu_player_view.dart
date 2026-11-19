import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../yu_log.dart';
import 'yu_player_controller.dart';

/// 播放画面。
///
/// **只是显示层**：原生播放器归 [YUPlayerController] 所有，这里只负责把画面
/// 接过来。挂上就有画面，摘掉播放器还在继续出声 —— 与官方 `video_player`
/// 的 `VideoPlayer` / `VideoPlayerController` 同一个分工。
///
/// 尺寸由父级约束决定，建议外面套 [AspectRatio]。
class YUVideoPlayer extends StatefulWidget {
  const YUVideoPlayer({
    super.key,
    required this.controller,
  });

  final YUPlayerController controller;

  @override
  State<YUVideoPlayer> createState() => _YUVideoPlayerState();
}

class _YUVideoPlayerState extends State<YUVideoPlayer> {
  /// 原生画面层的 id，由 PlatformView 创建回调给出
  int? _viewId;

  // mount / unmount 与控制器本身的创建销毁分开打：只看控制器归零了、组件还挂着，
  // 或者组件卸了、控制器还在，都是业务层的账没对上
  @override
  void initState() {
    super.initState();
    YUPlayerLog.log('[挂载] 播放器组件 ${widget.controller.logTag}');
  }

  @override
  void dispose() {
    final viewId = _viewId;
    if (viewId != null) widget.controller.detachView(viewId);
    YUPlayerLog.log('[卸载] 播放器组件 ${widget.controller.logTag}');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    void attach(int id) {
      _viewId = id;
      controller.attachView(id);
    }

    // 只带播放器 id：片源、音量、进度全在播放器那边，画面层不管这些。
    // 0 表示播放器还没创建（先挂 view、后 initialize），等 initialize 之后
    // 控制器会把 attachView 补发下来。
    final params = <String, dynamic>{'playerId': controller.playerId ?? 0};

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidView(
          viewType: 'yu_player_view',
          creationParams: params,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: attach,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        );
      case TargetPlatform.iOS:
        return UiKitView(
          viewType: 'yu_player_view',
          creationParams: params,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: attach,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        );
      default:
        return const SizedBox.shrink();
    }
  }
}
