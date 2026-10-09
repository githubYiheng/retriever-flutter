// 对位 Android PrereleaseRegressionTests.kt：发版前审查（A1–A5）的回归测试。Android 独有的异常 cause 链 / 环检测
// （stackTextKeepsUnknownHostAndTerminatesOnCycles）不对位：Dart 的错误没有 cause 链；改测 Dart 错误的栈进 exc。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:revdog_retriever/src/client.dart';
import 'package:revdog_retriever/src/ids.dart';
import 'package:revdog_retriever/src/json.dart';
import 'package:revdog_retriever/src/limits.dart';
import 'package:revdog_retriever/src/model.dart';
import 'package:revdog_retriever/src/outbox.dart';
import 'package:revdog_retriever/src/uploader.dart';
import 'package:test/test.dart';

import 'support/support.dart';

List<Map<String, Object?>> segLines(String path) =>
    readSegmentLines(path).skip(1).map((l) => JsonIn.objText(l)!).toList();

bool isRootUser() => (Process.runSync('id', ['-u']).stdout as String).trim() == '0';

/// 会话义务行已物化并确认 → RETAINED 段被驱逐 → 前台崩溃；openLines = OPEN 段里的非义务行数。
Future<(Harness, String, (int, int))> crashAfterEviction(int openLines) async {
  final h = await Harness.create();
  await h.settle();
  for (var i = 1; i <= 3; i++) {
    h.l(LogLevel.warn, 'w$i');
  }
  h.l(LogLevel.debug, 'd');
  await h.sealAndDrain();
  expect(h.transport.batchRequests.length, 1);
  expect(h.outboxFiles(), isEmpty);
  final sid = h.client.writer.currentSessionId;
  final cursorFile = '${h.sessionDir()}/cursor.json';
  final extracted = int_(h.readJson(cursorFile)['extracted_through_oseq']);
  expect(extracted, 3);
  final evictedLastSeq = await h.work((e) => e.current!.sealed.single.lastSeq);
  h.platform.available = 10 * 1024 * 1024;
  await h.work((e) => e.evictIfNeeded());
  expect(Directory(h.sessionDir()).listSync().where((e) => e.path.endsWith('.sealed')), isEmpty);
  expect(int_(h.readJson(cursorFile)['ctx_through_seq']), evictedLastSeq, reason: '被驱逐段的 lastSeq 并入 ctx 游标');
  for (var i = 0; i < openLines; i++) {
    h.l(LogLevel.debug, 'after eviction $i');
  }
  expect(h.readJson(cursorFile)['last_state'], 'fg');
  await h.simulateCrash();
  return (h, sid, (extracted, evictedLastSeq));
}

