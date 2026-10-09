package org.revdog.retriever.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import org.junit.Test;

/** 作业认归属（对位原生 SDK {@code HardeningTests.t_jobOwnership} 的 JobGate 部分）。 */
public class JobGateTest {
    static final String OURS = RetrieverUploadJobService.class.getName();

    static final class FakeJobs implements JobApi {
        String pending;
        boolean persistThrows;
        boolean rejectAll;
        final List<Boolean> scheduled = new ArrayList<>();
        final List<Integer> cancelled = new ArrayList<>();

        FakeJobs(String pending) {
            this.pending = pending;
        }

        @Override
        public String pendingService(int id) {
            return pending;
        }

        @Override
        public boolean schedule(int id, boolean persisted) {
            if (persisted && persistThrows) throw new IllegalArgumentException("RECEIVE_BOOT_COMPLETED missing");
            if (rejectAll) return false;
            scheduled.add(persisted);
            pending = OURS;
            return true;
        }

        @Override
        public void cancel(int id) {
            cancelled.add(id);
            pending = null;
        }
    }

    @Test
    public void hostJobWithSameIdIsNeverTouched() {
        FakeJobs host = new FakeJobs("com.host.SyncJobService");
        JobGate g = new JobGate(host, OURS);
        assertFalse("同 id 是宿主的作业：不替换、回 false", g.schedule(0x5254));
        assertFalse("不取消宿主的作业", g.cancel(0x5254));
        assertEquals(Collections.emptyList(), host.scheduled);
        assertEquals(Collections.emptyList(), host.cancelled);
    }

    @Test
    public void ownJobAlreadyPendingIsNotRescheduledAndCanBeCancelled() {
        FakeJobs mine = new FakeJobs(OURS);
        JobGate g = new JobGate(mine, OURS);
        assertTrue("自己的作业已排：不重排", g.schedule(1));
        assertEquals(Collections.emptyList(), mine.scheduled);
        assertTrue(g.cancel(1));
        assertEquals(Collections.singletonList(1), mine.cancelled);
        assertFalse("没有作业时 cancel 不调系统", g.cancel(1));
        assertEquals(Collections.singletonList(1), mine.cancelled);
    }

    @Test
    public void persistedFirstFallsBackToNonPersisted() {
        FakeJobs none = new FakeJobs(null);
        assertTrue(new JobGate(none, OURS).schedule(2));
        assertEquals("先排持久作业", Collections.singletonList(true), none.scheduled);

        FakeJobs noBoot = new FakeJobs(null);
        noBoot.persistThrows = true;
        assertTrue(new JobGate(noBoot, OURS).schedule(2));
        assertEquals("setPersisted 抛异常 → 退回非持久", Collections.singletonList(false), noBoot.scheduled);

        FakeJobs rejected = new FakeJobs(null);
        rejected.rejectAll = true;
        assertFalse("系统拒绝 → 回 false", new JobGate(rejected, OURS).schedule(2));
    }

    @Test
    public void nativeSdkJobServiceIsAlsoForeign() {
        // 与原生 SDK 混用（README 禁止）时，原生 SDK 的同号作业也不碰
        FakeJobs nativeSdk = new FakeJobs("org.revdog.retriever.RetrieverUploadJobService");
        JobGate g = new JobGate(nativeSdk, OURS);
        assertFalse(g.schedule(0x5254));
        assertFalse(g.cancel(0x5254));
        assertEquals(Collections.emptyList(), nativeSdk.cancelled);
    }
}
