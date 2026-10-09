// 禁用标记（ADR 0020 决定 2；ADR 0024 决定 6 三态）：root 同级空文件 `<root>.disabled`。对位 Android `Pre.kt` 的 Markers。
// 判定：存在 → present；不存在时列父目录——列不出（无权限、I/O、首次解锁前）→ unknown（按禁用处理），
// 列得出且不含它 → absent（stat 出错也会报「不存在」，不能只靠它）。
// 同步版只给 configure 之前的静态入口用（宿主调用里同步判定 / 落盘，带 1 s 缓存）；实例在引擎任务里用异步版。

import 'dart:io';

import 'fs.dart';

enum MarkerState { present, absent, unknown }

abstract final class Markers {
  static String file(String root) {
    final abs = File(root).absolute.path;
    final r = abs.endsWith('/') ? abs.substring(0, abs.length - 1) : abs;
    return '$r.disabled';
  }

  static Future<MarkerState> state(String root) async {
    final f = file(root);
    if (await Fs.exists(f)) return MarkerState.present;
    final names = await Fs.listStrict(Fs.parentOf(f));
    if (names == null) return MarkerState.unknown;
    return names.contains(Fs.baseName(f)) ? MarkerState.present : MarkerState.absent;
  }

  static MarkerState stateSync(String root) {
    final f = file(root);
    try {
      if (FileSystemEntity.typeSync(f, followLinks: false) != FileSystemEntityType.notFound) return MarkerState.present;
    } catch (_) {
      // 落到下面列目录
    }
    final names = Fs.listSync(Fs.parentOf(f));
    if (names == null) return MarkerState.unknown;
    return names.contains(Fs.baseName(f)) ? MarkerState.present : MarkerState.absent;
  }

  /// 写标记（原子创建）。
  static Future<bool> mark(String root) async {
    final f = File(file(root));
    try {
      await f.create(exclusive: true);
      return true;
    } catch (_) {
      return Fs.exists(f.path);
    }
  }

  static bool markSync(String root) {
    final f = File(file(root));
    try {
      f.createSync(exclusive: true);
      return true;
    } catch (_) {
      try {
        return f.existsSync();
      } catch (_) {
        return false;
      }
    }
  }

  /// 删标记；删不掉返回 false。
  static Future<bool> clear(String root) async {
    final f = File(file(root));
    try {
      if (!await f.exists()) return true;
      await f.delete();
      return true;
    } catch (_) {
      return !await Fs.exists(f.path);
    }
  }

  static bool clearSync(String root) {
    final f = File(file(root));
    try {
      if (!f.existsSync()) return true;
      f.deleteSync();
      return true;
    } catch (_) {
      try {
        return !f.existsSync();
      } catch (_) {
        return false;
      }
    }
  }
}
