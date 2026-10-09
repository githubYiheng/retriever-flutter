package org.revdog.retriever.flutter;

/** JobScheduler 的最小面（{@link JobGate} 用；{@link SystemJobApi} 给真实现，单测给假实现）。 */
interface JobApi {
    /** 同 id 排着（或在跑）的作业的 service 类名；没有作业 = null。 */
    String pendingService(int id);

    /** 排作业（{@code persisted} = 开机后保留）；系统拒绝抛异常或返回 false。 */
    boolean schedule(int id, boolean persisted);

    void cancel(int id);
}
