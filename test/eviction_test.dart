// 对位 Android EvictionTests.kt：容量与驱逐（方案 §3.8；宪法 R-5）。

import 'dart:io';

import 'package:revdog_retriever/src/engine.dart';
import 'package:revdog_retriever/src/fs.dart';
import 'package:revdog_retriever/src/ids.dart';
import 'package:revdog_retriever/src/limits.dart';
import 'package:revdog_retriever/src/materializer.dart';
import 'package:revdog_retriever/src/model.dart';
import 'package:revdog_retriever/src/outbox.dart';
import 'package:test/test.dart';

import 'support/support.dart';

/// 准备：RETAINED 段 ×2（无义务）、p2、q、p1、p0 各一。
Future<Harness> prepare() async {
  final h = await Harness.create(key: '');
  await h.settle();
  // 先生成一个 p2（只覆盖第一段），再塞两段 RETAINED 作驱逐对象
  h.l(LogLevel.debug, 'backfill me');
  await h.seal();
  await h.work((e) => e.materializeBackfill());
  for (var k = 0; k < 2; k++) {
    final seg = h.client.writer.snapshot.segNo;
    while (h.client.writer.snapshot.segNo == seg) {
      h.l(LogLevel.debug, 'd' * 300);
    }
    await h.settle();
  }
  h.l(LogLevel.warn, 'to quarantine');
  await h.seal();
  await h.work((e) => e.quarantine(e.metas.values.firstWhere((m) => m.prio == 1).name));
  h.clock.advance(1);
  h.l(LogLevel.warn, 'p1');
  await h.seal();
  h.clock.advance(1);
  h.l(LogLevel.error, 'p0');
  await h.seal();
  expect(h.outboxFiles().map((n) => n.substring(0, 2)).toList()..sort(), ['p0', 'p1', 'p2', 'q-']);
  return h;
}

List<String> sealedSegs(String dir) =>
    (Fs.listSync(dir) ?? const <String>[]).where((n) => n.endsWith('.sealed')).toList()..sort();

