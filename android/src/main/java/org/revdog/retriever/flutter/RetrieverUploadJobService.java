package org.revdog.retriever.flutter;

import android.app.job.JobParameters;
import android.app.job.JobService;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * 后台兜底上传（方案 §3.9；ADR 0003 决定 13；ADR 0007 D1）：系统拉起作业时，若进程里有 owner 引擎（它 bootstrap 过 = 宿主 configure 过）
 * → 在主线程 {@code invokeMethod("drainOutbox", {budgetMs})}，用 Dart 回包的 {@code reschedule} 调 {@code jobFinished}；
 * 没有 owner（没 configure / 进程刚被作业拉起、没有引擎）→ {@code onStartJob} 直接 {@code return false}（不跑 headless Dart）。
 * {@code onStopJob} → owner 的 {@code stopUploadJob()}，返回 true（系统按退避重排）。owner 在作业进行中 detach → 按重排结束。
 */
public final class RetrieverUploadJobService extends JobService {
    /** 同原生 SDK {@code RetrieverClient.JOB_BUDGET_MS}。 */
    static final int JOB_BUDGET_MS = 120_000;

    /** 主线程上的在跑作业。 */
    private static final List<Running> RUNNING = new ArrayList<>();

    static {
        EngineRegistry.shared().setOwnerGone(new EngineRegistry.OwnerGone() {
            @Override
            public void ownerGone(EngineHandle owner) {
                for (Running r : new ArrayList<>(RUNNING)) {
                    if (r.owner == owner) r.finish(true);
                }
            }
        });
    }

    private static final class Running {
        final JobService service;
        final JobParameters params;
        final EngineHandle owner;
        boolean done;

        Running(JobService service, JobParameters params, EngineHandle owner) {
            this.service = service;
            this.params = params;
            this.owner = owner;
        }

        void finish(boolean reschedule) {
            if (done) return;
            done = true;
            RUNNING.remove(this);
            try {
                service.jobFinished(params, reschedule);
            } catch (RuntimeException e) {
                // 作业已被系统回收
            }
        }
    }

    @Override
    public boolean onStartJob(JobParameters params) {
        final EngineHandle owner;
        try {
            owner = EngineRegistry.shared().owner();
        } catch (Throwable t) {
            return false;
        }
        if (owner == null) return false;
        final Running r = new Running(this, params, owner);
        RUNNING.add(r);
        Map<String, Object> args = new HashMap<>();
        args.put("budgetMs", JOB_BUDGET_MS);
        try {
            owner.call("drainOutbox", args, new EngineHandle.Reply() {
                @Override
                public void done(Object result) {
                    r.finish(reschedule(result));
                }

                @Override
                public void failed() {
                    r.finish(false);
                }
            });
        } catch (RuntimeException e) {
            r.finish(false);
        }
        return true;
    }

    @Override
    public boolean onStopJob(JobParameters params) {
        try {
            for (Running r : new ArrayList<>(RUNNING)) {
                if (r.params == params || r.params.getJobId() == params.getJobId()) {
                    r.done = true;
                    RUNNING.remove(r);
                    EngineRegistry.safeSend(r.owner, "stopUploadJob", null);
                }
            }
        } catch (Throwable t) {
            // 绝不抛给系统回调
        }
        return true;
    }

    static boolean reschedule(Object result) {
        if (result instanceof Map) return Boolean.TRUE.equals(((Map<?, ?>) result).get("reschedule"));
        return false;
    }
}
