// 段文件读侧（§3.3-5 / §3.4）：按 `\n` 切行、逐行校验，丢弃尾部残行与全 0 块并计 corrupt。
// 对位 Android `core/Segments.kt`，与 iOS `Segments` 逐字一致。读文件本身在 fs.dart（异步）。

import 'dart:typed_data';

import 'json.dart';
import 'model.dart';

/// 段文件的一行（读侧索引）。
class SegLine {
  const SegLine(this.seq, this.oseq, this.ts, this.levelRank, this.start, this.end);

  final int seq;

  /// 0 = 非义务行
  final int oseq;
  final int ts;
  final int levelRank;

  /// 行字节在 data 里的范围 [start, end)（不含 `\n`）
  final int start;
  final int end;
}

class SegmentHeader {
  const SegmentHeader(this.segNo, this.userId, this.startedMs);

  final int segNo;
  final String? userId;
  final int startedMs;

  Uint8List encode() {
    final o = JsonOut();
    o.raw('{"v":1,"seg_no":');
    o.integer(segNo);
    o.raw(',"user_id":');
    o.stringOrNull(userId);
    o.raw(',"started_ms":');
    o.integer(startedMs);
    o.raw('}\n');
    return o.toBytes();
  }
}

class SegmentFile {
  SegmentFile(this.path, this.segNo, this.header, this.data, this.lines, this.validEnd, this.corruptChunks);

  final String path;
  final int segNo;
  SegmentHeader? header;
  Uint8List data;
  final List<SegLine> lines;

  /// 最后一个完整行（或 header）结束处的字节偏移（截残行用）。
  int validEnd;

  /// 无法解析的块数（残行、全 0 块、坏 JSON）。
  int corruptChunks;

  /// 尾部残行里能认出的 (seq, oseq)（前缀在同一次 write 里先写，残行通常保住前缀）。
  int? tornSeq;
  int? tornOseq;

  bool get sealed => path.endsWith('.sealed');
}

typedef SegPrefix = ({int seq, int oseq, int ts, int levelRank});

abstract final class Segments {
  static String name(int segNo, bool open) {
    final n = segNo.toString();
    return 'seg-${'0' * (6 - n.length < 0 ? 0 : 6 - n.length)}$n${open ? '.open' : '.sealed'}';
  }

  /// `seg-000123.open|.sealed` → (123, isOpen)
  static ({int segNo, bool isOpen})? parseName(String name) {
    if (!name.startsWith('seg-')) return null;
    bool isOpen;
    String stem;
    if (name.endsWith('.open')) {
      isOpen = true;
      stem = name.substring(4, name.length - 5);
    } else if (name.endsWith('.sealed')) {
      isOpen = false;
      stem = name.substring(4, name.length - 7);
    } else {
      return null;
    }
    if (stem.isEmpty || !RegExp(r'^[0-9]+$').hasMatch(stem)) return null;
    final n = int.tryParse(stem);
    if (n == null || n <= 0) return null;
    return (segNo: n, isOpen: isOpen);
  }

  static String _baseName(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }

  /// 解析已读出的段字节（文件名不合规返回 null）。`validate` = 逐行 JSON 校验（恢复孤儿段时用；平时只解析前缀）。
  static SegmentFile? parse(String path, Uint8List data, bool validate) {
    final p = parseName(_baseName(path));
    if (p == null) return null;
    final seg = SegmentFile(path, p.segNo, null, data, <SegLine>[], 0, 0);
    var start = 0;
    var first = true;
    final n = data.length;
    while (start < n) {
      var end = start;
      while (end < n && data[end] != 0x0A) {
        end++;
      }
      var s = start;
      while (s < end && data[s] == 0) {
        s++;
      }
      if (end == n) {
        // 尾部残行（没有 `\n` 结尾）：计 corrupt；前缀在同一次 write 里先写，尽量认出 seq / oseq
        seg.corruptChunks += 1;
        if (s < end) {
          final pre = parsePrefix(data, s, end);
          if (pre != null) {
            seg.tornSeq = pre.seq;
            seg.tornOseq = pre.oseq;
          } else {
            final so = parseSeqOnly(data, s, end);
            if (so != null) {
              seg.tornSeq = so.$1;
              seg.tornOseq = so.$2;
            }
          }
        }
        break;
      }
      seg.validEnd = end + 1;
      if (s > start) seg.corruptChunks += 1; // 全 0 块
      if (s == end) {
        start = end + 1;
        continue;
      }
      if (first) {
        first = false;
        if (s == start) {
          final h = parseHeader(data, s, end);
          if (h != null) {
            seg.header = h;
            start = end + 1;
            continue;
          }
        }
      }
      final pre = parsePrefix(data, s, end);
      if (pre != null && (!validate || isValidJson(data, s, end))) {
        seg.lines.add(SegLine(pre.seq, pre.oseq, pre.ts, pre.levelRank, s, end));
      } else {
        seg.corruptChunks += 1;
      }
      start = end + 1;
    }
    return seg;
  }

  static bool isValidJson(Uint8List data, int s, int e) => JsonIn.obj(Uint8List.sublistView(data, s, e)) != null;

  static final Uint8List _headerPrefix = Bytes.ascii('{"v":');

