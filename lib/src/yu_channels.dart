/// 通道地址集中管理，避免字符串散落在各个文件里。
///
/// 播放器实例的通道按 `playerId` 动态拼，见 `src/player/yu_player_bridge.dart`；
/// 这里的常量只放插件级的全局通道（缓存管理、音频会话、创建播放器）。
library;

import 'package:flutter/services.dart';

/// 插件级全局通道：缓存管理、音频会话，以及播放器的创建入口。
const MethodChannel yuPluginChannel = MethodChannel('yu_video_player');

/// 一个原生播放器实例的方法通道。
///
/// `playerId` 由原生 `createPlayer` 分配，**与 view 无关**：没有
/// `YUVideoPlayer` 时同一个播放器照样能拉流、出声。
MethodChannel yuPlayerChannel(int playerId) =>
    MethodChannel('yu_video_player/player/$playerId');

/// 一个原生播放器实例的事件通道。与 [yuPlayerChannel] 同一个 playerId，
/// 生命周期跟着播放器走，不跟 view 走。
EventChannel yuPlayerEvents(int playerId) =>
    EventChannel('yu_video_player/events/$playerId');
