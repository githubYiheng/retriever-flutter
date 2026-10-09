// 启动恢复（§3.4 ORPHAN）：旧会话截残行、判退出、unclean_fg 合成 error 并按 error 封段带 ctx、旧会话终态写 sessions.jsonl
// （只为 last_oseq > 0 的会话写）；零行的会话目录直接删；段读不出的会话本次不动、下次重试（ADR 0019 决定 1 / 13）；
// 旧 session_id / user_id / device 一律取持久化值；cursor = max(cursor 文件, 出站箱里本会话最大 oseq_to)。
// 对位 Android `core/Recovery.kt`，与 iOS `Recovery.swift` 逐字一致。Flutter：段为片段，片段之间让出事件循环。

import 'dart:typed_data';

import 'engine.dart';
import 'fs.dart';
import 'ids.dart';
import 'json.dart';
import 'line_encoder.dart';
import 'materializer.dart';
import 'model.dart';
import 'public_api.dart';
import 'segments.dart';

/// 行是不是已合成过的 `rtv.unclean_exit`：解析整行看顶层 `tag` 与 `synthetic`（ADR 0024 决定 9）。
bool _isUncleanExitLine(Uint8List d, int s, int e) {
  final o = JsonIn.obj(Uint8List.sublistView(d, s, e));
  if (o == null) return false;
  return o['tag'] == 'rtv.unclean_exit' && o['synthetic'] == true;
}

extension EngineRecovery on Engine {
  Future<void> recoverOldSessions() async {
    final cur = current;
    if (cur == null) return;
    final now = clock.wallMs();
    final outMax = <String, int>{};
    for (final m in metas.values) {
      if (m.kind == BatchKind.primary && m.sessionId.isNotEmpty) {
        final prev = outMax[m.sessionId] ?? 0;
        outMax[m.sessionId] = m.oseqTo > prev ? m.oseqTo : prev;
      }
    }
    // 目录锁拿不到：本次不恢复（读不到已有的终态 / 墓碑就会重复写），下次启动重试
    final existing = await locks.withDirLock(() async {
      final closed = (await readClosedLocked()).map((c) => c.sessionId).toSet();
      final drops = await readDropsLocked();
      return (closed, drops);
    });
    if (existing == null) return;
    SessionMeta? latest;
    for (final sid in await Fs.list(procDir)) {
      if (!Ids.isUuid(sid) || sid == cur.meta.sessionId) continue;
      final dir = Fs.join(procDir, sid);
      // 活着的会话（别的进程 / 同进程另一实例持有会话目录的 `lock`）不动；旧版本留下的会话没有 `lock`：建它并加锁
      final lock = await SessionLock.tryAcquire(dir);
      if (lock == null) continue;
      try {
        final m = await _recoverOne(sid, dir, now, outMax, existing.$1, existing.$2);
        // 「上一个会话」按 started_ms（孤儿 pre 文件收编出的会话 session_no 是事后分配的，ADR 0023）
        if (m != null && (latest == null || m.startedMs > latest.startedMs)) latest = m;
      } finally {
        lock.release();
      }
      await yieldToEventLoop();
    }
    previousAppVersion = latest?.device.appVersion;
    recovered = true;
  }

