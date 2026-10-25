package com.vortx.android.sources

import java.io.File
import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Real caller/source bindings, not Compose focus/render or live account correctness proof. */
class SourceQuickFilterCallerContractTest {
    private fun read(relative: String): String = listOf(File(relative), File("app/$relative"), File("android/app/$relative"))
        .first(File::isFile).readText()
    private val main = "src/main/kotlin/com/vortx/android/"
    private fun between(source: String, start: String, end: String): String {
        val from = source.indexOf(start)
        val to = source.indexOf(end, from + start.length)
        require(from >= 0 && to > from) { "Missing reviewed source boundary" }
        return source.substring(from, to)
    }
    private fun sha256(text: String) = MessageDigest.getInstance("SHA-256").digest(text.toByteArray())
        .joinToString("") { "%02x".format(it) }

    @Test fun `actual cache check fold preserves every target owner credential and generation fence`() {
        val vm = read(main + "ui/viewmodel/DetailViewModel.kt")
        val fold = between(vm, "    private fun runCacheCheck(", "    /// Fold a \"cached\" marker")
        assertTrue(fold.contains("val hits = debrid.cacheCheck(hashes, owner)"))
        val mark = fold.indexOf("com.vortx.android.sources.markAccountConfirmedCache(")
        val firstFence = fold.indexOf("return@launch", fold.indexOf("val hits ="))
        val publication = fold.indexOf("sourceModel.setRawGroups(decorated)")
        assertTrue(firstFence in 0 until mark && publication > mark)
        listOf(
            "episodeId != _selectedEpisodeId.value", "episodeId == _selectedEpisodeId.value",
            "!sourceRequestFence.accepts(request, sourceSticky.currentProfileId())",
            "sourceRequestFence.accepts(request, sourceSticky.currentProfileId())",
            "!cacheCheckGate.isCurrent(cacheGeneration)", "cacheCheckGate.isCurrent(cacheGeneration)",
            "!debridKeys.isCurrent(owner)", "debridKeys.isCurrent(owner)",
            "debridKeys.currentCredentialRevision() != credentialRevision",
            "debridKeys.currentCredentialRevision() == credentialRevision",
            "val cacheDisplayRevision = DebridKeys.credentialRevision.value",
            "DebridKeys.credentialRevision.value != cacheDisplayRevision",
            "decorateCached(raw, torrentServices.keys), torrentServices.keys, cacheDisplayRevision,",
        ).forEach { assertTrue("Missing actual cache fold fence: $it", fold.contains(it)) }
        assertTrue(fold.substring(mark, publication).contains("decorated !== raw"))
        listOf("episodeId == _selectedEpisodeId.value", "sourceRequestFence.accepts(request, sourceSticky.currentProfileId())",
            "cacheCheckGate.isCurrent(cacheGeneration)", "debridKeys.isCurrent(owner)",
            "debridKeys.currentCredentialRevision() == credentialRevision",
            "DebridKeys.credentialRevision.value == cacheDisplayRevision").forEach {
            assertTrue("Missing final publication fence: $it", fold.substring(mark, publication).contains(it))
        }
        // Exact original text/id cache-decoration mechanism stays intact (29494785 / a5e677c2).
        val decoration = between(vm, "    private fun decorateCached(", "    /// The effective per-title")
        assertEquals("229e4fbbca9b5948dece948dbc5a0740ffac35fd487c9f8aeb5f62c33fa5623a", sha256(decoration))
    }