void main() {
  setUpRtv();

  // ---------------------------------------------------------------- A1 选批不递归

  test('a1_installMissingStopsNotBootstrappedAndKeepsBatch', () async {
    final h = await Harness.create();
    await h.settle();
    h.transport.defaultReply = Reply.network;
    h.l(LogLevel.warn, 'w');
    await h.sealAndDrain();
    expect(h.outboxFiles().length, 1);
    final sent = h.transport.batchRequests.length;
    // bootstrap 失败的状态（install.json 写不进 / 读不了）
    await h.work((e) => e.install = null);
    h.transport.defaultReply = Reply.echo;
    await h.tick(60000);
    expect(h.client.lastStop, ('not_bootstrapped', null));
    expect(h.transport.batchRequests.length, sent, reason: '不碰出站箱');
    expect(h.outboxFiles().length, 1);
  });

  test('a1_unreadableBatchSkippedOthersStillSent', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    h.l(LogLevel.warn, 'older, unreadable');
    await h.seal();
    h.clock.advance(10);
    h.l(LogLevel.warn, 'newer, readable');
    await h.seal();
    final names = h.outboxFiles();
    expect(names.length, 2);
    // 造「读不出」：同名换成目录（排在前面，先被选中）
    final bad = '${h.outbox}/${names[0]}';
    File(bad).deleteSync();
    Directory(bad).createSync();
    await h.work((e) => e.metas.clear());
    await h.enableUpload();
    expect(h.transport.batchRequests.length, 1);
    expect(FakeTransport.envOf(h.transport.batchRequests[0].body)!.lines.map((l) => l['msg']).toList(), [
      'newer, readable',
    ]);
    expect(h.outboxFiles(), [names[0]], reason: '读不出的不删');
    expect(Directory(bad).existsSync(), isTrue);
    expect(await h.work((e) => e.fails[names[0]]), isNull, reason: '不计 fail');
    // 全部读不出：停在 unreadable，不发请求
    await h.tick(2000);
    expect(h.client.lastStop, ('unreadable', null));
    expect(h.transport.batchRequests.length, 1);
    expect(Directory(bad).existsSync(), isTrue);
  });

  /// 「无副本」前提（ADR 0019 决定 8）：会话 meta.json 都没了时 install.json 损坏 → 清空 root 新建 install，留 `rtv.install_reset`。
  test('a1_corruptInstallJsonRebuiltWithSyntheticLine', () async {
    for (final bad in [utf8.encode('{"install_id":"not-a-uuid'), <int>[]]) {
      final h = await Harness.create(key: '');
      await h.settle();
      final old = h.client.installId!;
      final oldSid = h.client.writer.currentSessionId;
      await h.simulateCrash();
      for (final d in Directory('${h.root}/proc-main').listSync()) {
        final m = File('${d.path}/meta.json');
        if (m.existsSync()) m.deleteSync();
      }
      File('${h.root}/install.json').writeAsBytesSync(bad);
      final h2 = await Harness.create(root: h.root, key: '', clock: h.clock);
      await h2.settle();
      final iid = h2.client.installId;
      expect(iid, isNotNull, reason: 'bootstrap 成功');
      expect(Ids.isUuid(iid!), isTrue);
      expect(iid, isNot(old));
      final inst = h2.readJson('${h2.root}/install.json');
      expect(inst['install_id'], iid);
      expect(int_(inst['session_counter']), 1, reason: '计数器从 0 起再 +1');
      expect(h2.client.supportCode!.endsWith('-1'), isTrue);
      expect(Directory('${h2.root}/proc-main/$oldSid').existsSync(), isFalse, reason: '旧会话随 root 清掉');
      final reset = segLines(h2.client.debugOpenSegmentFile!).singleWhere((l) => l['tag'] == 'rtv.install_reset');
      expect(reset['level'], 'warn');
      expect(reset['msg'], 'install.json unreadable; local state discarded');
      expect(reset['attrs'], {'batches': 0.0, 'sessions': 1.0});
      expect(reset['synthetic'], true);
      expect(int_(reset['oseq']), 1, reason: '默认上传级别下是义务行');
      // 随新 install_id 的批上报
      await h2.seal();
      final env = h2.envelopes().singleWhere((e) => e['session_id'] == h2.client.writer.currentSessionId);
      expect(env['install_id'], iid);
      expect(env.lines.any((l) => l['tag'] == 'rtv.install_reset'), isTrue);
    }
  });

  test('a1_installJsonReadFailureDoesNotRebuild', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    await h.simulateCrash();
    final f = File('${h.root}/install.json');
    f.deleteSync();
    Directory(f.path).createSync(); // 同名目录：存在但读失败
    final h2 = await Harness.create(root: h.root, key: '', clock: h.clock);
    await h2.settle();
    expect(h2.client.installId, isNull, reason: '本次 bootstrap 失败、稍后重试');
    expect(Directory(f.path).existsSync(), isTrue, reason: '没被重建');
  });

  test('a1_installJsonPermissionDeniedDoesNotRebuild', () async {
    if (isRootUser()) {
      markTestSkipped('root 用户读得到');
      return;
    }
    final h = await Harness.create(key: '');
    await h.settle();
    await h.simulateCrash();
    final f = File('${h.root}/install.json');
    final saved = f.readAsBytesSync();
    Process.runSync('chmod', ['000', f.path]);
    try {
      final h2 = await Harness.create(root: h.root, key: '', clock: h.clock);
      await h2.settle();
      expect(h2.client.installId, isNull);
    } finally {
      Process.runSync('chmod', ['644', f.path]);
    }
    expect(f.readAsBytesSync(), saved, reason: '原文件未被替换');
  });

  // ---------------------------------------------------------------- A2 拉配置在途不自旋

  test('a2_configRequestMarksAttemptImmediately', () async {
    final h = await Harness.create();
    await h.settle();
    h.clock.advance(Limits.configPollIntervalS * 1000);
    expect(await h.work((e) => e.configPollDue(e.clock.monoMs())), isTrue);
    final dueAfter = await h.work((e) async {
      expect(await e.configRequest(), isNotNull);
      return e.configPollDue(e.clock.monoMs());
    });
    expect(dueAfter, isFalse, reason: '构造请求即记为上次尝试时刻');
  });

  test('a2_schedulerFloorWhileConfigFetchInFlight', () async {
    const now = 5000000;
    expect(RetrieverClient.schedulerDelayMs(now - 60000, now), 1000);
    expect(RetrieverClient.schedulerDelayMs(now, now), 1000);
    expect(RetrieverClient.schedulerDelayMs(now + 300, now), 1000);
    expect(RetrieverClient.schedulerDelayMs(now + 5000, now), 5000);

    final t = FakeTransport();
    final h = await Harness.create(transport: t);
    await h.settle();
    final n0 = t.configRequests.length;
    h.clock.advance(Limits.configPollIntervalS * 1000);
    final gate = Completer<void>();
    t.configGate = gate;
    try {
      h.clock.timerDelays.clear();
      // 离开 ≥ 30 min 回前台：到期拉配置，请求挂着不回
      h.platform.handler!.willEnterForeground();
      await waitUntil(() => t.configRequests.length > n0);
      expect(t.configRequests.length, n0 + 1);
      await h.client.onWork(h.client.reschedule);
      expect(await h.work((e) => e.configPollDue(e.clock.monoMs())), isFalse);
      final delays = List.of(h.clock.timerDelays);
      expect(delays, isNotEmpty);
      expect(delays.every((d) => d >= 1000), isTrue, reason: '$delays');
      expect(delays.last, greaterThanOrEqualTo(Limits.configPollIntervalS * 1000 - 1000), reason: '在途时轮询候选是 30 min 之后');
    } finally {
      gate.complete();
    }
    await h.settle();
  });

  // ---------------------------------------------------------------- A4 鉴权暂停只认带 reason 的 JSON

  test('a4_authStatusWithoutJsonReasonBacksOffLikeOthers', () async {
    final cases = <(Reply, String)>[
      (Reply.status(403), 'http_403'),
      (Reply.raw(401, utf8.encode('<html><body>Access denied | Cloudflare</body></html>')), 'http_401'),
      (Reply.status(403, {'error': 'forbidden'}), 'http_403'),
      (Reply.status(401, {'reason': 7}), 'http_401'),
    ];
    for (final (reply, reason) in cases) {
      final h = await Harness.create();
      await h.settle();
      h.transport.setScript([reply]);
      h.l(LogLevel.warn, 'w');
      await h.sealAndDrain();
      expect(h.transport.batchRequests.length, 1);
      final b = await h.backoff;
      expect(b.reason, reason);
      expect(b.pausedCategories, isEmpty, reason: '没有暂停类别');
      expect(b.pausedUntilMono, 0);
      expect(b.attempt, 1);
      final wait = b.nextAtMonoMs - h.nowMono;
      expect(wait, inInclusiveRange(800, 1200), reason: '$reason $wait');
      final name = h.outboxFiles().single;
      expect(await h.work((e) => e.fails[name]?.count), 1, reason: '计入该批 fail');
      // 退避到期即重试（不是 1 h）
      await h.tick(2000);
      expect(h.transport.batchRequests.length, 2);
      expect(h.outboxFiles(), isEmpty);
    }
  });

  test('a4_authPauseWithReasonDoublesAndResetsAfterAck', () async {
    final h = await Harness.create();
    await h.settle();
    final denied = Reply.status(401, {'reason': 'key_invalid'});
    h.transport.setScript([denied]);
    h.l(LogLevel.warn, 'w1');
    await h.sealAndDrain();
    var b = await h.backoff;
    expect(b.pausedCategories, ['all']);
    expect(b.pausedUntilMono - h.nowMono, 3600000);
    // 到期后再遇 → 2 h
    h.transport.setScript([denied]);
    await h.tick(3600000);
    expect(h.transport.batchRequests.length, 2);
    expect((await h.backoff).pausedUntilMono - h.nowMono, 7200000);
    // 到期后成功确认一次 → 倍增状态复位、已到期的暂停清掉
    await h.tick(7200000);
    expect(h.transport.batchRequests.length, 3);
    expect(h.outboxFiles(), isEmpty);
    b = await h.backoff;
    expect(b.reason, '');
    expect(b.pausedCategories, isEmpty);
    expect(b.pausedUntilMono, 0);
    expect(b.pausedUntilMs, 0);
    final persisted = h.readJson('${h.root}/backoff.json');
    expect(persisted['reason'], '');
    expect(int_(persisted['paused_until_ms']), 0);
    // 再遇带 reason 的 401 → 从 1 h 起步
    h.clock.advance(Limits.minRequestSpacingMs);
    h.transport.setScript([
      Reply.status(403, {'reason': 'app_disabled'}),
    ]);
    h.l(LogLevel.warn, 'w2');
    await h.sealAndDrain();
    expect(h.transport.batchRequests.length, 4);
    expect((await h.backoff).pausedUntilMono - h.nowMono, 3600000);
  });

  // ---------------------------------------------------------------- A5 恢复时 oseq / seq 高水位

  test('a5_uncleanExitAfterEvictionContinuesOseq', () async {
    final (h, sid, (extracted, evictedLastSeq)) = await crashAfterEviction(2);
    final h2 = await Harness.create(root: h.root, key: '', clock: h.clock);
    await h2.settle();
    final env = h2.envelopes().singleWhere((e) => e['session_id'] == sid);
    final synth = env.lines.singleWhere((l) => l['tag'] == 'rtv.unclean_exit');
    expect(int_(synth['oseq']), extracted + 1);
    expect(int_(env['oseq_from']), extracted + 1);
    expect(int_(env['oseq_to']), extracted + 1);
    expect(int_(synth['seq']), greaterThan(evictedLastSeq));
    expect(env.lines.where((l) => l['ctx'] == true).length, 2, reason: 'OPEN 段的非义务行作 ctx 随行');
    final closed = h2.readJsonl('sessions.jsonl').singleWhere((c) => c['session_id'] == sid);
    expect(closed['exit'], 'unclean_fg');
    expect(int_(closed['last_oseq']), extracted + 1);
    expect(int_(closed['last_seq']), int_(synth['seq']));
    assertAllValid(await runValidator([env]));
  });

  test('a5_seqHighWaterSurvivesEvictionWithEmptyOpenSegment', () async {
    final (h, sid, (extracted, evictedLastSeq)) = await crashAfterEviction(0);
    final h2 = await Harness.create(root: h.root, key: '', clock: h.clock);
    await h2.settle();
    final env = h2.envelopes().singleWhere((e) => e['session_id'] == sid);
    final synth = env.lines.singleWhere((l) => l['tag'] == 'rtv.unclean_exit');
    expect(int_(synth['oseq']), extracted + 1);
    expect(int_(synth['seq']), evictedLastSeq + 1, reason: '盘上已无行：seq 接着被驱逐段编');
    final closed = h2.readJsonl('sessions.jsonl').singleWhere((c) => c['session_id'] == sid);
    expect(int_(closed['last_oseq']), extracted + 1);
    expect(int_(closed['last_seq']), evictedLastSeq + 1);
  });

  /// 尾部义务行写失败且墓碑已落盘（盘上最大 oseq 低于墓碑）：合成行不复用被墓碑覆盖的 oseq，也不另记 corrupt。
  test('a5_tombstoneAboveDiskMaxRaisesHighWater', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    h.l(LogLevel.warn, 'on disk');
    final sid = h.client.writer.currentSessionId;
    await h.work((e) => e.appendDrops([DropEntry(sid, 2, 3, 2, 'write_failed', h.clock.wallMs(), -1)]));
    await h.simulateCrash();
    final h2 = await Harness.create(root: h.root, key: '', clock: h.clock);
    await h2.settle();
    final envs = h2.envelopes().where((e) => e['session_id'] == sid);
    final synth = envs.expand((e) => e.lines).singleWhere((l) => l['tag'] == 'rtv.unclean_exit');
    expect(int_(synth['oseq']), 4);
    expect(int_(h2.readJsonl('sessions.jsonl').singleWhere((c) => c['session_id'] == sid)['last_oseq']), 4);
    expect(
      h2.readJsonl('drops.jsonl').where((d) => d['session_id'] == sid).map((d) => d['reason']).toList(),
      ['write_failed'],
      reason: '墓碑已覆盖 2..3，不另记 corrupt',
    );
  });

  // ---------------------------------------------------------------- 异常栈（Dart：错误对象 + StackTrace）

  test('stackOfDartErrorReachesExc', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    try {
      throw const SocketException('Failed host lookup', osError: OSError('nodename nor servname provided', 8));
    } catch (e, st) {
      h.l(LogLevel.error, 'net', error: e, st: st);
    }
    // Error 子类不传栈：取 Error.stackTrace
    try {
      throw StateError('bad state');
    } catch (e) {
      h.l(LogLevel.error, 'state', error: e);
    }
    await h.seal(SealReason.error);
    final env = h.envelopes('p0').single;
    final net = obj(env.lines.singleWhere((l) => l['msg'] == 'net')['exc']);
    expect(net['type'], 'SocketException');
    expect((net['message'] as String).contains('Failed host lookup'), isTrue);
    expect((net['stack'] as String).startsWith('#0'), isTrue);
    final state = obj(env.lines.singleWhere((l) => l['msg'] == 'state')['exc']);
    expect(state['type'], 'StateError');
    expect((state['stack'] as String).isNotEmpty, isTrue);
  });
}
