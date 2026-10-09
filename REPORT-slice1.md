# M4 切片 1 完成报告（纯 Dart 引擎 + `dart test`）

> 实现子代理 2026-10-09。范围：`sdk/flutter/**`（未碰其它目录；未 git、未联网上传、未打 staging）。
> 依据：`docs/plan/m4-slice1-brief.md` → v3 → v2 → `sdk-0.3.0-brief.md` → 方案 §3 → Android 0.3.0 源码与测试；主代理中途口径更新 4 条已落实（见 §6）。

## 1. 结果

| 门禁 | 3.44.4（Dart 3.12.2，开发版本） | 3.41.4（Dart 3.11.1） | 3.32.8（Dart 3.8.1） |
|---|---|---|---|
| `flutter pub get` | ✅ test 1.31.0 / test_api 0.7.11 / flutter_test = SDK | ✅ test 1.30.0 / test_api 0.7.10 | ✅ test 1.25.15 / test_api 0.7.4 |
| 其余解析 | logger 2.8.0、crypto 3.0.7、flutter_lints 6.0.0、meta 1.18.0、clock 1.1.2 | 同左（meta 1.17.0） | 同左（meta 1.16.0） |
| `dart analyze` | No issues found | No issues found | No issues found（修了两处只有 3.8 analyzer 报的：`(_, __)`、文件头 `// Dart …` 被当成语言版本注释） |
| `dart format --set-exit-if-changed .` | 0 changed | 0 changed | 0 changed（三个版本的格式化结果一致） |
| `dart test` | **265 / 265 通过，0 跳过**（≈ 9 s） | 265 / 265 | 265 / 265 |

3.44.4 上连跑 5 遍全绿（无抖动）。最终命令输出尾部：

```
$ ~/fvm/versions/3.44.4/bin/dart analyze
Analyzing flutter...
No issues found!
$ ~/fvm/versions/3.44.4/bin/dart format --set-exit-if-changed .
Formatted 65 files (0 changed) in 0.13 seconds.
(exit 0)
$ ~/fvm/versions/3.44.4/bin/dart test -r expanded
00:07 +262: test/flutter_specific_test.dart: 非 owner ownerReleasedTakeover
00:07 +263: test/flutter_specific_test.dart: concurrentConfigureAndCallsDuringBootstrap
00:07 +264: test/flutter_specific_test.dart: eventLoopLagDuringStartupRecovery
[lag] fixture: outbox=21638 KB, ring=33225 KB
[lag] startup recovery 319 ms, ticks=318, max lag=1 ms, p99 lag=0 ms
[lag] outbox after recovery: 24818 KB
00:08 +265: All tests passed!
```

信息性数字（宿主机 JIT）：`log()` 1 万次 p50 = 4 µs、p99 = 20 µs、max = 305 µs；滞后探针（21 MB 出站箱 + 33 MB 本地环 + 崩溃时未物化的 ≈ 4 MB 义务行）
启动恢复 ≈ 320 ms，1 ms 周期 Timer 最大滞后 1–2 ms（门槛 50 ms）；`validate-envelope.ts` 9 种批全过
（pure_warn / error_ctx_cross_segment_truncated / recovered_with_drops_closed / recovered_unclean_exit / with_mapping / split_413_a / split_413_b / backfill / fatal）。

**`Isolate.run` 在 `dart test` 下可用**：实测 worker 的 `Isolate.current.debugName` 与主 isolate 不同（真起了 isolate，不是退回同步）。使用位置（闭包只捕获字节 / 路径，
不捕获任何持文件句柄的对象；`Isolate.run` 抛错一律退回当前 isolate 分片做）：
- `gzip.dart` `Gzip.compressOffMain`（← `materializer.dart` 写批，**所有批**）、`Gzip.decompressOffMain`（备用，当前无调用方）；
- `outbox.dart` `loadMetasOffMain`（启动扫描 / 对账，整批读 + 解压 + 解析，只回 `BatchMeta`）、`parseBatchFileOffMain`（413 切分读批）。

## 2. 做了什么

- `lib/src/` 32 个文件 + `lib/logger.dart` + `lib/revdog_retriever.dart`（合计 ≈ 11.3 k 行）：Android 0.3.0 `core/**` + `Retriever.kt` / `PublicApi.kt` / `ConfigDiagnostics.kt` 逐文件、逐函数对位到纯 Dart；
  另有 Flutter 专有的 `transport.dart`（`HttpClient`）、`clock.dart`、`platform.dart`（v3 §3 契约的抽象）、`adapter_bridge*.dart`、`retriever_stub.dart`（web）。
