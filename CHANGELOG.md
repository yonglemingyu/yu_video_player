## 1.0.1

- 修复 iOS 侧 SPM 依赖解析失败：`ios/yu_video_player/Package.swift` 里引用核心包时，
  `package:` 参数必须是 SwiftPM 由 URL 推导出的 identity `yu_video_player_ios`，
  1.0.0 误写成了远端声明的 `name: "YUVideoPlayerIOS"`，导致宿主构建报
  `unknown package 'YUVideoPlayerIOS' in dependencies of target 'yu_video_player'`。
- `tool/switch_core_dependency.sh` 的 local 模式同步对齐 identity，并把本地核心仓库路径改为
  可用 `CORE_LOCAL_PATH` 覆盖（原路径硬编码了旧机器的用户名）。
- Android 无变化。

## 1.0.0

- 首个版本：Android（Media3 DataSource）与 iOS（AVAssetResourceLoader）双端前缀缓存。
- 支持按字节配置单条与全局上限，超过上限按最久未使用淘汰。
- 支持播放前预取、播放中顺序补写、条目列表与清理。
- 前缀缓存核心拆分为独立包：iOS 为 `YUVideoPlayerIOS`（SwiftPM），Android 为
  `yu_video_player_android`（Maven），本包仅保留通道与 PlatformView。
- iOS 改为纯 SwiftPM，移除 podspec；最低 Flutter 版本提升到 3.44。
