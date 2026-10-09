// 对位 Android BlindReviewFixTests.kt：0.3.0 两份盲审之后的修复（A1–A8、B1–B9）。
// 不对位：a7_y10（Android tracker 回调兜 Throwable → 切片 2 的 Java 垫片）。
// 口径差异（Flutter）：a7_y1（configure 期间宿主代码打日志）在 Flutter 里 configure 是异步的，那一刻处于 K1 bootstrapping，
// 行照写 pre 文件、随后收编（不计数）；a7_y2（收编期间的 fatal）不排后台作业（v3 §1 §8），断言改为「行都在、0 次作业」。

import 'dart:async';
import 'dart:io';

import 'package:revdog_retriever/src/drop_counter.dart';
import 'package:revdog_retriever/src/fs.dart';
import 'package:revdog_retriever/src/ids.dart';
import 'package:revdog_retriever/src/json.dart';
import 'package:revdog_retriever/src/model.dart';
import 'package:revdog_retriever/src/outbox.dart';
import 'package:revdog_retriever/src/platform.dart';
import 'package:revdog_retriever/src/pre.dart';
import 'package:revdog_retriever/src/root_purge.dart';
import 'package:test/test.dart';

import 'support/support.dart';

List<SegLineRec> lines(StaticHarness h) => sessionLines(h.currentSessionDir());

const String header =
    '{"pre":1,"started_ms":1790668000000,"process":"main","device":{"os":"android","os_version":"15",'
    '"model":"m","app_version":"1","build":"1","locale":"en","sdk":"retriever-android/0.3.0"}}\n';

String orphan(String root, String content) {
  Directory('$root/pre').createSync(recursive: true);
  final f = File('$root/pre/${Ids.newV4()}.jsonl')..writeAsStringSync(content);
  return f.path;
}

/// 另一个进程看某个会话目录的锁（子进程 `--probe-lock`）。
Future<String> childLockState(String dir) async {
  final (code, out) = await runHelper(['--probe-lock', dir]);
  expect(code, 0);
  return out.trim();
}

bool isRootUser() => (Process.runSync('id', ['-u']).stdout as String).trim() == '0';

/// bootstrap 时调宿主代码打日志的平台（a7_y1）。
class LoggingPlatform extends FakePlatform {
  LoggingPlatform({super.clock, super.transport});

  bool armed = false;

  @override
  Future<BootstrapInfo> bootstrap() {
    if (armed) {
      armed = false;
      Retriever.log(LogLevel.warn, 'from host code during configure');
    }
    return super.bootstrap();
  }
}

