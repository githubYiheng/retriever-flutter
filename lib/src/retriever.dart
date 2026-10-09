// 静态入口（方案 §3.10，三端同名；v3 §1 K1 / §2 / §4）。对位 Android `Retriever.kt`。纯 Dart：不 import flutter。
//
// configure 之前没有实例（ADR 0023）：首次触达任何静态入口时向垫片要一次 `root()`；回包之前的 `log()` 只计数（R-1 例外的剩余部分），
// 回包之后追加到 `<root>/pre/<token>-<uuid>.jsonl`，configure 时收编。公开入口绝不向宿主抛异常；异步错误不外泄；
// `configure` / `flush` / `purgeLocal` 的 Future 有界完成；实例建成之前不建 Timer；`unsupported` 终态零 Timer 零文件。
//
// K1 configure 状态机：none → bootstrapping → ready | failed | unsupported | nonOwner（见 [RetrieverState]）。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'client.dart';
import 'config_check.dart';
import 'config_diagnostics.dart';
import 'drop_counter.dart';
import 'fs.dart';
import 'ids.dart';
import 'limits.dart';
import 'line_encoder.dart';
import 'markers.dart';
import 'model.dart';
import 'platform.dart';
import 'pre.dart';
import 'public_api.dart';
import 'root_purge.dart';
import 'text.dart';
import 'writer.dart';

/// K1 configure 状态（进程内静态；不进公开面）。
enum RetrieverState {
  /// 进程起：首触发 `root()`；`log` → 计数（root 已知后 → pre 文件）。
  none,

  /// `configure` 首次调用，`await bootstrap()`（超时 5 s）：第二次 configure 排在后面；log → pre 文件。
  bootstrapping,

  /// bootstrap 成功、实例建成（收编在实例的队列上做）。
  ready,

  /// bootstrap 超时 / 垫片调用失败：下一次触达或下一次 configure 重试，间隔 ≥ 5 s；不用 Timer。
  failed,

  /// `MissingPluginException`、web / 桌面、宿主 `flutter test`：终态（不留 Timer、不开文件、log 零开销）。
  unsupported,

  /// bootstrap 回包 owner = false（v3 §4）：写自己的 pre 文件；收到 `ownerReleased()` 或回前台立即重试 bootstrap，
  /// 被触达（log / setUser / flush）时按 ≥ 60 s 间隔重试。
  nonOwner,
}

/// facade 的进程内状态与测试钩子（不从 `package:revdog_retriever/revdog_retriever.dart` 导出）。
abstract final class RetrieverRuntime {
  /// 生产平台工厂：切片 2 由插件注册（ChannelPlatform；注入前先判 `RootIsolateToken.instance` 等）。null = 本进程不支持。
  static RetrieverPlatform Function()? defaultPlatformFactory;

  /// 测试注入的平台工厂（优先于 [defaultPlatformFactory]；不做 `FLUTTER_TEST` / 平台判定）。
  static RetrieverPlatform Function()? platformFactory;

  static RetrieverState state = RetrieverState.none;
  static RetrieverPlatform? platform;
  static RetrieverClient? client;

  /// 测试：实例的内部异常出口。
  static void Function(Object error)? internalErrorSink;

  // root() 回包
  static String? root;
  static String? token;
  static String? rootProcess;
  static Map<String, String>? rootDevice;
  static bool _rootInFlight = false;
  static int? _rootFailMono;

  /// configure 之前宿主调过的 `setEnabled`（显式值；建实例时作为初值）。
  static bool? pendingEnabled;

  /// configure 之前禁用标记判定的短缓存（结果 + 单调时刻）。
  static (MarkerState, int)? _markerCache;

  static Future<void> _chain = Future<void>.value();
  static (String, String, RetrieverOptions)? _lastConfigure;
  static int? _failMono;

  /// 非 owner：上次（进入非 owner 或排上重试）的单调时刻；触达时按 ≥ 60 s 间隔重试（v3 §4）。
  static int? _nonOwnerMono;

