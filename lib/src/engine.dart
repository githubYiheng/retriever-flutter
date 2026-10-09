// 后台状态机：封段处理、物化、出站箱、驱逐、恢复、配置、上传队列决策。对位 Android `core/Engine.kt`（物化 / 出站箱 /
// 上传 / 恢复 / 收编在同名文件里，以 extension 挂在 Engine 上，同 Kotlin 的扩展函数）。
//
// **只在引擎串行队列里访问**（RetrieverClient 保证串行），所以不加锁。一律异步 IO（v3 §7）；网络在队列外发。

import 'dart:async';
import 'dart:typed_data';

import 'clock.dart';
import 'config.dart';
import 'fs.dart';
import 'ids.dart';
import 'limits.dart';
import 'line_encoder.dart';
import 'markers.dart';
import 'materializer.dart';
import 'model.dart';
import 'outbox.dart';
import 'platform.dart';
import 'pre.dart';
import 'public_api.dart';
import 'drop_counter.dart';
import 'root_purge.dart';
import 'segments.dart';
import 'writer.dart';

/// 一个会话的物化状态（meta + cursor + 已封段索引）。
class SessionRecord {
  SessionRecord(this.meta, this.dir, this.cursor, this.sealed);

  final SessionMeta meta;
  final String dir;
  Cursor cursor;

  /// 已封段（RETAINED），按 seg_no 升序。
  final List<SegInfo> sealed;
}

class FailCount {
  FailCount(this.count, this.otherSuccess);

  int count;
  bool otherSuccess;
}

class AckedRange {
  const AckedRange(this.sessionId, this.from, this.to);

  final String sessionId;
  final int from;
  final int to;
}

class PendingMapping {
  const PendingMapping(this.user, this.digest);

  final String? user;
  final String digest;
}

/// 本批要带的 drops / closed_sessions（ADR 0019 决定 2：按文件顺序取最旧的未在途 N 条，不合并、不计数）。
class Extras {
  const Extras(this.drops, this.closed);

  final List<DropEntry> drops;
  final List<ClosedSession> closed;
}

class _Synth {
  const _Synth(this.msg, this.tag, this.attrs);

  final String msg;
  final String tag;
  final Map<String, Object?>? attrs;
}

class _ResetCounts {
  const _ResetCounts(this.batches, this.sessions);

  final int batches;
  final int sessions;
}

class _Bumped {
  const _Bumped(this.info, this.sessionNo, this.repaired, this.reset);

  final InstallInfo info;
  final int sessionNo;
  final bool repaired;
  final _ResetCounts? reset;
}

sealed class _Repair {
  const _Repair();
}

final class _RepairFound extends _Repair {
  const _RepairFound(this.info);

  final InstallInfo info;
}

final class _RepairNone extends _Repair {
  const _RepairNone();
}

final class _RepairFailed extends _Repair {
  const _RepairFailed();
}

class Engine {
  Engine({
    required this.root,
    required this.processName,
    required this.key,
    required this.baseUrl,
    required this.sdkVersion,
    required this.clock,
    required this.platform,
    required this.writer,
    required this.device,
    required this.token,
    required this.foregroundNow,
  }) : procDir = Fs.join(root, 'proc-$processName'),
       outboxDir = Fs.join(root, 'outbox'),
       locks = RootLocks(root) {
    effective = ConfigCache.effective(null, writer.host, clock.wallMs(), clock.monoMs());
  }

  final String root;
  final String processName;
  final String procDir;
  final String outboxDir;
  final RootLocks locks;
  final Clock clock;
  final RetrieverPlatform platform;
  final Writer writer;
  final Device device;

  /// 本进程的 token（v3 §1）：pre 文件名前缀等于它的一律不当孤儿。
  final String token;

  /// 当前前后台（垫片 tracker 的值，可空）：bootstrap 写初始 last_state 用。
  final bool? Function() foregroundNow;

  String key;

  String baseUrl;
  String sdkVersion;

  /// key 指纹（ADR 0024 决定 7）：sha256(key) 前 16 位十六进制，key 为空 = 空串。
  String get keyFp => Ids.keyFingerprint(key);

