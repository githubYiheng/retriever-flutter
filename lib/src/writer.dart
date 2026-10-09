// 写入侧（宪法 R-1，方案 §3.3 / §3.4）。对位 Android `core/Writer.kt`，与 iOS `Writer.swift` 逐字一致。
//
// Dart 是单线程的：主 isolate 上 `log()` 同步执行「seq++（义务行 oseq++）+ 拼前缀 + 一次 `writeFromSync`」，不需要锁。
// 写失败：`truncateSync` 回上一完整行后 `setPositionSync`（Dart 的 append 模式没有 O_APPEND，核实 §11b），关掉写句柄按 1 s 节流重开
// （ADR 0020 决定 6），该行照常占 seq / oseq 并记内存墓碑 write_failed；绝不抛给宿主。
// 换段时打开下一段用 `openSync`（热路径上唯一的「打开」；见报告）；旧段句柄交给引擎任务异步 flush + close（v3 §7）。
//
// 收编中（ADR 0023）：configure 时本进程有 pre 文件——之后的行（已过 redact、按生效 local_level 过滤）仍追加到 pre 文件
// （`r` = 1），用户切换写切换记录；引擎任务按文件顺序经 [adoptLine] / [adoptUser]（即正常追加路径）写进会话，
// 追到文件尾后切到正常态（[commitAdoption]）。

import 'dart:io';
import 'dart:typed_data';

import 'clock.dart';
import 'config.dart';
import 'fs.dart';
import 'limits.dart';
import 'line_encoder.dart';
import 'model.dart';
import 'pre.dart';
import 'public_api.dart';
import 'segments.dart';

/// 重入保护（§3.3-6）：redact 钩子内、SDK 内部路径上的 log() 直接忽略。Dart 单线程，一个静态标志即可。
abstract final class Reentrancy {
  static bool active = false;
}

/// 写失败区间（内存墓碑，可写时落盘）。
class FailedRange {
  FailedRange(this.from, this.to, this.n, this.atMs);

  final int from;
  int to;
  int n;
  final int atMs;
}

class WriteOutcome {
  bool written = false;
  bool rotated = false;
  bool fatal = false;
  bool deadlineChanged = false;
  bool tombstone = false;

  /// 没有会话（bootstrap 失败 / 目录消失 / 收编中写 pre 失败）：行没落盘，调用方计数（简报 §4.1）。
  bool noSession = false;

  /// 收编中：行已追加到 pre 文件，seq / oseq 等收编时再分配。
  bool deferred = false;

  /// 落盘失败（没有会话、段打不开、write 失败）——不含 local_level 过滤、禁用。
  bool failed = false;
}

/// setUser 的结果：`changed` = 值变了（身份变化，要重拉配置）；`rotated` = 因此封了段。
class UserChange {
  const UserChange(this.changed, this.rotated);

  final bool changed;
  final bool rotated;
}

/// flush 标记行：`reused` = 已有一个等待中的标记且其后没有新义务行，没有追加新行（简报 §8）。
class FlushMark {
  const FlushMark(this.sessionId, this.oseq, this.reused);

  final String sessionId;
  final int oseq;
  final bool reused;
}

enum Commit { done, more, failed }

class WriterSnapshot {
  const WriterSnapshot(this.seq, this.oseq, this.segNo, this.segBytes, this.segLines, this.user);

  final int seq;
  final int oseq;
  final int segNo;
  final int segBytes;
  final int segLines;
  final String? user;
}

class Writer {
  Writer(this._clock, [HostDefaults host = const HostDefaults(LogLevel.warn)]) : _hostDefaults = host {
    _recompute();
  }

  final Clock _clock;

  /// 段打不开 / 写失败之后多久再试一次（期间的行只计数记墓碑，不碰磁盘）。
  static const int reopenThrottleMs = 1000;

  /// 测试注入点：非 null 时下一次行写入只写前 n 字节就失败（模拟写到一半失败）。生产恒为 null。
  static int? writeCutForTesting;

