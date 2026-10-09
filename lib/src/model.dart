// 本地状态文件与信封的数据模型（§3.2 / §3.5 / §3.6；字段名与顺序取 packages/core/src/envelope.ts，
// 与 iOS Model.swift / Android Model.kt 逐字一致）。对位 Android `core/Model.kt`。

import 'dart:io';
import 'dart:typed_data';

import 'ids.dart';
import 'json.dart';
import 'limits.dart';
import 'public_api.dart';
import 'text.dart';

/// 级别序与线上值（不进公开面）。
extension LogLevelWire on LogLevel {
  int get rank => index;

  String get wire => name;
}

abstract final class LogLevels {
  static LogLevel ofRank(int r) => LogLevel.values[r < 0 ? 0 : (r > 4 ? 4 : r)];

  static LogLevel? ofWire(String? s) {
    if (s == null) return null;
    for (final l in LogLevel.values) {
      if (l.name == s) return l;
    }
    return null;
  }
}

/// 级别序（debug < info < warn < error < fatal）；线上值 lower_snake。
abstract final class Level {
  static const int debug = 0;
  static const int info = 1;
  static const int warn = 2;
  static const int error = 3;
  static const int fatal = 4;
  static const List<String> wireNames = ['debug', 'info', 'warn', 'error', 'fatal'];

  static int rankOf(String wire) => wireNames.indexOf(wire);
}

/// 设备快照（进 meta.json 与信封 device；每个字段 ≤ 128 B）。
class Device {
  const Device(this.os, this.osVersion, this.model, this.appVersion, this.build, this.locale, this.sdk);

  final String os;
  final String osVersion;
  final String model;
  final String appVersion;
  final String build;
  final String locale;
  final String sdk;

  /// 从垫片给的字段表（v3 §3 `device`）建；缺的字段 = 空串。
  factory Device.fromFields(Map<String, String>? f, String sdk) => Device(
    f?['os'] ?? '',
    f?['os_version'] ?? '',
    f?['model'] ?? '',
    f?['app_version'] ?? '',
    f?['build'] ?? '',
    f?['locale'] ?? '',
    sdk,
  ).sanitized();

  Device sanitized() {
    String t(String s) => Text.truncate(Text.fixSurrogates(s), Limits.deviceFieldBytes).s;
    return Device(t(os), t(osVersion), t(model), t(appVersion), t(build), t(locale), t(sdk));
  }

  void encode(JsonOut o) {
    o.raw('{"os":');
    o.string(os);
    o.raw(',"os_version":');
    o.string(osVersion);
    o.raw(',"model":');
    o.string(model);
    o.raw(',"app_version":');
    o.string(appVersion);
    o.raw(',"build":');
    o.string(build);
    o.raw(',"locale":');
    o.string(locale);
    o.raw(',"sdk":');
    o.string(sdk);
    o.raw('}');
  }

  static Device? decode(Object? v) {
    final d = JsonIn.asObj(v);
    if (d == null) return null;
    String? s(String k) => d[k] is String ? d[k] as String : null;
    final os = s('os'), ov = s('os_version'), m = s('model'), av = s('app_version'), b = s('build');
    final l = s('locale'), sdk = s('sdk');
    if (os == null || ov == null || m == null || av == null || b == null || l == null || sdk == null) return null;
    return Device(os, ov, m, av, b, l, sdk);
  }

  @override
  bool operator ==(Object other) =>
      other is Device &&
      other.os == os &&
      other.osVersion == osVersion &&
      other.model == model &&
      other.appVersion == appVersion &&
      other.build == build &&
      other.locale == locale &&
      other.sdk == sdk;

  @override
  int get hashCode => Object.hash(os, osVersion, model, appVersion, build, locale, sdk);
}

/// install.json：{install_id, session_counter, created_ms}
class InstallInfo {
  InstallInfo(this.installId, this.sessionCounter, this.createdMs);

  final String installId;
  int sessionCounter;
  final int createdMs;

  Uint8List encode() {
    final o = JsonOut();
    o.raw('{"install_id":');
    o.string(installId);
    o.raw(',"session_counter":');
    o.integer(sessionCounter);
    o.raw(',"created_ms":');
    o.integer(createdMs);
    o.raw('}');
    return o.toBytes();
  }

