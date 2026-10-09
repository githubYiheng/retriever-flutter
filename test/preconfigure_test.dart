// 对位 Android PreconfigureTests.kt（含 PreAlignmentTests、PreReviewFixTests）：configure 之前没有实例（ADR 0023；简报 §1 / §4.1–4.3；
// §11 A / B / C / F / G / H / I / L / M）。全部走静态入口 `Retriever.*`。D / E / J（真杀进程、别的活进程）在 preconfigure_kill_test.dart。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:revdog_retriever/src/client.dart';
import 'package:revdog_retriever/src/drop_counter.dart';
import 'package:revdog_retriever/src/fs.dart';
import 'package:revdog_retriever/src/ids.dart';
import 'package:revdog_retriever/src/json.dart';
import 'package:revdog_retriever/src/limits.dart';
import 'package:revdog_retriever/src/line_encoder.dart';
import 'package:revdog_retriever/src/model.dart';
import 'package:revdog_retriever/src/pre.dart';
import 'package:test/test.dart';

import 'support/support.dart';

List<SegLineRec> lines(StaticHarness h) => sessionLines(h.currentSessionDir());

List<Object?> msgs(StaticHarness h) => lines(h).map((l) => l['msg']).toList();

Map<String, Object?>? dropped(StaticHarness h) {
  final d = lines(h).where((l) => l['tag'] == DropCounter.tag).toList();
  return d.length == 1 ? d.single.map : null;
}

bool isRootUser() => (Process.runSync('id', ['-u']).stdout as String).trim() == '0';

const String header =
    '{"pre":1,"started_ms":1790668000000,"process":"main","device":{"os":"android","os_version":"15","model":"m",'
    '"app_version":"1","build":"1","locale":"en","sdk":"retriever-android/0.3.0"}}\n';

String orphan(String root, List<String> records) {
  Directory('$root/pre').createSync(recursive: true);
  final f = File('$root/pre/${Ids.newV4()}.jsonl')..writeAsStringSync(header + records.map((r) => '$r\n').join());
  return f.path;
}

