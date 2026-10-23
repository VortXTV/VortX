package com.vortx.android.foryou

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.time.LocalDate

/** The same scenarios as Apple `app/Tests/ForYouRowsModelTests.swift`, against a recording TMDB fake. */
@OptIn(ExperimentalCoroutinesApi::class)
class ForYouRowsModelTest {
    private val calls = mutableListOf<String>()
    private var empty = false
    private var rows = ForYouRows()

    private fun model(scope: TestScope) = ForYouRowsModel(
        scope = scope,
        ruleTitles = { movie, tv ->
            calls += "rule:${movie ?: "-"}|${tv ?: "-"}"
            if (empty) emptyList() else (1..5).map { MetaItem(id = "tt${calls.size}$it", type = MediaType.MOVIE, name = "T$it") }
        },
        personTitles = { id ->
            calls += "person:$id"
            if (empty) emptyList() else (1..3).map { MetaItem(id = "tp$id$it", type = MediaType.MOVIE, name = "P$it") }
        },
        today = { LocalDate.of(2026, 10, 13) },
        onRows = { rows = it },
    )

    @Test fun `rows follow the plan, refilter without refetching and retry an empty fetch`() = runTest(StandardTestDispatcher()) {
        val model = model(this)
        val interests = ForYouInterests(genres = listOf("scifi"), people = listOf(ForYouPerson(7, "Someone")), decided = true)
        val pinned = SmartCollection.make("Weekend dramas", SmartCollectionRules(genres = listOf("drama"), hideWatched = true), home = true)
        val libraryOnly = SmartCollection.make("Library only", SmartCollectionRules(), home = false)

        model.refresh("A", interests, listOf(pinned, libraryOnly), emptySet(), emptySet(), true)
        advanceUntilIdle()
        assertEquals(listOf("forYou.genre.scifi", "forYou.person.7"), rows.interest.map { it.plan.id })
        assertEquals(ForYouReason.INTERESTS, rows.interest[0].plan.reason)
        assertEquals(listOf("Weekend dramas"), rows.collections.map { it.collection.name })
        val fetched = calls.size
        assertEquals(3, fetched)

        val firstScifi = rows.interest[0].items[0].id
        val firstDrama = rows.collections[0].items[0].id
        model.refresh("A", interests, listOf(pinned, libraryOnly), setOf(firstScifi), setOf(firstDrama), true)
        advanceUntilIdle()
        assertEquals(fetched, calls.size)
        assertFalse(rows.interest[0].items.any { it.id == firstScifi })
        assertFalse(rows.collections[0].items.any { it.id == firstDrama })

        model.refresh("A", interests, listOf(pinned.copy(name = "Renamed")), emptySet(), emptySet(), true)
        advanceUntilIdle()
        assertEquals(fetched, calls.size)
        assertEquals(listOf("Renamed"), rows.collections.map { it.collection.name })

        model.refresh("A", interests, emptyList(), emptySet(), emptySet(), false)
        assertTrue(rows.interest.isEmpty() && rows.collections.isEmpty())

        empty = true
        model.refresh("B", interests, emptyList(), emptySet(), emptySet(), true)
        advanceUntilIdle()
        val afterEmpty = calls.size
        assertTrue(rows.interest.isEmpty())
        empty = false
        model.refresh("B", interests, emptyList(), emptySet(), emptySet(), true)
        advanceUntilIdle()
        assertEquals(afterEmpty + 2, calls.size)
        assertEquals(2, rows.interest.size)
    }

