// android/app/src/main/kotlin/com/example/hotspot_watchdog/CampusForegroundService.kt
package com.example.hotspot_watchdog

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

/**
 * Foreground service that keeps the process alive while the watchdog runs.
 *
 * Android 5.1.1 differences handled here:
 *  - no notification channels before Android 8  -> channel only created on O+
 *  - startForeground(id, n, type) only exists on Android 10+ -> 2-arg form below
 *  - PendingIntent.FLAG_IMMUTABLE only exists on Android 6+  -> added conditionally
 */
class CampusForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
            stopSelf()
        }
        // If the process is killed the Dart watchdog is gone too, so there is
        // nothing useful for a restarted service to do.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        @Suppress("DEPRECATION")
        stopForeground(true) // boolean form works on every API level
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val builder: Notification.Builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ensureChannel()
                Notification.Builder(this, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
            }

        builder
            .setContentTitle("Campus Hustler")
            .setContentText("Keeping you connected")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)

        val launch = packageManager.getLaunchIntentForPackage(packageName)
        if (launch != null) {
            var piFlags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                piFlags = piFlags or PendingIntent.FLAG_IMMUTABLE
            }
            builder.setContentIntent(PendingIntent.getActivity(this, 0, launch, piFlags))
        }
        return builder.build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "Campus Hustler",
                        NotificationManager.IMPORTANCE_LOW
                    )
                )
            }
        }
    }

    companion object {
        private const val CHANNEL_ID = "campus_hustler_service"
        private const val NOTIFICATION_ID = 4711
    }
}