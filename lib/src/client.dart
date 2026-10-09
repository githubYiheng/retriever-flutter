// 实例（静态 API 转发到进程内共享实例；测试也可直接建实例：临时目录 + 假平台）。对位 Android `core/Client.kt`。
// 只在 `configure` 时建（ADR 0023：configure 之前没有实例）；身份（processName / root）在首次 configure 定死。
//
// 并发模型（v3 §7）：
// - 热路径 `log()` 只碰 [Writer]（主 isolate 同步一次 writeFromSync），不进引擎队列、不等待任何后台工作；
// - 其余一切磁盘状态（收编、封段、物化、出站箱、驱逐、恢复、配置、队列决策）在一条串行 Future 链（引擎队列）上，一律异步 IO；
// - 网络在队列外：排空循环 / 配置拉取 / flush 等待是独立的异步任务，发送前后各回队列一次；
// - 宿主调用永不等待 SDK 后台工作（ADR 0020 决定 1）：fatal、purgeLocal 都是投递后立即返回（purgeLocal 返回的 Future 清完才完成）；
// - 异步错误不外泄：每个不等待的 Future 都接住错误；Timer 回调整体 try（v3 §1 §5）。

import 'dart:async';
import 'dart:typed_data';

import 'adoption.dart';
import 'clock.dart';
import 'config.dart';
import 'config_check.dart';
import 'drop_counter.dart';
import 'engine.dart';
import 'fs.dart';
import 'limits.dart';
import 'line_encoder.dart';
import 'markers.dart';
import 'model.dart';
import 'outbox.dart';
import 'platform.dart';
import 'pre.dart';
import 'public_api.dart';
import 'recovery.dart';
import 'text.dart';
import 'transport.dart';
import 'uploader.dart';
import 'writer.dart';

/// 引擎串行队列（对位 Android 的单线程 `work` 执行器）：Future 链，任务异常被捕获、不阻塞后续任务。
/// 队列任务跑在带标记的 Zone 里：任务内再 `onWork` 直接执行（同 Android 的 onEngineThread 判断）。
class SerialQueue {
  Future<void> _tail = Future<void>.value();
  int _pending = 0;

  final Object _key = Object();

  bool get inQueue => Zone.current[_key] == true;

  bool get idle => _pending == 0;

  Future<T> run<T>(FutureOr<T> Function() body) {
    final c = Completer<T>();
    _pending++;
    _tail = _tail.then((_) {
      return runZoned(() async {
        try {
          c.complete(await body());
        } catch (e, st) {
          c.completeError(e, st);
        } finally {
          _pending--;
        }
      }, zoneValues: {_key: true});
    });
    return c.future;
  }

  /// 在队列之外的 Zone 里跑（排空循环、配置拉取、flush 等待：它们的 onWork 必须真的排队）。
  void detach(Future<void> Function() body, void Function(Object) report) {
    runZoned(() {
      body().catchError((Object e) => report(e));
    }, zoneValues: {_key: false});
  }
}

/// 一个等待中的 flush 标记与挂在它上面的结果。
class _FlushGroup {
  final List<_FlushOnce> waiters = <_FlushOnce>[];
  FlushResult? result;
}

/// 只回一次（flush 的等待与超时兜底谁先到用谁）。
class _FlushOnce {
  final Completer<FlushResult> _c = Completer<FlushResult>();
  Timer? timer;

  Future<FlushResult> get future => _c.future;

  bool get done => _c.isCompleted;

  void resume(FlushResult r) {
    if (_c.isCompleted) return;
    timer?.cancel();
    timer = null;
    _c.complete(r);
  }
}

class _Handled {
  bool v = false;
}

class RetrieverClient {
  RetrieverClient({
    required this.root,
    required String key,
    required String baseUrl,
    required RetrieverOptions options,
    required this.platform,
    required this.autoProcessName,
    required Map<String, String> deviceFields,
    required String token,
    bool? foreground,
  }) : processName = sanitizeProcessName(options.processName ?? autoProcessName),
       clock = platform.clock,
       transport = platform.transport,
       writer = Writer(platform.clock, HostDefaults.of(options)),
       _foreground = foreground,
       jobId = options.jobId,
       _cfgKey = key,
       _cfgBaseUrl = baseUrl,
       _cfgSdkVersion = options.sdkVersion,
       _redact = options.redact {
    engine = Engine(
      root: root,
      processName: processName,
      key: key,
      baseUrl: baseUrl,
      sdkVersion: options.sdkVersion,
      clock: clock,
      platform: platform,
      writer: writer,
      device: Device.fromFields(deviceFields, 'retriever-flutter/${options.sdkVersion}'),
      token: token,
      foregroundNow: () => _foreground,
    );
    writer.onVanished = _scheduleVanished;
    engine.onVanished = _scheduleVanished;
  }

  static const int flushWindowMsDefault = 15000;

  /// 收编本进程 pre 文件时每片最多同步读 / 处理的字节数（片之间让出事件循环）。
  static const int adoptSliceBytes = 64 * 1024;

  /// 进后台时就地排空的预算。
  static const int backgroundBudgetMs = 25000;

  /// 一次后台作业的排空预算。
  static const int jobBudgetMs = 120000;
  static const Set<String> _waitable = {'spacing', 'backoff', 'offline'};
  static const Set<String> _jobRetryReasons = {'offline', 'backoff', 'spacing', 'locked', 'background_expired'};

  static const String reconfigureIgnoredTag = 'rtv.reconfigure_ignored';
  static const String reconfigureIgnoredMsg = 'identity field change ignored after first configure';
  static const String rootVanishedTag = 'rtv.root_vanished';
  static const String rootVanishedMsg = 'session directory vanished; new session started';

  final String root;
  final String processName;

  /// 垫片给的自动进程名（bootstrap 回包）：再次 configure 判 processName 变没变时用它（不用 root() 回包的，审计 #2）。
  final String autoProcessName;
  final RetrieverPlatform platform;
  final Clock clock;
  final Transport transport;
  final Writer writer;
  late final Engine engine;
  final SerialQueue _queue = SerialQueue();

  bool? _foreground;
  int jobId;

  /// 内部异常的出口（生产：吞掉，绝不抛给宿主；测试：记录并断言为空）。
  void Function(Object error)? onInternalError;

  /// 服务端拒绝当前 key、进入鉴权暂停时的诊断出口（ADR 0025）。在排空任务里、不在引擎队列上调。
  void Function(KeyRejection r)? onKeyRejected;

