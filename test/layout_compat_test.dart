// 对位 Android UpgradeTests.kt → Flutter 改为「跨端读取 Android 0.3.0 布局」（v3 §6 LayoutCompatTests）：展开
// packages/core/golden/layout-0.3.0.json（Android 0.3.0 真跑导出）到临时 root 后启动——install 不变、session_no 接计数器、
// 旧会话恢复、批字节原样上传、`X-Rtv-Install` 取信封、同 key 暂停延续 / 换 key 复位、映射 24 h 内不重发、禁用标记生效、
// purge 残留清掉。golden 不带 mtime：展开后把全部文件的 mtime 设到假时钟的「现在」（涉及 mtime 的分支：隔离批 24 h、段 7 天）。
// `upload.lock` 的字节区间锁 golden 表达不了（golden 里只是一个空文件），锁行为在 multi_process_test.dart 里测。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:revdog_retriever/src/fs.dart';
import 'package:revdog_retriever/src/ids.dart';
import 'package:revdog_retriever/src/json.dart';
import 'package:revdog_retriever/src/model.dart';
import 'package:test/test.dart';

import 'support/support.dart';

/// 展开 golden：root 名固定为 `retriever`（同生产；同级标记 / 清空残留的名字也一样）。返回 (root, golden)。
(String, Map<String, Object?>) expandLayout(int mtimeMs) {
  final g = Repo.golden('layout-0.3.0.json');
  final parent = tempDir('rtv-layout');
  final root = '$parent/${g['root']}';
  Directory(root).createSync(recursive: true);
  for (final e in objs(g['entries'])) {
    final rel = e['path'] as String;
    final path = rel.startsWith('../') ? '$parent/${rel.substring(3)}' : '$root/$rel';
    if (e['dir'] == true) {
      Directory(path).createSync(recursive: true);
      continue;
    }
    File(path).parent.createSync(recursive: true);
    final text = e['text'];
    final Uint8List bytes = text is String ? utf8.encode(text) : base64.decode(e['base64'] as String);
    File(path)
      ..writeAsBytesSync(bytes)
      ..setLastModifiedSync(DateTime.fromMillisecondsSinceEpoch(mtimeMs));
  }
  return (root, g);
}

Map<String, Object?> facts(Map<String, Object?> g) => obj(g['facts']);

Uint8List goldenBytes(Map<String, Object?> g, String rel) =>
    base64.decode(objs(g['entries']).singleWhere((e) => e['path'] == rel)['base64'] as String);

const int nowWall = 1790668900000;

