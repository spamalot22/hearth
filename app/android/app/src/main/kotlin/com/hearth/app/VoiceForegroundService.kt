package com.hearth.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/** Keeps an active WebRTC microphone session eligible to run while the screen is locked. */
class VoiceForegroundService : Service() {
    companion object {
        private const val CHANNEL_ID = "hearth_voice"
        private const val NOTIFICATION_ID = 2101
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Voice calls",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shown while Hearth is using the microphone for voice chat"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    @Suppress("DEPRECATION")
    private fun buildNotification(): Notification {
        val openHearth = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            openHearth,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Hearth voice")
            .setContentText("Voice channel active")
            .setContentIntent(pendingIntent)
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }
}