  /// 宿主默认只存一份（在写入侧，configure 在宿主调用里同步改它；引擎从同一处读）。
  HostDefaults get host => writer.host;

  /// 本实例收编的 pre 文件名（bootstrap 时记进 meta.json 的 `pre`；提交 / 放弃后为 null）。
  String? adoptPre;

  /// 会话目录 / 段文件在运行中消失：交给客户端重新 bootstrap（简报 §4.5）。
  void Function()? onVanished;

  /// 物化时段文件读失败（非 ENOENT）：本次不推进，定时重试（ADR 0024 决定 3）。
  bool readRetryPending = false;

  /// 本次 bootstrap 之后恢复旧会话已经成功做完：之前一律不驱逐。
  bool recovered = false;

  /// bootstrap 判出的待写合成行（install 修复 / 重建）：bootstrap 没成功时留着，重试成功后照写。
  final List<_Synth> _pendingSynth = <_Synth>[];

  InstallInfo? install;
  SessionRecord? current;
  final Map<String, SessionRecord> others = <String, SessionRecord>{};

  final Map<String, BatchMeta> metas = <String, BatchMeta>{};
  final Set<DropEntry> embeddedDrops = <DropEntry>{};
  final Set<String> embeddedClosed = <String>{};
  PendingMapping? pendingMapping;
  MappingState? mapping;

  ConfigCache? configCache;
  late EffectiveConfig effective;

  /// 上次尝试拉配置的单调时刻（null = 本进程还没拉过）。
  int? lastConfigFetchMono;

  BackoffState backoff = BackoffState();
  final Map<String, FailCount> fails = <String, FailCount>{};
  String? inFlight;
  int? lastRequestMono;

  /// 当前会话目录 `lock` 文件上的锁（进程存活期间一直持有）。
  SessionLock? sessionLock;

  /// 最近被 2xx 确认的 primary 区间（flush 判断「这一批已确认」用；只留最近 512 个）。
  final List<AckedRange> ackedRanges = <AckedRange>[];

  /// 本进程已生成过 backfill 的段（`<session_id>:<seg_no>`）。
  final Set<String> backfilledSegs = <String>{};

  /// 本进程写出的批文件计数（判断「这次封段有没有产生批次」）。
  int batchesWritten = 0;
  String todayDay = '';
  int todayCount = 0;

  /// 本进程的内存开关（引擎侧镜像；写入侧以 Writer 的开关为准）。
  bool enabled = true;

  /// 禁用标记写失败：内存照样禁用，每次调度 tick 重试（ADR 0020 决定 2）。
  bool markerPending = false;
  String? previousAppVersion;

  // MARK: 路径

  String get installFile => Fs.join(root, 'install.json');
  String get backoffFile => Fs.join(root, 'backoff.json');
  String get mappingFile => Fs.join(root, 'mapping.json');
  String get dropsFile => Fs.join(root, 'drops.jsonl');
  String get sessionsFile => Fs.join(root, 'sessions.jsonl');
  String get configFile => Fs.join(root, 'config.json');
  String get disabledFile => Markers.file(root);
  String get preDir => Fs.join(root, PreFile.dir);

  String get sdkHeader => 'retriever-flutter/$sdkVersion';

  String endpoint(String path) {
    var b = baseUrl;
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return '$b/$path';
  }

  // MARK: 启动