  /// 宿主在本实例上最后一次显式 setEnabled 的值（null = 没调过，按盘上标记判定）。
  bool? requestedEnabled;

  /// 禁用标记判定未知（且宿主没显式设过）：按禁用处理，每次 bootstrap 成功、每次定时唤醒重判（ADR 0024 决定 6）。
  bool markerUnknown = false;

  String _cfgKey;
  String _cfgBaseUrl;
  String _cfgSdkVersion;

  /// SDK 自己取消在途请求的次数（purge、作业被停、后台到期）：发请求前后不同 = 这次失败是我们取消的（ADR 0024 决定 10）。
  int _cancelEpoch = 0;

  // ---- 调度 / 排空 / 作业状态（Android 的 Control）----
  RedactHook? _redact;
  String? _installId;
  int _sessionNo = 0;
  bool _bootstrapped = false;
  int _nextBootstrapMono = 0;
  bool _draining = false;
  bool _rekick = false;
  final List<Completer<void>> _drainWaiters = <Completer<void>>[];
  String _lastStopReason = '';
  int? _lastStopWake;
  bool _jobRunning = false;
  bool _stopRequested = false;
  int _purging = 0;
  Timer? _timer;
  int? _timerTarget;
  bool _configFetching = false;
  bool _configRefetch = false;
  bool _tombstoneScheduled = false;
  Timer? _tombstoneTimer;
  bool _closed = false;
  bool _adoptRetry = false;
  bool _vanishScheduled = false;
  bool _vanishedWarnPending = false;
  bool _jobConflictReported = false;
  bool _metaPreFix = false;
  final Map<String, _FlushGroup> _flushGroups = <String, _FlushGroup>{};
  int _flushWindowMs = flushWindowMsDefault;
  final Set<_FlushOnce> _openFlushes = <_FlushOnce>{};

  /// 本进程 pre 文件的收编进度（引擎队列上用）。
  Adopter? _adopter;

  // MARK: 建立

  /// 实例建成后、发布之前（异步）：按暂存的开关 / 盘上标记定写入开关，bootstrap 会话（合成行留到 [attach]）。
  /// `preName` = 此刻本进程 pre 文件的名字（写进 meta.json 的 `pre`）。
  /// `initialUser` = configure 之前 setUser 的值（配置缓存的身份比对要用它，所以在 bootstrap 之前就交给写入侧）。
  Future<void> prepare({bool? initialEnabled, String? preName, String? initialUser}) async {
    requestedEnabled = initialEnabled;
    writer.initUser(initialUser, preName == null);
    _applyEnabled(initialEnabled, initialEnabled == null ? await engine.markerState() : MarkerState.absent);
    engine.adoptPre = preName;
    final ok = await engine.bootstrap(emitSynth: false);
    _bootstrapped = ok;
    _installId = engine.install?.installId;
    _sessionNo = engine.current?.meta.sessionNo ?? 0;
    if (!ok) _nextBootstrapMono = clock.monoMs() + ClientConstants.adoptRetryMs;
    final gap = TestHooks.prepareGap;
    if (gap != null) await gap();
  }

  /// 发布实例的那个同步块里：交来 pre 文件（要收编）、configure 之前的用户与开关；写 bootstrap 判出的合成行。
  void attach({PreFile? preFile, String? initialUser, bool? explicitEnabled}) {
    if (preFile != null) {
      writer.beginAdopt(preFile);
      if (_bootstrapped && engine.current?.meta.pre != preFile.name) _metaPreFix = true;
      engine.adoptPre = preFile.name;
      // 有 pre 文件：会话用户从 null 起（= pre 文件开头的用户），由切换记录按顺序推进。prepare 时还没有 pre 文件、await 期间
      // 才新建的情形，prepare 已按当时的用户开了会话：复位（段里还没有行，只改写段头）——同 Android 构造时同步交接的语义（审计 #3）
      writer.adoptUser(null);
    } else {
      engine.adoptPre = null;
    }
    TestHooks.adoption?.call('attach');
    // 没有 pre 文件：会话直接以 configure 之前设的用户开始；有 pre 文件：用户边界由切换记录按顺序推进
    writer.initUser(initialUser, preFile == null);
    if (explicitEnabled != null && explicitEnabled != requestedEnabled) {
      requestedEnabled = explicitEnabled;
      markerUnknown = false;
      writer.setEnabled(explicitEnabled);
      engine.enabled = explicitEnabled;
    }
    if (_bootstrapped) engine.writePendingSynth();
  }

  /// 实例已发布：引擎队列上先收编、再 startup；没有要收编的就当场补报没落盘的行（简报 §4.2）。
  void start() {
    workAsync(() async {
      final c = engine.current;
      if (writer.adoptingFile == null && c != null && c.meta.pre != null) await engine.clearMetaPre(c);
      await _adoptOwnPreSafely();
      await _startup();
    });
    if (requestedEnabled != null) workAsync(_persistEnabled);
    if (!writer.isAdopting && _bootstrapped) _emitDropped();
  }

  void _applyEnabled(bool? explicit, MarkerState marker) {
    final on = explicit ?? (marker == MarkerState.absent);
    markerUnknown = explicit == null && marker == MarkerState.unknown;
    writer.setEnabled(on);
    engine.enabled = on;
  }

  /// 每次 bootstrap 成功后重设写入开关 = 宿主显式值 ?? 标记三态判定（ADR 0024 决定 6）。
  Future<void> _rejudgeEnabled() async => _applyEnabled(requestedEnabled, await engine.markerState());

  // MARK: 启动（引擎队列）

  /// 收编抛了异常也不卡住：置重试，startup 照常执行。
  Future<void> _adoptOwnPreSafely() async {
    try {
      await _adoptOwnPre();
    } catch (e) {
      _report(e);
      _adoptRetry = true;
    }
  }

