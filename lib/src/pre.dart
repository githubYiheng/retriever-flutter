// configure 之前（ADR 0023；sdk-0.3.0 简报 §1.1；v3 §1）：没有实例，`log()` 只把行追加到 `<root>/pre/<token>-<uuid>.jsonl`。
// 对位 Android `core/Pre.kt` 的 PreRecords / PreFile / OrphanPre / PreLog / TestHooks（DropCounter、Markers、RootPurge 各自成文件）。
//
// Flutter 差异：
// - 文件名前缀 `token` = 垫片在 `root()` 回包里给的进程级静态 UUID（v3 §1）：同进程别的 Flutter 引擎的 pre 文件 flock 拿得到
//   （fcntl 锁是进程级的），但不是孤儿——收编 / 驱逐 / 清理时凡 token 等于自己的一律跳过、**不打开**（打开再关闭会释放那个引擎的锁）。
// - 行写入只用 `writeFromSync`；本进程 pre 文件的读也走同一个句柄（同步分块读：不另开 fd，也不在该句柄上挂异步操作）。

import 'dart:io';
import 'dart:typed_data';

import 'fs.dart';
import 'ids.dart';
import 'json.dart';
import 'limits.dart';
import 'model.dart';
import 'public_api.dart';
import 'text.dart';

/// 测试注入点（生产恒为 null）。
abstract final class TestHooks {
  /// 收编各步骤的崩溃点（`record:<n>` / `before_commit` / `after_unlink` / `attach`）；可以抛（模拟收编中途出错、交接后 attach 失败）。
  static void Function(String point)? adoption;

  /// 实例 `prepare` 的末尾（bootstrap 已回包、实例还没发布的异步间隙）：测试在这里调入口。
  static Future<void> Function()? prepareGap;

  /// 非 null 且返回 true：这次 pre 文件追加按写失败处理（模拟 I/O 错误）。
  static bool Function(List<int> bytes)? preWriteFault;

  /// 非 null：下一次 pre 文件追加只写前 n 字节就失败（模拟写到一半失败；验证截回 + `setPositionSync` 不留全 0 空洞）。
  static int? preWriteCut;
}

/// 进程名清洗（同 Android `RetrieverClient.sanitizeProcessName`）：只留 `[A-Za-z0-9._-]`，其余换成 `_`，≤ 64 B，空 = "main"。
String sanitizeProcessName(String s) {
  final sb = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    final ok =
        (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x61 && c <= 0x7A) ||
        (c >= 0x30 && c <= 0x39) ||
        c == 0x2E ||
        c == 0x5F ||
        c == 0x2D;
    sb.writeCharCode(ok ? c : 0x5F);
  }
  final out = Text.truncate(sb.toString(), Limits.processBytes).s;
  return out.isEmpty ? 'main' : out;
}

sealed class PreRec {
  const PreRec();
}

final class PreHeader extends PreRec {
  const PreHeader(this.startedMs, this.process, this.device);

  final int startedMs;
  final String process;
  final Device device;
}

final class PreUser extends PreRec {
  const PreUser(this.id);

  final String? id;
}

/// `body` = 行体 + `\n`（可直接交给 Writer）；`ts` / `level` 按行首固定位置解析；`synthetic` 按行尾固定位置判断。
final class PreLine extends PreRec {
  const PreLine(this.redacted, this.body, this.ts, this.level, this.synthetic);

  final bool redacted;
  final Uint8List body;
  final int ts;
  final LogLevel level;
  final bool synthetic;
}

final class PreBad extends PreRec {
  const PreBad();
}

/// pre 文件的记录（每条一行，`\n` 结尾）：
/// - 头记录（首行）：`{"pre":1,"started_ms":N,"process":"<p>","device":{os,os_version,model,app_version,build,locale,sdk}}`
/// - 用户切换：`{"pre_user":"<清洗后的 id>"}` / `{"pre_user":null}`
/// - 行：`{"r":0,` 或 `{"r":1,` + 行体（`"ts":…}`，不含 seq / oseq）。`r` = 是否已过 redact。
abstract final class PreRecords {
  static final Uint8List line0 = Bytes.ascii('{"r":0,');
  static final Uint8List line1 = Bytes.ascii('{"r":1,');
  static final Uint8List _header = Bytes.ascii('{"pre":');
  static final Uint8List _user = Bytes.ascii('{"pre_user":');
  static final Uint8List _ts = Bytes.ascii('"ts":');
  static final Uint8List _level = Bytes.ascii(',"level":"');
  static final List<Uint8List> _synth = [
    Bytes.ascii(',"synthetic":true}'),
    Bytes.ascii(',"synthetic":true,"truncated":true}'),
  ];