  /// bootstrapping 期间收到了 `ownerReleased` / `willEnterForeground`：回包若是非 owner，进 nonOwner 后立即重试一次。
  /// 3.38 起平台线程与 UI 线程合一，原生 → Dart 的消息可能同步派发、而 bootstrap 的回包排队投递——原生先回 owner=false、
  /// 随后旧 owner detach 发出的 ownerReleased 会先于回包到达（模拟器实测，切片 2 报告 §5.3），这里不能丢。
  static bool _retryAfterBootstrap = false;

  /// 实例建成之前到达的最近一次前后台事件（true = 前台）与事件序号（审计 #7）。
  static bool? _lastForeground;
  static int _foregroundEvents = 0;

  static final _Events _events = _Events();

  static int _mono() => platform?.clock.monoMs() ?? DateTime.now().millisecondsSinceEpoch;

  /// 测试：模拟进程重启——关掉实例（不收尾）、清空静态状态；`platformFactory` 非 null 时之后用它。
  static Future<void> resetForTesting({RetrieverPlatform Function()? platformFactory}) async {
    final c = client;
    client = null;
    if (c != null) {
      try {
        await c.closeForTesting();
      } catch (_) {}
    }
    try {
      platform?.eventHandler = null;
    } catch (_) {}
    platform = null;
    RetrieverRuntime.platformFactory = platformFactory;
    state = RetrieverState.none;
    root = null;
    token = null;
    rootProcess = null;
    rootDevice = null;
    _rootInFlight = false;
    _rootFailMono = null;
    pendingEnabled = null;
    _markerCache = null;
    _chain = Future<void>.value();
    _configuresInFlight = 0;
    _lastConfigure = null;
    _failMono = null;
    _nonOwnerMono = null;
    _retryAfterBootstrap = false;
    _lastForeground = null;
    _foregroundEvents = 0;
    internalErrorSink = null;
    ConfigDiagnostics.resetForTesting();
    PreLog.resetForTesting();
    DropCounter.reset();
    Reentrancy.active = false;
  }

  /// 首次触达：建平台、装事件出口（在 `root()` 之前）、要 root。返回 false = 本进程不支持（终态）。
  static bool touch() {
    if (state == RetrieverState.unsupported) return false;
    if (platform == null) {
      final injected = platformFactory;
      RetrieverPlatform? p;
      try {
        if (injected != null) {
          p = injected();
        } else {
          // 宿主 `flutter test`：未打桩的 channel 调用会挂到超时（不抛 MissingPluginException），挂着的超时 Timer 会让宿主的
          // widget 测试失败 —— 在任何 channel 调用之前判掉（v3 第二轮核实）。web 不会走到这里（条件导入）；桌面不支持。
          if (hostUnsupported(Platform.environment, Platform.operatingSystem)) {
            state = RetrieverState.unsupported;
            return false;
          }
          p = defaultPlatformFactory?.call();
        }
      } catch (_) {
        p = null;
      }
      if (p == null) {
        state = RetrieverState.unsupported;
        return false;
      }
      platform = p;
      ConfigDiagnostics.platformOf = () => platform;
      try {
        p.eventHandler = _events;
      } catch (_) {}
    }
    if (root == null) _requestRoot();
    return state != RetrieverState.unsupported;
  }

  /// 宿主判定（任何 channel 调用之前）：宿主 `flutter test`（`FLUTTER_TEST=true`）或不是 Android / iOS → 本进程 unsupported。
  static bool hostUnsupported(Map<String, String> env, String os) =>
      env['FLUTTER_TEST'] == 'true' || !(os == 'android' || os == 'ios');

