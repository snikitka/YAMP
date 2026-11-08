package ru.yamp.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

class PlaybackService : Service() {
    data class Track(
        val id: String,
        val title: String,
        val artist: String,
        val album: String,
        val art: String,
        val duration: Long,
        val position: Long,
        val playing: Boolean,
        val buffering: Boolean,
        val liked: Boolean,
        val disliked: Boolean,
    ) {
        companion object {
            fun from(map: Map<*, *>) = Track(
                id = map["id"] as? String ?: "",
                title = map["title"] as? String ?: "",
                artist = map["artist"] as? String ?: "",
                album = map["album"] as? String ?: "",
                art = map["art"] as? String ?: "",
                duration = (map["duration"] as? Number)?.toLong() ?: 0,
                position = (map["position"] as? Number)?.toLong() ?: 0,
                playing = map["playing"] == true,
                buffering = map["buffering"] == true,
                liked = map["liked"] == true,
                disliked = map["disliked"] == true,
            )
        }
    }

    companion object {
        private const val CHANNEL = "player"
        private const val OLD_CHANNEL = "playback"
        private const val ID = 2
        private const val ACTION_PLAY = "ru.yamp.app.PLAY"
        private const val ACTION_PAUSE = "ru.yamp.app.PAUSE"
        private const val ACTION_NEXT = "ru.yamp.app.NEXT"
        private const val ACTION_PREVIOUS = "ru.yamp.app.PREVIOUS"
        private const val ACTION_DISMISS = "ru.yamp.app.DISMISS"
        private const val ACTION_LIKE = "ru.yamp.app.LIKE"
        private const val ACTION_DISLIKE = "ru.yamp.app.DISLIKE"

        private val main = Handler(Looper.getMainLooper())
        private var channel: MethodChannel? = null
        private var track: Track? = null
        private var instance: PlaybackService? = null

        fun attach(context: Context, messenger: BinaryMessenger) {
            val app = context.applicationContext
            channel = MethodChannel(messenger, "yamp/media").apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        "update" -> {
                            update(app, Track.from(call.arguments as Map<*, *>))
                            result.success(null)
                        }
                        "stop" -> {
                            track = null
                            app.stopService(Intent(app, PlaybackService::class.java))
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
            }
        }

        private fun update(context: Context, t: Track) {
            track = t
            val service = instance
            if (service != null) {
                service.render()
            } else if (t.playing) {
                val intent = Intent(context, PlaybackService::class.java)
                runCatching {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(intent)
                    } else {
                        context.startService(intent)
                    }
                }
            }
        }

