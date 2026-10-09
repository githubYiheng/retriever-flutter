package org.revdog.retriever.revdog_retriever_example;

import android.app.Activity;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.util.Log;
import io.flutter.FlutterInjector;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.dart.DartExecutor;
import io.flutter.plugin.common.MethodChannel;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

/**
 * 示例自己的原生通道 {@code org.revdog.retriever.example}（不进生产垫片）：启动参数、第二引擎（后到 / 后台先）、finish 主 Activity
 * （销毁重建）。只在主线程上用。
 */
final class ExampleChannel {
    static final String TAG = "RTVEX";
    static final String CHANNEL = "org.revdog.retriever.example";

    private ExampleChannel() {}

    static volatile boolean bgFirstPending;
    private static String launchScenario;
    private static Activity mainActivity;
    private static FlutterEngine secondEngine;
    private static Map<String, Object> secondReport;
    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    static void noteLaunch(Activity activity, String scenario) {
        mainActivity = activity;
        launchScenario = bgFirstPending ? "second_engine_bg_first" : scenario;
        bgFirstPending = false;
        Log.i(TAG, "activity onCreate pid=" + Process.myPid() + " scenario=" + launchScenario);
    }

    static void installMain(FlutterEngine engine, final Activity activity) {
        mainActivity = activity;
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), CHANNEL).setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "launchScenario": {
                    String s = launchScenario;
                    launchScenario = null;
                    result.success(s);
                    return;
                }
                case "startSecondEngine":
                    startSecondEngine(activity.getApplicationContext());
                    result.success(null);
                    return;
                case "destroySecondEngine":
                    destroySecondEngine();
                    result.success(null);
                    return;
                case "secondEngineStatus":
                    result.success(secondReport);
                    return;
                case "rebuildMainEngine":
                    // 销毁重建：finish 主 Activity → FlutterActivity 自建的引擎随之 destroy（onDetachedFromEngine 释放 owner），进程仍活；
                    // 由验收脚本 `am start` 重新拉起（新引擎）
                    result.success(null);
                    MAIN.postDelayed(() -> {
                        Log.i(TAG, "finishing main activity pid=" + Process.myPid());
                        activity.finish();
                    }, 100);
                    return;
                case "sigkill":
                    Log.i(TAG, "sigkill pid=" + Process.myPid());
                    Process.sendSignal(Process.myPid(), Process.SIGNAL_KILL);
                    result.success(null);
                    return;
                case "armAtLaunch": {
                    String s = call.argument("scenario");
                    if ("second_engine_bg_first".equals(s)) {
                        armBgFirstAndExit(activity);
                        result.success(true);
                    } else {
                        result.success(false);
                    }
                    return;
                }
                default:
                    result.notImplemented();
            }
        });
    }

    static void startSecondEngine(Context ctx) {
        if (secondEngine != null) return;
        secondReport = null;
        // 默认自动注册全部插件（含 Retriever 垫片）：与 firebase_messaging / audio_service 建后台引擎的方式相同
        FlutterEngine e = new FlutterEngine(ctx.getApplicationContext());
        new MethodChannel(e.getDartExecutor().getBinaryMessenger(), CHANNEL).setMethodCallHandler((call, result) -> {
            if ("secondEngineReport".equals(call.method)) {
                Object a = call.arguments;
                Map<String, Object> m = new HashMap<>();
                if (a instanceof Map) {
                    for (Map.Entry<?, ?> en : ((Map<?, ?>) a).entrySet()) m.put(String.valueOf(en.getKey()), en.getValue());
                }
                secondReport = m;
                Log.i(TAG, "second engine report " + m);
                result.success(null);
            } else if ("launchScenario".equals(call.method)) {
                result.success(null);
            } else {
                result.notImplemented();
            }
        });
        e.getDartExecutor().executeDartEntrypoint(new DartExecutor.DartEntrypoint(
                FlutterInjector.instance().flutterLoader().findAppBundlePath(), "secondEngineMain"));
        secondEngine = e;
        Log.i(TAG, "second engine started pid=" + Process.myPid());
    }

    static void destroySecondEngine() {
        FlutterEngine e = secondEngine;
        secondEngine = null;
        if (e != null) {
            e.destroy();
            Log.i(TAG, "second engine destroyed");
        }
    }

    private static void armBgFirstAndExit(Activity activity) {
        try (FileOutputStream out = new FileOutputStream(new File(activity.getFilesDir(), ExampleApplication.BG_FIRST_FLAG))) {
            out.write("1".getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            Log.w(TAG, "arm failed", e);
            return;
        }
        Log.i(TAG, "armed second_engine_bg_first; exiting process, relaunch the app");
        MAIN.postDelayed(() -> Process.killProcess(Process.myPid()), 300);
    }
}
