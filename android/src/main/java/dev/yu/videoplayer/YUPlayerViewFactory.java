package dev.yu.videoplayer;

import dev.yu.videoplayer.core.*;

import android.content.Context;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import io.flutter.plugin.common.StandardMessageCodec;
import io.flutter.plugin.platform.PlatformView;
import io.flutter.plugin.platform.PlatformViewFactory;

/**
 * 注册名为 {@code yu_player_view} 的 PlatformView。
 *
 * 只负责建画面层，不碰播放器：播放器由控制器通过 {@code createPlayer} 建，
 * 这里拿到的是 creationParams 里的 {@code playerId}。
 */
public final class YUPlayerViewFactory extends PlatformViewFactory {

    public YUPlayerViewFactory() {
        super(StandardMessageCodec.INSTANCE);
    }

    @NonNull
    @Override
    public PlatformView create(@NonNull Context context, int viewId, @Nullable Object args) {
        return new YUPlayerView(context, viewId, args);
    }
}
