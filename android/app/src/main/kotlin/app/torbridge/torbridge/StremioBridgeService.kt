package app.torbridge.torbridge

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.res.AssetFileDescriptor
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors
import kotlin.math.min

class StremioBridgeService : Service() {
    private var server: ServerSocket? = null
    private val workers = Executors.newCachedThreadPool()

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(this)
        }
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("TorBridge is ready for Stremio")
            .setContentText("Serving downloaded media on this device")
            .setContentIntent(pending)
            .setOngoing(true)
            .build()
        startForeground(NOTIFICATION_ID, notification)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (server == null) startServer()
        return START_STICKY
    }

    override fun onDestroy() {
        isReady = false
        try { server?.close() } catch (_: Exception) {}
        server = null
        workers.shutdownNow()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startServer() {
        workers.execute {
            try {
                val socket = ServerSocket(PORT, 32, InetAddress.getByName("127.0.0.1"))
                server = socket
                isReady = true
                while (!socket.isClosed) {
                    val client = socket.accept()
                    workers.execute { handle(client) }
                }
            } catch (_: Exception) {
                isReady = false
            }
        }
    }

    private fun handle(socket: Socket) {
        socket.use { client ->
            try {
                client.soTimeout = 15_000
                val reader = BufferedReader(InputStreamReader(client.getInputStream()))
                val requestLine = reader.readLine() ?: return
                val parts = requestLine.split(' ')
                if (parts.size < 2) return
                val method = parts[0]
                val rawPath = parts[1].substringBefore('?')
                val headers = mutableMapOf<String, String>()
                while (true) {
                    val line = reader.readLine() ?: break
                    if (line.isEmpty()) break
                    val colon = line.indexOf(':')
                    if (colon > 0) {
                        headers[line.substring(0, colon).lowercase()] = line.substring(colon + 1).trim()
                    }
                }
                if (method == "OPTIONS") {
                    writeResponse(client.getOutputStream(), 204, "No Content", "text/plain", ByteArray(0))
                    return
                }
                when {
                    rawPath == "/health" -> json(
                        client.getOutputStream(),
                        JSONObject().put("status", "ready").put("downloads", entries().length())
                    )
                    rawPath == "/manifest.json" -> json(client.getOutputStream(), manifest())
                    rawPath.startsWith("/stream/") -> serveStreams(client.getOutputStream(), rawPath)
                    rawPath.startsWith("/media/") -> serveMedia(
                        client.getOutputStream(),
                        method,
                        rawPath,
                        headers["range"]
                    )
                    else -> writeResponse(
                        client.getOutputStream(), 404, "Not Found", "text/plain", "Not found".toByteArray()
                    )
                }
            } catch (_: Exception) {
                try {
                    writeResponse(
                        client.getOutputStream(), 500, "Server Error", "text/plain", "Server error".toByteArray()
                    )
                } catch (_: Exception) {}
            }
        }
    }

    private fun manifest(): JSONObject = JSONObject()
        .put("id", "app.torbridge.offline")
        .put("version", "1.2.6")
        .put("name", "TorBridge Offline")
        .put("description", "Downloaded movies and episodes available on this device.")
        .put("resources", JSONArray().put("stream"))
        .put("types", JSONArray().put("movie").put("series"))
        .put("catalogs", JSONArray())
        .put("idPrefixes", JSONArray().put("tt"))
        .put("behaviorHints", JSONObject().put("configurable", false).put("p2p", false))

    private fun serveStreams(output: OutputStream, rawPath: String) {
        val pieces = rawPath.removePrefix("/stream/").split('/', limit = 2)
        if (pieces.size != 2) {
            writeResponse(output, 404, "Not Found", "application/json", "{\"streams\":[]}".toByteArray())
            return
        }
        val type = decode(pieces[0])
        val videoId = decode(pieces[1]).removeSuffix(".json")
        val streams = JSONArray()
        val items = entries()
        for (index in 0 until items.length()) {
            val entry = items.optJSONObject(index) ?: continue
            if (entry.optString("type") != type || entry.optString("videoId") != videoId) continue
            val id = entry.optString("id")
            val hints = JSONObject()
                .put("notWebReady", true)
                .put("filename", entry.optString("filename"))
                .put("bingeGroup", "torbridge-offline-${entry.optString("showId")}")
            if (!entry.isNull("sizeBytes")) hints.put("videoSize", entry.optLong("sizeBytes"))
            streams.put(
                JSONObject()
                    .put("name", "TorBridge Offline")
                    .put("description", entry.optString("description"))
                    .put("url", "http://127.0.0.1:$PORT/media/$id")
                    .put("behaviorHints", hints)
            )
        }
        json(output, JSONObject().put("streams", streams))
    }

    private fun serveMedia(output: OutputStream, method: String, rawPath: String, range: String?) {
        val id = decode(rawPath.removePrefix("/media/"))
        val items = entries()
        var entry: JSONObject? = null
        for (index in 0 until items.length()) {
            val candidate = items.optJSONObject(index) ?: continue
            if (candidate.optString("id") == id) {
                entry = candidate
                break
            }
        }
        val selected = entry
        if (selected == null) {
            writeResponse(output, 404, "Not Found", "text/plain", "Not found".toByteArray())
            return
        }
        val descriptor = try {
            val path = selected.optString("localPath")
            val uri = Uri.parse(path)
            if (uri.scheme == "content") {
                contentResolver.openAssetFileDescriptor(uri, "r")
            } else {
                val file = if (uri.scheme == "file") File(uri.path ?: "") else File(path)
                AssetFileDescriptor(ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY),
                    0, AssetFileDescriptor.UNKNOWN_LENGTH)
            }
        } catch (_: Exception) { null }
        if (descriptor == null) {
            writeResponse(output, 404, "Not Found", "text/plain", "File missing".toByteArray())
            return
        }
        descriptor.use { asset ->
            asset.createInputStream().use { input ->
                val length = if (asset.declaredLength >= 0) asset.declaredLength
                    else input.channel.size() - asset.startOffset
                val parsed = parseRange(range, length)
                if (range != null && parsed == null) {
                    output.write(("HTTP/1.1 416 Range Not Satisfiable\r\n" +
                        "Content-Range: bytes */$length\r\nContent-Length: 0\r\n" +
                        corsHeaders() + "Connection: close\r\n\r\n").toByteArray(StandardCharsets.UTF_8))
                    return
                }
                val start = parsed?.first ?: 0L
                val end = parsed?.second ?: (length - 1)
                val count = (end - start + 1).coerceAtLeast(0)
                val status = if (parsed == null) "HTTP/1.1 200 OK" else "HTTP/1.1 206 Partial Content"
                val filename = selected.optString("filename")
                val header = buildString {
                    append("$status\r\n")
                    append("Content-Type: ${contentType(filename)}\r\n")
                    append("Content-Length: $count\r\n")
                    append("Accept-Ranges: bytes\r\n")
                    if (parsed != null) append("Content-Range: bytes $start-$end/$length\r\n")
                    append(corsHeaders())
                    append("Connection: close\r\n\r\n")
                }
                output.write(header.toByteArray(StandardCharsets.UTF_8))
                if (method == "HEAD" || count == 0L) return
                input.channel.position(asset.startOffset + start)
                var remaining = count
                val buffer = ByteArray(128 * 1024)
                while (remaining > 0) {
                    val read = input.read(buffer, 0, min(buffer.size.toLong(), remaining).toInt())
                    if (read <= 0) break
                    output.write(buffer, 0, read)
                    remaining -= read
                }
                output.flush()
            }
        }
    }

    private fun parseRange(value: String?, length: Long): Pair<Long, Long>? {
        if (value == null || length <= 0 || !value.startsWith("bytes=")) return null
        val parts = value.removePrefix("bytes=").split('-', limit = 2)
        if (parts.size != 2) return null
        if (parts[0].isEmpty()) {
            val suffix = parts[1].toLongOrNull() ?: return null
            if (suffix <= 0) return null
            return Pair((length - suffix).coerceAtLeast(0), length - 1)
        }
        val start = parts[0].toLongOrNull() ?: return null
        if (start !in 0 until length) return null
        val end = if (parts[1].isEmpty()) length - 1 else parts[1].toLongOrNull() ?: return null
        if (end < start) return null
        return Pair(start, end.coerceAtMost(length - 1))
    }

    private fun entries(): JSONArray {
        val text = getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(ENTRIES_KEY, "[]") ?: "[]"
        return try { JSONArray(text) } catch (_: Exception) { JSONArray() }
    }

    private fun json(output: OutputStream, value: JSONObject) {
        writeResponse(output, 200, "OK", "application/json", value.toString().toByteArray())
    }

    private fun writeResponse(
        output: OutputStream,
        code: Int,
        reason: String,
        contentType: String,
        body: ByteArray
    ) {
        val header = buildString {
            append("HTTP/1.1 $code $reason\r\n")
            append("Content-Type: $contentType\r\n")
            append("Content-Length: ${body.size}\r\n")
            append(corsHeaders())
            append("Connection: close\r\n\r\n")
        }
        output.write(header.toByteArray(StandardCharsets.UTF_8))
        output.write(body)
        output.flush()
    }

    private fun corsHeaders(): String =
        "Access-Control-Allow-Origin: *\r\n" +
            "Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n" +
            "Access-Control-Allow-Headers: Range, Content-Type\r\n"

    private fun contentType(filename: String): String = when (filename.substringAfterLast('.', "").lowercase()) {
        "mkv" -> "video/x-matroska"
        "webm" -> "video/webm"
        "avi" -> "video/x-msvideo"
        else -> "video/mp4"
    }

    private fun decode(value: String): String =
        URLDecoder.decode(value, StandardCharsets.UTF_8.name())

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Stremio bridge",
                    NotificationManager.IMPORTANCE_LOW
                ).apply { description = "Keeps downloaded files available to Stremio" }
            )
        }
    }

    companion object {
        const val ACTION_START = "app.torbridge.bridge.START"
        // Stremio's own Android streaming server listens on 11470.
        private const val PORT = 11471
        private const val PREFS = "torbridge_bridge"
        private const val ENTRIES_KEY = "entries"
        private const val CHANNEL_ID = "torbridge_stremio_bridge"
        private const val NOTIFICATION_ID = 11470

        @Volatile
        var isReady: Boolean = false
            private set

        fun saveEntries(context: Context, entries: String) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putString(ENTRIES_KEY, entries).apply()
        }
    }
}
