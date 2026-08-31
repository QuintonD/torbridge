package app.torbridge.torbridge

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Environment
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "app.torbridge/downloads"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enqueue" -> {
                        val url = call.argument<String>("url")
                        val filename = call.argument<String>("filename")
                        if (url.isNullOrBlank() || filename.isNullOrBlank() || filename.contains('/')) {
                            result.error("invalid_arguments", "A valid URL and filename are required.", null)
                        } else {
                            try {
                                result.success(enqueue(url, filename))
                            } catch (error: Exception) {
                                result.error("enqueue_failed", error.message, null)
                            }
                        }
                    }
                    "status" -> {
                        val id = call.argument<Number>("id")?.toLong()
                        if (id == null) {
                            result.error("invalid_id", "A download ID is required.", null)
                        } else {
                            result.success(status(id))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun enqueue(url: String, filename: String): Long {
        val request = DownloadManager.Request(Uri.parse(url))
            .setTitle(filename)
            .setDescription("Downloading for offline playback in TorBridge")
            .setMimeType("video/*")
            .setAllowedOverMetered(true)
            .setAllowedOverRoaming(false)
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)

        try {
            request.setDestinationInExternalPublicDir(
                Environment.DIRECTORY_DOWNLOADS,
                "TorBridge/$filename"
            )
        } catch (_: IllegalStateException) {
            // Some freshly-created or constrained emulators cannot create the
            // public Downloads directory on the first request. App-specific
            // external storage still survives process restarts and requires no
            // storage permission, so use it as a safe fallback.
            request.setDestinationInExternalFilesDir(
                this,
                Environment.DIRECTORY_MOVIES,
                filename
            )
        }
        return manager().enqueue(request)
    }

    private fun status(id: Long): Map<String, Any?> {
        val query = DownloadManager.Query().setFilterById(id)
        manager().query(query).use { cursor ->
            if (!cursor.moveToFirst()) {
                return mapOf("state" to "missing", "downloaded" to 0, "total" to -1)
            }
            val status = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            val downloaded = cursor.getLong(
                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)
            )
            val total = cursor.getLong(
                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
            )
            val reason = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
            val state = when (status) {
                DownloadManager.STATUS_SUCCESSFUL -> "complete"
                DownloadManager.STATUS_FAILED -> "failed"
                DownloadManager.STATUS_PAUSED -> "paused"
                DownloadManager.STATUS_PENDING -> "queued"
                else -> "downloading"
            }
            val localUri = if (status == DownloadManager.STATUS_SUCCESSFUL) {
                manager().getUriForDownloadedFile(id)?.toString()
            } else null
            return mapOf(
                "state" to state,
                "downloaded" to downloaded,
                "total" to total,
                "reason" to reason,
                "localUri" to localUri
            )
        }
    }

    private fun manager(): DownloadManager =
        getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
}
