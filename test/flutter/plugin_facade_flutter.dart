// flutter test（切片 2 简报 §1）：插件入口与 facade 经真 ChannelPlatform 走通 K1 状态机——registerWith 注入工厂、宿主 flutter test
// 判 unsupported、MissingPluginException → unsupported 终态且 configure 后无 pending Timer、PlatformException → failed、
// diagnose 通道不可用退回 print、owner / 非 owner / ownerReleased 接任、web stub 与桌面 no-op。
// 跑法：`flutter test test/flutter/*.dart`（文件名不以 `_test.dart` 结尾，纯 Dart 的 `dart test` 不碰它）。

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:revdog_retriever/revdog_retriever.dart';
import 'package:revdog_retriever/src/channel_platform.dart';
import 'package:revdog_retriever/src/config_diagnostics.dart';
import 'package:revdog_retriever/src/ids.dart';
import 'package:revdog_retriever/src/plugin_entry.dart';
import 'package:revdog_retriever/src/retriever.dart' show RetrieverRuntime, RetrieverState;
import 'package:revdog_retriever/src/retriever_stub.dart' as web;

const MethodChannel channel = MethodChannel(ChannelPlatform.channelName);
const StandardMethodCodec codec = StandardMethodCodec();

TestDefaultBinaryMessenger get messenger => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

Future<Object?> fromNative(String method, [Object? args]) async {
  final reply = Completer<ByteData?>();
  await messenger.handlePlatformMessage(
    ChannelPlatform.channelName,
    codec.encodeMethodCall(MethodCall(method, args)),
    reply.complete,
  );
  final data = await reply.future;
  return data == null ? null : codec.decodeEnvelope(data);
}

/// 假垫片（原生侧）：按 v3 §3 回包，记下每个调用。
class FakeShim {
  FakeShim(this.root);

  final String root;
  final String token = Ids.newV4();
  final List<MethodCall> calls = <MethodCall>[];
  bool owner = true;
  Object? Function(MethodCall call)? override;

  Map<String, Object?> get rootReply => _base;

  Map<String, Object?> get _base => <String, Object?>{
    'root': root,
    'token': token,
    'process': 'main',
    'device': <String, Object?>{
      'os': 'android',
      'os_version': '15',
      'model': 'Google sdk_gphone64_arm64',
      'app_version': '1.0.0',
      'build': '1',
      'locale': 'en-US',
    },
  };

  void install() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final o = override;
      if (o != null) {
        final r = o(call);
        if (r != null || call.method != 'root') return r;
      }
      switch (call.method) {
        case 'root':
          return _base;
        case 'bootstrap':
          return <String, Object?>{..._base, 'owner': owner, 'foreground': true};
        case 'scheduleUploadJob':
        case 'cancelUploadJob':
          return true;
        case 'availableBytes':
          return 10 * 1024 * 1024 * 1024;
      }
      return null;
    });
  }

  List<String> get methods => calls.map((c) => c.method).toList();
}

