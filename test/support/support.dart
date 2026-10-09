// 测试夹具（对位 Android `TestSupport.kt`）：路径与 golden、JSON 小工具、假时钟、假传输（内存）/ 假服务端（本地 HttpServer）、
// 假平台（v3 §3 契约全部方法与事件）、Harness（实例；默认经静态入口建）、StaticHarness（静态入口）、跨语言校验、段读取。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:revdog_retriever/src/client.dart';
import 'package:revdog_retriever/src/clock.dart';
import 'package:revdog_retriever/src/config_diagnostics.dart';
import 'package:revdog_retriever/src/engine.dart';
import 'package:revdog_retriever/src/fs.dart';
import 'package:revdog_retriever/src/gzip.dart';
import 'package:revdog_retriever/src/ids.dart';
import 'package:revdog_retriever/src/json.dart';
import 'package:revdog_retriever/src/model.dart';
import 'package:revdog_retriever/src/platform.dart';
import 'package:revdog_retriever/src/pre.dart';
import 'package:revdog_retriever/src/public_api.dart';
import 'package:revdog_retriever/src/retriever.dart';
import 'package:revdog_retriever/src/text.dart';
import 'package:revdog_retriever/src/transport.dart';
import 'package:test/test.dart';

export 'package:revdog_retriever/src/public_api.dart';
export 'package:revdog_retriever/src/retriever.dart' show Retriever, RetrieverRuntime, RetrieverState;

// ---------------------------------------------------------------- 路径

abstract final class Repo {
  /// 仓库根：从当前目录（dart test 的工作目录 = sdk/flutter）向上找 packages/core/golden。
  static final String root = () {
    var d = Directory.current.absolute;
    while (true) {
      if (Directory('${d.path}/packages/core/golden').existsSync()) return d.path;
      final p = d.parent;
      if (p.path == d.path) throw StateError('找不到仓库根（packages/core/golden）');
      d = p;
    }
  }();

  static Map<String, Object?> golden(String name) =>
      JsonIn.obj(File('$root/packages/core/golden/$name').readAsBytesSync()) ?? (throw StateError('golden $name 不是对象'));

  /// sdk/flutter 包目录。
  static String get package => '$root/sdk/flutter';
}

final List<String> _temps = <String>[];

String tempDir([String tag = 'rtv']) {
  final d = Directory.systemTemp.createTempSync(tag).resolveSymbolicLinksSync();
  _temps.add(d);
  return d;
}

/// 测试结束：删掉本用例建的临时目录（含 root 同级的 `.disabled` / `.purge-*`）。
void cleanTemps() {
  for (final d in _temps) {
    try {
      Directory(d).deleteSync(recursive: true);
    } catch (_) {}
    try {
      final parent = Directory(d).parent;
      final base = d.substring(d.lastIndexOf('/') + 1);
      for (final e in parent.listSync()) {
        final n = e.path.substring(e.path.lastIndexOf('/') + 1);
        if (n.startsWith('$base.')) e.deleteSync(recursive: true);
      }
    } catch (_) {}
  }
  _temps.clear();
}

// ---------------------------------------------------------------- JSON 小工具（测试用）

Map<String, Object?> obj(Object? v) => v as Map<String, Object?>;

List<Map<String, Object?>> objs(Object? v) => v is List ? [for (final x in v) x as Map<String, Object?>] : const [];

/// 数字取 int（缺省 / 非数字 = -999，同 iOS / Android 测试的 int()）。
int int_(Object? v) {
  if (v is int) return v;
  return JsonIn.int64(v) ?? -999;
}

String toJson(Object? v) {
  final o = JsonOut();
  _writeJson(o, v);
  return utf8.decode(o.toBytes(), allowMalformed: true);
}

void _writeJson(JsonOut o, Object? v) {
  if (v == null) {
    o.raw('null');
  } else if (v is String) {
    o.string(v);
  } else if (v is bool) {
    o.boolean(v);
  } else if (v is int) {
    o.integer(v);
  } else if (v is num) {
    o.number(v.toDouble());
  } else if (v is Map) {
    o.raw('{');
    var first = true;
    for (final e in v.entries) {
      if (!first) o.raw(',');
      first = false;
      o.string(e.key as String);
      o.raw(':');
      _writeJson(o, e.value);
    }
    o.raw('}');
  } else if (v is List) {
    o.raw('[');
    for (var i = 0; i < v.length; i++) {
      if (i > 0) o.raw(',');
      _writeJson(o, v[i]);
    }
    o.raw(']');
  } else {
    o.string(v.toString());
  }
}

/// 一个信封：原始（解压后）字节 + 解析结果。
class Env {
  Env(this.name, this.raw) : map = JsonIn.obj(raw) ?? (throw StateError('信封不是 JSON 对象：$name'));

