// 远程配置（方案 §5；packages/core/src/config.ts）。对位 Android `core/Config.kt`。
//
// Flutter 差异（v2 §2.1 / 核实 §11c）：Dart 在 Android 上的单调时钟不含深睡眠。缓存的「已过多久」取单调与墙钟两者的较大值
// （放大型字段「任一到期回落」）；从文件读回的缓存（没有单调基准）只看墙钟，同 Android。

import 'dart:typed_data';

import 'json.dart';
import 'limits.dart';
import 'model.dart';
import 'public_api.dart';

/// 远程配置（12 个字段）。
class RemoteConfig {
  const RemoteConfig({
    required this.etag,
    required this.ttlS,
    required this.uploadEnabled,
    required this.uploadLevel,
    required this.localLevel,
    required this.contextLines,
    required this.contextBytes,
    required this.flushIntervalS,
    required this.localCapBytes,
    required this.fullDump,
    required this.fullDumpTtlS,
    required this.dailyBatchCap,
  });

  final String etag;
  final int ttlS;
  final bool uploadEnabled;
  final LogLevel uploadLevel;
  final LogLevel localLevel;
  final int contextLines;
  final int contextBytes;
  final int flushIntervalS;
  final int localCapBytes;
  final bool fullDump;
  final int fullDumpTtlS;
  final int dailyBatchCap;

  RemoteConfig copyWith({
    String? etag,
    int? ttlS,
    bool? uploadEnabled,
    LogLevel? uploadLevel,
    LogLevel? localLevel,
    int? contextLines,
    int? contextBytes,
    int? flushIntervalS,
    int? localCapBytes,
    bool? fullDump,
    int? fullDumpTtlS,
    int? dailyBatchCap,
  }) => RemoteConfig(
    etag: etag ?? this.etag,
    ttlS: ttlS ?? this.ttlS,
    uploadEnabled: uploadEnabled ?? this.uploadEnabled,
    uploadLevel: uploadLevel ?? this.uploadLevel,
    localLevel: localLevel ?? this.localLevel,
    contextLines: contextLines ?? this.contextLines,
    contextBytes: contextBytes ?? this.contextBytes,
    flushIntervalS: flushIntervalS ?? this.flushIntervalS,
    localCapBytes: localCapBytes ?? this.localCapBytes,
    fullDump: fullDump ?? this.fullDump,
    fullDumpTtlS: fullDumpTtlS ?? this.fullDumpTtlS,
    dailyBatchCap: dailyBatchCap ?? this.dailyBatchCap,
  );

  @override
  bool operator ==(Object other) =>
      other is RemoteConfig &&
      other.etag == etag &&
      other.ttlS == ttlS &&
      other.uploadEnabled == uploadEnabled &&
      other.uploadLevel == uploadLevel &&
      other.localLevel == localLevel &&
      other.contextLines == contextLines &&
      other.contextBytes == contextBytes &&
      other.flushIntervalS == flushIntervalS &&
      other.localCapBytes == localCapBytes &&
      other.fullDump == fullDump &&
      other.fullDumpTtlS == fullDumpTtlS &&
      other.dailyBatchCap == dailyBatchCap;

  @override
  int get hashCode => Object.hash(
    etag,
    ttlS,
    uploadEnabled,
    uploadLevel,
    localLevel,
    contextLines,
    contextBytes,
    flushIntervalS,
    localCapBytes,
    fullDump,
    fullDumpTtlS,
    dailyBatchCap,
  );
}

/// 宿主在 configure 里给的默认（ADR 0004 / 0005）。`localLevel` / `dailyBatchCap` 可缺省。
class HostDefaults {
  const HostDefaults(
    this.uploadLevel, [
    this.localLevel,
    this.dailyBatchCap,
    this.localCapBytes = Limits.localCapBytesDefault,
  ]);

  factory HostDefaults.of(RetrieverOptions o) =>
      HostDefaults(o.uploadLevel, o.localLevel, o.dailyBatchCap, ConfigRules.clampHostCap(o.localCapBytes));

  final LogLevel uploadLevel;
  final LogLevel? localLevel;
  final int? dailyBatchCap;

  /// 宿主 `localCapBytes`（缓存过期时 local_cap 放大回落的目标；不参与 clampConfig）。
  final int localCapBytes;

  @override
  bool operator ==(Object other) =>
      other is HostDefaults &&
      other.uploadLevel == uploadLevel &&
      other.localLevel == localLevel &&
      other.dailyBatchCap == dailyBatchCap &&
      other.localCapBytes == localCapBytes;