  /// 建目录、install.json（首次生成 tmp → flush → rename，失败方重读；读到但解析不了 = 损坏，同一把锁内从会话 meta.json 的
  /// 副本修复身份，没有副本才清空 root 新建，都留痕，ADR 0019 决定 7 / 8）、计数器 +1、新会话。
  /// meta.json 必须写成，写不成 = bootstrap 失败（ADR 0024 决定 2）。收编中时 meta 记 `pre`。
  /// `emitSynth` = false：合成行留到调用方 [writePendingSynth]（configure 路径：先交接 pre 文件，合成行排在 configure 之前的行之后）。
  Future<bool> bootstrap({bool emitSynth = true}) async {
    if (!await Fs.ensureDir(root) || !await Fs.ensureDir(procDir) || !await Fs.ensureDir(outboxDir)) return false;
    final result = await locks.withDirLock(_bumpInstallLocked);
    if (result == null) return false;
    // install 修复 / 重建的合成行先记下：后面的步骤失败、bootstrap 重试时照样写
    if (result.repaired) {
      _pendingSynth.add(
        const _Synth('install.json unreadable; identity repaired from session meta', 'rtv.install_repaired', null),
      );
    }
    final r = result.reset;
    if (r != null) {
      _pendingSynth.add(
        _Synth('install.json unreadable; local state discarded', 'rtv.install_reset', <String, Object?>{
          'batches': r.batches,
          'sessions': r.sessions,
        }),
      );
      // 清空时 root 整个改了名：锁句柄还开在旧的 upload.lock 上，放掉，之后按需在新 root 重开
      locks.close();
    }
    final inst = result.info;
    final now = clock.wallMs();
    final sid = Ids.newV4();
    final dir = Fs.join(procDir, sid);
    if (!await Fs.ensureDir(dir)) return false;
    // 先加会话锁、再写 meta：别的进程的恢复流程永远看不到「有 meta、没锁」的活会话
    await lockSessionDir(dir);
    final meta = SessionMeta(sid, result.sessionNo, now, device, processName, inst.installId, adoptPre);
    if (!await Fs.writeAtomic(Fs.join(dir, 'meta.json'), meta.encode())) {
      releaseSessionLock();
      await Fs.remove(dir);
      return false;
    }
    install = inst;
    final fg = foregroundNow();
    final cursor = Cursor(lastState: fg == null ? null : (fg ? 'fg' : 'bg'), lastStateMs: now);
    final rec = SessionRecord(meta, dir, cursor, <SegInfo>[]);
    current = rec;
    await writeCursor(rec);
    writer.startSession(dir, sid);
    await _loadPersistentState();
    if (emitSynth) writePendingSynth();
    return true;
  }

  /// 把 bootstrap 判出的合成行写下（收编中时进 pre 文件 r = 1，排在 configure 之前的行之后）。
  void writePendingSynth() {
    final now = clock.wallMs();
    for (final s in _pendingSynth) {
      final enc = LineEncoder.encode(
        LogLine(ts: now, level: LogLevel.warn, msg: s.msg, tag: s.tag, attrs: s.attrs),
        synthetic: true,
      );
      writer.append(LogLevel.warn, enc.body);
    }
    _pendingSynth.clear();
  }

  /// 收编提交后清掉 meta.json 的 `pre`（写不成也无妨：所指文件已不在 = 已提交）。
  Future<void> clearMetaPre(SessionRecord rec) async {
    if (rec.meta.pre == null) return;
    await Fs.writeAtomic(Fs.join(rec.dir, 'meta.json'), rec.meta.copyWith(pre: null).encode());
  }

  /// 收编的 pre 文件在 bootstrap 之后才定下（configure 期间新建）：把 `pre` 补写进当前会话的 meta.json。
  Future<bool> setMetaPre(String name) async {
    final rec = current;
    if (rec == null) return false;
    if (rec.meta.pre == name) return true;
    final m = rec.meta.copyWith(pre: name);
    if (!await Fs.writeAtomic(Fs.join(rec.dir, 'meta.json'), m.encode())) return false;
    current = SessionRecord(m, rec.dir, rec.cursor, rec.sealed);
    return true;
  }

  /// 给孤儿 pre 文件分配一个 session_no（install.json 计数器 +1；install 已换了就不分配）。
  Future<int?> allocateSessionNo() async {
    final iid = install?.installId;
    if (iid == null) return null;
    return locks.withDirLock<int?>(() async {
      final b = await Fs.read(installFile);
      final inst = b == null ? null : InstallInfo.decode(b);
      if (inst == null || inst.installId != iid) return null;
      inst.sessionCounter += 1;
      if (!await Fs.writeAtomic(installFile, inst.encode())) return null;
      return inst.sessionCounter;
    });
  }

