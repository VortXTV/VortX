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
        val play = source.substringAfter("private fun play(\n        source: StreamSource,")
            .substringBefore("/**\n     * Resolve an in-player source")
        val accepted = play.indexOf("if (!canPublishPlaybackResolve(resolveLease)) return@launch")
        val published = play.indexOf("publishPlaybackResolve(resolveLease, nextPlayback)")
        val readyGate = play.indexOf("if (nextPlayback is Playback.Ready && stickyWrite != null)")
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
        val cancelResolve = rebuild.indexOf("cancelPlaybackResolveForSourceTargetInvalidation()")
        val invalidateSources = rebuild.indexOf("sourceRequestFence.invalidate(profileId)")

        assertTrue(rebuild.contains("sourceLoadJob?.cancel()"))
        assertTrue(cancelResolve >= 0)
        assertTrue(invalidateSources >= 0)
        assertTrue("Profile rebuild must revoke resolver authority before advancing the source fence", cancelResolve < invalidateSources)
        assertTrue(rebuild.contains("sourceSticky.onProfileChanged()"))
        assertTrue(rebuild.contains("torbox.reset(invalidGeneration, clearCache = true)"))
        assertTrue(rebuild.contains("singularity.reset(invalidGeneration)"))
        assertTrue(rebuild.contains("startSourceLoad(target?.id)"))
    }

    @Test
    fun `source target invalidation revokes resolver before cancellation and generation advance`() {
        val source = readProjectFile("src/main/kotlin/com/vortx/android/ui/viewmodel/DetailViewModel.kt")
        val helper = source.substringAfter("fun abandonPlaybackResolve()")
            .substringBefore("private fun canPublishPlaybackResolve")
        val startLoad = source.substringAfter("private fun startSourceLoad")
            .substringBefore("/**\n     * Retire an in-flight detail resolver")

        val revoke = helper.indexOf("playbackResolveFence.invalidateForSourceRequest(request)")
        val cancel = helper.indexOf("playbackResolveJob?.cancel()")
        val targetCancel = startLoad.indexOf("cancelPlaybackResolveForSourceTargetInvalidation()")
        val targetAdvance = startLoad.indexOf("sourceRequestFence.begin")

        assertTrue(revoke >= 0)
        assertTrue(cancel >= 0)
        assertTrue(targetCancel >= 0)
        assertTrue(targetAdvance >= 0)
        assertTrue(revoke < cancel)
        assertTrue(targetCancel < targetAdvance)
        assertTrue(helper.contains("if (_playback.value is Playback.Resolving)"))
        assertTrue(helper.contains("_playback.value = Playback.Idle"))
    }

    @Test
    fun `every target and dismiss path abandons a stale resolver`() {
        val viewModel = readProjectFile("src/main/kotlin/com/vortx/android/ui/viewmodel/DetailViewModel.kt")
        val phone = readProjectFile("src/main/kotlin/com/vortx/android/ui/VortXApp.kt")
        val tv = readProjectFile("src/main/kotlin/com/vortx/android/ui/tv/TvApp.kt")

        assertTrue(methodBody(viewModel, "fun retryMeta()", "fun selectEpisode").contains("cancelPlaybackResolveForSourceTargetInvalidation()"))
        assertTrue(methodBody(viewModel, "fun clearPlayback()", "fun clearMutationError").contains("abandonPlaybackResolve()"))
        assertTrue(methodBody(viewModel, "private fun startSourceLoad", "/**\n     * Retire").contains("cancelPlaybackResolveForSourceTargetInvalidation()"))

        assertCallbackAbandonsBeforeRoute(phone, "// Hardware/gesture back pops the player overlay", "BackHandler {", "DisposableEffect(historyIdentity, advanceVm)", "advanceVm?.abandonPlaybackResolve()")
        assertCallbackAbandonsBeforeRoute(phone, "PlayerScreen(\n                    playable = playable,", "onBack = {", "onError = {", "advanceVm?.abandonPlaybackResolve()")
        assertCallbackAbandonsBeforeRoute(phone, "PlayerScreen(\n                    playable = playable,", "onError = {", "// Natural end of the stream", "advanceVm?.abandonPlaybackResolve()")
        assertCallbackAbandonsBeforeRoute(phone, "UpNextOverlay(", "onCancel = {", "},\n                    )", "advanceVm.abandonPlaybackResolve()")
        assertCallbackAbandonsBeforeRoute(phone, "ManualSourcePickOverlay(", "onClose = {", "},\n                        )", "advanceVm.abandonPlaybackResolve()")
        assertCallbackAbandonsBeforeRoute(phone, "// System Back closes the detail overlay", "BackHandler {", "DetailScreen(", "detailVm.abandonPlaybackResolve()")
        assertCallbackAbandonsBeforeRoute(phone, "DetailScreen(\n                    viewModel = detailVm,", "onBack = {", "// DetailScreen supplies", "detailVm.abandonPlaybackResolve()")

        assertCallbackAbandonsBeforeRoute(tv, "// D-pad Back pops the player", "BackHandler {", "DisposableEffect(historyIdentity)", "playerVm?.abandonPlaybackResolve()")
        assertCallbackAbandonsBeforeRoute(tv, "PlayerScreen(\n                playable = playable,", "onBack = {", "onError = {", "playerVm?.abandonPlaybackResolve()")
        assertCallbackAbandonsBeforeRoute(tv, "PlayerScreen(\n                playable = playable,", "onError = {", "onSourceFailed =", "playerVm?.abandonPlaybackResolve()")
        assertCallbackAbandonsBeforeRoute(tv, "TvDetailScreen(\n                        viewModel = detailVm,", "onBack = {", "onPlay =", "detailVm.abandonPlaybackResolve()")
    }

    private fun methodBody(source: String, start: String, end: String): String =
        source.substringAfter(start).substringBefore(end)

    private fun assertCallbackAbandonsBeforeRoute(
        source: String,
        scopeStart: String,
        callbackStart: String,
        callbackEnd: String,
        abandon: String,
    ) {
        val scopeIndex = source.indexOf(scopeStart)
        assertTrue("Missing callback scope $scopeStart", scopeIndex >= 0)
        val startIndex = source.indexOf(callbackStart, scopeIndex + scopeStart.length)
        assertTrue("Missing callback start $callbackStart after $scopeStart", startIndex >= 0)
        val endIndex = source.indexOf(callbackEnd, startIndex + callbackStart.length)
        assertTrue("Missing callback end $callbackEnd after $callbackStart", endIndex >= 0)
        val body = source.substring(startIndex, endIndex)
        val revoke = body.indexOf(abandon)
        val route = body.indexOf("playing = null").takeIf { it >= 0 }
            ?: body.indexOf("openDetail(null)").takeIf { it >= 0 }
            ?: body.indexOf("detail = null")
        assertTrue("Missing $abandon after $callbackStart", revoke >= 0)
        assertTrue("Missing route dismissal after $callbackStart", route >= 0)
        assertTrue("$abandon must precede route dismissal", revoke < route)
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
