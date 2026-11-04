package com.vortx.android.integrations

import com.vortx.android.integrations.ProviderWatchlistReceipt.Operation
import com.vortx.android.integrations.ProviderWatchlistReceipt.Outcome
import org.junit.Assert.assertEquals
import org.junit.Test

class ProviderWatchlistReceiptTest {
    private val traktMovie = """{"movies":[{"ids":{"imdb":"tt1234567"}}]}"""
    private val traktShow = """{"shows":[{"ids":{"tmdb":235}}]}"""
    private val simklMovie = """{"movies":[{"ids":{"tmdb":235},"to":"plantowatch"}]}"""
    private val simklShow = """{"shows":[{"ids":{"imdb":"tt1234567"},"to":"plantowatch"}]}"""
    private val aggregate = """{"updated_at":"2026-01-01T00:00:00.000Z","item_count":4}"""
    private val zero = """{"movies":0,"shows":0,"seasons":0,"episodes":0}"""
    private val movie = """{"movies":1,"shows":0,"seasons":0,"episodes":0}"""
    private val show = """{"movies":0,"shows":1,"seasons":0,"episodes":0}"""

    @Test fun `single typed Trakt add existing and remove settle with matching counters`() {
        assertEquals(Outcome.ADDED, evaluate(Operation.TRAKT_ADD, traktMovie, 201,
            """{"list":$aggregate,"added":$movie,"existing":$zero,"not_found":{}}"""))
        assertEquals(Outcome.ALREADY_PRESENT, evaluate(Operation.TRAKT_ADD, traktShow, 201,
            """{"list":$aggregate,"added":$zero,"existing":$show,"not_found":{"shows":null,"movies":[]}}"""))
        assertEquals(Outcome.REMOVED, evaluate(Operation.TRAKT_REMOVE, traktMovie, 200,
            """{"list":$aggregate,"deleted":$movie,"not_found":{}}"""))
    }

    @Test fun `Trakt refuses mixed counts malformed reports and status only`() {
        val malformed = listOf(
            """{"list":$aggregate,"added":$movie,"existing":$movie,"not_found":{}}""",
            """{"list":$aggregate,"added":$show,"existing":$zero,"not_found":{}}""",
            """{"list":$aggregate,"added":${movie.replace(":1", ":2")},"existing":$zero,"not_found":{}}""",
            """{"list":$aggregate,"added":${movie.replace(":1", ":\"1\"")},"existing":$zero,"not_found":{}}""",
            """{"list":$aggregate,"added":${movie.replace(":1", ":1.000000000000000001")},"existing":$zero,"not_found":{}}""",
            """{"list":$aggregate,"added":${movie.replace(":1", ":-1")},"existing":$zero,"not_found":{}}""",
            """{"list":$aggregate,"added":{"movies":1},"existing":$zero,"not_found":{}}""",
            """{"list":$aggregate,"added":$movie,"existing":$zero,"not_found":{"movies":0}}""",
            """{"list":$aggregate,"added":$movie,"existing":$zero,"not_found":{"future":[]}}""",
            """{"list":$aggregate,"added":$movie,"existing":$zero,"not_found":{"movies":[{"ids":{"imdb":"tt1234567"}}]}}""",
            """{"list":$aggregate,"added":$movie,"existing":$zero}""",
            """{"list":$aggregate,"added":$movie,"existing":$zero,"not_found":{},"error":"unexpected"}""",
            "{}",
        )
        for (response in malformed) assertEquals(response, Outcome.UNVERIFIED,
            evaluate(Operation.TRAKT_ADD, traktMovie, 201, response))
        assertEquals(Outcome.UNVERIFIED, evaluate(Operation.TRAKT_ADD, traktMovie, 200,
            """{"list":$aggregate,"added":$movie,"existing":$zero,"not_found":{}}"""))
    }

