package org.revdog.retriever.flutter;

/**
 * 一个已 attach 的 Flutter 引擎（每引擎一个插件实例，核实 refresh §6 / round2 #6）在进程级登记里的面：
 * 原生 → Dart 的反向 invokeMethod。只在主线程上调。登记与 owner 逻辑只看身份，单测用假实现。
 */
interface EngineHandle {
    /** 反向调用，不要回包（事件）。 */
    void send(String method, Object args);

    /** 反向调用，要回包（`drainOutbox`）。对端不认识 / 出错 / 引擎已 detach 都走 {@link Reply#failed()}。 */
    void call(String method, Object args, Reply reply);

    interface Reply {
        void done(Object result);

        void failed();
    }
}
