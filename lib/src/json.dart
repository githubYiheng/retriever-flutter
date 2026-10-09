// 手写紧凑 JSON（对位 Android `core/Json.kt`：JsonOut / JsonIn / Bytes）。
// 输出与 JS `JSON.stringify` 逐字节一致：只转义 `"`、`\`、C0 控制字符；`\b \t \n \f \r` 用短形式，其余 `\u00xx`
// 小写十六进制；非 ASCII 原样 UTF-8（孤立代理项写 EF BF BD）。键序由调用方决定（golden 守）。

import 'dart:typed_data';

import 'text.dart';

/// 可增长的字节输出。
class JsonOut {
  JsonOut([int capacity = 256]) : _buf = Uint8List(capacity < 16 ? 16 : capacity);

  Uint8List _buf;
  int _size = 0;

  int get size => _size;

  void _ensure(int n) {
    if (_size + n > _buf.length) {
      var cap = _buf.length * 2;
      if (cap < _size + n) cap = _size + n;
      final nb = Uint8List(cap);
      nb.setRange(0, _size, _buf);
      _buf = nb;
    }
  }

  void byte(int b) {
    _ensure(1);
    _buf[_size++] = b;
  }

  /// 只用于 ASCII 字面量与数字。
  void raw(String s) {
    _ensure(s.length);
    for (var i = 0; i < s.length; i++) {
      _buf[_size++] = s.codeUnitAt(i);
    }
  }

  void rawBytes(List<int> b, [int off = 0, int? end]) {
    final e = end ?? b.length;
    final len = e - off;
    _ensure(len);
    _buf.setRange(_size, _size + len, b, off);
    _size += len;
  }

  void string(String s) {
    byte(0x22);
    escaped(s);
    byte(0x22);
  }

  void stringOrNull(String? s) {
    if (s == null) {
      raw('null');
    } else {
      string(s);
    }
  }

  void integer(int v) => raw(v.toString());

  void boolean(bool v) => raw(v ? 'true' : 'false');

  void number(double d) => raw(jsNumber(d));

  Uint8List toBytes() => Uint8List.fromList(Uint8List.sublistView(_buf, 0, _size));

  /// 原样 UTF-8（不转义）。
  void utf8(String s) {
    _ensure(s.length * 3);
    var i = 0;
    final len = s.length;
    while (i < len) {
      final c = s.codeUnitAt(i);
      if (c < 0x80) {
        _buf[_size++] = c;
      } else {
        i = _putNonAscii(s, i, c);
      }
      i++;
    }
  }

  /// 转义后的 UTF-8（逐 UTF-8 字节转义，非 ASCII 原样）。
  void escaped(String s) {
    _ensure(s.length * 6);
    var i = 0;
    final len = s.length;
    while (i < len) {
      final c = s.codeUnitAt(i);
      if (c < 0x80) {
        switch (c) {
          case 0x22:
            _buf[_size++] = 0x5C;
            _buf[_size++] = 0x22;
          case 0x5C:
            _buf[_size++] = 0x5C;
            _buf[_size++] = 0x5C;
          case 0x08:
            _buf[_size++] = 0x5C;
            _buf[_size++] = 0x62;
          case 0x09:
            _buf[_size++] = 0x5C;
            _buf[_size++] = 0x74;
          case 0x0A:
            _buf[_size++] = 0x5C;
            _buf[_size++] = 0x6E;
          case 0x0C:
            _buf[_size++] = 0x5C;
            _buf[_size++] = 0x66;
          case 0x0D:
            _buf[_size++] = 0x5C;
            _buf[_size++] = 0x72;
          default:
            if (c < 0x20) {
              _buf[_size++] = 0x5C;
              _buf[_size++] = 0x75;
              _buf[_size++] = 0x30;
              _buf[_size++] = 0x30;
              _buf[_size++] = _hex[c >> 4];
              _buf[_size++] = _hex[c & 0xF];
            } else {
              _buf[_size++] = c;
            }
        }
      } else {
        i = _putNonAscii(s, i, c);
      }
      i++;
    }
  }

