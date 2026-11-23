package com.apkbridge.host

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.content.FileProvider
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedReader
import java.io.File
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean

class ControlAndInputServer(
    private val context: Context,
    private val screenWidth: Int,
    private val screenHeight: Int,
    private val controlPort: Int = 5566,
    private val inputPort: Int = 5568,
    private val isStreamingProvider: () -> Boolean
) {
    private val tag = "ControlAndInput"
    private val running = AtomicBoolean(false)
    private var httpServer: ServerSocket? = null
    private var inputServer: ServerSocket? = null

    fun start() {
        if (!running.compareAndSet(false, true)) return
        Thread({ runHttpServer() }, "ApkBridge-HTTP").start()
        Thread({ runInputServer() }, "ApkBridge-Input").start()
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) return
        try { httpServer?.close() } catch (_: Exception) {}
        try { inputServer?.close() } catch (_: Exception) {}
    }

    private fun runHttpServer() {
        try {
            val server = ServerSocket(controlPort)
            httpServer = server
            while (running.get()) {
                val client = server.accept()
                Thread { handleHttpClient(client) }.start()
            }
        } catch (e: Exception) {
            if (running.get()) Log.e(tag, "HTTP server error", e)
        }
    }

    private fun handleHttpClient(socket: Socket) {
        try {
            socket.soTimeout = 10_000
            val reader = BufferedReader(InputStreamReader(socket.getInputStream()))
            val requestLine = reader.readLine() ?: return
            val parts = requestLine.split(" ")
            if (parts.size < 2) return
            val method = parts[0]
            val path = parts[1].substringBefore("?")

            var contentLength = 0
            while (true) {
                val line = reader.readLine() ?: break
                if (line.isEmpty()) break
                if (line.startsWith("Content-Length:", ignoreCase = true)) {
                    contentLength = line.substringAfter(":").trim().toIntOrNull() ?: 0
                }
            }

            val body = if (contentLength > 0) {
                val chars = CharArray(contentLength)
                var read = 0
                while (read < contentLength) {
                    val r = reader.read(chars, read, contentLength - read)
                    if (r <= 0) break
                    read += r
                }
                String(chars, 0, read)
            } else ""

            val responseJson = when {
                method == "GET" && path == "/status" -> buildStatusJson()
                method == "POST" && path == "/launch" -> handleLaunch(body)
                method == "POST" && path == "/install" -> handleInstall(body)
                method == "POST" && path == "/stop" -> handleStop(body)
                else -> JSONObject().put("error", "Not found")
            }

            sendJson(socket.getOutputStream(), 200, responseJson.toString())
        } catch (e: Exception) {
            Log.e(tag, "HTTP handle error", e)
        } finally {
            try { socket.close() } catch (_: Exception) {}
        }
    }

    private fun sendJson(out: OutputStream, code: Int, json: String) {
        val bytes = json.toByteArray(Charsets.UTF_8)
        val headers = "HTTP/1.1 $code OK\r\n" +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: ${bytes.size}\r\n" +
            "Connection: close\r\n\r\n"
        out.write(headers.toByteArray(Charsets.US_ASCII))
        out.write(bytes)
        out.flush()
    }

    private fun buildStatusJson(): JSONObject {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mi = ActivityManager.MemoryInfo()
        am.getMemoryInfo(mi)

        val pm = context.packageManager
        val launchable = JSONArray()
        val mainIntent = Intent(Intent.ACTION_MAIN, null).addCategory(Intent.CATEGORY_LAUNCHER)
        val apps = pm.queryIntentActivities(mainIntent, 0)
        val seen = HashSet<String>()
        for (ri in apps) {
            val pkg = ri.activityInfo.packageName
            if (pkg == context.packageName || !seen.add(pkg)) continue
            val isSys = (ri.activityInfo.applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            if (!isSys) {
                launchable.put(
                    JSONObject()
                        .put("packageName", pkg)
                        .put("label", ri.loadLabel(pm).toString())
                )
            }
        }

        return JSONObject().apply {
            put("model", Build.MODEL)
            put("manufacturer", Build.MANUFACTURER)
            put("abis", JSONArray(Build.SUPPORTED_ABIS.toList()))
            put("freeRamMb", mi.availMem / (1024 * 1024))
            put("totalRamMb", mi.totalMem / (1024 * 1024))
            put("screenWidth", screenWidth)
            put("screenHeight", screenHeight)
            put("streaming", isStreamingProvider())
            put("accessibilityReady", BridgeAccessibilityService.instance != null)
            put("installedApps", launchable)
        }
    }

    private fun handleLaunch(body: String): JSONObject {
        val json = JSONObject(body)
        val pkg = json.optString("packageName")
        if (pkg.isBlank()) return JSONObject().put("ok", false).put("error", "Missing packageName")

        // Trim background processes on 2GB RAM devices before launching
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val pm = context.packageManager
        for (app in pm.getInstalledApplications(0)) {
            if (app.packageName != pkg && app.packageName != context.packageName) {
                try { am.killBackgroundProcesses(app.packageName) } catch (_: Exception) {}
            }
        }

        val intent = pm.getLaunchIntentForPackage(pkg)
            ?: return JSONObject().put("ok", false).put("error", "App not installed: $pkg")
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        context.startActivity(intent)
        return JSONObject().put("ok", true).put("launched", pkg)
    }

    private fun handleStop(body: String): JSONObject {
        val json = JSONObject(body)
        val pkg = json.optString("packageName")
        if (pkg.isNotBlank()) {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            am.killBackgroundProcesses(pkg)
        }
        return JSONObject().put("ok", true)
    }

    private fun handleInstall(body: String): JSONObject {
        val json = JSONObject(body)
        val apkUrl = json.optString("apkUrl")
        if (apkUrl.isBlank()) return JSONObject().put("ok", false).put("error", "Missing apkUrl")

        Thread {
            try {
                val apkFile = File(context.cacheDir, "pending_install.apk")
                val conn = (URL(apkUrl).openConnection() as HttpURLConnection).apply {
                    instanceFollowRedirects = true
                    connectTimeout = 15_000
                    readTimeout = 60_000
                    setRequestProperty("User-Agent", "ApkBridgeHost/1.0")
                }
                conn.inputStream.use { input ->
                    BufferedInputStream(input).use { bis ->
                        FileOutputStream(apkFile).use { fos ->
                            bis.copyTo(fos)
                        }
                    }
                }

                val uri: Uri = FileProvider.getUriForFile(
                    context,
                    "${context.packageName}.fileprovider",
                    apkFile
                )
                val installIntent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                context.startActivity(installIntent)
            } catch (e: Exception) {
                Log.e(tag, "APK download/install failed", e)
            }
        }.start()

        return JSONObject().put("ok", true).put("status", "downloading")
    }

    private fun runInputServer() {
        try {
            val server = ServerSocket(inputPort)
            inputServer = server
            while (running.get()) {
                val client = server.accept()
                client.tcpNoDelay = true
                Thread { handleInputClient(client) }.start()
            }
        } catch (e: Exception) {
            if (running.get()) Log.e(tag, "Input server error", e)
        }
    }

    private fun handleInputClient(socket: Socket) {
        try {
            val reader = BufferedReader(InputStreamReader(socket.getInputStream()))
            while (running.get()) {
                val line = reader.readLine() ?: break
                if (line.isBlank()) continue
                val msg = JSONObject(line)
                val acc = BridgeAccessibilityService.instance ?: continue
                when (msg.optString("t")) {
                    "d" -> {
                        val x = (msg.optDouble("x") * screenWidth).toFloat()
                        val y = (msg.optDouble("y") * screenHeight).toFloat()
                        acc.onTouchDown(x, y)
                    }
                    "m" -> {
                        val x = (msg.optDouble("x") * screenWidth).toFloat()
                        val y = (msg.optDouble("y") * screenHeight).toFloat()
                        acc.onTouchMove(x, y)
                    }
                    "u" -> {
                        val x = (msg.optDouble("x") * screenWidth).toFloat()
                        val y = (msg.optDouble("y") * screenHeight).toFloat()
                        acc.onTouchUp(x, y)
                    }
                    "k" -> acc.performNav(msg.optString("action"))
                    "txt" -> acc.injectText(msg.optString("v"))
                    "bs" -> acc.backspaceText()
                }
            }
        } catch (_: Exception) {
        } finally {
            try { socket.close() } catch (_: Exception) {}
        }
    }
}
