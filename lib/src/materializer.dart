// 批次物化（方案 §3.5）。对位 Android `core/Materializer.kt`，与 iOS `Materializer.swift` 逐字一致。
//
// Flutter（v3 §7）：段读取异步、按段为片段（≤ 512 KB），片段之间 `await` 让出事件循环；信封 gzip 进 worker isolate
// （`Isolate.run`，只传字节）；批文件 tmp → flush（fsync）→ rename。

import 'dart:async';
import 'dart:typed_data';

import 'engine.dart';
import 'fs.dart';
import 'gzip.dart';
import 'ids.dart';
import 'limits.dart';
import 'model.dart';
import 'segments.dart';

class OLine {
  const OLine(this.seq, this.oseq, this.ts, this.rank, this.raw);

  final int seq;
  final int oseq;
  final int ts;
  final int rank;
  final Uint8List raw;
}

class _Chunk {
  _Chunk(this.user);

  final String? user;
  final List<OLine> lines = <OLine>[];
  int bytes = 0;
  bool hasError = false;
  List<OLine> ctx = const <OLine>[];
  int? ctxTruncated;
  bool extras = false;
  bool mapping = false;
}

/// 让出事件循环一拍（片段之间）。
Future<void> yieldToEventLoop() => Future<void>.delayed(Duration.zero);