  String? _sessionDir;
  String _sessionId = '';
  RandomAccessFile? _out;
  SegInfo _cur = SegInfo(0, null, 0, '/dev/null');
  int _seq = 0;
  int _oseq = 0;
  int _uploadRank = LogLevel.warn.index;
  int _localRank = LogLevel.debug.index;
  bool _enabled = true;

  /// 会话里当前段的用户（段头 user_id；收编时按切换记录推进）。
  String? _user;

  /// 宿主最近一次设的用户（配置身份用）；正常态 == [_user]，收编中可能领先。
  String? _latestUser;
  int _flushIntervalMs = Limits.flushIntervalSDefault * 1000;
  int? _errorDeadline;
  int _lastErrorSealMono = -(1 << 60);
  int? _warnDeadline;
  int? _fatalWindowStart;
  int _flushMarkOseq = 0;
  final List<SealJob> _pending = <SealJob>[];
  final List<FailedRange> _failed = <FailedRange>[];
  int _nextReopenMono = 0;
  PreFile? _adopt;
  HostDefaults _hostDefaults;
  ConfigCache? _cache;

  /// 会话目录在运行中消失（换段时打不开、目录已不在）：交给引擎重新 bootstrap（简报 §4.5）。只能投递。
  void Function()? onVanished;

  // MARK: 会话

  /// 开始（或重开）一个会话：关掉上一个会话的流（含没封完的段），seq / oseq 从 0 起，打开 seg-000001.open。
  void startSession(String dir, String sessionId) {
    _closeQuietly(_out);
    for (final j in _pending) {
      _closeQuietly(j.out);
    }
    _out = null;
    _sessionDir = dir;
    _sessionId = sessionId;
    _seq = 0;
    _oseq = 0;
    _pending.clear();
    _failed.clear();
    _errorDeadline = null;
    _warnDeadline = null;
    _fatalWindowStart = null;
    _flushMarkOseq = 0;
    _openSegment(1);
  }

  /// 放弃当前会话（purgeLocal / 目录消失 / 关停）：关流，不封段。
  void abandonSession() {
    _closeQuietly(_out);
    for (final j in _pending) {
      _closeQuietly(j.out);
    }
    _out = null;
    _pending.clear();
    _failed.clear();
    _sessionDir = null;
  }

  String get currentSessionId => _sessionId;

  bool get hasSession => _sessionDir != null;

  // MARK: 参数

  /// 宿主默认（只存这一份，引擎读它）。configure / reconfigure 在宿主调用里同步更新并重算生效级别。
  HostDefaults get host => _hostDefaults;

  set host(HostDefaults h) {
    _hostDefaults = h;
    _recompute();
  }

  /// 引擎每次 applyEffective 推新的缓存快照。
  void setConfigSnapshot(ConfigCache? c) {
    _cache = c;
    _recompute();
  }

  void _recompute() {
    final e = ConfigCache.effective(_cache, _hostDefaults, _clock.wallMs(), _clock.monoMs());
    _uploadRank = e.uploadLevel.index;
    _localRank = e.config.localLevel.index;
    _flushIntervalMs = e.config.flushIntervalS * 1000;
  }

  void setEnabled(bool on) => _enabled = on;

  bool get isEnabled => _enabled;

  /// 快速预判：未启用或低于 local_level 的行不做任何工作（不占 seq）。
  bool accepts(LogLevel level) => _enabled && level.index >= _localRank;

  /// 生效的上传 / 本地级别（远程配置钳制后；full_dump 期间上传级别为 debug）。
  (LogLevel, LogLevel) get levels => (LogLevels.ofRank(_uploadRank), LogLevels.ofRank(_localRank));

  /// 配置身份用的用户（宿主最近一次设的值）。
  String? get currentUser => _latestUser;

