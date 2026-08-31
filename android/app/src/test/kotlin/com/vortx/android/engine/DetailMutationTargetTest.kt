package com.vortx.android.engine

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.Episode
import com.vortx.android.data.ContinueWatchingOwner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import java.util.concurrent.atomic.AtomicBoolean

class DetailMutationTargetTest {
    private fun detail(id: String, type: MediaType = MediaType.MOVIE) =
        MetaDetail(id = id, type = type, name = "Fixture")

    @Test
    fun `mutation target requires the exact resident title id`() {
        assertTrue(matchesDetailMutationTarget(detail("tt001"), MediaType.MOVIE, "tt001"))
        assertFalse(matchesDetailMutationTarget(detail("tt002"), MediaType.MOVIE, "tt001"))
    }

    @Test
    fun `mutation target rejects same id with a different media type`() {
        assertFalse(matchesDetailMutationTarget(detail("shared", MediaType.SERIES), MediaType.MOVIE, "shared"))
        assertFalse(matchesDetailMutationTarget(null, MediaType.MOVIE, "tt001"))
    }

    @Test
    fun `detail updates include watched meta details broadcasts`() {
        assertTrue(isDetailStateUpdate(setOf(EngineActions.FIELD_META_DETAILS)))
        assertTrue(isDetailStateUpdate(setOf(EngineActions.FIELD_LIBRARY)))
        assertFalse(isDetailStateUpdate(setOf(EngineActions.FIELD_PLAYER)))
    }

    @Test
    fun `whole series action plan is deterministic`() {
        val detail = detail("tt001", MediaType.SERIES).copy(
            videos = listOf(
                Episode("s2e1", "S2E1", 2, 1),
                Episode("s1e2", "S1E2", 1, 2),
                Episode("s1e1b", "S1E1B", 1, 1),
                Episode("s1e1a", "S1E1A", 1, 1),
            ),
        )

        assertEquals(listOf("s1e1a", "s1e1b", "s1e2", "s2e1"), wholeSeriesWatchedVideos(detail).map { it.id })
    }

    @Test
    fun `competing detail refind cannot replace resident target between validation and action`() = runBlocking {
        val gate = MetaDetailsTransactionGate()
        var resident = "tt-a"
        val validated = AtomicBoolean(false)
        val allowAction = AtomicBoolean(false)
        val actions = mutableListOf<String>()

        val mutation = async {
            gate.exclusive {
                assertTrue(validated.compareAndSet(false, true))
                while (!allowAction.get()) yield()
                assertTrue(resident == "tt-a")
                actions += resident
            }
        }
        while (!validated.get()) yield()

        val refind = async {
            gate.exclusive { resident = "tt-b" }
        }
        yield()
        assertFalse("Re-find must wait until the mutation action is complete", refind.isCompleted)

        allowAction.set(true)
        mutation.await()
        refind.await()
        assertTrue(actions == listOf("tt-a"))
        assertTrue(resident == "tt-b")
    }

    @Test
    fun `owner and overlay mutation transactions retain their Result outcome`() = runBlocking {
        val gate = MetaDetailsTransactionGate()
        val owner = ContinueWatchingOwner("owner", "primary", "account", true, 1L)
        val overlay = ContinueWatchingOwner("guest", "primary", "account", false, 1L)

        val ownerResult = runCatchingPreservingCancellation {
            gate.exclusive { "${owner.profileId}:${owner.usesEngineHistory}" }
        }
        val overlayResult = runCatchingPreservingCancellation {
            gate.exclusive { "${overlay.profileId}:${overlay.usesEngineHistory}" }
        }
        val failedTarget = runCatchingPreservingCancellation {
            gate.exclusive {
                check(matchesDetailMutationTarget(detail("tt-other"), MediaType.MOVIE, "tt-requested"))
            }
        }

        assertEquals("owner:true", ownerResult.getOrThrow())
        assertEquals("guest:false", overlayResult.getOrThrow())
        assertTrue(failedTarget.isFailure)
    }
}
