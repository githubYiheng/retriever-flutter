// Flutter 专有（无 Android 对位；v3 §6 FlutterSpecificTests）：configure 必定完成（bootstrap 永不回包 / 抛平台异常 / 插件缺失）；
// runZonedGuarded 下零外泄错误；unsupported 终态零 Timer 零文件；非 owner 全部入口口径 + ownerReleased 接任；并发 configure 与
// bootstrapping 窗口里的 setUser / setEnabled / purge / flush；事件循环滞后探针（20 MB 出站箱 + 本地环夹具，启动恢复期间 1 ms Timer
// 最大滞后 < 50 ms；1 MB pre 文件 + redact 钩子的收编同样 < 50 ms）。全部走静态入口。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:revdog_retriever/src/config_diagnostics.dart';
import 'package:revdog_retriever/src/fs.dart';
import 'package:revdog_retriever/src/limits.dart';
import 'package:revdog_retriever/src/platform.dart';
import 'package:test/test.dart';

import 'support/support.dart';

/// 数本 zone 里建了多少 Timer、还有几个活着。
class TimerProbe {
  int created = 0;
  final List<Timer> timers = <Timer>[];

  ZoneSpecification get spec => ZoneSpecification(
    createTimer: (self, parent, zone, d, f) {
      created++;
      final t = parent.createTimer(zone, d, f);
      timers.add(t);
      return t;
    },
    createPeriodicTimer: (self, parent, zone, d, f) {
      created++;
      final t = parent.createPeriodicTimer(zone, d, f);
      timers.add(t);
      return t;
    },
  );

  int get active => timers.where((t) => t.isActive).length;
}

List<String> preFilesIn(String root) => (Fs.listSync('$root/pre') ?? const <String>[])
    .where((n) => n.endsWith('.jsonl'))
    .map((n) => '$root/pre/$n')
    .toList();

Future<void> waitClient() => waitUntil(() => RetrieverRuntime.client != null);

