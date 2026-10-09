// 文件系统纪律（§3.2 / §3.3；对位 Android `core/Fs.kt`：Fs、RootLocks、SessionLock）。
//
// - 状态文件一律同目录 tmp → `flush()`（= fsync，在 IO 线程上）→ rename；引擎任务里只用异步 IO（v3 §7）。
// - 段文件 / pre 文件的行写入只用 `RandomAccessFile.writeFromSync`（写入白名单，在 writer.dart / pre.dart）。
// - fcntl 锁是**进程级**的、不计数、关同一文件的任何 fd 都会释放本进程在它上面的全部锁（核实 §7）。所以：
//   被加锁的文件（`upload.lock`、`<sid>/lock`、自己的 pre 文件）整个 isolate 只开一个句柄，登记在 [LockRegistry] 里，
//   锁住期间永不关闭；同 isolate 的第二个使用者（测试里的多实例）先查登记表，不另开 fd。worker isolate 不碰它们。
//   加锁一律用非阻塞的 `lockSync`（try-lock，失败 = 本次失败稍后重试，v3 §7），不在异步操作挂起时碰同一个句柄。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'ids.dart';

/// 读的结果：读到 / 确实不存在（ENOENT）/ 读失败（其它错误：权限、I/O、是目录……）。
sealed class ReadResult {
  const ReadResult();
}

final class ReadOk extends ReadResult {
  const ReadOk(this.bytes);

  final Uint8List bytes;
}

final class ReadMissing extends ReadResult {
  const ReadMissing();
}

final class ReadFailed extends ReadResult {
  const ReadFailed();
}

abstract final class Fs {
  /// 测试注入点：非 null 时 [append] 只写前 n 字节就失败（模拟追加写到一半失败）。生产恒为 null。
  static int? appendFaultForTesting;

  /// 测试注入点：非 null 且对该路径返回 true 时 [writeAtomic] 直接失败（模拟 meta.json 写不进）。生产恒为 null。
  static bool Function(String path)? writeAtomicFaultForTesting;

  static String join(String a, String b) => a.endsWith('/') ? '$a$b' : '$a/$b';

  static String baseName(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }

  static String parentOf(String path) {
    final i = path.lastIndexOf('/');
    if (i <= 0) return i == 0 ? '/' : '.';
    return path.substring(0, i);
  }

  static Future<bool> ensureDir(String path) async {
    try {
      final d = Directory(path);
      if (await d.exists()) return true;
      await d.create(recursive: true);
      return await d.exists();
    } catch (_) {
      try {
        return await Directory(path).exists();
      } catch (_) {
        return false;
      }
    }
  }

