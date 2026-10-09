// 对位 Android StateOwnershipTests.kt：本地状态自带真实归属（ADR 0019）——install 身份从 meta.json 副本修复、无副本清空、
// 清空先改名再删、配置属于请求时的身份、段读不出不推进、jsonl 追加失败截回。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:revdog_retriever/src/fs.dart';
import 'package:revdog_retriever/src/ids.dart';
import 'package:revdog_retriever/src/json.dart';
import 'package:revdog_retriever/src/limits.dart';
import 'package:revdog_retriever/src/model.dart';
import 'package:test/test.dart';

import 'support/support.dart';

List<Map<String, Object?>> segLines(String path) =>
    readSegmentLines(path).skip(1).map((l) => JsonIn.objText(l)!).toList();

bool isRootUser() => (Process.runSync('id', ['-u']).stdout as String).trim() == '0';

void main() {
  setUpRtv();

  /// 旧会话有已确认批 + 出站箱 1 批 + 前台崩溃 → 损坏 install.json → 重启后 installId 不变、计数 = 旧 + 1、
  /// 所有请求头 == 信封 install、新会话的批不重复发映射；留 `rtv.install_repaired`（ADR 0019 决定 7）。
  test('corruptInstallJsonRepairsIdentityFromMeta', () async {
    final h = await Harness.create();
    await h.settle();
    h.l(LogLevel.warn, 'acked');
    await h.sealAndDrain();
    expect(h.transport.batchRequests.length, 1);
    expect(File('${h.root}/mapping.json').existsSync(), isTrue);
    h.transport.defaultReply = Reply.network;
    h.clock.advance(3000);
    h.l(LogLevel.warn, 'pending in outbox');
    await h.sealAndDrain();
    expect(h.outboxFiles().length, 1);
    h.l(LogLevel.warn, 'unsealed, foreground');
    final old = h.client.installId!;
    final oldSid = h.client.writer.currentSessionId;
    expect(h.readJson('${h.sessionDir()}/meta.json')['install_id'], old);
    await h.simulateCrash();
    File('${h.root}/install.json').writeAsStringSync('{"install_id":"not-a-uuid');

    final h2 = await Harness.create(root: h.root, clock: h.clock);
    await h2.settle();
    expect(h2.client.installId, old, reason: '不换 id');
    final inst = h2.readJson('${h2.root}/install.json');
    expect(inst['install_id'], old);
    expect(int_(inst['session_counter']), 2, reason: '计数续上');
    expect(h2.client.supportCode!.endsWith('-2'), isTrue);
    final repaired = segLines(
      '${h2.sessionDir()}/seg-000001.open',
    ).singleWhere((l) => l['tag'] == 'rtv.install_repaired');
    expect(repaired['level'], 'warn');
    expect(repaired['msg'], 'install.json unreadable; identity repaired from session meta');
    expect(repaired['synthetic'], true);
    expect(File('${h2.root}/mapping.json').existsSync(), isTrue, reason: '映射照常有效');
    await h2.sealAndDrain();
    for (var i = 0; i < 4; i++) {
      await h2.tick(2000);
    }
    expect(h2.outboxFiles(), isEmpty);
    final reqs = h2.transport.batchRequests;
    expect(reqs.length, 3, reason: '旧出站箱批 + 旧会话恢复批 + 新会话批');
    for (final r in reqs) {
      final e = FakeTransport.envOf(r.body)!;
      expect(e['install_id'], old);
      expect(r.headers['X-Rtv-Install'], e['install_id']);
    }
    final envs = reqs.map((r) => FakeTransport.envOf(r.body)!).toList();
    final own = envs.singleWhere(
      (e) =>
          e['session_id'] == h2.client.writer.currentSessionId ||
          e.lines.any((l) => l['tag'] == 'rtv.install_repaired'),
    );
    expect(own['mapping'], isNull, reason: '映射已确认过，新会话首批不重复发');
    expect(envs.any((e) => e['session_id'] == oldSid && e.lines.any((l) => l['tag'] == 'rtv.unclean_exit')), isTrue);
  });

  /// 有 meta 存在却读不了：同 install.json 读不了——本次失败、稍后重试，绝不重建（ADR 0019 决定 7）。
  test('unreadableMetaDuringRepairFailsBootstrap', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    await h.simulateCrash();
    final meta = File('${h.sessionDir()}/meta.json');
    meta.deleteSync();
    Directory(meta.path).createSync(); // 同名目录：存在但读失败
    final bad = utf8.encode('{"install_id":"not-a-uuid');
    File('${h.root}/install.json').writeAsBytesSync(bad);
    final h2 = await Harness.create(root: h.root, key: '', clock: h.clock);
    await h2.settle();
    expect(h2.client.installId, isNull, reason: '本次 bootstrap 失败、稍后重试');
    expect(File('${h.root}/install.json').readAsBytesSync(), bad, reason: '没被重建');
  });

  /// 修复身份时会话目录 stat 不了（无读 / 搜索权限）：同 meta 读不了——本次失败、稍后重试，不当成「无副本」清空 root。
  test('unsearchableSessionDirDuringRepairFailsBootstrap', () async {
    if (isRootUser()) {
      markTestSkipped('root 用户不受目录权限限制');
      return;
    }
    final h = await Harness.create(key: '');
    await h.settle();
    await h.simulateCrash();
    final dir = h.sessionDir();
    final bad = utf8.encode('{"install_id":"not-a-uuid');
    File('${h.root}/install.json').writeAsBytesSync(bad);
    Process.runSync('chmod', ['000', dir]);
    try {
      final h2 = await Harness.create(root: h.root, key: '', clock: h.clock);
      await h2.settle();
      expect(h2.client.installId, isNull, reason: '本次 bootstrap 失败、稍后重试');
      expect(File('${h.root}/install.json').readAsBytesSync(), bad, reason: '没被清空重建');
    } finally {
      Process.runSync('chmod', ['755', dir]);
    }
  });

  /// 无副本（只留 0.1.x 写的、不带 install_id 的 meta）+ jsonl + mapping + 出站箱 → 清空：重启后 root 只剩新状态，
  /// 首批带映射、无外来终态 / 墓碑，`rtv.install_reset` 的 attrs 记作废数量（ADR 0019 决定 8）。
  test('corruptInstallJsonWithoutEvidencePurges', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    h.l(LogLevel.warn, 'old batch');
    await h.seal();
    h.l(LogLevel.warn, 'old unsealed');
    final oldSid = h.client.writer.currentSessionId;
    await h.work((e) async {
      await e.appendDrops([DropEntry(oldSid, 9, 9, 1, 'corrupt', 1, -1)]);
      await e.appendClosed([ClosedSession(Ids.newV4(), 1, 1, 2, 3, 1, 'clean_bg')]);
    });
    await Fs.writeAtomic('${h.root}/mapping.json', MappingState(null, '0123456789abcdef', h.clock.wallMs()).encode());
    final old = h.client.installId!;
    await h.simulateCrash();
    // 降级成 0.1.x 的 meta（没有 install_id 键）
    final metaFile = File('${h.sessionDir()}/meta.json');
    final m = SessionMeta.decode(metaFile.readAsBytesSync())!;
    metaFile.writeAsBytesSync(m.copyWith(installId: null).encode());
    File('${h.root}/install.json').writeAsBytesSync(<int>[]);

    final h2 = await Harness.create(root: h.root, key: '', clock: h.clock);
    await h2.settle();
    final iid = h2.client.installId!;
    expect(iid, isNot(old));
    expect(h2.outboxFiles(), isEmpty);
    expect(File('${h2.root}/drops.jsonl').existsSync(), isFalse);
    expect(File('${h2.root}/sessions.jsonl').existsSync(), isFalse);
    expect(File('${h2.root}/mapping.json').existsSync(), isFalse);
    expect(Fs.listSync('${h2.root}/proc-main'), [h2.client.writer.currentSessionId]);
    final parent = Directory(h2.root).parent;
    final base = h2.root.split('/').last;
    expect(
      parent.listSync().every((e) => !e.path.split('/').last.startsWith('$base.purge-')),
      isTrue,
      reason: '改名出去的旧 root 已删',
    );
    final reset = segLines(h2.client.debugOpenSegmentFile!).singleWhere((l) => l['tag'] == 'rtv.install_reset');
    expect(reset['msg'], 'install.json unreadable; local state discarded');
    expect(reset['attrs'], {'batches': 1.0, 'sessions': 1.0});
    await h2.seal();
    final env = h2.envelopes().single;
    expect(env['install_id'], iid);
    expect(env.map.containsKey('mapping'), isTrue, reason: '首批带映射');
    expect(env.map.containsKey('closed_sessions'), isFalse, reason: '无外来终态');
    expect(env.map.containsKey('drops'), isFalse, reason: '无外来墓碑');
    assertAllValid(await runValidator([env]));
  });

  /// 启动时清掉 `<root>.purge-*` 残留；purgeLocal 之后 root 下只有新 install 的文件（ADR 0019 决定 9）。
  test('purgeLeftoverIsCleaned', () async {
    final root = tempDir();
    final leftover = Directory('$root.purge-x');
    Directory('${leftover.path}/proc-main').createSync(recursive: true);
    File('${leftover.path}/install.json').writeAsStringSync('{}');
    final h = await Harness.create(root: root);
    await h.settle();
    expect(leftover.existsSync(), isFalse);
    h.l(LogLevel.warn, 'before purge');
    h.transport.defaultReply = Reply.network;
    await h.sealAndDrain();
    expect(h.outboxFiles().length, 1);
    final old = h.client.installId;
    await h.purgeBlocking();
    expect(h.client.installId, isNot(old));
    expect((Fs.listSync(root)!..sort()).where((n) => !n.startsWith('.') && n != 'upload.lock').toList(), [
      'install.json',
      'outbox',
      'proc-main',
    ]);
    expect(h.outboxFiles(), isEmpty);
    final base = root.split('/').last;
    expect(Directory(root).parent.listSync().every((e) => !e.path.split('/').last.startsWith('$base.purge-')), isTrue);
  });

  /// 启动拉取挂起 → setUser("U") → 放行后出现第二个带 `X-Rtv-User: U` 的配置请求；同值 setUser 不产生额外请求（ADR 0019 决定 12）。
  test('setUserRefetchesConfigForNewIdentity', () async {
    final t = FakeTransport()..configBody = {'etag': 'e0', 'ttl_s': 600};
    final gate = Completer<void>();
    t.configGate = gate;
    final h = await Harness.create(transport: t);
    await waitUntil(() => t.configRequests.length == 1);
    expect(t.configRequests.length, 1);
    expect(t.configRequests[0].headers['X-Rtv-User'], isNull);
    h.setUser('U');
    t.configGate = null;
    gate.complete();
    await h.settle();
    await waitUntil(() => t.configRequests.length >= 2);
    await h.settle();
    expect(t.configRequests.length, 2);
    expect(t.configRequests[1].headers['X-Rtv-User'], 'U');
    h.setUser('U');
    await h.settle();
    expect(t.configRequests.length, 2, reason: '同值 setUser 不重拉');
    h.setUser(null);
    await h.settle();
    expect(t.configRequests.length, 3, reason: '登出也是身份变化');
    expect(t.configRequests[2].headers['X-Rtv-User'], isNull);
  });

  /// A 的配置响应在切到 B 之后才到：丢弃不生效并按 B 重拉（B 下 full_dump 不激活，也不生成 backfill）。
  test('staleResponseForPreviousUserNotApplied', () async {
    final t = FakeTransport()..configBody = {'etag': 'e0', 'ttl_s': 600};
    final h = await Harness.create(transport: t);
    await h.settle();
    h.l(LogLevel.debug, 'history for backfill');
    await h.seal();
    final gate = Completer<void>();
    t.configGate = gate;
    t.configBody = {'etag': 'for-a', 'ttl_s': 600, 'full_dump': true, 'full_dump_ttl_s': 3600};
    h.setUser('A');
    await waitUntil(() => t.configRequests.length == 2);
    t.configBody = {'etag': 'for-b', 'ttl_s': 600};
    h.setUser('B');
    t.configGate = null;
    gate.complete();
    await waitUntil(() => t.configRequests.length >= 3);
    await h.settle();
    expect(t.configRequests.length, 3);
    expect(t.configRequests[1].headers['X-Rtv-User'], 'A');
    expect(t.configRequests[2].headers['X-Rtv-User'], 'B');
    final eff = await h.work((e) => e.effective);
    expect(eff.fullDumpActive, isFalse, reason: 'A 的 full_dump 没作用到 B');
    expect(eff.config.etag, 'for-b');
    expect(h.outboxFiles('p2').length, 0);
  });

  /// 身份变化的那一刻配置缓存按过期处理：上一个用户的 full_dump 立即回落，不等新响应（ADR 0019 决定 12）。
  test('identityChangeExpiresCachedConfigImmediately', () async {
    final t = FakeTransport()..configBody = {'etag': 'e0', 'ttl_s': 600};
    final h = await Harness.create(transport: t);
    await h.settle();
    t.configBody = {'etag': 'for-a', 'ttl_s': 600, 'full_dump': true, 'full_dump_ttl_s': 3600};
    h.setUser('A');
    await h.settle();
    expect(await h.work((e) => e.effective.fullDumpActive), isTrue);
    expect(h.client.effectiveLevels.$1, LogLevel.debug);
    final gate = Completer<void>();
    t.configGate = gate;
    try {
      h.setUser('B');
      await waitUntil(() => t.configRequests.last.headers['X-Rtv-User'] == 'B');
      final eff = await h.work((e) => e.effective);
      expect(eff.fullDumpActive, isFalse, reason: '新响应还没到，A 的放大型字段已回落');
      expect(eff.expired, isTrue);
      expect(h.client.effectiveLevels.$1, LogLevel.warn);
    } finally {
      t.configGate = null;
      gate.complete();
    }
    await h.settle();
  });

  /// 身份变化只回落放大上传的字段，不回落 local_cap_bytes；真正的 TTL 过期照旧回落到宿主默认并驱逐。
  test('setUserDoesNotEvictOnCapFallback', () async {
    const hostCap = Limits.localCapBytesMin;
    final t = FakeTransport()
      ..configBody = {'etag': 'big', 'ttl_s': 600, 'upload_enabled': false, 'local_cap_bytes': 2 * hostCap};
    final h = await Harness.create(
      transport: t,
      options: const RetrieverOptions(localCapBytes: hostCap),
    );
    await h.settle();
    expect(await h.work((e) => e.effective.config.localCapBytes), 2 * hostCap);
    // 伪随机内容（gzip 压不动）攒出超过宿主默认的义务批
    var seed = 7;
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    String noise() {
      final sb = StringBuffer();
      for (var i = 0; i < 3500; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        sb.write(alphabet[seed % alphabet.length]);
      }
      return sb.toString();
    }

    int boxBytes() => h.outboxFiles().fold(0, (a, n) => a + File('${h.outbox}/$n').lengthSync());
    while (boxBytes() < hostCap + hostCap ~/ 4) {
      for (var i = 0; i < 100; i++) {
        h.l(LogLevel.warn, noise());
      }
      await h.seal();
    }
    List<Map<String, Object?>> overflow() =>
        h.readJsonl('drops.jsonl').where((d) => d['reason'] == 'buffer_overflow').toList();
    expect(overflow(), isEmpty);
    final before = h.outboxFiles();
    final gate = Completer<void>();
    t.configGate = gate;
    try {
      h.setUser('b');
      await waitUntil(() => t.configRequests.last.headers['X-Rtv-User'] == 'b');
      final eff = await h.work((e) => e.effective);
      expect(eff.expired, isTrue, reason: '身份变了：其它放大型字段按过期处理');
      expect(eff.config.localCapBytes, 2 * hostCap, reason: '上限不随身份回落');
    } finally {
      t.configGate = null;
      gate.complete();
    }
    await h.settle();
    expect(h.outboxFiles(), before, reason: '一个批都没删');
    expect(overflow(), isEmpty);
    // 真正的 TTL 过期：上限回落宿主默认，照旧驱逐并记墓碑
    t.configBody = null;
    await h.tick(600000 + 1000);
    expect(await h.work((e) => e.effective.config.localCapBytes), hostCap);
    expect(overflow(), isNotEmpty);
    expect(h.outboxFiles().length, lessThan(before.length));
  });

  /// 恢复时墓碑写不进 drops.jsonl（同名目录：追加失败）：终态照写，但不打「已收尾」标记，下次启动重试收尾。
  test('recoveryTombstoneAppendFailureKeepsSessionOpen', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    for (var i = 1; i <= 3; i++) {
      h.l(LogLevel.warn, 'w$i');
    }
    final sid = h.client.writer.currentSessionId;
    final dir = h.sessionDir();
    await h.simulateCrash();
    // 抠掉 w2：恢复时 oseq 2 是缺口，要记 corrupt 墓碑
    final seg = File('$dir/seg-000001.open');
    seg.writeAsStringSync(seg.readAsStringSync().split('\n').where((l) => !l.contains('"msg":"w2"')).join('\n'));
    final drops = Directory('${h.root}/drops.jsonl')..createSync();

    final h2 = await Harness.create(root: h.root, key: '', clock: h.clock);
    await h2.settle();
    expect(h2.readJsonl('sessions.jsonl').where((c) => c['session_id'] == sid).length, 1, reason: '终态写成了');
    expect(h2.readJson('$dir/cursor.json').containsKey('closed_ms'), isFalse, reason: '墓碑没写成：不打已收尾');
    await h2.simulateCrash();

    drops.deleteSync();
    final h3 = await Harness.create(root: h.root, key: '', clock: h.clock);
    await h3.settle();
    expect(h3.readJson('$dir/cursor.json').containsKey('closed_ms'), isTrue, reason: '能写了：下次启动收尾');
    expect(h3.readJsonl('sessions.jsonl').where((c) => c['session_id'] == sid).length, 1, reason: '终态不重复');
  });

  /// 恢复时段文件读不出：不推进 cursor、不删会话目录、不写终态，下次启动重试（ADR 0019 决定 13）。
  test('unreadableSegmentKeepsSessionForRetry', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    for (var i = 1; i <= 3; i++) {
      h.l(LogLevel.warn, 'w$i');
    }
    final sid = h.client.writer.currentSessionId;
    final dir = h.sessionDir();
    final seg = File('$dir/seg-000001.open');
    final aside = '${h.root}/aside.open';
    await h.simulateCrash();
    seg.renameSync(aside);
    Directory(seg.path).createSync(); // 同名目录：读不出
    final cursorBefore = File('$dir/cursor.json').readAsBytesSync();

    final h2 = await Harness.create(root: h.root, key: '', clock: h.clock);
    await h2.settle();
    expect(Directory(dir).existsSync(), isTrue, reason: '会话目录还在');
    expect(File('$dir/cursor.json').readAsBytesSync(), cursorBefore, reason: 'cursor 没动');
    expect(h2.readJsonl('sessions.jsonl').length, 0);
    expect(h2.envelopes().any((e) => e['session_id'] == sid), isFalse);
    await h2.simulateCrash();

    // 段恢复可读：下次启动正常收尾
    Directory(seg.path).deleteSync();
    File(aside).renameSync(seg.path);
    final h3 = await Harness.create(root: h.root, key: '', clock: h.clock);
    await h3.settle();
    final covered =
        h3
            .envelopes()
            .where((e) => e['session_id'] == sid)
            .expand((e) => e.lines.where((l) => l.containsKey('oseq') && l['ctx'] != true).map((l) => int_(l['oseq'])))
            .toList()
          ..sort();
    expect(covered, [1, 2, 3, 4], reason: '3 行 warn + 合成 unclean_exit');
    expect(h3.readJsonl('sessions.jsonl').where((c) => c['session_id'] == sid).length, 1);
  });

  /// jsonl 追加写到一半失败：截回追加前的长度，下一条不会与半行粘连（ADR 0019 决定 5）。
  test('jsonlAppendFailureTruncatesBack', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    final sid = h.client.writer.currentSessionId;
    final d1 = DropEntry(sid, 1, 1, 1, 'corrupt', 1, -1);
    final d2 = DropEntry(sid, 2, 2, 1, 'corrupt', 2, -1);
    final d3 = DropEntry(sid, 3, 3, 1, 'corrupt', 3, -1);
    expect(await h.work((e) => e.appendDrops([d1])), isTrue);
    final before = File('${h.root}/drops.jsonl').readAsBytesSync();
    Fs.appendFaultForTesting = 10;
    try {
      expect(await h.work((e) => e.appendDrops([d2])), isFalse);
    } finally {
      Fs.appendFaultForTesting = null;
    }
    expect(File('${h.root}/drops.jsonl').readAsBytesSync(), before, reason: '截回追加前的长度');
    expect(await h.work((e) => e.appendDrops([d3])), isTrue);
    expect(h.readJsonl('drops.jsonl').map(DropEntry.decode).toList(), [d1, d3]);
    // sessions.jsonl 同一实现
    final c = ClosedSession(sid, 1, 1, 2, 3, 1, 'clean_bg');
    Fs.appendFaultForTesting = 5;
    try {
      expect(await h.work((e) => e.appendClosed([c])), isFalse);
    } finally {
      Fs.appendFaultForTesting = null;
    }
    final sf = File('${h.root}/sessions.jsonl');
    expect(sf.existsSync() ? sf.lengthSync() : 0, 0);
    await Fs.append(sf.path, Jsonl.encodeClosed([c]));
    expect(h.readJsonl('sessions.jsonl').length, 1);
  });
}
