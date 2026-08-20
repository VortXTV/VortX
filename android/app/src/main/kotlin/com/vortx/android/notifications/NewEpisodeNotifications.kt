package com.vortx.android.notifications

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.workDataOf
import com.vortx.android.MainActivity
import com.vortx.android.R
import com.vortx.android.profile.ProfileStore
import java.util.concurrent.TimeUnit

/**
 * New-episode alerts (Apple F5, `NewEpisodeNotifications` in iOSSettingsView.swift). A followed series pings
 * the moment its next episode drops, with no server push: a periodic WorkManager sweep over the ACTIVE
 * profile's library finds each series' soonest upcoming episode and schedules one local notification per
 * series at its air time.
 *
 * WHY a sweep + a per-series delayed worker rather than Apple's single `UNCalendarNotificationTrigger`:
 * Android has no OS primitive for "post this notification at a wall-clock time" that survives process death
 * without an exact-alarm permission. WorkManager's initial-delay does survive process death and reboot (it
 * reschedules its own jobs), needs no `SCHEDULE_EXACT_ALARM`, and an approximate delivery is the right
 * fidelity for "a new episode is out". The sweep re-runs on a 12h cadence and at launch, so a dropped alarm
 * (reboot) is re-armed and the library stays in step, exactly as Apple re-schedules keyed by series id.
 *
 * SAME KEY as every other platform: the on/off flag lives on Apple's exact `stremiox.notifyNewEpisodes`
 * UserDefaults key in the shared [ProfileStore.PREFS_FILE], default ON (an unset key reads enabled), so it
 * rides the settings backup and means the same thing on iOS/tvOS/Mac/Android/web.
 *
 * PER-PROFILE BOUNDARY (the invariant, mirroring `ReleaseCalendarOwner`): the sweep captures the active
 * profile id when it starts and re-checks it has not changed before it publishes any schedule, so a sweep
 * that outlives a profile switch never schedules another profile's shows. Each scheduled notification also
 * carries its owning profile id and re-checks the current active profile at FIRE time, so even a schedule
 * that slipped through a switch can never POST for the wrong profile.
 */
object NewEpisodeNotifications {

    /** Apple's exact key, shared across every platform (the same-key mandate). Default ON when unset. */
    const val ENABLED_KEY = "stremiox.notifyNewEpisodes"

    /** Apple's 45-day horizon: only the soonest not-yet-aired episode within this window is scheduled. */
    const val HORIZON_DAYS = 45L

    internal const val MAX_SERIES = 60
    internal const val MAX_CONCURRENT_FETCHES = 6

    private const val CHANNEL_ID = "vortx.newepisodes"
    private const val SWEEP_INTERVAL_HOURS = 12L

    /** Unique-work names + tags. The tag lets the whole set be cancelled on disable or re-published cleanly. */
    internal const val SWEEP_PERIODIC_NAME = "vortx.newepisode.sweep.periodic"
    internal const val SWEEP_ONESHOT_NAME = "vortx.newepisode.sweep.now"
    internal const val NOTIFY_TAG = "vortx.newepisode.notify"
    internal const val NOTIFY_OWNER_TAG_PREFIX = "vortx.newepisode.owner:"
    internal fun notifyWorkName(seriesId: String): String = "vortx.newepisode.nextep:$seriesId"

    internal const val KEY_SERIES_ID = "seriesId"
    internal const val KEY_SERIES_NAME = "seriesName"
    internal const val KEY_EPISODE_LABEL = "episodeLabel"
    internal const val KEY_OWNER_PROFILE = "ownerProfileId"

    /**
     * On by default: an unset key reads as enabled, so a followed show pings out of the box and the first
     * enable asks for the notification permission in context. Once the user flips the toggle, the stored
     * value wins. Read the exact Apple semantics from [ENABLED_KEY].
     */
    fun isEnabled(context: Context): Boolean {
        val prefs = prefs(context)
        return if (!prefs.contains(ENABLED_KEY)) true else prefs.getBoolean(ENABLED_KEY, true)
    }

    /**
     * Turn alerts on or off. Enabling (re)arms the periodic + an immediate sweep; disabling clears both and
     * every pending per-series alert. Persists under the shared Apple key. The runtime POST_NOTIFICATIONS
     * request is the caller's (a Composable owns the permission launcher); a denial does not un-persist the
     * intent -- the sweep still runs, the alert just is not shown, exactly like the downloads notification.
     */
    fun setEnabled(context: Context, on: Boolean) {
        prefs(context).edit().putBoolean(ENABLED_KEY, on).apply()
        if (on) scheduleSweep(context) else cancelAll(context)
    }

    /** Called at process start (VortXApplication.onCreate) so the sweep is armed even with no UI opened. */
    fun scheduleSweepIfEnabled(context: Context) {
        if (isEnabled(context)) scheduleSweep(context)
    }