    @Test fun `transient evidence cannot come from provider import saved state or a ranker heuristic`() {
        val model = read(main + "model/Media.kt")
        assertTrue(model.contains("@Transient val accountConfirmedCacheRevision: Long? = null"))
        listOf("engine/EngineState.kt", "profile/LastStreamStore.kt", "communityjs/CommunityJsProviderSource.kt",
            "torbox/TorBoxSearchSource.kt", "singularity/SourceIndexClient.kt", "engine/StreamRanking.kt").forEach { path ->
            assertFalse("Transient evidence must not be decoded/persisted/ranked in $path", read(main + path).contains("accountConfirmedCacheRevision"))
        }
        val policy = read(main + "sources/SourceQuickFilters.kt")
        assertFalse(policy.contains("StreamRanking"))
        assertFalse(policy.contains("SharedPreferences"))
        assertFalse(policy.contains("nativePlaybackToken"))
        assertTrue(policy.contains("source.copy(accountConfirmedCacheRevision = proof)"))
        assertTrue(policy.contains("source.accountConfirmedCacheRevision == currentRevision"))
        assertTrue(policy.contains("currentRevision >= 0"))
        assertTrue(policy.contains("private val entries by lazy"))
        assertTrue(policy.contains("!source.isUsenet && !source.isMediaServer"))
        assertTrue(policy.contains("hash in hashes"))
    }

    @Test fun `existing account credential and profile lifecycles discard prior confirmed rows`() {
        val vm = read(main + "ui/viewmodel/DetailViewModel.kt")
        val reset = between(vm, "    private fun rebuildForProfile(", "    /// Load + assemble the sources")
        listOf("debridCacheEvidence = null", "sourceModel.setRawGroups(emptyList())", "_streams.value = UiState.Loading").forEach {
            assertTrue(reset.contains(it))
        }
        val phone = read(main + "ui/VortXApp.kt")
        val tv = read(main + "ui/tv/TvApp.kt")
        listOf(phone, tv).forEach { shell ->
            assertTrue(shell.contains("val detailSourceEpoch = \"\u0024debridOwnerEpoch:\u0024debridCredentialRevision:\u0024sourceSettingsRevision\""))
            assertTrue(shell.contains("rememberReplacingViewModelStoreOwner("))
            assertTrue(shell.contains("\u0024detailSourceEpoch"))
        }
    }

    @Test fun `phone tablet list filters do not redirect Quality Audio Copy or playback`() {
        val caller = read(main + "ui/screens/DetailScreen.kt")
        val body = between(caller, "private fun SourcesSection(", "/// The render window for the DET-2")
        listOf("quickFilterScope = viewModel to selectedEpisodeId", "remember(quickFilterScope)").forEach { assertTrue(caller.contains(it)) }
        listOf("SourceQuickFilterIndex(filteredGroups)", "facetIndex.matchingGroups(quickFilters, currentCacheRevision)", "val filtered = facetGroups",
            "StreamRanking.tiers(filteredGroups)", "StreamRanking.variantOptions(filteredGroups, activeTier)",
            "detailAudioLanguageOptions(filteredGroups)", "copyableSourceLinks(filteredGroups)",
            "onAudioLanguageHintChange(code)", "onPlay(source)", "SourceQuickFilterControls(",
            "No sources match these list filters.").forEach { assertTrue(body.contains(it)) }
        assertTrue(caller.contains("val cacheDisplayRevision by DebridKeys.credentialRevision.collectAsStateWithLifecycle()"))
        assertTrue(caller.contains("currentCacheRevision = maxOf(cacheDisplayRevision, DebridKeys.credentialRevision.value)"))
        val change = between(body, "                            onChange = {", "                            button =")
        listOf("onPlay", "onRefresh", "onSortChange", "onAudioLanguageHintChange", "onPin").forEach { assertFalse(change.contains(it)) }
        assertTrue(change.contains("pinMenuFor = null") && change.contains("renderLimit = SOURCE_WINDOW_INITIAL"))
        assertTrue(body.indexOf("copyableSourceLinks(filteredGroups)") < body.indexOf("SourceQuickFilterControls("))
    }

