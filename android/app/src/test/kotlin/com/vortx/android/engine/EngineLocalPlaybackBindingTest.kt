package com.vortx.android.engine

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.data.PlaybackSessionToken
import com.vortx.android.model.PlaybackContext
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Proves the locally-bound history seam (W1-D extension): the engine Player `selected` payload for an
 * offline play is synthesized PURELY from the immutable [PlaybackContext], so a stream-A then offline-B
 * session attributes every tick, the watched threshold, and Continue Watching re-derivation to B even
 * while the resident detail page still describes A. Phone and TV share the exact function, so platform
 * parity is structural: identical contexts produce identical payloads by construction.
 */
class EngineLocalPlaybackBindingTest {

    @Test
    fun `movie context synthesizes engine selected keyed on the movie ids`() {
        val context = PlaybackContext(
            owner = PlaybackContext.Owner("profile-owner", usesEngineHistory = true),
            contentId = "imdb:tt0108778",
            videoId = "imdb:tt0108778",
            type = "movie",
            season = null,
            episode = null,
            title = "The Big Lebowski",
            poster = "https://example.invalid/poster.jpg",
            provenance = localProvenance(),
        )

        val selected = buildLocalPlayerSelected(context)

        val metaPath = requireNotNull(selected.optJSONObject("metaRequest")).let { request ->
            assertEquals(LOCAL_PLAYBACK_REQUEST_BASE, request.optString("base"))
            requireNotNull(request.optJSONObject("path"))
        }
        assertEquals("meta", metaPath.optString("resource"))
        assertEquals("movie", metaPath.optString("type"))
        assertEquals("imdb:tt0108778", metaPath.optString("id"))
        assertEquals(0, requireNotNull(metaPath.optJSONArray("extra")).length())

        val streamPath = requireNotNull(selected.optJSONObject("streamRequest")).let { request ->
            assertEquals(LOCAL_PLAYBACK_REQUEST_BASE, request.optString("base"))
            requireNotNull(request.optJSONObject("path"))
        }
        assertEquals("stream", streamPath.optString("resource"))
        assertEquals("movie", streamPath.optString("type"))
        assertEquals("imdb:tt0108778", streamPath.optString("id"))
        assertEquals(0, requireNotNull(streamPath.optJSONArray("extra")).length())

        // The stream must carry a source-bearing url so the engine parses the Selected struct; it is
        // never opened by the engine itself.
        val streamUrl = requireNotNull(selected.optJSONObject("stream")).optString("url")
        assertTrue(streamUrl.startsWith(LOCAL_PLAYBACK_REQUEST_BASE))
        assertTrue(streamUrl.contains("offline"))
        assertTrue(streamUrl.endsWith("%7Cimdb%3Att0108778%7Cimdb%3Att0108778"))

        assertTrue(selected.isNull("subtitlesPath"))
    }

    @Test
    fun `episode context keys the stream request on the episode video id`() {
        val context = PlaybackContext(
            owner = PlaybackContext.Owner("profile-overlay", usesEngineHistory = false),
            contentId = "imdb:tt0108778",
            videoId = "imdb:tt0108778:3:1",
            type = "series",
            season = 3,
            episode = 1,
            title = "Friends",
            poster = null,
            provenance = localProvenance(),
        )

        val selected = buildLocalPlayerSelected(context)

        val metaId = requireNotNull(
            requireNotNull(selected.optJSONObject("metaRequest")).optJSONObject("path"),
        ).optString("id")
        val videoId = requireNotNull(
            requireNotNull(selected.optJSONObject("streamRequest")).optJSONObject("path"),
        ).optString("id")
        assertEquals("imdb:tt0108778", metaId)
        assertEquals("imdb:tt0108778:3:1", videoId)
        assertEquals("series", requireNotNull(selected.optJSONObject("metaRequest"))
            .optJSONObject("path")?.optString("type"))
    }

    @Test
    fun `payload depends only on the context so phone and TV bind identically`() {
        fun context() = PlaybackContext(
            owner = PlaybackContext.Owner("profile-owner", usesEngineHistory = true),
            contentId = "tmdb:618344",
            videoId = "tmdb:618344",
            type = "movie",
            season = null,
            episode = null,
            title = "Something Borrowed",
            poster = null,
            provenance = localProvenance(),
        )

        // The same context rendered twice (as the phone shell and the TV shell each would) must give a
        // byte-identical payload: no ambient state can leak into local-session binding.
        assertEquals(buildLocalPlayerSelected(context()).toString(), buildLocalPlayerSelected(context()).toString())

        // A different resident title's identity appears NOWHERE in the payload because the function
        // cannot read it: assert the only ids present are the bound ones.
        val payload = buildLocalPlayerSelected(context()).toString()
        assertFalse(payload.contains("imdb:"))
    }

    @Test
    fun `session record defaults to streaming semantics and preserves explicit local binding`() {
        val token = PlaybackSessionToken(7L)
        val owner = ContinueWatchingOwner(
            profileId = "p",
            accountSlot = "slot",
            principal = "principal",
            usesEngineHistory = true,
            revision = 1L,
        )
        val streaming = PlaybackHistorySession(
            token = token,
            owner = owner,
            enginePlayerLoaded = true,
            type = "movie",
            videoId = "imdb:tt0108778",
            overlayMetaId = null,
            name = "A",
            poster = null,
        )
        val local = PlaybackHistorySession(
            token = token,
            owner = owner,
            enginePlayerLoaded = true,
            type = "movie",
            videoId = "imdb:tt0112384",
            overlayMetaId = null,
            name = "B",
            poster = null,
            localIdentityBound = true,
        )
        // Streaming sessions keep the resident-keyed belt-and-suspenders watched marks; locally-bound
        // sessions must skip them (the repository gates those dispatches on this flag).
        assertFalse(streaming.localIdentityBound)
        assertTrue(local.localIdentityBound)
    }

    private fun localProvenance(): PlaybackContext.Provenance = PlaybackContext.Provenance(
        sourceName = null,
        qualityText = null,
        torrentFetched = false,
        debridOwnerIdentity = null,
        debridOwnerGeneration = null,
    )
}
