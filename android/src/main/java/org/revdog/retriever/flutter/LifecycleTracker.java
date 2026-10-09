package org.revdog.retriever.flutter;

import android.app.Activity;
import android.app.Application;
import android.os.Bundle;
import java.util.WeakHashMap;

/**
 * 进程级前后台 tracker（对位原生 SDK {@code android/Lifecycle.kt} 的 LifecycleTracker；v3 §1.4）：不依赖引擎、无 I/O、只装一次。
 * <ul>
 *   <li>按 Activity 身份集合计数：没见过 onStart 的 Activity 的 onStop 不参与（注册晚于某个 Activity 启动时，A → B 不误报后台）；
 *       配置变更（旋转）重建不算进后台；</li>
 *   <li>初值：{@code early}（init provider 里，Application.onCreate 之前）= 未知，按首个 onStart 定；
 *       否则（{@code onAttachedToEngine} 兜底）取进程重要性；</li>
 *   <li>状态变化交给 {@link Listener}（{@link EngineRegistry}：后台只投 owner，前台广播）。</li>
 * </ul>
 * 计数核心以 {@code Object} 为身份（单测不需要真 Activity）。
 */
final class LifecycleTracker {
    interface Listener {
        void onForeground();

        void onBackground();
    }

    /** 晚注册时的初值（进程重要性；null = 读不到）。 */
    interface Initial {
        Boolean get();
    }

    private static final LifecycleTracker SHARED = new LifecycleTracker();

    static LifecycleTracker shared() {
        return SHARED;
    }

    private final Object lock = new Object();
    private boolean installed;
    private final WeakHashMap<Object, Boolean> started = new WeakHashMap<>();
    private int changing;
    private Boolean foreground;
    private volatile Listener listener;

    LifecycleTracker() {}

    void setListener(Listener l) {
        listener = l;
    }

    /** 注册生命周期回调（进程级只一次）；返回这次是否真的注册了。 */
    boolean install(Application app, boolean early, Initial initial) {
        if (!markInstalled(early, initial)) return false;
        app.registerActivityLifecycleCallbacks(callbacks);
        return true;
    }

    /** 只置「已装」与初值（install 的状态部分；单测直接用）。 */
    boolean markInstalled(boolean early, Initial initial) {
        synchronized (lock) {
            if (installed) return false;
            installed = true;
            Boolean init = null;
            if (!early && initial != null) {
                try {
                    init = initial.get();
                } catch (RuntimeException e) {
                    init = null;
                }
            }
            foreground = init;
            return true;
        }
    }

    boolean isInstalled() {
        synchronized (lock) {
            return installed;
        }
    }

    /** 当前前后台（null = 没装 / 还不知道）。 */
    Boolean current() {
        synchronized (lock) {
            return installed ? foreground : null;
        }
    }

    void onStarted(Object activity) {
        final boolean fire;
        synchronized (lock) {
            if (started.containsKey(activity)) return;
            started.put(activity, Boolean.TRUE);
            if (changing > 0) {
                changing -= 1;
                fire = false;
            } else if (!Boolean.TRUE.equals(foreground)) {
                foreground = Boolean.TRUE;
                fire = true;
            } else {
                fire = false;
            }
        }
        if (fire) post(true);
    }

    void onStopped(Object activity, boolean changingConfigurations) {
        final boolean fire;
        synchronized (lock) {
            // 没见过它的 onStart（注册之前就启动了）：不参与计数
            if (started.remove(activity) == null) return;
            if (changingConfigurations) {
                // 旋转等配置变更：马上会重建并 onStart，不算进后台
                changing += 1;
                fire = false;
            } else if (started.isEmpty() && !Boolean.FALSE.equals(foreground)) {
                foreground = Boolean.FALSE;
                fire = true;
            } else {
                fire = false;
            }
        }
        if (fire) post(false);
    }

    private void post(boolean fg) {
        Listener l = listener;
        if (l == null) return;
        try {
            if (fg) l.onForeground();
            else l.onBackground();
        } catch (RuntimeException e) {
            // 绝不抛进宿主的生命周期回调
        }
    }

    private final Application.ActivityLifecycleCallbacks callbacks = new Application.ActivityLifecycleCallbacks() {
        // 宿主 Activity 覆写的 hashCode / isChangingConfigurations 抛异常也不进宿主的生命周期回调
        @Override
        public void onActivityStarted(Activity activity) {
            try {
                onStarted(activity);
            } catch (Throwable t) {
                // 绝不抛给宿主
            }
        }

        @Override
        public void onActivityStopped(Activity activity) {
            try {
                onStopped(activity, activity.isChangingConfigurations());
            } catch (Throwable t) {
                // 绝不抛给宿主
            }
        }

        @Override
        public void onActivityCreated(Activity activity, Bundle savedInstanceState) {}

        @Override
        public void onActivityResumed(Activity activity) {}

        @Override
        public void onActivityPaused(Activity activity) {}

        @Override
        public void onActivitySaveInstanceState(Activity activity, Bundle outState) {}

        @Override
        public void onActivityDestroyed(Activity activity) {}
    };
}
