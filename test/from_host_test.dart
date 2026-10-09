// 对位 Android FromHostTests.kt：缓存只记远程明确给的值（ADR 0022；简报 §2 / §11 K）。假服务端开回显模式。

import 'dart:async';
import 'dart:io';

import 'package:revdog_retriever/src/config.dart';
import 'package:revdog_retriever/src/json.dart';
import 'package:revdog_retriever/src/limits.dart';
import 'package:test/test.dart';

import 'support/support.dart';

int oseqOf(StaticHarness h, String msg) =>
    int_(sessionLines(h.currentSessionDir()).lastWhere((l) => l['msg'] == msg)['oseq']);

/// 上一次以 [first] 拉到缓存（未过期，回显）；这次 configure([second])，配置请求挂着不回。返回第二次的夹具。
Future<StaticHarness> cachedThenReconfigured(
  LogLevel first,
  LogLevel second, [
  Map<String, Object?> body = const {'etag': 'e', 'ttl_s': 1800},
]) async {
  final t = FakeTransport()
    ..echoHost = true
    ..configBody = body;
  final h = await StaticHarness.create(transport: t);
  await h.configure(demoKey, RetrieverOptions(uploadLevel: first));
  await h.settle();
  final cfg = JsonIn.obj(File('${h.root}/config.json').readAsBytesSync())!;
  expect(obj(cfg['config'])['upload_level'], body['upload_level'] ?? first.name, reason: '回显进了响应');
  final t2 = FakeTransport()
    ..echoHost = true
    ..configBody = body
    ..configGate = Completer<void>();
  final h2 = await h.restart(transport: t2);
  h2.log(LogLevel.info, 'before configure');
  await h2.configure(demoKey, RetrieverOptions(uploadLevel: second));
  h2.log(LogLevel.info, 'after configure');
  await h2.client.onWork(() {});
  return h2;
}

Future<void> release(StaticHarness h) async {
  h.transport.configGate?.complete();
  h.transport.configGate = null;
  await h.settle();
}