void main() {
  setUpRtv();

  test('evictionOrderAndTombstones', () async {
    final h = await prepare();
    final sid = h.client.writer.currentSessionId;
    final dir = h.sessionDir();
    expect(sealedSegs(dir).length, 6);
    // 阶段 1：上限刚好容下「出站箱全部 − p2」+ 当前段 → 删光 RETAINED 段，再删 p2
    final (segBytes, openBytes, box) = await h.work((e) {
      final segs = e.current!.sealed.fold<int>(0, (a, i) => a + File(i.path).lengthSync());
      final open = File(e.writer.currentSegmentPath!).lengthSync();
      final b = <String, int>{};
      for (final m in e.metas.values) {
        b[m.name.substring(0, 2)] = m.bytes;
      }
      return (segs, open, b);
    });
    expect(segBytes, greaterThan(1000000));
    final cap1 = openBytes + box['q-']! + box['p1']! + box['p0']!;
    await h.work((e) async {
      e.effective.config = e.effective.config.copyWith(localCapBytes: cap1);
      await e.evictIfNeeded();
    });
    expect(sealedSegs(dir), isEmpty);
    expect(h.outboxFiles().map((n) => n.substring(0, 2)).toList()..sort(), ['p0', 'p1', 'q-']);
    var drops = h.readJsonl('drops.jsonl');
    expect(drops.map((d) => d['reason']).toList(), ['backfill_evicted'], reason: 'RETAINED 段无义务：不记墓碑');
    expect(int_(drops[0]['oseq_from']), 0);
    expect(int_(drops[0]['oseq_to']), 0);
    expect(int_(drops[0]['n']), 1);
    // 阶段 2：上限 0 → q → p1 → p0 依次驱逐；当前 OPEN 段永不驱逐
    await h.work((e) async {
      e.effective.config = e.effective.config.copyWith(localCapBytes: 0);
      await e.evictIfNeeded();
    });
    expect(h.outboxFiles(), isEmpty);
    expect(File(h.client.debugOpenSegmentFile!).existsSync(), isTrue);
    drops = h.readJsonl('drops.jsonl');
    expect(drops.map((d) => d['reason']).toList(), [
      'backfill_evicted',
      'quarantine_evicted',
      'buffer_overflow',
      'buffer_overflow',
    ]);
    expect(drops.map((d) => int_(d['oseq_from'])).toList(), [0, 1, 2, 3]);
    expect(drops.every((d) => d['session_id'] == sid), isTrue);
    expect(drops.every((d) => int_(d['last_ack_age_ms']) == -1), isTrue);
    // 墓碑随下一个 primary 批上报，服务端校验通过
    await h.work((e) => e.effective.config = e.effective.config.copyWith(localCapBytes: Limits.localCapBytesDefault));
    h.l(LogLevel.warn, 'carrier');
    await h.seal();
    final env = h.envelopes().first;
    expect(objs(env['drops']).length, 4);
    final results = await runValidator([env]);
    assertAllValid(results);
    expect(int_(obj(results[0]['stats'])['dropsN']), 4);
  });

  /// ADR 0010：可用空间 10 MB（余量额度算成 0）时刚物化的 error 批留在出站箱并被上传，RETAINED 段让出。
  test('lowDiskKeepsFreshObligationBatchAndUploadsIt', () async {
    final h = await Harness.create();
    await h.settle();
    h.platform.available = 10 * 1024 * 1024;
    h.l(LogLevel.debug, 'context');
    h.l(LogLevel.error, 'boom');
    await h.seal(SealReason.error);
    expect(h.outboxFiles('p0').length, 1, reason: '义务批不因磁盘余量被驱逐');
    expect(sealedSegs(h.sessionDir()), isEmpty, reason: 'RETAINED 段被驱逐');
    expect(File(h.client.debugOpenSegmentFile!).existsSync(), isTrue);
    expect(h.readJsonl('drops.jsonl').length, 0);
    await h.tick(2000);
    expect(h.transport.batchRequests.length, 1);
    expect(FakeTransport.envOf(h.transport.batchRequests[0].body)!.lines.map((l) => l['msg']).toList(), [
      'context',
      'boom',
    ]);
    expect(h.outboxFiles(), isEmpty);
  });

  /// ADR 0010：低磁盘只驱逐 RETAINED 段与 p2（记 backfill_evicted）；超过 local_cap_bytes 时仍按 q → p1 → p0 驱逐并记墓碑。
  test('lowDiskEvictsOnlyNonObligationUntilHardCap', () async {
    final h = await prepare();
    final dir = h.sessionDir();
    expect(sealedSegs(dir).length, 6);
    h.platform.available = 10 * 1024 * 1024;
    await h.work((e) => e.evictIfNeeded());
    expect(sealedSegs(dir), isEmpty);
    expect(h.outboxFiles().map((n) => n.substring(0, 2)).toList()..sort(), ['p0', 'p1', 'q-']);
    expect(h.readJsonl('drops.jsonl').map((d) => d['reason']).toList(), ['backfill_evicted']);
    // 再次驱逐（磁盘仍紧张）：义务批与隔离批不动
    await h.work((e) => e.evictIfNeeded());
    expect(h.outboxFiles().map((n) => n.substring(0, 2)).toList()..sort(), ['p0', 'p1', 'q-']);
    // 硬上限压到 0：q → p1 → p0 依次驱逐，当前 OPEN 段永不驱逐
    await h.work((e) async {
      e.effective.config = e.effective.config.copyWith(localCapBytes: 0);
      await e.evictIfNeeded();
    });
    expect(h.outboxFiles(), isEmpty);
    expect(File(h.client.debugOpenSegmentFile!).existsSync(), isTrue);
    final drops = h.readJsonl('drops.jsonl');
    expect(drops.map((d) => d['reason']).toList(), [
      'backfill_evicted',
      'quarantine_evicted',
      'buffer_overflow',
      'buffer_overflow',
    ]);
    expect(drops.map((d) => int_(d['oseq_from'])).toList(), [0, 1, 2, 3]);
  });

  test('segmentsOlderThanSevenDaysDeletedUnconditionally', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    h.l(LogLevel.debug, 'old');
    await h.seal();
    final seg = '${h.sessionDir()}/seg-000001.sealed';
    expect(File(seg).existsSync(), isTrue);
    await Fs.touch(seg, h.clock.wallMs() - 8 * ClientConstants.dayMs);
    await h.work((e) => e.evictIfNeeded());
    expect(File(seg).existsSync(), isFalse);
    expect(h.readJsonl('drops.jsonl').length, 0);
  });

  /// drops.jsonl 到上限只做无损合并（ADR 0019 决定 4）。
  test('dropsFileCapOnlyLosslessMerge', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    final sid = h.client.writer.currentSessionId;
    // 1100 条稀疏单点（间隔 1，互不相接）+ 3 组相接的区间（各可并成一条）+ 一个别的会话的同区间（不跨会话合并）
    final sparse = [for (var i = 1; i <= 1100; i++) DropEntry(sid, i * 2, i * 2, 1, 'write_failed', i, -1)];
    final adjacent = [
      DropEntry(sid, 10000, 10004, 5, 'buffer_overflow', 1, -1),
      DropEntry(sid, 10005, 10009, 5, 'buffer_overflow', 2, -1),
      DropEntry(sid, 20000, 20009, 10, 'corrupt', 3, -1),
      DropEntry(sid, 20005, 20019, 15, 'corrupt', 4, -1),
    ];
    final other = Ids.newV4();
    final foreign = DropEntry(other, 10000, 10004, 5, 'buffer_overflow', 5, -1);
    final input = [...sparse, ...adjacent, foreign];
    await h.work((e) => e.appendDrops(input));
    final drops = h.readJsonl('drops.jsonl').map((o) => DropEntry.decode(o)!).toList();
    expect(drops.length, ClientConstants.dropsFileMaxEntries);
    for (final d in drops) {
      expect(d.n, d.oseqTo - d.oseqFrom + 1, reason: '$d');
    }
    expect(drops.contains(DropEntry(sid, 10000, 10009, 10, 'buffer_overflow', 2, -1)), isTrue);
    expect(drops.contains(DropEntry(sid, 20000, 20019, 20, 'corrupt', 4, -1)), isTrue);
    expect(drops.contains(foreign), isTrue, reason: '不跨会话合并');
    // 没有任何条目覆盖输入里不存在的 oseq
    final inputCover = <int>{};
    for (final d in input.where((d) => d.sessionId == sid)) {
      for (var o = d.oseqFrom; o <= d.oseqTo; o++) {
        inputCover.add(o);
      }
    }
    for (final d in drops.where((d) => d.sessionId == sid)) {
      for (var o = d.oseqFrom; o <= d.oseqTo; o++) {
        expect(inputCover.contains(o), isTrue, reason: '$d');
      }
    }
    // 仍超出删的是最旧的（文件最前面的稀疏点），最新的保留
    expect(drops.any((d) => d.oseqFrom == 2), isFalse);
    expect(drops.any((d) => d.oseqFrom == 2200), isTrue);
  });

  /// 无损合并只收合法区间：oseq_from < 1 的非 backfill 条目原样保留、不参与合并（同 iOS）。
  test('capDropsKeepsInvalidRangeUnmerged', () {
    final sid = Ids.newV4();
    final zero = DropEntry(sid, 0, 0, 1, 'corrupt', 1, -1);
    final all = [zero, DropEntry(sid, 1, 1, 1, 'corrupt', 2, -1), DropEntry(sid, 2, 2, 1, 'corrupt', 3, -1)];
    expect(Engine.capDrops(all, <DropEntry>{}, 2), [zero, DropEntry(sid, 1, 2, 2, 'corrupt', 3, -1)]);
  });

  /// 每批按文件顺序带最旧的 100 条墓碑：各自会话与精确区间，不合并；带不完的留给下一批（ADR 0019 决定 2）。
  test('dropsCarriedUnmergedOldestFirst', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    final entries = [for (var i = 1; i <= 150; i++) DropEntry(Ids.newV4(), 5, 7, 3, 'buffer_overflow', i, -1)];
    await h.work((e) => e.appendDrops(entries));
    final before = File('${h.root}/drops.jsonl').readAsBytesSync();
    h.l(LogLevel.warn, 'carrier 1');
    await h.seal();
    expect(File('${h.root}/drops.jsonl').readAsBytesSync(), before, reason: '携带不改写文件');
    final first = objs(h.envelopes().single['drops']);
    expect(first.length, Limits.dropsPerBatch);
    expect(first.map((d) => d['session_id']).toList(), entries.take(100).map((e) => e.sessionId).toList());
    expect(first.every((d) => int_(d['oseq_from']) == 5 && int_(d['oseq_to']) == 7 && int_(d['n']) == 3), isTrue);
    h.clock.advance(1);
    h.l(LogLevel.warn, 'carrier 2');
    await h.seal();
    final second = objs(h.envelopes().singleWhere((e) => e.lines.any((l) => l['msg'] == 'carrier 2'))['drops']);
    expect(second.map((d) => d['session_id']).toList(), entries.skip(100).map((e) => e.sessionId).toList());
    assertAllValid(await runValidator(h.envelopes()));
    // 两批都确认后文件清空
    await h.enableUpload();
    await h.tick(2000);
    expect(h.outboxFiles(), isEmpty);
    expect(h.readJsonl('drops.jsonl').length, 0);
  });

  /// 30 条非空终态：第一批最旧 20 条、第二批 10 条；全程没有 closed_sessions_dropped，携带前后文件字节不变（ADR 0019 决定 2）。
  test('terminalsCarriedOldestFirstNeverDropped', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    final closed = [
      for (var i = 1; i <= 30; i++) ClosedSession(Ids.newV4(), i, i * 1000, i * 1000 + 500, 10, 2, 'clean_bg'),
    ];
    await Fs.append('${h.root}/sessions.jsonl', Jsonl.encodeClosed(closed));
    final before = File('${h.root}/sessions.jsonl').readAsBytesSync();
    h.l(LogLevel.warn, 'carrier 1');
    await h.seal();
    final env1 = h.envelopes().single;
    expect(objs(env1['closed_sessions']).map((c) => int_(c['session_no'])).toList(), [for (var i = 1; i <= 20; i++) i]);
    expect(env1.map.containsKey('closed_sessions_dropped'), isFalse);
    expect(File('${h.root}/sessions.jsonl').readAsBytesSync(), before, reason: '携带不改写文件');
    h.clock.advance(1);
    h.l(LogLevel.warn, 'carrier 2');
    await h.seal();
    final env2 = h.envelopes().singleWhere((e) => e.lines.any((l) => l['msg'] == 'carrier 2'));
    expect(objs(env2['closed_sessions']).map((c) => int_(c['session_no'])).toList(), [
      for (var i = 21; i <= 30; i++) i,
    ]);
    expect(env2.map.containsKey('closed_sessions_dropped'), isFalse);
    assertAllValid(await runValidator([env1, env2]));
    // 2xx 后删除已报条目
    await h.enableUpload();
    await h.tick(2000);
    expect(h.outboxFiles(), isEmpty);
    expect(h.readJsonl('sessions.jsonl').length, 0);
  });

  /// 一个有数据的后台会话 + 25 个空的后台会话：空会话不写终态、目录直接删，真实会话的终态随载体批上报（ADR 0019 决定 1）。
  test('realTerminalSurvivesEmptySessions', () async {
    final root = tempDir();
    final clock = FakeClock();
    final p = FakePlatform(clock: clock)..foreground = false;
    final real = await Harness.create(root: root, key: '', platform: p, clock: clock);
    await real.settle();
    real.l(LogLevel.warn, 'real bg work');
    final realSid = real.client.writer.currentSessionId;
    await real.simulateCrash();
    for (var i = 0; i < 25; i++) {
      clock.advance(1000);
      final empty = await Harness.create(root: root, key: '', platform: p, clock: clock);
      await empty.settle();
      await empty.simulateCrash();
    }
    final last = await Harness.create(root: root, key: '', platform: p, clock: clock);
    await last.settle();
    final terms = last.readJsonl('sessions.jsonl');
    expect(terms.map((t) => t['session_id']).toList(), [realSid]);
    expect(terms.every((t) => int_(t['last_oseq']) != 0), isTrue);
    expect((Fs.listSync('$root/proc-main') ?? const <String>[]).toSet(), {
      realSid,
      last.client.writer.currentSessionId,
    }, reason: '空会话目录已删，只剩真实会话与当前会话');
    last.l(LogLevel.warn, 'carrier');
    await last.seal();
    final carriers = last.envelopes().where((e) => objs(e['closed_sessions']).any((c) => c['session_id'] == realSid));
    expect(carriers.length, 1);
  });

  /// sessions.jsonl 上限 1000 条：超出删最旧的未在途条目（ADR 0019 决定 3）。
  test('sessionsFileCapDropsOldest', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    final closed = [
      for (var i = 1; i <= 1005; i++) ClosedSession(Ids.newV4(), i, i * 1000, i * 1000 + 500, 10, 2, 'clean_bg'),
    ];
    await h.work((e) => e.appendClosed(closed));
    final left = h.readJsonl('sessions.jsonl').map((c) => int_(c['session_no'])).toList();
    expect(left, [for (var i = 6; i <= 1005; i++) i]);
  });
}
