package org.revdog.retriever.flutter;

/**
 * owner 引擎（v3 §4）：进程级只登记首个 {@code bootstrap()} 的引擎；同一引擎（热重启后同一个插件实例）再次 bootstrap 仍是 owner；
 * 其余引擎回 owner=false（非 owner）。owner 只在它 detach（{@code onDetachedFromEngine}，先于 isolate 关闭，核实 round2 #2）时释放。
 */
final class OwnerRegistry {
    private EngineHandle owner;

    /** 空位或同一引擎 → owner。 */
    synchronized boolean claim(EngineHandle engine) {
        if (owner == null || owner == engine) {
            owner = engine;
            return true;
        }
        return false;
    }

    /** 本引擎是 owner 时清空；返回是否释放了。 */
    synchronized boolean release(EngineHandle engine) {
        if (owner != null && owner == engine) {
            owner = null;
            return true;
        }
        return false;
    }

    synchronized EngineHandle owner() {
        return owner;
    }
}