extension EngineMaterializer on Engine {
  /// 义务行 = 本会话 oseq ∈ (extracted_through_oseq, targetOseq]，按 oseq 连续取走；用户边界与 oseq 缺口处切批；
  /// 解压后 ≤ 768 KB，超出按 oseq 切多批；本批含 error / fatal 时附 ctx（noCtx 除外）；没有义务行 → 不产生批次。
  Future<void> materialize(SessionRecord s, int targetOseq, int targetSeq, bool noCtx, bool ignoreCap) async {
    final now = clock.wallMs();
    final inst = install;
    if (inst == null) return;
    final cache = <int, SegmentFile?>{};
    Future<SegmentFile?> load(SegInfo info) async {
      if (cache.containsKey(info.segNo)) return cache[info.segNo];
      final f = await Engine.readSegment(info.path, false);
      cache[info.segNo] = f;
      return f;
    }

    final from = s.cursor.extractedThroughOseq + 1;
    final ob = <(OLine, String?)>[];
    if (targetOseq >= from) {
      final missing = <SegInfo>[];
      for (final info in List.of(s.sealed)) {
        if (!(info.obligCount > 0 && info.lastOseq >= from && info.firstOseq <= targetOseq)) continue;
        // 读失败 ≠ 没有内容（ADR 0024 决定 3）：读失败（非 ENOENT）本次不推进、不删、留待下次；确已不存在 → 墓碑后推进
        final r = await Fs.readResult(info.path);
        SegmentFile? f;
        switch (r) {
          case ReadOk(:final bytes):
            f = Segments.parse(info.path, bytes, false);
          case ReadMissing():
            missing.add(info);
            continue;
          case ReadFailed():
            f = null;
        }
        if (f == null) {
          readRetryPending = true;
          return;
        }
        cache[info.segNo] = f;
        for (final l in f.lines) {
          if (l.oseq >= from && l.oseq <= targetOseq) {
            ob.add((
              OLine(l.seq, l.oseq, l.ts, l.levelRank, Uint8List.fromList(Engine.view(f.data, l.start, l.end))),
              info.userId,
            ));
          }
        }
        await yieldToEventLoop();
      }
      if (missing.isNotEmpty) {
        final tombs = [
          for (final it in missing)
            () {
              final a = it.firstOseq > from ? it.firstOseq : from;
              final b = it.lastOseq < targetOseq ? it.lastOseq : targetOseq;
              return DropEntry(s.meta.sessionId, a, b, b - a + 1, DropReason.corrupt, now, lastAckAge(now));
            }(),
        ];
        if (!await appendDrops(tombs)) {
          readRetryPending = true;
          return;
        }
        s.sealed.removeWhere(missing.contains);
      }
      ob.sort((a, b) => a.$1.oseq.compareTo(b.$1.oseq));
    }
    if (ob.isEmpty) {
      if (targetOseq >= from) {
        // 区间内的行都不在盘上（写失败 / 已驱逐 / 段文件消失，均已记墓碑）
        s.cursor.extractedThroughOseq = targetOseq;
        await writeCursor(s);
      }
      return;
    }
    final hasError = ob.any((e) => e.$1.rank >= Level.error);
    final cap = effective.config.dailyBatchCap;
    if (!ignoreCap && !hasError && cap > 0 && todayBatches(now) >= cap) {
      // daily_batch_cap：超出的 p1 合并到下一次封段（p0 不受限；日志不丢只是攒大包，ADR 0005）
      return;
    }

    const budget = Limits.batchUncompressedBytesClient;
    final isCurrent = identical(s, current);

    // 头部字节上限估计：用最大位数的数字占位，外加 extras 的真实字节
    int headerBytes(String? user, Extras? extras, bool withMapping) {
      const big = 9007199254740991;
      final h = EnvelopeHeader(
        BatchKind.primary,
        Ids.namespace,
        9999999999999,
        '2026-09-29',
        inst.installId,
        s.meta.sessionId,
        s.meta.sessionNo,
        s.meta.process,
        user,
        s.meta.device,
        big,
        big,
        big,
        big,
        big,
      );
      if (extras != null) {
        h.drops = extras.drops;
        h.closedSessions = extras.closed;
      }
      if (withMapping) h.mapping = MappingBlock(user, s.meta.device);
      return h.encodePrefix().length + 2;
    }

    // extras（drops / closed_sessions）只随本次物化的第一批
    final extras = await takeExtras();
    final chunks = <_Chunk>[];
    _Chunk? curChunk;
    var curHeader = 0;
    var prevOseq = -1;
    var prevUserSet = false;
    String? prevUser;
    PendingMapping? mappingPendingFor;
    final digest = Engine.digest(s.meta.device);
    _Chunk startChunk(String? user) {
      final c = _Chunk(user);
      c.extras = chunks.isEmpty && curChunk == null;
      final pf = mappingPendingFor;
      if (isCurrent && needMapping(user, digest, now) && !(pf != null && pf.user == user && pf.digest == digest)) {
        c.mapping = true;
        mappingPendingFor = PendingMapping(user, digest);
      }
      curHeader = headerBytes(user, c.extras ? extras : null, c.mapping);
      curChunk = c;
      return c;
    }

    for (final (l, user) in ob) {
      final cost = l.raw.length + 1;
      final boundary = !prevUserSet || prevUser != user || l.oseq != prevOseq + 1;
      final cc = curChunk;
      _Chunk c;
      if (cc == null) {
        c = startChunk(user);
      } else if (boundary || curHeader + cc.bytes + cost > budget) {
        chunks.add(cc);
        c = startChunk(user);
      } else {
        c = cc;
      }
      c.lines.add(l);
      c.bytes += cost;
      if (l.rank >= Level.error) c.hasError = true;
      prevOseq = l.oseq;
      prevUser = user;
      prevUserSet = true;
    }
    final last = curChunk;
    if (last != null) chunks.add(last);

    // ctx：附在最后一个含 error 的批
    var ctxTarget = -1;
    if (!noCtx) {
      for (var i = chunks.length - 1; i >= 0; i--) {
        if (chunks[i].hasError) {
          ctxTarget = i;
          break;
        }
      }
    }
    if (ctxTarget >= 0) {
      final t = chunks[ctxTarget];
      final user = t.user;
      final hb = headerBytes(user, t.extras ? extras : null, t.mapping);
      final room = budget - hb - t.bytes;
      final byteBudget = effective.config.contextBytes < room ? effective.config.contextBytes : room;
      final lineBudget = effective.config.contextLines;
      final taken = <OLine>[];
      var takenBytes = 0;
      var truncated = 0;
      var stop = false;
      final through = s.cursor.ctxThroughSeq;
      for (final info in s.sealed.reversed.toList()) {
        if (info.lineCount == 0 || info.firstSeq > targetSeq) continue;
        if (info.userId != user || info.lastSeq <= through) break;
        if (info.lineCount == info.obligCount) continue;
        if (stop && info.firstSeq > through && info.lastSeq <= targetSeq) {
          truncated += info.lineCount - info.obligCount;
          continue;
        }
        final f = await load(info);
        if (f == null) continue;
        for (final l in f.lines.reversed) {
          if (!(l.oseq == 0 && l.seq > through && l.seq <= targetSeq)) continue;
          if (stop) {
            truncated += 1;
            continue;
          }
          final raw = Segments.withCtx(f.data, l.start, l.end);
          final cost = raw.length + 1;
          if (taken.length < lineBudget && takenBytes + cost <= byteBudget) {
            taken.add(OLine(l.seq, 0, l.ts, l.levelRank, raw));
            takenBytes += cost;
          } else {
            stop = true;
            truncated += 1;
          }
        }
        await yieldToEventLoop();
      }
      t.ctx = taken.reversed.toList();
      t.ctxTruncated = truncated;
      if (targetSeq > s.cursor.ctxThroughSeq) s.cursor.ctxThroughSeq = targetSeq;
    }

    // 写批：信封 JSON → gzip → outbox/tmp-* → flush → rename（提交点）；全部成功后原子写 cursor
    var committedThrough = s.cursor.extractedThroughOseq;
    var usedExtras = false;
    for (final c in chunks) {
      final all = List<OLine>.of(c.lines);
      if (c.ctx.isNotEmpty) {
        all.addAll(c.ctx);
        all.sort((a, b) => a.seq.compareTo(b.seq));
      }
      var tsMin = all.first.ts;
      for (final l in all) {
        if (l.ts < tsMin) tsMin = l.ts;
      }
      final oseqFrom = c.lines.first.oseq;
      final bid = Ids.batchId(inst.installId, s.meta.sessionId, BatchKind.primary, oseqFrom);
      if (bid == null) break;
      final h = EnvelopeHeader(
        BatchKind.primary,
        bid,
        now,
        Day.clientDay(tsMin, now),
        inst.installId,
        s.meta.sessionId,
        s.meta.sessionNo,
        s.meta.process,
        c.user,
        s.meta.device,
        all.first.seq,
        all.last.seq,
        oseqFrom,
        c.lines.last.oseq,
        c.ctxTruncated,
      );
      if (c.extras) {
        h.drops = extras.drops;
        h.closedSessions = extras.closed;
        usedExtras = true;
      }
      if (c.mapping) h.mapping = MappingBlock(c.user, s.meta.device);
      if (await writeBatch(h, [for (final l in all) l.raw], c.hasError ? 0 : 1) == null) {
        if (c.extras) usedExtras = false;
        break;
      }
      if (c.mapping) pendingMapping = PendingMapping(c.user, digest);
      countBatch(now);
      committedThrough = c.lines.last.oseq;
    }
    if (!usedExtras) releaseExtras(extras);
    // 区间尾部若因缺口没有行，也视为已处理（墓碑已覆盖）
    if (committedThrough == ob.last.$1.oseq && targetOseq > committedThrough) committedThrough = targetOseq;
    s.cursor.extractedThroughOseq = committedThrough;
    await writeCursor(s);
  }

