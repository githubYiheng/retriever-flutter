package org.revdog.retriever.revdog_retriever_example;

import android.app.Application;
import java.io.File;

/**
 * 「后台先」变体（v3 盲审 H4-2 / E2）：一次性标记在时，Activity 之前先起第二引擎并 configure（模拟 firebase_messaging 等在进程启动时
 * 建的后台引擎）。没有标记时什么都不做。
 */
public class ExampleApplication extends Application {
    static final String BG_FIRST_FLAG = "rtv-example-bg-first";

    @Override
    public void onCreate() {
        super.onCreate();
        File flag = new File(getFilesDir(), BG_FIRST_FLAG);
        if (flag.exists()) {
            //noinspection ResultOfMethodCallIgnored
            flag.delete();
            ExampleChannel.bgFirstPending = true;
            ExampleChannel.startSecondEngine(this);
        }
    }
}
