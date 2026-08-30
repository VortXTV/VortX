package com.vortx.android.player

import com.vortx.android.model.ExternalSubtitle
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ExoPlayerSidecarTransportTest {
    @Test
    fun `video and each structured sidecar keep distinct request headers`() {
        val playable = Playable(
            url = "https://video.example/movie.mkv",
            title = "Movie",
            headers = mapOf("Authorization" to "video-secret", "Referer" to "https://video.example"),
            externalSubtitleTracks = listOf(
                ExternalSubtitle(
                    url = "https://subs-a.example/en.vtt",
                    headers = mapOf("Authorization" to "subtitle-a-secret"),
                    language = "en",
                    name = "English",
                ),
                ExternalSubtitle(
                    url = "https://subs-b.example/es.srt",
                    headers = mapOf("X-Subtitle-Token" to "subtitle-b-secret"),
                    language = "es",
                    name = "Spanish",
                ),
            ),
        )

        val subtitles = normalizedExternalSubtitles(playable)
        val plan = media3RequestHeaderPlan(playable, subtitles)

        assertEquals(playable.headers, plan.videoHeaders())
        assertEquals(mapOf("Authorization" to "subtitle-a-secret"), plan.subtitleHeaders(0))
        assertEquals(mapOf("X-Subtitle-Token" to "subtitle-b-secret"), plan.subtitleHeaders(1))
        assertFalse(plan.subtitleHeaders(0).containsValue("video-secret"))
        assertFalse(plan.subtitleHeaders(1).containsValue("subtitle-a-secret"))
    }

    @Test
    fun `legacy url-only sidecars receive no request headers`() {
        val playable = Playable(
            url = "https://video.example/movie.mkv",
            title = "Movie",
            headers = mapOf("Authorization" to "video-secret"),
            externalSubtitles = listOf("https://subs.example/legacy.vtt"),
        )

        val subtitles = normalizedExternalSubtitles(playable)
        val plan = media3RequestHeaderPlan(playable, subtitles)

        assertEquals(1, subtitles.size)
        assertTrue(subtitles.single().headers.isEmpty())
        assertTrue(plan.subtitleHeaders(0).isEmpty())
    }

    @Test
    fun `header plan diagnostics and identity never expose secret values`() {
        val secret = "never-log-this-token"
        val subtitle = ExternalSubtitle(
            url = "https://subs.example/en.vtt",
            headers = mapOf("Authorization" to secret),
            language = "en",
            name = "English",
        )
        val plan = Media3RequestHeaderPlan(
            videoHeaders = mapOf("Authorization" to secret),
            subtitleHeaders = listOf(mapOf("X-Token" to secret)),
        )

        assertFalse(plan.toString().contains(secret))
        assertTrue(plan.toString().contains("videoHeaderCount=1"))
        assertFalse(plan == Media3RequestHeaderPlan(mapOf("Authorization" to secret), listOf(mapOf("X-Token" to secret))))
        assertFalse(subtitle.toString().contains(secret))
        assertNotEquals(
            subtitle,
            ExternalSubtitle(
                url = subtitle.url,
                headers = mapOf("Authorization" to "rotated-secret"),
                language = subtitle.language,
                name = subtitle.name,
            ),
        )
    }

    @Test
    fun `rotated sidecar credential publishes through groups and reaches playback plan`() {
        fun groupWith(token: String): StreamGroup = StreamGroup(
            addon = "Provider",
            streams = listOf(
                StreamSource(
                    id = "stable-source",
                    addon = "Provider",
                    title = "Movie",
                    url = "https://video.example/movie.mkv",
                    externalSubtitleTracks = listOf(
                        ExternalSubtitle(
                            url = "https://subs.example/en.vtt",
                            headers = mapOf("Authorization" to token),
                            language = "en",
                            name = "English",
                        ),
                    ),
                ),
            ),
        )

        val oldSecret = "old-secret"
        val rotatedSecret = "rotated-secret"
        val groups = MutableStateFlow(listOf(groupWith(oldSecret)))
        groups.value = listOf(groupWith(rotatedSecret))

        val publishedSubtitle = groups.value.single().streams.single().externalSubtitleTracks.single()
        val playable = Playable(
            url = "https://video.example/movie.mkv",
            title = "Movie",
            externalSubtitleTracks = listOf(publishedSubtitle),
        )
        val plan = media3RequestHeaderPlan(playable, normalizedExternalSubtitles(playable))

        assertEquals(mapOf("Authorization" to rotatedSecret), publishedSubtitle.headers)
        assertEquals(mapOf("Authorization" to rotatedSecret), plan.subtitleHeaders(0))
        assertFalse(publishedSubtitle.toString().contains(oldSecret))
        assertFalse(publishedSubtitle.toString().contains(rotatedSecret))
    }

    @Test
    fun `sidecar snapshots caller-owned header maps`() {
        val callerHeaders = mutableMapOf("Authorization" to "original-secret")
        val subtitle = ExternalSubtitle(
            url = "https://subs.example/en.vtt",
            headers = callerHeaders,
            language = "en",
            name = "English",
        )
        val originalHash = subtitle.hashCode()

        callerHeaders["Authorization"] = "mutated-secret"

        assertEquals(mapOf("Authorization" to "original-secret"), subtitle.headers)
        assertEquals(originalHash, subtitle.hashCode())
        assertFalse(subtitle.toString().contains("original-secret"))
        assertFalse(subtitle.toString().contains("mutated-secret"))
    }

    @Test
    fun `Media3 source construction isolates sidecars and preserves local video support`() {
        val source = readSource("ExoPlayerEngine.kt")

        assertTrue(source.contains("SingleSampleMediaSource.Factory(media3DataSourceFactory(headers))"))
        assertTrue(source.contains("createMediaSource(configuration, C.TIME_UNSET)"))
        assertTrue(source.contains("setLanguage(subtitle.language)"))
        assertTrue(source.contains("setLabel(subtitle.name)"))
        assertTrue(source.contains("setMimeType(mime)"))
        assertTrue(source.contains("setSelectionFlags(C.SELECTION_FLAG_DEFAULT)"))
        assertTrue(source.contains("setAllowCrossProtocolRedirects(true)"))
        assertTrue(source.contains("return DefaultDataSource.Factory(appContext, http)"))
        assertFalse(source.contains("setSubtitleConfigurations(subtitleConfigs)"))
    }

    private fun readSource(name: String): String {
        val sourcePath = sequenceOf(
            Path.of("src/main/kotlin/com/vortx/android/player/$name"),
            Path.of("app/src/main/kotlin/com/vortx/android/player/$name"),
        ).first(Files::exists)
        return String(Files.readAllBytes(sourcePath), StandardCharsets.UTF_8)
    }
}
