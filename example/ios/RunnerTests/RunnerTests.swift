import Flutter
import UIKit
import XCTest

@testable import revdog_retriever

// iOS 垫片原生单测（切片 2 简报 §3「原生单测」）：过期必 end、id 幂等、tracker 单例与去重、owner 释放两条路径。
// 真实 UIKit / FlutterEngine 的行为在模拟器实跑里验（REPORT-slice2 §5）。

/// 假引擎：状态可设，记下收到的反向调用。
final class FakeEngine: EngineHandle {
  let name: String
  var engineState: EngineState
  var sent: [(String, Any?)] = []

  init(_ name: String, _ state: EngineState = .running("isolate-\(UUID().uuidString)")) {
    self.name = name
    engineState = state
  }

  func send(_ method: String, _ arguments: Any?) {
    guard engineState.canReceive else { return }
    sent.append((method, arguments))
  }

  var methods: [String] { sent.map(\.0) }
}

/// 假 UIApplication 后台任务：记下 begin / end 的顺序。
final class FakeTasks {
  var next = 100
  var log: [String] = []
  var expirations: [Int: () -> Void] = [:]
  var failBegin = false

  lazy var tasks = BackgroundTasks(
    begin: { [unowned self] _, onExpire in
      if self.failBegin { return nil }
      self.next += 1
      self.log.append("begin \(self.next)")
      self.expirations[self.next] = onExpire
      return self.next
    },
    end: { [unowned self] id in self.log.append("end \(id)") }
  )

  func fireExpiration(_ id: Int) { expirations[id]?() }
}

/// 假前后台来源：手动发通知、手动设 applicationState。
final class FakeSource: ForegroundSource {
  var available = true
  var isMainThread = true
  var state: Bool? = true
  var handler: ((ForegroundNote) -> Void)?
  var observeCalls = 0

  func readForeground() -> Bool? { state }
  func onMain(_ f: @escaping () -> Void) { f() }
  func observe(_ handler: @escaping (ForegroundNote) -> Void) {
    observeCalls += 1
    self.handler = handler
  }

  func post(_ n: ForegroundNote) { handler?(n) }
}

/// 假 messenger（不是 FlutterEngine）：记下发出去的 channel 消息。
final class FakeMessenger: NSObject, FlutterBinaryMessenger {
  var sent: [String] = []

  func send(onChannel channel: String, message: Data?) { sent.append(channel) }

  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply? = nil) {
    sent.append(channel)
  }

  func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler? = nil)
    -> FlutterBinaryMessengerConnection
  { 1 }

  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
}

final class Listener: ForegroundListener {
  var events: [String] = []
  func trackerDidEnterBackground() { events.append("bg") }
  func trackerWillEnterForeground() { events.append("fg") }
  func trackerForegroundStateChanged(_ fg: Bool) { events.append("state:\(fg)") }
}

class RunnerTests: XCTestCase {

  // MARK: 后台任务：过期必 end、id 幂等

  func testExpirationEndsNativelyBeforeNotifyingOwner() {
    let fake = FakeTasks()
    let owner = FakeEngine("owner")
    var notified: [Int] = []
    let id = fake.tasks.begin(owner: owner) { id, o in
      XCTAssertTrue(o === owner)
      // 通知 owner 时原生已经 end
      XCTAssertEqual(fake.log.last, "end \(id)")
      notified.append(id)
    }
    XCTAssertEqual(id, 101)
    fake.fireExpiration(101)
    XCTAssertEqual(fake.log, ["begin 101", "end 101"])
    XCTAssertEqual(notified, [101])
    // 过期之后 Dart 再来 end：幂等，不重复 end
    XCTAssertFalse(fake.tasks.end(101))
    fake.fireExpiration(101)
    XCTAssertEqual(fake.log, ["begin 101", "end 101"])
    XCTAssertEqual(notified, [101])
  }

  func testEndIsIdempotent() {
    let fake = FakeTasks()
    let owner = FakeEngine("owner")
    let id = fake.tasks.begin(owner: owner) { _, _ in XCTFail("not expired") }!
    XCTAssertTrue(fake.tasks.end(id))
    XCTAssertFalse(fake.tasks.end(id))
    XCTAssertFalse(fake.tasks.end(9999), "未知 id 不调 UIKit")
    fake.fireExpiration(id)
    XCTAssertEqual(fake.log, ["begin 101", "end 101"])
    XCTAssertEqual(fake.tasks.activeIds, [])
  }

