package com.vortx.android.model

/** Compile-only app model shape; tests inspect exact object identity through the real merge. */
data class StreamGroup(val addon: String, val streams: List<StreamSource>)
data class StreamSource(
    val id: String,
    val addon: String = "",
    val title: String = "",
    val description: String? = null,
    val quality: String? = null,
    val isTorrent: Boolean = false,
    val infoHash: String? = null,
    val url: String? = null,
    val nzbUrl: String? = null,
    val isYouTubeTrailer: Boolean = false,
)
