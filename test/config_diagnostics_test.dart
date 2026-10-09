// 对位 Android ConfigDiagnosticsTests.kt：配置诊断（ADR 0025；简报 §13 V1–V9）。除 V1 外都走静态入口；出口换成记录
// (code, message, 是否在引擎队列上) 的 sink（测试结束复位、去重集合清空）。

import 'dart:async';
import 'dart:convert';

import 'package:revdog_retriever/src/config_check.dart';
import 'package:revdog_retriever/src/config_diagnostics.dart';
import 'package:revdog_retriever/src/ids.dart';
import 'package:revdog_retriever/src/limits.dart';
import 'package:revdog_retriever/src/model.dart';
import 'package:test/test.dart';

import 'support/support.dart';

// golden/apikey.json 里的假 key；拆开写，免得发布脚本的「真 key 形状」扫描把测试向量当成泄露
const testKey = 'lk_test_my_app-2_${'ffffffffffffffffffffffffffffffff'}_0456af9e';
const testKey2 = 'lk_test_ab_${'00000000000000000000000000000000'}_d7ae878c';
const liveKey = 'lk_live_bible-bff_${'0123456789abcdef0123456789abcdef'}_86381e7d';

/// 自定义主机（不判 env）。
const custom = 'http://127.0.0.1:8787';

class Diag {
  Diag(this.code, this.message, this.inEngine);

  final String code;
  final String message;
  final bool inEngine;
}

final List<Diag> got = <Diag>[];

List<String> get codes => got.map((d) => d.code).toList();

List<String> get rejected => got.where((d) => d.code == ConfigCheck.keyRejected).map((d) => d.message).toList();

Future<StaticHarness> harness([FakeTransport? t]) async {
  final h = await StaticHarness.create(transport: t);
  got.clear();
  ConfigDiagnostics.sink = (code, message) =>
      got.add(Diag(code, message, RetrieverRuntime.client?.inEngineQueue ?? false));
  return h;
}

Future<void> configure(String key, String baseUrl) async {
  await Retriever.configure(key, baseUrl: baseUrl);
}

Future<void> sealAndDrain(StaticHarness h) async {
  h.client.writer.rotate(SealReason.timer);
  await h.client.onWork(h.client.afterSeal);
  await h.settle();
}

Future<List<String>> pausedCategories(StaticHarness h) =>
    h.client.onWork(() => List<String>.of(h.client.engine.backoff.pausedCategories));

String rejectedMsg(int status, String reason, int minutes) =>
    'server rejected the key (HTTP $status, reason=$reason); uploads paused for $minutes min; logs are kept locally';

/// 消息绝不含 key 的任何部分。
void assertNoKeyLeak(List<String> keys) {
  for (final d in got) {
    expect(d.message.contains('lk_'), isFalse, reason: d.message);
    for (final k in keys) {
      for (final part in k.split('_').where((p) => p.length >= 6)) {
        expect(d.message.contains(part), isFalse, reason: '${d.message} ⊃ $part');
      }
    }
  }
}

