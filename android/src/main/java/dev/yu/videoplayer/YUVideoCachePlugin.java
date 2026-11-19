package dev.yu.videoplayer;

import dev.yu.videoplayer.core.*;

import android.content.Context;

import androidx.annotation.NonNull;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Flutter 入口：把 YUVideoCache 的能力暴露给 Dart。
 *
 * 三件事：缓存管理方法（configure/prefetch/stats/...）、创建原生播放器
 * ({@code createPlayer}，返回播放器 id）、以及注册画面层 PlatformView
 * （{@code yu_player_view}，见 {@link YUPlayerView}）。
 *
 * 播放器与画面层是分开的两件事：没有 view 也能建播放器、也能出声。
 */
public class YUVideoCachePlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {

    private MethodChannel channel;
    private Context context;
    private BinaryMessenger messenger;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        messenger = binding.getBinaryMessenger();
        channel = new MethodChannel(messenger, "yu_video_player");
        channel.setMethodCallHandler(this);
        binding.getPlatformViewRegistry()
                .registerViewFactory("yu_player_view", new YUPlayerViewFactory());
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (channel != null) {
            channel.setMethodCallHandler(null);
            channel = null;
        }
        // 引擎没了：所有播放器一起收掉，别留下还在跑的解码器
        YUPlayerInstance.releaseAll();
        messenger = null;
        context = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        if (context == null) {
            result.error("no_context", "plugin not attached", null);
            return;
        }

        switch (call.method) {
            case "createPlayer": {
                // 只建播放器，不涉及任何 view：没有画面也能拉流、出声
                if (messenger == null) {
                    result.error("no_engine", "plugin not attached", null);
                    return;
                }
                result.success(YUPlayerInstance.create(context, messenger));
                break;
            }
            case "configure": {
                Long total = asLong(call.argument("maxTotalBytes"));
                Long perVideo = asLong(call.argument("maxBytesPerVideo"));
                if (total != null) YUVideoCache.setMaxTotalBytes(total);
                if (perVideo != null) YUVideoCache.setMaxBytesPerVideo(perVideo);
                result.success(null);
                break;
            }
            case "prefetch": {
                String vid = call.argument("vid");
                String url = call.argument("url");
                if (vid == null || url == null) {
                    result.error("bad_args", "vid and url are required", null);
                    return;
                }
                // 后台执行，调用即返回
                YUVideoCache.prefetch(context, vid, url);
                result.success(null);
                break;
            }
            case "stats": {
                result.success(statsMap());
                break;
            }
            case "entries": {
                result.success(entriesList());
                break;
            }
            case "clear": {
                String vid = call.argument("vid");
                if (vid == null) {
                    result.error("bad_args", "vid is required", null);
                    return;
                }
                YUVideoCache.clear(context, vid);
                result.success(null);
                break;
            }
            case "clearAll": {
                YUVideoCache.clearAll(context);
                result.success(null);
                break;
            }
            case "enforceLimit": {
                YUVideoCache.enforceLimit(context);
                result.success(null);
                break;
            }
            case "configureAudio": {
                Boolean mix = call.argument("mixWithOthers");
                Boolean duck = call.argument("duckOthers");
                Boolean resume = call.argument("resumeAfterInterruption");
                YUPlayerAudio.configure(
                        Boolean.TRUE.equals(mix),
                        Boolean.TRUE.equals(duck),
                        !Boolean.FALSE.equals(resume));
                result.success(null);
                break;
            }
            default:
                result.notImplemented();
        }
    }

    private Map<String, Object> statsMap() {
        Map<String, Object> map = new HashMap<>();
        map.put("count", YUVideoCache.count(context));
        map.put("totalBytes", YUVideoCache.totalSize(context));
        map.put("maxTotalBytes", YUPrefixCache.maxTotalBytes);
        map.put("maxBytesPerVideo", YUPrefixCache.maxBytesPerVideo);
        return map;
    }

    private List<Map<String, Object>> entriesList() {
        List<Map<String, Object>> list = new ArrayList<>();
        for (YUPrefixCache.YUEntry entry : YUVideoCache.entries(context)) {
            Map<String, Object> item = new HashMap<>();
            item.put("key", entry.key);
            item.put("bytes", entry.bytes);
            item.put("downloaded", entry.downloaded);
            item.put("limit", entry.limit);
            item.put("totalLength", entry.totalLength);
            item.put("progress", (double) entry.progress());
            item.put("updatedAt", entry.updatedAt);
            list.add(item);
        }
        return list;
    }

    private static Long asLong(Object value) {
        if (value instanceof Number) return ((Number) value).longValue();
        return null;
    }
}
