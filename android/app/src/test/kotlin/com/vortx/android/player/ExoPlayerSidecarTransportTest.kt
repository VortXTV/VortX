package com.vortx.android.player

import androidx.media3.datasource.DataSource
import com.vortx.android.communityjs.CommunityJsMedia3DataSourceFactory
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

        val signedUrl = "https://user:password@subs.example/token/path-secret/en.vtt?token=signed-secret#private"
        val signedSubtitle = ExternalSubtitle(signedUrl, mapOf("Authorization" to secret), "en", "English")
        val source = StreamSource(
            id = "source", addon = "Provider", title = "Signed", url = signedUrl,
            requestHeaders = mapOf("Authorization" to secret), externalSubtitleTracks = listOf(signedSubtitle),
        )
        val playable = Playable(
            url = signedUrl, title = "Signed", headers = mapOf("Authorization" to secret),
            externalSubtitleTracks = listOf(signedSubtitle), communityJsTransport = true,
        )
        listOf(signedSubtitle.toString(), source.toString(), playable.toString()).forEach { diagnostic ->
            assertFalse(diagnostic.contains(secret))
            assertFalse(diagnostic.contains("signed-secret"))
            assertFalse(diagnostic.contains("password"))
            assertFalse(diagnostic.contains("path-secret"))
            assertFalse(diagnostic.contains("#private"))
        }
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

        assertTrue(source.contains("media3DataSourceFactory(configuration.uri.toString(), headers"))
        assertTrue(source.contains("CommunityJsMedia3DataSourceFactory(rootUrl, scopedHeaders)"))
        assertTrue(source.contains("createMediaSource(configuration, C.TIME_UNSET)"))
        assertTrue(source.contains("setLanguage(subtitle.language)"))
        assertTrue(source.contains("setLabel(subtitle.name)"))
        assertTrue(source.contains("setMimeType(mime)"))
        assertTrue(source.contains("setSelectionFlags(C.SELECTION_FLAG_DEFAULT)"))
        assertTrue(source.contains("setAllowCrossProtocolRedirects(true)"))
        assertTrue(source.contains("DefaultDataSource.Factory(appContext, http)"))
        assertFalse(source.contains("DefaultDataSource.Factory(appContext, CommunityJsMedia3DataSourceFactory"))
        assertFalse(source.contains("setSubtitleConfigurations(subtitleConfigs)"))
    }

    @Test
    fun `community media factory rejects non-http child schemes while trusted route stays selectable`() {
        val restricted = CommunityJsMedia3DataSourceFactory(
            rootUrl = "https://93.184.216.34/master.m3u8",
            providerHeaders = mapOf("Authorization" to "secret"),
        )
        assertFalse(restricted.admitsForTesting("file:///data/user/0/com.vortx.android/private"))
        assertFalse(restricted.admitsForTesting("content://com.vortx.android/private"))
        assertTrue(restricted.admitsForTesting("https://93.184.216.34/segment.ts"))

        val trusted = object : DataSource.Factory {
            override fun createDataSource(): DataSource = error("not opened")
        }
        assertTrue(selectMedia3DataSourceFactory(true, restricted = { restricted }, trusted = { trusted }) === restricted)
        assertTrue(selectMedia3DataSourceFactory(false, restricted = { restricted }, trusted = { trusted }) === trusted)
    }

    @Test
    fun `community playback never enters adaptive probe but trusted playback remains unchanged`() {
        val secret = "provider-probe-secret"
        val community = Playable(
            url = "https://media.example/video.m3u8?token=$secret",
            title = "Community",
            headers = mapOf("Authorization" to secret),
            communityJsTransport = true,
        )
        var communityCalls = 0
        noteAdaptiveStreamIfTrusted(community) { _, _ -> communityCalls++ }
        assertEquals(0, communityCalls)

        val trusted = community.copy(
            url = "https://trusted.example/video.m3u8",
            headers = mapOf("Referer" to "https://trusted.example/"),
            communityJsTransport = false,
        )
        var observed: Pair<String, Map<String, String>>? = null
        noteAdaptiveStreamIfTrusted(trusted) { url, headers -> observed = url to headers }
        assertEquals(trusted.url to trusted.headers, observed)
    }

    private fun readSource(name: String): String {
        val sourcePath = sequenceOf(
            Path.of("src/main/kotlin/com/vortx/android/player/$name"),
            Path.of("app/src/main/kotlin/com/vortx/android/player/$name"),
        ).first(Files::exists)
        return String(Files.readAllBytes(sourcePath), StandardCharsets.UTF_8)
    }
}
