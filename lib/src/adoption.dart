// 收编（ADR 0023；sdk-0.3.0 简报 §1.2）：把 pre 文件的记录按文件顺序经 writer 的正常追加路径写进会话——义务判定、seq / oseq、
// fatal 换段、error 去抖、warn 计时、用户边界都由同一个状态机产生。对位 Android `core/Adoption.kt`。
// 三处共用同一个函数：configure 时本进程的 pre 文件（引擎任务，先于 startup）、孤儿 pre 文件（startup 里、恢复旧会话之前）、
// 收编中途崩溃后的重做。

import 'dart:typed_data';

import 'drop_counter.dart';
import 'engine.dart';
import 'fs.dart';
import 'ids.dart';
import 'line_encoder.dart';
import 'model.dart';
import 'pre.dart';
import 'public_api.dart';
import 'segments.dart';
import 'writer.dart';

/// 逐条处理 pre 记录。`r` = 0 的行：有 redact 钩子则解码 → 调钩子（置重入标志，钩子里调 `log()` 被忽略；返回 null / 抛异常
/// → 丢弃该行；解不出 → 丢弃并计数）→ `ts` 取回原值、重编码（保留 synthetic，truncated 与原值取或）；无钩子或合成行不解码。
/// 然后按生效 local_level 过滤。`r` = 1 的行原样。钩子每条记录现取（收编中 reconfigure 换了钩子立即生效）。
class Adopter {
  Adopter(this._writer, this._redactOf, this._report);

  final Writer _writer;
  final RedactHook? Function() _redactOf;
  final void Function(Object error) _report;

  bool rotated = false;
  bool fatal = false;
  bool deadlineChanged = false;
  bool tombstone = false;
  int records = 0;
  bool sawHeader = false;
  PreHeader? header;

  /// 写会话时发现没有会话了（目录在收编中途消失）：停在这条记录。
  bool stalled = false;

  /// 有行没写成（没有会话、段打不开、write 失败；不含 local_level 过滤、redact 丢弃）：临时 writer 的收编据此不提交。
  bool failedWrites = false;

  /// 已处理到的文件偏移（逐条推进：处理中途抛异常，重试时从这里接着来，不重复写已收编的记录）。
  int offset = 0;

  bool _lastApplied = false;

  /// 处理 `data`（文件里从 `base` 开始的字节）里所有完整（`\n` 结尾）的记录；不完整的尾巴不算。
  void feed(Uint8List data, int base, {bool allowRedact = true}) {
    var start = 0;
    for (var i = 0; i < data.length; i++) {
      if (data[i] != 0x0A) continue;
      if (i > start) {
        if (stalled) return;
        _apply(PreRecords.parse(data, start, i), allowRedact);
        if (stalled) return;
      }
      start = i + 1;
      offset = base + start;
      if (_lastApplied) {
        _lastApplied = false;
        TestHooks.adoption?.call('record:$records');
      }
    }
  }

  /// `data` 里有没有完整的、还没过 redact 的行（需要单独处理）。
  bool hasUnredacted(Uint8List data) {
    if (_redactOf() == null) return false;
    var start = 0;
    for (var i = 0; i < data.length; i++) {
      if (data[i] == 0x0A) {
        final r = PreRecords.parse(data, start, i);
        if (r is PreLine && !r.redacted && !r.synthetic) return true;
        start = i + 1;
      }
    }
    return false;
  }

  void _apply(PreRec r, bool allowRedact) {
    switch (r) {
      case PreHeader():
        if (!sawHeader) header = r;
        sawHeader = true;
      case PreUser(:final id):
        sawHeader = true;
        if (_writer.adoptUser(id).rotated) rotated = true;
      case PreLine():
        sawHeader = true;
        final hook = _redactOf();
        if (r.redacted || r.synthetic) {
          _write(r.level, r.body, false);
        } else if (hook == null) {
          _write(r.level, r.body, true);
        } else {
          assert(allowRedact);
          _redacted(r, hook);
        }
      case PreBad():
        break;
    }
    records += 1;
    _lastApplied = true;
  }

