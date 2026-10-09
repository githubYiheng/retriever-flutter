# M4 切片 2 完成报告（两端垫片 + 插件入口 + 示例 app）

> 实现子代理 2026-10-09 至 10-10；本文由主代理按子代理回传的报告正文整理（子代理环境无法写本文件）。依据：`docs/plan/m4-slice2-brief.md` → v3 → 切片 1 代码 → 原生 SDK 平台层 → 核实 refresh / round2 → 主代理两轮裁决。
> 环境：Flutter 3.44.4、Xcode 27.0、iOS 27.0 模拟器（iPhone 18 Pro）、Android API 36 模拟机。

## 1. 结果

| 门禁 | 结果 |
|---|---|
| `flutter analyze`（含 example） | No issues |
| `dart format --set-exit-if-changed -o none .` | 0 changed |
| `dart test` | 294 / 294（290 + 竞态门面用例 4） |
| `flutter test test/flutter/*.dart` | 20 / 20（必须写 glob：只给目录会退回去跑整个 `test/`） |
| Android JUnit（`example/android: ./gradlew :revdog_retriever:testDebugUnitTest`） | 22 / 22 |
| iOS XCTest（`xcodebuild test … -only-testing:RunnerTests`） | 20 / 20 |
| `flutter build apk --debug` / `flutter build ios --simulator --no-codesign`（example，SwiftPM） | 通过 |
| CocoaPods 路径 | 插件目录外的 scratch 宿主：关 SwiftPM、`pod install`、构建 + 模拟器冒烟通过；隐私清单在 `revdog_retriever_privacy.bundle` |
| 两端模拟器实跑 | 全部场景通过（§4），含 second_engine 三变体 + 竞态变体 |

## 2. 交付

- `lib/src/channel_platform.dart`（唯一 import `package:flutter/services.dart` 的引擎文件；纯转发；`forCurrentIsolate()` 工厂，worker isolate 抛 → unsupported）、`lib/src/plugin_entry.dart`（`RetrieverDartPlugin.registerWith()` 只注入工厂）；pubspec android / ios 加 `dartPluginClass` + `dartFileName: src/plugin_entry.dart`。
- `android/`（纯 Java，`org.revdog.retriever.flutter`，AGP 8.7.3 / compileSdk 35 / minSdk 21 / Java 17）：`RetrieverPlugin`、`EngineHandle`、`EngineRegistry`、`OwnerRegistry`、`LifecycleTracker`、`RetrieverInitProvider`（authority `${applicationId}.revdog_retriever.init`，initOrder 1000）、`RetrieverUploadJobService`、`JobApi` / `JobGate` / `SystemJobApi`、`NetworkWatcher`、`Diagnostics`、`PlatformInfo`；JUnit 6 个文件。
- `ios/`：`revdog_retriever/Package.swift`（tools 5.9、iOS 15、依赖 `FlutterFramework`、`.process("PrivacyInfo.xcprivacy")`）、`revdog_retriever.podspec`（15.0，`resource_bundles`）；`Sources/revdog_retriever/`：`RetrieverPlugin`（`registrar.publish(self)`）、`EngineRegistry`（owner weak 引用 + isolateId 快照）、`ForegroundTracker`（进程级单例，UIApplication + UIScene 两套通知）、`BackgroundTasks`（过期 handler 内原生先 end）、`Diagnostics`、`PlatformInfo`、`PrivacyInfo.xcprivacy`。
- `example/`：插件模板 example + 场景按钮 / 启动参数（`error` `user` `bulk` `crash` `flush` `fatal_storm` `preconfigure` `preconfigure_kill` `second_engine`（late / background_first / rebuild / rebuild_hold --hold ms）、`secondEngineMain` 入口、`RetrieverLogger` 接法；Android `ExampleApplication` / `ExampleChannel`，iOS `AppDelegate` 含 `ExampleChannel`、`RunnerTests`；`env.json`（gitignored）/ `env.json.example`。Xcode 27 适配只在示例：部署目标 15、模拟器 `ARCHS = arm64`。iOS `Process.killPid` 返回 false → crash 场景退回原生 `kill(getpid(), SIGKILL)`。
- `test/flutter/`：`channel_platform_flutter.dart`（11）、`plugin_facade_flutter.dart`（9）。`test/purity_test.dart` 改为正向断言；`test/flutter_specific_test.dart` 末尾加 4 个「bootstrap 回包与事件次序」用例。
- README：平台与接入路径（SwiftPM / CocoaPods、宿主部署目标 ≥ 15）、后台兜底、多引擎与 owner、禁止混用、代理直连、开发（门禁命令、裸 `flutter test` 为何不能当门禁、工作 isolate / `flutter test` 下 no-op、示例 iOS 构建的无害错误）。

