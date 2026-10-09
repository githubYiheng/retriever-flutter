import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// tracker 的出口（EngineRegistry）。
protocol ForegroundListener: AnyObject {
    func trackerDidEnterBackground()
    func trackerWillEnterForeground()
    func trackerForegroundStateChanged(_ fg: Bool)
}

enum ForegroundNote: Equatable {
    case didEnterBackground, willEnterForeground, didBecomeActive, willResignActive
}

/// tracker 的平台边界（可注入；单测用假实现驱动状态机）。
protocol ForegroundSource: AnyObject {
    /// 有前后台概念（app 扩展里没有 UIApplication → 不装，状态恒为 nil）。
    var available: Bool { get }
    var isMainThread: Bool { get }
    /// 主线程上调：`applicationState != .background`（拿不到 UIApplication = nil）。
    func readForeground() -> Bool?
    func onMain(_ f: @escaping () -> Void)
    /// 开始把通知送给 handler（主线程）。
    func observe(_ handler: @escaping (ForegroundNote) -> Void)
}

/// 进程级前后台 tracker（对位 sdk/ios `Platform.swift` 的 ForegroundTracker；v3 §1.4；切片 2 简报 §3）。首次 `register(with:)` 时装，
/// 只用 NotificationCenter：`UIApplication` 与 `UIScene` 两套 didEnterBackground / willEnterForeground / didBecomeActive /
/// willResignActive（**不用 `addSceneDelegate`**：3.38 才有，与 3.32 门禁冲突）。状态变了才出事件（两套通知同一次切换只出一次）：
/// - didEnterBackground：主线程重读 `applicationState`，确实是 background（多 scene 时还有前台 scene 就不算）→ 出 `didEnterBackground`；
/// - willEnterForeground：通知发出时 `applicationState` **还是** background（Apple：「Posted shortly before an app leaves the
///   background state」），重读判不出来——以通知本身为准置前台 → 出 `willEnterForeground`（见 REPORT-slice2「偏离」）；
/// - didBecomeActive / willResignActive：主线程重读，变了只出 `foregroundStateChanged(fg)`（只改 last_state）。
/// 初值在主线程上读（scene 应用注册时是 background、sceneless 用户启动时是 inactive = 前台，核实 refresh §5）。
final class ForegroundTracker {
    static let shared = ForegroundTracker(source: ForegroundTracker.systemSource())

    private let source: ForegroundSource
    private let lock = NSLock()
    private var installed = false
    private var current: Bool?
    weak var listener: ForegroundListener?

    init(source: ForegroundSource) {
        self.source = source
    }

    var state: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return installed
    }

    /// 进程级只装一次；返回这次是否真的装了。
    @discardableResult
    func install() -> Bool {
        lock.lock()
        if installed {
            lock.unlock()
            return false
        }
        installed = true
        lock.unlock()
        guard source.available else { return true }
        source.observe { [weak self] note in self?.handle(note) }
        if source.isMainThread {
            resync(emit: false)
        } else {
            source.onMain { [weak self] in self?.resync(emit: false) }
        }
        return true
    }

    func handle(_ note: ForegroundNote) {
        switch note {
        case .didEnterBackground:
            // 多 scene：某个 scene 进后台但 app 还有前台 scene → 重读不是 background，不算
            if source.readForeground() == true { return }
            if set(false) { listener?.trackerDidEnterBackground() }
        case .willEnterForeground:
            if set(true) { listener?.trackerWillEnterForeground() }
        case .didBecomeActive, .willResignActive:
            resync(emit: true)
        }
    }

    /// 主线程：重读真实状态（读不到保持原值）。
    private func resync(emit: Bool) {
        guard let fg = source.readForeground() else { return }
        if set(fg), emit { listener?.trackerForegroundStateChanged(fg) }
    }

    /// 设状态；变了（含 unknown → 已知）返回 true。
    private func set(_ fg: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = current != fg
        current = fg
        return changed
    }

    static func systemSource() -> ForegroundSource {
        #if canImport(UIKit)
        return UIKitForegroundSource()
        #else
        return NoForegroundSource()
        #endif
    }
}

/// 没有前后台概念（非 UIKit）。
final class NoForegroundSource: ForegroundSource {
    var available: Bool { false }
    var isMainThread: Bool { Thread.isMainThread }
    func readForeground() -> Bool? { nil }
    func onMain(_ f: @escaping () -> Void) {}
    func observe(_ handler: @escaping (ForegroundNote) -> Void) {}
}

#if canImport(UIKit)
final class UIKitForegroundSource: ForegroundSource {
    private var observers: [NSObjectProtocol] = []

    var available: Bool { !Bundle.main.bundlePath.hasSuffix(".appex") }
    var isMainThread: Bool { Thread.isMainThread }

    func readForeground() -> Bool? { PlatformInfo.readForeground() }

    func onMain(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }

    func observe(_ handler: @escaping (ForegroundNote) -> Void) {
        let nc = NotificationCenter.default
        // UIApplication 级通知在 scene 应用里照发（Apple 原文，核实 refresh §5）；UIScene 级是单个 scene 的——两套都只当触发器
        let pairs: [(Notification.Name, ForegroundNote)] = [
            (UIApplication.didEnterBackgroundNotification, .didEnterBackground),
            (UIApplication.willEnterForegroundNotification, .willEnterForeground),
            (UIApplication.didBecomeActiveNotification, .didBecomeActive),
            (UIApplication.willResignActiveNotification, .willResignActive),
            (UIScene.didEnterBackgroundNotification, .didEnterBackground),
            (UIScene.willEnterForegroundNotification, .willEnterForeground),
            (UIScene.didActivateNotification, .didBecomeActive),
            (UIScene.willDeactivateNotification, .willResignActive),
        ]
        for (name, note) in pairs {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in handler(note) })
        }
    }
}
#endif
