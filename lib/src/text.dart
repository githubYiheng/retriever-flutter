// UTF-8 字节核算与码点边界截断（方案开头：所有长度按 UTF-8 字节，只在码点边界截断）。对位 Android `core/Text.kt`。
//
// Dart 字符串与 Java 一样是 UTF-16，可能含孤立代理项：一律按 U+FFFD（3 字节）计、编码时写 `EF BF BD`
// —— 与服务端 `utf8Len` / `TextEncoder` 逐字一致（`dart:convert` 的 utf8.encode 也这样编码孤立代理项）。

import 'dart:convert';
import 'dart:typed_data';

import 'limits.dart';

/// 截断结果：截后的串与是否截过。
typedef Cut = ({String s, bool truncated});

abstract final class Text {
  /// 与 packages/core `utf8Len` 逐字一致：只有「高位代理后紧跟低位代理」计 4 字节；孤立代理项 3 字节。
  static int utf8Len(String s) {
    var n = 0;
    var i = 0;
    final len = s.length;
    while (i < len) {
      final c = s.codeUnitAt(i);
      if (c < 0x80) {
        n += 1;
      } else if (c < 0x800) {
        n += 2;
      } else if (isHigh(c) && i + 1 < len && isLow(s.codeUnitAt(i + 1))) {
        n += 4;
        i++;
      } else {
        n += 3;
      }
      i++;
    }
    return n;
  }

  static bool isHigh(int c) => c >= 0xD800 && c <= 0xDBFF;

  static bool isLow(int c) => c >= 0xDC00 && c <= 0xDFFF;

  /// 位置 i 处码点占用的 UTF-16 单元数（代理对 = 2）。
  static int _unitsAt(String s, int i) =>
      isHigh(s.codeUnitAt(i)) && i + 1 < s.length && isLow(s.codeUnitAt(i + 1)) ? 2 : 1;

  /// 位置 i 处码点的 UTF-8 宽度。
  static int _widthAt(String s, int i) {
    final c = s.codeUnitAt(i);
    if (c < 0x80) return 1;
    if (c < 0x800) return 2;
    if (isHigh(c) && i + 1 < s.length && isLow(s.codeUnitAt(i + 1))) return 4;
    return 3;
  }

  /// 位置 i 处码点「JSON 转义后」的字节数（与逐 UTF-8 字节转义的 JsonOut 一致）。
  static int _escapedWidthAt(String s, int i) {
    final c = s.codeUnitAt(i);
    if (c < 0x80) return escapedAsciiWidth(c);
    return _widthAt(s, i);
  }

  static int escapedAsciiWidth(int c) {
    switch (c) {
      case 0x22:
      case 0x5C:
      case 0x08:
      case 0x09:
      case 0x0A:
      case 0x0C:
      case 0x0D:
        return 2;
    }
    if (c < 0x20) return 6;
    return 1;
  }

  /// 截到 ≤ maxBytes 字节（码点边界）。
  static Cut truncate(String s, int maxBytes) {
    if (s.length * 3 <= maxBytes || utf8Len(s) <= maxBytes) return (s: s, truncated: false);
    var n = 0;
    var i = 0;
    while (i < s.length) {
      final w = _widthAt(s, i);
      if (n + w > maxBytes) break;
      n += w;
      i += _unitsAt(s, i);
    }
    return (s: s.substring(0, i), truncated: true);
  }

  /// 保留尾部 ≤ maxBytes 字节（码点边界）。
  static String suffix(String s, int maxBytes) {
    if (utf8Len(s) <= maxBytes) return s;
    var n = 0;
    var start = s.length;
    while (start > 0) {
      final prev = _prevStart(s, start);
      final w = _widthAt(s, prev);
      if (n + w > maxBytes) break;
      n += w;
      start = prev;
    }
    return s.substring(start);
  }

  /// 截到「JSON 转义后（不含引号）」≤ budget 字节，码点边界。
  static String truncateEscaped(String s, int budget) {
    if (budget <= 0) return '';
    var n = 0;
    var i = 0;
    while (i < s.length) {
      final w = _escapedWidthAt(s, i);
      if (n + w > budget) break;
      n += w;
      i += _unitsAt(s, i);
    }
    return s.substring(0, i);
  }

