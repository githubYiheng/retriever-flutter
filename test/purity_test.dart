// 引擎纯度门禁（v3 §6 / 切片 1 简报）：`lib/src/**` 不 import flutter / dart:ui（`channel_platform.dart` 例外，切片 2）；
// web 条件导入只用 `dart.library.io`；`lib/logger.dart` 只经公开门面与桥接触引擎；引擎不碰宿主的 HttpOverrides.runZoned。

import 'dart:io';

import 'package:test/test.dart';

import 'support/support.dart';

final String pkg = '${Repo.root}/sdk/flutter';

List<File> dartFiles(String dir) =>
    Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));

Iterable<String> importsOf(File f) => f
    .readAsLinesSync()
    .map((l) => l.trim())
    .where((l) => l.startsWith('import ') || l.startsWith('export ') || l.startsWith("if ("));

void main() {
  test('engineHasNoFlutterImports', () {
    final offenders = <String>[];
    for (final f in dartFiles('$pkg/lib/src')) {
      if (f.path.endsWith('/channel_platform.dart')) continue;
      final text = f.readAsStringSync();
      if (RegExp(r'''(import|export)\s+['"](package:flutter/|dart:ui)''').hasMatch(text)) offenders.add(f.path);
    }
    expect(offenders, isEmpty);
    // logger 适配器同样纯 Dart（只依赖 package:logger 与本包）
    final logger = File('$pkg/lib/logger.dart').readAsStringSync();
    expect(RegExp(r'''['"](package:flutter/|dart:ui)''').hasMatch(logger), isFalse);
  });

  test('conditionalImportsOnlyUseDartLibraryIo', () {
    for (final f in [...dartFiles('$pkg/lib'), File('$pkg/lib/logger.dart')]) {
      final text = f.readAsStringSync();
      for (final m in RegExp(r'if\s*\(\s*([a-z_.]+)\s*\)').allMatches(text)) {
        final cond = m.group(1)!;
        if (!cond.startsWith('dart.library.')) continue;
        expect(cond, 'dart.library.io', reason: f.path);
      }
    }
  });

  test('loggerAdapterOnlyUsesFacadeAndBridge', () {
    final imports = importsOf(File('$pkg/lib/logger.dart')).join('\n');
    final srcImports = RegExp(r"'src/([a-z_]+)\.dart'").allMatches(imports).map((m) => m.group(1)).toSet();
    expect(srcImports, {'adapter_bridge_stub', 'adapter_bridge'});
  });

  test('noHttpOverridesRunZonedInEngine', () {
    for (final f in dartFiles('$pkg/lib')) {
      expect(f.readAsStringSync().contains('HttpOverrides.runZoned'), isFalse, reason: f.path);
    }
  });

  test('slice1DoesNotShipPlatformCode', () {
    // 切片 1 范围：不写 channel_platform.dart / ios / android / example（切片 2）
    expect(File('$pkg/lib/src/channel_platform.dart').existsSync(), isFalse);
    for (final d in ['ios', 'android', 'example']) {
      expect(Directory('$pkg/$d').existsSync(), isFalse, reason: d);
    }
  });
}
