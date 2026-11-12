package com.vortx.android.downloads

import android.content.Context
import com.vortx.android.VortXApplication
import com.vortx.android.engine.NativeCatalogRepository
import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.model.Playable
import com.vortx.android.model.PlaybackContext
import com.vortx.android.model.cwItemIsFinished
import com.vortx.android.player.PlaybackOwnerEpoch
import com.vortx.android.player.PlaybackOwnerToken
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.UserProfile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** Exact local download and revocable playback owner admitted before the first file or resume lookup. */
class DownloadedPlaybackAdmission internal constructor(
    internal val recordId: String,
    internal val ownerToken: PlaybackOwnerToken,
    internal val target: PlaybackContext,
    internal val policyWitness: DownloadedPolicyWitness?,
    internal val rollover: DownloadedRollover? = null,
)

internal fun interface DownloadedPolicyWitness {
    fun isCurrent(): Boolean
}

internal data class DownloadedPlaybackPolicy(
    val restricted: Boolean,
    val permitted: Set<PlaybackContext>,
    val witness: DownloadedPolicyWitness,
)

internal data class DownloadedTitleAvailability(
    val records: List<DownloadRecord> = emptyList(),
    val allowsMetadataFallback: Boolean = false,
)

private fun nativeDownloads(context: Context): NativeCatalogRepository? =
    (context.applicationContext as? VortXApplication)?.catalogRepository as? NativeCatalogRepository

internal suspend fun downloadedTitleAvailability(
    context: Context,
    candidates: List<DownloadRecord>,
    token: PlaybackOwnerToken,
): DownloadedTitleAvailability {
    if (candidates.isEmpty()) return DownloadedTitleAvailability()
    val owner = activeDownloadedPlaybackOwner()
    val local = withContext(Dispatchers.IO) {
        candidates.filter { DownloadStore.completedPlaybackFile(it) != null }
    }
    if (!PlaybackOwnerEpoch.isCurrent(token)) return DownloadedTitleAvailability()
    val native = nativeDownloads(context)
    val policy = if (native != null) {
        native.downloadedPlaybackPolicy(local.map { it.playbackContext(owner) }, token)
            ?: return DownloadedTitleAvailability()
    } else null
    if (!PlaybackOwnerEpoch.isCurrent(token) || policy?.witness?.isCurrent() == false) return DownloadedTitleAvailability()
    val permitted = local.filter { policy == null || it.playbackContext(owner) in policy.permitted }
    return DownloadedTitleAvailability(
        records = permitted.distinctBy { Triple(it.videoId, it.season, it.episode) }
            .sortedWith(compareBy({ it.season }, { it.episode }, { it.videoId })),
        allowsMetadataFallback = policy?.let { !it.restricted } ?: (ProfileStore.sharedOrNull()?.activeIsKids != true),
    )
}

private suspend fun readDownloadedAdmission(
    context: Context,
    target: PlaybackContext,
    recordId: String,
    token: PlaybackOwnerToken,
): DownloadedPlaybackAdmission? {
    if (!PlaybackOwnerEpoch.isCurrent(token)) return null
    val native = nativeDownloads(context)
    val witness = if (native != null) {
        val policy = native.downloadedPlaybackPolicy(listOf(target), token) ?: return null
        if (target !in policy.permitted) return null
        policy.witness
    } else null
    if (!PlaybackOwnerEpoch.isCurrent(token)) return null
    return DownloadedPlaybackAdmission(recordId, token, target, witness)
}

internal fun downloadedEpisode(records: List<DownloadRecord>, episode: Episode): DownloadRecord? =
    records.firstOrNull {
        it.type == "series" && it.videoId == episode.id && it.season == episode.season && it.episode == episode.episode
    }

/** The card supplies a title and, for series, its exact current video and coordinates. */
internal data class ContinueWatchingDownloadTarget(
    val contentId: String,
    val type: MediaType,
    val videoId: String,
    val season: Int? = null,
    val episode: Int? = null,
) {
    fun matches(record: DownloadRecord): Boolean =
        record.state == DownloadState.COMPLETED && record.contentId == contentId && record.type == type.id &&
            record.videoId == videoId && record.season == season && record.episode == episode
}

