// 切片 1 审计修复（`docs/audit/2026-10-09-m4-slice1/audit-opus.md`；v3 §10 裁决）的回归用例，全部走静态入口
// （#5 另有 Text 单元断言，#11 直接测根级锁原语）。#1 在 transport_test，#10 的滞后探针在 flutter_specific_test。

import 'dart:async';
import 'dart:io';

import 'package:revdog_retriever/src/drop_counter.dart';
import 'package:revdog_retriever/src/fs.dart';
import 'package:revdog_retriever/src/ids.dart';
import 'package:revdog_retriever/src/json.dart';
import 'package:revdog_retriever/src/limits.dart';
import 'package:revdog_retriever/src/outbox.dart';
import 'package:revdog_retriever/src/platform.dart';
import 'package:revdog_retriever/src/pre.dart';
import 'package:revdog_retriever/src/text.dart';
import 'package:test/test.dart';

import 'support/support.dart';

/// `root()` 回包的进程名可配（null = 按 v3 §3 契约原文只回 `{root, token}`）；`bootstrap()` 回 [processName]。
class _RootProcessPlatform extends FakePlatform {
  _RootProcessPlatform(this.rootProcess);

  final String? rootProcess;

  @override
  Future<RootInfo> root() {
    rootCalls++;
    return Future<RootInfo>.value(RootInfo(root: rootPath!, token: token, process: rootProcess, device: deviceFields));
  }
}

/// 一个会话目录里按段号排列的 `[段头 user_id, [非合成行的 msg…]]`。
List<List<Object?>> segments(String dir) {
  final names = (Fs.listSync(dir) ?? const <String>[]).where((n) => n.startsWith('seg-')).toList()
    ..sort((a, b) => int.parse(a.substring(4, 10)).compareTo(int.parse(b.substring(4, 10))));
  final out = <List<Object?>>[];
  for (final n in names) {
    final ls = readSegmentLines('$dir/$n');
    final hdr = JsonIn.objText(ls.first)!;
    final msgs = <Object?>[];
    for (final l in ls.skip(1)) {
      final o = JsonIn.objText(l);
      if (o != null && o['synthetic'] != true) msgs.add(o['msg']);
    }
    out.add([hdr['user_id'], msgs]);
  }
  return out;
}

int taggedLines(StaticHarness h, String tag) =>
    sessionLines(h.currentSessionDir()).where((l) => l['tag'] == tag).length;

Future<void> waitClient() => waitUntil(() => RetrieverRuntime.client != null);

/// 另一个进程看某个文件的 fcntl 锁（子 Dart 进程试一次非阻塞独占锁）：locked / free。
Future<String> childFileLock(String path) async {
  final dir = tempDir('rtv-probe');
  final script = File('$dir/probe.dart')
    ..writeAsStringSync('''
import 'dart:io';
void main(List<String> a) {
  final raf = File(a[0]).openSync(mode: FileMode.append);
  try {
    raf.lockSync(FileLock.exclusive);
    stdout.write('free');
    raf.unlockSync();
  } catch (_) {
    stdout.write('locked');
  }
  raf.closeSync();
}
''');
  final r = await Process.run(Platform.resolvedExecutable, [script.path, path]);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return (r.stdout as String).trim();
}

const String _otherHeader =
    '{"pre":1,"started_ms":1790668000000,"process":"main","device":{"os":"android","os_version":"15",'
    '"model":"m","app_version":"1","build":"1","locale":"en","sdk":"retriever-flutter/0.1.0"}}\n';

String _preLine(String msg) => '{"r":0,"ts":1790668000001,"level":"warn","msg":"$msg"}\n';

