# Changelog

Retriever monorepo `sdk/flutter`（pub 包名 `revdog_retriever`；公开只读镜像 `githubYiheng/retriever-flutter`，宿主以 git tag 依赖，不发 pub.dev）。
版本号遵循语义化版本：修订号 = 只修 bug；次版本 = 公开 API 只增；主版本 = 公开 API 有减或改。Flutter SDK 的版本号独立于原生 SDK；
协议、盘上布局与行为对位原生 SDK 0.3.0。条目标题写成 `## X.Y.Z - 日期`（`test/version_test.dart` 与发布脚本都按它找版本）。

## 0.1.0 - 2026-10-10

首个版本（ADR 0026「Flutter 对位 0.3.0」）：纯 Dart 传输层引擎 + 极薄原生垫片（Android 纯 Java / iOS Swift）+ `package:logger` 适配器。
行为、字段、顺序、数字与 Android / iOS `0.3.0` 逐字一致，只在平台层不同（README「与两端的平台差异」）。
约束 `sdk: ^3.8.0`、`flutter: >=3.32.0`；门禁 Flutter 3.32.8 / 3.41.4 / 3.44.4（`scripts/sdk-flutter-gates.sh`）。

### 接入（宿主请看）
- 依赖：`revdog_retriever: {git: {url: https://github.com/githubYiheng/retriever-flutter.git, ref: v0.1.0}}`。
- `main()` 里先 `WidgetsFlutterBinding.ensureInitialized()`，再尽早 `await Retriever.configure(...)`；**不要**在后台入口
  （`@pragma('vm:entry-point')` 的 firebase_messaging / audio_service / local_notifications 回调）里 configure。
- iOS 宿主部署目标 ≥ 15.0（SwiftPM 与 CocoaPods 都支持）；Android minSdk 21 起（API 24 以下少两项能力，见 README）。
- 同一 app 不要同时接原生 SDK（`retriever-ios` / `retriever-android`）与本包。开发机切换环境前先 `purgeLocal()` 或卸载重装。

### 公开面
- 静态入口 `Retriever`：`configure(key, {baseUrl, options})` → `Future<void>`（有界完成：最多等垫片 5 s）/ `setUser` /
  `log(level, msg, {tag, attrs, error, stackTrace})` / `flush({includeContext = true})` → `Future<FlushResult>` / `uploadLevel` /
  `localLevel` / `setEnabled` / `isEnabled` / `purgeLocal()` → `Future<void>`（清完才完成，完成时 `installId` 已是新值）/ `installId` /
  `supportCode`。值类型 `LogLevel`、`RetrieverOptions`（不可变：`const` 构造 + `copyWith`，可空字段用哨兵参数改回 null）、
  `FlushResult`（`FlushStored` / `FlushPending(reason)`）、`LogLine`、`LogException`、`RedactHook`、`RetrieverVersion`。三端同名同语义，
  签名差异（Future 代替回调、无 appGroup）见 README。
- `package:revdog_retriever/logger.dart`：`RetrieverLogOutput`（加进宿主现有的 `MultiOutput`）与 `RetrieverLogger`（默认 `ProductionFilter`）。

### 与原生 SDK 0.3.0 对位的行为（同一组 golden 向量与 `validate-envelope.ts` 跨语言校验守着）
- 批格式、对象键、信封、请求头；出站队列、退避与暂停（鉴权暂停 1 h 起倍增到 24 h）、413 切分；配置钳制与 `from_host`（ADR 0022），
  配置请求的身份 = install + user + 四项宿主默认 + key 指纹 + baseUrl，在途身份变了丢弃重拉。
- **configure 之前没有实例**（ADR 0023）：之前的 `log()` 一次 write 追加到 `pre/<token>-<uuid>.jsonl`，`configure` 时按**本次** configure 的
  设定收编（过 redact、判上传义务、分 seq / oseq、error 去抖 / fatal 换段 / 用户边界照常），行 ts 保持写入时刻；上限 1 MB；
  configure 之前进程就死 → 之后某次 owner configure 时作为独立会话收编。configure 之前其它入口同 Android 0.3.0。
- 实例身份只认首次 `configure`（之后改 `processName` → 忽略并留 `rtv.reconfigure_ignored`）；参数完全相同的重复 `configure` 只更新 redact、零请求；
  再次 configure 改的级别同步生效。
- **没落盘必计数**：超 1 MB / 写失败 / 没有会话 / 内部异常的行一律计数，有可写会话后写 `rtv.pre_init_dropped`（`count` / `error_count` /
  `first_ts` / `last_ts`）；`meta.json` 写不成 = 建会话失败；段读失败不推进游标；root 在运行中被删 → 重建会话 + `rtv.root_vanished`。
- **不抛、不崩宿主**：公开入口整体 `try / catch`；attrs / 异常逐值防护（`toString` 抛、循环引用、并发修改 → `"<unprintable>"` + `truncated`）；
  List / Set / Map 渲染紧凑 JSON；绝对值 > 2^53 − 1 的整数输出十进制字符串；SDK 内未等待的 Future、Timer、流订阅的错误一律吞掉，
  不落到宿主的 Zone / `PlatformDispatcher.onError`（Crashlytics 不会因此记致命崩溃）。
- **同意 fail-closed**：禁用标记三态，判定不了 = 禁用；`setEnabled(false)` 跨重启有效并取消后台作业；撤回同意 = `setEnabled(false)` +
  `purgeLocal()` + `setUser(null)`。
- 换 key 不带旧账（key 指纹）；fatal 10 s 节流、等待中的 flush 合并；`install.json` 损坏时 `rtv.install_repaired` / `rtv.install_reset`；
  启动恢复对前台死亡的会话合成 `rtv.unclean_exit` 并带上下文补传。