  static Uint8List header(int startedMs, String process, Device device) {
    final o = JsonOut(256);
    o.raw('{"pre":1,"started_ms":');
    o.integer(startedMs);
    o.raw(',"process":');
    o.string(process);
    o.raw(',"device":');
    device.encode(o);
    o.raw('}\n');
    return o.toBytes();
  }

  static Uint8List user(String? u) {
    final o = JsonOut(64);
    o.raw('{"pre_user":');
    o.stringOrNull(u);
    o.raw('}\n');
    return o.toBytes();
  }

  /// `body` = LineEncoder 的行体（`"ts":…}\n`）。
  static Uint8List line(bool redacted, List<int> body) => Bytes.concat([redacted ? line1 : line0, body]);

  /// 解析 `[s, e)`（不含 `\n`）一条记录。按前缀分类，不按子串嗅探。
  static PreRec parse(Uint8List d, int s, int e) {
    if (Bytes.startsWith(d, s, e, line0) || Bytes.startsWith(d, s, e, line1)) {
      final redacted = d[s + 5] == 0x31;
      final bs = s + line0.length;
      final tl = _tsLevelAt(d, bs, e);
      if (tl == null) return const PreBad();
      final body = Uint8List(e - bs + 1);
      body.setRange(0, e - bs, d, bs);
      body[body.length - 1] = 0x0A;
      var synthetic = false;
      for (final suf in _synth) {
        if (Bytes.hasSuffix(d, s, e, suf)) synthetic = true;
      }
      return PreLine(redacted, body, tl.$1, tl.$2, synthetic);
    }
    if (Bytes.startsWith(d, s, e, _user)) {
      final o = JsonIn.obj(Uint8List.sublistView(d, s, e));
      if (o == null || !o.containsKey('pre_user')) return const PreBad();
      final v = o['pre_user'];
      if (v != null && v is! String) return const PreBad();
      // 读回时再清洗一遍（文件可能被别的版本 / 外部改过）
      return PreUser(Text.sanitizeUserId(v as String?));
    }
    if (Bytes.startsWith(d, s, e, _header)) {
      final o = JsonIn.obj(Uint8List.sublistView(d, s, e));
      if (o == null) return const PreBad();
      final started = JsonIn.int64(o['started_ms']);
      if (started == null) return const PreBad();
      final dev = Device.decode(o['device']);
      if (dev == null) return const PreBad();
      final p = o['process'];
      return PreHeader(started, sanitizeProcessName(p is String ? p : 'main'), dev.sanitized());
    }
    return const PreBad();
  }

  /// 行体开头固定为 `"ts":<整数>,"level":"<级别>"`：按位置取 ts 与级别。
  static (int, LogLevel)? _tsLevelAt(Uint8List d, int from, int end) {
    if (!Bytes.startsWith(d, from, end, _ts)) return null;
    var i = from + _ts.length;
    var neg = false;
    if (i < end && d[i] == 0x2D) {
      neg = true;
      i++;
    }
    final digits = i;
    var v = 0;
    while (i < end && d[i] >= 0x30 && d[i] <= 0x39) {
      v = v * 10 + (d[i] - 0x30);
      i++;
    }
    if (i == digits || i - digits > 18) return null;
    if (!Bytes.startsWith(d, i, end, _level)) return null;
    i += _level.length;
    var j = i;
    while (j < end && d[j] != 0x22) {
      j++;
    }
    if (j >= end) return null;
    final level = LogLevels.ofWire(String.fromCharCodes(d, i, j));
    if (level == null) return null;
    return (neg ? -v : v, level);
  }
}

enum PrePut { written, full, failed, closed }

/// 本进程的 pre 文件：进程内首次写时创建并持 flock（表示写它的进程还活着）。读写都走同一个句柄、同步（见文件头）。
class PreFile {
  PreFile._(this.path, this._raf);

  /// 1 MB 上限（简报 §1.1）。
  static const int maxBytes = 1024 * 1024;
  static const String dir = 'pre';
  static const String suffix = '.jsonl';

  /// 本 isolate 里还开着的 pre 文件（绝对路径）：孤儿扫描与驱逐先按它跳过，不在本进程里开再关这些文件。
  static final Set<String> _live = <String>{};

