# revdog_retriever_example

Retriever Flutter 插件的示例 app：场景按钮 + 模拟器验收入口（切片 2 简报 §4）。

```bash
cp env.json.example env.json      # 填 key / baseUrl；env.json 不进仓库。空 key = 只写本地、出 no_key 诊断
flutter run --dart-define-from-file=env.json
```

场景（按钮，或启动参数）：`error` `user` `bulk` `crash` `flush` `fatal_storm` `preconfigure` `preconfigure_kill`
`second_engine_late` `second_engine_bg_first` `second_engine_rebuild` `second_engine_rebuild_hold`。结果打到屏幕与系统日志（前缀 `RTVEX`）。
`crash` / `preconfigure_kill` 先试 `Process.killPid(pid, sigkill)`，iOS 上它回 false（dart:io 在 iOS 杀不了进程），退回示例原生通道 `kill(getpid(), SIGKILL)`。
`second_engine_rebuild_hold`：iOS 换根 VC 后旧 VC 多留 1 s 再释放（启动参数 `--hold <ms>` 可改），强制「新引擎先 bootstrap、旧引擎后 detach」
的次序，验 `ownerReleased` 接任；Android 同 `second_engine_rebuild`。

- Android：`adb shell am start -n org.revdog.retriever.revdog_retriever_example/.MainActivity --es scenario <name>`（先 `am force-stop` 冷启动）。
  `second_engine_bg_first` 由 `ExampleApplication.onCreate` 先起第二引擎：按钮会写一次性标记并结束进程，再冷启动即可。
- iOS：`xcrun simctl launch <device> org.revdog.retriever.revdogRetrieverExample --scenario <name>`（`second_engine_bg_first` 由
  `AppDelegate` 在 `didFinishLaunching` 里先起第二引擎）。

怎么看系统日志：

- 垫片只往系统日志写**配置诊断**（`configure ignored: …`、`no key configured; …` 等，同 SDK README「接错 key / 地址时怎么看」）：
  Android `adb logcat -s Retriever`；iOS subsystem `org.revdog.retriever`、category `diagnostics`——
  `xcrun simctl spawn <device> log stream --level info --predicate 'subsystem == "org.revdog.retriever"'`。
- 垫片**没有** owner 登记 / 接任、后台任务的轨迹日志（调 `log config --mode level:debug` 也看不到）。owner 与接任看示例自己的 `RTVEX` 行
  （`configured owner=… installId=… supportCode=…`、`second engine report {…}`）；iOS 后台任务的 begin / end 看 UIKit 自己的日志：
  `xcrun simctl spawn <device> log stream --predicate 'subsystem == "com.apple.UIKit" AND category == "BackgroundTask"'`，
  taskName `org.revdog.retriever.upload`；Android 作业看 `adb shell dumpsys jobscheduler`（`RetrieverUploadJobService`）。
- 盘上状态：iOS 数据容器 `Library/Application Support/<bundle-id>.retriever/`（`xcrun simctl get_app_container <device> <bundle-id> data`）；
  Android `adb exec-out run-as org.revdog.retriever.revdog_retriever_example tar -cf - no_backup`。

第二引擎、`finish()` / 换根 VC 都在示例自己的原生代码里（`ExampleChannel`），不进生产垫片。

示例工程由 Flutter 3.44.4 模板生成（Android Gradle 9.1 / AGP 9.0.1；iOS 用 3.38 起的 `FlutterImplicitEngineDelegate` / `FlutterSceneDelegate`），
只能用 3.44 构建；为了 Xcode 27 只给 Apple Silicon 模拟器构建（`ios/Flutter/*.xcconfig` 的 `ARCHS[sdk=iphonesimulator*] = arm64`），部署目标 15.0。
门禁脚本 `scripts/sdk-flutter-gates.sh` 在源码拷贝里构建它，**不带** `--dart-define-from-file`（拷贝里没有 `env.json`）。
