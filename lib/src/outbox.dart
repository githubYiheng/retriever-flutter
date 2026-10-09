// 出站箱（§3.2 / §3.7 / §3.8）：元数据、驱逐、隔离、413 切分。对位 Android `core/Outbox.kt`，与 iOS `Outbox.swift` 逐字一致。
//
// Flutter（v3 §7）：启动扫描 `loadMeta`（读 + 解压 + 解析整批）整体在 worker isolate 里做，只回 [BatchMeta]；
// 413 切分的解压解析也在 worker 里。`Isolate.run` 失败退回当前 isolate 分片做，队列不能卡死。

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'engine.dart';
import 'fs.dart';
import 'gzip.dart';
import 'ids.dart';
import 'json.dart';
import 'limits.dart';
import 'materializer.dart';
import 'model.dart';
import 'pre.dart';
import 'segments.dart';

final Uint8List _linesKey = Bytes.ascii('"lines":[');

/// 解压并拆出信封头与行（行字节原样）。
class ParsedBatch {
  const ParsedBatch(this.header, this.lines);

  final EnvelopeHeader header;
  final List<Uint8List> lines;
}

ParsedBatch? parseBatch(List<int> gz) {
  final json = Gzip.decompress(gz);
  if (json == null) return null;
  return parseEnvelope(json);
}

/// 已解压的信封 → 头 + 行。顶层行数组按括号深度切（字符串内的括号 / 引号转义要跳过）。
ParsedBatch? parseEnvelope(Uint8List json) {
  final at = Bytes.find(_linesKey, json);
  if (at < 0) return null;
  final headJson = Bytes.concat([Uint8List.sublistView(json, 0, at + _linesKey.length), Bytes.ascii(']}')]);
  final o = JsonIn.obj(headJson);
  if (o == null) return null;
  final h = EnvelopeHeader.decode(o);
  if (h == null) return null;
  final lines = <Uint8List>[];
  var i = at + _linesKey.length;
  var depth = 0;
  var inStr = false;
  var esc = false;
  var start = -1;
  while (i < json.length) {
    final c = json[i];
    if (inStr) {
      if (esc) {
        esc = false;
      } else if (c == 0x5C) {
        esc = true;
      } else if (c == 0x22) {
        inStr = false;
      }
    } else if (c == 0x22) {
      inStr = true;
    } else if (c == 0x7B) {
      if (depth == 0) start = i;
      depth += 1;
    } else if (c == 0x7D) {
      depth -= 1;
      if (depth == 0 && start >= 0) {
        lines.add(Uint8List.fromList(Uint8List.sublistView(json, start, i + 1)));
        start = -1;
      }
    } else if (c == 0x5D && depth == 0) {
      break;
    }
    i++;
  }
  return ParsedBatch(h, lines);
}

/// 一个批文件的元数据（同步：给 worker isolate 用）。
BatchMeta? loadMetaSync(String outboxDir, String name) {
  try {
    final gz = File(Fs.join(outboxDir, name)).readAsBytesSync();
    final p = parseBatch(gz);
    if (p == null) return null;
    return batchMeta(name, p.header, p.lines, gz.length);
  } catch (_) {
    return null;
  }
}

List<BatchMeta?> _loadMetasSync(String outboxDir, List<String> names) => [
  for (final n in names) loadMetaSync(outboxDir, n),
];

/// 批量读元数据：整体在 worker isolate 里做（闭包只捕获路径与名字）；失败退回当前 isolate 逐个做、之间让出。
Future<List<BatchMeta?>> loadMetasOffMain(String outboxDir, List<String> names) async {
  if (names.isEmpty) return const <BatchMeta?>[];
  try {
    return await Isolate.run(() => _loadMetasSync(outboxDir, names), debugName: 'retriever-outbox-scan');
  } catch (_) {
    final out = <BatchMeta?>[];
    for (final n in names) {
      final b = await Fs.read(Fs.join(outboxDir, n));
      final p = b == null ? null : parseBatch(b);
      out.add(p == null ? null : batchMeta(n, p.header, p.lines, b!.length));
      await yieldToEventLoop();
    }
    return out;
  }
}