Future<bool> waitFor(bool Function() cond, {Duration timeout = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return cond();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final temps = <Directory>[];
  String tempRoot() {
    final d = Directory.systemTemp.createTempSync('rtv-flutter');
    temps.add(d);
    return '${d.resolveSymbolicLinksSync()}/retriever';
  }

  final savedDefault = RetrieverRuntime.defaultPlatformFactory;

  setUp(() async {
    await RetrieverRuntime.resetForTesting(platformFactory: ChannelPlatform.new);
  });

  tearDown(() async {
    await RetrieverRuntime.resetForTesting();
    RetrieverRuntime.defaultPlatformFactory = savedDefault;
    messenger.setMockMethodCallHandler(channel, null);
    for (final d in temps) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    }
    temps.clear();
  });

  group('插件入口', () {
    test('registerWith 只注入工厂：不发平台消息、不碰文件；工厂在根 isolate 建 ChannelPlatform', () {
      final shim = FakeShim(tempRoot())..install();
      RetrieverRuntime.defaultPlatformFactory = null;
      RetrieverDartPlugin.registerWith();
      expect(RetrieverRuntime.defaultPlatformFactory, isNotNull);
      expect(shim.calls, isEmpty);
      expect(RetrieverRuntime.defaultPlatformFactory!(), isA<ChannelPlatform>());
      expect(shim.calls, isEmpty, reason: '建平台也不发消息（root 在首次触达时才要）');
    });

    test('宿主 flutter test（FLUTTER_TEST）：注入了工厂也在任何 channel 调用之前判 unsupported', () async {
      final shim = FakeShim(tempRoot())..install();
      await RetrieverRuntime.resetForTesting();
      RetrieverDartPlugin.registerWith();
      expect(Platform.environment['FLUTTER_TEST'], 'true');
      Retriever.log(LogLevel.error, 'x');
      await Retriever.configure('');
      expect(RetrieverRuntime.state, RetrieverState.unsupported);
      expect(shim.calls, isEmpty);
      expect(await Retriever.flush(), isA<FlushPending>());
    });

    test('桌面 / web：facade 判 unsupported；web stub 全部入口 no-op 不抛', () async {
      expect(RetrieverRuntime.hostUnsupported(const <String, String>{}, 'macos'), isTrue);
      expect(RetrieverRuntime.hostUnsupported(const <String, String>{}, 'linux'), isTrue);
      expect(RetrieverRuntime.hostUnsupported(const <String, String>{}, 'android'), isFalse);
      expect(RetrieverRuntime.hostUnsupported(const <String, String>{}, 'ios'), isFalse);
      expect(RetrieverRuntime.hostUnsupported(const <String, String>{'FLUTTER_TEST': 'true'}, 'ios'), isTrue);
      await web.Retriever.configure('k');
      web.Retriever.log(LogLevel.fatal, 'x');
      web.Retriever.setUser('u');
      web.Retriever.setEnabled(false);
      expect(web.Retriever.isEnabled, isFalse);
      expect(await web.Retriever.flush(), isA<FlushPending>());
      await web.Retriever.purgeLocal();
      expect(web.Retriever.installId, isNull);
      expect(web.Retriever.supportCode, isNull);
    });
  });

  group('K1 经真 channel', () {
    testWidgets('MissingPluginException → unsupported 终态；configure 有界完成、之后无 pending Timer', (tester) async {
      // facade 的静态 Future 链要在 FakeAsync 区里新建（setUp 在真实区建的已完成 Future 的回调排在真实 microtask 队列，这里推不动）
      await RetrieverRuntime.resetForTesting(platformFactory: ChannelPlatform.new);
      messenger.setMockMethodCallHandler(channel, (call) async => throw MissingPluginException());
      await Retriever.configure('', baseUrl: 'https://logs.revdog.org');
      await tester.pump();
      expect(RetrieverRuntime.state, RetrieverState.unsupported);
      Retriever.log(LogLevel.error, 'after unsupported');
      expect(await Retriever.flush(), isA<FlushPending>());
      expect(Retriever.isEnabled, isFalse);
      // testWidgets 结束时断言没有 pending Timer（root / bootstrap 的 5 s 超时、diagnose 的 2 s 超时都已取消）
    });

    test('PlatformException → failed；configure 有界完成；显式再 configure 重新 bootstrap', () async {
      var bootstraps = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'bootstrap') bootstraps++;
        throw PlatformException(code: 'boom');
      });
      await Retriever.configure('').timeout(const Duration(seconds: 6));
      expect(RetrieverRuntime.state, RetrieverState.failed);
      expect(RetrieverRuntime.root, isNull);
      await Retriever.configure('').timeout(const Duration(seconds: 6));
      expect(bootstraps, 2);
      expect(RetrieverRuntime.state, RetrieverState.failed);
    });

    test('diagnose 经 channel；通道不可用退回 print、仍不抛', () async {
      final shim = FakeShim(tempRoot())..install();
      expect(RetrieverRuntime.touch(), isTrue);
      ConfigDiagnostics.configured('', '', 'https://logs.revdog.org');
      await pumpEventQueue();
      final diag = shim.calls.where((c) => c.method == 'diagnose').toList();
      expect(diag.single.arguments, <String, Object?>{
        'code': 'no_key',
        'message': (diag.single.arguments as Map)['message'],
      });

      ConfigDiagnostics.clearSeenForTesting();
      shim.override = (call) => call.method == 'diagnose' ? throw MissingPluginException() : null;
      final printed = <String>[];
      await runZoned(() async {
        ConfigDiagnostics.configured('', '', 'https://logs.revdog.org');
        await pumpEventQueue();
      }, zoneSpecification: ZoneSpecification(print: (_, _, _, line) => printed.add(line)));
      expect(printed, hasLength(1));
      expect(printed.single, startsWith('Retriever: '));
    });

    test('owner：configure 经 root / bootstrap 回包建实例；进后台的 bgTaskId 由实例 end', () async {
      final shim = FakeShim(tempRoot())..install();
      await Retriever.configure('', baseUrl: 'https://logs.revdog.org').timeout(const Duration(seconds: 10));
      expect(RetrieverRuntime.state, RetrieverState.ready);
      expect(Retriever.installId, isNotNull);
      // 首触发 root()；configure 一进来就出诊断（空 key → no_key），再 bootstrap（v3 §1 §13）
      expect(shim.methods.take(3), <String>['root', 'diagnose', 'bootstrap']);
      expect(Directory(shim.root).existsSync(), isTrue);

      await fromNative('didEnterBackground', <String, Object?>{'bgTaskId': 77});
      expect(
        await waitFor(() => shim.calls.any((c) => c.method == 'endBackgroundTask')),
        isTrue,
        reason: '后台排空结束后 end 原生后台任务',
      );
      expect(shim.calls.firstWhere((c) => c.method == 'endBackgroundTask').arguments, <String, Object?>{'id': 77});
      await fromNative('willEnterForeground');
      await fromNative('foregroundStateChanged', <String, Object?>{'fg': true});
      expect(await fromNative('drainOutbox', <String, Object?>{'budgetMs': 1000}), isA<Map<Object?, Object?>>());
    });

    test('bootstrap 回包还没处理时到达的 ownerReleased 不丢：回包之后再投 → 接任（合线程下的派发次序）', () async {
      final shim = FakeShim(tempRoot())..install();
      var bootstraps = 0;
      shim.override = (call) {
        if (call.method != 'bootstrap') return null;
        bootstraps++;
        if (bootstraps == 1) {
          // 原生：先判 owner=false（旧 owner 还活着），回包排队的同时旧 owner detach → ownerReleased 先于回包到 Dart
          fromNative('ownerReleased').ignore();
          return <String, Object?>{...shim.rootReply, 'owner': false, 'foreground': true};
        }
        return <String, Object?>{...shim.rootReply, 'owner': true, 'foreground': true};
      };
      await Retriever.configure('', baseUrl: 'https://logs.revdog.org').timeout(const Duration(seconds: 10));
      expect(await waitFor(() => RetrieverRuntime.state == RetrieverState.ready), isTrue);
      expect(bootstraps, 2);
      expect(Retriever.installId, isNotNull);
    });

    test('非 owner：configure_ignored 诊断；ownerReleased → 立即重试 bootstrap → 接任', () async {
      final shim = FakeShim(tempRoot())..install();
      shim.owner = false;
      await Retriever.configure('', baseUrl: 'https://logs.revdog.org').timeout(const Duration(seconds: 10));
      expect(RetrieverRuntime.state, RetrieverState.nonOwner);
      expect(Retriever.installId, isNull);
      await pumpEventQueue();
      final diag = shim.calls.where((c) => c.method == 'diagnose').map((c) => (c.arguments as Map)['code']).toList();
      expect(diag, contains(ConfigDiagnostics.nonOwnerCode));
      Retriever.log(LogLevel.warn, 'written to own pre file while non-owner');

      shim.owner = true;
      await fromNative('ownerReleased');
      expect(await waitFor(() => RetrieverRuntime.state == RetrieverState.ready), isTrue);
      expect(Retriever.installId, isNotNull);
      expect(shim.methods.where((m) => m == 'bootstrap'), hasLength(2));
    });
  });
}