internal fun continueWatchingDownloadTarget(item: MetaItem): ContinueWatchingDownloadTarget? {
    if (item.id.isBlank() || item.continueWatchingUnavailableMessage != null) return null
    return when (item.type) {
        MediaType.MOVIE -> if (item.watched) null else ContinueWatchingDownloadTarget(item.id, item.type, item.id)
        MediaType.SERIES -> {
            val episode = item.preferredEpisode?.takeUnless { it.upNext } ?: return null
            val video = episode.videoIdentity?.takeIf { it.isNotBlank() } ?: return null
            if (episode.season < 0 || episode.episode <= 0) return null
            ContinueWatchingDownloadTarget(item.id, item.type, video, episode.season, episode.episode)
        }
        else -> null
    }
}

internal class DownloadedContinueWatchingRequest private constructor(
    val item: MetaItem,
    val detailGeneration: Long,
    private val target: ContinueWatchingDownloadTarget,
    private val owner: PlaybackContext.Owner,
    private val ownerToken: PlaybackOwnerToken,
    private val copy: Copy,
) {
    private sealed interface Copy {
        data object Absent : Copy
        data object Ambiguous : Copy
        data class Exact(val id: String) : Copy
    }

    fun isCurrent(): Boolean = PlaybackOwnerEpoch.isCurrent(ownerToken) &&
        activeDownloadedPlaybackOwner() == owner && item.continueWatchingAdmission?.isCurrent() == true

    suspend fun open(context: Context): DownloadedContinueWatchingResult {
        if (!isCurrent()) return DownloadedContinueWatchingResult.Unavailable
        val record = when (copy) {
            Copy.Absent -> return if (DownloadStore.records.value.none(target::matches))
                DownloadedContinueWatchingResult.Missing else DownloadedContinueWatchingResult.Unavailable
            Copy.Ambiguous -> return DownloadedContinueWatchingResult.Unavailable
            is Copy.Exact -> DownloadStore.record(copy.id)?.takeIf(target::matches)
                ?: return DownloadedContinueWatchingResult.Unavailable
        }
        val local = openDownloadedPlaybackWithResume(context, record, owner, ownerToken, episodeTitle = null)
        return if (local != null && isCurrent()) DownloadedContinueWatchingResult.Ready(local)
            else DownloadedContinueWatchingResult.Unavailable
    }

    companion object {
        fun capture(item: MetaItem, detailGeneration: Long): DownloadedContinueWatchingRequest? {
            val admission = item.continueWatchingAdmission ?: return null
            val token = admission.downloadedResumeOwner ?: return null
            if (!admission.isCurrent()) return null
            val target = continueWatchingDownloadTarget(item) ?: return null
            val owner = activeDownloadedPlaybackOwner()
            // Preserve the hero's rendered copy or the exact tap-time index state, before any suspend.
            val copy = admission.renderedDownloadId?.let { Copy.Exact(it) } ?: run {
                val records = DownloadStore.records.value.filter(target::matches)
                when (records.size) {
                    0 -> Copy.Absent
                    1 -> Copy.Exact(records.single().id)
                    else -> Copy.Ambiguous
                }
            }
            return DownloadedContinueWatchingRequest(item, detailGeneration, target, owner, token, copy)
                .takeIf { it.isCurrent() }
        }
    }
}

internal sealed interface DownloadedContinueWatchingResult {
    data object Missing : DownloadedContinueWatchingResult
    data object Unavailable : DownloadedContinueWatchingResult
    data class Ready(val playable: Playable) : DownloadedContinueWatchingResult
}

