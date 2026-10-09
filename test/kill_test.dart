// 对位 Android KillTests.kt：真杀进程验收 R-1（方案 §3.11）——子 Dart 进程写 N 行后自发 SIGKILL，父进程用同一 root 恢复：
// N 行全部识别、oseq 连续、出站箱正确、sessions.jsonl 有 unclean_fg 且合成 error 已封段。

import 'dart:io';

import 'package:revdog_retriever/src/fs.dart';
import 'package:revdog_retriever/src/ids.dart';
import 'package:revdog_retriever/src/json.dart';
import 'package:revdog_retriever/src/limits.dart';
import 'package:test/test.dart';

import 'support/support.dart';

Future<(int, int)> helper(String root, int n, {bool torn = false, bool fatal = false}) async {
  final (code, out) = await runHelper([root, '$n', if (torn) '--torn', if (fatal) '--fatal']);
  expect(code, sigkillExit, reason: '子进程自发 SIGKILL：$out');
  final parts = out.trim().split(' ');
  return (int.parse(parts[0].replaceFirst('seq=', '')), int.parse(parts[1].replaceFirst('oseq=', '')));
}

/// 读旧会话全部段里的行。
List<Map<String, Object?>> allLines(String dir) => sessionLines(dir).map((l) => l.map).toList();

(String, String) oldSession(String root, String current) {
  final sid = Fs.listSync('$root/proc-main')!.firstWhere((n) => n != current && n.length == 36);
  return (sid, '$root/proc-main/$sid');
}

