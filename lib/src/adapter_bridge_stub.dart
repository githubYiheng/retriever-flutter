// web：logger 适配器的桥全部 no-op。

import 'public_api.dart';

void retrieverLogAt(
  int? ts,
  LogLevel level,
  String msg, {
  String? tag,
  Map<String, Object?>? attrs,
  Object? error,
  StackTrace? stackTrace,
}) {}

LogLevel retrieverLocalLevel() => LogLevel.fatal;
