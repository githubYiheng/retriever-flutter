package org.revdog.retriever.flutter;

import android.app.ActivityManager;
import android.app.Application;
import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.StrictMode;
import android.os.storage.StorageManager;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.nio.charset.Charset;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

/**
 * 进程 / 设备事实（对位原生 SDK {@code AndroidPlatform}：{@code deviceFields()}、{@code autoProcessName()}、重要性兜底、
 * {@code availableBytes}、root 目录）。垫片不读不写日志文件、不碰 key（ADR 0003 决定 3 / ADR 0007 D5）：root 只建目录。
 */
final class PlatformInfo {
    private PlatformInfo() {}

    /** 进程级静态 token（同进程每个引擎拿到同一个；小写 UUID，Dart 侧按小写 UUID 校验）。 */
    static final String TOKEN = UUID.randomUUID().toString().toLowerCase(Locale.ROOT);

    private static volatile String processName;

    /** root = {@code noBackupFilesDir/retriever/}（同原生 SDK；默认不进 Auto Backup）。 */
    static File rootDir(Context app) {
        return new File(app.getNoBackupFilesDir(), "retriever");
    }

    /** 建 root 目录（失败也返回路径；不建任何文件）。主线程碰磁盘：放行 StrictMode 再恢复（宿主 penaltyDeath 也不死）。 */
    static String ensureRoot(Context app) {
        StrictMode.ThreadPolicy old = StrictMode.allowThreadDiskWrites();
        try {
            File dir = rootDir(app);
            try {
                if (!dir.isDirectory()) {
                    //noinspection ResultOfMethodCallIgnored
                    dir.mkdirs();
                }
            } catch (SecurityException e) {
                // 照样返回路径：Dart 侧写失败会计数
            }
            return dir.getAbsolutePath();
        } finally {
            StrictMode.setThreadPolicy(old);
        }
    }

    /** 自动进程名：主进程 {@code main}，{@code <pkg>:x} → {@code x}，其它原样（对位 {@code autoProcessName}）。 */
    static String autoProcessName(String name, String pkg) {
        if (name == null || name.isEmpty() || name.equals(pkg)) return "main";
        if (pkg != null && name.startsWith(pkg + ":")) return name.substring(pkg.length() + 1);
        return name;
    }

    static String processName(Context app) {
        String p = processName;
        if (p != null) return p;
        String name;
        if (Build.VERSION.SDK_INT >= 28) {
            name = Application.getProcessName();
        } else {
            name = readCmdline();
        }
        p = autoProcessName(name, app.getPackageName());
        processName = p;
        return p;
    }

    private static String readCmdline() {
        StrictMode.ThreadPolicy old = StrictMode.allowThreadDiskReads();
        try (FileInputStream in = new FileInputStream("/proc/self/cmdline")) {
            byte[] buf = new byte[256];
            int n = in.read(buf);
            if (n <= 0) return null;
            int end = 0;
            while (end < n && buf[end] != 0) end++;
            return new String(buf, 0, end, Charset.forName("UTF-8")).trim();
        } catch (IOException | RuntimeException e) {
            return null;
        } finally {
            StrictMode.setThreadPolicy(old);
        }
    }

    /**
     * 进程重要性 → 前台：FOREGROUND（100）或 VISIBLE（200），与原生 SDK {@code AndroidPlatform.importanceForeground()} 逐字同口径
     * （主代理切片 2 裁决）。FOREGROUND_SERVICE（125，如后台播放中的媒体服务）、PERCEPTIBLE（230）、SERVICE（300）、CACHED（400）都算后台。
     */
    static boolean importanceIsForeground(int importance) {
        return importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
                || importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE;
    }

    /** 读不到 = null。 */
    static Boolean importanceForeground() {
        try {
            ActivityManager.RunningAppProcessInfo info = new ActivityManager.RunningAppProcessInfo();
            ActivityManager.getMyMemoryState(info);
            return importanceIsForeground(info.importance);
        } catch (RuntimeException e) {
            return null;
        }
    }

    /** 设备字段（不含 sdk；对位 {@code AndroidPlatform.deviceFields()}）。 */
    static Map<String, String> deviceFields(Context app) {
        String manufacturer = Build.MANUFACTURER == null ? "" : Build.MANUFACTURER;
        String model = Build.MODEL == null ? "" : Build.MODEL;
        String fullModel = manufacturer.isEmpty() || model.regionMatches(true, 0, manufacturer, 0, manufacturer.length())
                ? model
                : manufacturer + " " + model;
        String versionName = "";
        String versionCode = "";
        try {
            PackageInfo info = app.getPackageManager().getPackageInfo(app.getPackageName(), 0);
            versionName = info.versionName == null ? "" : info.versionName;
            if (Build.VERSION.SDK_INT >= 28) {
                versionCode = Long.toString(info.getLongVersionCode());
            } else {
                versionCode = Integer.toString(versionCodeLegacy(info));
            }
        } catch (PackageManager.NameNotFoundException | RuntimeException e) {
            // 保持空串
        }
        Map<String, String> m = new HashMap<>();
        m.put("os", "android");
        m.put("os_version", Build.VERSION.RELEASE == null ? "" : Build.VERSION.RELEASE);
        m.put("model", fullModel);
        m.put("app_version", versionName);
        m.put("build", versionCode);
        m.put("locale", Locale.getDefault().toLanguageTag());
        return m;
    }

    @SuppressWarnings("deprecation")
    private static int versionCodeLegacy(PackageInfo info) {
        return info.versionCode;
    }

    /**
     * 可分配空间（API 26+ {@code StorageManager.getAllocatableBytes}，含系统可回收的缓存；同原生 SDK）。该调用标 {@code @WorkerThread}
     * （核实 round2 #14）：只在后台线程上调本方法。拿不到 = null。
     */
    static Long availableBytes(Context app) {
        File dir = rootDir(app);
        if (Build.VERSION.SDK_INT >= 26) {
            try {
                StorageManager sm = (StorageManager) app.getSystemService(Context.STORAGE_SERVICE);
                if (sm != null) {
                    File probe = dir.exists() ? dir : app.getNoBackupFilesDir();
                    long v = sm.getAllocatableBytes(sm.getUuidForPath(probe));
                    if (v >= 0) return v;
                }
            } catch (IOException | RuntimeException e) {
                // 回落到 usableSpace
            }
        }
        try {
            File probe = dir.exists() ? dir : app.getNoBackupFilesDir();
            long v = probe.getUsableSpace();
            return v > 0 ? v : null;
        } catch (RuntimeException e) {
            return null;
        }
    }
}