  /// 收编本进程 configure 之前的 pre 文件（先于 startup；ADR 0023）：按文件顺序经正常追加路径写进当前会话；
  /// 追到文件尾后处理追赶期间新追加的剩余记录、切到正常态、unlink（提交点）、清 meta.pre。
  /// 剩余记录里有没过 redact 的行就再来一轮。按片读（≤ 64 KB，同一句柄），片之间让出事件循环（v3 §7；审计 #10）。
  Future<void> _adoptOwnPre() async {
    final pf = writer.adoptingFile;
    if (pf == null || !_bootstrapped) return;
    if (_metaPreFix) {
      // 收编的 pre 文件是 bootstrap 之后才建的：先把它记进 meta.pre，崩溃后才能重做而不重复
      if (!await engine.setMetaPre(pf.name)) {
        _adoptRetry = true;
        return;
      }
      _metaPreFix = false;
    }
    // 进度（a.offset）跨重试保留：读失败 / 提交失败 / 抛异常后 5 s 接着来，不重复写已收编的记录；钩子每条记录现取
    final a = _adopter ??= Adopter(writer, () => _redact, _report);
    while (true) {
      while (pf.length - a.offset > adoptSliceBytes) {
        final chunk = pf.readFrom(a.offset, adoptSliceBytes);
        if (chunk == null) {
          _adoptRetry = true;
          return;
        }
        final cut = _lastNewline(chunk, adoptSliceBytes);
        // 一片里没有完整记录（坏文件里的超长行）：退回读剩余全部
        if (cut <= 0) break;
        a.feed(Uint8List.sublistView(chunk, 0, cut), a.offset);
        if (a.stalled) return;
        await Future<void>.delayed(Duration.zero);
        if (!identical(writer.adoptingFile, pf)) return;
      }
      final data = pf.readFrom(a.offset);
      if (data == null) {
        _adoptRetry = true;
        return;
      }
      a.feed(data, a.offset);
      // 收编中途会话目录消失：停在这里，handleVanished 重建会话后从偏移 0 重新收编进新会话
      if (a.stalled) return;
      final r = writer.commitAdoption(pf, () => a.offset, (tail) {
        if (a.hasUnredacted(tail)) return false;
        a.feed(tail, a.offset, allowRedact: false);
        return !a.stalled;
      });
      if (a.stalled) return;
      if (r == Commit.done) break;
      if (r == Commit.failed) {
        _adoptRetry = true;
        return;
      }
      await Future<void>.delayed(Duration.zero);
    }
    _adopter = null;
    _adoptRetry = false;
    engine.adoptPre = null;
    final c = engine.current;
    if (c != null) await engine.clearMetaPre(c);
    _emitDropped();
  }

  static int _lastNewline(Uint8List d, int limit) {
    final end = d.length < limit ? d.length : limit;
    for (var i = end - 1; i >= 0; i--) {
      if (d[i] == 0x0A) return i + 1;
    }
    return 0;
  }

  Future<void> _startup() async {
    await engine.removePurgeLeftovers();
    if (!_bootstrapped) {
      // 没建成会话：定时重试（不只靠宿主再写一行）
      await reschedule();
      return;
    }
    await engine.scanOutboxAtStartup();
    await engine.adoptOrphans(_redact, _report);
    await engine.recoverOldSessions();
    final prev = engine.previousAppVersion;
    await engine.releaseQuarantine(prev != null && prev != engine.device.appVersion);
    // 收编出的封段（fatal 立即换段、满段、用户边界）在提交之后才物化
    await engine.processSeals();
    await engine.flushTombstones();
    await engine.evictIfNeeded();
    kickDrain();
    fetchConfig();
    await reschedule();
  }

  // MARK: 宿主 API

  /// 记一行。没落盘的行（没有会话、写 pre 失败、内部异常）计数，之后以 `rtv.pre_init_dropped` 上报（ADR 0024 决定 1）。
  /// `ts`：适配器给的事件时刻（logger 的 `LogEvent.time`）；null = 现在。
  void log(
    LogLevel level,
    String msg,
    String? tag,
    Map<String, Object?>? attrs,
    Object? error,
    StackTrace? stackTrace, {
    int? ts,
  }) {
    if (Reentrancy.active) return;
    Reentrancy.active = true;
    final handled = _Handled();
    try {
      _logInner(level, msg, tag, attrs, error, stackTrace, handled, ts);
    } catch (e) {
      if (!handled.v && writer.isEnabled) DropCounter.add(level, clock.wallMs());
      _report(e);
    } finally {
      Reentrancy.active = false;
    }
  }

  void _logInner(
    LogLevel level,
    String msg,
    String? tag,
    Map<String, Object?>? attrs,
    Object? error,
    StackTrace? stackTrace,
    _Handled handled,
    int? tsOverride,
  ) {
    if (!writer.accepts(level)) {
      handled.v = true;
      return;
    }
    if (!_bootstrapped) _retryBootstrap();
    final ts = tsOverride ?? clock.wallMs();
    final exc = error == null ? null : LineEncoder.exception(error, stackTrace);
    var line = LogLine(ts: ts, level: level, msg: msg, tag: tag, attrs: attrs, exc: exc?.$1);
    final r = _redact;
    if (r != null) {
      // 钩子抛异常：该行丢弃（宁丢不漏 PII），异常走内部出口；返回 null = 宿主丢弃。都不计数
      LogLine? out;
      try {
        out = r(line);
      } catch (e) {
        handled.v = true;
        _report(e);
        return;
      }
      if (out == null) {
        handled.v = true;
        return;
      }
      // redact 不能改 ts（ADR 0024 决定 10）
      line = out.copyWith(ts: ts);
      if (!writer.accepts(line.level)) {
        handled.v = true;
        return;
      }
    }
    final enc = LineEncoder.encode(line, forceTruncated: exc?.$2 == true);
    final out = writer.append(line.level, enc.body);
    handled.v = true;
    if (out.noSession) DropCounter.add(line.level, ts);
    if (out.fatal) {
      // fatal：调用方只写行与换段，封段物化投递到引擎队列、不等待（ADR 0020 决定 1）。只落盘不尝试上传。
      // Flutter 不在调用处排后台作业（Dart 不能同步调原生；v3 §1 §8），进程死后由下次启动的恢复兜底。
      workAsync(engine.processSeals);
      return;
    }
    _afterAppend(out);
  }

  /// 写入后的跟进：封了段 → 物化排空；期限变了 → 重排定时器；有待落盘的墓碑 → 1 s 后落盘。
  void _afterAppend(WriteOutcome out) {
    if (out.rotated) {
      workAsync(afterSeal);
    } else if (out.deadlineChanged) {
      workAsync(reschedule);
    }
    if (out.tombstone && !_tombstoneScheduled && !_closed) {
      _tombstoneScheduled = true;
      _tombstoneTimer = Timer(const Duration(seconds: 1), () {
        _guardSync(() {
          _tombstoneTimer = null;
          workAsync(() async {
            _tombstoneScheduled = false;
            await engine.flushTombstones();
          });
        });
      });
    }
  }

