/// 视频前缀缓存：把片头若干字节落到磁盘，其余继续走网络。
///
/// 这个文件是唯一的公开入口，只做聚合导出，不含实现。按能力分四组：
///
/// - 缓存管理 `YUVideoPrefixCache`：预热、用量、清理；
/// - 音频会话 `YUPlayerAudio`：全局混音 / 打断策略；
/// - 数据快照 `YUCacheStats` / `YUCacheEntry`：原生回包的只读视图；
/// - 播放器 `YUPlayerController` / `YUVideoPlayer`：走缓存链路的播放器。
///
/// 只用缓存管理时不需要挂播放器；要播放且吃到缓存，用 `YUVideoPlayer`。
///
/// 能力范围：播放 / 暂停 / 拖动 / 进度 / 缓冲状态 / 分辨率 / 音量 / 倍速 /
/// 播放中换源 / 缓存命中标记 / 无画面播放（只出声）。
/// 不做：手势、全屏、字幕、画中画。
///
/// ## 为什么播放器要自己搭
///
/// 缓存只负责把片头字节下到磁盘，播放器得自己挂原生实例：数据源交给
/// `YUVideoCache` 生成，播放时才真正读磁盘。官方 `video_player` 无法注入
/// 自定义数据源，所以这里不复用它。
///
/// ## 播放器内部的分层
///
/// 与官方 `video_player` 同构：**播放器归控制器，画面归组件**。
///
/// - `YUVideoPlayer` 只是显示层，挂上就有画面、摘掉就只剩声音；
/// - 原生播放器由控制器 `initialize()` 时通过 `createPlayer` 单独创建，
///   有自己的方法通道与事件通道（地址里是 `playerId`，不是 viewId）。
///
/// 实现都在 `src/player/` 下，公开的一共四个：
/// - [YUPlayerValue]：不可变状态快照，UI 只认它；
/// - [YUPlayerSource]：一次播放请求的片源（vid / url / 自动播放）；
/// - [YUPlayerController]：对外 API，持有原生播放器、把指令交给通道、把事件折成状态；
/// - [YUVideoPlayer]：PlatformView 外壳，只负责把画面接过来。
///
/// 不公开的两层：`YUPlayerBridge` 收口两条通道的收发，
/// `applyPlayerEvent` 负责事件到状态的纯映射。
library;

export 'src/audio/yu_player_audio.dart';
export 'src/cache/yu_cache_entry.dart';
export 'src/cache/yu_cache_stats.dart';
export 'src/cache/yu_video_prefix_cache.dart';
export 'src/player/yu_player_controller.dart';
export 'src/player/yu_player_source.dart';
export 'src/player/yu_player_value.dart';
export 'src/player/yu_player_view.dart';
export 'yu_log.dart';