  static InstallInfo? decode(List<int> b) {
    final o = JsonIn.obj(b);
    if (o == null) return null;
    final id = o['install_id'];
    if (id is! String || !Ids.isUuid(id)) return null;
    return InstallInfo(id, JsonIn.int64(o['session_counter']) ?? 0, JsonIn.int64(o['created_ms']) ?? 0);
  }
}

/// meta.json：会话开始时原子写。`install_id`（可选键，ADR 0019 决定 6）= install 身份冗余副本；
/// `pre`（可选键，ADR 0023）= 本会话正在收编的 pre 文件名。
class SessionMeta {
  const SessionMeta(
    this.sessionId,
    this.sessionNo,
    this.startedMs,
    this.device,
    this.process, [
    this.installId,
    this.pre,
    this.token,
  ]);

  final String sessionId;
  final int sessionNo;
  final int startedMs;
  final Device device;
  final String process;
  final String? installId;
  final String? pre;

  /// 写这个会话的进程令牌（Flutter 专有可选键 `token`，垫片 `bootstrap()` 回包的进程级 UUID；切片 2 主代理裁决）。
  /// 启动恢复据此区分「同一进程里 owner 引擎被销毁」（不是崩溃）与「进程死了」；Android / iOS 原生 SDK 不写 = 旧语义。
  final String? token;

  SessionMeta copyWith({Object? pre = _unset, Object? installId = _unset}) => SessionMeta(
    sessionId,
    sessionNo,
    startedMs,
    device,
    process,
    identical(installId, _unset) ? this.installId : installId as String?,
    identical(pre, _unset) ? this.pre : pre as String?,
    token,
  );

  Uint8List encode() {
    final o = JsonOut();
    o.raw('{"session_id":');
    o.string(sessionId);
    o.raw(',"session_no":');
    o.integer(sessionNo);
    o.raw(',"started_ms":');
    o.integer(startedMs);
    o.raw(',"device":');
    device.encode(o);
    o.raw(',"process":');
    o.string(process);
    if (installId != null) {
      o.raw(',"install_id":');
      o.string(installId!);
    }
    if (pre != null) {
      o.raw(',"pre":');
      o.string(pre!);
    }
    if (token != null) {
      o.raw(',"token":');
      o.string(token!);
    }
    o.raw('}');
    return o.toBytes();
  }

  static SessionMeta? decode(List<int> b) {
    final o = JsonIn.obj(b);
    if (o == null) return null;
    final sid = o['session_id'];
    if (sid is! String || !Ids.isUuid(sid)) return null;
    final no = JsonIn.int64(o['session_no']);
    if (no == null || no < 1) return null;
    final dev = Device.decode(o['device']);
    if (dev == null) return null;
    final iidRaw = o['install_id'];
    final iid = iidRaw is String && Ids.isUuid(iidRaw) ? iidRaw : null;
    final preRaw = o['pre'];
    final pre = preRaw is String && isPreName(preRaw) ? preRaw : null;
    final proc = o['process'];
    final tokRaw = o['token'];
    final tok = tokRaw is String && Ids.isUuid(tokRaw) ? tokRaw : null;
    return SessionMeta(sid, no, JsonIn.int64(o['started_ms']) ?? 0, dev, proc is String ? proc : 'main', iid, pre, tok);
  }

  /// pre 文件名（只认这两个形状：meta 里的名字会被拼进路径）：
  /// Android / iOS 的 `<uuid>.jsonl`；Flutter 的 `<token>-<uuid>.jsonl`（token = 垫片给的进程级 UUID，v3 §1）。
  static bool isPreName(String s) {
    if (!s.endsWith('.jsonl')) return false;
    if (s.length == 42) return Ids.isUuid(s.substring(0, 36));
    if (s.length == 79) return Ids.isUuid(s.substring(0, 36)) && s[36] == '-' && Ids.isUuid(s.substring(37, 73));
    return false;
  }
}

/// cursor.json：{extracted_through_oseq, ctx_through_seq, last_state: fg|bg, last_state_ms, closed_ms?}（原子写）。
class Cursor {
  Cursor({this.extractedThroughOseq = 0, this.ctxThroughSeq = 0, this.lastState, this.lastStateMs = 0, this.closedMs});

  int extractedThroughOseq;
  int ctxThroughSeq;
  String? lastState;
  int lastStateMs;
  int? closedMs;

