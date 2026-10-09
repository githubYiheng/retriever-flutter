/// `package:logger` 适配器（v2 §4；方案 §3.10）：[RetrieverLogOutput] 与带 `ProductionFilter` 的 [RetrieverLogger] 工厂。
///
/// - 读 `event.origin`，不读 `event.lines`（printer 的排版不进日志）；
/// - 级别映射：trace / verbose → debug、debug → debug、info → info、warning → warn、error → error、fatal / wtf → fatal；
///   `all` / `off` / `nothing` 不会出现在事件里（`LogEvent` 构造时就拒绝），万一出现：`all` 按 debug、`off` / `nothing` 丢弃；
/// - `origin.message` 是 Function / Map / Iterable 时照 logger 的 `PrettyPrinter.stringifyMessage` 转字符串；
/// - `origin.time` → 行 ts（ms UTC）；`error` / `stackTrace` → `exc`；
/// - 低于 `Retriever.localLevel` 的行尽早丢弃；
/// - output 自己 catch 并计数（logger 会吞掉 output 抛出的异常）。
///
/// 已自建 `Logger` 的宿主把 `RetrieverLogOutput()` 加进现有的 `MultiOutput`；`RetrieverLogger(...)` 的默认 filter 是
/// `ProductionFilter`（logger 默认的 `DevelopmentFilter` 在 release 下丢弃全部日志）。注意：printer 输出为空时 logger 不调 output。
library;

import 'dart:convert';

import 'package:logger/logger.dart';

import 'revdog_retriever.dart';
import 'src/adapter_bridge_stub.dart' if (dart.library.io) 'src/adapter_bridge.dart' as bridge;

/// 把 logger 的事件写进 Retriever。
class RetrieverLogOutput extends LogOutput {
  RetrieverLogOutput({this.tag}) {
    // 构造即触达（v3 §1：首触发 root()）
    try {
      Retriever.isEnabled;
    } catch (_) {}
  }

  /// 每行的 tag（null = 不带）。
  final String? tag;

  /// 本 isolate 里 output 自己吞掉的异常次数（logger 会吞掉 output 的异常，这里留个数）。
  static int failures = 0;

  /// logger 级别 → Retriever 级别；null = 丢弃。
  static LogLevel? mapLevel(Level level) {
    // ignore: deprecated_member_use
    if (level == Level.off || level == Level.nothing) return null;
    if (level.value >= Level.fatal.value) return LogLevel.fatal;
    // ignore: deprecated_member_use
    if (level == Level.wtf) return LogLevel.fatal;
    if (level.value >= Level.error.value) return LogLevel.error;
    if (level.value >= Level.warning.value) return LogLevel.warn;
    if (level.value >= Level.info.value) return LogLevel.info;
    return LogLevel.debug;
  }

  /// 同 logger `PrettyPrinter.stringifyMessage`：Function 先调，Map / Iterable 编成 JSON（两空格缩进，不可编码的取 toString）。
  static String stringifyMessage(dynamic message) {
    final m = message is Function ? message() : message;
    if (m is Map || m is Iterable) {
      return const JsonEncoder.withIndent('  ', _toEncodableFallback).convert(m);
    }
    return m.toString();
  }

  static Object? _toEncodableFallback(dynamic object) => object.toString();

  @override
  void output(OutputEvent event) {
    try {
      final origin = event.origin;
      final level = mapLevel(origin.level);
      if (level == null) return;
      if (level.index < bridge.retrieverLocalLevel().index) return;
      final msg = stringifyMessage(origin.message);
      bridge.retrieverLogAt(
        origin.time.toUtc().millisecondsSinceEpoch,
        level,
        msg,
        tag: tag,
        error: origin.error,
        stackTrace: origin.stackTrace,
      );
    } catch (_) {
      failures += 1;
    }
  }
}

/// 带 Retriever 输出的 `Logger`：默认 `ProductionFilter`、`SimplePrinter`（不着色）、控制台 + Retriever 两路输出。
/// 传了 `output` 时用 `MultiOutput([output, RetrieverLogOutput()])`。
class RetrieverLogger extends Logger {
  RetrieverLogger({LogFilter? filter, LogPrinter? printer, LogOutput? output, Level? level, String? tag})
    : this._(filter ?? ProductionFilter(), printer, output, level, tag);

  RetrieverLogger._(this.effectiveFilter, LogPrinter? printer, LogOutput? output, Level? level, String? tag)
    : super(
        filter: effectiveFilter,
        printer: printer ?? SimplePrinter(colors: false),
        output: MultiOutput([output ?? ConsoleOutput(), RetrieverLogOutput(tag: tag)]),
        level: level,
      );

  /// 生效的 filter（未传 = `ProductionFilter`；logger 默认的 `DevelopmentFilter` 在 release 下丢弃全部日志）。
  final LogFilter effectiveFilter;
}