  /// 清空 / 目录消失后重建之前：丢掉内存里属于旧 root 的全部状态。
  void resetState() {
    metas.clear();
    embeddedDrops.clear();
    embeddedClosed.clear();
    pendingMapping = null;
    mapping = null;
    others.clear();
    fails.clear();
    inFlight = null;
    backoff = BackoffState();
    ackedRanges.clear();
    backfilledSegs.clear();
    configCache = null;
    lastConfigFetchMono = null;
    install = null;
    current = null;
    readRetryPending = false;
    recovered = false;
    _pendingSynth.clear();
  }

  Future<void> lockSessionDir(String dir) async {
    releaseSessionLock();
    sessionLock = await SessionLock.tryAcquire(dir);
  }

  void releaseSessionLock() {
    sessionLock?.release();
    sessionLock = null;
  }

  /// 区分「读不到」与「读到了但解析不了」：不存在 → 首次创建；存在但读失败 → 本次失败、稍后重试，**绝不重建**；
  /// 读到字节（含 0 字节）却解析不了 → 损坏：从 meta.json 的副本修复；只有找不到任何副本才清空重建。
  Future<_Bumped?> _bumpInstallLocked() async {
    var repaired = false;
    _ResetCounts? reset;
    InstallInfo? inst;
    if (!await Fs.exists(installFile)) {
      inst = await _createInstallLocked();
      if (inst == null) return null;
    } else {
      final bytes = await Fs.readBytesOrNull(installFile);
      if (bytes == null) return null;
      inst = InstallInfo.decode(bytes);
      if (inst == null) {
        final r = await _repairFromMetasLocked();
        switch (r) {
          case _RepairFailed():
            return null;
          case _RepairFound(:final info):
            repaired = true;
            inst = info;
          case _RepairNone():
            reset = await _discardRootLocked();
            if (reset == null) return null;
            inst = await _createInstallLocked();
            if (inst == null) return null;
        }
      }
    }
    inst.sessionCounter += 1;
    if (!await Fs.writeAtomic(installFile, inst.encode())) return null;
    return _Bumped(inst, inst.sessionCounter, repaired, reset);
  }

  /// ADR 0019 决定 7：扫全部 `proc-<name>/<sid>/meta.json`，取 `started_ms` 最大且带 `install_id` 的那个 id，
  /// 会话计数器 = 该 id 下最大的 session_no。有 meta 存在却读不了 → Failed；没有任何带 install_id 的 meta → None。
  Future<_Repair> _repairFromMetasLocked() async {
    final found = <SessionMeta>[];
    final top = await Fs.listStrict(root);
    if (top == null) return const _RepairFailed();
    for (final p in top) {
      if (!p.startsWith('proc-')) continue;
      final pdir = Fs.join(root, p);
      final sids = await Fs.listStrict(pdir);
      if (sids == null) return const _RepairFailed();
      for (final sid in sids) {
        if (!Ids.isUuid(sid)) continue;
        final sdir = Fs.join(pdir, sid);
        final names = await Fs.listStrict(sdir);
        if (names == null) return const _RepairFailed();
        if (!names.contains('meta.json')) continue;
        final b = await Fs.readBytesOrNull(Fs.join(sdir, 'meta.json'));
        if (b == null) return const _RepairFailed();
        final m = SessionMeta.decode(b);
        if (m != null && m.installId != null) found.add(m);
      }
    }
    if (found.isEmpty) return const _RepairNone();
    var best = found.first;
    for (final m in found) {
      if (m.startedMs > best.startedMs) best = m;
    }
    final id = best.installId!;
    final mine = found.where((m) => m.installId == id).toList();
    var maxNo = 0;
    var minStarted = mine.first.startedMs;
    for (final m in mine) {
      if (m.sessionNo > maxNo) maxNo = m.sessionNo;
      if (m.startedMs < minStarted) minStarted = m.startedMs;
    }
    return _RepairFound(InstallInfo(id, maxNo, minStarted));
  }

