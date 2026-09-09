package app.torbridge.torbridge

import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import java.util.concurrent.Executors

/** Retain completions even when Flutter is not running. */
class DownloadCompleteReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != DownloadManager.ACTION_DOWNLOAD_COMPLETE) return
        val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1)
        if (id < 0 || !context.getSharedPreferences("torbridge_downloads", Context.MODE_PRIVATE)
                .contains("path_$id")) return
        val pending = goAsync()
        executor.execute {
            try {
                val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                manager.query(DownloadManager.Query().setFilterById(id)).use { cursor ->
                    if (cursor.moveToFirst() && cursor.getInt(cursor.getColumnIndexOrThrow(
                            DownloadManager.COLUMN_STATUS)) == DownloadManager.STATUS_SUCCESSFUL) {
                        LocalDownloadAccess(context.applicationContext).resolve(null, id)
                    }
                }
            } catch (error: Exception) {
                Log.w("TorBridgeDownloads", "Could not retain completed download $id", error)
            } finally {
                pending.finish()
            }
        }
    }

    companion object {
        private val executor = Executors.newSingleThreadExecutor()
    }
}
