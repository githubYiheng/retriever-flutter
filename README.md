# Retriever Flutter 传输层（`sdk/flutter`，pub 包名 `revdog_retriever`）

> M4 切片 2：引擎、原生垫片（Android Java / iOS Swift）、示例 app 已就位；发布渠道在切片 3 补齐（「发布」一节届时定稿）。

纯 Dart 引擎（批格式、队列、恢复、驱逐、配置……全部在 Dart 里）+ 极薄原生垫片（只给 root 目录、owner 登记、前后台事件、
Android JobScheduler 兜底作业、iOS 后台任务、诊断出口）。规格：`docs/plan/system-design.md` §3；不变式：`docs/architecture.md` §2；
Flutter 口径：`docs/plan/m4-flutter-brief-v3.md`、ADR 0026。行为、字段、顺序、数字与 Android / iOS 0.3.0 逐字一致，只在平台层不同。

| 项 | 值 |
|---|---|
| 约束 | `sdk: ^3.8.0`、`flutter: >=3.32.0`（门禁 3.32.8 / 3.41.4 / 3.44.4） |
| 依赖 | `crypto ^3.0.6`、`logger ^2.0.0`（适配器并在主包里，`package:revdog_retriever/logger.dart`） |
| 平台 | Android minSdk 21（API 24 起才有的能力按版本守卫）；iOS 15.0（SwiftPM 与 CocoaPods 两条路径）；web / 桌面 / 宿主 `flutter test` 下整个 SDK no-op |
| 发布 | 待补（切片 3：公开只读镜像 + git tag 依赖；不发 pub.dev） |

## 接入

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();          // 先于 configure
  await Retriever.configure(
    const String.fromEnvironment('RTV_KEY'),           // key 尽量同步可得（别等远程配置 / 登录之后才 configure）
    options: const RetrieverOptions(uploadLevel: LogLevel.warn),
  );
  Retriever.setUser(currentUserId);                    // 登录 / 登出时再调；null = 未登录
  runApp(const MyApp());
}

Retriever.log(LogLevel.error, 'purchase failed', tag: 'billing', attrs: {'code': 7}, error: e, stackTrace: st);
```

- 公开入口绝不向宿主抛异常；返回 `Future` 的入口（`configure` / `flush` / `purgeLocal`）一定在有界时间内完成、不会以错误完成。
  `configure` 最多等垫片 5 s（超时后照样完成，之后的触达再重试）。
- 「上报问题」：`final r = await Retriever.flush();` → `FlushResult.stored`（15 s 内被服务端确认）或 `FlushPending`
  （`offline` / `backoff` / `paused` / `timeout` / `disabled`；未 configure = `paused`）。语义同 Android README「接入」节。
- `attrs` 值认 String / num / BigInt / bool / null；List / Set / Map 渲染成紧凑 JSON 文本；其它 `toString()`。整数绝对值 > 2^53 − 1 输出十进制字符串。
- `error` → `exc`：type = `runtimeType`、message = `toString()`、stack = 传入的 `stackTrace`（没传且是 `Error` 子类时取 `Error.stackTrace`）。
  `--obfuscate` 构建下 type 是混淆名。

### `package:logger` 宿主

```dart
import 'package:revdog_retriever/logger.dart';

