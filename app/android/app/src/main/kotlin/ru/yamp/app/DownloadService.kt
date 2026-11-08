package ru.yamp.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import java.util.Locale

class DownloadService : Service() {
    companion object {
        private const val CHANNEL = "downloads"
        private const val ID = 1
        private var shown = 0L

        fun start(context: Context) {
            val intent = Intent(context, DownloadService::class.java)
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, DownloadService::class.java))
        }

        fun progress(context: Context, active: Int, queued: Int, speed: Double) {
            val now = SystemClock.elapsedRealtime()
            if (now - shown < 1000) return
            shown = now
            val text = buildString {
                append("В работе: ").append(active)
                if (queued > 0) append(", в очереди: ").append(queued)
                if (speed > 0) append(" · ").append(rate(speed))
            }
            manager(context).notify(ID, notification(context, text))
        }

        private fun rate(bytes: Double): String {
            val mb = bytes / (1024 * 1024)
            return if (mb >= 1) String.format(Locale("ru"), "%.1f МБ/с", mb)
            else String.format(Locale("ru"), "%.0f КБ/с", bytes / 1024)
        }

        private fun manager(context: Context) =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        private fun notification(context: Context, text: String): Notification {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager(context).createNotificationChannel(
                    NotificationChannel(CHANNEL, "Загрузки", NotificationManager.IMPORTANCE_LOW),
                )
            }
            val open = PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            return builder
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle("YAMP качает музыку")
                .setContentText(text)
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setProgress(0, 0, true)
                .build()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n = notification(this, "Готовлю загрузку")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(ID, n)
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }
}