- `lib/logger.dart`：`RetrieverLogOutput` + `RetrieverLogger`（v2 §4 全部规则）。
- `test/` 29 个测试文件 + `test/support/support.dart`（FakeClock / FakeTransport（内存，同 Android）/ FakeServer（真 `HttpServer`，同一份回复脚本）/ FakePlatform
  （root / bootstrap 的 ok / hang / fail / unsupported、owner / foreground、bootstrap 闸门、其余调用失败或同步抛）/ Harness（默认**经静态入口** `Retriever.configure` 建，
  `direct: true` 才直接构造）/ StaticHarness / validator 调用 / 子进程助手），`tool/kill_helper.dart`（子 Dart 进程写行后自发 SIGKILL）。
- README 骨架、CHANGELOG 0.1.0 骨架、LICENSE（照 `sdk/android/LICENSE`）。`pubspec.yaml` 已声明 `flutter.plugin.platforms`（android `org.revdog.retriever.flutter` /
  `RetrieverPlugin`，ios `RetrieverPlugin`）。

## 3. 文件对位（Android `sdk/android/retriever/src/main/kotlin/org/revdog/retriever/` → Dart `sdk/flutter/lib/`）

| Android | Dart | 备注 |
|---|---|---|
| `core/Limits.kt` | `src/limits.dart` | 常量逐字；另加 Flutter 的 channel 超时（5 s / 2 s）、root 重试间隔、标记缓存 1 s、响应体 64 KB |
| `core/Model.kt` | `src/model.dart` | 全部模型；`meta.json` 可选键 `pre`；`SessionMeta.isPreName` 认 42 字符（Android）与 79 字符（`<token>-<uuid>`）两种 |
| `core/Json.kt` | `src/json.dart` | 紧凑编码（键序、数字格式逐字节，golden 守）、按位置解析 |
| `core/LineEncoder.kt` | `src/line_encoder.dart` | 截断顺序、attrs 逐值防护、集合 / Map 紧凑 JSON、32 键、大整数（int / BigInt）转字符串 |
| `core/Text.kt` | `src/text.dart` | UTF-16 孤立代理按 U+FFFD 计 |
| `core/Ids.kt` | `src/ids.dart` | UUIDv4 / v5（`crypto` SHA-1）、设备摘要、key 指纹、CRC-32、supportCode、Day |
| `core/Gzip.kt` | `src/gzip.dart` | 严格解压（头解析 + CRC32 / ISIZE 校验）；`*OffMain` 走 `Isolate.run` |
| `core/Fs.kt` | `src/fs.dart` | 原子写、`LockRegistry`（isolate 内每文件一个句柄、按区间记持有者）、`RootLocks`（[0,1) 上传者、[1,2) 根级读改写：异步互斥 + Zone 重入 + 轮询 `lockSync`）、`SessionLock`、测试故障钩子 |
| `core/Pre.kt` | `src/pre.dart`、`src/drop_counter.dart`、`src/markers.dart`、`src/root_purge.dart` | PreFile / PreLog / PreRecords / OrphanPre；文件名 `pre/<token>-<uuid>.jsonl` |
| `core/Adoption.kt` | `src/adoption.dart` | 本进程收编 + 孤儿收编（token 等于自己的跳过、不打开） |
| `core/Writer.kt` | `src/writer.dart` | 主 isolate 同步写；收编中状态；fatal 节流；用户边界；写失败 `truncateSync` + `setPositionSync` 回滚 |
| `core/Segments.kt` | `src/segments.dart` | 段状态机 |
| `core/Materializer.kt` | `src/materializer.dart` | 物化、ctx、backfill；片段之间让出 |
| `core/Outbox.kt` | `src/outbox.dart` | 对账、启动扫描、隔离 / 放回、413 切分、驱逐（pre 计入、7 天孤儿） |
| `core/Uploader.kt` | `src/uploader.dart` | 排空步进、响应分类、退避 / 暂停、回显校验、换 key、拉配置 |
| `core/Recovery.kt` | `src/recovery.dart` | 启动恢复、unclean_exit、`meta.pre` 未提交重做 |
| `core/Config.kt`、`core/ConfigCheck.kt` | `src/config.dart`、`src/config_check.dart` | `from_host`、钳制、身份；六个 code，baseUrl 用 `Uri.tryParse` |
| `ConfigDiagnostics.kt` | `src/config_diagnostics.dart` | 消息逐字；isolate 内去重；默认 sink = `platform.diagnose`（2 s 超时，失败退回 `print`）；可替换 sink |
| `core/Platform.kt` | `src/platform.dart`、`src/transport.dart`、`src/clock.dart` | 抽象 `RetrieverPlatform`（v3 §3 全部方法 + 事件回调 `PlatformEventHandler`）；`HttpClientTransport`（K5）；`SystemClock` |
| `core/Engine.kt` | `src/engine.dart` | 引擎状态与操作（bootstrap / 封段处理 / 墓碑 / 读段 / 可用空间 2 s 超时） |
| `core/Client.kt` | `src/client.dart` | `SerialQueue`（Future 链 + Zone 标记重入）、实例、生命周期事件（含 iOS 的 `foregroundStateChanged` / `backgroundTaskExpired` / `endBackgroundTask`）、flush 合并与原因映射、调度器 |
| `Retriever.kt` | `src/retriever.dart`（真实现）、`src/retriever_stub.dart`（web） | K1 状态机、`RetrieverRuntime`（不导出）、pre 期入口、非 owner 入口 |
| `PublicApi.kt` | `src/public_api.dart` | 值类型；`RetrieverOptions` 不可变 + 哨兵 `copyWith`；`RetrieverVersion.current = '0.1.0'` |
| `RetrieverLog.kt` | `lib/logger.dart` + `src/adapter_bridge*.dart` | 不对位；Flutter 用 `package:logger` 适配器 |
| `android/AndroidPlatform.kt`、`android/Lifecycle.kt`、`RetrieverInitProvider.kt`、`RetrieverUploadJobService.kt` | —（切片 2 的 `channel_platform.dart` + 原生垫片） | 本切片不写 |