  func testEndAllForReleasedOwner() {
    let fake = FakeTasks()
    let a = FakeEngine("a")
    let b = FakeEngine("b")
    let ia = fake.tasks.begin(owner: a) { _, _ in }!
    let ib = fake.tasks.begin(owner: b) { _, _ in }!
    fake.tasks.endAll(owner: a)
    XCTAssertEqual(fake.tasks.activeIds, [ib])
    XCTAssertEqual(fake.log, ["begin \(ia)", "begin \(ib)", "end \(ia)"])
  }

  // MARK: tracker：单例只装一次、两套通知去重

  func testTrackerInstallsOnceAndDedupesAppAndSceneNotifications() {
    let src = FakeSource()
    src.state = false // scene 应用注册时读到 background
    let t = ForegroundTracker(source: src)
    let l = Listener()
    t.listener = l
    XCTAssertTrue(t.install())
    XCTAssertFalse(t.install(), "进程级只装一次")
    XCTAssertEqual(src.observeCalls, 1)
    XCTAssertEqual(t.state, false)
    XCTAssertEqual(l.events, [], "初值不出事件")

    // 用户把 app 拉到前台：scene + app 两套 willEnterForeground（通知发出时 applicationState 仍是 background）
    src.post(.willEnterForeground)
    src.post(.willEnterForeground)
    src.state = true
    src.post(.didBecomeActive)
    src.post(.didBecomeActive)
    XCTAssertEqual(l.events, ["fg"], "同一次切换只出一次 willEnterForeground；didBecomeActive 没变化不出")

    // 进后台：willResignActive（inactive 仍算前台）→ didEnterBackground × 2
    src.post(.willResignActive)
    src.state = false
    src.post(.didEnterBackground)
    src.post(.didEnterBackground)
    XCTAssertEqual(l.events, ["fg", "bg"])
    XCTAssertEqual(t.state, false)
  }

  func testDidEnterBackgroundIgnoredWhileAnotherSceneIsForeground() {
    let src = FakeSource()
    let t = ForegroundTracker(source: src)
    let l = Listener()
    t.listener = l
    t.install()
    XCTAssertEqual(t.state, true)
    // 多 scene：一个 scene 进后台，app 还有前台 scene
    src.state = true
    src.post(.didEnterBackground)
    XCTAssertEqual(l.events, [])
    XCTAssertEqual(t.state, true)
  }

  func testActiveNotificationsOnlyChangeState() {
    let src = FakeSource()
    src.state = nil // 注册时读不到
    let t = ForegroundTracker(source: src)
    let l = Listener()
    t.listener = l
    t.install()
    XCTAssertNil(t.state)
    src.state = true
    src.post(.didBecomeActive)
    XCTAssertEqual(l.events, ["state:true"], "didBecomeActive / willResignActive 只出 foregroundStateChanged")
    src.state = false
    src.post(.willResignActive)
    XCTAssertEqual(l.events, ["state:true", "state:false"])
  }

  func testTrackerUnavailableInExtensions() {
    let src = FakeSource()
    src.available = false
    let t = ForegroundTracker(source: src)
    XCTAssertTrue(t.install())
    XCTAssertEqual(src.observeCalls, 0)
    XCTAssertNil(t.state)
  }

  func testSharedTrackerIsInstalledOnceAcrossEngines() {
    // 示例 app 的引擎注册时已装过 shared tracker：再装不重复注册
    _ = ForegroundTracker.shared.install()
    XCTAssertTrue(ForegroundTracker.shared.isInstalled)
    XCTAssertFalse(ForegroundTracker.shared.install())
  }

  // MARK: owner：选择、释放两条路径、事件路由

  func testFirstBootstrapIsOwnerSameEngineStaysOwner() {
    let r = EngineRegistry(tasks: FakeTasks().tasks)
    let a = FakeEngine("a")
    let b = FakeEngine("b")
    r.attach(a)
    r.attach(b)
    XCTAssertTrue(r.claim(a))
    XCTAssertTrue(r.claim(a), "同一引擎再次 bootstrap 仍是 owner")
    XCTAssertFalse(r.claim(b))
    XCTAssertTrue(r.isOwner(a))
  }

