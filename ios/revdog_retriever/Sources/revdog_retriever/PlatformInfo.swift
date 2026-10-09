import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 进程 / 设备事实（对位 sdk/ios：`Client.defaultRoot`、`FS.markFile`、`SystemPlatform.deviceFields`、`FS.availableBytes`、
/// 扩展安全的 `sharedApplication`）。垫片不读不写日志文件、不碰 key（ADR 0003 决定 3 / ADR 0007 D5）：root 只建目录、设属性。
enum PlatformInfo {
    /// 进程级静态 token（同进程每个引擎拿到同一个；小写 UUID——Dart 侧按小写 UUID 校验）。
    static let token = UUID().uuidString.lowercased()

    /// `Library/Application Support/<bundle-id>.retriever/`（同 sdk/ios，无 App Group）。
    static func rootURL() -> URL {
        let bundle = Bundle.main.bundleIdentifier ?? "retriever"
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("\(bundle).retriever", isDirectory: true)
    }

    /// 建 root 目录并（每次）重设 `isExcludedFromBackup` + `completeUntilFirstUserAuthentication`；任何一步失败照样返回路径。
    static func ensureRoot() -> String {
        let url = rootURL()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var u = url
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        return url.path
    }

    /// 设备字段（不含 sdk；同 sdk/ios `SystemPlatform.deviceFields()`）。
    static func deviceFields() -> [String: String] {
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafeBytes(of: &sys.machine) { raw -> String in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[0..<n], as: UTF8.self)
        }
        var model = machine
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { model = sim }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = v.patchVersion > 0
            ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "os": "ios",
            "os_version": osVersion,
            "model": model,
            "app_version": info["CFBundleShortVersionString"] as? String ?? "",
            "build": info["CFBundleVersion"] as? String ?? "",
            "locale": Locale.current.identifier,
        ]
    }

    /// 可用空间（`volumeAvailableCapacityForImportantUsage`，回落 `volumeAvailableCapacity`；隐私清单 DiskSpace E174.1）。
    /// 后台队列上调。拿不到 = nil。
    static func availableBytes() -> Int64? {
        var url = rootURL()
        if !FileManager.default.fileExists(atPath: url.path) { url = url.deletingLastPathComponent() }
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let c = v.volumeAvailableCapacityForImportantUsage {
            return c
        }
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]), let c = v.volumeAvailableCapacity {
            return Int64(c)
        }
        return nil
    }

    #if canImport(UIKit)
    /// 扩展安全地取 UIApplication.shared（扩展里不可用 → nil；同 sdk/ios 的 selector 写法）。
    static func sharedApplication() -> UIApplication? {
        if Bundle.main.bundlePath.hasSuffix(".appex") { return nil }
        let sel = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: sel) else { return nil }
        return UIApplication.perform(sel)?.takeUnretainedValue() as? UIApplication
    }
    #endif

    /// 主线程现读 `applicationState != .background`（拿不到 = nil）。
    static func readForeground() -> Bool? {
        #if canImport(UIKit)
        return onMainSync {
            guard let app = sharedApplication() else { return nil }
            return app.applicationState != .background
        }
        #else
        return nil
        #endif
    }

    /// 在主线程上同步执行（已在主线程 = 直接执行）。
    static func onMainSync<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { body() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }
}