  final String name;
  final Uint8List raw;
  final Map<String, Object?> map;

  Object? operator [](String k) => map[k];

  List<Map<String, Object?>> get lines => objs(map['lines']);

  static Env? ofGzip(String name, List<int> gz) {
    final d = Gzip.decompress(gz);
    return d == null ? null : Env(name, d);
  }
}

// ---------------------------------------------------------------- 假时钟

class FakeClock implements Clock {
  FakeClock({int wall = 1790668800000, int mono = 1000000}) : _wall = wall, _mono = mono;

  int _wall;
  int _mono;

  @override
  int wallMs() => _wall;

  @override
  int monoMs() => _mono;

  void advance(int ms) {
    _wall += ms;
    _mono += ms;
  }

  /// 流程内等待：直接推进假时间。
  @override
  Future<void> sleep(int ms) {
    advance(ms < 0 ? 0 : ms);
    return Future<void>.value();
  }

  /// 调度器请求过的定时延迟（断言「不以 0 ms 自旋」用；不真的调度）。
  final List<int> timerDelays = <int>[];

  @override
  int? timerDelayMs(int ms) {
    timerDelays.add(ms);
    return null;
  }
}

// ---------------------------------------------------------------- 假传输

sealed class Reply {
  const Reply();

  /// 200 回显本批 batch_id
  static const Reply echo = _Echo();

  /// 200 回显别的 batch_id
  static const Reply echoWrong = _EchoWrong();

  /// 网络错误
  static const Reply network = _Network();

  /// 挂起直到 cancelAll
  static const Reply hang = _Hang();

  static Reply status(int code, [Map<String, Object?>? body, Map<String, String> headers = const {}]) =>
      _Status(code, body, headers);

  /// 任意字节的响应体（HTML 错误页等非 JSON）
  static Reply raw(int code, List<int> body) => _Raw(code, body);

  /// 等 gate 放行后回 then（模拟「请求在途时宿主换了 key」）
  static Reply gated(Completer<void> gate, Reply then) => _Gated(gate, then);
}

class _Echo extends Reply {
  const _Echo();
}

class _EchoWrong extends Reply {
  const _EchoWrong();
}

class _Network extends Reply {
  const _Network();
}

class _Hang extends Reply {
  const _Hang();
}

class _Status extends Reply {
  const _Status(this.code, this.body, this.headers);

  final int code;
  final Map<String, Object?>? body;
  final Map<String, String> headers;
}

class _Raw extends Reply {
  const _Raw(this.code, this.body);

  final int code;
  final List<int> body;
}

class _Gated extends Reply {
  const _Gated(this.gate, this.then);

  final Completer<void> gate;
  final Reply then;
}

/// 回复脚本（内存假传输与本地假服务端共用）。
class ReplyScript {
  final List<Reply> _script = <Reply>[];
  Reply defaultReply = Reply.echo;

  /// 按批决定回复（优先于 script）。
  Reply? Function(String batchId)? responder;
  Map<String, Object?>? configBody;
  String configEtag = 'etag-0';

  /// 回显模式（与 ingest 一致，ADR 0022）：响应 = configBody 里远程明确给的字段 + 没给的宿主型字段按请求头补齐，并带 `from_host`。
  bool echoHost = false;

  /// 非 null 时配置请求挂在这里直到放行（模拟「拉配置在途」）。
  Completer<void>? configGate;
  final List<TransportRequest> requests = <TransportRequest>[];
  final List<Completer<void>> _hanging = <Completer<void>>[];
  int cancelCount = 0;

  void setScript(List<Reply> s) {
    _script
      ..clear()
      ..addAll(s);
  }

  List<TransportRequest> get batchRequests => requests.where((r) => r.url.endsWith('/v1/batches')).toList();

  List<TransportRequest> get configRequests => requests.where((r) => r.url.endsWith('/v1/config')).toList();

  int get hangingCount => _hanging.length;

  /// null = 网络错误。
  Future<TransportResponse?> respond(TransportRequest request) async {
    requests.add(request);
    final etag = configEtag;
    if (request.url.endsWith('/v1/config')) {
      final cfg = configBody;
      final gate = configGate;
      if (gate != null) await gate.future.timeout(const Duration(seconds: 30), onTimeout: () {});
      final c = cfg ?? configBody;
      if (c == null) return TransportResponse(404);
      return TransportResponse(200, {}, _bytes(echoHost ? _echo(c, request.headers) : c));
    }
    final bid = batchIdOf(request.body) ?? '';
    final Reply rep = responder?.call(bid) ?? (_script.isNotEmpty ? _script.removeAt(0) : defaultReply);
    return _reply(rep, bid, etag);
  }

