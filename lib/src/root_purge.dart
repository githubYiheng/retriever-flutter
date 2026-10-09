// 清空（ADR 0019 决定 9）：root 整个改名为同级 `<root>.purge-<uuid>` 再删。实例与 configure 之前的 purge 共用。
// 对位 Android `Pre.kt` 的 RootPurge。

import 'dart:io';

import 'fs.dart';
import 'ids.dart';

sealed class PurgeResult {
  const PurgeResult();
}

final class PurgeMoved extends PurgeResult {
  const PurgeMoved(this.dir);

  final String dir;
}

/// root 本来就不在：没东西可清。
final class PurgeAbsent extends PurgeResult {
  const PurgeAbsent();
}

/// 改名失败（root 所在目录只读等）：调用方退回逐项删除。
final class PurgeFailed extends PurgeResult {
  const PurgeFailed();
}

abstract final class RootPurge {
  static const String infix = '.purge-';

  static String _abs(String root) {
    final a = File(root).absolute.path;
    return a.endsWith('/') ? a.substring(0, a.length - 1) : a;
  }

  /// 返回改名后的目录；root 不存在或改名失败返回 null。
  static Future<String?> moveAside(String root) async {
    final r = await move(root);
    return r is PurgeMoved ? r.dir : null;
  }

  static Future<PurgeResult> move(String root) async {
    final abs = _abs(root);
    if (!await Fs.exists(abs)) return const PurgeAbsent();
    final dst = '$abs$infix${Ids.newV4()}';
    try {
      await Directory(abs).rename(dst);
      return PurgeMoved(dst);
    } catch (_) {
      return const PurgeFailed();
    }
  }

  /// 改名失败时的兜底：逐项删除 root 下的内容（宁可失去原子性也要把本地数据清掉；与实例的 purge、iOS 同口径）。
  static Future<void> deleteContents(String root) async {
    for (final name in await Fs.list(root)) {
      await Fs.remove(Fs.join(root, name));
    }
  }

  /// 改名失败时先列出 root 下此刻的全部条目（文件与目录，深度优先）——之后只删这些，purge 之后新建的 pre 文件与状态不碰。
  static Future<List<String>> snapshot(String root) async {
    final out = <String>[];
    Future<void> walk(String d) async {
      for (final n in await Fs.list(d)) {
        final f = Fs.join(d, n);
        if (await Fs.isDirectory(f)) await walk(f);
        out.add(f);
      }
    }

    await walk(root);
    return out;
  }

  /// 删 [snapshot] 列出的条目：文件直接删，目录只在已空时删（里面有 purge 之后新建的东西就留着）。
  static Future<void> deleteListed(List<String> entries) async {
    for (final f in entries) {
      try {
        if (await Fs.isDirectory(f)) {
          if ((await Fs.list(f)).isEmpty) await Directory(f).delete();
        } else {
          await File(f).delete();
        }
      } catch (_) {
        // 删不掉的留着
      }
    }
  }

  static Future<void> removeLeftovers(String root) async {
    final abs = _abs(root);
    final parent = Fs.parentOf(abs);
    final prefix = '${Fs.baseName(abs)}$infix';
    for (final n in await Fs.list(parent)) {
      if (n.startsWith(prefix)) await Fs.remove(Fs.join(parent, n));
    }
  }
}
