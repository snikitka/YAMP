package ru.yamp.app

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build

object RemoteNet {
    private var lock: WifiManager.MulticastLock? = null

    fun multicast(context: Context, on: Boolean): Boolean {
        if (!on) {
            lock?.takeIf { it.isHeld }?.release()
            lock = null
            return true
        }
        if (lock?.isHeld == true) return true
        val wifi = context.applicationContext.getSystemService(WifiManager::class.java) ?: return false
        return runCatching {
            wifi.createMulticastLock("yamp-remote").apply {
                setReferenceCounted(false)
                acquire()
                lock = this
            }
        }.isSuccess
    }

    fun deviceName(): String {
        val maker = Build.MANUFACTURER.orEmpty().trim()
        val model = Build.MODEL.orEmpty().trim()
        return when {
            model.isEmpty() -> maker
            maker.isEmpty() || model.startsWith(maker, ignoreCase = true) -> model
            else -> "${maker.replaceFirstChar { it.uppercase() }} $model"
        }
    }
}