  static bool isLiveHere(String path) => _live.contains(File(path).absolute.path);

  final String path;
  final RandomAccessFile _raf;
  int _size = 0;
  bool _full = false;

  /// 用户切换记录写失败：之后任何记录都不再写（粘滞），免得之后的行挂到错的用户名下。
  bool _broken = false;
  bool _closed = false;

  String get name => Fs.baseName(path);

  bool get isClosed => _closed;

  int get length => _size;

  /// 一次 write 追加。`capped` = configure 之前的记录：1 MB 上限（含头记录）；超了这条不写并把文件标满（粘滞）。
  /// 交接之后（收编中）的 r = 1 行与用户记录不受上限约束。写失败截回追加前的长度。
  PrePut append(List<int> bytes, bool capped) {
    if (_closed) return PrePut.closed;
    if (_broken) return PrePut.failed;
    if (capped && (_full || _size + bytes.length > maxBytes)) {
      _full = true;
      return PrePut.full;
    }
    try {
      final fault = TestHooks.preWriteFault;
      if (fault != null && fault(bytes)) throw const FileSystemException('injected pre write failure');
      _raf.setPositionSync(_size);
      final cut = TestHooks.preWriteCut;
      if (cut != null && cut < bytes.length) {
        TestHooks.preWriteCut = null;
        _raf.writeFromSync(bytes, 0, cut);
        throw const FileSystemException('injected partial pre write');
      }
      _raf.writeFromSync(bytes);
      _size += bytes.length;
      return PrePut.written;
    } catch (_) {
      try {
        _raf.truncateSync(_size);
        _raf.setPositionSync(_size);
      } catch (_) {
        // 读侧会把残行当坏记录跳过
      }
      return PrePut.failed;
    }
  }

  /// 用户切换记录没写成：标坏（粘滞），之后的记录一律不写（调用方计数）。
  void markBroken() => _broken = true;

  /// 读 `[from, 当前长度)`，给了 [max] 则最多读 [max] 字节（同步，同一句柄；读失败返回 null）。
  /// 收编按 ≤ 64 KB 一片读、片之间让出事件循环（审计 #10）。
  Uint8List? readFrom(int from, [int? max]) {
    if (_closed) return null;
    var end = _size;
    if (max != null && from + max < end) end = from + max;
    final n = end - from;
    if (n <= 0) return Uint8List(0);
    try {
      final out = Uint8List(n);
      _raf.setPositionSync(from);
      var got = 0;
      while (got < n) {
        final r = _raf.readIntoSync(out, got, n);
        if (r <= 0) break;
        got += r;
      }
      _raf.setPositionSync(_size);
      return got == n ? out : null;
    } catch (_) {
      return null;
    }
  }

  /// 提交点 / 清空：unlink 成功（或文件已不在），或 unlink 失败但把自己的句柄截成 0 长度成功（恢复按「长度 0 = 已提交」判）
  /// → 关闭（放 flock）返回 true；两者都失败返回 false，文件仍开着、内容完整（调用方稍后重试）。
  bool unlinkAndClose() {
    if (_closed) return true;
    var gone = false;
    try {
      File(path).deleteSync();
      gone = true;
    } catch (_) {
      try {
        gone = FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound;
      } catch (_) {
        gone = false;
      }
    }
    var ok = gone;
    if (!ok) {
      try {
        _raf.truncateSync(0);
        _size = 0;
        ok = true;
      } catch (_) {
        ok = false;
      }
    }
    if (ok) _closeNow();
    return ok;
  }

  /// 关闭但不删（测试模拟进程死亡；或文件交出后不再由本对象管理）。
  void close() => _closeNow();

  void _closeNow() {
    if (_closed) return;
    _closed = true;
    try {
      _raf.unlockSync();
    } catch (_) {}
    try {
      _raf.closeSync();
    } catch (_) {}
    _live.remove(File(path).absolute.path);
  }

