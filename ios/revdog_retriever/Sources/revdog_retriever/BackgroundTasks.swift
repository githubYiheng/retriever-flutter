import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 后台任务记账（v3 §3；切片 2 简报 §3）：进后台时原生同步 begin（Dart 回调来不及，3.29 起 Dart 与主线程合一），id 交给 owner；
/// - `end(id)` 幂等：只 end 记账里还在的（Dart 排空结束、实例建成前到达等多路都可能来 end）；
/// - 过期 handler 内**原生先 end**，再通知 owner `backgroundTaskExpired(id)`（Dart 只取消在途请求）；
/// - owner 释放时它名下的任务一并 end。
/// UIKit 调用经可注入的 begin / end（单测用假实现）。只在主线程上用。
final class BackgroundTasks {
    typealias Begin = (_ name: String, _ onExpire: @escaping () -> Void) -> Int?
    typealias End = (_ id: Int) -> Void
    typealias Expired = (_ id: Int, _ owner: EngineHandle) -> Void

    private struct Entry {
        weak var owner: EngineHandle?
        let onExpired: Expired
    }

    private final class Box {
        var id: Int?
        var expiredEarly = false
    }

    static let taskName = "org.revdog.retriever.upload"

    private let lock = NSLock()
    private var active: [Int: Entry] = [:]
    private let beginImpl: Begin
    private let endImpl: End

    init(begin: @escaping Begin, end: @escaping End) {
        beginImpl = begin
        endImpl = end
    }

    /// 记账里还没 end 的任务。
    var activeIds: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return active.keys.sorted()
    }

    /// begin 一个任务（拿不到 = nil）。`onExpired` 在过期时（已先 end）调。
    func begin(owner: EngineHandle, onExpired: @escaping Expired) -> Int? {
        let box = Box()
        let id = beginImpl(BackgroundTasks.taskName) { [weak self] in
            guard let self else { return }
            guard let id = box.id else {
                box.expiredEarly = true
                return
            }
            self.expire(id)
        }
        guard let id else { return nil }
        box.id = id
        lock.lock()
        active[id] = Entry(owner: owner, onExpired: onExpired)
        lock.unlock()
        if box.expiredEarly {
            // begin 还没返回就过期（理论上不会）：同样先 end 再通知
            expire(id)
            return nil
        }
        return id
    }

    /// 幂等 end：只 end 记账里还在的；返回这次是否真的 end 了。
    @discardableResult
    func end(_ id: Int) -> Bool {
        lock.lock()
        let had = active.removeValue(forKey: id) != nil
        lock.unlock()
        if had { endImpl(id) }
        return had
    }

    /// 过期：原生先 end，再通知 owner。
    func expire(_ id: Int) {
        lock.lock()
        let e = active.removeValue(forKey: id)
        lock.unlock()
        guard let e else { return }
        endImpl(id)
        if let o = e.owner { e.onExpired(id, o) }
    }

    /// owner 释放：它名下（含已释放的弱引用）的任务全部 end。
    func endAll(owner: EngineHandle) {
        lock.lock()
        let ids = active.filter { $0.value.owner == nil || $0.value.owner === owner }.map(\.key)
        for id in ids { active.removeValue(forKey: id) }
        lock.unlock()
        for id in ids.sorted() { endImpl(id) }
    }

    /// 真实现：UIApplication（扩展里拿不到 → begin 回 nil）。
    static func system() -> BackgroundTasks {
        BackgroundTasks(
            begin: { name, onExpire in
                #if canImport(UIKit)
                return PlatformInfo.onMainSync {
                    guard let app = PlatformInfo.sharedApplication() else { return nil }
                    let id = app.beginBackgroundTask(withName: name) { onExpire() }
                    return id == .invalid ? nil : id.rawValue
                }
                #else
                return nil
                #endif
            },
            end: { id in
                #if canImport(UIKit)
                PlatformInfo.onMainSync {
                    PlatformInfo.sharedApplication()?.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id))
                }
                #endif
            }
        )
    }
}
