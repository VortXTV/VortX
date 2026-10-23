package com.vortx.android.player

/** Active engine evidence only. No filename, configured language or display capability input. */
data class PlaybackMetadata(
    val width: Int = 0, val height: Int = 0,
    val dynamicRange: PlaybackDynamicRange = PlaybackDynamicRange.UNKNOWN,
    val audioSelected: Boolean = false, val audioLanguage: String? = null,
    val audioCodec: String? = null, val audioChannels: Int = 0,
) {
    fun pills(): List<PlaybackMetadataPill> = buildList {
        if (width > 0 && height > 0) {
            val quality = when {
                width >= 7000 -> "8K"; width >= 3000 -> "4K"; width >= 2200 -> "1440p"
                width >= 1500 -> "1080p"; width >= 1000 -> "720p"; else -> "${height}p"
            }
            add(PlaybackMetadataPill("quality", quality, "Video resolution: $width by $height, $quality"))
        }
        dynamicRange.label?.let { add(PlaybackMetadataPill("range", it, "Active video dynamic range: $it")) }
        if (audioSelected) {
            val parts = mutableListOf<String>()
            audioLanguage?.trim()?.takeIf {
                it.matches(languagePattern) &&
                    it.lowercase(java.util.Locale.ROOT) !in setOf("und", "unknown", "zxx")
            }?.let { parts += java.util.Locale.forLanguageTag(it).getDisplayLanguage(java.util.Locale.getDefault())
                .ifEmpty { it.uppercase(java.util.Locale.ROOT) } }
            codecLabel(audioCodec)?.let { parts += it }
            if (audioChannels in 1..64) parts += "${audioChannels}ch"
            val text = parts.joinToString(" · ").ifEmpty { "Audio" }
            add(PlaybackMetadataPill("audio", text, "Selected audio: $text"))
        }
    }
    companion object {
        private val languagePattern = Regex("[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*")
        fun codecLabel(raw: String?): String? = when (raw?.lowercase(java.util.Locale.ROOT)) {
            "eac3", "ec-3", "eac3-joc", "audio/eac3", "audio/eac3-joc" -> "EAC3"
            "ac3", "ac-3", "audio/ac3" -> "AC3"
            "truehd", "audio/true-hd" -> "TrueHD"
            "dts", "dts-hd", "dca", "audio/vnd.dts", "audio/vnd.dts.hd" -> "DTS"
            "aac", "mp4a", "audio/mp4a-latm" -> "AAC"
            "flac", "audio/flac" -> "FLAC"; "opus", "audio/opus" -> "Opus"
            "mp3", "audio/mpeg" -> "MP3"; "alac", "audio/alac" -> "ALAC"
            "pcm", "audio/raw" -> "PCM"; else -> null
        }
        fun mpvRange(gamma: String?): PlaybackDynamicRange = when (gamma?.lowercase(java.util.Locale.ROOT)) {
            "pq", "smpte2084" -> PlaybackDynamicRange.PQ
            "hlg", "arib-std-b67" -> PlaybackDynamicRange.HLG
            "bt.1886", "srgb", "gamma2.2", "gamma2.4", "bt.709" -> PlaybackDynamicRange.SDR
            else -> PlaybackDynamicRange.UNKNOWN
        }
    }
}
enum class PlaybackDynamicRange(val label: String?) {
    UNKNOWN(null), SDR(null), PQ("HDR"), HLG("HLG"), DOLBY_VISION("Dolby Vision")
}
data class PlaybackMetadataPill(val id: String, val text: String, val accessibilityLabel: String)