  /// 在 `<root>/pre/` 下独占新建 `<token>-<uuid>.jsonl` 并加锁；失败返回 null（调用方计数）。
  static PreFile? create(String root, String token) {
    final d = Fs.join(root, dir);
    try {
      Directory(d).createSync(recursive: true);
    } catch (_) {
      return null;
    }
    final prefix = Ids.isUuid(token) ? '$token-' : '';
    final f = File(Fs.join(d, '$prefix${Ids.newV4()}$suffix'));
    RandomAccessFile raf;
    try {
      f.createSync(exclusive: true);
      raf = f.openSync(mode: FileMode.append);
    } catch (_) {
      return null;
    }
    try {
      raf.lockSync(FileLock.exclusive);
    } catch (_) {
      try {
        raf.closeSync();
      } catch (_) {}
      try {
        f.deleteSync();
      } catch (_) {}
      return null;
    }
    final pf = PreFile._(f.path, raf);
    _live.add(f.absolute.path);
    return pf;
  }
}

/// 别的（可能已死的）进程留下的 pre 文件：拿得到 flock = 写它的进程已死（孤儿）。持锁期间读、收编、unlink。
/// 跳过（不打开）：本 isolate 开着的、token 等于本进程的、本 isolate 已登记加锁的。
class OrphanPre {
  OrphanPre._(this.path);

  final String path;

  String get name => Fs.baseName(path);

  /// 本进程（同 token）写的 pre 文件：不碰。
  static bool sameProcess(String fileName, String? ownToken) =>
      ownToken != null && ownToken.isNotEmpty && fileName.startsWith('$ownToken-');

  static Future<OrphanPre?> tryAcquire(String path, String? ownToken) async {
    if (sameProcess(Fs.baseName(path), ownToken) || PreFile.isLiveHere(path) || LockRegistry.heldHere(path)) {
      return null;
    }
    if (!await Fs.isFile(path)) return null;
    return _acquire(path);
  }

  /// 同步版（configure 之前首次建 pre 文件前清理死文件用）。
  static OrphanPre? tryAcquireSync(String path, String? ownToken) {
    if (sameProcess(Fs.baseName(path), ownToken) || PreFile.isLiveHere(path) || LockRegistry.heldHere(path)) {
      return null;
    }
    try {
      if (!FileSystemEntity.isFileSync(path)) return null;
    } catch (_) {
      return null;
    }
    return _acquire(path);
  }

  static OrphanPre? _acquire(String path) {
    final o = OrphanPre._(path);
    if (!LockRegistry.tryLock(path, 0, -1, o)) return null;
    // 打开与加锁之间对方可能已提交（unlink 后放锁）：锁住的是已删的 inode，放弃（否则会重复收编）
    try {
      if (!FileSystemEntity.isFileSync(path)) {
        o.release();
        return null;
      }
    } catch (_) {
      o.release();
      return null;
    }
    return o;
  }

  /// 经持锁的句柄读（不另开 fd：关任何 fd 都会放掉本进程在它上面的锁）。
  Future<Uint8List?> readAll() => LockRegistry.readAllVia(path, this);

  int get lengthSync {
    try {
      return File(path).lengthSync();
    } catch (_) {
      return -1;
    }
  }

  Future<int> get length async {
    try {
      return await File(path).length();
    } catch (_) {
      return -1;
    }
  }

  /// 提交：unlink，失败则截成 0 长度（恢复按「长度 0 = 已提交」判）。都失败返回 false。
  Future<bool> commit() async {
    try {
      await File(path).delete();
      return true;
    } catch (_) {
      if (!await Fs.exists(path)) return true;
    }
    return LockRegistry.truncateVia(path, this, 0);
  }

  void release() => LockRegistry.releaseAll(path, this);
}

enum PreRes { written, dropped, redirect, wait }

/// 进程内 configure 之前的状态（静态）：本进程的 pre 文件与 configure 之前 `setUser` 的值。
/// 状态：open（没有实例；按需建文件）→ done（文件已交给实例）。Dart 单线程：交接与发布实例在同一个同步块里完成，没有 Android 的
/// HANDED 竞态窗口；done 之后静态路径直接走实例（redirect）。交接之后实例没建成（attach 抛异常）→ [handoffFailed] 回到 open。
abstract final class PreLog {
  static bool _done = false;
  static PreFile? _file;
  static String? _user;

  static String? get pendingUser => _user;

  /// 死掉的 pre 文件的总量 / 个数上限（两端同值）。
  static const int maxDeadBytes = 4 * 1024 * 1024;
  static const int maxDeadFiles = 8;

  /// configure 之前的 `log()`：`record` = [PreRecords.line] 的结果；`header` 只在新建文件时调用。
  static PreRes appendLine(String root, String token, Uint8List record, Uint8List Function() header) {
    if (_done) return PreRes.redirect;
    final f = _file;
    if (f == null) return _createWith(root, token, record, header);
    return _put(f.append(record, true));
  }