  /// 映射块：user_id 或设备摘要相对 mapping.json 变化、或距 acked_ms ≥ 24 h。
  bool needMapping(String? user, String digest, int now) {
    final p = pendingMapping;
    if (p != null && p.user == user && p.digest == digest) return false;
    final m = mapping;
    if (m == null) return true;
    // 确认它的请求用的是别的 key / 服务端：对当前 key 按未确认（ADR 0024 决定 7）；旧版本写的（没有这两个键）按相同
    if (!sameIdentity(m.hasIdentity, m.keyFp, m.baseUrl)) return true;
    return m.userId != user || m.deviceDigest != digest || now - m.ackedMs >= Limits.mappingRefreshMs;
  }

  /// 取本批要带的 drops（≤ 100）与 closed_sessions（≤ 20）：按文件顺序取最旧的、未在途的前 N 条；携带不改写文件。
  Future<Extras> takeExtras() async {
    final r = await locks.withDirLock(() async {
      final drops = (await readDropsLocked())
          .where((d) => !embeddedDrops.contains(d))
          .take(Limits.dropsPerBatch)
          .toList();
      embeddedDrops.addAll(drops);
      final closed = (await readClosedLocked())
          .where((c) => !embeddedClosed.contains(c.sessionId))
          .take(Limits.closedSessionsPerBatch)
          .toList();
      embeddedClosed.addAll(closed.map((c) => c.sessionId));
      return Extras(drops, closed);
    });
    return r ?? const Extras(<DropEntry>[], <ClosedSession>[]);
  }

  void releaseExtras(Extras e) {
    embeddedDrops.removeAll(e.drops);
    embeddedClosed.removeAll(e.closed.map((c) => c.sessionId));
  }

  /// 写一个批文件；返回元数据（失败 null，不留半成品：tmp 在失败时删除，启动时也清理）。
  Future<BatchMeta?> writeBatch(EnvelopeHeader h, List<Uint8List> lines, int prio) async {
    final json = h.encode(lines);
    final gz = await Gzip.compressOffMain(json);
    if (gz == null) return null;
    final tmp = Fs.join(outboxDir, 'tmp-$processName-${Ids.newV4()}');
    final name = OutboxName.make(prio, h.createdMs, h.batchId);
    final dest = Fs.join(outboxDir, name);
    final ok = await Fs.writeSynced(tmp, gz) && await Fs.rename(tmp, dest);
    if (!ok) {
      await Fs.remove(tmp);
      return null;
    }
    final meta = batchMeta(name, h, lines, gz.length);
    metas[name] = meta;
    batchesWritten += 1;
    return meta;
  }