## 3. 契约落点（v3 §3；参数一律是以契约参数名为键的 Map）

→：`root` / `bootstrap` / `diagnose` / `scheduleUploadJob` / `cancelUploadJob` / `endBackgroundTask` / `availableBytes`（Android 在后台线程取 `getAllocatableBytes` 后回主线程；iOS global 队列）。
←：`didEnterBackground({bgTaskId})` 只投 owner（iOS 只在有活 owner 时同步 begin 一个后台任务；Dart 无出口时带 id 当场 end）；`willEnterForeground` 广播；`foregroundStateChanged({fg})` 只投 owner（iOS）；`backgroundTaskExpired({id})` 原生先 end；`networkRestored` 只投 owner（Android）；`drainOutbox({budgetMs}) → {reschedule}`（预算 120000 ms；无 owner → `onStartJob` 返回 false；owner 作业中 detach → 按重排结束）；`stopUploadJob`；`ownerReleased` 广播给其余引擎（Android `onDetachedFromEngine`；iOS `detachFromEngine(for:)`）。
事件处理器在 `ChannelPlatform` 构造时装（早于 `root()`）；binding 未初始化时推到首次调用前装，装不上按 `binding_uninitialized` 进 failed。

## 4. 模拟器实跑摘要

Android（API 36）与 iOS（27.0，scene 应用，SwiftPM）全部场景冷启动、上传指向本机不通端口、从出站箱核 oseq：error（`oseq 1-2` + 57 行 ctx）、user（段头 `user=device-test-user`）、bulk（200 行 ctx）、flush（`pending(offline)`）、fatal_storm（Android 589 行 2 批 `1-112` / `113-590`；iOS 600 行 `1-120` / `121-601`，连续）、crash（`rtv.unclean_exit`）、preconfigure（收编 `oseq 1-4`，首触到 root 回包之间 2 行 → `rtv.pre_init_dropped {count 2, error_count 1}`）、preconfigure_kill（孤儿收编为独立会话 `oseq 1-3`）。
second_engine：后到 → `configure ignored: another engine owns Retriever in this process`（logcat `W/Retriever` / os_log diagnostics），第二引擎 pre 文件进程死后作为孤儿上传；后台先 → 第二引擎成 owner，销毁后主引擎约 100 ms 接任、旧会话按死会话恢复；销毁重建 → Android `finish()` 后同 pid 新引擎 `owner=true`，iOS 换根 VC 后接任。Android 作业：有 owner 时 `jobFinished`，冷进程无 owner `onStartJob returned false`；网络回调已登记。空 key 两端出 `no_key`。iOS 进后台 begin 一个任务、Dart 排空后 end，两套通知只 begin 一次。

**竞态（已修在门面）**：3.38 起平台 / UI 线程合一，原生发往 Dart 的事件可能先于排队的 `bootstrap()` 回包到达：新引擎回包 `owner=false` 之前就收到了 `ownerReleased`，门面处于 bootstrapping 把它丢了（iOS 换根 VC 约 1/10 复现，`--hold 36–54 ms` 稳定复现）。修法：`_Events` 在 bootstrapping 态收到 `ownerReleased` / `willEnterForeground` → 置 `_retryAfterBootstrap`；回包非 owner 时消费标志立即 `retryConfigure(force: true)`；每轮 bootstrap 开始清标志。修后带延迟变体 10/10、普通变体 10/10 接任；4 个门面单测 + 1 个真 channel 用例确定性覆盖（变异检查过）。

## 5. 偏离与说明

