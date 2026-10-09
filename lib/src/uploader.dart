// 出站队列与响应分类（§3.6 / §3.7，宪法 R-2 / R-3）。对位 Android `core/Uploader.kt`，与 iOS `Uploader.swift` 逐字一致。
// 决策在引擎队列里，网络在队列外。

import 'dart:math';
import 'config.dart';
import 'config_check.dart';
import 'engine.dart';
import 'fs.dart';
import 'ids.dart';
import 'json.dart';
import 'limits.dart';
import 'materializer.dart';
import 'model.dart';
import 'outbox.dart';
import 'public_api.dart';
import 'text.dart';
import 'transport.dart';

sealed class SendStep {
  const SendStep();
}

/// `keyFp` / `baseUrl`：这次请求用的 key 指纹与 baseUrl（响应回来时 key 已换 → 401 / 403 不暂停新 key，ADR 0024 决定 7）。
final class SendNow extends SendStep {
  const SendNow(this.name, this.request, this.keyFp, this.baseUrl);

  final String name;
  final TransportRequest request;
  final String keyFp;
  final String baseUrl;
}

final class SendStop extends SendStep {
  const SendStop(this.reason, this.wakeMono);

  final String reason;
  final int? wakeMono;
}

class ResponseEffect {
  bool fetchConfig = false;
  bool acked = false;

  /// 本次响应让当前 key 进入了鉴权暂停：调用方在引擎队列外出 `key_rejected` 诊断（ADR 0025）。
  KeyRejection? keyRejected;
}

class ConfigEffect {
  bool sealed = false;
  bool backfill = false;

  /// 响应属于请求时的身份，而身份已经变了：丢弃不生效，调用方重拉（ADR 0019 决定 12）。
  bool stale = false;
}

/// 配置请求与请求时的身份 = install + user + 四项宿主默认 + key 指纹 + baseUrl。
class ConfigFetch {
  const ConfigFetch(this.request, this.installId, this.userId, this.host, this.keyFp, this.baseUrl);

  final TransportRequest request;
  final String installId;
  final String? userId;
  final HostDefaults host;
  final String keyFp;
  final String baseUrl;
}

final Random _random = Random();

int? retryAfter(Map<String, Object?>? body, String? header) {
  final v = JsonIn.dbl(body?['retry_after_s']);
  if (v != null && !v.isNaN && !v.isInfinite) return v.truncate();
  final h = header?.trim();
  return h == null ? null : int.tryParse(h);
}

int clampRetryAfterMs(int s) =>
    (s < Limits.retryAfterMinS ? Limits.retryAfterMinS : (s > Limits.retryAfterMaxS ? Limits.retryAfterMaxS : s)) *
    1000;

int jitter(int ms) {
  final f = (1 - Limits.backoffJitter) + _random.nextDouble() * 2 * Limits.backoffJitter;
  return (ms * f).round();
}

/// backoff(attempt) = min(1 s × 2^attempt, 15 min) × (1 ± 20%)
int backoffMs(int attempt) {
  final shift = attempt < 30 ? attempt : 30;
  final b = Limits.backoffBaseMs << shift;
  return jitter(b < Limits.backoffMaxMs ? b : Limits.backoffMaxMs);
}

String percentEncode(String s) {
  const hex = '0123456789ABCDEF';
  final b = Text.utf8Bytes(s);
  final sb = StringBuffer();
  for (final v in b) {
    final isAlnum = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39);
    if (isAlnum) {
      sb.writeCharCode(v);
    } else {
      sb
        ..write('%')
        ..write(hex[v >> 4])
        ..write(hex[v & 0xF]);
    }
  }
  return sb.toString();
}

