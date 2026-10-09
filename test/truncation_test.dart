// 对位 Android TruncationTests.kt：UTF-8 截断（§3.1）——按字节、只在码点边界；单行序列化 ≤ 16 KB。

import 'dart:convert';
import 'dart:typed_data';

import 'package:revdog_retriever/src/json.dart';
import 'package:revdog_retriever/src/limits.dart';
import 'package:revdog_retriever/src/line_encoder.dart';
import 'package:revdog_retriever/src/segments.dart';
import 'package:revdog_retriever/src/text.dart';
import 'package:test/test.dart';

import 'support/support.dart';

LogLine line(LogLevel level, String msg, {String? tag, Map<String, Object?>? attrs, LogException? exc, int ts = 1}) =>
    LogLine(ts: ts, level: level, msg: msg, tag: tag, attrs: attrs, exc: exc);

(Map<String, Object?>, int) decode(Encoded e, {int seq = 9007199254740991, int oseq = 9007199254740991}) {
  final full = Uint8List.fromList([...LineEncoder.prefix(seq, oseq), ...e.body.sublist(0, e.body.length - 1)]);
  // 物化 ctx 行时再插一个字段：上限也要容得下
  final withCtx = Segments.withCtx(full, 0, full.length);
  return (JsonIn.obj(withCtx)!, withCtx.length);
}

int utf8Len(String s) => utf8.encode(s).length;

