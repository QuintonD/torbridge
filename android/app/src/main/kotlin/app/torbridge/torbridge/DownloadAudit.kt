package app.torbridge.torbridge

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Environment
import java.io.File
import java.security.MessageDigest

/** Read-only snapshots. Called on the download I/O executor, never the UI thread. */
class DownloadAudit(private val context: Context) {
    fun snapshot(paths: List<String>): Map<String, Any> = synchronized(LocalDownloadAccess.lock) {
        val prefs = context.getSharedPreferences("torbridge_downloads", Context.MODE_PRIVATE)
        val roots = context.getExternalFilesDirs(Environment.DIRECTORY_MOVIES).filterNotNull()
            .map { File(it, "TorBridge").absolutePath } + File(context.filesDir, "TorBridge").absolutePath
        val rows = mutableListOf<Map<String, Any?>>()
        val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        manager.query(DownloadManager.Query()).use { cursor ->
            while (cursor.moveToNext() && rows.size < 10000) {
                val id = cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_ID))
                val status = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                val raw = cursor.getString(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI))
                val path = raw?.let { if (Uri.parse(it).scheme == "file") Uri.parse(it).path else it }
                val inferred = path?.let { Regex("/TorBridge/Transfers/([A-Za-z0-9_-]+)/[A-Za-z0-9_-]+/").find(it)?.groupValues?.get(1) }
                rows.add(mapOf("id" to id, "jobId" to (prefs.getString("job_$id", null) ?: inferred),
                    "path" to (prefs.getString("path_$id", null) ?: path),
                    "retained" to prefs.getString("retained_$id", null),
                    "expected" to prefs.getLong("bytes_$id", -1),
                    "state" to when (status) {
                        DownloadManager.STATUS_SUCCESSFUL -> "complete"
                        DownloadManager.STATUS_FAILED -> "failed"
                        DownloadManager.STATUS_PAUSED -> "paused"
                        DownloadManager.STATUS_PENDING -> "queued"
                        else -> "downloading"
                    }))
            }
        }
        // Retention survives native record cleanup. Include those identities too.
        val ids = rows.map { it["id"] }.toMutableSet()
        for ((key, value) in prefs.all) {
            if (rows.size >= 10000) break
            if (key.startsWith("retained_") && !key.startsWith("retained_source_") && value is String) {
                val id = key.removePrefix("retained_").toLongOrNull() ?: continue
                if (ids.add(id)) rows.add(mapOf("id" to id,
                    "jobId" to prefs.getString("job_$id", null), "path" to value,
                    "retained" to value, "expected" to prefs.getLong("bytes_$id", -1), "state" to "retained"))
            }
        }
        val journal = prefs.all.filterKeys { it.startsWith("retained_source_") }.values
            .filterIsInstance<String>().take(10000).map { mapOf("target" to it) }.toMutableList()
        for (raw in paths.take(10000)) {
            val uri = Uri.parse(raw)
            if (uri.scheme !in setOf(null, "file")) continue
            val path = File(if (uri.scheme == "file") uri.path ?: continue else raw).canonicalPath
            val digest = MessageDigest.getInstance("SHA-256").digest(path.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            prefs.getString("retained_source_$digest", null)?.let { journal.add(mapOf("source" to raw, "target" to it)) }
        }
        mapOf("roots" to roots, "native" to rows, "journal" to journal,
            "partial" to (rows.size >= 10000 || paths.size > 10000 || journal.size >= 10000))
    }

    fun inspect(raw: String, id: Long?): Map<String, Any> {
        val uri = Uri.parse(raw)
        val expected = id?.let { context.getSharedPreferences("torbridge_downloads", Context.MODE_PRIVATE)
            .getLong("bytes_$it", -1) } ?: -1
        return try {
            if (uri.scheme == "content") {
                context.contentResolver.openAssetFileDescriptor(uri, "r")!!.use { descriptor ->
                    descriptor.createInputStream().use { input ->
                        val buffer = ByteArray(4096)
                        val count = input.read(buffer).coerceAtLeast(0)
                        mapOf("bytes" to descriptor.length, "header" to buffer.take(count).map { it.toInt() and 255 }, "expected" to expected)
                    }
                }
            } else {
                val file = File(if (uri.scheme == "file") uri.path ?: "" else raw)
                val size = file.length()
                val modified = file.lastModified()
                val header = file.inputStream().use { input ->
                    val buffer = ByteArray(4096)
                    val count = input.read(buffer).coerceAtLeast(0)
                    buffer.take(count).map { it.toInt() and 255 }
                }
                mapOf("bytes" to size, "header" to header, "expected" to expected,
                    "changed" to (size != file.length() || modified != file.lastModified()))
            }
        } catch (_: Exception) { mapOf("missing" to true) }
    }
}
