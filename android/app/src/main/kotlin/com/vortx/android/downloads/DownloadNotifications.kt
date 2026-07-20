package com.vortx.android.downloads

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import com.vortx.android.MainActivity
import com.vortx.android.R

/**
 * The foreground-service notification a running [DownloadWorker] posts.
 *
 * Apple needs no such thing: `URLSession`'s background transfers are OS-owned and invisible. Android requires a
 * long-running transfer to be a FOREGROUND SERVICE with a user-visible notification, so this is Android-native
 * scaffolding rather than a port of anything in the Swift.
 */
internal object DownloadNotifications {

    private const val CHANNEL_ID = "vortx.downloads"

    /**
     * Stable per-record notification id. WorkManager's `SystemForegroundService` keys its foreground notification by
     * this id, so two concurrent downloads (the default cap is 2) MUST NOT collide or the second would replace the
     * first's notification and the service would track only one. `hashCode` of a UUID string is well-distributed;
     * `absoluteValue` keeps it positive, and the offset keeps it clear of any other notification id in the app.
     */
    fun notificationId(recordId: String): Int = 0x0D_00_00_00 + (recordId.hashCode() and 0x00FF_FFFF)

    /** Create the channel. Idempotent; required on API 26+, which is our minSdk, so it always runs. */
    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.downloads_channel_name),
            // LOW: a download is ambient progress, not something to interrupt the user with. No sound, no heads-up.
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = context.getString(R.string.downloads_channel_description)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    /**
     * The progress notification for one in-flight download. [fraction] < 0 renders an INDETERMINATE bar, which is the
     * honest rendering when the server declared no Content-Length (every torrent loopback transfer, and any debrid
     * link that streams without a length) -- a 0% determinate bar would imply we know the size and are stuck at zero.
     */
    fun progress(context: Context, title: String, fraction: Double): android.app.Notification {
        ensureChannel(context)
        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(context.getString(R.string.downloads_notification_title))
            .setContentText(title)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        if (fraction < 0) {
            builder.setProgress(0, 0, true)
        } else {
            builder.setProgress(100, (fraction * 100).toInt().coerceIn(0, 100), false)
        }
        return builder.build()
    }
}
