// 真垫片的 Dart 端（v3 §3 契约；切片 2）：MethodChannel `org.revdog.retriever` 上的 [RetrieverPlatform]。
// 引擎里唯一 import `package:flutter/services.dart` 的文件（purity_test 守）；facade / client 不知道 channel 的存在。
//
// - → 方向：`root` / `bootstrap` / `diagnose` / `scheduleUploadJob` / `cancelUploadJob` / `endBackgroundTask` / `availableBytes`，
//   参数一律是以契约参数名为键的 Map（`{code, message}`、`{jobId}`、`{id}`），回包按契约解析；回包形状不对 = 垫片错误。
// - ← 方向：同一 channel 的反向 `invokeMethod`（`didEnterBackground` / `willEnterForeground` / `foregroundStateChanged` /
//   `backgroundTaskExpired` / `networkRestored` / `drainOutbox` / `stopUploadJob` / `ownerReleased`），参数同样是 Map
//   （`{bgTaskId}`、`{fg}`、`{id}`、`{budgetMs}`）；`drainOutbox` 回 `{reschedule: bool}`。处理器在构造时装（早于 `root()`）。
// - 错误映射：`MissingPluginException` → [PlatformUnsupportedException]（K1 unsupported 终态）；`PlatformException`、
//   binding 未初始化（宿主在 `WidgetsFlutterBinding.ensureInitialized()` 之前就触达）、回包形状不对 → [PlatformCallException]
//   （K1 failed，下一次触达重试）。超时由调用方施加（facade / client，v3 §3）。
// - 纯转发：不排序、不暂存事件。「bootstrap 回包与其后事件的到达次序不保证」由 facade 处理（retriever.dart `_retryAfterBootstrap`）。
// - 非根 isolate（`Isolate.spawn` / `compute`，`RootIsolateToken.instance == null`）不建平台：[forCurrentIsolate] 抛 →
//   facade 的 `touch()` 当「没有平台」→ 该 isolate unsupported（v3 §4、§10）。

import 'dart:async';

import 'package:flutter/services.dart';

import 'clock.dart';
import 'platform.dart';
import 'transport.dart';

class ChannelPlatform implements RetrieverPlatform {
  /// [channel] / [clock] / [transport] 只给测试替换。
  ChannelPlatform({MethodChannel? channel, Clock? clock, Transport? transport})
    : _channel = channel ?? const MethodChannel(channelName),
      clock = clock ?? SystemClock(),
      transport = transport ?? HttpClientTransport() {
    _installHandler();
  }

  static const String channelName = 'org.revdog.retriever';

  /// 插件入口注入的生产工厂：只在根 isolate 建平台。不发平台消息、不碰文件。
  ///
  /// 非根 isolate（worker）**抛** [PlatformUnsupportedException]：`RetrieverRuntime.defaultPlatformFactory` 的类型是
  /// `RetrieverPlatform Function()?`（返回值不可空），facade 的 `touch()` 把工厂抛出的任何东西当「没有平台」→ 该 isolate unsupported
  /// ——与简报「工厂返回 null」同一结果（REPORT-slice2「偏离」）。
  static RetrieverPlatform forCurrentIsolate() {
    if (RootIsolateToken.instance == null) {
      throw const PlatformUnsupportedException('not a root isolate');
    }
    return ChannelPlatform();
  }

  final MethodChannel _channel;
  bool _handlerInstalled = false;
  PlatformEventHandler? _handler;

  @override
  final Clock clock;

  @override
  final Transport transport;

  @override
  set eventHandler(PlatformEventHandler? handler) {
    _handler = handler;
    _installHandler();
  }

