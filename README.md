# Retriever Flutter 传输层（`sdk/flutter`，pub 包名 `revdog_retriever`）

纯 Dart 引擎（批格式、队列、恢复、驱逐、配置……全部在 Dart 里）+ 极薄原生垫片（只给 root 目录、owner 登记、前后台事件、
Android JobScheduler 兜底作业、iOS 后台任务、诊断出口）。规格：`docs/plan/system-design.md` §3；不变式：`docs/architecture.md` §2；
Flutter 口径：`docs/plan/m4-flutter-brief-v3.md`、ADR 0026。行为、字段、顺序、数字与 Android / iOS 0.3.0 逐字一致，只在平台层不同
（见文末「与两端的平台差异」）。

| 项 | 值 |
|---|---|
| 版本 | 0.1.0（`RetrieverVersion.current`；`device.sdk` / `X-Rtv-Sdk` = `retriever-flutter/0.1.0`） |
| 约束 | `sdk: ^3.8.0`、`flutter: >=3.32.0`（门禁 3.32.8 / 3.41.4 / 3.44.4，开发钉 3.44.4） |
| 依赖 | `crypto ^3.0.6`、`logger ^2.0.0`（适配器并在主包里，`package:revdog_retriever/logger.dart`） |
| 平台 | Android minSdk 21（API 24 以下少两项能力，见「平台与接入路径」）；iOS 15.0（SwiftPM 与 CocoaPods 两条路径）；web / 桌面 / 宿主 `flutter test` 下整个 SDK no-op |
| 发布 | 公开只读镜像 `githubYiheng/retriever-flutter` + git tag 依赖；**不发 pub.dev**（ADR 0006 / ADR 0007 D4）。见文末「发布」 |

## 安装

```yaml
# 宿主 pubspec.yaml
dependencies:
  revdog_retriever:
    git:
      url: https://github.com/githubYiheng/retriever-flutter.git
      ref: v0.1.0
```

- 镜像仓库根就是包根；`ref` 写 tag（升级时改 tag），也可以写完整 commit sha。pubspec.lock 里会记下 `resolved-ref`。
- **公开仓库只读**：它是 monorepo `sdk/flutter` 的 subtree split 发布镜像，issue / PR 不在那里处理，改动一律回 monorepo。版本变更见 `CHANGELOG.md`。
- iOS 宿主的部署目标须 ≥ 15.0；Android 宿主 minSdk ≥ 21。插件自动注册（`pluginClass` + `dartPluginClass`），宿主不需要任何手工注册代码。

## 接入