void main() {
  test('msgCjkTruncatedAtCodePoint', () {
    final e = LineEncoder.encode(line(LogLevel.info, '日' * 1400)); // 4200 B
    expect(e.truncated, isTrue);
    final (o, _) = decode(e);
    final m = o['msg'] as String;
    expect(utf8Len(m), 4095); // 1365 × 3 B，第 1366 个放不下
    expect(o['truncated'], true);
    expect(m.split('').every((c) => c == '日'), isTrue);
  });

  test('emojiNotSplit', () {
    final e = LineEncoder.encode(line(LogLevel.info, 'a${'🐶' * 1100}', tag: '🐱' * 20));
    final (o, _) = decode(e);
    expect(utf8Len(o['msg'] as String), 1 + 1023 * 4);
    expect(utf8Len(o['tag'] as String), 64);
    expect((o['tag'] as String).runes.length, 16);
  });

  test('loneSurrogateBecomesReplacementChar', () {
    const broken = 'a\uD83Db';
    expect(Text.utf8Len(broken), 5); // 与服务端 utf8Len 一致：孤立代理项 3 B
    final e = LineEncoder.encode(line(LogLevel.info, broken));
    final (o, _) = decode(e);
    expect(o['msg'], 'a�b');
    expect(Text.utf8Len('a�b'), 5);
    expect(utf8.decode(Text.utf8Bytes(broken)), 'a�b');
  });

  test('controlCharsEscapedLikeJsonStringify', () {
    final e = LineEncoder.encode(line(LogLevel.info, 'q"b\\n\n t\t\u0001\u007f/ '));
    final s = utf8.decode(e.body);
    expect(s.contains(r'"msg":"q\"b\\n\n t\t\u0001'), isTrue, reason: s);
    expect(s.contains('\u007f/ "'), isTrue, reason: s);
  });

  test('stackHeadAndTail', () {
    final head = 'h' * 10000;
    final tail = '${'t' * 9000}Caused by: IOError';
    final e = LineEncoder.encode(
      line(
        LogLevel.error,
        'x',
        exc: LogException(type: 'T', message: 'm', stack: head + tail),
      ),
    );
    final (o, _) = decode(e);
    final stack = obj(o['exc'])['stack'] as String;
    expect(utf8Len(stack), lessThanOrEqualTo(Limits.lineExcStackBytes));
    // 字段级：头 8 KB + 标记 + 尾（总长 ≤ 16 KB）
    final field = LineEncoder.headTail(head + tail);
    expect(field.startsWith('${'h' * 8192}\n…[truncated]…\n'), isTrue);
    expect(utf8Len(field), Limits.lineExcStackBytes);
    // 行级：满额 stack 放不进 16 KB 的行，再按「头 + 标记 + 尾」收缩，尾部 `Caused by` 保住
    expect(stack.startsWith('h' * 7900), isTrue);
    expect(stack.contains('\n…[truncated]…\n'), isTrue);
    expect(stack.endsWith('Caused by: IOError'), isTrue);
    expect(o['truncated'], true);
  });

  test('excFieldLimits', () {
    final e = LineEncoder.encode(
      line(
        LogLevel.error,
        'x',
        exc: LogException(type: '類' * 100, message: 'm' * 2000),
      ),
    );
    final (o, _) = decode(e);
    final exc = obj(o['exc']);
    expect(utf8Len(exc['type'] as String), lessThanOrEqualTo(256));
    expect(utf8Len(exc['message'] as String), 1024);
    expect(exc['stack'], isNull);
  });

  test('attrsKeysAndBytesLimits', () {
    final attrs = <String, Object?>{};
    for (var i = 0; i < 40; i++) {
      attrs['k${i.toString().padLeft(2, '0')}'] = i.toDouble();
    }
    attrs['inf'] = double.infinity;
    attrs['nan'] = double.nan;
    final (o, _) = decode(LineEncoder.encode(line(LogLevel.info, 'x', attrs: attrs)));
    expect(obj(o['attrs']).length, 32);
    expect(o['truncated'], true);
    // 非有限数转 string；其它类型 toString；集合渲染成紧凑 JSON 文本（0.3.0）
    final (o2, _) = decode(
      LineEncoder.encode(
        line(
          LogLevel.info,
          'x',
          attrs: {
            'inf': double.infinity,
            'nan': double.nan,
            'n': double.negativeInfinity,
            'l': 42,
            'obj': [1, 2],
          },
        ),
      ),
    );
    final a2 = obj(o2['attrs']);
    expect(a2['inf'], 'Infinity');
    expect(a2['nan'], 'NaN');
    expect(a2['n'], '-Infinity');
    expect(a2['l'], 42.0);
    expect(a2['obj'], '[1,2]');
    // 序列化 ≤ 4096：贪心装入
    final big = {'a': 'x' * 3000, 'b': 'y' * 3000, 'c': true};
    final (o3, _) = decode(LineEncoder.encode(line(LogLevel.info, 'x', attrs: big)));
    final a3 = obj(o3['attrs']);
    expect(a3.keys.toSet(), {'a', 'c'});
    expect(utf8Len(toJson(a3)), lessThanOrEqualTo(4096));
  });

  test('serializedLineCapped16KB', () {
    // attrs 4 KB + stack 16 KB（控制字符，转义 6 倍）+ msg 4 KB ASCII → 先删 attrs、再截 stack，msg 保住
    final attrs = <String, Object?>{};
    for (var i = 0; i < 8; i++) {
      attrs['k$i'] = 'a' * 450;
    }
    final l = LogLine(
      ts: 1790668800000,
      level: LogLevel.error,
      msg: 'm' * 4000,
      tag: 't' * 64,
      attrs: attrs,
      exc: LogException(type: 'T' * 256, message: '\u0002' * 1024, stack: 'HEAD${'\u0003' * 20000}Caused by: X'),
    );
    final (o, n) = decode(LineEncoder.encode(l));
    expect(n, lessThanOrEqualTo(Limits.lineSerializedBytes));
    expect(o['attrs'], isNull, reason: 'attrs 先整个删掉');
    expect(o['truncated'], true);
    expect(utf8Len(o['msg'] as String), 4000);
    final stack = obj(o['exc'])['stack'] as String;
    expect(stack.startsWith('HEAD'), isTrue);
    expect(stack.endsWith('Caused by: X'), isTrue);

    // msg 本身转义后就超（4000 个控制字符 = 24 KB）→ stack 去掉后再截 msg
    final l2 = LogLine(
      ts: 1,
      level: LogLevel.error,
      msg: '\u0001' * 4000,
      exc: LogException(type: 'T', message: 'm', stack: 's' * 5000),
    );
    final (o2, n2) = decode(LineEncoder.encode(l2));
    expect(n2, lessThanOrEqualTo(Limits.lineSerializedBytes));
    expect((o2['msg'] as String).length < 4000, isTrue);
    expect(o2['truncated'], true);
  });

  /// 超长 attrs 值先按预算判再转义（ADR 0020 决定 3）：20 MB 的值该键被跳过并打 truncated，其它键照常，耗时有上限。
  test('hugeAttrValueBounded', () {
    final huge = '"' * (20 * 1024 * 1024);
    final attrs = {'a': 'kept', 'huge': huge, 'z': 7};
    final sw = Stopwatch()..start();
    final (json, truncated) = LineEncoder.encodeAttrs(attrs);
    final took = sw.elapsedMilliseconds;
    expect(String.fromCharCodes(json!), '{"a":"kept","z":7}');
    expect(truncated, isTrue);
    expect(took, lessThan(20), reason: 'took $took ms');
    // 整行编码同样有上限（非 String 的值：toString 后按长度判）
    final sw2 = Stopwatch()..start();
    final e = LineEncoder.encode(line(LogLevel.info, 'x', attrs: {'huge': StringBuffer(huge)}));
    expect(sw2.elapsedMilliseconds, lessThan(200));
    final (o, _) = decode(e);
    expect(o['attrs'], isNull);
    expect(o['truncated'], true);
  });

  /// 与服务端逐字节核算：validator 的 JSON.stringify(行) ≤ 16384（含 ctx 字段与最大位数的 seq / oseq）。
  test('worstCaseLinesFitServerLimit', () {
    for (final ch in ['a', '\u0001', '日', '🐶', '"', '\uD800']) {
      final l = LogLine(
        ts: 9999999999999,
        level: LogLevel.fatal,
        msg: ch * 5000,
        tag: ch * 100,
        attrs: {'x': ch * 5000},
        exc: LogException(type: ch * 300, message: ch * 2000, stack: ch * 30000),
      );
      final (_, n) = decode(LineEncoder.encode(l, synthetic: true));
      expect(n, lessThanOrEqualTo(Limits.lineSerializedBytes), reason: ch);
    }
  });

  test('truncateHelpers', () {
    expect(Text.truncate('abc', 2).s, 'ab');
    expect(Text.truncate('é', 1).s, '');
    expect(utf8Len(Text.suffix('xyz日本', 4)), 3);
    expect(Text.suffix('a🐶', 4), '🐶');
    expect(Text.sanitizeUserId('u\u0000\u00851'), 'u1');
    expect(utf8Len(Text.sanitizeUserId('用' * 50)!), 126);
    expect(Text.sanitizeUserId('a\uDC00'), 'a�');
  });
}
