// 对位 Android LifecycleTests.kt：生命周期与后台兜底（方案 §3.9 Flutter 列；v3 §3 ← 方向的事件）——进后台封段 + 排空 + 排一次性
// 后台作业；作业里排空出站箱并回报是否需要系统重排；系统停止作业时取消在途请求、不删批。
// Flutter 差异：fatal 不排后台作业（v3 §1 §8）；另加 iOS 侧事件（foregroundStateChanged / backgroundTaskExpired / endBackgroundTask）。

import 'dart:io';

import 'package:revdog_retriever/src/fs.dart';
import 'package:revdog_retriever/src/limits.dart';
import 'package:test/test.dart';

import 'support/support.dart';

Map<String, Object?> cursor(Harness h) => h.readJson('${h.sessionDir()}/cursor.json');

Future<bool> runJob(Harness h) async {
  final r = await h.platform.handler!.drainOutbox(60000).timeout(const Duration(seconds: 30));
  await h.settle();
  return r;
}

void main() {
  setUpRtv();

  test('backgroundSealsDrainsAndSchedulesJob', () async {
    final h = await Harness.create();
    await h.settle();
    h.transport.defaultReply = Reply.network; // 离线：批留在出站箱，靠作业兜底
    h.l(LogLevel.warn, 'w');
    h.platform.handler!.didEnterBackground(null);
    await h.settle();
    expect(cursor(h)['last_state'], 'bg');
    expect(h.outboxFiles('p1').length, 1, reason: '进后台封段并物化');
    expect(h.transport.batchRequests.length, 1, reason: '排空尝试过');
    expect(h.platform.scheduledJobs, [0x5254], reason: '后台时排了作业（默认 id 0x5254）');
    // 上传锁已释放（另一个进程能拿到）
    final other = RootLocks(h.root);
    expect(other.tryUploadLock(), isTrue);
    other.close();
  });

  test('backgroundWithoutObligationDoesNotSealNorSchedule', () async {
    final h = await Harness.create();
    await h.settle();
    h.l(LogLevel.info, 'just info');
    h.platform.handler!.didEnterBackground(null);
    await h.settle();
    expect(h.client.writer.snapshot.segNo, 1);
    expect(h.transport.batchRequests.length, 0);
    expect(h.platform.scheduledJobs.length, 0, reason: '出站箱没有待传批：不排作业');
    expect(cursor(h)['last_state'], 'bg');
  });

  /// Flutter 口径（v3 §1 §8）：fatal 不排后台作业（Dart 不能同步调原生），封段物化照常、进程死后由恢复兜底。
  test('fatalSealsWithoutSchedulingJob', () async {
    final h = await Harness.create(options: const RetrieverOptions(jobId: 4242));
    await h.settle();
    h.l(LogLevel.info, 'ctx');
    h.l(LogLevel.fatal, 'dying', error: StateError('x'));
    expect(h.platform.scheduledJobs, isEmpty);
    await h.settle();
    expect(h.outboxFiles('p0').length, 1);
  });

  test('backgroundLastStateMeansCleanExitOnNextLaunch', () async {
    final root = tempDir();
    final a = await Harness.create(root: root, key: '');
    await a.settle();
    a.l(LogLevel.warn, 'w');
    a.platform.handler!.didEnterBackground(null);
    await a.settle();
    final aSid = a.client.writer.currentSessionId;
    await a.simulateCrash();
    final b = await Harness.create(root: root, key: '');
    await b.settle();
    final closed = b.readJsonl('sessions.jsonl').firstWhere((c) => c['session_id'] == aSid);
    expect(closed['exit'], 'clean_bg');
    // 后台被杀是常态：不合成 unclean_exit
    expect(b.envelopes().any((e) => e.lines.any((l) => l['synthetic'] == true)), isFalse);
  });

  test('foregroundWritesLastStateAndDrains', () async {
    final h = await Harness.create();
    await h.settle();
    h.transport.defaultReply = Reply.network;
    h.l(LogLevel.warn, 'w');
    h.platform.handler!.didEnterBackground(null);
    await h.settle();
    expect(h.outboxFiles().length, 1);
    h.transport.defaultReply = Reply.echo;
    h.clock.advance(Limits.backoffMaxMs);
    h.platform.handler!.willEnterForeground();
    await h.settle();
    expect(cursor(h)['last_state'], 'fg');
    expect(h.outboxFiles(), isEmpty);
  });

  test('uploadJobDrainsAndReportsReschedule', () async {
    final h = await Harness.create();
    await h.settle();
    h.transport.defaultReply = Reply.network;
    h.l(LogLevel.error, 'e');
    await h.seal();
    // 作业 1：离线 → 批还在、要求系统按退避重排
    expect(await runJob(h), isTrue);
    expect(h.outboxFiles().length, 1);
    // 作业 2：有网 → 排空、不再重排
    h.transport.defaultReply = Reply.echo;
    h.clock.advance(Limits.backoffMaxMs);
    expect(await runJob(h), isFalse);
    expect(h.outboxFiles(), isEmpty);
    // 作业 3：没有 key → 什么都不做、不重排
    final h2 = await Harness.create(key: '');
    await h2.settle();
    h2.l(LogLevel.warn, 'w');
    await h2.seal();
    expect(await runJob(h2), isFalse);
    expect(h2.outboxFiles().length, 1);
  });

  test('stoppedJobCancelsInFlightKeepsBatch', () async {
    final h = await Harness.create();
    await h.settle();
    h.transport.defaultReply = Reply.hang;
    h.l(LogLevel.warn, 'w');
    await h.seal();
    final job = h.platform.handler!.drainOutbox(60000);
    await waitUntil(() => h.transport.hangingCount == 1);
    expect(h.transport.hangingCount, 1, reason: '排空已在途');
    // 系统回调 onStopJob
    h.platform.handler!.stopUploadJob();
    expect(await job.timeout(const Duration(seconds: 10)), isTrue, reason: '被停的作业要求重排');
    expect(h.transport.cancelCount, greaterThanOrEqualTo(1));
    await h.settle();
    expect(h.outboxFiles().length, 1, reason: '取消的请求不删批');
    final other = RootLocks(h.root);
    expect(other.tryUploadLock(), isTrue, reason: '上传锁已释放');
    other.close();
    // 回前台：重新排空
    h.transport.defaultReply = Reply.echo;
    h.clock.advance(Limits.backoffMaxMs);
    h.platform.handler!.willEnterForeground();
    await h.settle();
    expect(h.outboxFiles(), isEmpty);
  });

  test('backgroundDrainsSeveralBatchesAcrossSpacing', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    for (var i = 0; i < 3; i++) {
      h.l(LogLevel.warn, 'w$i');
      await h.seal();
    }
    h.l(LogLevel.warn, 'in open segment');
    await h.work((e) => e.key = demoKey);
    h.platform.handler!.didEnterBackground(null);
    await waitUntil(() => h.outboxFiles().isEmpty && h.transport.batchRequests.length == 4);
    await h.settle();
    expect(h.transport.batchRequests.length, 4, reason: '3 个旧批 + 进后台封出的 1 批，间隔 2 s 就地等待');
    expect(h.outboxFiles(), isEmpty);
  });

  /// iOS：进后台的后台任务 id 随事件交给 Dart，排空结束后 `endBackgroundTask(id)`；到期（原生已先 end）只取消在途请求、不删批、不计失败。
  test('backgroundTaskEndedAfterDrainAndExpiryCancelsInFlight', () async {
    final h = await Harness.create();
    await h.settle();
    h.l(LogLevel.warn, 'w');
    h.platform.handler!.didEnterBackground(7);
    await h.settle();
    await waitUntil(() => h.platform.endedTasks.isNotEmpty);
    expect(h.platform.endedTasks, [7]);
    expect(h.outboxFiles(), isEmpty);
    // 到期：在途请求被取消，批留着，不计失败也不退避
    h.platform.handler!.willEnterForeground();
    h.transport.defaultReply = Reply.hang;
    h.clock.advance(3000);
    h.l(LogLevel.warn, 'w2');
    h.platform.handler!.didEnterBackground(8);
    await waitUntil(() => h.transport.hangingCount == 1);
    h.platform.handler!.backgroundTaskExpired(8);
    await waitUntil(() => h.platform.endedTasks.length == 2);
    await h.settle();
    expect(h.platform.endedTasks, [7, 8]);
    final name = h.outboxFiles().single;
    expect(await h.work((e) => e.fails[name]), isNull);
    expect((await h.backoff).attempt, 0);
    expect(h.client.lastStop.$1, 'background_expired');
    // 回前台复位停止标志：照常排空
    h.transport.defaultReply = Reply.echo;
    h.clock.advance(3000);
    h.platform.handler!.willEnterForeground();
    await h.settle();
    expect(h.outboxFiles(), isEmpty);
  });

  /// `foregroundStateChanged(fg)` 只改 last_state、不封段（对位 iOS 0.3.0）。
  test('foregroundStateChangedOnlyWritesLastState', () async {
    final h = await Harness.create();
    await h.settle();
    h.l(LogLevel.warn, 'w');
    h.platform.handler!.foregroundStateChanged(false);
    await h.settle();
    expect(cursor(h)['last_state'], 'bg');
    expect(h.client.writer.snapshot.segNo, 1, reason: '不封段');
    expect(h.outboxFiles(), isEmpty);
    h.platform.handler!.foregroundStateChanged(true);
    await h.settle();
    expect(cursor(h)['last_state'], 'fg');
    expect(Fs.listSync(h.sessionDir())!.where((n) => n.endsWith('.sealed')), isEmpty);
  });

  /// bootstrap 回包的 foreground 可空：读不到 = null → last_state 留空，退出判 unknown（不硬塞 bg）。
  test('nullForegroundLeavesLastStateEmpty', () async {
    final p = FakePlatform()..foreground = null;
    final h = await Harness.create(key: '', platform: p, clock: p.clock as FakeClock);
    await h.settle();
    expect(cursor(h)['last_state'], isNull);
    h.l(LogLevel.warn, 'w');
    final sid = h.client.writer.currentSessionId;
    await h.simulateCrash();
    final h2 = await Harness.create(root: h.root, key: '', clock: h.clock);
    await h2.settle();
    expect(h2.readJsonl('sessions.jsonl').singleWhere((c) => c['session_id'] == sid)['exit'], 'unknown');
    expect(File('${h.root}/proc-main/$sid/seg-000001.sealed').existsSync(), isTrue);
  });
}
