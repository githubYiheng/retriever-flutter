package org.revdog.retriever.flutter;

import java.util.ArrayList;
import java.util.List;

/** 假引擎：记下收到的反向调用（方法名 + 参数）。 */
final class FakeEngine implements EngineHandle {
    final String name;
    final List<String> sent = new ArrayList<>();
    final List<Object> args = new ArrayList<>();
    Reply pending;
    boolean throwOnSend;

    FakeEngine(String name) {
        this.name = name;
    }

    @Override
    public void send(String method, Object a) {
        if (throwOnSend) throw new IllegalStateException("detached");
        sent.add(method);
        args.add(a);
    }

    @Override
    public void call(String method, Object a, Reply reply) {
        sent.add(method);
        args.add(a);
        pending = reply;
    }

    @Override
    public String toString() {
        return name;
    }
}