```dart
import 'package:flutter/widgets.dart';
import 'package:revdog_retriever/revdog_retriever.dart';

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
  `configure` 最多等垫片 5 s（超时后照样完成，之后的触达再重试）。key 与 baseUrl 先去掉首尾空白与控制字符再用。
- 「上报问题」：`final r = await Retriever.flush();` 向当前段追加合成行（`error`、`tag: "rtv.flush"`、`synthetic: true`，无视上传级别一定上传），
  立即封段并排空；该批 15 s 内被服务端确认 → `FlushResult.stored`，否则 `FlushPending`（`reason` ∈ `offline` / `backoff` / `paused` /
  `timeout` / `disabled`；未 configure = `paused`，等待中被禁用 = `disabled`）。`flush(includeContext: false)` 时该批不带上下文。
  已有一个 flush 在等待、且它之后没有新的义务行时，新调用挂到同一个等待上——**不要在拿到 pending 后自旋重试**。
- 用户撤回同意：`Retriever.setEnabled(false)`；清空本地：`await Retriever.purgeLocal()`；当前状态：`Retriever.isEnabled`；客服短码：
  `Retriever.supportCode`（install_id 前 8 位 + 会话号）。语义见「同意与清空」。
- 生效级别（远程配置钳制后）：`Retriever.uploadLevel` / `Retriever.localLevel`，适配器用来早过滤。
- `attrs` 值认 String / num / BigInt / bool / null；List / Set / Map 渲染成紧凑 JSON 文本（有上限）；其它 `toString()`。≤ 32 键、≤ 4 KB，
  超出截断并标 `truncated`；单个值求值出错（`toString` 抛异常、循环引用、遍历时被并发修改）只影响那个值：写 `"<unprintable>"` 并标
  `truncated`，行照常落盘。整数绝对值 > 2^53 − 1 输出十进制字符串（查看台与 `rtv` 用 `JSON.parse`）。
- `error` → `exc`：type = `runtimeType`、message = `toString()`、stack = 传入的 `stackTrace`（没传且是 `Error` 子类时取 `Error.stackTrace`）。
  `--obfuscate` 构建下 type 是混淆名。
- `RetrieverOptions` 不可变（`const` 构造 + `copyWith`；`redact` / `processName` 这类可空字段要显式传 null 才改回 null）：`uploadLevel`
  （默认 warn）、`localLevel`（默认 debug）、`dailyBatchCap`（默认 0 = 不限）、`localCapBytes`（默认 20 MiB，远程可调 2–100 MB）、`redact`、
  `processName`（只认首次 configure）、`jobId`（Android 后台作业 id，默认 `0x5254`）。

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
- `RetrieverLogger()` 默认两路输出（控制台 + Retriever，同 `Logger()` 默认）；传 `output` 时替换控制台那一路。printer 输出为空时 logger 根本不调 output（logger 自身行为）。
- output 自己 catch 一切异常并计数，零 `print`、零外泄。

### fatal 用法

`FlutterError.onError` / `PlatformDispatcher.instance.onError` 里记 **error**（走 2 s 去抖），**不要记 fatal**：每条 fatal 立即封段物化，
每帧抛错会形成封段风暴、塞满出站箱（fatal 有 10 s 节流，窗口内只有第一条立即换段）。fatal 只留给真正即将退出的路径。
Dart 异常不杀进程，Flutter 宿主几乎不会出现 `rtv.unclean_exit`。Flutter 的 fatal **不排后台作业**（Dart 不能同步调原生）；
进程随后死亡的话，下次启动的恢复把这一行物化成同一个 batch_id 的批。

## configure 之前的日志（对位 ADR 0023）

- 首次触达任何入口（含 `RetrieverLogOutput` 构造、第一次 `log()`）时，SDK 向垫片要一次 root 目录。**回包之前**的 `log()` 只计数
  （有会话后以合成行 `rtv.pre_init_dropped` 上报），`isEnabled` 回 **false**。这一拍通常是几毫秒。
- 回包之后的行（不含 seq / oseq）一次 write 追加到 `<root>/pre/<token>-<uuid>.jsonl`（本进程一个文件，持文件锁；`token` 是垫片给的
  进程级 UUID），`configure` 时按**本次 configure** 的设定收编（过 redact、判上传义务、分 seq / oseq、error 去抖 / fatal 换段 / 用户边界照常），
  行 ts 保持写入时刻。不论 `configure` 早晚，判定结果一样。
- **会过 redact**：收编时 configure 之前的行经过 `RetrieverOptions.redact`（返回 null / 抛异常 = 丢弃该行）——redact 可能在 SDK 的异步任务里被调，
  要快、不要依赖调用栈；它改了 `ts` 也会被取回原值。SDK 自己的合成行（`rtv.*`）不经 redact。
- **上限 1 MB**：本进程 pre 文件写到 1 MB 后不再写；超出的、写失败的行计数，有会话之后以 `rtv.pre_init_dropped` 上报。计数只在内存：
  进程在那之前死掉，计数随之丢失。
- configure 之前其它入口：`setUser` 记下来并留用户切换记录；`setEnabled` 当场落盘 / 删标记（root 还没回包时记内存、回包后补做）；
  `flush` → `pending("paused")`；`purgeLocal` 删 pre 文件并清 root（清完才完成）；`installId` / `supportCode` = null；
  `uploadLevel` / `localLevel` = warn / debug（适配器早过滤按全收）；fatal 只写行。configure 之前不驱逐、不联网、不排作业、不恢复旧会话。
- configure 之前进程就死：pre 文件留在本地，之后某次 owner 引擎 configure 时作为独立会话收编并上传（没有前后台记录，不合成
  `rtv.unclean_exit`）。只有收编不了的孤儿满 7 天才在驱逐时删除；pre 文件计入本地总量上限。
- 实例身份只认首次 `configure`：之后改 `processName` 被忽略并留合成 warn `rtv.reconfigure_ignored`（`attrs.field = "process_name"`）；
  参数完全相同的重复 `configure` 只更新 redact、不发请求、不再等垫片。再次 `configure` 改的级别同步生效。

## 合成行（SDK 自己写的，`synthetic: true`，不经 redact）

| tag | 级别 | 何时 | attrs |
|---|---|---|---|
| `rtv.pre_init_dropped` | warn | 有没落盘的行（首触到 root 回包之间、pre 文件超 1 MB / 写失败、没有会话时的 log、内部异常），一旦有可写会话就写一条并清零 | `count`、`error_count`（error 及以上）、`first_ts`、`last_ts` |
| `rtv.root_vanished` | warn | 运行中会话目录 / root 被删，重新建会话后写一条 | — |
| `rtv.reconfigure_ignored` | warn | 首次之后的 `configure` 改了 `processName` | `field`: `process_name` |
| `rtv.install_repaired` / `rtv.install_reset` | warn | `install.json` 损坏：按会话 `meta.json` 里的副本修复 / 找不到副本清空重建 | 同 Android CHANGELOG 0.2.0 |
| `rtv.unclean_exit` | error | 启动恢复发现上次在前台死亡的会话（msg `process ended while foregrounded`，带上下文补传；同进程内被销毁的引擎会话不算，见「宿主必须知道的纪律」） | — |
| `rtv.flush` | error | `flush()` 的标记行 | — |

## 接错 key / 地址时怎么看（对位 ADR 0025）

key 或 baseUrl 写错时，日志流本身正好传不上去——所以 SDK 经垫片把诊断写进**系统日志**。接入、换 key、换环境之后看一眼：

```bash
adb logcat -s Retriever                                                         # Android
xcrun simctl spawn booted log stream --level info --predicate 'subsystem == "org.revdog.retriever"'   # iOS 模拟器（真机用 Console.app 过滤同一 subsystem）
```

| code | 何时 | 级别（Android / iOS） | 消息 |
|---|---|---|---|
| `no_key` | key 为空（`""` / 纯空白） | I / `.info` | `no key configured; logs are written locally and never uploaded` |
| `key_trimmed` | key 首尾带空白 / 控制字符，已去掉 | W / `.notice` | `key had leading or trailing whitespace; it was trimmed` |
| `key_malformed` | key 不符合 `lk_<live\|test>_<app>_<32 hex>_<crc>` 或校验位不对 | W / `.notice` | `key is not a valid Retriever key (format or checksum mismatch); the server will reject it` |
| `key_env_mismatch` | test key 配生产地址，或 live key 配 staging 地址 | W / `.notice` | `key environment does not match the endpoint (test key with production endpoint, or live key with staging endpoint); the server will reject it` |
| `base_url_invalid` | baseUrl 不是带主机的 `http` / `https` 绝对地址 | W / `.notice` | `baseUrl is not a valid http(s) URL; uploads will fail` |
| `key_rejected` | 服务端拒绝当前 key（401 / 403 且回了 `reason`），上传进入暂停 | W / `.notice` | `server rejected the key (HTTP <status>, reason=<reason>); uploads paused for <N> min; logs are kept locally` |
| `configure_ignored`（Flutter 专有） | 非 owner 引擎调了 `configure`（见「多引擎与 owner」） | W / `.notice` | `configure ignored: another engine owns Retriever in this process` |

- 诊断只是说出来：不拦请求、不停写本地；被拒后暂停上传（1 h 起倍增到 24 h），本地照写，key 改对后（换 key 立即清暂停）积压的批照常补传。
- 不传 baseUrl 时默认是生产地址 `https://logs.revdog.org`：test key 不传 baseUrl 会出 `key_env_mismatch`。自定义主机不判环境。
- 同一（code, key, baseUrl）每进程只出一次（Dart 侧 isolate 内去重 + 垫片进程级去重）；消息是写死的英文句子，**不含 key 的任何部分**。
- 垫片不可用时退回 `print`：Android 在 logcat `I/flutter`，iOS 在 app 进程的 syslog `flutter: …` 行（没有 subsystem）。
- 边缘 / WAF / captive portal 代答的 401 / 403（没有 `reason`）不出 `key_rejected`（按普通失败退避）。

