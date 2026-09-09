package app.torbridge.torbridge

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import java.io.File
import java.io.FileInputStream

/** Resolve old records through Android's download record as well as our saved path. */
class LocalDownloadAccess(private val context: Context) {
    fun resolve(path: String?, id: Long?): String? {
        readable(path)?.let { return it }
        if (id == null) return null
        val saved = context.getSharedPreferences("torbridge_downloads", Context.MODE_PRIVATE)
            .getString("path_$id", null)
        readable(saved)?.let { return it }
        val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        try {
            manager.query(DownloadManager.Query().setFilterById(id)).use { cursor ->
                if (!cursor.moveToFirst()) return null
                if (cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)) !=
                    DownloadManager.STATUS_SUCCESSFUL) return null
                val location = cursor.getString(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI))
                readable(location)?.let { return it }
            }
            return readable(manager.getUriForDownloadedFile(id)?.toString())
        } catch (_: Exception) {
            return null
        }
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
