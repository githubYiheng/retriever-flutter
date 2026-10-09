// 对位 Android EnvelopeCrossLangTests.kt：跨语言信封校验——Dart 物化出的 ≥ 6 种批（原始字节）都要过 packages/core 的
// validateEnvelope（服务端同一份代码；`npx --no-install tsx packages/core/scripts/validate-envelope.ts`）。

import 'package:revdog_retriever/src/limits.dart';
import 'package:revdog_retriever/src/model.dart';
import 'package:test/test.dart';

import 'support/support.dart';

class Expect {
  Expect(this.name, this.env, this.lines, this.errors, this.warn);

  final String name;
  final Env env;
  final int lines;
  final int errors;
  final bool warn;
}

const _rank = {'debug': 0, 'info': 1, 'warn': 2, 'error': 3, 'fatal': 4};

Expect expectOf(String name, Env env) {
  final ls = env.lines;
  final errors = ls.where((l) => (_rank[l['level']] ?? 0) >= 3 && l['ctx'] != true).length;
  final warn = ls.any((l) => (_rank[l['level']] ?? 0) >= 2);
  return Expect(name, env, ls.length, errors, warn);
}

class Boom implements Exception {
  @override
  String toString() => 'Boom: boom';
}

void main() {
  setUpRtv();

  test('materializedBatchesPassServerValidator', () async {
    final cases = <Expect>[];

    // 1. 纯 warn（attrs 各种值、CJK + emoji）
    {
      final h = await Harness.create(key: '');
      await h.settle();
      h.l(LogLevel.info, 'i');
      h.l(LogLevel.warn, 'w1', tag: 'net', attrs: {'ms': 3200, 'ok': false, 'u': '/v1', 'ratio': 0.25, 'none': null});
      h.l(LogLevel.warn, 'w2 日志🐶');
      await h.seal();
      final e = h.envelopes().first;
      expect(e.lines.length, 2);
      expect(e['ctx_truncated'], isNull);
      cases.add(expectOf('pure_warn', e));
    }

    // 2 / 3. error 带 ctx 跨段；ctx 被字节预算截断
    {
      final h = await Harness.create(key: '');
      await h.settle();
      while (h.client.writer.snapshot.segNo == 1) {
        h.l(LogLevel.debug, 'old ${'o' * 2000}');
      }
      for (var i = 0; i < 10; i++) {
        h.l(LogLevel.info, 'new $i');
      }
      h.l(LogLevel.error, 'failed', tag: 'billing', error: Boom(), st: StackTrace.current);
      await h.tick(2000);
      final e = h.envelopes('p0').first;
      final ctx = e.lines.where((l) => l['ctx'] == true).toList();
      expect(ctx.length, greaterThan(10), reason: '跨段');
      expect(ctx.length, lessThan(Limits.ctxLinesDefault), reason: '字节预算先到');
      expect(int_(e['ctx_truncated']), greaterThan(0));
      expect(ctx.fold<int>(0, (a, l) => a + toJson(l).length + 1), lessThanOrEqualTo(Limits.ctxBytesDefault + 2000));
      cases.add(expectOf('error_ctx_cross_segment_truncated', e));
    }

    // 4. drops / closed_sessions / mapping（旧会话恢复 + 墓碑 + 映射）
    {
      final root = tempDir();
      final a = await Harness.create(root: root, key: '');
      await a.settle();
      a.l(LogLevel.info, 'before crash');
      a.l(LogLevel.warn, 'a warn');
      final aSid = a.client.writer.currentSessionId;
      await a.work((e) => e.appendDrops([DropEntry(aSid, 7, 9, 3, 'buffer_overflow', 1, 86400000)]));
      await a.simulateCrash();
      final b = await Harness.create(root: root, key: ''); // 同一 root 再启动：a 的会话成了孤儿（last_state = fg）
      await b.settle();
      b.setUser('u_1024');
      b.l(LogLevel.warn, 'b warn');
      await b.seal();
      final envs = b.envelopes();
      // 墓碑 7..9 高于盘上最大 oseq 1：恢复按墓碑续编，2..6 记 corrupt，合成行 oseq = 10 与 1 不相接 → 两批
      final recs = envs.where((e) => e['session_id'] == aSid).toList();
      expect(recs.length, 2);
      final rec = recs.singleWhere((e) => e.map.containsKey('closed_sessions'));
      final closedA = objs(rec['closed_sessions']).first;
      expect(closedA['exit'], 'unclean_fg');
      expect(int_(closedA['last_oseq']), 10);
      expect(objs(rec['drops']).map((d) => (d['reason'], int_(d['oseq_from']))).toList(), [
        ('buffer_overflow', 7),
        ('corrupt', 2),
      ]);
      expect(rec['mapping'], isNull, reason: '旧会话批不带 mapping');
      final synth = recs.singleWhere((e) => !identical(e, rec));
      expect(synth.lines.any((l) => l['synthetic'] == true && int_(l['oseq']) == 10), isTrue);
      expect(synth['mapping'], isNull);
      final cur = envs.firstWhere((e) => e['session_id'] != aSid);
      expect(obj(cur['mapping'])['user_id'], 'u_1024');
      expect(cur['user_id'], 'u_1024');
      expect(obj(cur['device'])['os'], 'android');
      expect(obj(cur['device'])['sdk'], 'retriever-flutter/${RetrieverVersion.current}');
      cases.add(expectOf('recovered_with_drops_closed', rec));
      cases.add(expectOf('recovered_unclean_exit', synth));
      cases.add(expectOf('with_mapping', cur));
    }

    // 5. 413 切分后的两半
    {
      final h = await Harness.create();
      await h.settle();
      h.transport.setScript([
        Reply.status(413, {'reason': 'too_large', 'max_bytes': 1048576}),
      ]);
      h.transport.defaultReply = Reply.status(503);
      h.l(LogLevel.debug, 'ctx');
      for (var i = 1; i <= 5; i++) {
        h.l(LogLevel.warn, 'w$i');
      }
      await h.sealAndDrain();
      final halves = h.envelopes()..sort((a, b) => int_(a['oseq_from']).compareTo(int_(b['oseq_from'])));
      expect(halves.length, 2);
      expect(int_(halves[1]['oseq_from']), int_(halves[0]['oseq_to']) + 1);
      cases.add(expectOf('split_413_a', halves[0]));
      cases.add(expectOf('split_413_b', halves[1]));
    }

    // 6. backfill（full_dump 生效）
    {
      final h = await Harness.create(key: '');
      await h.settle();
      for (var i = 0; i < 20; i++) {
        h.l(i.isEven ? LogLevel.debug : LogLevel.info, 'history $i');
      }
      h.l(LogLevel.warn, 'w');
      await h.seal();
      h.transport.configBody = {'etag': 'e1', 'ttl_s': 600, 'full_dump': true, 'full_dump_ttl_s': 3600};
      h.transport.defaultReply = Reply.status(503); // 不确认，批留在出站箱里供检查
      await h.enableUpload();
      final bf = h.envelopes('p2').first;
      expect(bf['kind'], 'backfill');
      expect(bf['oseq_from'], isNull);
      expect(bf.lines.length, 20);
      expect(bf.lines.every((l) => !l.containsKey('oseq') && !l.containsKey('ctx')), isTrue);
      // 生效后新写的 debug 行直接是义务行
      h.l(LogLevel.debug, 'now obligation');
      expect(h.client.debugCounters.$2, 2);
      cases.add(expectOf('backfill', bf));
    }

    // 7. fatal（只落盘）
    {
      final h = await Harness.create(key: '');
      await h.settle();
      h.l(LogLevel.info, 'last words');
      h.l(LogLevel.fatal, 'fatal', error: StateError('D'));
      await h.settle();
      cases.add(expectOf('fatal', h.envelopes('p0').first));
    }

    expect(cases.length, greaterThanOrEqualTo(6));
    final results = await runValidator(cases.map((c) => c.env).toList());
    expect(results.length, cases.length);
    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      final r = results[i];
      expect(r['ok'], true, reason: '${c.name}: $r');
      final st = obj(r['stats']);
      expect(int_(st['lines']), c.lines, reason: c.name);
      expect(int_(st['errors']), c.errors, reason: c.name);
      expect(st['hasWarnOrAbove'], c.warn, reason: c.name);
    }
    print(
      '[validator] ${[for (var i = 0; i < cases.length; i++) '${cases[i].name}=${int_(obj(results[i]['stats'])['lines'])}'].join(' ')}',
    );
  });
}
