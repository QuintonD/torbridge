package app.torbridge.torbridge

import android.content.Context
import android.os.Environment
import java.io.File
import java.io.IOException
import java.security.MessageDigest

/** Completed videos must not remain at the path owned by DownloadManager's idle cleanup. */
class DownloadRetention(private val context: Context) {
    private val preferences get() = context.getSharedPreferences("torbridge_downloads", Context.MODE_PRIVATE)

    fun retainedPath(id: Long): String? = preferences.getString("retained_$id", null)
        ?.takeIf { File(it).isFile && File(it).length() > 0 }

    private fun libraryFor(source: File): File? {
        val roots = context.getExternalFilesDirs(Environment.DIRECTORY_MOVIES)
            .filterNotNull().map { it.canonicalFile to File(it, "TorBridge/Library").canonicalFile } +
            (File(context.filesDir, "TorBridge").canonicalFile to
                File(context.filesDir, "TorBridge/Library").canonicalFile)
        return roots.firstOrNull {
            source.path.startsWith(it.first.path + File.separator)
        }?.second
    }

    /** Resolve a journaled rename after a crash, even before Flutter saved the new path. */
    fun recovered(source: File): String? {
        val key = sourceKey(source.canonicalPath)
        return preferences.getString(key, null)?.takeIf {
            File(it).isFile && File(it).length() > 0
        }
    }

    fun retain(file: File, id: Long?): String {
        val source = file.canonicalFile
        val library = libraryFor(source) ?: return source.path // Public downloads are already durable.
        if (source.path.startsWith(library.path + File.separator)) return source.path
        val key = sourceKey(source.path)
        val targetPath = preferences.getString(key, null)
            ?: File(File(library, java.util.UUID.randomUUID().toString()), source.name).path
        val target = File(targetPath)
        if (target.exists()) throw IOException("The library destination is already occupied.")
        if (!target.parentFile!!.isDirectory && !target.parentFile!!.mkdirs()) {
            throw IOException("Could not create the offline library directory.")
        }
        // Journal before the atomic, same-filesystem rename. Never copy partially or overwrite.
        if (!preferences.edit().putString(key, target.path).commit()) {
            throw IOException("Could not save the offline library location.")
        }
        if (!source.renameTo(target)) {
            throw IOException("Could not move the completed video into the offline library.")
        }
        remember(id, target.path)
        return target.path
    }

    fun remember(id: Long?, path: String) {
        if (id == null) return
        preferences.edit().putString("path_$id", path).putString("retained_$id", path).commit()
    }

    private fun sourceKey(path: String): String = "retained_source_" +
        MessageDigest.getInstance("SHA-256").digest(path.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
}