void main() {
  setUpRtv();

  test('k_cachedEchoDoesNotOverrideNewHostLevel', () async {
    final h = await cachedThenReconfigured(LogLevel.info, LogLevel.warn);
    expect(Retriever.uploadLevel, LogLevel.warn);
    expect(oseqOf(h, 'before configure'), -999, reason: 'configure 之前的 info 无 oseq');
    expect(oseqOf(h, 'after configure'), -999);
    await release(h);

    final h2 = await cachedThenReconfigured(LogLevel.warn, LogLevel.info);
    expect(Retriever.uploadLevel, LogLevel.info);
    expect(oseqOf(h2, 'before configure'), 1);
    expect(oseqOf(h2, 'after configure'), 2);
    await release(h2);
  });

  /// 远程明确给了 upload_level（不在 from_host 里）：不随宿主变。
  test('k_explicitRemoteValueStays', () async {
    final h = await cachedThenReconfigured(LogLevel.warn, LogLevel.info, {
      'etag': 'e',
      'ttl_s': 1800,
      'upload_level': 'error',
    });
    expect(Retriever.uploadLevel, LogLevel.error);
    expect(oseqOf(h, 'after configure'), -999);
    final cfg = JsonIn.obj(File('${h.root}/config.json').readAsBytesSync())!;
    expect(cfg['from_host'], ['local_level', 'local_cap_bytes', 'daily_batch_cap']);
    await release(h);
  });

  /// reconfigure 在宿主调用里同步生效：返回后立即写的行按新级别（引擎队列被堵住也成立）。
  test('k_reconfigureLevelsSyncEvenWhenEngineBlocked', () async {
    final h = await StaticHarness.create();
    await h.configure('');
    await h.settle();
    final gate = Completer<void>();
    final entered = Completer<void>();
    h.client.workAsync(() async {
      entered.complete();
      await gate.future;
    });
    await entered.future;
    try {
      h.log(LogLevel.info, 'warn level');
      Retriever.configure(
        '',
        baseUrl: base,
        options: const RetrieverOptions(uploadLevel: LogLevel.info),
      ).ignore();
      h.log(LogLevel.info, 'info level');
      final raw = readSegmentLines(h.client.debugOpenSegmentFile!).skip(1).map((l) => JsonIn.objText(l)!).toList();
      expect(raw.map((o) => int_(o['oseq'])).toList(), [-999, 1]);
      expect(Retriever.uploadLevel, LogLevel.info);
    } finally {
      gate.complete();
    }
    await h.settle();
  });

  /// 请求在途时宿主默认变了：响应按身份不符丢弃并重拉；缓存记的是新宿主默认那次的响应。
  test('k_inflightResponseForOldHostDiscarded', () async {
    final gate = Completer<void>();
    final t = FakeTransport()
      ..echoHost = true
      ..configBody = {'etag': 'e', 'ttl_s': 1800, 'full_dump': true, 'full_dump_ttl_s': 600}
      ..configGate = gate;
    final h = await StaticHarness.create(transport: t);
    await h.configure(demoKey, const RetrieverOptions(uploadLevel: LogLevel.warn));
    await waitUntil(() => t.configRequests.isNotEmpty);
    expect(t.configRequests.single.headers['X-Rtv-Upload-Level'], 'warn');
    await Retriever.configure(
      demoKey,
      baseUrl: base,
      options: const RetrieverOptions(uploadLevel: LogLevel.error),
    );
    t.configBody = {'etag': 'e2', 'ttl_s': 1800};
    t.configGate = null;
    gate.complete();
    await waitUntil(() => t.configRequests.length >= 2);
    await h.settle();
    expect(t.configRequests.length, 2);
    expect(t.configRequests[1].headers['X-Rtv-Upload-Level'], 'error');
    final eff = h.client.engine.effective;
    expect(eff.fullDumpActive, isFalse, reason: '旧宿主默认那次的响应（含 full_dump）没生效');
    expect(eff.config.etag, 'e2');
    expect(Retriever.uploadLevel, LogLevel.error);
  });

  /// golden `from_host[]` 回放：测试里的 hostDerivedFields 移植与服务端一致；SDK 生效配置对 from_host 字段取当前宿主值，其余取缓存。
  test('goldenFromHostReplay', () {
    final g = Repo.golden('config.json');
    final vs = objs(g['from_host']);
    expect(vs, isNotEmpty);
    const hostA = HostDefaults(LogLevel.info, LogLevel.info, 5, 3 * 1024 * 1024);
    const hostB = HostDefaults(LogLevel.error, LogLevel.warn, 77, 9 * 1024 * 1024);
    for (final v in vs) {
      final name = v['name'] as String;
      final expectF = [for (final x in v['expect'] as List) x as String];
      expect(hostDerivedFields(v['raw']), expectF, reason: name);
      final fromHost = ConfigRules.fromHost(expectF);
      expect(fromHost.toList(), expectF, reason: name);
      final cached = ConfigRules.clamp(v['raw'], hostA);
      final cache = ConfigCache(cached, 0, 0, fromHost: fromHost);
      for (final host in [hostA, hostB]) {
        final hc = ConfigRules.clamp(null, host);
        final e = ConfigCache.effective(cache, host, 0, 0).config;
        expect(e.uploadLevel, expectF.contains('upload_level') ? hc.uploadLevel : cached.uploadLevel, reason: name);
        expect(e.localLevel, expectF.contains('local_level') ? hc.localLevel : cached.localLevel, reason: name);
        expect(
          e.localCapBytes,
          expectF.contains('local_cap_bytes') ? hc.localCapBytes : cached.localCapBytes,
          reason: name,
        );
        expect(
          e.dailyBatchCap,
          expectF.contains('daily_batch_cap') ? hc.dailyBatchCap : cached.dailyBatchCap,
          reason: name,
        );
      }
    }
    // 缺省 / 非数组 / 未知名字：空集或只认已知字段
    expect(ConfigRules.fromHost(null), <String>{});
    expect(ConfigRules.fromHost('upload_level'), <String>{});
    expect(ConfigRules.fromHost(['bogus', 'local_level', 3.0]), {'local_level'});
    // clamp 的 local_cap_bytes 缺省 = 宿主值（对齐 packages/core）
    expect(ConfigRules.clamp(<String, Object?>{}, hostA).localCapBytes, 3 * 1024 * 1024);
    expect(
      ConfigRules.clamp(<String, Object?>{}, const HostDefaults(LogLevel.warn)).localCapBytes,
      Limits.localCapBytesDefault,
    );
  });
}