1. 非根 isolate 工厂抛异常（类型不可空）→ unsupported，同效。惰性注入退路不做（主库不能 import flutter）。
2. iOS tracker 收到 `willEnterForeground` 不重读状态（此时 `applicationState` 仍是 background）直接置前台；`didEnterBackground` / active / resign 重读。
3. Android early 初值未知、等首个 onStart；重要性按原生逐字 `== FOREGROUND || == VISIBLE`（125 / 150 算后台）。
4. 示例删了模板里两条本地包引用（插件根目录名 `flutter` ≠ 包名，Xcode 27 SwiftPM identity 冲突）；flutter_tools 每次构建会尝试加回并自行回退，只在 `-v` 里留一条无害错误。
5. `flutter test` 文件名 `*_flutter.dart`（纯 `dart test` 不编它们）；门禁命令 `flutter test test/flutter/*.dart`。裸 `flutter test` 在 flutter_tester 下 11 个用例失败：`kill_test` 3、`preconfigure_kill_test` 5、`blind_review_fix_test.a1_sessionLockSurvivesAdoption`、`audit_fix_test` #8 / #9——共同原因是它们用 `Platform.resolvedExecutable` 起子 Dart 进程，而 flutter_tester 下它是 `flutter_tester`、不按 `dart <script>` 执行（握手超时）。
6. **staging 意外上传**：主代理在子代理仍在运行时（10-10 00:39）把 staging key 写进了 `example/env.json`，子代理 00:45–00:52 的 20 次 iOS「销毁重建」运行用它构建并真上传了（每次新 install、1–2 批示例行；最后一个 install `9cd01c58…`）。属主代理操作失误；数据无害，留作 staging 链路通的证据，不清理。
7. 原生 SDK 走系统代理、Flutter 直连；iOS `Process.killPid` 对本进程返回 false（README 写）。

## 6. 主代理裁决（2026-10-10，第二轮之后）

- iOS 引擎对象：`registrar.messenger()` 在 3.32.8 / 3.41.4 / 3.44.4 都是 `FlutterBinaryMessengerRelay`，`as? FlutterEngine` 必失败，第二条释放路径等于关闭，且防不住「已 `destroyContext` 未释放」窗口的发送崩溃 → 改回 registrar 的 `flutterEngine` 属性（`responds(to:)` 守），拿不到时退 `registrar.viewController?.engine`，再退 `.unknown`。
- Android 重要性阈值：按原生逐字（100 / 200）。
- owner 引擎被销毁而进程仍活 → 旧会话被合成 `rtv.unclean_exit`（Selah 按返回键退出会每次假报崩溃）→ 新规则：`meta.json` 加可选键 `token`（本进程令牌），恢复时同 token 的死会话按 `clean_bg` 收尾、不合成 unclean_exit（引擎在进程内被销毁从不是崩溃；真崩溃进程死、令牌必变）。
- 门禁 `flutter test test/flutter/*.dart`；裸 `flutter test` 失败清单接受并写 README。

## 6b. 第三轮落地（2026-10-10）

§6 三条已全部落地：`model.dart` meta 可选键 `token`（孤儿收编的会话不带）、`recovery.dart` 同 token 死会话 fg → `clean_bg` 无合成行（`lifecycle_test` +3，变异检查过）；iOS `RetrieverPlugin.swift` 引擎解析三级退路（XCTest 21）；README 加 `Process.killPid` 一句。销毁重建两端各 3 次：`sessions.jsonl exit=clean_bg`、无 `rtv.unclean_exit`；另跑一次真 crash 仍是 `unclean_fg` + 合成行。门禁：analyze / format / `dart test` 297 / `flutter test` 20 / JUnit 22 / XCTest 21 / 两端 example 构建，全过（主代理复跑 Dart 侧与 JUnit 一致）。

## 7. 没覆盖

staging 冒烟（主代理）；3.32.8 / 3.41.4 门禁（切片 3）；iOS 后台任务过期、Android `onStopJob`、`networkRestored` 实际投递只有单测；Android 真实返回键路径用 `finish()` 代替；示例 app 无 widget / integration 测试。