  /// configure 时交来的初始用户：没有 pre 文件 → 会话直接以它开始（段还没有行时改写段头）；有 pre 文件 → 会话从 null 起，
  /// 按切换记录推进。
  void initUser(String? u, bool sessionToo) {
    _latestUser = u;
    if (sessionToo) _sessionUser(u);
  }

  // MARK: 收编（ADR 0023）

  void beginAdopt(PreFile pf) => _adopt = pf;

  PreFile? get adoptingFile => _adopt;

  bool get isAdopting => _adopt != null;

  /// 收编：一行经正常追加路径写进会话。pre 行是已落盘的数据：禁用时照样写（上传仍被禁用挡住）；
  /// `filter` = 按生效 local_level 过滤（configure 之前写的 r = 0 行；r = 1 行写入时已过滤，原样）。
  WriteOutcome adoptLine(LogLevel level, Uint8List body, bool filter) {
    if (filter && level.index < _localRank) return WriteOutcome();
    return _append(level, body, false, adopted: true);
  }

  /// 收编：一条用户切换记录经 setUser 路径作用于会话（不动 [_latestUser]）。
  UserChange adoptUser(String? u) => _sessionUser(u);

  /// 目录消失后从偏移 0 重新收编：会话用户回到 pre 文件开头的 null（[_latestUser] 不动）。
  void resetSessionUserForReadoption() => _user = null;

  /// 目录消失时随之没了的段：当前 `.open` 段与还没封完的段，由调用方并入没落盘的行计数。收编中不算。
  List<SegInfo> takeLostSegments() {
    if (_adopt != null) return const <SegInfo>[];
    final out = <SegInfo>[];
    for (final j in _pending) {
      if (j.info.lineCount > 0) out.add(j.info);
    }
    if (_cur.lineCount > 0) out.add(_cur);
    _cur = SegInfo(_cur.segNo, _user, _cur.startedMs, _cur.path);
    return out;
  }

  /// 收编提交：`tail` 处理 `pos()` 之后追加的剩余记录——只含已过 redact 的行与用户记录时调用方当场写完返回 true；
  /// 剩余里还有没过 redact 的行返回 false（MORE），调用方处理完再来。然后 unlink pre 文件（提交点；unlink 失败则截成 0 长度）
  /// → 切到正常态。两者都失败 = FAILED：保持收编中，调用方稍后重试。
  Commit commitAdoption(PreFile pf, int Function() pos, bool Function(Uint8List rest) tail) {
    if (!identical(_adopt, pf)) return Commit.done;
    if (pf.length > pos()) {
      final rest = pf.readFrom(pos());
      if (rest == null) return Commit.failed;
      if (!tail(rest)) return Commit.more;
    }
    TestHooks.adoption?.call('before_commit');
    if (!pf.unlinkAndClose()) return Commit.failed;
    TestHooks.adoption?.call('after_unlink');
    _adopt = null;
    if (_latestUser != _user) _sessionUser(_latestUser);
    return Commit.done;
  }

  /// 收编放弃（purgeLocal：pre 文件随本地数据一起清掉）。
  PreFile? abortAdoption() {
    final pf = _adopt;
    _adopt = null;
    _user = _latestUser;
    return pf;
  }

  // MARK: 热路径

  WriteOutcome append(LogLevel level, Uint8List body) {
    final pf = _adopt;
    return pf != null ? _appendPre(pf, level, body) : _append(level, body, false);
  }

  /// 收编中：已过 redact 的行按生效 local_level 过滤后追加到 pre 文件（`r` = 1）。
  WriteOutcome _appendPre(PreFile pf, LogLevel level, Uint8List body) {
    final res = WriteOutcome();
    if (!_enabled || level.index < _localRank) return res;
    if (pf.append(PreRecords.line(true, body), false) == PrePut.written) {
      res.written = true;
      res.deferred = true;
    } else {
      res.noSession = true;
      res.failed = true;
    }
    return res;
  }