  static SegmentHeader? parseHeader(Uint8List data, int s, int e) {
    if (!Bytes.startsWith(data, s, e, _headerPrefix)) return null;
    final o = JsonIn.obj(Uint8List.sublistView(data, s, e));
    if (o == null) return null;
    final segNo = JsonIn.int64(o['seg_no']);
    if (segNo == null) return null;
    final u = o['user_id'];
    return SegmentHeader(segNo, u is String ? u : null, JsonIn.int64(o['started_ms']) ?? 0);
  }

  static final Uint8List _pSeq = Bytes.ascii('{"seq":');
  static final Uint8List _pOseq = Bytes.ascii('"oseq":');
  static final Uint8List _pTs = Bytes.ascii('"ts":');
  static final Uint8List _pLevel = Bytes.ascii(',"level":"');

  /// 解析我方写出的固定前缀 `{"seq":N[,"oseq":M],"ts":T,"level":"L"`。
  static SegPrefix? parsePrefix(List<int> d, int from, int end) {
    var i = from;
    bool expect(List<int> p) {
      if (end - i < p.length) return false;
      for (var k = 0; k < p.length; k++) {
        if (d[i + k] != p[k]) return false;
      }
      i += p.length;
      return true;
    }

    int? number() {
      var v = 0;
      var any = false;
      while (i < end && d[i] >= 0x30 && d[i] <= 0x39) {
        v = v * 10 + (d[i] - 0x30);
        i++;
        any = true;
      }
      return any ? v : null;
    }

    if (!expect(_pSeq)) return null;
    final seq = number();
    if (seq == null) return null;
    if (i >= end || d[i] != 0x2C) return null;
    i++;
    var oseq = 0;
    if (expect(_pOseq)) {
      final o = number();
      if (o == null) return null;
      if (i >= end || d[i] != 0x2C) return null;
      oseq = o;
      i++;
    }
    if (!expect(_pTs)) return null;
    final ts = number();
    if (ts == null) return null;
    if (!expect(_pLevel)) return null;
    var j = i;
    while (j < end && d[j] != 0x22) {
      j++;
    }
    if (j >= end) return null;
    final rank = Level.rankOf(String.fromCharCodes(d, i, j));
    if (rank < 0) return null;
    return (seq: seq, oseq: oseq, ts: ts, levelRank: rank);
  }

  /// 残行只剩前缀一部分时尽量认出 seq / oseq。
  static (int, int)? parseSeqOnly(List<int> d, int from, int end) {
    if (!Bytes.startsWith(d, from, end, _pSeq)) return null;
    var i = from + _pSeq.length;
    var seq = 0;
    var any = false;
    while (i < end && d[i] >= 0x30 && d[i] <= 0x39) {
      seq = seq * 10 + (d[i] - 0x30);
      i++;
      any = true;
    }
    if (!any || i >= end || d[i] != 0x2C) return null;
    i++;
    var oseq = 0;
    if (Bytes.startsWith(d, i, end, _pOseq)) {
      i += _pOseq.length;
      var v = 0;
      var got = false;
      while (i < end && d[i] >= 0x30 && d[i] <= 0x39) {
        v = v * 10 + (d[i] - 0x30);
        i++;
        got = true;
      }
      // 数字后必须跟逗号才可信（否则可能被截在数字中间）
      if (got && i < end && d[i] == 0x2C) oseq = v;
    }
    return (seq, oseq);
  }

  static final List<Uint8List> _ctxSuffixes = [
    Bytes.ascii(',"ctx":true}'),
    Bytes.ascii(',"ctx":true,"synthetic":true}'),
    Bytes.ascii(',"ctx":true,"truncated":true}'),
    Bytes.ascii(',"ctx":true,"synthetic":true,"truncated":true}'),
  ];

  /// 行是不是 ctx 行：按固定位置判断（ADR 0024 决定 9）——`ctx` 只出现在行尾、exc 之后、synthetic / truncated 之前。
  static bool isCtxLine(List<int> raw, int s, int e) {
    for (final suf in _ctxSuffixes) {
      if (Bytes.hasSuffix(raw, s, e, suf)) return true;
    }
    return false;
  }

  static final List<Uint8List> _ctxInsertBefore = [
    Bytes.ascii(',"synthetic":true,"truncated":true}'),
    Bytes.ascii(',"synthetic":true}'),
    Bytes.ascii(',"truncated":true}'),
  ];
  static final Uint8List _ctxField = Bytes.ascii(',"ctx":true');

  /// 物化 ctx 行：在固定位置（exc 之后、synthetic / truncated 之前）插入 `"ctx":true`。
  static Uint8List withCtx(List<int> raw, int s, int e) {
    for (final suf in _ctxInsertBefore) {
      if (Bytes.hasSuffix(raw, s, e, suf)) {
        final cut = e - suf.length;
        final out = JsonOut(e - s + _ctxField.length);
        out.rawBytes(raw, s, cut);
        out.rawBytes(_ctxField);
        out.rawBytes(suf);
        return out.toBytes();
      }
    }
    final out = JsonOut(e - s + _ctxField.length);
    out.rawBytes(raw, s, e - 1);
    out.rawBytes(_ctxField);
    out.byte(0x7D);
    return out.toBytes();
  }
}