  @override
  int get hashCode => Object.hash(uploadLevel, localLevel, dailyBatchCap, localCapBytes);
}

abstract final class ConfigRules {
  /// full_dump_ttl_s 上限：覆盖默认 ttl × 7（= 7 天）。
  static const int fullDumpTtlSMax = Limits.overrideTtlSDefault * 7;

  /// `clampConfig` 逐字移植（config.ts）：越界取边界，类型错 / 未知枚举取默认；raw 非对象 → 全默认。
  static RemoteConfig clamp(Object? raw, HostDefaults host) {
    final r = JsonIn.asObj(raw) ?? const <String, Object?>{};
    final hostCap = clampInt(host.dailyBatchCap?.toDouble(), 0, Limits.dailyBatchCapMax, Limits.dailyBatchCapDefault);
    final ul = r['upload_level'];
    final ll = r['local_level'];
    return RemoteConfig(
      etag: JsonIn.string(r['etag']) ?? '',
      ttlS: clampInt(JsonIn.dbl(r['ttl_s']), Limits.configTtlSMin, Limits.configTtlSMax, Limits.configTtlSDefault),
      uploadEnabled: JsonIn.boolean(r['upload_enabled']) ?? true,
      uploadLevel: LogLevels.ofWire(ul is String ? ul : null) ?? host.uploadLevel,
      localLevel: LogLevels.ofWire(ll is String ? ll : null) ?? (host.localLevel ?? LogLevel.debug),
      contextLines: clampInt(JsonIn.dbl(r['context_lines']), 0, Limits.ctxLinesMax, Limits.ctxLinesDefault),
      contextBytes: clampInt(JsonIn.dbl(r['context_bytes']), 0, Limits.ctxBytesMax, Limits.ctxBytesDefault),
      flushIntervalS: clampInt(
        JsonIn.dbl(r['flush_interval_s']),
        Limits.flushIntervalSMin,
        Limits.flushIntervalSMax,
        Limits.flushIntervalSDefault,
      ),
      // 缺省 = 宿主值（对齐 packages/core clampConfig 的 hostLocalCap；ADR 0022）
      localCapBytes: clampInt(
        JsonIn.dbl(r['local_cap_bytes']),
        Limits.localCapBytesMin,
        Limits.localCapBytesMax,
        host.localCapBytes,
      ),
      fullDump: JsonIn.boolean(r['full_dump']) ?? false,
      fullDumpTtlS: clampInt(JsonIn.dbl(r['full_dump_ttl_s']), 0, fullDumpTtlSMax, 0),
      dailyBatchCap: clampInt(JsonIn.dbl(r['daily_batch_cap']), 0, Limits.dailyBatchCapMax, hostCap),
    );
  }

  /// 有限 number 先向下取整再夹到 [min, max]（按浮点比较，避免大数溢出）；其它一律取默认。
  static int clampInt(double? x, int min, int max, int dflt) {
    if (x == null || x.isNaN || x.isInfinite) return dflt;
    final v = x.floorToDouble();
    if (v <= min.toDouble()) return min;
    if (v > max.toDouble()) return max;
    return v.toInt();
  }

  static int clampHostCap(int v) => v < Limits.localCapBytesMin
      ? Limits.localCapBytesMin
      : (v > Limits.localCapBytesMax ? Limits.localCapBytesMax : v);

  /// 宿主型字段（packages/core `HOST_FIELDS`，顺序固定）。
  static const List<String> hostFields = ['upload_level', 'local_level', 'local_cap_bytes', 'daily_batch_cap'];

  /// 响应 / 缓存文件里的 `from_host`（ADR 0022）：只认已知的宿主型字段名；缺失或不是数组 = 空集。按 [hostFields] 的顺序。
  static Set<String> fromHost(Object? v) {
    final l = JsonIn.asList(v);
    if (l == null) return <String>{};
    final names = {
      for (final x in l)
        if (x is String) x,
    };
    return {
      for (final f in hostFields)
        if (names.contains(f)) f,
    };
  }

  /// `from_host` 里的字段取**当前**宿主默认（按 clamp 规则钳制），其余保留缓存值。
  static RemoteConfig withHost(RemoteConfig c, Set<String> fields, HostDefaults host) {
    if (fields.isEmpty) return c;
    final h = clamp(null, host);
    return c.copyWith(
      uploadLevel: fields.contains('upload_level') ? h.uploadLevel : c.uploadLevel,
      localLevel: fields.contains('local_level') ? h.localLevel : c.localLevel,
      localCapBytes: fields.contains('local_cap_bytes') ? h.localCapBytes : c.localCapBytes,
      dailyBatchCap: fields.contains('daily_batch_cap') ? h.dailyBatchCap : c.dailyBatchCap,
    );
  }

