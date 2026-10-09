// Retriever Flutter 插件示例 app（切片 2 简报 §4）：场景按钮 + 启动参数驱动的模拟器验收。
// 场景与结果打到屏幕和系统日志（print → Android logcat tag `flutter` / iOS syslog，前缀 `RTVEX`）。
// key / baseUrl 经 `--dart-define-from-file=env.json` 注入；缺省空 key（SDK 出 no_key 诊断，照常本地落盘）。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:revdog_retriever/logger.dart';
import 'package:revdog_retriever/revdog_retriever.dart';

const String kKey = String.fromEnvironment('RETRIEVER_KEY');
const String kBaseUrl = String.fromEnvironment('RETRIEVER_BASE_URL', defaultValue: 'https://logs.revdog.org');

/// 示例自己的原生通道（启动参数、第二引擎、finish / 换根 VC）：不进生产垫片。
const MethodChannel exampleChannel = MethodChannel('org.revdog.retriever.example');

/// `logger` 适配器接法：控制台 + Retriever 两路。
final RetrieverLogger appLog = RetrieverLogger(tag: 'example');

final List<String> results = <String>[];
final ValueNotifier<int> resultsVersion = ValueNotifier<int>(0);

void report(String line) {
  print('RTVEX $line');
  results.add(line);
  if (results.length > 200) results.removeAt(0);
  resultsVersion.value++;
}

Future<void> configureNow() => Retriever.configure(kKey, baseUrl: kBaseUrl);

String status() =>
    'owner=${Retriever.installId != null} installId=${Retriever.installId} supportCode=${Retriever.supportCode} '
    'enabled=${Retriever.isEnabled} upload=${Retriever.uploadLevel.name} local=${Retriever.localLevel.name}';

/// SIGKILL 自己（比 exit(1) 更贴近被系统杀）。iOS 上 `Process.killPid` 回 false（dart:io 在 iOS 不支持杀进程），退回示例原生通道。
Future<void> sigkillSelf() async {
  final ok = Process.killPid(pid, ProcessSignal.sigkill);
  report('Process.killPid(sigkill) returned $ok; falling back to native kill');
  await exampleChannel.invokeMethod<void>('sigkill');
}

Future<String?> launchScenario() async {
  try {
    return await exampleChannel.invokeMethod<String>('launchScenario');
  } catch (_) {
    return null;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final launch = await launchScenario();
  report('main start pid=$pid scenario=${launch ?? '-'} key=${kKey.isEmpty ? 'empty' : 'set'} baseUrl=$kBaseUrl');
  switch (launch) {
    case Scenarios.preconfigure:
      await Scenarios.preconfigureRun();
    case Scenarios.preconfigureKill:
      await Scenarios.preconfigureKillRun();
      return;
    case Scenarios.secondEngineBgFirst:
      await Scenarios.bgFirstMain();
    default:
      await configureNow();
  }
  report('configured ${status()}');
  // 非 owner / 接任之后的状态（销毁重建、后台先等场景看它）
  Timer(const Duration(seconds: 3), () => report('status +3s ${status()}'));
  appLog.i('example app launched pid=$pid');
  runApp(const ExampleApp());
  if (launch != null && Scenarios.afterConfigure.contains(launch)) {
    // 首帧之后再跑（fatal_storm 要帧）
    SchedulerBinding.instance.addPostFrameCallback((_) => unawaited(Scenarios.run(launch)));
  }
}

/// 第二引擎入口（示例的原生代码起：后到 / 后台先）。不 runApp（无界面的后台引擎）。
@pragma('vm:entry-point')
Future<void> secondEngineMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  print('RTVEX second engine start pid=$pid');
  Retriever.log(LogLevel.info, 'second engine before configure', tag: 'second');
  await Retriever.configure(kKey, baseUrl: kBaseUrl);
  final owner = Retriever.installId != null;
  for (var i = 0; i < 5; i++) {
    Retriever.log(LogLevel.warn, 'second engine line $i owner=$owner', tag: 'second');
  }
  print('RTVEX second engine configured owner=$owner installId=${Retriever.installId}');
  try {
    await exampleChannel.invokeMethod<void>('secondEngineReport', <String, Object?>{
      'owner': owner,
      'installId': Retriever.installId,
      'supportCode': Retriever.supportCode,
    });
  } catch (e) {
    print('RTVEX second engine report failed: $e');
  }
}

class ScenarioError implements Exception {
  @override
  String toString() => 'ScenarioError: scenario failure';
}

abstract final class Scenarios {
  static const String preconfigure = 'preconfigure';
  static const String preconfigureKill = 'preconfigure_kill';
  static const String secondEngineLate = 'second_engine_late';
  static const String secondEngineBgFirst = 'second_engine_bg_first';
  static const String secondEngineRebuild = 'second_engine_rebuild';

