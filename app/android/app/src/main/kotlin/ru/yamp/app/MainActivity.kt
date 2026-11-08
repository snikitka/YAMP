package ru.yamp.app

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var pendingPick: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        return cache.get(ENGINE) ?: FlutterEngine(context.applicationContext).also { cache.put(ENGINE, it) }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        CoreBridge.start(this)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "yamp/core").setMethodCallHandler { call, result ->
            when (call.method) {
                "send" -> {
                    CoreBridge.send(call.arguments as String)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        PlaybackService.attach(this, messenger)
        EventChannel(messenger, "yamp/core/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) = CoreBridge.attach(events)
            override fun onCancel(arguments: Any?) = CoreBridge.attach(null)
        })
        val android = MethodChannel(messenger, "yamp/android")
        NetworkWatch.attach(this, android)
        android.setMethodCallHandler { call, result ->
            when (call.method) {
                "metered" -> result.success(NetworkWatch.current(this))
                "open" -> result.success(open(call.arguments as String))
                "openFolder" -> result.success(openFolder(call.arguments as String))
                "share" -> result.success(share(call.arguments as String))
                "pickFolder" -> pickFolder(call.arguments as String?, result)
                "storageGranted" -> result.success(storageGranted())
                "deviceName" -> result.success(RemoteNet.deviceName())
                "multicast" -> result.success(RemoteNet.multicast(this, call.arguments as Boolean))
                "requestStorage" -> {
                    requestStorage()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun open(target: String): Boolean = try {
        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(target)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (e: ActivityNotFoundException) {
        false
    }

    private fun share(text: String): Boolean = try {
        val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
        startActivity(Intent.createChooser(send, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (e: ActivityNotFoundException) {
        false
    }

    private fun documentId(path: String): String? {
        val primary = Environment.getExternalStorageDirectory().path
        return when {
            path == primary -> "primary:"
            path.startsWith("$primary/") -> "primary:" + path.removePrefix("$primary/")
            path.startsWith("/storage/") -> {
                val rest = path.removePrefix("/storage/")
                rest.substringBefore('/') + ":" + rest.substringAfter('/', "")
            }
            else -> null
        }
    }

    private fun documentUri(path: String): Uri? =
        documentId(path.trimEnd('/'))?.let { DocumentsContract.buildDocumentUri(EXTERNAL_DOCS, it) }

    private fun openFolder(path: String): Boolean {
        var dir = File(path)
        if (dir.isFile) dir = dir.parentFile ?: dir
        while (!dir.exists() && dir.parentFile != null) dir = dir.parentFile!!
        val attempts = mutableListOf<Intent>()
        documentUri(dir.path)?.let {
            attempts += Intent(Intent.ACTION_VIEW).setDataAndType(it, DocumentsContract.Document.MIME_TYPE_DIR)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        attempts += Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse(dir.path), "resource/folder")
        for (intent in attempts) {
            try {
                startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (e: ActivityNotFoundException) {
                continue
            } catch (e: SecurityException) {
                continue
            }
        }
        return false
    }

    private fun pickFolder(initial: String?, result: MethodChannel.Result) {
        pendingPick?.success(null)
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !initial.isNullOrEmpty()) {
            documentUri(initial)?.let { intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, it) }
        }
        try {
            startActivityForResult(intent, PICK_FOLDER)
        } catch (e: ActivityNotFoundException) {
            pendingPick = null
            result.error("unavailable", "На телефоне нет системного выбора папок", null)
        }
    }

    @Deprecated("FlutterActivity is not a ComponentActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_FOLDER) return
        val result = pendingPick ?: return
        pendingPick = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        val path = treePath(uri)
        if (path == null) {
            result.error("unsupported", "Эту папку нельзя выбрать. Выберите папку во внутренней памяти или на карте памяти", null)
        } else {
            result.success(path)
        }
    }

    private fun treePath(uri: Uri): String? {
        val id = try {
            DocumentsContract.getTreeDocumentId(uri)
        } catch (e: IllegalArgumentException) {
            return null
        }
        return when (uri.authority) {
            EXTERNAL_DOCS -> {
                val volume = id.substringBefore(':')
                val rel = id.substringAfter(':', "")
                val root = if (volume.equals("primary", ignoreCase = true)) {
                    Environment.getExternalStorageDirectory().path
                } else {
                    "/storage/$volume"
                }
                if (rel.isEmpty()) root else "$root/$rel"
            }
            DOWNLOAD_DOCS -> when {
                id.startsWith("raw:") -> id.removePrefix("raw:")
                id == "downloads" -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).path
                else -> null
            }
            else -> null
        }
    }

    private fun storageGranted(): Boolean = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        Environment.isExternalStorageManager()
    } else {
        checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestStorage() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val app = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName"))
            try {
                startActivity(app)
            } catch (e: ActivityNotFoundException) {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
        } else {
            requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), 2)
        }
    }

    companion object {
        private const val ENGINE = "main"
        private const val PICK_FOLDER = 41
        private const val EXTERNAL_DOCS = "com.android.externalstorage.documents"
        private const val DOWNLOAD_DOCS = "com.android.providers.downloads.documents"
    }
}