/** The local index can prove episode+1 within the same season. A source list cannot prove season finality. */
internal fun immediateDownloadedSuccessor(
    current: PlaybackContext,
    records: List<DownloadRecord>,
    isAvailable: (DownloadRecord) -> Boolean = { true },
): DownloadRecord? {
    val season = current.season?.takeIf { it > 0 } ?: return null
    val episode = current.episode?.takeIf { it in 1 until Int.MAX_VALUE } ?: return null
    if (current.type != "series") return null
    val coordinate = records.filter {
        it.type == "series" && it.contentId == current.contentId && it.season == season &&
            it.episode == episode + 1 && it.state == DownloadState.COMPLETED && it.videoId != current.videoId
    }
    if (coordinate.map { it.videoId }.distinct().size != 1) return null
    return coordinate.firstOrNull(isAvailable)
}

internal fun playableDownloadResumeMs(offsetMs: Long, durationMs: Long): Long {
    if (offsetMs <= 0L || durationMs <= 0L) return 0L
    return offsetMs.takeUnless { cwItemIsFinished("series", it.toFloat() / durationMs, 0, 0) } ?: 0L
}

internal fun isDownloadedPlaybackOwnerCurrent(playable: Playable): Boolean {
    val admission = playable.downloadedPlaybackAdmission ?: return false
    val owner = playable.playbackContext?.owner ?: return false
    return PlaybackOwnerEpoch.isCurrent(admission.ownerToken) && activeDownloadedPlaybackOwner() == owner
}

/** Used only to accept a new mounted file. Running playback retains its existing owner gate. */
internal fun isDownloadedPlaybackAdmissionCurrent(playable: Playable): Boolean {
    val admission = playable.downloadedPlaybackAdmission ?: return false
    return playable.playbackContext == admission.target && isDownloadedPlaybackOwnerCurrent(playable) &&
        admission.policyWitness?.isCurrent() != false &&
        admission.rollover?.isCurrent(DownloadStore.records.value) != false
}

internal suspend fun openDownloadedPlayback(
    context: Context,
    record: DownloadRecord,
    episodeTitle: String? = null,
): Playable? {
    val ownerToken = PlaybackOwnerEpoch.capture() ?: return null
    val owner = activeDownloadedPlaybackOwner()
    return openDownloadedPlaybackWithResume(context, record, owner, ownerToken, episodeTitle)
}

private suspend fun openDownloadedPlaybackWithResume(
    context: Context,
    record: DownloadRecord,
    owner: PlaybackContext.Owner,
    ownerToken: PlaybackOwnerToken,
    episodeTitle: String?,
): Playable? {
    val local = openDownloadedPlayback(context, record, owner, ownerToken, episodeTitle) ?: return null
    val bound = local.playbackContext ?: return null
    val native = nativeDownloads(context)
    val resume = if (native != null) {
        native.downloadedResumePositionMs(bound, ownerToken)
    } else if (!owner.usesEngineHistory) {
        val entry = ProfileStore.sharedOrNull()?.watch?.get(bound.contentId)
        if (entry != null && entry.videoId == bound.videoId && entry.type == bound.type) {
            playableDownloadResumeMs(entry.timeOffsetMs.toLong(), entry.durationMs.toLong())
        } else 0L
    } else 0L
    val admitted = refreshDownloadedPlaybackAdmission(context, local) ?: return null
    return admitted.copy(startPositionMs = resume)
}

