import Foundation

/// 引擎状态（owner 释放的第二条路径与「能不能往它发消息」都看它；v3 §4、核实 round2 #2）。
enum EngineState: Equatable {
    /// 拿不到引擎对象（registrar 的 `flutterEngine` 属性与 `viewController?.engine` 都没有）：只能靠 detach 释放；照常可发消息。
    case unknown
    /// 引擎对象已释放。
    case gone
    /// 引擎在、没有 isolate：`destroyContext` 之后（或还没起来）。**不能**往它发消息——`-[FlutterEngine sendOnChannel:]`
    /// 会解引用已 reset 的 shell（3.44.4 `FlutterEngine.mm:1311–1329`）。
    case noIsolate
    case running(String)

    var canReceive: Bool {
        switch self {
        case .unknown, .running: return true
        case .gone, .noIsolate: return false
        }
    }

    var isolateId: String? {
        if case .running(let id) = self { return id }
        return nil
    }
}

/// 一个已注册的引擎（每引擎一个插件实例）。只在主线程上用；单测用假实现。
protocol EngineHandle: AnyObject {
    var engineState: EngineState { get }
    /// 原生 → Dart 的反向调用（fire-and-forget）。实现方自己再判一次 `canReceive`。
    func send(_ method: String, _ arguments: Any?)
}

/// 进程级引擎登记 + owner（v3 §3 / §4）：
/// - owner = 首个 `bootstrap()` 的引擎（插件实例）+ 登记时的 `isolateId` 快照；同一引擎（热重启）再次 bootstrap 仍是 owner、更新快照；
/// - 释放两条路径：① `detachFromEngine(for:)`（只在引擎 dealloc 且插件 `publish` 过时调）→ 释放、结束它的后台任务、向其余引擎广播
///   `ownerReleased`；② 任何引擎 `bootstrap()` 时若 owner 引擎已释放、没有 isolate、或 isolateId 与快照不同 → 视为已释放（`destroyContext`
///   不调 detach，核实 round2 #2）。② 只在拿得到引擎对象时生效（见 `RetrieverPlugin.resolveEngine`）；拿不到（`.unknown`）只靠 ①；
/// - 投递：`willEnterForeground` / `ownerReleased` 广播给所有能收消息的引擎，其余只投 owner（切片 1 审计裁决）。
final class EngineRegistry {
    static let shared = EngineRegistry(tasks: BackgroundTasks.system())

    private struct Owner {
        let handle: EngineHandle
        var snapshot: String?
    }

    private let lock = NSLock()
    private var engines: [EngineHandle] = []
    private var owner: Owner?
    let tasks: BackgroundTasks

    init(tasks: BackgroundTasks) {
        self.tasks = tasks
    }

    func attach(_ h: EngineHandle) {
        lock.lock()
        defer { lock.unlock() }
        if !engines.contains(where: { $0 === h }) { engines.append(h) }
    }

    /// 注销；本引擎是 owner → 释放、结束它名下的后台任务、向其余能收消息的引擎发 `ownerReleased()`。返回是否释放了 owner。
    @discardableResult
    func detach(_ h: EngineHandle) -> Bool {
        lock.lock()
        engines.removeAll { $0 === h }
        let released = owner?.handle === h
        if released { owner = nil }
        let others = engines
        lock.unlock()
        guard released else { return false }
        tasks.endAll(owner: h)
        for e in others where e.engineState.canReceive {
            e.send("ownerReleased", nil)
        }
        return true
    }

    /// `bootstrap()`：空位 / 同一引擎 / 现 owner 已失效（第二条释放路径）→ 本引擎成为 owner。
    func claim(_ h: EngineHandle) -> Bool {
        let mine = h.engineState
        var stale: EngineHandle?
        lock.lock()
        if var o = owner {
            if o.handle === h {
                o.snapshot = mine.isolateId ?? o.snapshot
                owner = o
                lock.unlock()
                return true
            }
            var released: Bool
            switch o.handle.engineState {
            case .unknown:
                released = false
            case .gone, .noIsolate:
                released = true
            case .running(let id):
                if let snap = o.snapshot {
                    // 热重启成了别的 isolate、新 isolate 还没 bootstrap：视为已释放（v3 §4）
                    released = id != snap
                } else {
                    // 登记时还没有 isolateId：把现在的当快照（同一个 isolate），仍是 owner
                    o.snapshot = id
                    owner = o
                    released = false
                }
            }
            if !released {
                lock.unlock()
                return false
            }
            stale = o.handle
        }
        owner = Owner(handle: h, snapshot: mine.isolateId)
        lock.unlock()
        // 旧 owner 名下还没 end 的后台任务一并 end（它的 isolate 已不在，没人替它 end）
        if let stale { tasks.endAll(owner: stale) }
        return true
    }

    /// 当前能收消息的 owner（失效的不算；不改登记）。
    func liveOwner() -> EngineHandle? {
        lock.lock()
        let o = owner?.handle
        lock.unlock()
        guard let o, o.engineState.canReceive else { return nil }
        return o
    }

    func isOwner(_ h: EngineHandle) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return owner?.handle === h
    }

    var attachedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return engines.count
    }

    func broadcast(_ method: String, _ arguments: Any?) {
        lock.lock()
        let all = engines
        lock.unlock()
        for e in all where e.engineState.canReceive {
            e.send(method, arguments)
        }
    }
}

// MARK: tracker → 引擎

extension EngineRegistry: ForegroundListener {
    /// 进后台：只在有（活着的）owner 时、在通知回调里同步 `beginBackgroundTask`，id 随 `didEnterBackground(bgTaskId)` 交给 owner。
    func trackerDidEnterBackground() {
        guard let o = liveOwner() else { return }
        let id = tasks.begin(owner: o) { id, owner in
            // 原生已先 end（BackgroundTasks.expire）；Dart 只取消在途请求
            if owner.engineState.canReceive { owner.send("backgroundTaskExpired", ["id": id]) }
        }
        o.send("didEnterBackground", ["bgTaskId": id.map { $0 as Any } ?? NSNull()])
    }

    /// 回前台：广播（非 owner 靠它重试 bootstrap）。
    func trackerWillEnterForeground() {
        broadcast("willEnterForeground", nil)
    }

    /// didBecomeActive / willResignActive 读到状态变化：只改 owner 的 last_state。
    func trackerForegroundStateChanged(_ fg: Bool) {
        liveOwner()?.send("foregroundStateChanged", ["fg": fg])
    }
}