  /// flush 的合成行（level error、tag rtv.flush、synthetic）：无视 local_level / upload_level 一定是义务行，写完立即封段。
  /// 已有一个等待中的标记且其后没有新写入的义务行 → 复用它（简报 §8）。写失败返回 null（已记 write_failed 墓碑）。
  FlushMark? appendFlushMarker(Uint8List body, bool noCtx) {
    if (_flushMarkOseq > 0 && _oseq == _flushMarkOseq && _sessionDir != null) {
      return FlushMark(_sessionId, _flushMarkOseq, true);
    }
    final o = _append(LogLevel.error, body, true);
    if (!o.written) return null;
    _flushMarkOseq = _oseq;
    _rotate(SealReason.flush, noCtx);
    return FlushMark(_sessionId, _oseq, false);
  }

  /// SDK 自己的计数合成行（`rtv.pre_init_dropped`）：强制写入、强制义务，不因它按大小换段。禁用时不写。
  WriteOutcome appendForced(LogLevel level, Uint8List body) => _append(level, body, true);

  /// 等待结束：之后的 flush 追加新标记。
  void clearFlushMarker(String sid, int marker) {
    if (_sessionId == sid && _flushMarkOseq == marker) _flushMarkOseq = 0;
  }

  /// `adopted`：收编的行（已过滤 / 已落过盘）——不看启用开关与 local_level。
  WriteOutcome _append(LogLevel level, Uint8List body, bool forced, {bool adopted = false}) {
    final res = WriteOutcome();
    if (!adopted && (!_enabled || !(forced || level.index >= _localRank))) return res;
    if (_sessionDir == null) {
      res.noSession = true;
      res.failed = true;
      return res;
    }
    final now = _clock.monoMs();
    if (_out == null && now >= _nextReopenMono) {
      if (!_reopen()) _nextReopenMono = now + reopenThrottleMs;
      if (_sessionDir == null) {
        res.noSession = true;
        res.failed = true;
        return res;
      }
    }
    _seq += 1;
    final oblig = forced || level.index >= _uploadRank;
    if (oblig) _oseq += 1;
    final pre = LineEncoder.prefix(_seq, oblig ? _oseq : 0);
    final buf = Uint8List(pre.length + body.length);
    buf.setRange(0, pre.length, pre);
    buf.setRange(pre.length, buf.length, body);
    var ok = false;
    final o = _out;
    if (o != null) {
      try {
        final cut = writeCutForTesting;
        if (cut != null && cut < buf.length) {
          writeCutForTesting = null;
          o.writeFromSync(buf, 0, cut);
          throw const FileSystemException('injected partial write');
        }
        o.writeFromSync(buf);
        ok = true;
      } catch (_) {
        ok = false;
      }
      if (!ok) {
        // 回到上一完整行（并把文件位置拉回，否则下一次写留全 0 空洞）；关掉写句柄，节流期内的行不再碰磁盘
        var rolled = false;
        try {
          o.truncateSync(_cur.bytes);
          o.setPositionSync(_cur.bytes);
          rolled = true;
        } catch (_) {}
        if (!rolled) Fs.truncateSync(_cur.path, _cur.bytes);
        _closeQuietly(o);
        _out = null;
        _nextReopenMono = now + reopenThrottleMs;
      }
    }
    if (!ok) {
      res.failed = true;
      if (oblig) {
        _recordFailed(_oseq);
        res.tombstone = true;
      }
      return res;
    }
    res.written = true;
    if (_failed.isNotEmpty) res.tombstone = true;
    _cur.bytes += buf.length;
    if (_cur.firstSeq == 0) _cur.firstSeq = _seq;
    _cur.lastSeq = _seq;
    final ts = LineEncoder.tsOf(body);
    if (_cur.lineCount == 0) {
      _cur.firstTs = ts;
      _cur.lastTs = ts;
    } else {
      if (ts < _cur.firstTs) _cur.firstTs = ts;
      if (ts > _cur.lastTs) _cur.lastTs = ts;
    }
    if (level.index >= LogLevel.error.index) _cur.errorLines += 1;
    _cur.lineCount += 1;
    if (oblig) {
      if (_cur.firstOseq == 0) _cur.firstOseq = _oseq;
      _cur.lastOseq = _oseq;
      _cur.obligCount += 1;
      if (level.index >= LogLevel.error.index) _cur.hasError = true;
    }
    if (forced) return res;
    if (level == LogLevel.fatal) {
      final ws = _fatalWindowStart;
      if (ws == null || now - ws >= ClientConstants.fatalSealWindowMs) {
        // 窗口内第一条 fatal：立即换段；封段物化由调用方投递到引擎任务、不等待（ADR 0020 决定 1），只落盘不尝试上传
        if (_rotate(SealReason.fatal, false)) {
          res.rotated = true;
          res.fatal = true;
          _fatalWindowStart = now;
        }
        return res;
      }
      // 10 s 内的后续 fatal：照常逐行落盘，不强制换段，并入 error 的去抖封段（简报 §8）
    }
    if (oblig && level.index >= LogLevel.error.index && _errorDeadline == null) {
      final a = now + Limits.errorDebounceMs;
      final b = _lastErrorSealMono + Limits.errorSealMinIntervalMs;
      _errorDeadline = a > b ? a : b;
      res.deadlineChanged = true;
    }
    if (oblig && _cur.obligCount == 1 && _warnDeadline == null) {
      _warnDeadline = now + _flushIntervalMs;
      res.deadlineChanged = true;
    }
    if (_cur.bytes >= Limits.segmentBytes) res.rotated = _rotate(SealReason.size, false);
    return res;
  }