    private fun scheduleSweep(context: Context) {
        val wm = WorkManager.getInstance(context.applicationContext)
        // A meta fetch needs the network; the notify worker that POSTS the alert deliberately has NO
        // constraint so it fires at air time even offline.
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()
        val periodic = PeriodicWorkRequestBuilder<NewEpisodeSweepWorker>(
            SWEEP_INTERVAL_HOURS, TimeUnit.HOURS,
        ).setConstraints(constraints).build()
        // KEEP: a relaunch must not reset the cadence; the one-shot below refreshes promptly on every launch.
        wm.enqueueUniquePeriodicWork(SWEEP_PERIODIC_NAME, ExistingPeriodicWorkPolicy.KEEP, periodic)
        val immediate = OneTimeWorkRequestBuilder<NewEpisodeSweepWorker>()
            .setConstraints(constraints)
            .build()
        wm.enqueueUniqueWork(SWEEP_ONESHOT_NAME, ExistingWorkPolicy.REPLACE, immediate)
    }

    private fun cancelAll(context: Context) {
        val wm = WorkManager.getInstance(context.applicationContext)
        wm.cancelUniqueWork(SWEEP_PERIODIC_NAME)
        wm.cancelUniqueWork(SWEEP_ONESHOT_NAME)
        wm.cancelAllWorkByTag(NOTIFY_TAG)
    }

    /**
     * (Re)publish the per-series alerts after the sweep's boundary check has passed. Cancels every prior
     * pending alert first (so a series dropped from the library, or one with nothing upcoming, clears), then
     * schedules exactly one delayed [NewEpisodeNotifyWorker] per series that has an upcoming episode. Each is
     * keyed by series id (unique work, REPLACE) so re-sweeping replaces rather than duplicates, and tagged
     * with its owning profile so a switch can cancel the outgoing set.
     */
    internal fun applySchedules(
        context: Context,
        ownerProfileId: String,
        alerts: List<UpcomingEpisodeAlert>,
    ) {
        val wm = WorkManager.getInstance(context.applicationContext)
        // Cancel-then-enqueue is WorkManager's documented replace-the-whole-set pattern: the cancel captures
        // the existing work ids before the fresh enqueues below, so the new requests are never swept up by it.
        wm.cancelAllWorkByTag(NOTIFY_TAG)
        val now = System.currentTimeMillis()
        for (alert in alerts) {
            val delay = alert.airEpochMillis - now
            if (delay <= 0L) continue
            val request = OneTimeWorkRequestBuilder<NewEpisodeNotifyWorker>()
                .setInitialDelay(delay, TimeUnit.MILLISECONDS)
                .setInputData(
                    workDataOf(
                        KEY_SERIES_ID to alert.seriesId,
                        KEY_SERIES_NAME to alert.seriesName,
                        KEY_EPISODE_LABEL to alert.episodeLabel,
                        KEY_OWNER_PROFILE to ownerProfileId,
                    ),
                )
                .addTag(NOTIFY_TAG)
                .addTag(NOTIFY_OWNER_TAG_PREFIX + ownerProfileId)
                .build()
            wm.enqueueUniqueWork(notifyWorkName(alert.seriesId), ExistingWorkPolicy.REPLACE, request)
        }
    }

    /** Create the channel. Idempotent; required on API 26+, which is our minSdk, so it always runs. */
    private fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.new_episode_channel_name),
            // DEFAULT: a followed show's new episode is worth a heads-up glance, unlike the LOW ambient
            // download-progress channel.
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = context.getString(R.string.new_episode_channel_description)
            setShowBadge(true)
        }
        manager.createNotificationChannel(channel)
    }

    /**
     * Post the actual "new episode is out" notification. Called only from [NewEpisodeNotifyWorker] AFTER its
     * enabled + owning-profile checks pass. No-ops when the runtime POST_NOTIFICATIONS permission is missing
     * (API 33+), matching the downloads rule: the feature never crashes on a denied permission, the alert is
     * simply not shown.
     */
    internal fun postEpisodeAlert(
        context: Context,
        seriesId: String,
        seriesName: String,
        episodeLabel: String,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ensureChannel(context)
        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(seriesName)
            .setContentText(episodeLabel)
            .setSmallIcon(android.R.drawable.stat_notify_more)
            .setAutoCancel(true)
            .setContentIntent(open)
            .setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
            .build()
        NotificationManagerCompat.from(context).notify(notificationId(seriesId), notification)
    }

    /** Stable per-series notification id, kept clear of the downloads id space (0x0D...). */
    private fun notificationId(seriesId: String): Int = 0x0E_00_00_00 + (seriesId.hashCode() and 0x00FF_FFFF)

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE)
}

/** One series' next-episode alert to schedule: the copy plus the wall-clock air time in epoch millis. */
internal data class UpcomingEpisodeAlert(
    val seriesId: String,
    val seriesName: String,
    val episodeLabel: String,
    val airEpochMillis: Long,
)