void main() {
  setUpRtv();

  // ---------------------------------------------------------------- #2
  group('#2 再次 configure 的进程名来源 = 实例（bootstrap 回包）', () {
    for (final rp in <String?>[null, 'main']) {
      test('sameParamsReconfigureNoWarn_rootProcess_${rp ?? 'absent'}', () async {
        final p = _RootProcessPlatform(rp)..processName = 'remote';
        final h = await StaticHarness.create(platform: p, clock: p.clock as FakeClock);
        await h.configure('');
        await h.settle();
        expect(h.client.processName, 'remote');
        await h.configure('');
        await h.configure('');
        await h.settle();
        expect(taggedLines(h, 'rtv.reconfigure_ignored'), 0, reason: '同参数重复 configure 零 reconfigure_ignored');
        // 对照：显式给了不同的 processName → 照常一条
        await h.configure('', const RetrieverOptions(processName: 'other'));
        await h.settle();
        expect(taggedLines(h, 'rtv.reconfigure_ignored'), 1);
        expect(h.client.processName, 'remote');
      });
    }
  });

  // ---------------------------------------------------------------- #3
  group('#3 bootstrapping 窗口里的用户切换：用户边界 = 段边界，归属与调用顺序一致', () {
    /// setUser(a) 在 bootstrap 回包前（此时还没有 pre 文件）；log / setUser(null) / log / setUser(b) / log 在 prepare 的异步间隙里。
    test('setUserLogSequenceInWindowGivesThreeSegments', () async {
      final h = await StaticHarness.create();
      final gate = Completer<void>();
      h.platform.bootstrapGate = gate;
      final f = h.configure('', const RetrieverOptions(uploadLevel: LogLevel.info));
      await pump();
      expect(RetrieverRuntime.state, RetrieverState.bootstrapping);
      Retriever.setUser('a');
      expect(h.preFiles, isEmpty);
      var inGap = false;
      TestHooks.prepareGap = () async {
        TestHooks.prepareGap = null;
        inGap = RetrieverRuntime.client == null && RetrieverRuntime.state == RetrieverState.bootstrapping;
        h.log(LogLevel.info, 'l1');
        Retriever.setUser(null);
        h.log(LogLevel.info, 'l2');
        Retriever.setUser('b');
        h.log(LogLevel.info, 'l3');
      };
      gate.complete();
      await f;
      await h.settle();
      expect(inGap, isTrue);
      expect(segments(h.currentSessionDir()), [
        [
          'a',
          ['l1'],
        ],
        [
          null,
          ['l2'],
        ],
        [
          'b',
          ['l3'],
        ],
      ]);
      expect(h.client.writer.currentUser, 'b');
    });

    /// 审计实证的那条：setUser(a) 在 bootstrap 回包前（没有 pre 文件），间隙里先登出再写 → 这一行不能落进 a 的段。
    test('logoutInPrepareGapNeverAttributedToPreviousUser', () async {
      final h = await StaticHarness.create();
      final gate = Completer<void>();
      h.platform.bootstrapGate = gate;
      final f = h.configure('', const RetrieverOptions(uploadLevel: LogLevel.info));
      await pump();
      Retriever.setUser('a');
      TestHooks.prepareGap = () async {
        TestHooks.prepareGap = null;
        Retriever.setUser(null);
        h.log(LogLevel.info, 'after logout');
        Retriever.setUser('b');
        h.log(LogLevel.info, 'as b');
      };
      gate.complete();
      await f;
      await h.settle();
      final segs = segments(h.currentSessionDir());
      expect(segs, [
        [
          null,
          ['after logout'],
        ],
        [
          'b',
          ['as b'],
        ],
      ]);
      expect(segs.where((s) => s[0] == 'a'), isEmpty, reason: '登出后的行不能挂到 a 名下');
    });
  });

  // ---------------------------------------------------------------- #4
  group('#4 bootstrap 时生效开关为 false → 丢弃已累计的计数（v3 §1.1）', () {
    /// 禁用标记在、没有显式值：root 回包前计的数在 bootstrap 时丢弃，之后重新启用也不上报。
    test('markerPresentWithoutExplicitDiscards', () async {
      final h = await StaticHarness.create(noRoot: true);
      File(h.marker).createSync();
      h.log(LogLevel.warn, 'w');
      h.log(LogLevel.error, 'e');
      expect(DropCounter.pending, 2, reason: 'root 未知：标记判定不了，只计数');
      await h.configure('');
      await h.settle();
      expect(Retriever.isEnabled, isFalse);
      expect(DropCounter.pending, 0, reason: '生效开关 false：丢弃');
      Retriever.setEnabled(true);
      await h.settle();
      expect(taggedLines(h, DropCounter.tag), 0);
    });

    /// 显式 true（标记在）：保留并上报。
    test('explicitTrueWithMarkerKeepsAndReports', () async {
      final h = await StaticHarness.create(noRoot: true);
      File(h.marker).createSync();
      h.log(LogLevel.warn, 'w');
      h.log(LogLevel.error, 'e');
      Retriever.setEnabled(true);
      await h.configure('');
      await h.settle();
      expect(Retriever.isEnabled, isTrue);
      expect(File(h.marker).existsSync(), isFalse, reason: 'root 到达时补做落盘');
      final d = sessionLines(h.currentSessionDir()).singleWhere((l) => l['tag'] == DropCounter.tag);
      expect(obj(d['attrs'])['count'], 2);
      expect(obj(d['attrs'])['error_count'], 1);
      expect(DropCounter.pending, 0);
    });

    /// 显式 false：之后的行一开始就不计；之前已计的在 bootstrap 时丢弃（生效开关 false）；重新启用也不上报。
    test('explicitFalseNeverCountsAndDiscardsEarlier', () async {
      final h = await StaticHarness.create(noRoot: true);
      h.log(LogLevel.warn, 'counted before consent withdrawn');
      expect(DropCounter.pending, 1);
      Retriever.setEnabled(false);
      h.log(LogLevel.warn, 'w');
      h.log(LogLevel.error, 'e');
      expect(DropCounter.pending, 1, reason: '显式 false 之后不计');
      await h.configure('');
      await h.settle();
      expect(DropCounter.pending, 0);
      Retriever.setEnabled(true);
      await h.settle();
      expect(taggedLines(h, DropCounter.tag), 0);
    });
  });

  // ---------------------------------------------------------------- #5
  group('#5 user_id 空白判定逐字对位 Android（Char.isWhitespace，不用 String.trim）', () {
    test('sanitizeUserIdBlankRule', () {
      // U+FEFF（Cf）不是空白：保留（Dart 的 trim 会剥掉它）
      expect(Text.sanitizeUserId('﻿'), '﻿');
      expect(Text.sanitizeUserId('​'), '​');
      // Unicode White_Space：纯空白 = null
      for (final ws in [' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', '　', ' ']) {
        expect(Text.sanitizeUserId(ws), isNull, reason: 'U+${ws.codeUnitAt(0).toRadixString(16)}');
      }
      expect(Text.sanitizeUserId('   　 '), isNull);
      // 控制字符先删、剩下纯空白 = null；不修剪非空的值
      expect(Text.sanitizeUserId('\u0085\u0009 \u000A'), isNull);
      expect(Text.sanitizeUserId(' a '), ' a ');
      expect(Text.sanitizeUserId('﻿ '), '﻿ ');
    });

    test('setUserBlankRuleThroughStaticEntry', () async {
      final h = await StaticHarness.create();
      await h.configure('');
      await h.settle();
      Retriever.setUser('x');
      Retriever.setUser('  ');
      expect(h.client.writer.currentUser, isNull, reason: 'Unicode White_Space = 空 = null');
      Retriever.setUser('﻿');
      expect(h.client.writer.currentUser, '﻿');
    });
  });

  // ---------------------------------------------------------------- #6
  group('#6 非 owner 触达时按 ≥ 60 s 间隔重试 bootstrap', () {
    test('nonOwnerTouchRetriesOncePer60s', () async {
      final h = await StaticHarness.create();
      h.platform.owner = false;
      await h.configure('');
      expect(RetrieverRuntime.state, RetrieverState.nonOwner);
      expect(h.platform.bootstrapCalls, 1);
      // 60 s 内触达（log / setUser / flush）：不重试
      h.clock.advance(ClientConstants.nonOwnerRetryMs - 1000);
      h.log(LogLevel.warn, 'n1');
      Retriever.setUser('u');
      expect(await Retriever.flush(), FlushResult.pending('paused'));
      await pump();
      expect(h.platform.bootstrapCalls, 1);
      // 满 60 s：触达重试一次（连续触达不重复排）
      h.clock.advance(1000);
      h.log(LogLevel.warn, 'n2');
      h.log(LogLevel.warn, 'n3');
      Retriever.setUser('v');
      await Retriever.flush();
      await pump();
      expect(h.platform.bootstrapCalls, 2);
      expect(RetrieverRuntime.state, RetrieverState.nonOwner);
      // 重新计时：又 60 s 内不重试
      h.clock.advance(ClientConstants.nonOwnerRetryMs - 1);
      h.log(LogLevel.warn, 'n4');
      await pump();
      expect(h.platform.bootstrapCalls, 2);
      // owner 已释放（例如 iOS destroyContext 没有 ownerReleased）：60 s 后的触达接任
      h.platform.owner = true;
      h.clock.advance(1);
      h.log(LogLevel.warn, 'n5');
      await waitClient();
      await h.settle();
      expect(RetrieverRuntime.state, RetrieverState.ready);
      expect(h.platform.bootstrapCalls, 3);
      final msgs = sessionLines(h.currentSessionDir()).map((l) => l['msg']).toList();
      expect(msgs, containsAll(['n1', 'n2', 'n3', 'n4', 'n5']));
      expect(h.preFiles, isEmpty);
    });

    /// 事件（willEnterForeground / ownerReleased）照旧立即重试，不受 60 s 间隔约束。
    test('nonOwnerEventsStillRetryImmediately', () async {
      final h = await StaticHarness.create();
      h.platform.owner = false;
      await h.configure('');
      h.platform.handler!.willEnterForeground();
      await pump();
      expect(h.platform.bootstrapCalls, 2);
      h.platform.handler!.ownerReleased();
      await pump();
      expect(h.platform.bootstrapCalls, 3);
      expect(RetrieverRuntime.state, RetrieverState.nonOwner);
    });
  });

  // ---------------------------------------------------------------- #7
  group('#7 实例建成前到达的 didEnterBackground：立即 end，前后台状态记下', () {
    Map<String, Object?> cursorOf(StaticHarness h) =>
        JsonIn.obj(File('${h.currentSessionDir()}/cursor.json').readAsBytesSync())!;

    /// bootstrapping 窗口（回包前）：立即 end；回包 foreground 为 null → 用记下的 bg 作初值。
    test('beforeReplyEndsTaskAndSeedsNullForeground', () async {
      final h = await StaticHarness.create();
      final gate = Completer<void>();
      h.platform.bootstrapGate = gate;
      h.platform.foreground = null;
      final f = h.configure('');
      await pump();
      h.platform.handler!.didEnterBackground(42);
      await pump();
      expect(h.platform.endedTasks, [42], reason: '实例还没建成也立即 end');
      gate.complete();
      await f;
      await h.settle();
      expect(cursorOf(h)['last_state'], 'bg');
    });

    /// 回包 foreground 非 null：以回包（回包时刻 tracker 的值）为准。
    test('beforeReplyNonNullForegroundWins', () async {
      final h = await StaticHarness.create();
      final gate = Completer<void>();
      h.platform.bootstrapGate = gate;
      final f = h.configure('');
      await pump();
      h.platform.handler!.didEnterBackground(null);
      await pump();
      expect(h.platform.endedTasks, isEmpty, reason: '没有 id 不调 end');
      gate.complete();
      await f;
      await h.settle();
      expect(cursorOf(h)['last_state'], 'fg');
    });

    /// 回包之后、实例发布之前（prepare 的异步间隙）：事件比回包新，发布时生效。
    test('inPrepareGapEndsTaskAndAppliesAfterPublish', () async {
      final h = await StaticHarness.create();
      TestHooks.prepareGap = () async {
        TestHooks.prepareGap = null;
        h.platform.handler!.didEnterBackground(9);
      };
      await h.configure('');
      await h.settle();
      expect(h.platform.endedTasks, [9]);
      expect(cursorOf(h)['last_state'], 'bg');
    });

    /// failed（原生可能已登记本引擎为 owner）：同样立即 end；之后建实例时回包 foreground 为 null → 用记下的状态。
    test('failedStateEndsTaskAndRemembers', () async {
      final h = await StaticHarness.create();
      h.platform.bootstrapMode = CallMode.fail;
      await h.configure('');
      expect(RetrieverRuntime.state, RetrieverState.failed);
      h.platform.handler!.didEnterBackground(7);
      h.platform.handler!.didEnterBackground(null);
      await pump();
      expect(h.platform.endedTasks, [7]);
      h.platform.bootstrapMode = CallMode.ok;
      h.platform.foreground = null;
      await h.configure('');
      await h.settle();
      expect(RetrieverRuntime.state, RetrieverState.ready);
      expect(cursorOf(h)['last_state'], 'bg');
    });
  });

  // ---------------------------------------------------------------- #8
  group('#8 交接后 attach 失败：回退（同 Android handoffFailed）', () {
    test('attachFailureKeepsPreFileForNextRetry', () async {
      final h = await StaticHarness.create();
      h.log(LogLevel.warn, 'before');
      final pre = h.preFiles.single;
      var fired = false;
      TestHooks.adoption = (p) {
        if (p == 'attach' && !fired) {
          fired = true;
          throw StateError('attach boom');
        }
      };
      await h.configure('', const RetrieverOptions(uploadLevel: LogLevel.info));
      expect(fired, isTrue);
      expect(RetrieverRuntime.state, RetrieverState.failed);
      expect(RetrieverRuntime.client, isNull);
      expect(h.errors.whereType<StateError>().length, 1);
      h.errors.clear();
      // pre 文件不丢：还在、flock 仍持有（没被关掉；先探锁——本进程里读它会开关 fd、放掉锁）、仍是本进程正在写的那个、可继续追加
      expect(h.preFiles, [pre]);
      expect(await childFileLock(pre), 'locked', reason: 'flock 仍持有（没被关掉）');
      expect(PreLog.currentPath, File(pre).path);
      h.log(LogLevel.warn, 'after failure');
      expect(readJsonlAt(pre).where((r) => r.containsKey('r')).map((r) => r['msg']), ['before', 'after failure']);
      // 下次重试（显式 configure）再收编
      await h.configure('', const RetrieverOptions(uploadLevel: LogLevel.info));
      await h.settle();
      expect(RetrieverRuntime.state, RetrieverState.ready);
      final msgs = sessionLines(h.currentSessionDir()).map((l) => l['msg']).toList();
      expect(msgs, containsAllInOrder(['before', 'after failure']));
      expect(h.preFiles, isEmpty);
      expect(DropCounter.pending, 0);
    });
  });

  // ---------------------------------------------------------------- #9
  group('#9 同 token 的外来 pre 文件（同进程别的引擎）', () {
    /// 收编（configure 时的本进程 pre 与 startup 的孤儿收编）、首次建 pre 文件前的 `_trimDead`、驱逐的 7 天删除三条路径都不打开它：
    /// 不收编、不删、它的 flock 仍在；进程死后（flock 可得且 token 不同）才当孤儿收编。
    test('sameTokenForeignPreFileNeverOpened', () async {
      final h = await StaticHarness.create();
      final tok = h.platform.token;
      Directory('${h.root}/pre').createSync(recursive: true);
      final other = File('${h.root}/pre/$tok-${Ids.newV4()}.jsonl')
        ..writeAsStringSync(_otherHeader + _preLine('other engine line'));
      final bytes = other.readAsBytesSync();
      // 「别的引擎」持锁（同进程：本进程任何 fd 的开关都会放掉它）
      final raf = other.openSync(mode: FileMode.append)..lockSync(FileLock.exclusive);
      // 比 7 天老（按 SDK 的墙钟）
      other.setLastModifiedSync(DateTime.fromMillisecondsSinceEpoch(h.clock.wallMs() - 8 * ClientConstants.dayMs));
      // 另有 9 个死掉的孤儿（别的 token、没人持锁）：超过 8 个 → 首次建 pre 文件前修剪
      final dead = <File>[];
      for (var i = 0; i < 9; i++) {
        final f = File('${h.root}/pre/${Ids.newV4()}-${Ids.newV4()}.jsonl')
          ..writeAsStringSync(_otherHeader + _preLine('dead $i'));
        f.setLastModifiedSync(DateTime.now().subtract(Duration(minutes: 30 - i)));
        dead.add(f);
      }
      h.log(LogLevel.warn, 'own pre line'); // 建本进程 pre 文件（先 _trimDead）
      expect(dead.where((f) => f.existsSync()).length, 8, reason: '修剪了最旧的死文件');
      expect(other.existsSync(), isTrue, reason: '同 token 的不进修剪');
      expect(await childFileLock(other.path), 'locked');
      await h.configure('');
      await h.settle();
      await h.client.onWork(h.client.engine.evictIfNeeded);
      await h.settle();
      expect(other.existsSync(), isTrue, reason: '驱逐的 7 天删除跳过同 token');
      // 只用 stat 看（本进程里开关它的任何 fd 都会放掉对方的锁，测试自己也不能读）
      expect(other.lengthSync(), bytes.length);
      expect(await childFileLock(other.path), 'locked', reason: '从没被打开过（打开再关会放掉对方的锁）');
      final all = <Object?>[for (final d in h.sessionDirs()) ...sessionLines(d).map((l) => l['msg'])];
      expect(all, contains('own pre line'));
      expect(all, isNot(contains('other engine line')), reason: '不收编');
      expect(all.where((m) => '$m'.startsWith('dead ')).length, 8, reason: '真孤儿照常收编');
      // 那个引擎所在的进程死了（锁放掉）；下次启动 token 不同 → 当孤儿收编
      raf.closeSync();
      expect(other.readAsBytesSync(), bytes, reason: '内容原样');
      final h2 = await h.restart();
      await h2.configure('');
      await h2.settle();
      final after = <Object?>[for (final d in h2.sessionDirs()) ...sessionLines(d).map((l) => l['msg'])];
      expect(after, contains('other engine line'));
      expect(other.existsSync(), isFalse);
    });
  });

  // ---------------------------------------------------------------- #11
  group('#11 根级锁的重入标记不泄漏', () {
    test('zoneMarkerDoesNotLeakPastRelease', () async {
      final root = tempDir();
      final locks = RootLocks(root);
      // 嵌套调用（同一持有内）照常重入
      final nested = await locks.withDirLock(() async => await locks.withDirLock(() async => 7));
      expect(nested, 7);
      // 临界区里留下的 Zone（Timer / then 回调会继承它）：锁释放之后再从它里面调 withDirLock 不能被当成重入
      late Zone inner;
      await locks.withDirLock(() async {
        inner = Zone.current;
        return true;
      });
      final release = Completer<void>();
      var holderInside = false;
      final holding = locks.withDirLock(() async {
        holderInside = true;
        await release.future;
        holderInside = false;
        return true;
      });
      await pump();
      expect(holderInside, isTrue);
      var leakedRan = false;
      var overlapped = false;
      final leaked = inner.run(
        () => locks.withDirLock(() async {
          leakedRan = true;
          overlapped = holderInside;
          return true;
        }),
      );
      await pump();
      expect(leakedRan, isFalse, reason: '别人持锁：必须排队，不能当重入直接执行');
      release.complete();
      await holding;
      expect(await leaked, isTrue);
      expect(leakedRan, isTrue);
      expect(overlapped, isFalse);
      locks.close();
    });
  });

  // ---------------------------------------------------------------- #12
  group('#12 token 不是小写 UUID = 垫片错误', () {
    for (final bad in ['not-a-uuid', 'UPPER']) {
      test('nonUuidTokenIsShimError_$bad', () async {
        final p = FakePlatform()..rootPath = tempDir();
        p.token = bad == 'UPPER' ? Ids.newV4().toUpperCase() : bad;
        await RetrieverRuntime.resetForTesting(platformFactory: () => p);
        final errs = <Object>[];
        RetrieverRuntime.internalErrorSink = errs.add;
        Retriever.log(LogLevel.warn, 'w1');
        await pump();
        expect(p.rootCalls, 1);
        expect(RetrieverRuntime.root, isNull, reason: 'root() 回包 token 不合法：按 root() 失败处理');
        Retriever.log(LogLevel.error, 'w2');
        expect(DropCounter.pending, 2, reason: '无处可写：计数');
        expect(Directory('${p.rootPath}/pre').existsSync(), isFalse, reason: '不建 pre 文件');
        // bootstrap 回包 token 不合法：进 failed
        await Retriever.configure('', baseUrl: base);
        expect(RetrieverRuntime.state, RetrieverState.failed);
        expect(RetrieverRuntime.client, isNull);
        expect(RetrieverRuntime.token, isNull);
        // 垫片给了合法 token：下一次 configure 成功，计数补报
        p.token = Ids.newV4();
        await Retriever.configure('', baseUrl: base);
        expect(RetrieverRuntime.state, RetrieverState.ready);
        final c = RetrieverRuntime.client!;
        await c.settle();
        final dir = '${p.rootPath}/proc-${c.processName}/${c.writer.currentSessionId}';
        final d = sessionLines(dir).singleWhere((l) => l['tag'] == DropCounter.tag);
        expect(obj(d['attrs'])['count'], 2);
        expect(errs, isEmpty);
      });
    }
  });
}