  Cursor copy({int? extractedThroughOseq, int? ctxThroughSeq}) => Cursor(
    extractedThroughOseq: extractedThroughOseq ?? this.extractedThroughOseq,
    ctxThroughSeq: ctxThroughSeq ?? this.ctxThroughSeq,
    lastState: lastState,
    lastStateMs: lastStateMs,
    closedMs: closedMs,
  );

  Uint8List encode() {
    final o = JsonOut();
    o.raw('{"extracted_through_oseq":');
    o.integer(extractedThroughOseq);
    o.raw(',"ctx_through_seq":');
    o.integer(ctxThroughSeq);
    o.raw(',"last_state":');
    o.stringOrNull(lastState);
    o.raw(',"last_state_ms":');
    o.integer(lastStateMs);
    if (closedMs != null) {
      o.raw(',"closed_ms":');
      o.integer(closedMs!);
    }
    o.raw('}');
    return o.toBytes();
  }

  static Cursor? decode(List<int> b) {
    final o = JsonIn.obj(b);
    if (o == null) return null;
    final ls = o['last_state'];
    return Cursor(
      extractedThroughOseq: JsonIn.int64(o['extracted_through_oseq']) ?? 0,
      ctxThroughSeq: JsonIn.int64(o['ctx_through_seq']) ?? 0,
      lastState: ls is String ? ls : null,
      lastStateMs: JsonIn.int64(o['last_state_ms']) ?? 0,
      closedMs: JsonIn.int64(o['closed_ms']),
    );
  }
}

/// 一个段的索引（封段时由写入侧统计；恢复 / 旧会话由读文件重建）。
class SegInfo {
  SegInfo(
    this.segNo,
    this.userId,
    this.startedMs,
    this.path, {
    this.firstSeq = 0,
    this.lastSeq = 0,
    this.firstOseq = 0,
    this.lastOseq = 0,
    this.lineCount = 0,
    this.obligCount = 0,
    this.hasError = false,
    this.bytes = 0,
    this.errorLines = 0,
    this.firstTs = 0,
    this.lastTs = 0,
  });

  final int segNo;
  String? userId;
  final int startedMs;
  String path;
  int firstSeq;
  int lastSeq;
  int firstOseq;
  int lastOseq;
  int lineCount;
  int obligCount;
  bool hasError;
  int bytes;

  /// 写入侧统计：error 及以上的行数、首末 ts——段随目录消失时按它并入没落盘的行计数。
  int errorLines;
  int firstTs;
  int lastTs;

  File get file => File(path);
}

enum SealReason { size, user, background, error, fatal, timer, flush, fullDump, uploadEnabled, shutdown, recovery }

/// 封段任务：写入侧换段时生成，引擎任务里 flush + close + rename + 物化。
/// `out` = 旧段的写句柄（v3 §7：Writer 交给封段任务异步 flush + close；写入侧不再碰它）。
class SealJob {
  SealJob(this.out, this.info, this.reason, this.noCtx, this.seqAtSeal, this.oseqAtSeal);

  final RandomAccessFile? out;
  final SegInfo info;
  final SealReason reason;

  /// flush(includeContext = false)：本次物化不附 ctx。
  final bool noCtx;

  /// 换段时刻的全局 seq / oseq（物化的上界）。
  final int seqAtSeal;
  final int oseqAtSeal;
}

abstract final class DropReason {
  static const String bufferOverflow = 'buffer_overflow';
  static const String writeFailed = 'write_failed';
  static const String corrupt = 'corrupt';
  static const String backfillEvicted = 'backfill_evicted';
  static const String quarantineEvicted = 'quarantine_evicted';
}

/// 墓碑：{session_id, oseq_from, oseq_to, n, reason, at_ms, last_ack_age_ms}（值相等，同 Kotlin data class）。
class DropEntry {
  const DropEntry(this.sessionId, this.oseqFrom, this.oseqTo, this.n, this.reason, this.atMs, this.lastAckAgeMs);

  final String sessionId;
  final int oseqFrom;
  final int oseqTo;
  final int n;
  final String reason;
  final int atMs;
  final int lastAckAgeMs;

