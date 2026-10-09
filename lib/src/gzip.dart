// gzip（§3.9）：`dart:io` 的 gzip 编码 → 单成员标准 gzip、无尾随字节（否则服务端按损坏隔离）。对位 Android `core/Gzip.kt`。
//
// 解压用于读回出站箱批次（元数据、413 切分、驱逐墓碑）：严格模式——头部合法、恰好一个成员、末尾 8 字节就是该成员的
// CRC32 + ISIZE。`dart:io` 的解码器很宽松（多成员会拼接输出、尾随字节与缺尾都不报错），所以在它之上补校验：
// 多成员 → 输出长度对不上最后一个成员的 ISIZE；尾随 / 缺尾 → 末尾 8 字节不是 trailer，CRC 对不上。

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'ids.dart';

abstract final class Gzip {
  static Uint8List? compress(List<int> input) {
    try {
      return Uint8List.fromList(gzip.encode(input));
    } catch (_) {
      return null;
    }
  }

  static Uint8List? decompress(List<int> input, {int limit = 64 * 1024 * 1024}) {
    if (input.length < 18) return null;
    if (input[0] != 0x1F || input[1] != 0x8B || input[2] != 8) return null;
    final flg = input[3];
    if (flg & 0xE0 != 0) return null;
    var pos = 10;
    if (flg & 0x04 != 0) {
      if (pos + 2 > input.length) return null;
      final xlen = input[pos] | (input[pos + 1] << 8);
      pos += 2 + xlen;
    }
    if (flg & 0x08 != 0) {
      final p = _skipZ(input, pos);
      if (p == null) return null;
      pos = p;
    }
    if (flg & 0x10 != 0) {
      final p = _skipZ(input, pos);
      if (p == null) return null;
      pos = p;
    }
    if (flg & 0x02 != 0) pos += 2;
    if (pos >= input.length - 8) return null;
    final List<int> out;
    try {
      out = gzip.decode(input);
    } catch (_) {
      return null;
    }
    if (out.length > limit) return null;
    final t = input.length - 8;
    if (_le32(input, t) != Ids.crc32(out)) return null;
    if (_le32(input, t + 4) != (out.length & 0xFFFFFFFF)) return null;
    return out is Uint8List ? out : Uint8List.fromList(out);
  }

  static int? _skipZ(List<int> b, int from) {
    var p = from;
    while (p < b.length && b[p] != 0) {
      p++;
    }
    return p < b.length ? p + 1 : null;
  }

  static int _le32(List<int> b, int p) => b[p] | (b[p + 1] << 8) | (b[p + 2] << 16) | (b[p + 3] << 24);

  /// worker isolate 里压缩（v3 §7：全部 gzip 用 `Isolate.run`；闭包只捕获字节，不捕获任何持文件句柄的对象）。
  /// `Isolate.run` 失败（极少见：isolate 起不来）退回当前 isolate 做。
  static Future<Uint8List?> compressOffMain(Uint8List input) async {
    try {
      return await Isolate.run(() => compress(input), debugName: 'retriever-gzip');
    } catch (_) {
      return compress(input);
    }
  }

  static Future<Uint8List?> decompressOffMain(Uint8List input) async {
    try {
      return await Isolate.run(() => decompress(input), debugName: 'retriever-gunzip');
    } catch (_) {
      return decompress(input);
    }
  }
}
