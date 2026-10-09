// web / 没有 dart:io 的平台：全部入口 no-op、不抛（v2 §1；v3 §2 web 守卫）。公开签名与 retriever.dart 的 Retriever 一致。

import 'public_api.dart';

abstract final class Retriever {
  static const String defaultBaseUrl = 'https://logs.revdog.org';

  static Future<void> configure(
    String key, {
    String baseUrl = defaultBaseUrl,
    RetrieverOptions options = const RetrieverOptions(),
  }) => Future<void>.value();

  static void setUser(String? id) {}

  static void log(
    LogLevel level,
    String msg, {
    String? tag,
    Map<String, Object?>? attrs,
    Object? error,
    StackTrace? stackTrace,
  }) {}

  static Future<FlushResult> flush({bool includeContext = true}) =>
      Future<FlushResult>.value(FlushResult.pending('paused'));

  static LogLevel get uploadLevel => LogLevel.warn;

  static LogLevel get localLevel => LogLevel.debug;

  static void setEnabled(bool enabled) {}

  static bool get isEnabled => false;

  static Future<void> purgeLocal() => Future<void>.value();

  static String? get installId => null;

  static String? get supportCode => null;
}