  // MARK: backfill（full_dump 生效时；§3.5 / §5）

  /// 对 RETAINED 段中**全部非义务行**按段生成 backfill 批（p2，不带 oseq）。每段一批，batch_id = `…:backfill:<seg_no>`；
  /// 超 768 KB 的段按 seq 切多批，batch_id = `…:backfill:<seg_no>:<seq_from>`。本进程内同一段只生成一次。
  Future<void> materializeBackfill([int budget = Limits.batchUncompressedBytesClient]) async {
    final inst = install;
    if (inst == null) return;
    final now = clock.wallMs();
    for (final s in ownSessions) {
      for (final info in List.of(s.sealed)) {
        if (info.lineCount <= info.obligCount) continue;
        final key = '${s.meta.sessionId}:${info.segNo}';
        if (backfilledSegs.contains(key)) continue;
        final f = await Engine.readSegment(info.path, false);
        if (f == null) continue;
        final lines = [
          for (final l in f.lines)
            if (l.oseq == 0)
              OLine(l.seq, 0, l.ts, l.levelRank, Uint8List.fromList(Engine.view(f.data, l.start, l.end))),
        ]..sort((a, b) => a.seq.compareTo(b.seq));
        if (lines.isEmpty) {
          backfilledSegs.add(key);
          continue;
        }
        EnvelopeHeader header(List<OLine> part, String batchId) {
          var tsMin = part.first.ts;
          for (final l in part) {
            if (l.ts < tsMin) tsMin = l.ts;
          }
          return EnvelopeHeader(
            BatchKind.backfill,
            batchId,
            now,
            Day.clientDay(tsMin, now),
            inst.installId,
            s.meta.sessionId,
            s.meta.sessionNo,
            s.meta.process,
            info.userId,
            s.meta.device,
            part.first.seq,
            part.last.seq,
            null,
            null,
            null,
          );
        }

        // 按 seq 切：头部按最大位数占位估算
        final headBytes = header(lines, Ids.namespace).encodePrefix().length + 2 + 64;
        final parts = <List<OLine>>[<OLine>[]];
        var size = 0;
        for (final l in lines) {
          final cost = l.raw.length + 1;
          if (parts.last.isNotEmpty && headBytes + size + cost > budget) {
            parts.add(<OLine>[]);
            size = 0;
          }
          parts.last.add(l);
          size += cost;
        }
        var ok = true;
        for (final part in parts) {
          final bid = parts.length == 1
              ? Ids.batchId(inst.installId, s.meta.sessionId, BatchKind.backfill, info.segNo)
              : Ids.backfillSplitBatchId(inst.installId, s.meta.sessionId, info.segNo, part.first.seq);
          if (bid == null || await writeBatch(header(part, bid), [for (final l in part) l.raw], 2) == null) {
            ok = false;
            break;
          }
        }
        if (!ok) return;
        backfilledSegs.add(key);
        await yieldToEventLoop();
      }
    }
  }
}

/// 批的元数据。级别与是否 ctx 按位置判断（ADR 0024 决定 9）。解析不出前缀的行保守按 warn 计。纯函数（可在 worker isolate 里跑）。
BatchMeta batchMeta(String name, EnvelopeHeader h, List<List<int>> lines, int bytes) {
  var warn = false;
  var err = false;
  for (final l in lines) {
    final rank = Segments.parsePrefix(l, 0, l.length)?.levelRank ?? Level.warn;
    if (rank >= Level.warn) warn = true;
    if (rank >= Level.error && !Segments.isCtxLine(l, 0, l.length)) err = true;
  }
  final prio = OutboxName.parse(name)?.prio ?? 1;
  final m = h.mapping;
  return BatchMeta(
    name,
    prio,
    h.createdMs,
    h.batchId,
    h.installId,
    h.kind,
    h.sessionId,
    h.oseqFrom ?? 0,
    h.oseqTo ?? 0,
    lines.length,
    warn,
    err,
    h.drops,
    h.closedSessions,
    m != null,
    m?.userId,
    m == null ? null : Engine.digest(m.device),
    bytes,
  );
}
