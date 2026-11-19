import Flutter
import UIKit
import YUVideoPlayerIOS

/// Flutter 入口：把 YUVideoCache 的能力暴露给 Dart。
///
/// 三件事：缓存管理方法（configure/prefetch/stats/...）、创建原生播放器
/// （`createPlayer`，返回播放器 id）、以及注册画面层 PlatformView
/// （`yu_player_view`，见 `YUPlayerPlatformView`）。
///
/// 播放器与画面层是分开的两件事：没有 view 也能建播放器、也能出声。
public class YUVideoCachePlugin: NSObject, FlutterPlugin {

    private var messenger: FlutterBinaryMessenger?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "yu_video_player",
                                           binaryMessenger: registrar.messenger())
        let instance = YUVideoCachePlugin()
        instance.messenger = registrar.messenger()
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.register(YUPlayerViewFactory(messenger: registrar.messenger()),
                           withId: "yu_player_view")
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "createPlayer":
            // 只建播放器，不涉及任何 view：没有画面也能拉流、出声
            guard let messenger else {
                result(FlutterError(code: "no_engine", message: "plugin not attached", details: nil))
                return
            }
            result(YUPlayerInstance.create(messenger: messenger))

        case "configure":
            if let args = call.arguments as? [String: Any] {
                if let total = args["maxTotalBytes"] as? NSNumber {
                    YUVideoCache.maxTotalBytes = total.int64Value
                }
                if let perVideo = args["maxBytesPerVideo"] as? NSNumber {
                    YUVideoCache.maxBytesPerVideo = perVideo.int64Value
                }
            }
            result(nil)

        case "prefetch":
            guard let args = call.arguments as? [String: Any],
                  let vid = args["vid"] as? String,
                  let urlString = args["url"] as? String,
                  let url = URL(string: urlString) else {
                result(FlutterError(code: "bad_args", message: "vid and url are required", details: nil))
                return
            }
            YUVideoCache.prefetch(vid: vid, realURL: url)
            result(nil)

        case "stats":
            result([
                "count": YUVideoCache.count,
                "totalBytes": YUVideoCache.totalSize,
                "maxTotalBytes": YUVideoCache.maxTotalBytes,
                "maxBytesPerVideo": YUVideoCache.maxBytesPerVideo,
            ])

        case "entries":
            let list: [[String: Any]] = YUVideoCache.entries.map { entry in
                [
                    "key": entry.key,
                    "bytes": entry.bytes,
                    "downloaded": entry.downloaded,
                    "limit": entry.limit,
                    "totalLength": entry.totalLength,
                    "progress": entry.progress,
                    "updatedAt": Int(entry.updatedAt.timeIntervalSince1970 * 1000),
                ]
            }
            result(list)

        case "clear":
            guard let args = call.arguments as? [String: Any],
                  let vid = args["vid"] as? String else {
                result(FlutterError(code: "bad_args", message: "vid is required", details: nil))
                return
            }
            YUVideoCache.clear(vid: vid)
            result(nil)

        case "clearAll":
            YUVideoCache.clearAll()
            result(nil)

        case "enforceLimit":
            YUVideoCache.enforceLimit()
            result(nil)

        case "configureAudio":
            let args = call.arguments as? [String: Any] ?? [:]
            YUAudioSession.shared.configure(
                mixWithOthers: args["mixWithOthers"] as? Bool ?? false,
                duckOthers: args["duckOthers"] as? Bool ?? false,
                resumeAfterInterruption: args["resumeAfterInterruption"] as? Bool ?? true
            )
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
