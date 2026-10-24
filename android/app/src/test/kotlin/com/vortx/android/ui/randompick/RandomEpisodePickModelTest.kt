package com.vortx.android.ui.randompick

import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RandomEpisodePickModelTest {
    private data class Owner(val profile: String, val revision: Long = 1)

    private val clock = Instant.parse("2026-10-24T00:00:00Z")
    private val first = episode("first", 1)
    private val second = episode("second", 2)
    private val third = episode("third", 3)

    @Test
    fun `pick is preview only and excludes the selected episode when alternatives exist`() = runTest {
        val owner = Owner("A")
        val detail = detail(first, second, third)
        var reads = 0
        var actions = 0
        val model = RandomEpisodePickModel(
            scope = this,
            currentOwner = { owner },
            readDetail = { reads++; detail },
            currentEpisodeId = { first.id },
            now = { clock },
            nextInt = { 0 },
        )

        model.pick()
        assertTrue(model.state.value.loading)
        runCurrent()

        assertEquals(1, reads)
        assertEquals(second, model.state.value.episode)
        assertEquals("Fixture show", model.state.value.seriesName)
        assertEquals(0, actions)
        assertFalse(model.state.value.loading)
        model.forAction { acceptedDetail, acceptedEpisode, acceptedOwner ->
            actions++
            assertEquals(detail, acceptedDetail)
            assertEquals(second, acceptedEpisode)
            assertEquals(owner, acceptedOwner)
            assertNull(model.state.value.episode)
        }
        runCurrent()
        model.forAction { _, _, _ -> actions++ }
        runCurrent()

        assertEquals(2, reads)
        assertEquals(1, actions)
        assertNull(model.state.value.episode)
        assertFalse(model.state.value.loading)
    }

    @Test
    fun `pick again avoids the previous preview as well as the selected episode`() = runTest {
        val model = RandomEpisodePickModel(
            scope = this,
            currentOwner = { Owner("A") },
            readDetail = { detail(first, second, third) },
            currentEpisodeId = { first.id },
            now = { clock },
            nextInt = { 0 },
        )

        model.pick()
        runCurrent()
        assertEquals(second, model.state.value.episode)
        model.pick()
        runCurrent()
        assertEquals(third, model.state.value.episode)
    }

    @Test
    fun `a sole eligible selected episode remains pickable`() = runTest {
        val model = RandomEpisodePickModel(
            scope = this,
            currentOwner = { Owner("A") },
            readDetail = { detail(first) },
            currentEpisodeId = { first.id },
            now = { clock },
            nextInt = { 0 },
        )

        model.pick()
        runCurrent()

        assertEquals(first, model.state.value.episode)
    }

    @Test
    fun `a locked owner does not read inventory or dispatch an action`() = runTest {
        var reads = 0
        var actions = 0
        val model = RandomEpisodePickModel<Owner>(
            scope = this,
            currentOwner = { null },
            readDetail = { reads++; detail(first) },
            currentEpisodeId = { null },
            now = { clock },
        )

        model.pick()
        runCurrent()
        model.forAction { _, _, _ -> actions++ }
        runCurrent()

        assertEquals(0, reads)
        assertEquals(0, actions)
        assertNull(model.state.value.episode)
        assertEquals(RandomEpisodePickNotice.PROFILE_LOCKED, model.state.value.notice)
        assertFalse(model.state.value.loading)
    }

    @Test
    fun `late noncancellable pick cannot revive profile A after an A B A transition`() = runTest {
        val a = Owner("A")
        var owner: Owner? = a
        val late = CompletableDeferred<MetaDetail>()
        var reads = 0
        val model = RandomEpisodePickModel(
            scope = this,
            currentOwner = { owner },
            readDetail = {
                reads++
                if (reads == 1) withContext(NonCancellable) { late.await() } else detail(second)
            },
            currentEpisodeId = { null },
            now = { clock },
            nextInt = { 0 },
        )

        model.pick()
        runCurrent()
        owner = Owner("B")
        model.invalidate()
        owner = a
        model.invalidate()
        model.pick()
        runCurrent()
        assertEquals(second, model.state.value.episode)
        late.complete(detail(first))
        runCurrent()

        assertEquals(2, reads)
        assertEquals(second, model.state.value.episode)
        assertFalse(model.state.value.loading)
        assertNull(model.state.value.notice)
    }

    @Test
    fun `owner loss during a read clears loading without publishing its episode`() = runTest {
        var owner: Owner? = Owner("A")
        val result = CompletableDeferred<MetaDetail>()
        val model = RandomEpisodePickModel(
            scope = this,
            currentOwner = { owner },
            readDetail = { result.await() },
            currentEpisodeId = { null },
            now = { clock },
        )

        model.pick()
        runCurrent()
        owner = null
        result.complete(detail(first))
        runCurrent()

        assertNull(model.state.value.episode)
        assertFalse(model.state.value.loading)
        assertEquals(RandomEpisodePickNotice.PROFILE_LOCKED, model.state.value.notice)
    }

    @Test
    fun `fresh action inventory must retain the exact episode coordinates and series`() = runTest {
        val original = detail(first)
        var fresh = original
        var actions = 0
        val model = RandomEpisodePickModel(
            scope = this,
            currentOwner = { Owner("A") },
            readDetail = { fresh },
            currentEpisodeId = { null },
            now = { clock },
            nextInt = { 0 },
        )

        model.pick()
        runCurrent()
        fresh = original.copy(videos = listOf(first.copy(episode = 9)))
        model.forAction { _, _, _ -> actions++ }
        runCurrent()
        assertEquals(RandomEpisodePickNotice.PICK_UNAVAILABLE, model.state.value.notice)
        assertNull(model.state.value.episode)

        fresh = original
        model.pick()
        runCurrent()
        fresh = original.copy(id = "another-series")
        model.forAction { _, _, _ -> actions++ }
        runCurrent()
        assertEquals(RandomEpisodePickNotice.PICK_UNAVAILABLE, model.state.value.notice)
        assertEquals(0, actions)
    }

    @Test
    fun `an episode removed or made future dated after preview is not accepted`() = runTest {
        var fresh = detail(first)
        var actions = 0
        val model = RandomEpisodePickModel(
            scope = this,
            currentOwner = { Owner("A") },
            readDetail = { fresh },
            currentEpisodeId = { null },
            now = { clock },
            nextInt = { 0 },
        )

        model.pick()
        runCurrent()
        fresh = detail()
        model.forAction { _, _, _ -> actions++ }
        runCurrent()
        assertEquals(RandomEpisodePickNotice.PICK_UNAVAILABLE, model.state.value.notice)

        fresh = detail(first)
        model.pick()
        runCurrent()
        fresh = detail(first.copy(released = "2027-01-01T00:00:00Z"))
        model.forAction { _, _, _ -> actions++ }
        runCurrent()
        assertEquals(RandomEpisodePickNotice.PICK_UNAVAILABLE, model.state.value.notice)
        assertEquals(0, actions)
    }

    @Test
    fun `only the latest action request may dispatch even when an old read ignores cancellation`() = runTest {
        val late = CompletableDeferred<MetaDetail>()
        var reads = 0
        val calls = mutableListOf<String>()
        val model = RandomEpisodePickModel(
            scope = this,
            currentOwner = { Owner("A") },
            readDetail = {
                reads++
                if (reads == 2) withContext(NonCancellable) { late.await() } else detail(first)
            },
            currentEpisodeId = { null },
            now = { clock },
            nextInt = { 0 },
        )

        model.pick()
        runCurrent()
        model.forAction { _, _, _ -> calls += "old" }
        runCurrent()
        model.forAction { _, _, _ -> calls += "latest" }
        runCurrent()
        assertEquals(listOf("latest"), calls)
        late.complete(detail(first))
        runCurrent()

        assertEquals(3, reads)
        assertEquals(listOf("latest"), calls)
        assertNull(model.state.value.episode)
        assertFalse(model.state.value.loading)
    }

    @Test
    fun `invalidating an action prevents its late completion from dispatching after owner returns`() = runTest {
        val a = Owner("A")
        var owner: Owner? = a
        val late = CompletableDeferred<MetaDetail>()
        var reads = 0
        var actions = 0
        val model = RandomEpisodePickModel(
            scope = this,
            currentOwner = { owner },
            readDetail = {
                reads++
                if (reads == 2) withContext(NonCancellable) { late.await() } else detail(first)
            },
            currentEpisodeId = { null },
            now = { clock },
            nextInt = { 0 },
        )

        model.pick()
        runCurrent()
        model.forAction { _, _, _ -> actions++ }
        runCurrent()
        owner = Owner("B")
        model.invalidate()
        owner = a
        model.invalidate()
        late.complete(detail(first))
        runCurrent()

        assertEquals(0, actions)
        assertNull(model.state.value.episode)
        assertFalse(model.state.value.loading)
    }

    @Test
    fun `empty cache and failed reads expose only fixed notices`() = runTest {
        var fail = false
        val model = RandomEpisodePickModel(
            scope = this,
            currentOwner = { Owner("A") },
            readDetail = {
                if (fail) error("private provider detail must not reach UI")
                null
            },
            currentEpisodeId = { null },
            now = { clock },
        )

        model.pick()
        runCurrent()
        assertEquals(RandomEpisodePickNotice.EMPTY, model.state.value.notice)
        fail = true
        model.pick()
        runCurrent()

        assertEquals(RandomEpisodePickNotice.LOAD_ERROR, model.state.value.notice)
        assertNull(model.state.value.episode)
        assertFalse(model.state.value.loading)
    }

    @Test
    fun `cancellation clears current loading without being converted into an error notice`() = runTest {
        val model = RandomEpisodePickModel(
            scope = this,
            currentOwner = { Owner("A") },
            readDetail = { throw CancellationException("fixture cancellation") },
            currentEpisodeId = { null },
            now = { clock },
        )

        model.pick()
        runCurrent()

        assertNull(model.state.value.episode)
        assertNull(model.state.value.notice)
        assertFalse(model.state.value.loading)
    }

    @Test
    fun unknownDateSpecialEpisodeZeroStillUsesNormalConfirmedAction() = runTest {
        val special = Episode("special-zero", "Special zero", 0, 0, released = null)
        var fresh = detail(special)
        var actions = 0
        val model = RandomEpisodePickModel(
            scope = this,
            currentOwner = { Owner("A") },
            readDetail = { fresh },
            currentEpisodeId = { null },
            now = { clock },
        )
        model.pick()
        runCurrent()
        assertEquals(special, model.state.value.episode)
        assertEquals(0, actions)
        fresh = detail(special.copy(released = "unparseable"))
        model.forAction { _, accepted, _ ->
            assertEquals(0, accepted.season)
            assertEquals(0, accepted.episode)
            actions++
        }
        runCurrent()
        assertEquals(1, actions)
        assertNull(model.state.value.episode)
    }

    private fun episode(id: String, number: Int): Episode = Episode(
        id = id,
        title = "Episode $number",
        season = 1,
        episode = number,
        released = "2020-01-01T00:00:00Z",
    )

    private fun detail(vararg episodes: Episode): MetaDetail = MetaDetail(
        id = "fixture-show",
        type = MediaType.SERIES,
        name = "Fixture show",
        videos = episodes.toList(),
    )
}