    @Test fun `Trakt exact misses differ from ambiguous zero delete and malformed negatives`() {
        val miss = """{"list":$aggregate,"deleted":$zero,"not_found":{"movies":[{"ids":{"imdb":"tt1234567"}}]}}"""
        assertEquals(Outcome.ITEM_REPORTED_NOT_FOUND, evaluate(Operation.TRAKT_REMOVE, traktMovie, 200, miss))
        assertEquals(Outcome.UNVERIFIED, evaluate(Operation.TRAKT_REMOVE, traktMovie, 200,
            """{"list":$aggregate,"deleted":$zero,"not_found":{}}"""))
        for (body in listOf(miss.replace("tt1234567", "tt7654321"), miss.replace("ids", "title"),
            miss.replace("not_found", "not-found"), miss.replace("tt1234567", "tt1234567x"))) {
            assertEquals(Outcome.UNVERIFIED, evaluate(Operation.TRAKT_REMOVE, traktMovie, 200, body))
        }
    }

    @Test fun `a success cannot settle untyped multiple or ambiguous original identities`() {
        val removed = """{"list":$aggregate,"deleted":$movie,"not_found":{}}"""
        val requests = listOf(
            """{"movies":[{"ids":{"imdb":"tt1234567"}}],"shows":[{"ids":{"imdb":"tt1234567"}}]}""",
            """{"movies":[{"ids":{"imdb":"tt1234567"}},{"ids":{"imdb":"tt7654321"}}]}""",
            """{"movies":[{"ids":{"imdb":"tt1234567","tmdb":235}}]}""",
            """{"movies":[{"ids":{"tmdb":"235"}}]}""",
            """{"movies":[{"ids":{"tmdb":0}}]}""",
            """{"movies":[{"ids":{"tmdb":2147483648}}]}""",
            """{"movies":[{"ids":{"imdb":"tt1234567"},"notes":"scope change"}]}""",
        )
        for (request in requests) assertEquals(Outcome.UNVERIFIED,
            evaluate(Operation.TRAKT_REMOVE, request, 200, removed))
    }

    @Test fun `Trakt requires the official typed list summary without assigning it title authority`() {
        val reply = """{"added":$movie,"existing":$zero,"not_found":{}}"""
        assertEquals(Outcome.UNVERIFIED, evaluate(Operation.TRAKT_ADD, traktMovie, 201, reply))
        val invalidLists = listOf(
            "null", "[]", "{}",
            """{"updated_at":"2026-01-01T00:00:00.000Z","item_count":"4"}""",
            """{"updated_at":"2026-01-01T00:00:00.000Z","item_count":4.25}""",
            """{"updated_at":"2026-01-01T00:00:00.000Z","item_count":-1}""",
            """{"updated_at":"2026-01-01T00:00:00.000Z","item_count":4,"error":null}""",
            """{"updated_at":"not-a-timestamp","item_count":4}""",
            """{"updated_at":"2026-02-31T00:00:00Z","item_count":4}""",
            """{"updated_at":"2026-01-01T24:00:00Z","item_count":4}""",
            """{"updated_at":"2026-01-01T23:60:00Z","item_count":4}""",
            """{"updated_at":"2016-12-31T23:59:60Z","item_count":4}""",
            """{"updated_at":1,"item_count":4}""",
        )
        for (list in invalidLists) {
            val invalid = """{"list":$list,${reply.drop(1)}"""
            assertEquals(invalid, Outcome.UNVERIFIED, evaluate(Operation.TRAKT_ADD, traktMovie, 201, invalid))
        }
        val validList = """{"updated_at":"2026-01-01T23:59:59Z","item_count":4}"""
        assertEquals(Outcome.ADDED, evaluate(Operation.TRAKT_ADD, traktMovie, 201,
            """{"list":$validList,${reply.drop(1)}"""))
    }

