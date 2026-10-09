// 没落盘的行（ADR 0024 决定 1；sdk-0.3.0 简报 §4.1）：总行数、error 及以上行数、最小 / 最大 ts。对位 Android `Pre.kt` 的 DropCounter。
// isolate 内、静态、按来源合并（root 回包前的行、pre 文件超限 / 写失败、已 configure 却没有会话、内部异常）。禁用期间的行不计。
// 一旦有可写会话就以合成 warn `rtv.pre_init_dropped` 上报并清零；只在内存（进程在此之前死掉则丢——承诺边界）。

import 'public_api.dart';

class DropSnapshot {
  const DropSnapshot(this.count, this.errorCount, this.firstTs, this.lastTs);

  final int count;
  final int errorCount;
  final int firstTs;
  final int lastTs;
}

abstract final class DropCounter {
  static int _count = 0;
  static int _errorCount = 0;
  static int _firstTs = 0;
  static int _lastTs = 0;

  static const String tag = 'rtv.pre_init_dropped';
  static const String msg = 'lines dropped before a session was available';

  static void add(LogLevel? level, int ts) {
    if (_count == 0) {
      _firstTs = ts;
      _lastTs = ts;
    } else {
      if (ts < _firstTs) _firstTs = ts;
      if (ts > _lastTs) _lastTs = ts;
    }
    _count += 1;
    if (level != null && level.index >= LogLevel.error.index) _errorCount += 1;
  }

  /// 取走并清零（没有计数返回 null）。
  static DropSnapshot? take() {
    if (_count == 0) return null;
    final s = DropSnapshot(_count, _errorCount, _firstTs, _lastTs);
    _count = 0;
    _errorCount = 0;
    return s;
  }

  /// 合成行没写成（没有会话了）：放回去，下次再报。
  static void putBack(DropSnapshot s) {
    if (_count == 0) {
      _firstTs = s.firstTs;
      _lastTs = s.lastTs;
    } else {
      if (s.firstTs < _firstTs) _firstTs = s.firstTs;
      if (s.lastTs > _lastTs) _lastTs = s.lastTs;
    }
    _count += s.count;
    _errorCount += s.errorCount;
  }

  static void reset() {
    _count = 0;
    _errorCount = 0;
    _firstTs = 0;
    _lastTs = 0;
  }

  static int get pending => _count;
}
