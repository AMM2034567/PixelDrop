package io.github.amm2034567.pixeldrop

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity: FlutterActivity() {
    private val WAKELOCK_CHANNEL = "io.github.amm2034567.pixeldrop/wakelock"
    private val SERVICE_CHANNEL = "io.github.amm2034567.pixeldrop/service"
    private val SHARING_CHANNEL = "io.github.amm2034567.pixeldrop/sharing"

    private var initialSharedFiles: List<String>? = null
    private var sharingChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val files = handleShareIntent(intent)
        if (!files.isNullOrEmpty()) {
            sharingChannel?.invokeMethod("onSharedFiles", files)
            if (sharingChannel != null) {
                initialSharedFiles = null
            }
        }
    }

    private fun handleShareIntent(intent: Intent?): List<String>? {
        if (intent == null) return null
        val action = intent.action ?: return null
        val files = mutableListOf<String>()

        if (Intent.ACTION_SEND == action) {
            val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            } ?: intent.data

            if (uri != null) {
                resolveUriToPath(uri)?.let { files.add(it) }
            }
        } else if (Intent.ACTION_SEND_MULTIPLE == action) {
            val uris = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            }

            if (uris != null) {
                for (u in uris) {
                    resolveUriToPath(u)?.let { files.add(it) }
                }
            }
        }

        if (files.isEmpty() && intent.clipData != null) {
            val clipData = intent.clipData!!
            for (i in 0 until clipData.itemCount) {
                val itemUri = clipData.getItemAt(i).uri
                if (itemUri != null) {
                    resolveUriToPath(itemUri)?.let { files.add(it) }
                }
            }
        }

        if (files.isNotEmpty()) {
            initialSharedFiles = files
            return files
        }
        return null
    }

    private fun resolveUriToPath(uri: Uri): String? {
        if (uri.scheme == "file") {
            return uri.path
        }
        if (uri.scheme == "content") {
            try {
                var fileName = "shared_${System.currentTimeMillis()}"
                contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex != -1 && cursor.moveToFirst()) {
                        val name = cursor.getString(nameIndex)
                        if (!name.isNullOrBlank()) {
                            fileName = name
                        }
                    }
                }

                // If displayName lacks an extension, resolve extension via MIME type
                if (!fileName.contains(".")) {
                    val mimeType = contentResolver.getType(uri)
                    if (!mimeType.isNullOrBlank()) {
                        val ext = android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType)
                        if (!ext.isNullOrBlank()) {
                            fileName = "$fileName.$ext"
                        }
                    }
                }

                val cacheSubdir = File(cacheDir, "shared_inbox")
                if (!cacheSubdir.exists()) {
                    cacheSubdir.mkdirs()
                }

                // Protect against collision in cache directory
                var destFile = File(cacheSubdir, fileName)
                if (destFile.exists()) {
                    val base = fileName.substringBeforeLast('.', fileName)
                    val ext = if (fileName.contains('.')) ".${fileName.substringAfterLast('.')}" else ""
                    destFile = File(cacheSubdir, "${base}_${System.currentTimeMillis()}$ext")
                }

                val input = contentResolver.openInputStream(uri) ?: return null
                input.use { inStream ->
                    destFile.outputStream().use { output ->
                        inStream.copyTo(output)
                    }
                }
                return destFile.absolutePath
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
        return uri.path
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 1. Screen Keep-On Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WAKELOCK_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "enable" -> {
                    runOnUiThread {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(true)
                }
                "disable" -> {
                    runOnUiThread {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 2. Android Native Foreground Service Channel (True background keep-alive)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SERVICE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    val title = call.argument<String>("title") ?: "PixelDrop 正在运行"
                    val content = call.argument<String>("content") ?: "正在处理任务..."
                    val progress = call.argument<Int>("progress") ?: 0

                    runOnUiThread {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }

                    val intent = Intent(this, PixelDropService::class.java).apply {
                        action = PixelDropService.ACTION_START
                        putExtra(PixelDropService.EXTRA_TITLE, title)
                        putExtra(PixelDropService.EXTRA_CONTENT, content)
                        putExtra(PixelDropService.EXTRA_PROGRESS, progress)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }
                "updateProgress" -> {
                    val title = call.argument<String>("title") ?: "PixelDrop 正在运行"
                    val content = call.argument<String>("content") ?: "正在处理任务..."
                    val progress = call.argument<Int>("progress") ?: 0

                    val intent = Intent(this, PixelDropService::class.java).apply {
                        action = PixelDropService.ACTION_UPDATE
                        putExtra(PixelDropService.EXTRA_TITLE, title)
                        putExtra(PixelDropService.EXTRA_CONTENT, content)
                        putExtra(PixelDropService.EXTRA_PROGRESS, progress)
                    }
                    startService(intent)
                    result.success(true)
                }
                "stopService" -> {
                    runOnUiThread {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }

                    val intent = Intent(this, PixelDropService::class.java).apply {
                        action = PixelDropService.ACTION_STOP
                    }
                    startService(intent)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 3. Android Native Sharing Channel (ACTION_SEND & ACTION_SEND_MULTIPLE)
        sharingChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARING_CHANNEL)
        sharingChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialSharedFiles" -> {
                    val files = initialSharedFiles
                    initialSharedFiles = null
                    result.success(files)
                }
                else -> result.notImplemented()
            }
        }
    }
}
