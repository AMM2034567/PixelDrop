package com.antigravity.pixeldrop

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

class PixelDropService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    companion object {
        const val CHANNEL_ID = "pixeldrop_foreground_channel"
        const val NOTIFICATION_ID = 999
        const val ACTION_START = "ACTION_START"
        const val ACTION_UPDATE = "ACTION_UPDATE"
        const val ACTION_STOP = "ACTION_STOP"
        const val EXTRA_TITLE = "EXTRA_TITLE"
        const val EXTRA_CONTENT = "EXTRA_CONTENT"
        const val EXTRA_PROGRESS = "EXTRA_PROGRESS"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "PixelDrop::ProcessingWakeLock")
            wakeLock?.acquire(2 * 60 * 60 * 1000L) // 2 hours max safety
        } catch (_: Exception) {}
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "PixelDrop 正在运行"
                val content = intent.getStringExtra(EXTRA_CONTENT) ?: "正在处理任务..."
                val progress = intent.getIntExtra(EXTRA_PROGRESS, 0)
                startForeground(NOTIFICATION_ID, buildNotification(title, content, progress))
            }
            ACTION_UPDATE -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "PixelDrop 正在运行"
                val content = intent.getStringExtra(EXTRA_CONTENT) ?: "正在处理任务..."
                val progress = intent.getIntExtra(EXTRA_PROGRESS, 0)
                val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.notify(NOTIFICATION_ID, buildNotification(title, content, progress))
            }
            ACTION_STOP -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    stopForeground(true)
                }
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun buildNotification(title: String, content: String, progress: Int): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, launchIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(content)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)

        if (progress in 0..100) {
            builder.setProgress(100, progress, false)
        } else {
            builder.setProgress(0, 0, true)
        }

        return builder.build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "PixelDrop 任务保活与进度",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "确保切后台或锁屏时编解码任务不被系统杀死"
                setShowBadge(false)
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    override fun onDestroy() {
        try {
            wakeLock?.let {
                if (it.isHeld) {
                    it.release()
                }
            }
        } catch (_: Exception) {}
        super.onDestroy()
    }
}