- **配置诊断**（ADR 0025）：`no_key` / `key_trimmed` / `key_malformed` / `key_env_mismatch` / `base_url_invalid` / `key_rejected`，文案与原生逐字相同，
  经垫片写系统日志（Android logcat tag `Retriever`；iOS `os.Logger` subsystem `org.revdog.retriever`、category `diagnostics`）；
  同一（code, key, baseUrl）每进程一次；消息不含 key。只出诊断、不拦请求、不停写本地。
- 盘上布局 = Android 0.3.0（`layout-0.3.0.json` golden 守着）：同一 app 从原生 SDK 换成本包能读回旧状态（install 不变、旧会话恢复、
  旧批原样上传、暂停与禁用标记延续）。`device_digest` 含 `sdk`，换 SDK 后映射重发一次（无害）。`device.sdk` / `X-Rtv-Sdk` = `retriever-flutter/0.1.0`。

### Flutter 专有
- **owner 引擎**：同一进程里只有首个完成 bootstrap 的 Flutter 引擎（owner）有实例。别的引擎 `configure` 时出诊断 `configure_ignored`
  （`configure ignored: another engine owns Retriever in this process`，warn 级），它们的行写各自的 pre 文件，**进程死后**由下一任 owner 当孤儿
  收编上传（无前后台记录，不合成 `rtv.unclean_exit`）。owner 引擎销毁而进程仍活（Android `onDetachedFromEngine`；iOS 引擎对象释放，另在
  任何引擎 bootstrap 时发现 owner 引擎已 nil / isolate 变了也算释放）→ 其余已 configure 的引擎在 `ownerReleased`、回前台或距上次 ≥ 60 s
  被触达时重试接任，新 owner 把旧引擎的会话当死会话恢复。
- **事件与回包的竞态**：3.38 起平台线程与 UI 线程合一，原生发来的事件可能先于排队的 `bootstrap()` 回包到达。bootstrapping 期间收到的
  `ownerReleased` / `willEnterForeground` 不丢，回包为非 owner 时立即重试（门面单测 + 真 channel 用例确定性覆盖）。
- **同进程死会话不算崩溃**：`meta.json` 加可选键 `token`（本进程令牌）。恢复时 `meta.token` 等于当前令牌、且最后状态是前台的会话按
  `clean_bg` 收尾、不合成 `rtv.unclean_exit`——引擎在进程内被销毁（Android 按返回键 `finish()`、iOS 换根 VC）从不是崩溃。真崩溃进程死、
  令牌必变，照常 `unclean_fg` + 合成行。孤儿收编出来的会话不带该键；Android 0.3.0 不写该键 = 旧语义。
- `configure` 返回 `Future`（等垫片最多 5 s，超时照样完成，之后的触达再重试）；首触到垫片 `root()` 回包这一拍的行只计数，`isEnabled`
  在这之前为 false。
- **上传直连**：SDK 自己的 `dart:io HttpClient`——不经宿主的 http / dio 拦截器、不经 `HttpOverrides.global`、不读系统代理与 `http_proxy`
  等环境变量（原生 SDK 走系统代理）；超时 30 s、不跟随重定向、响应体最多读 64 KB；请求带 `Accept-Encoding: identity`，中间盒仍压缩时自动解压。
- **no-op 场合**：宿主 `flutter test`（`FLUTTER_TEST=true`，在任何 channel 调用之前判）、web、桌面、工作 isolate（`Isolate.run` / `compute`）
  里整个 SDK no-op——零 Timer、零文件、零 channel 调用、不抛；工作 isolate 的行不落盘、不计数。
- fatal 不排后台作业（Dart 不能同步调原生）：只写行并换段，封段物化在异步任务里做；进程随后死亡的话，下次启动的恢复把这一行物化成
  同一个 batch_id 的批。`log()` 在主 isolate 上一次同步 write；gzip、整批解析、启动扫描在 `Isolate.run` 里做。
- **Android 垫片**（纯 Java，不 apply Kotlin 插件；minSdk 21）：init provider（authority `${applicationId}.revdog_retriever.init`、
  `initOrder` 1000）在 `Application.onCreate` 之前装进程级前后台 tracker（按 Activity 身份计数）；进后台有待传批时排一次性 JobScheduler 作业
  （id 默认 `0x5254`，`RetrieverOptions.jobId` 可改；同 id 是别人的作业不碰），作业经 owner 引擎的 channel 让 Dart 排空，冷进程没有 owner
  时作业直接结束、不跑 headless Dart；API ≥ 24 的默认网络回调只用于提前唤醒。
- **iOS 垫片**（Swift，iOS 15.0+，SwiftPM `ios/revdog_retriever/Package.swift` 与 CocoaPods `ios/revdog_retriever.podspec` 同一份源码）：
  进后台时在通知回调里同步 `beginBackgroundTask`（只在有 owner 时、一次切换一个），Dart 排空后 end；系统收回时原生先 end，再让 Dart
  取消在途请求。前后台只用 NotificationCenter（`UIApplication` 与 `UIScene` 两套通知），scene / sceneless 宿主都适用。隐私清单随包。

### 已知限制
- 非 owner 引擎的行、只跑过后台引擎（从不 configure）的进程留下的行，要等进程死后由下一任 owner 收编才上传（宪法 §3 例外）。
- 同进程多 isolate 之间没有锁互斥（owner 交接的重叠窗口）；首触到 `root()` 回包这一拍的计数只在内存，进程先死则丢（R-1 例外）。
- iOS 上 `Process.killPid(pid, ProcessSignal.sigkill)` 对本进程返回 false（dart:io 杀不了本进程）。
