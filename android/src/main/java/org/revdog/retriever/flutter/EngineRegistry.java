package org.revdog.retriever.flutter;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;

/**
 * 进程级引擎登记（v3 §3 / §4）：本进程里所有 attach 着的引擎 + owner。事件投递规则（切片 1 审计裁决）：
 * {@code willEnterForeground} 与 {@code ownerReleased} 广播给所有引擎（非 owner 靠它们重试 bootstrap），
 * 其余（{@code didEnterBackground} / {@code networkRestored} / 作业回调）只投给 owner。所有投递都在主线程。
 */
final class EngineRegistry implements LifecycleTracker.Listener {
    /** owner detach 时的钩子（作业服务：owner 负责的在跑作业不会再回包，按重排结束）。 */
    interface OwnerGone {
        void ownerGone(EngineHandle owner);
    }

    private static final EngineRegistry SHARED = new EngineRegistry();

    static EngineRegistry shared() {
        return SHARED;
    }

    private final Object lock = new Object();
    private final LinkedHashSet<EngineHandle> engines = new LinkedHashSet<>();
    private final OwnerRegistry owners = new OwnerRegistry();
    private volatile OwnerGone ownerGone;

    void setOwnerGone(OwnerGone hook) {
        ownerGone = hook;
    }

    void attach(EngineHandle engine) {
        synchronized (lock) {
            engines.add(engine);
        }
    }

    /**
     * 注销；本引擎是 owner → 释放，并向其余仍 attach 的引擎发 {@code ownerReleased()}。返回是否释放了 owner。
     */
    boolean detach(EngineHandle engine) {
        final boolean released;
        final List<EngineHandle> others;
        synchronized (lock) {
            engines.remove(engine);
            released = owners.release(engine);
            others = new ArrayList<>(engines);
        }
        if (released) {
            OwnerGone hook = ownerGone;
            if (hook != null) {
                try {
                    hook.ownerGone(engine);
                } catch (RuntimeException e) {
                    // 绝不抛进引擎销毁流程
                }
            }
            for (EngineHandle e : others) safeSend(e, "ownerReleased", null);
        }
        return released;
    }

    boolean claim(EngineHandle engine) {
        return owners.claim(engine);
    }

    EngineHandle owner() {
        return owners.owner();
    }

    List<EngineHandle> attached() {
        synchronized (lock) {
            return new ArrayList<>(engines);
        }
    }

    /** 进后台（Android 没有后台任务 id）：只投给 owner。 */
    @Override
    public void onBackground() {
        EngineHandle o = owner();
        if (o == null) return;
        Map<String, Object> args = new HashMap<>();
        args.put("bgTaskId", null);
        safeSend(o, "didEnterBackground", args);
    }

    /** 回前台：广播给所有引擎（非 owner 靠它重试 bootstrap）。 */
    @Override
    public void onForeground() {
        for (EngineHandle e : attached()) safeSend(e, "willEnterForeground", null);
    }

    /** 网络恢复（只用于提前唤醒）：只投给 owner。 */
    void networkRestored() {
        EngineHandle o = owner();
        if (o != null) safeSend(o, "networkRestored", null);
    }

    static void safeSend(EngineHandle e, String method, Object args) {
        try {
            e.send(method, args);
        } catch (RuntimeException ex) {
            // 引擎已 detach / channel 异常：丢掉这条事件
        }
    }
}
