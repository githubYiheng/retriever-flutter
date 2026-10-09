// 对位 Android LayoutAndPerfTests.kt：本地布局（方案 §3.2）与 log() 延迟（信息性）。

import 'dart:io';

import 'package:revdog_retriever/src/fs.dart';
import 'package:revdog_retriever/src/ids.dart';
import 'package:test/test.dart';

import 'support/support.dart';

void main() {
  setUpRtv();

  /// 本地布局（方案 §3.2，含 config.json / cursor.closed_ms / backoff.last_ack_ms）。
  test('layoutAndInstallJson', () async {
    final t = FakeTransport()..configBody = {'etag': 'e', 'ttl_s': 600};
    final h = await Harness.create(transport: t);
    await h.settle();
    h.l(LogLevel.warn, 'w');
    await h.sealAndDrain();
    final inst = h.readJson('${h.root}/install.json');
    expect(Ids.isUuid(inst['install_id'] as String), isTrue);
    expect(int_(inst['session_counter']), 1);
    expect(inst['install_id'], h.client.installId);
    expect(h.client.supportCode, '${(inst['install_id'] as String).substring(0, 8)}-1');
    final meta = h.readJson('${h.sessionDir()}/meta.json');
    expect(int_(meta['session_no']), 1);
    expect(meta['process'], 'main');
    expect(obj(meta['device'])['sdk'], 'retriever-flutter/${RetrieverVersion.current}');
    expect(obj(meta['device'])['os'], 'android');
    for (final name in [
      'install.json',
      'config.json',
      'backoff.json',
      'mapping.json',
      'upload.lock',
      'outbox',
      'proc-main',
    ]) {
      expect(FileSystemEntity.typeSync('${h.root}/$name') != FileSystemEntityType.notFound, isTrue, reason: name);
    }
    expect(h.readJson('${h.root}/backoff.json').containsKey('last_ack_ms'), isTrue);
    expect(obj(h.readJson('${h.root}/config.json')['config']).containsKey('upload_level'), isTrue);
    final files = Fs.listSync(h.sessionDir())!..sort();
    expect(files, [
      'cursor.json',
      'lock',
      'meta.json',
      'seg-000001.sealed',
      'seg-000002.open',
    ], reason: '会话锁在专用文件 lock 上');
    // 第二次启动：计数器 +1，install_id 不变
    final h2 = await Harness.create(root: h.root, key: '', clock: h.clock);
    await h2.settle();
    expect(h2.client.installId, h.client.installId);
    expect(h2.client.supportCode!.endsWith('-2'), isTrue);
    // purgeLocal：新 install_id（Future 清完才完成，此时是新值）
    final oldIid = h2.client.installId;
    await h2.purgeBlocking();
    expect(h2.client.installId, isNot(oldIid));
    expect(h2.client.supportCode!.endsWith('-1'), isTrue);
    h2.l(LogLevel.warn, 'after purge');
    expect(h2.client.debugCounters.$1, 1);
    expect((Fs.listSync(h2.root)!..sort()).where((n) => !n.startsWith('.') && n != 'upload.lock').toList(), [
      'install.json',
      'outbox',
      'proc-main',
    ]);
  });

  /// 性能（信息性）：log() 1 万次的 p99，打印到测试输出；断言 < 1 ms（dart test 下的 JIT，宿主机）。
  test('logLatencyP99', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    final samples = <int>[];
    final sw = Stopwatch()..start();
    for (var i = 0; i < 10000; i++) {
      final t0 = sw.elapsedMicroseconds;
      Retriever.log(
        i % 10 == 0 ? LogLevel.warn : LogLevel.info,
        'request finished',
        tag: 'net',
        attrs: {'status': 200, 'path': '/v1/plan', 'ms': i % 300},
      );
      samples.add(sw.elapsedMicroseconds - t0);
    }
    samples.sort();
    final p50 = samples[5000];
    final p99 = samples[9900];
    final max = samples.last;
    print('[perf] log() x10000 (dart test, JIT): p50=$p50µs p99=$p99µs max=$maxµs');
    expect(p99, lessThan(1000), reason: 'p99=$p99 µs');
  });
}