  func testReleasePath1DetachBroadcastsToOtherLiveEngines() {
    let fake = FakeTasks()
    let r = EngineRegistry(tasks: fake.tasks)
    let owner = FakeEngine("owner")
    let other = FakeEngine("other")
    let dead = FakeEngine("dead", .noIsolate)
    [owner, other, dead].forEach(r.attach)
    XCTAssertTrue(r.claim(owner))
    let id = fake.tasks.begin(owner: owner) { _, _ in }!
    XCTAssertFalse(r.detach(other), "非 owner detach 不释放")
    r.attach(other)
    XCTAssertTrue(r.detach(owner))
    XCTAssertEqual(other.methods, ["ownerReleased"])
    XCTAssertEqual(dead.methods, [], "没有 isolate 的引擎不发（发了会崩）")
    XCTAssertEqual(owner.methods, [])
    XCTAssertEqual(fake.log, ["begin \(id)", "end \(id)"], "释放时 owner 名下的后台任务一并 end")
    XCTAssertTrue(r.claim(other), "收到 ownerReleased 的引擎重试 bootstrap → owner")
  }

  func testReleasePath2DeadOwnerDetectedOnClaim() {
    let r = EngineRegistry(tasks: FakeTasks().tasks)
    // destroyContext：引擎还在、isolateId 变 nil
    let a = FakeEngine("a", .running("i-a"))
    let b = FakeEngine("b")
    r.attach(a)
    r.attach(b)
    XCTAssertTrue(r.claim(a))
    XCTAssertFalse(r.claim(b))
    a.engineState = .noIsolate
    XCTAssertTrue(r.claim(b), "owner 的 isolate 已关：视为已释放")
    XCTAssertFalse(r.claim(a))

    // 引擎对象已释放（weak → nil）
    let c = FakeEngine("c")
    r.attach(c)
    b.engineState = .gone
    XCTAssertTrue(r.claim(c))

    // 热重启成了别的 isolate、新 isolate 还没 bootstrap：别的引擎可以接任
    let d = FakeEngine("d")
    r.attach(d)
    c.engineState = .running("i-c2")
    XCTAssertTrue(r.claim(d))

    // 同一引擎热重启后再次 bootstrap：仍是 owner，快照更新
    d.engineState = .running("i-d2")
    XCTAssertTrue(r.claim(d))
    let e = FakeEngine("e")
    r.attach(e)
    XCTAssertFalse(r.claim(e), "快照已更新为新 isolate：owner 活着")
  }

  func testUnknownEngineIsNeverStolen() {
    let r = EngineRegistry(tasks: FakeTasks().tasks)
    let a = FakeEngine("a", .unknown)
    let b = FakeEngine("b")
    XCTAssertTrue(r.claim(a))
    XCTAssertFalse(r.claim(b), "拿不到引擎对象：只靠 detach 释放")
    XCTAssertTrue(r.detach(a))
    XCTAssertTrue(r.claim(b))
  }

  func testBackgroundBeginsOneTaskOnlyWithOwnerAndRoutesEvents() {
    let fake = FakeTasks()
    let r = EngineRegistry(tasks: fake.tasks)
    let owner = FakeEngine("owner")
    let other = FakeEngine("other")
    r.attach(owner)
    r.attach(other)

    // 没有 owner：不 begin、不投递
    r.trackerDidEnterBackground()
    XCTAssertEqual(fake.log, [])

    XCTAssertTrue(r.claim(owner))
    r.trackerDidEnterBackground()
    XCTAssertEqual(fake.log, ["begin 101"])
    XCTAssertEqual(owner.methods, ["didEnterBackground"])
    XCTAssertEqual((owner.sent[0].1 as? [String: Any])?["bgTaskId"] as? Int, 101)
    XCTAssertEqual(other.methods, [], "后台只投 owner")

    r.trackerWillEnterForeground()
    XCTAssertEqual(owner.methods, ["didEnterBackground", "willEnterForeground"])
    XCTAssertEqual(other.methods, ["willEnterForeground"], "回前台广播")

    r.trackerForegroundStateChanged(true)
    XCTAssertEqual(owner.methods.last, "foregroundStateChanged")
    XCTAssertEqual(other.methods, ["willEnterForeground"])

    // 过期：原生先 end，再投 backgroundTaskExpired(id) 给 owner
    fake.fireExpiration(101)
    XCTAssertEqual(fake.log, ["begin 101", "end 101"])
    XCTAssertEqual(owner.methods.last, "backgroundTaskExpired")
    XCTAssertEqual((owner.sent.last?.1 as? [String: Any])?["id"] as? Int, 101)

    // begin 失败（拿不到 UIApplication）：仍投 didEnterBackground，id 为 null
    fake.failBegin = true
    r.trackerDidEnterBackground()
    XCTAssertTrue((owner.sent.last?.1 as? [String: Any])?["bgTaskId"] is NSNull)
  }

