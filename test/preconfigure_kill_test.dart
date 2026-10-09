// 对位 Android PreconfigureKillTests.kt：真杀进程（子 Dart 进程自发 SIGKILL，沿用 tool/kill_helper.dart；简报 §11 D / E / J）：
// configure 之前被杀 → 下次启动收编为独立会话；收编中途被杀 → 重做后不重不丢、提交前没有批次进出站箱；别的活进程的 pre 文件不碰。

import 'dart:convert';
import 'dart:io';

import 'package:revdog_retriever/src/fs.dart';
import 'package:revdog_retriever/src/json.dart';
import 'package:test/test.dart';

import 'support/support.dart';

Future<void> runToKill(List<String> args) async {
  final (code, out) = await runHelper(args);
  expect(code, sigkillExit, reason: '子进程自发 SIGKILL：$out');
}

/// kill_helper `_preLines(n)` 的级别规则。
String levelOf(int i) {
  if (i % 50 == 0) return 'error';
  if (i % 10 == 0) return 'warn';
  return i % 2 == 0 ? 'info' : 'debug';
}

String otherSession(StaticHarness h) =>
    h.sessionDirs().singleWhere((d) => !d.endsWith(h.client.writer.currentSessionId));

void assertAdoptedExactly(String dir, int n) {
  final ls = sessionLines(dir).where((l) => l['synthetic'] != true).toList();
  expect(ls.map((l) => l['msg']).toList(), [for (var i = 1; i <= n; i++) 'pre $i']);
  expect(ls.map((l) => l['level']).toList(), [for (var i = 1; i <= n; i++) levelOf(i)]);
  expect(ls.map((l) => int_(l['seq'])).toList(), [for (var i = 1; i <= n; i++) i], reason: 'seq 连续');
  final oseqs = ls.where((l) => l.map.containsKey('oseq')).map((l) => int_(l['oseq'])).toList();
  expect(oseqs, [for (var i = 1; i <= n ~/ 2; i++) i], reason: '按 configure(INFO) 判定：偶数行是义务行，oseq 连续');
  // 用户边界：第 n/2 + 1 行起是 killed-user
  expect(segHeaders(dir).map((x) => x['user_id']).toSet().toList(), [null, 'killed-user']);
}