  /// `root()`：回包前的行只计数；失败下次触达再试（间隔 ≥ 5 s），不建 Timer。
  static void _requestRoot() {
    final p = platform;
    if (p == null || _rootInFlight) return;
    final last = _rootFailMono;
    if (last != null && _mono() - last < ClientConstants.rootRetryMs) return;
    _rootInFlight = true;
    final Future<RootInfo> f;
    try {
      f = p.root().timeout(const Duration(milliseconds: ClientConstants.channelBootstrapTimeoutMs));
    } catch (e) {
      _rootInFlight = false;
      _onRootError(e);
      return;
    }
    f
        .then((info) {
          _rootInFlight = false;
          if (!identical(platform, p)) return;
          // token 不是小写 UUID：垫片错误，按 root() 失败处理（同 token 跳过规则靠文件名前缀 = token，审计 #12）
          if (!Ids.isUuid(info.token)) {
            _onRootError(const PlatformCallException(_badToken, 'root() token is not a lowercase UUID'));
            return;
          }
          _setRoot(info.root, info.token, info.process, info.device);
        })
        .catchError((Object e) {
          _rootInFlight = false;
          if (identical(platform, p)) _onRootError(e);
        })
        .ignore();
  }

  static const String _badToken = 'bad_token';

  static void _onRootError(Object e) {
    if (e is PlatformUnsupportedException) {
      _becomeUnsupported();
    } else {
      _rootFailMono = _mono();
    }
  }

  static void _setRoot(String r, String t, String? process, Map<String, String>? device) {
    if (root != null) return;
    root = r;
    token = t;
    rootProcess = process;
    rootDevice = device;
    _markerCache = null;
    // root 未知时宿主 setEnabled 过：root 到达时补做落盘（v3 §1）
    final pe = pendingEnabled;
    if (pe != null && client == null) {
      final ok = pe ? Markers.clearSync(r) : Markers.markSync(r);
      if (pe && !ok) pendingEnabled = null;
    }
  }

  /// 实例建成之前的前后台事件：记下（建实例时回包 foreground 为 null 则作初值；回包之后才到的在发布时补上）。
  static void _noteForeground(bool fg) {
    _lastForeground = fg;
    _foregroundEvents++;
  }

  /// 实例建成之前到达的 `didEnterBackground(id)`：没有实例替它 end，立即 end（2 s 超时，失败忽略；iOS 幂等记账）。
  static void _endBackgroundTaskNow(int id) {
    final p = platform;
    if (p == null) return;
    try {
      p
          .endBackgroundTask(id)
          .timeout(const Duration(milliseconds: ClientConstants.channelCallTimeoutMs))
          .catchError((Object _) {})
          .ignore();
    } catch (_) {}
  }

  static void _becomeUnsupported() {
    state = RetrieverState.unsupported;
    // 终态：不留任何东西（没有实例、没有 Timer；pre 文件只有 root 回包后才会建，unsupported 之后不再写）
    try {
      platform?.eventHandler = null;
    } catch (_) {}
  }

  /// configure 之前的 log() 用：判定结果缓存 1 s。
  static MarkerState cachedMarkerState(String r) {
    final now = _mono();
    final c = _markerCache;
    if (c != null && now - c.$2 >= 0 && now - c.$2 < ClientConstants.markerCacheMs) return c.$1;
    final s = Markers.stateSync(r);
    _markerCache = (s, now);
    return s;
  }

  static Uint8List _header(int now) {
    final device = Device.fromFields(rootDevice, 'retriever-flutter/${RetrieverVersion.current}');
    return PreRecords.header(now, sanitizeProcessName(rootProcess ?? 'main'), device);
  }

