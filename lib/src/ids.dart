// 标识符（packages/core/src/ids.ts）：UUID_RE 整串匹配、RFC 4122 UUIDv5、确定性 batch_id、key 指纹、CRC-32、
// 设备摘要、supportCode、日期。对位 Android `core/Ids.kt`（Ids + Day）与 `ConfigCheck.crc32Hex`、`Engine.digest`。

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'json.dart';
import 'limits.dart';
import 'model.dart';
import 'text.dart';

enum BatchKind {
  primary('primary'),
  backfill('backfill');

  const BatchKind(this.wire);

  final String wire;

  static BatchKind? of(String? s) {
    for (final k in values) {
      if (k.wire == s) return k;
    }
    return null;
  }
}

abstract final class Ids {
  /// Retriever 的 UUIDv5 命名空间（固定常量，永不改）。
  static const String namespace = '9a1d7c3e-5b2f-4e8a-8c6d-2f1e0b3a7d95';

  static const String _hex = '0123456789abcdef';

  /// `^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$`，整串匹配。
  static bool isUuid(String s) {
    if (s.length != 36) return false;
    for (var i = 0; i < 36; i++) {
      final c = s.codeUnitAt(i);
      switch (i) {
        case 8:
        case 13:
        case 18:
        case 23:
          if (c != 0x2D) return false;
        case 14:
          if (c < 0x31 || c > 0x38) return false;
        default:
          if (!((c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66))) return false;
      }
    }
    return true;
  }

  static Uint8List? uuidBytes(String s) {
    final hex = s.replaceAll('-', '');
    if (hex.length != 32) return null;
    final out = Uint8List(16);
    for (var k = 0; k < 16; k++) {
      final hi = _hexVal(hex.codeUnitAt(2 * k));
      final lo = _hexVal(hex.codeUnitAt(2 * k + 1));
      if (hi < 0 || lo < 0) return null;
      out[k] = (hi << 4) | lo;
    }
    return out;
  }

  static int _hexVal(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    return -1;
  }

  static String format(List<int> b) {
    final sb = StringBuffer();
    for (var k = 0; k < b.length; k++) {
      if (k == 4 || k == 6 || k == 8 || k == 10) sb.write('-');
      final x = b[k] & 0xFF;
      sb
        ..write(_hex[x >> 4])
        ..write(_hex[x & 0xF]);
    }
    return sb.toString();
  }

  static String hexOf(List<int> b, [int? count]) {
    final n = count ?? b.length;
    final sb = StringBuffer();
    for (var k = 0; k < n; k++) {
      final x = b[k] & 0xFF;
      sb
        ..write(_hex[x >> 4])
        ..write(_hex[x & 0xF]);
    }
    return sb.toString();
  }

  /// RFC 4122 UUIDv5（SHA-1），name 按 UTF-8。namespace 必须满足 isUuid。
  static String? uuidv5(String ns, String name) {
    if (!isUuid(ns)) return null;
    final nsb = uuidBytes(ns);
    if (nsb == null) return null;
    final digest = crypto.sha1.convert(Bytes.concat([nsb, Text.utf8Bytes(name)])).bytes;
    final b = Uint8List.fromList(digest.sublist(0, 16));
    b[6] = (b[6] & 0x0F) | 0x50;
    b[8] = (b[8] & 0x3F) | 0x80;
    return format(b);
  }

  /// `${install_id}:${session_id}:${kind}:${n}`；n = primary 的 oseq_from / backfill 的 seg_no。
  static String batchIdName(String installId, String sessionId, BatchKind kind, int n) =>
      '$installId:$sessionId:${kind.wire}:$n';

  /// 输入不合规（非小写 UUID、n 为负）返回 null（TS 侧抛错）。
  static String? batchId(String installId, String sessionId, BatchKind kind, int n) {
    if (!isUuid(installId) || !isUuid(sessionId) || n < 0) return null;
    return uuidv5(namespace, batchIdName(installId, sessionId, kind, n));
  }

  /// backfill 段超 768 KB 按 seq 切多批时的 batch_id（`…:backfill:<seg_no>:<seq_from>`）。
  static String? backfillSplitBatchId(String installId, String sessionId, int segNo, int seqFrom) {
    if (!isUuid(installId) || !isUuid(sessionId) || segNo < 0 || seqFrom < 1) return null;
    return uuidv5(namespace, '$installId:$sessionId:backfill:$segNo:$seqFrom');
  }

