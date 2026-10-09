// 只给测试用（真杀进程验收 R-1，方案 §3.11；对位 Android test/KillHelper.kt）：用给定 root 写 N 行（含 warn / error），
// 可选在最后写半行（模拟撕裂的 write）或写一条 fatal（log() 一返回就杀，异步封段来不及做），然后自发 SIGKILL——
// 不跑任何收尾。
//
//   dart tool/kill_helper.dart <root> <N> [--torn] [--fatal]
//   dart tool/kill_helper.dart --pre <root> <N>                 configure 之前写 N 行后自杀（下次启动作为孤儿收编）
//   dart tool/kill_helper.dart --pre-hold <root> <N>            configure 之前写 N 行后打印 ready 并一直活着（持 flock）
//   dart tool/kill_helper.dart --adopt-crash <root> <N> <point> configure 之前写 N 行，然后 configure；收编走到 <point> 时自杀
//   dart tool/kill_helper.dart --adopt-crash-writing …          同上，且 record:30 时宿主再写 10 行（configure 之后的 r = 1 行）
//   dart tool/kill_helper.dart --probe-lock <dir>               另一个进程看某个会话目录的锁：locked / free

import 'dart:async';
import 'dart:io';

import 'package:revdog_retriever/src/client.dart';
import 'package:revdog_retriever/src/clock.dart';
import 'package:revdog_retriever/src/fs.dart';
import 'package:revdog_retriever/src/ids.dart';
import 'package:revdog_retriever/src/platform.dart';
import 'package:revdog_retriever/src/pre.dart';
import 'package:revdog_retriever/src/public_api.dart';
import 'package:revdog_retriever/src/retriever.dart';
import 'package:revdog_retriever/src/transport.dart';

class _NoTransport implements Transport {
  @override
  Future<TransportResponse?> send(TransportRequest request) async => null;

  @override
  void cancelAll() {}
}

class _HeadlessPlatform implements RetrieverPlatform {
  _HeadlessPlatform(this.rootPath);

  final String rootPath;
  final String token = Ids.newV4();

  @override
  final Clock clock = SystemClock();

  @override
  final Transport transport = _NoTransport();

  static const Map<String, String> device = {
    'os': 'android',
    'os_version': '15',
    'model': 'helper',
    'app_version': '1.0.0',
    'build': '1',
    'locale': 'en-US',
  };

  @override
  Future<RootInfo> root() async => RootInfo(root: rootPath, token: token, process: 'main', device: device);

  @override
  Future<BootstrapInfo> bootstrap() async =>
      BootstrapInfo(owner: true, root: rootPath, token: token, process: 'main', foreground: true, device: device);

  @override
  Future<void> diagnose(String code, String message) async {}

  @override
  Future<bool> scheduleUploadJob(int jobId) async => true;

  @override
  Future<bool> cancelUploadJob(int jobId) async => true;

  @override
  Future<void> endBackgroundTask(int id) async {}

  @override
  Future<int?> availableBytes() async => null;

  @override
  set eventHandler(PlatformEventHandler? handler) {}
}

/// 写 stdout 并等它交给内核（自杀前必须写完：Dart 的 stdout 对管道是异步写的）。
Future<void> _say(String line) async {
  stdout.writeln(line);
  await stdout.flush();
}

Never _kill() {
  Process.killPid(pid, ProcessSignal.sigkill);
  // SIGKILL 是异步投递的：在它到达之前不要往下跑
  while (true) {
    sleep(const Duration(milliseconds: 50));
  }
}

LogLevel _preLevel(int i) {
  if (i % 50 == 0) return LogLevel.error;
  if (i % 10 == 0) return LogLevel.warn;
  return i % 2 == 0 ? LogLevel.info : LogLevel.debug;
}

/// pre 文件的测试行：每 10 行一条 warn，每 50 行一条 error，其余交替 debug / info；第 n/2 行之前 setUser。
void _preLines(int n) {
  for (var i = 1; i <= n; i++) {
    if (i == n ~/ 2 + 1) Retriever.setUser('killed-user');
    Retriever.log(_preLevel(i), 'pre $i', tag: 'kill', attrs: {'i': i});
  }
}

