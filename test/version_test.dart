// 版本号唯一来源（对位 Android VersionTests 的意图）：`RetrieverVersion.current` == pubspec.yaml 的 version == CHANGELOG 最新条目；
// 进 `device.sdk = "retriever-flutter/<ver>"`、pre 文件头与请求头 `X-Rtv-Sdk`。

import 'dart:io';

import 'package:test/test.dart';

import 'support/support.dart';

final String pkg = '${Repo.root}/sdk/flutter';

void main() {
  setUpRtv();

  test('versionMatchesPubspecAndChangelog', () {
    final pub = File('$pkg/pubspec.yaml').readAsLinesSync();
    final v = pub.firstWhere((l) => l.startsWith('version:')).split(':').last.trim();
    expect(RetrieverVersion.current, v);
    final cl = File('$pkg/CHANGELOG.md').readAsLinesSync().firstWhere((l) => l.startsWith('## '));
    expect(cl.startsWith('## $v'), isTrue, reason: cl);
  });

  test('sdkStringReachesDeviceAndHeaders', () async {
    final h = await Harness.create();
    await h.settle();
    h.l(LogLevel.warn, 'w');
    await h.sealAndDrain();
    final sdk = 'retriever-flutter/${RetrieverVersion.current}';
    final r = h.transport.batchRequests.single;
    expect(r.headers['X-Rtv-Sdk'], sdk);
    expect(obj(FakeTransport.envOf(r.body)!['device'])['sdk'], sdk);
    expect(h.transport.configRequests.every((c) => c.headers['X-Rtv-Sdk'] == sdk), isTrue);
    expect(obj(h.readJson('${h.sessionDir()}/meta.json')['device'])['sdk'], sdk);
  });

  test('preFileHeaderCarriesSdk', () async {
    final h = await StaticHarness.create();
    h.log(LogLevel.info, 'x');
    final header = readJsonlAt(h.preFiles.single).first;
    expect(obj(header['device'])['sdk'], 'retriever-flutter/${RetrieverVersion.current}');
  });
}