  /// 写一个非 ASCII 码点（调用方已 ensure）；返回最后消费的下标。
  int _putNonAscii(String s, int i, int c) {
    if (c < 0x800) {
      _buf[_size++] = 0xC0 | (c >> 6);
      _buf[_size++] = 0x80 | (c & 0x3F);
      return i;
    }
    if (Text.isHigh(c) && i + 1 < s.length && Text.isLow(s.codeUnitAt(i + 1))) {
      final cp = 0x10000 + ((c - 0xD800) << 10) + (s.codeUnitAt(i + 1) - 0xDC00);
      _buf[_size++] = 0xF0 | (cp >> 18);
      _buf[_size++] = 0x80 | ((cp >> 12) & 0x3F);
      _buf[_size++] = 0x80 | ((cp >> 6) & 0x3F);
      _buf[_size++] = 0x80 | (cp & 0x3F);
      return i + 1;
    }
    final v = (Text.isHigh(c) || Text.isLow(c)) ? 0xFFFD : c;
    _buf[_size++] = 0xE0 | (v >> 12);
    _buf[_size++] = 0x80 | ((v >> 6) & 0x3F);
    _buf[_size++] = 0x80 | (v & 0x3F);
    return i;
  }

  static const List<int> _hex = [
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, //
    0x61, 0x62, 0x63, 0x64, 0x65, 0x66,
  ];

  /// 字符串值（含两侧引号）序列化后的字节数。
  static int escapedLength(String s) {
    var n = 2;
    var i = 0;
    final len = s.length;
    while (i < len) {
      final c = s.codeUnitAt(i);
      if (c < 0x80) {
        n += Text.escapedAsciiWidth(c);
      } else if (c < 0x800) {
        n += 2;
      } else if (Text.isHigh(c) && i + 1 < len && Text.isLow(s.codeUnitAt(i + 1))) {
        n += 4;
        i++;
      } else {
        n += 3;
      }
      i++;
    }
    return n;
  }

  /// ECMAScript Number::toString（JSON.stringify 的数字格式）。调用方保证 d 有限。
  /// 数字串取 Dart `double.toString`（最短往返，与 JS 同一组数字），再按 JS 规则排版。
  static String jsNumber(double d) {
    if (d == 0.0) return '0';
    if (d == d.roundToDouble() && d.abs() < 9007199254740992.0) return d.toInt().toString();
    final desc = d.abs().toString();
    var mantissa = desc;
    var exp = 0;
    final e = desc.indexOf(RegExp('[eE]'));
    if (e >= 0) {
      mantissa = desc.substring(0, e);
      exp = int.parse(desc.substring(e + 1).replaceFirst('+', ''));
    }
    var intPart = mantissa;
    var fracPart = '';
    final dot = mantissa.indexOf('.');
    if (dot >= 0) {
      intPart = mantissa.substring(0, dot);
      fracPart = mantissa.substring(dot + 1);
    }
    var digits = intPart + fracPart;
    var n = intPart.length + exp;
    var lead = 0;
    while (lead < digits.length - 1 && digits.codeUnitAt(lead) == 0x30) {
      lead++;
      n -= 1;
    }
    digits = digits.substring(lead);
    var end = digits.length;
    while (end > 1 && digits.codeUnitAt(end - 1) == 0x30) {
      end--;
    }
    digits = digits.substring(0, end);
    final k = digits.length;
    String out;
    if (n >= k && n <= 21) {
      out = digits + '0' * (n - k);
    } else if (n >= 1 && n <= 21) {
      out = '${digits.substring(0, n)}.${digits.substring(n)}';
    } else if (n > -6 && n <= 0) {
      out = '0.${'0' * (-n)}$digits';
    } else {
      final ee = n - 1;
      final sign = ee >= 0 ? '+' : '-';
      out = k == 1 ? '${digits}e$sign${ee.abs()}' : '${digits[0]}.${digits.substring(1)}e$sign${ee.abs()}';
    }
    return d < 0 ? '-$out' : out;
  }
}

/// 读 JSON（本地状态文件、信封头、服务端响应）：递归下降解析，严格（同 Android `JsonIn`）。
/// 结果：对象 = `Map<String, Object?>`（插入序，重复键后者覆盖，同 JS）、数组 = `List<Object?>`、
/// 数字 = `double`（同 JS `typeof number`）、布尔 = `bool`、null = `null`。解析失败返回 [invalid]。
abstract final class JsonIn {
  static const Object invalid = _Invalid();