  /// configure 之前的 `log()`（ADR 0023）：编码成行体，一次 write 追加到本进程 pre 文件。级别不过滤（全收）。
  /// 禁用（显式 false 或标记在 / 判定不了）→ 不写不计；root 未知、超 1 MB、写失败 → 计数。fatal 只写行。
  static void preLog(
    LogLevel level,
    String msg,
    String? tag,
    Map<String, Object?>? attrs,
    Object? error,
    StackTrace? st, {
    int? ts,
  }) {
    if (Reentrancy.active) return;
    final p = platform;
    if (p == null) return;
    final now = ts ?? p.clock.wallMs();
    final explicit = pendingEnabled;
    if (explicit == false) return;
    final r = root;
    final t = token;
    if (r == null || t == null) {
      // 首触到 root 回包之间：无处可写，只计数（R-1 例外的剩余部分，宪法 §3）
      DropCounter.add(level, now);
      return;
    }
    if (explicit == null && cachedMarkerState(r) != MarkerState.absent) return;
    var res = PreRes.dropped;
    Reentrancy.active = true;
    try {
      final exc = error == null ? null : LineEncoder.exception(error, st);
      final enc = LineEncoder.encode(
        LogLine(ts: now, level: level, msg: msg, tag: tag, attrs: attrs, exc: exc?.$1),
        forceTruncated: exc?.$2 == true,
      );
      res = PreLog.appendLine(r, t, PreRecords.line(false, enc.body), () => _header(now));
    } catch (_) {
      res = PreRes.dropped;
    } finally {
      Reentrancy.active = false;
    }
    switch (res) {
      case PreRes.written:
        break;
      case PreRes.dropped:
      case PreRes.wait:
        DropCounter.add(level, now);
      case PreRes.redirect:
        final c = client;
        if (c != null) {
          c.log(level, msg, tag, attrs, error, st, ts: ts);
        } else {
          DropCounter.add(level, now);
        }
    }
  }

  /// 适配器入口（logger 的 `LogEvent.time` 作行 ts）：同 [Retriever.log]，绝不抛。
  static void logAt(
    int? ts,
    LogLevel level,
    String msg, {
    String? tag,
    Map<String, Object?>? attrs,
    Object? error,
    StackTrace? stackTrace,
  }) {
    try {
      if (state == RetrieverState.unsupported) return;
      final c = client;
      if (c != null) {
        c.log(level, msg, tag, attrs, error, stackTrace, ts: ts);
        return;
      }
      if (!touch()) return;
      preLog(level, msg, tag, attrs, error, stackTrace, ts: ts);
      retryConfigure();
    } catch (_) {}
  }

  // MARK: configure

  static int _configuresInFlight = 0;

  static Future<void> configure(String rawKey, String key, String baseUrl, RetrieverOptions options) {
    // 已有实例且没有排着的 configure：reconfigure 在调用处同步生效（之后立即写的行按新级别，v3 §1 §2）
    if (client != null && _configuresInFlight == 0) {
      try {
        _configureLocked(key, baseUrl, options).ignore();
      } catch (e) {
        _report(e);
      }
      return Future<void>.value();
    }
    _configuresInFlight++;
    final f = _chain
        .then((_) => _configureLocked(key, baseUrl, options))
        .catchError((Object e) {
          _report(e);
        })
        .whenComplete(() => _configuresInFlight--);
    _chain = f;
    return f;
  }

  static Future<void> _configureLocked(String key, String baseUrl, RetrieverOptions options) async {
    if (state == RetrieverState.unsupported) return;
    final c = client;
    if (c != null) {
      // 自动进程名取实例的（bootstrap 回包），不取 root() 回包的（两者可能不同，审计 #2；同 Android 两条路径同一个来源）
      c.reconfigure(key, baseUrl, options, sanitizeProcessName(options.processName ?? c.autoProcessName));
      return;
    }
    _lastConfigure = (key, baseUrl, options);
    await _bootstrapAndCreate();
  }

  /// 失败之后的重试（下一次触达，间隔 ≥ 5 s；回前台）与非 owner 的重试（`ownerReleased` / 回前台，[force] = true，立即；
  /// 被触达时按 ≥ 60 s 间隔，v3 §4 兜底）：排在 configure 链上。显式的下一次 configure 不经这里，直接重新 bootstrap。
  static void retryConfigure({bool force = false}) {
    if (_lastConfigure == null || client != null) return;
    if (state == RetrieverState.failed) {
      final f = _failMono;
      if (!force && f != null && _mono() - f < ClientConstants.rootRetryMs) return;
    } else if (state == RetrieverState.nonOwner) {
      final since = _nonOwnerMono;
      if (!force && since != null && _mono() - since < ClientConstants.nonOwnerRetryMs) return;
      // 排上就重新计时：连续触达不重复排
      _nonOwnerMono = _mono();
    } else {
      return;
    }
    _chain = _chain
        .then((_) async {
          if (client != null || _lastConfigure == null) return;
          if (state != RetrieverState.failed && state != RetrieverState.nonOwner) return;
          await _bootstrapAndCreate();
        })
        .catchError((Object e) {
          _report(e);
        });
  }