  /// 413 半批：`${install_id}:${session_id}:primary:${oseq_from}:${oseq_to}`。
  static String splitBatchIdName(String installId, String sessionId, int oseqFrom, int oseqTo) =>
      '$installId:$sessionId:primary:$oseqFrom:$oseqTo';

  /// 413 切分出的半批 batch_id（ADR 0019 决定 11）。输入不合规返回 null。
  static String? splitBatchId(String installId, String sessionId, int oseqFrom, int oseqTo) {
    if (!isUuid(installId) || !isUuid(sessionId) || oseqFrom < 1 || oseqTo < oseqFrom) return null;
    return uuidv5(namespace, splitBatchIdName(installId, sessionId, oseqFrom, oseqTo));
  }

  static Random? _secure;
  static final Random _fallback = Random();

  static Random get _rng {
    if (_secure != null) return _secure!;
    try {
      _secure = Random.secure();
      return _secure!;
    } on UnsupportedError {
      return _fallback;
    }
  }

  /// 新的随机 UUID（v4，小写）。
  static String newV4() {
    final r = _rng;
    final b = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      b[i] = r.nextInt(256);
    }
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    return format(b);
  }

  /// key 指纹（ADR 0024 决定 7）：`sha256(key 的 UTF-8)` 的前 16 位小写十六进制；key 为空 → 空串。
  static String keyFingerprint(String key) {
    if (key.isEmpty) return '';
    return hexOf(crypto.sha256.convert(Text.utf8Bytes(key)).bytes, 8);
  }

  /// 设备摘要：设备块紧凑 JSON 的 sha256 前 16 hex（mapping 是否变化的判据；对位 Android `Engine.digest`）。
  static String deviceDigest(Device d) {
    final o = JsonOut();
    d.encode(o);
    return hexOf(crypto.sha256.convert(o.toBytes()).bytes, 8);
  }

  /// supportCode = install_id 前 8 位 + "-" + session_no。
  static String supportCode(String installId, int sessionNo) =>
      '${installId.length >= 8 ? installId.substring(0, 8) : installId}-$sessionNo';

  /// CRC-32/IEEE（反射多项式 0xEDB88320，init / xorout 0xFFFFFFFF）。
  static int crc32(List<int> bytes) {
    var c = 0xFFFFFFFF;
    final t = _crcTable;
    for (var i = 0; i < bytes.length; i++) {
      c = t[(c ^ bytes[i]) & 0xFF] ^ (c >> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  /// 8 位小写十六进制。
  static String crc32Hex(List<int> bytes) => crc32(bytes).toRadixString(16).padLeft(8, '0');

  static final Uint32List _crcTable = () {
    final t = Uint32List(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      t[n] = c;
    }
    return t;
  }();
}

/// 日期（packages/core/src/object-key.ts）：ms UTC → `YYYY-MM-DD`；客户端 day 规则。
abstract final class Day {
  static String fromMs(int ms) {
    // floor 除法（负数也正确），再用 Howard Hinnant 的 civil_from_days（与 iOS / Android 同算法）。
    final days = _floorDiv(ms, ClientConstants.dayMs);
    final z = days + 719468;
    final era = (z >= 0 ? z : z - 146096) ~/ 146097;
    final doe = z - era * 146097;
    final yoe = (doe - doe ~/ 1460 + doe ~/ 36524 - doe ~/ 146096) ~/ 365;
    var y = yoe + era * 400;
    final doy = doe - (365 * yoe + yoe ~/ 4 - yoe ~/ 100);
    final mp = (5 * doy + 2) ~/ 153;
    final d = doy - (153 * mp + 2) ~/ 5 + 1;
    final m = mp < 10 ? mp + 3 : mp - 9;
    if (m <= 2) y += 1;
    return '${_pad(y, 4)}-${_pad(m, 2)}-${_pad(d, 2)}';
  }

  static int _floorDiv(int a, int b) {
    final q = a ~/ b;
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q;
  }

  static String _pad(int v, int w) {
    final s = v.toString();
    return s.length >= w ? s : '0' * (w - s.length) + s;
  }

  /// day = UTC 日期(clamp(批内最早行 ts, created − 30 d, created))。
  static String clientDay(int tsMinMs, int createdMs) {
    final lo = createdMs - Limits.dayClampPastDaysClient * ClientConstants.dayMs;
    var t = tsMinMs < lo ? lo : tsMinMs;
    if (t > createdMs) t = createdMs;
    return fromMs(t);
  }
}
