// 传输（对位 Android `core/Platform.kt` 的 Transport / HttpUrlTransport；v3 §7 K5）：专用 `dart:io HttpClient`
// （不经宿主的 http 包 / 拦截器，避免把上传请求再记成日志，§3.3-6）。
//
// - 独立实例，用 `HttpOverrides` 基类的默认 `createHttpClient` 建：宿主设的 `HttpOverrides.global` 不作用于它；
// - `connectionTimeout` 30 s + 整体 30 s 超时（到时 abort）；不跟随重定向（服务端不回 3xx）；响应体最多读 64 KB（解压后的字节）；
// - 回包压缩（审计 #1）：`HttpClient` 每个请求都自动加 `Accept-Encoding: gzip`，Cloudflare 会把 ≥ 48 B 的 JSON 回包压成 gzip。
//   两手都做（同原生 SDK 透明解压的结果）：请求显式带 `Accept-Encoding: identity`（覆盖自动加的 gzip），且 `autoUncompress = true`
//   （中间盒无视 identity 仍压缩时由 Dart 解压）；
// - `cancelAll()` 中止在途请求（purge / 作业被停 / 后台到期）；
// - 一律直连（`findProxy` 显式设成 DIRECT）：`HttpClient` 不设 `findProxy` 时默认是 `HttpClient.findProxyFromEnvironment`，它读
//   `http_proxy` 等环境变量，**并且经 `HttpOverrides.current.findProxyFromEnvironment`** —— 宿主的 `HttpOverrides.global` 会从这里
//   漏进来（Dart 3.12.2 `_http/http_impl.dart` `_findProxy = HttpClient.findProxyFromEnvironment`；transport_test 实测）。
//   不走系统代理（dart:io 本来就不读系统代理设置；README 写明）。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'limits.dart';

class TransportRequest {
  const TransportRequest(this.method, this.url, this.headers, this.body);

  final String method;
  final String url;

  /// 插入序（请求头顺序与 Android 一致，便于对照）。
  final Map<String, String> headers;
  final Uint8List? body;
}

class TransportResponse {
  TransportResponse(this.status, [Map<String, String>? headers, Uint8List? body])
    : headers = headers ?? const <String, String>{},
      body = body ?? Uint8List(0);

  final int status;

  /// 键一律小写。
  final Map<String, String> headers;
  final Uint8List body;
}

abstract class Transport {
  /// 网络错误（超时、TLS、离线、被取消）返回 null。绝不抛。
  Future<TransportResponse?> send(TransportRequest request);

  /// 取消在途请求。
  void cancelAll();
}

class _PlainHttpOverrides extends HttpOverrides {}

class HttpClientTransport implements Transport {
  HttpClientTransport({int timeoutMs = ClientConstants.requestTimeoutMs})
    : _timeout = Duration(milliseconds: timeoutMs);

  final Duration _timeout;
  HttpClient? _client;
  final Set<HttpClientRequest> _inflight = <HttpClientRequest>{};
  int _epoch = 0;

  HttpClient get _http => _client ??= _create(_timeout);

  static String _direct(Uri _) => 'DIRECT';

  static HttpClient _create(Duration timeout) {
    // 不经 `HttpOverrides.current`（宿主的 `HttpOverrides.global`）：直接用基类的默认实现建（v3 §7 K5，第二轮核实）
    final c = _PlainHttpOverrides().createHttpClient(null);
    c.connectionTimeout = timeout;
    c.idleTimeout = const Duration(seconds: 15);
    c.autoUncompress = true;
    c.userAgent = null;
    c.findProxy = _direct;
    return c;
  }

  @override
  Future<TransportResponse?> send(TransportRequest request) async {
    final epoch = _epoch;
    HttpClientRequest? req;
    Future<TransportResponse?> run() async {
      final r = await _http.openUrl(request.method, Uri.parse(request.url));
      req = r;
      _inflight.add(r);
      if (epoch != _epoch) {
        r.abort();
        return null;
      }
      r.followRedirects = false;
      r.persistentConnection = true;
      request.headers.forEach((k, v) => r.headers.set(k, v, preserveHeaderCase: true));
      // 覆盖 HttpClient 自动加的 `Accept-Encoding: gzip`（见文件头）
      r.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final body = request.body;
      if (body != null) {
        r.contentLength = body.length;
        r.add(body);
      }
      final resp = await r.close();
      final headers = <String, String>{};
      resp.headers.forEach((name, values) {
        if (values.isNotEmpty) headers[name.toLowerCase()] = values.last;
      });
      final data = BytesBuilder(copy: false);
      // 回包是 gzip 时这里读到的已是解压后的字节：64 KB 上限按解压后算
      await for (final chunk in resp) {
        final room = ClientConstants.maxResponseBytes - data.length;
        if (room <= 0) break;
        data.add(chunk.length <= room ? chunk : chunk.sublist(0, room));
        if (data.length >= ClientConstants.maxResponseBytes) break;
      }
      return TransportResponse(resp.statusCode, headers, data.takeBytes());
    }

    try {
      return await run().timeout(
        _timeout,
        onTimeout: () {
          req?.abort();
          return null;
        },
      );
    } catch (_) {
      return null;
    } finally {
      final r = req;
      if (r != null) _inflight.remove(r);
    }
  }

  @override
  void cancelAll() {
    _epoch++;
    for (final r in _inflight.toList()) {
      try {
        r.abort();
      } catch (_) {}
    }
  }

  /// 测试 / 关停：关掉底层 HttpClient。
  void close() {
    cancelAll();
    try {
      _client?.close(force: true);
    } catch (_) {}
    _client = null;
  }
}