  static Future<void> _bootstrapAndCreate() async {
    final p = platform;
    final args = _lastConfigure;
    if (p == null || args == null) return;
    _retryAfterBootstrap = false;
    state = RetrieverState.bootstrapping;
    BootstrapInfo info;
    try {
      info = await p.bootstrap().timeout(const Duration(milliseconds: ClientConstants.channelBootstrapTimeoutMs));
      // token 不是小写 UUID：垫片错误 → failed（审计 #12）
      if (!Ids.isUuid(info.token)) {
        throw const PlatformCallException(_badToken, 'bootstrap() token is not a lowercase UUID');
      }
    } on PlatformUnsupportedException {
      _becomeUnsupported();
      return;
    } catch (_) {
      state = RetrieverState.failed;
      _failMono = _mono();
      return;
    }
    if (!identical(platform, p)) return;
    _setRoot(info.root, info.token, info.process, info.device);
    if (!info.owner) {
      state = RetrieverState.nonOwner;
      _nonOwnerMono = _mono();
      ConfigDiagnostics.nonOwner();
      if (_retryAfterBootstrap) {
        // 回包在途时 owner 已释放 / 已回前台：立即重试（排在本次 configure 之后）
        _retryAfterBootstrap = false;
        retryConfigure(force: true);
      }
      return;
    }
    final (key, baseUrl, options) = args;
    // 回包之后、发布之前到达的前后台事件比回包新：发布时补上（审计 #7）
    final fgEventsAtReply = _foregroundEvents;
    RetrieverClient? created;
    PreFile? handed;
    var handedOff = false;
    try {
      created = RetrieverClient(
        root: info.root,
        key: key,
        baseUrl: baseUrl,
        options: options,
        platform: p,
        autoProcessName: info.process,
        deviceFields: info.device,
        token: info.token,
        // 回包读不到前后台（null）：用实例建成之前记下的最近一次事件（审计 #7）
        foreground: info.foreground ?? _lastForeground,
      );
      created.onInternalError = (e) => _report(e);
      created.onKeyRejected = ConfigDiagnostics.rejected;
      await created.prepare(
        initialEnabled: pendingEnabled,
        preName: PreLog.currentName,
        initialUser: PreLog.pendingUser,
      );
      if (!identical(platform, p)) {
        await created.closeForTesting();
        return;
      }
      // 交接与发布在同一个同步块里（Dart 单线程：没有「文件已交出、实例还没发布」的窗口）
      handed = PreLog.handoff();
      handedOff = true;
      created.attach(preFile: handed, initialUser: PreLog.pendingUser, explicitEnabled: pendingEnabled);
      client = created;
      state = RetrieverState.ready;
      pendingEnabled = null;
      // v3 §1.1：bootstrap 成功时生效开关（显式值 ?? 标记 == ABSENT）为 false → 丢弃已累计的计数；显式 true → 保留上报（审计 #4）
      if (!created.isEnabled) DropCounter.reset();
      created.start();
      final fg = _lastForeground;
      if (_foregroundEvents != fgEventsAtReply && fg != null) created.foregroundStateChanged(fg);
    } catch (e) {
      _report(e);
      if (client == null) {
        if (handedOff) {
          // 交接之后 attach 抛异常（同 Android handoffFailed，审计 #8）：pre 文件从没发布的实例手里拿回来（不关、不删、flock 仍持有），
          // 回到 open —— 之后的行照常追加，下次重试再收编
          try {
            created?.writer.abortAdoption();
          } catch (_) {}
          PreLog.handoffFailed(handed);
        }
        state = RetrieverState.failed;
        _failMono = _mono();
        try {
          await created?.closeForTesting();
        } catch (_) {}
      }
    }
  }

