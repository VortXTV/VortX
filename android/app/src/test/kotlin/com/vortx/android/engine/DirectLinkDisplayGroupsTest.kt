package com.vortx.android.engine

import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.sources.SourcePrefsSnapshot
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class DirectLinkDisplayGroupsTest {
    @Test
    fun `direct only removes raw torrents but preserves every resolved and direct row`() {
        val rawTorrent = source("raw", isTorrent = true, infoHash = HASH)
        val resolvedDebrid = source(
            "resolved",
            isTorrent = true,
            infoHash = HASH,
            url = "https://debrid.example/file",
        )
        val direct = source("direct", url = "https://cdn.example/file")
        val externalTorrent = source(
            "external-torrent",
            isTorrent = true,
            infoHash = HASH,
            externalUrl = "https://addon.example/resolve",
        )
        val fakeDirectTorrent = source(
            "fake-direct-torrent",
            isTorrent = true,
            infoHash = HASH,
            url = "magnet:?xt=urn:btih:$HASH",
        )
        val mediaServer = source(
            "server",
            isTorrent = true,
            infoHash = HASH,
            isMediaServer = true,
        )
        val groups = listOf(
            StreamGroup(
                "Provider",
                listOf(rawTorrent, resolvedDebrid, direct, externalTorrent, fakeDirectTorrent, mediaServer),
            ),
        )

        val display = SourceListModel.directLinkDisplayGroups(groups, enabled = true)

        assertEquals(listOf("resolved", "direct", "server"), display.flatMap { it.streams }.map { it.id })
        assertSame(groups, SourceListModel.directLinkDisplayGroups(groups, enabled = false))
    }

    @Test
    fun `smart source ranking input cannot contain a raw torrent`() {
        val rawTorrent = source("raw", isTorrent = true, infoHash = HASH)
        val direct = source("direct", url = "https://cdn.example/file")
        val smartInput = SourceListModel.directLinkDisplayGroups(
            listOf(StreamGroup("Provider", listOf(rawTorrent, direct))),
            enabled = true,
        )

        val picked = StreamRanking.best(smartInput, prefs = SourcePrefsSnapshot.DEFAULT)

        assertFalse(smartInput.flatMap { it.streams }.any { it.id == "raw" })
        assertEquals("direct", picked?.id)
    }

    @Test
    fun `detail immediate paint and smart picks consume the shared filtered input`() {
        val source = readProjectFile("src/main/kotlin/com/vortx/android/ui/viewmodel/DetailViewModel.kt")

        assertTrue(source.contains("val displayRaw = SourceListModel.directLinkDisplayGroups(raw, ctx.directLinksOnly)"))
        assertTrue(source.contains("_streams.value = UiState.Success(displayRaw)"))
        assertTrue(source.contains("val assembled = sourceModel.awaitSettledTarget("))
        assertTrue(source.contains("assembled?.best"))
        assertTrue(source.contains("displayRaw,\n                                continuity = null,"))
        assertTrue(source.contains("sticky = sticky,"))
        assertTrue(source.contains("providerPenalty = unhealthy,"))
    }

    @Test
    fun `manual sticky write follows accepted ready publication`() {
        val source = readProjectFile("src/main/kotlin/com/vortx/android/ui/viewmodel/DetailViewModel.kt")
        val play = source.substringAfter("private fun play(source: StreamSource, manualPick: Boolean)")
        val accepted = play.indexOf("sourceRequestFence.accepts(request, sourceSticky.currentProfileId())")
        val published = play.indexOf("_playback.value = result.fold(")
        val readyGate = play.indexOf("if (_playback.value is Playback.Ready && stickyWrite != null)")
        val persisted = play.indexOf("sourceSticky.record(stickyWrite, source.addon, source.bingeGroup)")

        assertTrue(accepted >= 0)
        assertTrue(published > accepted)
        assertTrue(readyGate > published)
        assertTrue(persisted > readyGate)
    }

    @Test
    fun `profile switch cancels invalidates clears and rebuilds`() {
        val source = readProjectFile("src/main/kotlin/com/vortx/android/ui/viewmodel/DetailViewModel.kt")
        val rebuild = source.substringAfter("private fun rebuildForProfile(profileId: String)")
            .substringBefore("private suspend fun loadSources")

        assertTrue(rebuild.contains("sourceLoadJob?.cancel()"))
        assertTrue(rebuild.contains("playbackResolveJob?.cancel()"))
        assertTrue(rebuild.contains("sourceRequestFence.invalidate(profileId)"))
        assertTrue(rebuild.contains("sourceSticky.onProfileChanged()"))
        assertTrue(rebuild.contains("torbox.reset(invalidGeneration, clearCache = true)"))
        assertTrue(rebuild.contains("singularity.reset(invalidGeneration)"))
        assertTrue(rebuild.contains("startSourceLoad(target?.id)"))
    }

    private fun source(
        id: String,
        isTorrent: Boolean = false,
        isMediaServer: Boolean = false,
        infoHash: String? = null,
        url: String? = null,
        externalUrl: String? = null,
    ) = StreamSource(
        id = id,
        addon = "Provider",
        title = "1080p",
        isTorrent = isTorrent,
        isMediaServer = isMediaServer,
        infoHash = infoHash,
        url = url,
        externalUrl = externalUrl,
    )

    private fun readProjectFile(relativePath: String): String {
        val candidates = listOf(File(relativePath), File("app/$relativePath"), File("android/app/$relativePath"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relativePath from ${File(".").absolutePath}")
    }

    private companion object {
        const val HASH = "abcdef0123456789abcdef0123456789abcdef01"
    }
}
