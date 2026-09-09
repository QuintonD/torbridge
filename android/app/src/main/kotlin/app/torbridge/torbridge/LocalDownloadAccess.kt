package app.torbridge.torbridge

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import java.io.File
import java.io.FileInputStream

class DownloadRetentionException(val source: String, cause: Exception) : Exception(
    "Could not protect this video from Android download cleanup. The original file was kept. Run Diagnostics to try again.", cause
)

/** Resolve old records through Android's download record as well as our saved path. */
class LocalDownloadAccess(private val context: Context) {
    fun resolve(path: String?, id: Long?): String? = synchronized(lock) {
        resolveLocked(path, id ?: downloadId(path))
    }

    private fun resolveLocked(path: String?, id: Long?): String? {
        val retention = DownloadRetention(context)
        val candidates = mutableListOf<String?>()
        if (id != null) {
            retention.retainedPath(id)?.let { saved -> readable(saved)?.let { return it } }
            candidates.add(context.getSharedPreferences("torbridge_downloads", Context.MODE_PRIVATE)
                .getString("path_$id", null))
            candidates.add(downloadLocation(id))
        }
        candidates.add(path)
        // Prefer a real path so app-private content-URI downloads are also migrated.
        for (candidate in candidates.distinct()) {
            if (candidate.isNullOrBlank()) continue
            val uri = Uri.parse(candidate)
            if (uri.scheme !in setOf(null, "file")) continue
            val file = if (uri.scheme == "file") File(uri.path ?: "") else File(candidate)
            retention.recovered(file)?.let {
                if (readable(it) != null) {
                    retention.remember(id, it)
                    return it
                }
            }
            if (readable(candidate) == null) continue
            try {
                return retention.retain(file, id)
            } catch (error: Exception) {
                throw DownloadRetentionException(file.absolutePath, error)
            }
        }
        for (candidate in candidates) readable(candidate)?.let { return it }
        if (id == null) return null
        val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        return try { readable(manager.getUriForDownloadedFile(id)?.toString()) }
            catch (_: Exception) { null }
    }

    private fun downloadLocation(id: Long): String? {
        val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        try {
            manager.query(DownloadManager.Query().setFilterById(id)).use { cursor ->
                if (!cursor.moveToFirst()) return null
                if (cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)) !=
                    DownloadManager.STATUS_SUCCESSFUL) return null
                return cursor.getString(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI))
            }
        } catch (_: Exception) {
            return null
        }
    }

    private fun downloadId(path: String?): Long? {
        if (path == null) return null
        val uri = Uri.parse(path)
        return if (uri.scheme == "content" && uri.authority == "downloads")
            uri.lastPathSegment?.toLongOrNull() else null
    }

    companion object {
        // Receiver and Flutter can discover the same completion concurrently.
        val lock = Any()
    }

    private fun readable(value: String?): String? {
        if (value.isNullOrBlank()) return null
        return try {
            val uri = Uri.parse(value)
            when (uri.scheme) {
                "content" -> context.contentResolver.openAssetFileDescriptor(uri, "r")?.use {
                    it.createInputStream().use { input -> if (input.read() >= 0) value else null }
                }
                null, "file" -> {
                    val file = if (uri.scheme == "file") File(uri.path ?: "") else File(value)
                    if (!file.isFile) null else FileInputStream(file).use {
                        if (it.read() >= 0) file.absolutePath else null
                    }
                }
                else -> null
            }
        } catch (_: Exception) {
            null
        }
    }
}