## 同意与清空

语义同 Android README「同意与清空」（ADR 0019 / 0020 / 0024）：

- **`setEnabled(false)` 跨重启有效**：落盘为 root 同级的空标记 `retriever.disabled`（Android `noBackupFilesDir/retriever.disabled`、iOS
  `Application Support/<bundle-id>.retriever.disabled`），直到 `setEnabled(true)`。禁用 = 不写、不传、不拉配置、不排后台作业，并取消已排的
  Android 作业。标记**判定不了**时按禁用处理（fail-closed），之后每次建会话成功、每次定时唤醒重判。标记写失败时内存照样禁用、稍后重试——
  **已撤回同意的宿主请在每次启动时、`configure` 之前调一次 `setEnabled(false)`**（幂等）。
- **`isEnabled`** = 显式值 ?? 标记（三态，1 s 缓存）；首触到 root 回包之前判定不了标记 = **false**。
- **撤回同意的完整组合** = `setEnabled(false)` + `await purgeLocal()` + `setUser(null)`（`purgeLocal` 不清用户、不改变启用状态）。
- **`await Retriever.purgeLocal()`**：Future 完成时本地已清空、`installId` 已是新值。清空 = root 先整个改名为同级的 `<root>.purge-<uuid>` 再删，
  中途被杀不会留下半个 root；启动时清掉残留。非 owner 引擎调用只删它自己的 pre 文件（不清 owner 的数据）。

## 宿主必须知道的纪律