  /// SDK 自己的合成 warn（不经 redact；收编中进 pre 文件）。
  void _syntheticWarnNow(String msg, String tag, Map<String, Object?>? attrs) {
    final enc = LineEncoder.encode(
      LogLine(ts: clock.wallMs(), level: LogLevel.warn, msg: msg, tag: tag, attrs: attrs),
      synthetic: true,
    );
    _afterAppend(writer.append(LogLevel.warn, enc.body));
  }

  /// 有可写的会话了：把没落盘的行的计数写成一条合成 warn `rtv.pre_init_dropped` 并清零（ADR 0024 决定 1）。禁用时不写。
  void _emitDropped() {
    if (!writer.isEnabled || writer.isAdopting || !writer.hasSession) return;
    final s = DropCounter.take();
    if (s == null) return;
    final attrs = <String, Object?>{
      'count': s.count,
      'error_count': s.errorCount,
      'first_ts': s.firstTs,
      'last_ts': s.lastTs,
    };
    final enc = LineEncoder.encode(
      LogLine(ts: clock.wallMs(), level: LogLevel.warn, msg: DropCounter.msg, tag: DropCounter.tag, attrs: attrs),
      synthetic: true,
    );
    // 强制写入、强制义务（不受 local_level / upload_level 影响，像 flush 标记；不因它按大小换段）
    final out = writer.appendForced(LogLevel.warn, enc.body);
    if (out.noSession || (!out.written && !out.tombstone)) {
      DropCounter.putBack(s);
      return;
    }
    _afterAppend(out);
  }

  /// 登录 / 登出：值变化即封段；身份变了 → 配置缓存按过期处理并立即按新身份重拉（ADR 0019 决定 12）。
  void setUser(String? id) {
    _safely(() {
      final u = Text.sanitizeUserId(id);
      final ch = writer.setUser(u);
      if (ch.rotated) workAsync(afterSeal);
      if (ch.changed) {
        workAsync(() async {
          if ((await engine.identityChanged()).sealed) kickDrain();
        });
        fetchConfig(refetch: true);
      }
    });
  }

  /// 「上报问题」：向当前段追加合成行（error / tag rtv.flush / synthetic），立即封段并排空。15 s 内被 2xx 确认 → stored；
  /// 否则 pending(offline | backoff | paused | timeout | disabled)。Future 必完成：兜底计时器先排上。
  Future<FlushResult> flush(bool includeContext) {
    final once = _FlushOnce();
    try {
      _armFlushTimer(once);
      if (!writer.isEnabled) {
        once.resume(FlushResult.pending('disabled'));
        return once.future;
      }
      if (writer.isAdopting) {
        // 标记行要排在收编出的行之后：收编是引擎队列上的第一件事，排在它后面
        workAsync(() async => _flushMarked(once, includeContext));
        return once.future;
      }
      _flushMarked(once, includeContext);
    } catch (e) {
      _report(e);
      once.resume(FlushResult.pending('timeout'));
    }
    return once.future;
  }

  void _armFlushTimer(_FlushOnce once) {
    if (_closed) {
      once.resume(FlushResult.pending('timeout'));
      return;
    }
    _openFlushes.add(once);
    once.timer = Timer(Duration(milliseconds: _flushWindowMs), () {
      _openFlushes.remove(once);
      once.resume(FlushResult.pending('timeout'));
    });
    once.future.whenComplete(() => _openFlushes.remove(once)).ignore();
  }

  void _flushMarked(_FlushOnce once, bool includeContext) {
    try {
      if (!writer.isEnabled) {
        once.resume(FlushResult.pending('disabled'));
        return;
      }
      // 收编还没提交（读失败 / 提交失败等着重试）：标记行不能越过还没收编的行直接写进会话
      if (writer.isAdopting) {
        once.resume(FlushResult.pending('timeout'));
        return;
      }
      final enc = LineEncoder.encode(
        LogLine(ts: clock.wallMs(), level: LogLevel.error, msg: 'flush', tag: 'rtv.flush'),
        synthetic: true,
      );
      final mark = writer.appendFlushMarker(enc.body, !includeContext);
      if (mark == null) {
        once.resume(FlushResult.pending(writer.isEnabled ? 'timeout' : 'disabled'));
        return;
      }
      final key = '${mark.sessionId}:${mark.oseq}';
      final g = _flushGroups[key];
      if (g != null) {
        final done = g.result;
        if (done != null) {
          once.resume(done);
        } else {
          g.waiters.add(once);
        }
        return;
      }
      _flushGroups[key] = _FlushGroup()..waiters.add(once);
      final window = _flushWindowMs;
      _queue.detach(() async {
        FlushResult r = FlushResult.pending('timeout');
        try {
          await onWork(engine.processSeals);
          r = await _flushWait(mark.sessionId, mark.oseq, window);
        } catch (e) {
          _report(e);
        } finally {
          _resolveFlush(key, mark, r);
        }
      }, _report);
    } catch (e) {
      _report(e);
      once.resume(FlushResult.pending('timeout'));
    }
  }

  void _resolveFlush(String key, FlushMark mark, FlushResult r) {
    final g = _flushGroups.remove(key);
    g?.result = r;
    writer.clearFlushMarker(mark.sessionId, mark.oseq);
    for (final w in g?.waiters ?? const <_FlushOnce>[]) {
      w.resume(r);
    }
  }

  Future<FlushResult> _flushWait(String sid, int marker, int window) async {
    final deadline = clock.monoMs() + window;
    while (true) {
      if (!writer.isEnabled) return FlushResult.pending('disabled');
      await drainNow();
      if (await onWork(() => engine.isAcked(sid, marker))) return FlushResult.stored;
      if (!writer.isEnabled) return FlushResult.pending('disabled');
      final reason = _lastStopReason;
      final wake = _lastStopWake;
      final now = clock.monoMs();
      if (now < deadline &&
          _waitable.contains(reason) &&
          wake != null &&
          wake <= deadline &&
          !(_stopRequested || _closed)) {
        await clock.sleep(wake - now < 0 ? 0 : wake - now);
        continue;
      }
      return FlushResult.pending(flushReason(reason));
    }
  }

  /// 生效的上传 / 本地级别（远程配置钳制后；适配器早过滤用）。
  (LogLevel, LogLevel) get effectiveLevels => writer.levels;

