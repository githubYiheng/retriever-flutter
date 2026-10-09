// 行 JSON 手写编码（§3.1）。对位 Android `core/LineEncoder.kt`，与 iOS `LineEncoder.swift` 逐字一致。
//
// 字段顺序固定：seq, oseq, ts, level, msg, tag, attrs, exc, ctx, synthetic, truncated；可选字段缺省不输出键。
// 本编码器只产出 seq / oseq 之后的部分（`"ts":…}` + `\n`），seq / oseq 前缀在写入时拼上；`ctx` 只在物化进信封时插入。

import 'dart:typed_data';

import 'json.dart';
import 'limits.dart';
import 'model.dart';
import 'public_api.dart';
import 'text.dart';

class Encoded {
  const Encoded(this.body, this.truncated);

  /// `"ts":…}\n`
  final Uint8List body;
  final bool truncated;
}

abstract final class LineEncoder {
  /// 行 JSON 里 body 之外可能出现的最大字节：`{"seq":<16 位>,"oseq":<16 位>,`（48 B）+ 物化时插入的 `"ctx":true,`（11 B）。
  static const int reservedBytes = 48 + 11;
  static const int bodyBudget = Limits.lineSerializedBytes - reservedBytes;

  /// 从宿主错误对象构造 exc（§3.1）：type = `runtimeType`、message = `toString()`、stack = 栈文本（空串视同无）。
  /// `toString()` 抛异常 → message 写占位串、返回值第二项 = true（该行标 truncated）；取栈抛任何东西 → 无栈。绝不抛给宿主。
  static (LogException, bool) exception(Object error, StackTrace? stackTrace) {
    var bad = false;
    String type;
    try {
      type = error.runtimeType.toString();
    } catch (_) {
      type = 'Object';
    }
    String message;
    try {
      message = error.toString();
    } catch (_) {
      bad = true;
      message = ClientConstants.unprintable;
    }
    String stack;
    try {
      final st = stackTrace ?? (error is Error ? error.stackTrace : null);
      stack = st?.toString() ?? '';
    } catch (_) {
      stack = '';
    }
    return (LogException(type: type, message: message, stack: stack.isEmpty ? null : stack), bad);
  }

  /// 收编时给 redact 钩子看的行：把 pre 文件里的行体（`"ts":…}`，可带结尾 `\n`）解回 [LogLine]。
  /// 返回 (行, synthetic, truncated)；解不出返回 null（该行按坏记录跳过）。attrs 的数字解成 double。
  static (LogLine, bool, bool)? decodeBody(List<int> body) {
    var end = body.length;
    if (end > 0 && body[end - 1] == 0x0A) end -= 1;
    final buf = Uint8List(end + 1);
    buf[0] = 0x7B;
    buf.setRange(1, end + 1, body);
    final o = JsonIn.obj(buf);
    if (o == null) return null;
    final ts = JsonIn.int64(o['ts']);
    if (ts == null) return null;
    final lv = o['level'];
    final level = LogLevels.ofWire(lv is String ? lv : null);
    if (level == null) return null;
    final msg = o['msg'];
    if (msg is! String) return null;
    final tag = o['tag'];
    final attrs = JsonIn.asObj(o['attrs']);
    final e = JsonIn.asObj(o['exc']);
    LogException? exc;
    if (e != null) {
      final t = e['type'], m = e['message'], s = e['stack'];
      exc = LogException(type: t is String ? t : '', message: m is String ? m : '', stack: s is String ? s : null);
    }
    return (
      LogLine(ts: ts, level: level, msg: msg, tag: tag is String ? tag : null, attrs: attrs, exc: exc),
      o['synthetic'] == true,
      o['truncated'] == true,
    );
  }