  DropEntry copyWith({int? oseqTo, int? n, int? atMs, int? lastAckAgeMs}) => DropEntry(
    sessionId,
    oseqFrom,
    oseqTo ?? this.oseqTo,
    n ?? this.n,
    reason,
    atMs ?? this.atMs,
    lastAckAgeMs ?? this.lastAckAgeMs,
  );

  void encode(JsonOut o) {
    o.raw('{"session_id":');
    o.string(sessionId);
    o.raw(',"oseq_from":');
    o.integer(oseqFrom);
    o.raw(',"oseq_to":');
    o.integer(oseqTo);
    o.raw(',"n":');
    o.integer(n);
    o.raw(',"reason":');
    o.string(reason);
    o.raw(',"at_ms":');
    o.integer(atMs);
    o.raw(',"last_ack_age_ms":');
    o.integer(lastAckAgeMs);
    o.raw('}');
  }

  static DropEntry? decode(Object? v) {
    final o = JsonIn.asObj(v);
    if (o == null) return null;
    final sid = o['session_id'];
    final r = o['reason'];
    if (sid is! String || r is! String) return null;
    final f = JsonIn.int64(o['oseq_from']);
    final t = JsonIn.int64(o['oseq_to']);
    final n = JsonIn.int64(o['n']);
    if (f == null || t == null || n == null) return null;
    return DropEntry(sid, f, t, n, r, JsonIn.int64(o['at_ms']) ?? 0, JsonIn.int64(o['last_ack_age_ms']) ?? -1);
  }

  @override
  bool operator ==(Object other) =>
      other is DropEntry &&
      other.sessionId == sessionId &&
      other.oseqFrom == oseqFrom &&
      other.oseqTo == oseqTo &&
      other.n == n &&
      other.reason == reason &&
      other.atMs == atMs &&
      other.lastAckAgeMs == lastAckAgeMs;

  @override
  int get hashCode => Object.hash(sessionId, oseqFrom, oseqTo, n, reason, atMs, lastAckAgeMs);

  @override
  String toString() => 'DropEntry($sessionId, $oseqFrom..$oseqTo, n=$n, $reason, at=$atMs, age=$lastAckAgeMs)';
}

abstract final class SessionExit {
  static const String cleanBg = 'clean_bg';
  static const String uncleanFg = 'unclean_fg';
  static const String unknown = 'unknown';
}

/// 会话终态：{session_id, session_no, started_ms, ended_ms, last_seq, last_oseq, exit}
class ClosedSession {
  const ClosedSession(
    this.sessionId,
    this.sessionNo,
    this.startedMs,
    this.endedMs,
    this.lastSeq,
    this.lastOseq,
    this.exit,
  );

  final String sessionId;
  final int sessionNo;
  final int startedMs;
  final int endedMs;
  final int lastSeq;
  final int lastOseq;
  final String exit;

  void encode(JsonOut o) {
    o.raw('{"session_id":');
    o.string(sessionId);
    o.raw(',"session_no":');
    o.integer(sessionNo);
    o.raw(',"started_ms":');
    o.integer(startedMs);
    o.raw(',"ended_ms":');
    o.integer(endedMs);
    o.raw(',"last_seq":');
    o.integer(lastSeq);
    o.raw(',"last_oseq":');
    o.integer(lastOseq);
    o.raw(',"exit":');
    o.string(exit);
    o.raw('}');
  }