void main() {
  setUpRtv();

  test('killThenRecover', () async {
    final root = tempDir('rtv-kill');
    final (seq, oseq) = await helper(root, 5000);
    expect(seq, 5000);
    expect(oseq, 500);

    final h = await Harness.create(root: root, key: '');
    await h.settle();
    final (sid, dir) = oldSession(root, h.client.writer.currentSessionId);

    // 全部段已封，无残留 .open
    final segs = Fs.listSync(dir)!.where((n) => n.startsWith('seg-')).toList();
    expect(segs.every((n) => n.endsWith('.sealed')), isTrue, reason: '$segs');

    // 5000 行全部识别 + 合成 error（seq / oseq 接着编）
    final ls = allLines(dir);
    expect(ls.length, 5001);
    expect(ls.map((l) => int_(l['seq'])).toList(), [for (var i = 1; i <= 5001; i++) i]);
    expect(ls.where((l) => l.containsKey('oseq')).map((l) => int_(l['oseq'])).toList(), [
      for (var i = 1; i <= 501; i++) i,
    ]);
    final synth = ls.last;
    expect(synth['tag'], 'rtv.unclean_exit');
    expect(synth['synthetic'], true);
    expect(synth['level'], 'error');
    expect(synth['msg'], 'process ended while foregrounded');

    // 会话终态
    final closed = h.readJsonl('sessions.jsonl').where((c) => c['session_id'] == sid).toList();
    expect(closed.length, 1);
    expect(closed[0]['exit'], 'unclean_fg');
    expect(int_(closed[0]['last_seq']), 5001);
    expect(int_(closed[0]['last_oseq']), 501);

    // 出站箱：旧会话 primary 批 oseq 区间首尾相接覆盖 1..501，合成 error 在带 ctx 的 p0 批里
    final envs = h.envelopes().where((e) => e['session_id'] == sid).toList();
    final ranges = envs.map((e) => (int_(e['oseq_from']), int_(e['oseq_to']))).toList()
      ..sort((a, b) => a.$1.compareTo(b.$1));
    expect(ranges.first.$1, 1);
    expect(ranges.last.$2, 501);
    for (var i = 1; i < ranges.length; i++) {
      expect(ranges[i].$1, ranges[i - 1].$2 + 1);
    }
    final p0 = envs.firstWhere((e) => e.lines.any((l) => l['tag'] == 'rtv.unclean_exit'));
    expect(p0.name.startsWith('p0-'), isTrue);
    expect(p0.lines.where((l) => l['ctx'] == true).length, Limits.ctxLinesDefault);
    expect(objs(p0['closed_sessions']).any((c) => c['session_id'] == sid), isTrue);

    // 服务端校验器逐个通过
    assertAllValid(await runValidator(envs));

    // 重启第二次：不再重复合成、不重复写终态
    final h2 = await Harness.create(root: root, key: '');
    await h2.settle();
    expect(allLines(dir).length, 5001);
    expect(h2.readJsonl('sessions.jsonl').where((c) => c['session_id'] == sid).length, 1);
    expect(h2.envelopes().where((e) => e['session_id'] == sid).length, envs.length);
  });

  test('tornLastLine', () async {
    final root = tempDir('rtv-torn');
    final (seq, oseq) = await helper(root, 3000, torn: true);
    expect(seq, 3000);
    expect(oseq, 300);
    final h = await Harness.create(root: root, key: '');
    await h.settle();
    final (sid, dir) = oldSession(root, h.client.writer.currentSessionId);
    final ls = allLines(dir);
    // 残行被截掉：3000 行完整 + 合成 error 的 seq 跳过残行占用的 3001
    expect(ls.length, 3001);
    expect(ls.sublist(0, ls.length - 1).map((l) => int_(l['seq'])).toList(), [for (var i = 1; i <= 3000; i++) i]);
    expect(int_(ls.last['seq']), 3002);
    expect(int_(ls.last['oseq']), 302);
    // 残行 oseq 301 记 corrupt 墓碑
    final drops = h.readJsonl('drops.jsonl').where((d) => d['session_id'] == sid).toList();
    expect(drops.length, 1);
    expect(drops[0]['reason'], 'corrupt');
    expect(int_(drops[0]['oseq_from']), 301);
    expect(int_(drops[0]['oseq_to']), 301);
    // 出站箱覆盖 1..300 与 302（缺口处切批）
    final envs = h.envelopes().where((e) => e['session_id'] == sid).toList();
    final covered =
        envs
            .expand((e) => e.lines.where((l) => l.containsKey('oseq') && l['ctx'] != true).map((l) => int_(l['oseq'])))
            .toList()
          ..sort();
    expect(covered, [for (var i = 1; i <= 300; i++) i, 302]);
    assertAllValid(await runValidator(envs));
  });

  /// fatal 之后立刻 SIGKILL（封段物化是异步的，来不及做）：重启后 fatal 行已恢复、oseq 连续，它所在的批
  /// batch_id = UUIDv5(install:session:primary:oseq_from)，与正常封段时同名。
  test('fatalThenKillBeforeSeal', () async {
    final root = tempDir('rtv-fatal');
    final (seq, oseq) = await helper(root, 2000, fatal: true);
    expect(seq, 2001);
    expect(oseq, 201);
    final h = await Harness.create(root: root, key: '');
    await h.settle();
    final (sid, dir) = oldSession(root, h.client.writer.currentSessionId);
    final ls = allLines(dir);
    final fatal = ls.singleWhere((l) => l['level'] == 'fatal');
    expect(int_(fatal['seq']), 2001);
    expect(int_(fatal['oseq']), 201);
    expect(int_(ls.singleWhere((l) => l['tag'] == 'rtv.unclean_exit')['oseq']), 202, reason: '合成 unclean_exit 接着编');
    final envs = h.envelopes().where((e) => e['session_id'] == sid).toList();
    final ranges = envs.map((e) => (int_(e['oseq_from']), int_(e['oseq_to']))).toList()
      ..sort((a, b) => a.$1.compareTo(b.$1));
    expect(ranges.first.$1, 1);
    expect(ranges.last.$2, 202);
    for (var i = 1; i < ranges.length; i++) {
      expect(ranges[i].$1, ranges[i - 1].$2 + 1);
    }
    final carrier = envs.singleWhere((e) => e.lines.any((l) => l['level'] == 'fatal' && l['ctx'] != true));
    expect(carrier.name.startsWith('p0-'), isTrue);
    expect(carrier['batch_id'], Ids.batchId(h.client.installId!, sid, BatchKind.primary, int_(carrier['oseq_from'])));
    expect(h.readJsonl('sessions.jsonl').where((c) => c['session_id'] == sid).length, 1);
    assertAllValid(await runValidator(envs));
  });

  /// 同一 root 上另一个还活着的实例：它的会话锁着，恢复流程不动它。
  test('liveSessionIsNotRecovered', () async {
    final root = tempDir('rtv-live');
    final a = await Harness.create(root: root, key: '', direct: true);
    await a.settle();
    a.l(LogLevel.warn, 'a alive');
    final b = await Harness.create(root: root, key: '', direct: true);
    await b.settle();
    expect(File(a.client.debugOpenSegmentFile!).existsSync(), isTrue, reason: 'a 的 .open 段没被封');
    expect(b.readJsonl('sessions.jsonl').length, 0);
    a.l(LogLevel.warn, 'a still writes');
    expect(a.client.debugCounters.$2, 2);
    // a 死后，下一次启动才恢复它（b 仍活着，不动）
    final aSid = a.client.writer.currentSessionId;
    await a.simulateCrash();
    final c = await Harness.create(root: root, key: '', direct: true);
    await c.settle();
    final closed = c.readJsonl('sessions.jsonl');
    expect(closed.map((x) => x['session_id']).toList(), [aSid]);
    expect(closed[0]['exit'], 'unclean_fg');
    expect(int_(closed[0]['last_oseq']), 3, reason: '2 行 warn + 合成 error');
    expect(JsonIn.objText('{}'), isNotNull);
  });
}