  static PreRes _put(PrePut r) {
    switch (r) {
      case PrePut.written:
        return PreRes.written;
      case PrePut.closed:
        return PreRes.redirect;
      case PrePut.full:
      case PrePut.failed:
        return PreRes.dropped;
    }
  }

  /// 进程内首次建 pre 文件之前：`pre/` 下拿得到锁的旧文件（不含本进程与别的活进程的）总量超过 4 MB 或个数超过 8 个时，
  /// 按 mtime 从最旧的删起（R-5：从不 configure 的宿主不让 pre 文件无限累积）。不计数。
  static void _trimDead(String root, String token) {
    final d = Fs.join(root, PreFile.dir);
    final names = Fs.listSync(d);
    if (names == null) return;
    final dead = <OrphanPre>[];
    try {
      for (final n in names) {
        if (!n.endsWith(PreFile.suffix)) continue;
        final o = OrphanPre.tryAcquireSync(Fs.join(d, n), token);
        if (o != null) dead.add(o);
      }
      int total() => dead.fold(0, (a, o) => a + (o.lengthSync < 0 ? 0 : o.lengthSync));
      if (dead.length <= maxDeadFiles && total() <= maxDeadBytes) return;
      int mtime(OrphanPre o) {
        try {
          return File(o.path).lastModifiedSync().millisecondsSinceEpoch;
        } catch (_) {
          return 0;
        }
      }

      final sorted = List.of(dead)
        ..sort((a, b) {
          final c = mtime(a).compareTo(mtime(b));
          return c != 0 ? c : a.name.compareTo(b.name);
        });
      var count = sorted.length;
      var bytes = total();
      for (final o in sorted) {
        if (count <= maxDeadFiles && bytes <= maxDeadBytes) break;
        final len = o.lengthSync < 0 ? 0 : o.lengthSync;
        try {
          File(o.path).deleteSync();
          count -= 1;
          bytes -= len;
        } catch (_) {}
      }
    } finally {
      for (final o in dead) {
        o.release();
      }
    }
  }

  /// 首次写：头记录 + （有的话）当前用户 + 这一行，一次 write。写不成就删掉文件，下次再建。
  static PreRes _createWith(String root, String token, Uint8List record, Uint8List Function() header) {
    _trimDead(root, token);
    final f = PreFile.create(root, token);
    if (f == null) return PreRes.dropped;
    final h = header();
    final u = _user != null ? PreRecords.user(_user) : Uint8List(0);
    final all = Bytes.concat([h, u, record]);
    if (f.append(all, true) == PrePut.written) {
      _file = f;
      return PreRes.written;
    }
    f.unlinkAndClose();
    return PreRes.dropped;
  }

  /// configure 之前的 `setUser`（已清洗）：记内存；文件已存在则追加一条用户切换记录（随后创建时写在头记录之后）。
  static void setUser(String? u) {
    if (u == _user) return;
    _user = u;
    if (_done) return;
    final f = _file;
    // 写失败（满了已经粘滞）：标坏，之后的行计数，绝不挂到错的用户名下
    if (f != null && f.append(PreRecords.user(u), true) == PrePut.failed) f.markBroken();
  }

  /// configure（实例建成、发布的那个同步块里）：取走本进程的 pre 文件（可能为 null）交给新实例。
  static PreFile? handoff() {
    _done = true;
    final f = _file;
    _file = null;
    return f;
  }

  /// 交接之后实例没建成（同 Android `handoffFailed`）：文件拿回来（仍开着、仍持 flock）、回到 open，之后的行照常追加，
  /// 下一次 configure / 重试再收编。
  static void handoffFailed(PreFile? f) {
    _done = false;
    if (f != null && !f.isClosed && _file == null) _file = f;
  }

  /// 当前 pre 文件名（bootstrap 先用它写 meta.pre；交接时若已换了文件，实例补写）。
  static String? get currentName => _file?.name;

  static String? get currentPath => _file?.path;

  /// configure 之前的 purgeLocal / 非 owner 的 purgeLocal：删本进程 pre 文件（下次写时重建；用户值保留）。
  static void discard() {
    _file?.unlinkAndClose();
    _file = null;
  }

  /// 测试：模拟进程重启（关掉文件、不删，回到初始状态）。
  static void resetForTesting() {
    _file?.close();
    _file = null;
    _user = null;
    _done = false;
  }
}