- **只在 `main()` 里 configure**：先 `WidgetsFlutterBinding.ensureInitialized()`，再尽早 `await Retriever.configure(...)`；key 尽量同步可得。
  **不要**在后台入口（`@pragma('vm:entry-point')` 的 firebase_messaging / audio_service / local_notifications 回调）里 configure——
  先 configure 的引擎成为本进程的 owner，后台引擎抢到 owner 后主引擎的行要等进程死后才上传。
- **多引擎与 owner**：同一进程里只有 owner 引擎（首个完成 bootstrap 的引擎）有实例；别的引擎 configure 时系统日志出 `configure_ignored`，
  它们的行写自己的 pre 文件，**要等进程死后**由下一任 owner 收编上传（进程活着时 owner 不碰同进程别的引擎的 pre 文件）。只跑过后台引擎、
  从不 configure 的进程同理。owner 引擎销毁而进程还活着（Android `onDetachedFromEngine`；iOS 引擎对象释放时——只 `destroyContext` 而引擎对象
  一直被别处持有的，靠下一次任何引擎 bootstrap 时发现 owner 的 isolate 已失效）→ 已 configure 的其余引擎收到 `ownerReleased`（或回前台、或距上次
  ≥ 60 s 被触达）时重试接任，新 owner 把旧引擎的会话当死会话恢复。**同一进程里被销毁的引擎会话按 `clean_bg` 收尾、不合成 `rtv.unclean_exit`**
  （按会话 `meta.json` 的进程令牌认：Android 按返回键 `finish()`、iOS 换根 VC 都不是崩溃；真崩溃进程死、令牌必变）。
- **工作 isolate**（`Isolate.run` / `compute`）里调 SDK = no-op（行丢、不计数）；后台**引擎**（firebase_messaging 等）是根 isolate，照上面的 owner 规则走。
- **`flutter test` 下整个 SDK no-op**（`FLUTTER_TEST=true` 时在任何 channel 调用之前判：零 Timer、零文件、不抛，也不发 channel 调用——
  `testWidgets` 里未打桩的 channel 调用会挂到超时，所以必须在调用之前判）；web / 桌面同样 no-op。宿主单测里不用为 Retriever 打桩。
- **不与原生 SDK 混用**：同一 app 不要同时接 `retriever-android` / `retriever-ios` 与本包。root 同名（Android `noBackupFilesDir/retriever/`、
  iOS `Application Support/<bundle-id>.retriever/`，同原生 SDK）——两套引擎会同写一个目录；后台作业 id 默认同为 `0x5254`。本包的 init
  provider 换了 authority（`${applicationId}.revdog_retriever.init`）只是为了 manifest 合并不冲突、不被静默丢掉，不代表能共存。
  从原生 SDK **换成**本包可以：盘上布局相同，旧状态照读（install 不变、旧会话恢复、旧批原样上传）。
- **开发机切换环境**（staging ↔ 生产、换成另一个 app 的 key）：切换前先 `purgeLocal()` 或卸载重装。
- **iOS 上 `Process.killPid(pid, ProcessSignal.sigkill)` 对本进程返回 false**（dart:io 在 iOS 杀不了本进程）：要模拟「被系统杀」，示例 app 走原生
  `kill(getpid(), SIGKILL)`（`example/ios/Runner/AppDelegate.swift`）。
- **`log()` 落盘即返回**：每行一次同步 write（进程被杀不丢，真杀进程测试守着）；其余 I/O 都在异步任务里，重活（gzip、批解析、启动扫描）在
  `Isolate.run` 里做。`redact` 钩子在落盘前同步执行，钩子里调 `log()` 被忽略，抛异常则该行丢弃（宁丢不漏 PII）。
- **网络**：SDK 用自己的 `dart:io HttpClient`——不经宿主的 http / dio 拦截器、不经 `HttpOverrides.global`、**一律直连**（不读系统代理，
  也不读 `http_proxy` 等环境变量；原生 SDK 走系统代理）；超时 30 s、不跟随重定向、响应体最多读 64 KB；请求带 `Accept-Encoding: identity`。
  需要经代理才能出网的环境（企业 MDM 强制代理等）上传不了，本地照写。
- **目录**：不要自行清理；SDK 按容量（默认 20 MB，远程可调 2–100 MB）与 7 天驱逐。
- **后台兜底**（对位原生 SDK）：
  - Android：进后台时封段并就地排空；出站箱还有待传批时排一个一次性 JobScheduler 作业（id 默认 `0x5254`，`RetrieverOptions.jobId` 可改；
    网络约束、持久化，缺 `RECEIVE_BOOT_COMPLETED` 时退回非持久；同 id 已被别的组件占着则不替换、不取消——用 WorkManager 的宿主请把 `jobId`
    挪出它的 id 区间）。系统拉起作业时，进程里有 owner 引擎就经它的 channel 让 Dart 排空；进程是被作业冷启动、没有跑过 `main()`（没有 owner）→
    作业直接结束，不跑 headless Dart，批留到下次启动。`setEnabled(false)` 取消作业。网络恢复（API ≥ 24 默认网络回调）只用于提前唤醒。
  - iOS：进后台时垫片在通知回调里同步 `beginBackgroundTask`（只在有 owner 时、一次切换一个），Dart 排空结束后 end；系统收回时原生先
    end，再让 Dart 取消在途请求。iOS 没有作业，回前台时再排空。