  /// 销毁重建的竞争变体：旧引擎晚于新引擎 bootstrap 才释放（iOS 旧 VC 多留 1 s；Android 同 [secondEngineRebuild]）。
  static const String secondEngineRebuildHold = 'second_engine_rebuild_hold';

  /// configure 之后跑的场景。
  static const List<String> afterConfigure = <String>[
    'error',
    'user',
    'bulk',
    'crash',
    'flush',
    'fatal_storm',
    secondEngineLate,
    secondEngineRebuild,
    secondEngineRebuildHold,
  ];

  /// 需要冷启动才能跑的场景（按钮：Android 写标记 / 都提示用启动参数）。
  static const List<String> atLaunch = <String>[preconfigure, preconfigureKill, secondEngineBgFirst];

  static void _done(String name) => Retriever.log(LogLevel.warn, 'scenario $name done', tag: 'scenario');

  static Future<void> run(String name) async {
    report('scenario $name start');
    try {
      switch (name) {
        case 'error':
          _errorLines();
          _done(name);
        case 'user':
          Retriever.setUser('device-test-user');
          Retriever.log(LogLevel.info, 'after setUser', tag: 'scenario');
          Retriever.log(LogLevel.error, 'error as device-test-user', tag: 'scenario');
          _done(name);
        case 'bulk':
          for (var i = 0; i < 5000; i++) {
            Retriever.log(
              LogLevel.info,
              'bulk info line $i 中文 emoji 😀 padding padding padding padding padding',
              tag: 'bulk',
            );
          }
          Retriever.log(LogLevel.warn, 'bulk done', tag: 'scenario');
          Retriever.log(LogLevel.error, 'bulk error after 5000 lines', tag: 'scenario');
          _done(name);
        case 'flush':
          Retriever.log(LogLevel.info, 'before flush', tag: 'scenario');
          final r = await Retriever.flush();
          final text = switch (r) {
            FlushStored() => 'stored',
            FlushPending(:final reason) => 'pending($reason)',
          };
          report('flush result: $text');
          Retriever.log(LogLevel.warn, 'flush result: $text', tag: 'scenario');
          _done(name);
        case 'crash':
          for (var i = 0; i < 200; i++) {
            Retriever.log(LogLevel.info, 'pre-crash info $i', tag: 'scenario');
          }
          Retriever.log(LogLevel.warn, 'about to crash', tag: 'scenario');
          report('crash: SIGKILL in 1.5 s (pid $pid)');
          await Future<void>.delayed(const Duration(milliseconds: 1500));
          await sigkillSelf();
        case 'fatal_storm':
          await _fatalStorm();
          _done(name);
        case secondEngineLate:
          await _secondEngineLate();
          _done(name);
        case secondEngineRebuild:
          await _secondEngineRebuild(0);
        case secondEngineRebuildHold:
          await _secondEngineRebuild(1000);
        default:
          Retriever.log(LogLevel.warn, 'unknown scenario $name', tag: 'scenario');
      }
    } catch (e) {
      report('scenario $name failed: $e');
    }
    report('scenario $name returned; ${status()}');
  }

  static void _errorLines() {
    for (var i = 0; i < 50; i++) {
      Retriever.log(LogLevel.debug, 'debug line $i', tag: 'scenario', attrs: <String, Object?>{'i': i});
    }
    for (var i = 0; i < 5; i++) {
      Retriever.log(LogLevel.info, 'info line $i', tag: 'scenario');
    }
    Retriever.log(
      LogLevel.error,
      'scenario error',
      tag: 'scenario',
      attrs: <String, Object?>{'code': 42, 'ok': false},
      error: ScenarioError(),
      stackTrace: StackTrace.current,
    );
  }

  /// configure 之前先各级别 log（首触到 root 回包之间的只计数；之后的写进 pre 文件），再 configure：收编。
  static void _preLines(String name, String phase) {
    for (var i = 0; i < 5; i++) {
      Retriever.log(LogLevel.debug, '$name $phase debug $i', tag: 'scenario', attrs: <String, Object?>{'i': i});
    }
    for (var i = 0; i < 3; i++) {
      Retriever.log(LogLevel.info, '$name $phase info $i', tag: 'scenario');
    }
    Retriever.log(LogLevel.warn, '$name $phase warn', tag: 'scenario');
    Retriever.log(LogLevel.error, '$name $phase error', tag: 'scenario', attrs: <String, Object?>{'code': 7});
  }

  static Future<void> preconfigureRun() async {
    // 首触：这两行在 root() 回包之前 → 只计数（rtv.pre_init_dropped）
    Retriever.log(LogLevel.info, 'preconfigure first touch (counted)', tag: 'scenario');
    Retriever.log(LogLevel.error, 'preconfigure first touch error (counted)', tag: 'scenario');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    _preLines(preconfigure, 'pre');
    report('preconfigure: wrote lines before configure; isEnabled=${Retriever.isEnabled}');
    await configureNow();
    _done(preconfigure);
  }