  /// 用户同意 / 撤回（ADR 0020 决定 2）：先改本进程内存开关（写入立即停 / 恢复），落盘在引擎队列上。
  void setEnabled(bool enabled) {
    _safely(() {
      requestedEnabled = enabled;
      markerUnknown = false;
      writer.setEnabled(enabled);
      workAsync(_persistEnabled);
    });
  }

  bool get isEnabled => writer.isEnabled;

  /// 引擎队列：把内存开关的当前值落到盘上（连着调几次只按最后一次的值落盘）。
  Future<void> _persistEnabled() async {
    if (writer.isEnabled) {
      final marked = await engine.disabledMarked();
      if (!await engine.clearDisabledMarker()) {
        // 标记删不掉：保持禁用（宁可不传，也不误传）
        writer.setEnabled(false);
        engine.enabled = false;
        return;
      }
      final was = engine.enabled && !marked;
      engine.enabled = true;
      if (!was) {
        kickDrain();
        fetchConfig();
      }
      _emitDropped();
    } else {
      engine.enabled = false;
      await engine.markDisabled();
      // 在跑的作业不取消：它的排空在下一次选批时停在 disabled
      if (!_jobRunning) {
        try {
          await platform
              .cancelUploadJob(jobId)
              .timeout(const Duration(milliseconds: ClientConstants.channelCallTimeoutMs));
        } catch (_) {}
      }
    }
    await reschedule();
  }

  /// 清空本地（ADR 0019 决定 9 / ADR 0020 决定 1）：只取消在途请求并置「清空中」，删除与重建投递到引擎队列；
  /// 返回的 Future 在清完之后完成（此时 installId 已是新值）。不碰禁用标记、不清用户。
  Future<void> purgeLocal() {
    _purging += 1;
    final done = Completer<void>();
    try {
      _cancelEpoch += 1;
      transport.cancelAll();
      if (_closed) throw StateError('client closed');
      _queue
          .run(() async {
            try {
              await _purgeNow();
            } catch (e) {
              _report(e);
            } finally {
              _purging -= 1;
              // 新 install 的配置：有在途请求也要在它结束后再拉一次
              fetchConfig(refetch: true);
              if (!done.isCompleted) done.complete();
            }
          })
          .catchError((Object e) {
            _report(e);
          });
    } catch (e) {
      _report(e);
      _purging -= 1;
      if (!done.isCompleted) done.complete();
    }
    return done.future;
  }

  /// 引擎队列：root 先改名移走，bootstrap 新 root（新 install_id，写入切到新会话），最后才删移走的旧 root。
  Future<void> _purgeNow() async {
    writer.abortAdoption()?.unlinkAndClose();
    _adopter = null;
    engine.adoptPre = null;
    _metaPreFix = false;
    // 清空也清零没落盘的行的计数（它们属于被清掉的本地数据）
    DropCounter.reset();
    _adoptRetry = false;
    engine.releaseUploadLock();
    engine.releaseSessionLock();
    engine.locks.close();
    // 先改名再删：一步原子。改名失败时退回逐项删除——原地删之前先放弃当前会话
    final moved = await engine.moveRootAside();
    if (moved == null && await Fs.exists(root)) {
      _report(StateError('purgeLocal: cannot move $root aside; deleting in place'));
      writer.abandonSession();
      for (final name in await Fs.list(root)) {
        await Fs.remove(Fs.join(root, name));
      }
    }
    engine.resetState();
    // bootstrap 里 writer.startSession 关掉旧会话的流、切到新会话
    final ok = await engine.bootstrap();
    // 新 root 没建成：不再往旧会话写（同未 bootstrap 的状态，由 retryBootstrap 重试；期间的行计数），旧状态照删
    if (!ok) writer.abandonSession();
    _bootstrapped = ok;
    _installId = engine.install?.installId;
    _sessionNo = engine.current?.meta.sessionNo ?? 0;
    if (ok) {
      // 新 root 里没有旧会话：恢复算做完（驱逐照常）
      engine.recovered = true;
      await _rejudgeEnabled();
      _emitDropped();
    }
    if (moved != null) await Fs.remove(moved);
  }

  String? get installId => _installId;

  /// install_id 前 8 位 + "-" + session_no。
  String? get supportCode {
    final i = _installId;
    return i == null ? null : '${i.length >= 8 ? i.substring(0, 8) : i}-$_sessionNo';
  }

  // MARK: 再次 configure（身份在首次 configure 定死，简报 §1.3）

  /// 再次 configure：processName 与现有实例不同 → 忽略并留合成 warn `rtv.reconfigure_ignored`，其余参数照常生效。
  /// 同参数 → 只更新 redact。否则宿主调用里同步更新宿主默认并重算生效级别；key / baseUrl / 排空 / 重拉配置在引擎队列。
  void reconfigure(String key, String baseUrl, RetrieverOptions options, String resolvedProcessName) {
    _safely(() {
      _redact = options.redact;
      if (resolvedProcessName != processName) {
        _syntheticWarnNow(reconfigureIgnoredMsg, reconfigureIgnoredTag, const {'field': 'process_name'});
      }
      final host = HostDefaults.of(options);
      if (key == _cfgKey &&
          baseUrl == _cfgBaseUrl &&
          host == writer.host &&
          options.sdkVersion == _cfgSdkVersion &&
          options.jobId == jobId) {
        return;
      }
      _cfgKey = key;
      _cfgBaseUrl = baseUrl;
      _cfgSdkVersion = options.sdkVersion;
      jobId = options.jobId;
      writer.host = host;
      workAsync(() async {
        await engine.applyIdentity(key, baseUrl);
        engine.sdkVersion = options.sdkVersion;
        await engine.applyEffective();
        engine.lastConfigFetchMono = null;
        kickDrain();
        // 在途请求带的是旧宿主默认 / 旧 key：它回来时按身份不符丢弃并重拉
        fetchConfig(refetch: true);
        await reschedule();
      });
    });
  }

  void _retryBootstrap() {
    final now = clock.monoMs();
    if (_bootstrapped || _closed || now < _nextBootstrapMono) return;
    _nextBootstrapMono = now + ClientConstants.adoptRetryMs;
    workAsync(() async {
      if (_bootstrapped) return;
      final ok = await engine.bootstrap();
      _bootstrapped = ok;
      _installId = engine.install?.installId;
      _sessionNo = engine.current?.meta.sessionNo ?? 0;
      if (ok) {
        await _afterRebootstrap();
      } else {
        await reschedule();
      }
    });
  }