## 平台与接入路径

- **Android**：纯 Java 垫片、不 apply Kotlin Gradle Plugin（Flutter 3.44 的 built-in Kotlin 迁移与它无关）；compileSdk 35、minSdk 21、Java 17。
  manifest 自动合并进宿主：`INTERNET`、`ACCESS_NETWORK_STATE`、`RECEIVE_BOOT_COMPLETED` 权限，`RetrieverUploadJobService`，`RetrieverInitProvider`
  （authority `${applicationId}.revdog_retriever.init`、`initOrder` 1000，在 `Application.onCreate` 之前注册进程级前后台 tracker、不做 I/O；宿主可用
  `tools:node="remove"` 去掉，之后在引擎 attach 时兜底注册、初值取进程重要性）。前后台按 Activity 身份计数（`AppLifecycleListener` 跟随单个
  Activity，宿主开原生 Activity 会误判，不用它）。
  **API 21–23 的退化**：没有默认网络回调（网络恢复不会提前唤醒，靠作业的网络约束与下次回前台）；认作业归属用 `getAllPendingJobs()` 逐个找
  （API 24 起用 `getPendingJob(id)`）。其余行为相同。
- **iOS**：Swift 垫片，最低 iOS **15.0**（宿主 app 的部署目标须 ≥ 15.0；CocoaPods 宿主的 Podfile 写 `platform :ios, '15.0'`）。两条接入路径同一份
  源码——**SwiftPM**（`ios/revdog_retriever/Package.swift`，依赖 `FlutterFramework`；宿主开了 SwiftPM 就走它，其余插件照走 CocoaPods）与
  **CocoaPods**（`ios/revdog_retriever.podspec`）。隐私清单随包（SwiftPM 资源 / CocoaPods `revdog_retriever_privacy.bundle`）。
  前后台只用 NotificationCenter（`UIApplication` 与 `UIScene` 两套通知），scene / sceneless 宿主都适用，宿主不需要为本包迁 UIScene。
  root 每次 root / bootstrap 都重设「不进 iCloud 备份」与 `completeUntilFirstUserAuthentication`。
- **Xcode 27 下的宿主壳**（任何 Flutter app 都一样，与本包无关；`docs/ops/pitfalls.md` C 节）：Apple 只接受 15.0 起的部署目标，而 Flutter 自己的
  `Flutter` pod 还写着 12.0 / 13.0——CocoaPods 宿主要在 Podfile 的 `post_install` 里把各 pod 的 `IPHONEOS_DEPLOYMENT_TARGET` 提到 15.0；
  Xcode 27 的 `lipo` 不再接受 `-verify_arch arm64 x86_64`，Flutter 给 generic 模拟器目标构建时在 thinFramework 一步失败（3.32.8 与 3.44.4 实测）——
  只给 Apple Silicon 模拟器构建的话在 `ios/Flutter/Debug.xcconfig` / `Release.xcconfig` 加 `ARCHS[sdk=iphonesimulator*] = arm64`。
- **Dart 入口**：pubspec 同时声明 `pluginClass`（原生）与 `dartPluginClass: RetrieverDartPlugin`（`src/plugin_entry.dart`），引擎在每个根
  isolate 跑入口之前注入平台工厂；宿主不需要任何手工注册。

## 示例 app（`example/`）

场景按钮 + 启动参数（`error` `user` `bulk` `crash` `flush` `fatal_storm` `preconfigure` `preconfigure_kill` `second_engine_*`），
key / baseUrl 经 `--dart-define-from-file=env.json` 注入（`env.json` gitignored，模板 `env.json.example`；空 key = 只写本地、出 `no_key`）。
用法、两端的启动命令与怎么看系统日志见 `example/README.md`。第二引擎、`finish()` / 换根 VC 在示例自己的原生代码里，不进生产垫片。
示例工程由 Flutter 3.44.4 模板生成（Android Gradle 9.1 / AGP 9.0.1；iOS 用 3.38 起的 `FlutterImplicitEngineDelegate` / `FlutterSceneDelegate`），
只能用 3.44 构建；旧版本的构建门禁用该版本 `flutter create` 的模板宿主（见「开发」）。

