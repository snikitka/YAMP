package ru.yamp.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

object NetworkWatch {
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var registered = false
    private var metered: Boolean? = null

    fun attach(context: Context, ch: MethodChannel) {
        channel = ch
        if (registered) return
        val cm = context.applicationContext.getSystemService(ConnectivityManager::class.java) ?: return
        registered = runCatching {
            cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                    report(!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED))
                }
            })
        }.isSuccess
    }

    fun current(context: Context): Boolean {
        val cm = context.applicationContext.getSystemService(ConnectivityManager::class.java) ?: return false
        return cm.isActiveNetworkMetered
    }

    private fun report(value: Boolean) {
        main.post {
            if (metered == value) return@post
            metered = value
            channel?.invokeMethod("network", value)
        }
    }
}