## 4. 测试对位（Android `src/test/kotlin/org/revdog/retriever/` → `sdk/flutter/test/`）

规则：**用例名逐字相同的一一对位**；下表只列差异。Android 232 个用例；Dart 265 个（对位 222 + Flutter 专有 43）。

| Android（数） | Dart（数） | 差异 |
|---|---|---|
| GoldenTests (12) | golden_test (12) | `versionMatchesGradle` → `version_test.versionMatchesPubspecAndChangelog`；新增 `flutterAmplifyingFieldsExpireOnEitherClock`（放大型字段任一钟到期回落） |
| EnvelopeCrossLangTests (1) | envelope_crosslang_test (1) | 同（`npx --no-install tsx packages/core/scripts/validate-envelope.ts`，9 种批） |
| GzipTests (2) | gzip_test (2) | 同 |
| WriteDisciplineTests (11) | write_discipline_test (11) | `strictModeAllowanceWrapsEveryWrite` 不对位（无 StrictMode）→ 换成 `partialWriteRollbackLeavesNoZeroHole`（Dart append 无 O_APPEND） |
| SegmentTests (12) / TruncationTests (11) / QueueTests (17) / EvictionTests (10) / ConfigTests (5) / FromHostTests (5) / StateOwnershipTests (12) / MultiProcessTests (5) / KillTests (4) / PreconfigureKillTests (5) / LayoutAndPerfTests (2) | 同名文件，同数 | 全部同名对位；真杀 = 子 Dart 进程 `Process.killPid(pid, sigkill)`（退出码 −9） |
| ConfigDiagnosticsTests (10) | config_diagnostics_test (11) | 新增 `v10_defaultSinkGoesThroughPlatformDiagnose` |
| HardeningTests (13) | hardening_test (12) | `t_jobOwnership` / `t_lifecycleTracker` 按 v3 不对位（JobGate / tracker 在原生垫片，切片 2 的 JUnit）；新增 `t_jobConflictReportedOnce`（实例侧那一半） |
| HostSafetyTests (14) | host_safety_test (13) | `fatalArmsJobOnCallerThread` 按 v3 不对位（Flutter fatal 不排作业）；`disableCancelsJob` 断言假平台收到 `cancelUploadJob` |
| NeverThrowTests (4) | never_throw_test (3) | `o_nullArgumentsNeverThrow` → `o_degenerateArgumentsNeverThrow`（Dart 参数非空，改测 root 未回包、空 key、空 msg、缺省 baseUrl、全空可选参数）；`o_callbacksThatThrow…` → `o_futuresAlwaysComplete`（没有回调）；`o_retrieverLogSwallowsThrowables` 不对位（`RetrieverLog`；适配器的同义用例在 logger_adapter_test） |
| BlindReviewFixTests (22) | blind_review_fix_test (21) | `a7_y1` → `a7_y1_logDuringConfigureWrittenAndAdopted`（configure 是异步的，那一刻处于 bootstrapping，行写 pre、随后收编，不计数）；`a7_y2` → `a7_y2_fatalDuringAdoptionAllWritten`（行都在、0 次作业）；`b6_a4_nullLevel…` → `b6_a4_countReportedOnceAtTick`（没有 null level）；`a7_y10` 不对位（tracker 回调兜异常 → 切片 2 的 Java 垫片） |
| PrereleaseRegressionTests (14) | prerelease_regression_test (13) | `stackTextKeepsUnknownHostAndTerminatesOnCycles` + `stackOfNetworkErrorReachesExc`（JVM Throwable 链 / cause 环）→ `stackOfDartErrorReachesExc`（Dart 错误没有 cause 链） |
| PreconfigureTests (24) | preconfigure_test (24) | `g_writeFailureNoContextAndDisabled` → `g_writeFailureNoRootAndDisabled`（Flutter 没有 context，对应「root 未回包」） |
| LifecycleTests (8) | lifecycle_test (11) | `fatalSchedulesJobWithCustomId` → `fatalSealsWithoutSchedulingJob`；新增 `backgroundTaskEndedAfterDrainAndExpiryCancelsInFlight`、`foregroundStateChangedOnlyWritesLastState`、`nullForegroundLeavesLastStateEmpty` |
| UpgradeTests (4) | layout_compat_test (5) | 0.1 / 0.2 升级不适用（Flutter 无旧版）；改为读 Android 0.3.0 真跑导出的 `layout-0.3.0.json`：`sameKeyContinuesPauseAndRecoversOldSession`、`newKeyResetsPauseAndUploadsBytesVerbatim`、`mappingWithin24hNotResent`、`disabledMarkerHonored`、`goldenFilesDecode` |
| LayoutExportTests (1) | — | 导出器（主代理生成 golden 用），不对位 |
| RetrieverLogTests (4) | — | `RetrieverLog` 不对位；Flutter 侧是 logger_adapter_test |
| — | logger_adapter_test (12) | v2 §4 逐条：级别映射（含 all / off / verbose / wtf 落点）、读 origin 不读 lines、Function / Map / Iterable 照 printer 转字符串、`origin.time` → ts、error / stack → exc、低于 localLevel 在求值前丢、output 自己 catch 并计数（零 print、零外泄）、工厂默认 ProductionFilter + 控制台 / Retriever 两路、宿主 MultiOutput 接法、空 printer 不调 output、configure 之前进 pre 且 ts 保持、unsupported no-op |
| — | flutter_specific_test (10) | v3 §6 清单：bootstrap 永不回包（5 s 后完成、≥ 5 s 后重试并收编）/ 平台异常 / 插件缺失；unsupported 终态零 Timer 零文件零 channel 调用；宿主判定（`FLUTTER_TEST` / 非 Android-iOS，默认工厂不被调用）；runZonedGuarded 零外泄（channel 调用异步失败与同步抛各一轮）；非 owner 全部入口；`ownerReleased` 接任（旧 owner 会话按死会话恢复）；并发 configure + bootstrapping 窗口里的 setUser / setEnabled / purge / flush；事件循环滞后探针 |
| — | transport_test (8) | 真 `HttpClientTransport` 对本地 `HttpServer`：请求头与字节原样、无默认 UA、不跟随重定向、64 KB 上限、网络错误 / 拒连 / 非法 URL → null、cancelAll、整体超时、**不吃宿主 `HttpOverrides.global`（含代理查找）**、静态入口端到端 flush → stored |
| — | purity_test (5) / version_test (3) | lib/src 无 flutter / dart:ui；条件导入只用 `dart.library.io`；logger.dart 只经桥；无 `HttpOverrides.runZoned`；切片 1 不含 channel_platform / ios / android / example；版本 == pubspec == CHANGELOG，`retriever-flutter/0.1.0` 进 device / 请求头 / pre 头 |