/// 读 + 解压 + 解析一个批（worker isolate；失败退回当前 isolate）。
Future<ParsedBatch?> parseBatchFileOffMain(String path) async {
  try {
    return await Isolate.run(() {
      try {
        return parseBatch(File(path).readAsBytesSync());
      } catch (_) {
        return null;
      }
    }, debugName: 'retriever-batch-parse');
  } catch (_) {
    final b = await Fs.read(path);
    return b == null ? null : parseBatch(b);
  }
}

class _SplitLine {
  const _SplitLine(this.raw, this.seq, this.oseq, this.ts, this.rank, this.ctx);

  final Uint8List raw;
  final int seq;
  final int oseq;
  final int ts;
  final int rank;
  final bool ctx;
}

class _EvSeg {
  const _EvSeg(this.path, this.size, this.mtime, this.segNo);

  final String path;
  final int size;
  final int mtime;
  final int segNo;
}

extension EngineOutbox on Engine {
  Future<BatchMeta?> loadMeta(String name) async {
    final b = await Fs.read(Fs.join(outboxDir, name));
    if (b == null) return null;
    final p = parseBatch(b);
    if (p == null) return null;
    return batchMeta(name, p.header, p.lines, b.length);
  }

  /// 与磁盘对齐（出站箱在多进程间共享）：新文件读元数据（worker isolate），消失的文件移出缓存。
  Future<void> reconcileOutbox() async {
    final seen = <String>{};
    final fresh = <String>[];
    for (final name in await Fs.list(outboxDir)) {
      if (OutboxName.parse(name) == null) continue;
      seen.add(name);
      if (!metas.containsKey(name)) fresh.add(name);
    }
    if (fresh.isNotEmpty) {
      final loaded = await loadMetasOffMain(outboxDir, fresh);
      for (var i = 0; i < fresh.length; i++) {
        final name = fresh[i];
        final p = OutboxName.parse(name)!;
        metas[name] =
            loaded[i] ??
            // 读不出（位腐烂等）：保守当作含 warn 的 primary，交给服务端隔离；请求头的 install 只能取当前值
            BatchMeta(
              name,
              p.prio,
              p.createdMs,
              p.batchId,
              install?.installId ?? '',
              BatchKind.primary,
              '',
              0,
              0,
              0,
              true,
              p.prio == 0,
              const <DropEntry>[],
              const <ClosedSession>[],
              false,
              null,
              null,
              await Fs.size(Fs.join(outboxDir, name)) ?? 0,
            );
      }
    }
    metas.removeWhere((k, _) => !seen.contains(k));
  }

  /// 启动：清 tmp、扫出站箱、重建「在途携带」集合与今日批数。
  Future<void> scanOutboxAtStartup() async {
    final nowWall = clock.wallMs();
    for (final name in await Fs.list(outboxDir)) {
      if (!name.startsWith('tmp-')) continue;
      final f = Fs.join(outboxDir, name);
      // 自己进程名的 tmp 一定是崩溃残留；别的进程的只清 1 h 以前的（可能正在构建）
      if (name.startsWith('tmp-$processName-') || (await Fs.mtimeMs(f) ?? 0) < nowWall - 3600000) await Fs.remove(f);
    }
    for (final name in await Fs.list(root)) {
      if (!(name.startsWith('.') && name.contains('.tmp-'))) continue;
      final f = Fs.join(root, name);
      if ((await Fs.mtimeMs(f) ?? 0) < nowWall - 3600000) await Fs.remove(f);
    }
    await reconcileOutbox();
    embeddedDrops.clear();
    embeddedClosed.clear();
    pendingMapping = null;
    final today = Day.fromMs(nowWall);
    todayDay = today;
    todayCount = 0;
    final iid = install?.installId;
    for (final m in metas.values) {
      embeddedDrops.addAll(m.drops);
      embeddedClosed.addAll(m.closed.map((c) => c.sessionId));
      // 别的 install 的批带的映射不算本 install 的在途映射
      if (m.hasMapping && m.mappingDigest != null && m.installId == iid) {
        pendingMapping = PendingMapping(m.mappingUser, m.mappingDigest!);
      }
      if (m.prio <= 1 && Day.fromMs(m.createdMs) == today) todayCount += 1;
    }
  }