  static Object? parseBytes(List<int> bytes) => parse(Text.decode(bytes));

  static Object? parse(String text) {
    try {
      final p = _Parser(text);
      p.ws();
      final v = p.value(0);
      p.ws();
      return p.i != text.length ? invalid : v;
    } on _JsonError {
      return invalid;
    } on FormatException {
      return invalid;
    }
  }

  static Map<String, Object?>? obj(List<int> bytes) => asObj(parseBytes(bytes));

  static Map<String, Object?>? objText(String text) => asObj(parse(text));

  static Map<String, Object?>? asObj(Object? v) => v is Map<String, Object?> ? v : null;

  static List<Object?>? asList(Object? v) => v is List<Object?> ? v : null;

  static double? dbl(Object? v) => v is double ? v : null;

  static bool? boolean(Object? v) => v is bool ? v : null;

  static String? string(Object? v) => v is String ? v : null;

  /// 有限、整数、|v| ≤ 2^53 − 1 的数（与 iOS / Android 同口径）。
  static int? int64(Object? v) {
    if (v is! double) return null;
    if (v.isNaN || v.isInfinite || v != v.roundToDouble() || v.abs() > 9007199254740991.0) return null;
    return v.toInt();
  }
}

class _Invalid {
  const _Invalid();

  @override
  String toString() => 'JsonIn.invalid';
}

class _JsonError implements Exception {
  const _JsonError();
}

class _Parser {
  _Parser(this.s);

  final String s;
  int i = 0;

  void ws() {
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
        i++;
      } else {
        break;
      }
    }
  }

  Object? value(int depth) {
    if (depth > 512 || i >= s.length) throw const _JsonError();
    switch (s.codeUnitAt(i)) {
      case 0x7B: // {
        return obj(depth);
      case 0x5B: // [
        return arr(depth);
      case 0x22: // "
        return str();
      case 0x74: // t
        return lit('true', true);
      case 0x66: // f
        return lit('false', false);
      case 0x6E: // n
        return lit('null', null);
      default:
        return num();
    }
  }

  Object? lit(String w, Object? v) {
    if (!s.startsWith(w, i)) throw const _JsonError();
    i += w.length;
    return v;
  }

  Map<String, Object?> obj(int depth) {
    i++;
    final m = <String, Object?>{};
    ws();
    if (i < s.length && s.codeUnitAt(i) == 0x7D) {
      i++;
      return m;
    }
    while (true) {
      ws();
      if (i >= s.length || s.codeUnitAt(i) != 0x22) throw const _JsonError();
      final k = str();
      ws();
      if (i >= s.length || s.codeUnitAt(i) != 0x3A) throw const _JsonError();
      i++;
      ws();
      // 重复键：后者覆盖（同 JS），但保留第一次出现的位置（同 LinkedHashMap.put）
      m[k] = value(depth + 1);
      ws();
      if (i >= s.length) throw const _JsonError();
      final c = s.codeUnitAt(i);
      if (c == 0x2C) {
        i++;
        continue;
      }
      if (c == 0x7D) {
        i++;
        return m;
      }
      throw const _JsonError();
    }
  }

  List<Object?> arr(int depth) {
    i++;
    final l = <Object?>[];
    ws();
    if (i < s.length && s.codeUnitAt(i) == 0x5D) {
      i++;
      return l;
    }
    while (true) {
      ws();
      l.add(value(depth + 1));
      ws();
      if (i >= s.length) throw const _JsonError();
      final c = s.codeUnitAt(i);
      if (c == 0x2C) {
        i++;
        continue;
      }
      if (c == 0x5D) {
        i++;
        return l;
      }
      throw const _JsonError();
    }
  }

  String str() {
    i++;
    final sb = StringBuffer();
    var runStart = i;
    while (true) {
      if (i >= s.length) throw const _JsonError();
      final c = s.codeUnitAt(i);
      if (c == 0x22) {
        if (i > runStart) sb.write(s.substring(runStart, i));
        i++;
        return sb.toString();
      }
      if (c == 0x5C) {
        if (i > runStart) sb.write(s.substring(runStart, i));
        i++;
        if (i >= s.length) throw const _JsonError();
        final e = s.codeUnitAt(i++);
        switch (e) {
          case 0x22:
            sb.writeCharCode(0x22);
          case 0x5C:
            sb.writeCharCode(0x5C);
          case 0x2F:
            sb.writeCharCode(0x2F);
          case 0x62:
            sb.writeCharCode(0x08);
          case 0x66:
            sb.writeCharCode(0x0C);
          case 0x6E:
            sb.writeCharCode(0x0A);
          case 0x72:
            sb.writeCharCode(0x0D);
          case 0x74:
            sb.writeCharCode(0x09);
          case 0x75:
            if (i + 4 > s.length) throw const _JsonError();
            var v = 0;
            for (var k = 0; k < 4; k++) {
              final h = _hexVal(s.codeUnitAt(i + k));
              if (h < 0) throw const _JsonError();
              v = (v << 4) | h;
            }
            i += 4;
            sb.writeCharCode(v);
          default:
            throw const _JsonError();
        }
        runStart = i;
        continue;
      }
      if (c < 0x20) throw const _JsonError();
      i++;
    }
  }

  static int _hexVal(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    return -1;
  }

  static bool _digit(int c) => c >= 0x30 && c <= 0x39;

  double num() {
    final start = i;
    if (i < s.length && s.codeUnitAt(i) == 0x2D) i++;
    if (i >= s.length) throw const _JsonError();
    final c0 = s.codeUnitAt(i);
    if (c0 == 0x30) {
      i++;
    } else if (c0 >= 0x31 && c0 <= 0x39) {
      while (i < s.length && _digit(s.codeUnitAt(i))) {
        i++;
      }
    } else {
      throw const _JsonError();
    }
    if (i < s.length && s.codeUnitAt(i) == 0x2E) {
      i++;
      final f = i;
      while (i < s.length && _digit(s.codeUnitAt(i))) {
        i++;
      }
      if (i == f) throw const _JsonError();
    }
    if (i < s.length && (s.codeUnitAt(i) == 0x65 || s.codeUnitAt(i) == 0x45)) {
      i++;
      if (i < s.length && (s.codeUnitAt(i) == 0x2B || s.codeUnitAt(i) == 0x2D)) i++;
      final f = i;
      while (i < s.length && _digit(s.codeUnitAt(i))) {
        i++;
      }
      if (i == f) throw const _JsonError();
    }
    return double.parse(s.substring(start, i));
  }
}

