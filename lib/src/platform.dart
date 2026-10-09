// 可注入的平台边界（对位 Android `core/Platform.kt` 的 Platform 接口；v3 §3 垫片 channel 契约）。
// 切片 1 的假 platform 与切片 2 的 `ChannelPlatform` 实现同一份接口。纯 Dart：不 import flutter。
//
// 错误映射：ChannelPlatform 把 `MissingPluginException` 映射成 [PlatformUnsupportedException]（本进程终态 no-op，K1 `unsupported`），
// 把 `PlatformException` 映射成 [PlatformCallException]（K1 `failed`）；超时由调用方（facade / client）按 v3 §3 统一施加。

import 'clock.dart';
import 'transport.dart';

/// `root()` 回包（v3 §3）。`process` / `device` 是本切片在契约上的补充（可选）：configure 之前写 pre 文件头记录要用
/// （同 Android 头记录取 `deviceFields()` / `autoProcessName()`）；垫片不给时头记录用空串 / "main"。见报告「需要主代理定」。
class RootInfo {
  const RootInfo({required this.root, required this.token, this.process, this.device});

  final String root;

  /// 进程级静态 UUID（同进程每个 Flutter 引擎拿到同一个）。
  final String token;
  final String? process;
  final Map<String, String>? device;
}

/// `bootstrap()` 回包（v3 §3）。
class BootstrapInfo {
  const BootstrapInfo({
    required this.owner,
    required this.root,
    required this.token,
    required this.process,
    required this.foreground,
    required this.device,
  });

  final bool owner;
  final String root;
  final String token;

  /// 自动进程名（Android 主进程 "main"，其它取 `:` 之后的后缀；iOS "main"）。
  final String process;

  /// 回包时刻 tracker 的值；读不到 = null（last_state 留空、退出判 unknown）。
  final bool? foreground;

  /// {os, os_version, model, app_version, build, locale}
  final Map<String, String> device;
}

/// 原生 → Dart 的事件（v3 §3 ← 方向）。facade 在发 `root()` 之前就把它装上。
abstract class PlatformEventHandler {
  void didEnterBackground(int? bgTaskId);

  void willEnterForeground();

  /// 只改 last_state、不封段（对位 iOS 0.3.0）。
  void foregroundStateChanged(bool foreground);

  /// 原生 handler 内已先 end；Dart 只取消在途请求。
  void backgroundTaskExpired(int id);

  /// 只用于提前唤醒。
  void networkRestored();

  /// Android 作业回调：排空出站箱，返回是否需要系统按退避重排。
  Future<bool> drainOutbox(int budgetMs);

  void stopUploadJob();

  /// 别的引擎（之前的 owner）detach：本引擎若处于 non_owner 就重试 bootstrap（v3 §4）。
  void ownerReleased();
}

/// 本进程不支持（`MissingPluginException`、web / 桌面）：K1 `unsupported` 终态。
class PlatformUnsupportedException implements Exception {
  const PlatformUnsupportedException([this.message]);

  final String? message;

  @override
  String toString() => 'PlatformUnsupportedException($message)';
}

/// 垫片调用失败（`PlatformException` 等）：K1 `failed`，下一次触达 / configure 重试。
class PlatformCallException implements Exception {
  const PlatformCallException(this.code, [this.message]);

  final String code;
  final String? message;

  @override
  String toString() => 'PlatformCallException($code, $message)';
}

/// 平台钩子（v3 §3 的 → 方向全部方法 + 时钟 + 传输）。
abstract class RetrieverPlatform {
  Clock get clock;

  Transport get transport;

  /// 建目录、设备份排除 / 保护类别；**不登记 owner**。
  Future<RootInfo> root();

  /// 登记 owner（v3 §4）。
  Future<BootstrapInfo> bootstrap();

  /// 配置诊断出口（Android `android.util.Log` tag `Retriever`；iOS `os.Logger`）。进程级去重在垫片。
  Future<void> diagnose(String code, String message);

  /// Android `JobGate` 认归属：返回是否排上；iOS no-op 返回 false。
  Future<bool> scheduleUploadJob(int jobId);

  Future<bool> cancelUploadJob(int jobId);

  /// iOS 幂等记账；Android no-op。
  Future<void> endBackgroundTask(int id);

  /// 可用磁盘空间（null = 未知，不按空间收缩上限）。
  Future<int?> availableBytes();

  /// 原生 → Dart 事件出口（null = 卸下）。
  set eventHandler(PlatformEventHandler? handler);
}
