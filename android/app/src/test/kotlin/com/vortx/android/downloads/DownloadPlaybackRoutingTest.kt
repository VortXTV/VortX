package com.vortx.android.downloads

import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class DownloadPlaybackRoutingTest {

    private fun record(
        isDolbyVision: Boolean? = false,
        isAtmos: Boolean? = false,
    ) = DownloadRecord(
        id = "download-1",
        contentId = "tt1234567",
        videoId = "tt1234567",
        type = "movie",
        name = "Test Movie",
        qualityText = "4K",
        isDolbyVision = isDolbyVision,
        isAtmos = isAtmos,
        remoteURL = "https://example.test/movie.mkv",
        localFilename = "download-1.mkv",
        state = DownloadState.COMPLETED,
    )

    private fun authenticLegacyJson(): JSONObject = JSONObject()
        .put("id", "legacy")
        .put("contentId", "tt7654321")
        .put("videoId", "tt7654321")
        .put("type", "movie")
        .put("name", "Legacy Movie")
        .put("qualityText", "4K")
        .put("remoteURL", "https://example.test/legacy.mkv")
        .put("localFilename", "legacy.mkv")
        .put("state", DownloadState.COMPLETED.wireValue)

    private fun resolveLegacy(
        capabilities: DownloadedMediaCapabilities?,
    ): DownloadedMediaCapabilityResolution {
        val legacy = requireNotNull(DownloadStore.recordFromJson(authenticLegacyJson()))
        return DownloadedMediaCapabilityResolver.resolve(
            record = legacy,
            file = File("legacy.mkv"),
            probe = DownloadedMediaCapabilityProbe { capabilities },
        )
    }

    @Test
    fun `new download local playback preserves known routing flags`() {
        val playable = record(isDolbyVision = true, isAtmos = true)
            .localPlayable("file:///downloads/movie.mkv")

        assertEquals("file:///downloads/movie.mkv", playable.url)
        assertTrue(playable.isDolbyVision)
        assertTrue(playable.isAtmos)
        assertFalse(playable.isTorrent)
        assertFalse(playable.viaStreamingServer)
    }

    @Test
    fun `new download index round trip preserves known routing flags`() {
        val decoded = DownloadStore.recordFromJson(
            DownloadStore.recordToJson(record(isDolbyVision = true, isAtmos = false)),
        )

        assertNotNull(decoded)
        assertEquals(true, decoded!!.isDolbyVision)
        assertEquals(false, decoded.isAtmos)
    }

    @Test
    fun `authentic legacy 4K index keeps both capabilities unknown`() {
        val decoded = DownloadStore.recordFromJson(authenticLegacyJson())

        assertNotNull(decoded)
        assertNull(decoded!!.isDolbyVision)
        assertNull(decoded.isAtmos)
        assertFalse(DownloadStore.recordToJson(decoded).has("isDolbyVision"))
        assertFalse(DownloadStore.recordToJson(decoded).has("isAtmos"))
    }

    @Test
    fun `authentic legacy 4K probe resolves Dolby Vision only`() {
        var persisted: DownloadRecord? = null
        val legacy = requireNotNull(DownloadStore.recordFromJson(authenticLegacyJson()))
        val resolution = DownloadedMediaCapabilityResolver.resolve(
            record = legacy,
            file = File("legacy.mkv"),
            probe = DownloadedMediaCapabilityProbe {
                DownloadedMediaCapabilities(isDolbyVision = true, isAtmos = false)
            },
            persistResolved = { persisted = it },
        )

        assertTrue(resolution.shouldPersist)
        assertEquals(resolution.record, persisted)
        assertEquals(true, resolution.record.isDolbyVision)
        assertEquals(false, resolution.record.isAtmos)
        assertTrue(resolution.record.localPlayable("file:///legacy.mkv").isDolbyVision)
        assertFalse(resolution.record.localPlayable("file:///legacy.mkv").isAtmos)
    }

    @Test
    fun `authentic legacy 4K probe resolves Atmos JOC only`() {
        val resolution = resolveLegacy(
            DownloadedMediaCapabilities(isDolbyVision = false, isAtmos = true),
        )

        assertTrue(resolution.shouldPersist)
        assertEquals(false, resolution.record.isDolbyVision)
        assertEquals(true, resolution.record.isAtmos)
        assertFalse(resolution.record.localPlayable("file:///legacy.mkv").isDolbyVision)
        assertTrue(resolution.record.localPlayable("file:///legacy.mkv").isAtmos)
    }

    @Test
    fun `authentic legacy 4K probe resolves neither capability`() {
        val resolution = resolveLegacy(
            DownloadedMediaCapabilities(isDolbyVision = false, isAtmos = false),
        )

        assertTrue(resolution.shouldPersist)
        assertEquals(false, resolution.record.isDolbyVision)
        assertEquals(false, resolution.record.isAtmos)
    }

    @Test
    fun `authentic legacy 4K probe failure retains unknown and fails routing closed`() {
        var persistCalls = 0
        val legacy = requireNotNull(DownloadStore.recordFromJson(authenticLegacyJson()))
        val resolution = DownloadedMediaCapabilityResolver.resolve(
            record = legacy,
            file = File("legacy.mkv"),
            probe = DownloadedMediaCapabilityProbe { null },
            persistResolved = { persistCalls += 1 },
        )

        assertFalse(resolution.shouldPersist)
        assertEquals(0, persistCalls)
        assertNull(resolution.record.isDolbyVision)
        assertNull(resolution.record.isAtmos)
        assertFalse(resolution.record.localPlayable("file:///legacy.mkv").isDolbyVision)
        assertFalse(resolution.record.localPlayable("file:///legacy.mkv").isAtmos)
    }

    @Test
    fun `known new download skips local capability probe`() {
        var calls = 0
        val known = record(isDolbyVision = false, isAtmos = true)

        val resolution = DownloadedMediaCapabilityResolver.resolve(
            record = known,
            file = File("new-download.mkv"),
            probe = DownloadedMediaCapabilityProbe {
                calls += 1
                DownloadedMediaCapabilities(isDolbyVision = true, isAtmos = false)
            },
        )

        assertEquals(0, calls)
        assertFalse(resolution.shouldPersist)
        assertEquals(known, resolution.record)
    }

    @Test
    fun `mime evidence recognizes JOC but not ordinary TrueHD as Atmos`() {
        val joc = requireNotNull(
            downloadedMediaCapabilitiesFromMimeTypes(
                listOf("video/hevc", "audio/eac3-joc"),
            ),
        )
        val trueHd = requireNotNull(
            downloadedMediaCapabilitiesFromMimeTypes(
                listOf("video/hevc", "audio/true-hd"),
            ),
        )

        assertTrue(joc.isAtmos)
        assertFalse(trueHd.isAtmos)
    }
}