extension EngineUploader on Engine {
  /// 选下一批：p0 > p1 > p2，同级 created_ms 升序（失败过的批让到后面）；单在途；相邻请求 ≥ 2 s；全局或对应类别未暂停。
  /// 读不出的批本轮跳过、试下一个。
  Future<SendStep> nextSend() async {
    final nowMono = clock.monoMs();
    if (key.isEmpty) return const SendStop('not_configured', null);
    // 本进程内存开关 ∧ 盘上无禁用标记（别的进程禁用也在这里挡住，ADR 0020 决定 2）
    if (!await uploadAllowed()) return const SendStop('disabled', null);
    // 未 bootstrap：不碰磁盘直接停，bootstrap 成功后由 startup 重新排空
    if (install == null) return const SendStop('not_bootstrapped', null);
    if (!effective.config.uploadEnabled) return const SendStop('upload_disabled', null);
    final pauseActive = backoff.pausedUntilMono > nowMono;
    if (pauseActive && backoff.pausedCategories.contains('all')) return SendStop('paused', backoff.pausedUntilMono);
    if (backoff.nextAtMonoMs > nowMono) {
      return SendStop(backoff.reason == 'network' ? 'offline' : 'backoff', backoff.nextAtMonoMs);
    }
    final last = lastRequestMono;
    if (last != null && nowMono < last + Limits.minRequestSpacingMs) {
      return SendStop('spacing', last + Limits.minRequestSpacingMs);
    }
    await reconcileOutbox();
    final candidates = metas.values.where((m) => m.prio < 3).toList();
    if (candidates.isEmpty) return const SendStop('empty', null);
    final pausedCats = pauseActive ? backoff.pausedCategories.toSet() : const <String>{};
    final eligible = candidates.where((m) {
      final c = m.category;
      return !(c != null && pausedCats.contains(c));
    }).toList();
    int failed(BatchMeta m) => (fails[m.name]?.count ?? 0) > 0 ? 1 : 0;
    eligible.sort((a, b) {
      var c = failed(a).compareTo(failed(b));
      if (c != 0) return c;
      c = a.prio.compareTo(b.prio);
      if (c != 0) return c;
      c = a.createdMs.compareTo(b.createdMs);
      if (c != 0) return c;
      return a.name.compareTo(b.name);
    });
    // candidates 非空时 eligible 为空只可能是类别暂停
    if (eligible.isEmpty) return SendStop('paused', backoff.pausedUntilMono);
    if (!acquireUploadLock()) return SendStop('locked', nowMono + 60000);
    for (final pick in eligible) {
      // 读不出（坏块 / 权限）：不删、不隔离、不计 fail，留在出站箱下一轮再试
      final body = await Fs.read(Fs.join(outboxDir, pick.name));
      if (body == null) continue;
      final req = TransportRequest('POST', endpoint('v1/batches'), <String, String>{
        'Authorization': 'Bearer $key',
        'Content-Type': 'application/json',
        'Content-Encoding': 'gzip',
        // 每个批以自身信封里的 install_id 上报（ADR 0019 决定 10）
        'X-Rtv-Install': pick.installId,
        'X-Rtv-Sent-Ms': clock.wallMs().toString(),
        'X-Rtv-Sdk': sdkHeader,
      }, body);
      inFlight = pick.name;
      lastRequestMono = nowMono;
      return SendNow(pick.name, req, keyFp, baseUrl);
    }
    return const SendStop('unreadable', null);
  }

  // MARK: 上传锁（多进程：只有拿到 upload.lock 的一方排空；每次选批重新加锁，每轮排空结束释放）

  bool acquireUploadLock() => locks.tryUploadLock();

  void releaseUploadLock() => locks.releaseUploadLock();

  // MARK: 响应分类

