package com.vortx.android.notifications

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.UserProfile

/**
 * Posts one series' "new episode is out" notification when its scheduled air time arrives. Enqueued with an
 * initial delay by [NewEpisodeNotifications.applySchedules]; WorkManager fires it approximately at air time
 * and survives process death and reboot.
 *
 * FIRE-TIME PER-PROFILE GUARD: this can run days after it was scheduled, across any number of profile
 * switches. It re-reads the current active profile and posts only when it still matches the profile that
 * scheduled it, so a profile-A alert can never surface while profile B is active -- the second line of the
 * per-profile boundary the sweep opens. It also honours a since-flipped enable toggle: a disabled state
 * suppresses the post.
 */
class NewEpisodeNotifyWorker(context: Context, params: WorkerParameters) :
    CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val context = applicationContext
        if (!NewEpisodeNotifications.isEnabled(context)) return Result.success()

        val ownerProfileId = inputData.getString(NewEpisodeNotifications.KEY_OWNER_PROFILE)
            ?: return Result.success()
        val currentProfileId = ProfileStore.sharedOrNull()?.activeProfileId ?: UserProfile.OWNER_ID
        // The boundary: never post one profile's alert while a different profile is active.
        if (currentProfileId != ownerProfileId) return Result.success()

        val seriesId = inputData.getString(NewEpisodeNotifications.KEY_SERIES_ID) ?: return Result.success()
        val seriesName = inputData.getString(NewEpisodeNotifications.KEY_SERIES_NAME).orEmpty()
        val episodeLabel = inputData.getString(NewEpisodeNotifications.KEY_EPISODE_LABEL).orEmpty()
        NewEpisodeNotifications.postEpisodeAlert(context, seriesId, seriesName, episodeLabel)
        return Result.success()
    }
}
