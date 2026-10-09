package org.revdog.retriever.flutter;

import android.app.Application;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;

/**
 * 只在进程启动时（Application.onCreate 之前）注册进程级前后台 tracker（v3 §1.4；对位原生 SDK {@code RetrieverInitProvider}），
 * 无任何磁盘 I/O、不提供数据。authority = {@code ${applicationId}.revdog_retriever.init}（与原生 SDK 不同，核实 round2 #15）。
 */
public final class RetrieverInitProvider extends ContentProvider {
    @Override
    public boolean onCreate() {
        try {
            Context c = getContext();
            Context app = c == null ? null : c.getApplicationContext();
            if (app == null) app = c;
            if (app instanceof Application) RetrieverPlugin.installTracker((Application) app, true);
        } catch (Throwable t) {
            // 绝不抛给宿主
        }
        return true;
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        return null;
    }

    @Override
    public String getType(Uri uri) {
        return null;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        return null;
    }

    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        return 0;
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        return 0;
    }
}