  /// bootstrap 失败之后重试成功（或目录消失后重建成功）：重判开关、补写合成行、收编、startup。
  Future<void> _afterRebootstrap() async {
    await _rejudgeEnabled();
    if (_vanishedWarnPending) {
      _vanishedWarnPending = false;
      _syntheticWarnNow(rootVanishedMsg, rootVanishedTag, null);
    }
    await _adoptOwnPreSafely();
    _emitDropped();
    await _startup();
  }

  // MARK: 目录在运行中消失（简报 §4.5）

  void _scheduleVanished() {
    if (_vanishScheduled || _closed) return;
    _vanishScheduled = true;
    workAsync(_handleVanished);
  }

  /// 会话目录 / root 在运行中消失：引擎队列上重新 bootstrap（新会话），写合成 warn `rtv.root_vanished`；
  /// 期间的行（没有会话）计数，重建后随 `rtv.pre_init_dropped` 上报。
  Future<void> _handleVanished() async {
    _vanishScheduled = false;
    final cur = engine.current;
    if (cur != null && await Fs.isDirectory(cur.dir) && writer.hasSession && await Fs.isDirectory(root)) return;
    // 写进旧会话（已被删的 inode）的行：当前 .open 段与待封段，按段计数。收编中：pre 文件提交前完整 → 新会话从偏移 0 重新收编
    for (final seg in writer.takeLostSegments()) {
      DropCounter.putBack(DropSnapshot(seg.lineCount, seg.errorLines, seg.firstTs, seg.lastTs));
    }
    if (writer.isAdopting) {
      _adopter = null;
      writer.resetSessionUserForReadoption();
    }
    writer.abandonSession();
    engine.releaseUploadLock();
    engine.releaseSessionLock();
    engine.locks.close();
    engine.resetState();
    _vanishedWarnPending = true;
    final ok = await engine.bootstrap();
    _bootstrapped = ok;
    _installId = engine.install?.installId;
    _sessionNo = engine.current?.meta.sessionNo ?? 0;
    if (!ok) {
      writer.abandonSession();
      _nextBootstrapMono = clock.monoMs() + ClientConstants.adoptRetryMs;
      await reschedule();
      return;
    }
    await _afterRebootstrap();
  }

  // MARK: 生命周期（v3 §3 ← 方向的事件）

  void didEnterBackground(int? bgTaskId) => _safely(() => _enterBackground(bgTaskId));

  void willEnterForeground() {
    _safely(() {
      _foreground = true;
      _stopRequested = false;
      workAsync(() async {
        await engine.setLastState('fg');
        await engine.applyEffective();
        if (engine.effective.expired || engine.configPollDue(clock.monoMs())) fetchConfig();
        kickDrain();
        await reschedule();
      });
    });
  }

  /// 只改 last_state、不封段（对位 iOS 0.3.0）。
  void foregroundStateChanged(bool fg) {
    _safely(() {
      _foreground = fg;
      workAsync(() => engine.setLastState(fg ? 'fg' : 'bg'));
    });
  }

  /// 后台时间到期（原生 handler 内已先 end）：挡住排空、取消在途请求（不删批、不计毒批）。
  void backgroundTaskExpired(int id) {
    _safely(() {
      _stopRequested = true;
      _cancelEpoch += 1;
      transport.cancelAll();
      workAsync(() async => engine.releaseUploadLock());
    });
  }

  /// 只用于提前唤醒（不做可达性预检）：清掉退避等待，暂停（401 / 429）不动。
  void networkRestored() {
    _safely(() {
      workAsync(() async {
        engine.backoff.nextAtMonoMs = 0;
        engine.backoff.nextAtWallMs = 0;
        kickDrain();
      });
    });
  }

  /// 进后台：封段（段内有义务行）+ 排空；出站箱有待传批时排一个一次性后台作业兜底。禁用时不排作业。
  void _enterBackground(int? bgTaskId) {
    _foreground = false;
    _stopRequested = false;
    writer.rotate(SealReason.background, onlyIfObligation: true);
    workAsync(() async {
      await engine.setLastState('bg');
      await engine.processSeals();
      if (await engine.hasUploadWork()) await _scheduleJob();
    });
    _queue.detach(() async {
      try {
        await drainPatiently(backgroundBudgetMs);
        await onWork(() async => engine.releaseUploadLock());
      } finally {
        if (bgTaskId != null) {
          try {
            await platform
                .endBackgroundTask(bgTaskId)
                .timeout(const Duration(milliseconds: ClientConstants.channelCallTimeoutMs));
          } catch (_) {}
        }
      }
    }, _report);
  }

  /// 排后台作业；同 id 是别人的作业或系统拒绝 → 不替换，只记一次诊断（ADR 0024 决定 11）。
  Future<void> _scheduleJob() async {
    final id = jobId;
    var ok = false;
    try {
      ok = await platform
          .scheduleUploadJob(id)
          .timeout(const Duration(milliseconds: ClientConstants.channelCallTimeoutMs));
    } catch (_) {
      ok = false;
    }
    if (ok) return;
    if (_jobConflictReported) return;
    _jobConflictReported = true;
    _report(StateError('upload job $id not scheduled: id held by another component or rejected by the system'));
  }

  /// 后台作业：排空出站箱（拿 upload.lock，不与在途重复），返回是否需要系统按退避重排。
  Future<bool> runUploadJob(int budgetMs) async {
    _jobRunning = true;
    _stopRequested = false;
    var reschedule = false;
    try {
      await drainPatiently(budgetMs);
      reschedule = await onWork(() async {
        engine.releaseUploadLock();
        return await engine.hasUploadWork() && _jobRetryReasons.contains(_lastStopReason);
      });
    } catch (e) {
      _report(e);
    } finally {
      // 停止标志只对当次作业的排空生效（ADR 0020 决定 6）
      _jobRunning = false;
      _stopRequested = false;
    }
    return reschedule;
  }

  /// 系统停止作业：挡住当次作业的排空、取消在途请求；作业已经结束时（迟到的回调）什么都不做。
  void stopUploadJob() {
    _safely(() {
      if (!_jobRunning) return;
      _stopRequested = true;
      _cancelEpoch += 1;
      transport.cancelAll();
      workAsync(() async => engine.releaseUploadLock());
    });
  }