  /// `forceTruncated`：行在编码之前就已经丢过东西（值求值出错、收编前已截断）。
  static Encoded encode(LogLine line, {bool synthetic = false, bool forceTruncated = false}) {
    var truncated = forceTruncated;

    final mc = Text.truncate(line.msg, Limits.lineMsgBytes);
    var msg = mc.s;
    truncated = truncated || mc.truncated;

    String? tag;
    final lt = line.tag;
    if (lt != null) {
      final tc = Text.truncate(lt, Limits.lineTagBytes);
      tag = tc.s;
      truncated = truncated || tc.truncated;
    }

    Uint8List? attrsJson;
    final a = line.attrs;
    if (a != null) {
      // 宿主的 map：length / 迭代都可能抛，全部在 encodeAttrs 里兜住
      (Uint8List?, bool) r;
      try {
        r = encodeAttrs(a);
      } catch (_) {
        r = (null, true);
      }
      attrsJson = r.$1;
      truncated = truncated || r.$2;
    }

    LogException? exc;
    final le = line.exc;
    if (le != null) {
      final t1 = Text.truncate(le.type, Limits.lineExcTypeBytes);
      final t2 = Text.truncate(le.message, Limits.lineExcMessageBytes);
      var stack = le.stack;
      var t3 = false;
      if (stack != null && Text.utf8Len(stack) > Limits.lineExcStackBytes) {
        stack = headTail(stack);
        t3 = true;
      }
      exc = LogException(type: t1.s, message: t2.s, stack: stack);
      truncated = truncated || t1.truncated || t2.truncated || t3;
    }

    // 单行上限：超出先删 attrs、再截 stack、再截 msg（按转义后字节核算）。
    var body = build(line.ts, line.level, msg, tag, attrsJson, exc, synthetic, truncated);
    if (body.length - 1 > bodyBudget && attrsJson != null) {
      attrsJson = null;
      truncated = true;
      body = build(line.ts, line.level, msg, tag, null, exc, synthetic, true);
    }
    final e0 = exc;
    final s0 = e0?.stack;
    if (body.length - 1 > bodyBudget && e0 != null && s0 != null) {
      // 再截 stack：仍按「头 + 标记 + 尾」保住 `Caused by`，按转义后字节核算
      final excess = body.length - 1 - bodyBudget;
      final current = JsonOut.escapedLength(s0) - 2;
      exc = e0.copyWith(stack: headTailEscaped(s0, current - excess));
      truncated = true;
      body = build(line.ts, line.level, msg, tag, null, exc, synthetic, true);
    }
    if (body.length - 1 > bodyBudget) {
      final excess = body.length - 1 - bodyBudget;
      final current = JsonOut.escapedLength(msg) - 2;
      final b = current - excess;
      msg = Text.truncateEscaped(msg, b < 0 ? 0 : b);
      truncated = true;
      body = build(line.ts, line.level, msg, tag, null, exc, synthetic, true);
    }
    return Encoded(body, truncated);
  }

  /// stack 超长：头 8 KB + 标记 + 尾（8 KB − 标记字节，保证总长 ≤ 16 KB 的服务端硬上限）。
  static String headTail(String s) {
    const marker = ClientConstants.stackMarker;
    final head = Text.truncate(s, Limits.lineExcStackHeadBytes).s;
    final tailBudget = Limits.lineExcStackBytes - Text.utf8Len(head) - Text.utf8Len(marker);
    final tail = Text.suffix(s, Limits.lineExcStackTailBytes < tailBudget ? Limits.lineExcStackTailBytes : tailBudget);
    return head + marker + tail;
  }

  /// 转义后 ≤ budget 的「头 + 标记 + 尾」；budget 连标记都放不下时返回 null（去掉 stack）。
  static String? headTailEscaped(String s, int budget) {
    const marker = ClientConstants.stackMarker;
    final markerEsc = JsonOut.escapedLength(marker) - 2;
    final room = budget - markerEsc;
    if (room < 2) return budget > 0 ? Text.truncateEscaped(s, budget) : null;
    final head = Text.truncateEscaped(s, room ~/ 2);
    final headEsc = JsonOut.escapedLength(head) - 2;
    final tail = Text.suffixEscaped(s, room - headEsc);
    return head + marker + tail;
  }

  static const int _valueOk = 0;
  static const int _valueSkip = 1;
  static const int _valueUnprintable = 2;