    @Test fun `TV list filters keep original groups for control authority and Best row`() {
        val caller = read(main + "ui/tv/TvSourceList.kt")
        val detail = read(main + "ui/tv/TvDetailScreen.kt")
        assertTrue(detail.contains("quickFilterScope = viewModel to selectedEpisodeId"))
        assertTrue(detail.contains("currentCacheRevision = maxOf(cacheDisplayRevision, com.vortx.android.debrid.DebridKeys.credentialRevision.value)"))
        assertTrue(detail.contains("val cacheDisplayRevision by com.vortx.android.debrid.DebridKeys.credentialRevision.collectAsStateWithLifecycle()"))
        listOf("quickFilterScope = quickFilterScope", "remember(quickFilterScope)", "SourceQuickFilterIndex(groups)",
            "facetIndex.matchingGroups(quickFilters, currentCacheRevision)",
            "tvSourceWindow(facetGroups, collapsed, renderLimit, jumpGroupKey)", "val expandableTotal = facetGroups.mapIndexed",
            "groups = facetGroups", "total = facetCount", "best = best", "No sources match these list filters.").forEach {
            assertTrue(caller.contains(it))
        }
        val content = between(caller, "private fun TvSourceListContent(", "/// Rendering-only leaf:")
        val controls = between(content, "        TvSourceControlsRow(", "        Text(")
        assertTrue(controls.contains("groups = groups") && controls.contains("onPlay = onPlay"))
        val change = between(controls, "            onQuickFiltersChange = {", "        )")
        listOf("jumpLease = null", "jumpGroupKey = null", "jumpRevision++", "pinMenuFor = null").forEach { assertTrue(change.contains(it)) }
        listOf("onPlay(", "onSortChange(", "onAudioLanguageHintChange(").forEach { assertFalse(change.contains(it)) }
        assertTrue(caller.contains("item(key = \"source-quick-filters\")"))
        assertTrue(caller.contains("TvFilterChip(label = label, selected = selected, onClick = click)"))
        // Empty-filter result cannot take the original no-sources early-return path and hide its reset.
        assertTrue(content.indexOf("if (total == 0)") < content.indexOf("TvSourceControlsRow("))
        assertFalse(content.contains("if (facetCount == 0) {\n        // Done"))
    }

    @Test fun `shared menu exposes All Unknown and reset without stored settings`() {
        val menu = read(main + "ui/components/SourceQuickFilterControls.kt")
        listOf("Cache:", "Reported range:", "Reported codec:", "SourceCacheFacet.entries", "SourceRangeFacet.entries",
            "SourceCodecFacet.entries", "\"All\" to null", "Reset list filters", "onChange(SourceQuickFilters())").forEach { assertTrue(menu.contains(it)) }
        listOf("rememberSaveable", "SharedPreferences", "SourcePreferencesStore", "onPlay", "onRefresh", "setSourceSort").forEach {
            assertFalse(menu.contains(it))
        }
    }

    @Test fun `All and cache-only bypass format parsing and cheap revision changes reproject visible rows`() {
        val policy = read(main + "sources/SourceQuickFilters.kt")
        val projection = between(policy, "    fun matchingGroups(", "/** Actual cache-check observations")
        val all = projection.indexOf("if (!filters.active) return groups")
        val cacheOnly = projection.indexOf("if (filters.range == null && filters.codec == null)")
        val formats = projection.indexOf("entries[index]")
        assertTrue(all >= 0 && cacheOnly > all && formats > cacheOnly)
        val fast = projection.substring(cacheOnly, formats)
        assertTrue(fast.contains("filters.acceptsCache(sourceConfirmedCacheIsCurrent(it, currentCacheRevision))"))
        assertFalse(fast.contains("sourceQuickFilterFacts("))
        assertTrue(policy.contains("private val entries by lazy"))
        listOf("ui/screens/DetailScreen.kt", "ui/tv/TvSourceList.kt").forEach { caller ->
            val source = read(main + caller)
            assertTrue(source.contains("remember(facetIndex, quickFilters, currentCacheRevision)"))
            assertTrue(source.contains("facetIndex.matchingGroups(quickFilters, currentCacheRevision)"))
        }
        assertFalse(policy.contains("NativeProviderAccess.read("))
        assertFalse(policy.contains("currentCredentialRevision("))
    }
}