## 5. 偏离简报的地方（及原因）

1. **物化**：简报写「> 256 KB 的 JSON 与 gzip 用 `Isolate.run`」。现状：批 JSON 在主 isolate 分片拼（片段之间让出），**gzip 一律** `Isolate.run`（不按大小分流）。
   理由：拼 JSON 要读引擎内存里的行，搬进 worker 得整份复制；gzip 是唯一的大块 CPU。滞后探针 max 1–2 ms 支持这个划分。
2. **主 isolate 上的同步 IO 不止 `writeFromSync`**：pre 文件创建（`openSync` + `lockSync`）、段轮转时开新段（`openSync`）在 `log()` 调用栈里同步做；
   收编自己的 pre 文件用**同一句柄**分块同步读（另开 fd 再关会释放本进程在该文件上的 fcntl 锁）。理由：R-1「返回前一次 write」要求文件此刻就在。
3. **`root()` 回包多带可选 `process` / `device`**（v3 §3 只有 `{root, token}`）：pre 文件头记录要进程名与设备字段（对位 Android `PreRecords.header`）。缺省时进程名按 `main`、设备字段为空。
4. **`HttpClient` 显式 `findProxy = DIRECT`**（v3 K5 只说 `_PlainOverrides().createHttpClient(null)`）：实测仅此不够——`HttpClient` 不设 `findProxy` 时默认是
   `HttpClient.findProxyFromEnvironment`，它读 `http_proxy` 等环境变量**并经 `HttpOverrides.current.findProxyFromEnvironment`**，宿主的 `HttpOverrides.global` 从这里漏进来
   （Dart 3.12.2 `sdk/lib/_http/http_impl.dart:2790`、`http.dart:1634`；`transport_test.ignoresHostHttpOverridesGlobal` 不加 DIRECT 时失败）。
   这也更正核实文档 `2026-10-09-flutter-plugin-facts-refresh.md` §9「不设 findProxy 就总是直连」：API 文档那句话与源码不符。
