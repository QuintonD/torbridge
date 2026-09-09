package app.torbridge.torbridge

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import android.os.Environment
import android.os.Build
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val downloadChannelName = "app.torbridge/downloads"
    private val bridgeChannelName = "app.torbridge/bridge"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, downloadChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "resolve" -> result.success(LocalDownloadAccess(this).resolve(
                        call.argument<String>("path"),
                        call.argument<Number>("id")?.toLong()
                    ))
                    "enqueue" -> {
                        val url = call.argument<String>("url")
                        val filename = call.argument<String>("filename")
                        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                        val safeFilename = filename
                            ?.replace(Regex("[\\\\/:*?\"<>|\\p{Cc}]"), "_")
                            ?.trim()
                        when {
                            url.isNullOrBlank() ->
                                result.error("invalid_url", "The download service received an empty URL.", null)
                            Uri.parse(url).scheme !in setOf("http", "https") ->
                                result.error("invalid_url", "The download URL must use HTTP or HTTPS.", null)
                            safeFilename.isNullOrBlank() ->
                                result.error("invalid_filename", "The download filename is empty after sanitizing it.", null)
                            else -> try {
                                result.success(enqueue(url, safeFilename, headers))
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
                    "cancel" -> {
                        val id = call.argument<Number>("id")?.toLong()
                        if (id == null) {
                            result.error("invalid_id", "A download ID is required.", null)
                        } else {
                            manager().remove(id)
                            downloadPath(id)?.let { File(it).delete() }
                            forgetDownload(id)
                            result.success(null)
                        }
                    }
                    "delete" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("invalid_path", "A file path is required.", null)
                        } else {
                            result.success(deletePath(path))
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.torbridge/playback")
            .setMethodCallHandler { call, result ->
                if (call.method != "open") {
                    result.notImplemented()
                } else {
                    try {
                        val raw = call.argument<String>("source") ?: ""
                        val parsed = Uri.parse(raw)
                        val source = if (parsed.scheme == "file" || parsed.scheme == null) {
                            val file = if (parsed.scheme == "file") File(parsed.path ?: "") else File(raw)
                            require(file.isFile)
                            FileProvider.getUriForFile(this, "$packageName.files", file)
                        } else parsed
                        require(source.scheme in setOf("http", "https", "content"))
                        val intent = Intent(Intent.ACTION_VIEW)
                            .setDataAndType(source, "video/*")
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            .putExtra(Intent.EXTRA_TITLE, call.argument<String>("title"))
                        startActivity(Intent.createChooser(intent, "Play in external player"))
                        result.success(true)
                    } catch (error: Exception) {
                        result.error("player_unavailable", "No compatible video player could be opened.", null)
                    }
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, bridgeChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start", "update" -> {
                        val entries = call.argument<String>("entries") ?: "[]"
                        StremioBridgeService.saveEntries(this, entries)
                        val intent = Intent(this, StremioBridgeService::class.java)
                            .setAction(StremioBridgeService.ACTION_START)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    }
                    "ping" -> result.success(StremioBridgeService.isReady)
                    "stop" -> {
                        stopService(Intent(this, StremioBridgeService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun enqueue(
        url: String,
        filename: String,
        headers: Map<String, String>
    ): Map<String, Any> {
        val base = getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: filesDir
        val directory = File(base, "TorBridge").apply { mkdirs() }
        val target = uniqueFile(directory, filename)
        val request = DownloadManager.Request(Uri.parse(url))
            .setTitle(filename)
            .setDescription("Downloading for offline playback in TorBridge")
            .setMimeType("video/*")
            .setAllowedOverMetered(true)
            .setAllowedOverRoaming(false)
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)

        headers.forEach { (name, value) ->
            if (isSafeRequestHeader(name, value)) {
                request.addRequestHeader(name, value)
            }
        }

        request.setDestinationUri(Uri.fromFile(target))
        val id = manager().enqueue(request)
        getSharedPreferences(DOWNLOAD_PREFS, Context.MODE_PRIVATE)
            .edit().putString("path_$id", target.absolutePath).apply()
        return mapOf("id" to id, "path" to target.absolutePath)
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
            return mapOf(
                "state" to state,
                "downloaded" to downloaded,
                "total" to total,
                "reason" to reason,
                "localPath" to downloadPath(id)
            )
        }
    }

    private fun downloadPath(id: Long): String? =
        getSharedPreferences(DOWNLOAD_PREFS, Context.MODE_PRIVATE)
            .getString("path_$id", null)

    private fun forgetDownload(id: Long) {
        getSharedPreferences(DOWNLOAD_PREFS, Context.MODE_PRIVATE)
            .edit().remove("path_$id").apply()
    }

    private fun deletePath(value: String): Boolean {
        return try {
            val uri = Uri.parse(value)
            if (uri.scheme == "content") {
                contentResolver.delete(uri, null, null) > 0
            } else {
                val file = if (uri.scheme == "file") File(uri.path ?: value) else File(value)
                !file.exists() || file.delete()
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun uniqueFile(directory: File, filename: String): File {
        var candidate = File(directory, filename)
        if (!candidate.exists()) return candidate
        val dot = filename.lastIndexOf('.')
        val base = if (dot > 0) filename.substring(0, dot) else filename
        val extension = if (dot > 0) filename.substring(dot) else ""
        var suffix = 2
        while (candidate.exists()) {
            candidate = File(directory, "$base ($suffix)$extension")
            suffix++
        }
        return candidate
    }

    private fun isSafeRequestHeader(name: String, value: String): Boolean {
        if (name.isBlank() || name.contains(':') || name.contains('\r') || name.contains('\n')) {
            return false
        }
        if (value.contains('\r') || value.contains('\n')) return false
        return name.lowercase() !in setOf(
            "connection",
            "content-length",
            "host",
            "transfer-encoding"
        )
    }

    private fun manager(): DownloadManager =
        getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager

    companion object {
        private const val DOWNLOAD_PREFS = "torbridge_downloads"
    }
}