  /// 装反向调用的处理器。binding 还没初始化时（`ServicesBinding.instance` 抛）先不装，下一次 → 方向调用之前再装。
  bool _installHandler() {
    if (_handlerInstalled) return true;
    try {
      _channel.setMethodCallHandler(_onCall);
      _handlerInstalled = true;
    } catch (_) {
      _handlerInstalled = false;
    }
    return _handlerInstalled;
  }

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    // 处理器必须早于第一个 → 方向调用（回包到订阅之间不丢事件，v3 §3）；装不上 = binding 未初始化 → failed
    if (!_installHandler()) {
      throw const PlatformCallException(bindingUninitialized, 'Flutter binding is not initialized');
    }
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException catch (e) {
      throw PlatformUnsupportedException(e.message);
    } on PlatformException catch (e) {
      throw PlatformCallException(e.code, e.message);
    } catch (e) {
      // binding 未初始化（FlutterError）、codec 错误等：按调用失败处理（K1 failed）
      throw PlatformCallException(channelError, e.toString());
    }
  }

  static const String bindingUninitialized = 'binding_uninitialized';
  static const String channelError = 'channel_error';
  static const String badReply = 'bad_reply';

  // MARK: → 方向

  @override
  Future<RootInfo> root() async {
    final r = await _invoke<Object?>('root');
    final m = _map(r);
    final root = m?['root'];
    final token = m?['token'];
    if (root is! String || root.isEmpty || token is! String) {
      throw const PlatformCallException(badReply, 'root() reply is not {root, token, …}');
    }
    final process = m!['process'];
    return RootInfo(
      root: root,
      token: token,
      process: process is String ? process : null,
      device: _stringMap(m['device']),
    );
  }

  @override
  Future<BootstrapInfo> bootstrap() async {
    final r = await _invoke<Object?>('bootstrap');
    final m = _map(r);
    final owner = m?['owner'];
    final root = m?['root'];
    final token = m?['token'];
    if (owner is! bool || root is! String || root.isEmpty || token is! String) {
      throw const PlatformCallException(badReply, 'bootstrap() reply is not {owner, root, token, …}');
    }
    final process = m!['process'];
    final fg = m['foreground'];
    return BootstrapInfo(
      owner: owner,
      root: root,
      token: token,
      process: process is String && process.isNotEmpty ? process : 'main',
      foreground: fg is bool ? fg : null,
      device: _stringMap(m['device']) ?? const <String, String>{},
    );
  }

  @override
  Future<void> diagnose(String code, String message) async {
    await _invoke<Object?>('diagnose', <String, Object?>{'code': code, 'message': message});
  }

  @override
  Future<bool> scheduleUploadJob(int jobId) async {
    final r = await _invoke<Object?>('scheduleUploadJob', <String, Object?>{'jobId': jobId});
    return r == true;
  }

  @override
  Future<bool> cancelUploadJob(int jobId) async {
    final r = await _invoke<Object?>('cancelUploadJob', <String, Object?>{'jobId': jobId});
    return r == true;
  }

  @override
  Future<void> endBackgroundTask(int id) async {
    await _invoke<Object?>('endBackgroundTask', <String, Object?>{'id': id});
  }

  @override
  Future<int?> availableBytes() async {
    final r = await _invoke<Object?>('availableBytes');
    if (r is int) return r >= 0 ? r : null;
    if (r is num && r.isFinite && r >= 0) return r.toInt();
    return null;
  }

  // MARK: ← 方向

  Future<Object?> _onCall(MethodCall call) async {
    final h = _handler;
    try {
      switch (call.method) {
        case 'didEnterBackground':
          final id = _int(call.arguments, 'bgTaskId');
          if (h != null) {
            h.didEnterBackground(id);
          } else if (id != null) {
            // 没有事件出口（unsupported / 已卸下）：后台任务不能留着等过期——立即 end（iOS 幂等记账）
            endBackgroundTask(id).catchError((Object _) {}).ignore();
          }
          return null;
        case 'willEnterForeground':
          h?.willEnterForeground();
          return null;
        case 'foregroundStateChanged':
          final fg = _bool(call.arguments, 'fg');
          if (fg != null) h?.foregroundStateChanged(fg);
          return null;
        case 'backgroundTaskExpired':
          final id = _int(call.arguments, 'id');
          if (id != null) h?.backgroundTaskExpired(id);
          return null;
        case 'networkRestored':
          h?.networkRestored();
          return null;
        case 'drainOutbox':
          final budget = _int(call.arguments, 'budgetMs') ?? 0;
          final reschedule = h == null ? false : await h.drainOutbox(budget);
          return <String, Object?>{'reschedule': reschedule};
        case 'stopUploadJob':
          h?.stopUploadJob();
          return null;
        case 'ownerReleased':
          h?.ownerReleased();
          return null;
      }
    } catch (_) {
      // 事件处理器绝不把异常抛回垫片（drainOutbox 失败 = 不重排）
      if (call.method == 'drainOutbox') return <String, Object?>{'reschedule': false};
      return null;
    }
    // 未知方法：照 Flutter 惯例回 notImplemented（原生侧按「对端不认识」处理）
    throw MissingPluginException('Retriever: unknown event ${call.method}');
  }

  // MARK: 解码

  static Map<Object?, Object?>? _map(Object? v) => v is Map ? v.cast<Object?, Object?>() : null;

  static Map<String, String>? _stringMap(Object? v) {
    if (v is! Map) return null;
    final out = <String, String>{};
    v.forEach((k, val) {
      if (k is String && val != null) out[k] = val is String ? val : val.toString();
    });
    return out;
  }

  /// 契约参数是以参数名为键的 Map；也容忍直接传值（`invokeMethod("x", 5)`）。
  static Object? _arg(Object? args, String key) => args is Map ? args[key] : args;

  static int? _int(Object? args, String key) {
    final v = _arg(args, key);
    if (v is int) return v;
    if (v is num && v.isFinite) return v.toInt();
    return null;
  }

  static bool? _bool(Object? args, String key) {
    final v = _arg(args, key);
    return v is bool ? v : null;
  }
}