  // MARK: 隔离（毒批）

  Future<void> quarantine(String name) async {
    final m = metas[name];
    if (m == null) return;
    final q = OutboxName.make(3, m.createdMs, m.batchId);
    if (!await Fs.rename(Fs.join(outboxDir, name), Fs.join(outboxDir, q))) return;
    await Fs.touch(Fs.join(outboxDir, q), clock.wallMs());
    metas.remove(name);
    m.name = q;
    m.prio = 3;
    metas[q] = m;
    fails.remove(name);
  }

  /// q-* 在 24 h 后或 app_version 变化后回到队列。
  Future<void> releaseQuarantine(bool force) async {
    final now = clock.wallMs();
    for (final e in metas.entries.toList()) {
      final name = e.key;
      final m = e.value;
      if (m.prio != 3) continue;
      final f = Fs.join(outboxDir, name);
      final since = await Fs.mtimeMs(f) ?? 0;
      if (!(force || now - since >= ClientConstants.quarantineRetryMs)) continue;
      final prio = m.kind == BatchKind.backfill ? 2 : (m.hasError ? 0 : 1);
      final p = OutboxName.make(prio, m.createdMs, m.batchId);
      if (await Fs.rename(f, Fs.join(outboxDir, p))) {
        metas.remove(name);
        m.name = p;
        m.prio = prio;
        metas[p] = m;
      }
    }
  }

  /// 最早的隔离批再试时刻（单调）。
  Future<int?> nextQuarantineReleaseMono() async {
    final nowWall = clock.wallMs();
    final nowMono = clock.monoMs();
    int? best;
    for (final e in metas.entries) {
      if (e.value.prio != 3) continue;
      final since = await Fs.mtimeMs(Fs.join(outboxDir, e.key)) ?? nowWall;
      final wait = since + ClientConstants.quarantineRetryMs - nowWall;
      final at = nowMono + (wait < 0 ? 0 : wait);
      if (best == null || at < best) best = at;
    }
    return best;
  }

  // MARK: 413：按 oseq（或 ctx）二分重物化，全部半批提交后才删原批（ADR 0019 决定 11）

