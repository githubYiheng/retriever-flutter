// 对位 Android GoldenTests.kt：golden 向量（packages/core/golden）三端与服务端逐字一致。

import 'package:revdog_retriever/src/config.dart';
import 'package:revdog_retriever/src/ids.dart';
import 'package:revdog_retriever/src/json.dart';
import 'package:revdog_retriever/src/limits.dart';
import 'package:revdog_retriever/src/line_encoder.dart';
import 'package:revdog_retriever/src/model.dart';
import 'package:test/test.dart';

import 'support/support.dart';

void main() {
  test('idsUuidv5', () {
    final g = Repo.golden('ids.json');
    expect(g['retriever_namespace'], Ids.namespace);
    final vs = objs(g['uuidv5']);
    expect(vs, isNotEmpty);
    for (final v in vs) {
      expect(Ids.uuidv5(v['namespace'] as String, v['name'] as String), v['expect'], reason: '${v['name']}');
    }
  });

  test('idsBatchId', () {
    final g = Repo.golden('ids.json');
    for (final v in objs(g['batch_id'])) {
      final kind = BatchKind.of(v['kind'] as String)!;
      final n = int_(v['n']);
      final iid = v['install_id'] as String;
      final sid = v['session_id'] as String;
      expect(Ids.batchIdName(iid, sid, kind, n), v['name']);
      expect(Ids.batchId(iid, sid, kind, n), v['expect']);
    }
    for (final v in objs(g['batch_id_invalid'])) {
      final kind = BatchKind.of(v['kind'] as String)!;
      // n 非整数（1.5）在 int 接口里不可表达：同样视为拒绝
      final n = JsonIn.int64(v['n']);
      if (n == null) continue;
      expect(Ids.batchId(v['install_id'] as String, v['session_id'] as String, kind, n), isNull, reason: '${v['why']}');
    }
  });

  test('backfillSplitBatchIdName', () {
    const iid = '3f2c9a4e-8b1d-4c7a-9e5f-0a1b2c3d4e5f';
    const sid = '7c9e6679-7425-40de-944b-e07fc1f90ae7';
    final bid = Ids.backfillSplitBatchId(iid, sid, 3, 1201);
    expect(bid, Ids.uuidv5(Ids.namespace, '$iid:$sid:backfill:3:1201'));
    expect(bid, isNot(Ids.batchId(iid, sid, BatchKind.backfill, 3)));
    expect(Ids.isUuid(bid!), isTrue);
    expect(Ids.backfillSplitBatchId(iid.toUpperCase(), sid, 3, 1), isNull);
  });

  test('idsSplitBatchId', () {
    final g = Repo.golden('ids.json');
    final vs = objs(g['split_batch_id']);
    expect(vs, isNotEmpty);
    for (final v in vs) {
      final iid = v['install_id'] as String;
      final sid = v['session_id'] as String;
      final from = int_(v['oseq_from']);
      final to = int_(v['oseq_to']);
      expect(Ids.splitBatchIdName(iid, sid, from, to), v['name']);
      expect(Ids.splitBatchId(iid, sid, from, to), v['expect'], reason: '${v['name']}');
      expect(Ids.splitBatchId(iid, sid, from, to), isNot(Ids.batchId(iid, sid, BatchKind.primary, from)));
    }
    final iid = vs[0]['install_id'] as String;
    final sid = vs[0]['session_id'] as String;
    expect(Ids.splitBatchId(iid, sid, 0, 3), isNull);
    expect(Ids.splitBatchId(iid, sid, 4, 3), isNull);
    expect(Ids.splitBatchId(iid.toUpperCase(), sid, 1, 3), isNull);
  });

  /// 整数 attrs（ADR 0020 决定 3，golden attrs.json）：|v| ≤ 2^53 − 1 → JSON 数字，否则十进制字符串，不打 truncated。
  /// Dart 的整数型：int（64 位）与 BigInt；每个向量按它装得下的类型各跑一遍（fits = big 只有 BigInt）。
  test('attrsIntegers', () {
    final g = Repo.golden('attrs.json');
    expect(g['max_safe_integer'], '9007199254740991');
    final vs = objs(g['int_attr']);
    expect(vs.length, greaterThanOrEqualTo(10));
    for (final v in vs) {
      final big = BigInt.parse(v['value'] as String);
      final forms = <Object>[big];
      if (v['fits'] == 'int64') {
        expect(big.bitLength < 64, isTrue);
        forms.add(big.toInt());
      } else {
        expect(v['fits'], 'big');
      }
      for (final x in forms) {
        final (json, truncated) = LineEncoder.encodeAttrs({'v': x});
        expect(String.fromCharCodes(json!), '{"v":${v['json']}}', reason: '${x.runtimeType} ${v['value']}');
        expect(truncated, isFalse);
      }
    }
    // double 仍按 JS 数字格式
    expect(String.fromCharCodes(LineEncoder.encodeAttrs({'v': 1.5}).$1!), '{"v":1.5}');
    expect(String.fromCharCodes(LineEncoder.encodeAttrs({'v': 9007199254740992.0}).$1!), '{"v":9007199254740992}');
  });

  test('idsUuidRegex', () {
    final g = Repo.golden('ids.json');
    for (final s in g['uuid_valid'] as List) {
      expect(Ids.isUuid(s as String), isTrue, reason: s);
    }
    for (final v in objs(g['uuid_invalid'])) {
      expect(Ids.isUuid(v['value'] as String), isFalse, reason: '${v['why']}');
    }
    // 新生成的 v4 必须过 UUID_RE
    for (var i = 0; i < 100; i++) {
      expect(Ids.isUuid(Ids.newV4()), isTrue);
    }
  });

  test('clientDay', () {
    final g = Repo.golden('object-key.json');
    final vs = objs(g['client_day']);
    expect(vs, isNotEmpty);
    for (final v in vs) {
      expect(Day.clientDay(int_(v['ts_min_ms']), int_(v['created_ms'])), v['expect'], reason: '${v['name']}');
    }
    for (final v in objs(g['day_from_ms'])) {
      expect(Day.fromMs(int_(v['ms'])), v['expect']);
    }
    // 负数也按 floor（1969-12-31）
    expect(Day.fromMs(-1), '1969-12-31');
  });

  test('configClamp', () {
    final g = Repo.golden('config.json');
    final vs = objs(g['clamp']);
    expect(vs.length, greaterThanOrEqualTo(55));
    expect(vs.where((v) => obj(v['host']).containsKey('localCapBytes')).length, greaterThanOrEqualTo(5));
    for (final v in vs) {
      final name = v['name'] as String;
      final h = obj(v['host']);
      final host = HostDefaults(
        LogLevels.ofWire(h['uploadLevel'] as String?) ?? LogLevel.warn,
        LogLevels.ofWire(h['localLevel'] as String?),
        JsonIn.int64(h['dailyBatchCap']),
        ConfigRules.clampInt(
          JsonIn.dbl(h['localCapBytes']),
          Limits.localCapBytesMin,
          Limits.localCapBytesMax,
          Limits.localCapBytesDefault,
        ),
      );
      final c = ConfigRules.clamp(v['raw'], host);
      final e = obj(v['expect']);
      expect(c.etag, e['etag'], reason: name);
      expect(c.ttlS, int_(e['ttl_s']), reason: name);
      expect(c.uploadEnabled, e['upload_enabled'], reason: name);
      expect(c.uploadLevel.wire, e['upload_level'], reason: name);
      expect(c.localLevel.wire, e['local_level'], reason: name);
      expect(c.contextLines, int_(e['context_lines']), reason: name);
      expect(c.contextBytes, int_(e['context_bytes']), reason: name);
      expect(c.flushIntervalS, int_(e['flush_interval_s']), reason: name);
      expect(c.localCapBytes, int_(e['local_cap_bytes']), reason: name);
      expect(c.fullDump, e['full_dump'], reason: name);
      expect(c.fullDumpTtlS, int_(e['full_dump_ttl_s']), reason: name);
      expect(c.dailyBatchCap, int_(e['daily_batch_cap']), reason: name);
      expect(e.keys.length, 12, reason: name);
      // 缓存文件往返：encode 后再 clamp 得到同一份
      expect(ConfigRules.clamp(JsonIn.obj(ConfigRules.encode(c)), host), c, reason: name);
    }
  });

  /// 缓存过期后放大型字段回落（宪法 U-2）。
  test('expiredCacheRevertsAmplifyingFields', () {
    const host = HostDefaults(LogLevel.warn);
    final raw = <String, Object?>{
      'ttl_s': 60.0,
      'upload_level': 'debug',
      'context_lines': 500.0,
      'context_bytes': 262144.0,
      'flush_interval_s': 30.0,
      'full_dump': true,
      'full_dump_ttl_s': 3600.0,
      'local_cap_bytes': 104857600.0,
    };
    final cfg = ConfigRules.clamp(raw, host);
    final cache = ConfigCache(cfg, 0, 1000);
    final live = ConfigCache.effective(cache, host, 0, 1000 + 59000);
    expect(live.fullDumpActive, isTrue);
    expect(live.uploadLevel, LogLevel.debug);
    expect(live.config.contextLines, 500);
    final exp = ConfigCache.effective(cache, host, 0, 1000 + 60000);
    expect(exp.fullDumpActive, isFalse);
    expect(exp.uploadLevel, LogLevel.warn);
    expect(exp.config.contextLines, Limits.ctxLinesDefault);
    expect(exp.config.contextBytes, Limits.ctxBytesDefault);
    expect(exp.config.flushIntervalS, Limits.flushIntervalSDefault);
    expect(exp.config.localCapBytes, Limits.localCapBytesDefault);
    // 重启后（无单调基准）用墙钟兜底
    final cold = ConfigCache(cfg, 5000, null);
    expect(ConfigCache.effective(cold, host, 5000 + 30000, 0).fullDumpActive, isTrue);
    expect(ConfigCache.effective(cold, host, 5000 + 61000, 0).fullDumpActive, isFalse);
    raw['upload_level'] = 'error';
    final quiet = ConfigCache(ConfigRules.clamp(raw, host), 0, 0);
    // 高于宿主默认（更少上传）的级别过期后不回落（只回落放大型）
    expect(ConfigCache.effective(quiet, host, 0, 999999).uploadLevel, LogLevel.error);
  });

  /// Flutter 口径（v2 §2.1）：本进程拉到的缓存按「单调或墙钟任一到期」回落——Android 上 Dart 的单调钟不含深睡眠。
  test('flutterAmplifyingFieldsExpireOnEitherClock', () {
    const host = HostDefaults(LogLevel.warn);
    final cfg = ConfigRules.clamp({'ttl_s': 60.0, 'full_dump': true, 'full_dump_ttl_s': 600.0}, host);
    final cache = ConfigCache(cfg, 0, 1000);
    // 单调钟只走了 10 s（深睡眠不计），墙钟走了 2 min：按墙钟到期回落
    final e = ConfigCache.effective(cache, host, 120000, 1000 + 10000);
    expect(e.expired, isTrue);
    expect(e.fullDumpActive, isFalse);
  });

  /// JS Number::toString 格式（attrs 数字）。Dart 的 double.toString 是最短往返：5e-324 也一致。
  test('jsNumberFormatting', () {
    final cases = <double, String>{
      0.0: '0',
      -0.0: '0',
      1.0: '1',
      -5.0: '-5',
      0.1: '0.1',
      123.456: '123.456',
      1e21: '1e+21',
      1e20: '100000000000000000000',
      1.5e-7: '1.5e-7',
      1e-7: '1e-7',
      0.000001: '0.000001',
      double.parse('123456789012345680000'): '123456789012345680000',
      double.parse('9007199254740993'): '9007199254740992',
      2.5e300: '2.5e+300',
      -1.25: '-1.25',
      5e-324: '5e-324',
    };
    cases.forEach((d, s) => expect(JsonOut.jsNumber(d), s, reason: '$d'));
  });

  test('jsonParserStrictness', () {
    expect(JsonIn.parse('{"a":1} x'), same(JsonIn.invalid));
    expect(JsonIn.parse('{"a":01}'), same(JsonIn.invalid));
    expect(JsonIn.parse('{"a":"\n"}'), same(JsonIn.invalid));
    final o = JsonIn.objText(r'{"a":1,"a":2,"s":"日🐶","n":null,"b":false,"l":[1.5,-2e3]}')!;
    expect(o['a'], 2.0);
    expect(o['s'], '日🐶');
    expect(o.containsKey('n'), isTrue);
    expect(o['n'], isNull);
    expect(o['b'], false);
    expect(o['l'], [1.5, -2000.0]);
    expect(JsonIn.int64(1.5), isNull);
    expect(JsonIn.int64(9007199254740992.0), isNull);
    expect(JsonIn.int64(9007199254740991.0), 9007199254740991);
  });
}
