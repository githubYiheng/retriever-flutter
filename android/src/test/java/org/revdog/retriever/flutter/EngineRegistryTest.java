package org.revdog.retriever.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import org.junit.Test;

/** owner 选择 / 释放 / ownerReleased 广播与事件路由（切片 2 简报 §2「原生单测」；v3 §3 / §4）。 */
public class EngineRegistryTest {
    @Test
    public void firstBootstrapIsOwnerSameEngineStaysOwnerOthersAreNot() {
        OwnerRegistry r = new OwnerRegistry();
        FakeEngine a = new FakeEngine("a");
        FakeEngine b = new FakeEngine("b");
        assertTrue("空位 → owner", r.claim(a));
        assertTrue("同引擎（热重启）再次 bootstrap 仍是 owner", r.claim(a));
        assertFalse("别的引擎 → 非 owner", r.claim(b));
        assertSame(a, r.owner());
        assertFalse("非 owner 释放无效", r.release(b));
        assertSame(a, r.owner());
        assertTrue(r.release(a));
        assertNull(r.owner());
        assertTrue("释放后先到者成为 owner", r.claim(b));
    }

    @Test
    public void ownerDetachReleasesAndBroadcastsToRemainingEnginesOnly() {
        EngineRegistry reg = new EngineRegistry();
        FakeEngine main = new FakeEngine("main");
        FakeEngine bg = new FakeEngine("bg");
        FakeEngine late = new FakeEngine("late");
        reg.attach(main);
        reg.attach(bg);
        reg.attach(late);
        final List<EngineHandle> gone = new ArrayList<>();
        reg.setOwnerGone(new EngineRegistry.OwnerGone() {
            @Override
            public void ownerGone(EngineHandle owner) {
                gone.add(owner);
            }
        });
        assertTrue(reg.claim(bg));
        assertFalse(reg.claim(main));

        // 非 owner detach：不释放、不广播
        assertFalse(reg.detach(late));
        assertEquals(Collections.emptyList(), main.sent);
        assertEquals(Collections.emptyList(), bg.sent);
        assertSame(bg, reg.owner());

        // owner detach：释放；只向其余仍 attach 的引擎发 ownerReleased（自己不收）
        assertTrue(reg.detach(bg));
        assertNull(reg.owner());
        assertEquals(Collections.singletonList("ownerReleased"), main.sent);
        assertEquals(Collections.emptyList(), bg.sent);
        assertEquals(Collections.emptyList(), late.sent);
        assertEquals(Collections.<EngineHandle>singletonList(bg), gone);

        // 接任：收到 ownerReleased 的引擎重试 bootstrap → owner
        assertTrue(reg.claim(main));
        assertSame(main, reg.owner());
    }

    @Test
    public void broadcastSurvivesAThrowingEngine() {
        EngineRegistry reg = new EngineRegistry();
        FakeEngine owner = new FakeEngine("owner");
        FakeEngine broken = new FakeEngine("broken");
        FakeEngine ok = new FakeEngine("ok");
        broken.throwOnSend = true;
        reg.attach(owner);
        reg.attach(broken);
        reg.attach(ok);
        assertTrue(reg.claim(owner));
        reg.detach(owner);
        assertEquals(Collections.singletonList("ownerReleased"), ok.sent);
    }

    @Test
    public void backgroundGoesToOwnerOnlyForegroundIsBroadcast() {
        EngineRegistry reg = new EngineRegistry();
        FakeEngine a = new FakeEngine("a");
        FakeEngine b = new FakeEngine("b");
        reg.attach(a);
        reg.attach(b);

        // 还没有 owner：后台事件无处可投，前台照常广播
        reg.onBackground();
        reg.onForeground();
        assertEquals(Collections.singletonList("willEnterForeground"), a.sent);
        assertEquals(Collections.singletonList("willEnterForeground"), b.sent);

        assertTrue(reg.claim(b));
        reg.onBackground();
        reg.networkRestored();
        reg.onForeground();
        assertEquals(Arrays.asList("willEnterForeground", "willEnterForeground"), a.sent);
        assertEquals(Arrays.asList("willEnterForeground", "didEnterBackground", "networkRestored", "willEnterForeground"), b.sent);
        Map<?, ?> bgArgs = (Map<?, ?>) b.args.get(1);
        assertTrue("didEnterBackground 带 bgTaskId 键（Android 恒为 null）", bgArgs.containsKey("bgTaskId"));
        assertNull(bgArgs.get("bgTaskId"));
    }

    @Test
    public void trackerDrivesRegistry() {
        EngineRegistry reg = new EngineRegistry();
        FakeEngine owner = new FakeEngine("owner");
        FakeEngine other = new FakeEngine("other");
        reg.attach(owner);
        reg.attach(other);
        reg.claim(owner);
        LifecycleTracker t = new LifecycleTracker();
        t.setListener(reg);
        t.markInstalled(true, null);
        Object act = new Object();
        t.onStarted(act);
        t.onStopped(act, false);
        assertEquals(Arrays.asList("willEnterForeground", "didEnterBackground"), owner.sent);
        assertEquals(Collections.singletonList("willEnterForeground"), other.sent);
    }

    @Test
    public void jobRescheduleReplyParsing() {
        Map<String, Object> yes = new java.util.HashMap<>();
        yes.put("reschedule", true);
        Map<String, Object> no = new java.util.HashMap<>();
        no.put("reschedule", false);
        assertTrue(RetrieverUploadJobService.reschedule(yes));
        assertFalse(RetrieverUploadJobService.reschedule(no));
        assertFalse(RetrieverUploadJobService.reschedule(null));
        assertFalse(RetrieverUploadJobService.reschedule(true));
    }
}