  static ClosedSession? decode(Object? v) {
    final o = JsonIn.asObj(v);
    if (o == null) return null;
    final sid = o['session_id'];
    final no = JsonIn.int64(o['session_no']);
    final ex = o['exit'];
    if (sid is! String || no == null || ex is! String) return null;
    return ClosedSession(
      sid,
      no,
      JsonIn.int64(o['started_ms']) ?? 0,
      JsonIn.int64(o['ended_ms']) ?? 0,
      JsonIn.int64(o['last_seq']) ?? 0,
      JsonIn.int64(o['last_oseq']) ?? 0,
      ex,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ClosedSession &&
      other.sessionId == sessionId &&
      other.sessionNo == sessionNo &&
      other.startedMs == startedMs &&
      other.endedMs == endedMs &&
      other.lastSeq == lastSeq &&
      other.lastOseq == lastOseq &&
      other.exit == exit;

  @override
  int get hashCode => Object.hash(sessionId, sessionNo, startedMs, endedMs, lastSeq, lastOseq, exit);
}

/// jsonl 文件（drops.jsonl / sessions.jsonl）的编解码（读写在 fs / engine 里）。
abstract final class Jsonl {
  static List<Map<String, Object?>> parse(List<int>? b) {
    if (b == null) return const [];
    final out = <Map<String, Object?>>[];
    var start = 0;
    for (var i = 0; i < b.length; i++) {
      if (b[i] == 0x0A) {
        if (i > start) {
          final o = JsonIn.obj(Uint8List.sublistView(b is Uint8List ? b : Uint8List.fromList(b), start, i));
          if (o != null) out.add(o);
        }
        start = i + 1;
      }
    }
    return out;
  }

  static Uint8List encodeDrops(List<DropEntry> d) {
    final o = JsonOut();
    for (final e in d) {
      e.encode(o);
      o.raw('\n');
    }
    return o.toBytes();
  }

  static Uint8List encodeClosed(List<ClosedSession> c) {
    final o = JsonOut();
    for (final e in c) {
      e.encode(o);
      o.raw('\n');
    }
    return o.toBytes();
  }
}

/// mapping.json：{user_id, device_digest, acked_ms, key_fp?, base_url?}（上次被服务端确认的映射）。
class MappingState {
  const MappingState(this.userId, this.deviceDigest, this.ackedMs, [this.keyFp, this.baseUrl, this.hasIdentity = true]);

  final String? userId;
  final String deviceDigest;
  final int ackedMs;
  final String? keyFp;
  final String? baseUrl;

  /// 文件里有 key_fp / base_url 键（旧版本写的两个都没有 = 视为当前目标）。
  final bool hasIdentity;

  MappingState withIdentity(String fp, String base) => MappingState(userId, deviceDigest, ackedMs, fp, base, true);

  Uint8List encode() {
    final o = JsonOut();
    o.raw('{"user_id":');
    o.stringOrNull(userId);
    o.raw(',"device_digest":');
    o.string(deviceDigest);
    o.raw(',"acked_ms":');
    o.integer(ackedMs);
    o.raw(',"key_fp":');
    o.stringOrNull(keyFp);
    o.raw(',"base_url":');
    o.stringOrNull(baseUrl);
    o.raw('}');
    return o.toBytes();
  }

  static MappingState? decode(List<int> b) {
    final o = JsonIn.obj(b);
    if (o == null) return null;
    final d = o['device_digest'];
    if (d is! String) return null;
    final u = o['user_id'];
    final fp = o['key_fp'];
    final base = o['base_url'];
    return MappingState(
      u is String ? u : null,
      d,
      JsonIn.int64(o['acked_ms']) ?? 0,
      fp is String ? fp : null,
      base is String ? base : null,
      o.containsKey('key_fp') || o.containsKey('base_url'),
    );
  }
}

/// 信封里的 mapping 块。
class MappingBlock {
  const MappingBlock(this.userId, this.device);

  final String? userId;
  final Device device;
}

/// 信封头（lines 之前的全部字段），字段顺序取 envelope.ts 的 Envelope。
class EnvelopeHeader {
  EnvelopeHeader(
    this.kind,
    this.batchId,
    this.createdMs,
    this.day,
    this.installId,
    this.sessionId,
    this.sessionNo,
    this.process,
    this.userId,
    this.device,
    this.seqFrom,
    this.seqTo,
    this.oseqFrom,
    this.oseqTo,
    this.ctxTruncated, {
    this.drops = const [],
    this.closedSessions = const [],
    this.closedSessionsDropped = 0,
    this.mapping,
  });

  final BatchKind kind;
  String batchId;
  final int createdMs;
  String day;
  final String installId;
  final String sessionId;
  final int sessionNo;
  final String process;
  final String? userId;
  final Device device;
  int seqFrom;
  int seqTo;
  int? oseqFrom;
  int? oseqTo;
  int? ctxTruncated;
  List<DropEntry> drops;
  List<ClosedSession> closedSessions;

  /// 0.2.0 起物化不再写（ADR 0019 决定 2）；只为 0.1.x 留在出站箱里的旧批被 413 切分时原样带上。
  int closedSessionsDropped;
  MappingBlock? mapping;

  EnvelopeHeader copy({
    String? batchId,
    String? day,
    int? seqFrom,
    int? seqTo,
    Object? oseqFrom = _unset,
    Object? oseqTo = _unset,
    Object? ctxTruncated = _unset,
    List<DropEntry>? drops,
    List<ClosedSession>? closedSessions,
    int? closedSessionsDropped,
    Object? mapping = _unset,
  }) => EnvelopeHeader(
    kind,
    batchId ?? this.batchId,
    createdMs,
    day ?? this.day,
    installId,
    sessionId,
    sessionNo,
    process,
    userId,
    device,
    seqFrom ?? this.seqFrom,
    seqTo ?? this.seqTo,
    identical(oseqFrom, _unset) ? this.oseqFrom : oseqFrom as int?,
    identical(oseqTo, _unset) ? this.oseqTo : oseqTo as int?,
    identical(ctxTruncated, _unset) ? this.ctxTruncated : ctxTruncated as int?,
    drops: drops ?? this.drops,
    closedSessions: closedSessions ?? this.closedSessions,
    closedSessionsDropped: closedSessionsDropped ?? this.closedSessionsDropped,
    mapping: identical(mapping, _unset) ? this.mapping : mapping as MappingBlock?,
  );

  /// 输出到 `"lines":[` 为止（含）。
  Uint8List encodePrefix() {
    final o = JsonOut(1024);
    o.raw('{"v":1,"kind":');
    o.string(kind.wire);
    o.raw(',"batch_id":');
    o.string(batchId);
    o.raw(',"created_ms":');
    o.integer(createdMs);
    o.raw(',"day":');
    o.string(day);
    o.raw(',"install_id":');
    o.string(installId);
    o.raw(',"session_id":');
    o.string(sessionId);
    o.raw(',"session_no":');
    o.integer(sessionNo);
    o.raw(',"process":');
    o.string(process);
    o.raw(',"user_id":');
    o.stringOrNull(userId);
    o.raw(',"device":');
    device.encode(o);
    o.raw(',"seq_from":');
    o.integer(seqFrom);
    o.raw(',"seq_to":');
    o.integer(seqTo);
    final f = oseqFrom, t = oseqTo;
    if (f != null && t != null) {
      o.raw(',"oseq_from":');
      o.integer(f);
      o.raw(',"oseq_to":');
      o.integer(t);
    }
    if (ctxTruncated != null) {
      o.raw(',"ctx_truncated":');
      o.integer(ctxTruncated!);
    }
    if (drops.isNotEmpty) {
      o.raw(',"drops":[');
      for (var i = 0; i < drops.length; i++) {
        if (i > 0) o.raw(',');
        drops[i].encode(o);
      }
      o.raw(']');
    }
    if (closedSessions.isNotEmpty) {
      o.raw(',"closed_sessions":[');
      for (var i = 0; i < closedSessions.length; i++) {
        if (i > 0) o.raw(',');
        closedSessions[i].encode(o);
      }
      o.raw(']');
    }
    if (closedSessionsDropped > 0) {
      o.raw(',"closed_sessions_dropped":');
      o.integer(closedSessionsDropped);
    }
    final m = mapping;
    if (m != null) {
      o.raw(',"mapping":{"user_id":');
      o.stringOrNull(m.userId);
      o.raw(',"device":');
      m.device.encode(o);
      o.raw('}');
    }
    o.raw(',"lines":[');
    return o.toBytes();
  }

  /// 整个信封：头 + 行（逗号分隔）+ `]}`。
  Uint8List encode(List<List<int>> lines) {
    final prefix = encodePrefix();
    var total = prefix.length + 2;
    for (final l in lines) {
      total += l.length + 1;
    }
    final o = JsonOut(total);
    o.rawBytes(prefix);
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) o.byte(0x2C);
      o.rawBytes(lines[i]);
    }
    o.byte(0x5D);
    o.byte(0x7D);
    return o.toBytes();
  }