  static void _report(Object e) {
    try {
      internalErrorSink?.call(e);
    } catch (_) {}
  }
}

/// 原生 → Dart 事件：转给实例；非 owner 收到 `ownerReleased` / 回前台时立即重试 bootstrap（v3 §4）；实例建成之前到达的前后台事件
/// 记下（建实例时用），`didEnterBackground(id)` 立即 end（审计 #7）。
class _Events implements PlatformEventHandler {
  RetrieverClient? get _c => RetrieverRuntime.client;

  void _guard(void Function() body) {
    try {
      body();
    } catch (e) {
      RetrieverRuntime._report(e);
    }
  }

  @override
  void didEnterBackground(int? bgTaskId) => _guard(() {
    final c = _c;
    if (c != null) {
      c.didEnterBackground(bgTaskId);
      return;
    }
    // 实例还没建成（bootstrapping / failed / 回包后实例未发布）：不能吞——后台任务立即 end，前后台状态记下（审计 #7）
    RetrieverRuntime._noteForeground(false);
    if (bgTaskId != null) RetrieverRuntime._endBackgroundTaskNow(bgTaskId);
  });

  @override
  void willEnterForeground() => _guard(() {
    final c = _c;
    if (c != null) {
      c.willEnterForeground();
    } else {
      RetrieverRuntime._noteForeground(true);
      if (RetrieverRuntime.state == RetrieverState.bootstrapping) RetrieverRuntime._retryAfterBootstrap = true;
      RetrieverRuntime.retryConfigure(force: RetrieverRuntime.state == RetrieverState.nonOwner);
    }
  });

  @override
  void foregroundStateChanged(bool foreground) => _guard(() {
    final c = _c;
    if (c != null) {
      c.foregroundStateChanged(foreground);
    } else {
      RetrieverRuntime._noteForeground(foreground);
    }
  });

  @override
  void backgroundTaskExpired(int id) => _guard(() => _c?.backgroundTaskExpired(id));

  @override
  void networkRestored() => _guard(() => _c?.networkRestored());

  @override
  Future<bool> drainOutbox(int budgetMs) async {
    try {
      final c = _c;
      if (c == null) return false;
      return await c.runUploadJob(budgetMs);
    } catch (e) {
      RetrieverRuntime._report(e);
      return false;
    }
  }

  @override
  void stopUploadJob() => _guard(() => _c?.stopUploadJob());

  @override
  void ownerReleased() => _guard(() {
    switch (RetrieverRuntime.state) {
      case RetrieverState.nonOwner:
        RetrieverRuntime.retryConfigure(force: true);
      case RetrieverState.bootstrapping:
        // 回包还没处理：记下，回包若是非 owner 就立即重试（见 [RetrieverRuntime._retryAfterBootstrap]）
        RetrieverRuntime._retryAfterBootstrap = true;
      default:
        break;
    }
  });
}

/// 静态入口（三端同名）。公开入口绝不向宿主抛异常。
abstract final class Retriever {
  static const String defaultBaseUrl = 'https://logs.revdog.org';

  /// 首次调用：向垫片 bootstrap、建实例并收编 configure 之前的行（有界完成：bootstrap 超时 5 s）。之后的调用：同参数 = 只更新 redact；
  /// `processName` 与首次不同 → 忽略这一项并留合成 warn `rtv.reconfigure_ignored`，其余参数照常生效（宿主默认同步生效）。
  /// key 与 baseUrl 先去掉首尾空白与控制字符；写错时经垫片在系统日志里出诊断（ADR 0025）。
  /// 只在 `main()` 里 configure（`WidgetsFlutterBinding.ensureInitialized()` 之后、尽早 `await`），不要在后台入口 configure。
  static Future<void> configure(
    String key, {
    String baseUrl = defaultBaseUrl,
    RetrieverOptions options = const RetrieverOptions(),
  }) {
    try {
      final k = ConfigCheck.trim(key);
      final base = ConfigCheck.trim(baseUrl);
      if (!RetrieverRuntime.touch()) return Future<void>.value();
      // 诊断一进来就算、fire-and-forget 发出，再 bootstrap（与实例建没建成无关）；只出诊断不改行为
      ConfigDiagnostics.configured(key, k, base);
      return RetrieverRuntime.configure(key, k, base, options).catchError((Object _) {});
    } catch (_) {
      return Future<void>.value();
    }
  }