  /// `sentKeyFp` / `sentBaseUrl`：请求所用的 key 指纹与 baseUrl（null = 当前）；与当前不同时 401 / 403 不暂停。
  /// `cancelledBySdk`：SDK 自己取消的请求——不计毒批失败次数（ADR 0024 决定 10）。
  Future<ResponseEffect> handleResponse(
    String name,
    TransportResponse? response, {
    String? sentKeyFp,
    String? sentBaseUrl,
    bool cancelledBySdk = false,
  }) async {
    final eff = ResponseEffect();
    if (inFlight == name) inFlight = null;
    final meta = metas[name];
    if (meta == null) return eff;
    final fp = sentKeyFp ?? keyFp;
    final base = sentBaseUrl ?? baseUrl;
    if (response == null) {
      if (!cancelledBySdk) await _failure(name, null, 'network', true);
      return eff;
    }
    final body = JsonIn.obj(response.body);
    final status = response.status;
    if (status >= 200 && status <= 299) {
      // 回显的 batch_id 与本批一致才算确认（防 captive portal）；stored 与 quarantined 都算
      if (body != null && body['batch_id'] is String && body['batch_id'] == meta.batchId) {
        await _ack(meta, body['status'] == 'stored', fp, base);
        eff.acked = true;
        final e = body['config_etag'];
        if (e is String && e != (configCache?.config.etag ?? '')) eff.fetchConfig = true;
      } else {
        await _failure(name, null, 'echo_mismatch', true);
      }
    } else if (status == 401 || status == 403) {
      // 只有服务端明确表态（JSON 对象且 reason 是字符串）才鉴权暂停（ADR 0011）
      final r = body?['reason'];
      final reason = r is String ? r : null;
      if (fp != keyFp || base != baseUrl) {
        // 旧 key 在途请求的拒绝：不暂停、不退避、不计毒批
      } else if (reason != null) {
        eff.keyRejected = KeyRejection(status, reason, await _authPause(), fp, base);
      } else {
        await _failure(name, null, 'http_$status', true);
      }
    } else if (status == 413) {
      // 切分写不出（磁盘满等）：原批保留，按普通失败退避（不计毒批）
      if (!await split413(name)) await _failure(name, null, 'http_413', false);
    } else if (status == 429) {
      await _categoryPause(body, response.headers['retry-after']);
    } else if (status == 503) {
      await _failure(name, retryAfter(body, response.headers['retry-after']), 'http_503', false);
    } else {
      await _failure(name, null, 'http_$status', true);
    }
    return eff;
  }

  Future<void> _ack(BatchMeta meta, bool stored, String sentKeyFp, String sentBaseUrl) async {
    final nowWall = clock.wallMs();
    await Fs.remove(Fs.join(outboxDir, meta.name));
    metas.remove(meta.name);
    fails.remove(meta.name);
    for (final f in fails.values) {
      f.otherSuccess = true;
    }
    if (meta.kind == BatchKind.primary && meta.oseqFrom > 0) {
      ackedRanges.add(AckedRange(meta.sessionId, meta.oseqFrom, meta.oseqTo));
      if (ackedRanges.length > 512) ackedRanges.removeRange(0, ackedRanges.length - 512);
    }
    // 删已报墓碑与会话终态（按原样匹配）。目录锁拿不到：文件不改，条目留在「在途」集合里
    if (meta.drops.isNotEmpty || meta.closed.isNotEmpty) {
      final done = await locks.withDirLock(() async {
        if (meta.drops.isNotEmpty) {
          final gone = meta.drops.toSet();
          await Fs.writeAtomic(
            dropsFile,
            Jsonl.encodeDrops((await readDropsLocked()).where((d) => !gone.contains(d)).toList()),
          );
        }
        if (meta.closed.isNotEmpty) {
          final gone = meta.closed.map((c) => c.sessionId).toSet();
          await Fs.writeAtomic(
            sessionsFile,
            Jsonl.encodeClosed((await readClosedLocked()).where((c) => !gone.contains(c.sessionId)).toList()),
          );
        }
        return true;
      });
      if (done == true) {
        embeddedDrops.removeAll(meta.drops);
        embeddedClosed.removeAll(meta.closed.map((c) => c.sessionId));
      }
    }
    final d = meta.mappingDigest;
    if (meta.hasMapping && d != null) {
      // 服务端只在 stored 时写映射；别的 install 的批、旧 key / 旧服务端的 2xx 不算映射已确认
      if (stored && meta.installId == install?.installId && sentKeyFp == keyFp && sentBaseUrl == baseUrl) {
        final m = MappingState(meta.mappingUser, d, nowWall, keyFp, baseUrl);
        mapping = m;
        await Fs.writeAtomic(mappingFile, m.encode());
      }
      final p = pendingMapping;
      if (p != null && p.user == meta.mappingUser && p.digest == d) pendingMapping = null;
    }
    backoff.attempt = 0;
    backoff.nextAtMonoMs = 0;
    backoff.nextAtWallMs = 0;
    backoff.lastAckMs = nowWall;
    // 任何一次 2xx 都复位暂停倍增状态；已到期的暂停一并清掉，仍在生效的类别暂停不动（ADR 0011）
    backoff.reason = '';
    if (backoff.pausedUntilMono <= clock.monoMs()) {
      backoff.pausedCategories = <String>[];
      backoff.pausedUntilMono = 0;
      backoff.pausedUntilMs = 0;
    }
    await persistBackoff();
  }

