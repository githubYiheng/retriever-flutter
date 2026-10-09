// 插件的 Dart 入口（pubspec `dartPluginClass: RetrieverDartPlugin`，`dartFileName: src/plugin_entry.dart`；v3 §2、round2 #7）。
// 引擎在每个根 isolate 跑入口函数之前调 [RetrieverDartPlugin.registerWith]（主引擎、热重启后的新 isolate、后台引擎的回调入口），
// 此时 binding 还没初始化：这里**只注入工厂**——不发平台消息、不碰文件。工厂在首次触达时才建 [ChannelPlatform]，
// 非根 isolate（`RootIsolateToken.instance == null`）工厂抛 → facade 当「没有平台」→ 该 isolate unsupported（v3 §4）。
// 本文件不 import flutter（purity_test）：根 isolate 判定在 channel_platform.dart 里。
//
// `flutter test` 与 `Isolate.spawn` 出来的 isolate 不调 registerWith：前者 facade 先按 `FLUTTER_TEST` 判 unsupported，
// 后者没有根 isolate token，结果与注入后相同（都是 unsupported），见 REPORT-slice2「偏离」。

import 'channel_platform.dart';
import 'retriever.dart';

class RetrieverDartPlugin {
  RetrieverDartPlugin._();

  static void registerWith() {
    try {
      RetrieverRuntime.defaultPlatformFactory = ChannelPlatform.forCurrentIsolate;
    } catch (_) {
      // 绝不抛给宿主的 registrant
    }
  }
}