    @Test fun `SIMKL confirms exact identity and actual plan to watch status`() {
        assertEquals(Outcome.STATUS_CONFIRMED, evaluate(Operation.SIMKL_ADD, simklMovie, 201,
            """{"added":{"movies":[{"to":"plantowatch","ids":{"tmdb":"235","simkl":42,"letterboxd":"movie-title"},"type":"movie","anime_type":null}],"shows":[]},"not_found":{"movies":[],"shows":[]}}"""))
        assertEquals(Outcome.STATUS_CONFIRMED, evaluate(Operation.SIMKL_ADD, simklShow, 201,
            """{"added":{"shows":[{"to":"plantowatch","ids":{"imdb":"tt1234567"},"type":"show","anime_type":"tv"}]},"not_found":{}}"""))
        assertEquals(Outcome.STATUS_CONFIRMED, evaluate(Operation.SIMKL_ADD, simklShow, 201,
            """{"added":{"shows":[{"to":"plantowatch","ids":{"imdb":"tt1234567","simkl":42,"simkl_id":42,"tmdb":"235","tvdb":"5","mal":"8","slug":"show-title"},"type":"show","title":"Example","year":2026,"anime_type":"ova"}]},"not_found":{}}"""))
    }

    @Test fun `SIMKL refuses a missing conflicting or malformed result even on 201`() {
        val item = """{"to":"plantowatch","ids":{"tmdb":"235"},"type":"movie"}"""
        val response = """{"added":{"movies":[$item]},"not_found":{}}"""
        val malformed = listOf(
            response.replace("plantowatch", "completed"),
            response.replace("\"type\":\"movie\"", "\"type\":\"show\""),
            response.replace("\"tmdb\"", "\"simkl\""),
            response.replace("\"235\"", "\"0235\""),
            response.replace("\"235\"", "\"236\""),
            response.replace("\"235\"", "235.000000000000000001"),
            response.replace("movies", "shows"),
            response.replace("[$item]", "[$item,$item]"),
            response.replace("[$item]", "1"),
            """{"added":{"movies":[$item],"anime":[$item]},"not_found":{}}""",
            """{"added":{"movies":[$item]},"not_found":{"movies":[$item]}}""",
            """{"added":{},"not_found":{"movies":[{"to":"plantowatch","ids":{"tmdb":true}}]}}""",
        )
        for (body in malformed) assertEquals(body, Outcome.UNVERIFIED,
            evaluate(Operation.SIMKL_ADD, simklMovie, 201, body))
        val conflictingRequest = simklMovie.replace("\"tmdb\":235", "\"tmdb\":235,\"imdb\":\"tt1234567\"")
        val bothEchoed = response.replace("\"tmdb\":\"235\"", "\"tmdb\":\"235\",\"imdb\":\"tt1234567\"")
        assertEquals(Outcome.UNVERIFIED, evaluate(Operation.SIMKL_ADD, conflictingRequest, 201, bothEchoed))
        assertEquals(Outcome.UNVERIFIED, evaluate(Operation.SIMKL_ADD, simklMovie, 200, response))
        assertEquals(Outcome.ITEM_REPORTED_NOT_FOUND, evaluate(Operation.SIMKL_ADD, simklMovie, 201,
            """{"added":{"movies":[]},"not_found":{"movies":[{"to":"plantowatch","ids":{"tmdb":235}}]}}"""))
    }