  static void setUser(String? id) {
    try {
      final c = RetrieverRuntime.client;
      if (c != null) {
        c.setUser(id);
        return;
      }
      if (!RetrieverRuntime.touch()) return;
      // configure 之前：清洗后记内存；本进程 pre 文件已存在则写一条用户切换记录（随后创建时写在头记录之后）
      PreLog.setUser(Text.sanitizeUserId(id));
      RetrieverRuntime.retryConfigure();
    } catch (_) {}
  }

  /// 记一行。`error` → `exc`（type = runtimeType、message = toString()、stack = stackTrace 或 Error.stackTrace）。绝不抛给宿主。
  static void log(
    LogLevel level,
    String msg, {
    String? tag,
    Map<String, Object?>? attrs,
    Object? error,
    StackTrace? stackTrace,
  }) {
    try {
      if (RetrieverRuntime.state == RetrieverState.unsupported) return;
      final c = RetrieverRuntime.client;
      if (c != null) {
        c.log(level, msg, tag, attrs, error, stackTrace);
        return;
      }
      if (!RetrieverRuntime.touch()) return;
      RetrieverRuntime.preLog(level, msg, tag, attrs, error, stackTrace);
      RetrieverRuntime.retryConfigure();
    } catch (_) {}
  }

  /// 「上报问题」：15 s 内确认 → [FlushResult.stored]，否则 [FlushPending]（原因）。Future 必完成、不抛；未 configure → paused。
  static Future<FlushResult> flush({bool includeContext = true}) {
    try {
      final c = RetrieverRuntime.client;
      if (c != null) return c.flush(includeContext).catchError((Object _) => FlushResult.pending('timeout'));
      // 触达：failed 按 ≥ 5 s、非 owner 按 ≥ 60 s 间隔重试 bootstrap（不等它，本次照回 paused）
      if (RetrieverRuntime.touch()) RetrieverRuntime.retryConfigure();
      return Future<FlushResult>.value(FlushResult.pending('paused'));
    } catch (_) {
      return Future<FlushResult>.value(FlushResult.pending('timeout'));
    }
  }

  /// 生效的自动上传级别（远程配置钳制后；full_dump 期间为 debug）。configure 之前 = warn。
  static LogLevel get uploadLevel {
    try {
      return RetrieverRuntime.client?.effectiveLevels.$1 ?? LogLevel.warn;
    } catch (_) {
      return LogLevel.warn;
    }
  }

  /// 生效的本地落盘级别。适配器用它早过滤。configure 之前 = debug（全收）。
  static LogLevel get localLevel {
    try {
      return RetrieverRuntime.client?.effectiveLevels.$2 ?? LogLevel.debug;
    } catch (_) {
      return LogLevel.debug;
    }
  }

  /// 用户同意 / 撤回：false 时不写、不传、不拉配置、不排后台作业。**跨重启有效**（root 同级 `<root>.disabled` 标记）。
  /// 撤回同意的完整组合 = `setEnabled(false)` + `purgeLocal()` + `setUser(null)`（purge 不清用户）。
  static void setEnabled(bool enabled) {
    try {
      final c = RetrieverRuntime.client;
      if (c != null) {
        c.setEnabled(enabled);
        return;
      }
      if (!RetrieverRuntime.touch()) return;
      RetrieverRuntime._markerCache = null;
      final r = RetrieverRuntime.root;
      if (r == null) {
        // root 未知：只记内存值（root 到达时补做落盘；建实例时作为初值）
        RetrieverRuntime.pendingEnabled = enabled;
        return;
      }
      final ok = enabled ? Markers.clearSync(r) : Markers.markSync(r);
      // 标记删不掉：不记显式 true、保持禁用（fail-closed）；写不成：内存照样禁用（实例在引擎队列上重试）
      RetrieverRuntime.pendingEnabled = (enabled && !ok) ? null : enabled;
    } catch (_) {}
  }

