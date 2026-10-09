// flutter test（切片 2 简报 §1）：ChannelPlatform 的 v3 §3 契约编解码与反向事件分发。
// 文件名不以 `_test.dart` 结尾：纯 Dart 的 `dart test` 不会去编译它（这里 import flutter_test / dart:ui）。
// 跑法：`flutter test test/flutter/*.dart`。未打桩 channel 与 dart:io 异步 I/O 在 testWidgets 里会挂（核实 round2 #10）——这里一律 test()。

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:revdog_retriever/src/channel_platform.dart';
import 'package:revdog_retriever/src/platform.dart';

const MethodChannel channel = MethodChannel(ChannelPlatform.channelName);
const StandardMethodCodec codec = StandardMethodCodec();

TestDefaultBinaryMessenger get messenger => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// 原生 → Dart：经同一 channel 送一条反向调用，返回 Dart 的回包（notImplemented = null）。
Future<Object?> fromNative(String method, [Object? args]) async {
  final reply = Completer<ByteData?>();
  await messenger.handlePlatformMessage(
    ChannelPlatform.channelName,
    codec.encodeMethodCall(MethodCall(method, args)),
    reply.complete,
  );
  final data = await reply.future;
  return data == null ? _notImplemented : codec.decodeEnvelope(data);
}

const Object _notImplemented = 'notImplemented';

class Recorder implements PlatformEventHandler {
  final List<String> events = <String>[];
  bool reschedule = true;
  bool drainThrows = false;

  @override
  void didEnterBackground(int? bgTaskId) => events.add('bg:$bgTaskId');

  @override
  void willEnterForeground() => events.add('fg');

  @override
  void foregroundStateChanged(bool foreground) => events.add('state:$foreground');

  @override
  void backgroundTaskExpired(int id) => events.add('expired:$id');

  @override
  void networkRestored() => events.add('net');

  @override
  Future<bool> drainOutbox(int budgetMs) async {
    events.add('drain:$budgetMs');
    if (drainThrows) throw StateError('drain failed');
    return reschedule;
  }

  @override
  void stopUploadJob() => events.add('stop');

