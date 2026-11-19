## 1.0.0

- 首个版本：Android（Media3 DataSource）与 iOS（AVAssetResourceLoader）双端前缀缓存。
- 支持按字节配置单条与全局上限，超过上限按最久未使用淘汰。
- 支持播放前预取、播放中顺序补写、条目列表与清理。
- 前缀缓存核心拆分为独立包：iOS 为 `YUVideoPlayerIOS`（SwiftPM），Android 为
  `yu_video_player_android`（Maven），本包仅保留通道与 PlatformView。
- iOS 改为纯 SwiftPM，移除 podspec；最低 Flutter 版本提升到 3.44。
