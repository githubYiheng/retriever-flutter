// 配置诊断（ADR 0025；sdk-0.3.0 简报 §13）：key / baseUrl 的修剪、纯函数检查、`key_rejected` 的 reason 清洗与写死的消息。
// **只出诊断，不改行为**：请求照发，服务端是唯一裁决者。消息是写死的英文句子，绝不含 key 的任何部分。
// code 与消息与 iOS `ConfigCheck.swift` / Android `ConfigCheck.kt` 逐字一致。

import 'ids.dart';
import 'text.dart';

abstract final class ConfigCheck {
  static const String noKey = 'no_key';
  static const String keyTrimmed = 'key_trimmed';
  static const String keyMalformed = 'key_malformed';
  static const String keyEnvMismatch = 'key_env_mismatch';
  static const String baseUrlInvalid = 'base_url_invalid';
  static const String keyRejected = 'key_rejected';

  /// 生产 / staging 的入口主机（只判这两个，其它主机不判 env）。
  static const String productionHost = 'logs.revdog.org';
  static const String stagingHost = 'logs-staging.revdog.org';

  /// 同 `packages/core/src/apikey.ts` 的 `API_KEY_RE`；整串匹配。
  static final RegExp _keyRe = RegExp(r'^lk_(live|test)_([a-z0-9][a-z0-9_-]{1,31})_([0-9a-f]{32})_([0-9a-f]{8})$');

  /// reason 清洗后的上限（字符）。
  static const int _reasonMax = 40;

  /// 去掉首尾的空白与控制字符：[Text.trimmable]（码点 ≤ 0x20、0x7F–0x9F，以及 Unicode White_Space（U+00A0、U+1680、
  /// U+2000–U+200A、U+2028、U+2029、U+202F、U+205F、U+3000））。都在 BMP，代理项不会命中。
  static String trim(String s) {
    var start = 0;
    var end = s.length;
    while (start < end && Text.trimmable(s.codeUnitAt(start))) {
      start++;
    }
    while (end > start && Text.trimmable(s.codeUnitAt(end - 1))) {
      end--;
    }
    return start == 0 && end == s.length ? s : s.substring(start, end);
  }

  /// 本地检查（顺序固定）：`rawKey` = 宿主传入的原值，`key` / `baseUrl` = 修剪后的值。
  /// 1 `no_key`（key 为空，此时不再判 2–4）→ 2 `key_trimmed` → 3 `key_malformed` → 4 `key_env_mismatch` → 5 `base_url_invalid`。
  static List<String> check(String rawKey, String key, String baseUrl) {
    final out = <String>[];
    final url = _parse(baseUrl);
    if (key.isEmpty) {
      out.add(noKey);
    } else {
      if (rawKey != key) out.add(keyTrimmed);
      final env = keyEnv(key);
      if (env == null) {
        out.add(keyMalformed);
      } else {
        // 只判两个已知主机；自定义主机（自建、本机）不判
        final host = url?.host.toLowerCase();
        if ((host == productionHost && env == 'test') || (host == stagingHost && env == 'live')) {
          out.add(keyEnvMismatch);
        }
      }
    }
    if (!_isHttpUrl(url)) out.add(baseUrlInvalid);
    return out;
  }

  /// key 合法时返回 env（`live` | `test`），否则 null：整串匹配，且末 8 位 = 最后一个 `_` 之前全部 UTF-8 字节的 CRC-32/IEEE。
  static String? keyEnv(String key) {
    final m = _keyRe.firstMatch(key);
    if (m == null) return null;
    final crc = m.group(4)!;
    final body = key.substring(0, key.length - crc.length - 1);
    if (crc32Hex(Text.utf8Bytes(body)) != crc) return null;
    return m.group(1);
  }

  /// CRC-32/IEEE，8 位小写十六进制。
  static String crc32Hex(List<int> bytes) => Ids.crc32Hex(bytes);

  /// 按绝对 URL 解析 baseUrl（v3 §1：`Uri.tryParse`）；解析不了 = null。
  static Uri? _parse(String baseUrl) {
    try {
      return Uri.tryParse(baseUrl);
    } catch (_) {
      return null;
    }
  }

  /// scheme ∈ {http, https}（不分大小写）且主机非空的绝对 URL。
  static bool _isHttpUrl(Uri? u) {
    if (u == null) return false;
    final scheme = u.scheme.toLowerCase();
    return (scheme == 'http' || scheme == 'https') && u.host.isNotEmpty;
  }

  /// 五个本地检查的消息（三端逐字一致）。
  static String message(String code) {
    switch (code) {
      case noKey:
        return 'no key configured; logs are written locally and never uploaded';
      case keyTrimmed:
        return 'key had leading or trailing whitespace; it was trimmed';
      case keyMalformed:
        return 'key is not a valid Retriever key (format or checksum mismatch); the server will reject it';
      case keyEnvMismatch:
        return 'key environment does not match the endpoint (test key with production endpoint, or live key with staging endpoint); the server will reject it';
      case baseUrlInvalid:
        return 'baseUrl is not a valid http(s) URL; uploads will fail';
      default:
        return code;
    }
  }

  /// `key_rejected` 的消息：reason 先清洗；分钟数 = 本次暂停时长向上取整到分钟。
  static String rejectedMessage(int status, String reason, int pauseMs) {
    final minutes = ((pauseMs < 0 ? 0 : pauseMs) + 59999) ~/ 60000;
    return 'server rejected the key (HTTP $status, reason=${sanitizeReason(reason)}); uploads paused for $minutes min; logs are kept locally';
  }

  /// reason 清洗：只留 `[a-z0-9_]`（其它字符一律去掉，大写也去掉、不转小写）、最多 40 字符；清洗后为空 = `unknown`。
  static String sanitizeReason(String reason) {
    final sb = StringBuffer();
    var n = 0;
    for (var i = 0; i < reason.length; i++) {
      if (n >= _reasonMax) break;
      final c = reason.codeUnitAt(i);
      if ((c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F) {
        sb.writeCharCode(c);
        n++;
      }
    }
    return n == 0 ? 'unknown' : sb.toString();
  }
}

/// 服务端拒绝 key、本次进入鉴权暂停（`key_rejected` 诊断的素材）。
class KeyRejection {
  const KeyRejection(this.status, this.reason, this.pauseMs, this.keyFp, this.baseUrl);

  final int status;
  final String reason;
  final int pauseMs;
  final String keyFp;
  final String baseUrl;
}
