// 对位 Android HardeningTests.kt：宿主误用加固（ADR 0024 决定 3 / 4 / 7–11；简报 §11 N / P / Q / R / S / T）。
// t_jobOwnership 的 JobGate 部分与 t_lifecycleTracker 在切片 2 的 Java 垫片（JUnit）里测；这里只留实例侧的「排不上只记一次」。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:revdog_retriever/src/fs.dart';
import 'package:revdog_retriever/src/ids.dart';
import 'package:revdog_retriever/src/materializer.dart';
import 'package:revdog_retriever/src/model.dart';
import 'package:revdog_retriever/src/outbox.dart';
import 'package:test/test.dart';

import 'support/support.dart';

Map<String, Object?> cursor(Harness h) => h.readJson('${h.sessionDir()}/cursor.json');

void main() {
  setUpRtv(expectInternalErrors: false);

  /// 段读失败（非 ENOENT）不推进游标、不记墓碑，定时重试；段文件确已不存在 → 记墓碑后推进。
  test('n_readFailureVsMissingSegment', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    h.l(LogLevel.warn, 'a');
    h.l(LogLevel.warn, 'b');
    final seg = h.client.debugOpenSegmentFile!;
    final content = File(seg).readAsBytesSync();
    h.client.writer.debugBreakStream();
    File(seg).deleteSync();
    Directory(seg).createSync();
    h.client.writer.rotate(SealReason.timer);
    await h.client.onWork(h.engine.processSeals);
    expect(int_(cursor(h)['extracted_through_oseq']), 0, reason: '读失败不推进');
    expect(h.outboxFiles(), isEmpty);
    expect(h.readJsonl('drops.jsonl'), isEmpty);
    final sealed = '${h.sessionDir()}/seg-000001.sealed';
    expect(FileSystemEntity.isDirectorySync(sealed), isTrue);
    Directory(sealed).deleteSync();
    File(sealed).writeAsBytesSync(content);
    await h.tick(60000);
    expect(h.envelopes().single.lines.map((l) => l['msg']).toList(), ['a', 'b']);
    expect(int_(cursor(h)['extracted_through_oseq']), 2);

    // 段文件被删：墓碑后推进
    h.l(LogLevel.warn, 'c');
    final seg2 = h.client.debugOpenSegmentFile!;
    h.client.writer.debugBreakStream();
    File(seg2).deleteSync();
    h.client.writer.rotate(SealReason.timer);
    await h.client.onWork(h.engine.processSeals);
    await h.settle();
    final d = h.readJsonl('drops.jsonl').single;
    expect(d['reason'], 'corrupt');
    expect(int_(d['oseq_from']), 3);
    expect(int_(d['oseq_to']), 3);
    expect(int_(cursor(h)['extracted_through_oseq']), 3);
  });

  /// root 被删：换段时发现 → 引擎队列上重新 bootstrap，新会话写 `rtv.root_vanished`；期间的行计数并上报。
  test('n_rootVanishedRebootstraps', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    h.l(LogLevel.warn, 'before');
    final oldSid = h.client.writer.currentSessionId;
    final gate = await h.blockEngine();
    Directory(h.root).deleteSync(recursive: true);
    h.client.writer.rotate(SealReason.timer);
    h.l(LogLevel.error, 'lost while vanished');
    gate.complete();
    await h.settle();
    final sid = h.client.writer.currentSessionId;
    expect(sid, isNot(oldSid));
    final ls = sessionLines(h.sessionDir());
    expect(ls.map((l) => l['tag']).toList(), ['rtv.root_vanished', 'rtv.pre_init_dropped']);
    expect(ls[0]['msg'], 'session directory vanished; new session started');
    // 旧会话 .open 段里的 1 行（写进了被删的 inode，按段计）+ 目录消失期间的 1 行
    expect(int_(obj(ls[1]['attrs'])['count']), 2);
    expect(int_(obj(ls[1]['attrs'])['error_count']), 1);
    h.l(LogLevel.warn, 'after');
    expect(sessionLines(h.sessionDir()).last['msg'], 'after');
  });

  /// 目录锁拿不到（upload.lock 打不开）：不执行临界区。
  test('n_dirLockUnavailableSkipsCriticalSection', () async {
    final root = tempDir();
    Directory('$root/upload.lock').createSync();
    var ran = false;
    final r = await RootLocks(root).withDirLock(() async {
      ran = true;
      return true;
    });
    expect(r, isNull);
    expect(ran, isFalse);
  });

  /// 换 key：鉴权暂停清除、立即可传；映射重发。
  test('p_keyChangeClearsPauseAndResendsMapping', () async {
    final h = await Harness.create(key: 'lk_test_a_old_00000001');
    await h.settle();
    h.l(LogLevel.warn, 'w1');
    await h.sealAndDrain();
    expect(FakeTransport.envOf(h.transport.batchRequests.last.body)!['mapping'], isNotNull, reason: '首批带映射');
    h.transport.setScript([
      Reply.status(401, {'reason': 'key_revoked'}),
    ]);
    h.clock.advance(2000);
    h.l(LogLevel.warn, 'w2');
    await h.sealAndDrain();
    expect((await h.backoff).pausedCategories, ['all']);
    await Retriever.configure('lk_test_b_new_00000002', baseUrl: base);
    await h.settle();
    expect((await h.backoff).pausedCategories, isEmpty, reason: '换 key 清暂停');
    await h.tick(2000);
    expect(h.outboxFiles(), isEmpty);
    expect(h.transport.batchRequests.last.headers['Authorization'], 'Bearer lk_test_b_new_00000002');
    h.l(LogLevel.warn, 'w3');
    h.clock.advance(2000);
    await h.sealAndDrain();
    expect(FakeTransport.envOf(h.transport.batchRequests.last.body)!['mapping'], isNotNull, reason: '映射对新 key 重发');
    expect(h.readJson('${h.root}/backoff.json')['key_fp'], Ids.keyFingerprint('lk_test_b_new_00000002'));
  });

  /// 旧 key 在途请求的 401 不暂停新 key。
  test('p_inflight401ForOldKeyDoesNotPause', () async {
    final h = await Harness.create(key: 'lk_test_a_old_00000001');
    await h.settle();
    final gate = Completer<void>();
    h.transport.setScript([
      Reply.gated(gate, Reply.status(401, {'reason': 'key_revoked'})),
    ]);
    h.l(LogLevel.warn, 'w');
    h.client.writer.rotate(SealReason.timer);
    h.client.onWork(h.client.afterSeal).ignore();
    await waitUntil(() => h.transport.batchRequests.isNotEmpty);
    await Retriever.configure('lk_test_b_new_00000002', baseUrl: base);
    await h.client.onWork(() {});
    gate.complete();
    await h.settle();
    expect((await h.backoff).pausedCategories, isEmpty);
    await h.tick(2000);
    expect(h.outboxFiles(), isEmpty);
    expect(h.transport.batchRequests.last.headers['Authorization'], 'Bearer lk_test_b_new_00000002');
  });

  /// fatal 连打 100 条：1 次立即换段，其余并入 error 去抖；10 s 窗口过后再立即换段。
  /// Flutter：fatal 不在调用处排后台作业（v3 §1 §8；Android 的「1 次排作业」断言改成「0 次」）。
  test('q_fatalBurstThrottled', () async {
    final h = await Harness.create();
    await h.settle();
    h.transport.defaultReply = Reply.network;
    for (var i = 0; i < 100; i++) {
      h.l(LogLevel.fatal, 'f$i');
    }
    await h.settle();
    expect(h.outboxFiles('p0').length, 1);
    expect(h.platform.scheduledJobs, isEmpty);
    expect(h.client.writer.snapshot.segNo, 2);
    await h.tick(10000);
    expect(h.outboxFiles('p0').length, 2, reason: '其余 99 条随 error 去抖封段');
    expect(h.envelopes('p0').fold<int>(0, (a, e) => a + e.lines.where((l) => l['ctx'] != true).length), 100);
    h.l(LogLevel.fatal, 'next window');
    await h.settle();
    expect(h.outboxFiles('p0').length, 3);
    expect(h.platform.scheduledJobs, isEmpty);
  });

  /// flush 连调 100 次（第一次还在等）：1 条标记行，100 个 Future 都完成。
  test('q_flushBurstCoalesced', () async {
    final h = await Harness.create();
    await h.settle();
    h.transport.defaultReply = Reply.hang;
    h.client.setFlushWindowForTesting(500);
    h.l(LogLevel.info, 'before');
    final all = [for (var i = 0; i < 100; i++) Retriever.flush()];
    final results = await Future.wait(all).timeout(const Duration(seconds: 30));
    expect(results.length, 100);
    h.transport.defaultReply = Reply.network;
    h.transport.cancelAll();
    await h.settle();
    var markers = 0;
    for (final n in Fs.listSync(h.sessionDir())!.where((n) => n.startsWith('seg-'))) {
      markers += File(
        '${h.sessionDir()}/$n',
      ).readAsStringSync().split('\n').where((l) => l.contains('"tag":"rtv.flush"')).length;
    }
    expect(markers, 1);
  });

  /// attrs 键名 ctx / level / synthetic / tag 的值「像」标记：物化优先级、413 切分、恢复判重都不受影响（按位置解析）。
  test('r_attrsDoNotSpoofParsedFields', () async {
    final spoof = <String, Object?>{
      'a': 1,
      'ctx': true,
      'level': 'error',
      'synthetic': true,
      'tag': 'rtv.unclean_exit',
    };
    // 批的级别 / ctx：按行首前缀与行尾位置
    final raw = [
      Uint8List.fromList(
        '{"seq":1,"oseq":1,"ts":1,"level":"debug","msg":"m","attrs":{"a":1,"ctx":true,"level":"error"}}'.codeUnits,
      ),
    ];
    final h0 = EnvelopeHeader(
      BatchKind.primary,
      Ids.newV4(),
      1,
      '2026-10-01',
      Ids.newV4(),
      Ids.newV4(),
      1,
      'main',
      null,
      const Device('a', 'b', 'c', 'd', 'e', 'f', 'g'),
      1,
      1,
      1,
      1,
      null,
    );
    final m = batchMeta('p1-1-${h0.batchId}.gz', h0, raw, 10);
    expect(m.hasError, isFalse, reason: 'attrs 的 level 不算');
    expect(m.hasWarnOrAbove, isFalse);
    expect(m.category, 'info');

    // 413 切分：两条义务行（attrs 里有 ,"ctx":true）照常二分
    final h = await Harness.create();
    await h.settle();
    h.transport.defaultReply = Reply.network;
    h.l(LogLevel.warn, 'w1', attrs: spoof);
    h.l(LogLevel.warn, 'w2', attrs: spoof);
    await h.seal();
    final name = h.outboxFiles().single;
    expect(await h.work((e) => e.split413(name)), isTrue);
    final halves = h.envelopes()..sort((a, b) => int_(a['oseq_from']).compareTo(int_(b['oseq_from'])));
    expect(halves.map((e) => (int_(e['oseq_from']), int_(e['oseq_to']))).toList(), [(1, 1), (2, 2)]);
    expect(halves.map((e) => e.lines.single['msg']).toList(), ['w1', 'w2']);

    // 恢复判重：最后一行 attrs 里有 "tag":"rtv.unclean_exit" 不算已合成
    final k = await Harness.create(key: '');
    await k.settle();
    k.l(LogLevel.warn, 'last', attrs: spoof);
    final sid = k.client.writer.currentSessionId;
    await k.simulateCrash();
    final k2 = await Harness.create(root: k.root, key: '', clock: k.clock);
    await k2.settle();
    final ls = sessionLines('${k.root}/proc-main/$sid');
    expect(ls.map((l) => l['msg']).toList(), ['last', 'process ended while foregrounded']);
  });

  /// redact 改 ts（负数、超大）：行照常、ts 为原值（configure 之后与收编两条路径）。
  test('s_redactCannotChangeTs', () async {
    final h = await Harness.create(
      key: '',
      options: RetrieverOptions(redact: (l) => l.copyWith(ts: l.msg.contains('neg') ? -5 : 9223372036854775807)),
    );
    h.l(LogLevel.warn, 'neg');
    h.l(LogLevel.warn, 'huge');
    final ls = sessionLines(h.sessionDir());
    expect(ls.map((l) => int_(l['ts'])).toList(), [h.clock.wallMs(), h.clock.wallMs()]);

    final s = await StaticHarness.create();
    final t0 = s.clock.wallMs();
    s.log(LogLevel.warn, 'neg pre');
    await s.configure('', RetrieverOptions(redact: (l) => l.copyWith(ts: -1)));
    await s.settle();
    expect(int_(sessionLines(s.currentSessionDir()).single['ts']), t0);
  });

  /// setUser("") / 纯空白 / 纯控制字符 = null（configure 之前与之后）。
  test('s_blankUserIsNil', () async {
    final s = await StaticHarness.create();
    Retriever.setUser('  \t ');
    Retriever.setUser('u');
    Retriever.setUser('\u0000\u0001');
    s.log(LogLevel.warn, 'x');
    await s.configure('');
    await s.settle();
    expect(s.client.writer.currentUser, isNull);
    Retriever.setUser('u2');
    Retriever.setUser('');
    expect(s.client.writer.currentUser, isNull);
  });

  /// SDK 自己取消的请求（作业被系统停）不计入毒批失败次数，也不动退避。
  test('s_sdkCancelledRequestNotCountedAsFailure', () async {
    final h = await Harness.create();
    await h.settle();
    h.transport.defaultReply = Reply.hang;
    h.l(LogLevel.warn, 'w');
    await h.seal();
    final name = h.outboxFiles().single;
    final job = h.platform.handler!.drainOutbox(60000);
    await waitUntil(() => h.transport.hangingCount == 1);
    h.platform.handler!.stopUploadJob();
    await job.timeout(const Duration(seconds: 10));
    await h.settle();
    expect(await h.work((e) => e.fails[name]), isNull);
    expect((await h.backoff).attempt, 0, reason: '也不动退避（B8）');
    expect((await h.backoff).nextAtMonoMs, 0);
    expect(h.outboxFiles(), [name]);
  });

  /// 同 id 的后台作业被别人占着（垫片 `scheduleUploadJob` 回 false）：不替换，只记一次诊断（ADR 0024 决定 11）。
  /// （JobGate 的归属判定在 Android 垫片的 JUnit 里测。）
  test('t_jobConflictReportedOnce', () async {
    final h = await Harness.create();
    await h.settle();
    h.platform.scheduleResult = false;
    h.transport.defaultReply = Reply.network;
    h.l(LogLevel.warn, 'w1');
    h.platform.handler!.didEnterBackground(null);
    await h.settle();
    h.platform.handler!.willEnterForeground();
    h.clock.advance(20000);
    h.l(LogLevel.warn, 'w2');
    h.platform.handler!.didEnterBackground(null);
    await h.settle();
    expect(h.platform.scheduledJobs.length, 2);
    expect(h.errors.where((e) => e.toString().contains('not scheduled')).length, 1);
    h.errors.clear();
  });
}
