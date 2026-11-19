package dev.yu.videoplayer;

import dev.yu.videoplayer.core.*;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.view.TextureView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.VideoSize;
import androidx.media3.exoplayer.ExoPlayer;

import java.util.HashMap;
import java.util.Map;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * 一个原生播放器实例，**不依赖任何 view**。
 *
 * 与旧结构的区别：以前播放器长在 {@link YUPlayerView} 里，view 没了播放就没了；
 * 现在播放器由 Dart 控制器通过 {@code createPlayer} 单独创建，view 只是
 * 「往哪个 {@link TextureView} 上画」，随时可以 attach / detach。
 *
 * 因此没有 view 时也能拉流、出声 —— 这正是与官方 video_player 对齐的分层。
 * 数据源仍由 {@link YUVideoCache#mediaSource} 生成，播放时直接读磁盘前缀。
 */
final class YUPlayerInstance implements MethodChannel.MethodCallHandler {

    /** playerId -> 实例。Dart 侧的通道地址就是按这个 id 拼的 */
    static final Map<Integer, YUPlayerInstance> instances = new HashMap<>();

    /** viewId -> 画面层。Dart 让播放器 attach 时按 viewId 找它 */
    static final Map<Integer, YUPlayerView> views = new HashMap<>();

    private static int nextId = 1;

    /** 建一个播放器实例，返回它的 id（通道地址的一部分） */
    static synchronized int create(@NonNull Context context,
                                   @NonNull BinaryMessenger messenger) {
        final int id = nextId++;
        instances.put(id, new YUPlayerInstance(context.getApplicationContext(), messenger, id));
        return id;
    }

    /** 按 id 销毁。找不到说明已经被释放，幂等 */
    static synchronized void releaseById(int id) {
        final YUPlayerInstance instance = instances.remove(id);
        if (instance != null) instance.dispose();
    }

    /** 引擎卸载时把所有播放器收掉 */
    static synchronized void releaseAll() {
        for (YUPlayerInstance instance : new java.util.ArrayList<>(instances.values())) {
            instance.dispose();
        }
        instances.clear();
        views.clear();
    }

    @Nullable
    static YUPlayerInstance find(int id) {
        synchronized (YUPlayerInstance.class) {
            return instances.get(id);
        }
    }

    private static final long TICK_MS = 200;

    private final Context context;
    /** 播放器 id：既是通道地址，也是日志里的编号，和 Dart 侧一对一对上 */
    private final int playerId;
    private final ExoPlayer player;
    private final MethodChannel methods;
    private final EventChannel events;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final long createdAt = System.currentTimeMillis();
    /** 本次片源开始装配的时刻，换源时重置；用来算「起播耗时」 */
    private long sourceStartedAt = System.currentTimeMillis();
    /** 当前片源的缓存主键，换源后会变（使用计数在 {@link #loadSource} 里换手） */
    private String vid = "";
    private boolean usingCache;
    /**
     * 上一次推给 Dart 的 position / buffered（毫秒，-1 表示还没推过）。
     *
     * 200ms 的采样节拍照旧，但值没变就不发：卡在缓冲这类位置不动的场景，
     * 原来每拍都往通道塞一条内容完全相同的消息。
     */
    private long lastSentPositionMs = -1L;
    private long lastSentBufferedMs = -1L;

    /** 当前画在哪个 TextureView 上，没有画面时为 null */
    @Nullable
    private TextureView textureView;
    private int attachedViewId;

    @Nullable
    private EventChannel.EventSink sink;
    private boolean released;
    private boolean readySent;

    @SuppressWarnings("unchecked")
    private YUPlayerInstance(@NonNull Context context,
                             @NonNull BinaryMessenger messenger,
                             int playerId) {
        this.context = context;
        this.playerId = playerId;

        methods = new MethodChannel(messenger, "yu_video_player/player/" + playerId);
        methods.setMethodCallHandler(this);

        events = new EventChannel(messenger, "yu_video_player/events/" + playerId);
        events.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink sink) {
                YUPlayerInstance.this.sink = sink;
                // Dart 订阅上来的那一刻补一次快照，避免早于订阅丢失状态
                sendState();
                if (readySent) sendReady();
                // 断线期间的位置推送丢了，去重表作废，恢复推送后第一拍必发
                lastSentPositionMs = -1L;
                lastSentBufferedMs = -1L;
            }

            @Override
            public void onCancel(Object arguments) {
                sink = null;
            }
        });

        YULog.birth("播放器", playerId, "playerId=" + playerId);

        player = new ExoPlayer.Builder(context).build();
        // 第二个参数为 true 时申请音频焦点：来电/闹钟等打断会自动暂停，
        // 中断结束后恢复；混音场景传 false，不抢焦点也不打断别人
        player.setAudioAttributes(
                new AudioAttributes.Builder()
                        .setUsage(C.USAGE_MEDIA)
                        .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                        .build(),
                !YUPlayerAudio.mixWithOthers());
        player.addListener(new Player.Listener() {
            @Override
            public void onPlaybackStateChanged(int state) {
                if (state == Player.STATE_READY && !readySent) sendReady();
                if (state == Player.STATE_ENDED) {
                    YULog.log("[播完] 播放器#" + playerId + " vid=" + vid);
                    send("completed", null);
                }
                // 进入缓冲时重新起轮询：缓冲期间 position 不动但 buffered 在涨
                if (state == Player.STATE_BUFFERING) tickPosition();
                sendState();
            }

            @Override
            public void onIsPlayingChanged(boolean isPlaying) {
                sendState();
                if (isPlaying) tickPosition();
            }

            @Override
            public void onVideoSizeChanged(@NonNull VideoSize size) {
                Map<String, Object> payload = sizePayload(size);
                // 尺寸未确定时不上报，避免把上层已知值冲成 0
                if (!payload.isEmpty()) send("size", payload);
            }

            @Override
            public void onPlayerError(@NonNull PlaybackException error) {
                Map<String, Object> map = new HashMap<>();
                String message = error.getMessage();
                map.put("message", message != null
                        ? message
                        : "errorCode " + error.errorCode);
                YULog.log("[错误] 播放器#" + playerId + " vid=" + vid
                        + " 原因=" + map.get("message"));
                send("error", map);
                sendState();
            }
        });
    }

    // ---- 画面挂载 ----

    /**
     * 把画面接到指定的 view 上。播放器可能比 view 先建、也可能后建，
     * 两边谁先到都行：后到的一方主动调这个方法。
     */
    void attachView(int viewId) {
        if (released) return;
        final YUPlayerView view;
        synchronized (YUPlayerInstance.class) {
            view = views.get(viewId);
        }
        if (view == null) {
            // view 还没建好：它构造完会自己回头挂上来
            YULog.log("[连接] 播放器#" + playerId + " 视图#" + viewId + " 还没建好，等它上来");
            return;
        }
        attachTexture(view.textureView(), viewId);
    }

    /** 把画面接到一个 TextureView 上（view 自己构造完也会调这里） */
    void attachTexture(@NonNull TextureView target, int viewId) {
        if (released) return;
        if (textureView == target) return;
        textureView = target;
        attachedViewId = viewId;
        player.setVideoTextureView(target);
        YULog.log("[连接] 播放器#" + playerId + " <-> 视图#" + viewId
                + (player.getPlaybackState() == Player.STATE_READY ? "（立即出画）" : ""));
    }

    /**
     * 摘掉画面，播放器继续跑 —— 这是「关掉画面还有声音」的关键。
     *
     * 只清 TextureView，不动 player 与片源，也不减缓存计数（计数归播放器）。
     */
    void detachTexture(@Nullable TextureView target) {
        if (released) return;
        if (target == null || textureView != target) return;
        player.clearVideoTextureView(target);
        textureView = null;
        YULog.log("[连接] 播放器#" + playerId + " 摘掉 视图#" + attachedViewId + "（继续出声）");
        attachedViewId = 0;
    }

    void detachView(int viewId) {
        if (released) return;
        final YUPlayerView view;
        synchronized (YUPlayerInstance.class) {
            view = views.get(viewId);
        }
        detachTexture(view != null ? view.textureView() : textureView);
    }

    // ---- 片源 ----

    /**
     * 装配一份片源：占位（计数加一）→ 换 MediaSource → prepare → 起播。
     *
     * 计数换手顺序是「先加新的、再减旧的」，中间不会出现零引用被淘汰掉目录。
     * 播放器实例、TextureView、音量、倍速都保留，所以换源没有整块重建的空档。
     */
    private void loadSource(String newVid, String url, boolean autoPlay) {
        sourceStartedAt = System.currentTimeMillis();
        String oldVid = vid;

        // 先占位再装配：避免 setMediaSource 到 prepare 之间被淘汰逻辑删掉目录
        YUVideoCache.acquire(newVid);
        vid = newVid;
        usingCache = YUPrefixCache.storeIfReady(context, newVid) != null;
        readySent = false;
        // 换了片源，上一份的进度不能拿来比对，否则新片从 0 开始会被吞掉
        lastSentPositionMs = -1L;
        lastSentBufferedMs = -1L;

        // stop 会释放旧 MediaSource（连同它的 DataSource 与在飞请求）
        player.stop();
        player.setMediaSource(YUVideoCache.mediaSource(context, newVid, url));
        player.prepare();
        player.setPlayWhenReady(autoPlay);

        if (!oldVid.isEmpty()) YUVideoCache.release(context, oldVid);

        YULog.log("[换源] 播放器#" + playerId + " -> vid=" + newVid
                + " 命中缓存=" + usingCache + " 自动播放=" + autoPlay
                + " 画面=" + (textureView != null ? "有" : "无"));

        sendState();
    }

    // ---- 方法通道 ----

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        if (released) {
            result.error("released", "player already released", null);
            return;
        }
        switch (call.method) {
            case "play":
                player.play();
                result.success(null);
                break;
            case "pause":
                player.pause();
                result.success(null);
                break;
            case "seekTo": {
                Long positionMs = asLong(call.argument("positionMs"));
                if (positionMs != null) player.seekTo(Math.max(0, positionMs));
                result.success(null);
                break;
            }
            case "setVolume": {
                Double volume = asDouble(call.argument("volume"));
                if (volume != null) {
                    player.setVolume((float) Math.min(Math.max(volume, 0.0), 1.0));
                }
                result.success(null);
                break;
            }
            case "setSpeed": {
                Double speed = asDouble(call.argument("speed"));
                if (speed != null) {
                    // 这个值是持久的：暂停时设置，起播后依然生效
                    player.setPlaybackSpeed((float) Math.min(Math.max(speed, 0.25), 4.0));
                }
                result.success(null);
                break;
            }
            case "setSource": {
                // 播放中换源 / 换签名：只换 MediaSource，player 与 view 都保留
                String newVid = asString(call.argument("vid"), "");
                if (newVid.isEmpty()) {
                    result.error("bad_args", "vid is empty", null);
                    break;
                }
                String newUrl = asString(call.argument("url"), "");
                Boolean autoPlayArg = asBoolean(call.argument("autoPlay"));
                loadSource(newVid, newUrl, autoPlayArg == null || autoPlayArg);
                result.success(null);
                break;
            }
            case "attachView": {
                Integer viewId = asInt(call.argument("viewId"));
                if (viewId != null) attachView(viewId);
                result.success(null);
                break;
            }
            case "detachView": {
                Integer viewId = asInt(call.argument("viewId"));
                if (viewId != null) detachView(viewId);
                result.success(null);
                break;
            }
            case "release": {
                // Dart 侧 dispose 时主动调用，不等 view / 引擎回收
                releaseById(playerId);
                result.success(null);
                break;
            }
            default:
                result.notImplemented();
        }
    }

    // ---- 销毁 ----

    private void dispose() {
        if (released) return;
        released = true;
        // 只看到这条、看不到垃圾回收后的收尾是正常的：Java 侧没有 deinit 可打，
        // 但「播放器存活」是否归零已足够判断有没有被真正放掉
        YULog.death("播放器", playerId,
                YULog.alive(createdAt) + " 触发=Dart 主动释放 vid=" + vid
                        + " 命中缓存=" + usingCache
                        + " 画面=" + (textureView != null ? "有" : "无"));

        main.removeCallbacksAndMessages(null);
        methods.setMethodCallHandler(null);
        events.setStreamHandler(null);
        sink = null;
        textureView = null;
        player.release();
        // 计数减一：还在播的其它 player 会把这条继续保在「活跃」里，不会被淘汰删掉。
        // 没 setSource 过时 vid 为空，压根没 acquire 过，不能减。
        if (!vid.isEmpty()) YUVideoCache.release(context, vid);

        // 「关掉之后到底回落到多少」：release() 之后解码器是异步回收的，采三个点看趋势。
        // Java 侧没有 deinit 可打，这条是判断内存有没有漏的唯一口径。
        // 必须用新的 Handler：上面 removeCallbacksAndMessages(null) 会把 main 上的消息清掉。
        final int id = playerId;
        final Handler sampler = new Handler(Looper.getMainLooper());
        final String[] labels = {"0.5s", "2.0s", "5.0s"};
        final long[] delays = {500L, 2000L, 5000L};
        for (int i = 0; i < delays.length; i++) {
            final String label = labels[i];
            sampler.postDelayed(() -> YULog.log("[内存] 播放器#" + id + " 释放后 "
                    + label + " 内存=" + YULog.mem()), delays[i]);
        }
    }

    // ---- 事件 ----

    private void sendReady() {
        readySent = true;
        Map<String, Object> map = new HashMap<>();
        long duration = player.getDuration();
        map.put("durationMs", duration == C.TIME_UNSET ? 0L : duration);
        Map<String, Object> size = sizePayload(player.getVideoSize());
        map.putAll(size);
        map.put("usingCache", usingCache);

        // 起播耗时 = 装配片源到首帧就绪，换源时基准会重置
        int width = size.get("width") instanceof Number ? ((Number) size.get("width")).intValue() : 0;
        int height = size.get("height") instanceof Number ? ((Number) size.get("height")).intValue() : 0;
        YULog.log("[就绪] 播放器#" + playerId + " vid=" + vid
                + " 时长=" + map.get("durationMs") + "ms"
                + " 分辨率=" + width + "x" + height
                + " 命中缓存=" + usingCache + " " + YULog.cost(sourceStartedAt));

        send("ready", map);
    }

    /**
     * 把 VideoSize 转成上报用的宽高。
     *
     * 旋转 90/270 的片源容器宽高是反的（竖屏视频常以横向编码 + rotation 元数据
     * 存在），此时需要交换。尺寸还没确定时返回空 map，让上层保留原值。
     */
    private static Map<String, Object> sizePayload(@NonNull VideoSize size) {
        Map<String, Object> map = new HashMap<>();
        if (size.width <= 0 || size.height <= 0) return map;
        boolean swap = size.unappliedRotationDegrees % 180 == 90;
        map.put("width", swap ? size.height : size.width);
        map.put("height", swap ? size.width : size.height);
        return map;
    }

    private void sendState() {
        if (released) return;
        Map<String, Object> map = new HashMap<>();
        map.put("isPlaying", player.isPlaying());
        map.put("isBuffering", player.getPlaybackState() == Player.STATE_BUFFERING);
        map.put("isCompleted", player.getPlaybackState() == Player.STATE_ENDED);
        send("state", map);
    }

    private void send(String type, @Nullable Map<String, Object> payload) {
        EventChannel.EventSink now = sink;
        if (now == null || released) return;
        Map<String, Object> map = new HashMap<>();
        map.put("type", type);
        if (payload != null) map.putAll(payload);
        now.success(map);
    }

    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            if (released) return;
            long position = player.getCurrentPosition();
            long buffered = player.getBufferedPosition();
            if (buffered == C.TIME_UNSET) buffered = 0L;
            // 采到的两个值都没动就不发：Dart 侧不会因此少任何信息，只是少收空包
            if (position != lastSentPositionMs || buffered != lastSentBufferedMs) {
                lastSentPositionMs = position;
                lastSentBufferedMs = buffered;
                Map<String, Object> map = new HashMap<>();
                map.put("positionMs", position);
                map.put("bufferedMs", buffered);
                send("position", map);
            }
            // 缓冲中也要继续，否则缓冲进度条会停住
            if (player.isPlaying() || player.getPlaybackState() == Player.STATE_BUFFERING) {
                main.postDelayed(this, TICK_MS);
            }
        }
    };

    private void tickPosition() {
        main.removeCallbacks(tick);
        main.postDelayed(tick, TICK_MS);
    }

    private static String asString(@Nullable Object value, String fallback) {
        return value instanceof String ? (String) value : fallback;
    }

    @Nullable
    private static Long asLong(@Nullable Object value) {
        return value instanceof Number ? ((Number) value).longValue() : null;
    }

    @Nullable
    private static Integer asInt(@Nullable Object value) {
        return value instanceof Number ? ((Number) value).intValue() : null;
    }

    @Nullable
    private static Double asDouble(@Nullable Object value) {
        return value instanceof Number ? ((Number) value).doubleValue() : null;
    }

    @Nullable
    private static Boolean asBoolean(@Nullable Object value) {
        return value instanceof Boolean ? (Boolean) value : null;
    }
}