  void _recordFailed(int o) {
    final at = _clock.wallMs();
    final last = _failed.isEmpty ? null : _failed.last;
    if (last != null && last.to + 1 == o) {
      last.to = o;
      last.n += 1;
    } else {
      _failed.add(FailedRange(o, o, 1, at));
    }
  }

  // MARK: 换段

  bool _openSegment(int segNo) {
    final dir = _sessionDir;
    if (dir == null) return false;
    final path = Fs.join(dir, Segments.name(segNo, true));
    final started = _clock.wallMs();
    _cur = SegInfo(segNo, _user, started, path);
    final header = SegmentHeader(segNo, _user, started).encode();
    RandomAccessFile f;
    try {
      f = File(path).openSync(mode: FileMode.write);
    } catch (_) {
      _out = null;
      _checkVanished(dir);
      return false;
    }
    try {
      f.writeFromSync(header);
    } catch (_) {
      _closeQuietly(f);
      _out = null;
      return false;
    }
    _out = f;
    _cur.bytes = header.length;
    return true;
  }

  /// 打不开段文件且会话目录已不在（root 被删、别的进程清空）：放弃会话（之后的行计数），交给引擎重新 bootstrap。
  void _checkVanished(String dir) {
    try {
      if (FileSystemEntity.isDirectorySync(dir)) return;
    } catch (_) {
      return;
    }
    if (!Fs.isMissingSync(dir)) return;
    _sessionDir = null;
    onVanished?.call();
  }

  /// 写失败之后重开：段里已有行就接着追加（失败时已截回上一完整行，header 不重写）；还没有行则按新段重开。
  bool _reopen() {
    if (_cur.segNo == 0 || _cur.lineCount == 0) return _openSegment(_cur.segNo == 0 ? 1 : _cur.segNo);
    try {
      _out = File(_cur.path).openSync(mode: FileMode.append);
    } catch (_) {
      _out = null;
      final d = _sessionDir;
      if (d != null) _checkVanished(d);
    }
    return _out != null;
  }