void main() {
  setUpRtv();

  /// golden/apikey.json：`crc32[]` 逐条相等、`valid[]` 判合法（env 正确、不出任何 code）、`invalid[]` 判 `key_malformed`。
  test('v1_goldenApiKey', () {
    final g = Repo.golden('apikey.json');
    final crcs = objs(g['crc32']);
    expect(crcs, isNotEmpty);
    for (final v in crcs) {
      expect(ConfigCheck.crc32Hex(utf8.encode(v['text'] as String)), v['expect'], reason: '${v['source']}');
    }
    final valid = objs(g['valid']);
    expect(valid, isNotEmpty);
    for (final v in valid) {
      final k = v['key'] as String;
      expect(ConfigCheck.crc32Hex(utf8.encode(v['crc_input'] as String)), v['crc'], reason: '${v['name']}');
      expect(ConfigCheck.keyEnv(k), v['env'], reason: '${v['name']}');
      expect(ConfigCheck.check(k, k, custom), <String>[], reason: '${v['name']}');
    }
    final invalid = objs(g['invalid']);
    expect(invalid, isNotEmpty);
    for (final v in invalid) {
      final k = v['key'] as String;
      expect(ConfigCheck.keyEnv(k), isNull, reason: '${v['name']}');
      // 空 key 按第 1 条出 no_key（此时不再判 2–4）
      expect(
        ConfigCheck.check(k, k, custom),
        k.isEmpty ? [ConfigCheck.noKey] : [ConfigCheck.keyMalformed],
        reason: '${v['name']}',
      );
    }
    // baseUrl 判定（Uri.tryParse；scheme ∈ {http, https} 不分大小写、host 非空）
    expect(ConfigCheck.check(testKey, testKey, 'HTTP://127.0.0.1:1'), <String>[]);
    expect(ConfigCheck.check(testKey, testKey, 'https://'), [ConfigCheck.baseUrlInvalid]);
    expect(ConfigCheck.check(testKey, testKey, 'mailto:x@y'), [ConfigCheck.baseUrlInvalid]);
  });

  /// key 首部空格、尾部 `\n`，baseUrl 尾部空格：请求头是修剪后的 key、端点无空白、上传成功，`key_trimmed` 出一次。
  test('v2_trimmedKeyAndBaseUrl', () async {
    final h = await harness();
    await configure(' $testKey\n', '$base  ');
    await h.settle();
    expect(codes, [ConfigCheck.keyTrimmed]);
    expect(got[0].message, 'key had leading or trailing whitespace; it was trimmed');
    expect(h.client.engine.keyFp, Ids.keyFingerprint(testKey));
    h.log(LogLevel.warn, 'w');
    await sealAndDrain(h);
    final req = h.transport.batchRequests.single;
    expect(req.headers['Authorization'], 'Bearer $testKey');
    expect(req.url, '$base/v1/batches');
    expect(
      h.transport.configRequests.every(
        (r) => r.url == '$base/v1/config' && r.headers['Authorization'] == 'Bearer $testKey',
      ),
      isTrue,
    );
    expect(h.outboxFiles(), isEmpty, reason: '已确认');
    // 同参数判定也用修剪后的值：换一种空白写法的重复 configure 是空操作（零请求），也不重复出诊断
    final n = h.transport.requests.length;
    await configure('　$testKey\t\u0085', ' $base ');
    await h.settle();
    expect(h.transport.requests.length, n);
    expect(codes, [ConfigCheck.keyTrimmed]);
    assertNoKeyLeak([testKey]);
  });

  /// 畸形 key：出 `key_malformed`，同参数再 configure 不重复出；请求照发，假服务端回 401 + reason → 再出 `key_rejected`。
  test('v3_malformedKeyStillSent', () async {
    final t = FakeTransport();
    final h = await harness(t);
    const bad = 'lk_test_demo_abc_12345678';
    await configure(bad, base);
    await h.settle();
    expect(codes, [ConfigCheck.keyMalformed]);
    expect(got[0].message, 'key is not a valid Retriever key (format or checksum mismatch); the server will reject it');
    await configure(bad, base);
    await h.settle();
    expect(codes, [ConfigCheck.keyMalformed], reason: '同参数不重复出');
    t.defaultReply = Reply.status(401, {'reason': 'key_invalid'});
    h.log(LogLevel.warn, 'w');
    await sealAndDrain(h);
    expect(t.batchRequests.single.headers['Authorization'], 'Bearer $bad', reason: '只出诊断不拦请求');
    expect(codes, [ConfigCheck.keyMalformed, ConfigCheck.keyRejected]);
    expect(got[1].message, rejectedMsg(401, 'key_invalid', 60));
    assertNoKeyLeak([bad]);
  });

  /// 空 key：出 `no_key`、零联网、本地照写；纯空白（修剪后为空）同样只是 `no_key`（不另出 `key_trimmed`）。
  test('v4_noKey', () async {
    final h = await harness();
    await configure('', base);
    h.log(LogLevel.error, 'e');
    expect(sessionLines(h.currentSessionDir()).any((l) => l['msg'] == 'e'), isTrue, reason: '本地照写');
    await sealAndDrain(h);
    h.clock.advance(60000);
    await h.client.tickNow();
    expect(codes, [ConfigCheck.noKey]);
    expect(got[0].message, 'no key configured; logs are written locally and never uploaded');
    expect(h.transport.requests.length, 0, reason: '零联网');
    expect(h.outboxFiles().length, 1, reason: '封段照常物化进出站箱');
    // 同一（no_key, 空指纹, baseUrl）：不重复
    await configure(' \n\t', base);
    expect(codes, [ConfigCheck.noKey]);
    // 换 baseUrl = 新的去重键：再出一次，纯空白 key 仍不出 key_trimmed
    await configure(' \n', custom);
    await h.settle();
    expect(codes, [ConfigCheck.noKey, ConfigCheck.noKey]);
    expect(h.transport.requests.length, 0);
  });

  /// `key_env_mismatch`：test key + 生产地址、live key + staging 地址各出一次（主机不分大小写）；方向对的与自定义主机不出。
  test('v5_envMismatch', () async {
    final h = await harness();
    await configure(testKey, 'https://logs.revdog.org');
    expect(codes, [ConfigCheck.keyEnvMismatch]);
    expect(
      got[0].message,
      'key environment does not match the endpoint (test key with production endpoint, or live key with staging endpoint); the server will reject it',
    );
    await configure(liveKey, 'https://logs-staging.revdog.org/');
    expect(codes, [ConfigCheck.keyEnvMismatch, ConfigCheck.keyEnvMismatch]);
    await configure(testKey, 'HTTPS://LOGS.REVDOG.ORG');
    expect(codes.where((c) => c == ConfigCheck.keyEnvMismatch).length, 3);
    // 方向对的、自定义主机：不出
    await configure(liveKey, 'https://logs.revdog.org');
    await configure(testKey, 'https://logs-staging.revdog.org');
    await configure(testKey, custom);
    await configure(liveKey, custom);
    await h.settle();
    expect(codes, [ConfigCheck.keyEnvMismatch, ConfigCheck.keyEnvMismatch, ConfigCheck.keyEnvMismatch]);
    assertNoKeyLeak([testKey, liveKey]);
    // 主机按 URL 的主机判（与 scheme 是否合法无关），顺序固定：4 在 5 之前
    expect(ConfigCheck.check(testKey, testKey, 'ftp://logs.revdog.org'), [
      ConfigCheck.keyEnvMismatch,
      ConfigCheck.baseUrlInvalid,
    ]);
    expect(ConfigCheck.check('$testKey\n', testKey, 'https://logs.revdog.org/v1'), [
      ConfigCheck.keyTrimmed,
      ConfigCheck.keyEnvMismatch,
    ]);
  });

  /// `base_url_invalid`：缺 scheme、`ftp://x`、空串各出一次（重复 configure 不重复）；`http://127.0.0.1:<port>` 不出。
  test('v6_baseUrlInvalid', () async {
    final h = await harness();
    for (final b in ['logs.revdog.org', 'ftp://x', '']) {
      await configure(testKey, b);
      await configure(testKey, b);
    }
    await h.settle();
    expect(codes, [ConfigCheck.baseUrlInvalid, ConfigCheck.baseUrlInvalid, ConfigCheck.baseUrlInvalid]);
    expect(got[0].message, 'baseUrl is not a valid http(s) URL; uploads will fail');
    // 纯空白 = 修剪后的空串：同一去重键，不再出
    await configure(testKey, '  \n');
    await configure(testKey, custom);
    await h.settle();
    expect(codes.length, 3);
    expect(h.client.engine.baseUrl, custom);
  });

  /// 401 带 reason → `key_rejected`（状态码 / reason / 分钟数），不在引擎队列上出；同 key 第二次暂停（403，倍增）不重复；
  /// 401 无 reason（HTML 体）不出。
  test('v7_keyRejectedOncePerKey', () async {
    final t = FakeTransport();
    final h = await harness(t);
    await configure(testKey, base);
    await h.settle();
    t.setScript([Reply.raw(401, utf8.encode('<html><body>Access denied</body></html>'))]);
    h.log(LogLevel.warn, 'w1');
    await sealAndDrain(h);
    expect(t.batchRequests.length, 1);
    expect(rejected, isEmpty, reason: 'HTML 401 不暂停、不出');
    expect(await pausedCategories(h), isEmpty);

    t.setScript([
      Reply.status(401, {'reason': 'key_revoked'}),
    ]);
    h.clock.advance(5000);
    await h.client.tickNow();
    expect(t.batchRequests.length, 2);
    expect(await pausedCategories(h), ['all']);
    expect(rejected, [rejectedMsg(401, 'key_revoked', 60)]);
    final d = got.singleWhere((x) => x.code == ConfigCheck.keyRejected);
    expect(d.inEngine, isFalse, reason: '在排空任务里出，不在引擎队列上');

    // 暂停到期后同 key 再被拒（403，暂停倍增到 120 min）：仍在暂停，但不重复出
    t.setScript([
      Reply.status(403, {'reason': 'app_disabled'}),
    ]);
    h.clock.advance(Limits.pause401BaseMs + 1000);
    await h.client.tickNow();
    expect(t.batchRequests.length, 3);
    expect(await pausedCategories(h), ['all']);
    expect(rejected.length, 1);
    assertNoKeyLeak([testKey]);
  });

  /// 旧 key 在途请求的 401（带 reason）：不暂停新 key，也不出 `key_rejected`。
  test('v7_inflight401ForOldKeyNotReported', () async {
    final t = FakeTransport();
    final h = await harness(t);
    await configure(testKey, base);
    await h.settle();
    final gate = Completer<void>();
    t.setScript([
      Reply.gated(gate, Reply.status(401, {'reason': 'key_revoked'})),
    ]);
    h.log(LogLevel.warn, 'w');
    h.client.writer.rotate(SealReason.timer);
    h.client.onWork(h.client.afterSeal).ignore();
    await waitUntil(() => t.batchRequests.isNotEmpty);
    await configure(testKey2, base);
    await h.client.onWork(() {});
    gate.complete();
    await h.settle();
    expect(rejected, isEmpty);
    expect(await pausedCategories(h), isEmpty);
    h.clock.advance(3000);
    await h.client.tickNow();
    expect(h.outboxFiles(), isEmpty);
    expect(t.batchRequests.last.headers['Authorization'], 'Bearer $testKey2');
    expect(rejected, isEmpty);
  });

  /// reason 清洗：只留 `[a-z0-9_]`（大写、空格、非 ASCII 去掉）、最多 40 字符、清洗后为空 = `unknown`。
  test('v8_reasonSanitized', () async {
    final t = FakeTransport();
    final h = await harness(t);
    final cases = <(String, String)>[
      ('Key_Invalid', 'ey_nvalid'),
      ('key invalid now', 'keyinvalidnow'),
      ('${'a' * 30}_${'b' * 30}', '${'a' * 30}_${'b' * 9}'),
      ('!! -- ÄÖ 中文 \n', 'unknown'),
      ('', 'unknown'),
    ];
    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      // 每例换一个 key：换 key 清掉上一例的暂停，（code, 指纹, baseUrl）也是新的
      await configure('lk_test_v8_case_$i', base);
      await h.settle();
      t.setScript([
        Reply.status(401, {'reason': c.$1}),
      ]);
      h.log(LogLevel.warn, 'w$i');
      h.clock.advance(3000);
      await sealAndDrain(h);
      expect(rejected.length, i + 1, reason: c.$1);
      expect(rejected.last, rejectedMsg(401, c.$2, 60), reason: c.$1);
      expect(ConfigCheck.sanitizeReason(c.$1), c.$2, reason: c.$1);
    }
    // 分钟数向上取整
    expect(ConfigCheck.rejectedMessage(403, 'x', 60001), rejectedMsg(403, 'x', 2));
    expect(ConfigCheck.rejectedMessage(403, 'x', Limits.pause401MaxMs), rejectedMsg(403, 'x', 1440));
  });

  /// 出口抛异常（sink 抛 Error）：configure 不抛、实例照建、修剪照做、两条诊断都尝试过；`key_rejected` 时抛也不打断排空。
  test('v9_sinkThrowsSwallowed', () async {
    final t = FakeTransport();
    final h = await harness(t);
    var calls = 0;
    ConfigDiagnostics.sink = (_, _) {
      calls++;
      throw StateError('sink boom');
    };
    await configure(' lk_bad\n', base);
    expect(RetrieverRuntime.client, isNotNull);
    await h.settle();
    expect(calls, 2, reason: 'key_trimmed + key_malformed 都尝试过');
    expect(h.client.engine.key, 'lk_bad');
    t.setScript([
      Reply.status(401, {'reason': 'key_invalid'}),
    ]);
    h.log(LogLevel.warn, 'w');
    await sealAndDrain(h);
    expect(calls, 3);
    expect(t.batchRequests.single.headers['Authorization'], 'Bearer lk_bad');
    expect(await pausedCategories(h), ['all']);
    // 排空没被出口打断：换成合法 key 后照常上传
    await configure(testKey, base);
    h.clock.advance(3000);
    await h.client.tickNow();
    expect(h.outboxFiles(), isEmpty);
    expect(t.batchRequests.last.headers['Authorization'], 'Bearer $testKey');
    expect(calls, 3);
  });

  /// 默认出口经垫片 `diagnose(code, message)`（v3 §1 §13）；configure 一进来就发，与 bootstrap 结果无关。
  test('v10_defaultSinkGoesThroughPlatformDiagnose', () async {
    final h = await StaticHarness.create();
    h.platform.bootstrapMode = CallMode.fail;
    await configure('', base);
    await pump();
    expect(h.platform.diagnoses.map((d) => d.$1).toList(), [ConfigCheck.noKey]);
    expect(h.platform.diagnoses.single.$2, 'no key configured; logs are written locally and never uploaded');
    expect(RetrieverRuntime.state, RetrieverState.failed);
  });
}