  /// ADR 0019 决定 8：没有任何副本 → 按清空处理：先数作废的出站箱批与会话目录，再把 root 整个改名移走、重建空目录。
  Future<_ResetCounts?> _discardRootLocked() async {
    final batches = (await Fs.list(outboxDir)).where((n) => OutboxName.parse(n) != null).length;
    var sessions = 0;
    for (final p in await Fs.list(root)) {
      if (p.startsWith('proc-')) sessions += (await Fs.list(Fs.join(root, p))).where(Ids.isUuid).length;
    }
    if (await moveRootAside() == null) return null;
    if (!await Fs.ensureDir(root) || !await Fs.ensureDir(procDir) || !await Fs.ensureDir(outboxDir)) return null;
    return _ResetCounts(batches, sessions);
  }

  /// 首次生成：tmp（独占创建）→ flush → rename；已存在（并发的另一方先写了）则放弃自己的，重读。
  Future<InstallInfo?> _createInstallLocked() async {
    final info = InstallInfo(Ids.newV4(), 0, clock.wallMs());
    final tmp = Fs.join(root, '.install.json.tmp-${Ids.newV4()}');
    if (await Fs.writeAtomic(tmp, info.encode())) {
      if (await Fs.exists(installFile) || !await Fs.rename(tmp, installFile)) await Fs.remove(tmp);
    }
    final b = await Fs.read(installFile);
    return b == null ? null : InstallInfo.decode(b);
  }

  // MARK: 清空（ADR 0019 决定 9：先改名再删）

  Future<String?> moveRootAside() => RootPurge.moveAside(root);

  Future<void> removePurgeLeftovers() => RootPurge.removeLeftovers(root);

  // MARK: 启用状态（ADR 0020 决定 2）

  /// 禁用标记三态（ADR 0024 决定 6）：未知按禁用处理。
  Future<MarkerState> markerState() => Markers.state(root);

  /// 标记在或判定不了（未知按禁用，fail-closed）。
  Future<bool> disabledMarked() async => await markerState() != MarkerState.absent;

  /// 上传 / 拉配置 / 排后台作业 = 本进程内存开关 ∧ 盘上无标记（每次决策判一次）。
  Future<bool> uploadAllowed() async => writer.isEnabled && !await disabledMarked();

  /// 写禁用标记；失败记 [markerPending]，由调度 tick 重试。
  Future<void> markDisabled() async {
    markerPending = !await Markers.mark(root);
  }

  /// 删禁用标记；删不掉返回 false（调用方保持禁用：宁可不传，也不误传）。
  Future<bool> clearDisabledMarker() async {
    markerPending = false;
    return Markers.clear(root);
  }

  /// 读跨启动状态。退避 / 映射 / 配置缓存都带 key 指纹 + baseUrl（ADR 0024 决定 7）：与当前不同——退避与暂停不继承、
  /// 映射按未确认、配置缓存按身份过期并在启动时重拉。旧版本写的文件没有这两个键：视为与当前相同，并把当前值补写进去。
  Future<void> _loadPersistentState() async {
    final nowWall = clock.wallMs();
    final nowMono = clock.monoMs();
    final fp = keyFp;
    final bb = await Fs.read(backoffFile);
    if (bb != null) {
      final s = BackoffState.decodeColdStart(bb, nowWall, nowMono);
      if (s != null) {
        if (sameIdentity(s.hasIdentity, s.keyFp, s.baseUrl)) {
          backoff = s;
          if (!s.hasIdentity) await persistBackoff();
        } else {
          backoff = s.forIdentity(fp, baseUrl);
          await persistBackoff();
        }
      }
    }
    final mb = await Fs.read(mappingFile);
    if (mb != null) {
      final m = MappingState.decode(mb);
      mapping = m;
      if (m != null && !m.hasIdentity) {
        final filled = m.withIdentity(fp, baseUrl);
        mapping = filled;
        await Fs.writeAtomic(mappingFile, filled.encode());
      }
    }
    final cb = await Fs.read(configFile);
    if (cb != null) {
      final c = ConfigCache.decodeFile(cb, host, fp, baseUrl, writer.currentUser);
      configCache = c;
      if (c != null && c.legacyIdentity) await Fs.writeAtomic(configFile, c.encodeFile());
    }
    effective = ConfigCache.effective(configCache, host, nowWall, nowMono);
    writer.setConfigSnapshot(configCache);
  }