  static EnvelopeHeader? decode(Map<String, Object?> o) {
    final kind = BatchKind.of(o['kind'] is String ? o['kind'] as String : null);
    final bid = o['batch_id'];
    final created = JsonIn.int64(o['created_ms']);
    final day = o['day'];
    final iid = o['install_id'];
    final sid = o['session_id'];
    final sno = JsonIn.int64(o['session_no']);
    final proc = o['process'];
    final dev = Device.decode(o['device']);
    if (kind == null || bid is! String || created == null || day is! String || iid is! String) return null;
    if (sid is! String || sno == null || proc is! String || dev == null) return null;
    final uid = o['user_id'];
    final h = EnvelopeHeader(
      kind,
      bid,
      created,
      day,
      iid,
      sid,
      sno,
      proc,
      uid is String ? uid : null,
      dev,
      JsonIn.int64(o['seq_from']) ?? 0,
      JsonIn.int64(o['seq_to']) ?? 0,
      JsonIn.int64(o['oseq_from']),
      JsonIn.int64(o['oseq_to']),
      JsonIn.int64(o['ctx_truncated']),
    );
    h.drops = [for (final x in JsonIn.asList(o['drops']) ?? const <Object?>[]) ?DropEntry.decode(x)];
    h.closedSessions = [
      for (final x in JsonIn.asList(o['closed_sessions']) ?? const <Object?>[]) ?ClosedSession.decode(x),
    ];
    h.closedSessionsDropped = JsonIn.int64(o['closed_sessions_dropped']) ?? 0;
    final m = JsonIn.asObj(o['mapping']);
    if (m != null) {
      final md = Device.decode(m['device']);
      final mu = m['user_id'];
      if (md != null) h.mapping = MappingBlock(mu is String ? mu : null, md);
    }
    return h;
  }
}

