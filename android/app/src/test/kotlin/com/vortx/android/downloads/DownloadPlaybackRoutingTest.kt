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
    fun `active transfer generation survives index round trip`() {
        val decoded = DownloadStore.recordFromJson(
            DownloadStore.recordToJson(
                record().copy(
                    state = DownloadState.DOWNLOADING,
                    transferGeneration = "opaque-generation",
                    representationETag = "\"representation-v1\"",
                ),
            ),
        )

        assertEquals("opaque-generation", decoded?.transferGeneration)
        assertEquals("\"representation-v1\"", decoded?.representationETag)
        assertNull(DownloadStore.recordFromJson(authenticLegacyJson())?.transferGeneration)
        assertNull(DownloadStore.recordFromJson(authenticLegacyJson())?.representationETag)
    }

    @Test
    fun `debrid owner survives index round trip and fences another generation`() {
        val decoded = requireNotNull(
            DownloadStore.recordFromJson(
                DownloadStore.recordToJson(
                    record().copy(
                        debridOwnerIdentity = "account:account-a",
                        debridOwnerGeneration = 7,
                    ),
                ),
            ),
        )

        assertEquals("account:account-a", decoded.debridOwnerIdentity)
        assertEquals(7L, decoded.debridOwnerGeneration)
        assertTrue(
            DownloadDebridOwnerPolicy.isCurrent(
                decoded.debridOwnerIdentity,
                decoded.debridOwnerGeneration,
                DownloadDebridOwnerPolicy.Owner("account:account-a", 7),
            ),
        )
        assertFalse(
            DownloadDebridOwnerPolicy.isCurrent(
                decoded.debridOwnerIdentity,
                decoded.debridOwnerGeneration,
                DownloadDebridOwnerPolicy.Owner("account:account-b", 8),
            ),
        )
    }

    @Test
    fun `legacy ownerless index stays schema compatible but partial owner fails closed`() {
        val legacy = requireNotNull(DownloadStore.recordFromJson(authenticLegacyJson()))

        assertNull(legacy.debridOwnerIdentity)
        assertNull(legacy.debridOwnerGeneration)
        assertTrue(DownloadDebridOwnerPolicy.isCurrent(null, null, current = null))
        assertFalse(
            DownloadDebridOwnerPolicy.isCurrent(
                expectedIdentity = "account:account-a",
                expectedGeneration = null,
                current = DownloadDebridOwnerPolicy.Owner("account:account-a", 1),
            ),
        )
    }

    @Test
    fun `owner transition between worker precheck and locked claim rejects the fresh record`() {
        val ownerBound = record().copy(
            state = DownloadState.QUEUED,
            transferGeneration = "generation-a",
            debridOwnerIdentity = "account:account-a",
            debridOwnerGeneration = 7,
        )
        var currentOwner = DownloadDebridOwnerPolicy.Owner("account:account-a", 7)

        assertTrue(
            DownloadDebridOwnerPolicy.isCurrent(
                ownerBound.debridOwnerIdentity,
                ownerBound.debridOwnerGeneration,
                currentOwner,
            ),
        )

        currentOwner = DownloadDebridOwnerPolicy.Owner("account:account-b", 8)
        val decision = DownloadTransferClaimPolicy.decide(
            record = ownerBound,
            requestedGeneration = "generation-a",
            isOwnerCurrent = {
                DownloadDebridOwnerPolicy.isCurrent(
                    it.debridOwnerIdentity,
                    it.debridOwnerGeneration,
                    currentOwner,
                )
            },
        )

        assertEquals(DownloadTransferClaimDecision.OwnerChanged, decision)
    }

    @Test
    fun `terminal stale work is rejected before an owner mismatch can rewrite its state`() {
        var ownerChecks = 0
        val decision = DownloadTransferClaimPolicy.decide(
            record = record().copy(
                state = DownloadState.COMPLETED,
                transferGeneration = null,
                debridOwnerIdentity = "account:account-a",
                debridOwnerGeneration = 7,
            ),
            requestedGeneration = "obsolete-generation",
            isOwnerCurrent = {
                ownerChecks += 1
                false
            },
        )

        assertEquals(DownloadTransferClaimDecision.Rejected, decision)
        assertEquals(0, ownerChecks)
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
    fun `authentic legacy 4K probe persists positive Dolby Vision and leaves Atmos unknown`() {
        var persisted: DownloadRecord? = null
        val legacy = requireNotNull(DownloadStore.recordFromJson(authenticLegacyJson()))
        val resolution = DownloadedMediaCapabilityResolver.resolve(
            record = legacy,
            file = File("legacy.mkv"),
            probe = DownloadedMediaCapabilityProbe {
                DownloadedMediaCapabilities(isDolbyVision = true, isAtmos = null)
            },
            persistResolved = { persisted = it },
        )

        assertTrue(resolution.shouldPersist)
        assertEquals(resolution.record, persisted)
        assertEquals(true, resolution.record.isDolbyVision)
        assertNull(resolution.record.isAtmos)
        assertTrue(resolution.record.localPlayable("file:///legacy.mkv").isDolbyVision)
        assertFalse(resolution.record.localPlayable("file:///legacy.mkv").isAtmos)
    }

    @Test
    fun `authentic legacy 4K probe persists positive Atmos and leaves Dolby Vision unknown`() {
        val resolution = resolveLegacy(
            DownloadedMediaCapabilities(isDolbyVision = null, isAtmos = true),
        )

        assertTrue(resolution.shouldPersist)
        assertNull(resolution.record.isDolbyVision)
        assertEquals(true, resolution.record.isAtmos)
        assertFalse(resolution.record.localPlayable("file:///legacy.mkv").isDolbyVision)
        assertTrue(resolution.record.localPlayable("file:///legacy.mkv").isAtmos)
    }

    @Test
    fun `inconclusive successful probe retains unknown and does not persist false`() {
        var persistCalls = 0
        val legacy = requireNotNull(DownloadStore.recordFromJson(authenticLegacyJson()))
        val resolution = DownloadedMediaCapabilityResolver.resolve(
            record = legacy,
            file = File("legacy.mkv"),
            probe = DownloadedMediaCapabilityProbe {
                DownloadedMediaCapabilities(isDolbyVision = null, isAtmos = null)
            },
            persistResolved = { persistCalls += 1 },
        )

        assertFalse(resolution.shouldPersist)
        assertEquals(0, persistCalls)
        assertNull(resolution.record.isDolbyVision)
        assertNull(resolution.record.isAtmos)
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
                DownloadedMediaCapabilities(isDolbyVision = true, isAtmos = null)
            },
        )

        assertEquals(0, calls)
        assertFalse(resolution.shouldPersist)
        assertEquals(known, resolution.record)
    }

    @Test
    fun `mime evidence recognizes JOC but keeps ordinary EAC3 and TrueHD inconclusive`() {
        val joc = requireNotNull(
            downloadedMediaCapabilitiesFromMimeTypes(
                listOf("video/hevc", "audio/eac3-joc"),
            ),
        )
        val eac3 = requireNotNull(
            downloadedMediaCapabilitiesFromMimeTypes(
                listOf("video/hevc", "audio/eac3"),
            ),
        )
        val trueHd = requireNotNull(
            downloadedMediaCapabilitiesFromMimeTypes(
                listOf("video/hevc", "audio/true-hd"),
            ),
        )

        assertEquals(true, joc.isAtmos)
        assertNull(eac3.isAtmos)
        assertNull(trueHd.isAtmos)
        assertNull(trueHd.isDolbyVision)
    }
}
