// 对位 Android NeverThrowTests.kt：公开入口不抛、不崩宿主（ADR 0024 决定 5；简报 §5 / §11 O）。全部走静态入口。
// Dart 差异：参数非空（没有 null level / null key）、没有回调（flush / purgeLocal 返回 Future）、num 不能被继承（没有 EvilNumber）、
// msg 必传（没有「msg 为 null 时取 error.toString()」）；o_retrieverLogSwallowsThrowables 是 Android 的 RetrieverLog，不对位
// （Flutter 的 logger 适配器在 logger_adapter_test.dart 里测）。

import 'dart:collection';
import 'dart:typed_data';

import 'package:revdog_retriever/src/drop_counter.dart';
import 'package:test/test.dart';

import 'support/support.dart';

class EvilThrowable implements Exception {
  @override
  String toString() => throw StateError('toString boom');
}

class EvilObject {
  @override
  String toString() => throw StateError('toString boom');
}

class Ping {
  Ping([this.other]);

  Object? other;

  @override
  String toString() => 'ping($other)';
}

/// 迭代到第 3 个键时抛并发修改。
class Mutating extends MapBase<String, Object?> {
  @override
  Object? operator [](Object? key) => null;

  @override
  void operator []=(String key, Object? value) {}

  @override
  void clear() {}

  @override
  Iterable<String> get keys => const [];

  @override
  Object? remove(Object? key) => null;

  @override
  int get length => 5;

  @override
  Iterable<MapEntry<String, Object?>> get entries => _MutatingEntries();
}

class _MutatingEntries extends IterableBase<MapEntry<String, Object?>> {
  @override
  Iterator<MapEntry<String, Object?>> get iterator => _MutatingIterator();
}

class _MutatingIterator implements Iterator<MapEntry<String, Object?>> {
  int i = 0;
  late MapEntry<String, Object?> _cur;

  @override
  MapEntry<String, Object?> get current => _cur;

  @override
  bool moveNext() {
    if (i == 2) throw ConcurrentModificationError();
    i++;
    _cur = MapEntry('k$i', i);
    return true;
  }
}

List<SegLineRec> lines(StaticHarness h) => sessionLines(h.currentSessionDir());

void main() {
  setUpRtv();

  test('o_degenerateArgumentsNeverThrow', () async {
    final h = await StaticHarness.create(noRoot: true);
    // root 还没回包：只计数
    Retriever.log(LogLevel.warn, 'before root');
    expect(DropCounter.pending, 1);
    h.platform.rootMode = CallMode.ok;
    // 默认 baseUrl、空 key、空 msg、全空可选参数
    await Retriever.configure('');
    await h.settle();
    expect(h.client.engine.key, '');
    expect(h.client.engine.baseUrl, 'https://logs.revdog.org', reason: 'baseUrl 缺省 = 默认');
    final d = lines(h).singleWhere((l) => l['tag'] == DropCounter.tag);
    expect(int_(obj(d['attrs'])['count']), 1);
    Retriever.log(LogLevel.info, '');
    Retriever.log(LogLevel.info, '', tag: '', attrs: const {}, error: null, stackTrace: null);
    // 内部计数只在下一次调度唤醒统一上报（一条），不每条写一行合成行
    for (var i = 0; i < 5; i++) {
      DropCounter.add(LogLevel.error, h.clock.wallMs());
    }
    expect(lines(h).where((l) => l['tag'] == DropCounter.tag).length, 1);
    await h.client.tickNow();
    final all = lines(h).where((l) => l['tag'] == DropCounter.tag).toList();
    expect(all.length, 2);
    expect(int_(obj(all[1]['attrs'])['count']), 5);
    await Retriever.flush();
    await Retriever.purgeLocal();
    Retriever.setUser(null);
    await h.settle();
    // RetrieverOptions 的可空字段能用 copyWith 改回 null（哨兵）
    final o = RetrieverOptions(processName: 'x', redact: (l) => l).copyWith(processName: null, redact: null);
    expect(o.processName, isNull);
    expect(o.redact, isNull);
    expect(o.uploadLevel, LogLevel.warn);
    expect(o.localLevel, LogLevel.debug);
    expect(o.sdkVersion, RetrieverVersion.current);
  });

  /// flush / purgeLocal 的 Future 必完成（configure 之前、之后、实例已关）；flush 实例已关 → timeout。
  test('o_futuresAlwaysComplete', () async {
    final h = await StaticHarness.create();
    expect(await Retriever.flush().timeout(const Duration(seconds: 10)), FlushResult.pending('paused'));
    await Retriever.purgeLocal().timeout(const Duration(seconds: 10));
    await h.configure('');
    await h.settle();
    expect(await Retriever.flush().timeout(const Duration(seconds: 30)), isA<FlushResult>());
    await Retriever.purgeLocal().timeout(const Duration(seconds: 10));
    await h.settle();
    // 实例已关：flush 也必完成（timeout）
    await h.client.closeForTesting();
    expect(await Retriever.flush().timeout(const Duration(seconds: 10)), FlushResult.pending('timeout'));
    await Retriever.purgeLocal().timeout(const Duration(seconds: 10));
    h.errors.clear();
  });

  /// 宿主对象出错只影响那个值：行照常落盘，值写占位串并标 truncated（configure 之前与之后同一套编码）。
  test('o_hostObjectsThatThrowOnlyAffectThatValue', () async {
    final h = await StaticHarness.create();
    final a = Ping();
    final b = Ping(a);
    a.other = b;
    final selfList = <Object?>[1];
    selfList.add(selfList);
    final attrs = <String, Object?>{
      'evil': EvilObject(),
      'cycle': a,
      'self': selfList,
      'ok': 'fine',
      'arr': Int32List.fromList([1, 2, 3]),
      'list': [
        'a',
        2,
        null,
        {'k': true},
      ],
    };
    Retriever.log(LogLevel.error, 'pre', tag: 't', attrs: attrs, error: EvilThrowable());
    Retriever.log(LogLevel.warn, 'mutating', tag: 't', attrs: Mutating());
    await h.configure('');
    h.log(LogLevel.error, 'after', attrs: attrs, error: EvilThrowable());
    await h.settle();
    final ls = lines(h);
    expect(ls.length, 3);
    for (final l in [ls[0], ls[2]]) {
      final at = obj(l['attrs']);
      expect(at['evil'], '<unprintable>');
      expect(at['cycle'], '<unprintable>');
      expect(at['self'], '<unprintable>');
      expect(at['ok'], 'fine');
      expect(at['arr'], '[1,2,3]', reason: '数组输出元素');
      expect(at['list'], '["a",2,null,{"k":true}]');
      expect(l['truncated'], true);
      expect(obj(l['exc'])['message'], '<unprintable>');
      expect(obj(l['exc'])['type'], 'EvilThrowable');
    }
    expect(ls[0]['msg'], 'pre');
    expect(ls[2]['msg'], 'after');
    expect(ls[1]['attrs'], {'k1': 1.0, 'k2': 2.0}, reason: '并发修改：已拿到的键照用');
    expect(ls[1]['truncated'], true);
    expect(DropCounter.pending, 0);
  });
}