  /// 保留尾部「JSON 转义后（不含引号）」≤ budget 字节，码点边界。
  static String suffixEscaped(String s, int budget) {
    if (budget <= 0) return '';
    var n = 0;
    var start = s.length;
    while (start > 0) {
      final prev = _prevStart(s, start);
      final w = _escapedWidthAt(s, prev);
      if (n + w > budget) break;
      n += w;
      start = prev;
    }
    return s.substring(start);
  }

  /// end 之前那个码点的起点（代理对整体后退）。
  static int _prevStart(String s, int end) {
    final p = end - 1;
    if (p > 0 && isLow(s.codeUnitAt(p)) && isHigh(s.codeUnitAt(p - 1))) return p - 1;
    return p;
  }

  /// 孤立代理项换成 U+FFFD（用于 user_id / device 等会被读回比较的值）。
  static String fixSurrogates(String s) {
    var i = 0;
    var bad = false;
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (isHigh(c) && i + 1 < s.length && isLow(s.codeUnitAt(i + 1))) {
        i += 2;
        continue;
      }
      if (isHigh(c) || isLow(c)) {
        bad = true;
        break;
      }
      i++;
    }
    if (!bad) return s;
    final sb = StringBuffer();
    i = 0;
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (isHigh(c) && i + 1 < s.length && isLow(s.codeUnitAt(i + 1))) {
        sb.writeCharCode(c);
        sb.writeCharCode(s.codeUnitAt(i + 1));
        i += 2;
        continue;
      }
      sb.writeCharCode(isHigh(c) || isLow(c) ? 0xFFFD : c);
      i++;
    }
    return sb.toString();
  }

  /// user_id：≤ 128 B、不含 C0 / DEL / C1 控制字符（服务端校验规则；在源头清洗）。
  /// 清洗后为空（`""`、纯空白、纯控制字符）= null（ADR 0024 决定 10）；空白 = [trimmable]（同 Android `isBlank()` / `Char.isWhitespace`，
  /// 不用 `String.trim`：它还会剥 U+FEFF，审计 #5）。
  static String? sanitizeUserId(String? s) {
    if (s == null) return null;
    final fixed = fixSurrogates(s);
    final sb = StringBuffer();
    for (var i = 0; i < fixed.length; i++) {
      final c = fixed.codeUnitAt(i);
      if (!isControl(c)) sb.writeCharCode(c);
    }
    final out = truncate(sb.toString(), Limits.userIdBytes).s;
    return isBlank(out) ? null : out;
  }

  /// 全部码点都是 [trimmable]（含空串）。
  static bool isBlank(String s) {
    for (var i = 0; i < s.length; i++) {
      if (!trimmable(s.codeUnitAt(i))) return false;
    }
    return true;
  }

  /// 空白与控制字符（修剪 / 空白判定的唯一口径；同 Android `ConfigCheck.trimmable`）：码点 ≤ 0x20、0x7F–0x9F（C0 / 空格 / DEL / C1），
  /// 以及 Unicode White_Space（U+00A0、U+1680、U+2000–U+200A、U+2028、U+2029、U+202F、U+205F、U+3000；其余 White_Space 已落在前两段）。
  /// 都在 BMP，代理项不会命中。U+FEFF（Cf）不算。
  static bool trimmable(int c) =>
      c <= 0x20 ||
      (c >= 0x7F && c <= 0x9F) ||
      c == 0xA0 ||
      c == 0x1680 ||
      (c >= 0x2000 && c <= 0x200A) ||
      c == 0x2028 ||
      c == 0x2029 ||
      c == 0x202F ||
      c == 0x205F ||
      c == 0x3000;

  static bool isControl(int v) => v <= 0x1F || (v >= 0x7F && v <= 0x9F);

  /// UTF-8 编码（孤立代理项 → EF BF BD）。
  static Uint8List utf8Bytes(String s) => utf8.encode(s);

  /// UTF-8 解码（坏字节 → U+FFFD，同 Java `String(bytes, UTF_8)`）。
  static String decode(List<int> b, [int start = 0, int? end]) =>
      utf8.decode(start == 0 && end == null ? b : b.sublist(start, end), allowMalformed: true);
}
