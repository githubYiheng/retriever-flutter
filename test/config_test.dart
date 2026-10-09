// 对位 Android ConfigTests.kt：远程配置（方案 §5；宪法 U-1 / U-2）。

import 'package:revdog_retriever/src/limits.dart';
import 'package:test/test.dart';

import 'support/support.dart';

void main() {
  setUpRtv();

  test('fetchHeadersAndApply', () async {
    final t = FakeTransport()
      ..configBody = {
        'etag': 'e1',
        'ttl_s': 600,
        'upload_level': 'info',
        'local_level': 'info',
        'flush_interval_s': 60,
      };
    final h = await Harness.create(options: const RetrieverOptions(dailyBatchCap: 7), transport: t);
    await h.settle();
    h.setUser('张三 u/1');
    await h.tick(Limits.configPollIntervalS * 1000);
    final r = t.configRequests.last;
    expect(r.method, 'GET');
    expect(r.url, 'https://logs-test.invalid/v1/config');
    expect(r.headers['Authorization'], 'Bearer lk_test_demo_abc_12345678');
    expect(r.headers['X-Rtv-Install'], h.client.installId);
    expect(r.headers['X-Rtv-Sdk'], 'retriever-flutter/${RetrieverVersion.current}');
    expect(r.headers['X-Rtv-App-Version'], '1.2.3');
    expect(r.headers['X-Rtv-Upload-Level'], 'warn');
    expect(r.headers['X-Rtv-Local-Level'], 'debug');
    expect(r.headers['X-Rtv-Daily-Batch-Cap'], '7');
    expect(r.headers['X-Rtv-Local-Cap-Bytes'], (20 * 1024 * 1024).toString());
    expect(r.headers['X-Rtv-User'], '%E5%BC%A0%E4%B8%89%20u%2F1');
    expect(Uri.decodeComponent(r.headers['X-Rtv-User']!), '张三 u/1');
    // 生效：info 行成义务行，debug 行不写；公开只读级别同步
    expect(h.client.effectiveLevels.$1, LogLevel.info);
    expect(h.client.effectiveLevels.$2, LogLevel.info);
    final before = h.client.debugCounters;
    h.l(LogLevel.debug, 'filtered');
    h.l(LogLevel.info, 'obligation now');
    expect(h.client.debugCounters.$1, before.$1 + 1);
    expect(h.client.debugCounters.$2, before.$2 + 1);
    // 缓存到 config.json（记拉它的用户），重启后（同一用户）按墙钟兜底
    expect(h.readJson('${h.root}/config.json')['user_id'], '张三 u/1');
    final h2 = await Harness.create(root: h.root, clock: h.clock, transport: FakeTransport(), initialUser: '张三 u/1');
    await h2.settle();
    final eff = await h2.work((e) => e.effective);
    expect(eff.uploadLevel, LogLevel.info);
    expect(eff.config.flushIntervalS, 60);
  });

  test('malformedConfigFallsBackWithoutAmplifying', () async {
    final t = FakeTransport()
      ..configBody = {'upload_level': 'VERBOSE', 'context_lines': 'lots', 'full_dump': 'yes', 'local_cap_bytes': -5};
    final h = await Harness.create(transport: t);
    await h.settle();
    final eff = await h.work((e) => e.effective);
    expect(eff.uploadLevel, LogLevel.warn);
    expect(eff.fullDumpActive, isFalse);
    expect(eff.config.contextLines, Limits.ctxLinesDefault);
    expect(eff.config.localCapBytes, Limits.localCapBytesMin);
  });

  test('configEtagChangeInBatchResponseTriggersFetch', () async {
    final t = FakeTransport()..configBody = {'etag': 'etag-0', 'ttl_s': 1800};
    final h = await Harness.create(transport: t);
    await h.settle();
    final n0 = t.configRequests.length;
    h.l(LogLevel.warn, 'a');
    await h.sealAndDrain();
    expect(t.configRequests.length, n0, reason: 'etag 未变不拉');
    t.configEtag = 'etag-1';
    h.l(LogLevel.warn, 'b');
    await h.sealAndDrain();
    await h.tick(2000);
    await h.settle();
    expect(t.configRequests.length, n0 + 1);
  });

  test('uploadDisabledWritesButDoesNotSend', () async {
    final t = FakeTransport()..configBody = {'etag': 'x', 'upload_enabled': false};
    final h = await Harness.create(transport: t);
    await h.settle();
    h.l(LogLevel.warn, 'kept locally');
    await h.sealAndDrain();
    expect(t.batchRequests.length, 0);
    expect(h.outboxFiles().length, 1);
    expect(await h.flushBlocking(), FlushResult.pending('paused'));
    expect(h.outboxFiles().length, 2, reason: 'flush 的批也只落盘');
    // 恢复：upload_enabled 变化触发封段并排空
    t.configBody = {'etag': 'y', 'upload_enabled': true};
    h.l(LogLevel.warn, 'more');
    await h.tick(Limits.configPollIntervalS * 1000);
    await h.tick(2000);
    await h.tick(2000);
    expect(h.outboxFiles(), isEmpty);
    expect(t.batchRequests.length, 3);
  });

  /// 不看网络类型（ADR 0009）：backfill 批与其它批走同一套队列 / 退避规则，生成后照常上传。
  test('backfillUploadsLikeOtherBatches', () async {
    final t = FakeTransport();
    final h = await Harness.create(key: '', transport: t);
    await h.settle();
    h.l(LogLevel.debug, 'history');
    await h.seal();
    t.configBody = {'etag': 'fd', 'full_dump': true, 'full_dump_ttl_s': 3600};
    await h.enableUpload();
    expect(t.batchRequests.length, 1, reason: 'backfill 不等网络，照常上传');
    expect(FakeTransport.envOf(t.batchRequests[0].body)!['kind'], 'backfill');
    expect(h.outboxFiles(), isEmpty);
    expect(h.client.effectiveLevels.$1, LogLevel.debug);
  });
}