  /// 换段：当前段（有行才换；写句柄已因写失败关掉也照封）交给引擎任务封，立即打开下一段。
  bool _rotate(SealReason reason, bool noCtx) {
    if (_sessionDir == null || _cur.lineCount <= 0) return false;
    _pending.add(SealJob(_out, _cur, reason, noCtx, _seq, _oseq));
    if (_cur.hasError) _lastErrorSealMono = _clock.monoMs();
    _errorDeadline = null;
    _warnDeadline = null;
    _out = null;
    _openSegment(_cur.segNo + 1);
    return true;
  }

  /// 外部触发的封段（flush / full_dump / upload_enabled / 进后台 / 关停）。
  /// `onlyIfObligation`：进后台、warn 计时只在段内有义务行时封。
  bool rotate(SealReason reason, {bool onlyIfObligation = false}) {
    if (onlyIfObligation && _cur.obligCount == 0) return false;
    return _rotate(reason, false);
  }

  /// setUser：值变化即封段；当前段还没有行时直接改写 header（用户边界 = 段边界）。
  /// 收编中：只记最新值并往 pre 文件追加一条切换记录，会话的用户边界等收编按顺序推进。
  UserChange setUser(String? u) {
    if (u == _latestUser) return const UserChange(false, false);
    _latestUser = u;
    final pf = _adopt;
    if (pf != null) {
      // 写失败：标坏，之后的行计数，绝不挂到错的用户名下
      if (pf.append(PreRecords.user(u), false) == PrePut.failed) pf.markBroken();
      return const UserChange(true, false);
    }
    return UserChange(true, _sessionUser(u).rotated);
  }

  /// 会话层的用户切换（段边界）。
  UserChange _sessionUser(String? u) {
    if (u == _user) return const UserChange(false, false);
    _user = u;
    final o = _out;
    if (o != null && _cur.lineCount == 0) {
      final header = SegmentHeader(_cur.segNo, u, _cur.startedMs).encode();
      var ok = false;
      try {
        o.truncateSync(0);
        o.setPositionSync(0);
        o.writeFromSync(header);
        ok = true;
      } catch (_) {}
      if (ok) {
        _cur.userId = u;
        _cur.bytes = header.length;
        return const UserChange(true, false);
      }
    }
    if (_out == null && _cur.lineCount == 0) {
      // 段还没开成（或写失败后关了）且没有行：重开时按新 user 写 header
      _cur.userId = u;
      return const UserChange(true, false);
    }
    return UserChange(true, _rotate(SealReason.user, false));
  }

  /// 定时器：error 去抖到期 / warn 计时到期（仅当有义务行）。
  bool checkDeadlines() {
    final now = _clock.monoMs();
    final d = _errorDeadline;
    if (d != null && now >= d) {
      _errorDeadline = null;
      if (_rotate(SealReason.error, false)) return true;
    }
    final w = _warnDeadline;
    if (w != null && now >= w) {
      _warnDeadline = null;
      if (_cur.obligCount > 0) return _rotate(SealReason.timer, false);
    }
    return false;
  }

  int? get nextDeadline {
    final a = _errorDeadline, b = _warnDeadline;
    if (a == null) return b;
    if (b == null) return a;
    return a < b ? a : b;
  }

  List<SealJob> takePendingSeals() {
    final p = List<SealJob>.of(_pending);
    _pending.clear();
    return p;
  }

  List<FailedRange> takeFailed() {
    final f = List<FailedRange>.of(_failed);
    _failed.clear();
    return f;
  }

  void putBackFailed(List<FailedRange> f) => _failed.insertAll(0, f);

  /// 测试 / 诊断用快照。
  WriterSnapshot get snapshot => WriterSnapshot(_seq, _oseq, _cur.segNo, _cur.bytes, _cur.lineCount, _user);

  /// 测试：关掉当前段的流，模拟写失败（ENOSPC / 目录不可写）。
  void debugBreakStream() {
    try {
      _out?.closeSync();
    } catch (_) {}
  }

  String? get currentSegmentPath => _out != null ? _cur.path : null;

  static void _closeQuietly(RandomAccessFile? o) {
    try {
      o?.closeSync();
    } catch (_) {}
  }
}