Future<void> _staticEnv(String root) async {
  final p = _HeadlessPlatform(root);
  await RetrieverRuntime.resetForTesting(platformFactory: () => p);
  RetrieverRuntime.touch();
  for (var i = 0; i < 1000 && RetrieverRuntime.root == null; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _preMode(List<String> args) async {
  if (args[0] == '--probe-lock') {
    final l = await SessionLock.tryAcquire(args[1]);
    await _say(l == null ? 'locked' : 'free');
    l?.release();
    exit(0);
  }
  final root = args[1];
  final n = int.parse(args[2]);
  await _staticEnv(root);
  _preLines(n);
  switch (args[0]) {
    case '--pre':
      break;
    case '--pre-hold':
      await _say('ready');
      await stdin.first;
      return;
    case '--adopt-crash':
    case '--adopt-crash-writing':
      final point = args[3];
      final writing = args[0] == '--adopt-crash-writing';
      TestHooks.adoption = (p) {
        // 收编期间宿主还在写（configure 之后的行 = r = 1，追加到 pre 文件尾）
        if (writing && p == 'record:30') {
          for (var k = 0; k < 10; k++) {
            Retriever.log(LogLevel.warn, 'post $k', tag: 'kill');
          }
        }
        if (p == point) _kill();
      };
      await Retriever.configure(
        '',
        baseUrl: 'https://invalid.example',
        options: const RetrieverOptions(uploadLevel: LogLevel.info),
      );
      // 收编在引擎队列上；走到崩溃点之前别退出（没走到 = 测试失败：父进程会看到退出码不是 SIGKILL）
      await Future<void>.delayed(const Duration(seconds: 10));
      exit(3);
  }
  await _say('pre=$n');
  _kill();
}

LogLevel _lineLevel(int i) {
  if (i % 1000 == 0) return LogLevel.error;
  if (i % 10 == 0) return LogLevel.warn;
  return i % 2 == 0 ? LogLevel.info : LogLevel.debug;
}

Future<void> main(List<String> args) async {
  if (args[0].startsWith('--')) {
    await _preMode(args);
    return;
  }
  final root = args[0];
  final n = int.parse(args[1]);
  final torn = args.contains('--torn');
  // key 为空：不上传（不联网），只验证落盘与恢复
  final p = _HeadlessPlatform(root);
  final client = RetrieverClient(
    root: root,
    key: '',
    baseUrl: 'https://invalid.example',
    options: const RetrieverOptions(),
    platform: p,
    autoProcessName: 'main',
    deviceFields: _HeadlessPlatform.device,
    token: p.token,
    foreground: true,
  );
  await client.prepare();
  client.attach();
  client.start();
  for (var i = 1; i <= n; i++) {
    client.log(_lineLevel(i), 'line $i ${'x' * 64}', 'kill', {'i': i}, null, null);
  }
  if (torn) {
    // 模拟撕裂：下一行只写一半（前缀在同一次 write 里先写，所以能认出 seq / oseq）
    final f = client.debugOpenSegmentFile!;
    final (seq, oseq) = client.debugCounters;
    final raf = File(f).openSync(mode: FileMode.append);
    raf.writeStringSync('{"seq":${seq + 1},"oseq":${oseq + 1},"ts":1,"level":"warn","msg":"to');
    raf.closeSync();
  }
  if (args.contains('--fatal')) {
    // fatal：调用方只写行与换段，封段物化在引擎队列上异步做（ADR 0020 决定 1）——写完立即杀进程。计数先报（fatal 必占 seq / oseq）
    final (seq, oseq) = client.debugCounters;
    await _say('seq=${seq + 1} oseq=${oseq + 1}');
    client.log(LogLevel.fatal, 'last words', 'kill', null, StateError('fatal'), StackTrace.current);
    _kill();
  }
  // 输出计数给测试核对，然后硬杀自己
  final (seq, oseq) = client.debugCounters;
  await _say('seq=$seq oseq=$oseq');
  assert(Fs.baseName(root).isNotEmpty);
  _kill();
}
