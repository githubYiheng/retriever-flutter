import Foundation
#if canImport(os)
import os
#endif

/// 配置诊断的系统日志出口（ADR 0025；v3 §1 §13）：与 sdk/ios 同款——`os.Logger(subsystem: "org.revdog.retriever",
/// category: "diagnostics")`，`no_key` 用 `.info`、其余（含 Flutter 专有的 `configure_ignored`）`.notice`，消息 `.public`。
/// 进程级按 (code, message) 去重（Dart 侧只在 isolate 内去重）。出口抛任何东西都吞掉。
final class Diagnostics {
    static let subsystem = "org.revdog.retriever"
    static let category = "diagnostics"
    static let noKey = "no_key"

    typealias Sink = (_ info: Bool, _ message: String) -> Void

    static let shared = Diagnostics(sink: Diagnostics.system)

    private let lock = NSLock()
    private var seen: Set<String> = []
    private let sink: Sink

    init(sink: @escaping Sink) {
        self.sink = sink
    }

    /// 返回这次是否真的出了（去重后）。
    @discardableResult
    func emit(code: String, message: String) -> Bool {
        lock.lock()
        let first = seen.insert(code + "\u{0}" + message).inserted
        lock.unlock()
        guard first else { return false }
        sink(code == Diagnostics.noKey, message)
        return true
    }

    private static func system(_ info: Bool, _ message: String) {
        #if canImport(os)
        let log = Logger(subsystem: subsystem, category: category)
        if info {
            log.info("\(message, privacy: .public)")
        } else {
            log.notice("\(message, privacy: .public)")
        }
        #endif
    }
}