## 协议备注（与服务端 / 另两端对齐）

- 批格式、`batch_id`（UUIDv5）、请求头、映射确认、backfill 去重、会话终态与墓碑的携带规则、本地状态文件：全部同 Android README「协议备注」。
- 盘上布局 = Android 0.3.0（`packages/core/golden/layout-0.3.0.json` 守着），只多两处：pre 文件名是 `pre/<token>-<uuid>.jsonl`（同进程多引擎
  靠 token 区分「活着的别的引擎」与孤儿；Android 收编按 `*.jsonl` 认文件，前缀不影响格式）；`meta.json` 多一个可选键 `token`（本进程令牌，
  只用于「同进程死会话按 clean_bg 收尾」，孤儿收编出来的会话不带）。Android 0.3.0 读到这两处都按已有语义处理。
- `device_digest` 含 `sdk` 字段：同一 app 从原生 SDK 换成本包后映射重发一次（无害）。

## 与两端的平台差异

| | iOS 0.3.0 | Android 0.3.0 | Flutter 0.1.0 |
|---|---|---|---|
| 引擎 | Swift | Kotlin | 纯 Dart（主 isolate；重活 `Isolate.run`），原生只有薄垫片 |
| 目录 / 备份 | Application Support + isExcludedFromBackup + 保护类别 | `noBackupFilesDir` | 垫片给同一路径并设同样属性（与原生 SDK 同 root） |
| configure | 同步返回 | 同步返回 | `Future`，最多等垫片 5 s；首触到 root 回包这一拍只计数 |
| flush / purgeLocal | 回调 | 回调 | `Future`（purge 完成即清完） |
| 进后台 | `beginBackgroundTask` 包住排空 | 就地排空 + 一次性 JobScheduler 作业 | 两端各同原生；Android 作业只经 owner 引擎排空，冷进程无 owner 不跑 headless Dart |
| fatal | 只落盘，封段物化异步 | 同左 + 在调用线程上排作业 | 只落盘，不排作业 |
| 多实例 | 多进程（会话目录按进程名） | 同左 | 同进程多引擎：只有 owner 有实例，其余写 pre 文件、进程死后收编 |
| 同进程内被销毁的会话 | — | — | 按 `clean_bg` 收尾、不合成 `rtv.unclean_exit`（`meta.json` 的 `token`） |
| 会话锁 / 根级读改写锁 | 目录 fd 上 flock | `meta.json` 的 `FileChannel` 锁；`upload.lock` 第 2 字节区间 | `<sid>/lock` 专用文件；`upload.lock` 第 2 字节区间（每个临界区重新加锁、不缓存「已持有」） |
| 单调时钟 | `CLOCK_MONOTONIC` | `elapsedRealtime()`（含深睡眠） | 进程内 `Stopwatch`（Android 上不含深睡眠：退避可能拉长，放大型配置任一钟到期即回落） |
| 网络 | 专用 `URLSession`，走系统代理 | `HttpURLConnection`，走系统代理 | `dart:io HttpClient`，**直连** |
| 适配器 | swift-log / CocoaLumberjack / `RetrieverLogger` | Timber / `RetrieverLog` | `package:logger`（`RetrieverLogOutput` / `RetrieverLogger`） |
| 宿主单测 | — | JVM 单测会跑 `Application.onCreate` | `flutter test` 下整个 SDK no-op |
| 选项 | `appGroup`（暂不支持生产） | `jobId` | `jobId`（Android）；无 appGroup |

## 开发

```bash
scripts/sdk-flutter-gates.sh                 # 仓库根：三版本门禁（3.32.8 / 3.41.4 / 3.44.4），十几分钟；--keep-going 跑完全部再报
scripts/sdk-flutter-gates.sh --versions 3.44.4   # 只跑开发版本

cd sdk/flutter                               # 单项手跑（3.44.4）
~/fvm/versions/3.44.4/bin/flutter pub get
~/fvm/versions/3.44.4/bin/flutter analyze                 # 含 example/
~/fvm/versions/3.44.4/bin/dart format --set-exit-if-changed -o none .
~/fvm/versions/3.44.4/bin/dart test                       # 纯 Dart 引擎（假平台）；跨语言校验要仓库根 npm install 过
~/fvm/versions/3.44.4/bin/flutter test test/flutter/*.dart   # 通道打桩 / 插件入口（真 ChannelPlatform）
cd example/android && ./gradlew :revdog_retriever:testDebugUnitTest --no-build-cache --rerun-tasks   # Android 垫片 JUnit（先在 example 里 flutter build apk 一次）
cd example/ios && xcodebuild test -workspace Runner.xcworkspace -scheme Runner \
  -destination 'platform=iOS Simulator,name=<模拟器>' -only-testing:RunnerTests  # iOS 垫片 XCTest（先 flutter build ios --simulator 一次）
```