  /// 当前是否启用：有实例 = 本进程的开关；configure 之前 = 显式值 ?? 盘上标记三态（1 s 缓存；root 未知 = false）。
  static bool get isEnabled {
    try {
      final c = RetrieverRuntime.client;
      if (c != null) return c.isEnabled;
      if (!RetrieverRuntime.touch()) return false;
      final pe = RetrieverRuntime.pendingEnabled;
      if (pe != null) return pe;
      final r = RetrieverRuntime.root;
      if (r == null) return false;
      return RetrieverRuntime.cachedMarkerState(r) == MarkerState.absent;
    } catch (_) {
      return false;
    }
  }

  /// 清空本地（新 install_id）。返回的 Future 清完才完成（此时 [installId] 已是新值或 null）；不改变启用状态、不清用户。
  /// configure 之前：删本进程 pre 文件、清零没落盘的计数，按「改名再删」清 root（root 未知时立即完成）。
  static Future<void> purgeLocal() {
    try {
      final c = RetrieverRuntime.client;
      if (c != null) return c.purgeLocal().catchError((Object _) {});
      if (!RetrieverRuntime.touch()) return Future<void>.value();
      switch (RetrieverRuntime.state) {
        case RetrieverState.bootstrapping:
          // 排在 configure 之后
          return RetrieverRuntime._chain.then((_) => purgeLocal()).catchError((Object _) {});
        case RetrieverState.nonOwner:
          // 非 owner：只删自己的 pre 文件、立即完成（不清 owner 的数据）
          PreLog.discard();
          return Future<void>.value();
        default:
          return _purgeBeforeConfigure();
      }
    } catch (_) {
      return Future<void>.value();
    }
  }

  static Future<void> _purgeBeforeConfigure() {
    DropCounter.reset();
    final r = RetrieverRuntime.root;
    if (r == null) return Future<void>.value();
    PreLog.discard();
    // 改名在本调用里同步做（之后的 log() 新建的 pre 文件在新 root 里，不会被这次清掉）；删除异步、删完才完成
    final abs = File(r).absolute.path;
    String? moved;
    List<String>? listed;
    try {
      if (Directory(abs).existsSync()) {
        final dst = '$abs${RootPurge.infix}${Ids.newV4()}';
        try {
          Directory(abs).renameSync(dst);
          moved = dst;
        } catch (_) {
          // 改名失败：列出此刻的条目，后台只删这些（purge 之后新建的 pre 文件不碰）
          listed = _snapshotSync(abs);
        }
      }
    } catch (_) {}
    final m = moved;
    final l = listed;
    return () async {
      if (m != null) await Fs.remove(m);
      if (l != null) await RootPurge.deleteListed(l);
    }().catchError((Object _) {});
  }

  static List<String> _snapshotSync(String root) {
    final out = <String>[];
    void walk(String d) {
      for (final n in Fs.listSync(d) ?? const <String>[]) {
        final f = Fs.join(d, n);
        if (FileSystemEntity.isDirectorySync(f)) walk(f);
        out.add(f);
      }
    }

    walk(root);
    return out;
  }

  static String? get installId {
    try {
      return RetrieverRuntime.client?.installId;
    } catch (_) {
      return null;
    }
  }

  /// install_id 前 8 位 + "-" + session_no（给客服报障用）。configure 之前为 null。
  static String? get supportCode {
    try {
      return RetrieverRuntime.client?.supportCode;
    } catch (_) {
      return null;
    }
  }
}
