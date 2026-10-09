import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    ExampleChannel.noteLaunch(ProcessInfo.processInfo.arguments)
    if ExampleChannel.launchScenario == "second_engine_bg_first" {
      // 「后台先」（v3 盲审 H4-2 / E2）：主引擎之前先起第二引擎并 configure
      ExampleChannel.startSecondEngine()
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    ExampleChannel.installMain(messenger: engineBridge.applicationRegistrar.messenger())
  }
}

/// 示例自己的原生通道 `org.revdog.retriever.example`（不进生产垫片）：启动参数、第二引擎（后到 / 后台先）、换根 VC 到新引擎（销毁重建）。
enum ExampleChannel {
  static let name = "org.revdog.retriever.example"
  static var launchScenario: String?
  static var secondEngine: FlutterEngine?
  static var secondReport: [String: Any]?
  static var rebuiltEngines: [FlutterEngine] = []
  static var channels: [FlutterMethodChannel] = []

  static func log(_ s: String) { NSLog("RTVEX %@", s) }

  /// `--scenario <name>`（`xcrun simctl launch … --scenario error`）。
  static var holdOverride: Int?

  static func noteLaunch(_ args: [String]) {
    if let i = args.firstIndex(of: "--scenario"), i + 1 < args.count { launchScenario = args[i + 1] }
    if let i = args.firstIndex(of: "--hold"), i + 1 < args.count { holdOverride = Int(args[i + 1]) }
    log("didFinishLaunching pid=\(getpid()) scenario=\(launchScenario ?? "-")")
  }

  static func installMain(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    ch.setMethodCallHandler { call, result in
      switch call.method {
      case "launchScenario":
        let s = launchScenario
        launchScenario = nil
        result(s)
      case "startSecondEngine":
        startSecondEngine()
        result(nil)
      case "destroySecondEngine":
        destroySecondEngine()
        result(nil)
      case "secondEngineStatus":
        result(secondReport)
      case "rebuildMainEngine":
        // 启动参数 `--hold <ms>` 覆盖（验收时扫竞争窗口用）
        let holdMs = holdOverride ?? (call.arguments as? [String: Any])?["holdOldMs"] as? Int ?? 0
        result(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { rebuildMainEngine(holdOldMs: holdMs) }
      case "sigkill":
        log("sigkill pid=\(getpid())")
        kill(getpid(), SIGKILL)
        result(nil)
      case "armAtLaunch":
        // iOS：冷启动场景用启动参数（`--scenario <name>`）
        result(false)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channels.append(ch)
  }

  static func startSecondEngine() {
    guard secondEngine == nil else { return }
    secondReport = nil
    let e = FlutterEngine(name: "rtv-second", project: nil, allowHeadlessExecution: true)
    e.run(withEntrypoint: "secondEngineMain")
    GeneratedPluginRegistrant.register(with: e)
    let ch = FlutterMethodChannel(name: name, binaryMessenger: e.binaryMessenger)
    ch.setMethodCallHandler { call, result in
      switch call.method {
      case "secondEngineReport":
        secondReport = call.arguments as? [String: Any]
        log("second engine report \(secondReport ?? [:])")
        result(nil)
      case "launchScenario":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channels.append(ch)
    secondEngine = e
    log("second engine started pid=\(getpid())")
  }

  /// destroyContext（关 isolate，不调 detach）+ 放掉引用（dealloc → 插件 detachFromEngine(for:)）。
  static func destroySecondEngine() {
    guard let e = secondEngine else { return }
    secondEngine = nil
    e.destroyContext()
    log("second engine destroyContext done")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak e] in
      log("second engine deallocated=\(e == nil)")
    }
  }

  /// 销毁重建（v3 盲审 H4-3 / E1）：根 VC 换成新引擎的 FlutterViewController；旧 VC 释放 → 旧引擎 destroyContext / dealloc。
  /// `holdOldMs` > 0：旧 VC 多留这么久再释放（强制「新引擎先 bootstrap、旧引擎后 detach」的次序，验 ownerReleased 接任）。
  static func rebuildMainEngine(holdOldMs: Int = 0) {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let window = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) ?? scenes.first?.windows.first else {
      log("rebuild: no window")
      return
    }
    var oldVC: UIViewController? = window.rootViewController
    let oldEngine = (oldVC as? FlutterViewController)?.engine
    let e = FlutterEngine(name: "rtv-rebuilt-\(rebuiltEngines.count + 1)")
    e.run()
    GeneratedPluginRegistrant.register(with: e)
    installMain(messenger: e.binaryMessenger)
    rebuiltEngines.append(e)
    window.rootViewController = FlutterViewController(engine: e, nibName: nil, bundle: nil)
    log("rebuild: root VC replaced with a new engine pid=\(getpid()) holdOldMs=\(holdOldMs)")
    if holdOldMs > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(holdOldMs)) {
        log("rebuild: releasing old VC")
        oldVC = nil
      }
    } else {
      oldVC = nil
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak oldEngine] in
      log("rebuild: old engine deallocated=\(oldEngine == nil) isolateId=\(oldEngine?.isolateId ?? "nil")")
    }
  }
}
