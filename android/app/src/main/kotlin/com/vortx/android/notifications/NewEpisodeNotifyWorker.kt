package com.vortx.android.notifications

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.vortx.android.VortXApplication
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** Deliver a scheduled alert offline once the original account and profile are mounted. */
class NewEpisodeNotifyWorker(context: Context, params: WorkerParameters) :
    CoroutineWorker(context, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val context = applicationContext
        if (!NewEpisodeNotifications.isEnabled(context)) return@withContext Result.success()

        // A pre-upgrade job has only a profile ID, which can be shared by multiple accounts.
        val expected = EpisodeNotificationOwner.parse(
            inputData.getString(NewEpisodeNotifications.KEY_OWNER_SCOPE),
            inputData.getString(NewEpisodeNotifications.KEY_OWNER_PROFILE),
        ) ?: return@withContext Result.success()
        val seriesId = inputData.getString(NewEpisodeNotifications.KEY_SERIES_ID) ?: return@withContext Result.success()
        val airEpochMillis = inputData.getLong(NewEpisodeNotifications.KEY_AIR_EPOCH_MILLIS, 0L)
        val notificationTag = expected.notificationTag(seriesId, airEpochMillis) ?: return@withContext Result.success()
        if (expected.eventKey(seriesId, airEpochMillis) !in tags) return@withContext Result.success()
        val seriesName = inputData.getString(NewEpisodeNotifications.KEY_SERIES_NAME).orEmpty()
        val episodeLabel = inputData.getString(NewEpisodeNotifications.KEY_EPISODE_LABEL).orEmpty()
        val app = context as? VortXApplication ?: return@withContext Result.success()
        val captured = when (val owner = captureEpisodeNotificationOwner(app)) {
            is EpisodeNotificationOwnerObservation.Mounted -> owner
            EpisodeNotificationOwnerObservation.Unavailable -> return@withContext Result.retry()
            EpisodeNotificationOwnerObservation.SignedOut -> return@withContext Result.success()
        }
        if (expected != captured.owner) return@withContext Result.success()

        val operation = this.coroutineContext
        val posted = NewEpisodeNotifications.postEpisodeAlert(
            context, seriesId, seriesName, episodeLabel, notificationTag,
        ) { post ->
            captured.publishIfCurrent {
                operation.ensureActive()
                if (NewEpisodeNotifications.isEnabled(context)) post()
            }
        }
        if (posted) Result.success() else Result.retry()
    }
}