  /// 文件里记的身份与当前相同；两个键都没有（旧版本写的）按相同处理；只要有且任一不符 = 不同。
  bool sameIdentity(bool present, String? fp, String? base) => !present || (fp == keyFp && base == baseUrl);

  /// configure / reconfigure 后：key 指纹或 baseUrl 变了 → 清鉴权暂停与退避、映射按未确认、配置缓存按身份过期。返回是否变了。
  Future<bool> applyIdentity(String newKey, String newBaseUrl) async {
    final oldFp = keyFp;
    final oldBase = baseUrl;
    key = newKey;
    baseUrl = newBaseUrl;
    if (keyFp == oldFp && baseUrl == oldBase) return false;
    backoff = backoff.forIdentity(keyFp, baseUrl);
    await persistBackoff();
    configCache = configCache?.staleForIdentity();
    lastConfigFetchMono = null;
    return true;
  }

  // MARK: 状态文件

  Future<void> writeCursor(SessionRecord s) async {
    await Fs.writeAtomic(Fs.join(s.dir, 'cursor.json'), s.cursor.encode());
  }

  Future<void> persistBackoff() async {
    backoff.keyFp = keyFp;
    backoff.baseUrl = baseUrl;
    await Fs.writeAtomic(backoffFile, backoff.encode());
  }

  Future<void> setLastState(String state) async {
    final cur = current;
    if (cur == null) return;
    cur.cursor.lastState = state;
    cur.cursor.lastStateMs = clock.wallMs();
    await writeCursor(cur);
  }

  // MARK: 封段处理（flush + close → rename → 物化 → 原子写 cursor）

  /// 处理写入侧交来的全部封段任务；返回是否有新批次产生。收编提交之前什么都不做（会话 S 不物化、不记墓碑，ADR 0023）。
  Future<bool> processSeals() async {
    if (writer.isAdopting) return false;
    final jobs = writer.takePendingSeals();
    final cur = current;
    if (jobs.isEmpty || cur == null) {
      await flushTombstones();
      return false;
    }
    var vanished = false;
    for (final j in jobs) {
      final out = j.out;
      if (out != null) {
        try {
          await out.flush();
        } catch (_) {
          // 流已坏（写失败路径）：照常 rename
        }
        try {
          await out.close();
        } catch (_) {}
      }
      final info = j.info;
      final openFile = info.path;
      final sealedFile = Fs.join(Fs.parentOf(openFile), Segments.name(info.segNo, false));
      if (await Fs.rename(openFile, sealedFile)) {
        info.path = sealedFile;
      } else if (await Fs.isMissing(openFile) && !await Fs.exists(sealedFile) && !await Fs.isDirectory(cur.dir)) {
        // 会话目录在运行中被删：这一段的行随之没了，按段计数（同 iOS），重新 bootstrap（简报 §4.5）
        vanished = true;
        if (info.lineCount > 0) {
          DropCounter.putBack(DropSnapshot(info.lineCount, info.errorLines, info.firstTs, info.lastTs));
        }
        continue;
      }
      if (Fs.parentOf(openFile) == cur.dir) cur.sealed.add(info);
    }
    if (vanished) onVanished?.call();
    final last = jobs.last;
    final noCtx = jobs.any((j) => j.noCtx);
    final ignoreCap = jobs.any(
      (j) => j.reason == SealReason.flush || j.reason == SealReason.fatal || j.reason == SealReason.shutdown,
    );
    final before = batchesWritten;
    await materialize(cur, last.oseqAtSeal, last.seqAtSeal, noCtx, ignoreCap);
    await flushTombstones();
    await evictIfNeeded();
    return batchesWritten != before;
  }

  /// 物化积压（段读失败没推进的义务行）：定时器上重试。
  Future<void> retryBacklog() async {
    final cur = current;
    if (cur == null || writer.isAdopting) return;
    var lastOseq = 0;
    for (final i in cur.sealed) {
      if (i.lastOseq > lastOseq) lastOseq = i.lastOseq;
    }
    readRetryPending = false;
    if (lastOseq <= cur.cursor.extractedThroughOseq) return;
    await materialize(cur, lastOseq, cur.sealed.isEmpty ? 0 : cur.sealed.last.lastSeq, false, false);
  }

