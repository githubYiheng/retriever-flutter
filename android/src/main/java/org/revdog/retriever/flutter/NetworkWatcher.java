package org.revdog.retriever.flutter;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

/**
 * 网络恢复（v3 §3 {@code networkRestored}，只用于提前唤醒，不做可达性预检）：API ≥ 24 {@code registerDefaultNetworkCallback}，
 * 进程级只注册一次；从「没网」到 {@code onAvailable} 才投给 owner（主线程）。API < 24 不注册（v2 C4）。
 */
final class NetworkWatcher {
    private NetworkWatcher() {}

    private static final Object LOCK = new Object();
    private static boolean registered;
    private static Boolean hadNetwork;

    static void ensure(Context app) {
        if (Build.VERSION.SDK_INT < 24) return;
        synchronized (LOCK) {
            if (registered) return;
            registered = true;
        }
        try {
            final ConnectivityManager cm = (ConnectivityManager) app.getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm == null) return;
            final Handler main = new Handler(Looper.getMainLooper());
            synchronized (LOCK) {
                hadNetwork = cm.getActiveNetwork() != null;
            }
            cm.registerDefaultNetworkCallback(new ConnectivityManager.NetworkCallback() {
                @Override
                public void onAvailable(Network network) {
                    final boolean fire;
                    synchronized (LOCK) {
                        fire = Boolean.FALSE.equals(hadNetwork);
                        hadNetwork = Boolean.TRUE;
                    }
                    if (fire) {
                        main.post(new Runnable() {
                            @Override
                            public void run() {
                                EngineRegistry.shared().networkRestored();
                            }
                        });
                    }
                }

                @Override
                public void onLost(Network network) {
                    synchronized (LOCK) {
                        hadNetwork = Boolean.FALSE;
                    }
                }
            });
        } catch (RuntimeException e) {
            // 宿主移除了 ACCESS_NETWORK_STATE / 系统异常：只少了「提前唤醒」
        }
    }
}
