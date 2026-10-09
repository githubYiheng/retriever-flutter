package org.revdog.retriever.flutter;

/**
 * 后台作业认归属（对位原生 SDK {@code JobGate}；ADR 0024 决定 11）：只有 {@code getPendingJob(id)?.service} 是本插件的
 * {@link RetrieverUploadJobService} 时才视为「已排」或才 cancel；不是自己的同号作业一律不碰（不替换、不取消，返回 false，
 * 由 Dart 侧记一次诊断）。{@code setPersisted(true)} 因缺 {@code RECEIVE_BOOT_COMPLETED} 抛异常时退回非持久作业。
 */
final class JobGate {
    private final JobApi api;
    private final String ours;

    JobGate(JobApi api, String ours) {
        this.api = api;
        this.ours = ours;
    }

    /** 是否排上（已排着自己的同号作业也算）。 */
    boolean schedule(int id) {
        String pending = api.pendingService(id);
        if (pending != null) return pending.equals(ours);
        Boolean persisted;
        try {
            persisted = api.schedule(id, true);
        } catch (RuntimeException e) {
            persisted = null;
        }
        if (Boolean.TRUE.equals(persisted)) return true;
        try {
            return api.schedule(id, false);
        } catch (RuntimeException e) {
            return false;
        }
    }

    /** 是否取消了（只取消自己的同号作业）。 */
    boolean cancel(int id) {
        if (ours.equals(api.pendingService(id))) {
            api.cancel(id);
            return true;
        }
        return false;
    }
}
