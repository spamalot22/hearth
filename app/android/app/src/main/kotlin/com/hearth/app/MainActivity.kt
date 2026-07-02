package com.hearth.app

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Environment
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Bridges Android's system [DownloadManager] to Dart so app updates download in
 * a system process that survives the app being backgrounded, screen-locked, or
 * closed (and resumes across connectivity drops). Dart enqueues the APK, polls
 * status, then verifies its SHA-256 against the signed manifest before install.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "hearth/downloader"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                when (call.method) {
                    "enqueue" -> {
                        val url = call.argument<String>("url")
                        val fileName = call.argument<String>("fileName")
                        if (url == null || fileName == null) {
                            result.error("args", "url and fileName required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            // Overwrite any previous download of the same name so
                            // the app-private dir doesn't accumulate stale APKs.
                            File(
                                getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS),
                                fileName,
                            ).takeIf { it.exists() }?.delete()

                            val req = DownloadManager.Request(Uri.parse(url))
                                .setTitle("Hearth update")
                                .setDescription(fileName)
                                .setNotificationVisibility(
                                    DownloadManager.Request
                                        .VISIBILITY_VISIBLE_NOTIFY_COMPLETED,
                                )
                                .setDestinationInExternalFilesDir(
                                    this,
                                    Environment.DIRECTORY_DOWNLOADS,
                                    fileName,
                                )
                                .setAllowedOverMetered(true)
                                .setAllowedOverRoaming(true)
                            result.success(dm.enqueue(req))
                        } catch (e: Exception) {
                            result.error("enqueue", e.message, null)
                        }
                    }

                    "status" -> {
                        val id = (call.argument<Number>("id"))?.toLong()
                        if (id == null) {
                            result.error("args", "id required", null)
                            return@setMethodCallHandler
                        }
                        dm.query(DownloadManager.Query().setFilterById(id)).use { c ->
                            if (c != null && c.moveToFirst()) {
                                val status = c.getInt(
                                    c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS),
                                )
                                val downloaded = c.getLong(
                                    c.getColumnIndexOrThrow(
                                        DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR,
                                    ),
                                )
                                val total = c.getLong(
                                    c.getColumnIndexOrThrow(
                                        DownloadManager.COLUMN_TOTAL_SIZE_BYTES,
                                    ),
                                )
                                val localUri = c.getString(
                                    c.getColumnIndexOrThrow(
                                        DownloadManager.COLUMN_LOCAL_URI,
                                    ),
                                )
                                val reason = c.getInt(
                                    c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON),
                                )
                                result.success(
                                    mapOf(
                                        "status" to status,
                                        "downloaded" to downloaded,
                                        "total" to total,
                                        "path" to localUri?.let { Uri.parse(it).path },
                                        "reason" to reason,
                                    ),
                                )
                            } else {
                                result.success(null) // not found (cleared)
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