        private fun command(method: String, argument: Any? = null) {
            main.post { channel?.invokeMethod(method, argument) }
        }
    }

    private lateinit var session: MediaSession
    private lateinit var audio: AudioManager
    private val loader = Executors.newSingleThreadExecutor()
    private var foreground = false
    private var focused = false
    private var resumeOnGain = false
    private var noisyRegistered = false
    private var metadataFor: Track? = null
    private var coverUrl = ""
    private var cover: Bitmap? = null
    private var focusRequest: AudioFocusRequest? = null

    private val noisy = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) command("pause")
        }
    }

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                resumeOnGain = false
                abandonFocus()
                command("pause")
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                if (track?.playing == true) {
                    resumeOnGain = true
                    command("pause")
                }
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                if (resumeOnGain) {
                    resumeOnGain = false
                    command("play")
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) manager().deleteNotificationChannel(OLD_CHANNEL)
        session = MediaSession(this, "YAMP").apply {
            @Suppress("DEPRECATION")
            setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS)
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() = command("play")
                override fun onPause() = command("pause")
                override fun onStop() = command("stop")
                override fun onSkipToNext() = command("next")
                override fun onSkipToPrevious() = command("previous")
                override fun onSeekTo(pos: Long) = command("seek", pos)
                override fun onCustomAction(action: String, extras: Bundle?) {
                    when (action) {
                        ACTION_LIKE -> command("like")
                        ACTION_DISLIKE -> command("dislike")
                    }
                }
            })
            setSessionActivity(openApp())
            isActive = true
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PLAY -> command("play")
            ACTION_PAUSE -> command("pause")
            ACTION_NEXT -> command("next")
            ACTION_PREVIOUS -> command("previous")
            ACTION_LIKE -> command("like")
            ACTION_DISLIKE -> command("dislike")
            ACTION_DISMISS -> {
                if (track?.playing != true) stopSelf()
                return START_NOT_STICKY
            }
        }
        if (track == null) {
            promote(placeholder())
            stopSelf()
            return START_NOT_STICKY
        }
        render(promote = intent?.action == null)
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (track?.playing != true) stopSelf()
    }

    override fun onDestroy() {
        instance = null
        abandonFocus()
        setNoisy(false)
        session.isActive = false
        session.release()
        loader.shutdownNow()
        stopForeground(STOP_FOREGROUND_REMOVE)
        manager().cancel(ID)
        foreground = false
        super.onDestroy()
    }

    fun render(promote: Boolean = false) {
        val t = track ?: return
        val active = t.playing || t.buffering
        if (t.playing) requestFocus() else if (!resumeOnGain) abandonFocus()
        setNoisy(t.playing)
        loadCover(t.art)
        val old = metadataFor
        if (old == null || old.id != t.id || old.duration != t.duration || old.title != t.title) {
            metadataFor = t
            publishMetadata(t)
        }
        session.setPlaybackState(playbackState(t))
        val n = notification(t)
        if (active || promote) {
            if (!foreground) {
                foreground = promote(n)
                if (!foreground) manager().notify(ID, n)
            } else {
                manager().notify(ID, n)
            }
        }
        if (!active && foreground) {
            stopForeground(STOP_FOREGROUND_DETACH)
            foreground = false
        }
        if (!active) manager().notify(ID, n)
    }

    private fun promote(n: Notification): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(ID, n)
        }
        true
    } catch (e: RuntimeException) {
        false
    }

    private fun publishMetadata(t: Track) {
        val b = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_MEDIA_ID, t.id)
            .putString(MediaMetadata.METADATA_KEY_TITLE, t.title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, t.artist)
            .putString(MediaMetadata.METADATA_KEY_ALBUM, t.album)
            .putLong(MediaMetadata.METADATA_KEY_DURATION, t.duration)
        if (coverUrl == t.art) cover?.let { b.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it) }
        session.setMetadata(b.build())
    }

    private fun playbackState(t: Track): PlaybackState {
        val state = when {
            t.buffering -> PlaybackState.STATE_BUFFERING
            t.playing -> PlaybackState.STATE_PLAYING
            else -> PlaybackState.STATE_PAUSED
        }
        val speed = if (t.playing && !t.buffering) 1f else 0f
        return PlaybackState.Builder()
            .setActions(
                PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or
                    PlaybackState.ACTION_STOP or PlaybackState.ACTION_SEEK_TO or
                    PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS,
            )
            .setState(state, t.position, speed, SystemClock.elapsedRealtime())
            .addCustomAction(
                PlaybackState.CustomAction.Builder(
                    ACTION_DISLIKE,
                    if (t.disliked) "Убрать дизлайк" else "Не нравится",
                    if (t.disliked) R.drawable.ic_disliked else R.drawable.ic_dislike,
                ).build(),
            )
            .addCustomAction(
                PlaybackState.CustomAction.Builder(
                    ACTION_LIKE,
                    if (t.liked) "Убрать из любимых" else "Нравится",
                    if (t.liked) R.drawable.ic_liked else R.drawable.ic_like,
                ).build(),
            )
            .build()
    }

    private fun loadCover(url: String) {
        if (url == coverUrl) return
        coverUrl = url
        cover = null
        if (url.isEmpty()) return
        loader.execute {
            val bitmap = runCatching {
                val conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = 10_000
                conn.readTimeout = 10_000
                try {
                    conn.inputStream.use { BitmapFactory.decodeStream(it) }
                } finally {
                    conn.disconnect()
                }
            }.getOrNull() ?: return@execute
            main.post {
                if (instance !== this || coverUrl != url) return@post
                cover = bitmap
                track?.let {
                    publishMetadata(it)
                    manager().notify(ID, notification(it))
                }
            }
        }
    }

    private fun requestFocus() {
        if (focused) return
        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = focusRequest ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setOnAudioFocusChangeListener(focusListener, main)
                .build()
                .also { focusRequest = it }
            audio.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audio.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        }
        focused = granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonFocus() {
        if (!focused) return
        focused = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audio.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            audio.abandonAudioFocus(focusListener)
        }
    }

    private fun setNoisy(on: Boolean) {
        if (on == noisyRegistered) return
        noisyRegistered = on
        if (on) {
            registerReceiver(noisy, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        } else {
            unregisterReceiver(noisy)
        }
    }

    private fun manager() = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun openApp(): PendingIntent = PendingIntent.getActivity(
        this,
        0,
        Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun action(name: String, code: Int): PendingIntent = PendingIntent.getService(
        this,
        code,
        Intent(this, PlaybackService::class.java).setAction(name),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun button(icon: Int, title: String, name: String, code: Int) =
        Notification.Action.Builder(Icon.createWithResource(this, icon), title, action(name, code)).build()

    private fun builder(): Notification.Builder {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager().createNotificationChannel(
                NotificationChannel(CHANNEL, "Плеер", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    setShowBadge(false)
                    setSound(null, null)
                    enableVibration(false)
                    enableLights(false)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                },
            )
            return Notification.Builder(this, CHANNEL)
        }
        @Suppress("DEPRECATION")
        return Notification.Builder(this)
    }

    private fun placeholder(): Notification = builder()
        .setSmallIcon(android.R.drawable.ic_media_play)
        .setContentTitle("YAMP")
        .build()

    private fun notification(t: Track): Notification {
        val toggle = if (t.playing) {
            button(android.R.drawable.ic_media_pause, "Пауза", ACTION_PAUSE, 2)
        } else {
            button(android.R.drawable.ic_media_play, "Играть", ACTION_PLAY, 1)
        }
        val like = if (t.liked) {
            button(R.drawable.ic_liked, "Убрать из любимых", ACTION_LIKE, 6)
        } else {
            button(R.drawable.ic_like, "Нравится", ACTION_LIKE, 6)
        }
        val dislike = if (t.disliked) {
            button(R.drawable.ic_disliked, "Убрать дизлайк", ACTION_DISLIKE, 7)
        } else {
            button(R.drawable.ic_dislike, "Не нравится", ACTION_DISLIKE, 7)
        }
        val b = builder()
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(t.title)
            .setContentText(t.artist)
            .setSubText(t.album)
            .setContentIntent(openApp())
            .setDeleteIntent(action(ACTION_DISMISS, 5))
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setOngoing(t.playing)
            .addAction(like)
            .addAction(button(android.R.drawable.ic_media_previous, "Предыдущий", ACTION_PREVIOUS, 3))
            .addAction(toggle)
            .addAction(button(android.R.drawable.ic_media_next, "Следующий", ACTION_NEXT, 4))
            .addAction(dislike)
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(session.sessionToken)
                    .setShowActionsInCompactView(1, 2, 3),
            )
        if (coverUrl == t.art) cover?.let { b.setLargeIcon(it) }
        return b.build()
    }
}