  /// attrs：先对宿主的 map 取浅拷贝快照，且只取前 32 个键（迭代顺序；先截到上限再排序）；键按字典序（UTF-16 码元序，同 Java）；
  /// 贪心装入直到序列化 ≤ 4096 B。值：String / bool / null 原样；整数（int / BigInt）|v| ≤ 2^53 − 1 输出 JSON 数字、超出输出十进制字符串
  /// （ADR 0020 决定 3，golden `attrs.json`；不打 truncated）；double 按 JS 数字格式（非有限数转 "NaN" / "Infinity" / "-Infinity"）；
  /// Iterable / Map 渲染成紧凑 JSON 文本作字符串值（有上限：文本超过 4096 B 跳过该键、嵌套超过 8 层写占位串）；其它 `toString()`。
  /// 逐值防护（ADR 0024 决定 5）：单个值求值抛任何东西（toString 抛、间接循环引用的 StackOverflowError）→ 该值写占位串
  /// `"<unprintable>"` 并标 truncated；拷贝快照时并发修改 → 已拿到的键照用、标 truncated。返回 (JSON 或 null, 是否截断)。
  static (Uint8List?, bool) encodeAttrs(Map<String, Object?> attrs) {
    var truncated = false;
    final keys = <String>[];
    final vals = <String, Object?>{};
    try {
      for (final e in attrs.entries) {
        if (keys.length >= Limits.lineAttrsKeys) {
          truncated = true;
          break;
        }
        final k = e.key;
        keys.add(k);
        vals[k] = e.value;
      }
    } catch (_) {
      // 并发修改 / 宿主 map 的迭代器抛异常
      truncated = true;
    }
    keys.sort();
    final out = JsonOut(256);
    out.byte(0x7B);
    var count = 0;
    for (final k in keys) {
      if (k.length > Limits.lineAttrsBytes) {
        truncated = true;
        continue;
      }
      var item = JsonOut(32);
      if (count > 0) item.raw(',');
      item.string(k);
      item.raw(':');
      int r;
      try {
        r = _value(item, vals[k]);
      } catch (_) {
        item = JsonOut(32);
        if (count > 0) item.raw(',');
        item.string(k);
        item.raw(':');
        item.string(ClientConstants.unprintable);
        r = _valueUnprintable;
      }
      if (r == _valueSkip) {
        truncated = true;
        continue;
      }
      if (r == _valueUnprintable) truncated = true;
      if (out.size + item.size + 1 > Limits.lineAttrsBytes) {
        truncated = true;
        continue;
      }
      out.rawBytes(item.toBytes());
      count += 1;
    }
    if (count == 0) return (null, truncated || keys.isNotEmpty);
    out.byte(0x7D);
    return (out.toBytes(), truncated);
  }

  /// 写一个 attrs 值；返回 OK / SKIP（放不下，跳过该键）/ UNPRINTABLE。可能抛：调用方逐值兜住。
  static int _value(JsonOut item, Object? v) {
    if (v == null) {
      item.raw('null');
    } else if (v is bool) {
      item.boolean(v);
    } else if (v is int) {
      _integer(item, v);
    } else if (v is BigInt) {
      _bigInteger(item, v);
    } else if (v is double) {
      _number(item, v);
    } else if (v is String) {
      // 一个 UTF-16 单元至少 1 个 UTF-8 字节：长度超过预算的值放不下，先判再转义
      if (v.length > Limits.lineAttrsBytes) return _valueSkip;
      item.string(v);
    } else if (v is Iterable<Object?> || v is Map<Object?, Object?>) {
      final j = JsonOut(64);
      if (!_render(j, v, 0)) return _valueSkip;
      if (j.size > Limits.lineAttrsBytes) return _valueSkip;
      item.string(Text.decode(j.toBytes()));
    } else {
      final s = v.toString();
      if (s.length > Limits.lineAttrsBytes) return _valueSkip;
      item.string(s);
    }
    return _valueOk;
  }