void main() {
  setUpRtv();

  /// 同一把 key：install 不变、session_no 接计数器、旧会话 B 恢复（截撕裂的半行、补 corrupt 墓碑、合成 unclean_exit）、
  /// 鉴权暂停延续（零上传）、purge / tmp 残留清掉、会话 A（已收尾）不重复收尾。
  test('sameKeyContinuesPauseAndRecoversOldSession', () async {
    final (root, g) = expandLayout(nowWall);
    final f = facts(g);
    File('$root.disabled').deleteSync();
    final clock = FakeClock(wall: nowWall);
    final h = await Harness.create(root: root, clock: clock);
    await h.settle();
    // install 不变、session_no 接计数器
    expect(h.client.installId, f['install_id']);
    expect(int_(h.readJson('$root/install.json')['session_counter']), int_(f['session_counter']) + 1);
    expect(h.client.supportCode, '${(f['install_id'] as String).substring(0, 8)}-${int_(f['session_counter']) + 1}');
    // purge / tmp 残留清掉
    final parent = Fs.parentOf(root);
    expect(Directory(parent).listSync().where((e) => e.path.split('/').last.startsWith('retriever.purge-')), isEmpty);
    expect(File('$root/${f['tmp_leftover']}').existsSync(), isFalse);
    // 旧会话 B：截掉撕裂的半行（seq 10 / oseq 8 → corrupt 墓碑），前台死亡合成 unclean_exit（seq 11 / oseq 9）
    final sessions = objs(f['sessions']);
    final b = sessions.singleWhere((s) => s['closed'] == false);
    final a = sessions.singleWhere((s) => s['closed'] == true);
    final bSid = b['session_id'] as String;
    final bDir = '$root/proc-main/$bSid';
    final torn = obj(b['torn_line']);
    final ls = sessionLines(bDir);
    expect(ls.where((l) => int_(l['seq']) == int_(torn['seq'])), isEmpty);
    final synth = ls.last;
    expect(synth['tag'], 'rtv.unclean_exit');
    expect(int_(synth['seq']), int_(torn['seq']) + 1);
    expect(int_(synth['oseq']), int_(torn['oseq']) + 1);
    expect(Fs.listSync(bDir)!.where((n) => n.endsWith('.open')), isEmpty, reason: '旧会话的段一律封好');
    final drops = h.readJsonl('drops.jsonl');
    expect(
      drops.where((d) => d['session_id'] == bSid && d['reason'] == 'corrupt').map((d) => int_(d['oseq_from'])).toList(),
      [int_(torn['oseq'])],
    );
    expect(drops.where((d) => d['reason'] == 'write_failed').length, int_(f['drops']), reason: 'golden 里的墓碑原样保留');
    final closed = h.readJsonl('sessions.jsonl');
    expect(closed.where((c) => c['session_id'] == a['session_id']).length, 1, reason: '已收尾的 A 不重复写终态');
    final bClosed = closed.singleWhere((c) => c['session_id'] == bSid);
    expect(bClosed['exit'], 'unclean_fg');
    expect(int_(bClosed['last_oseq']), int_(torn['oseq']) + 1);
    // 同 key：鉴权暂停延续，零上传；暂停到期时刻按墙钟换算
    final bo = await h.backoff;
    expect(bo.pausedCategories, ['all']);
    expect(bo.reason, f['pause_reason']);
    expect(bo.pausedUntilMono - h.nowMono, int_(f['paused_until_ms']) - nowWall);
    expect(h.transport.batchRequests, isEmpty);
    expect(h.client.lastStop.$1, 'paused');
    // golden 的批原样留在出站箱（隔离批 mtime = 现在：24 h 内不放回）
    for (final bt in objs(f['batches'])) {
      final rel = bt['file'] as String;
      expect(File('$root/$rel').readAsBytesSync(), goldenBytes(g, rel), reason: rel);
    }
    expect(h.outboxFiles('q-').length, 1);
  });

  /// 换 key：暂停与退避复位、golden 的批字节原样上传、`X-Rtv-Install` 取信封、映射按未确认重发。
  test('newKeyResetsPauseAndUploadsBytesVerbatim', () async {
    final (root, g) = expandLayout(nowWall);
    final f = facts(g);
    File('$root.disabled').deleteSync();
    final clock = FakeClock(wall: nowWall);
    const newKey = 'lk_test_other_key_00000002';
    final h = await Harness.create(root: root, clock: clock, key: newKey);
    await h.settle();
    expect((await h.backoff).pausedCategories, isEmpty, reason: '换 key 不继承旧 key 的暂停');
    expect(h.readJson('$root/backoff.json')['key_fp'], Ids.keyFingerprint(newKey));
    h.l(LogLevel.warn, 'new session line');
    await h.sealAndDrain();
    for (var i = 0; i < 10; i++) {
      await h.tick(2000);
    }
    final sent = {for (final r in h.transport.batchRequests) FakeTransport.batchId(r.body): r};
    // golden 的 p 批：请求体 == 文件字节（原样上传）；隔离批（q-）24 h 内不发
    for (final bt in objs(f['batches'])) {
      final rel = bt['file'] as String;
      final r = sent[bt['batch_id']];
      if (rel.split('/').last.startsWith('q-')) {
        expect(r, isNull, reason: '隔离批不发');
        continue;
      }
      expect(r, isNotNull, reason: rel);
      expect(r!.body, goldenBytes(g, rel), reason: '批字节原样上传：$rel');
      expect(r.headers['X-Rtv-Install'], FakeTransport.envOf(r.body)!['install_id']);
      expect(r.headers['X-Rtv-Install'], f['install_id']);
    }
    expect(h.outboxFiles().where((n) => !n.startsWith('q-')), isEmpty);
    // 映射：golden 的映射是旧 key 确认的 → 对新 key 按未确认，新会话首批重发
    final own = h.transport.batchRequests
        .map((r) => FakeTransport.envOf(r.body)!)
        .singleWhere((e) => e['session_id'] == h.client.writer.currentSessionId);
    expect(own['mapping'], isNotNull);
    expect(own['user_id'], isNull);
  });

  /// 同 key、映射 24 h 内：不重发映射（golden 的设备是 Android 的——sdk 字段不同，摘要换成本 SDK 设备的摘要后再验）。
  test('mappingWithin24hNotResent', () async {
    final (root, g) = expandLayout(nowWall);
    final f = facts(g);
    File('$root.disabled').deleteSync();
    final m = MappingState.decode(File('$root/mapping.json').readAsBytesSync())!;
    final dev = Device.fromFields(FakePlatform().deviceFields, 'retriever-flutter/${RetrieverVersion.current}');
    File(
      '$root/mapping.json',
    ).writeAsBytesSync(MappingState(m.userId, Ids.deviceDigest(dev), m.ackedMs, m.keyFp, m.baseUrl).encode());
    final clock = FakeClock(wall: nowWall);
    final h = await Harness.create(root: root, clock: clock);
    await h.settle();
    // 暂停到期（仍在 acked_ms 之后 24 h 内）
    clock.advance(int_(f['paused_until_ms']) - nowWall + 1000);
    expect(clock.wallMs() - int_(f['mapping_acked_ms']), lessThan(24 * 3600 * 1000));
    h.l(LogLevel.warn, 'new session line');
    await h.sealAndDrain();
    for (var i = 0; i < 10; i++) {
      await h.tick(2000);
    }
    final own = h.transport.batchRequests
        .map((r) => FakeTransport.envOf(r.body)!)
        .singleWhere((e) => e['session_id'] == h.client.writer.currentSessionId);
    expect(own['mapping'], isNull, reason: '同 key、同设备、24 h 内：不重发映射');
  });

  /// 禁用标记（root 同级 `retriever.disabled`）生效：不写、不传。
  test('disabledMarkerHonored', () async {
    final (root, g) = expandLayout(nowWall);
    expect(File('$root.disabled').existsSync(), isTrue);
    final clock = FakeClock(wall: nowWall + 4000000); // 暂停已到期：挡住上传的只有禁用标记
    final h = await Harness.create(root: root, clock: clock, key: 'lk_test_other_key_00000002');
    await h.settle();
    expect(Retriever.isEnabled, isFalse);
    h.l(LogLevel.error, 'not written');
    expect(h.client.debugCounters.$1, 0);
    await h.tick(60000);
    expect(h.transport.requests, isEmpty);
    expect(h.outboxFiles().length, greaterThanOrEqualTo(objs(facts(g)['batches']).length));
    expect(File('$root.disabled').existsSync(), isTrue);
  });

  /// golden 文件本身能被引擎的解析读回（install / meta / cursor / config / backoff / mapping / 批头）。
  test('goldenFilesDecode', () {
    final (root, g) = expandLayout(nowWall);
    final f = facts(g);
    expect(InstallInfo.decode(File('$root/install.json').readAsBytesSync())!.installId, f['install_id']);
    for (final s in objs(f['sessions'])) {
      final dir = '$root/proc-main/${s['session_id']}';
      final meta = SessionMeta.decode(File('$dir/meta.json').readAsBytesSync())!;
      expect(meta.sessionNo, int_(s['session_no']));
      expect(meta.installId, f['install_id']);
      expect(meta.pre, isNull);
      expect(Cursor.decode(File('$dir/cursor.json').readAsBytesSync())!.closedMs != null, s['closed']);
    }
    final bo = BackoffState.decodeColdStart(File('$root/backoff.json').readAsBytesSync(), nowWall, 0)!;
    expect(bo.keyFp, f['key_fp']);
    expect(bo.baseUrl, f['base_url']);
    expect(MappingState.decode(File('$root/mapping.json').readAsBytesSync())!.ackedMs, int_(f['mapping_acked_ms']));
    final cfg = JsonIn.obj(File('$root/config.json').readAsBytesSync())!;
    expect(cfg['from_host'], f['from_host']);
    for (final bt in objs(f['batches'])) {
      final e = Env.ofGzip('b', goldenBytes(g, bt['file'] as String))!;
      expect(e['batch_id'], bt['batch_id']);
      expect(e.lines.length, int_(bt['lines']));
    }
  });
}