  /// 切分 = 重物化：每个半批都是新名字的新批（batch_id = UUIDv5(ns, `<install>:<session>:primary:<oseq_from>:<oseq_to>`)，
  /// install 取原批信封，created_ms 沿用原批）。全部半批提交后才删原批；任一半写失败 → 删掉本次已写的半批、原批原样保留，
  /// 返回 false（调用方按普通失败退避）。
  Future<bool> split413(String name) async {
    final file = Fs.join(outboxDir, name);
    final p = await parseBatchFileOffMain(file);
    if (p == null || p.header.kind != BatchKind.primary) {
      await quarantine(name);
      return true;
    }
    final ls = <_SplitLine>[];
    for (final raw in p.lines) {
      final pre = Segments.parsePrefix(raw, 0, raw.length);
      if (pre == null) continue;
      // 是否 ctx 按行尾固定位置判断（ADR 0024 决定 9），attrs 里的 `ctx` 键不算
      ls.add(_SplitLine(raw, pre.seq, pre.oseq, pre.ts, pre.levelRank, Segments.isCtxLine(raw, 0, raw.length)));
    }
    final oblig = ls.where((l) => !l.ctx && l.oseq > 0).toList();
    final ctx = ls.where((l) => l.ctx).toList();
    final h = p.header;
    final parts = <(EnvelopeHeader, List<_SplitLine>)>[];
    if (oblig.length >= 2) {
      final mid = oblig[oblig.length ~/ 2 - 1].oseq;
      final a = oblig.where((l) => l.oseq <= mid).toList();
      final b = oblig.where((l) => l.oseq > mid).toList();
      final aErr = a.any((l) => l.rank >= Level.error);
      final bErr = b.any((l) => l.rank >= Level.error);
      final ctxToA = aErr && !bErr;
      final ha = h.copy(oseqFrom: a.first.oseq, oseqTo: a.last.oseq);
      final hb = h.copy(
        oseqFrom: b.first.oseq,
        oseqTo: b.last.oseq,
        drops: const <DropEntry>[],
        closedSessions: const <ClosedSession>[],
        closedSessionsDropped: 0,
        mapping: null,
      );
      if (ctxToA) {
        hb.ctxTruncated = null;
      } else {
        ha.ctxTruncated = null;
      }
      parts.add((ha, [...a, if (ctxToA) ...ctx]));
      parts.add((hb, [...b, if (!ctxToA) ...ctx]));
    } else if (oblig.length == 1 && ctx.isNotEmpty) {
      ctx.sort((x, y) => x.seq.compareTo(y.seq));
      final drop = ctx.length ~/ 2 < 1 ? 1 : ctx.length ~/ 2;
      ctx.removeRange(0, drop);
      final ha = h.copy(ctxTruncated: (h.ctxTruncated ?? 0) + drop);
      parts.add((ha, [...oblig, ...ctx]));
    } else {
      await quarantine(name);
      return true;
    }
    final written = <String>[];
    for (final (h0, part) in parts) {
      final lines = List.of(part)..sort((x, y) => x.seq.compareTo(y.seq));
      final bid = Ids.splitBatchId(h0.installId, h0.sessionId, h0.oseqFrom ?? 0, h0.oseqTo ?? 0);
      if (bid == null) {
        // 信封身份不合规（推导不出确定性 id）：切不了，交给服务端隔离（与 iOS 同口径）
        await _rollbackSplit(written, name);
        await quarantine(name);
        return true;
      }
      var tsMin = lines.first.ts;
      for (final l in lines) {
        if (l.ts < tsMin) tsMin = l.ts;
      }
      final hh = h0.copy(
        batchId: bid,
        seqFrom: lines.first.seq,
        seqTo: lines.last.seq,
        day: Day.clientDay(tsMin, h0.createdMs),
      );
      final hasErr = lines.any((l) => !l.ctx && l.rank >= Level.error);
      final m = await writeBatch(hh, [for (final l in lines) l.raw], hasErr ? 0 : 1);
      if (m == null) {
        await _rollbackSplit(written, name);
        return false;
      }
      written.add(m.name);
    }
    if (!written.contains(name)) {
      await Fs.remove(file);
      metas.remove(name);
    }
    fails.remove(name);
    return true;
  }

  /// 413 切分没有全部写成：只删本次写出的半批，原批不动。
  Future<void> _rollbackSplit(List<String> written, String original) async {
    for (final w in written) {
      if (w == original) continue;
      await Fs.remove(Fs.join(outboxDir, w));
      metas.remove(w);
    }
  }

  // MARK: 驱逐（§3.8，宪法 R-5）

