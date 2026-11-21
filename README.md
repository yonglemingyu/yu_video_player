# yu_video_player

English | [简体中文](https://github.com/yonglemingyu/yu_video_player/blob/main/doc/README.zh.md)

Cache the opening bytes of a remote video to disk, so the first seconds play
from disk while the rest keeps streaming from the network.

Designed for the "fast first frame" case: prefetch a small prefix before the
user taps play, and the player still behaves like a normal online player after
that prefix.

## Platform support

| Platform | Implementation | Minimum |
|---|---|---|
| Android | `DataSource` (Media3) | API 21 |
| iOS | `AVAssetResourceLoader` | iOS 15 |

Neither platform needs host-side configuration:

- Android uses no local proxy, so no `network_security_config` is required.
- iOS uses a custom URL scheme, so no ATS exception is required.

## Installation

```yaml
dependencies:
  yu_video_player: ^1.1.0
```

Requires Flutter 3.44 or later (the release where Swift Package Manager became
the default dependency manager on iOS).

iOS is supported through SwiftPM only; no podspec is shipped. The CocoaPods
trunk went read-only on 2026-12-02, so projects still on CocoaPods should
migrate first.

## Repository layout

The native cores are not part of this package. This package is a bridge over
two separately published packages:

| Repository | Contents | Distribution |
|---|---|---|
| `yu_video_player` | Dart API, channels, PlatformView | pub.dev |
| `yu_video_player_ios` | iOS prefix cache (`AVAssetResourceLoader`) | git tag, consumed by SwiftPM |
| `yu_video_player_android` | Android prefix cache (Media3 `DataSource`) | Maven (JitPack / Central) |

Change native logic in the matching core repository; change channels or the
Dart API here.

For local development the iOS dependency points at the local core checkout
through `coreDependency` in `ios/yu_video_player/Package.swift`; run
`tool/switch_core_dependency.sh remote` before publishing. On Android, local
integration resolves through `mavenLocal()`, so run
`./gradlew publishToMavenLocal` in the core repository first.

## Usage

```dart
import 'package:yu_video_player/yu_video_player.dart';

// 1. Configure capacity (optional; defaults to 1GB total, 6MB per video)
await YUVideoPrefixCache.configure(
  maxTotalBytes: 1024 * 1024 * 1024,
  maxBytesPerVideo: 6 * 1024 * 1024,
);

// 2. Turn prefetching on (off by default)
await YUVideoPrefixCache.enable();

// 3. Prefetch when the detail page becomes visible
await YUVideoPrefixCache.prefetch('3412', playUrl);

// 4. Inspect usage
final stats = await YUVideoPrefixCache.stats();
debugPrint('${stats.count} entries, ${stats.totalBytes ~/ 1024 ~/ 1024} MB');

// 5. List entries for a settings screen
for (final entry in await YUVideoPrefixCache.entries()) {
  debugPrint('${entry.key} ${entry.bytes} ${entry.progress}');
}

// 6. Clear
await YUVideoPrefixCache.clear('3412');
await YUVideoPrefixCache.clearAll();
```

### Turning prefetch off

Prefetching is **off by default**: without `enable()` nothing is prefetched and no
cache is built. On the first play the total length is never probed, so no meta is
written, `mediaSource` / `playerItem` keep using the plain network path, and later
plays never hit the cache.

```dart
await YUVideoPrefixCache.enable();    // on
await YUVideoPrefixCache.disable();   // off

YUVideoPrefixCache.enabled;           // current state (Dart-side mirror)
```

`disable()` only stops the "warm the prefix forward" side: no more probing for
the total length, no more downloading the head of the file, including the
implicit prefetch the native player triggers the first time a source is loaded.
**Prefixes already on disk are still used**, so playback keeps the cache path
and simply stops writing further ahead.

Neither call deletes cached data; use `clear` / `clearAll` for that. The switch
is not persisted and returns to off after a cold start, so set it on every launch
the same way you set the capacity limits.

## Player

`YUPlayerController` and `YUVideoPlayer` wrap the native PlatformView on both
platforms, and the data source goes through the cache path automatically:

```dart
final controller = YUPlayerController(vid: 'dom01', url: playUrl, autoPlay: true);
// Mounting creates the view and starts playback
Column(children: [AspectRatio(aspectRatio: 16 / 9, child: YUVideoPlayer(controller: controller))]);

controller.play();
controller.seekTo(const Duration(seconds: 3));
controller.setVolume(0);      // 0 = muted, playback continues
controller.setSpeed(1.5);     // 0.25 ~ 4.0
```

### Switching source during playback

`setSource` replaces only the native item or MediaSource. The player instance
and the view are kept, so there is no black gap from rebuilding the whole view:

```dart
// Switch to another video
await controller.setSource(vid: 'dom02', url: nextUrl);

// Refresh the signature or CDN address only: same vid, same cache entry
await controller.setSource(vid: 'dom01', url: freshSignedUrl);

// Same arguments = retry in place
await controller.setSource(vid: 'dom01', url: playUrl);
```

`value` resets to the uninitialized state on switch (duration, size and
position are cleared) and is filled in when the native `ready` event arrives.
Volume and speed are player-level settings and are not affected.

## Native integration

`prefetch` only writes bytes to disk. To make a player use that cache, swap its
data source on the native side:

- **Android**: replace `MediaItem` with
  `YUVideoCache.mediaSource(context, vid, url)`, call it once per video switch,
  and pair `acquire` with `release`.
- **iOS**: replace `AVPlayerItem(url:)` with
  `YUVideoCache.playerItem(vid:realURL:)`, and call
  `YUVideoCache.release(vid:)` when leaving the player screen.

Detailed steps live in the repository docs:

- `docs/android-缓存实现说明.md`
- `docs/ios-缓存接入说明.md`
- `docs/ios-缓存拦截方案.md`

## How it works

```
Player requests bytes=N-
  |- N inside the cached prefix  -> read from disk
  |- N past the prefix           -> fetch from origin
  '- N spans the boundary        -> read disk, then continue from origin
                                      within the same request
```

The cache is keyed by vid, not by URL. Signature refreshes and CDN switches do
not affect cache hits.

## Known limitations

- Only the range starting at 0 is cached; seeking back outside the prefix
  downloads again.
- Writes are sequential and append-only, so a seek into the middle at the very
  start of playback is not persisted.
- HLS segment-level caching is not implemented.
- AirPlay is not supported (iOS custom URL schemes cannot be sent to an
  external device).

## License

MIT