  // MARK: 墓碑与终态（drops.jsonl / sessions.jsonl：追加写，各自上限 1000 条）

  int lastAckAge(int at) => backoff.lastAckMs < 0 ? -1 : (at - backoff.lastAckMs < 0 ? 0 : at - backoff.lastAckMs);

  /// 写入侧的 write_failed 墓碑：可写时落盘（收编提交之前不记）。
  Future<void> flushTombstones() async {
    if (writer.isAdopting) return;
    final failed = writer.takeFailed();
    final cur = current;
    if (failed.isEmpty || cur == null) {
      if (failed.isNotEmpty) writer.putBackFailed(failed);
      return;
    }
    final entries = [
      for (final f in failed)
        DropEntry(cur.meta.sessionId, f.from, f.to, f.n, DropReason.writeFailed, f.atMs, lastAckAge(f.atMs)),
    ];
    if (!await appendDrops(entries)) writer.putBackFailed(failed);
  }

  Future<bool> appendDrops(List<DropEntry> entries) async {
    if (entries.isEmpty) return true;
    final r = await locks.withDirLock(() async {
      if (!await Fs.append(dropsFile, Jsonl.encodeDrops(entries))) return false;
      final all = await readDropsLocked();
      if (all.length > ClientConstants.dropsFileMaxEntries) {
        await Fs.writeAtomic(
          dropsFile,
          Jsonl.encodeDrops(capDrops(all, embeddedDrops, ClientConstants.dropsFileMaxEntries)),
        );
      }
      return true;
    });
    return r ?? false;
  }

  /// 会话终态落盘（只为 last_oseq > 0 的会话写，调用方保证）；超上限删最旧的未在途条目。
  Future<bool> appendClosed(List<ClosedSession> entries) async {
    if (entries.isEmpty) return true;
    final r = await locks.withDirLock(() async {
      if (!await Fs.append(sessionsFile, Jsonl.encodeClosed(entries))) return false;
      final all = await readClosedLocked();
      if (all.length > ClientConstants.dropsFileMaxEntries) {
        await Fs.writeAtomic(
          sessionsFile,
          Jsonl.encodeClosed(capClosed(all, embeddedClosed, ClientConstants.dropsFileMaxEntries)),
        );
      }
      return true;
    });
    return r ?? false;
  }

  Future<List<DropEntry>> readDropsLocked() async => [
    for (final o in Jsonl.parse(await Fs.read(dropsFile))) ?DropEntry.decode(o),
  ];

  Future<List<ClosedSession>> readClosedLocked() async => [
    for (final o in Jsonl.parse(await Fs.read(sessionsFile))) ?ClosedSession.decode(o),
  ];

  // MARK: 杂项

  bool isAcked(String sessionId, int oseq) =>
      ackedRanges.any((r) => r.sessionId == sessionId && r.from <= oseq && oseq <= r.to);

  int todayBatches(int now) {
    final d = Day.fromMs(now);
    if (d != todayDay) {
      todayDay = d;
      todayCount = 0;
    }
    return todayCount;
  }

  void countBatch(int now) {
    todayBatches(now);
    todayCount += 1;
  }

  /// 所有自己进程目录里的会话记录（当前 + 旧；旧的按 started_ms）。
  List<SessionRecord> get ownSessions {
    final out = <SessionRecord>[];
    final c = current;
    if (c != null) out.add(c);
    final rest = others.values.toList()
      ..sort((a, b) {
        final x = a.meta.startedMs.compareTo(b.meta.startedMs);
        return x != 0 ? x : a.meta.sessionNo.compareTo(b.meta.sessionNo);
      });
    out.addAll(rest);
    return out;
  }

  /// 有可上传的批（进后台时据此排 JobScheduler 作业）。
  Future<bool> hasUploadWork() async =>
      key.isNotEmpty && effective.config.uploadEnabled && metas.values.any((m) => m.prio < 3) && await uploadAllowed();

