package com.vortx.android.downloads

import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadedSeasonBoundaryTest {
    private val imdb = "tt0123456"
    private val tmdb = 123
    private val series = "/tv/$tmdb?append_to_response=external_ids"
    private val find = "/find/$imdb?external_source=imdb_id"
    private val season1 = "/tv/$tmdb/season/1"
    private val season2 = "/tv/$tmdb/season/2"

    @Test fun exactCanonicalPairSurvivesIndexRoundTripAndQueuedNextFirst() = runBlocking {
        val origin = record("origin", imdb, 1, 2)
        val next = record("next", imdb, 2, 1, state = DownloadState.QUEUED)
        val proof = requireNotNull(resolve(origin, next, endpoints()).single())
        assertEquals(102, proof.finalTmdbEpisodeId)
        assertEquals(201, proof.firstTmdbEpisodeId)
        val index = DownloadStore.recordToJson(origin.copy(seasonBoundary = proof))
        assertEquals(proof, DownloadStore.recordFromJson(index)?.seasonBoundary)
        index.getJSONObject("seasonBoundary").put("finalEpisode", "2")
        assertNull(DownloadStore.recordFromJson(index)?.seasonBoundary)
        index.remove("seasonBoundary")
        assertNull(DownloadStore.recordFromJson(index)?.seasonBoundary)
    }

    @Test fun tmdbRouteMayKeepExactImdbVideoIdsWithoutGuessingAliases() = runBlocking {
        val origin = record("origin", "tmdb:$tmdb", 1, 2)
        val next = record("next", "tmdb:$tmdb", 2, 1)
        assertEquals(next.videoId, resolve(origin, next, endpoints() - find).single()?.nextVideoId)
        val typedOrigin = origin.copy(contentId = "tmdb:tv:$tmdb", videoId = "tmdb:tv:$tmdb:1:2")
        val typedNext = next.copy(contentId = "tmdb:tv:$tmdb", videoId = "tmdb:tv:$tmdb:2:1")
        assertEquals(typedNext.videoId, resolve(typedOrigin, typedNext, endpoints() - find).single()?.nextVideoId)
        assertTrue(resolve(origin, next.copy(videoId = "addon:2:1"), endpoints() - find).isEmpty())
        assertTrue(resolve(origin, next.copy(contentId = "another"), endpoints() - find).isEmpty())
    }

    @Test fun partialOrContradictoryEvidenceNeverCreatesABoundary() = runBlocking {
        val origin = record("origin", imdb, 1, 2)
        val next = record("next", imdb, 2, 1)
        val incomplete = endpoints().also { it.getValue(season1).getJSONArray("episodes").remove(1) }
        val duplicate = endpoints().also {
            it.getValue(season1).getJSONArray("episodes").getJSONObject(1).put("episode_number", 1)
        }
        val wrongSeason = endpoints().also { it.getValue(season2).put("id", 999) }
        val missingEpisodeId = endpoints().also {
            it.getValue(season2).getJSONArray("episodes").getJSONObject(0).remove("id")
        }
        val missingEpisodeShow = endpoints().also {
            it.getValue(season2).getJSONArray("episodes").getJSONObject(0).remove("show_id")
        }
        val wrongEpisodeShow = endpoints().also {
            it.getValue(season2).getJSONArray("episodes").getJSONObject(0).put("show_id", 999)
        }
        val crossSeasonId = endpoints().also {
            it.getValue(season2).getJSONArray("episodes").getJSONObject(0).put("id", 102)
        }
        val wrongAccountlessTitle = endpoints().also {
            it.getValue(series).getJSONObject("external_ids").put("imdb_id", "tt7654321")
        }
        val ambiguous = endpoints().also { it.getValue(find).getJSONArray("tv_results").put(JSONObject().put("id", 999)) }
        for (response in listOf(incomplete, duplicate, wrongSeason, missingEpisodeId, missingEpisodeShow,
            wrongEpisodeShow, crossSeasonId, wrongAccountlessTitle, ambiguous)
        ) {
            assertTrue(resolve(origin, next, response).isEmpty())
        }
    }

    @Test fun twoBoundariesShareTheMiddleSeasonResponse() = runBlocking {
        val from1 = record("from1", imdb, 1, 2)
        val from2 = record("from2", imdb, 2, 2)
        val rows = listOf(from1, record("first2", imdb, 2, 1), from2, record("first3", imdb, 3, 1))
        val response = endpoints().toMutableMap().also {
            it.getValue(series).getJSONArray("seasons").put(descriptor(3, 33, 2))
            it["/tv/$tmdb/season/3"] = season(3, 33, 301, 302)
        }
        val requests = mutableListOf<String>()
        val proof = mutableListOf<DownloadedSeasonBoundary?>()
        resolveDownloadedSeasonBoundaries(imdb, listOf(from1, from2), rows.groupBy { it.season },
            { path -> requests += path; response[path] },
        ) { _, boundary -> proof += boundary }
        assertEquals(listOf(201, 301), proof.map { it?.firstTmdbEpisodeId })
        assertEquals(listOf(find, series, season1, season2, "/tv/$tmdb/season/3"), requests)
    }

    @Test fun positiveContradictionRevokesExistingProofButTransportFailurePreservesIt() = runBlocking {
        val origin = record("origin", imdb, 1, 2)
        val next = record("next", imdb, 2, 1)
        val proof = requireNotNull(resolve(origin, next, endpoints()).single())
        val retained = origin.copy(seasonBoundary = proof)
        val longer = endpoints().also {
            it.getValue(series).getJSONArray("seasons").getJSONObject(0).put("episode_count", 3)
        }
        assertEquals(listOf<DownloadedSeasonBoundary?>(null), resolve(retained, next, longer))
        assertTrue(resolve(retained, next, endpoints() - season2).isEmpty())
    }

    @Test fun observedPredecessorContradictionRevokesBeforeMissingSuccessor() = runBlocking {
        val origin = record("origin", imdb, 1, 2)
        val next = record("next", imdb, 2, 1)
        val proof = requireNotNull(resolve(origin, next, endpoints()).single())
        val retained = origin.copy(seasonBoundary = proof)
        val wrongShow = endpoints().also {
            it.getValue(season1).getJSONArray("episodes").getJSONObject(1).put("show_id", 999)
        } - season2
        val changedEpisodeId = endpoints().also {
            it.getValue(season1).getJSONArray("episodes").getJSONObject(1).put("id", 103)
        } - season2
        assertEquals(listOf<DownloadedSeasonBoundary?>(null), resolve(retained, next, wrongShow))
        assertEquals(listOf<DownloadedSeasonBoundary?>(null), resolve(retained, next, changedEpisodeId))
    }

    @Test fun observedSuccessorContradictionRevokesEvenWhenPredecessorIsUnavailable() = runBlocking {
        val origin = record("origin", imdb, 1, 2)
        val first2 = record("first2", imdb, 2, 1)
        val proof = requireNotNull(resolve(origin, first2, endpoints()).single())
        val retained = origin.copy(seasonBoundary = proof)
        val changedFirst = endpoints().also {
            it.getValue(season2).getJSONArray("episodes").getJSONObject(0).put("id", 203)
        } - season1
        assertEquals(listOf<DownloadedSeasonBoundary?>(null), resolve(retained, first2, changedFirst))
        assertTrue(resolve(retained, first2, endpoints() - season1).isEmpty())

        val newer = record("newer", imdb, 2, 2)
        val first3 = record("first3", imdb, 3, 1)
        val response = changedFirst.toMutableMap().also {
            it.getValue(series).getJSONArray("seasons").put(descriptor(3, 33, 2))
            it["/tv/$tmdb/season/3"] = season(3, 33, 301, 302)
        }
        val paths = mutableListOf<String>()
        val updates = mutableListOf<Pair<String, DownloadedSeasonBoundary?>>()
        resolveDownloadedSeasonBoundaries(imdb, listOf(newer, retained),
            listOf(newer, retained, first2, first3).groupBy { it.season },
            { path -> paths += path; response[path] },
        ) { record, boundary -> updates += record.id to boundary }
        assertEquals(listOf("newer", "origin"), updates.map { it.first })
        assertEquals(301, updates.first().second?.firstTmdbEpisodeId)
        assertNull(updates.last().second)
        assertEquals(1, paths.count { it == season2 })
    }

    @Test fun ambiguousLocalSuccessorDoesNotHideKnownCountContradiction() = runBlocking {
        val origin = record("origin", imdb, 1, 2)
        val next = record("next", imdb, 2, 1)
        val proof = requireNotNull(resolve(origin, next, endpoints()).single())
        val retained = origin.copy(seasonBoundary = proof)
        val conflicting = next.copy(id = "conflicting", videoId = "tmdb:$tmdb:2:1")
        val response = endpoints().also {
            it.getValue(series).getJSONArray("seasons").getJSONObject(0).put("episode_count", 3)
        } - season1 - season2
        assertEquals(listOf<DownloadedSeasonBoundary?>(null), resolve(retained, next, response, conflicting))
    }

    @Test fun authoritativeAliasChangeRevokesEvenWhenNewWitnessCannotBeMade() = runBlocking {
        val next = record("next", imdb, 2, 1)
        val origin = record("origin", imdb, 1, 2)
        val original = requireNotNull(resolve(origin, next, endpoints()).single())
        val changedLookup = endpoints().also {
            it.getValue(find).getJSONArray("tv_results").getJSONObject(0).put("id", 456)
        } - series
        assertEquals(listOf<DownloadedSeasonBoundary?>(null),
            resolve(origin.copy(seasonBoundary = original), next, changedLookup))
        assertTrue(resolve(origin.copy(seasonBoundary = original), next, endpoints() - find).isEmpty())

        val tmdbOrigin = origin.copy(contentId = "tmdb:$tmdb")
        val tmdbNext = next.copy(contentId = "tmdb:$tmdb")
        val tmdbProof = requireNotNull(resolve(tmdbOrigin, tmdbNext, endpoints() - find).single())
        val changedImdb = endpoints().also {
            it.getValue(series).getJSONObject("external_ids").put("imdb_id", "tt7654321")
        } - find - season1 - season2
        assertEquals(listOf<DownloadedSeasonBoundary?>(null),
            resolve(tmdbOrigin.copy(seasonBoundary = tmdbProof), tmdbNext, changedImdb))
    }

    @Test fun handoffStaysBoundToPhysicalNextAndRejectsNewContradictoryRows() = runBlocking {
        val origin = record("origin", imdb, 1, 2)
        val next = record("next", imdb, 2, 1)
        val proof = requireNotNull(resolve(origin, next, endpoints()).single())
        val retained = origin.copy(seasonBoundary = proof)
        val handoff = DownloadedRollover(DownloadedSeasonFile(origin), DownloadedSeasonFile(next), proof)
        assertTrue(handoff.isCurrent(listOf(retained, next)))
        assertTrue(handoff.isCurrent(listOf(next))) // exact ended origin may be reclaimed after admission
        assertFalse(handoff.isCurrent(listOf(origin, next))) // live origin's proof was revoked
        assertFalse(handoff.isCurrent(listOf(retained, next.copy(id = "replacement"))))
        assertFalse(handoff.isCurrent(listOf(retained, next.copy(addedAt = next.addedAt + 1))))
        assertFalse(handoff.isCurrent(listOf(retained.copy(addedAt = retained.addedAt + 1), next)))
        assertFalse(handoff.isCurrent(listOf(retained, next.copy(state = DownloadState.PAUSED))))
        assertFalse(handoff.isCurrent(listOf(retained, next, record("late", imdb, 1, 3, state = DownloadState.QUEUED))))
        assertFalse(handoff.isCurrent(listOf(retained, next, next.copy(id = "ambiguous", videoId = "another:2:1"))))
    }

    @Test fun canonicalLaterEpisodeRevokesProofInUpsertAndRemovalCannotReviveIt() = runBlocking {
        val origin = record("00000000-0000-0000-0000-000000000001", imdb, 1, 2)
        val next = record("00000000-0000-0000-0000-000000000002", imdb, 2, 1)
        val proof = requireNotNull(resolve(origin, next, endpoints()).single())
        val retained = origin.copy(seasonBoundary = proof)
        val initial = listOf(retained, next)
        val later = record("00000000-0000-0000-0000-000000000003", imdb, 1, 3, state = DownloadState.QUEUED)
        for (unproven in listOf(later.copy(videoId = "private:1:3"),
            later.copy(contentId = "tt7654321"), later.copy(season = 2, videoId = "$imdb:2:3"))
        ) {
            assertFalse(proof.isDisprovedByLaterEpisode(unproven))
            assertEquals(proof, downloadIndexAfterUpsert(initial, unproven).single { it.id == origin.id }.seasonBoundary)
        }
        val confirmedAlias = later.copy(videoId = "tmdb:tv:$tmdb:1:3")
        assertTrue(proof.isDisprovedByLaterEpisode(confirmedAlias))
        val inserted = downloadIndexAfterUpsert(initial, confirmedAlias)
        assertEquals(listOf(later.id, origin.id, next.id), inserted.map { it.id })
        assertNull(inserted.single { it.id == origin.id }.seasonBoundary)
        val afterRemoval = inserted.filterNot { it.id == later.id }
        val reopened = DownloadStore.decodeIndexRecords(JSONArray(afterRemoval.map(DownloadStore::recordToJson)).toString())
        assertNull(reopened.single { it.id == origin.id }.seasonBoundary)
        assertEquals(next, reopened.single { it.id == next.id })
    }

    @Test fun sameTitleRouteABAAndPhysicalRecordABARevokeOldWrites() {
        val fence = DownloadedSeasonBoundaryRefreshFence()
        val originalRequest = fence.begin()
        assertTrue(fence.isCurrent(originalRequest))
        fence.invalidate()
        val currentRequest = fence.begin()
        assertFalse(fence.isCurrent(originalRequest))
        assertTrue(fence.isCurrent(currentRequest))
        val queued = record("file", imdb, 1, 2, state = DownloadState.QUEUED)
        val placement = DownloadedSeasonFile(queued)
        assertTrue(placement.matches(queued.copy(state = DownloadState.COMPLETED)))
        assertFalse(placement.matches(queued.copy(addedAt = queued.addedAt + 1)))
        assertFalse(placement.matches(queued.copy(localFilename = "replaced.mp4")))
    }

    private suspend fun resolve(origin: DownloadRecord, next: DownloadRecord, responses: Map<String, JSONObject>,
        vararg additional: DownloadRecord,
    ) = mutableListOf<DownloadedSeasonBoundary?>().also { result ->
        val rows = (listOf(origin, next) + additional).filter { it.contentId == origin.contentId }.groupBy { it.season }
        var expected = origin
        resolveDownloadedSeasonBoundaries(origin.contentId, listOf(origin), rows, { path -> responses[path] }) { found, proof ->
            assertEquals(expected, found)
            expected = expected.copy(seasonBoundary = proof)
            result += proof
        }
    }

    private fun endpoints() = mapOf(
        find to JSONObject().put("tv_results", JSONArray().put(JSONObject().put("id", tmdb))),
        series to JSONObject().put("id", tmdb).put("external_ids", JSONObject().put("imdb_id", imdb))
            .put("seasons", JSONArray().put(descriptor(1, 11, 2)).put(descriptor(2, 22, 2))),
        season1 to season(1, 11, 101, 102),
        season2 to season(2, 22, 201, 202),
    )

    private fun descriptor(number: Int, id: Int, count: Int) =
        JSONObject().put("season_number", number).put("id", id).put("episode_count", count)

    private fun season(number: Int, id: Int, vararg episodeIds: Int) =
        JSONObject().put("season_number", number).put("id", id).put("episodes", JSONArray().also { out ->
            episodeIds.forEachIndexed { index, episodeId ->
                out.put(JSONObject().put("season_number", number).put("episode_number", index + 1)
                    .put("id", episodeId).put("show_id", tmdb))
            }
        })

    private fun record(id: String, title: String, season: Int, episode: Int,
        state: DownloadState = DownloadState.COMPLETED,
    ) = DownloadRecord(id = id, contentId = title, videoId = "$imdb:$season:$episode", type = "series",
        name = "Fixture", season = season, episode = episode, remoteURL = "https://example.invalid/video",
        localFilename = "$id.mp4", state = state)
}