5. **`RetrieverLogger` 多一个公开字段 `effectiveFilter`**（只读）：为了能断言「默认 ProductionFilter」（logger 的 `Logger` 不暴露 filter）。
6. **pre 文件权限**：Android 建 pre 文件时设 0600；`dart:io` 没有改权限的 API，未做（app 私有目录本来只有本 uid 可读写）。
7. **gzip 解压上限**：先 `gzip.decode` 整体解出再比 64 MB 上限（Android 是流式边解边比）。只解自己写的批，风险低；要流式可改 `ZLibDecoder` 分块。
8. 简报 §4 说假服务端「对位 `TestSupport.kt` 的 FakeServer（本地 HttpServer）」：Android 的 TestSupport 实际是内存 `FakeTransport`。现状两者都有、共用一份回复脚本：
   默认内存（同 Android），真 `HttpServer` 只在 transport_test 用。未建 `test/fixtures/`（golden 直接读 `packages/core/golden/`）。
9. **本轮自查修掉的一个口径错误**：非 owner 状态下每次 `log()` / `setUser()` 都会重试 bootstrap（Android 无此态，v3 §4 只许 `ownerReleased` / 回前台重试）。已改：非 owner 只在 force（`ownerReleased` / 回前台）时重试；显式再次 `configure` 照常重新 bootstrap。

## 6. 主代理中途口径更新的落实

1. `FLUTTER_TEST`：`RetrieverRuntime.touch()` 在调默认平台工厂（即任何 channel 调用）之前判 `hostUnsupported(Platform.environment, Platform.operatingSystem)`
   （`FLUTTER_TEST == 'true'` 或非 Android / iOS → unsupported 终态）；测试注入的 `platformFactory` 不做此判定。插件缺失（`PlatformUnsupportedException`）路径保留。
2. 根 isolate 判定：纯 Dart 门面不 import flutter；`RetrieverRuntime.defaultPlatformFactory` 的文档写明由切片 2 的注入工厂判 `RootIsolateToken.instance`（见 §7 第 9 条）。
3. 锁不缓存「已持有」：`upload.lock` [0,1) 每次 `nextSend` 都重新 `lockSync`、排空结束 `unlock`；[1,2) 每个根级读改写临界区重新 `lockSync`、结束即 `unlock`；
   isolate 内异步互斥 + Zone 重入保留；`LockRegistry.tryLock` 即使本对象已持有也重新 `lockSync`。
4. `HttpClient`：`class _PlainHttpOverrides extends HttpOverrides {}` → `createHttpClient(null)`，不用 `runZoned`；另见 §5 第 4 条（DIRECT）。web 条件导入只用 `dart.library.io`（purity_test 守）。

## 7. 需要主代理定（现状做法 / 备选）

1. **`root()` 回包字段**：现状 `{root, token, process?, device?}`（§5-3）。备选：只 `{root, token}`，pre 头里进程名写 `main`、设备留空，收编时用 bootstrap 的设备字段补。
2. **非 owner 诊断的 code**：`diagnose(code, message)` 的 code 现状 `configure_ignored`（消息逐字 v3 §4）。备选：空串 / 别的名字；垫片按 code 选日志级别时要一致。
3. **`configure` 的 Future 何时完成**：现状 = 实例已发布 + `start()` 已排进引擎队列（不等收编 / 启动恢复做完；之后的 `log()` 按序排在后面）。备选：等收编完成（configure 变慢，宿主 `await` 卡启动）。
4. **非 owner 之外的「未确认身份」状态下的 `purgeLocal`**：`none` / `failed` 态照 Android 改名清整个 root——同进程另一个引擎若是 owner，会被清掉数据。
   v3 只规定了 `nonOwner`。备选：`failed` 态也只删自己的 pre 文件；或排到下一次 bootstrap 之后。
5. **会话锁 / 自己 pre 文件的锁是「存活期一直持有」**，不像上传锁 / 根锁那样每个临界区重锁（它们表示「活着」）。保证手段：任何代码都不另开这两个文件
   （收编跳过同 token 的 pre 文件；`lock` 只建不读；worker isolate 只碰批文件）。备选：每次调度器唤醒对它们重新 `lockSync` 一次（自愈，但会掩盖丢锁）。