/// 出站箱批文件的元数据（物化时填入缓存；启动时解压扫描重建）。只含可在 isolate 间发送的值。
class BatchMeta {
  BatchMeta(
    this.name,
    this.prio,
    this.createdMs,
    this.batchId,
    this.installId,
    this.kind,
    this.sessionId,
    this.oseqFrom,
    this.oseqTo,
    this.lineCount,
    this.hasWarnOrAbove,
    this.hasError,
    this.drops,
    this.closed,
    this.hasMapping,
    this.mappingUser,
    this.mappingDigest,
    this.bytes,
  );

  String name;

  /// 0 / 1 / 2 = p0 / p1 / p2；3 = q
  int prio;
  final int createdMs;
  final String batchId;

  /// 信封里的 install_id：请求头 `X-Rtv-Install` 取它（ADR 0019 决定 10）。
  final String installId;
  final BatchKind kind;
  final String sessionId;
  final int oseqFrom;
  final int oseqTo;
  final int lineCount;
  final bool hasWarnOrAbove;
  final bool hasError;
  final List<DropEntry> drops;
  final List<ClosedSession> closed;
  final bool hasMapping;
  final String? mappingUser;
  final String? mappingDigest;
  final int bytes;

  /// 429 `["info","backfill"]` 暂停的类别：p2 = backfill；不含 warn 以上的 primary = info。
  String? get category => kind == BatchKind.backfill ? 'backfill' : (hasWarnOrAbove ? null : 'info');
}

/// 出站箱文件名：`p{0|1|2}-<created_ms>-<batch_id>.gz` / `q-<created_ms>-<batch_id>.gz`。
abstract final class OutboxName {
  static String make(int prio, int createdMs, String batchId) => '${prio >= 3 ? 'q' : 'p$prio'}-$createdMs-$batchId.gz';

  static ({int prio, int createdMs, String batchId})? parse(String name) {
    if (!name.endsWith('.gz')) return null;
    final stem = name.substring(0, name.length - 3);
    final a = stem.indexOf('-');
    if (a < 0) return null;
    final b = stem.indexOf('-', a + 1);
    if (b < 0) return null;
    final created = int.tryParse(stem.substring(a + 1, b));
    if (created == null) return null;
    final int prio;
    switch (stem.substring(0, a)) {
      case 'p0':
        prio = 0;
      case 'p1':
        prio = 1;
      case 'p2':
        prio = 2;
      case 'q':
        prio = 3;
      default:
        return null;
    }
    final bid = stem.substring(b + 1);
    if (!Ids.isUuid(bid)) return null;
    return (prio: prio, createdMs: created, batchId: bid);
  }
}

/// backoff.json：{attempt, next_at_wall_ms, next_at_mono_ms, paused_until_ms, paused_categories, reason, last_ack_ms, key_fp?, base_url?}
class BackoffState {
  BackoffState({
    this.attempt = 0,
    this.nextAtWallMs = 0,
    this.nextAtMonoMs = 0,
    this.pausedUntilMs = 0,
    this.pausedUntilMono = 0,
    List<String>? pausedCategories,
    this.reason = '',
    this.lastAckMs = -1,
    this.keyFp,
    this.baseUrl,
    this.hasIdentity = true,
  }) : pausedCategories = pausedCategories ?? <String>[];

