// 配置诊断的出口（ADR 0025；sdk-0.3.0 简报 §13；v3 §1 §13）。对位 Android `ConfigDiagnostics.kt`。
// key / baseUrl 写错、服务端拒绝 key 时在系统日志里说出来：Dart 侧算好（code, message），经垫片 `diagnose(code, message)`
// fire-and-forget 发出（Android `android.util.Log` tag `Retriever`；iOS `os.Logger`）；channel 不可用退回 `print`，仍不抛。
// 去重两层：这里（isolate 内，同一 (code, key 指纹, baseUrl) 只出一次）+ 垫片进程级静态集合。禁用时照常出。
// 测试钩子 = 可替换的 [sink]。

import 'dart:async';

import 'config_check.dart';
import 'ids.dart';
import 'limits.dart';
import 'platform.dart';

abstract final class ConfigDiagnostics {
  /// 非 owner 引擎 configure 时的系统日志（v3 §4：文案固定，不占六个 code）。
  static const String nonOwnerCode = 'configure_ignored';
  static const String nonOwnerMessage = 'configure ignored: another engine owns Retriever in this process';

  static final Set<String> _seen = <String>{};

  /// 当前平台（facade 设）：默认出口经它的 `diagnose`。
  static RetrieverPlatform? Function()? platformOf;

  static void _defaultSink(String code, String message) {
    final p = platformOf?.call();
    if (p == null) {
      print('Retriever: $message');
      return;
    }
    try {
      p.diagnose(code, message).timeout(const Duration(milliseconds: ClientConstants.channelCallTimeoutMs)).catchError((
        Object _,
      ) {
        print('Retriever: $message');
      }).ignore();
    } catch (_) {
      print('Retriever: $message');
    }
  }

  /// 出口：生产 = 垫片 `diagnose`；测试替换成记录 `(code, message)` 的 sink（[resetForTesting] 复位）。
  static void Function(String code, String message) sink = _defaultSink;

  /// configure / 再次 configure：按修剪前后的值做本地检查，逐条出。`rawKey` = 宿主传入的原值。
  static void configured(String rawKey, String key, String baseUrl) {
    try {
      final codes = ConfigCheck.check(rawKey, key, baseUrl);
      if (codes.isEmpty) return;
      final fp = Ids.keyFingerprint(key);
      for (final code in codes) {
        _emit(code, fp, baseUrl, ConfigCheck.message(code));
      }
    } catch (_) {
      // 绝不抛给宿主
    }
  }

  /// 服务端拒绝 key、进入鉴权暂停（请求用的是当前 key 指纹与 baseUrl）。
  static void rejected(KeyRejection r) {
    try {
      _emit(ConfigCheck.keyRejected, r.keyFp, r.baseUrl, ConfigCheck.rejectedMessage(r.status, r.reason, r.pauseMs));
    } catch (_) {}
  }

  /// 非 owner 引擎 configure（每 isolate 一次）。
  static void nonOwner() {
    try {
      _emit(nonOwnerCode, '', '', nonOwnerMessage);
    } catch (_) {}
  }

  static void _emit(String code, String keyFp, String baseUrl, String message) {
    if (!_seen.add('$code\u0000$keyFp\u0000$baseUrl')) return;
    try {
      sink(code, message);
    } catch (_) {
      // 出口本身失败：吞掉
    }
  }

  /// 测试：清空去重集合（不动 sink）。
  static void clearSeenForTesting() => _seen.clear();

  /// 测试：sink 复位为默认出口，去重集合清空。
  static void resetForTesting() {
    sink = _defaultSink;
    _seen.clear();
  }
}