    @Test fun `SIMKL rejects undocumented positives malformed metadata and conflicting canonical aliases`() {
        val movieItem = """{"to":"plantowatch","ids":{"tmdb":"235"},"type":"movie"}"""
        val showItem = """{"to":"plantowatch","ids":{"imdb":"tt1234567"},"type":"show"}"""
        val badMovieFields = listOf(
            "\"error\":\"id_err\"", "\"id_err\":false", "\"future\":null",
            "\"anime_type\":{}", "\"anime_type\":\"tv\"", "\"title\":null",
            "\"title\":5", "\"title\":\"   \"", "\"year\":\"2026\"",
            "\"year\":2026.01", "\"year\":0", "\"year\":10000",
        )
        for (field in badMovieFields) {
            val body = """{"added":{"movies":[{$field,${movieItem.drop(1)}]},"not_found":{}}"""
            assertEquals(body, Outcome.UNVERIFIED, evaluate(Operation.SIMKL_ADD, simklMovie, 201, body))
        }
        val badIdentities = listOf(
            "\"error\":false", "\"tmdb\":235", "\"simkl\":\"42\"",
            "\"simkl_id\":0", "\"simkl\":42,\"simkl_id\":43", "\"simkl\":42.1",
            "\"imdb\":true", "\"tvdb\":42", "\"anilist\":\"042\"",
            "\"slug\":{}", "\"slug\":\"with space\"",
        )
        for (identities in badIdentities) {
            val ids = if (identities.startsWith("\"tmdb\"")) identities else "\"tmdb\":\"235\",$identities"
            val body = """{"added":{"movies":[{"to":"plantowatch","ids":{$ids},"type":"movie"}]},"not_found":{}}"""
            assertEquals(body, Outcome.UNVERIFIED, evaluate(Operation.SIMKL_ADD, simklMovie, 201, body))
        }
        val unknownAnimeType = """{"added":{"shows":[{"anime_type":"future",${showItem.drop(1)}]},"not_found":{}}"""
        assertEquals(Outcome.UNVERIFIED, evaluate(Operation.SIMKL_ADD, simklShow, 201, unknownAnimeType))
        val movieOnlyId = """{"added":{"shows":[{"to":"plantowatch","ids":{"imdb":"tt1234567","letterboxd":"movie-title"},"type":"show"}]},"not_found":{}}"""
        assertEquals(Outcome.UNVERIFIED, evaluate(Operation.SIMKL_ADD, simklShow, 201, movieOnlyId))
    }

    @Test fun `strict byte ingress rejects duplicate decoded names invalid UTF8 and over limit`() {
        val response = """{"list":$aggregate,"added":$movie,"existing":$zero,"not_found":{}}"""
        val escapedDuplicate = """{"list":$aggregate,"added":$zero,"\u0061dded":$movie,"existing":$zero,"not_found":{}}"""
        val nestedDuplicate = response.replace("\"movies\":1", "\"movies\":0,\"movies\":1")
        for (body in listOf(escapedDuplicate, nestedDuplicate, response + "{}", response + " ".repeat(32_768))) {
            assertEquals(Outcome.UNVERIFIED, evaluate(Operation.TRAKT_ADD, traktMovie, 201, body))
        }
        val duplicateIds = """{"movies":[{"ids":{"imdb":"tt7654321","imdb":"tt1234567"}}]}"""
        assertEquals(Outcome.UNVERIFIED, evaluate(Operation.TRAKT_ADD, duplicateIds, 201, response))
        val titlePrefix = "{\"added\":{\"movies\":[{\"to\":\"plantowatch\",\"ids\":{\"tmdb\":\"235\"},\"type\":\"movie\",\"title\":\""
        val titleSuffix = "\"}]},\"not_found\":{}}"
        assertEquals(Outcome.STATUS_CONFIRMED,
            evaluate(Operation.SIMKL_ADD, simklMovie, 201, titlePrefix + "metadata" + titleSuffix))
        val malformedUtf8 = titlePrefix.encodeToByteArray() +
            byteArrayOf(0xc0.toByte(), 0xaf.toByte()) + titleSuffix.encodeToByteArray()
        assertEquals(Outcome.UNVERIFIED, ProviderWatchlistReceipt.evaluate(
            Operation.SIMKL_ADD, simklMovie.encodeToByteArray(), 201, malformedUtf8))
    }

    private fun evaluate(operation: Operation, request: String, status: Int, response: String): Outcome =
        ProviderWatchlistReceipt.evaluate(operation, request.encodeToByteArray(), status, response.encodeToByteArray())
}