  Future<TransportResponse?> _reply(Reply rep, String bid, String etag) async {
    switch (rep) {
      case _Echo():
        return TransportResponse(200, {}, _bytes({'batch_id': bid, 'status': 'stored', 'config_etag': etag}));
      case _EchoWrong():
        return TransportResponse(
          200,
          {},
          _bytes({'batch_id': '00000000-0000-4000-8000-000000000000', 'status': 'stored', 'config_etag': etag}),
        );
      case _Status(:final code, :final body, :final headers):
        return TransportResponse(code, {
          for (final e in headers.entries) e.key.toLowerCase(): e.value,
        }, body == null ? Uint8List(0) : _bytes(body));
      case _Raw(:final code, :final body):
        return TransportResponse(code, {}, Uint8List.fromList(body));
      case _Network():
        return null;
      case _Hang():
        final c = Completer<void>();
        _hanging.add(c);
        await c.future.timeout(const Duration(seconds: 30), onTimeout: () {});
        return null;
      case _Gated(:final gate, :final then):
        await gate.future.timeout(const Duration(seconds: 30), onTimeout: () {});
        if (then is _Status) return _reply(then, bid, etag);
        return _reply(Reply.echo, bid, etag);
    }
  }

  Map<String, Object?> _echo(Map<String, Object?> c, Map<String, String> headers) {
    final out = Map<String, Object?>.of(c);
    final fromHost = hostDerivedFields(c);
    for (final f in fromHost) {
      out[f] = switch (f) {
        'upload_level' => headers['X-Rtv-Upload-Level'],
        'local_level' => headers['X-Rtv-Local-Level'],
        'local_cap_bytes' => int.tryParse(headers['X-Rtv-Local-Cap-Bytes'] ?? ''),
        _ => int.tryParse(headers['X-Rtv-Daily-Batch-Cap'] ?? ''),
      };
    }
    out['from_host'] = fromHost;
    return out;
  }

  void cancelAll() {
    cancelCount += 1;
    final h = List.of(_hanging);
    _hanging.clear();
    for (final c in h) {
      if (!c.isCompleted) c.complete();
    }
  }

  static Uint8List _bytes(Object? v) => utf8.encode(toJson(v));

  static String? batchIdOf(List<int>? body) => envOf(body)?['batch_id'] as String?;

  static Env? envOf(List<int>? body) => body == null ? null : Env.ofGzip('request', body);
}

/// 内存假传输（对位 Android `FakeTransport`）。
class FakeTransport extends ReplyScript implements Transport {
  @override
  Future<TransportResponse?> send(TransportRequest request) => respond(request);

  static Env? envOf(List<int>? body) => ReplyScript.envOf(body);

  static String? batchId(List<int>? body) => ReplyScript.batchIdOf(body);
}

/// 回包压缩方式（模拟 Cloudflare 边缘：请求 `Accept-Encoding` 含 gzip 且体 ≥ 48 B 就压缩、回 `Content-Encoding: gzip`）。
enum ReplyGzip {
  /// 从不压缩。
  never,

  /// 请求允许（`Accept-Encoding` 含 gzip）且体 ≥ 48 B 才压缩（Cloudflare 的规则）。
  whenAccepted,

  /// 无视 `Accept-Encoding`（含 identity）一律压缩（不守规矩的中间盒）。
  always,
}

/// 本地假服务端（`HttpServer`，回复脚本同 [FakeTransport]）：给真实的 `HttpClientTransport` 用（v3 §7 K5 的传输层断言）。
class FakeServer extends ReplyScript {
  FakeServer._(this._server);

  final HttpServer _server;

  /// 每个请求处理前的延迟（模拟慢服务端）。
  Duration delay = Duration.zero;

  /// 回包压缩方式（默认不压缩）。
  ReplyGzip gzipReplies = ReplyGzip.never;

  /// 实际以 gzip 回出去的回包个数。
  int gzippedReplies = 0;

  String get base => 'http://127.0.0.1:${_server.port}';

