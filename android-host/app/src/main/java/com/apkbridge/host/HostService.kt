package com.apkbridge.host

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.DisplayMetrics
import android.view.WindowManager

class HostService : Service() {

    companion object {
        const val ACTION_START = "com.apkbridge.host.START"
        const val ACTION_STOP = "com.apkbridge.host.STOP"
        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_DATA = "data"
        private const val CHANNEL_ID = "apkbridge_host_channel"
        private const val NOTIF_ID = 1001

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private var mediaProjection: MediaProjection? = null
    private var streamer: AvcScreenStreamer? = null
    private var controlServer: ControlAndInputServer? = null
    private var nsdAdvertiser: NsdAdvertiser? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED) ?: Activity.RESULT_CANCELED
        @Suppress("DEPRECATION")
        val data: Intent? = intent?.getParcelableExtra(EXTRA_DATA)

        if (resultCode != Activity.RESULT_OK || data == null) {
            stopSelf()
            return START_NOT_STICKY
        }

        createNotificationChannel()
        val notif = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIF_ID, notif)
        }

        startStreamingStack(resultCode, data)
        isRunning = true
        return START_STICKY
    }

    private fun startStreamingStack(resultCode: Int, data: Intent) {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ApkBridge::HostWakeLock").apply {
            acquire(10 * 60 * 60 * 1000L)
        }

        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        wifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "ApkBridge::WifiLock").apply {
            acquire()
        }

        val metrics = DisplayMetrics()
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(metrics)

        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val projection = mpm.getMediaProjection(resultCode, data)
        mediaProjection = projection

        val avc = AvcScreenStreamer(
            mediaProjection = projection,
            rawWidth = metrics.widthPixels,
            rawHeight = metrics.heightPixels,
            densityDpi = metrics.densityDpi,
            port = 5567
        )
        avc.start()
        streamer = avc

        val ctrl = ControlAndInputServer(
            context = this,
            screenWidth = avc.width,
            screenHeight = avc.height,
            controlPort = 5566,
            inputPort = 5568,
            isStreamingProvider = { isRunning }
        )
        ctrl.start()
        controlServer = ctrl

        val nsd = NsdAdvertiser(this)
        nsd.start(port = 5566, screenWidth = avc.width, screenHeight = avc.height)
        nsdAdvertiser = nsd
    }

    override fun onDestroy() {
        isRunning = false
        nsdAdvertiser?.stop()
        controlServer?.stop()
        streamer?.stop()
        try { mediaProjection?.stop() } catch (_: Exception) {}
        try { if (wakeLock?.isHeld == true) wakeLock?.release() } catch (_: Exception) {}
        try { if (wifiLock?.isHeld == true) wifiLock?.release() } catch (_: Exception) {}
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                CHANNEL_ID,
                "ApkBridge Host",
                NotificationManager.IMPORTANCE_LOW
            )
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(ch)
        }
    }

    private fun buildNotification(): Notification {
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, HostService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("ApkBridge Host Active")
            .setContentText("Streaming & accepting iOS Hub connections on Wi-Fi")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentIntent(openIntent)
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_media_pause,
                    "Stop",
                    stopIntent
                ).build()
            )
            .setOngoing(true)
            .build()
    }
}