  static Future<void> preconfigureKillRun() async {
    Retriever.log(LogLevel.info, 'preconfigure_kill first touch (counted)', tag: 'scenario');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    _preLines(preconfigureKill, 'pre');
    Retriever.log(LogLevel.warn, 'scenario $preconfigureKill killing before configure', tag: 'scenario');
    report('preconfigure_kill: SIGKILL before configure (pid $pid)');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await sigkillSelf();
  }

  static Future<Map<Object?, Object?>?> _waitSecondReport({Duration timeout = const Duration(seconds: 10)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final r = await exampleChannel.invokeMethod<Map<Object?, Object?>>('secondEngineStatus');
      if (r != null) return r;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  static Future<bool> _waitOwner({Duration timeout = const Duration(seconds: 10)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if (Retriever.installId != null) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return Retriever.installId != null;
  }

  /// 后到：主引擎已 configure（owner）后，示例原生代码起第二引擎并 configure → 非 owner（configure_ignored 诊断）。
  static Future<void> _secondEngineLate() async {
    await exampleChannel.invokeMethod<void>('startSecondEngine');
    final r = await _waitSecondReport();
    report('second_engine_late: second engine report $r');
    Retriever.log(
      LogLevel.warn,
      'main engine still owner after second engine: ${Retriever.installId != null}',
      tag: 'scenario',
    );
    await exampleChannel.invokeMethod<void>('destroySecondEngine');
    report('second_engine_late: second engine destroyed; main ${status()}');
  }

  /// 后台先（E2）：原生在 Application.onCreate / didFinishLaunching 里先起第二引擎并 configure（owner）；主引擎随后 configure →
  /// 非 owner；销毁第二引擎 → ownerReleased → 主引擎接任。
  static Future<void> bgFirstMain() async {
    final r = await _waitSecondReport();
    report('second_engine_bg_first: second engine report $r');
    await configureNow();
    report('second_engine_bg_first: main after configure ${status()}');
    Retriever.log(LogLevel.warn, 'main engine line while non-owner', tag: 'scenario');
    await exampleChannel.invokeMethod<void>('destroySecondEngine');
    final owner = await _waitOwner();
    report('second_engine_bg_first: after second engine destroyed owner=$owner ${status()}');
    _done(secondEngineBgFirst);
  }

  /// 销毁重建（E1）：Android finish() 主 Activity（非缓存引擎随之销毁、进程仍活），再 am start 拉起；iOS 换根 VC 到新引擎。
  static Future<void> _secondEngineRebuild(int holdOldMs) async {
    Retriever.log(LogLevel.warn, 'scenario $secondEngineRebuild: destroying main engine', tag: 'scenario');
    report('second_engine_rebuild: destroying main engine (pid $pid) ${status()}');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await exampleChannel.invokeMethod<void>('rebuildMainEngine', <String, Object?>{'holdOldMs': holdOldMs});
  }

  /// fatal_storm：每帧一条 error，持续 10 s（观察批数 / 去抖）。
  static Future<void> _fatalStorm() {
    final done = Completer<void>();
    final start = DateTime.now();
    var n = 0;
    void tick(Duration _) {
      Retriever.log(LogLevel.error, 'fatal_storm frame error $n', tag: 'storm', attrs: <String, Object?>{'n': n});
      n++;
      if (DateTime.now().difference(start) < const Duration(seconds: 10)) {
        SchedulerBinding.instance.scheduleFrameCallback(tick);
        SchedulerBinding.instance.scheduleFrame();
      } else {
        report('fatal_storm: $n error lines in 10 s');
        done.complete();
      }
    }

    SchedulerBinding.instance.scheduleFrameCallback(tick);
    SchedulerBinding.instance.scheduleFrame();
    return done.future;
  }
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(title: 'Retriever example', home: const ScenarioPage());
  }
}

class ScenarioPage extends StatelessWidget {
  const ScenarioPage({super.key});

  Future<void> _tap(String name) async {
    if (Scenarios.atLaunch.contains(name)) {
      // 冷启动场景：示例原生代码记一次性标记并结束进程（Android）；iOS 提示用启动参数
      final armed = await exampleChannel.invokeMethod<bool>('armAtLaunch', <String, Object?>{'scenario': name});
      report('$name needs a cold start: armed=$armed (relaunch the app)');
      return;
    }
    await Scenarios.run(name);
  }

  @override
  Widget build(BuildContext context) {
    final names = <String>[...Scenarios.afterConfigure, ...Scenarios.atLaunch];
    return Scaffold(
      appBar: AppBar(title: const Text('Retriever example')),
      body: Column(
        children: <Widget>[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final n in names) ElevatedButton(onPressed: () => unawaited(_tap(n)), child: Text(n)),
            ],
          ),
          const Divider(),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: resultsVersion,
              builder: (context, _, _) => ListView(
                padding: const EdgeInsets.all(8),
                children: <Widget>[for (final r in results.reversed) Text(r, style: const TextStyle(fontSize: 11))],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
