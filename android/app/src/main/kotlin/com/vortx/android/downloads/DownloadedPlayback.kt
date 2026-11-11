package com.vortx.android.downloads

import android.content.Context
import com.vortx.android.VortXApplication
import com.vortx.android.engine.NativeCatalogRepository
import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import com.vortx.android.model.Episode
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
        admission.policyWitness?.isCurrent() != false
}

internal suspend fun openDownloadedPlayback(
    context: Context,
    record: DownloadRecord,
    episodeTitle: String? = null,
): Playable? {
    val ownerToken = PlaybackOwnerEpoch.capture() ?: return null
    val owner = activeDownloadedPlaybackOwner()
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
    val next = withContext(Dispatchers.IO) {
        val records = DownloadStore.records.value
        val origin = records.firstOrNull { it.id == admission.recordId } ?: return@withContext null
        if (origin.state != DownloadState.COMPLETED || origin.playbackContext(current.owner) != current ||
            !DownloadStore.matchesManagedFileUri(origin, ended.url)) return@withContext null
        immediateDownloadedSuccessor(current, records) {
            DownloadStore.completedPlaybackFile(it) != null
        }
    } ?: return null
    return openDownloadedPlayback(context, next, current.owner, admission.ownerToken, episodeTitle = null)
}

/** Re-admit the same file for a new mount without replacing its original playback-owner token. */
internal suspend fun refreshDownloadedPlaybackAdmission(context: Context, playable: Playable): Playable? {
    val admission = playable.downloadedPlaybackAdmission ?: return null
    val target = playable.playbackContext ?: return null
    if (target != admission.target || !isDownloadedPlaybackOwnerCurrent(playable)) return null
    val exists = withContext(Dispatchers.IO) {
        val record = DownloadStore.record(admission.recordId) ?: return@withContext false
        record.playbackContext(target.owner) == target && DownloadStore.completedPlaybackFile(record) != null &&
            DownloadStore.matchesManagedFileUri(record, playable.url)
    }
    if (!exists) return null
    val current = readDownloadedAdmission(context, target, admission.recordId, admission.ownerToken) ?: return null
    return playable.copy(downloadedPlaybackAdmission = current).takeIf(::isDownloadedPlaybackAdmissionCurrent)
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