6. **`device_digest` 含 `sdk` 字段**：同一 app 从原生 SDK 换成 Flutter SDK 后摘要变化 → 映射重发一次（无害）。layout_compat 的「24 h 内不重发」用例因此把 golden 的摘要换成 Flutter 设备的摘要再验。备选：摘要排除 `sdk`（三端同改，属协议变更）。
7. **代理**：现状一律直连（§5-4）。原生 SDK 走系统代理（HttpURLConnection / URLSession）；Flutter 的 `dart:io` 本来就不读系统代理。备选：读 `http_proxy` 环境变量（移动端基本没有），或垫片给 `findProxy`。
8. **`RetrieverLogger()` 默认输出**：现状 `MultiOutput([ConsoleOutput(), RetrieverLogOutput()])`（传 `output` 时替换控制台那一路）。备选：只输出到 Retriever。
9. **非根 isolate（`Isolate.spawn` / `compute`）里触达**：v3 写「直接 non_owner、不发 channel 调用」，但 pre 文件需要 `root()`（也是 channel 调用）。备选：工厂返回 null → 该 isolate unsupported（行丢不计）；
   或给本地实现：`bootstrap` 本地回 owner=false、`root` 经 `BackgroundIsolateBinaryMessenger` 照常要（行写 pre）。切片 2 定。
10. **logger 适配器的 ts**：`origin.time` 经内部 `RetrieverRuntime.logAt(ts, …)` 写行（公开 `Retriever.log` 没有 ts 参数）。备选：公开 API 加可选 `ts`（三端不一致，不建议）。
11. **事实更正**（不需要定，供记录）：logger 2.8.0 有两个传递依赖 `meta` + `clock`（v2 D3 写「无传递依赖」）；`HttpClient.findProxy` 见 §5-4。

## 8. 没做完的

- 本切片范围内无未完成项。按简报留给切片 2 / 3 的：`channel_platform.dart`、`ios/`、`android/`、`example/`、原生单测、README「待补」段落（平台 / 后台兜底 / 发布）、真机 profile 模式的性能门槛。

## 9. 审计修复（2026-10-09）

依据 `docs/audit/2026-10-09-m4-slice1/audit-opus.md` 与主代理裁决（v3 §10）。只改 `lib/**`、`test/**`；新增用例 25 个（265 → 290），全部走静态入口（#5 另有 `Text` 单元断言，#11 直接测根级锁原语）。新用例主要在新文件 `test/audit_fix_test.dart`（下称 AF）。修复前先跑过新用例：除 #9（现状行为本来就对，只补用例）和 #3 的字面序列用例（见下）之外都按预期失败；#8 另做了变异检查（去掉回退后用例失败）。

1. **🔴 回包被自动 gzip（审计 #1）**：两手都做。`transport.dart` 每个请求在写完调用方的请求头之后显式设 `Accept-Encoding: identity`，覆盖 `HttpClient` 自动加的 gzip；同时 `autoUncompress = true`，中间盒无视 identity 仍压缩时由 Dart 解压。`await for` 读到的已是解压后的字节，所以 64 KB 上限按解压后算。
   - 夹具：`support.dart` 的 `FakeServer` 加 `gzipReplies`。`whenAccepted` 照 Cloudflare 规则（`Accept-Encoding` 含 gzip 且体 ≥ 48 B 才压缩，回 `Content-Encoding: gzip`）；`always` 无视 identity 一律压缩。另记 `gzippedReplies`。
   - 用例（`transport_test`）：
     - `requestsIdentityEncodingSoEdgeDoesNotCompress`
     - `gzipReplyDespiteIdentityIsDecompressed`（含「200 KB 解压后截到 64 KB」）
     - `endToEndWithCompressingServer_whenAccepted` / `_always`：静态入口 + 真 `HttpClientTransport`；远程 `upload_level: info` 生效、flush → `stored`、批与配置请求都带 identity。
2. **🟠 reconfigure 的进程名来源（#2）**：`RetrieverClient` 新增 `autoProcessName` 字段（bootstrap 回包的值）；`_configureLocked` 改用 `options.processName ?? c.autoProcessName`，不再用 `root()` 回包的进程名。`rootProcess` 只留给 pre 文件头记录。
   - 用例 AF `sameParamsReconfigureNoWarn_rootProcess_absent` / `_main`：bootstrap 回 `remote`，`root()` 一个不带进程名、一个带 `main`。同参数 configure 三次，`reconfigure_ignored` 为 0 条；对照：显式改 processName 后照常 1 条。
