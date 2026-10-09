// 对位 Android HostSafetyTests.kt：宿主安全（ADR 0020）——宿主调用永不等待 SDK 后台工作；setEnabled 落盘、禁用即零联网；
// 后台作业的停止标志只对当次作业生效。fatalArmsJobOnCallerThread 不对位（v3 §1 §8：Flutter 的 fatal 不排后台作业）。

import 'dart:async';
import 'dart:io';

import 'package:revdog_retriever/src/fs.dart';
import 'package:revdog_retriever/src/json.dart';
import 'package:revdog_retriever/src/limits.dart';
import 'package:test/test.dart';

import 'support/support.dart';

bool isRootUser() => (Process.runSync('id', ['-u']).stdout as String).trim() == '0';

void main() {
  setUpRtv();

  /// 引擎队列被堵住（冷启动恢复、大批物化）时 fatal 立即返回；开闸后出站箱有 p0 批、段已封。
  test('fatalReturnsWhileEngineBusy', () async {
    final h = await Harness.create();
    await h.settle();
    h.l(LogLevel.info, 'warm up');
    final gate = await h.blockEngine();
    final sw = Stopwatch()..start();
    h.l(LogLevel.fatal, 'dying');
    final took = sw.elapsedMicroseconds;
    final before = h.outboxFiles('p0');
    gate.complete();
    expect(took, lessThan(50000), reason: 'took ${took / 1000} ms');
    expect(before, isEmpty, reason: '开闸前还没物化');
    await h.settle();
    expect(h.outboxFiles('p0').length, 1);
    expect(File('${h.sessionDir()}/seg-000001.sealed').existsSync(), isTrue);
    expect(h.transport.batchRequests.length, 0, reason: 'fatal 只落盘不尝试上传');
  });

  /// purgeLocal 立即返回（引擎堵住也不等），返回的 Future 清完才完成：完成时 installId 已是新值、root 已清；
  /// 排在前面的排空不发要清掉的批。
  test('purgeReturnsImmediately', () async {
    final h = await Harness.create();
    await h.settle();
    h.l(LogLevel.warn, 'to be purged');
    await h.seal();
    expect(h.outboxFiles().length, 1);
    final old = h.client.installId;
    final gate = await h.blockEngine();
    h.client.kickDrain(); // 排空排在清空前面：它的选批卡在引擎队列上
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final sw = Stopwatch()..start();
    final f = Retriever.purgeLocal();
    final took = sw.elapsedMicroseconds;
    expect(h.client.installId, old, reason: '返回时还是旧值');
    gate.complete();
    expect(took, lessThan(50000), reason: 'took ${took / 1000} ms');
    await f.timeout(const Duration(seconds: 10));
    final inDone = h.client.installId;
    await h.settle();
    expect(inDone, isNot(old));
    expect(h.client.installId, inDone);
    expect(h.outboxFiles(), isEmpty);
    expect(h.transport.batchRequests.length, 0, reason: '要清掉的批一个都没发');
  });

  /// 清空进行中宿主照常 log()：切换之前的行随旧 root 删掉（设计如此），同一会话内每一行都占 seq，切换之后的行全部在新会话的段里。
  test('logDuringPurgeIsNotSilentlyDropped', () async {
    final h = await Harness.create();
    await h.settle();
    h.l(LogLevel.warn, 'before purge');
    final old = h.client.installId;
    final w = h.client.writer;
    final gate = await h.blockEngine();
    var done = false;
    Retriever.purgeLocal().whenComplete(() => done = true).ignore();
    gate.complete();
    var n = 0;
    var dropped = 0;
    // 至少 50 行，一直写到清空完成（行间让出事件循环，让清空的每一步都有行落在其间）
    while (n < 50 || (!done && n < 3000)) {
      final sid0 = w.currentSessionId;
      final seq0 = w.snapshot.seq;
      h.l(LogLevel.warn, 'during $n');
      final sid1 = w.currentSessionId;
      final seq1 = w.snapshot.seq;
      // 前后都在同一会话：这一行必须占一个 seq
      if (sid0 == sid1 && seq1 != seq0 + 1) dropped += 1;
      n += 1;
      await Future<void>.delayed(const Duration(microseconds: 100));
    }
    expect(done, isTrue);
    h.l(LogLevel.warn, 'after purge');
    await h.settle();
    expect(dropped, 0, reason: '同一会话内每行都占 seq（没有空返回）');
    expect(h.client.installId, isNot(old));
    final seg = h.client.debugOpenSegmentFile!;
    expect(Fs.parentOf(seg), h.sessionDir(), reason: '新会话的段在新 root 里');
    final msgs = readSegmentLines(seg).skip(1).map((l) => JsonIn.objText(l)!['msg'] as String).toList();
    expect(msgs.length, h.client.debugCounters.$1, reason: '新段的行数 == 新会话的 seq 计数');
    // 新段 = 切换之后的连续尾巴：during k … during n-1、after purge
    final k = n - (msgs.length - 1);
    expect(msgs, [for (var i = k; i < n; i++) 'during $i', 'after purge']);
    final base = h.root.split('/').last;
    expect(
      Directory(h.root).parent.listSync().every((e) => !e.path.split('/').last.startsWith('$base.purge-')),
      isTrue,
    );
  });

  /// 两次 purgeLocal 重叠：第一次做完、第二次还排着时，排空在取批前停在 purging、拉配置被拒；两次清空之后只拉一次配置。
  test('overlappingPurgesHoldNetworkUntilLast', () async {
    final h = await Harness.create();
    await h.settle();
    h.l(LogLevel.warn, 'to be purged');
    await h.seal();
    expect(h.outboxFiles().length, 1);
    final c0 = h.transport.configRequests.length;
    final old = h.client.installId;
    final gateA = await h.blockEngine();
    final first = Retriever.purgeLocal();
    // 第二次清空排在另一道闸后面：第一次做完之后它还没开始
    final gateB = Completer<void>();
    h.client.workAsync(() => gateB.future);
    final second = Retriever.purgeLocal();
    gateA.complete();
    await first.timeout(const Duration(seconds: 10));
    h.client.kickDrain();
    h.client.fetchConfig();
    await waitUntil(() => h.client.lastStop.$1 == 'purging');
    expect(h.client.lastStop.$1, 'purging', reason: '第二次清空还没做：排空停在 purging');
    gateB.complete();
    await second.timeout(const Duration(seconds: 10));
    await h.settle();
    expect(h.client.installId, isNot(old));
    expect(h.outboxFiles(), isEmpty);
    expect(h.transport.batchRequests.length, 0, reason: '要清掉的批一个都没发');
    expect(h.transport.configRequests.length, c0 + 1, reason: '两次清空之后只拉一次配置');
    expect(h.transport.configRequests.last.headers['X-Rtv-Install'], h.client.installId);
  });

  /// 禁用跨重启有效：重建实例后 log() 不占 seq，启动之后 0 次上传、0 次拉配置（出站箱预置了批）。
  test('disabledPersistsAcrossRestart', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    h.l(LogLevel.warn, 'queued before consent withdrawn');
    await h.seal();
    h.setEnabled(false);
    await h.settle();
    expect(File(h.disabledMarker).existsSync(), isTrue, reason: '标记在 root 同级');
    expect(File('${h.root}/disabled').existsSync(), isFalse);
    await h.simulateCrash();

    final h2 = await Harness.create(root: h.root, clock: h.clock);
    expect(h2.client.isEnabled, isFalse);
    h2.l(LogLevel.error, 'not written');
    expect(h2.client.debugCounters.$1, 0);
    await h2.settle();
    await h2.tick(Limits.configPollIntervalS * 1000);
    h2.platform.handler!.willEnterForeground();
    await h2.settle();
    expect(h2.transport.batchRequests.length, 0);
    expect(h2.transport.configRequests.length, 0);
    // 只有预置的那一批留在本地：禁用期间恢复不合成 unclean_exit，旧会话零行直接删
    final queued = h2.outboxFiles().length;
    expect(queued, 1);
    // 重新同意：删标记、排空、拉配置
    h2.setEnabled(true);
    await h2.settle();
    expect(File(h2.disabledMarker).existsSync(), isFalse);
    expect(h2.transport.configRequests, isNotEmpty, reason: '重新启用后拉配置');
    await h2.tick(2000);
    expect(h2.transport.batchRequests.length, queued);
    expect(h2.outboxFiles(), isEmpty);
  });

  /// 禁用期间不拉配置：推进 31 min 再发回前台事件，拉配置 0 次。
  test('disabledStopsConfigPoll', () async {
    final h = await Harness.create();
    await h.settle();
    final n0 = h.transport.configRequests.length;
    h.setEnabled(false);
    await h.settle();
    await h.tick(31 * 60 * 1000);
    h.platform.handler!.willEnterForeground();
    await h.settle();
    await h.tick(31 * 60 * 1000);
    expect(h.transport.configRequests.length, n0);
  });

  /// 禁用状态下清空：新 install_id；0 次请求；标记仍在（它在 root 外面）。
  test('purgeWhileDisabled', () async {
    final h = await Harness.create();
    await h.settle();
    final n0 = h.transport.configRequests.length;
    h.setEnabled(false);
    await h.settle();
    final old = h.client.installId;
    await h.purgeBlocking();
    expect(h.client.installId, isNot(old));
    expect(File(h.disabledMarker).existsSync(), isTrue);
    expect(h.client.isEnabled, isFalse);
    expect(h.transport.configRequests.length, n0);
    expect(h.transport.batchRequests.length, 0);
  });

  /// configure 之前的 setEnabled：暂存，建实例时作为初值（写入立即按它生效）并落盘。
  test('pendingEnabledAppliedAtConstruction', () async {
    final h = await Harness.create(key: '', initialEnabled: false);
    expect(h.client.isEnabled, isFalse);
    h.l(LogLevel.error, 'not written');
    expect(h.client.debugCounters.$1, 0);
    await h.settle();
    expect(File(h.disabledMarker).existsSync(), isTrue);
    // 暂存值为 true 时删掉旧标记
    await h.simulateCrash();
    final h2 = await Harness.create(root: h.root, key: '', clock: h.clock, initialEnabled: true);
    expect(h2.client.isEnabled, isTrue);
    await h2.settle();
    expect(File(h2.disabledMarker).existsSync(), isFalse);
    // 静态入口：还没有实例、root 也还不知道（root() 没回包）时暂存
    final p = FakePlatform()..rootMode = CallMode.hang;
    await RetrieverRuntime.resetForTesting(platformFactory: () => p);
    Retriever.setEnabled(false);
    expect(Retriever.isEnabled, isFalse);
    Retriever.setEnabled(true);
    expect(Retriever.isEnabled, isTrue);
  });

  /// setEnabled(false) 之后零联网，不等引擎把开关同步过去：落盘那一跳之前已排进引擎的选批 / 拉配置也看宿主刚设的开关。
  test('disableTakesEffectBeforeEngineCatchesUp', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    h.l(LogLevel.warn, 'queued');
    await h.seal();
    expect(h.outboxFiles().length, 1);
    final gate = await h.blockEngine();
    // 开上传，并让排空的选批、拉配置的请求构造都排进引擎队列（在 setEnabled 的落盘之前）
    h.client.reconfigure(demoKey, base, const RetrieverOptions(), h.client.processName);
    h.client.kickDrain();
    h.client.fetchConfig();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    h.setEnabled(false);
    gate.complete();
    await h.settle();
    expect(h.transport.batchRequests.length, 0);
    expect(h.transport.configRequests.length, 0);
    expect(h.outboxFiles().length, 1);
    expect(File(h.disabledMarker).existsSync(), isTrue);
  });

  /// setEnabled(false) 取消排着的后台作业（假平台收到 cancelUploadJob）；禁用时进后台不排作业。
  test('disableCancelsJob', () async {
    final h = await Harness.create(options: const RetrieverOptions(jobId: 77));
    await h.settle();
    h.transport.defaultReply = Reply.network;
    h.l(LogLevel.warn, 'pending');
    await h.sealAndDrain();
    expect(h.outboxFiles().length, 1);
    h.setEnabled(false);
    await h.settle();
    expect(h.platform.cancelledJobs, [77]);
    h.platform.handler!.didEnterBackground(null);
    await h.settle();
    expect(h.platform.scheduledJobs, isEmpty);
  });

  /// 标记写失败（父目录不可写）：内存照样禁用，调度 tick 重试直到写成。
  test('markerWriteRetry', () async {
    if (isRootUser()) {
      markTestSkipped('root 用户写得进去');
      return;
    }
    final parent = tempDir('rtv-parent');
    final h = await Harness.create(root: '$parent/retriever', key: '');
    await h.settle();
    Process.runSync('chmod', ['555', parent]);
    try {
      h.setEnabled(false);
      await h.settle();
      expect(h.client.isEnabled, isFalse);
      expect(File(h.disabledMarker).existsSync(), isFalse);
      expect(await h.work((e) => e.markerPending), isTrue);
      h.l(LogLevel.warn, 'not written');
      expect(h.client.debugCounters.$1, 0);
    } finally {
      Process.runSync('chmod', ['755', parent]);
    }
    await h.tick();
    expect(File(h.disabledMarker).existsSync(), isTrue);
    expect(await h.work((e) => e.markerPending), isFalse);
  });

  /// 禁用状态下启动 20 次：会话都是零行，目录直接删、不写终态，sessions.jsonl 行数不增（ADR 0019 决定 1）。
  test('emptySessionsNotRecorded', () async {
    final root = tempDir();
    final first = await Harness.create(root: root, key: '');
    await first.settle();
    first.setEnabled(false);
    await first.settle();
    await first.simulateCrash();
    var last = first;
    for (var i = 0; i < 20; i++) {
      final h = await Harness.create(root: root, key: '', clock: first.clock);
      await h.settle();
      await h.simulateCrash();
      last = h;
    }
    expect(last.readJsonl('sessions.jsonl').length, 0);
    expect(Fs.listSync('$root/proc-main'), [last.client.writer.currentSessionId]);
  });

  /// 系统停止作业后，之后的排空（封段触发）照常上传；迟到的 stopUploadJob（作业已结束）不挡任何排空。
  test('stoppedJobDoesNotBlockLaterDrains', () async {
    final h = await Harness.create();
    await h.settle();
    h.transport.defaultReply = Reply.hang;
    h.l(LogLevel.warn, 'w1');
    await h.seal();
    final job = h.platform.handler!.drainOutbox(60000);
    await waitUntil(() => h.transport.hangingCount == 1);
    h.platform.handler!.stopUploadJob();
    expect(await job.timeout(const Duration(seconds: 10)), isTrue);
    await h.settle();
    h.transport.defaultReply = Reply.echo;
    h.clock.advance(Limits.backoffMaxMs);
    h.l(LogLevel.warn, 'w2');
    await h.sealAndDrain();
    await h.tick(2000);
    expect(h.outboxFiles(), isEmpty, reason: '被停的作业之后，封段触发的排空照常上传');
    // 迟到的停止回调：作业早已结束，不挡之后的排空
    h.platform.handler!.stopUploadJob();
    h.clock.advance(2000);
    h.l(LogLevel.warn, 'w3');
    await h.sealAndDrain();
    expect(h.outboxFiles(), isEmpty);
  });
}