  static Future<FakeServer> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final f = FakeServer._(s);
    s.listen((req) => f._handle(req).catchError((Object _) {}));
    return f;
  }

  Future<void> _handle(HttpRequest req) async {
    final body = BytesBuilder(copy: false);
    await for (final c in req) {
      body.add(c);
    }
    final headers = <String, String>{};
    req.headers.forEach((name, values) {
      // 还原成 SDK 发出的大小写（测试按 Android 的键名断言）
      headers[_canonical(name)] = values.join(',');
    });
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final tr = TransportRequest(req.method, '$base${req.uri}', headers, body.isEmpty ? null : body.takeBytes());
    final r = await respond(tr);
    if (r == null) {
      // 网络错误：直接断开连接
      try {
        final s = await req.response.detachSocket(writeHeaders: false);
        s.destroy();
      } catch (_) {}
      return;
    }
    req.response.statusCode = r.status;
    r.headers.forEach((k, v) => req.response.headers.set(k, v));
    final accepts = (req.headers[HttpHeaders.acceptEncodingHeader] ?? const <String>[])
        .expand((v) => v.split(','))
        .any((t) => t.trim().split(';').first.trim().toLowerCase() == 'gzip');
    final compress = switch (gzipReplies) {
      ReplyGzip.never => false,
      ReplyGzip.whenAccepted => accepts && r.body.length >= 48,
      ReplyGzip.always => r.body.isNotEmpty,
    };
    if (compress) {
      gzippedReplies++;
      req.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
      req.response.add(gzip.encode(r.body));
    } else {
      req.response.add(r.body);
    }
    await req.response.close();
  }

  static String _canonical(String lower) {
    const known = [
      'Authorization',
      'Content-Type',
      'Content-Encoding',
      'X-Rtv-Install',
      'X-Rtv-Sent-Ms',
      'X-Rtv-Sdk',
      'X-Rtv-App-Version',
      'X-Rtv-Upload-Level',
      'X-Rtv-Local-Level',
      'X-Rtv-Daily-Batch-Cap',
      'X-Rtv-Local-Cap-Bytes',
      'X-Rtv-User',
    ];
    for (final k in known) {
      if (k.toLowerCase() == lower) return k;
    }
    return lower;
  }

  Future<void> close() => _server.close(force: true);
}

// ---------------------------------------------------------------- 假平台

enum CallMode { ok, hang, fail, unsupported }

/// 假平台（v3 §3 契约全部方法与事件回调）：root / bootstrap 可配 owner / foreground / 失败模式（永不回包、`PlatformCallException`、
/// `PlatformUnsupportedException`），记录 diagnose / scheduleUploadJob / cancelUploadJob / endBackgroundTask 调用，可注入事件。
class FakePlatform implements RetrieverPlatform {
  FakePlatform({FakeClock? clock, Transport? transport, this.rootPath})
    : clock = clock ?? FakeClock(),
      transport = transport ?? FakeTransport();

  @override
  final Clock clock;

  @override
  Transport transport;

  /// root（null = 由 Harness 设置）。
  String? rootPath;

  /// 进程级 token：一个「进程」一个；[newProcess] 换一个（模拟进程重启）。
  String token = Ids.newV4();

  bool? foreground = true;
  bool owner = true;
  String processName = 'main';
  int? available;
  CallMode rootMode = CallMode.ok;
  CallMode bootstrapMode = CallMode.ok;
  bool scheduleResult = true;

  final List<int> scheduledJobs = <int>[];
  final List<int> cancelledJobs = <int>[];
  final List<int> endedTasks = <int>[];
  final List<(String, String)> diagnoses = <(String, String)>[];
  int rootCalls = 0;
  int bootstrapCalls = 0;

  PlatformEventHandler? handler;

  Map<String, String> deviceFields = const {
    'os': 'android',
    'os_version': '15',
    'model': 'Google Pixel-test',
    'app_version': '1.2.3',
    'build': '45',
    'locale': 'zh-CN',
  };

  void newProcess() => token = Ids.newV4();

  Future<T> _mode<T>(CallMode m, T Function() ok) {
    switch (m) {
      case CallMode.ok:
        return Future<T>.value(ok());
      case CallMode.hang:
        return Completer<T>().future;
      case CallMode.fail:
        return Future<T>.error(const PlatformCallException('boom', 'fake failure'));
      case CallMode.unsupported:
        return Future<T>.error(const PlatformUnsupportedException('fake'));
    }
  }

  @override
  Future<RootInfo> root() {
    rootCalls++;
    return _mode(rootMode, () => RootInfo(root: rootPath!, token: token, process: processName, device: deviceFields));
  }

  /// 非 null：bootstrap 等它完成后再按 [bootstrapMode] 回包（让测试在 bootstrapping 窗口里调入口）。
  Completer<void>? bootstrapGate;

  /// root / bootstrap 以外的调用（diagnose、作业、后台任务、可用空间）的模式：ok / hang / fail / unsupported。
  CallMode otherMode = CallMode.ok;

  /// true：root / bootstrap 以外的调用同步抛（不是返回失败的 Future）。
  bool otherThrowSync = false;

  Future<T> _other<T>(T Function() ok) {
    if (otherThrowSync) throw const PlatformCallException('sync', 'fake sync throw');
    return _mode(otherMode, ok);
  }

  @override
  Future<BootstrapInfo> bootstrap() {
    bootstrapCalls++;
    final gate = bootstrapGate;
    if (gate != null) return gate.future.then((_) => _bootstrapNow());
    return _bootstrapNow();
  }

  Future<BootstrapInfo> _bootstrapNow() {
    return _mode(
      bootstrapMode,
      () => BootstrapInfo(
        owner: owner,
        root: rootPath!,
        token: token,
        process: processName,
        foreground: foreground,
        device: deviceFields,
      ),
    );
  }

