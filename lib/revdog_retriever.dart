/// Retriever（revdog）客户端日志传输层的 Flutter 插件：纯 Dart 引擎 + 极薄原生垫片。
///
/// 公开面三端同名：[Retriever] 静态入口与值类型。web 下整个引擎不被引用，全部入口 no-op（条件导入只看 `dart.library.io`）。
library;

export 'src/public_api.dart';
export 'src/retriever_stub.dart' if (dart.library.io) 'src/retriever.dart' show Retriever;
