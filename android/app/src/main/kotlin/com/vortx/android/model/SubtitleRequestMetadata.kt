package com.vortx.android.model

import java.net.URLEncoder

/** Exact-file hints belonging to the selected source, never a guessed torrent infoHash. */
data class SubtitleRequestMetadata(
    val filename: String? = null,
    val videoHash: String? = null,
    val videoSize: Long? = null,
) {
    fun resourcePath(type: String, videoId: String): String {
        val extras = buildList {
            videoHash?.takeIf { it.isNotEmpty() }?.let { add("videoHash=${encode(it)}") }
            videoSize?.takeIf { it > 0L }?.let { add("videoSize=$it") }
            filename?.takeIf { it.isNotEmpty() }?.let { add("filename=${encode(it)}") }
        }.joinToString("&")
        return "subtitles/${encode(type)}/${encode(videoId).replace("%3A", ":")}" +
            (if (extras.isEmpty()) "" else "/$extras") + ".json"
    }

    private fun encode(value: String): String =
        URLEncoder.encode(value, "UTF-8").replace("+", "%20").replace("*", "%2A").replace("%7E", "~")
}