  /// 全局退避：next = now + max(clamp(Retry-After), backoff)；非 429 的失败计入该批 fail（毒批判定）。
  Future<void> _failure(String name, int? retryAfterS, String reason, bool countFail) async {
    final nowMono = clock.monoMs();
    final nowWall = clock.wallMs();
    var wait = backoffMs(backoff.attempt);
    if (retryAfterS != null) {
      final ra = clampRetryAfterMs(retryAfterS);
      if (ra > wait) wait = ra;
    }
    backoff.attempt += 1;
    backoff.nextAtMonoMs = nowMono + wait;
    backoff.nextAtWallMs = nowWall + wait;
    if (!backoff.reason.startsWith('auth:')) backoff.reason = reason;
    await persistBackoff();
    if (!countFail) return;
    final f = fails.putIfAbsent(name, () => FailCount(0, false));
    f.count += 1;
    // 同一批连续 5 次非 429 失败、且期间有别的批成功过 → 隔离；所有批都在失败则视为服务端故障，不隔离
    if (f.count >= Limits.poisonConsecutiveFails && f.otherSuccess) await quarantine(name);
  }

  /// 401 / 403 带 reason：全局暂停 1 h 起倍增到 24 h；照常写本地、照常拉配置；不删任何文件。返回本次暂停时长（ms）。
  Future<int> _authPause() async {
    int? prev;
    if (backoff.reason.startsWith('auth:')) prev = int.tryParse(backoff.reason.substring(5));
    final dur = prev != null
        ? (prev * 2 < Limits.pause401MaxMs ? prev * 2 : Limits.pause401MaxMs)
        : Limits.pause401BaseMs;
    backoff.pausedCategories = <String>['all'];
    backoff.pausedUntilMono = clock.monoMs() + dur;
    backoff.pausedUntilMs = clock.wallMs() + dur;
    backoff.reason = 'auth:$dur';
    await persistBackoff();
    return dur;
  }

  /// 429：按 categories 暂停到 now + retry_after_s（单调；钳制 1 s–1 h；±20% 抖动）；`all` = 全局。不计毒批。
  Future<void> _categoryPause(Map<String, Object?>? body, String? header) async {
    final ra = retryAfter(body, header) ?? 60;
    final wait = jitter(clampRetryAfterMs(ra));
    final cats = [
      for (final x in JsonIn.asList(body?['categories']) ?? const <Object?>[])
        if (x is String) x,
    ];
    final known = cats.where((c) => c == 'info' || c == 'backfill').toList();
    backoff.pausedCategories = cats.contains('all') || known.isEmpty ? <String>['all'] : known;
    backoff.pausedUntilMono = clock.monoMs() + wait;
    backoff.pausedUntilMs = clock.wallMs() + wait;
    final r = body?['reason'];
    if (!backoff.reason.startsWith('auth:')) backoff.reason = '429:${r is String ? r : ''}';
    await persistBackoff();
  }

  /// 排空的下一次唤醒（退避 / 暂停到期）。
  Future<int?> uploadWakeMono() async {
    if (key.isEmpty || !effective.config.uploadEnabled || !await uploadAllowed()) return null;
    if (!metas.values.any((m) => m.prio < 3)) return null;
    final now = clock.monoMs();
    int? w;
    void add(int v) {
      if (w == null || v > w!) w = v;
    }

    if (backoff.nextAtMonoMs > now) add(backoff.nextAtMonoMs);
    if (backoff.pausedUntilMono > now) add(backoff.pausedUntilMono);
    final l = lastRequestMono;
    if (l != null && l + Limits.minRequestSpacingMs > now) add(l + Limits.minRequestSpacingMs);
    return w;
  }

  // MARK: 远程配置（§5）

