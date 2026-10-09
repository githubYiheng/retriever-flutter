package org.revdog.retriever.flutter;

import android.util.Log;
import java.util.HashSet;
import java.util.Set;

/**
 * 配置诊断的系统日志出口（ADR 0025；v3 §1 §13）：与原生 SDK 同款——logcat tag {@code Retriever}，{@code no_key} 用 {@code Log.i}，
 * 其余（含 Flutter 专有的 {@code configure_ignored}）用 {@code Log.w}。进程级按 (code, message) 去重（Dart 侧只在 isolate 内去重，
 * 多引擎 / 热重启之后这里兜最终去重）。出口抛任何东西都吞掉。
 */
final class Diagnostics {
    static final String TAG = "Retriever";
    static final String NO_KEY = "no_key";

    interface Sink {
        void log(boolean info, String message);
    }

    private static final Diagnostics SHARED = new Diagnostics(new Sink() {
        @Override
        public void log(boolean info, String message) {
            if (info) Log.i(TAG, message);
            else Log.w(TAG, message);
        }
    });

    static Diagnostics shared() {
        return SHARED;
    }

    private final Set<String> seen = new HashSet<>();
    private final Sink sink;

    Diagnostics(Sink sink) {
        this.sink = sink;
    }

    /** 返回这次是否真的出了（去重后）。 */
    boolean emit(String code, String message) {
        if (code == null || message == null) return false;
        synchronized (seen) {
            if (!seen.add(code + '\u0000' + message)) return false;
        }
        try {
            sink.log(NO_KEY.equals(code), message);
        } catch (RuntimeException e) {
            // 出口失败：吞掉
        }
        return true;
    }
}