  void _redacted(PreLine r, RedactHook hook) {
    final decoded = LineEncoder.decodeBody(r.body);
    if (decoded == null) {
      // 有钩子却解不出来：不能不经脱敏就写，丢弃并计数
      DropCounter.add(r.level, r.ts);
      return;
    }
    final (line, synthetic, truncated) = decoded;
    final prev = Reentrancy.active;
    Reentrancy.active = true;
    LogLine? out;
    try {
      out = hook(line);
    } catch (e) {
      // 钩子抛异常：该行丢弃（宁丢不漏 PII）
      _report(e);
      out = null;
    } finally {
      Reentrancy.active = prev;
    }
    if (out == null) return;
    Encoded enc;
    try {
      // redact 不能改 ts（ADR 0024 决定 10）
      enc = LineEncoder.encode(
        out.copyWith(ts: line.ts),
        synthetic: synthetic,
        forceTruncated: truncated,
      );
    } catch (e) {
      _report(e);
      return;
    }
    _write(out.level, enc.body, true);
  }

  void _write(LogLevel level, Uint8List body, bool filter) {
    final o = _writer.adoptLine(level, body, filter);
    if (o.failed) failedWrites = true;
    if (o.noSession) {
      stalled = true;
      return;
    }
    if (o.rotated) rotated = true;
    if (o.fatal) fatal = true;
    if (o.deadlineChanged) deadlineChanged = true;
    if (o.tombstone) tombstone = true;
  }
}

/// 孤儿 pre 文件被哪个会话认领了（meta.json 的 `pre`）：proc 目录名 + session_id。
class PreClaim {
  const PreClaim(this.procDir, this.sessionId);

  final String procDir;
  final String sessionId;
}

int? _firstLineTs(Uint8List data) {
  var start = 0;
  for (var i = 0; i < data.length; i++) {
    if (data[i] == 0x0A) {
      final r = PreRecords.parse(data, start, i);
      if (r is PreLine) return r.ts;
      start = i + 1;
    }
  }
  return null;
}

PreHeader? _firstHeader(Uint8List data) {
  final nl = data.indexOf(0x0A);
  if (nl <= 0) return null;
  final r = PreRecords.parse(data, 0, nl);
  return r is PreHeader ? r : null;
}

extension EngineAdoption on Engine {
  /// 孤儿 pre 文件（flock 拿得到 = 写它的进程已死，且不是本进程的）：startup() 里、恢复旧会话之前收编（简报 §1.2-3 / 4）。
  /// - 被本进程名下某个会话的 meta.pre 认领 = 那次收编没提交就崩了 → 清掉该会话已写的段与游标进度，从 pre 文件重做；
  /// - 被别的进程名下的会话认领 → 留给那个进程；
  /// - 没人认领 = configure 之前进程就死了 → 按头记录新建一个会话目录。
  /// 都用同一个收编函数写入（临时 writer，不碰活会话），提交后交给现有恢复流程。禁用时照样收编。
  Future<void> adoptOrphans(RedactHook? redact, void Function(Object) report) async {
    if (install == null) return;
    final names = (await Fs.list(preDir)).where((n) => n.endsWith(PreFile.suffix)).toList()..sort();
    if (names.isEmpty) return;
    final dead = <OrphanPre>[];
    // 拿得到锁的孤儿一律收编，不看年龄（「7 天」只用于驱逐时删除没能收编的孤儿）；本进程（同 token）的不打开
    for (final n in names) {
      final o = await OrphanPre.tryAcquire(Fs.join(preDir, n), token);
      if (o != null) dead.add(o);
    }
    if (dead.isEmpty) return;
    final claims = await _preClaims();
    for (final o in dead) {
      try {
        // 长度 0 = 已提交（unlink 失败时截成 0 的那种）：删掉，不收编、不重做
        if (await o.length == 0) {
          await Fs.deleteFile(o.path);
          continue;
        }
        final claim = claims[o.name];
        if (claim == null) {
          await _adoptAsNewSession(o, redact, report);
        } else if (claim.procDir == Fs.baseName(procDir)) {
          await _readopt(claim.sessionId, o, redact, report);
        }
      } catch (e) {
        report(e);
      } finally {
        o.release();
      }
    }
  }

  /// 扫全部 `proc-*` 的会话 meta.json，收集 `pre` 认领（只在有死掉的孤儿 pre 文件时才扫）。
  Future<Map<String, PreClaim>> _preClaims() async {
    final out = <String, PreClaim>{};
    for (final p in await Fs.list(root)) {
      if (!p.startsWith('proc-')) continue;
      final pdir = Fs.join(root, p);
      for (final sid in await Fs.list(pdir)) {
        // 当前会话跳过（它不会认领孤儿）
        if (!Ids.isUuid(sid) || sid == current?.meta.sessionId) continue;
        final b = await Fs.read(Fs.join(Fs.join(pdir, sid), 'meta.json'));
        final m = b == null ? null : SessionMeta.decode(b);
        final pre = m?.pre;
        if (pre != null) out[pre] = PreClaim(p, sid);
      }
    }
    return out;
  }