  /// 配置请求（null = 不拉：没 key、没 bootstrap、或已禁用——禁用期间零联网）。带上请求时的身份。
  Future<ConfigFetch?> configRequest() async {
    if (key.isEmpty || !await uploadAllowed()) return null;
    final inst = install;
    if (inst == null) return null;
    final user = writer.currentUser;
    final h = host;
    final headers = <String, String>{
      'Authorization': 'Bearer $key',
      'X-Rtv-Install': inst.installId,
      'X-Rtv-Sdk': sdkHeader,
      'X-Rtv-App-Version': device.appVersion,
      'X-Rtv-Upload-Level': h.uploadLevel.wire,
      'X-Rtv-Local-Level': (h.localLevel ?? LogLevel.debug).wire,
      'X-Rtv-Daily-Batch-Cap': (h.dailyBatchCap ?? 0).toString(),
      'X-Rtv-Local-Cap-Bytes': h.localCapBytes.toString(),
    };
    // 值一律 percent-encode（ASCII 字母数字以外全部编码，服务端 decodeURIComponent）
    if (user != null) headers['X-Rtv-User'] = percentEncode(user);
    // 发起即记「上次尝试时刻」：请求在途期间轮询候选不再是过去时
    lastConfigFetchMono = clock.monoMs();
    return ConfigFetch(
      TransportRequest('GET', endpoint('v1/config'), headers, null),
      inst.installId,
      user,
      h,
      keyFp,
      baseUrl,
    );
  }

  /// 拉到配置：钳制后缓存并生效；拉不到 / 非 200 / 非对象 → 用缓存（不放大）。身份变了 → 丢弃（`stale`），调用方重拉。
  Future<ConfigEffect> applyConfigResponse(ConfigFetch fetch, TransportResponse? r) async {
    lastConfigFetchMono = clock.monoMs();
    if (fetch.installId != install?.installId ||
        fetch.userId != writer.currentUser ||
        fetch.host != host ||
        fetch.keyFp != keyFp ||
        fetch.baseUrl != baseUrl) {
      return ConfigEffect()..stale = true;
    }
    if (r == null || r.status != 200) return ConfigEffect();
    final o = JsonIn.obj(r.body);
    if (o == null) return ConfigEffect();
    final cfg = ConfigRules.clamp(o, host);
    final nowWall = clock.wallMs();
    final cache = ConfigCache(
      cfg,
      nowWall,
      clock.monoMs(),
      fromHost: ConfigRules.fromHost(o['from_host']),
      keyFp: fetch.keyFp,
      baseUrl: fetch.baseUrl,
      userId: fetch.userId,
    );
    configCache = cache;
    await Fs.writeAtomic(configFile, cache.encodeFile());
    return applyEffective();
  }

  /// 重新计算生效配置并推给写入侧；full_dump 生效 / upload_enabled 变化触发封段，full_dump 生效生成 backfill。
  Future<ConfigEffect> applyEffective() async {
    final eff = ConfigEffect();
    final old = effective;
    effective = ConfigCache.effective(configCache, host, clock.wallMs(), clock.monoMs());
    writer.setConfigSnapshot(configCache);
    if (!old.fullDumpActive && effective.fullDumpActive) {
      writer.rotate(SealReason.fullDump);
      await processSeals();
      await materializeBackfill();
      eff.sealed = true;
      eff.backfill = true;
    }
    if (old.config.uploadEnabled != effective.config.uploadEnabled) {
      if (writer.rotate(SealReason.uploadEnabled)) await processSeals();
      eff.sealed = true;
    }
    if (old.config.localCapBytes != effective.config.localCapBytes) await evictIfNeeded();
    return eff;
  }

  /// 身份（setUser 的值）变了：缓存里的配置属于上一个身份，按过期处理（ADR 0019 决定 12）。
  Future<ConfigEffect> identityChanged() async {
    configCache = configCache?.staleForIdentity();
    return applyEffective();
  }

  bool configPollDue(int nowMono) {
    if (key.isEmpty) return false;
    final l = lastConfigFetchMono;
    if (l == null) return true;
    return nowMono - l >= Limits.configPollIntervalS * 1000;
  }
}