  /// 可用空间（v3 §3：channel 调用 2 s 超时，超时 / 失败 = 未知）。
  Future<int?> availableBytes() async {
    try {
      return await platform.availableBytes().timeout(
        const Duration(milliseconds: ClientConstants.channelCallTimeoutMs),
      );
    } catch (_) {
      return null;
    }
  }

  /// drops.jsonl 超上限（ADR 0019 决定 4）：先无损合并——同会话、同 reason、区间相接或重叠的并成一条（n = 并集长度），
  /// `backfill_evicted`（恒 0..0）同会话 n 相加；仍超出删最旧的未在途条目。在途条目与不合法区间原样保留、不参与合并。
  static List<DropEntry> capDrops(List<DropEntry> all, Set<DropEntry> inFlight, int limit) {
    if (all.length <= limit) return all;
    final slots = <(int, DropEntry)>[];
    final groups = <String, List<(int, DropEntry)>>{};
    for (var i = 0; i < all.length; i++) {
      final e = all[i];
      final lossless = e.reason == DropReason.backfillEvicted || (e.oseqFrom >= 1 && e.n == e.oseqTo - e.oseqFrom + 1);
      if (inFlight.contains(e) || !lossless) {
        slots.add((i, e));
      } else {
        groups.putIfAbsent('${e.sessionId}|${e.reason}', () => <(int, DropEntry)>[]).add((i, e));
      }
    }
    DropEntry join(DropEntry a, DropEntry b, int to, int n) => a.copyWith(
      oseqTo: to,
      n: n,
      atMs: a.atMs > b.atMs ? a.atMs : b.atMs,
      lastAckAgeMs: a.lastAckAgeMs > b.lastAckAgeMs ? a.lastAckAgeMs : b.lastAckAgeMs,
    );
    for (final g in groups.values) {
      if (g[0].$2.reason == DropReason.backfillEvicted) {
        var m = g[0].$2;
        for (var k = 1; k < g.length; k++) {
          m = join(m, g[k].$2, m.oseqTo, m.n + g[k].$2.n);
        }
        slots.add((g[0].$1, m));
        continue;
      }
      final sorted = List.of(g)
        ..sort((a, b) {
          final c = a.$2.oseqFrom.compareTo(b.$2.oseqFrom);
          return c != 0 ? c : a.$1.compareTo(b.$1);
        });
      var pos = sorted[0].$1;
      var cur = sorted[0].$2;
      for (var k = 1; k < sorted.length; k++) {
        final (p, e) = sorted[k];
        if (e.oseqFrom <= cur.oseqTo + 1) {
          final to = cur.oseqTo > e.oseqTo ? cur.oseqTo : e.oseqTo;
          cur = join(cur, e, to, to - cur.oseqFrom + 1);
          if (p < pos) pos = p;
        } else {
          slots.add((pos, cur));
          pos = p;
          cur = e;
        }
      }
      slots.add((pos, cur));
    }
    slots.sort((a, b) => a.$1.compareTo(b.$1));
    var excess = slots.length - limit;
    final out = <DropEntry>[];
    for (final (_, e) in slots) {
      if (excess > 0 && !inFlight.contains(e)) {
        excess -= 1;
      } else {
        out.add(e);
      }
    }
    return out;
  }

  /// sessions.jsonl 超上限（ADR 0019 决定 3）：删最旧的未在途条目。
  static List<ClosedSession> capClosed(List<ClosedSession> all, Set<String> inFlight, int limit) {
    var excess = all.length - limit;
    if (excess <= 0) return all;
    final out = <ClosedSession>[];
    for (final c in all) {
      if (excess > 0 && !inFlight.contains(c.sessionId)) {
        excess -= 1;
      } else {
        out.add(c);
      }
    }
    return out;
  }

  static String digest(Device d) => Ids.deviceDigest(d);

  /// 段文件读（异步；文件名不合规 / 读不出返回 null）。
  static Future<SegmentFile?> readSegment(String path, bool validate) async {
    final b = await Fs.read(path);
    if (b == null) return null;
    return Segments.parse(path, b, validate);
  }

  /// 小工具：拿到一个只读的字节视图。
  static Uint8List view(Uint8List data, int s, int e) => Uint8List.sublistView(data, s, e);
}