  // MARK: 排空

  Future<void> afterSeal() async {
    if (await engine.processSeals()) kickDrain();
    await reschedule();
  }

  void kickDrain() {
    if (_closed) return;
    if (_draining) {
      _rekick = true;
      return;
    }
    _draining = true;
    _startDrainLoop();
  }

  void _startDrainLoop() {
    _queue.detach(_drainLoopSafe, _report);
  }

  /// 触发一次排空并等它结束（已在排空则等下一轮结束）。
  Future<void> drainNow() {
    if (_closed) return Future<void>.value();
    final c = Completer<void>();
    _drainWaiters.add(c);
    if (_draining) {
      _rekick = true;
    } else {
      _draining = true;
      _startDrainLoop();
    }
    return c.future;
  }

  /// 排空直到出站箱无可发的批、或被暂停 / 退避挡住；相邻请求间隔（2 s）就地等待，最长 budgetMs。
  Future<void> drainPatiently(int budgetMs) async {
    final deadline = clock.monoMs() + budgetMs;
    while (true) {
      await drainNow();
      final reason = _lastStopReason;
      final wake = _lastStopWake;
      if (reason != 'spacing' || wake == null || wake > deadline || _stopRequested || _closed) return;
      final w = wake - clock.monoMs();
      await clock.sleep(w < 0 ? 0 : w);
    }
  }

  Future<void> _drainLoopSafe() async {
    try {
      await _drainLoop();
    } catch (e) {
      _report(e);
      try {
        await onWork(() async => engine.releaseUploadLock());
      } catch (e2) {
        _report(e2);
      }
      _finishDrain();
    }
  }

  void _finishDrain() {
    _rekick = false;
    _draining = false;
    final w = List<Completer<void>>.of(_drainWaiters);
    _drainWaiters.clear();
    for (final c in w) {
      if (!c.isCompleted) c.complete();
    }
  }

  Future<void> _drainLoop() async {
    while (true) {
      while (true) {
        final halt = _purging > 0 ? 'purging' : (_stopRequested ? 'background_expired' : null);
        if (halt != null) {
          _lastStopReason = halt;
          _lastStopWake = null;
          break;
        }
        if (_closed) {
          _lastStopReason = 'closed';
          _lastStopWake = null;
          break;
        }
        final step = await onWork(engine.nextSend);
        if (step is SendStop) {
          _lastStopReason = step.reason;
          _lastStopWake = step.wakeMono;
          break;
        }
        final send = step as SendNow;
        if (_purging > 0) {
          // 取批之后、发出之前清空开始了：这一批要随 root 一起清掉，不发
          await onWork(() async {
            if (engine.inFlight == send.name) engine.inFlight = null;
          });
          _lastStopReason = 'purging';
          _lastStopWake = null;
          break;
        }
        final epoch = _cancelEpoch;
        TransportResponse? resp;
        try {
          resp = await transport.send(send.request);
        } catch (_) {
          resp = null;
        }
        final cancelled = resp == null && _cancelEpoch != epoch;
        final eff = await onWork(
          () => engine.handleResponse(
            send.name,
            resp,
            sentKeyFp: send.keyFp,
            sentBaseUrl: send.baseUrl,
            cancelledBySdk: cancelled,
          ),
        );
        // 进入鉴权暂停：引擎队列外、出 `key_rejected`（出口抛什么都吞掉）
        final kr = eff.keyRejected;
        if (kr != null) {
          try {
            onKeyRejected?.call(kr);
          } catch (_) {}
        }
        if (eff.fetchConfig) fetchConfig();
      }
      await onWork(() async {
        engine.releaseUploadLock();
        await reschedule();
      });
      final again = _rekick && !_stopRequested && _purging == 0 && !_closed;
      if (again) {
        _rekick = false;
        continue;
      }
      _finishDrain();
      return;
    }
  }

  // MARK: 配置

  /// 拉配置（同一时刻最多一个在途）。`refetch`：身份变了——有在途请求时置「待重拉」，在途结束后再拉一次。
  /// 禁用时 configRequest 返回 null，不联网。清空进行中不拉（清空做完时会再调一次）。
  void fetchConfig({bool refetch = false}) {
    if (_closed || _purging > 0) return;
    if (_configFetching) {
      if (refetch) _configRefetch = true;
      return;
    }
    _configFetching = true;
    _queue.detach(() async {
      var again = false;
      try {
        final fetch = await onWork(engine.configRequest);
        if (fetch != null) {
          TransportResponse? resp;
          try {
            resp = await transport.send(fetch.request);
          } catch (_) {
            resp = null;
          }
          final eff = await onWork(() => engine.applyConfigResponse(fetch, resp));
          if (eff.sealed) kickDrain();
          again = eff.stale;
        } else {
          await onWork(() async => engine.lastConfigFetchMono = clock.monoMs());
        }
      } catch (e) {
        _report(e);
      } finally {
        _configFetching = false;
        final r = (again || _configRefetch) && _purging == 0;
        _configRefetch = false;
        if (r) {
          fetchConfig();
        } else {
          workAsync(reschedule);
        }
      }
    }, _report);
  }

  // MARK: 调度（离线 / 退避时真正睡眠，不空转）

  Future<void> reschedule() async {
    final nowMono = clock.monoMs();
    final nowWall = clock.wallMs();
    final cands = <int>[];
    final d = writer.nextDeadline;
    if (d != null) cands.add(d);
    final u = await engine.uploadWakeMono();
    if (u != null) cands.add(u);
    if (engine.key.isNotEmpty && engine.enabled) {
      cands.add((engine.lastConfigFetchMono ?? nowMono) + Limits.configPollIntervalS * 1000);
    }
    // 禁用标记没写成：保证 60 s 内有一次 tick 重试
    if (engine.markerPending && !engine.enabled) cands.add(nowMono + ClientConstants.markerRetryMs);
    // 标记判定未知 / 段读失败没推进：定时重试；收编没做完：5 s 后重试
    if (markerUnknown || engine.readRetryPending) cands.add(nowMono + ClientConstants.retryMs);
    if (_adoptRetry) cands.add(nowMono + ClientConstants.adoptRetryMs);
    // 没建成会话：5 s 后重试
    if (!_bootstrapped) cands.add(_nextBootstrapMono > nowMono ? _nextBootstrapMono : nowMono);
    // 恢复旧会话被跳过（拿不到 root 锁）：5 s 后重试
    if (_bootstrapped && !engine.recovered) cands.add(nowMono + ClientConstants.adoptRetryMs);
    final cc = engine.configCache?.nextChangeMono(nowWall, nowMono);
    if (cc != null) cands.add(cc);
    final q = await engine.nextQuarantineReleaseMono();
    if (q != null) cands.add(q);
    int? next;
    for (final c in cands) {
      if (next == null || c < next) next = c;
    }
    if (_closed) return;
    if (_timerTarget == next && _timer != null) return;
    _timer?.cancel();
    _timer = null;
    _timerTarget = next;
    if (next == null) return;
    final delay = clock.timerDelayMs(schedulerDelayMs(next, nowMono));
    if (delay == null) return;
    _timer = Timer(Duration(milliseconds: delay), () {
      _guardSync(() => workAsync(tick));
    });
  }

