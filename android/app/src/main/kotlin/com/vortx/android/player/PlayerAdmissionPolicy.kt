package com.vortx.android.player

import com.vortx.android.model.Playable
import com.vortx.android.model.StreamSource
import com.vortx.android.model.TrackPreferences
import java.util.Locale

private val knownAudioLanguageCodes: Set<String> = Locale.getISOLanguages().toSet().let { alpha2 ->
    alpha2 + alpha2.map { Locale(it).isO3Language } +
        setOf("fre", "ger", "chi", "dut", "gre", "cze", "rum", "slo", "per", "ice", "mac", "alb", "arm", "geo", "baq", "wel", "may", "bur", "fil", "pob", "scc", "scr")
}

internal fun isJunkPlayerDuration(durationMs: Long, playable: Playable): Boolean {
    if (playable.isTrailer || durationMs <= 0L) return false
    val expected = playable.expectedDurationMs
    return if (expected > 0L) durationMs < minOf(expected / 2, (expected - 600_000L).takeIf { it > 0L } ?: expected / 2)
    else durationMs < 120_000L
}

internal fun isJunkPlayerEof(positionMs: Long, durationMs: Long, playable: Playable): Boolean {
    if (playable.isTrailer) return false
    val expected = playable.expectedDurationMs
    return if (expected > 0L) positionMs < minOf(expected / 2, (expected - 600_000L).takeIf { it > 0L } ?: expected / 2)
    else positionMs < 120_000L && durationMs < 120_000L
}

/** Local, cast, and exit writes use the same ratio-poisoning policy, even for a manually chosen file. */
internal fun canReportPlayerProgress(playable: Playable, positionMs: Long, durationMs: Long): Boolean =
    !playable.isTrailer && positionMs >= 0L && durationMs > 0L && !isJunkPlayerDuration(durationMs, playable)

/** Unknown/unlabelled audio is not evidence of a wrong file. This verdict uses mounted tracks, never filenames. */
internal fun knownWrongAutomaticAudio(
    tracks: List<PlayerTrack>, preferences: TrackPreferences, matchAudioSub: Boolean,
    manualAudio: Boolean = false, manualSource: Boolean = false,
): Boolean {
    if (manualAudio || manualSource || tracks.isEmpty()) return false
    val wanted = if (matchAudioSub) preferences.subtitleLanguages else preferences.audioLanguages
    if (wanted.isEmpty()) return false
    if (tracks.any { track ->
        val language = track.lang?.trim()?.lowercase().orEmpty()
        language.substringBefore('-').substringBefore('_') !in knownAudioLanguageCodes
    }) return false
    return TrackSelector.select(tracks, emptyList(), preferences, matchAudioSub).audioId == null
}

/** Per-target automatic audio recovery is finite and cannot revisit the same source after an ABA update. */
internal class AutomaticAudioAlternates(private val maxAlternates: Int = 2) {
    private val rejected = mutableSetOf<String>()
    private var attempts = 0
    fun next(current: StreamSource?, candidates: List<StreamSource>): StreamSource? {
        current?.let { rejected += playerSourceHandle(it) }
        if (attempts >= maxAlternates) return null
        val next = candidates.firstOrNull { playerSourceHandle(it) !in rejected } ?: return null
        rejected += playerSourceHandle(next); attempts++
        return next
    }
}
