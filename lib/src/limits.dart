// 线上限与默认值：逐字取自 packages/core/src/limits.ts（改数 = 改契约，同 commit 改方案）。
// 对位 Android `core/Limits.kt`（Limits + ClientConstants），与 iOS `Limits.swift` 同值。

/// §3.1 / §3.4 / §3.5 / §3.7 / §5 的线上数字。
abstract final class Limits {
  // ---- 单行（§3.1）----
  static const int lineMsgBytes = 4096;
  static const int lineTagBytes = 64;
  static const int lineAttrsKeys = 32;
  static const int lineAttrsBytes = 4096;
  static const int lineExcTypeBytes = 256;
  static const int lineExcMessageBytes = 1024;
  static const int lineExcStackBytes = 16 * 1024;
  static const int lineExcStackHeadBytes = 8 * 1024;
  static const int lineExcStackTailBytes = 8 * 1024;
  static const int lineSerializedBytes = 16 * 1024;

  // ---- 段与批（§3.4 / §3.5）----
  static const int segmentBytes = 512 * 1024;
  static const int batchUncompressedBytesClient = 768 * 1024;
  static const int ctxLinesDefault = 200;
  static const int ctxLinesMax = 500;
  static const int ctxBytesDefault = 128 * 1024;
  static const int ctxBytesMax = 256 * 1024;
  static const int dropsPerBatch = 100;
  static const int closedSessionsPerBatch = 20;
  static const int userIdBytes = 128;
  static const int processBytes = 64;
  static const int deviceFieldBytes = 128;

  // ---- 日期（§4）----
  static const int dayClampPastDaysClient = 30;

  // ---- 队列与退避（§3.7）----
  static const int minRequestSpacingMs = 2000;
  static const int backoffBaseMs = 1000;
  static const int backoffMaxMs = 15 * 60 * 1000;
  static const double backoffJitter = 0.2;
  static const int retryAfterMinS = 1;
  static const int retryAfterMaxS = 3600;
  static const int pause401BaseMs = 60 * 60 * 1000;
  static const int pause401MaxMs = 24 * 60 * 60 * 1000;
  static const int poisonConsecutiveFails = 5;
  static const int errorDebounceMs = 2000;
  static const int errorSealMinIntervalMs = 10000;
  static const int ringMaxAgeDays = 7;

  // ---- 远程配置默认与钳制（§5）----
  static const int flushIntervalSDefault = 300;
  static const int flushIntervalSMin = 30;
  static const int flushIntervalSMax = 3600;
  static const int localCapBytesDefault = 20 * 1024 * 1024;
  static const int localCapBytesMin = 2 * 1024 * 1024;
  static const int localCapBytesMax = 100 * 1024 * 1024;
  static const int dailyBatchCapDefault = 0;
  static const int dailyBatchCapMax = 10000;
  static const int configTtlSDefault = 1800;
  static const int configTtlSMin = 60;
  static const int configTtlSMax = 86400;
  static const int overrideTtlSDefault = 86400;
  static const int configPollIntervalS = 1800;
  static const int mappingRefreshMs = 24 * 60 * 60 * 1000;
}

/// 方案正文里有、limits.ts 未收录的客户端数字（§3.2 / §3.6 / §3.7 / §3.8）。与 Android `ClientConstants` 同值。
abstract final class ClientConstants {
  /// §3.8 `drops.jsonl` 与 `sessions.jsonl` 各自的条数上限（ADR 0019 决定 3 / 4）。
  static const int dropsFileMaxEntries = 1000;

  /// 禁用标记没写成时的重试间隔（ADR 0020 决定 2）。
  static const int markerRetryMs = 60000;

  /// §3.8 可用空间余量。
  static const int diskReserveBytes = 64 * 1024 * 1024;

  /// §3.7 隔离批 24 h 后再试。
  static const int quarantineRetryMs = 24 * 60 * 60 * 1000;

  /// 调度地板：任何候选已到期时也至少等 1 s，杜绝 0 ms 自旋。
  static const int schedulerMinDelayMs = 1000;

  /// §3.9 传输连接 / 读超时（v3 §7 K5：HttpClient connectionTimeout 与整体超时）。
  static const int requestTimeoutMs = 30000;

  /// fatal 强制换段的节流窗口（ADR 0024 决定 8）。
  static const int fatalSealWindowMs = 10000;

  /// 段读失败 / 禁用标记判定未知时的重试间隔。
  static const int retryMs = 60000;

  /// 收编没做完、bootstrap 没成的重试间隔 5 s（两端同值）。
  static const int adoptRetryMs = 5000;

  /// attrs 里集合 / 数组 / map 渲染成 JSON 文本时的最大嵌套深度（超出 = 占位串）。
  static const int attrRenderMaxDepth = 8;

  /// attrs 值求值出错时写的占位串（标 truncated）。
  static const String unprintable = '<unprintable>';

  /// §3.1 stack 超长时中间插入的标记。
  static const String stackMarker = '\n…[truncated]…\n';

  static const int dayMs = 24 * 60 * 60 * 1000;

  /// 响应体最多读 64 KB（v3 §7 K5；同 Android `HttpUrlTransport.MAX_RESPONSE_BYTES`）。
  static const int maxResponseBytes = 64 * 1024;

  /// v3 §3：`root()` / `bootstrap()` 的 channel 调用超时。
  static const int channelBootstrapTimeoutMs = 5000;

  /// v3 §3：其余 channel 调用的超时（超时按未知处理）。
  static const int channelCallTimeoutMs = 2000;

  /// K1：`root()` / `bootstrap()` 失败后重试的最小间隔（不用 Timer，等下一次触达）。
  static const int rootRetryMs = 5000;

  /// v3 §4：非 owner 被触达（log / setUser / flush）时重试 bootstrap 的最小间隔（兜底：iOS `destroyContext` 不触发释放事件）。
  static const int nonOwnerRetryMs = 60000;

  /// configure 之前禁用标记判定的缓存时长。
  static const int markerCacheMs = 1000;

  /// v3 §7：超过这个大小的 JSON 编解码进 worker isolate。
  static const int isolateJsonThresholdBytes = 256 * 1024;
}