  /// 总量 = 各会话段 + 出站箱 + pre 文件（ADR 0023）；两个额度（ADR 0010）：硬上限 = local_cap_bytes，是驱逐义务批的唯一依据；
  /// 余量额度 = min(硬上限, 本方已占 + 可用空间 − 64 MB)（可用空间未知时 = 硬上限），只约束无义务类（RETAINED 段、p2）。
  /// 顺序：RETAINED 段最旧优先（> 7 d 无条件删）→ p2（backfill_evicted）→（超硬上限时）q（quarantine_evicted）
  /// → p1（buffer_overflow）→ p0（buffer_overflow）。当前 OPEN 段永不驱逐。
  Future<void> evictIfNeeded() async {
    // 恢复旧会话成功完成之前一律不驱逐
    if (!recovered) return;
    final nowWall = clock.wallMs();
    final sealed = <_EvSeg>[];
    var total = 0;
    for (final procName in await Fs.list(root)) {
      if (!procName.startsWith('proc-')) continue;
      final pdir = Fs.join(root, procName);
      for (final sid in await Fs.list(pdir)) {
        if (!Ids.isUuid(sid)) continue;
        final sdir = Fs.join(pdir, sid);
        for (final f in await Fs.list(sdir)) {
          final pn = Segments.parseName(f);
          if (pn == null) continue;
          final file = Fs.join(sdir, f);
          final size = await Fs.size(file) ?? 0;
          total += size;
          if (!pn.isOpen) sealed.add(_EvSeg(file, size, await Fs.mtimeMs(file) ?? nowWall, pn.segNo));
        }
      }
    }
    // pre 文件：计入总量；不属于任何活进程（flock 拿得到）且 mtime 超过 7 天的删掉。本进程的（同 token）与别的活进程的不碰
    for (final n in await Fs.list(preDir)) {
      if (!n.endsWith(PreFile.suffix)) continue;
      final f = Fs.join(preDir, n);
      final size = await Fs.size(f) ?? 0;
      final mt = await Fs.mtimeMs(f) ?? nowWall;
      if (nowWall - mt > Limits.ringMaxAgeDays * ClientConstants.dayMs) {
        final orphan = await OrphanPre.tryAcquire(f, token);
        if (orphan != null) {
          await Fs.deleteFile(f);
          orphan.release();
          continue;
        }
      }
      total += size;
    }
    await reconcileOutbox();
    for (final m in metas.values) {
      total += m.bytes;
    }

    final hardCap = effective.config.localCapBytes;
    final avail = await availableBytes();
    // 低磁盘只让出可再生的部分：义务批不能因余量不足在上传前消失
    int softCap = hardCap;
    if (avail != null) {
      var v = total + avail - ClientConstants.diskReserveBytes;
      if (v < 0) v = 0;
      softCap = hardCap < v ? hardCap : v;
    }
    sealed.sort((a, b) {
      final c = a.mtime.compareTo(b.mtime);
      return c != 0 ? c : a.segNo.compareTo(b.segNo);
    });
    const maxAge = Limits.ringMaxAgeDays * ClientConstants.dayMs;
    final remaining = <_EvSeg>[];
    for (final s in sealed) {
      if (nowWall - s.mtime > maxAge) {
        if (await _evictSegment(s.path, nowWall)) total -= s.size;
      } else {
        remaining.add(s);
      }
    }
    final cur = current;
    if (total > softCap && cur != null && !writer.isAdopting) {
      final lastOseq = cur.sealed.isEmpty ? 0 : cur.sealed.last.lastOseq;
      if (lastOseq > cur.cursor.extractedThroughOseq) {
        // daily cap 推迟的义务行先物化，保证 RETAINED 段不带义务
        var maxOseq = 0;
        for (final i in cur.sealed) {
          if (i.lastOseq > maxOseq) maxOseq = i.lastOseq;
        }
        await materialize(cur, maxOseq, cur.sealed.isEmpty ? 0 : cur.sealed.last.lastSeq, false, true);
        await reconcileOutbox();
        total = remaining.fold(0, (a, s) => a + s.size) + metas.values.fold(0, (a, m) => a + m.bytes);
        final open = writer.currentSegmentPath;
        if (open != null) total += await Fs.size(open) ?? 0;
      }
    }
    for (final s in remaining) {
      if (total <= softCap) break;
      if (await _evictSegment(s.path, nowWall)) total -= s.size;
    }
    if (total > softCap) {
      for (final prio in const [2, 3, 1, 0]) {
        // p2 无义务，受余量额度约束；q / p1 / p0 只受硬上限约束
        final cap = prio == 2 ? softCap : hardCap;
        final batch = metas.values.where((m) => m.prio == prio && m.name != inFlight).toList()
          ..sort((a, b) {
            final c = a.createdMs.compareTo(b.createdMs);
            return c != 0 ? c : a.name.compareTo(b.name);
          });
        for (final m in batch) {
          if (total <= cap) break;
          if (await _evictBatch(m, nowWall)) total -= m.bytes;
        }
      }
    }
  }

