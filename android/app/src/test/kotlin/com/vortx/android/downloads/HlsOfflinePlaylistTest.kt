package com.vortx.android.downloads

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HlsOfflinePlaylistTest {
    private val base = "https://media.example/catalog/movie.m3u8".toHttpUrl()

    @Test
    fun masterChoosesHighestBandwidthAndFirstTieDeterministically() {
        val result = HlsOfflinePlaylistParser.parse(
            """#EXTM3U
                |#EXT-X-STREAM-INF:BANDWIDTH=100,CODECS="avc1.4d401f,mp4a.40.2"
                |low.m3u8
                |#EXT-X-STREAM-INF:BANDWIDTH=200
                |../high.m3u8
                |#EXT-X-STREAM-INF:BANDWIDTH=200
                |tie.m3u8
            """.trimMargin(), base,
        ) as HlsOfflinePlaylist.Master
        assertEquals("https://media.example/high.m3u8", result.selectedVariant.toString())
    }

    @Test
    fun mediaRetainsSequenceDiscontinuityAndFiniteEnding() {
        val result = media("""#EXT-X-MEDIA-SEQUENCE:41
            |#EXTINF:4.5,Title
            |first.ts?token=one
            |#EXT-X-DISCONTINUITY
            |#EXTINF:4,
            |../second.ts
        """.trimMargin())
        assertEquals(2, result.assets.size)
        assertEquals("https://media.example/catalog/first.ts?token=one", result.assets[0].url.toString())
        assertTrue(result.localPlaylist.contains("#EXT-X-MEDIA-SEQUENCE:41"))
        assertTrue(result.localPlaylist.contains("#EXT-X-DISCONTINUITY"))
        assertTrue(result.localPlaylist.endsWith("#EXT-X-ENDLIST\n"))
        assertFalse(result.localPlaylist.contains("token="))
    }

    @Test
    fun identityKeysAndMapsBecomeLocalAndKeyRotationIsPreserved() {
        val result = media("""#EXT-X-KEY:METHOD=AES-128,URI="keys/one",IV=0x01,KEYFORMAT="identity"
            |#EXT-X-MAP:URI="init.mp4"
            |#EXTINF:4,
            |one.m4s
            |#EXT-X-KEY:METHOD=AES-128,URI="keys/two",IV=0x02
            |#EXTINF:4,
            |two.m4s
            |#EXT-X-KEY:METHOD=NONE
            |#EXTINF:4,
            |three.m4s
        """.trimMargin())
        assertEquals(listOf(HlsOfflineAssetKind.KEY, HlsOfflineAssetKind.MAP, HlsOfflineAssetKind.SEGMENT, HlsOfflineAssetKind.KEY, HlsOfflineAssetKind.SEGMENT, HlsOfflineAssetKind.SEGMENT), result.assets.map { it.kind })
        assertTrue(result.localPlaylist.contains("URI=\"key-000000.bin\",IV=0x01"))
        assertTrue(result.localPlaylist.contains("#EXT-X-MAP:URI=\"map-000001.bin\""))
        assertTrue(result.localPlaylist.contains("URI=\"key-000003.bin\",IV=0x02"))
    }

    @Test
    fun byteRangesResolveExactAndImplicitOffsetsAndDisappearLocally() {
        val result = media("""#EXT-X-MAP:URI="init.mp4",BYTERANGE="16@32"
            |#EXTINF:4,
            |#EXT-X-BYTERANGE:8@0
            |all.ts
            |#EXTINF:4,
            |#EXT-X-BYTERANGE:12
            |all.ts
        """.trimMargin())
        assertEquals(listOf(HlsOfflineByteRange(32, 16), HlsOfflineByteRange(0, 8), HlsOfflineByteRange(8, 12)), result.assets.map { it.range })
        assertFalse(result.localPlaylist.contains("BYTERANGE"))
    }

    @Test
    fun implicitRangeRequiresPreviousRangeOfTheSameResource() {
        rejectsMedia("#EXTINF:4,\n#EXT-X-BYTERANGE:4\none.ts")
        rejectsMedia("#EXTINF:4,\n#EXT-X-BYTERANGE:4@0\none.ts\n#EXTINF:4,\n#EXT-X-BYTERANGE:4\ntwo.ts")
        rejectsMedia("#EXTINF:4,\none.ts\n#EXTINF:4,\n#EXT-X-BYTERANGE:4\none.ts")
    }

    @Test
    fun rangeOverflowAndAmbiguousMapRangesAreRejected() {
        rejectsMedia("#EXTINF:4,\n#EXT-X-BYTERANGE:10@9223372036854775800\none.ts")
        rejectsMedia("#EXT-X-MAP:URI=\"init.mp4\",BYTERANGE=\"16\"\n#EXTINF:4,\none.ts")
    }

    @Test
    fun liveEmptyAndTrailingMediaAreRejected() {
        rejects("#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\none.ts")
        rejects("#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-ENDLIST")
        rejects("#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\none.ts\n#EXT-X-ENDLIST\n#EXTINF:4,\ntwo.ts")
    }

    @Test
    fun drmSampleAesEncryptedRangesAndMapsWithoutIvAreRejected() {
        listOf(
            "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key\"",
            "#EXT-X-KEY:METHOD=AES-128,URI=\"key\",KEYFORMAT=\"com.apple.streamingkeydelivery\"",
            "#EXT-X-KEY:METHOD=AES-128,URI=\"key\",KEYFORMATVERSIONS=\"2\"",
            "#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXT-X-MAP:URI=\"init.mp4\"",
            "#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXT-X-BYTERANGE:16@0",
        ).forEach { rejectsMedia("$it\n#EXTINF:4,\none.ts") }
    }

    @Test
    fun externalRenditionsAreNotSilentlyDropped() {
        rejects("#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=200,AUDIO=\"a\"\nvideo.m3u8")
        rejects("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=200,AUDIO=\"a\"\nvideo.m3u8")
    }

    @Test
    fun unknownNetworkTagsAndLowLatencyTagsFailClosed() {
        listOf(
            "#EXT-X-PART:DURATION=1,URI=\"part.ts\"",
            "#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"future.ts\"",
            "#EXT-X-RENDITION-REPORT:URI=\"other.m3u8\"",
            "#EXT-X-CONTENT-STEERING:SERVER-URI=\"https://tracker.example/\"",
            "#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"key\"",
            "#EXT-X-FUTURE:URI=\"hidden.ts\"",
            "#EXT-X-I-FRAMES-ONLY",
            "#EXT-X-GAP",
        ).forEach { rejectsMedia("$it\n#EXTINF:4,\none.ts") }
    }

    @Test
    fun insecureOrNonHttpUrisAndMalformedAttributesAreRejected() {
        listOf("http://media.example/one.ts", "file:///private/one.ts", "https://user:pass@media.example/one.ts", "one.ts#fragment", "one\\two.ts").forEach {
            rejectsMedia("#EXTINF:4,\n$it")
        }
        rejectsMedia("#EXT-X-KEY:METHOD=AES-128,URI=\"key\",URI=\"key2\"\n#EXTINF:4,\none.ts")
        rejectsMedia("#EXT-X-KEY:METHOD=AES-128,URI=\"unterminated\n#EXTINF:4,\none.ts")
    }

    @Test
    fun playlistBytesAndEntryCountsAreBounded() {
        rejects("#EXTM3U\n#" + "a".repeat(HlsOfflinePlaylistParser.MAX_PLAYLIST_BYTES))
        rejectsMedia((0..HlsOfflinePlaylistParser.MAX_SEGMENTS).joinToString("\n") { "#EXTINF:1,\n$it.ts" })
    }

    private fun media(body: String) = HlsOfflinePlaylistParser.parse("#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-TARGETDURATION:5\n$body\n#EXT-X-ENDLIST\n", base) as HlsOfflinePlaylist.Media
    private fun rejectsMedia(body: String) { assertTrue(runCatching { media(body) }.exceptionOrNull() is HlsOfflineException) }
    private fun rejects(text: String) { assertTrue(runCatching { HlsOfflinePlaylistParser.parse(text, base) }.exceptionOrNull() is HlsOfflineException) }
}