  @override
  Future<void> diagnose(String code, String message) => _other(() => diagnoses.add((code, message)));

  @override
  Future<bool> scheduleUploadJob(int jobId) => _other(() {
    scheduledJobs.add(jobId);
    return scheduleResult;
  });

  @override
  Future<bool> cancelUploadJob(int jobId) => _other(() {
    cancelledJobs.add(jobId);
    return true;
  });

  @override
  Future<void> endBackgroundTask(int id) => _other(() => endedTasks.add(id));

  @override
  Future<int?> availableBytes() => _other(() => available);

  @override
  set eventHandler(PlatformEventHandler? h) => handler = h;
}

// ---------------------------------------------------------------- 测试生命周期

final List<Harness> _live = <Harness>[];
final List<StaticHarness> _staticLive = <StaticHarness>[];

/// 每个测试文件的 main() 开头调：开始前清空静态入口的进程内状态；结束时关掉实例、断言无内部异常。
void setUpRtv({bool expectInternalErrors = false}) {
  setUp(() async {
    await RetrieverRuntime.resetForTesting();
    LockRegistry.resetForTesting();
  });
  tearDown(() async {
    final errs = <Object>[for (final h in _live) ...h.errors, for (final h in _staticLive) ...h.errors];
    final all = List.of(_live);
    _live.clear();
    _staticLive.clear();
    await RetrieverRuntime.resetForTesting();
    for (final h in all) {
      await h.client.closeForTesting();
    }
    TestHooks.adoption = null;
    TestHooks.prepareGap = null;
    TestHooks.preWriteFault = null;
    Fs.writeAtomicFaultForTesting = null;
    Fs.appendFaultForTesting = null;
    LockRegistry.resetForTesting();
    cleanTemps();
    if (!expectInternalErrors && errs.isNotEmpty) fail('内部异常 ${errs.length} 个：${errs.first}');
  });
}

const String base = 'https://logs-test.invalid';
const String demoKey = 'lk_test_demo_abc_12345678';

// ---------------------------------------------------------------- Harness

/// 一个实例。默认经静态入口建（`Retriever.configure`，v3 §6「全部在静态入口层面」）；`direct: true` = 直接构造
/// （同一 root 上要同时活着两个实例时：多进程、活会话不恢复）。
class Harness {
  Harness._(this.root, this.key, this.clock, this.transport, this.platform, this.client, this.isStatic);

  final String root;
  final String key;
  final FakeClock clock;
  final FakeTransport transport;
  final FakePlatform platform;
  final RetrieverClient client;
  final bool isStatic;
  final List<Object> errors = <Object>[];

  static Future<Harness> create({
    String? root,
    String key = demoKey,
    RetrieverOptions options = const RetrieverOptions(),
    FakeClock? clock,
    FakeTransport? transport,
    FakePlatform? platform,
    bool? initialEnabled,
    String? initialUser,
    bool direct = false,
  }) async {
    final r = root ?? tempDir();
    final c = clock ?? FakeClock();
    final t = transport ?? FakeTransport();
    final p = platform ?? FakePlatform(clock: c, transport: t);
    p.transport = t;
    p.rootPath = r;
    p.newProcess();
    final errors = <Object>[];
    RetrieverClient client;
    var isStatic = false;
    if (!direct) {
      final prev = RetrieverRuntime.client;
      if (prev != null) await prev.closeForTesting();
      await RetrieverRuntime.resetForTesting(platformFactory: () => p);
      RetrieverRuntime.internalErrorSink = errors.add;
      if (initialUser != null) Retriever.setUser(initialUser);
      if (initialEnabled != null) Retriever.setEnabled(initialEnabled);
      await Retriever.configure(key, baseUrl: base, options: options);
      client = RetrieverRuntime.client!;
      isStatic = true;
    } else {
      client = RetrieverClient(
        root: r,
        key: key,
        baseUrl: base,
        options: options,
        platform: p,
        autoProcessName: p.processName,
        deviceFields: p.deviceFields,
        token: p.token,
        foreground: p.foreground,
      );
      client.onInternalError = errors.add;
      await client.prepare(initialEnabled: initialEnabled, initialUser: Text.sanitizeUserId(initialUser));
      client.attach(initialUser: Text.sanitizeUserId(initialUser), explicitEnabled: initialEnabled);
      client.start();
    }
    final h = Harness._(r, key, c, t, p, client, isStatic);
    h.errors.addAll(errors);
    if (isStatic) RetrieverRuntime.internalErrorSink = h.errors.add;
    client.onInternalError = h.errors.add;
    _live.add(h);
    return h;
  }

  Engine get engine => client.engine;

  String get outbox => '$root/outbox';

  Future<void> settle() => client.settle();

