package org.revdog.retriever.revdog_retriever_example;

import android.os.Bundle;
import androidx.annotation.NonNull;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;

/**
 * 主 Activity：用 FlutterActivity 自建的非缓存引擎（finish 时随之 destroy，「销毁重建」场景靠它）。
 * 启动参数 {@code --es scenario <name>} 经 {@link ExampleChannel} 的 {@code launchScenario} 交给 Dart。
 */
public class MainActivity extends FlutterActivity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        ExampleChannel.noteLaunch(this, getIntent() == null ? null : getIntent().getStringExtra("scenario"));
        super.onCreate(savedInstanceState);
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        ExampleChannel.installMain(flutterEngine, this);
    }
}
