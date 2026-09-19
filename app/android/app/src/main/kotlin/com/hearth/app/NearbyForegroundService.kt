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

/** No microphone or location collection. Only user-enabled nearby messaging. */
class NearbyForegroundService : Service() {
    companion object {
        const val STOP = "com.hearth.app.STOP_NEARBY"
        var onStop: (() -> Unit)? = null
        private const val CHANNEL = "hearth_nearby"
        private const val ID = 2102
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) {
            onStop?.invoke()
            stopSelf()
            return START_NOT_STICKY
        }
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(
                CHANNEL, "Nearby messaging", NotificationManager.IMPORTANCE_LOW,
            ).apply { setShowBadge(false) })
        }
        val open = PendingIntent.getActivity(this, ID,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, ID,
            Intent(this, NearbyForegroundService::class.java).setAction(STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL)
            else Notification.Builder(this)
        @Suppress("DEPRECATION")
        val notification = builder.setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Hearth nearby messaging")
            .setContentText("Nearby messaging / proximity scanner active")
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stop).build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(ID, notification)
        }
        // Do not restart without the Flutter engine and its encrypted queue.
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        onStop?.invoke()
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