/// 字节级小工具：在我们写出的 JSON 文本里找模式（字符串值内的 `"` 一律被转义，
/// 所以以 `"` 开头的键模式不会在字符串值内部误中）。
abstract final class Bytes {
  static Uint8List ascii(String s) => Text.utf8Bytes(s);

  static int find(List<int> pattern, List<int> hay, [int from = 0, int? to]) {
    final end = to ?? hay.length;
    if (pattern.isEmpty || end - from < pattern.length) return -1;
    final first = pattern[0];
    final last = end - pattern.length;
    var i = from;
    while (i <= last) {
      if (hay[i] == first) {
        var j = 1;
        while (j < pattern.length && hay[i + j] == pattern[j]) {
          j++;
        }
        if (j == pattern.length) return i;
      }
      i++;
    }
    return -1;
  }

  static bool contains(List<int> pattern, List<int> hay, [int from = 0, int? to]) => find(pattern, hay, from, to) >= 0;

  static bool hasSuffix(List<int> hay, int from, int to, List<int> suffix) {
    if (to - from < suffix.length) return false;
    final base = to - suffix.length;
    for (var k = 0; k < suffix.length; k++) {
      if (hay[base + k] != suffix[k]) return false;
    }
    return true;
  }

  static bool startsWith(List<int> hay, int from, int to, List<int> prefix) {
    if (to - from < prefix.length) return false;
    for (var k = 0; k < prefix.length; k++) {
      if (hay[from + k] != prefix[k]) return false;
    }
    return true;
  }

  static Uint8List concat(List<List<int>> parts) {
    var n = 0;
    for (final p in parts) {
      n += p.length;
    }
    final out = Uint8List(n);
    var o = 0;
    for (final p in parts) {
      out.setRange(o, o + p.length, p);
      o += p.length;
    }
    return out;
  }

  static bool equals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
