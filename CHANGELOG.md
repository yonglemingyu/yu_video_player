## 1.0.2

- 修复 iOS 画面全黑（有声音、进度条在走）：Flutter 的 platform view 编号从 0 开始，
  App 里首个视图拿到的就是 `viewId=0`，而 `attachView` / `detachView` 里用
  `if viewId != 0` 过滤，把合法的 0 号视图丢掉了，`playerLayer.player` 一直没设上。
  现在改为可选值判空，不再把 0 当无效值。Android 侧原本就是 `if (viewId != null)`，不受影响。
- 视图回收时改走 `YUPlayerInstance.detachViews(viewId)` 摘画面：播放器晚于视图创建时
  `playerId` 恒为 0，原来的 `if playerId > 0` 会漏掉 detach。
- `tool/switch_core_dependency.sh` 的 local 模式改用同级目录相对路径，不再写死绝对路径。
- 缓存、预取、换源逻辑与 Android 侧均无变化。

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