  /// 序列化成与服务端同名字段的 JSON（缓存到 config.json）。
  static Uint8List encode(RemoteConfig c) {
    final o = JsonOut();
    o.raw('{"etag":');
    o.string(c.etag);
    o.raw(',"ttl_s":');
    o.integer(c.ttlS);
    o.raw(',"upload_enabled":');
    o.boolean(c.uploadEnabled);
    o.raw(',"upload_level":');
    o.string(c.uploadLevel.wire);
    o.raw(',"local_level":');
    o.string(c.localLevel.wire);
    o.raw(',"context_lines":');
    o.integer(c.contextLines);
    o.raw(',"context_bytes":');
    o.integer(c.contextBytes);
    o.raw(',"flush_interval_s":');
    o.integer(c.flushIntervalS);
    o.raw(',"local_cap_bytes":');
    o.integer(c.localCapBytes);
    o.raw(',"full_dump":');
    o.boolean(c.fullDump);
    o.raw(',"full_dump_ttl_s":');
    o.integer(c.fullDumpTtlS);
    o.raw(',"daily_batch_cap":');
    o.integer(c.dailyBatchCap);
    o.raw('}');
    return o.toBytes();
  }
}

/// 生效配置：缓存 + 到期回落（§5）。`config` 可被测试改写（同 Android 的 var）。
class EffectiveConfig {
  EffectiveConfig(this.config, this.fullDumpActive, this.uploadLevel, this.expired);

  RemoteConfig config;
  final bool fullDumpActive;

  /// 生效 upload_level（full_dump 生效期间降为 debug）。
  final LogLevel uploadLevel;
  final bool expired;
}

/// 缓存的远程配置（不可变快照：引擎任务换新对象，写入侧在宿主调用里读同一个快照重算级别）。
class ConfigCache {
  const ConfigCache(
    this.config,
    this.fetchedWallMs,
    this.fetchedMonoMs, {
    this.identityStale = false,
    this.fromHost = const <String>{},
    this.keyFp = '',
    this.baseUrl = '',
    this.legacyIdentity = false,
    this.userId,
  });

  final RemoteConfig config;
  final int fetchedWallMs;

  /// 本进程拉到时的单调时刻；从文件恢复的缓存为 null（改用墙钟）。
  final int? fetchedMonoMs;

  /// 身份（install_id, user_id, key 指纹, baseUrl）变了：按过期处理直到新身份的响应到达。
  final bool identityStale;

  /// 响应的 `from_host`（ADR 0022）：这些宿主型字段远程没给，生效时取当前宿主默认。
  final Set<String> fromHost;

  /// 拉到这份配置时的 key 指纹与 baseUrl（写进 config.json；读回时与当前不同 = 身份过期）。
  final String keyFp;
  final String baseUrl;

  /// 从旧版本的 config.json 读来（没有 key_fp / base_url）：按与当前相同处理，调用方补写当前值。
  final bool legacyIdentity;

  /// 拉到这份配置时的用户（清洗后，可为 null）。
  final String? userId;

  /// 已过多久：本进程拉到的取「单调、墙钟」两者较大（任一到期回落）；文件读回的只看墙钟。
  int elapsedMs(int nowWall, int nowMono) {
    final m = fetchedMonoMs;
    final wall = nowWall - fetchedWallMs;
    if (m == null) return wall;
    final mono = nowMono - m;
    return mono > wall ? mono : wall;
  }

  /// 同一份配置，按过期处理（放大型字段立即回落）。
  ConfigCache staleForIdentity() => ConfigCache(
    config,
    fetchedWallMs,
    fetchedMonoMs,
    identityStale: true,
    fromHost: fromHost,
    keyFp: keyFp,
    baseUrl: baseUrl,
    userId: userId,
  );

