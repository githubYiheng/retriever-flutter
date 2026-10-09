// 对位 Android QueueTests.kt：出站队列与响应分类（方案 §3.6 / §3.7；宪法 R-2 / R-3）。

import 'dart:convert';
import 'dart:io';

import 'package:revdog_retriever/src/gzip.dart';
import 'package:revdog_retriever/src/ids.dart';
import 'package:revdog_retriever/src/limits.dart';
import 'package:revdog_retriever/src/materializer.dart';
import 'package:revdog_retriever/src/outbox.dart';
import 'package:revdog_retriever/src/transport.dart';
import 'package:test/test.dart';

import 'support/support.dart';

Env env(TransportRequest r) => FakeTransport.envOf(r.body)!;

void main() {
  setUpRtv();

  test('ackWithEchoDeletesFile', () async {
    final h = await Harness.create();
    await h.settle();
    h.l(LogLevel.info, 'ctx');
    h.l(LogLevel.warn, 'w1');
    await h.sealAndDrain();
    expect(h.transport.batchRequests.length, 1);
    expect(h.outboxFiles(), isEmpty);
    final r = h.transport.batchRequests[0];
    expect(r.method, 'POST');
    expect(r.url, 'https://logs-test.invalid/v1/batches');
    expect(r.headers['Authorization'], 'Bearer lk_test_demo_abc_12345678');
    expect(r.headers['Content-Type'], 'application/json');
    expect(r.headers['Content-Encoding'], 'gzip');
    expect(r.headers['X-Rtv-Install'], h.client.installId);
    expect(r.headers['X-Rtv-Sent-Ms'], h.clock.wallMs().toString());
    expect(r.headers['X-Rtv-Sdk'], 'retriever-flutter/${RetrieverVersion.current}');
    final e = env(r);
    expect(e['kind'], 'primary');
    expect(int_(e['oseq_from']), 1);
    expect(e.lines.length, 1, reason: '纯 warn 批不带 ctx');
    expect(e.lines.first['msg'], 'w1');
    final b = await h.backoff;
    expect(b.attempt, 0);
    expect(b.lastAckMs, h.clock.wallMs());
    // mapping 块已被确认 → mapping.json
    final m = h.readJson('${h.root}/mapping.json');
    expect(m.containsKey('user_id') && m['user_id'] == null, isTrue);
    expect(int_(m['acked_ms']), h.clock.wallMs());
  });

  test('echoMismatchKeepsFileAndBacksOff', () async {
    final h = await Harness.create();
    await h.settle();
    h.transport.setScript([Reply.echoWrong]);
    h.l(LogLevel.warn, 'w');
    await h.sealAndDrain();
    expect(h.transport.batchRequests.length, 1);
    expect(h.outboxFiles().length, 1);
    final b = await h.backoff;
    final wait = b.nextAtMonoMs - h.nowMono;
    expect(b.attempt, 1);
    expect(wait, inInclusiveRange(800, 1200));
    expect(b.reason, 'echo_mismatch');
    // 退避期内不发（且相邻请求 ≥ 2 s）
    await h.tick(700);
    expect(h.transport.batchRequests.length, 1);
    await h.tick(1300);
    expect(h.transport.batchRequests.length, 2);
    expect(h.outboxFiles(), isEmpty);
    // backoff.json 已持久化
    expect(int_(h.readJson('${h.root}/backoff.json')['attempt']), 0);
  });

  test('unauthorizedPausesOneHourThenDoubles', () async {
    final h = await Harness.create();
    await h.settle();
    h.transport.setScript([
      Reply.status(401, {'reason': 'key_invalid'}),
      Reply.status(403, {'reason': 'app_disabled'}),
    ]);
    h.l(LogLevel.warn, 'w');
    await h.sealAndDrain();
    var b = await h.backoff;
    expect(b.pausedCategories, ['all']);
    expect(b.pausedUntilMono - h.nowMono, 3600000);
    expect(h.outboxFiles().length, 1, reason: '不删任何文件');
    // 照常写本地
    h.l(LogLevel.warn, 'still written');
    expect(h.client.debugCounters.$2, 2);
    await h.tick(3599000);
    expect(h.transport.batchRequests.length, 1);
    await h.tick(1000);
    expect(h.transport.batchRequests.length, 2);
    b = await h.backoff;
    expect(b.pausedUntilMono - h.nowMono, 7200000);
    expect(h.outboxFiles().length, 2, reason: 'warn 计时封出的第二批也在，均未删');
    // 暂停期间照常拉配置
    final cfgBefore = h.transport.configRequests.length;
    await h.tick(Limits.configPollIntervalS * 1000);
    expect(h.transport.configRequests.length, greaterThan(cfgBefore));
    expect(h.transport.batchRequests.length, 2);
    // 24 h 封顶
    for (var i = 0; i < 6; i++) {
      await h.work((e) {
        e.backoff.pausedUntilMono = 0;
        e.backoff.pausedCategories = <String>[];
      });
      h.transport.setScript([
        Reply.status(401, {'reason': 'key_invalid'}),
      ]);
      await h.tick(Limits.minRequestSpacingMs);
    }
    b = await h.backoff;
    expect(b.pausedUntilMono - h.nowMono, Limits.pause401MaxMs);
  });

  test('tooLargeSplitsIntoContiguousHalves', () async {
    final h = await Harness.create();
    await h.settle();
    h.transport.setScript([
      Reply.status(413, {'reason': 'too_large', 'max_bytes': 1048576}),
      Reply.echo,
      Reply.echo,
    ]);
    for (var i = 1; i <= 6; i++) {
      h.l(i == 5 ? LogLevel.error : LogLevel.warn, 'w$i');
    }
    h.l(LogLevel.debug, 'ctx after');
    await h.sealAndDrain();
    expect(h.transport.batchRequests.length, 1);
    final original = env(h.transport.batchRequests[0]);
    expect(int_(original['oseq_from']), 1);
    expect(int_(original['oseq_to']), 6);
    expect(h.outboxFiles().length, 2);
    await h.tick(2000);
    await h.tick(2000);
    expect(h.transport.batchRequests.length, 3);
    expect(h.outboxFiles(), isEmpty);
    final a = env(h.transport.batchRequests[1]);
    final b = env(h.transport.batchRequests[2]);
    final halves = [a, b]..sort((x, y) => int_(x['oseq_from']).compareTo(int_(y['oseq_from'])));
    expect(int_(halves[0]['oseq_from']), 1);
    expect(int_(halves[0]['oseq_to']), 3);
    expect(int_(halves[1]['oseq_from']), 4);
    expect(int_(halves[1]['oseq_to']), 6);
    // 半批用区间两端命名（ADR 0019 决定 11）：与原批（…:primary:1）必不同名；install 取原批信封
    final iid = original['install_id'] as String;
    final sid = original['session_id'] as String;
    expect(halves[0]['batch_id'], Ids.splitBatchId(iid, sid, 1, 3));
    expect(halves[1]['batch_id'], Ids.splitBatchId(iid, sid, 4, 6));
    expect(halves[0]['batch_id'], isNot(original['batch_id']));
    expect(halves[0]['created_ms'], original['created_ms']);
    // ctx 跟着含 error 的那一半；p0 先发
    expect(int_(a['oseq_from']), 4);
    expect(halves[1].lines.any((l) => l['ctx'] == true), isTrue);
    expect(halves[0].lines.any((l) => l['ctx'] == true), isFalse);
    assertAllValid(await runValidator([a, b]));
  });

  /// 413 切分的后一半写不出（目标路径被占）：本次已写的前一半删掉、原批原样保留，墓碑 0 条、区间一个不少；
  /// 恢复写入后下一轮收敛为两半、原批删除（ADR 0019 决定 11）。
  test('tooLargeSplitNeverLosesRange', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    for (var i = 1; i <= 6; i++) {
      h.l(LogLevel.warn, 'w$i');
    }
    await h.seal();
    final original = h.outboxFiles().single;
    final env0 = h.envelopes().single;
    final iid = env0['install_id'] as String;
    final sid = env0['session_id'] as String;
    final created = int_(env0['created_ms']);
    final blocker = Directory('${h.outbox}/p1-$created-${Ids.splitBatchId(iid, sid, 4, 6)}.gz')..createSync();
    File('${blocker.path}/occupied').writeAsStringSync('x');
    h.transport.setScript([
      Reply.status(413, {'reason': 'too_large'}),
      Reply.status(413, {'reason': 'too_large'}),
    ]);
    await h.enableUpload();
    expect(h.transport.batchRequests.length, 1);
    expect(File('${h.outbox}/$original').existsSync(), isTrue, reason: '原批仍在');
    expect(
      File('${h.outbox}/p1-$created-${Ids.splitBatchId(iid, sid, 1, 3)}.gz').existsSync(),
      isFalse,
      reason: '本次写出的前一半已回滚',
    );
    final covered = <int>{};
    for (final n in h.outboxFiles()) {
      final f = File('${h.outbox}/$n');
      if (!f.existsSync()) continue;
      final e = Env.ofGzip(n, f.readAsBytesSync());
      if (e == null) continue;
      for (var o = int_(e['oseq_from']); o <= int_(e['oseq_to']); o++) {
        covered.add(o);
      }
    }
    expect(covered.containsAll([1, 2, 3, 4, 5, 6]), isTrue, reason: '$covered');
    expect(h.readJsonl('drops.jsonl').length, 0);
    expect((await h.backoff).reason, 'http_413', reason: '切分失败按普通失败退避');
    // 恢复写入：原批再 413 → 两半都写成 → 原批删除 → 两半依次上传
    blocker.deleteSync(recursive: true);
    await h.tick(2000);
    expect(h.transport.batchRequests.length, 2);
    expect(File('${h.outbox}/$original').existsSync(), isFalse);
    await h.tick(2000);
    await h.tick(2000);
    expect(h.transport.batchRequests.length, 4);
    expect(h.outboxFiles(), isEmpty);
    final sent = h.transport.batchRequests.skip(2).map(env).toList()
      ..sort((x, y) => int_(x['oseq_from']).compareTo(int_(y['oseq_from'])));
    expect(sent.map((e) => (int_(e['oseq_from']), int_(e['oseq_to']))).toList(), [(1, 3), (4, 6)]);
    expect(sent.map((e) => e['batch_id']).toList(), [
      Ids.splitBatchId(iid, sid, 1, 3),
      Ids.splitBatchId(iid, sid, 4, 6),
    ]);
  });

  /// 请求头 `X-Rtv-Install` 取批自身信封里的 install_id（ADR 0019 决定 10），不取当前 install。
  test('batchHeaderUsesEnvelopeInstall', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    h.l(LogLevel.warn, 'from another install');
    await h.seal();
    final name = h.outboxFiles().single;
    final env0 = h.envelopes().single;
    // 把这一批改写成别的 install 的批（多进程清空窗口里别的进程写进来的那种）
    final other = Ids.newV4();
    final json = utf8.decode(env0.raw).replaceAll(env0['install_id'] as String, other);
    File('${h.outbox}/$name').writeAsBytesSync(Gzip.compress(utf8.encode(json))!);
    await h.work((e) => e.metas.clear());
    await h.enableUpload();
    expect(h.transport.batchRequests.length, 1);
    final r = h.transport.batchRequests[0];
    expect(env(r)['install_id'], other);
    expect(r.headers['X-Rtv-Install'], other, reason: '请求头 == 信封');
    expect(r.headers['X-Rtv-Install'], isNot(h.client.installId));
  });

  /// 被服务端隔离（status = quarantined）的带映射批：确认删批，但不把映射记成已确认，下一批重发映射（ADR 0019 决定 10）。
  test('quarantinedAckDoesNotConfirmMapping', () async {
    final h = await Harness.create();
    await h.settle();
    h.transport.responder = (bid) =>
        Reply.status(200, {'batch_id': bid, 'status': 'quarantined', 'config_etag': 'etag-0'});
    h.l(LogLevel.warn, 'w1');
    await h.sealAndDrain();
    expect(h.transport.batchRequests.length, 1);
    expect(env(h.transport.batchRequests[0]).map.containsKey('mapping'), isTrue, reason: '批里带了映射');
    expect(h.outboxFiles(), isEmpty, reason: '隔离也算确认：删批');
    expect(File('${h.root}/mapping.json').existsSync(), isFalse, reason: '映射没记成已确认');
    h.transport.responder = null;
    h.clock.advance(Limits.minRequestSpacingMs);
    h.l(LogLevel.warn, 'w2');
    await h.sealAndDrain();
    expect(h.transport.batchRequests.length, 2);
    expect(env(h.transport.batchRequests[1]).map.containsKey('mapping'), isTrue, reason: '下一批重发映射');
    expect(File('${h.root}/mapping.json').existsSync(), isTrue);
  });

  test('rateLimitedInfoBackfillPausesOnlyThoseCategories', () async {
    final h = await Harness.create(options: const RetrieverOptions(uploadLevel: LogLevel.info));
    await h.settle();
    h.transport.setScript([
      Reply.status(
        429,
        {
          'reason': 'quota',
          'categories': ['info', 'backfill'],
          'retry_after_s': 60,
        },
        {'retry-after': '60'},
      ),
    ]);
    h.l(LogLevel.info, 'pure info');
    await h.sealAndDrain();
    expect(h.transport.batchRequests.length, 1);
    // backfill 批（debug 行在 info 模式下不是义务行）
    h.l(LogLevel.debug, 'debug 1');
    h.l(LogLevel.debug, 'debug 2');
    await h.seal();
    await h.work((e) => e.materializeBackfill());
    expect(h.outboxFiles('p2').length, 1);
    // p0 照发
    h.l(LogLevel.error, 'boom');
    await h.sealAndDrain();
    await h.tick(2000);
    expect(h.transport.batchRequests.length, 2);
    expect(env(h.transport.batchRequests[1]).lines.any((l) => l['level'] == 'error'), isTrue);
    await h.tick(2000);
    expect(h.transport.batchRequests.length, 2, reason: 'info / backfill 仍暂停');
    expect(h.outboxFiles('p1').length, 1);
    expect(h.outboxFiles('p2').length, 1);
    final b = await h.backoff;
    expect(b.pausedCategories.toSet(), {'info', 'backfill'});
    expect(b.attempt, 0, reason: '429 不计退避与毒批');
    await h.tick(73000);
    await h.tick(2000);
    expect(h.transport.batchRequests.length, 4);
    expect(h.outboxFiles(), isEmpty);
  });

  test('rateLimitedAllPausesEverything', () async {
    final h = await Harness.create();
    await h.settle();
    h.transport.setScript([
      Reply.status(
        429,
        {
          'reason': 'rate',
          'categories': ['all'],
          'retry_after_s': 30,
        },
        {'retry-after': '30'},
      ),
    ]);
    h.l(LogLevel.error, 'e');
    await h.sealAndDrain();
    final b = await h.backoff;
    expect(b.pausedCategories, ['all']);
    final wait = b.pausedUntilMono - h.nowMono;
    expect(wait, inInclusiveRange(24000, 36000));
    await h.tick(23000);
    expect(h.transport.batchRequests.length, 1);
    await h.tick(14000);
    expect(h.transport.batchRequests.length, 2);
    expect(h.outboxFiles(), isEmpty);
  });

  test('serviceUnavailableBackoffCurve', () async {
    final h = await Harness.create();
    await h.settle();
    h.transport.defaultReply = Reply.status(503, {'reason': 'storage'});
    h.l(LogLevel.warn, 'w');
    await h.sealAndDrain();
    final curve = <int>[];
    for (var i = 0; i < 14; i++) {
      final b = await h.backoff;
      final base = (1000 << i) < Limits.backoffMaxMs ? (1000 << i) : Limits.backoffMaxMs;
      final wait = b.nextAtMonoMs - h.nowMono;
      curve.add(wait);
      expect(wait >= base * 8 ~/ 10 && wait <= base * 12 ~/ 10, isTrue, reason: 'attempt $i: $wait');
      expect(b.attempt, i + 1);
      await h.tick(wait > 2000 ? wait : 2000);
      expect(h.transport.batchRequests.length, i + 2);
    }
    print('[backoff] 503 curve (ms): $curve');
    expect(h.outboxFiles('p1').length, 1, reason: '503 不隔离、不删');
    // Retry-After 大于退避时取 Retry-After（钳制 1 s–1 h）
    await h.work((e) => e.backoff.attempt = 0);
    h.transport.defaultReply = Reply.status(503, {'reason': 'storage', 'retry_after_s': 120}, {'retry-after': '120'});
    await h.tick(Limits.backoffMaxMs * 2);
    expect((await h.backoff).nextAtMonoMs - h.nowMono, 120000);
  });

  test('poisonBatchQuarantinedAfterFiveFailuresWhenOthersSucceed', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    h.l(LogLevel.warn, 'poison');
    await h.seal();
    h.clock.advance(10);
    h.l(LogLevel.warn, 'good');
    await h.seal();
    final names = h.outboxFiles();
    expect(names.length, 2);
    final poisonId = names[0].substring(3 + 13 + 1, names[0].length - 3);
    h.transport.responder = (bid) => bid == poisonId ? Reply.status(500) : Reply.echo;
    await h.enableUpload();
    for (var i = 0; i < 30; i++) {
      if (h.outboxFiles('q-').isNotEmpty) break;
      await h.tick(Limits.backoffMaxMs + 1);
    }
    expect(h.transport.batchRequests.where((r) => FakeTransport.batchId(r.body) == poisonId).length, 5);
    expect(h.outboxFiles('q-').length, 1);
    expect(h.outboxFiles('q-')[0].contains(poisonId), isTrue);
    expect(h.outboxFiles('p').length, 0);
    // 隔离后不再发
    final before = h.transport.batchRequests.length;
    await h.tick(3600000);
    expect(h.transport.batchRequests.length, before);
  });

  test('allFailingIsServerOutageNotPoison', () async {
    final h = await Harness.create();
    await h.settle();
    h.transport.defaultReply = Reply.status(500);
    h.l(LogLevel.warn, 'w');
    await h.sealAndDrain();
    for (var i = 0; i < 8; i++) {
      await h.tick(Limits.backoffMaxMs + 1);
    }
    expect(h.transport.batchRequests.length, 9);
    expect(h.outboxFiles('p1').length, 1);
    expect(h.outboxFiles('q-').length, 0);
  });

  test('minimumSpacingTwoSeconds', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    h.l(LogLevel.warn, 'a');
    await h.seal();
    h.l(LogLevel.warn, 'b');
    await h.seal();
    await h.enableUpload();
    expect(h.transport.batchRequests.length, 1);
    await h.tick(1999);
    expect(h.transport.batchRequests.length, 1);
    await h.tick(1);
    expect(h.transport.batchRequests.length, 2);
    expect(h.outboxFiles(), isEmpty);
  });

  test('priorityOrder', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    h.l(LogLevel.warn, 'p1 older');
    await h.seal();
    h.l(LogLevel.debug, 'for backfill');
    await h.seal();
    await h.work((e) => e.materializeBackfill());
    h.clock.advance(5);
    h.l(LogLevel.error, 'p0');
    await h.seal();
    h.clock.advance(5);
    h.l(LogLevel.warn, 'p1 newer');
    await h.seal();
    expect(h.outboxFiles().map((n) => n.substring(0, 2)).toList()..sort(), ['p0', 'p1', 'p1', 'p2']);
    await h.enableUpload();
    for (var i = 0; i < 4; i++) {
      await h.tick(2000);
    }
    final order = h.transport.batchRequests.map((r) {
      final e = env(r);
      if (e['kind'] == 'backfill') return 'p2';
      for (final l in e.lines) {
        if (!l.containsKey('ctx')) return l['msg'] as String? ?? '?';
      }
      return '?';
    }).toList();
    expect(order, ['p0', 'p1 older', 'p1 newer', 'p2']);
  });

  test('offlineNetworkErrorBacksOffWithoutSpinning', () async {
    final h = await Harness.create();
    await h.settle();
    h.transport.defaultReply = Reply.network;
    h.l(LogLevel.warn, 'w');
    await h.sealAndDrain();
    expect(h.transport.batchRequests.length, 1);
    // 退避期内反复 tick 不发请求
    for (var i = 0; i < 5; i++) {
      await h.tick(100);
    }
    expect(h.transport.batchRequests.length, 1);
    // 网络恢复信号：提前唤醒
    h.transport.defaultReply = Reply.echo;
    h.platform.handler!.networkRestored();
    await h.settle();
    await h.tick(2000);
    expect(h.outboxFiles(), isEmpty);
  });

  test('backoffPersistsAcrossRestartWithClamp', () async {
    final h = await Harness.create();
    await h.settle();
    await h.work((e) async {
      e.backoff.attempt = 12;
      e.backoff.nextAtWallMs = e.clock.wallMs() + 3600000; // 时钟回拨等造成的远期
      await e.persistBackoff();
    });
    final h2 = await Harness.create(root: h.root, clock: h.clock);
    await h2.settle();
    final b = await h2.backoff;
    expect(b.attempt, 12);
    expect(b.nextAtMonoMs - h2.nowMono, Limits.backoffMaxMs);
  });

  test('quarantinedBatchReturnsAfter24h', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    h.l(LogLevel.warn, 'q');
    await h.seal();
    await h.work((e) => e.quarantine(e.metas.values.first.name));
    expect(h.outboxFiles('q-').length, 1);
    // mtime 按假时钟写入：24 h 后回到队列并被上传
    await h.enableUpload();
    expect(h.transport.batchRequests.length, 0);
    await h.tick(ClientConstants.quarantineRetryMs + 1);
    await h.tick(2000);
    expect(h.transport.batchRequests.length, 1);
    expect(h.outboxFiles(), isEmpty);
  });
}