  /// 立即封当前段并处理（不走定时器）。
  Future<void> seal([SealReason reason = SealReason.timer]) async {
    client.writer.rotate(reason);
    await client.onWork(engine.processSeals);
    await settle();
  }

  /// 封当前段并按正常路径触发排空（封段是排空触发点之一）。
  Future<void> sealAndDrain([SealReason reason = SealReason.timer]) async {
    client.writer.rotate(reason);
    await client.onWork(client.afterSeal);
    await settle();
  }

  Future<void> tick([int advance = 0]) async {
    if (advance > 0) clock.advance(advance);
    await client.tickNow();
  }

  Future<void> enableUpload({String key = demoKey, RetrieverOptions options = const RetrieverOptions()}) async {
    client.reconfigure(key, base, options, client.processName);
    await settle();
  }

  Future<T> work<T>(FutureOr<T> Function(Engine e) body) => client.onWork(() => body(engine));

  List<String> outboxFiles([String? prefix]) {
    final names = Fs.listSync(outbox) ?? const <String>[];
    return names.where((n) => n.endsWith('.gz') && (prefix == null || n.startsWith(prefix))).toList()..sort();
  }

  List<Env> envelopes([String? prefix]) => [
    for (final n in outboxFiles(prefix))
      if (FileSystemEntity.isFileSync('$outbox/$n')) ?Env.ofGzip(n, File('$outbox/$n').readAsBytesSync()),
  ];

  List<Map<String, Object?>> readJsonl(String name) => readJsonlAt('$root/$name');

  Map<String, Object?> readJson(String path) =>
      JsonIn.obj(File(path).readAsBytesSync()) ?? (throw StateError('不是 JSON 对象：$path'));

  String sessionDir([RetrieverClient? c]) {
    final cc = c ?? client;
    return '$root/proc-${cc.processName}/${cc.writer.currentSessionId}';
  }

  void l(LogLevel level, String msg, {String? tag, Map<String, Object?>? attrs, Object? error, StackTrace? st}) {
    if (isStatic && identical(RetrieverRuntime.client, client)) {
      Retriever.log(level, msg, tag: tag, attrs: attrs, error: error, stackTrace: st);
    } else {
      client.log(level, msg, tag, attrs, error, st);
    }
  }

  void log(LogLevel level, String msg, {int count = 1, int pad = 0}) {
    for (var i = 0; i < count; i++) {
      l(level, (count > 1 ? '$msg $i' : msg) + 'p' * pad);
    }
  }

  void setUser(String? u) {
    if (isStatic && identical(RetrieverRuntime.client, client)) {
      Retriever.setUser(u);
    } else {
      client.setUser(u);
    }
  }

  void setEnabled(bool on) {
    if (isStatic && identical(RetrieverRuntime.client, client)) {
      Retriever.setEnabled(on);
    } else {
      client.setEnabled(on);
    }
  }

  Future<FlushResult> flushBlocking([bool includeContext = true]) =>
      (isStatic && identical(RetrieverRuntime.client, client)
              ? Retriever.flush(includeContext: includeContext)
              : client.flush(includeContext))
          .timeout(const Duration(seconds: 30));

  Future<BackoffState> get backoff => work((e) => e.backoff.copy());

  int get nowMono => clock.monoMs();

  /// root 同级的禁用标记（ADR 0020 决定 2）。
  String get disabledMarker => '$root.disabled';

  /// 堵住引擎队列直到放行（模拟引擎忙：冷启动恢复、大批物化等）。
  Future<Completer<void>> blockEngine() async {
    final gate = Completer<void>();
    final entered = Completer<void>();
    client.workAsync(() async {
      entered.complete();
      await gate.future.timeout(const Duration(seconds: 30), onTimeout: () {});
    });
    await entered.future.timeout(const Duration(seconds: 10));
    return gate;
  }

  Future<void> purgeBlocking() async {
    if (isStatic && identical(RetrieverRuntime.client, client)) {
      await Retriever.purgeLocal().timeout(const Duration(seconds: 30));
    } else {
      await client.purgeLocal().timeout(const Duration(seconds: 30));
    }
    await settle();
  }

  /// 模拟进程死亡（不封段、不收尾；放锁）。
  Future<void> simulateCrash() async {
    await client.simulateCrash();
    if (identical(RetrieverRuntime.client, client)) {
      await RetrieverRuntime.resetForTesting();
    }
  }
}

// ---------------------------------------------------------------- 静态入口夹具

/// 静态入口测试：把 [Retriever] 的平台换成临时目录 + 假时钟 + 假传输 + 假平台（`noRoot` = 模拟 root() 永不回包的进程）。
/// [restart] 模拟进程重启（实例不收尾地关掉、pre 文件放锁不删）。
class StaticHarness {
  StaticHarness._(this.root, this.clock, this.transport, this.platform);

