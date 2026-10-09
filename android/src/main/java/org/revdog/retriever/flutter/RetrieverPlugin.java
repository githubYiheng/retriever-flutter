package org.revdog.retriever.flutter;

import android.app.Application;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import androidx.annotation.NonNull;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;

/**
 * Retriever 的 Android 垫片（v3 §3 契约；切片 2 简报 §2）。每个 Flutter 引擎一个实例（核实 round2 #6），都登记到进程级
 * {@link EngineRegistry}；owner 由首个 {@code bootstrap()} 的引擎担任，它 {@code onDetachedFromEngine} 时释放并向其余引擎广播
 * {@code ownerReleased}（v3 §4）。垫片不读不写日志文件、不碰 key（ADR 0003 决定 3 / ADR 0007 D5）。
 *
 * <p>MethodChannel {@code org.revdog.retriever}：Dart → 原生 {@code root} / {@code bootstrap} / {@code diagnose} /
 * {@code scheduleUploadJob} / {@code cancelUploadJob} / {@code endBackgroundTask} / {@code availableBytes}；原生 → Dart 走同一 channel
 * 的反向 invokeMethod（事件见 {@link EngineRegistry}、{@link RetrieverUploadJobService}）。参数一律以契约参数名为键的 Map。
 */
public final class RetrieverPlugin implements FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler, EngineHandle {
    static final String CHANNEL = "org.revdog.retriever";

    private static final ExecutorService IO = Executors.newSingleThreadExecutor(new ThreadFactory() {
        @Override
        public Thread newThread(Runnable r) {
            Thread t = new Thread(r, "retriever-shim-io");
            t.setDaemon(true);
            return t;
        }
    });

    private final Handler main = new Handler(Looper.getMainLooper());
    private MethodChannel channel;
    private Context app;

    /** 装进程级 tracker（只一次；provider 里 early = true，引擎 attach 时兜底 early = false、初值取进程重要性）。 */
    static void installTracker(Application application, boolean early) {
        LifecycleTracker t = LifecycleTracker.shared();
        t.setListener(EngineRegistry.shared());
        t.install(application, early, new LifecycleTracker.Initial() {
            @Override
            public Boolean get() {
                return PlatformInfo.importanceForeground();
            }
        });
    }

    // MARK: FlutterPlugin

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        app = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
        channel.setMethodCallHandler(this);
        EngineRegistry.shared().attach(this);
        try {
            if (app instanceof Application) installTracker((Application) app, false);
            NetworkWatcher.ensure(app);
        } catch (Throwable t) {
            // 绝不抛进引擎的插件注册
        }
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        MethodChannel c = channel;
        if (c != null) c.setMethodCallHandler(null);
        // 先注销再清 channel：owner 释放时广播只发给「其余」引擎
        EngineRegistry.shared().detach(this);
        channel = null;
    }

    // MARK: ActivityAware（只用来兜底注册 tracker：applicationContext 不是 Application 时用 Activity 的）

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        try {
            installTracker(binding.getActivity().getApplication(), false);
        } catch (Throwable t) {
            // 绝不抛给宿主
        }
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {}

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {}

    @Override
    public void onDetachedFromActivity() {}

    // MARK: EngineHandle（主线程）

    @Override
    public void send(String method, Object args) {
        MethodChannel c = channel;
        if (c != null) c.invokeMethod(method, args);
    }

    @Override
    public void call(String method, Object args, final Reply reply) {
        MethodChannel c = channel;
        if (c == null) {
            reply.failed();
            return;
        }
        c.invokeMethod(method, args, new MethodChannel.Result() {
            @Override
            public void success(Object result) {
                reply.done(result);
            }

            @Override
            public void error(@NonNull String code, String message, Object details) {
                reply.failed();
            }

            @Override
            public void notImplemented() {
                reply.failed();
            }
        });
    }

    // MARK: Dart → 原生

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        try {
            switch (call.method) {
                case "root":
                    result.success(rootReply());
                    return;
                case "bootstrap":
                    result.success(bootstrapReply());
                    return;
                case "diagnose": {
                    String code = call.argument("code");
                    String message = call.argument("message");
                    Diagnostics.shared().emit(code, message);
                    result.success(null);
                    return;
                }
                case "scheduleUploadJob":
                    result.success(jobs().schedule(intArg(call, "jobId")));
                    return;
                case "cancelUploadJob":
                    result.success(jobs().cancel(intArg(call, "jobId")));
                    return;
                case "endBackgroundTask":
                    // Android 没有后台任务 id：no-op
                    result.success(null);
                    return;
                case "availableBytes":
                    availableBytes(result);
                    return;
                default:
                    result.notImplemented();
            }
        } catch (Throwable t) {
            result.error("retriever_shim", t.getClass().getName() + ": " + t.getMessage(), null);
        }
    }

    private Map<String, Object> rootReply() {
        Map<String, Object> m = new HashMap<>();
        m.put("root", PlatformInfo.ensureRoot(app));
        m.put("token", PlatformInfo.TOKEN);
        m.put("process", PlatformInfo.processName(app));
        m.put("device", PlatformInfo.deviceFields(app));
        return m;
    }

    private Map<String, Object> bootstrapReply() {
        boolean owner = EngineRegistry.shared().claim(this);
        Map<String, Object> m = rootReply();
        m.put("owner", owner);
        Boolean fg = LifecycleTracker.shared().current();
        if (fg == null) fg = PlatformInfo.importanceForeground();
        m.put("foreground", fg);
        return m;
    }

    private JobGate jobs() {
        return new JobGate(new SystemJobApi(app), RetrieverUploadJobService.class.getName());
    }

    private static int intArg(MethodCall call, String key) {
        Object v = call.arguments instanceof Map ? call.argument(key) : call.arguments;
        if (v instanceof Number) return ((Number) v).intValue();
        throw new IllegalArgumentException(key + " missing");
    }

    /** {@code getAllocatableBytes} 是 {@code @WorkerThread}（核实 round2 #14）：后台线程取，回主线程回包。 */
    private void availableBytes(final MethodChannel.Result result) {
        final Context ctx = app;
        IO.execute(new Runnable() {
            @Override
            public void run() {
                Long v;
                try {
                    v = PlatformInfo.availableBytes(ctx);
                } catch (Throwable t) {
                    v = null;
                }
                final Long value = v;
                main.post(new Runnable() {
                    @Override
                    public void run() {
                        result.success(value);
                    }
                });
            }
        });
    }
}
