package com.apkbridge.host

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import java.net.Inet4Address
import java.net.NetworkInterface

class MainActivity : AppCompatActivity() {

    private lateinit var statusText: TextView
    private lateinit var toggleButton: Button
    private lateinit var accButton: Button
    private lateinit var installPermButton: Button

    private val projectionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK && result.data != null) {
            val svcIntent = Intent(this, HostService::class.java).apply {
                action = HostService.ACTION_START
                putExtra(HostService.EXTRA_RESULT_CODE, result.resultCode)
                putExtra(HostService.EXTRA_DATA, result.data)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(svcIntent)
            } else {
                startService(svcIntent)
            }
            toggleButton.postDelayed({ refreshUi() }, 350)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#0F1117"))
            setPadding(56, 80, 56, 56)
            gravity = Gravity.TOP
        }

        val title = TextView(this).apply {
            text = "ApkBridge Host"
            textSize = 26f
            setTypeface(null, Typeface.BOLD)
            setTextColor(Color.WHITE)
        }
        root.addView(title)

        statusText = TextView(this).apply {
            textSize = 14f
            setTextColor(Color.parseColor("#B0B8C8"))
            setPadding(0, 28, 0, 40)
            setLineSpacing(10f, 1.15f)
        }
        root.addView(statusText)

        toggleButton = Button(this).apply {
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.parseColor("#2563EB"))
            setPadding(32, 28, 32, 28)
            setOnClickListener {
                if (HostService.isRunning) {
                    startService(Intent(this@MainActivity, HostService::class.java).setAction(HostService.ACTION_STOP))
                    postDelayed({ refreshUi() }, 250)
                } else {
                    val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                    projectionLauncher.launch(mpm.createScreenCaptureIntent())
                }
            }
        }
        root.addView(toggleButton)

        accButton = Button(this).apply {
            text = "Enable Touch & Key Accessibility"
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.parseColor("#1F2430"))
            setPadding(32, 24, 32, 24)
            setOnClickListener {
                startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            }
        }
        val lp1 = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { topMargin = 28 }
        root.addView(accButton, lp1)

        installPermButton = Button(this).apply {
            text = "Allow Installing GitHub APKs"
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.parseColor("#1F2430"))
            setPadding(32, 24, 32, 24)
            setOnClickListener {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val i = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                        data = Uri.parse("package:$packageName")
                    }
                    startActivity(i)
                }
            }
        }
        val lp2 = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { topMargin = 20 }
        root.addView(installPermButton, lp2)

        setContentView(root)
    }

    override fun onResume() {
        super.onResume()
        refreshUi()
    }

    private fun refreshUi() {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mi = ActivityManager.MemoryInfo()
        am.getMemoryInfo(mi)
        val freeMb = mi.availMem / (1024 * 1024)
        val totalMb = mi.totalMem / (1024 * 1024)

        val ip = getLocalWifiIp() ?: "Unavailable"
        val accReady = BridgeAccessibilityService.instance != null
        val canInstall = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else true

        val stateLabel = if (HostService.isRunning) "RUNNING (5566/5567/5568)" else "STOPPED"
        statusText.text = """
            Status: $stateLabel
            Device: ${Build.MANUFACTURER} ${Build.MODEL}
            ABI: ${Build.SUPPORTED_ABIS.joinToString(", ")}
            Wi-Fi IP: $ip
            RAM: $freeMb MB free / $totalMb MB total
            Touch Accessibility: ${if (accReady) "ENABLED" else "DISABLED"}
            APK Install Perm: ${if (canInstall) "GRANTED" else "NEEDS PERMISSION"}
        """.trimIndent()

        toggleButton.text = if (HostService.isRunning) "Stop Streaming Host" else "Start Streaming Host"
        toggleButton.setBackgroundColor(
            Color.parseColor(if (HostService.isRunning) "#DC2626" else "#2563EB")
        )
    }

    private fun getLocalWifiIp(): String? {
        return try {
            NetworkInterface.getNetworkInterfaces()?.toList()?.flatMap { it.inetAddresses.toList() }
                ?.firstOrNull { !it.isLoopbackAddress && it is Inet4Address }
                ?.hostAddress
        } catch (_: Exception) {
            null
        }
    }
}