  final String root;
  final FakeClock clock;
  final FakeTransport transport;
  final FakePlatform platform;
  final List<Object> errors = <Object>[];

  static Future<StaticHarness> create({
    String? root,
    FakeClock? clock,
    FakeTransport? transport,
    FakePlatform? platform,
    bool noRoot = false,
  }) async {
    final r = root ?? tempDir();
    final c = clock ?? FakeClock();
    final t = transport ?? FakeTransport();
    final p = platform ?? FakePlatform(clock: c, transport: t);
    p.transport = t;
    p.rootPath = r;
    p.newProcess();
    p.rootMode = noRoot ? CallMode.hang : CallMode.ok;
    await RetrieverRuntime.resetForTesting(platformFactory: () => p);
    final h = StaticHarness._(r, c, t, p);
    RetrieverRuntime.internalErrorSink = h.errors.add;
    _staticLive.add(h);
    // 首触：要 root（回包是异步的，等它到）
    RetrieverRuntime.touch();
    if (!noRoot) await h.waitRoot();
    return h;
  }

  /// 等 root() 回包（首触后）。
  Future<void> waitRoot() async {
    for (var i = 0; i < 1000 && RetrieverRuntime.root == null; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  RetrieverClient get client => RetrieverRuntime.client ?? (throw StateError('还没有实例'));

  Future<void> configure([String key = '', RetrieverOptions options = const RetrieverOptions()]) async {
    await Retriever.configure(key, baseUrl: base, options: options);
    RetrieverRuntime.client?.onInternalError = errors.add;
  }

  Future<void> settle() async => RetrieverRuntime.client?.settle();

  void log(LogLevel level, String msg, {Map<String, Object?>? attrs, Object? error, StackTrace? st}) {
    Retriever.log(level, msg, tag: 't', attrs: attrs, error: error, stackTrace: st);
  }

  /// 模拟进程重启：实例不收尾地停掉、静态状态清空（pre 文件放锁不删），之后用同一个 root、新的进程 token。
  Future<StaticHarness> restart({FakeTransport? transport}) async {
    await RetrieverRuntime.client?.simulateCrash();
    LockRegistry.resetForTesting();
    return StaticHarness.create(root: root, clock: clock, transport: transport ?? this.transport, platform: platform);
  }

  List<String> get preFiles {
    final names = Fs.listSync('$root/pre') ?? const <String>[];
    return (names.where((n) => n.endsWith('.jsonl')).map((n) => '$root/pre/$n').toList())..sort();
  }

  String get outbox => '$root/outbox';

  List<String> outboxFiles([String? prefix]) {
    final names = Fs.listSync(outbox) ?? const <String>[];
    return names.where((n) => n.endsWith('.gz') && (prefix == null || n.startsWith(prefix))).toList()..sort();
  }

  List<Env> envelopes([String? prefix]) => [
    for (final n in outboxFiles(prefix))
      if (FileSystemEntity.isFileSync('$outbox/$n')) ?Env.ofGzip(n, File('$outbox/$n').readAsBytesSync()),
  ];

  List<Map<String, Object?>> readJsonl(String name) => readJsonlAt('$root/$name');

  String currentSessionDir() => '$root/proc-${client.processName}/${client.writer.currentSessionId}';

  /// 本进程名下全部会话目录（含当前）。
  List<String> sessionDirs([String proc = 'main']) {
    final names = Fs.listSync('$root/proc-$proc') ?? const <String>[];
    return [
      for (final n in names)
        if (FileSystemEntity.isDirectorySync('$root/proc-$proc/$n')) '$root/proc-$proc/$n',
    ];
  }

  String get marker => '$root.disabled';
}

List<Map<String, Object?>> readJsonlAt(String path) {
  final f = File(path);
  if (!f.existsSync()) return const [];
  return [
    for (final l in f.readAsStringSync().split('\n'))
      if (l.isNotEmpty) ?JsonIn.objText(l),
  ];
}

// ---------------------------------------------------------------- 段读取

/// 一个会话目录里全部段的一行（按段号，跳过段头），附原始文本。
class SegLineRec {
  SegLineRec(this.map, this.raw);

  final Map<String, Object?> map;
  final String raw;

  Object? operator [](String k) => map[k];
}

List<String> _segNames(String dir) {
  final names = (Fs.listSync(dir) ?? const <String>[]).where((n) => n.startsWith('seg-')).toList();
  names.sort((a, b) {
    final c = int.parse(a.substring(4, 10)).compareTo(int.parse(b.substring(4, 10)));
    return c != 0 ? c : (a.endsWith('.open') ? 1 : 0).compareTo(b.endsWith('.open') ? 1 : 0);
  });
  return names;
}

List<SegLineRec> sessionLines(String dir) {
  final out = <SegLineRec>[];
  for (final n in _segNames(dir)) {
    final ls = File('$dir/$n').readAsStringSync().split('\n').where((l) => l.isNotEmpty).toList();
    for (var i = 1; i < ls.length; i++) {
      final o = JsonIn.objText(ls[i]);
      if (o != null) out.add(SegLineRec(o, ls[i]));
    }
  }
  return out;
}

List<Map<String, Object?>> segHeaders(String dir) => [
  for (final n in _segNames(dir)) ?JsonIn.objText(File('$dir/$n').readAsStringSync().split('\n').first),
];

List<String> readSegmentLines(String path) =>
    File(path).readAsStringSync().split('\n').where((l) => l.isNotEmpty).toList();

// ---------------------------------------------------------------- 跨语言校验

/// 跑 `npx --no-install tsx packages/core/scripts/validate-envelope.ts <files>`（cwd = 仓库根），把物化出的**原始信封字节**
/// 逐个交给服务端同一份 validateEnvelope。返回每个文件一行的结果对象。
Future<List<Map<String, Object?>>> runValidator(List<Env> envs) async {
  final dir = tempDir('rtv-validate');
  final paths = <String>[];
  for (var i = 0; i < envs.length; i++) {
    final f = File('$dir/env-$i.json')..writeAsBytesSync(envs[i].raw);
    paths.add(f.path);
  }
  final home = Platform.environment['HOME'] ?? '';
  final extra = <String>[
    if (Platform.environment['NVM_BIN'] != null) Platform.environment['NVM_BIN']!,
    '/opt/homebrew/bin',
    '/usr/local/bin',
    ...(() {
      try {
        return Directory('$home/.nvm/versions/node').listSync().map((e) => '${e.path}/bin');
      } catch (_) {
        return const <String>[];
      }
    })(),
  ];
  final env = Map<String, String>.of(Platform.environment);
  env['PATH'] = [...extra, env['PATH'] ?? '/usr/bin:/bin'].join(':');
  final r = await Process.run(
    'npx',
    ['--no-install', 'tsx', 'packages/core/scripts/validate-envelope.ts', ...paths],
    workingDirectory: Repo.root,
    environment: env,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  final text = r.stdout as String;
  final results = [
    for (final l in text.split('\n'))
      if (l.trim().isNotEmpty) ?JsonIn.objText(l),
  ];
  if (results.length != paths.length) fail('validator 输出不符：$text ${r.stderr}');
  return results;
}

void assertAllValid(List<Map<String, Object?>> results) {
  for (final r in results) {
    expect(r['ok'], true, reason: '$r');
  }
}

// ---------------------------------------------------------------- packages/core hostDerivedFields 的移植

const Set<String> _levels = {'debug', 'info', 'warn', 'error', 'fatal'};

/// `raw` 交给 clampConfig 时取宿主回落的宿主型字段（顺序固定；ADR 0022）。
List<String> hostDerivedFields(Object? raw) {
  final r = raw is Map ? raw : const {};
  return ['upload_level', 'local_level', 'local_cap_bytes', 'daily_batch_cap'].where((f) {
    final v = r[f];
    if (f == 'upload_level' || f == 'local_level') return !_levels.contains(v);
    return !((v is double && !v.isNaN && !v.isInfinite) || v is int);
  }).toList();
}

/// 测试里常用的等待：条件成立或超时（真实时间）。
Future<void> waitUntil(bool Function() cond, {int maxMs = 5000}) async {
  final sw = Stopwatch()..start();
  while (!cond() && sw.elapsedMilliseconds < maxMs) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// 让出若干拍事件循环（让 fire-and-forget 的任务跑完）。
Future<void> pump([int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 诊断 sink 的替换（测试用）。
void captureDiagnostics(List<(String, String)> into) {
  ConfigDiagnostics.sink = (code, message) => into.add((code, message));
}

// ---------------------------------------------------------------- 真杀进程（tool/kill_helper.dart）

/// 跑子进程 `dart tool/kill_helper.dart <args>`（它写完后自发 SIGKILL）。返回 (退出码, stdout)。
Future<(int, String)> runHelper(List<String> args) async {
  final p = await Process.start(Platform.resolvedExecutable, [
    'tool/kill_helper.dart',
    ...args,
  ], workingDirectory: Repo.package);
  final out = p.stdout.transform(utf8.decoder).join();
  p.stderr.drain<void>().ignore();
  final code = await p.exitCode.timeout(const Duration(seconds: 120));
  return (code, await out);
}

/// SIGKILL 的退出码（Dart 在 POSIX 上报负的信号号）。
const int sigkillExit = -9;

/// 启动一个子进程但不等它结束（--pre-hold）。
Future<Process> startHelper(List<String> args) =>
    Process.start(Platform.resolvedExecutable, ['tool/kill_helper.dart', ...args], workingDirectory: Repo.package);
