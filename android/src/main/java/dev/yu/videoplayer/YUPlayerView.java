package dev.yu.videoplayer;

import dev.yu.videoplayer.core.*;

import android.content.Context;
import android.view.TextureView;
import android.view.View;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.Map;

import io.flutter.plugin.platform.PlatformView;

/**
 * 画面层。**只管显示**，不持有播放器。
 *
 * 原生播放器在 {@link YUPlayerInstance} 里，由 Dart 控制器通过
 * {@code createPlayer} 单独创建。这个 view 的唯一职责是把某个播放器的画面
 * 接到自己的 {@link TextureView} 上；解挂之后播放器继续出声。
 *
 * 两边创建顺序任意：view 先建就等播放器 attach，播放器先建就由它在
 * {@code attachView} 里回头找这个 view。
 */
public final class YUPlayerView implements PlatformView {

    private final TextureView textureView;
    private final int viewId;
    private final int playerId;
    private final int logId = YULog.nextId();
    private final long createdAt = System.currentTimeMillis();
    private boolean disposed;

    YUPlayerView(@NonNull Context context, int viewId, @Nullable Object args) {
        this.viewId = viewId;
        this.playerId = readPlayerId(args);
        textureView = new TextureView(context);

        // 先登记再挂载：播放器的 attachView 靠 viewId 在这张表里找画面层
        synchronized (YUPlayerInstance.class) {
            YUPlayerInstance.views.put(viewId, this);
        }
        YULog.birth("视图", logId, "viewId=" + viewId + " playerId=" + playerId);

        if (playerId <= 0) {
            YULog.log("[连接] 视图#" + viewId + " 先建好，等播放器 attach");
            return;
        }
        final YUPlayerInstance instance = YUPlayerInstance.find(playerId);
        if (instance == null) {
            YULog.log("[连接] 视图#" + viewId + " 找不到播放器#" + playerId + "，等它上来");
            return;
        }
        instance.attachTexture(textureView, viewId);
    }

    @NonNull
    TextureView textureView() {
        return textureView;
    }

    @Override
    public View getView() {
        return textureView;
    }

    @Override
    public void dispose() {
        if (disposed) return;
        disposed = true;
        synchronized (YUPlayerInstance.class) {
            YUPlayerInstance.views.remove(viewId);
        }
        // 只摘画面，不碰播放器：声音继续
        if (playerId > 0) {
            final YUPlayerInstance instance = YUPlayerInstance.find(playerId);
            if (instance != null) instance.detachTexture(textureView);
        }
        YULog.death("视图", logId,
                YULog.alive(createdAt) + " 触发=Flutter 回收 playerId=" + playerId);
    }

    private static int readPlayerId(@Nullable Object args) {
        if (args instanceof Map) {
            final Object value = ((Map<?, ?>) args).get("playerId");
            if (value instanceof Number) return ((Number) value).intValue();
        }
        return 0;
    }
}