- **门禁脚本做什么**（`scripts/sdk-flutter-gates.sh` 文件头有全文）：每个版本 `pub get` → `analyze`（含 example）→ `format` → `dart test` →
  `flutter test test/flutter/*.dart` → `build apk` + `build ios --simulator`（3.44.4 = example、SwiftPM；3.32.8 / 3.41.4 = 该版本模板宿主 + example 的
  `lib/main.dart`、CocoaPods）→ 3.44.4 另跑 JUnit 与 XCTest；另查引擎纯度与版本号三处一致。分析、格式化和构建在工作目录里的**源码拷贝**上做
  （pub get 关 SwiftPM 时会改 example 的 xcconfig、生成 Podfile），`dart test` / `flutter test` 在位跑；跑完 `sdk/flutter` 的受控文件一个不变，
  `pubspec.lock` 回到 3.44.4 的状态。构建不带 `--dart-define-from-file`。
- **`flutter test` 只认 glob**：`test/flutter/` 下的文件故意不叫 `*_test.dart`——它们 import `flutter_test`（`dart:ui`），叫 `_test.dart` 的话纯
  `dart test` 会去编译它们而失败；只给目录 `flutter test test/flutter/` 找不到 `_test.dart` 文件、会退回跑整个 `test/`。
- **裸 `flutter test`（不带参数）不能当门禁**：它在 flutter_tester 里跑 `test/` 下的纯 Dart 用例，其中起子 Dart 进程的 11 个用例（真杀进程、多进程锁：
  `kill_test` 3、`preconfigure_kill_test` 5、`blind_review_fix_test.a1_sessionLockSurvivesAdoption`、`audit_fix_test` #8 / #9）失败——flutter_tester 下
  `Platform.resolvedExecutable` 是 flutter_tester，不按 `dart <script>` 执行（握手超时）。那些用例只在 `dart test`（独立 VM）下有意义。
- **工作 isolate**（`Isolate.run` / `compute`）里触达 SDK = unsupported（插件工厂对非根 isolate 抛异常，门面当作「没有平台」，行丢、不计数）。
  不提供「首次触达时惰性注入平台」的退路：插件入口由 `dartPluginClass` 在每个根 isolate 跑入口之前注入。
- **示例 iOS 构建的一条无害错误**：在本仓库里 `flutter build ios -v`（example）的详细输出里每次都有一条 “An error occurred when adding the plugin's Swift
  package to the Xcode project”（不带 `-v` 时不显示）。原因：flutter_tools 给插件自带的 example 工程加「本地插件包」引用时，Xcode 27 的 SwiftPM 按目录名认包——
  插件根目录在本仓库叫 `sdk/flutter`、包名是 `revdog_retriever`，对不上，flutter_tools 校验失败后自行回退，构建照常成功。这一步只对插件自带的
  example 做；宿主 app 不受影响（实测：以 git 依赖引用 split 提交的空宿主在 3.44.4 / Xcode 27 下 SwiftPM 构建通过，插件包引用的目录名是 pub 缓存的
  `<仓库名>-<sha>`，也 ≠ 包名，照样解析）。

## 发布

monorepo 是唯一开发源；公开仓库 `githubYiheng/retriever-flutter` 只读（`git subtree split --prefix=sdk/flutter` 推送，改动一律回 monorepo）。
不发 pub.dev（ADR 0006 / ADR 0007 D4）：宿主以 git tag 依赖（见「安装」）。

```bash
scripts/sdk-flutter-release.sh 0.1.0            # dry-run：六道门禁 + split + 泄漏检查 + 最小宿主 pub get + git push --dry-run
scripts/sdk-flutter-release.sh 0.1.0 --apply    # 推 retriever-flutter main + tag v0.1.0
```

- 六道门禁：CHANGELOG 有 `## 0.1.0 - <日期>` 条目；工作区干净；`scripts/sdk-flutter-gates.sh` 全绿；`RetrieverVersion.current` == pubspec `version`
  == 参数（且 `RetrieverOptions.sdkVersion` 默认引用它）；远端 main fast-forward；tag 不存在。
- split 树泄漏检查：不得含 `build/`、`.dart_tool/`、`pubspec.lock`、`Pods/`、`.symlinks/`、`xcuserdata/`、`ephemeral/`、`example/env.json`、
  `Generated.xcconfig` 等本地文件（xcconfig 只允许示例的 `Debug` / `Release` 两个模板）、`local.properties`、keystore、内部报告 `REPORT-slice*.md`，
  也不得有形如真 key 的串（明显假的随机段放行，只报文件名不打印值）。
