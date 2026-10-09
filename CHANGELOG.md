# Changelog

Retriever monorepo `sdk/flutter`（pub 包名 `revdog_retriever`）。版本号遵循语义化版本：修订号 = 只修 bug；次版本 = 公开 API 只增；
主版本 = 公开 API 有减或改。Flutter SDK 的版本号独立于原生 SDK；协议、盘上布局与行为对位原生 SDK 0.3.0。

## 0.1.0 - 未发布

首个版本（ADR 0026「Flutter 对位 0.3.0」）。纯 Dart 传输层引擎 + 极薄原生垫片（Android / iOS）+ `package:logger` 适配器。

### 公开面
- 静态入口 `Retriever`：`configure`（`Future`，有界完成）/ `setUser` / `log` / `flush`（`Future<FlushResult>`）/ `uploadLevel` / `localLevel` /
  `setEnabled` / `isEnabled` / `purgeLocal`（`Future`，清完才完成）/ `installId` / `supportCode`；值类型 `LogLevel`、`RetrieverOptions`、
  `FlushResult`（`FlushStored` / `FlushPending`）、`LogLine`、`LogException`、`RedactHook`。三端同名同语义。
- `package:revdog_retriever/logger.dart`：`RetrieverLogOutput`（加进宿主现有的 `MultiOutput`）与 `RetrieverLogger`（默认 `ProductionFilter`）。

### 与原生 SDK 0.3.0 的对位
- 批格式、对象键、信封字段、请求头、队列 / 退避 / 暂停、配置钳制与 `from_host`、恢复与收编、驱逐、禁用标记与清空：逐字对位 Android 0.3.0
  （同一组 golden 向量与 `validate-envelope.ts` 跨语言校验守着）。盘上布局与 Android 0.3.0 相同，从原生 SDK 换成 Flutter SDK 的同一 app
  能读回旧状态（`layout-0.3.0.json` golden 守着）——但同一进程里**不要**同时用原生 SDK 与 Flutter SDK。
- `device.sdk` / `X-Rtv-Sdk` = `retriever-flutter/0.1.0`。

### Flutter 特有
- configure 之前的行写 `pre/<token>-<uuid>.jsonl`；首次触达任何入口时向垫片要 root，回包之前的行只计数（`rtv.pre_init_dropped`）。
- 同进程多个 Flutter 引擎：只有 owner 引擎（首个 bootstrap 的）有实例；其余引擎的行写自己的 pre 文件，进程死后由下一任 owner 收编。
- `fatal` 不排后台作业（Dart 不能同步调原生）；封段物化照常，进程死后由启动恢复兜底。
- 宿主 `flutter test`、web、桌面：整个 SDK no-op（零 Timer、零文件、不抛）。
- 上传用 SDK 自己的 `dart:io HttpClient`：不经宿主的 http 包 / 拦截器 / `HttpOverrides.global`，一律直连（不走代理）。
