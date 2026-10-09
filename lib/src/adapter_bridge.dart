// logger 适配器到引擎的桥（有 dart:io 的平台）。web 用 adapter_bridge_stub.dart。

import 'public_api.dart';
import 'retriever.dart';

void retrieverLogAt(
  int? ts,
  LogLevel level,
  String msg, {
  String? tag,
  Map<String, Object?>? attrs,
  Object? error,
  StackTrace? stackTrace,
}) => RetrieverRuntime.logAt(ts, level, msg, tag: tag, attrs: attrs, error: error, stackTrace: stackTrace);

LogLevel retrieverLocalLevel() => Retriever.localLevel;