  Future<void> tick() async {
    _timer?.cancel();
    _timer = null;
    _timerTarget = null;
    // 没建成会话：重试 bootstrap（成功后照常 afterRebootstrap / startup）
    if (!_bootstrapped) {
      _retryBootstrap();
      await reschedule();
      return;
    }
    // 恢复旧会话上次被跳过：重试，做完再按上限驱逐
    if (!engine.recovered) {
      await engine.recoverOldSessions();
      if (engine.recovered) await engine.evictIfNeeded();
    }
    // 禁用标记判定未知（宿主没显式设过）：重判（ADR 0024 决定 6）
    if (markerUnknown && requestedEnabled == null) {
      await _rejudgeEnabled();
      if (writer.isEnabled) _emitDropped();
    }
    // 禁用标记上次没写成：每次 tick 重试
    if (engine.markerPending && !engine.enabled) await engine.markDisabled();
    if (_adoptRetry && writer.isAdopting) {
      await _adoptOwnPreSafely();
      if (!writer.isAdopting) await engine.processSeals();
    }
    if (engine.readRetryPending) await engine.retryBacklog();
    // 内部异常等没落盘的行：定时唤醒时补报
    if (DropCounter.pending > 0) _emitDropped();
    if (writer.checkDeadlines()) await engine.processSeals();
    await engine.applyEffective();
    await engine.releaseQuarantine(false);
    if (engine.configPollDue(clock.monoMs())) fetchConfig();
    kickDrain();
    await reschedule();
  }

  // MARK: 队列工具

  /// 在引擎队列上执行并等结果（已在队列里则直接执行）。只给 SDK 自己的后台任务与测试用，宿主调用的入口一律不用它。
  Future<T> onWork<T>(FutureOr<T> Function() body) {
    if (_queue.inQueue) return Future<T>.sync(body);
    return _queue.run(body);
  }

  void workAsync(FutureOr<void> Function() body) {
    if (_closed) return;
    _queue.run(body).catchError((Object e) {
      _report(e);
    });
  }

  void _guardSync(void Function() body) {
    try {
      body();
    } catch (e) {
      _report(e);
    }
  }

  void _safely(void Function() body) => _guardSync(body);

  void _report(Object e) {
    try {
      onInternalError?.call(e);
    } catch (_) {
      // 出口本身失败：吞掉
    }
  }

  // MARK: 测试 / 诊断

  /// 等后台工作（引擎队列、排空、配置拉取）全部落定。
  Future<void> settle() async {
    for (var i = 0; i < 2000; i++) {
      await onWork(() {});
      if (!_draining && !_configFetching && _queue.idle) {
        await onWork(() {});
        await Future<void>.delayed(Duration.zero);
        if (!_draining && !_configFetching && _queue.idle) return;
      }
      if (_draining) {
        await drainNow();
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }
  }

  /// 测试：推进假时钟后手动触发一次定时器。
  Future<void> tickNow() async {
    await onWork(tick);
    await settle();
  }

  void _shutdown() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    _tombstoneTimer?.cancel();
    _tombstoneTimer = null;
    for (final f in _openFlushes.toList()) {
      f.resume(FlushResult.pending('timeout'));
    }
    _openFlushes.clear();
  }

  /// 测试：模拟进程死亡（不封段、不收尾；关流、放会话锁与根锁与 pre 文件的锁、停调度）。同 root 的新实例会把它当孤儿恢复。
  Future<void> simulateCrash() async {
    _shutdown();
    await _queue.run(() async {
      writer.adoptingFile?.close();
      writer.abandonSession();
      engine.releaseUploadLock();
      engine.releaseSessionLock();
      engine.locks.close();
    });
    transport.cancelAll();
    _finishDrain();
  }

  /// 测试：停掉（不收尾）。
  Future<void> closeForTesting() async {
    _shutdown();
    try {
      await _queue
          .run(() async {
            writer.adoptingFile?.close();
            writer.abandonSession();
            engine.releaseUploadLock();
            engine.releaseSessionLock();
            engine.locks.close();
          })
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // 已停
    }
    transport.cancelAll();
    _finishDrain();
  }

  bool get isClosed => _closed;

  void setFlushWindowForTesting(int ms) => _flushWindowMs = ms;

  (String, int?) get lastStop => (_lastStopReason, _lastStopWake);

  (int, int) get debugCounters {
    final s = writer.snapshot;
    return (s.seq, s.oseq);
  }

  String? get debugOpenSegmentFile => writer.currentSegmentPath;

  bool get isBootstrapped => _bootstrapped;

  bool get isDraining => _draining;

  /// 当前是否在引擎队列的任务里（测试断言「诊断不在引擎队列上出」用）。
  bool get inEngineQueue => _queue.inQueue;

  bool get adoptRetryPending => _adoptRetry;

  /// 定时器延迟 = max(next − now, 1 s)：候选已到期也不以 0 ms 自旋。
  static int schedulerDelayMs(int next, int nowMono) {
    final d = next - nowMono;
    return d > ClientConstants.schedulerMinDelayMs ? d : ClientConstants.schedulerMinDelayMs;
  }

  /// 排空停下的原因 → flush 的 Pending 原因（不新增公开原因值；三端逐字一致）。
  static String flushReason(String stop) {
    switch (stop) {
      case 'offline':
        return 'offline';
      case 'backoff':
        return 'backoff';
      case 'disabled':
        return 'disabled';
      case 'paused':
      case 'upload_disabled':
      case 'not_configured':
      case 'locked':
        return 'paused';
      default:
        return 'timeout';
    }
  }
}