  /// 有上限的 JSON 渲染（Iterable → `[…]`、Map → `{"k":…}`，元素规则同 attrs 值；其它对象 `toString()` 作字符串）。
  /// 文本超过 4096 B 立即停止返回 false（调用方跳过该键）；嵌套超过 8 层（含循环引用）抛出 → 占位串。
  static bool _render(JsonOut o, Object? v, int depth) {
    if (o.size > Limits.lineAttrsBytes) return false;
    if (depth > ClientConstants.attrRenderMaxDepth) throw const _TooDeep();
    if (v == null) {
      o.raw('null');
    } else if (v is bool) {
      o.boolean(v);
    } else if (v is int) {
      _integer(o, v);
    } else if (v is BigInt) {
      _bigInteger(o, v);
    } else if (v is double) {
      _number(o, v);
    } else if (v is String) {
      if (v.length > Limits.lineAttrsBytes) return false;
      o.string(v);
    } else if (v is Map<Object?, Object?>) {
      o.byte(0x7B);
      var first = true;
      for (final e in v.entries) {
        if (!first) o.byte(0x2C);
        first = false;
        final ks = e.key?.toString() ?? 'null';
        if (ks.length > Limits.lineAttrsBytes) return false;
        o.string(ks);
        o.byte(0x3A);
        if (!_render(o, e.value, depth + 1)) return false;
      }
      o.byte(0x7D);
    } else if (v is Iterable<Object?>) {
      o.byte(0x5B);
      var first = true;
      for (final x in v) {
        if (!first) o.byte(0x2C);
        first = false;
        if (!_render(o, x, depth + 1)) return false;
      }
      o.byte(0x5D);
    } else {
      final s = v.toString();
      if (s.length > Limits.lineAttrsBytes) return false;
      o.string(s);
    }
    return o.size <= Limits.lineAttrsBytes;
  }

  /// 2^53 − 1：JS `Number.MAX_SAFE_INTEGER`，查看端 `JSON.parse` 能精确表示的最大整数。
  static const int _maxSafeInteger = 9007199254740991;
  static final BigInt _maxSafeBig = BigInt.from(_maxSafeInteger);

  static void _integer(JsonOut o, int v) {
    if (v >= -_maxSafeInteger && v <= _maxSafeInteger) {
      o.integer(v);
    } else {
      o.string(v.toString());
    }
  }

  static void _bigInteger(JsonOut o, BigInt v) {
    if (v.abs() <= _maxSafeBig) {
      o.raw(v.toString());
    } else {
      o.string(v.toString());
    }
  }

  static void _number(JsonOut o, double d) {
    if (d.isNaN) {
      o.string('NaN');
    } else if (d.isInfinite) {
      o.string(d > 0 ? 'Infinity' : '-Infinity');
    } else {
      o.number(d);
    }
  }

  static Uint8List build(
    int ts,
    LogLevel level,
    String msg,
    String? tag,
    Uint8List? attrs,
    LogException? exc,
    bool synthetic,
    bool truncated,
  ) {
    final o = JsonOut(64 + msg.length * 3);
    o.raw('"ts":');
    o.integer(ts);
    o.raw(',"level":"');
    o.raw(level.wire);
    o.raw('"');
    o.raw(',"msg":');
    o.string(msg);
    if (tag != null) {
      o.raw(',"tag":');
      o.string(tag);
    }
    if (attrs != null) {
      o.raw(',"attrs":');
      o.rawBytes(attrs);
    }
    if (exc != null) {
      o.raw(',"exc":{"type":');
      o.string(exc.type);
      o.raw(',"message":');
      o.string(exc.message);
      final st = exc.stack;
      if (st != null) {
        o.raw(',"stack":');
        o.string(st);
      }
      o.raw('}');
    }
    if (synthetic) o.raw(',"synthetic":true');
    if (truncated) o.raw(',"truncated":true');
    o.raw('}\n');
    return o.toBytes();
  }

  /// 行体开头固定为 `"ts":<整数>`：按位置取 ts（解析不出 = 0）。
  static int tsOf(List<int> body) {
    var i = 5;
    if (body.length < 6 || body[0] != 0x22 || body[1] != 0x74) return 0;
    var neg = false;
    if (i < body.length && body[i] == 0x2D) {
      neg = true;
      i++;
    }
    var v = 0;
    var n = 0;
    while (i < body.length && body[i] >= 0x30 && body[i] <= 0x39 && n < 18) {
      v = v * 10 + (body[i] - 0x30);
      i++;
      n++;
    }
    return neg ? -v : v;
  }

  /// 写入时拼的前缀：`{"seq":N,` 或 `{"seq":N,"oseq":M,`。
  static Uint8List prefix(int seq, int oseq) {
    final o = JsonOut(48);
    o.raw('{"seq":');
    o.integer(seq);
    if (oseq > 0) {
      o.raw(',"oseq":');
      o.integer(oseq);
    }
    o.raw(',');
    return o.toBytes();
  }
}

class _TooDeep implements Exception {
  const _TooDeep();
}