  Future<void> _adoptAsNewSession(OrphanPre o, RedactHook? redact, void Function(Object) report) async {
    final data = await o.readAll();
    if (data == null) return;
    // 没有任何完整记录（第一次写就撕裂）：没东西可收编，删掉
    if (!data.contains(0x0A)) {
      await Fs.deleteFile(o.path);
      return;
    }
    final head = _firstHeader(data);
    final sid = Ids.newV4();
    final no = await allocateSessionNo();
    if (no == null) return;
    final dir = Fs.join(procDir, sid);
    if (!await Fs.ensureDir(dir)) return;
    // 缺头记录：started_ms 取首行 ts，没有行才取 mtime
    final started = head?.startedMs ?? _firstLineTs(data) ?? (await Fs.mtimeMs(o.path) ?? clock.wallMs());
    final meta = SessionMeta(
      sid,
      no,
      started,
      head?.device ?? device,
      head?.process ?? processName,
      install?.installId,
      o.name,
    );
    if (!await Fs.writeAtomic(Fs.join(dir, 'meta.json'), meta.encode())) {
      await Fs.remove(dir);
      return;
    }
    await _adoptInto(dir, meta, data, o, redact, report);
  }

  Future<void> _readopt(String sid, OrphanPre o, RedactHook? redact, void Function(Object) report) async {
    final dir = Fs.join(procDir, sid);
    final mb = await Fs.read(Fs.join(dir, 'meta.json'));
    final meta = mb == null ? null : SessionMeta.decode(mb);
    if (meta == null) return;
    // 会话还活着（别的实例持有会话锁）：不动
    final lock = await SessionLock.tryAcquire(dir);
    if (lock == null) return;
    try {
      final data = await o.readAll();
      if (data == null) return;
      // 收编未提交：清掉该会话目录下已写的段与游标里的段进度（保留 last_state 等前后台 / 收尾字段），从 pre 文件重做
      for (final n in await Fs.list(dir)) {
        if (Segments.parseName(n) != null) await Fs.remove(Fs.join(dir, n));
      }
      final cf = Fs.join(dir, 'cursor.json');
      final cb = await Fs.read(cf);
      final c = cb == null ? null : Cursor.decode(cb);
      if (c != null) await Fs.writeAtomic(cf, c.copy(extractedThroughOseq: 0, ctxThroughSeq: 0).encode());
      await _adoptInto(dir, meta, data, o, redact, report);
    } finally {
      lock.release();
    }
  }

  /// 用临时 writer 把 `data` 收编进 `dir` 的会话：段按写入侧的状态机生成（未封的段留 `.open`，恢复流程统一封）。
  /// 有任何行没写成 → 不提交：删掉这次写出的段，meta.pre 与 pre 文件原样保留，下次启动重做。
  /// 提交 = unlink pre 文件（失败则截成 0），再清 meta.pre。
  Future<void> _adoptInto(
    String dir,
    SessionMeta meta,
    Uint8List data,
    OrphanPre o,
    RedactHook? redact,
    void Function(Object) report,
  ) async {
    final tw = Writer(clock, host);
    tw.setConfigSnapshot(configCache);
    tw.startSession(dir, meta.sessionId);
    final a = Adopter(tw, () => redact, report);
    try {
      a.feed(data, 0);
    } finally {
      // 临时 writer 的段句柄：未封的留 `.open`、已换出的段直接关掉（恢复流程统一 fsync + 封）
      for (final j in tw.takePendingSeals()) {
        try {
          await j.out?.close();
        } catch (_) {}
      }
      tw.abandonSession();
    }
    if (a.stalled || a.failedWrites) {
      for (final n in await Fs.list(dir)) {
        if (Segments.parseName(n) != null) await Fs.remove(Fs.join(dir, n));
      }
      return;
    }
    if (!await o.commit()) return;
    await Fs.writeAtomic(Fs.join(dir, 'meta.json'), meta.copyWith(pre: null).encode());
  }
}
