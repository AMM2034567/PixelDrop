package com.antigravity.pixeldrop

import android.content.Intent
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val WAKELOCK_CHANNEL = "com.antigravity.pixeldrop/wakelock"
    private val SERVICE_CHANNEL = "com.antigravity.pixeldrop/service"

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
    }
}
