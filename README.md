# Retriever Flutter 传输层（`sdk/flutter`，pub 包名 `revdog_retriever`）

> 骨架（M4 切片 1）：引擎与 `dart test` 已就位；原生垫片、示例 app、发布渠道在切片 2 / 3 补齐，标「待补」的段落届时定稿。

纯 Dart 引擎（批格式、队列、恢复、驱逐、配置……全部在 Dart 里）+ 极薄原生垫片（只给 root 目录、owner 登记、前后台事件、
Android JobScheduler 兜底作业、iOS 后台任务、诊断出口）。规格：`docs/plan/system-design.md` §3；不变式：`docs/architecture.md` §2；
Flutter 口径：`docs/plan/m4-flutter-brief-v3.md`、ADR 0026。行为、字段、顺序、数字与 Android / iOS 0.3.0 逐字一致，只在平台层不同。

| 项 | 值 |
|---|---|
| 约束 | `sdk: ^3.8.0`、`flutter: >=3.32.0`（门禁 3.32.8 / 3.41.4 / 3.44.4） |
| 依赖 | `crypto ^3.0.6`、`logger ^2.0.0`（适配器并在主包里，`package:revdog_retriever/logger.dart`） |
| 平台 | Android（minSdk 待补）、iOS（待补）；web / 桌面 / 宿主 `flutter test` 下整个 SDK no-op |
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
- **多引擎**：同一进程里只有 owner 引擎有实例；非 owner / 后台引擎的行写自己的 pre 文件，**要等进程死后**由下一任 owner 收编上传。
  owner 引擎销毁时其余已 configure 的引擎接任（回前台时也会重试）。
- **`flutter test` 下整个 SDK no-op**（零 Timer、零文件、不抛，也不发任何 channel 调用）；web / 桌面同样 no-op。
- **不与原生 SDK 混用**：同一 app 不要同时接 `retriever-android` / `retriever-ios` 与本包。
- **开发机切换环境**（staging ↔ 生产、换成另一个 app 的 key）：切换前先 `purgeLocal()` 或卸载重装。
- **`log()` 落盘即返回**：每行一次同步 write（进程被杀不丢，真杀进程测试守着）；其余 I/O 都在异步任务里，重活（gzip、批解析）在
  `Isolate.run` 里做。`redact` 钩子在落盘前同步执行，钩子里调 `log()` 被忽略，抛异常则该行丢弃。
- **网络**：SDK 用自己的 `dart:io HttpClient`——不经宿主的 http / dio 拦截器、不经 `HttpOverrides.global`、**一律直连**（不读系统代理，
  也不读 `http_proxy` 等环境变量）；超时 30 s、不跟随重定向、响应体最多读 64 KB。
- **后台兜底**：待补（切片 2：Android JobScheduler 作业 / iOS 后台任务，对位原生 SDK）。

## 开发

```bash
cd sdk/flutter
~/fvm/versions/3.44.4/bin/flutter pub get
~/fvm/versions/3.44.4/bin/dart analyze
~/fvm/versions/3.44.4/bin/dart format --set-exit-if-changed .
~/fvm/versions/3.44.4/bin/dart test          # 纯 Dart（假平台）；跨语言校验要仓库根 npm install 过
```

## 发布

待补（切片 3）。
