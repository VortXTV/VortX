package com.vortx.android.downloads

import com.vortx.android.debrid.DebridAccountOwnerBinding
import com.vortx.android.debrid.DebridAccountOwnerState
import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import com.vortx.android.sync.DurableSessionState
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class DownloadPlaybackRoutingTest {

    private val testOwner = com.vortx.android.model.PlaybackContext.Owner(
        profileId = "owner-profile",
        usesEngineHistory = true,
    )

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
            .localPlayable("file:///downloads/movie.mkv", owner = testOwner)

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
    fun `durable debrid owner epoch keeps an account download valid after process restart`() {
        var durableSession: String? = "account-a"
        var durableEpoch = 17L
        fun restartSession(): DurableSessionState<String> = DurableSessionState(
            initialValue = durableSession,
            initialOwnerEpoch = durableEpoch,
            persist = { session, nextEpoch ->
                durableSession = session
                durableEpoch = nextEpoch
                true
            },
            clear = { nextEpoch ->
                durableSession = null
                durableEpoch = nextEpoch
                true
            },
        )

        val firstProcess = restartSession()
        val persistedDownload = requireNotNull(
            DownloadStore.recordFromJson(
                DownloadStore.recordToJson(
                    record().copy(
                        debridOwnerIdentity = "account:${firstProcess.value}",
                        debridOwnerGeneration = firstProcess.ownerEpoch,
                    ),
                ),
            ),
        )
        val restartedProcess = restartSession()
        val restartedBinding = DebridAccountOwnerBinding().apply {
            bind {
                DebridAccountOwnerState.Account(
                    id = requireNotNull(restartedProcess.value),
                    generation = restartedProcess.ownerEpoch,
                )
            }
        }
        val restartedOwner = requireNotNull(restartedBinding.currentOwner())

        assertEquals(17L, restartedProcess.ownerEpoch)
        assertTrue(
            DownloadDebridOwnerPolicy.isCurrent(
                persistedDownload.debridOwnerIdentity,
                persistedDownload.debridOwnerGeneration,
                DownloadDebridOwnerPolicy.Owner(
                    identity = restartedOwner.identity,
                    generation = restartedOwner.generation,
                ),
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
            readOwnerStatus = {
                DownloadDebridOwnerPolicy.status(
                    it.debridOwnerIdentity,
                    it.debridOwnerGeneration,
                ) { currentOwner }
            },
        )

        assertEquals(DownloadTransferClaimDecision.OwnerChanged, decision)
    }

    @Test
    fun `first unavailable read inside locked claim is retryable and cannot become changed on a second read`() {
        val row = record().copy(
            state = DownloadState.DOWNLOADING,
            transferGeneration = "live-generation",
            debridOwnerIdentity = "account:account-a",
            debridOwnerGeneration = 7,
        )
        var reads = 0
        val binding = DebridAccountOwnerBinding().apply {
            bind {
                if (++reads == 1) {
                    DebridAccountOwnerState.UnknownOrUnavailable
                } else {
                    DebridAccountOwnerState.Account("account-b", 8)
                }
            }
        }
        val decision = DownloadTransferClaimPolicy.decide(row, "live-generation") {
            DownloadDebridOwnerPolicy.status(it.debridOwnerIdentity, it.debridOwnerGeneration) {
                binding.currentOwner()?.let { owner ->
                    DownloadDebridOwnerPolicy.Owner(owner.identity, owner.generation)
                }
            }
        }

        assertEquals(DownloadTransferClaimDecision.OwnerUnavailable, decision)
        assertEquals(1, reads)
    }

    @Test
    fun `ownerless transfers are eligible without reading account persistence`() {
        val owner = DownloadDebridOwnerPolicy.status(null, null) {
            error("Direct transfer tried to read account persistence")
        }

        assertEquals(DownloadDebridOwnerPolicy.Status.CURRENT, owner)
    }

    @Test
    fun `bound row distinguishes unavailable same owner and confirmed different owner`() {
        val matching = DownloadDebridOwnerPolicy.Owner("account:account-a", 7)
        val changedEpoch = matching.copy(generation = 8)
        val signedOut = DownloadDebridOwnerPolicy.Owner("local", 8)
        fun read(owner: DownloadDebridOwnerPolicy.Owner?) =
            DownloadDebridOwnerPolicy.status(matching.identity, matching.generation) { owner }

        assertEquals(DownloadDebridOwnerPolicy.Status.UNAVAILABLE, read(null))
        assertEquals(DownloadDebridOwnerPolicy.Status.CURRENT, read(matching))
        assertEquals(DownloadDebridOwnerPolicy.Status.CHANGED, read(changedEpoch))
        assertEquals(DownloadDebridOwnerPolicy.Status.CHANGED, read(signedOut))
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
            readOwnerStatus = {
                ownerChecks += 1
                DownloadDebridOwnerPolicy.Status.CHANGED
            },
        )

        assertEquals(DownloadTransferClaimDecision.Rejected, decision)
        assertEquals(0, ownerChecks)
    }

    @Test
    fun `genuine transfer retry budget survives index round trip and old rows default to zero`() {
        val row = record().copy(transferGeneration = "active", transferRetryCount = 1)
        val restored = requireNotNull(DownloadStore.recordFromJson(DownloadStore.recordToJson(row)))
        val legacy = requireNotNull(DownloadStore.recordFromJson(authenticLegacyJson()))

        assertEquals(1, restored.transferRetryCount)
        assertFalse(DownloadTransferPolicy.canRetryWrite(restored.transferRetryCount))
        assertEquals(0, legacy.transferRetryCount)
        assertTrue(DownloadTransferPolicy.canRetryWrite(legacy.transferRetryCount))
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
        assertTrue(resolution.record.localPlayable("file:///legacy.mkv", owner = testOwner).isDolbyVision)
        assertFalse(resolution.record.localPlayable("file:///legacy.mkv", owner = testOwner).isAtmos)
    }

    @Test
    fun `authentic legacy 4K probe persists positive Atmos and leaves Dolby Vision unknown`() {
        val resolution = resolveLegacy(
            DownloadedMediaCapabilities(isDolbyVision = null, isAtmos = true),
        )

        assertTrue(resolution.shouldPersist)
        assertNull(resolution.record.isDolbyVision)
        assertEquals(true, resolution.record.isAtmos)
        assertFalse(resolution.record.localPlayable("file:///legacy.mkv", owner = testOwner).isDolbyVision)
        assertTrue(resolution.record.localPlayable("file:///legacy.mkv", owner = testOwner).isAtmos)
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
        assertFalse(resolution.record.localPlayable("file:///legacy.mkv", owner = testOwner).isDolbyVision)
        assertFalse(resolution.record.localPlayable("file:///legacy.mkv", owner = testOwner).isAtmos)
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