  /// config.json：`{"fetched_ms":N,"key_fp":"…","base_url":"…","user_id":…,"config":{12 字段},"from_host":[…]}`。
  Uint8List encodeFile() {
    final o = JsonOut();
    o.raw('{"fetched_ms":');
    o.integer(fetchedWallMs);
    o.raw(',"key_fp":');
    o.string(keyFp);
    o.raw(',"base_url":');
    o.string(baseUrl);
    o.raw(',"user_id":');
    o.stringOrNull(userId);
    o.raw(',"config":');
    o.rawBytes(ConfigRules.encode(config));
    o.raw(',"from_host":[');
    var i = 0;
    for (final f in ConfigRules.hostFields) {
      if (!fromHost.contains(f)) continue;
      if (i++ > 0) o.raw(',');
      o.string(f);
    }
    o.raw(']}');
    return o.toBytes();
  }

  /// 下一次生效配置可能变化的单调时刻（过期 / full_dump 到期），供调度器唤醒。
  int? nextChangeMono(int nowWall, int nowMono) {
    if (identityStale) return null;
    final elapsed = elapsedMs(nowWall, nowMono);
    int? best;
    final ttl = config.ttlS * 1000;
    if (elapsed < ttl) best = nowMono + (ttl - elapsed);
    if (config.fullDump) {
      final fd = config.fullDumpTtlS * 1000;
      if (elapsed < fd) {
        final at = nowMono + (fd - elapsed);
        if (best == null || at < best) best = at;
      }
    }
    return best;
  }

  /// 读 config.json；读不出 / 不是对象 / 没有 fetched_ms 返回 null。身份对不上 → 按身份过期处理。
  static ConfigCache? decodeFile(List<int> b, HostDefaults host, String keyFp, String baseUrl, String? user) {
    final o = JsonIn.obj(b);
    if (o == null) return null;
    final fetched = JsonIn.int64(o['fetched_ms']);
    if (fetched == null) return null;
    final fpRaw = o['key_fp'];
    final baseRaw = o['base_url'];
    final fp = fpRaw is String ? fpRaw : null;
    final base = baseRaw is String ? baseRaw : null;
    // 两个键都没有 = 旧版本写的：视为当前目标（补写、不复位）；只要有且任一不符 = 身份过期
    final legacy = !o.containsKey('key_fp') && !o.containsKey('base_url');
    final same = legacy || (fp == keyFp && base == baseUrl);
    final u = o['user_id'];
    final cachedUser = u is String ? u : null;
    return ConfigCache(
      ConfigRules.clamp(o['config'], host),
      fetched,
      null,
      identityStale: !same || cachedUser != user,
      fromHost: ConfigRules.fromHost(o['from_host']),
      keyFp: same ? keyFp : (fp ?? ''),
      baseUrl: same ? baseUrl : (base ?? ''),
      legacyIdentity: legacy,
      userId: cachedUser,
    );
  }

  /// 生效配置（纯函数：不可变缓存快照 + 宿主默认 + 时刻）：`from_host` 里的字段取当前宿主默认，其余取缓存值；
  /// 再做过期回落——放大型字段回落到宿主默认 / 内置默认（宪法 U-2）。只因身份变化按过期处理时 local_cap 不回落。
  static EffectiveConfig effective(ConfigCache? cache, HostDefaults host, int nowWall, int nowMono) {
    if (cache == null) {
      final c = ConfigRules.clamp(null, host);
      return EffectiveConfig(c, false, c.uploadLevel, true);
    }
    var c = ConfigRules.withHost(cache.config, cache.fromHost, host);
    final elapsed = cache.elapsedMs(nowWall, nowMono);
    final ttlExpired = elapsed < 0 || elapsed >= c.ttlS * 1000;
    final expired = cache.identityStale || ttlExpired;
    if (expired) {
      c = c.copyWith(
        fullDump: false,
        fullDumpTtlS: 0,
        uploadLevel: c.uploadLevel.index < host.uploadLevel.index ? host.uploadLevel : c.uploadLevel,
        contextLines: c.contextLines < Limits.ctxLinesDefault ? c.contextLines : Limits.ctxLinesDefault,
        contextBytes: c.contextBytes < Limits.ctxBytesDefault ? c.contextBytes : Limits.ctxBytesDefault,
        flushIntervalS: c.flushIntervalS > Limits.flushIntervalSDefault
            ? c.flushIntervalS
            : Limits.flushIntervalSDefault,
        localCapBytes: ttlExpired
            ? (c.localCapBytes < host.localCapBytes ? c.localCapBytes : host.localCapBytes)
            : c.localCapBytes,
      );
    }
    final fullDumpActive = c.fullDump && elapsed >= 0 && elapsed < c.fullDumpTtlS * 1000;
    return EffectiveConfig(c, fullDumpActive, fullDumpActive ? LogLevel.debug : c.uploadLevel, expired);
  }
}