    @Test fun `collections retry only empty or failed raw rows and retain successful rows`() = runTest(StandardTestDispatcher()) {
        for (throws in listOf(false, true)) {
            var fetched = 0
            var published = ForYouRows()
            val first = SmartCollection.make("First", SmartCollectionRules(hideWatched = true), home = true)
            val retry = SmartCollection.make("Retry", SmartCollectionRules(), home = true)
            val last = SmartCollection.make("Last", SmartCollectionRules(), home = true)
            val collections = listOf(first, retry, last)
            val firstTitle = MetaItem("tt-first", MediaType.MOVIE, "First")
            val lastTitle = MetaItem("tt-last", MediaType.MOVIE, "Last")
            val recoveredTitle = MetaItem("tt-recovered", MediaType.MOVIE, "Recovered")
            val model = ForYouRowsModel(
                scope = this,
                ruleTitles = { _, _ ->
                    when (++fetched) {
                        1 -> listOf(firstTitle)
                        2 -> if (throws) throw IOException("temporary failure") else emptyList()
                        3 -> listOf(lastTitle)
                        4 -> listOf(recoveredTitle)
                        else -> error("A successful raw row was fetched again")
                    }
                },
                onRows = { published = it },
            )

            model.refresh("A", null, collections, emptySet(), emptySet(), true)
            advanceUntilIdle()
            assertEquals("No automatic retry, even when the row is empty", 3, fetched)
            assertEquals(listOf(first.id, last.id), published.collections.map { it.collection.id })

            model.refresh("A", null, collections, emptySet(), setOf(firstTitle.id), true)
            advanceUntilIdle()
            assertEquals("Only the missing raw row retries", 4, fetched)
            assertEquals(listOf(retry.id, last.id), published.collections.map { it.collection.id })
            assertEquals(recoveredTitle, published.collections.first().items.single())

            model.refresh("A", null, collections, emptySet(), emptySet(), true)
            advanceUntilIdle()
            assertEquals("A filtered-out success stays cached", 4, fetched)
            assertEquals(listOf(first.id, retry.id, last.id), published.collections.map { it.collection.id })
            assertEquals(firstTitle, published.collections.first().items.single())
        }
    }

    @Test fun `a canceled collection attempt stops and remains retryable on a later refresh`() = runTest(StandardTestDispatcher()) {
        var fetched = 0
        var published = ForYouRows()
        val collections = listOf(
            SmartCollection.make("First", SmartCollectionRules(), home = true),
            SmartCollection.make("Second", SmartCollectionRules(), home = true),
        )
        val model = ForYouRowsModel(
            scope = this,
            ruleTitles = { _, _ ->
                fetched++
                if (fetched == 1) throw CancellationException("request canceled")
                listOf(MetaItem("tt-$fetched", MediaType.MOVIE, "Recovered"))
            },
            onRows = { published = it },
        )

        model.refresh("A", null, collections, emptySet(), emptySet(), true)
        advanceUntilIdle()
        assertEquals("Cancellation does not continue fetching later rows", 1, fetched)
        assertTrue(published.collections.isEmpty())
        model.refresh("A", null, collections, emptySet(), emptySet(), true)
        advanceUntilIdle()
        assertEquals(3, fetched)
        assertEquals(collections.map { it.id }, published.collections.map { it.collection.id })
    }

    @Test fun `late canceled collections cannot publish or invalidate a replacement request after clear and ABA`() = runTest(StandardTestDispatcher()) {
        val retiredResult = CompletableDeferred<List<MetaItem>>()
        val currentResult = CompletableDeferred<List<MetaItem>>()
        var fetched = 0
        var published = ForYouRows()
        val collection = SmartCollection.make("Pinned", SmartCollectionRules(), home = true)
        val currentTitle = MetaItem("tt-current", MediaType.MOVIE, "Current")
        val model = ForYouRowsModel(
            scope = this,
            ruleTitles = { _, _ ->
                when (++fetched) {
                    1 -> withContext(NonCancellable) { retiredResult.await() }
                    2 -> currentResult.await()
                    else -> error("The current request was incorrectly invalidated")
                }
            },
            onRows = { published = it },
        )

        model.refresh("A", null, listOf(collection), emptySet(), emptySet(), true)
        runCurrent()
        model.clear()
        model.refresh("B", null, listOf(collection), emptySet(), emptySet(), true)
        model.refresh("A", null, listOf(collection), emptySet(), emptySet(), true)
        runCurrent()
        assertEquals(2, fetched)

        retiredResult.complete(listOf(MetaItem("tt-retired", MediaType.MOVIE, "Retired")))
        runCurrent()
        assertTrue("The retired owner must remain invisible", published.collections.isEmpty())
        model.refresh("A", null, listOf(collection), emptySet(), emptySet(), true)
        runCurrent()
        assertEquals("A retired finally block must not reset the replacement key", 2, fetched)

        currentResult.complete(listOf(currentTitle))
        advanceUntilIdle()
        assertEquals(currentTitle, published.collections.single().items.single())
        model.refresh("A", null, listOf(collection), emptySet(), emptySet(), true)
        advanceUntilIdle()
        assertEquals(2, fetched)
    }
}
