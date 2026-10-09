// 对位 Android WriteDisciplineTests.kt：写入纪律（宪法 R-1，方案 §3.3）。

import 'dart:io';

import 'package:revdog_retriever/src/json.dart';
import 'package:revdog_retriever/src/pre.dart';
import 'package:revdog_retriever/src/writer.dart';
import 'package:test/test.dart';

import 'support/support.dart';

/// 用另一个句柄直接读（不经 flush）。
List<String> readSegment(String path) => readSegmentLines(path);

class Boom implements Exception {
  @override
  String toString() => 'Boom: bad thing';
}

class Silent implements Exception {
  @override
  String toString() => '';
}

void main() {
  setUpRtv();

  test('lineVisibleToOtherStreamImmediately', () async {
    final h = await Harness.create(key: '');
    final f = h.client.debugOpenSegmentFile!;
    for (var i = 1; i <= 50; i++) {
      h.l(i % 5 == 0 ? LogLevel.warn : LogLevel.info, 'visible $i');
      final ls = readSegment(f);
      expect(ls.length, i + 1, reason: 'header + $i lines');
      final last = JsonIn.objText(ls.last)!;
      expect(int_(last['seq']), i);
      expect(last['msg'], 'visible $i');
      expect(last.containsKey('oseq'), i % 5 == 0);
    }
    // 段首行是 header
    final header = JsonIn.objText(readSegment(f)[0])!;
    expect(int_(header['v']), 1);
    expect(int_(header['seg_no']), 1);
    expect(header.containsKey('user_id') && header['user_id'] == null, isTrue);
  });

  test('fieldOrderAndOptionalKeys', () async {
    final h = await Harness.create(key: '');
    h.l(
      LogLevel.error,
      'boom',
      tag: 'net',
      attrs: {'b': true, 'a': 1.5, 'c': 'x', 'n': null, 'i': 7},
      error: Boom(),
      st: StackTrace.current,
    );
    h.l(LogLevel.debug, 'plain');
    h.l(LogLevel.warn, 'no message', error: Silent());
    final ls = readSegment(h.client.debugOpenSegmentFile!);
    expect(ls[1].startsWith('{"seq":1,"oseq":1,"ts":'), isTrue, reason: ls[1]);
    expect(
      ls[1].contains(
        '"level":"error","msg":"boom","tag":"net","attrs":{"a":1.5,"b":true,"c":"x","i":7,"n":null},'
        '"exc":{"type":"Boom","message":"Boom: bad thing","stack":"',
      ),
      isTrue,
      reason: ls[1],
    );
    expect(ls[2].startsWith('{"seq":2,"ts":'), isTrue, reason: ls[2]);
    expect(ls[2].contains('tag'), isFalse);
    expect(ls[2].contains('truncated'), isFalse);
    final exc = obj(JsonIn.objText(ls[1])!['exc']);
    expect((exc['stack'] as String).startsWith('#0'), isTrue, reason: 'Dart 栈文本');
    // toString 为空串 → message ""；没传栈、也不是 Error → 无 stack
    final exc3 = obj(JsonIn.objText(ls[3])!['exc']);
    expect(exc3['type'], 'Silent');
    expect(exc3['message'], '');
    expect(exc3.containsKey('stack'), isFalse);
  });

  test('redactNullDoesNotConsumeSeq', () async {
    final h = await Harness.create(
      key: '',
      options: RetrieverOptions(redact: (line) => line.msg.contains('secret') ? null : line),
    );
    h.l(LogLevel.warn, 'a');
    h.l(LogLevel.warn, 'secret token');
    h.l(LogLevel.warn, 'b');
    expect(h.client.debugCounters, (2, 2));
  });

  test('redactCanRewriteAndReentrancyIgnored', () async {
    final h = await Harness.create(
      key: '',
      options: RetrieverOptions(
        redact: (line) {
          Retriever.log(LogLevel.error, 'from inside redact'); // 重入：直接忽略
          return line.copyWith(msg: line.msg.replaceAll('pw=123', 'pw=***'));
        },
      ),
    );
    h.l(LogLevel.info, 'login pw=123');
    expect(h.client.debugCounters.$1, 1);
    final ls = readSegment(h.client.debugOpenSegmentFile!);
    expect(ls.length, 2);
    expect(ls[1].contains('pw=***'), isTrue);
  });

  test('localLevelFilterDoesNotConsumeSeq', () async {
    final h = await Harness.create(
      key: '',
      options: const RetrieverOptions(localLevel: LogLevel.info),
    );
    h.l(LogLevel.debug, 'dropped');
    h.l(LogLevel.info, 'kept');
    h.l(LogLevel.debug, 'dropped');
    expect(h.client.debugCounters, (1, 0));
  });

  test('setEnabledFalseWritesNothing', () async {
    final h = await Harness.create(key: '');
    h.setEnabled(false);
    h.l(LogLevel.error, 'nope');
    expect(h.client.debugCounters.$1, 0);
    h.setEnabled(true);
    h.l(LogLevel.error, 'yes');
    expect(h.client.debugCounters.$1, 1);
  });

  test('writeFailureRecordsTombstoneAndNeverThrows', () async {
    final h = await Harness.create(key: '');
    await h.settle(); // 启动任务里的 flushTombstones 先跑完，两次失败才会合并成一个区间
    h.l(LogLevel.warn, 'ok 1');
    // 模拟写失败：关掉当前段的流（write 抛 FileSystemException）
    final f = h.client.debugOpenSegmentFile!;
    h.client.writer.debugBreakStream();
    h.l(LogLevel.warn, 'lost 2');
    h.l(LogLevel.warn, 'lost 3');
    h.l(LogLevel.info, 'lost, no oseq');
    expect(h.client.debugCounters, (4, 3));
    await h.work((e) => e.flushTombstones());
    final drops = h.readJsonl('drops.jsonl');
    expect(drops.length, 1, reason: '$drops');
    expect(drops[0]['reason'], 'write_failed');
    expect(int_(drops[0]['oseq_from']), 2);
    expect(int_(drops[0]['oseq_to']), 3);
    expect(int_(drops[0]['n']), 2);
    expect(int_(drops[0]['last_ack_age_ms']), -1);
    // 段文件里没有半行
    expect(readSegment(f).length, 2);
  });

  /// 写失败之后关掉写句柄、按 1 s 节流重开（ADR 0020 决定 6）：节流期内的行只计数记墓碑、不碰磁盘；
  /// 重开时接着原段追加（已写的行不丢、header 不重写），seq / oseq 连续。
  test('writeFailureClosesHandleAndReopensThrottled', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    h.l(LogLevel.warn, 'ok 1');
    final f = h.client.debugOpenSegmentFile!;
    h.client.writer.debugBreakStream();
    h.l(LogLevel.warn, 'lost 2');
    expect(h.client.debugOpenSegmentFile, isNull, reason: '失败后句柄关掉');
    h.l(LogLevel.warn, 'lost 3 (throttled)');
    h.clock.advance(999);
    h.l(LogLevel.warn, 'lost 4 (throttled)');
    h.clock.advance(1);
    h.l(LogLevel.warn, 'ok 5');
    expect(h.client.debugOpenSegmentFile, f);
    final ls = readSegment(f);
    expect(ls.length, 3);
    expect(ls.skip(1).map((l) => JsonIn.objText(l)!['msg']).toList(), ['ok 1', 'ok 5']);
    expect(ls.skip(1).map((l) => int_(JsonIn.objText(l)!['oseq'])).toList(), [1, 5]);
    await h.work((e) => e.flushTombstones());
    final drops = h.readJsonl('drops.jsonl');
    expect(drops.length, 1);
    expect([int_(drops[0]['oseq_from']), int_(drops[0]['oseq_to']), int_(drops[0]['n'])], [2, 4, 3]);
    // 句柄关着时也照常封段（用户边界不跨段）
    h.client.writer.debugBreakStream();
    h.l(LogLevel.warn, 'lost 6');
    h.setUser('u2');
    await h.settle();
    final envs = h.envelopes();
    final all = envs.expand((e) => e.lines).toList()..sort((a, b) => int_(a['seq']).compareTo(int_(b['seq'])));
    expect(all.map((l) => l['msg']).toList(), ['ok 1', 'ok 5']);
    expect(envs.every((e) => e['user_id'] == null), isTrue, reason: '旧用户的行不挂到新用户名下');
  });

  /// Dart 的 append 模式没有 O_APPEND（核实 §11b）：写到一半失败 → 截回上一完整行并把文件位置拉回；之后的写不留全 0 空洞。
  test('partialWriteRollbackLeavesNoZeroHole', () async {
    final h = await Harness.create(key: '');
    await h.settle();
    h.l(LogLevel.warn, 'ok 1');
    final f = h.client.debugOpenSegmentFile!;
    Writer.writeCutForTesting = 10;
    h.l(LogLevel.warn, 'torn 2');
    h.clock.advance(1000);
    h.l(LogLevel.warn, 'ok 3');
    final bytes = File(f).readAsBytesSync();
    expect(bytes.contains(0), isFalse, reason: '无全 0 空洞');
    expect(readSegment(f).skip(1).map((l) => JsonIn.objText(l)!['msg']).toList(), ['ok 1', 'ok 3']);

    // pre 文件同理（句柄一直开着：每次追加前 setPositionSync 到已知长度）
    final s = await StaticHarness.create();
    s.log(LogLevel.warn, 'pre 1');
    TestHooks.preWriteCut = 5;
    s.log(LogLevel.warn, 'pre torn');
    s.log(LogLevel.warn, 'pre 3');
    final pre = File(s.preFiles.single).readAsBytesSync();
    expect(pre.contains(0), isFalse);
    final recs = String.fromCharCodes(pre).split('\n').where((l) => l.isNotEmpty).toList();
    expect(recs.length, 3, reason: 'header + 2 行');
  });

  /// Dart 单线程：多个异步任务交错写，seq / oseq 无重无缺（对位 concurrentLoggingKeepsSeqUnique）。
  test('concurrentLoggingKeepsSeqUnique', () async {
    final h = await Harness.create(key: '');
    Future<void> worker(int t) async {
      for (var i = 0; i < 500; i++) {
        h.l(i % 3 == 0 ? LogLevel.warn : LogLevel.debug, 't$t i$i');
        if (i % 50 == 0) await Future<void>.delayed(Duration.zero);
      }
    }

    await Future.wait([for (var t = 0; t < 8; t++) worker(t)]);
    expect(h.client.debugCounters.$1, 4000);
    await h.settle();
    final ls = sessionLines(h.sessionDir());
    expect(ls.map((l) => int_(l['seq'])).toList(), [for (var i = 1; i <= 4000; i++) i]);
    final oseqs = ls.where((l) => l.map.containsKey('oseq')).map((l) => int_(l['oseq'])).toList();
    expect(oseqs, [for (var i = 1; i <= oseqs.length; i++) i]);
  });

  /// redact 钩子抛异常：该行丢弃（宁丢不漏 PII）、不占 seq、绝不抛给宿主；异常走内部出口。
  test('redactThrowingDropsLineAndNeverThrows', () async {
    final h = await Harness.create(
      key: '',
      options: RetrieverOptions(redact: (line) => line.msg.contains('bad') ? throw ArgumentError('hook bug') : line),
    );
    h.l(LogLevel.warn, 'ok');
    h.l(LogLevel.warn, 'bad line');
    h.l(LogLevel.warn, 'ok 2');
    expect(h.client.debugCounters.$1, 2);
    expect(h.errors.length, 1);
    expect(h.errors[0], isA<ArgumentError>());
    h.errors.clear();
  });
}
