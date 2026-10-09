// Flutter 专有（无 Android 对位）：`package:revdog_retriever/logger.dart` 适配器（v2 §4 规则逐条；核实 2026-10-09 §4）。
// 全部经 logger 的公开 API 走到静态入口，再读盘上的段验结果。

import 'dart:async';
import 'dart:convert';

import 'package:logger/logger.dart';
import 'package:revdog_retriever/logger.dart';
import 'package:revdog_retriever/src/fs.dart';
import 'package:test/test.dart';

import 'support/support.dart';

List<SegLineRec> linesOf(Harness h) => sessionLines(h.sessionDir());

class _EmptyPrinter extends LogPrinter {
  @override
  List<String> log(LogEvent event) => const [];
}

class _Unencodable {
  @override
  String toString() => 'Unencodable<1>';
}

class _BadToString {
  @override
  String toString() => throw StateError('toString boom');
}

void main() {
  setUpRtv();

  /// 级别映射：五级 + 已弃用别名；`all` / `off` / `nothing` 不会出现在事件里（LogEvent 构造即拒），万一出现也有落点。
  test('levelMapping', () {
    // ignore_for_file: deprecated_member_use
    final cases = <Level, LogLevel?>{
      Level.all: LogLevel.debug,
      Level.verbose: LogLevel.debug,
      Level.trace: LogLevel.debug,
      Level.debug: LogLevel.debug,
      Level.info: LogLevel.info,
      Level.warning: LogLevel.warn,
      Level.error: LogLevel.error,
      Level.wtf: LogLevel.fatal,
      Level.fatal: LogLevel.fatal,
      Level.nothing: null,
      Level.off: null,
    };
    for (final e in cases.entries) {
      expect(RetrieverLogOutput.mapLevel(e.key), e.value, reason: '${e.key}');
    }
    expect(() => LogEvent(Level.all, 'x'), throwsArgumentError, reason: 'logger 2.8.0：LogEvent 拒绝 all');
    expect(() => LogEvent(Level.off, 'x'), throwsArgumentError, reason: 'logger 2.8.0：LogEvent 拒绝 off');
  });

  /// 读 `event.origin`，不读 `event.lines`：printer 的排版（PrettyPrinter 的框线、emoji、栈）不进日志；tag 原样；级别按映射。
  test('readsOriginNotPrinterLines', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    final logger = Logger(
      filter: ProductionFilter(),
      printer: PrettyPrinter(),
      output: RetrieverLogOutput(tag: 'app'),
    );
    logger.t('t');
    logger.d('d');
    logger.i('i');
    logger.w('w');
    logger.e('e');
    logger.f('f');
    await h.settle();
    final ls = linesOf(h).where((l) => l['tag'] == 'app').toList();
    expect(ls.map((l) => l['msg']).toList(), ['t', 'd', 'i', 'w', 'e', 'f']);
    expect(ls.map((l) => l['level']).toList(), ['debug', 'debug', 'info', 'warn', 'error', 'fatal']);
    expect(ls.every((l) => !l.raw.contains('│') && !l.raw.contains('┌')), isTrue, reason: '不带 printer 排版');
    // 无 tag 的 output：行不带 tag 字段
    Logger(filter: ProductionFilter(), output: RetrieverLogOutput()).w('untagged');
    expect(linesOf(h).last['tag'], isNull);
    expect(linesOf(h).last['msg'], 'untagged');
  });

  /// `origin.message` 为 Function / Map / Iterable 时照 logger printer 转字符串（两空格缩进 JSON，不可编码的取 toString）。
  test('messageStringifiedLikePrinter', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    // printer 用不求值的占位（SimplePrinter 遇到不可编码对象自己会抛，那是 logger 的事）
    final logger = Logger(filter: ProductionFilter(), printer: _NoopPrinter(), output: RetrieverLogOutput());
    final map = {
      'a': 1,
      'b': [true, null],
      'c': _Unencodable(),
    };
    final list = ['x', 2];
    logger.w(() => 'lazy ${1 + 1}');
    logger.w(map);
    logger.w(list);
    logger.w({'k', 'v'}); // Set 也是 Iterable
    logger.w(42);
    final ms = linesOf(h).map((l) => l['msg']).toList();
    final pp = PrettyPrinter();
    expect(ms, [
      'lazy 2',
      pp.stringifyMessage(map),
      pp.stringifyMessage(list),
      pp.stringifyMessage({'k', 'v'}),
      '42',
    ]);
    expect(
      ms[1],
      const JsonEncoder.withIndent('  ').convert({
        'a': 1,
        'b': [true, null],
        'c': 'Unencodable<1>',
      }),
    );
  });

  /// `origin.time` → 行 ts（ms UTC）：本地时区与 UTC 的 DateTime 都按绝对时刻；不传 time 时取 logger 的当前时刻。
  test('originTimeBecomesTs', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    final logger = Logger(filter: ProductionFilter(), output: RetrieverLogOutput());
    final utc = DateTime.utc(2026, 10, 1, 8, 30, 15, 123);
    final local = DateTime(2026, 10, 1, 16, 30, 15, 456);
    logger.w('utc', time: utc);
    logger.w('local', time: local);
    final before = DateTime.now().millisecondsSinceEpoch;
    logger.w('now');
    final after = DateTime.now().millisecondsSinceEpoch;
    final ls = linesOf(h);
    expect(int_(ls[0]['ts']), utc.millisecondsSinceEpoch);
    expect(int_(ls[1]['ts']), local.millisecondsSinceEpoch);
    expect(int_(ls[2]['ts']), inInclusiveRange(before, after), reason: 'LogEvent 未传 time = clock.now()');
  });

  /// `error` / `stackTrace` → `exc`（类型、消息、栈）；只有 error 时 Error 子类取自身的栈。
  test('errorAndStackTraceBecomeExc', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    final logger = Logger(filter: ProductionFilter(), output: RetrieverLogOutput());
    try {
      throw const FormatException('bad input');
    } catch (e, st) {
      logger.e('parse failed', error: e, stackTrace: st);
    }
    try {
      throw StateError('bad state');
    } catch (e) {
      logger.e('state', error: e);
    }
    logger.w('no error');
    final ls = linesOf(h);
    final f = obj(ls.singleWhere((l) => l['msg'] == 'parse failed')['exc']);
    expect(f['type'], 'FormatException');
    expect((f['message'] as String).contains('bad input'), isTrue);
    expect((f['stack'] as String).startsWith('#0'), isTrue);
    final s = obj(ls.singleWhere((l) => l['msg'] == 'state')['exc']);
    expect(s['type'], 'StateError');
    expect((s['stack'] as String).isNotEmpty, isTrue);
    expect(ls.singleWhere((l) => l['msg'] == 'no error')['exc'], isNull);
  });

  /// 低于 `Retriever.localLevel` 的行尽早丢弃：不占 seq，也不调用懒消息（转字符串之前就丢）。
  test('belowLocalLevelDroppedBeforeStringify', () async {
    final h = await Harness.create(
      key: '',
      options: const RetrieverOptions(localLevel: LogLevel.info),
    );
    await h.settle();
    expect(Retriever.localLevel, LogLevel.info);
    // printer 用不求值的占位：验的是 output 自己不求值（logger 自带的 printer 会先求一次）
    final logger = Logger(filter: ProductionFilter(), printer: _NoopPrinter(), output: RetrieverLogOutput());
    var called = 0;
    logger.t(() => '${called++}');
    logger.d(() => '${called++}');
    logger.i('kept');
    expect(called, 0, reason: '被丢的行不转字符串');
    expect(linesOf(h).map((l) => l['msg']).toList(), ['kept']);
    expect(h.client.debugCounters.$1, 1, reason: 'seq 只给了 1 行');
  });

  /// output 自己 catch 并计数（logger 会吞 output 的异常并 print）：消息求值 / toString 抛错 → 计数 +1，零 print、零外泄。
  test('outputCatchesAndCounts', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    final logger = Logger(filter: ProductionFilter(), printer: _NoopPrinter(), output: RetrieverLogOutput());
    final printed = <String>[];
    final leaked = <Object>[];
    final before = RetrieverLogOutput.failures;
    runZonedGuarded(
      () {
        logger.w(() => throw StateError('lazy boom'));
        logger.w(_BadToString());
        // 直接调 output 也不抛
        RetrieverLogOutput().output(OutputEvent(LogEvent(Level.error, () => throw ArgumentError('x')), const ['x']));
      },
      (e, _) => leaked.add(e),
      zoneSpecification: ZoneSpecification(print: (_, _, _, line) => printed.add(line)),
    );
    await pump();
    expect(RetrieverLogOutput.failures - before, 3);
    expect(printed, isEmpty, reason: 'logger 的 catch 没被触发');
    expect(leaked, isEmpty);
    logger.w('still works');
    expect(linesOf(h).map((l) => l['msg']).toList(), ['still works']);
  });

  /// `RetrieverLogger(...)`：默认 ProductionFilter（DevelopmentFilter 在 release 下全丢）；filter / level / printer / output 可换；
  /// 默认输出 = 控制台 + Retriever 两路。
  test('retrieverLoggerFactoryDefaults', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    final printed = <String>[];
    late RetrieverLogger def;
    runZoned(() {
      def = RetrieverLogger(tag: 'rl');
      def.w('both outputs');
    }, zoneSpecification: ZoneSpecification(print: (_, _, _, line) => printed.add(line)));
    expect(def.effectiveFilter, isA<ProductionFilter>());
    expect(printed.single.contains('both outputs'), isTrue, reason: '控制台一路（SimplePrinter 不着色）');
    expect(printed.single.contains('\u001b['), isFalse);
    expect(linesOf(h).last['msg'], 'both outputs');
    expect(linesOf(h).last['tag'], 'rl');
    // level 参数作用在 ProductionFilter 上
    final mem = MemoryOutput();
    final warnOnly = RetrieverLogger(level: Level.warning, output: mem);
    warnOnly.i('dropped by filter');
    warnOnly.w('passes');
    expect(mem.buffer.length, 1);
    expect(linesOf(h).map((l) => l['msg']).where((m) => m == 'dropped by filter'), isEmpty);
    expect(linesOf(h).last['msg'], 'passes');
    // 传入的 filter 原样生效
    final custom = DevelopmentFilter();
    expect(RetrieverLogger(filter: custom, output: MemoryOutput()).effectiveFilter, same(custom));
  });

  /// 自建 Logger 的宿主（selah 的接法）：把 `RetrieverLogOutput()` 加进现有 MultiOutput，宿主的 filter 决定 Retriever 看到什么。
  test('existingMultiOutputHost', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    final mem = MemoryOutput();
    final host = Logger(
      filter: ProductionFilter()..level = Level.info,
      printer: PrettyPrinter(methodCount: 0),
      output: MultiOutput([mem, RetrieverLogOutput(tag: 'host')]),
    );
    host.d('host filter drops');
    host.i('seen');
    host.e('failed', error: StateError('x'));
    expect(mem.buffer.length, 2);
    final ls = linesOf(h).where((l) => l['tag'] == 'host').toList();
    expect(ls.map((l) => l['msg']).toList(), ['seen', 'failed']);
  });

  /// printer 输出为空时 logger 不调 output（logger 自身行为，核实 2026-10-09）：Retriever 收不到——README 写明。
  test('emptyPrinterOutputNeverReachesOutput', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    Logger(filter: ProductionFilter(), printer: _EmptyPrinter(), output: RetrieverLogOutput()).w('lost');
    expect(linesOf(h), isEmpty);
  });

  /// configure 之前：构造 output 即首触（要 root）；之后经 logger 写的行进 pre 文件、ts 保持 origin.time，configure 后被接管。
  test('beforeConfigureLinesGoToPreKeepingOriginTime', () async {
    final p = FakePlatform();
    p.rootPath = tempDir();
    await RetrieverRuntime.resetForTesting(platformFactory: () => p);
    final output = RetrieverLogOutput(tag: 'early');
    expect(p.rootCalls, 1, reason: '构造即触达');
    await waitRootArrived();
    final h = StaticHarnessView(p);
    final t0 = DateTime.utc(2026, 10, 9, 1, 2, 3, 4);
    Logger(filter: ProductionFilter(), output: output).w('pre line', time: t0);
    expect(h.preFiles.length, 1);
    await Retriever.configure('', baseUrl: base);
    await RetrieverRuntime.client!.settle();
    final dir = '${p.rootPath}/proc-main/${RetrieverRuntime.client!.writer.currentSessionId}';
    final l = sessionLines(dir).singleWhere((l) => l['tag'] == 'early');
    expect(l['msg'], 'pre line');
    expect(int_(l['ts']), t0.millisecondsSinceEpoch);
    expect(h.preFiles, isEmpty);
  });

  /// unsupported 终态（dart test 宿主机 = 非 Android / iOS；宿主 `flutter test` 同理）：适配器整条链 no-op、不抛、不建文件。
  test('unsupportedIsNoop', () async {
    await RetrieverRuntime.resetForTesting(); // 不注入假 platform：宿主机不是 Android / iOS
    final printed = <String>[];
    final leaked = <Object>[];
    final before = RetrieverLogOutput.failures;
    runZonedGuarded(
      () {
        final logger = RetrieverLogger(output: MemoryOutput());
        logger.e('x', error: StateError('y'));
        logger.f('z');
      },
      (e, _) => leaked.add(e),
      zoneSpecification: ZoneSpecification(print: (_, _, _, line) => printed.add(line)),
    );
    await pump();
    expect(RetrieverRuntime.state, RetrieverState.unsupported);
    expect(leaked, isEmpty);
    expect(printed, isEmpty);
    expect(RetrieverLogOutput.failures, before);
  });
}

class _NoopPrinter extends LogPrinter {
  @override
  List<String> log(LogEvent event) => const ['x'];
}

/// 只读视图：不触达、不建 Harness（测试自己控制首触时机）。
class StaticHarnessView {
  StaticHarnessView(this.p);

  final FakePlatform p;

  List<String> get preFiles =>
      (Fs.listSync('${p.rootPath}/pre') ?? const <String>[]).where((n) => n.endsWith('.jsonl')).toList();
}

Future<void> waitRootArrived() async {
  for (var i = 0; i < 1000 && RetrieverRuntime.root == null; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