final log = RetrieverLogger(tag: 'app');               // 默认 ProductionFilter（logger 默认的 DevelopmentFilter 在 release 下全丢）
// 已自建 Logger 的宿主：把 RetrieverLogOutput() 加进现有的 MultiOutput
final logger = Logger(filter: ProductionFilter(), output: MultiOutput([ConsoleOutput(), RetrieverLogOutput()]));
```

- 读 `event.origin`（不读 printer 排版后的行）；级别 trace / debug → debug、info → info、warning → warn、error → error、fatal → fatal；
  `origin.time` 作行 ts；`error` / `stackTrace` → `exc`；Function / Map / Iterable 消息照 logger printer 转字符串。
- 宿主的 filter 决定 Retriever 看到哪些级别（release 下 filter 丢了 debug → error 批的上下文里就没有 debug）。低于 `Retriever.localLevel` 的行在转字符串之前丢弃。
- printer 输出为空时 logger 根本不调 output（logger 自身行为）。

### fatal 用法

`FlutterError.onError` / `PlatformDispatcher.instance.onError` 里记 **error**（走 2 s 去抖），**不要记 fatal**：每条 fatal 立即封段物化，
每帧抛错会形成封段风暴、塞满出站箱。fatal 只留给真正即将退出的路径。Dart 异常不杀进程，Flutter 宿主几乎不会出现 `rtv.unclean_exit`。
Flutter 的 fatal **不排后台作业**（Dart 不能同步调原生）；进程随后死亡的话，下次启动的恢复把这一行物化成同一个 batch_id 的批。

## configure 之前的日志（对位 ADR 0023）

- 首次触达任何入口（含 `RetrieverLogOutput` 构造、第一次 `log()`）时，SDK 向垫片要一次 root 目录。**回包之前**的 `log()` 只计数
  （有会话后以合成行 `rtv.pre_init_dropped` 上报），`isEnabled` 回 **false**。
- 回包之后的行（不含 seq / oseq）一次 write 追加到 `<root>/pre/<token>-<uuid>.jsonl`（本进程一个文件，持文件锁），`configure` 时按
  **本次 configure** 的设定收编（过 redact、判上传义务、分 seq / oseq、error 去抖 / fatal 换段 / 用户边界照常），行 ts 保持写入时刻。上限 1 MB。
- configure 之前其它入口：`setUser` 记下来并留用户切换记录；`setEnabled` 当场落盘 / 删标记；`flush` → `pending("paused")`；
  `purgeLocal` 删 pre 文件并清 root（清完才完成）；`installId` / `supportCode` = null；`uploadLevel` / `localLevel` = warn / debug。
- configure 之前进程就死：pre 文件留在本地，之后某次 owner 引擎 configure 时作为独立会话收编并上传。

## 合成行（SDK 自己写的 warn，`synthetic: true`，不经 redact）

同 Android README：`rtv.pre_init_dropped`、`rtv.root_vanished`、`rtv.reconfigure_ignored`、`rtv.install_repaired` / `rtv.install_reset`，
另有恢复时合成的 `rtv.unclean_exit`（前台死亡）、flush 的 `rtv.flush`（error）。

## 接错 key / 地址时怎么看（对位 ADR 0025）

诊断经垫片写进系统日志（Android logcat tag `Retriever`；iOS `os.Logger` subsystem `org.revdog.retriever`、category `diagnostics`），
code 与文案同 Android README（`no_key` / `key_trimmed` / `key_malformed` / `key_env_mismatch` / `base_url_invalid` / `key_rejected`）。
Flutter 另有一条：非 owner 引擎 configure 时 `configure ignored: another engine owns Retriever in this process`。垫片不可用时退回 `print`。

## 同意与清空

语义同 Android README「同意与清空」：`setEnabled(false)` 跨重启有效（root 同级空标记 `retriever.disabled`）；撤回同意的完整组合 =
`setEnabled(false)` + `purgeLocal()` + `setUser(null)`；`await Retriever.purgeLocal()` 完成时本地已清空、`installId` 已是新值。

## 宿主必须知道的纪律

- **只在 `main()` 里 configure**：先 `WidgetsFlutterBinding.ensureInitialized()`，再尽早 `await Retriever.configure(...)`；
  **不要**在后台入口（`@pragma('vm:entry-point')` 的 firebase_messaging / audio_service / local_notifications 回调）里 configure——
  先 configure 的引擎成为本进程的 owner，后台引擎抢到 owner 后主引擎的行要等进程死后才上传。
- **多引擎与 owner**：同一进程里只有 owner 引擎（首个完成 bootstrap 的引擎）有实例；别的引擎 configure 时系统日志出一条
  `configure ignored: another engine owns Retriever in this process`，它们的行写自己的 pre 文件，**要等进程死后**由下一任 owner 收编上传
  （进程活着时 owner 不碰同进程别的引擎的 pre 文件）。owner 引擎销毁而进程还活着（Android `onDetachedFromEngine`；iOS 引擎对象释放时——
  只 `destroyContext` 而引擎对象一直被别处持有的，本进程内不会释放 owner）→ 已 configure 的其余引擎收到 `ownerReleased`（或回前台、或距上次
  ≥ 60 s 被触达）时重试接任，新 owner 把旧引擎的会话当死会话恢复（`rtv.unclean_exit`）。`Isolate.run` / `compute` 出来的 worker isolate 里调 SDK =
  no-op（行丢、不计数）；后台**引擎**（firebase_messaging 等）是根 isolate，照上面的 owner 规则走。
- **`flutter test` 下整个 SDK no-op**（零 Timer、零文件、不抛，也不发任何 channel 调用）；web / 桌面同样 no-op。
- **不与原生 SDK 混用**：同一 app 不要同时接 `retriever-android` / `retriever-ios` 与本包。root 同名（Android `noBackupFilesDir/retriever/`、
  iOS `Application Support/<bundle-id>.retriever/`，同原生 SDK）——两套引擎会同写一个目录；后台作业 id 默认同为 `0x5254`。本包的 init
  provider 换了 authority（`${applicationId}.revdog_retriever.init`）只是为了 manifest 合并不冲突、不被静默丢掉，不代表能共存。
- **开发机切换环境**（staging ↔ 生产、换成另一个 app 的 key）：切换前先 `purgeLocal()` 或卸载重装。
- **iOS 上 `Process.killPid(pid, ProcessSignal.sigkill)` 对本进程返回 false**（dart:io 在 iOS 杀不了进程）：要模拟「被系统杀」，示例 app 走原生
  `kill(getpid(), SIGKILL)`（`example/ios/Runner/AppDelegate.swift`）。
- **`log()` 落盘即返回**：每行一次同步 write（进程被杀不丢，真杀进程测试守着）；其余 I/O 都在异步任务里，重活（gzip、批解析）在
  `Isolate.run` 里做。`redact` 钩子在落盘前同步执行，钩子里调 `log()` 被忽略，抛异常则该行丢弃。
- **网络**：SDK 用自己的 `dart:io HttpClient`——不经宿主的 http / dio 拦截器、不经 `HttpOverrides.global`、**一律直连**（不读系统代理，
  也不读 `http_proxy` 等环境变量）；超时 30 s、不跟随重定向、响应体最多读 64 KB。
- **后台兜底**（对位原生 SDK）：
  - Android：进后台且出站箱有待传批时，排一个一次性 JobScheduler 作业（id 默认 `0x5254`，`RetrieverOptions.jobId` 可改；网络约束、
    持久化，缺 `RECEIVE_BOOT_COMPLETED` 时退回非持久；同 id 已被别的组件占着则不替换、不取消）。系统拉起作业时，进程里有 owner 引擎
    就经它的 channel 让 Dart 排空；进程是被作业冷启动、没有跑过 `main()`（没有 owner）→ 作业直接结束，不跑 headless Dart，批留到下次
    启动。`setEnabled(false)` 取消作业。网络恢复（API ≥ 24 默认网络回调）只用于提前唤醒。
  - iOS：进后台时垫片在通知回调里同步 `beginBackgroundTask`（只在有 owner 时、一次切换一个），Dart 排空结束后 end；系统收回时原生先
    end，再让 Dart 取消在途请求。iOS 没有作业，回前台时再排空。

## 平台与接入路径

- **Android**：纯 Java 垫片、不 apply Kotlin Gradle Plugin（Flutter 3.44 的 built-in Kotlin 迁移与它无关）。manifest 自动合并进宿主：
  `INTERNET`、`ACCESS_NETWORK_STATE`、`RECEIVE_BOOT_COMPLETED` 权限，`RetrieverUploadJobService`，`RetrieverInitProvider`（authority
  `${applicationId}.revdog_retriever.init`、`initOrder` 1000，在 `Application.onCreate` 之前注册进程级前后台 tracker、不做 I/O；宿主可用
  `tools:node="remove"` 去掉，之后在引擎 attach 时兜底注册、初值取进程重要性）。前后台按 Activity 身份计数（`AppLifecycleListener` 跟随单个
  Activity，宿主开原生 Activity 会误判，不用它）。
- **iOS**：Swift 垫片，最低 iOS **15.0**（宿主 app 的部署目标须 ≥ 15.0；CocoaPods 宿主的 Podfile 写 `platform :ios, '15.0'`）。两条接入路径同一份
  源码——**SwiftPM**（`ios/revdog_retriever/Package.swift`，依赖 `FlutterFramework`；Flutter 3.44 起默认开启，按插件混合：宿主开了 SwiftPM 就走它，
  其余插件照走 CocoaPods）与 **CocoaPods**（`ios/revdog_retriever.podspec`）。（Xcode 27 起 Apple 只接受 15.0 以上的部署目标，Flutter 3.44 自己的
  `Flutter` pod 还是 13.0：CocoaPods 宿主在 Xcode 27 下需在 Podfile 的 `post_install` 里把各 pod 的 `IPHONEOS_DEPLOYMENT_TARGET` 提到 15.0——与本包
  无关，任何 Flutter app 都一样。）隐私清单随包
  （SwiftPM 资源 / CocoaPods `revdog_retriever_privacy.bundle`），声明同 sdk/ios（DiskSpace E174.1、FileTimestamp C617.1 与收集的数据类型）。
  前后台只用 NotificationCenter（`UIApplication` 与 `UIScene` 两套通知），scene / sceneless 宿主都适用，宿主不需要为本包迁 UIScene。
  root 每次 root / bootstrap 都重设「不进 iCloud 备份」与 `completeUntilFirstUserAuthentication`。
- **诊断退回 `print` 时**（垫片不可用）：Android 在 logcat `I/flutter`，iOS 在 app 进程的 syslog `flutter: …` 行（没有 subsystem）。
- **Dart 入口**：pubspec 同时声明 `pluginClass`（原生）与 `dartPluginClass: RetrieverDartPlugin`（`src/plugin_entry.dart`），引擎在每个根
  isolate 跑入口之前注入平台工厂；宿主不需要任何手工注册。

## 开发

```bash
cd sdk/flutter
~/fvm/versions/3.44.4/bin/flutter pub get
~/fvm/versions/3.44.4/bin/flutter analyze                 # 含 example/
~/fvm/versions/3.44.4/bin/dart format --set-exit-if-changed .
~/fvm/versions/3.44.4/bin/dart test                       # 纯 Dart 引擎（假平台）；跨语言校验要仓库根 npm install 过
~/fvm/versions/3.44.4/bin/flutter test test/flutter/*.dart   # 通道打桩 / 插件入口（真 ChannelPlatform）
cd example/android && ./gradlew :revdog_retriever:testDebugUnitTest            # Android 垫片 JUnit（先在 example 里 flutter build apk 一次）
cd example/ios && xcodebuild test -workspace Runner.xcworkspace -scheme Runner \
  -destination 'platform=iOS Simulator,name=<模拟器>' -only-testing:RunnerTests  # iOS 垫片 XCTest（先 flutter build ios --simulator 一次）
```

- **门禁 = `dart test` + `flutter test test/flutter/*.dart`**（加原生单测与两端 example 构建）。`test/flutter/` 下的文件故意不叫 `*_test.dart`：
  它们 import `flutter_test`（`dart:ui`），叫 `_test.dart` 的话纯 `dart test` 会去编译它们而失败；所以要显式列文件（shell 展开 `*.dart`），
  只给目录 `flutter test test/flutter/` 找不到 `_test.dart` 文件、会退回跑整个 `test/`。
- **裸 `flutter test`（不带参数）不能当门禁**：它在 flutter_tester 里跑 `test/` 下的纯 Dart 用例，其中依赖子 Dart 进程（真杀进程、多进程锁）与
  `dart:io` 真实网络 / 进程环境的用例在 flutter_tester 下失败（清单与原因见切片 2 报告）；那些用例只在 `dart test`（独立 VM）下有意义。
- **宿主 `flutter test` 下整个 SDK no-op**（`FLUTTER_TEST=true` 时在任何 channel 调用之前判 unsupported：零 Timer、零文件、不抛）；
  **工作 isolate**（`Isolate.run` / `compute`）里触达 SDK = unsupported（插件工厂对非根 isolate 抛异常，门面当作「没有平台」，行丢、不计数）。
  不提供「首次触达时惰性注入平台」的退路：插件入口由 `dartPluginClass` 在每个根 isolate 跑入口之前注入，上面两种场合注入与否结果都一样。
- **示例 iOS 构建的一条无害错误**：`flutter build ios -v`（example）的详细输出里每次都有一条 “An error occurred when adding the plugin's Swift
  package to the Xcode project”（不带 `-v` 时不显示）。原因：flutter_tools 给插件自带的 example 工程加「本地插件包」引用时，Xcode 27 的 SwiftPM 按目录名认包——插件根目录在本仓库叫
  `sdk/flutter`、包名是 `revdog_retriever`，对不上，flutter_tools 校验失败后自行回退，构建照常成功。split 出去的仓库根就是包根，不会出现。
- 示例 app 用法见 `example/README.md`（key / baseUrl 经 `--dart-define-from-file=env.json` 注入，`env.json` 不进仓库）。

## 发布

待补（切片 3）。
