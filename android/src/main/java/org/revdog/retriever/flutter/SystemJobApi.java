package org.revdog.retriever.flutter;

import android.app.job.JobInfo;
import android.app.job.JobScheduler;
import android.content.ComponentName;
import android.content.Context;
import android.os.Build;
import java.util.List;

/** 框架 JobScheduler（ADR 0003 决定 13：不引 WorkManager）。一次性、NETWORK_TYPE_ANY；API ≥ 24 用 getPendingJob，之前退回过滤全表。 */
final class SystemJobApi implements JobApi {
    private final Context app;

    SystemJobApi(Context app) {
        this.app = app;
    }

    private JobScheduler scheduler() {
        return (JobScheduler) app.getSystemService(Context.JOB_SCHEDULER_SERVICE);
    }

    @Override
    public String pendingService(int id) {
        JobScheduler js = scheduler();
        if (js == null) return null;
        JobInfo info = null;
        if (Build.VERSION.SDK_INT >= 24) {
            info = js.getPendingJob(id);
        } else {
            List<JobInfo> all = js.getAllPendingJobs();
            if (all != null) {
                for (JobInfo j : all) {
                    if (j != null && j.getId() == id) {
                        info = j;
                        break;
                    }
                }
            }
        }
        if (info == null) return null;
        ComponentName c = info.getService();
        return c == null ? "" : c.getClassName();
    }

    @Override
    public boolean schedule(int id, boolean persisted) {
        JobScheduler js = scheduler();
        if (js == null) return false;
        JobInfo.Builder b = new JobInfo.Builder(id, new ComponentName(app, RetrieverUploadJobService.class))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY);
        if (persisted) b.setPersisted(true);
        return js.schedule(b.build()) == JobScheduler.RESULT_SUCCESS;
    }

    @Override
    public void cancel(int id) {
        JobScheduler js = scheduler();
        if (js != null) js.cancel(id);
    }
}