  /// 驱逐一个段：有没物化的义务行先记墓碑，记成了再删；墓碑写不成本轮不驱逐它（返回 false）。
  Future<bool> _evictSegment(String path, int now) async {
    for (final s in ownSessions) {
      final idx = s.sealed.indexWhere((i) => i.path == path);
      if (idx < 0) continue;
      final info = s.sealed[idx];
      if (info.obligCount > 0 && info.lastOseq > s.cursor.extractedThroughOseq) {
        final from = info.firstOseq > s.cursor.extractedThroughOseq + 1
            ? info.firstOseq
            : s.cursor.extractedThroughOseq + 1;
        final t = DropEntry(
          s.meta.sessionId,
          from,
          info.lastOseq,
          info.lastOseq - from + 1,
          DropReason.bufferOverflow,
          now,
          lastAckAge(now),
        );
        if (!await appendDrops([t])) return false;
      }
      s.sealed.removeAt(idx);
      if (!identical(s, current) && s.sealed.isEmpty && s.cursor.closedMs != null) {
        others.remove(s.meta.sessionId);
        await Fs.remove(s.dir);
        return true;
      }
      // seq 高水位：被驱逐段的 lastSeq 并入 ctx 游标（恢复时 maxSeq 取 max(盘上, ctx_through_seq)）
      if (info.lastSeq > s.cursor.ctxThroughSeq) {
        s.cursor.ctxThroughSeq = info.lastSeq;
        await writeCursor(s);
      }
      break;
    }
    await Fs.remove(path);
    // 别的进程 / 已关闭会话的目录空了就一并清掉
    final dir = Fs.parentOf(path);
    final names = await Fs.list(dir);
    if (!names.any((n) => Segments.parseName(n) != null) &&
        dir != current?.dir &&
        others[Fs.baseName(dir)] == null &&
        Fs.parentOf(dir) != procDir) {
      await Fs.remove(dir);
    }
    return true;
  }

  /// 驱逐一个批：先记墓碑（义务批 / backfill），记成了再删；墓碑写不成本轮不驱逐它（返回 false）。
  Future<bool> _evictBatch(BatchMeta m, int now) async {
    if (m.sessionId.isNotEmpty) {
      final age = lastAckAge(now);
      DropEntry? t;
      if (m.kind == BatchKind.backfill) {
        t = DropEntry(m.sessionId, 0, 0, m.lineCount < 1 ? 1 : m.lineCount, DropReason.backfillEvicted, now, age);
      } else if (m.oseqFrom > 0) {
        final reason = m.prio == 3 ? DropReason.quarantineEvicted : DropReason.bufferOverflow;
        t = DropEntry(m.sessionId, m.oseqFrom, m.oseqTo, m.oseqTo - m.oseqFrom + 1, reason, now, age);
      }
      if (t != null && !await appendDrops([t])) return false;
    }
    await Fs.remove(Fs.join(outboxDir, m.name));
    metas.remove(m.name);
    fails.remove(m.name);
    // 携带的墓碑 / 会话终态仍在 jsonl 里，放回待携带
    embeddedDrops.removeAll(m.drops);
    embeddedClosed.removeAll(m.closed.map((c) => c.sessionId));
    final p = pendingMapping;
    if (m.hasMapping && p != null && p.user == m.mappingUser && p.digest == m.mappingDigest) pendingMapping = null;
    return true;
  }
}
