## 1.0.3

- Documentation only: `README.md` and `CHANGELOG.md` are now written in English,
  as pub.dev expects. This restores the 10 points of the "Follow Dart file
  conventions" score that were lost to the non-ASCII check.
- No code changes; identical to 1.0.2.

## 1.0.2

- Fixed a black screen on iOS where audio and the progress bar kept working.
  Flutter numbers platform views from 0, so the first view in an app gets
  `viewId=0`, while `attachView` and `detachView` filtered with `if viewId != 0`
  and dropped that legitimate view. As a result `playerLayer.player` was never
  set. Both handlers now unwrap the optional instead of treating 0 as invalid.
  Android already used `if (viewId != null)` and was unaffected.
- View teardown now detaches through `YUPlayerInstance.detachViews(viewId)`.
  When the player is created after the view, the view's `playerId` stays 0, so
  the previous `if playerId > 0` check skipped the detach.
- `tool/switch_core_dependency.sh` local mode now uses a relative path to the
  sibling core repository instead of a hard-coded absolute path.
- No changes to caching, prefetching, source switching, or the Android side.

## 1.0.1

- Fixed SPM dependency resolution on iOS. In `ios/yu_video_player/Package.swift`
  the `package:` argument of `.product(...)` must be the SwiftPM identity derived
  from the repository URL (`yu_video_player_ios`); 1.0.0 used the remote
  manifest's `name: "YUVideoPlayerIOS"` instead, which failed the host build with
  `unknown package 'YUVideoPlayerIOS' in dependencies of target 'yu_video_player'`.
- `tool/switch_core_dependency.sh` local mode now matches that identity, and the
  local core path can be overridden with `CORE_LOCAL_PATH` (it used to hard-code
  the previous machine's user name).
- No changes on Android.

## 1.0.0

- First release: prefix cache for Android (Media3 `DataSource`) and iOS
  (`AVAssetResourceLoader`).
- Per-video and global limits configured in bytes; entries are evicted
  least-recently-used once the global limit is exceeded.
- Prefetch before playback, sequential backfill during playback, entry listing
  and clearing.
- The prefix cache core is split into standalone packages: `YUVideoPlayerIOS`
  (SwiftPM) on iOS and `yu_video_player_android` (Maven) on Android. This package
  keeps only the channels and the PlatformView.
- iOS is now SwiftPM-only; the podspec was removed and the minimum Flutter
  version is 3.44.
