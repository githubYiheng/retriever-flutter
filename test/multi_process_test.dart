// 对位 Android MultiProcessTests.kt：多进程（方案 §3.2 / §3.4）——各进程独立会话目录；install.json / 出站箱共享；
// 只有持有 upload.lock 的一方排空。同一 isolate 里的两个实例模拟两个进程（fcntl 锁是进程级的：isolate 内由加锁登记表互斥）。

import 'dart:io';

import 'package:revdog_retriever/src/pre.dart';
import 'package:revdog_retriever/src/uploader.dart';
import 'package:test/test.dart';

import 'support/support.dart';

void main() {
  setUpRtv();

  test('processesHaveOwnSessionDirsAndShareOutbox', () async {
    final root = tempDir();
    final main = await Harness.create(root: root, key: '', direct: true);
    await main.settle();
    final remote = await Harness.create(
      root: root,
      key: '',
      options: const RetrieverOptions(processName: 'remote'),
      direct: true,
    );
    await remote.settle();
    expect(remote.client.processName, 'remote');
    expect(Directory('$root/proc-main').existsSync(), isTrue);
    expect(Directory('$root/proc-remote').existsSync(), isTrue);
    // 共享 install_id，session_no 各自递增
    expect(remote.client.installId, main.client.installId);
    expect(remote.client.supportCode, isNot(main.client.supportCode));
    main.l(LogLevel.warn, 'from main');
    remote.l(LogLevel.warn, 'from remote');
    await main.seal();
    await remote.seal();
    final envs = main.envelopes();
    expect(envs.map((e) => e['process']).toSet(), {'main', 'remote'});
    // 远端进程的会话不被主进程的恢复流程当孤儿
    final main2 = await Harness.create(root: root, key: '', direct: true);
    await main2.settle();
    expect(File('${remote.sessionDir()}/meta.json').existsSync(), isTrue);
    expect(
      main2.readJsonl('sessions.jsonl').where((c) => c['session_id'] == remote.client.writer.currentSessionId).length,
      0,
    );
    assertAllValid(await runValidator(envs));
  });

  test('uploadLockIsExclusiveAcrossInstances', () async {
    final root = tempDir();
    final a = await Harness.create(root: root, key: '', direct: true);
    await a.settle();
    final b = await Harness.create(
      root: root,
      key: '',
      options: const RetrieverOptions(processName: 'worker'),
      direct: true,
    );
    await b.settle();
    expect(await a.work((e) => e.acquireUploadLock()), isTrue);
    expect(await a.work((e) => e.acquireUploadLock()), isTrue, reason: '同一实例重新加锁');
    expect(await b.work((e) => e.acquireUploadLock()), isFalse);
    // 拿不到锁的一方不发请求（locked，1 分钟后再试）
    await b.work((e) => e.key = demoKey);
    b.l(LogLevel.warn, 'w');
    await b.sealAndDrain();
    expect(b.transport.batchRequests.length, 0);
    expect(b.client.lastStop.$1, 'locked');
    await a.work((e) => e.releaseUploadLock());
    await b.tick(60000);
    expect(b.transport.batchRequests.length, 1);
    expect(b.outboxFiles(), isEmpty);
  });

  /// 禁用标记在 root 同级、多进程共享（ADR 0020 决定 2）：A 禁用后，B 的上传 / 拉配置在下一次决策时就停；
  /// B 的写入要到它自己调用或重启才停。A 重新启用后 B 照常上传。
  test('markerSeenAcrossProcesses', () async {
    final root = tempDir();
    final a = await Harness.create(root: root, key: '', direct: true);
    await a.settle();
    final b = await Harness.create(
      root: root,
      options: const RetrieverOptions(processName: 'worker'),
      direct: true,
    );
    await b.settle();
    final cfg0 = b.transport.configRequests.length;
    a.client.setEnabled(false);
    await a.settle();
    expect(File(a.disabledMarker).existsSync(), isTrue);
    expect(b.client.isEnabled, isTrue, reason: 'B 的内存开关不受影响');
    b.l(LogLevel.warn, 'b still writes');
    expect(b.client.debugCounters.$2, 1);
    await b.sealAndDrain();
    expect(b.client.lastStop.$1, 'disabled');
    expect(b.transport.batchRequests.length, 0);
    await b.tick(31 * 60 * 1000);
    expect(b.transport.configRequests.length, cfg0, reason: 'B 也不拉配置');
    a.client.setEnabled(true);
    await a.settle();
    await b.tick(2000);
    expect(b.transport.batchRequests.length, 1);
    expect(b.outboxFiles(), isEmpty);
  });

  /// 多进程下 purgeLocal 只保证调用进程：B 内存里还是旧 install，但它排空时以每个批自身信封里的 install 上报（ADR 0019 决定 10）。
  test('otherProcessUploadsWithEnvelopeInstallAfterPurge', () async {
    final root = tempDir();
    final a = await Harness.create(root: root, key: '', direct: true);
    await a.settle();
    final b = await Harness.create(
      root: root,
      key: '',
      options: const RetrieverOptions(processName: 'worker'),
      direct: true,
    );
    await b.settle();
    final old = a.client.installId;
    await a.purgeBlocking();
    final fresh = a.client.installId!;
    expect(fresh, isNot(old));
    expect(b.client.installId, old, reason: 'B 内存里的 install 不变（写进 README 的限制）');
    a.l(LogLevel.warn, 'written after purge');
    await a.seal();
    expect(a.envelopes().single['install_id'], fresh);
    await b.enableUpload();
    expect(b.transport.batchRequests.length, 1);
    final r = b.transport.batchRequests[0];
    expect(FakeTransport.envOf(r.body)!['install_id'], fresh);
    expect(r.headers['X-Rtv-Install'], fresh, reason: '请求头 == 信封，不是 B 内存里的旧 install');
    expect(a.outboxFiles(), isEmpty);
  });

  test('processNameSanitized', () {
    expect(sanitizeProcessName(''), 'main');
    expect(sanitizeProcessName('remote'), 'remote');
    expect(sanitizeProcessName('com.foo:bar 1'), 'com.foo_bar_1');
    expect(sanitizeProcessName('日志/'), '___');
    expect(sanitizeProcessName('x' * 100).length, 64);
  });
}
