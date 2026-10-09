// 对位 Android HttpUrlTransport 的行为（v3 §7 K5）：真实的 `HttpClientTransport` 对本地假服务端（HttpServer）——请求头与 gzip 体、
// 不跟随重定向、响应体 64 KB 上限、cancelAll 中止在途请求、整体超时、网络错误一律 null；不经宿主的 `HttpOverrides.global`
// （也就不吃宿主配的代理）。最后一条经静态入口端到端：flush → stored。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:revdog_retriever/src/gzip.dart';
import 'package:revdog_retriever/src/json.dart';
import 'package:revdog_retriever/src/transport.dart';
import 'package:test/test.dart';

import 'support/support.dart';

/// 宿主的全局 HttpOverrides：建出来的 HttpClient 一律走一个不存在的代理（若 SDK 用了它，请求必失败），并记次数。
class _HostOverrides extends HttpOverrides {
  int created = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    created++;
    final c = super.createHttpClient(context);
    c.findProxy = (_) => 'PROXY 127.0.0.1:9';
    return c;
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) => 'PROXY 127.0.0.1:9';
}

TransportRequest post(String url, List<int> body, [Map<String, String>? headers]) => TransportRequest(
  'POST',
  url,
  headers ?? {'Content-Type': 'application/json', 'Content-Encoding': 'gzip'},
  Uint8List.fromList(body),
);

