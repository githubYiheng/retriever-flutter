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
的次序，验 `ownerReleased` 接任；Android 同 `second_engine_rebuild`。iOS 垫片的 owner / 后台任务轨迹是 `.debug` 级：
`xcrun simctl spawn <device> log config --subsystem org.revdog.retriever --mode level:debug` 之后 `log show --debug` 可见。

- Android：`adb shell am start -n org.revdog.retriever.revdog_retriever_example/.MainActivity --es scenario <name>`（先 `am force-stop` 冷启动）。
  `second_engine_bg_first` 由 `ExampleApplication.onCreate` 先起第二引擎：按钮会写一次性标记并结束进程，再冷启动即可。
- iOS：`xcrun simctl launch <device> org.revdog.retriever.revdogRetrieverExample --scenario <name>`（`second_engine_bg_first` 由
  `AppDelegate` 在 `didFinishLaunching` 里先起第二引擎）。

第二引擎、`finish()` / 换根 VC 都在示例自己的原生代码里（`ExampleChannel`），不进生产垫片。
