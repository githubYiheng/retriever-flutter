// 时钟（对位 Android `core/Platform.kt` 的 Clock 与 `AndroidClock`）：墙钟（行 ts、created_ms）与单调时钟（退避、暂停、去抖）。
//
// Flutter 口径（v2 §2.1；核实 §11c）：Dart VM 的单调时钟在 Android 上不含深睡眠。退避 / 暂停允许因此拉长（保守方向）；
// 放大型配置字段按「单调或墙钟任一到期」回落（config.dart `ConfigCache.elapsedMs`）。

import 'dart:async';

abstract class Clock {
  int wallMs();

  int monoMs();

  /// 流程内的短等待（flush / 后台排空等待相邻请求间隔）。
  Future<void> sleep(int ms);

  /// 调度器定时唤醒的真实延迟；null = 不自动唤醒（测试假时钟，手动 tick）。
  int? timerDelayMs(int ms);
}

/// 生产时钟：墙钟 `DateTime.now()`；单调 = 进程内 `Stopwatch`（起点固定、只增不减）。
class SystemClock implements Clock {
  SystemClock() : _base = DateTime.now().millisecondsSinceEpoch {
    _sw.start();
  }

  final Stopwatch _sw = Stopwatch();
  final int _base;

  @override
  int wallMs() => DateTime.now().millisecondsSinceEpoch;

  @override
  int monoMs() => _base + _sw.elapsedMilliseconds;

  @override
  Future<void> sleep(int ms) => ms > 0 ? Future<void>.delayed(Duration(milliseconds: ms)) : Future<void>.value();

  @override
  int? timerDelayMs(int ms) => ms < 0 ? 0 : ms;
}
