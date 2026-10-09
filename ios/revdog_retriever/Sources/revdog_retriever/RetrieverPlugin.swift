import Flutter
import Foundation
import UIKit

/// Retriever 的 iOS 垫片（v3 §3 契约；切片 2 简报 §3）。每个引擎一个实例（`register(with:)` 每引擎调一次），都登记到进程级
/// `EngineRegistry`；`registrar.publish(self)` 才能在引擎 dealloc 时收到 `detachFromEngine(for:)`（核实 round2 #2）。
/// 垫片不读不写日志文件、不碰 key（ADR 0003 决定 3 / ADR 0007 D5）。
///
/// MethodChannel `org.revdog.retriever`：Dart → 原生 `root` / `bootstrap` / `diagnose` / `scheduleUploadJob` / `cancelUploadJob` /
/// `endBackgroundTask` / `availableBytes`；原生 → Dart 走同一 channel 的反向 invokeMethod（见 `EngineRegistry`）。参数一律以契约参数名
/// 为键的字典。发送前判引擎状态（见 `send`）。
public final class RetrieverPlugin: NSObject, FlutterPlugin, EngineHandle {
    static let channelName = "org.revdog.retriever"

    private let channel: FlutterMethodChannel
    private weak var engine: FlutterEngine?
    private let engineResolved: Bool

    init(channel: FlutterMethodChannel, engine: FlutterEngine?) {
        self.channel = channel
        self.engine = engine
        engineResolved = engine != nil
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
        let instance = RetrieverPlugin(channel: channel, engine: resolveEngine(registrar))
        registrar.addMethodCallDelegate(instance, channel: channel)
        // 不 publish 就永远收不到 detachFromEngine(for:)（核实 round2 #2）
        registrar.publish(instance)
        EngineRegistry.shared.attach(instance)
        ForegroundTracker.shared.listener = EngineRegistry.shared
        ForegroundTracker.shared.install()
    }

    /// 只在引擎 dealloc 时调（`destroyContext` 不调）：注销；是 owner → 释放并向其余引擎广播 `ownerReleased`。
    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        channel.setMethodCallHandler(nil)
        EngineRegistry.shared.detach(self)
    }

    /// 插件 API 不直接给引擎对象（`registrar.messenger()` 是 `FlutterBinaryMessengerRelay`，不是引擎）。按序取：
    /// ① registrar 的 `flutterEngine` 属性（3.32.8 / 3.41.4 / 3.44.4 的 `FlutterEngine.mm` 里都是 weak 属性；先 `responds(to:)` 守着）；
    /// ② 公开的 `registrar.viewController?.engine`（有 VC 的引擎）；③ 都拿不到 → nil（`EngineState.unknown`：快照为 nil，只靠 detach 释放）。
    static func resolveEngine(_ registrar: FlutterPluginRegistrar) -> FlutterEngine? {
        if let obj = registrar as? NSObject {
            let sel = Selector(("flutterEngine"))
            if obj.responds(to: sel), let e = obj.perform(sel)?.takeUnretainedValue() as? FlutterEngine {
                return e
            }
        }
        return (registrar.viewController as? FlutterViewController)?.engine
    }

    // MARK: EngineHandle

    var engineState: EngineState {
        guard engineResolved else { return .unknown }
        guard let e = engine else { return .gone }
        guard let id = e.isolateId else { return .noIsolate }
        return .running(id)
    }

    /// 往 `destroyContext` 之后的引擎发消息会解引用已 reset 的 shell（3.44.4 `FlutterEngine.mm:1311–1329`）：拿得到引擎时只在
    /// `isolateId != nil` 时发；拿不到引擎（`.unknown`）照发。
    func send(_ method: String, _ arguments: Any?) {
        if engineResolved {
            guard let e = engine, e.isolateId != nil else { return }
        }
        channel.invokeMethod(method, arguments: arguments)
    }

    // MARK: Dart → 原生

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "root":
            result(rootReply())
        case "bootstrap":
            let owner = EngineRegistry.shared.claim(self)
            var m = rootReply()
            m["owner"] = owner
            m["foreground"] = PlatformInfo.readForeground().map { $0 as Any } ?? NSNull()
            result(m)
        case "diagnose":
            let args = call.arguments as? [String: Any]
            if let code = args?["code"] as? String, let message = args?["message"] as? String {
                Diagnostics.shared.emit(code: code, message: message)
            }
            result(nil)
        case "scheduleUploadJob", "cancelUploadJob":
            // iOS 没有对应的后台作业（后台任务在进后台时原生同步 begin）
            result(false)
        case "endBackgroundTask":
            if let id = RetrieverPlugin.intArg(call.arguments, "id") {
                EngineRegistry.shared.tasks.end(id)
            }
            result(nil)
        case "availableBytes":
            DispatchQueue.global(qos: .utility).async {
                let v = PlatformInfo.availableBytes()
                DispatchQueue.main.async {
                    result(v.map { NSNumber(value: $0) })
                }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func rootReply() -> [String: Any] {
        [
            "root": PlatformInfo.ensureRoot(),
            "token": PlatformInfo.token,
            "process": "main",
            "device": PlatformInfo.deviceFields(),
        ]
    }

    static func intArg(_ arguments: Any?, _ key: String) -> Int? {
        let v = (arguments as? [String: Any])?[key] ?? arguments
        if let n = v as? NSNumber { return n.intValue }
        return v as? Int
    }
}