void main() {
  setUpRtv();

  /// D：configure 之前进程被杀 → 下次启动收编为独立会话：行数相等、按当时 configure 的级别判定、无 rtv.unclean_exit。
  test('d_killedBeforeConfigureAdoptedAsOwnSession', () async {
    final root = tempDir('rtv-prekill');
    await runToKill(['--pre', root, '300']);
    final pre = Directory('$root/pre').listSync().single.path;
    final h = await StaticHarness.create(root: root);
    await h.configure('', const RetrieverOptions(uploadLevel: LogLevel.info));
    await h.settle();
    expect(File(pre).existsSync(), isFalse, reason: '提交 = unlink');
    final dir = otherSession(h);
    assertAdoptedExactly(dir, 300);
    final meta = JsonIn.obj(File('$dir/meta.json').readAsBytesSync())!;
    expect(meta.containsKey('pre'), isFalse);
    expect(meta['process'], 'main');
    expect(
      sessionLines(dir).any((l) => l['tag'] == 'rtv.unclean_exit'),
      isFalse,
      reason: '孤儿会话没有前后台记录：不合成 unclean_exit',
    );
    final sid = dir.split('/').last;
    final mine = h.envelopes().where((e) => e['session_id'] == sid).toList();
    final covered = mine.expand((e) => e.lines.where((l) => l['ctx'] != true).map((l) => int_(l['oseq']))).toList()
      ..sort();
    expect(covered, [for (var i = 1; i <= 150; i++) i]);
    expect(h.readJsonl('sessions.jsonl').singleWhere((c) => c['session_id'] == sid)['exit'], 'unknown');
    expect(mine.map((e) => e['user_id']).toSet(), {null, 'killed-user'}, reason: '用户边界 = 批边界');
    assertAllValid(await runValidator(mine));
    // 再启动一次：不重复收编
    final h2 = await h.restart();
    await h2.configure('');
    await h2.settle();
    expect(sessionLines(dir).where((l) => l['synthetic'] != true).length, 300);
  });

  /// E：收编中途被杀（第 57 条记录之后 / 提交之前）→ 重做后不重不丢；被杀时出站箱里没有这个会话的批。重做保留游标里的前后台记录
  /// （被杀时在前台）→ 按现有规则合成 `rtv.unclean_exit`。
  test('e_killedMidAdoptionRedone', () async {
    for (final point in ['record:57', 'before_commit']) {
      final root = tempDir('rtv-adoptkill');
      await runToKill(['--adopt-crash', root, '200', point]);
      expect(Directory('$root/pre').listSync().length, 1, reason: '$point：pre 文件在提交前始终完整');
      expect(
        (Fs.listSync('$root/outbox') ?? const <String>[]).where((n) => n.endsWith('.gz')),
        isEmpty,
        reason: '$point：提交前没有批次进出站箱',
      );
      final crashed = Directory('$root/proc-main').listSync().single.path;
      expect(JsonIn.obj(File('$crashed/meta.json').readAsBytesSync())!.containsKey('pre'), isTrue);
      final h = await StaticHarness.create(root: root);
      await h.configure('', const RetrieverOptions(uploadLevel: LogLevel.info));
      await h.settle();
      expect(h.preFiles, isEmpty);
      expect(otherSession(h), crashed, reason: '重做进同一个会话');
      assertAdoptedExactly(crashed, 200);
      expect(
        sessionLines(crashed).where((l) => l['tag'] == 'rtv.unclean_exit').length,
        1,
        reason: '$point：前台死亡合成 unclean_exit',
      );
      final sid = crashed.split('/').last;
      final covered =
          h
              .envelopes()
              .where((e) => e['session_id'] == sid)
              .expand((e) => e.lines.where((l) => l['ctx'] != true).map((l) => int_(l['oseq'])))
              .toList()
            ..sort();
      expect(covered, [for (var i = 1; i <= 101; i++) i], reason: '$point：不重不丢');
      await RetrieverRuntime.resetForTesting();
    }
  });

  /// E：unlink 之后、清 meta.pre 之前被杀 = 已提交：按普通会话恢复（前台死亡照常合成 unclean_exit），不重复收编。
  test('e_killedAfterCommitPointRecoveredNormally', () async {
    final root = tempDir('rtv-adoptkill2');
    await runToKill(['--adopt-crash', root, '200', 'after_unlink']);
    expect(Directory('$root/pre').listSync(), isEmpty);
    final crashed = Directory('$root/proc-main').listSync().single.path;
    final h = await StaticHarness.create(root: root);
    await h.configure('', const RetrieverOptions(uploadLevel: LogLevel.info));
    await h.settle();
    assertAdoptedExactly(crashed, 200);
    expect(sessionLines(crashed).where((l) => l['tag'] == 'rtv.unclean_exit').length, 1);
    final sid = crashed.split('/').last;
    final covered =
        h
            .envelopes()
            .where((e) => e['session_id'] == sid)
            .expand((e) => e.lines.where((l) => l['ctx'] != true).map((l) => int_(l['oseq'])))
            .toList()
          ..sort();
    expect(covered, [for (var i = 1; i <= 101; i++) i]);
  });

  /// E（B10）：收编期间宿主还在写（configure 之后的 r = 1 行追加到 pre 文件尾）时被杀：重做后全部行恰好出现一次、顺序正确、oseq 连续。
  test('e_killedWhileHostWritingDuringAdoption', () async {
    final root = tempDir('rtv-adoptkill3');
    await runToKill(['--adopt-crash-writing', root, '200', 'record:60']);
    final crashed = Directory('$root/proc-main').listSync().single.path;
    final h = await StaticHarness.create(root: root);
    await h.configure('', const RetrieverOptions(uploadLevel: LogLevel.info));
    await h.settle();
    expect(h.preFiles, isEmpty);
    final ls = sessionLines(crashed).where((l) => l['synthetic'] != true).toList();
    expect(ls.map((l) => l['msg']).toList(), [
      for (var i = 1; i <= 200; i++) 'pre $i',
      for (var k = 0; k < 10; k++) 'post $k',
    ]);
    expect(ls.map((l) => int_(l['seq'])).toList(), [for (var i = 1; i <= 210; i++) i]);
    final sid = crashed.split('/').last;
    final covered =
        h
            .envelopes()
            .where((e) => e['session_id'] == sid)
            .expand((e) => e.lines.where((l) => l['ctx'] != true).map((l) => int_(l['oseq'])))
            .toList()
          ..sort();
    expect(covered, [for (var i = 1; i <= 111; i++) i], reason: 'pre 偶数行 100 + post 10 + 前台死亡的 unclean_exit');
  });

  /// J：别的活进程的 pre 文件（持 flock）不碰——不收编、不按年龄删；它死后下次启动才收编。
  test('j_liveProcessPreFileUntouched', () async {
    final root = tempDir('rtv-live-pre');
    final p = await startHelper(['--pre-hold', root, '40']);
    try {
      final ready = await p.stdout.transform(utf8.decoder).transform(const LineSplitter()).first;
      expect(ready, 'ready');
      final pre = File(Directory('$root/pre').listSync().single.path);
      final bytes = pre.readAsBytesSync();
      pre.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 8)));
      final h = await StaticHarness.create(root: root);
      await h.configure('');
      await h.settle();
      await h.client.onWork(h.client.engine.processSeals);
      expect(pre.existsSync(), isTrue);
      expect(pre.readAsBytesSync(), bytes);
      expect(h.sessionDirs().length, 1, reason: '没有替它建会话');
      p.kill(ProcessSignal.sigkill);
      await p.exitCode.timeout(const Duration(seconds: 30));
      pre.setLastModifiedSync(DateTime.now());
      final h2 = await h.restart();
      await h2.configure('', const RetrieverOptions(uploadLevel: LogLevel.info));
      await h2.settle();
      expect(pre.existsSync(), isFalse);
      final adopted = h2
          .sessionDirs()
          .where((d) => !d.endsWith(h2.client.writer.currentSessionId))
          .singleWhere((d) => sessionLines(d).any((l) => l['msg'] == 'pre 1'));
      assertAdoptedExactly(adopted, 40);
    } finally {
      p.kill(ProcessSignal.sigkill);
    }
  });
}