void main() {
  setUpRtv();

  late FakeServer server;
  late HttpClientTransport t;

  setUp(() async {
    server = await FakeServer.start();
    t = HttpClientTransport();
  });

  tearDown(() async {
    t.close();
    await server.close();
    HttpOverrides.global = null;
  });

  test('sendsHeadersAndBodyVerbatim', () async {
    final body = Gzip.compress(Uint8List.fromList('{"batch_id":"b-1"}'.codeUnits))!;
    final r = await t.send(
      post('${server.base}/v1/batches', body, {
        'Authorization': 'Bearer $demoKey',
        'Content-Type': 'application/json',
        'Content-Encoding': 'gzip',
        'X-Rtv-Install': 'iid',
        'X-Rtv-Sdk': 'retriever-flutter/0.1.0',
      }),
    );
    expect(r, isNotNull);
    final req = server.requests.single;
    expect(req.method, 'POST');
    expect(req.body, body, reason: '字节原样（不二次压缩、不解压）');
    expect(req.headers['Authorization'], 'Bearer $demoKey');
    expect(req.headers['Content-Encoding'], 'gzip');
    expect(req.headers['X-Rtv-Sdk'], 'retriever-flutter/0.1.0');
    expect(req.headers['content-length'], '${body.length}');
    expect(req.headers.containsKey('user-agent'), isFalse, reason: '不带 dart:io 默认 UA');
    // 响应：状态码、小写键的响应头、体
    expect(r!.status, 200);
    expect(r.headers.keys.every((k) => k == k.toLowerCase()), isTrue);
  });

  test('doesNotFollowRedirects', () async {
    server.defaultReply = Reply.status(302, null, {'Location': '${server.base}/elsewhere'});
    final r = await t.send(post('${server.base}/v1/batches', [1]));
    expect(r!.status, 302);
    expect(server.requests.length, 1);
  });

  test('responseBodyCappedAt64KB', () async {
    server.defaultReply = Reply.raw(200, List<int>.filled(200 * 1024, 0x61));
    final r = await t.send(post('${server.base}/v1/batches', [1]));
    expect(r!.status, 200);
    expect(r.body.length, 64 * 1024);
  });

  test('networkErrorsAreNull', () async {
    server.defaultReply = Reply.network; // 服务端直接断开
    expect(await t.send(post('${server.base}/v1/batches', [1])), isNull);
    // 端口没人听
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    expect(await t.send(post('http://127.0.0.1:$port/v1/batches', [1])), isNull);
    // 非法 URL
    expect(await t.send(post('not a url', [1])), isNull);
  });

  test('cancelAllAbortsInFlight', () async {
    server.delay = const Duration(seconds: 20);
    final sw = Stopwatch()..start();
    final f = t.send(post('${server.base}/v1/batches', [1]));
    await Future<void>.delayed(const Duration(milliseconds: 300)); // 请求已发出、服务端在拖
    t.cancelAll();
    expect(await f.timeout(const Duration(seconds: 3)), isNull);
    expect(sw.elapsedMilliseconds, lessThan(5000));
    // 取消之后的新请求照常
    server.delay = Duration.zero;
    expect((await t.send(post('${server.base}/v1/batches', [1])))!.status, 200);
  });

  test('overallTimeoutAborts', () async {
    final quick = HttpClientTransport(timeoutMs: 300);
    server.delay = const Duration(seconds: 5);
    final sw = Stopwatch()..start();
    expect(await quick.send(post('${server.base}/v1/batches', [1])), isNull);
    expect(sw.elapsedMilliseconds, lessThan(2000));
    quick.close();
  });

  /// 宿主设了 `HttpOverrides.global`（拦截器 / 代理 / 证书钉扎）：SDK 的 HttpClient 不经它建；代理查找也不经它
  /// （`findProxy` 默认值会经 `HttpOverrides.current.findProxyFromEnvironment`，所以 SDK 显式设 DIRECT）。
  test('ignoresHostHttpOverridesGlobal', () async {
    final host = _HostOverrides();
    HttpOverrides.global = host;
    // 宿主自己的 HttpClient 确实走那个坏代理
    final hostClient = HttpClient();
    expect(host.created, 1);
    hostClient.close(force: true);
    final fresh = HttpClientTransport();
    final r = await fresh.send(post('${server.base}/v1/batches', [1]));
    expect(r?.status, 200, reason: '直连成功 = 没用宿主的 overrides');
    expect(host.created, 1);
    fresh.close();
  });

  /// 端到端（静态入口 + 真实传输）：warn 行 → flush → stored；服务端收到的批能解出信封，X-Rtv-Install == 信封 install_id。
  test('endToEndFlushStoredOverRealHttp', () async {
    final p = FakePlatform()..rootPath = tempDir();
    final real = HttpClientTransport();
    p.transport = real;
    await RetrieverRuntime.resetForTesting(platformFactory: () => p);
    await Retriever.configure(demoKey, baseUrl: server.base);
    Retriever.log(LogLevel.warn, 'over the wire', tag: 'net');
    final res = await Retriever.flush().timeout(const Duration(seconds: 20));
    expect(res, FlushResult.stored);
    final batch = server.batchRequests.single;
    final env = FakeTransport.envOf(batch.body)!;
    expect(env.lines.map((l) => l['msg']), contains('over the wire'));
    expect(batch.headers['X-Rtv-Install'], env['install_id']);
    expect(batch.headers['Authorization'], 'Bearer $demoKey');
    expect(server.configRequests.length, 1);
    real.close();
  });

  // ---- 审计 #1（🔴）：回包被自动 gzip。请求显式带 `Accept-Encoding: identity`，且 `autoUncompress = true`（中间盒仍压缩时 Dart 解压）；
  // 64 KB 上限按解压后的字节算。

  /// 模拟 Cloudflare（请求允许 gzip 且体 ≥ 48 B 就压缩）：SDK 请求声明 identity → 回包不压缩，回显照常解析。
  test('requestsIdentityEncodingSoEdgeDoesNotCompress', () async {
    server.gzipReplies = ReplyGzip.whenAccepted;
    final body = Gzip.compress(Uint8List.fromList('{"batch_id":"b-1"}'.codeUnits))!;
    final r = await t.send(post('${server.base}/v1/batches', body));
    expect(server.requests.single.headers['accept-encoding'], 'identity');
    expect(server.gzippedReplies, 0);
    expect(r!.status, 200);
    final echo = JsonIn.obj(r.body)!;
    expect(echo['batch_id'], 'b-1');
    expect(echo['status'], 'stored');
  });

  /// 中间盒无视 identity 仍回 gzip：Dart 透明解压，拿到的是 JSON；64 KB 上限按解压后的字节算。
  test('gzipReplyDespiteIdentityIsDecompressed', () async {
    server.gzipReplies = ReplyGzip.always;
    final body = Gzip.compress(Uint8List.fromList('{"batch_id":"b-2"}'.codeUnits))!;
    final r = await t.send(post('${server.base}/v1/batches', body));
    expect(server.gzippedReplies, 1);
    expect(r!.status, 200);
    expect(JsonIn.obj(r.body)!['batch_id'], 'b-2');
    // 200 KB 的 'a' 压成很小的 gzip：读出的是解压后的前 64 KB
    server.defaultReply = Reply.raw(200, List<int>.filled(200 * 1024, 0x61));
    final big = await t.send(post('${server.base}/v1/batches', [1]));
    expect(server.gzippedReplies, 2);
    expect(big!.body.length, 64 * 1024);
    expect(big.body.every((b) => b == 0x61), isTrue);
  });

  /// 端到端（静态入口 + 真实传输）：服务端按 Cloudflare 规则压缩时，2xx 回显校验通过（flush → stored）、远程配置生效。
  for (final mode in [ReplyGzip.whenAccepted, ReplyGzip.always]) {
    test('endToEndWithCompressingServer_${mode.name}', () async {
      server.gzipReplies = mode;
      server.configBody = {'etag': 'e-gz', 'ttl_s': 600, 'upload_level': 'info'};
      final p = FakePlatform()..rootPath = tempDir();
      final real = HttpClientTransport();
      p.transport = real;
      await RetrieverRuntime.resetForTesting(platformFactory: () => p);
      final errors = <Object>[];
      RetrieverRuntime.internalErrorSink = errors.add;
      await Retriever.configure(demoKey, baseUrl: server.base);
      await RetrieverRuntime.client!.settle();
      expect(Retriever.uploadLevel, LogLevel.info, reason: '配置回包解析成功并生效');
      Retriever.log(LogLevel.info, 'compressed edge');
      final res = await Retriever.flush().timeout(const Duration(seconds: 20));
      expect(res, FlushResult.stored, reason: '2xx 回显校验通过');
      expect(server.batchRequests.every((r) => r.headers['accept-encoding'] == 'identity'), isTrue);
      expect(server.configRequests.every((r) => r.headers['accept-encoding'] == 'identity'), isTrue);
      if (mode == ReplyGzip.always) expect(server.gzippedReplies, greaterThanOrEqualTo(2));
      if (mode == ReplyGzip.whenAccepted) expect(server.gzippedReplies, 0);
      expect(errors, isEmpty);
      real.close();
    });
  }
}