  int attempt;
  int nextAtWallMs;
  int nextAtMonoMs;
  int pausedUntilMs;
  int pausedUntilMono;
  List<String> pausedCategories;
  String reason;
  int lastAckMs;
  String? keyFp;
  String? baseUrl;

  /// 文件里有 key_fp / base_url 键（旧版本写的两个都没有 = 视为当前目标）。
  bool hasIdentity;

  BackoffState copy() => BackoffState(
    attempt: attempt,
    nextAtWallMs: nextAtWallMs,
    nextAtMonoMs: nextAtMonoMs,
    pausedUntilMs: pausedUntilMs,
    pausedUntilMono: pausedUntilMono,
    pausedCategories: List.of(pausedCategories),
    reason: reason,
    lastAckMs: lastAckMs,
    keyFp: keyFp,
    baseUrl: baseUrl,
    hasIdentity: hasIdentity,
  );

  Uint8List encode() {
    final o = JsonOut();
    o.raw('{"attempt":');
    o.integer(attempt);
    o.raw(',"next_at_wall_ms":');
    o.integer(nextAtWallMs);
    o.raw(',"next_at_mono_ms":');
    o.integer(nextAtMonoMs);
    o.raw(',"paused_until_ms":');
    o.integer(pausedUntilMs);
    o.raw(',"paused_categories":[');
    for (var i = 0; i < pausedCategories.length; i++) {
      if (i > 0) o.raw(',');
      o.string(pausedCategories[i]);
    }
    o.raw('],"reason":');
    o.string(reason);
    o.raw(',"last_ack_ms":');
    o.integer(lastAckMs);
    o.raw(',"key_fp":');
    o.stringOrNull(keyFp);
    o.raw(',"base_url":');
    o.stringOrNull(baseUrl);
    o.raw('}');
    return o.toBytes();
  }

  /// 换了 key 指纹或 baseUrl：清鉴权暂停、类别暂停与退避（`last_ack_ms` 保留）。
  BackoffState forIdentity(String fp, String base) => BackoffState(lastAckMs: lastAckMs, keyFp: fp, baseUrl: base);

  /// 冷启动：单调时钟不跨进程，用墙钟换算；next_at 晚于 now + 15 min（时钟回拨）截断。
  static BackoffState? decodeColdStart(List<int> b, int nowWall, int nowMono) {
    final o = JsonIn.obj(b);
    if (o == null) return null;
    final s = BackoffState();
    s.attempt = JsonIn.int64(o['attempt']) ?? 0;
    s.nextAtWallMs = JsonIn.int64(o['next_at_wall_ms']) ?? 0;
    s.pausedUntilMs = JsonIn.int64(o['paused_until_ms']) ?? 0;
    s.pausedCategories = [
      for (final x in JsonIn.asList(o['paused_categories']) ?? const <Object?>[])
        if (x is String) x,
    ];
    final r = o['reason'];
    s.reason = r is String ? r : '';
    s.lastAckMs = JsonIn.int64(o['last_ack_ms']) ?? -1;
    final fp = o['key_fp'];
    final base = o['base_url'];
    s.keyFp = fp is String ? fp : null;
    s.baseUrl = base is String ? base : null;
    s.hasIdentity = o.containsKey('key_fp') || o.containsKey('base_url');
    final nextWait = _clamp(s.nextAtWallMs - nowWall, 0, Limits.backoffMaxMs);
    s.nextAtWallMs = nextWait > 0 ? nowWall + nextWait : 0;
    s.nextAtMonoMs = nextWait > 0 ? nowMono + nextWait : 0;
    final pauseWait = _clamp(s.pausedUntilMs - nowWall, 0, Limits.pause401MaxMs);
    s.pausedUntilMs = pauseWait > 0 ? nowWall + pauseWait : 0;
    s.pausedUntilMono = pauseWait > 0 ? nowMono + pauseWait : 0;
    if (pauseWait == 0) s.pausedCategories = <String>[];
    return s;
  }

  static int _clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);
}

const Object _unset = _Unset();

class _Unset {
  const _Unset();
}
