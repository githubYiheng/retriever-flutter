package org.revdog.retriever.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import android.app.Activity;
import android.app.Application;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import org.junit.Test;

/** 进程级 tracker（对位原生 SDK {@code HardeningTests.t_lifecycleTracker}；切片 2 简报 §2）。 */
public class LifecycleTrackerTest {
    static final class Events implements LifecycleTracker.Listener {
        final List<String> seen = new ArrayList<>();

        @Override
        public void onForeground() {
            seen.add("fg");
        }

        @Override
        public void onBackground() {
            seen.add("bg");
        }
    }

    @Test
    public void earlyInstallIsUnknownUntilFirstStart() {
        LifecycleTracker t = new LifecycleTracker();
        Events ev = new Events();
        t.setListener(ev);
        assertNull("没装 = null", t.current());
        assertTrue(t.install(new Application(), true, new LifecycleTracker.Initial() {
            @Override
            public Boolean get() {
                throw new AssertionError("early 不读进程重要性");
            }
        }));
        assertNull("early：未知，按首个 onStart 定", t.current());
        Activity a = new Activity();
        t.onStarted(a);
        assertEquals(Boolean.TRUE, t.current());
        assertEquals(Collections.singletonList("fg"), ev.seen);
    }

    @Test
    public void installsOnlyOnce() {
        LifecycleTracker t = new LifecycleTracker();
        assertTrue(t.install(new Application(), true, null));
        assertFalse("进程级只装一次（兜底 install 不覆盖 early 的初值）", t.install(new Application(), false, new LifecycleTracker.Initial() {
            @Override
            public Boolean get() {
                return Boolean.TRUE;
            }
        }));
        assertNull(t.current());
    }

    @Test
    public void switchingActivitiesDoesNotReportBackground() {
        LifecycleTracker t = new LifecycleTracker();
        Events ev = new Events();
        t.setListener(ev);
        t.markInstalled(true, null);
        Object a = new Object();
        Object b = new Object();
        t.onStarted(a);
        t.onStarted(b);
        t.onStopped(a, false);
        assertEquals("A → B 不误报后台", Collections.singletonList("fg"), ev.seen);
        t.onStopped(b, false);
        assertEquals(Arrays.asList("fg", "bg"), ev.seen);
        assertEquals(Boolean.FALSE, t.current());
        t.onStarted(a);
        assertEquals(Arrays.asList("fg", "bg", "fg"), ev.seen);
    }

    @Test
    public void stopOfUnseenActivityIsIgnored() {
        // 注册晚于某个 Activity 的 onStart（provider 被移除）：那个 Activity 的 onStop 不参与计数
        LifecycleTracker late = new LifecycleTracker();
        Events ev = new Events();
        late.setListener(ev);
        late.markInstalled(false, new LifecycleTracker.Initial() {
            @Override
            public Boolean get() {
                return Boolean.TRUE;
            }
        });
        Object c = new Object();
        Object d = new Object();
        late.onStarted(d);
        late.onStopped(c, false);
        assertEquals("初值取进程重要性 = 前台：onStart 不再报", Collections.<String>emptyList(), ev.seen);
        assertEquals(Boolean.TRUE, late.current());
        late.onStopped(d, false);
        assertEquals(Collections.singletonList("bg"), ev.seen);
    }

    @Test
    public void configurationChangeIsNotBackground() {
        LifecycleTracker t = new LifecycleTracker();
        Events ev = new Events();
        t.setListener(ev);
        t.markInstalled(true, null);
        Object a1 = new Object();
        Object a2 = new Object();
        t.onStarted(a1);
        t.onStopped(a1, true);
        t.onStarted(a2);
        assertEquals("旋转重建不算进后台", Collections.singletonList("fg"), ev.seen);
        assertEquals(Boolean.TRUE, t.current());
    }

    @Test
    public void lateInstallInitialFromImportance() {
        LifecycleTracker bgProc = new LifecycleTracker();
        bgProc.markInstalled(false, new LifecycleTracker.Initial() {
            @Override
            public Boolean get() {
                return PlatformInfo.importanceIsForeground(400); // 作业 / 广播冷启动（CACHED）
            }
        });
        assertEquals(Boolean.FALSE, bgProc.current());
        LifecycleTracker fgProc = new LifecycleTracker();
        fgProc.markInstalled(false, new LifecycleTracker.Initial() {
            @Override
            public Boolean get() {
                return PlatformInfo.importanceIsForeground(100); // 用户冷启动
            }
        });
        assertEquals(Boolean.TRUE, fgProc.current());
        LifecycleTracker unknown = new LifecycleTracker();
        unknown.markInstalled(false, new LifecycleTracker.Initial() {
            @Override
            public Boolean get() {
                throw new SecurityException("boom");
            }
        });
        assertNull("读不到重要性 = 未知", unknown.current());
    }

    @Test
    public void importanceMappingMatchesNativeSdk() {
        assertTrue(PlatformInfo.importanceIsForeground(100));
        assertTrue("VISIBLE 算前台（同原生 SDK）", PlatformInfo.importanceIsForeground(200));
        assertFalse("前台服务（后台播放）不算前台（同原生 SDK）", PlatformInfo.importanceIsForeground(125));
        assertFalse(PlatformInfo.importanceIsForeground(150));
        assertFalse(PlatformInfo.importanceIsForeground(230));
        assertFalse(PlatformInfo.importanceIsForeground(300));
        assertFalse(PlatformInfo.importanceIsForeground(400));
    }

    @Test
    public void listenerThrowingNeverEscapes() {
        LifecycleTracker t = new LifecycleTracker();
        t.setListener(new LifecycleTracker.Listener() {
            @Override
            public void onForeground() {
                throw new IllegalStateException("x");
            }

            @Override
            public void onBackground() {
                throw new IllegalStateException("y");
            }
        });
        t.markInstalled(true, null);
        Object a = new Object();
        t.onStarted(a);
        t.onStopped(a, false);
        assertEquals(Boolean.FALSE, t.current());
    }
}