3. **🟠 bootstrapping 窗口里的用户归属（#3）**：`client.attach` 在有 pre 文件时，于 `beginAdopt` 之后、`writePendingSynth` 之前调 `writer.adoptUser(null)`，把会话用户复位到 pre 文件开头的 null（段里还没有行，只改写段头），之后由切换记录按顺序推进。对位 Android「构造时同步交接、有 pre 文件则会话用户从 null 起」。
   - 新增测试钩子 `TestHooks.prepareGap`（`prepare` 末尾，生产恒为 null），用来确定性地打进「回包之后、发布之前」的间隙。
   - 用例 AF `setUserLogSequenceInWindowGivesThreeSegments`：`setUser(a)` 在回包前；log / `setUser(null)` / log / `setUser(b)` / log 在间隙里。结果三段，段头依次 a / null / b，各一行。
     - 注：这个字面序列修复前也通过。第一行 log 建 pre 文件时会写入 `pre_user:a`，纠正了会话用户。
   - 真正复现缺陷的是 `logoutInPrepareGapNeverAttributedToPreviousUser`（审计实证序列：回包前 `setUser(a)`，间隙里先登出再写）。修复前，「after logout」落进段头 a；修复后段头依次 null / b，a 名下无行。
4. **🟠 bootstrap 时开关为 false 则丢弃计数（#4，v3 §1.1）**：facade 在发布实例的同步块里，若 `!created.isEnabled`（即显式值 ?? 标记 == ABSENT 为 false，含标记判定不了的情形），就 `DropCounter.reset()`。显式 true 保留，由 `start()` 上报。
   - 用例 AF：
     - `markerPresentWithoutExplicitDiscards`：标记在、无显式值 → 计数丢，重新启用也不报。
     - `explicitTrueWithMarkerKeepsAndReports`：报出 `count 2 / error_count 1`，root 到达时标记被删。
     - `explicitFalseNeverCountsAndDiscardsEarlier`：显式 false 之后不计；之前已计的在 bootstrap 时丢。
5. **🟠 修剪规则（#5）**：`text.dart` 新增 `Text.trimmable`（码点 ≤ 0x20、0x7F–0x9F，以及 Unicode White_Space：U+00A0、U+1680、U+2000–200A、U+2028、U+2029、U+202F、U+205F、U+3000）和 `Text.isBlank`。`sanitizeUserId` 改用 `isBlank`，不再用 `String.trim`。`ConfigCheck.trim` 改调同一个 `Text.trimmable`，删掉自己那份副本（唯一实现）。
   - 用例 AF `sanitizeUserIdBlankRule`：U+FEFF / U+200B 保留；U+00A0、U+2028 等纯空白 → null；不修剪非空值。
   - 用例 AF `setUserBlankRuleThroughStaticEntry`。
6. **🟡 非 owner 卡死（#6）**：`limits.dart` 新增 `ClientConstants.nonOwnerRetryMs = 60000`。
   - `retryConfigure` 在 nonOwner 态的规则：非 force 时距上次（进入 nonOwner，或上次排上重试）不足 60 s 就跳过；排上即重新计时，连续触达不会重复排。进入 nonOwner 时也记一次时刻。
   - `Retriever.flush` 未建实例时也算触达（failed 按 5 s、nonOwner 按 60 s 间隔）。log / logAt / setUser 本来就算。
   - `willEnterForeground` / `ownerReleased` 照旧 force 立即重试。垫片侧广播给所有引擎是切片 2 的事。
   - 用例 AF `nonOwnerTouchRetriesOncePer60s`：59 s 内的 log / setUser / flush 不重试；满 60 s 重试一次，连续触达不重复；重新计时后 owner 已释放，触达即接任，n1–n5 全部收编。
   - 用例 AF `nonOwnerEventsStillRetryImmediately`。
7. **🟡 实例建成前的 `didEnterBackground`（#7）**：`_Events` 在实例为 null 时的处理：
   - `didEnterBackground(id)`：有 id 就立即 `platform.endBackgroundTask(id)`（2 s 超时，失败忽略），并记 bg。
   - `willEnterForeground` / `foregroundStateChanged`：同样记下状态，记在 facade 静态 `_lastForeground` 和事件序号里。
   - 建实例时，若 bootstrap 回包的 `foreground` 为 null，就用记下的值作初值（裁决原文）。
   - **补充一处（请主代理确认）**：回包之后、实例发布之前（prepare 的异步间隙）到达的事件比回包新。按「不能吞」处理：发布后调一次 `created.foregroundStateChanged(最新值)`，只改 last_state。只靠「null 才用」覆盖不到审计列的这个时段。
   - 用例 AF：
     - `beforeReplyEndsTaskAndSeedsNullForeground`：回包前到达、id 42，立即 end；回包 null → last_state bg。
     - `beforeReplyNonNullForegroundWins`：回包非 null 以回包为准；无 id 不调 end。
     - `inPrepareGapEndsTaskAndAppliesAfterPublish`
     - `failedStateEndsTaskAndRemembers`