void main() {
  setUpRtv();

  group('configure 必定完成', () {
    /// bootstrap 永不回包：configure 在 5 s 超时后完成（failed）；之后的行进 pre 文件；≥ 5 s 后的下一次触达重试并收编。
    test('bootstrapNeverRepliesCompletesAfterTimeout', () async {
      final h = await StaticHarness.create();
      h.platform.bootstrapMode = CallMode.hang;
      h.log(LogLevel.warn, 'before');
      final sw = Stopwatch()..start();
      await Retriever.configure(demoKey, baseUrl: base);
      final ms = sw.elapsedMilliseconds;
      expect(
        ms,
        inInclusiveRange(
          ClientConstants.channelBootstrapTimeoutMs - 200,
          ClientConstants.channelBootstrapTimeoutMs + 3000,
        ),
      );
      expect(RetrieverRuntime.state, RetrieverState.failed);
      expect(RetrieverRuntime.client, isNull);
      h.log(LogLevel.warn, 'while failed');
      expect(h.platform.bootstrapCalls, 1, reason: '5 s 内的触达不重试');
      expect(h.preFiles.length, 1);
      // 垫片恢复；≥ 5 s 后下一次触达重试
      h.platform.bootstrapMode = CallMode.ok;
      h.clock.advance(ClientConstants.rootRetryMs);
      h.log(LogLevel.warn, 'retry trigger');
      await waitClient();
      await h.settle();
      expect(h.platform.bootstrapCalls, 2);
      expect(RetrieverRuntime.state, RetrieverState.ready);
      final msgs = sessionLines(h.currentSessionDir()).map((l) => l['msg']).toList();
      expect(msgs, containsAllInOrder(['before', 'while failed', 'retry trigger']));
      expect(h.preFiles, isEmpty);
    });

    /// bootstrap 抛平台异常（PlatformException 的映射）：configure 立即完成（failed）；下一次 configure 立即重试。
    test('bootstrapPlatformExceptionFailsThenNextConfigureRetries', () async {
      final h = await StaticHarness.create();
      h.platform.bootstrapMode = CallMode.fail;
      final sw = Stopwatch()..start();
      await Retriever.configure(demoKey, baseUrl: base);
      expect(sw.elapsedMilliseconds, lessThan(1000));
      expect(RetrieverRuntime.state, RetrieverState.failed);
      h.platform.bootstrapMode = CallMode.ok;
      await Retriever.configure(demoKey, baseUrl: base);
      expect(h.platform.bootstrapCalls, 2);
      expect(RetrieverRuntime.state, RetrieverState.ready);
      expect(Retriever.installId, isNotNull);
    });

    /// bootstrap 回「插件缺失」（MissingPluginException 的映射）：本进程终态 unsupported——之后全部入口 no-op，不再发任何 channel 调用，
    /// 已有的 pre 文件不再追加。
    test('bootstrapMissingPluginBecomesUnsupported', () async {
      final h = await StaticHarness.create();
      h.log(LogLevel.warn, 'pre line');
      final pre = h.preFiles.single;
      final size = File(pre).lengthSync();
      h.platform.bootstrapMode = CallMode.unsupported;
      await Retriever.configure(demoKey, baseUrl: base);
      expect(RetrieverRuntime.state, RetrieverState.unsupported);
      final calls = (h.platform.rootCalls, h.platform.bootstrapCalls, h.platform.diagnoses.length);
      h.log(LogLevel.error, 'after');
      Retriever.setUser('u');
      Retriever.setEnabled(false);
      await Retriever.configure(demoKey, baseUrl: base);
      expect(await Retriever.flush(), FlushResult.pending('paused'));
      await Retriever.purgeLocal();
      expect(Retriever.isEnabled, isFalse);
      expect(File(pre).lengthSync(), size, reason: 'unsupported 之后不写');
      expect(File(h.marker).existsSync(), isFalse, reason: 'setEnabled 也不落标记');
      expect((h.platform.rootCalls, h.platform.bootstrapCalls, h.platform.diagnoses.length), calls);
    });
  });

  group('unsupported 终态', () {
    /// root() 回「插件缺失」：终态之后全部入口零 Timer、零文件、零 channel 调用；Future 照样完成。
    test('terminalStateCreatesNoTimersNoFiles', () async {
      final parent = tempDir();
      final p = FakePlatform()
        ..rootPath = '$parent/retriever'
        ..rootMode = CallMode.unsupported;
      await RetrieverRuntime.resetForTesting(platformFactory: () => p);
      final probe = TimerProbe();
      final leaked = <Object>[];
      runZonedGuarded(
        () => Retriever.log(LogLevel.warn, 'first touch'),
        (e, _) => leaked.add(e),
        zoneSpecification: probe.spec,
      );
      await pump();
      expect(RetrieverRuntime.state, RetrieverState.unsupported);
      expect(probe.active, 0, reason: 'root() 的超时 Timer 随回包取消');
      final before = probe.created;
      final futures = runZonedGuarded(
        () {
          for (final l in LogLevel.values) {
            Retriever.log(l, 'x', tag: 't', attrs: {'a': 1}, error: StateError('e'), stackTrace: StackTrace.current);
          }
          Retriever.setUser('u1');
          Retriever.setEnabled(false);
          Retriever.setEnabled(true);
          Retriever.isEnabled;
          Retriever.installId;
          Retriever.supportCode;
          Retriever.uploadLevel;
          Retriever.localLevel;
          return <Future<Object?>>[
            Retriever.configure(demoKey, baseUrl: base),
            Retriever.flush(),
            Retriever.flush(includeContext: false),
            Retriever.purgeLocal(),
          ];
        },
        (e, _) => leaked.add(e),
        zoneSpecification: probe.spec,
      )!;
      final results = await Future.wait(futures).timeout(const Duration(seconds: 2));
      expect(results[1], FlushResult.pending('paused'));
      expect(probe.created, before, reason: '终态零 Timer');
      expect(probe.active, 0);
      expect(leaked, isEmpty);
      expect((p.rootCalls, p.bootstrapCalls, p.diagnoses.length), (1, 0, 0));
      expect(Directory(parent).listSync(), isEmpty, reason: '零文件（root、标记、pre 都不建）');
    });

    /// 宿主判定在任何 channel 调用之前：`FLUTTER_TEST=true` 或非 Android / iOS → unsupported；默认工厂根本不被调用。
    test('hostDecisionBeforeAnyChannelCall', () async {
      expect(RetrieverRuntime.hostUnsupported({'FLUTTER_TEST': 'true'}, 'android'), isTrue);
      expect(RetrieverRuntime.hostUnsupported({'FLUTTER_TEST': 'true'}, 'ios'), isTrue);
      expect(RetrieverRuntime.hostUnsupported(const {}, 'android'), isFalse);
      expect(RetrieverRuntime.hostUnsupported({'FLUTTER_TEST': 'false'}, 'ios'), isFalse);
      expect(RetrieverRuntime.hostUnsupported(const {}, 'macos'), isTrue);
      expect(RetrieverRuntime.hostUnsupported(const {}, 'linux'), isTrue);
      // dart test 在宿主机上跑 = 非 Android / iOS：默认工厂不被调用
      var made = 0;
      final saved = RetrieverRuntime.defaultPlatformFactory;
      try {
        await RetrieverRuntime.resetForTesting();
        RetrieverRuntime.defaultPlatformFactory = () {
          made++;
          return FakePlatform();
        };
        Retriever.log(LogLevel.error, 'x');
        await Retriever.configure(demoKey);
        expect(made, 0);
        expect(RetrieverRuntime.state, RetrieverState.unsupported);
      } finally {
        RetrieverRuntime.defaultPlatformFactory = saved;
      }
    });
  });

  /// runZonedGuarded 下零外泄错误：root 失败再成功、bootstrap 失败、其余 channel 调用全部失败（异步失败与同步抛各一轮）、
  /// 正常运行与生命周期事件、作业、purge、开关、flush。
  test('zeroLeakedErrorsUnderRunZonedGuarded', () async {
    final leaked = <Object>[];
    final printed = <String>[];
    // 诊断走默认出口（垫片 diagnose 失败 → 退回 print，仍不抛）
    await runZonedGuarded(
      () async {
        for (final syncThrow in [false, true]) {
          final h = await StaticHarness.create();
          h.platform.otherMode = CallMode.fail;
          h.platform.otherThrowSync = syncThrow;
          h.platform.bootstrapMode = CallMode.fail;
          await Retriever.configure('  $demoKey ', baseUrl: base);
          h.platform.bootstrapMode = CallMode.ok;
          await Retriever.configure(demoKey, baseUrl: base);
          expect(RetrieverRuntime.state, RetrieverState.ready);
          h.log(LogLevel.error, 'e', error: StateError('x'));
          h.log(LogLevel.fatal, 'f');
          h.platform.handler!.didEnterBackground(3);
          h.platform.handler!.backgroundTaskExpired(3);
          h.platform.handler!.willEnterForeground();
          h.platform.handler!.foregroundStateChanged(false);
          h.platform.handler!.networkRestored();
          await h.platform.handler!.drainOutbox(1000);
          h.platform.handler!.stopUploadJob();
          h.platform.handler!.ownerReleased();
          Retriever.setEnabled(false);
          Retriever.setEnabled(true);
          await Retriever.flush().timeout(const Duration(seconds: 20));
          await Retriever.purgeLocal();
          await h.settle();
          h.clock.advance(Limits.backoffMaxMs);
          await h.client.tickNow();
          await h.settle();
          // 作业排不上（scheduleUploadJob 失败）按设计经内部异常出口报一次；其余不该有
          expect(h.errors.where((e) => !'$e'.contains('not scheduled')), isEmpty, reason: '${h.errors}');
          h.errors.clear();
        }
      },
      (e, st) => leaked.add(e),
      zoneSpecification: ZoneSpecification(print: (_, _, _, line) => printed.add(line)),
    );
    await pump();
    expect(leaked, isEmpty, reason: '$leaked');
    expect(printed.where((l) => l.contains('Unhandled')), isEmpty);
  });

  group('非 owner', () {
    /// v3 §4：log → 自己的 pre 文件；setUser → pre 用户记录；setEnabled → 落盘标记（进程共享）；isEnabled → 读标记；
    /// purgeLocal → 只删自己的 pre 文件、立即完成；flush → pending("paused")；installId / supportCode → null；诊断一条。
    test('nonOwnerEntries', () async {
      final h = await StaticHarness.create();
      h.platform.owner = false;
      // owner 引擎的数据（同 root）：purge 不能碰
      Directory('${h.root}/outbox').createSync(recursive: true);
      File('${h.root}/outbox/p1-owner.gz').writeAsBytesSync([1, 2, 3]);
      File('${h.root}/install.json').writeAsStringSync('{"install_id":"x","session_counter":1}');
      await Retriever.configure(demoKey, baseUrl: base);
      expect(RetrieverRuntime.state, RetrieverState.nonOwner);
      expect(RetrieverRuntime.client, isNull);
      expect(h.platform.diagnoses.where((d) => d.$1 == ConfigDiagnostics.nonOwnerCode).length, 1);
      expect(h.platform.diagnoses.last.$2, ConfigDiagnostics.nonOwnerMessage);
      h.log(LogLevel.info, 'n1');
      Retriever.setUser('user-9');
      h.log(LogLevel.warn, 'n2');
      final pre = h.preFiles.single;
      final recs = readJsonlAt(pre);
      expect(recs.first['pre'], 1);
      expect(recs.where((r) => r.containsKey('pre_user')).single['pre_user'], 'user-9');
      expect(recs.where((r) => r.containsKey('r')).length, 2);
      // 开关：进程共享的标记
      Retriever.setEnabled(false);
      expect(File(h.marker).existsSync(), isTrue);
      expect(Retriever.isEnabled, isFalse);
      Retriever.setEnabled(true);
      expect(File(h.marker).existsSync(), isFalse);
      expect(Retriever.isEnabled, isTrue);
      expect(await Retriever.flush(), FlushResult.pending('paused'));
      expect(Retriever.installId, isNull);
      expect(Retriever.supportCode, isNull);
      expect(Retriever.uploadLevel, LogLevel.warn);
      expect(Retriever.localLevel, LogLevel.debug);
      // purge：只删自己的 pre 文件
      await Retriever.purgeLocal().timeout(const Duration(milliseconds: 500));
      expect(File(pre).existsSync(), isFalse);
      expect(File('${h.root}/outbox/p1-owner.gz').existsSync(), isTrue);
      expect(File('${h.root}/install.json').existsSync(), isTrue);
      // 再次 configure：仍非 owner，诊断不重复刷
      await Retriever.configure(demoKey, baseUrl: base);
      expect(RetrieverRuntime.state, RetrieverState.nonOwner);
      expect(h.platform.diagnoses.where((d) => d.$1 == ConfigDiagnostics.nonOwnerCode).length, 1);
      expect(h.platform.bootstrapCalls, 2);
    });

    /// ownerReleased → 重试 bootstrap、成为 owner：自己的 pre 行被收编；旧 owner 的会话按死会话恢复。回前台同样会重试。
    test('ownerReleasedTakeover', () async {
      final root = tempDir();
      // 旧 owner：一个已死的引擎会话（锁已随 isolate 释放）
      final old = await Harness.create(root: root, key: '', direct: true);
      await old.settle();
      old.l(LogLevel.warn, 'old owner line');
      final oldSid = old.client.writer.currentSessionId;
      final h = await StaticHarness.create(root: root, clock: old.clock);
      h.platform.owner = false;
      await Retriever.configure('', baseUrl: base);
      expect(RetrieverRuntime.state, RetrieverState.nonOwner);
      h.log(LogLevel.warn, 'while non-owner');
      // 回前台：仍非 owner（重试过一次）
      h.platform.handler!.willEnterForeground();
      await pump();
      expect(h.platform.bootstrapCalls, 2);
      expect(RetrieverRuntime.state, RetrieverState.nonOwner);
      // 旧 owner 引擎销毁 → 原生发 ownerReleased
      await old.client.simulateCrash();
      h.platform.owner = true;
      h.platform.handler!.ownerReleased();
      await waitClient();
      await h.settle();
      expect(RetrieverRuntime.state, RetrieverState.ready);
      expect(sessionLines(h.currentSessionDir()).map((l) => l['msg']), contains('while non-owner'));
      expect(h.preFiles, isEmpty);
      final closed = h.readJsonl('sessions.jsonl').where((c) => c['session_id'] == oldSid).toList();
      expect(closed.length, 1, reason: '旧 owner 的会话按死会话恢复');
      expect(h.envelopes().any((e) => e['session_id'] == oldSid), isTrue);
    });
  });

  /// 并发 configure + bootstrapping 窗口里的入口：第二次 configure 排在后面按 reconfigure 生效（不重复 bootstrap）；setUser 成为实例初值；
  /// flush 立即 pending("paused")；purge 排在 configure 之后、清完才完成；setEnabled(false) 实例以禁用启动。
  test('concurrentConfigureAndCallsDuringBootstrap', () async {
    final h = await StaticHarness.create();
    final gate = Completer<void>();
    h.platform.bootstrapGate = gate;
    h.log(LogLevel.warn, 'before configure');
    final f1 = Retriever.configure('', baseUrl: base);
    final f2 = Retriever.configure(
      '',
      baseUrl: base,
      options: const RetrieverOptions(uploadLevel: LogLevel.error),
    );
    await pump();
    expect(RetrieverRuntime.state, RetrieverState.bootstrapping);
    Retriever.setUser('u-7');
    h.log(LogLevel.warn, 'during bootstrap');
    final flushF = Retriever.flush();
    final purgeF = Retriever.purgeLocal();
    var purged = false;
    purgeF.then((_) => purged = true).ignore();
    expect(await flushF.timeout(const Duration(milliseconds: 500)), FlushResult.pending('paused'));
    await pump();
    expect(purged, isFalse, reason: 'purge 排在 configure 之后');
    gate.complete();
    await Future.wait([f1, f2]).timeout(const Duration(seconds: 10));
    await purgeF.timeout(const Duration(seconds: 10));
    expect(h.platform.bootstrapCalls, 1, reason: '第二次 configure 是 reconfigure');
    expect(Retriever.uploadLevel, LogLevel.error);
    expect(h.client.writer.currentUser, 'u-7');
    expect(Retriever.installId, isNotNull);
    expect(Retriever.supportCode!.endsWith('-1'), isTrue, reason: 'purge 之后计数器从 1 起');
    final msgs = sessionLines(h.currentSessionDir()).map((l) => l['msg']).toList();
    expect(msgs, isNot(contains('before configure')), reason: 'purge 清掉了之前的全部数据');
    expect(msgs, isNot(contains('during bootstrap')));
    // setEnabled(false) 在 bootstrapping 窗口里：实例以禁用启动
    final h2 = await StaticHarness.create();
    final gate2 = Completer<void>();
    h2.platform.bootstrapGate = gate2;
    final f3 = Retriever.configure('', baseUrl: base);
    await pump();
    Retriever.setEnabled(false);
    expect(File(h2.marker).existsSync(), isTrue);
    gate2.complete();
    await f3;
    expect(Retriever.isEnabled, isFalse);
    h2.log(LogLevel.error, 'not written');
    expect(h2.client.debugCounters.$1, 0);
  });

  /// 事件循环滞后探针：20 MB 出站箱 + 本地环（含崩溃时没来得及物化的 4 MB 义务行）夹具上启动；从 configure 到启动恢复全部落定，
  /// 1 ms 周期 Timer 的最大滞后 < 50 ms（dart test JIT，宿主机）。
  test('eventLoopLagDuringStartupRecovery', () async {
    final root = tempDir();
    const opts = RetrieverOptions(localCapBytes: Limits.localCapBytesMax);
    final rnd = Random(7);
    String noise(int n) => base64.encode(List<int>.generate(n, (_) => rnd.nextInt(256)));
    final a = await Harness.create(root: root, key: '', options: opts);
    await a.settle();
    // 不可压缩的 warn 行（每行 ≈ 8 KB）
    void bulk(int bytes) {
      var n = 0;
      while (n < bytes) {
        final msg = noise(2900);
        final attrs = {'a': noise(900), 'b': noise(900), 'c': noise(900)};
        a.l(LogLevel.warn, msg, attrs: attrs);
        n += msg.length + 3 * 1200;
      }
    }

    var outboxBytes = 0;
    while (outboxBytes < 20 * 1024 * 1024) {
      bulk(2 * 1024 * 1024);
      await a.settle();
      outboxBytes = a.outboxFiles().fold<int>(0, (s, n) => s + File('${a.outbox}/$n').lengthSync());
    }
    // 「被杀」的盘面：引擎堵住时再写 4 MB 义务行（段已封、还没物化，cursor 落后），此刻把整个 root 拷走 = SIGKILL 留下的样子
    final gate = await a.blockEngine();
    bulk(4 * 1024 * 1024);
    final crashed = '${tempDir()}/retriever';
    final cp = await Process.run('cp', ['-Rp', root, crashed]);
    expect(cp.exitCode, 0, reason: '${cp.stderr}');
    gate.complete();
    await a.simulateCrash();
    final atCrash = Fs.listSync(
      '$crashed/outbox',
    )!.where((n) => n.endsWith('.gz')).fold<int>(0, (s, n) => s + File('$crashed/outbox/$n').lengthSync());
    final segs = Directory(crashed).listSync(recursive: true).whereType<File>().where((f) => f.path.contains('/seg-'));
    final ringBytes = segs.fold<int>(0, (s, f) => s + f.lengthSync());
    print('[lag] fixture: outbox=${atCrash ~/ 1024} KB, ring=${ringBytes ~/ 1024} KB');
    expect(atCrash, greaterThanOrEqualTo(20 * 1024 * 1024));

    // 探针：1 ms 周期 Timer
    final sw = Stopwatch()..start();
    var last = sw.elapsedMicroseconds;
    var maxLag = 0;
    var ticks = 0;
    final lags = <int>[];
    final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      final now = sw.elapsedMicroseconds;
      final lag = now - last - 1000;
      if (lag > maxLag) maxLag = lag;
      lags.add(lag);
      last = now;
      ticks++;
    });
    final t0 = sw.elapsedMilliseconds;
    final b = await Harness.create(root: crashed, key: '', options: opts, clock: a.clock);
    await b.settle();
    final elapsed = sw.elapsedMilliseconds - t0;
    timer.cancel();
    lags.sort();
    final p99 = lags.isEmpty ? 0 : lags[(lags.length * 0.99).floor().clamp(0, lags.length - 1)];
    print('[lag] startup recovery $elapsed ms, ticks=$ticks, max lag=${maxLag ~/ 1000} ms, p99 lag=${p99 ~/ 1000} ms');
    // 恢复确实做了：崩溃会话已收尾，4 MB 义务行物化进了出站箱
    expect(b.readJsonl('sessions.jsonl').isNotEmpty, isTrue);
    final after = b.outboxFiles().fold<int>(0, (s, n) => s + File('${b.outbox}/$n').lengthSync());
    print('[lag] outbox after recovery: ${after ~/ 1024} KB');
    expect(after, greaterThan(atCrash));
    expect(ticks, greaterThan(0));
    expect(maxLag, lessThan(50 * 1000), reason: 'max lag ${maxLag ~/ 1000} ms');
  }, timeout: const Timeout(Duration(minutes: 5)));

  /// 收编滞后探针（审计 #10）：≈ 1 MB 的本进程 pre 文件 + redact 钩子，从 configure 到收编提交、startup 落定（含物化），
  /// 1 ms 周期 Timer 的最大滞后 < 50 ms（收编按 ≤ 64 KB 一片同步读 / 处理，片之间让出事件循环）。
  test('eventLoopLagDuringPreAdoptionWithRedact', () async {
    final h = await StaticHarness.create();
    final rnd = Random(11);
    String noise(int n) => base64.encode(List<int>.generate(n, (_) => rnd.nextInt(256)));
    var n = 0;
    var len = 0;
    while (len < 1000 * 1024) {
      for (var k = 0; k < 10; k++) {
        h.log(n % 5 == 0 ? LogLevel.warn : LogLevel.info, 'pre line $n ${'x' * 120}', attrs: {'i': n, 'k': noise(60)});
        n++;
      }
      len = File(h.preFiles.single).lengthSync(); // stat，不开 fd
    }
    final pre = h.preFiles.single;
    expect(len, lessThanOrEqualTo(1024 * 1024), reason: '没超 1 MB 上限：全部行都在 pre 文件里');
    print('[lag] pre file ${len ~/ 1024} KB, $n lines');
    var redacted = 0;
    final sw = Stopwatch()..start();
    var last = sw.elapsedMicroseconds;
    var maxLag = 0;
    var ticks = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      final now = sw.elapsedMicroseconds;
      final lag = now - last - 1000;
      if (lag > maxLag) maxLag = lag;
      last = now;
      ticks++;
    });
    final t0 = sw.elapsedMilliseconds;
    await h.configure(
      '',
      RetrieverOptions(
        uploadLevel: LogLevel.info,
        redact: (l) {
          redacted++;
          return l.copyWith(msg: l.msg.replaceAll('x', 'y'));
        },
      ),
    );
    await h.settle();
    final elapsed = sw.elapsedMilliseconds - t0;
    timer.cancel();
    print('[lag] pre adoption + startup $elapsed ms, ticks=$ticks, max lag=${maxLag ~/ 1000} ms');
    expect(File(pre).existsSync(), isFalse, reason: '收编已提交');
    final ls = sessionLines(h.currentSessionDir()).where((l) => '${l['msg']}'.startsWith('pre line ')).toList();
    expect(ls.length, n);
    expect(redacted, n, reason: '每一行都过了钩子');
    expect(ls.every((l) => !'${l['msg']}'.contains('x')), isTrue);
    expect(ticks, greaterThan(0));
    expect(maxLag, lessThan(50 * 1000), reason: 'max lag ${maxLag ~/ 1000} ms');
  }, timeout: const Timeout(Duration(minutes: 2)));

  /// bootstrap 回包与其后事件的次序（切片 2 模拟器实测）：原生已判 owner=false、回包在途时，旧 owner detach 发出的 ownerReleased（或回前台的
  /// willEnterForeground）先到 Dart——3.38 起平台 / UI 线程合一，原生 → Dart 的消息可同步派发、回包排队投递。门面在 bootstrapping 态记下，
  /// 回包是非 owner 就立即重试 → 接任；不记就卡在非 owner，等 60 s 触达或下次回前台。
  group('bootstrap 回包与事件次序', () {
    for (final event in <String>['ownerReleased', 'willEnterForeground']) {
      test('${event}BeforeNonOwnerReplyRetriesImmediately', () async {
        final p = _ScriptedOwnerPlatform(<bool>[false, true]);
        await StaticHarness.create(platform: p);
        final gate = Completer<void>();
        p.bootstrapGate = gate;
        final f = Retriever.configure('', baseUrl: base);
        await waitUntil(() => p.bootstrapCalls == 1 && RetrieverRuntime.state == RetrieverState.bootstrapping);
        if (event == 'ownerReleased') {
          p.handler!.ownerReleased();
        } else {
          p.handler!.willEnterForeground();
        }
        expect(RetrieverRuntime.state, RetrieverState.bootstrapping);
        gate.complete();
        await f;
        await waitClient();
        expect(p.bootstrapCalls, 2, reason: '回包是非 owner → 立即重试一次');
        expect(RetrieverRuntime.state, RetrieverState.ready);
        expect(Retriever.installId, isNotNull);
      });
    }

    test('eventDuringOwnerBootstrapIsHarmless', () async {
      final p = _ScriptedOwnerPlatform(<bool>[true]);
      await StaticHarness.create(platform: p);
      final gate = Completer<void>();
      p.bootstrapGate = gate;
      final f = Retriever.configure('', baseUrl: base);
      await waitUntil(() => p.bootstrapCalls == 1);
      p.handler!.ownerReleased();
      gate.complete();
      await f;
      await waitClient();
      await pump();
      expect(p.bootstrapCalls, 1);
      expect(RetrieverRuntime.state, RetrieverState.ready);
    });

    test('flagDoesNotLeakIntoLaterBootstrap', () async {
      // 第一次 bootstrap 期间收到事件、但回包失败（failed）；下一次显式 configure 回非 owner：标志已在新一轮 bootstrap 开始时清掉，不立即重试
      final p = _ScriptedOwnerPlatform(<bool>[false, false, true])..failNext = true;
      await StaticHarness.create(platform: p);
      final gate = Completer<void>();
      p.bootstrapGate = gate;
      final f = Retriever.configure('', baseUrl: base);
      await waitUntil(() => p.bootstrapCalls == 1);
      p.handler!.ownerReleased();
      gate.complete();
      await f;
      expect(RetrieverRuntime.state, RetrieverState.failed);
      await Retriever.configure('', baseUrl: base);
      await pump();
      expect(RetrieverRuntime.state, RetrieverState.nonOwner);
      expect(p.bootstrapCalls, 2);
    });
  });
}

/// bootstrap 按脚本回 owner（调用时就取值，闸门之后才回包）；`failNext` = 下一次回包抛垫片错误。
class _ScriptedOwnerPlatform extends FakePlatform {
  _ScriptedOwnerPlatform(this.owners);

  final List<bool> owners;
  bool failNext = false;

  @override
  Future<BootstrapInfo> bootstrap() async {
    bootstrapCalls++;
    final owner = owners.isEmpty ? true : owners.removeAt(0);
    final fail = failNext;
    failNext = false;
    final gate = bootstrapGate;
    if (gate != null) await gate.future;
    if (fail) throw const PlatformCallException('boom', 'scripted failure');
    return BootstrapInfo(
      owner: owner,
      root: rootPath!,
      token: token,
      process: processName,
      foreground: foreground,
      device: deviceFields,
    );
  }
}
