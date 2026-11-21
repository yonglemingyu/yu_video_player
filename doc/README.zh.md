# yu_video_player

[English](README.md) | 简体中文

把远程视频的开头一段字节缓存到本地，前几秒从磁盘播放，其余继续走网络。

为"快速首帧"场景设计：用户点播放前先预取一小段前缀，之后播放器行为与普通在线播放完全一致。

## 平台支持

| 平台 | 实现 | 最低版本 |
|---|---|---|
| Android | `DataSource`（Media3） | API 21 |
| iOS | `AVAssetResourceLoader` | iOS 15 |

两端都不需要宿主额外配置：

- Android 不走本地代理，不需要 `network_security_config`
- iOS 用自定义 scheme，不需要 ATS 例外

## 安装

```yaml
dependencies:
  yu_video_player: ^1.1.0
```

最低要求 Flutter 3.44（Swift Package Manager 成为 iOS 默认依赖管理器的那一版）。

iOS 只走 SwiftPM，不提供 podspec。CocoaPods 官方仓库已于 2026-12-02 转为只读，
还在用 CocoaPods 的工程请先迁移。

## 仓库结构

原生核心不在本包里，而是两个独立发布的包，本包只做桥接：

| 仓库 | 内容 | 发布方式 |
|---|---|---|
| `yu_video_player` | Dart API、通道、PlatformView | pub.dev |
| `yu_video_player_ios` | iOS 前缀缓存（AVAssetResourceLoader） | git tag，SwiftPM 消费 |
| `yu_video_player_android` | Android 前缀缓存（Media3 DataSource） | Maven（JitPack / Central） |

改原生逻辑去对应的核心仓库，改通道和 Dart API 才回本包。

本地联调时 iOS 依赖指向本地核心目录（`ios/yu_video_player/Package.swift` 里的
`coreDependency`），发布前用 `tool/switch_core_dependency.sh remote` 切到远端。
Android 侧本地联调走 `mavenLocal()`，先在核心仓库执行 `./gradlew publishToMavenLocal`。

## 用法

```dart
import 'package:yu_video_player/yu_video_player.dart';

// 1. 配置容量（可选，默认全局 1GB、单条 6MB）
await YUVideoPrefixCache.configure(
  maxTotalBytes: 1024 * 1024 * 1024,
  maxBytesPerVideo: 6 * 1024 * 1024,
);

// 2. 打开预取（默认关闭，不调就不会预热）
await YUVideoPrefixCache.enable();

// 3. 详情页曝光时预取
await YUVideoPrefixCache.prefetch('3412', playUrl);

// 4. 查看用量
final stats = await YUVideoPrefixCache.stats();
debugPrint('${stats.count} 条，${stats.totalBytes ~/ 1024 ~/ 1024} MB');

// 5. 设置页列表
for (final entry in await YUVideoPrefixCache.entries()) {
  debugPrint('${entry.key} ${entry.bytes} ${entry.progress}');
}

// 6. 清理
await YUVideoPrefixCache.clear('3412');
await YUVideoPrefixCache.clearAll();
```

### 预取开关

预取默认**关闭**：不调 `enable()` 就不会有任何预取，缓存也不会建立 —— 首次播放
不探测总长就没有 meta，`mediaSource` / `playerItem` 一直走纯网络，后续也不会命中。

```dart
await YUVideoPrefixCache.enable();    // 开
await YUVideoPrefixCache.disable();   // 关

YUVideoPrefixCache.enabled;           // 当前状态（Dart 侧镜像）
```

`disable()` 只停"往前补前缀"：不再探测总长、不再下载片头，连首次播放时原生
内部那次隐式预取也一起停掉。**磁盘上已有的前缀照常命中**，播放仍走缓存链路，
只是不再继续往后写。

两个方法都不删除已有缓存；要清空间仍然用 `clear` / `clearAll`。
开关不持久化，冷启动回到关闭 —— 与容量配置一样，需要每次启动时按需调一次。

## 播放器

`YUPlayerController` + `YUVideoPlayer` 已经封装好双端 PlatformView，数据源自动走缓存链路：

```dart
final controller = YUPlayerController(vid: 'dom01', url: playUrl, autoPlay: true);
// 挂载后 view 创建、开始播放
Column(children: [AspectRatio(aspectRatio: 16 / 9, child: YUVideoPlayer(controller: controller))]);

controller.play();
controller.seekTo(const Duration(seconds: 3));
controller.setVolume(0);      // 0 = 静音但仍继续播
controller.setSpeed(1.5);     // 0.25 ~ 4.0
```

### 播放中换源

`setSource` 只替换原生 item / MediaSource，播放器实例与 view 都保留，
所以不会出现"整块 view 重建"的黑屏空档：

```dart
// 换一条片源
await controller.setSource(vid: 'dom02', url: nextUrl);

// 只换签名 / CDN 地址：vid 不变，继续命中同一份缓存
await controller.setSource(vid: 'dom01', url: freshSignedUrl);

// 传相同参数 = 原地重试
await controller.setSource(vid: 'dom01', url: playUrl);
```

换源瞬间 `value` 会回到未初始化状态（时长、分辨率、进度清零），
等原生 `ready` 事件回来再填；音量与倍速是播放器级设置，不受影响。

## 原生侧接入

`prefetch` 只负责把字节下到磁盘。要让播放器用上这份缓存，需要在原生侧
把播放器的数据源替换掉：

- **Android**：用 `YUVideoCache.mediaSource(context, vid, url)` 替代
  `MediaItem`，切换视频时调用一次，并 `acquire` / `release`。
- **iOS**：用 `YUVideoCache.playerItem(vid:realURL:)` 替代
  `AVPlayerItem(url:)`，离开播放页时 `YUVideoCache.release(vid:)`。

两端的详细步骤见仓库文档：

- `docs/android-缓存实现说明.md`
- `docs/ios-缓存接入说明.md`
- `docs/ios-缓存拦截方案.md`

## 工作原理

```
播放器请求 bytes=N-
  ├─ N 落在已缓存前缀内 → 从磁盘读
  ├─ N 越界            → 回源
  └─ 跨界              → 同一个请求里先读磁盘、再回源
```

缓存以 vid 为 key，与 URL 无关。所有入口地址（签名、CDN 切换）都不影响命中。

## 已知限制

- 只缓存从 0 开始的一段，往回拖到前缀之外需要重新下载。
- 写入只接受顺序追加；播放一开始就 seek 到中段时，那段不落盘。
- 未做 HLS 分片级缓存。
- 不支持 AirPlay（iOS 自定义 scheme 无法外放）。

## License

MIT
