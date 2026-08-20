package com.vortx.android.notifications

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.vortx.android.VortXApplication
import com.vortx.android.home.HttpUpcomingMetaFetcher
import com.vortx.android.home.UpcomingMetaResponse
import com.vortx.android.home.upcomingMetaBases
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.UserProfile
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId

/**
 * The periodic library sweep behind new-episode alerts. Reads the ACTIVE profile's library, finds each
 * series' soonest not-yet-aired episode within the [NewEpisodeNotifications.HORIZON_DAYS] window from the
 * installed meta add-ons (reusing the SAME `HttpUpcomingMetaFetcher` + `upcomingMetaBases` the Home release
 * calendar uses), and hands the results to [NewEpisodeNotifications.applySchedules] to arm one delayed
 * notification per series.
 *
 * PER-PROFILE BOUNDARY (mirrors `ReleaseCalendarOwner`): the active profile id is captured at the start and
 * re-checked before publishing. If the user switched profiles while the add-on fetches were in flight, the
 * results are discarded and NOTHING is scheduled -- a sweep that outlives a switch must never schedule the
 * previous profile's shows. The fire-time guard in [NewEpisodeNotifyWorker] is the second line of defence.
 */
class NewEpisodeSweepWorker(context: Context, params: WorkerParameters) :
    CoroutineWorker(context, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val context = applicationContext
        if (!NewEpisodeNotifications.isEnabled(context)) {
            // The user disabled alerts (or another surface did) since this work was enqueued: clear any
            // pending per-series alerts and stop, rather than posting stale notifications.
            WorkManager.getInstance(context).cancelAllWorkByTag(NewEpisodeNotifications.NOTIFY_TAG)
            return@withContext Result.success()
        }

        val app = context as? VortXApplication ?: return@withContext Result.success()
        // Capture the owner BEFORE any repository read begins (the ReleaseCalendarOwner discipline).
        val ownerProfileId = ProfileStore.sharedOrNull()?.activeProfileId ?: UserProfile.OWNER_ID
        val repo = app.catalogRepository

        val library = repo.library().getOrElse {
            // A transient engine/read failure: let WorkManager retry rather than wiping the schedule.
            return@withContext Result.retry()
        }.items
        val addons = repo.installedAddons().getOrElse { emptyList() }
        val bases = upcomingMetaBases(addons)
        if (bases.isEmpty()) return@withContext Result.success()

        val now = Instant.now()
        val horizon = now.plusSeconds(NewEpisodeNotifications.HORIZON_DAYS * SECONDS_PER_DAY)
        val series = library.asSequence()
            .filter { it.type == MediaType.SERIES && (it.id.startsWith("tt") || it.id.startsWith("tmdb:")) }
            .distinctBy { it.id }
            .take(NewEpisodeNotifications.MAX_SERIES)
            .toList()

        val alerts = coroutineScope {
            val slots = Semaphore(NewEpisodeNotifications.MAX_CONCURRENT_FETCHES)
            series
                .map { seed -> async { slots.withPermit { nextEpisodeAlert(seed, bases, now, horizon) } } }
                .awaitAll()
        }.filterNotNull()

        // BOUNDARY re-check: refuse to publish another profile's shows if the active profile changed while
        // the fetches were running. Exactly the `activeOwner != owner` guard ReleaseCalendarModel applies.
        val currentOwner = ProfileStore.sharedOrNull()?.activeProfileId ?: UserProfile.OWNER_ID
        if (currentOwner != ownerProfileId) return@withContext Result.success()

        NewEpisodeNotifications.applySchedules(context, ownerProfileId, alerts)
        Result.success()
    }

    /** One series' soonest upcoming episode, or null when it has nothing within the horizon / no meta. */
    private suspend fun nextEpisodeAlert(
        seed: MetaItem,
        bases: List<String>,
        now: Instant,
        horizon: Instant,
    ): UpcomingEpisodeAlert? {
        val meta = firstMeta(seed.id, bases) ?: return null
        val videos = meta.optJSONArray("videos") ?: return null
        var best: JSONObject? = null
        var bestDate: Instant? = null
        for (index in 0 until videos.length()) {
            val video = videos.optJSONObject(index) ?: continue
            val date = releaseInstant(video.optStringOrNull("released")) ?: continue
            if (date <= now || date >= horizon || (bestDate != null && date >= bestDate)) continue
            best = video
            bestDate = date
        }
        val video = best ?: return null
        val airDate = bestDate ?: return null
        val episode = video.optIntOrNull("episode")
        val season = video.optIntOrNull("season")
        val episodeLabel = when {
            episode == null -> video.optStringOrNull("title") ?: "New episode"
            season != null -> "S${season}E$episode"
            else -> "E$episode"
        }
        val name = meta.optStringOrNull("name")?.ifBlank { null } ?: seed.name
        return UpcomingEpisodeAlert(
            seriesId = seed.id,
            seriesName = name,
            episodeLabel = "New episode is out: $episodeLabel",
            airEpochMillis = airDate.toEpochMilli(),
        )
    }

    /** First add-on that answers with a `meta` object, mirroring ReleaseCalendarModel.firstMeta. */
    private suspend fun firstMeta(id: String, bases: List<String>): JSONObject? {
        for (base in bases) {
            val response = try {
                HttpUpcomingMetaFetcher.fetch(base, MediaType.SERIES, id)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                continue
            }
            if (response is UpcomingMetaResponse.Success) {
                val meta = response.payload?.optJSONObject("meta")
                if (meta != null) return meta
            }
        }
        return null
    }

    private fun releaseInstant(raw: String?): Instant? {
        val value = raw?.trim().takeUnless { it.isNullOrEmpty() } ?: return null
        return runCatching { OffsetDateTime.parse(value).toInstant() }
            .recoverCatching { Instant.parse(value) }
            .recoverCatching {
                require(value.length >= 10)
                LocalDate.parse(value.take(10)).atStartOfDay(ZoneId.systemDefault()).toInstant()
            }
            .getOrNull()
    }

    private fun JSONObject.optStringOrNull(key: String): String? {
        if (!has(key) || isNull(key)) return null
        return optString(key).ifBlank { null }
    }

    private fun JSONObject.optIntOrNull(key: String): Int? {
        if (!has(key) || isNull(key)) return null
        return optInt(key)
    }

    private companion object {
        const val SECONDS_PER_DAY = 86_400L
    }
}