internal suspend fun nextDownloadedPlayback(context: Context, ended: Playable): Playable? {
    val current = ended.playbackContext ?: return null
    val admission = ended.downloadedPlaybackAdmission ?: return null
    if (!isDownloadedPlaybackOwnerCurrent(ended) || !ended.url.startsWith("file:")) return null
    if (readDownloadedAdmission(context, current, admission.recordId, admission.ownerToken) == null) return null
    val (next, rollover) = withContext<Pair<DownloadRecord, DownloadedRollover?>?>(Dispatchers.IO) {
        val records = DownloadStore.records.value
        val origin = records.firstOrNull { it.id == admission.recordId } ?: return@withContext null
        if (origin.state != DownloadState.COMPLETED || origin.playbackContext(current.owner) != current ||
            !DownloadStore.matchesManagedFileUri(origin, ended.url)) return@withContext null
        immediateDownloadedSuccessor(current, records) {
            DownloadStore.completedPlaybackFile(it) != null
        }?.let { return@withContext it to null }
        val boundary = origin.seasonBoundary?.takeIf { it.matchesOrigin(origin) } ?: return@withContext null
        if (records.any(boundary::contradicts)) return@withContext null
        val successor = records.firstOrNull {
            boundary.matchesNext(it) && DownloadStore.completedPlaybackFile(it) != null
        } ?: return@withContext null
        successor to DownloadedRollover(DownloadedSeasonFile(origin), DownloadedSeasonFile(successor), boundary)
    } ?: return null
    val playable = openDownloadedPlaybackWithResume(context, next, current.owner, admission.ownerToken, episodeTitle = null)
        ?: return null
    if (rollover == null) return playable
    val opened = playable.downloadedPlaybackAdmission ?: return null
    return playable.copy(downloadedPlaybackAdmission = DownloadedPlaybackAdmission(
        opened.recordId, opened.ownerToken, opened.target, opened.policyWitness, rollover,
    )).takeIf(::isDownloadedPlaybackAdmissionCurrent)
}

/** Re-admit the same file for a new mount without replacing its original playback-owner token. */
internal suspend fun refreshDownloadedPlaybackAdmission(context: Context, playable: Playable): Playable? {
    val admission = playable.downloadedPlaybackAdmission ?: return null
    val target = playable.playbackContext ?: return null
    if (target != admission.target || !isDownloadedPlaybackOwnerCurrent(playable)) return null
    val exists = withContext(Dispatchers.IO) {
        val record = DownloadStore.record(admission.recordId) ?: return@withContext false
        record.playbackContext(target.owner) == target && DownloadStore.completedPlaybackFile(record) != null &&
            DownloadStore.matchesManagedFileUri(record, playable.url) &&
            admission.rollover?.isCurrent(DownloadStore.records.value) != false
    }
    if (!exists) return null
    val current = readDownloadedAdmission(context, target, admission.recordId, admission.ownerToken) ?: return null
    return playable.copy(downloadedPlaybackAdmission = DownloadedPlaybackAdmission(
        current.recordId, current.ownerToken, current.target, current.policyWitness, admission.rollover,
    )).takeIf(::isDownloadedPlaybackAdmissionCurrent)
}

private suspend fun openDownloadedPlayback(
    context: Context,
    record: DownloadRecord,
    owner: PlaybackContext.Owner,
    ownerToken: PlaybackOwnerToken,
    episodeTitle: String?,
): Playable? {
    val target = record.playbackContext(owner)
    if (readDownloadedAdmission(context, target, record.id, ownerToken) == null) return null
    val prepared = withContext(Dispatchers.IO) {
        if (!ownerToken.isActive) return@withContext null
        val file = DownloadStore.completedPlaybackFile(record) ?: return@withContext null
        val resolution = DownloadedMediaCapabilityResolver.resolve(record, file, AndroidDownloadedMediaCapabilityProbe)
        coroutineContext.ensureActive()
        if (!ownerToken.isActive) return@withContext null
        val accepted = if (resolution.shouldPersist) {
            DownloadStore.updateIf(record.id, predicate = { it == record }) { resolution.record }
        } else {
            record
        } ?: return@withContext null
        if (DownloadStore.completedPlaybackFile(accepted) != file) return@withContext null
        accepted.localPlayable(file.toURI().toString(), owner).copy(episodeTitle = episodeTitle)
    } ?: return null
    val admission = readDownloadedAdmission(context, target, record.id, ownerToken) ?: return null
    return prepared.copy(downloadedPlaybackAdmission = admission).takeIf(::isDownloadedPlaybackAdmissionCurrent)
}

private fun activeDownloadedPlaybackOwner(): PlaybackContext.Owner {
    val profiles = ProfileStore.sharedOrNull()
    return PlaybackContext.Owner(
        profileId = profiles?.activeProfileId ?: UserProfile.OWNER_ID,
        usesEngineHistory = profiles?.activeUsesEngineHistory ?: true,
    )
}