  @override
  void ownerReleased() => events.add('released');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  void mock(Object? Function(MethodCall call) reply) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  }

  setUp(() => calls = <MethodCall>[]);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('→ 方向编解码', () {
    test('root：无参数；回包 {root, token, process?, device?}', () async {
      mock(
        (c) => <String, Object?>{
          'root': '/data/r',
          'token': '3f0c8a5e-1b2c-4d3e-8f4a-5b6c7d8e9f00',
          'process': 'main',
          'device': <String, Object?>{'os': 'android', 'os_version': '15', 'build': 45},
          'extra': true,
        },
      );
      final r = await ChannelPlatform().root();
      expect(calls.single.method, 'root');
      expect(calls.single.arguments, isNull);
      expect(r.root, '/data/r');
      expect(r.token, '3f0c8a5e-1b2c-4d3e-8f4a-5b6c7d8e9f00');
      expect(r.process, 'main');
      expect(r.device, <String, String>{'os': 'android', 'os_version': '15', 'build': '45'});

      mock((c) => <String, Object?>{'root': '/r', 'token': '3f0c8a5e-1b2c-4d3e-8f4a-5b6c7d8e9f00'});
      final bare = await ChannelPlatform().root();
      expect(bare.process, isNull, reason: 'process / device 可选（切片 1 裁决）');
      expect(bare.device, isNull);
    });

    test('root / bootstrap 回包形状不对 = 垫片错误（failed）', () async {
      mock((c) => <String, Object?>{'root': 1});
      await expectLater(
        ChannelPlatform().root(),
        throwsA(isA<PlatformCallException>().having((e) => e.code, 'code', ChannelPlatform.badReply)),
      );
      mock((c) => <String, Object?>{'root': '/r', 'token': 't'});
      await expectLater(
        ChannelPlatform().bootstrap(),
        throwsA(isA<PlatformCallException>().having((e) => e.code, 'code', ChannelPlatform.badReply)),
      );
      mock((c) => null);
      await expectLater(ChannelPlatform().root(), throwsA(isA<PlatformCallException>()));
    });

    test('bootstrap：{owner, root, token, process, foreground?, device}', () async {
      mock(
        (c) => <String, Object?>{
          'owner': true,
          'root': '/r',
          'token': '3f0c8a5e-1b2c-4d3e-8f4a-5b6c7d8e9f00',
          'process': 'remote',
          'foreground': false,
          'device': <String, Object?>{
            'os': 'ios',
            'os_version': '27.0',
            'model': 'iPhone18,1',
            'app_version': '1.0',
            'build': '1',
            'locale': 'en_US',
          },
        },
      );
      final b = await ChannelPlatform().bootstrap();
      expect(calls.single.method, 'bootstrap');
      expect(calls.single.arguments, isNull);
      expect(b.owner, isTrue);
      expect(b.process, 'remote');
      expect(b.foreground, isFalse);
      expect(b.device['model'], 'iPhone18,1');

      mock(
        (c) => <String, Object?>{
          'owner': false,
          'root': '/r',
          'token': '3f0c8a5e-1b2c-4d3e-8f4a-5b6c7d8e9f00',
          'foreground': null,
        },
      );
      final n = await ChannelPlatform().bootstrap();
      expect(n.owner, isFalse);
      expect(n.foreground, isNull, reason: '读不到前后台 = null（v3 §1.4）');
      expect(n.process, 'main');
      expect(n.device, isEmpty);
    });

    test('diagnose / 作业 / 后台任务 / 可用空间：参数以契约参数名为键', () async {
      Object? jobReply = true;
      Object? bytes = 123456789012;
      mock((c) {
        switch (c.method) {
          case 'scheduleUploadJob':
          case 'cancelUploadJob':
            return jobReply;
          case 'availableBytes':
            return bytes;
        }
        return null;
      });
      final p = ChannelPlatform();
      await p.diagnose('no_key', 'Retriever: no key');
      expect(await p.scheduleUploadJob(0x5254), isTrue);
      expect(await p.cancelUploadJob(0x5254), isTrue);
      await p.endBackgroundTask(7);
      expect(await p.availableBytes(), 123456789012);
      expect(calls.map((c) => c.method), <String>[
        'diagnose',
        'scheduleUploadJob',
        'cancelUploadJob',
        'endBackgroundTask',
        'availableBytes',
      ]);
      expect(calls[0].arguments, <String, Object?>{'code': 'no_key', 'message': 'Retriever: no key'});
      expect(calls[1].arguments, <String, Object?>{'jobId': 0x5254});
      expect(calls[2].arguments, <String, Object?>{'jobId': 0x5254});
      expect(calls[3].arguments, <String, Object?>{'id': 7});
      expect(calls[4].arguments, isNull);

      jobReply = false;
      expect(await p.scheduleUploadJob(1), isFalse, reason: '排不上（同 id 是别人的作业）');
      jobReply = null;
      expect(await p.cancelUploadJob(1), isFalse);
      bytes = null;
      expect(await p.availableBytes(), isNull);
      bytes = -1;
      expect(await p.availableBytes(), isNull);
      bytes = 2.5e9;
      expect(await p.availableBytes(), 2500000000);
    });

    test('MissingPluginException → PlatformUnsupportedException；PlatformException → PlatformCallException', () async {
      mock((c) => throw MissingPluginException('none'));
      await expectLater(ChannelPlatform().root(), throwsA(isA<PlatformUnsupportedException>()));
      await expectLater(ChannelPlatform().bootstrap(), throwsA(isA<PlatformUnsupportedException>()));
      await expectLater(ChannelPlatform().diagnose('c', 'm'), throwsA(isA<PlatformUnsupportedException>()));

      mock((c) => throw PlatformException(code: 'boom', message: 'native failed'));
      await expectLater(
        ChannelPlatform().bootstrap(),
        throwsA(
          isA<PlatformCallException>()
              .having((e) => e.code, 'code', 'boom')
              .having((e) => e.message, 'm', 'native failed'),
        ),
      );
    });

    test('未打桩（插件没注册）：test() 里同样是 MissingPluginException → unsupported', () async {
      await expectLater(ChannelPlatform().root(), throwsA(isA<PlatformUnsupportedException>()));
    });
  });

  group('← 方向事件分发', () {
    test('处理器在构造时就装（早于 root()）：每个事件按参数名取值', () async {
      final p = ChannelPlatform();
      final r = Recorder();
      p.eventHandler = r;
      expect(await fromNative('didEnterBackground', <String, Object?>{'bgTaskId': 5}), isNull);
      await fromNative('didEnterBackground', <String, Object?>{'bgTaskId': null});
      await fromNative('willEnterForeground');
      await fromNative('foregroundStateChanged', <String, Object?>{'fg': false});
      await fromNative('backgroundTaskExpired', <String, Object?>{'id': 9});
      await fromNative('networkRestored');
      await fromNative('stopUploadJob');
      await fromNative('ownerReleased');
      expect(r.events, <String>['bg:5', 'bg:null', 'fg', 'state:false', 'expired:9', 'net', 'stop', 'released']);
    });

    test('drainOutbox(budgetMs) → {reschedule}；处理器抛 = 不重排', () async {
      final p = ChannelPlatform();
      final r = Recorder();
      p.eventHandler = r;
      expect(await fromNative('drainOutbox', <String, Object?>{'budgetMs': 120000}), <String, Object?>{
        'reschedule': true,
      });
      r.reschedule = false;
      expect(await fromNative('drainOutbox', <String, Object?>{'budgetMs': 1}), <String, Object?>{'reschedule': false});
      r.drainThrows = true;
      expect(await fromNative('drainOutbox', <String, Object?>{'budgetMs': 2}), <String, Object?>{'reschedule': false});
      expect(r.events, <String>['drain:120000', 'drain:1', 'drain:2']);
    });

    test('没有事件出口：drainOutbox 回不重排；带 id 的 didEnterBackground 立即 end（不留到过期）', () async {
      mock((c) => null);
      final p = ChannelPlatform();
      p.eventHandler = null;
      expect(await fromNative('drainOutbox', <String, Object?>{'budgetMs': 5}), <String, Object?>{'reschedule': false});
      await fromNative('didEnterBackground', <String, Object?>{'bgTaskId': 41});
      await pumpEventQueue();
      expect(calls.map((c) => '${c.method} ${c.arguments}'), <String>['endBackgroundTask {id: 41}']);
    });

    test('未知事件 → notImplemented', () async {
      ChannelPlatform().eventHandler = Recorder();
      expect(await fromNative('somethingNew'), same(_notImplemented));
    });
  });

  group('根 isolate 判定', () {
    test('根 isolate：工厂建 ChannelPlatform；worker isolate：工厂抛（facade 当「没有平台」→ unsupported）', () async {
      expect(ChannelPlatform.forCurrentIsolate(), isA<ChannelPlatform>());
      final inWorker = await Isolate.run(() {
        try {
          ChannelPlatform.forCurrentIsolate();
          return 'created';
        } on PlatformUnsupportedException {
          return 'unsupported';
        }
      });
      expect(inWorker, 'unsupported');
    });
  });
}