void main() {
  setUpRtv();

  group('PreconfigureTests', () {
    /// 先 log 后 configure(INFO)：info 及以上有 oseq 且从 1 连续，debug 照写不占 oseq；ts 保持写入时刻；pre 文件已删、meta 无 pre。
    test('a_linesBeforeConfigureJudgedByThisConfigure', () async {
      final h = await StaticHarness.create();
      final ts = <int>[];
      final levels = [LogLevel.debug, LogLevel.info, LogLevel.warn, LogLevel.error];
      for (var i = 0; i < levels.length; i++) {
        ts.add(h.clock.wallMs());
        h.log(levels[i], 'pre $i');
        h.clock.advance(1000);
      }
      expect(RetrieverRuntime.client, isNull, reason: 'configure 之前没有实例');
      expect(h.preFiles.length, 1);
      expect(Retriever.uploadLevel, LogLevel.warn);
      expect(Retriever.localLevel, LogLevel.debug);
      expect(Retriever.installId, isNull);
      expect(Retriever.supportCode, isNull);
      await h.configure('', const RetrieverOptions(uploadLevel: LogLevel.info));
      await h.settle();
      final ls = lines(h);
      expect(ls.map((l) => l['msg']).toList(), ['pre 0', 'pre 1', 'pre 2', 'pre 3']);
      expect(ls.map((l) => int_(l['seq'])).toList(), [1, 2, 3, 4]);
      expect(ls.map((l) => int_(l['oseq'])).toList(), [-999, 1, 2, 3]);
      expect(ls.map((l) => int_(l['ts'])).toList(), ts, reason: 'ts 保持写入时刻');
      expect(h.preFiles, isEmpty, reason: '提交 = unlink pre 文件');
      expect(JsonIn.obj(File('${h.currentSessionDir()}/meta.json').readAsBytesSync())!.containsKey('pre'), isFalse);
      // configure 之后照常写，oseq 接着编
      h.log(LogLevel.info, 'after');
      expect(int_(lines(h).last['oseq']), 4);
    });

    test('a_uploadLevelErrorAndLocalLevelInfo', () async {
      final h = await StaticHarness.create();
      h.log(LogLevel.debug, 'd');
      h.log(LogLevel.warn, 'w');
      h.log(LogLevel.error, 'e');
      await h.configure('', const RetrieverOptions(uploadLevel: LogLevel.error));
      await h.settle();
      final ls = lines(h);
      expect(ls.map((l) => l['msg']).toList(), ['d', 'w', 'e']);
      expect(ls.map((l) => int_(l['oseq'])).toList(), [-999, -999, 1], reason: 'warn 无 oseq');

      final h2 = await StaticHarness.create();
      h2.log(LogLevel.debug, 'd');
      h2.log(LogLevel.info, 'i');
      await h2.configure('', const RetrieverOptions(localLevel: LogLevel.info));
      await h2.settle();
      expect(msgs(h2), ['i'], reason: 'debug 行不出现、不占 seq');
      expect(int_(lines(h2).single['seq']), 1);
    });

    /// configure 之前的行经过 redact：改写生效、null / 抛异常丢弃；钩子里调 log 被忽略；synthetic / truncated 保留。
    test('b_preLinesGoThroughRedact', () async {
      final h = await StaticHarness.create();
      var calls = 0;
      final opts = RetrieverOptions(
        uploadLevel: LogLevel.info,
        redact: (l) {
          calls++;
          if (l.msg.contains('drop')) return null;
          if (l.msg.contains('boom')) throw StateError('hook bug');
          if (l.msg.contains('reenter')) {
            Retriever.log(LogLevel.error, 'from inside hook');
            return l;
          }
          if (l.msg.contains('secret')) return l.copyWith(msg: l.msg.replaceAll('secret', '***'));
          if (l.msg.contains('long')) return l.copyWith(msg: 'short');
          return l;
        },
      );
      for (final m in ['a secret', 'please drop', 'boom', 'reenter', 'long ${'x' * 5000}', 'plain']) {
        h.log(LogLevel.info, m);
      }
      await h.configure('', opts);
      await h.settle();
      final ls = lines(h);
      expect(ls.map((l) => l['msg']).toList(), ['a ***', 'reenter', 'short', 'plain']);
      expect(ls.map((l) => int_(l['seq'])).toList(), [1, 2, 3, 4], reason: '收编的行按文件顺序编号');
      expect(ls[2]['truncated'], true, reason: '截断标记与原值取或');
      expect(calls, 6);
      expect(h.errors.length, 1, reason: '钩子抛异常走内部出口');
      h.errors.clear();
    });

    /// 合成行不经 redact（收编中的 bootstrap 合成行进 pre 文件 r = 1）；无钩子时行体字节不变。
    test('b_syntheticSkipsRedactAndBytesUnchangedWithoutHook', () async {
      final h = await StaticHarness.create();
      await h.configure('');
      await h.settle();
      // 下一次启动 install.json 损坏 → bootstrap 写合成 warn rtv.install_repaired（收编中 → pre 文件 r = 1）
      final h2 = await h.restart();
      File('${h2.root}/install.json').writeAsStringSync('{"install_id":"bad');
      h2.log(LogLevel.warn, 'pre line', attrs: {'n': 1.25, 's': '中文 😀', 'big': 9007199254740993});
      await h2.configure('', RetrieverOptions(redact: (_) => null));
      await h2.settle();
      final ls = lines(h2);
      expect(ls.map((l) => l['tag']).toList(), ['rtv.install_repaired'], reason: '钩子丢光 configure 之前的行；合成行照写');
      expect(ls.single['synthetic'], true);

      // 无钩子：段里的行 = pre 记录去掉 `{"r":0,` 换上 seq / oseq 前缀，其余逐字节相同
      final h3 = await StaticHarness.create();
      h3.log(
        LogLevel.warn,
        'bytes',
        attrs: {'n': 1.25, 's': '中文 😀\u0001', 'big': 9007199254740993},
        error: StateError('x'),
      );
      final rec = File(h3.preFiles.single).readAsStringSync().split('\n').firstWhere((l) => l.startsWith('{"r":0,'));
      await h3.configure('');
      await h3.settle();
      final raw = lines(h3).single.raw;
      expect(raw.substring(raw.indexOf('"oseq":1,') + '"oseq":1,'.length), rec.substring('{"r":0,'.length));
    });

    /// configure 之前 setUser：用户边界与段头 user_id 正确；configure 之前 setUser（文件还没建）→ 写在头记录之后。
    test('c_userBoundariesBeforeConfigure', () async {
      final h = await StaticHarness.create();
      Retriever.setUser('early');
      h.log(LogLevel.warn, 'as early');
      Retriever.setUser(null);
      h.log(LogLevel.warn, 'anon');
      Retriever.setUser('u1');
      h.log(LogLevel.warn, 'as u1');
      Retriever.setUser('u2');
      await h.configure('');
      await h.settle();
      final dir = h.currentSessionDir();
      expect(segHeaders(dir).map((x) => x['user_id']).toList(), ['early', null, 'u1', 'u2']);
      final names = Fs.listSync(dir)!.where((n) => n.startsWith('seg-')).toList()
        ..sort((a, b) => int.parse(a.substring(4, 10)).compareTo(int.parse(b.substring(4, 10))));
      final bySeg = names
          .map((n) => readSegmentLines('$dir/$n').skip(1).map((l) => JsonIn.objText(l)!['msg']).toList())
          .toList();
      expect(bySeg, [
        ['as early'],
        ['anon'],
        ['as u1'],
        <Object?>[],
      ]);
      expect(h.client.writer.currentUser, 'u2');
      h.log(LogLevel.warn, 'as u2');
      h.client.writer.rotate(SealReason.timer);
      await h.client.onWork(h.client.engine.processSeals);
      final envs = h.envelopes()..sort((a, b) => int_(a['seq_from']).compareTo(int_(b['seq_from'])));
      expect(envs.map((e) => e['user_id']).toList(), ['early', null, 'u1', 'u2']);
    });

    /// configure 之前写 error：收编后在去抖时间内封段；fatal：立即封段（启动后出站箱就有 p0）。
    test('c_errorDebounceAndFatalSealAfterAdoption', () async {
      final h = await StaticHarness.create();
      h.log(LogLevel.info, 'ctx');
      h.log(LogLevel.error, 'pre error');
      await h.configure('');
      await h.settle();
      expect(h.outboxFiles(), isEmpty);
      h.clock.advance(Limits.errorDebounceMs);
      await h.client.tickNow();
      final p0 = h.envelopes('p0').single;
      expect(p0.lines.map((l) => l['msg']).toList(), ['ctx', 'pre error']);
      expect(p0.lines[0]['ctx'], true);

      final h2 = await StaticHarness.create();
      h2.log(LogLevel.info, 'ctx');
      h2.log(LogLevel.fatal, 'pre fatal');
      await h2.configure('');
      await h2.settle();
      expect(h2.envelopes('p0').single.lines.map((l) => l['msg']).toList(), [
        'ctx',
        'pre fatal',
      ], reason: 'fatal 立即换段，提交后物化');
    });

    /// configure 之前：零驱逐、零联网、零后台作业、不恢复旧会话；configure(localCap = 50 MB) 后按 50 MB。
    test('f_nothingHappensBeforeConfigure', () async {
      final h = await StaticHarness.create();
      await h.configure('');
      h.log(LogLevel.warn, 'old session line');
      await h.settle();
      final oldSid = h.client.writer.currentSessionId;
      final h2 = await h.restart();
      // 出站箱塞 25 MB（> 默认 20 MB）
      final rnd = Random(3);
      for (var i = 0; i < 5; i++) {
        final b = Uint8List(5 * 1024 * 1024);
        for (var k = 0; k < b.length; k++) {
          b[k] = rnd.nextInt(256);
        }
        File('${h2.outbox}/p1-${1790000000000 + i}-${Ids.newV4()}.gz').writeAsBytesSync(b);
      }
      final before = h2.outboxFiles();
      for (var i = 0; i < 50; i++) {
        h2.log(LogLevel.error, 'pre $i');
      }
      h2.log(LogLevel.fatal, 'pre fatal');
      expect(RetrieverRuntime.client, isNull);
      expect(h2.outboxFiles(), before);
      expect(h2.transport.requests.length, 0, reason: '零联网');
      expect(h2.platform.scheduledJobs.length, 0, reason: '零后台作业');
      expect(Directory('${h2.root}/proc-main/$oldSid').existsSync(), isTrue, reason: '不恢复旧会话');
      expect(File('${h2.root}/sessions.jsonl').existsSync(), isFalse);
      expect(File('${h2.root}/drops.jsonl').existsSync(), isFalse);
      await h2.configure('', const RetrieverOptions(localCapBytes: 50 * 1024 * 1024));
      await h2.settle();
      expect(h2.client.engine.effective.config.localCapBytes, 50 * 1024 * 1024);
      expect(h2.outboxFiles().toSet().containsAll(before), isTrue, reason: '按 50 MB：一个旧批都没驱逐');
      expect(h2.readJsonl('drops.jsonl').where((d) => d['reason'] == 'buffer_overflow'), isEmpty);
    });

    /// pre 文件 1 MB 上限：超出的行计数，`rtv.pre_init_dropped` 的四项计数正确。
    test('g_capOverflowCounted', () async {
      final h = await StaticHarness.create();
      const n = 700;
      final big = 'x' * 2000;
      final ts = <int>[];
      for (var i = 0; i < n; i++) {
        ts.add(h.clock.wallMs());
        h.log(i % 10 == 0 ? LogLevel.error : LogLevel.info, '$i $big');
        h.clock.advance(1);
      }
      final size = File(h.preFiles.single).lengthSync();
      expect(size <= PreFile.maxBytes && size > PreFile.maxBytes - 3000, isTrue, reason: '$size');
      await h.configure('');
      await h.settle();
      final adopted = lines(h).where((l) => l['synthetic'] != true).length;
      expect(adopted > 0 && adopted < n, isTrue);
      final d = obj(dropped(h)!['attrs']);
      expect(int_(d['count']), n - adopted);
      expect(int_(d['error_count']), [for (var i = adopted; i < n; i++) i].where((i) => i % 10 == 0).length);
      expect(int_(d['first_ts']), ts[adopted]);
      expect(int_(d['last_ts']), ts[n - 1]);
      final line = dropped(h)!;
      expect(line['level'], 'warn');
      expect(line['msg'], DropCounter.msg);
      expect(line['synthetic'], true);
      expect(DropCounter.pending, 0);
    });

    /// 写失败（pre 目录建不出来）与 root 未知：计数；禁用期间不计。
    test('g_writeFailureNoRootAndDisabled', () async {
      final h = await StaticHarness.create();
      Directory(h.root).createSync(recursive: true);
      File('${h.root}/pre').writeAsStringSync('not a dir');
      h.log(LogLevel.error, 'lost 1');
      h.clock.advance(5);
      h.log(LogLevel.info, 'lost 2');
      File('${h.root}/pre').deleteSync();
      await h.configure('');
      await h.settle();
      final d = obj(dropped(h)!['attrs']);
      expect(d, {
        'count': 2.0,
        'error_count': 1.0,
        'first_ts': (h.clock.wallMs() - 5).toDouble(),
        'last_ts': h.clock.wallMs().toDouble(),
      });

      // root 还没回包（首触到回包之间）：无处可写，只计数；之后 bootstrap 给出 root 再 configure
      final h2 = await StaticHarness.create(noRoot: true);
      h2.log(LogLevel.warn, 'no root 1');
      h2.log(LogLevel.fatal, 'no root 2');
      expect(Directory('${h2.root}/pre').existsSync(), isFalse);
      h2.platform.rootMode = CallMode.ok;
      await h2.configure('');
      await h2.settle();
      expect(int_(obj(dropped(h2)!['attrs'])['count']), 2);
      expect(int_(obj(dropped(h2)!['attrs'])['error_count']), 1);

      // 禁用期间：不写、不计
      final h3 = await StaticHarness.create();
      Retriever.setEnabled(false);
      h3.log(LogLevel.error, 'not written');
      expect(Directory('${h3.root}/pre').existsSync(), isFalse);
      expect(DropCounter.pending, 0);
      Retriever.setEnabled(true);
      await h3.configure('');
      await h3.settle();
      expect(dropped(h3), isNull);
    });

    /// 孤儿 pre 文件：拿得到锁的一律收编，不看年龄；没能收编的（被别的进程名认领）超过 7 天在驱逐时删；pre 文件计入本地总量。
    test('g_orphanPreAgeAndTotal', () async {
      final eightDaysAgo = DateTime.fromMillisecondsSinceEpoch(FakeClock().wallMs() - 8 * 24 * 3600 * 1000);
      const hdr =
          '{"pre":1,"started_ms":1,"process":"main","device":{"os":"android","os_version":"15","model":"m","app_version":"1","build":"1","locale":"en","sdk":"x"}}\n';
      // 先单独看「老孤儿照样收编」（没有容量压力）
      final h0 = await StaticHarness.create();
      Directory('${h0.root}/pre').createSync(recursive: true);
      final old = File('${h0.root}/pre/${Ids.newV4()}.jsonl')
        ..writeAsStringSync('$hdr{"r":0,"ts":1,"level":"warn","msg":"ancient"}\n');
      old.setLastModifiedSync(eightDaysAgo);
      await h0.configure('');
      await h0.settle();
      expect(old.existsSync(), isFalse, reason: '超过 7 天的孤儿照样收编');
      expect(h0.sessionDirs().any((d) => sessionLines(d).any((l) => l['msg'] == 'ancient')), isTrue);

      final h = await StaticHarness.create();
      final preDir = Directory('${h.root}/pre')..createSync(recursive: true);
      // 认领它们的会话在别的进程名下：本进程不收编；年轻的计入总量，超过 7 天的驱逐时删
      const dev = Device('android', '15', 'm', '1', '1', 'en', 'x');
      File claimed(List<int> bytes) {
        final f = File('${preDir.path}/${Ids.newV4()}.jsonl')..writeAsBytesSync(bytes);
        final sid = Ids.newV4();
        final d = Directory('${h.root}/proc-other/$sid')..createSync(recursive: true);
        File(
          '${d.path}/meta.json',
        ).writeAsBytesSync(SessionMeta(sid, 1, 1, dev, 'other', null, f.path.split('/').last).encode());
        return f;
      }

      final big = claimed(Uint8List(3 * 1024 * 1024)..fillRange(0, 3 * 1024 * 1024, 0x20));
      final stale = claimed(utf8.encode('$hdr{"r":0,"ts":1,"level":"warn","msg":"stale"}\n'));
      stale.setLastModifiedSync(eightDaysAgo);
      // 一个 1 MB 的出站箱批：只有把 3 MB 的 pre 文件算进总量才超过 2 MB 上限
      Directory(h.outbox).createSync(recursive: true);
      final rnd = Random(1);
      final batch = File('${h.outbox}/p1-1790000000000-${Ids.newV4()}.gz')
        ..writeAsBytesSync([for (var i = 0; i < 1024 * 1024; i++) rnd.nextInt(256)]);
      await h.configure('', const RetrieverOptions(localCapBytes: 2 * 1024 * 1024));
      await h.settle();
      expect(big.existsSync(), isTrue, reason: '别的进程名认领的不收编');
      expect(stale.existsSync(), isFalse, reason: '没能收编、超过 7 天的驱逐时删');
      expect(batch.existsSync(), isFalse, reason: 'pre 文件计入总量：出站箱批被驱逐');
    });

    /// 禁用标记在：configure 之前零写入、零计数，isEnabled = false。
    test('h_markerBlocksPreWrites', () async {
      final h = await StaticHarness.create();
      File(h.marker).createSync();
      expect(Retriever.isEnabled, isFalse);
      h.log(LogLevel.error, 'x');
      expect(Directory('${h.root}/pre').existsSync(), isFalse);
      expect(DropCounter.pending, 0);
      await h.configure('');
      await h.settle();
      expect(h.client.isEnabled, isFalse);
      expect(h.client.debugCounters.$1, 0);
    });

    /// 标记判定未知（父目录列不出）→ 按禁用；判定恢复后（定时唤醒）重判。
    test('h_unknownMarkerFailsClosedThenRejudged', () async {
      if (isRootUser()) {
        markTestSkipped('root 用户列得出');
        return;
      }
      final parent = tempDir('rtv-parent');
      final root = '$parent/retriever';
      final h = await StaticHarness.create(root: root);
      Process.runSync('chmod', ['333', parent]);
      try {
        expect(Retriever.isEnabled, isFalse);
        h.log(LogLevel.error, 'unknown → not written');
        expect(Directory('$root/pre').existsSync(), isFalse);
        await h.configure('');
        await h.settle();
        expect(h.client.isEnabled, isFalse);
        expect(h.client.markerUnknown, isTrue);
        h.log(LogLevel.error, 'still not written');
        expect(h.client.debugCounters.$1, 0);
      } finally {
        Process.runSync('chmod', ['755', parent]);
      }
      await h.client.tickNow();
      expect(h.client.isEnabled, isTrue, reason: '判定恢复：重判为启用');
      h.log(LogLevel.error, 'written');
      expect(msgs(h), ['written']);
    });

    /// configure 之前 purgeLocal：pre 文件与 root 都清（改名再删）、计数清零、Future 清完才完成；之后的行重新建 pre 文件。
    test('h_purgeBeforeConfigure', () async {
      final h = await StaticHarness.create();
      await h.configure('');
      await h.settle();
      final h2 = await h.restart();
      h2.log(LogLevel.warn, 'to purge');
      TestHooks.preWriteFault = (_) => true;
      Retriever.log(LogLevel.warn, 'counted');
      TestHooks.preWriteFault = null;
      expect(DropCounter.pending, 1);
      expect(File('${h2.root}/install.json').existsSync(), isTrue);
      await Retriever.purgeLocal().timeout(const Duration(seconds: 10));
      expect(File('${h2.root}/install.json').existsSync(), isFalse, reason: 'root 清了');
      expect(h2.preFiles, isEmpty);
      expect(DropCounter.pending, 0);
      final base = h2.root.split('/').last;
      expect(
        Directory(h2.root).parent.listSync().every((e) => !e.path.split('/').last.startsWith('$base.purge-')),
        isTrue,
      );
      h2.log(LogLevel.warn, 'after purge');
      await h2.configure('');
      await h2.settle();
      expect(msgs(h2), ['after purge']);
    });

    /// 第二次 configure 改 processName：被忽略 + `rtv.reconfigure_ignored`，行继续进原会话。同参数重复 configure：零请求。
    test('i_identityFixedAtFirstConfigure', () async {
      final t = FakeTransport()..configBody = {'etag': 'e', 'ttl_s': 1800};
      final h = await StaticHarness.create(transport: t);
      await h.configure(demoKey);
      await h.settle();
      final sid = h.client.writer.currentSessionId;
      final client = h.client;
      h.log(LogLevel.warn, 'before');
      await h.configure(demoKey, const RetrieverOptions(processName: 'other'));
      h.log(LogLevel.warn, 'after');
      await h.settle();
      expect(identical(client, RetrieverRuntime.client), isTrue, reason: '同一个实例');
      expect(h.client.processName, 'main');
      expect(h.client.writer.currentSessionId, sid);
      expect(Directory('${h.root}/proc-other').existsSync(), isFalse);
      final ls = lines(h);
      expect(ls.map((l) => l['msg']).toList(), ['before', RetrieverClient.reconfigureIgnoredMsg, 'after']);
      final w = ls[1];
      expect(w['tag'], 'rtv.reconfigure_ignored');
      expect(w['attrs'], {'field': 'process_name'});
      expect(w['synthetic'], true);
      // 同参数重复 configure：零请求、零合成行
      final n0 = t.requests.length;
      final seq0 = h.client.debugCounters.$1;
      for (var i = 0; i < 5; i++) {
        await h.configure(demoKey);
      }
      await h.settle();
      expect(t.requests.length, n0);
      expect(h.client.debugCounters.$1, seq0);
      // 同参数但换了 redact：只更新 redact
      await h.configure(demoKey, RetrieverOptions(redact: (l) => l.copyWith(msg: 'masked')));
      h.log(LogLevel.warn, 'secret');
      expect(lines(h).last['msg'], 'masked');
      expect(t.requests.length, n0);
    });

    /// 并发：多个异步任务交错 log，configure 夹在中间，seq / oseq 无重无缺、行不丢、每个任务自己的行顺序不乱。
    test('l_concurrentLogAndConfigure', () async {
      final h = await StaticHarness.create();
      const threads = 8;
      const per = 400;
      Future<void> worker(int t) async {
        for (var i = 0; i < per; i++) {
          Retriever.log(i % 3 == 0 ? LogLevel.warn : LogLevel.debug, 't$t i$i');
          if (i % 20 == 0) await Future<void>.delayed(Duration.zero);
        }
      }

      final cfg = () async {
        await Future<void>.delayed(Duration.zero);
        await h.configure('', RetrieverOptions(redact: (l) => l));
      }();
      await Future.wait([for (var t = 0; t < threads; t++) worker(t), cfg]);
      await h.settle();
      final ls = lines(h);
      expect(ls.length, threads * per);
      expect(ls.map((l) => int_(l['seq'])).toList(), [for (var i = 1; i <= threads * per; i++) i]);
      final oseqs = ls.where((l) => l.map.containsKey('oseq')).map((l) => int_(l['oseq'])).toList();
      expect(oseqs, [for (var i = 1; i <= oseqs.length; i++) i]);
      expect(oseqs.length, threads * [for (var i = 0; i < per; i++) i].where((i) => i % 3 == 0).length);
      for (var t = 0; t < threads; t++) {
        expect(ls.map((l) => l['msg'] as String).where((m) => m.startsWith('t$t ')).toList(), [
          for (var i = 0; i < per; i++) 't$t i$i',
        ]);
      }
      expect(DropCounter.pending, 0);
      expect(h.preFiles, isEmpty);
    });

    /// 没有会话时的 log()（bootstrap 失败：meta.json 写不成）：计数、重试成功后上报；不留「有会话、没 meta」的目录。
    test('m_noSessionCountedAndMetaRequired', () async {
      final h = await StaticHarness.create();
      Fs.writeAtomicFaultForTesting = (p) => p.endsWith('/meta.json');
      await h.configure('');
      await h.settle();
      expect(h.client.isBootstrapped, isFalse, reason: 'meta 写不成 = bootstrap 失败');
      expect(Retriever.installId, isNull);
      for (final d in h.sessionDirs()) {
        expect(File('$d/meta.json').existsSync(), isTrue, reason: '没有无 meta 的会话目录：$d');
      }
      h.log(LogLevel.error, 'lost e');
      h.log(LogLevel.info, 'lost i');
      Fs.writeAtomicFaultForTesting = null;
      h.clock.advance(5000);
      h.log(LogLevel.warn, 'triggers retry');
      await h.settle();
      expect(h.client.isBootstrapped, isTrue);
      expect(Retriever.installId, isNotNull);
      final d = obj(dropped(h)!['attrs']);
      expect(int_(d['count']), 3);
      expect(int_(d['error_count']), 1);
      h.log(LogLevel.warn, 'written');
      expect(msgs(h), [DropCounter.msg, 'written']);
    });
  });

  /// 主代理定稿的两端对齐口径（简报补充 B）：提交点、禁用时照样收编、解不出的行计数、往返无损。
  group('PreAlignmentTests', () {
    String adoptedOrphan(StaticHarness h) =>
        h.sessionDirs().singleWhere((d) => !d.endsWith(h.client.writer.currentSessionId));

    /// unlink 失败时把自己的句柄截成 0 长度 = 已提交；长度 0 的 pre 文件不收编、不重做（直接删）。
    test('commitByTruncateWhenUnlinkFails', () async {
      if (isRootUser()) {
        markTestSkipped('root 用户删得掉');
        return;
      }
      final root = tempDir();
      final pf = PreFile.create(root, Ids.newV4())!;
      expect(pf.append(utf8.encode('{"pre_user":null}\n'), true), PrePut.written);
      final dir = '$root/pre';
      Process.runSync('chmod', ['555', dir]);
      try {
        expect(pf.unlinkAndClose(), isTrue);
        expect(File(pf.path).existsSync(), isTrue);
        expect(File(pf.path).lengthSync(), 0);
      } finally {
        Process.runSync('chmod', ['755', dir]);
      }
      final h = await StaticHarness.create(root: root);
      await h.configure('');
      await h.settle();
      expect(File(pf.path).existsSync(), isFalse, reason: '长度 0 = 已提交：删掉');
      expect(h.sessionDirs().length, 1);
    });

    /// 禁用状态下照样收编孤儿 pre 文件（已落盘的数据），上传仍被禁用挡住。
    test('orphanAdoptedWhileDisabled', () async {
      final h = await StaticHarness.create();
      final f = orphan(h.root, ['{"r":0,"ts":1790668000001,"level":"warn","msg":"orphan w"}']);
      File(h.marker).createSync();
      await h.configure(demoKey);
      await h.settle();
      expect(File(f).existsSync(), isFalse);
      expect(sessionLines(adoptedOrphan(h)).map((l) => l['msg']).toList(), ['orphan w']);
      expect(h.transport.batchRequests.length, 0);
    });

    /// 有 redact 钩子而 pre 行解不出来：丢弃并计数（之后以 rtv.pre_init_dropped 上报）。
    test('undecodableLineWithHookDroppedAndCounted', () async {
      final h = await StaticHarness.create();
      orphan(h.root, [
        '{"r":0,"ts":1790668000002,"level":"error","msg":}',
        '{"r":0,"ts":1790668000003,"level":"warn","msg":"ok"}',
      ]);
      await h.configure('', RetrieverOptions(redact: (l) => l));
      await h.settle();
      expect(sessionLines(adoptedOrphan(h)).map((l) => l['msg']).toList(), ['ok']);
      await h.client.tickNow();
      final d = sessionLines(h.currentSessionDir()).singleWhere((l) => l['tag'] == DropCounter.tag);
      expect(d['attrs'], {'count': 1.0, 'error_count': 1.0, 'first_ts': 1790668000002.0, 'last_ts': 1790668000002.0});
    });

    /// 往返无损（简报补充 B-17）：恒等 redact 钩子下「解码 → 钩子 → 重编码」与输入逐字节相同。iOS 夹具在就一并回放。
    test('preRoundtripLossless', () {
      final bodies = <(String, String)>[];
      void add(String name, LogLine l, {bool synthetic = false}) {
        final s = utf8.decode(LineEncoder.encode(l, synthetic: synthetic).body);
        bodies.add((name, s.substring(0, s.length - 1)));
      }

      add('plain', const LogLine(ts: 1790668800000, level: LogLevel.info, msg: 'hello'));
      add(
        'full',
        const LogLine(
          ts: 1,
          level: LogLevel.error,
          msg: 'm "q" \\ \u0001 中文 😀',
          tag: 'tag',
          attrs: {'a': 1.5, 'b': true, 'c': null, 'd': 9007199254740993, 'e': -0.000001, 'f': 's'},
          exc: LogException(type: 'T', message: 'msg', stack: 'line1\n\tat x'),
        ),
      );
      add(
        'synthetic',
        const LogLine(
          ts: 2,
          level: LogLevel.warn,
          msg: 'lines dropped',
          tag: 'rtv.pre_init_dropped',
          attrs: {'count': 3},
        ),
        synthetic: true,
      );
      add('truncated', LogLine(ts: 3, level: LogLevel.debug, msg: 'x' * 5000));
      add('lone surrogate', const LogLine(ts: 4, level: LogLevel.info, msg: 'a\uD800b', attrs: {'k': '\uDC00'}));
      add(
        'numbers',
        const LogLine(
          ts: 5,
          level: LogLevel.fatal,
          msg: 'n',
          attrs: {'big': 1e21, 'small': 1.5e-7, 'neg': -5, 'frac': 123.456},
        ),
      );
      final fixture = File('${Repo.root}/sdk/ios/Tests/RetrieverTests/Fixtures/pre-roundtrip.json');
      if (fixture.existsSync()) {
        for (final v in objs(JsonIn.parseBytes(fixture.readAsBytesSync()))) {
          bodies.add((v['name'] as String, v['body'] as String));
        }
      }
      for (final (name, body) in bodies) {
        final bytes = utf8.encode('$body\n');
        final decoded = LineEncoder.decodeBody(bytes);
        expect(decoded, isNotNull, reason: '$name 解不出');
        final (line, synthetic, truncated) = decoded!;
        final out = LineEncoder.encode(line.copyWith(), synthetic: synthetic, forceTruncated: truncated);
        final s = utf8.decode(out.body);
        expect(s.substring(0, s.length - 1), body, reason: name);
      }
    });
  });

  /// 主代理复审补充（2026-10-01）：configure 之前 purge 的改名兜底、收编中途目录消失续接、bootstrap 定时重试、标记判定短缓存。
  group('PreReviewFixTests', () {
    /// configure 之前的 purgeLocal：改名失败（root 所在目录只读）→ 逐项删除 root 下的内容，删完才完成。
    test('purgeBeforeConfigureFallsBackToDeleteInPlace', () async {
      if (isRootUser()) {
        markTestSkipped('root 用户改得了名');
        return;
      }
      final parent = tempDir('rtv-ro-parent');
      final root = '$parent/retriever';
      final h = await StaticHarness.create(root: root);
      h.log(LogLevel.warn, 'to purge');
      File('$root/install.json').writeAsStringSync('{}');
      Directory('$root/outbox').createSync(recursive: true);
      File('$root/outbox/p1-1-x.gz').writeAsStringSync('x');
      Process.runSync('chmod', ['555', parent]);
      try {
        await Retriever.purgeLocal().timeout(const Duration(seconds: 10));
        expect(Directory(root).existsSync(), isTrue, reason: 'root 还在（改名失败）');
        expect(Directory(root).listSync(), isEmpty, reason: '但里面清空了');
        expect(
          Directory(parent).listSync().every((e) => !e.path.split('/').last.startsWith('retriever.purge-')),
          isTrue,
        );
      } finally {
        Process.runSync('chmod', ['755', parent]);
      }
      h.log(LogLevel.warn, 'after purge');
      await h.configure('');
      await h.settle();
      expect(lines(h).map((l) => l['msg']).toList(), ['after purge']);
    });

    /// 收编进行到一半 root 被删（A6）：pre 文件提交前完整，新会话建好后从偏移 0 重新收编进新会话——全部 pre 行都在新会话里、不计数、不丢。
    test('rootVanishedMidAdoptionReadoptsFromStart', () async {
      final h = await StaticHarness.create();
      for (var i = 0; i < 40; i++) {
        h.log(i == 20 ? LogLevel.fatal : LogLevel.info, 'pre $i');
      }
      var fired = false;
      TestHooks.adoption = (p) {
        if (p == 'record:11' && !fired) {
          fired = true;
          Directory(h.root).deleteSync(recursive: true);
        }
      };
      await h.configure('', const RetrieverOptions(uploadLevel: LogLevel.info));
      await h.settle();
      TestHooks.adoption = null;
      final ls = lines(h);
      expect(ls.where((l) => l['synthetic'] != true).map((l) => l['msg']).toList(), [
        for (var i = 0; i < 40; i++) 'pre $i',
      ], reason: '全部 40 行都在新会话里');
      expect(ls.where((l) => l['tag'] == 'rtv.root_vanished').length, 1);
      expect(ls.where((l) => l['tag'] == DropCounter.tag).length, 0, reason: '不计数');
      expect(DropCounter.pending, 0);
      expect(h.preFiles, isEmpty);
      expect(ls.map((l) => int_(l['seq'])).toList(), [for (var i = 1; i <= ls.length; i++) i]);
      expect(
        JsonIn.obj(File('${h.currentSessionDir()}/meta.json').readAsBytesSync())!.containsKey('pre'),
        isFalse,
        reason: 'meta.pre 已清',
      );
    });

    /// bootstrap 失败后不靠宿主再写一行：调度器 5 s 唤醒一次重试，成功后照常补报计数、startup。
    test('bootstrapRetriedByTimerWithoutLog', () async {
      final h = await StaticHarness.create();
      Fs.writeAtomicFaultForTesting = (p) => p.endsWith('/meta.json');
      await h.configure('');
      await h.settle();
      expect(h.client.isBootstrapped, isFalse);
      h.log(LogLevel.error, 'lost');
      await h.client.onWork(h.client.reschedule);
      expect(
        h.clock.timerDelays.any((d) => d >= 1000 && d <= 5000),
        isTrue,
        reason: '调度器要求了定时唤醒：${h.clock.timerDelays}',
      );
      h.clock.advance(5000);
      await h.client.tickNow();
      expect(h.client.isBootstrapped, isFalse, reason: '还写不成：继续失败');
      Fs.writeAtomicFaultForTesting = null;
      h.clock.advance(5000);
      await h.client.tickNow();
      expect(h.client.isBootstrapped, isTrue);
      final d = obj(lines(h).singleWhere((l) => l['tag'] == DropCounter.tag)['attrs']);
      expect(int_(d['count']), 1);
    });

    /// configure 之前标记判定缓存 1 s（不让每行都列一次目录）；setEnabled 作废缓存。
    test('preMarkerJudgementCachedOneSecond', () async {
      final h = await StaticHarness.create();
      final marker = File(h.marker);
      try {
        h.log(LogLevel.warn, 'a');
        marker.createSync();
        h.log(LogLevel.warn, 'b (cached: not yet seen)');
        h.clock.advance(1000);
        h.log(LogLevel.warn, 'c (marker seen)');
        marker.deleteSync();
        h.log(LogLevel.warn, 'd (still cached as present)');
        Retriever.setEnabled(true);
        h.log(LogLevel.warn, 'e');
        await h.configure('');
        await h.settle();
        expect(lines(h).map((l) => l['msg']).toList(), ['a', 'b (cached: not yet seen)', 'e']);
      } finally {
        if (marker.existsSync()) marker.deleteSync();
      }
    });
  });
}
