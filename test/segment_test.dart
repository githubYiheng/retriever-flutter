// 对位 Android SegmentTests.kt（含 BackfillTests）：段状态机与物化（方案 §3.4 / §3.5）。

import 'dart:io';

import 'package:revdog_retriever/src/ids.dart';
import 'package:revdog_retriever/src/json.dart';
import 'package:revdog_retriever/src/limits.dart';
import 'package:revdog_retriever/src/materializer.dart';
import 'package:revdog_retriever/src/model.dart';
import 'package:test/test.dart';

import 'support/support.dart';

List<String> segFiles(Harness h) => ((Directory(
  h.sessionDir(),
).listSync().map((e) => e.path.split('/').last)).where((n) => n.startsWith('seg-')).toList()..sort());

Map<String, Object?> header(String path) => JsonIn.objText(File(path).readAsStringSync().split('\n')[0])!;

Map<String, Object?>? flushLine(Env e) {
  for (final l in e.lines) {
    if (l['tag'] == 'rtv.flush') return l;
  }
  return null;
}

void main() {
  setUpRtv();

  group('SegmentTests', () {
    test('rotatesAt512KB', () async {
      final h = await Harness.create(key: '');
      await h.settle();
      while (segFiles(h).length < 2) {
        h.l(LogLevel.debug, 'fill ${'x' * 200}');
      }
      await h.settle();
      expect(segFiles(h), ['seg-000001.sealed', 'seg-000002.open']);
      final size = File('${h.sessionDir()}/seg-000001.sealed').lengthSync();
      expect(size, greaterThanOrEqualTo(Limits.segmentBytes));
      expect(size, lessThan(Limits.segmentBytes + 400));
      expect(int_(header('${h.sessionDir()}/seg-000002.open')['seg_no']), 2);
      // 全是 debug（非义务行）→ 不产生批次
      expect(h.outboxFiles(), isEmpty);
      final cursor = h.readJson('${h.sessionDir()}/cursor.json');
      expect(int_(cursor['extracted_through_oseq']), 0);
      expect(cursor['last_state'], 'fg');
    });

    test('setUserSealsAndHeaderCarriesUser', () async {
      final h = await Harness.create(key: '');
      await h.settle();
      h.setUser('early'); // 段内还没有行：直接改写 header，不封段
      h.l(LogLevel.warn, 'as early');
      h.setUser('u1');
      h.l(LogLevel.warn, 'as u1');
      h.setUser('u1'); // 值没变：不封段
      h.l(LogLevel.warn, 'still u1');
      h.setUser(null);
      await h.settle();
      final files = segFiles(h);
      expect(files, ['seg-000001.sealed', 'seg-000002.sealed', 'seg-000003.open']);
      expect(header('${h.sessionDir()}/${files[0]}')['user_id'], 'early');
      expect(header('${h.sessionDir()}/${files[1]}')['user_id'], 'u1');
      final h3 = header('${h.sessionDir()}/${files[2]}');
      expect(h3.containsKey('user_id') && h3['user_id'] == null, isTrue);
      final envs = h.envelopes()..sort((a, b) => int_(a['oseq_from']).compareTo(int_(b['oseq_from'])));
      expect(envs.length, 2);
      expect(envs[0]['user_id'], 'early');
      expect(envs[0].lines.map((l) => l['msg']).toList(), ['as early']);
      expect(envs[1]['user_id'], 'u1');
      expect(envs[1].lines.map((l) => l['msg']).toList(), ['as u1', 'still u1']);
      expect(obj(envs[1]['mapping'])['user_id'], 'u1');
    });

    test('errorDebounceTwoSecondsAndTenSecondSpacing', () async {
      final h = await Harness.create(key: '');
      await h.settle();
      h.l(LogLevel.error, 'e1');
      h.l(LogLevel.debug, 'after e1');
      await h.tick(1999);
      expect(h.outboxFiles(), isEmpty);
      await h.tick(1);
      expect(h.outboxFiles('p0').length, 1);
      // 第二个 error：距上次 error 封段不足 10 s → 推到 10 s
      await h.tick(1000);
      h.l(LogLevel.error, 'e2');
      await h.tick(2000);
      expect(h.outboxFiles('p0').length, 1);
      await h.tick(6999);
      expect(h.outboxFiles('p0').length, 1);
      await h.tick(1);
      expect(h.outboxFiles('p0').length, 2);
    });

    test('fatalSealsImmediatelyWithoutUpload', () async {
      final h = await Harness.create();
      await h.settle();
      final before = h.transport.batchRequests.length;
      h.l(LogLevel.info, 'ctx before fatal');
      h.l(LogLevel.fatal, 'crashing');
      // 封段物化在引擎队列上异步做（ADR 0020 决定 1）；做完后批在出站箱，且没有发起上传
      await h.settle();
      expect(h.outboxFiles('p0').length, 1);
      expect(h.transport.batchRequests.length, before);
      final e = h.envelopes('p0').first;
      expect(e.lines.map((l) => l['msg']).toList(), ['ctx before fatal', 'crashing']);
      expect(e.lines.first['ctx'], true);
    });

    test('warnTimerFlushInterval', () async {
      final h = await Harness.create(key: '');
      await h.settle();
      h.l(LogLevel.info, 'not obligation');
      await h.tick(400000);
      expect(h.outboxFiles(), isEmpty, reason: '没有义务行不封');
      h.l(LogLevel.warn, 'w');
      await h.tick(299999);
      expect(h.outboxFiles(), isEmpty);
      await h.tick(1);
      expect(h.outboxFiles('p1').length, 1);
    });

    test('ctxAcrossSegmentsAndDedupedByCtxThroughSeq', () async {
      final h = await Harness.create(key: '');
      await h.settle();
      // 段 1 塞满 debug，段 2 再写 50 行 debug，然后 error
      while (segFiles(h).length < 2) {
        h.l(LogLevel.debug, 'old ${'o' * 300}');
      }
      final seg1Last = h.client.debugCounters.$1;
      for (var i = 0; i < 50; i++) {
        h.l(LogLevel.debug, 'new $i');
      }
      h.l(LogLevel.error, 'e1');
      await h.tick(2000);
      final e1 = h.envelopes('p0').first;
      final ctx1 = e1.lines.where((l) => l['ctx'] == true).toList();
      expect(ctx1.length, Limits.ctxLinesDefault);
      expect(ctx1.any((l) => int_(l['seq']) <= seg1Last), isTrue, reason: 'ctx 跨段取');
      expect(ctx1.any((l) => int_(l['seq']) > seg1Last), isTrue);
      expect(int_(e1['ctx_truncated']), greaterThan(0));
      expect(ctx1.every((l) => !l.containsKey('oseq')), isTrue);
      // 行按 seq 升序，ctx 与义务行交错
      final seqs = e1.lines.map((l) => int_(l['seq'])).toList();
      expect(seqs, List.of(seqs)..sort());
      // 第二个 error 只带新的 ctx
      final through = int_(e1['seq_to']);
      for (var i = 0; i < 5; i++) {
        h.l(LogLevel.info, 'between $i');
      }
      h.l(LogLevel.error, 'e2');
      await h.tick(10000);
      final all = h.envelopes('p0');
      expect(all.length, 2);
      final e2 = all.firstWhere((e) => int_(e['oseq_from']) == 2);
      final ctx2 = e2.lines.where((l) => l['ctx'] == true).toList();
      expect(ctx2.map((l) => l['msg']).toList(), [for (var i = 0; i < 5; i++) 'between $i']);
      expect(ctx2.every((l) => int_(l['seq']) > through), isTrue);
      expect(int_(e2['ctx_truncated']), 0);
      assertAllValid(await runValidator(all));
    });

    test('dailyCapMergesP1AndSplitsAt768KB', () async {
      final h = await Harness.create(key: '', options: const RetrieverOptions(dailyBatchCap: 1));
      await h.settle();
      h.l(LogLevel.warn, 'first');
      await h.seal();
      expect(h.outboxFiles('p1').length, 1);
      // 超出上限的 p1 推迟：每段 ~512 KB 的 warn，封 3 段
      final big = 'w' * 4000;
      for (var k = 0; k < 3; k++) {
        final seg = h.client.writer.snapshot.segNo;
        while (h.client.writer.snapshot.segNo == seg) {
          h.l(LogLevel.warn, big);
        }
        await h.settle();
      }
      expect(h.outboxFiles().length, 1, reason: 'p1 被推迟合并');
      // p0 不受限，并把推迟的义务行一起物化（按 768 KB 切多批，oseq 首尾相接）
      h.l(LogLevel.error, 'boom');
      await h.seal(SealReason.error);
      final envs = h.envelopes()..sort((a, b) => int_(a['oseq_from']).compareTo(int_(b['oseq_from'])));
      expect(envs.length, greaterThanOrEqualTo(4));
      for (var i = 1; i < envs.length; i++) {
        expect(int_(envs[i]['oseq_from']), int_(envs[i - 1]['oseq_to']) + 1);
      }
      expect(int_(envs.last['oseq_to']), h.client.debugCounters.$2);
      for (final e in envs) {
        expect(e.raw.length, lessThanOrEqualTo(Limits.batchUncompressedBytesClient));
      }
      expect(h.outboxFiles('p0').length, 1);
      assertAllValid(await runValidator(envs));
    });

    test('flushWithContextStoredAfterAck', () async {
      final h = await Harness.create();
      await h.settle();
      h.l(LogLevel.info, 'user tapped report');
      h.l(LogLevel.debug, 'detail');
      expect(await h.flushBlocking(true), FlushResult.stored);
      final e = FakeTransport.envOf(h.transport.batchRequests.last.body)!;
      final marker = flushLine(e)!;
      expect(marker['level'], 'error');
      expect(marker['msg'], 'flush');
      expect(marker['synthetic'], true);
      expect(int_(marker['oseq']), 1);
      expect(e.lines.where((l) => l['ctx'] == true).map((l) => l['msg']).toList(), ['user tapped report', 'detail']);
      expect(h.outboxFiles(), isEmpty);
    });

    test('flushWithoutContextAndAboveUploadLevel', () async {
      final h = await Harness.create(
        options: const RetrieverOptions(uploadLevel: LogLevel.fatal, localLevel: LogLevel.fatal),
      );
      await h.settle();
      h.l(LogLevel.fatal, 'earlier fatal');
      h.l(LogLevel.info, 'filtered by localLevel');
      await h.settle();
      final n0 = h.transport.batchRequests.length;
      expect(await h.flushBlocking(false), FlushResult.stored);
      expect(h.transport.batchRequests.length, greaterThan(n0));
      final e = h.transport.batchRequests
          .map((r) => FakeTransport.envOf(r.body)!)
          .firstWhere((e) => flushLine(e) != null);
      expect(e.lines.where((l) => l['ctx'] == true).length, 0, reason: 'includeContext = false 不带 ctx');
      expect(e['ctx_truncated'], isNull);
      expect(flushLine(e)!['oseq'], isNotNull, reason: 'uploadLevel 高于 error 也是义务行');
    });

    test('flushPendingReasons', () async {
      final h = await Harness.create();
      await h.settle();
      h.transport.defaultReply = Reply.network;
      expect(await h.flushBlocking(), FlushResult.pending('offline'));
      // 退避回到 0 后测 401 → paused
      await h.work((e) => e.backoff = BackoffState());
      h.transport.defaultReply = Reply.status(401, {'reason': 'key_invalid'});
      await h.tick(3000);
      expect(await h.flushBlocking(), FlushResult.pending('paused'));
      // 503 + Retry-After 1 h：退避超出 15 s 窗口 → backoff
      await h.work((e) => e.backoff = BackoffState());
      h.transport.defaultReply = Reply.status(
        503,
        {'reason': 'storage', 'retry_after_s': 3600},
        {'retry-after': '3600'},
      );
      await h.tick(3000);
      expect(await h.flushBlocking(), FlushResult.pending('backoff'));
      // 在途请求挂起 → 真实时间兜底 timeout
      await h.work((e) => e.backoff = BackoffState());
      h.transport.defaultReply = Reply.hang;
      h.client.setFlushWindowForTesting(200);
      h.clock.advance(3000); // 越过 2 s 间隔，让 flush 的批立即在途
      expect(await h.flushBlocking(), FlushResult.pending('timeout'));
      expect(h.transport.hangingCount, 1);
      h.transport.defaultReply = Reply.network;
      h.transport.cancelAll();
      await h.settle();
      h.setEnabled(false);
      expect(await h.flushBlocking(), FlushResult.pending('disabled'));
      expect(FlushResult.pending('disabled').toString(), 'pending("disabled")', reason: '与 iOS / Android 一致');
      expect(FlushResult.stored.toString(), 'stored');
    });
  });

  /// backfill（full_dump 生效；主代理 2026-09-29 裁决）：RETAINED 段中全部非义务行按段成批，不受 ctx_through_seq 限制。
  group('BackfillTests', () {
    test('backfillIncludesLinesAlreadySentAsCtx', () async {
      final h = await Harness.create(key: '');
      await h.settle();
      for (var i = 0; i < 5; i++) {
        h.l(LogLevel.debug, 'before error $i');
      }
      h.l(LogLevel.error, 'e');
      await h.tick(2000);
      final p0 = h.envelopes('p0').first;
      expect(p0.lines.where((l) => l['ctx'] == true).length, 5);
      h.l(LogLevel.info, 'after');
      await h.seal();
      await h.work((e) => e.materializeBackfill());
      final bfs = h.envelopes('p2')..sort((a, b) => int_(a['seq_from']).compareTo(int_(b['seq_from'])));
      expect(bfs.length, 2, reason: '每段一批');
      expect(bfs[0].lines.map((l) => l['msg']).toList(), [for (var i = 0; i < 5; i++) 'before error $i']);
      expect(bfs[1].lines.map((l) => l['msg']).toList(), ['after']);
      final iid = h.client.installId!;
      final sid = h.client.writer.currentSessionId;
      expect(bfs[0]['batch_id'], Ids.batchId(iid, sid, BatchKind.backfill, 1));
      expect(bfs[1]['batch_id'], Ids.batchId(iid, sid, BatchKind.backfill, 2));
      // 同一进程内不重复生成
      await h.work((e) => e.materializeBackfill());
      expect(h.outboxFiles('p2').length, 2);
      assertAllValid(await runValidator(bfs));
    });

    test('oversizedSegmentSplitsBySeqWithThreePartName', () async {
      final h = await Harness.create(key: '');
      await h.settle();
      for (var i = 0; i < 30; i++) {
        h.l(LogLevel.debug, 'd$i ${'x' * 300}');
      }
      await h.seal();
      await h.work((e) => e.materializeBackfill(4096));
      final parts = h.envelopes('p2')..sort((a, b) => int_(a['seq_from']).compareTo(int_(b['seq_from'])));
      expect(parts.length, greaterThan(1));
      final iid = h.client.installId!;
      final sid = h.client.writer.currentSessionId;
      var next = 1;
      for (final p in parts) {
        expect(int_(p['seq_from']), next, reason: '按 seq 首尾相接');
        next = int_(p['seq_to']) + 1;
        final name = '$iid:$sid:backfill:1:${int_(p['seq_from'])}';
        expect(p['batch_id'], Ids.uuidv5(Ids.namespace, name));
        expect(p.raw.length, lessThanOrEqualTo(4096 + 400));
        expect(p.map.containsKey('oseq_from'), isFalse);
      }
      expect(next, 31);
      assertAllValid(await runValidator(parts));
    });
  });
}
