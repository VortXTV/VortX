package com.vortx.android.player

import java.util.UUID

/** Main-looper confined Media3 source map. IDs are opaque, never URL hashes or signed transport data. */
internal class SubtitleSidecarIdentity(private val newId: () -> String = { UUID.randomUUID().toString() }) {
    private val byUri = mutableMapOf<String, String>()
    fun reset() { byUri.clear() }
    fun idFor(uri: String): String = byUri.getOrPut(uri) { "vortx-sidecar:${newId()}" }
    fun existingId(uri: String): String? = byUri[uri]
}

internal data class OwnedSubtitleTrack(val group: Int, val track: Int, val formatId: String?)

/** Language/title/count/last-item are not file identity. Ambiguous and excessive inputs fail closed. */
internal fun uniqueOwnedSubtitleTrack(id: String, candidates: List<OwnedSubtitleTrack>): OwnedSubtitleTrack? {
    if (!id.startsWith("vortx-sidecar:") || candidates.size > 4096) return null
    var match: OwnedSubtitleTrack? = null
    for (candidate in candidates) {
        if (candidate.group < 0 || candidate.track < 0) return null
        if (candidate.formatId != id) continue
        if (match != null) return null
        match = candidate
    }
    return match
}