  static Future<bool> isDirectory(String path) async {
    try {
      return await FileSystemEntity.isDirectory(path);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isFile(String path) async {
    try {
      return await FileSystemEntity.isFile(path);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> exists(String path) async {
    try {
      return await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.notFound;
    } catch (_) {
      return false;
    }
  }

  /// 递归删除（文件或目录）；失败吞掉。
  static Future<void> remove(String path) async {
    try {
      final t = await FileSystemEntity.type(path, followLinks: false);
      if (t == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      } else if (t != FileSystemEntityType.notFound) {
        await File(path).delete();
      }
    } catch (_) {
      // 删不掉的留着
    }
  }

  /// 删一个文件（不递归）；成功或本来就不在返回 true。
  static Future<bool> deleteFile(String path) async {
    try {
      await File(path).delete();
      return true;
    } catch (_) {
      return !await exists(path);
    }
  }

  /// 列目录名（不是目录 / 列不出 = 空表）。
  static Future<List<String>> list(String dir) async => await listStrict(dir) ?? const <String>[];

  /// 列目录，区分「不是目录（空表）」与「是目录却列不出（null）」：身份修复要靠后者判断「本次失败、稍后重试」。
  static Future<List<String>?> listStrict(String dir) async {
    try {
      final d = Directory(dir);
      final t = await FileSystemEntity.type(dir);
      if (t != FileSystemEntityType.directory) return const <String>[];
      final out = <String>[];
      await for (final e in d.list(followLinks: false)) {
        out.add(baseName(e.path));
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  static List<String>? listSync(String dir) {
    try {
      return [for (final e in Directory(dir).listSync(followLinks: false)) baseName(e.path)];
    } catch (_) {
      return null;
    }
  }

  /// 读文件；不是文件 / 读失败返回 null。
  static Future<Uint8List?> read(String path) async {
    try {
      if (!await FileSystemEntity.isFile(path)) return null;
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// 读文件且区分「读失败」（null）与其它：存在但读不了（权限、是目录、I/O）→ null。用于 install.json。
  static Future<Uint8List?> readBytesOrNull(String path) async {
    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// 区分「不存在」与「读失败」（ADR 0024 决定 3：读失败 ≠ 没有内容）。「不存在」还要求父目录列得出且不含它。
  static Future<ReadResult> readResult(String path) async {
    try {
      return ReadOk(await File(path).readAsBytes());
    } catch (_) {
      return await isMissing(path) ? const ReadMissing() : const ReadFailed();
    }
  }

  /// 确实不存在：父目录列得出且不含它；父目录本身也确实不存在（root 整个被删）同样算。列不出 = 不知道 → false。
  static Future<bool> isMissing(String path) async {
    if (await exists(path)) return false;
    final p = parentOf(path);
    if (p == path) return false;
    final names = await listStrict(p);
    if (names == null) return false;
    if (names.isEmpty && !await isDirectory(p)) return isMissing(p);
    return !names.contains(baseName(path));
  }

  /// 同上，同步版（写入侧的换段失败路径用；只在失败时走到）。
  static bool isMissingSync(String path) {
    try {
      if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound) return false;
    } catch (_) {
      return false;
    }
    final p = parentOf(path);
    if (p == path) return false;
    bool parentIsDir;
    try {
      parentIsDir = FileSystemEntity.isDirectorySync(p);
    } catch (_) {
      return false;
    }
    if (!parentIsDir) {
      try {
        if (FileSystemEntity.typeSync(p) == FileSystemEntityType.notFound) return isMissingSync(p);
      } catch (_) {
        return false;
      }
      return false;
    }
    final names = listSync(p);
    if (names == null) return false;
    return !names.contains(baseName(path));
  }

  static Future<int?> size(String path) async {
    try {
      final s = await File(path).stat();
      if (s.type == FileSystemEntityType.notFound) return null;
      return s.size;
    } catch (_) {
      return null;
    }
  }

  static Future<int?> mtimeMs(String path) async {
    try {
      final s = await FileStat.stat(path);
      if (s.type == FileSystemEntityType.notFound) return null;
      return s.modified.millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }

  static Future<void> touch(String path, int wallMs) async {
    try {
      await File(path).setLastModified(DateTime.fromMillisecondsSinceEpoch(wallMs < 0 ? 0 : wallMs));
    } catch (_) {
      // 改不了 mtime：隔离批按旧 mtime 计时（保守）
    }
  }

  static Future<bool> rename(String from, String to) async {
    try {
      final t = await FileSystemEntity.type(from, followLinks: false);
      if (t == FileSystemEntityType.directory) {
        await Directory(from).rename(to);
      } else if (t == FileSystemEntityType.notFound) {
        return false;
      } else {
        await File(from).rename(to);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 原子写：同目录 tmp → write → flush（fsync）→ rename；失败不留半成品。
  static Future<bool> writeAtomic(String path, List<int> bytes) async {
    final fault = writeAtomicFaultForTesting;
    if (fault != null && fault(path)) return false;
    final tmp = join(parentOf(path), '.${baseName(path)}.tmp-${Ids.newV4()}');
    RandomAccessFile? raf;
    try {
      raf = await File(tmp).open(mode: FileMode.write);
      await raf.writeFrom(bytes);
      await raf.flush();
      await raf.close();
      raf = null;
      await File(tmp).rename(path);
      return true;
    } catch (_) {
      try {
        await raf?.close();
      } catch (_) {}
      try {
        await File(tmp).delete();
      } catch (_) {}
      return false;
    }
  }

  /// 写一个新文件并 flush（fsync），不 rename（出站箱 tmp-* 用：调用方自己 rename 到最终名字）。
  static Future<bool> writeSynced(String path, List<int> bytes) async {
    RandomAccessFile? raf;
    try {
      raf = await File(path).open(mode: FileMode.write);
      await raf.writeFrom(bytes);
      await raf.flush();
      await raf.close();
      return true;
    } catch (_) {
      try {
        await raf?.close();
      } catch (_) {}
      return false;
    }
  }

  /// 追加一段字节（一次 write）；文件不存在则创建。失败时截回追加前的长度（ADR 0019 决定 5）。
  static Future<bool> append(String path, List<int> bytes) async {
    int before = 0;
    try {
      if (await FileSystemEntity.isFile(path)) before = await File(path).length();
    } catch (_) {}
    RandomAccessFile? raf;
    try {
      raf = await File(path).open(mode: FileMode.append);
      final cut = appendFaultForTesting;
      if (cut != null && cut < bytes.length) {
        await raf.writeFrom(bytes, 0, cut);
        throw const FileSystemException('injected partial append');
      }
      await raf.writeFrom(bytes);
      await raf.close();
      return true;
    } catch (_) {
      try {
        await raf?.close();
      } catch (_) {}
      try {
        if (await FileSystemEntity.isFile(path) && await File(path).length() > before) await truncate(path, before);
      } catch (_) {}
      return false;
    }
  }

  /// 截断到 size（截残行 / 追加失败回滚）。不 fsync（ADR 0020 决定 6）。
  static Future<bool> truncate(String path, int size) async {
    RandomAccessFile? raf;
    try {
      raf = await File(path).open(mode: FileMode.append);
      await raf.truncate(size);
      await raf.close();
      return true;
    } catch (_) {
      try {
        await raf?.close();
      } catch (_) {}
      return false;
    }
  }

  /// 同步截断（写入侧写失败回滚的兜底：写句柄已坏时按路径截）。
  static bool truncateSync(String path, int size) {
    RandomAccessFile? raf;
    try {
      raf = File(path).openSync(mode: FileMode.append);
      raf.truncateSync(size);
      raf.closeSync();
      return true;
    } catch (_) {
      try {
        raf?.closeSync();
      } catch (_) {}
      return false;
    }
  }

  /// 对已有文件 fsync（恢复封段前）：开一个句柄 flush 再关。段文件不加锁，开关随意。
  static Future<void> syncFile(String path) async {
    RandomAccessFile? raf;
    try {
      raf = await File(path).open(mode: FileMode.append);
      await raf.flush();
    } catch (_) {
      // 照常 rename
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }
}

/// 进程（isolate）内的加锁文件登记表：每个被加锁的路径只开一个句柄；区间 → 持有者。
/// 同 isolate 里第二个持有者拿同一区间 = 失败（模拟 Android 的 OverlappingFileLockException / JVM 内锁）。
abstract final class LockRegistry {
  static final Map<String, _LockedFile> _files = {};

  static String _key(String path) => File(path).absolute.path;

  /// 区间 [start, end) 有没有被本 isolate 里任何持有者占着。
  static bool heldHere(String path, [int start = 0]) => _files[_key(path)]?.owners.containsKey(start) ?? false;

  /// 试锁 [start, end)：本 isolate 别的持有者占着 → false；否则在共享句柄上 fcntl try-lock。
  /// **自己已登记持有也照样重新加锁**（v3 §7 第二轮核实）：同进程里任何别的 fd 关掉（例如旧 owner 引擎的 isolate 死亡后
  /// 被 GC 关掉它的 upload.lock 句柄）都会静默放掉本进程的锁，登记表探测不到；重新 lockSync 要么重新拿回，要么（别的进程
  /// 趁机拿走了）失败——绝不凭「记得已持有」放行。
  static bool tryLock(String path, int start, int end, Object owner) {
    final k = _key(path);
    var f = _files[k];
    final cur = f?.owners[start];
    if (cur != null && !identical(cur, owner)) return false;
    if (f == null) {
      RandomAccessFile raf;
      try {
        raf = File(k).openSync(mode: FileMode.append);
      } catch (_) {
        return false;
      }
      f = _LockedFile(raf);
      _files[k] = f;
    }
    try {
      f.raf.lockSync(FileLock.exclusive, start, end);
    } catch (_) {
      f.owners.remove(start);
      f.ends.remove(start);
      if (f.owners.isEmpty) _drop(k, f);
      return false;
    }
    f.owners[start] = owner;
    f.ends[start] = end;
    return true;
  }

  static void unlock(String path, int start, int end, Object owner) {
    final k = _key(path);
    final f = _files[k];
    if (f == null || !identical(f.owners[start], owner)) return;
    try {
      f.raf.unlockSync(start, end);
    } catch (_) {
      // 关句柄时内核一并释放
    }
    f.owners.remove(start);
    f.ends.remove(start);
  }

  /// 持有者放掉它在这个路径上的全部区间；没有任何持有者了就关句柄（之后按路径重开：root 改名后同名路径是新文件）。
  static void releaseAll(String path, Object owner) {
    final k = _key(path);
    final f = _files[k];
    if (f == null) return;
    for (final s in f.owners.entries.where((e) => identical(e.value, owner)).map((e) => e.key).toList()) {
      try {
        f.raf.unlockSync(s, f.ends[s] ?? -1);
      } catch (_) {}
      f.owners.remove(s);
      f.ends.remove(s);
    }
    if (f.owners.isEmpty) _drop(k, f);
  }

  /// 经持有者自己的句柄读整个文件（不另开 fd：关任何 fd 都会放掉本进程在这个文件上的锁）。
  static Future<Uint8List?> readAllVia(String path, Object owner) async {
    final f = _files[_key(path)];
    if (f == null || !f.owners.values.any((o) => identical(o, owner))) return null;
    try {
      final n = await f.raf.length();
      await f.raf.setPosition(0);
      final out = Uint8List(n);
      var got = 0;
      while (got < n) {
        final r = await f.raf.readInto(out, got, n);
        if (r <= 0) break;
        got += r;
      }
      return got == n ? out : null;
    } catch (_) {
      return null;
    }
  }

  /// 经持有者自己的句柄截断（同上，不另开 fd）。
  static Future<bool> truncateVia(String path, Object owner, int size) async {
    final f = _files[_key(path)];
    if (f == null || !f.owners.values.any((o) => identical(o, owner))) return false;
    try {
      await f.raf.truncate(size);
      return true;
    } catch (_) {
      return false;
    }
  }

  static void _drop(String k, _LockedFile f) {
    _files.remove(k);
    try {
      f.raf.closeSync();
    } catch (_) {}
  }

  /// 测试：模拟进程死亡（放掉并关掉全部句柄）。
  static void resetForTesting() {
    for (final f in _files.values) {
      try {
        f.raf.closeSync();
      } catch (_) {}
    }
    _files.clear();
  }
}

class _LockedFile {
  _LockedFile(this.raf);

  final RandomAccessFile raf;

  /// 区间起点 → 持有者 / 区间终点（`upload.lock` 的 [0,1)、[1,2)；会话锁与 pre 文件是整个文件 [0, -1)）。
  final Map<int, Object> owners = {};
  final Map<int, int> ends = {};
}

/// 根目录上的进程间锁（§3.2 `upload.lock`）：同一个 `upload.lock` 文件、同一个句柄上的两个字节区间——
/// [0,1) = 上传者锁（只在排空出站箱期间持有）；[1,2) = 根级共享状态的读改写锁（install.json 计数器、drops.jsonl、sessions.jsonl）。
/// 根级锁的 isolate 内部分用异步互斥（同一 root 路径共享）+ Zone 标记的重入（v3 §7 J3：`heldByMe`）。重入只认「本次持有」的令牌：
/// 临界区里登记的延后回调会继承 Zone 值，锁释放后令牌作废，泄漏出去的 Zone 不再算重入（审计 #11）。
class RootLocks {
  RootLocks(this.root);

  final String root;

  String get lockFile => Fs.join(root, 'upload.lock');

  static final Map<String, _AsyncMutex> _mutexes = {};

  _AsyncMutex get _mutex => _mutexes.putIfAbsent(File(root).absolute.path, _AsyncMutex.new);

  Object get _zoneKey => _mutex;

  /// 在根级读改写锁内执行 [body]。锁拿不到（`upload.lock` 打不开、fd 耗尽、别的进程一直占着）时**不执行**、返回 null——
  /// 按本次失败处理、稍后重试（ADR 0024 决定 3），绝不不加锁执行。同一调用链里重入直接执行。
  Future<T?> withDirLock<T>(Future<T> Function() body) async {
    final m = _mutex;
    final holding = m.holder;
    if (holding != null && identical(Zone.current[_zoneKey], holding)) return body();
    await m.acquire();
    try {
      // 跨进程：非阻塞 try-lock，拿不到就短暂让出再试（最多约 2 s），仍拿不到 = 本次失败
      var ok = false;
      for (var attempt = 0; attempt < 200; attempt++) {
        if (LockRegistry.tryLock(lockFile, 1, 2, this)) {
          ok = true;
          break;
        }
        if (!await _canOpen()) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      if (!ok) return null;
      final hold = Object();
      m.holder = hold;
      try {
        return await runZoned(body, zoneValues: {_zoneKey: hold});
      } finally {
        m.holder = null;
        LockRegistry.unlock(lockFile, 1, 2, this);
      }
    } finally {
      m.release();
    }
  }

  /// upload.lock 能不能打开（打不开 = 不是锁冲突，不必重试）。
  Future<bool> _canOpen() async {
    try {
      final t = await FileSystemEntity.type(lockFile);
      return t == FileSystemEntityType.file || t == FileSystemEntityType.notFound;
    } catch (_) {
      return false;
    }
  }

  /// 上传者锁：每次选批前重新加锁（不缓存「已持有」），排空结束即释放。
  bool tryUploadLock() => LockRegistry.tryLock(lockFile, 0, 1, this);

  void releaseUploadLock() => LockRegistry.unlock(lockFile, 0, 1, this);

  bool get holdsUploadLock {
    return LockRegistry._files[LockRegistry._key(lockFile)]?.owners[0] == this;
  }

  /// purgeLocal / 关停：释放本对象持有的全部锁（没有别的持有者时关句柄，之后按需在新 root 重开）。
  void close() => LockRegistry.releaseAll(lockFile, this);
}

/// 会话目录锁：锁住会话目录下的专用文件 `lock`（0.3.0 起；只建不读不重写，任何代码都不得另开它）。
/// 进程存活期间一直持有，进程死亡由内核释放；恢复流程拿不到某个旧会话的锁 = 该会话还活着，跳过不动。
class SessionLock {
  SessionLock._(this._path);

  static const String fileName = 'lock';

  final String _path;
  bool _released = false;

  /// 会话目录 [dir] 的锁：拿不到（被占用 / 打不开 / 本 isolate 已持有）返回 null。`lock` 文件不存在时创建（目录不存在则失败）。
  static Future<SessionLock?> tryAcquire(String dir) async {
    if (!await Fs.isDirectory(dir)) return null;
    final path = Fs.join(dir, fileName);
    if (LockRegistry.heldHere(path)) return null;
    final l = SessionLock._(path);
    if (!LockRegistry.tryLock(path, 0, -1, l)) return null;
    return l;
  }

  void release() {
    if (_released) return;
    _released = true;
    LockRegistry.releaseAll(_path, this);
  }
}

/// isolate 内的异步互斥（FIFO）。
class _AsyncMutex {
  Future<void> _tail = Future<void>.value();

  /// 本次持有的令牌（[RootLocks.withDirLock] 判重入用；没人持有 = null）。
  Object? holder;

  Completer<void>? _current;

  Future<void> acquire() {
    final prev = _tail;
    final c = Completer<void>();
    _tail = c.future;
    return prev.then((_) {
      _current = c;
    });
  }

  void release() {
    final c = _current;
    _current = null;
    c?.complete();
  }
}
