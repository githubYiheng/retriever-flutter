// 宿主 API 的值类型（方案 §3.10，三端同名；对位 Android `PublicApi.kt`）。入口在 retriever.dart。
// 纯 Dart：不 import flutter / dart:ui。

/// 日志级别；线上值 lower_snake（`debug` … `fatal`）。顺序 debug < info < warn < error < fatal。
enum LogLevel { debug, info, warn, error, fatal }

/// 异常（§3.1 `exc`）。宿主的 Dart 错误对象由 SDK 转换：type = `runtimeType`、message = `toString()`、
/// stack = `StackTrace.toString()`（没有栈为 null）。`--obfuscate` 构建下 type 是混淆名。
class LogException {
  const LogException({required this.type, required this.message, this.stack});

  final String type;
  final String message;
  final String? stack;

  LogException copyWith({String? type, String? message, Object? stack = _unset}) => LogException(
    type: type ?? this.type,
    message: message ?? this.message,
    stack: identical(stack, _unset) ? this.stack : stack as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is LogException && other.type == type && other.message == message && other.stack == stack;

  @override
  int get hashCode => Object.hash(type, message, stack);

  @override
  String toString() => 'LogException(type: $type, message: $message, stack: ${stack == null ? 'null' : '…'})';
}

/// 给 `redact` 钩子看的行（落盘前）。seq / oseq 由 SDK 在落盘时分配，钩子不可改；`ts` 改了也取回原值。
/// `attrs` 的值认 String / num / BigInt / bool / null，集合与 Map 渲染成紧凑 JSON 文本，其它 `toString()`。
class LogLine {
  const LogLine({required this.ts, required this.level, required this.msg, this.tag, this.attrs, this.exc});

  final int ts;
  final LogLevel level;
  final String msg;
  final String? tag;
  final Map<String, Object?>? attrs;
  final LogException? exc;

  /// 可空字段用哨兵：`copyWith(tag: null)` 能把 tag 改回 null。
  LogLine copyWith({
    int? ts,
    LogLevel? level,
    String? msg,
    Object? tag = _unset,
    Object? attrs = _unset,
    Object? exc = _unset,
  }) => LogLine(
    ts: ts ?? this.ts,
    level: level ?? this.level,
    msg: msg ?? this.msg,
    tag: identical(tag, _unset) ? this.tag : tag as String?,
    attrs: identical(attrs, _unset) ? this.attrs : attrs as Map<String, Object?>?,
    exc: identical(exc, _unset) ? this.exc : exc as LogException?,
  );

  @override
  String toString() => 'LogLine(ts: $ts, level: ${level.name}, msg: $msg, tag: $tag)';
}

/// redact 钩子：返回 null = 丢弃（不占 seq、不记墓碑）；抛异常 = 丢弃该行。钩子内调 `log()` 视为重入直接忽略。
/// configure 之前的行在收编时过它——可能在 SDK 的异步任务里被调：要快、不要依赖调用栈。
typedef RedactHook = LogLine? Function(LogLine line);

/// 宿主选项（§3.10；ADR 0004 / 0005）。不可变：`const` 构造 + `copyWith`（可空字段用哨兵参数才能改回 null）。
class RetrieverOptions {
  const RetrieverOptions({
    this.uploadLevel = LogLevel.warn,
    this.localLevel = LogLevel.debug,
    this.dailyBatchCap = 0,
    this.localCapBytes = 20 * 1024 * 1024,
    this.redact,
    this.processName,
    this.jobId = 0x5254,
    this.sdkVersion = RetrieverVersion.current,
  });

  /// 自动上传级别（ADR 0004）：该级别及以上的行是义务行（有 oseq）。远程配置可覆盖。
  final LogLevel uploadLevel;

  /// 本地落盘级别（§3.3-9）：以下的行不写、不占 seq。远程配置可覆盖。
  final LogLevel localLevel;

  /// 每日包数软上限（ADR 0005）；0 = 不限。远程配置可覆盖（钳制 0–10000）。
  final int dailyBatchCap;

  /// 本地总量上限（宿主默认，远程可改，钳制 2–100 MB）。
  final int localCapBytes;

  /// 落盘前调用；见 [RedactHook]。
  final RedactHook? redact;

  /// 会话目录 `proc-<name>` 与信封 `process`；null = 垫片给的自动名（Android 主进程 "main"，其它取 `:` 之后的后缀；iOS "main"）。
  /// 只认首次 configure（之后不同 → 忽略并留合成 warn `rtv.reconfigure_ignored`）。
  final String? processName;

  /// Android 后台兜底 JobScheduler 作业 id（宿主可改，避免与自己的作业冲突）。iOS 不用。
  final int jobId;

  /// 进 `device.sdk = "retriever-flutter/<ver>"` 与 `X-Rtv-Sdk`。
  final String sdkVersion;

  RetrieverOptions copyWith({
    LogLevel? uploadLevel,
    LogLevel? localLevel,
    int? dailyBatchCap,
    int? localCapBytes,
    Object? redact = _unset,
    Object? processName = _unset,
    int? jobId,
    String? sdkVersion,
  }) => RetrieverOptions(
    uploadLevel: uploadLevel ?? this.uploadLevel,
    localLevel: localLevel ?? this.localLevel,
    dailyBatchCap: dailyBatchCap ?? this.dailyBatchCap,
    localCapBytes: localCapBytes ?? this.localCapBytes,
    redact: identical(redact, _unset) ? this.redact : redact as RedactHook?,
    processName: identical(processName, _unset) ? this.processName : processName as String?,
    jobId: jobId ?? this.jobId,
    sdkVersion: sdkVersion ?? this.sdkVersion,
  );
}

/// `flush()` 的结果：[stored] = flush 产生的批 15 s 内已被服务端确认；[FlushPending] 附原因
/// （offline / backoff / paused / timeout / disabled；未 configure = paused，等待中被禁用 = disabled）。
sealed class FlushResult {
  const FlushResult();

  static const FlushResult stored = FlushStored._();

  factory FlushResult.pending(String reason) = FlushPending;

  bool get isStored => this is FlushStored;
}

final class FlushStored extends FlushResult {
  const FlushStored._();

  @override
  String toString() => 'stored';
}

final class FlushPending extends FlushResult {
  const FlushPending(this.reason);

  final String reason;

  @override
  bool operator ==(Object other) => other is FlushPending && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  /// 与 iOS / Android 一致：`pending("disabled")`。
  @override
  String toString() => 'pending("$reason")';
}

/// SDK 版本号（唯一来源）：进 `device.sdk = "retriever-flutter/<ver>"` 与 `X-Rtv-Sdk`；必须 == pubspec.yaml 的 version。
abstract final class RetrieverVersion {
  static const String current = '0.1.0';
}

const Object _unset = _Unset();

class _Unset {
  const _Unset();
}
