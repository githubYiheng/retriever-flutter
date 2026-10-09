// 对位 Android GzipTests.kt：gzip 能被标准 gunzip 解开，单成员、无尾随字节（否则服务端按损坏隔离）。

import 'dart:io';
import 'dart:typed_data';

import 'package:revdog_retriever/src/gzip.dart';
import 'package:test/test.dart';

import 'support/support.dart';

void main() {
  setUpRtv();

  test('gunzipAcceptsSingleMemberWithoutTrailingBytes', () async {
    final input = Uint8List.fromList([
      for (var i = 0; i < 200000; i++) ((i * 31) ^ (i >> 3)) & 0xFF,
      ...'日志🐶 {"seq":1}'.codeUnits.expand((c) => c < 0x80 ? [c] : <int>[]),
    ]);
    final gz = Gzip.compress(input)!;
    expect(gz.sublist(0, 3), [0x1F, 0x8B, 0x08]);
    // ISIZE = 原长 mod 2^32（小端），且就在文件末尾（无尾随字节）
    var isize = 0;
    for (var k = 0; k < 4; k++) {
      isize |= gz[gz.length - 4 + k] << (8 * k);
    }
    expect(isize, input.length);
    expect(gzip.decode(gz), input);
    // 标准 gunzip
    final dir = tempDir('rtv-gz');
    final f = File('$dir/b.gz')..writeAsBytesSync(gz);
    expect((await Process.run('gunzip', ['-t', f.path])).exitCode, 0);
    final out = await Process.run('gunzip', ['-c', f.path], stdoutEncoding: null);
    expect(out.exitCode, 0);
    expect(out.stdout as List<int>, input);
    expect(Gzip.decompress(gz), input);
    // 严格解压：多一个成员或尾随字节都拒绝；缺尾也拒绝
    expect(Gzip.decompress([...gz, ...gz]), isNull);
    expect(Gzip.decompress([...gz, 0]), isNull);
    expect(Gzip.decompress(gz.sublist(0, gz.length - 4)), isNull);
    expect(Gzip.decompress(Gzip.compress(Uint8List(0))!), Uint8List(0));
    // worker isolate 版本结果相同
    expect(await Gzip.compressOffMain(input), isNotNull);
    expect(await Gzip.decompressOffMain(gz), input);
  });

  test('outboxFileIsExactRequestBodyAndGunzipClean', () async {
    final h = await Harness.create();
    await h.settle();
    h.transport.defaultReply = Reply.status(503);
    h.l(LogLevel.warn, 'w');
    await h.sealAndDrain();
    final name = h.outboxFiles().first;
    final f = File('${h.outbox}/$name');
    expect(h.transport.batchRequests.first.body, f.readAsBytesSync(), reason: '文件字节即请求体');
    expect((await Process.run('gunzip', ['-t', f.path])).exitCode, 0);
    // 重试原样重发
    await h.tick(5000);
    expect(h.transport.batchRequests.length, 2);
    expect(h.transport.batchRequests[1].body, h.transport.batchRequests[0].body);
  });
}
