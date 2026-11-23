package com.apkbridge.host

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log

class NsdAdvertiser(private val context: Context) {
    private val tag = "NsdAdvertiser"
    private var nsdManager: NsdManager? = null
    private var registrationListener: NsdManager.RegistrationListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    fun start(port: Int, screenWidth: Int, screenHeight: Int) {
        stop()
        try {
            val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            multicastLock = wifi?.createMulticastLock("apkbridge_mdns")?.apply {
                setReferenceCounted(false)
                acquire()
            }

            val serviceInfo = NsdServiceInfo().apply {
                serviceName = "ApkBridge-${Build.MODEL}".replace(" ", "-")
                serviceType = "_apkbridge._tcp."
                setPort(port)
                setAttribute("model", Build.MODEL)
                setAttribute("abi", Build.SUPPORTED_ABIS.firstOrNull() ?: "armeabi-v7a")
                setAttribute("w", screenWidth.toString())
                setAttribute("h", screenHeight.toString())
            }

            val listener = object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(info: NsdServiceInfo) {
                    Log.i(tag, "Registered mDNS: ${info.serviceName} on port $port")
                }

                override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                    Log.e(tag, "mDNS registration failed: $errorCode")
                }

                override fun onServiceUnregistered(info: NsdServiceInfo) {
                    Log.i(tag, "Unregistered mDNS: ${info.serviceName}")
                }

                override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                    Log.e(tag, "mDNS unregistration failed: $errorCode")
                }
            }

            nsdManager = (context.getSystemService(Context.NSD_SERVICE) as? NsdManager)?.also {
                it.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, listener)
            }
            registrationListener = listener
        } catch (e: Exception) {
            Log.e(tag, "Failed to start NsdAdvertiser", e)
        }
    }

    fun stop() {
        try {
            registrationListener?.let { nsdManager?.unregisterService(it) }
        } catch (_: Exception) {
        }
        registrationListener = null
        try {
            if (multicastLock?.isHeld == true) {
                multicastLock?.release()
            }
        } catch (_: Exception) {
        }
        multicastLock = null
    }
}