  func testDeadOwnerGetsNoEventsAndNoTask() {
    let fake = FakeTasks()
    let r = EngineRegistry(tasks: fake.tasks)
    let owner = FakeEngine("owner")
    r.attach(owner)
    XCTAssertTrue(r.claim(owner))
    owner.engineState = .noIsolate
    r.trackerDidEnterBackground()
    XCTAssertEqual(fake.log, [], "owner 的 isolate 已关：不 begin")
    XCTAssertNil(r.liveOwner())
  }

  // MARK: 插件拿引擎对象与引擎状态

  func testResolveEngineFromRealRegistrar() {
    // 真 registrar：`flutterEngine` 属性（responds(to:) 守着）拿得到同一个引擎
    let engine = FlutterEngine(name: "rtv-test-registrar")
    let registrar = engine.registrar(forPlugin: "RtvResolveProbe")!
    XCTAssertTrue(RetrieverPlugin.resolveEngine(registrar) === engine)
  }

  func testRealRegistrarMessengerIsNotTheEngine() {
    // 事实记录：registrar.messenger() 是 FlutterBinaryMessengerRelay，不是 FlutterEngine（所以不能靠它拿引擎）
    let engine = FlutterEngine(name: "rtv-test-relay")
    let registrar = engine.registrar(forPlugin: "RtvRelayProbe")!
    XCTAssertFalse((registrar.messenger() as AnyObject) is FlutterEngine)
  }

  func testUnresolvedEngineIsUnknownAndStillSends() {
    let m = FakeMessenger()
    let plugin = RetrieverPlugin(channel: FlutterMethodChannel(name: RetrieverPlugin.channelName, binaryMessenger: m), engine: nil)
    XCTAssertEqual(plugin.engineState, EngineState.unknown, "拿不到引擎：快照为 nil，只靠 detach 释放")
    plugin.send("willEnterForeground", nil)
    XCTAssertEqual(m.sent, [RetrieverPlugin.channelName])
    let r = EngineRegistry(tasks: FakeTasks().tasks)
    XCTAssertTrue(r.claim(plugin))
    XCTAssertFalse(r.claim(FakeEngine("other")), "unknown 的 owner 不会被第二条路径抢走")
  }

  func testResolvedEngineWithoutIsolateIsNotSentTo() {
    // 拿得到引擎、但没有 isolate（没 run / 已 destroyContext）：不发（发了会解引用空 shell）
    let m = FakeMessenger()
    let engine = FlutterEngine(name: "rtv-test-unrun")
    let plugin = RetrieverPlugin(channel: FlutterMethodChannel(name: RetrieverPlugin.channelName, binaryMessenger: m), engine: engine)
    XCTAssertEqual(plugin.engineState, EngineState.noIsolate)
    plugin.send("willEnterForeground", nil)
    XCTAssertEqual(m.sent, [], "没有 isolate 的引擎不发")
  }

  // MARK: 诊断去重、参数、root

  func testDiagnosticsDedupeAndLevels() {
    var out: [String] = []
    let d = Diagnostics { info, m in out.append((info ? "I " : "N ") + m) }
    XCTAssertTrue(d.emit(code: "no_key", message: "m1"))
    XCTAssertFalse(d.emit(code: "no_key", message: "m1"))
    XCTAssertTrue(d.emit(code: "configure_ignored", message: "configure ignored: another engine owns Retriever in this process"))
    XCTAssertTrue(d.emit(code: "key_rejected", message: "r401"))
    XCTAssertTrue(d.emit(code: "key_rejected", message: "r403"))
    XCTAssertEqual(out, ["I m1", "N configure ignored: another engine owns Retriever in this process", "N r401", "N r403"])
  }

  func testIntArgAndToken() {
    XCTAssertEqual(RetrieverPlugin.intArg(["id": 7], "id"), 7)
    XCTAssertEqual(RetrieverPlugin.intArg(["id": NSNumber(value: 8)], "id"), 8)
    XCTAssertEqual(RetrieverPlugin.intArg(9, "id"), 9)
    XCTAssertNil(RetrieverPlugin.intArg(["x": 1], "id"))
    let token = PlatformInfo.token
    XCTAssertNotNil(token.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression))
  }

  func testEnsureRootCreatesDirectoryAndExcludesFromBackup() throws {
    let path = PlatformInfo.ensureRoot()
    XCTAssertTrue(path.hasSuffix(".retriever"))
    var isDir: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: path, isDirectory: &isDir))
    XCTAssertTrue(isDir.boolValue)
    let v = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(v.isExcludedFromBackup, true)
    XCTAssertEqual(PlatformInfo.deviceFields()["os"], "ios")
    XCTAssertNotNil(PlatformInfo.availableBytes())
  }
}