void main() {
  setUpRtv();

  /// A1：收编后、孤儿收编后另一个进程看到当前会话仍是 locked（会话锁在专用文件 `lock` 上，meta 重写 / 读都不影响）。
  test('a1_sessionLockSurvivesAdoption', () async {
    final a = await StaticHarness.create();
    await a.configure('');
    await a.settle();
    expect(await childLockState(a.currentSessionDir()), 'locked', reason: 'P1a');

    final b = await StaticHarness.create();
    b.log(LogLevel.warn, 'pre');
    await b.configure('');
    await b.settle();
    expect(JsonIn.obj(File('${b.currentSessionDir()}/meta.json').readAsBytesSync())!.containsKey('pre'), isFalse);
    expect(await childLockState(b.currentSessionDir()), 'locked', reason: 'P1b：收编提交后（meta.json 已重写）');

    final c = await StaticHarness.create();
    orphan(c.root, '$header{"r":0,"ts":1790668000001,"level":"warn","msg":"orphan"}\n');
    await c.configure('');
    await c.settle();
    expect(await childLockState(c.currentSessionDir()), 'locked', reason: 'P1c：孤儿收编（扫了认领）之后');
    // 上传者锁每次选批重新加锁、排空结束即放（v3 §7 第二轮核实）：空闲时另一个进程拿得到
    expect(LockRegistry.heldHere('${c.root}/upload.lock'), isFalse);
  });

  /// A3：进程内首次建 pre 文件之前：拿得到锁的旧 pre 文件超过 8 个或 4 MB → 按 mtime 从最旧的删起；活的不碰。
  test('a3_deadPreFilesTrimmedBeforeFirstCreate', () async {
    final h = await StaticHarness.create();
    final dir = Directory('${h.root}/pre')..createSync(recursive: true);
    final now = DateTime.now();
    final dead = [
      for (var i = 0; i < 10; i++)
        File('${dir.path}/${Ids.newV4()}.jsonl')
          ..writeAsBytesSync(List.filled(600 * 1024, 0x20))
          ..setLastModifiedSync(now.subtract(Duration(minutes: 100 - i))),
    ];
    // 一个活的（本 isolate 里开着、持锁，模拟别的活进程）：最旧，但不碰
    final live = PreFile.create(h.root, Ids.newV4())!;
    File(live.path).setLastModifiedSync(now.subtract(const Duration(minutes: 1000)));
    try {
      h.log(LogLevel.warn, 'first');
      for (var i = 0; i < 4; i++) {
        expect(dead[i].existsSync(), isFalse, reason: '最旧的 $i 删了');
      }
      for (var i = 4; i < 10; i++) {
        expect(dead[i].existsSync(), isTrue, reason: '$i 留着');
      }
      expect(File(live.path).existsSync(), isTrue, reason: '活的不碰');
      expect(PreLog.currentPath, isNotNull);
      expect(DropCounter.pending, 0);
    } finally {
      live.close();
    }
  });

  /// Y1：configure 期间（bootstrap 在途）宿主代码打日志：Flutter 下此刻是 K1 bootstrapping，行照写 pre 文件、随后收编，不丢不计数。
  test('a7_y1_logDuringConfigureWrittenAndAdopted', () async {
    final root = tempDir('rtv-y1');
    final clock = FakeClock();
    final lp = LoggingPlatform(clock: clock, transport: FakeTransport())..rootPath = root;
    await RetrieverRuntime.resetForTesting(platformFactory: () => lp);
    RetrieverRuntime.touch();
    await pump();
    lp.armed = true;
    await Retriever.configure('', baseUrl: base);
    final c = RetrieverRuntime.client!;
    await c.settle();
    final ls = sessionLines('$root/proc-main/${c.writer.currentSessionId}');
    expect(ls.map((l) => l['msg']).toList(), ['from host code during configure']);
    expect(ls.where((l) => l['tag'] == DropCounter.tag), isEmpty);
  });

  /// Y2：收编期间宿主写 100 条 fatal：行都在（进 pre 文件 r = 1、按文件顺序收编），不排后台作业。
  test('a7_y2_fatalDuringAdoptionAllWritten', () async {
    final h = await StaticHarness.create();
    h.log(LogLevel.info, 'pre');
    var fired = false;
    TestHooks.adoption = (p) {
      if (p == 'record:1' && !fired) {
        fired = true;
        for (var i = 0; i < 100; i++) {
          Retriever.log(LogLevel.fatal, 'f$i');
        }
      }
    };
    await h.configure(demoKey);
    await h.settle();
    expect(h.platform.scheduledJobs, isEmpty);
    expect(lines(h).where((l) => (l['msg'] as String?)?.startsWith('f') == true).length, 100);
  });

  /// Y6：`meta.pre` 所指文件判定不了（是目录）= 本轮跳过（不重做、不当普通会话恢复）。
  test('a7_y6_unknownCommitStateSkipsSession', () async {
    final h = await StaticHarness.create();
    final sid = Ids.newV4();
    final dir = Directory('${h.root}/proc-main/$sid')..createSync(recursive: true);
    final pre = '${Ids.newV4()}.jsonl';
    Directory('${h.root}/pre/$pre').createSync(recursive: true);
    File('${dir.path}/meta.json').writeAsStringSync(
      '{"session_id":"$sid","session_no":1,"started_ms":1,"device":{"os":"a","os_version":"b","model":"c",'
      '"app_version":"d","build":"e","locale":"f","sdk":"g"},"process":"main","pre":"$pre"}',
    );
    File('${dir.path}/seg-000001.open').writeAsStringSync(
      '{"v":1,"seg_no":1,"user_id":null,"started_ms":1}\n{"seq":1,"oseq":1,"ts":1,"level":"warn","msg":"partial"}\n',
    );
    await h.configure('');
    await h.settle();
    expect(File('${dir.path}/seg-000001.open').existsSync(), isTrue, reason: '没当普通会话恢复（没封段）');
    expect(h.readJsonl('sessions.jsonl').any((c) => c['session_id'] == sid), isFalse);
    expect(h.envelopes().any((e) => e['session_id'] == sid), isFalse);
  });

  /// Y8：configure 之前用户切换记录写失败 → pre 文件标坏（粘滞），之后的行计数，不挂到错的用户名下。
  test('a7_y8_userRecordFailureMarksBroken', () async {
    final h = await StaticHarness.create();
    h.log(LogLevel.warn, 'a');
    TestHooks.preWriteFault = (b) => String.fromCharCodes(b).startsWith('{"pre_user"');
    try {
      Retriever.setUser('u');
    } finally {
      TestHooks.preWriteFault = null;
    }
    h.log(LogLevel.warn, 'b');
    await h.configure('');
    await h.settle();
    final ls = lines(h);
    expect(ls.where((l) => l['synthetic'] != true).map((l) => l['msg']).toList(), ['a']);
    expect(int_(obj(ls.singleWhere((l) => l['tag'] == DropCounter.tag)['attrs'])['count']), 1);
  });

  /// Y9：收编抛异常 → 置重试、startup 照常；5 s 后接着收编，不重复写已收编的记录。
  test('a7_y9_adoptionExceptionDoesNotBlockStartup', () async {
    final h = await StaticHarness.create();
    for (var i = 0; i < 10; i++) {
      h.log(LogLevel.warn, 'pre $i');
    }
    var fired = false;
    TestHooks.adoption = (p) {
      if (p == 'record:4' && !fired) {
        fired = true;
        throw StateError('boom');
      }
    };
    await h.configure('');
    await h.settle();
    expect(h.client.engine.recovered, isTrue, reason: 'startup 照常执行');
    expect(h.client.writer.isAdopting, isTrue);
    h.clock.advance(5000);
    await h.client.tickNow();
    expect(h.client.writer.isAdopting, isFalse);
    expect(lines(h).map((l) => l['msg']).toList(), [for (var i = 0; i < 10; i++) 'pre $i']);
    expect(h.errors.length, 1);
    h.errors.clear();
  });

  /// Y12：purge 改名失败的兜底只删 purge 时刻列出的条目；之后新建的 pre 文件与状态不碰。
  test('a7_y12_purgeFallbackDeletesOnlyListedEntries', () async {
    final root = tempDir();
    Directory('$root/pre').createSync(recursive: true);
    File('$root/pre/old.jsonl').writeAsStringSync('x');
    File('$root/install.json').writeAsStringSync('{}');
    final listed = await RootPurge.snapshot(root);
    final fresh = File('$root/pre/new.jsonl')..writeAsStringSync('y');
    final state = Directory('$root/outbox')..createSync(recursive: true);
    await RootPurge.deleteListed(listed);
    expect(File('$root/pre/old.jsonl').existsSync(), isFalse);
    expect(File('$root/install.json').existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue, reason: 'purge 之后新建的 pre 文件留着');
    expect(state.existsSync(), isTrue);
  });

  /// Y15：收编中 reconfigure 换了 redact：之后的 r = 0 行立即用新钩子。
  test('a7_y15_redactSwappedMidAdoption', () async {
    final h = await StaticHarness.create();
    for (var i = 0; i < 6; i++) {
      h.log(LogLevel.warn, 'pre $i');
    }
    var fired = false;
    TestHooks.adoption = (p) {
      if (p == 'record:3' && !fired) {
        fired = true;
        Retriever.configure(
          '',
          baseUrl: base,
          options: RetrieverOptions(redact: (l) => l.copyWith(msg: 'new')),
        ).ignore();
      }
    };
    await h.configure('', RetrieverOptions(redact: (l) => l));
    await h.settle();
    expect(lines(h).map((l) => l['msg']).toList(), ['pre 0', 'pre 1', 'new', 'new', 'new', 'new']);
  });

  /// A8 (1)：configure 之前 setEnabled(true) 而标记删不掉：不记显式 true、保持禁用（P5）。
  test('a8_1_setEnabledTrueWithUndeletableMarkerStaysDisabled', () async {
    if (isRootUser()) {
      markTestSkipped('root 用户删得掉');
      return;
    }
    final parent = tempDir('rtv-a8');
    final root = '$parent/retriever';
    Directory(root).createSync(recursive: true);
    final marker = File('$parent/retriever.disabled')..createSync();
    final h = await StaticHarness.create(root: root);
    Process.runSync('chmod', ['555', parent]);
    try {
      Retriever.setEnabled(true);
      expect(marker.existsSync(), isTrue);
      expect(Retriever.isEnabled, isFalse);
      h.log(LogLevel.warn, 'not written');
      expect(h.preFiles, isEmpty);
      await h.configure('');
      await h.settle();
      expect(Retriever.isEnabled, isFalse);
    } finally {
      Process.runSync('chmod', ['755', parent]);
    }
  });

  /// A8 (8)：孤儿缺头记录：started_ms 取首行 ts；(11) 读 pre 记录时用户 id / process / device 再清洗。
  test('a8_8_11_orphanStartedMsAndResanitize', () async {
    final h = await StaticHarness.create();
    final noHeader = orphan(h.root, '{"r":0,"ts":1790000000123,"level":"warn","msg":"no header"}\n');
    orphan(
      h.root,
      '${header.replaceFirst('"process":"main"', '"process":"a:b"')}{"pre_user":"\\u0001u\\u0002"}\n'
      '{"r":0,"ts":1790668000002,"level":"warn","msg":"dirty"}\n',
    );
    await h.configure('');
    await h.settle();
    expect(File(noHeader).existsSync(), isFalse);
    final dirs = h.sessionDirs().where((d) => !d.endsWith(h.client.writer.currentSessionId)).toList();
    final a = dirs.singleWhere((d) => sessionLines(d).any((l) => l['msg'] == 'no header'));
    expect(int_(JsonIn.obj(File('$a/meta.json').readAsBytesSync())!['started_ms']), 1790000000123);
    final b = dirs.singleWhere((d) => sessionLines(d).any((l) => l['msg'] == 'dirty'));
    expect(JsonIn.obj(File('$b/meta.json').readAsBytesSync())!['process'], 'a_b');
    expect(segHeaders(b).any((x) => x['user_id'] == 'u'), isTrue);
  });

  /// B1：恢复旧会话成功完成之前一律不驱逐（总闸门）。
  test('b1_noEvictionBeforeRecovery', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    h.l(LogLevel.warn, 'w');
    await h.seal();
    final box = h.outboxFiles();
    expect(box.length, 1);
    await h.work((e) async {
      e.recovered = false;
      e.effective.config = e.effective.config.copyWith(localCapBytes: 0);
      await e.evictIfNeeded();
    });
    expect(h.outboxFiles(), box, reason: '恢复没做完：不驱逐');
    await h.work((e) async {
      e.recovered = true;
      await e.evictIfNeeded();
    });
    expect(h.outboxFiles(), isEmpty);
  });

  /// B1 场景：旧会话有「已封未物化」的义务段且超过 7 天 + configure 之前 log → setUser → log：旧会话的义务行必须进批或有墓碑。
  test('b1_oldSealedObligationNeverSilentlyLost', () async {
    final h = await StaticHarness.create();
    final sid = Ids.newV4();
    final dir = Directory('${h.root}/proc-main/$sid')..createSync(recursive: true);
    File('${dir.path}/meta.json').writeAsStringSync(
      '{"session_id":"$sid","session_no":1,"started_ms":1,"device":{"os":"a","os_version":"b","model":"c",'
      '"app_version":"d","build":"e","locale":"f","sdk":"g"},"process":"main"}',
    );
    File(
      '${dir.path}/cursor.json',
    ).writeAsStringSync('{"extracted_through_oseq":0,"ctx_through_seq":0,"last_state":"bg","last_state_ms":1}');
    final seg = File('${dir.path}/seg-000001.sealed')
      ..writeAsStringSync(
        '{"v":1,"seg_no":1,"user_id":null,"started_ms":1}\n'
        '${[for (var i = 1; i <= 3; i++) '{"seq":$i,"oseq":$i,"ts":$i,"level":"warn","msg":"old $i"}\n'].join()}',
      );
    seg.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 8)));
    h.platform.available = 1;
    h.log(LogLevel.warn, 'p1');
    Retriever.setUser('u');
    h.log(LogLevel.warn, 'p2');
    await h.configure('');
    await h.settle();
    final inBatch = h
        .envelopes()
        .where((e) => e['session_id'] == sid)
        .expand((e) => e.lines.map((l) => int_(l['oseq'])))
        .toSet();
    final tombs = <int>{};
    for (final d in h.readJsonl('drops.jsonl').where((d) => d['session_id'] == sid)) {
      for (var o = int_(d['oseq_from']); o <= int_(d['oseq_to']); o++) {
        tombs.add(o);
      }
    }
    for (var o = 1; o <= 3; o++) {
      expect(inBatch.contains(o) || tombs.contains(o), isTrue, reason: 'oseq $o 进批或有墓碑');
    }
  });

  /// B2：1 MB 上限只管 configure 之前；pre 写满后 configure，收编期间宿主写的 20 条 error 全部落盘，计数不变。
  test('b2_postConfigureLinesNotCapped', () async {
    final h = await StaticHarness.create();
    final big = 'x' * 3000;
    var i = 0;
    while (DropCounter.pending == 0 && i < 5000) {
      h.log(LogLevel.info, 'fill ${i++} $big');
    }
    final counted = DropCounter.pending;
    expect(counted, greaterThan(0));
    var fired = false;
    TestHooks.adoption = (p) {
      if (p == 'record:2' && !fired) {
        fired = true;
        for (var k = 0; k < 20; k++) {
          Retriever.log(LogLevel.error, 'during adoption $k');
        }
      }
    };
    await h.configure('', const RetrieverOptions(uploadLevel: LogLevel.info));
    await h.settle();
    final ls = lines(h);
    expect(ls.map((l) => l['msg'] as String).where((m) => m.startsWith('during')).toList(), [
      for (var k = 0; k < 20; k++) 'during adoption $k',
    ]);
    expect(int_(obj(ls.singleWhere((l) => l['tag'] == DropCounter.tag)['attrs'])['count']), counted);
  });

  /// B3：临时 writer 收编（孤儿）有行没写成 → 不提交：meta.pre 与 pre 文件原样保留，下次启动重做。
  test('b3_tempWriterFailureDoesNotCommit', () async {
    if (isRootUser()) {
      markTestSkipped('root 用户写得进只读目录');
      return;
    }
    final h = await StaticHarness.create();
    final f = orphan(
      h.root,
      '$header{"r":0,"ts":1790668000001,"level":"warn","msg":"a"}\n{"r":0,"ts":1790668000002,"level":"warn","msg":"b"}\n'
      '{"pre_user":"u"}\n{"r":0,"ts":1790668000003,"level":"warn","msg":"c"}\n',
    );
    final proc = '${h.root}/proc-main';
    var fired = false;
    TestHooks.adoption = (p) {
      if (p == 'record:3' && !fired) {
        fired = true;
        for (final d in Directory(proc).listSync()) {
          Process.runSync('chmod', ['555', d.path]);
        }
      }
    };
    try {
      await h.configure('');
      await h.settle();
    } finally {
      TestHooks.adoption = null;
      for (final d in Directory(proc).listSync()) {
        Process.runSync('chmod', ['755', d.path]);
      }
    }
    expect(File(f).existsSync(), isTrue, reason: 'pre 文件原样保留');
    final od = h.sessionDirs().singleWhere((d) => !d.endsWith(h.client.writer.currentSessionId));
    expect(JsonIn.obj(File('$od/meta.json').readAsBytesSync())!['pre'], f.split('/').last);
    final odSid = od.split('/').last;
    expect(h.envelopes().any((e) => e['session_id'] == odSid), isFalse, reason: '没物化');
    expect(h.readJsonl('sessions.jsonl').any((c) => c['session_id'] == odSid), isFalse);
    final h2 = await h.restart();
    await h2.configure('');
    await h2.settle();
    expect(File(f).existsSync(), isFalse);
    expect(sessionLines(od).map((l) => l['msg']).toList(), ['a', 'b', 'c']);
  });

  /// B4：配置缓存记用户：缓存是用户 A 拉的（远程明确给 upload_level = debug），离线冷启动、configure 之前 setUser("B") → B 的 info 无 oseq。
  test('b4_configCacheBelongsToUser', () async {
    final t = FakeTransport()..configBody = {'etag': 'e', 'ttl_s': 1800, 'upload_level': 'debug'};
    final h = await StaticHarness.create(transport: t);
    await h.configure(demoKey);
    Retriever.setUser('A');
    await h.settle();
    final cfg = JsonIn.obj(File('${h.root}/config.json').readAsBytesSync())!;
    expect(cfg['user_id'], 'A');
    expect(cfg.keys.toList(), ['fetched_ms', 'key_fp', 'base_url', 'user_id', 'config', 'from_host']);
    final t2 = FakeTransport()..configGate = Completer<void>();
    final h2 = await h.restart(transport: t2);
    Retriever.setUser('B');
    h2.log(LogLevel.info, 'b info');
    await h2.configure(demoKey);
    await h2.client.onWork(() {});
    expect(h2.client.engine.configCache!.identityStale, isTrue);
    expect(int_(lines(h2).singleWhere((l) => l['msg'] == 'b info')['oseq']), -999);
    t2.configGate!.complete();
    t2.configGate = null;
    await h2.settle();
  });

  /// B5：flush 兜底计时器不排在引擎队列上：引擎被堵 1.5 s，300 ms 窗口到期照样回 pending("timeout")。
  test('b5_flushTimerFiresWhileEngineBlocked', () async {
    final h = await Harness.create();
    await h.settle();
    h.client.setFlushWindowForTesting(300);
    final gate = await h.blockEngine();
    final sw = Stopwatch()..start();
    final r = await Retriever.flush().timeout(const Duration(milliseconds: 1200));
    expect(sw.elapsedMilliseconds, lessThan(1200), reason: '窗口到期就回，不等引擎队列');
    gate.complete();
    expect(r, FlushResult.pending('timeout'));
    await h.settle();
  });

  /// B6：`rtv.pre_init_dropped` 强制写入、强制义务（不受 local_level / upload_level 影响）。
  test('b6_droppedLineForcedObligation', () async {
    final h = await StaticHarness.create(noRoot: true);
    h.log(LogLevel.debug, 'lost 1');
    h.log(LogLevel.debug, 'lost 2');
    h.platform.rootMode = CallMode.ok;
    await h.configure('', const RetrieverOptions(localLevel: LogLevel.error, uploadLevel: LogLevel.fatal));
    await h.settle();
    final d = lines(h).singleWhere((l) => l['tag'] == DropCounter.tag);
    expect(int_(d['oseq']), 1);
    expect(int_(obj(d['attrs'])['count']), 2);
  });

  /// B7：驱逐先记墓碑、记成了再删；墓碑写不成本轮不驱逐该项。
  test('b7_evictionWritesTombstoneFirst', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    h.l(LogLevel.warn, 'w');
    await h.seal();
    final box = h.outboxFiles();
    final drops = Directory('${h.root}/drops.jsonl')..createSync();
    await h.work((e) async {
      e.effective.config = e.effective.config.copyWith(localCapBytes: 0);
      await e.evictIfNeeded();
    });
    expect(h.outboxFiles(), box, reason: '墓碑写不成：不驱逐');
    drops.deleteSync();
    await h.work((e) => e.evictIfNeeded());
    expect(h.outboxFiles(), isEmpty);
    expect(h.readJsonl('drops.jsonl').single['reason'], 'buffer_overflow');
  });

  /// B9：bootstrap 重试时保留待写的合成行（install.json 修复的 `rtv.install_repaired`）。
  test('b9_pendingSyntheticSurvivesBootstrapRetry', () async {
    final h = await StaticHarness.create();
    await h.configure('');
    h.log(LogLevel.warn, 'first run');
    await h.settle();
    final iid = Retriever.installId;
    final h2 = await h.restart();
    File('${h2.root}/install.json').writeAsStringSync('{"install_id":"bad');
    Fs.writeAtomicFaultForTesting = (p) => p.endsWith('/meta.json');
    await h2.configure('');
    await h2.settle();
    expect(h2.client.isBootstrapped, isFalse);
    Fs.writeAtomicFaultForTesting = null;
    h2.clock.advance(5000);
    await h2.client.tickNow();
    expect(h2.client.isBootstrapped, isTrue);
    expect(Retriever.installId, iid);
    expect(lines(h2).where((l) => l['tag'] == 'rtv.install_repaired').length, 1);
  });

  /// B6 / A4 配套：被 local_level 过滤的级别也不影响计数行；内部计数只在下一次唤醒时一条上报。
  test('b6_a4_countReportedOnceAtTick', () async {
    final h = await StaticHarness.create();
    await h.configure('', const RetrieverOptions(localLevel: LogLevel.error));
    await h.settle();
    for (var i = 0; i < 7; i++) {
      DropCounter.add(LogLevel.info, h.clock.wallMs());
    }
    expect(lines(h).where((l) => l['tag'] == DropCounter.tag), isEmpty);
    await h.client.tickNow();
    final d = lines(h).singleWhere((l) => l['tag'] == DropCounter.tag);
    expect(int_(obj(d['attrs'])['count']), 7);
    h.client.writer.rotate(SealReason.timer);
  });
}