  /// 恢复一个旧会话；返回它的 meta（用于判断 app_version 变化）。
  Future<SessionMeta?> _recoverOne(
    String sid,
    String dir,
    int now,
    Map<String, int> outMax,
    Set<String> existingClosed,
    List<DropEntry> existingDrops,
  ) async {
    final segNames = <(int, bool, String)>[];
    for (final n in await Fs.list(dir)) {
      final p = Segments.parseName(n);
      if (p != null) segNames.add((p.segNo, p.isOpen, n));
    }
    segNames.sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : (a.$2 ? 1 : 0).compareTo(b.$2 ? 1 : 0);
    });
    final mb = await Fs.read(Fs.join(dir, 'meta.json'));
    final meta = mb == null ? null : SessionMeta.decode(mb);
    if (meta == null) {
      if (segNames.isEmpty) await Fs.remove(dir);
      return null;
    }
    // 收编是否已提交，三态：确认不存在或确认长度为 0 = 已提交；长度 > 0 = 未提交（重新收编在 adoptOrphans 里做）；
    // stat 出错 = 判定不了。后两种本轮都跳过，下次重试
    final pre = meta.pre;
    if (pre != null) {
      final pf = Fs.join(preDir, pre);
      final committed = await Fs.isMissing(pf) || (await Fs.isFile(pf) && await Fs.size(pf) == 0);
      if (!committed) return meta;
    }
    final cb = await Fs.read(Fs.join(dir, 'cursor.json'));
    final cursor = (cb == null ? null : Cursor.decode(cb)) ?? Cursor();
    final om = outMax[sid] ?? 0;
    if (om > cursor.extractedThroughOseq) cursor.extractedThroughOseq = om;

    final files = <SegmentFile>[];
    for (final (_, isOpen, n) in segNames) {
      final file = Fs.join(dir, n);
      // 段读不出（I/O 错误）：本次不动这个会话——不推进 cursor、不删目录、不写终态，下次启动重试（ADR 0019 决定 13）
      final f = await Engine.readSegment(file, isOpen);
      if (f == null) return meta;
      if (isOpen && f.validEnd < f.data.length) {
        // 截残行：回到最后一个完整行
        await Fs.truncate(file, f.validEnd);
        f.data = Uint8List.fromList(Uint8List.sublistView(f.data, 0, f.validEnd));
      }
      files.add(f);
      await yieldToEventLoop();
    }

    var maxSeq = 0;
    var maxOseq = 0;
    var maxTs = meta.startedMs;
    final present = <int>{};
    for (final f in files) {
      for (final l in f.lines) {
        if (l.seq > maxSeq) maxSeq = l.seq;
        if (l.ts > maxTs) maxTs = l.ts;
        if (l.oseq > 0) {
          if (l.oseq > maxOseq) maxOseq = l.oseq;
          present.add(l.oseq);
        }
      }
      final ts = f.tornSeq;
      if (ts != null && ts > maxSeq) maxSeq = ts;
      final to = f.tornOseq;
      if (to != null && to > 0 && to > maxOseq) maxOseq = to;
    }
    // 旧段已被驱逐时盘上最大值偏低：并入已物化水位、本会话墓碑与 ctx 游标
    if (cursor.ctxThroughSeq > maxSeq) maxSeq = cursor.ctxThroughSeq;
    var tombMax = 0;
    for (final d in existingDrops) {
      if (d.sessionId == sid && d.oseqTo > tombMax) tombMax = d.oseqTo;
    }
    if (cursor.extractedThroughOseq > maxOseq) maxOseq = cursor.extractedThroughOseq;
    if (tombMax > maxOseq) maxOseq = tombMax;

    if (maxSeq == 0 && maxOseq == 0) {
      // 零行：无数据、无终态可写，直接删目录（ADR 0019 决定 1）。判零行在合成 rtv.unclean_exit 之前
      await Fs.remove(dir);
      return meta;
    }

    final newTombs = <DropEntry>[];
    var exit = SessionExit.unknown;
    if (cursor.closedMs == null) {
      // 缺口（残行、全 0 块、未落盘的 write_failed）计 corrupt 墓碑；已有墓碑覆盖的不重复记
      final covered = existingDrops.where((d) => d.sessionId == sid).toList();
      bool isCovered(int o) => covered.any((d) => d.oseqFrom <= o && o <= d.oseqTo);
      var o = cursor.extractedThroughOseq + 1;
      while (o <= maxOseq) {
        if (present.contains(o) || isCovered(o)) {
          o += 1;
          continue;
        }
        final start = o;
        while (o + 1 <= maxOseq && !present.contains(o + 1) && !isCovered(o + 1)) {
          o += 1;
        }
        newTombs.add(DropEntry(sid, start, o, o - start + 1, DropReason.corrupt, now, lastAckAge(now)));
        o += 1;
      }
      exit = switch (cursor.lastState) {
        'fg' => SessionExit.uncleanFg,
        'bg' => SessionExit.cleanBg,
        _ => SessionExit.unknown,
      };
      final lastFile = files.isEmpty ? null : files.last;
      final lastLine = (lastFile == null || lastFile.lines.isEmpty) ? null : lastFile.lines.last;
      final alreadySynth = lastLine != null && _isUncleanExitLine(lastFile!.data, lastLine.start, lastLine.end);
      // 合成行也是写入：只看本进程内存开关（禁用 = 不写，ADR 0020 决定 2）
      if (exit == SessionExit.uncleanFg && !alreadySynth && enabled) {
        final oblig = LogLevel.error.index >= effective.uploadLevel.index;
        final seq = maxSeq + 1;
        final oseq = oblig ? maxOseq + 1 : 0;
        final ts = maxTs > cursor.lastStateMs ? maxTs : cursor.lastStateMs;
        final enc = LineEncoder.encode(
          LogLine(ts: ts, level: LogLevel.error, msg: 'process ended while foregrounded', tag: 'rtv.unclean_exit'),
          synthetic: true,
        );
        final bytes = Uint8List.fromList([...LineEncoder.prefix(seq, oseq), ...enc.body]);
        String target;
        if (lastFile != null && !lastFile.sealed) {
          target = lastFile.path;
        } else {
          final no = (lastFile?.segNo ?? 0) + 1;
          target = Fs.join(dir, Segments.name(no, true));
          await Fs.writeAtomic(target, SegmentHeader(no, lastFile?.header?.userId, ts).encode());
        }
        if (await Fs.append(target, bytes)) {
          maxSeq = seq;
          if (oseq > 0) maxOseq = oseq;
          final idx = files.indexWhere((f) => f.path == target);
          final nf = await Engine.readSegment(target, false);
          if (nf != null) {
            if (idx >= 0) {
              files[idx] = nf;
            } else {
              files.add(nf);
            }
          }
        }
      }
    }

    if (cursor.closedMs == null) {
      final rec = SessionRecord(meta, dir, cursor, await _sealAll(files));
      // 终态只为有义务行的会话写（ADR 0019 决定 1）
      var closedOk = true;
      if (!existingClosed.contains(sid) && maxOseq > 0) {
        final ended = [maxTs, cursor.lastStateMs, meta.startedMs].reduce((a, b) => a > b ? a : b);
        closedOk = await appendClosed([
          ClosedSession(sid, meta.sessionNo, meta.startedMs, ended, maxSeq, maxOseq, exit),
        ]);
      }
      final dropsOk = newTombs.isEmpty || await appendDrops(newTombs);
      // 按 error 封段带 ctx。墓碑没写成就不物化（物化会把 cursor 推过缺口）；整个会话留到下次启动重试
      if (dropsOk) await materialize(rec, maxOseq, maxSeq, false, true);
      // 终态或墓碑没写成：不打「已收尾」标记，下次启动重试收尾
      if (closedOk && dropsOk) {
        rec.cursor.closedMs = now;
        await writeCursor(rec);
      }
      await _register(rec);
    } else {
      final rec = SessionRecord(meta, dir, cursor, await _sealAll(files));
      if (maxOseq > cursor.extractedThroughOseq) await materialize(rec, maxOseq, maxSeq, false, true);
      await _register(rec);
    }
    return meta;
  }

  Future<void> _register(SessionRecord rec) async {
    if (rec.sealed.isEmpty) {
      await Fs.remove(rec.dir);
    } else {
      others[rec.meta.sessionId] = rec;
    }
  }

  /// 旧会话的 .open 段一律 fsync + rename 为 .sealed；返回段索引。
  Future<List<SegInfo>> _sealAll(List<SegmentFile> files) async {
    final out = <SegInfo>[];
    for (final f in files) {
      var path = f.path;
      if (!f.sealed) {
        await Fs.syncFile(path);
        final dst = Fs.join(Fs.parentOf(path), Segments.name(f.segNo, false));
        if (await Fs.rename(path, dst)) path = dst;
      }
      out.add(segInfoFrom(f, path));
    }
    out.sort((a, b) => a.segNo.compareTo(b.segNo));
    return out;
  }
}

/// 由读出的段重建索引（对位 Android `SegInfo.from`）。
SegInfo segInfoFrom(SegmentFile f, String path) {
  final s = SegInfo(f.segNo, f.header?.userId, f.header?.startedMs ?? 0, path);
  for (final l in f.lines) {
    if (s.firstSeq == 0) s.firstSeq = l.seq;
    if (l.seq > s.lastSeq) s.lastSeq = l.seq;
    s.lineCount += 1;
    if (l.oseq > 0) {
      if (s.firstOseq == 0) s.firstOseq = l.oseq;
      if (l.oseq > s.lastOseq) s.lastOseq = l.oseq;
      s.obligCount += 1;
      if (l.levelRank >= Level.error) s.hasError = true;
    }
  }
  s.bytes = f.data.length;
  return s;
}
