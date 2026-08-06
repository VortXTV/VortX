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
        val mediaServer = source(
            "server",
            isTorrent = true,
            infoHash = HASH,
            isMediaServer = true,
        )
        val groups = listOf(StreamGroup("Provider", listOf(rawTorrent, resolvedDebrid, direct, mediaServer)))

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
        assertTrue(source.contains("StreamRanking.best(displayRaw, prefs = ctx.prefs, pin = currentPin())"))
        assertTrue(source.contains("displayRaw,\n                                continuity = hint.first"))
    }

    private fun source(
        id: String,
        isTorrent: Boolean = false,
        isMediaServer: Boolean = false,
        infoHash: String? = null,
        url: String? = null,
    ) = StreamSource(
        id = id,
        addon = "Provider",
        title = "1080p",
        isTorrent = isTorrent,
        isMediaServer = isMediaServer,
        infoHash = infoHash,
        url = url,
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
