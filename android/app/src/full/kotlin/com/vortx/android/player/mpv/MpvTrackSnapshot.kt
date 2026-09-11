package com.vortx.android.player.mpv

import com.vortx.android.player.PlayerTrack
import org.json.JSONArray

internal data class MpvTrackSnapshot(val audio: List<PlayerTrack>, val subtitles: List<PlayerTrack>)

/** Null means unavailable/malformed, not an authoritative empty track list. Parse atomically. */
internal fun parseMpvTrackSnapshot(json: String?): MpvTrackSnapshot? {
    if (json == null) return null
    return runCatching {
        val array = JSONArray(json)
        val audio = mutableListOf<PlayerTrack>()
        val subtitles = mutableListOf<PlayerTrack>()
        for (index in 0 until array.length()) {
            val track = array.getJSONObject(index)
            val type = track.optString("type")
            val id = track.optInt("id", -1)
            if (id < 0) continue
            val entry = PlayerTrack(
                id = id,
                title = track.optString("title").ifEmpty {
                    track.optString("lang").ifEmpty { "$type $id" }
                },
                lang = track.optString("lang").ifEmpty { null },
                selected = track.optBoolean("selected", false),
                forced = track.optBoolean("forced", false),
                channels = if (type == "audio") track.optInt("demux-channel-count", 0) else 0,
            )
            when (type) {
                "audio" -> audio.add(entry)
                "sub" -> subtitles.add(entry)
            }
        }
        MpvTrackSnapshot(audio, subtitles)
    }.getOrNull()
}
