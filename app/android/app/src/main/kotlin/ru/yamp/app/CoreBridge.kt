package ru.yamp.app

import android.content.Context
import android.os.Environment
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import org.json.JSONObject
import ru.yamp.core.mobile.Mobile
import ru.yamp.core.mobile.Sink
import java.io.File

object CoreBridge : Sink {
    private val main = Handler(Looper.getMainLooper())
    private val running = mutableSetOf<Int>()
    private val finished = setOf("done", "error", "cancelled")
    private var events: EventChannel.EventSink? = null
    private var app: Context? = null
    private var busy = false

    fun start(context: Context) {
        val ctx = context.applicationContext
        app = ctx
        val music = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC), "YAMP")
        Mobile.start(ctx.filesDir.path, ctx.cacheDir.path, music.path, this)
    }

    fun attach(sink: EventChannel.EventSink?) {
        events = sink
    }

    fun send(command: String) {
        Mobile.send(command)
    }

    override fun event(event: String) {
        if (event.contains("\"type\":\"installPackage\"")) {
            val path = runCatching { JSONObject(event).getString("path") }.getOrNull()
            val ctx = app
            if (path != null && ctx != null) main.post { ApkProvider.install(ctx, path) }
        }
        val job = event.contains("\"type\":\"job\"")
        val stats = event.contains("\"type\":\"stats\"")
        val json = if (job || stats) runCatching { JSONObject(event) }.getOrNull() else null
        main.post {
            if (json != null) {
                if (job) track(json) else if (busy) progress(json)
            }
            events?.success(event)
        }
    }

    private fun track(json: JSONObject) {
        val id = json.optInt("id")
        if (json.optString("status") in finished) running.remove(id) else running.add(id)
        val ctx = app ?: return
        val now = running.isNotEmpty()
        if (now && !busy) DownloadService.start(ctx)
        if (!now && busy) DownloadService.stop(ctx)
        busy = now
    }

    private fun progress(json: JSONObject) {
        val ctx = app ?: return
        DownloadService.progress(ctx, json.optInt("active"), json.optInt("queued"), json.optDouble("speed", 0.0))
    }
}