8. **🟡 attach 失败回退（#8）**：`PreLog.handoffFailed(f)`（同 Android）回到 open，文件仍开着、仍持 flock 时取回。facade 在「已交接、实例未发布」时抛异常的处理：先 `created.writer.abortAdoption()` 把文件从未发布的实例手里摘下，这样 `closeForTesting` 不会关掉它；再 `handoffFailed`；然后进 failed。`client.attach` 在交接之后加测试崩溃点 `TestHooks.adoption('attach')`。
   - 用例 AF `attachFailureKeepsPreFileForNextRetry`：注入 attach 失败后，状态为 failed；pre 文件还在，子进程探锁仍是 locked，可以继续追加。下次 configure 收编 before / after failure 两行，pre 文件清空。
9. **🟡 同 token 外来 pre 文件（#9，只补用例）**：用例 AF `sameTokenForeignPreFileNeverOpened`。夹具：同 token、比 SDK 墙钟早 8 天的「别的引擎」pre 文件，由测试持 flock；另放 9 个死孤儿（别的 token，触发 `_trimDead`）。
   - 覆盖三条路径：首次建 pre 文件前的 `_trimDead`（死文件修剪到 8 个，同 token 那个不碰）、configure 的收编与孤儿收编（8 个真孤儿照收，它不收）、驱逐的 7 天删除。
   - 三条路径之后：文件仍在、长度不变；子 Dart 进程探锁仍是 locked，证明从没在本进程打开过。
   - 放锁并换 token 重启后，才作为孤儿被收编，文件删除。
   - 夹具要点：测试自己在本进程里读这个文件也会放掉锁，所以持锁期间只用 stat。
10. **🟡 收编分块（#10）**：
    - `PreFile.readFrom(from, [max])` 加长度上限。
    - `_adoptOwnPre` 按 `adoptSliceBytes = 64 KB` 一片读，同一句柄、不另开 fd。按最后一个换行切片再 feed，片之间 `await Future.delayed(Duration.zero)`。
    - 一片里没有完整记录（坏文件的超长行）时，退回读剩余全部，同旧行为。
    - 尾段（≤ 64 KB）与提交时的剩余仍同步读。
    - 新用例 `flutter_specific_test.eventLoopLagDuringPreAdoptionWithRedact`：1000 KB / 3410 行的 pre 文件 + redact 钩子，从 configure 到收编提交、startup 落定（含物化），断言最大滞后 < 50 ms、每行都过钩子、全部收编。
    - 实测（Mac JIT）：新做法 5–10 ms；同夹具换回旧的 256 KB 读剩余全部为 22–48 ms。
11. **🟡 根级锁 Zone 标记泄漏（#11）**：`_AsyncMutex` 加 `holder`。`withDirLock` 每次持有时新建一个令牌放进 Zone 值，判重入改为 `identical(Zone.current[key], mutex.holder)`，`finally` 里清掉。锁释放后，泄漏出去的 Zone 不再算重入。
    - 用例 AF `zoneMarkerDoesNotLeakPastRelease`：嵌套调用照常重入。在已释放锁的临界区 Zone 里再调 `withDirLock`，别人持锁时必须排队；修复前会直接执行、与持有者重叠。
12. **🟡 token 格式防线（#12）**：token 不是小写 UUID 时一律当垫片错误：
    - `root()` 回包：按 root() 失败处理（`_onRootError(PlatformCallException('bad_token'))`）。root 不设、不建 pre 文件、行计数，≥ 5 s 后的触达再要。
    - `bootstrap()` 回包：抛 `PlatformCallException`，进 failed。
    - 用例 AF `nonUuidTokenIsShimError_not-a-uuid` / `_UPPER`：root 为 null、计数 2、不建 pre 目录；configure 进 failed、token 为 null。垫片给合法 token 后，configure 成功并补报计数 2。

改动文件：

| 范围 | 文件 |
|---|---|
| lib | `transport.dart`、`retriever.dart`、`client.dart`、`pre.dart`、`text.dart`、`config_check.dart`、`fs.dart`、`limits.dart` |
| test | `support/support.dart`（`FakeServer.gzipReplies`、tearDown 清 `prepareGap`）、`transport_test.dart`、`flutter_specific_test.dart`、新增 `audit_fix_test.dart` |

`dart test` 尾部（3.44.4；`dart analyze`：No issues found；`dart format --set-exit-if-changed .`：0 changed）：

```
00:07 +288: test/flutter_specific_test.dart: eventLoopLagDuringStartupRecovery
[lag] fixture: outbox=21638 KB, ring=33225 KB
[lag] startup recovery 345 ms, ticks=344, max lag=1 ms, p99 lag=0 ms
[lag] outbox after recovery: 24818 KB
00:08 +289: test/flutter_specific_test.dart: eventLoopLagDuringPreAdoptionWithRedact
[lag] pre file 1000 KB, 3410 lines
[lag] pre adoption + startup 55 ms, ticks=33, max lag=5 ms
00:08 +290: All tests passed!
```