- 最小宿主冒烟：`flutter create` 的空 app 以 git 依赖（本地临时 bare 仓库里的 split 提交、完整 sha 作 ref）引用本包，在 3.32.8 与 3.44.4 各
  `flutter pub get` 一次，核 `pubspec.lock` 的 `resolved-ref` 与版本、插件已登记。
- dry-run 把每一项都跑完、逐项报，最后有不过的就非零退出；`--apply` 遇到第一项不过就停、什么都不推。

升级规则：修订号 = 只修 bug；次版本 = 公开 API 只增；主版本 = 公开 API 有减或改，看 CHANGELOG 迁移说明。

## 隐私申报指引

### iOS（App Store 隐私清单与隐私标签）

本包随带 `PrivacyInfo.xcprivacy`（照 sdk/ios 的清单），宿主打包时 Xcode 自动汇总，不用抄进宿主清单：

- **收集的数据类型**：Device ID（install_id，随 app 数据容器的随机 ID）、User ID（`setUser` 的值）、Crash Data（fatal 行、`exc.stack`、
  `rtv.unclean_exit`）、Other Diagnostic Data（日志行、机型 / 系统版本 / locale / app 版本）；均关联用户、不用于跟踪，用途 App Functionality。
  宿主在 App Store Connect 填隐私标签时同步这四项；`msg` / `attrs` 里写了别的内容（搜索词、用户输入）的，按实际内容另报。
- **Required Reason API**：FileTimestamp `C617.1`（读自己写的段文件大小与修改时间，驱逐与 7 天孤儿判定）、DiskSpace `E174.1`
  （垫片 `volumeAvailableCapacityForImportantUsage`，写日志前查可用空间）。Dart 引擎编进宿主的 `App.framework`，它做的文件时间戳访问由本包的清单声明。
- 不做跟踪：`NSPrivacyTracking = false`、无跟踪域名。

### Google Play Data safety

表单由宿主开发者负责填写，Retriever 这一部分同 Android README「Google Play Data safety 申报指引」（定义取自 Play 官方
[Data safety 说明](https://support.google.com/googleplay/android-developer/answer/10787469)）：

- 「收集」= 数据从设备传出，**包括 app 内 SDK 传出的**；Retriever 后端由开发者自己运营（第三方 app 接入时是服务提供方），**共享：否**。

| Play 数据类型 | SDK 里的来源 | 收集 | 共享 | 用途 |
|---|---|---|---|---|
| 设备或其他 ID | `install_id`（随机 UUID，随 app 数据容器） | 是 | 否 | Analytics |
| 用户 ID | `setUser` 的值 | 调了才有 | 否 | Analytics（用于客服按人查询时加选 App functionality） |
| 崩溃日志 | fatal 行、`exc.stack`、`rtv.unclean_exit` | 是 | 否 | Analytics |
| 诊断 | 日志行、机型 / OS / locale / app 版本、墓碑 | 是 | 否 | Analytics |
| 其他（宿主判断） | `msg` / `attrs` 里写的内容：页面点击 → App interactions；搜索词 → In-app search history；自由文本 → Other user-generated content | 视宿主 | 否 | 同上 |

- **本地内容按「可能被收集」申报**：error 附带的上下文与远程按需全量（full_dump）能带走任何一行本地日志，所以保守申报。
- **可选 / 必需**：宿主用 `setEnabled` 做了同意开关的，可申报「可选」；否则「必需」。
- **传输加密：可勾**（默认 `https://logs.revdog.org`；宿主自己配 `http://` 的 baseUrl 就不能勾）。
- **可请求删除：有条件地勾**：服务端 30 天自动删除，`rtv user purge` / 查看台能按 user / install 清除；宿主要对外提供申请渠道（例如让用户报
  `supportCode`）才能勾。不适用「临时处理」豁免（数据保留 30 天）。

## 脱敏（宿主建议）

日志在落盘前经过 `RetrieverOptions.redact: LogLine? Function(LogLine)`（返回 null = 丢弃该行；configure 之前的行在收编时经过它，可能在 SDK 的
异步任务里被调，要快）。宿主自己的 URL、交易号、用户标识往往会出现在第三方 SDK 的错误文本里，建议在这里统一掩码，例如把
`/v1/subscribers/<id>` 与 `tx=<id>` 替换成 `<masked>`。Retriever 服务端不做二次脱敏，落盘的就是上传的。

```dart
LogLine? redact(LogLine l) => LogLine(
      ts: l.ts, level: l.level, tag: l.tag, attrs: l.attrs, exc: l.exc,
      msg: l.msg.replaceAll(RegExp(r'tx=[A-Za-z0-9]+'), 'tx=<masked>'),
    );
await Retriever.configure(key, options: RetrieverOptions(redact: redact));
```
