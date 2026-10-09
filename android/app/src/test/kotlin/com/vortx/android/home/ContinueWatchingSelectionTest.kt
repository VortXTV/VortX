package com.vortx.android.home

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.engine.EngineState
import com.vortx.android.engine.nativeContinueWatchingItem
import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.profile.ProfileDiscoveryPreferences
import com.vortx.android.profile.UserProfile
import com.vortx.android.profile.eligibleLegacyContinueWatchingMigration
import com.vortx.android.profile.sameContinueWatchingMigrationAuthority
import com.vortx.android.profile.ContinueWatchingMigrationCheckpoint
import com.vortx.android.profile.NativeProfileGateway
import com.vortx.android.profile.pendingContinueWatchingDiscoveryCapture
import com.vortx.android.model.PreferredEpisode
import com.vortx.android.ui.viewmodel.detailPreferredEpisodeForAdmission
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.advanceTimeBy
import com.vortx.android.player.warm.continueWatchingWarmAdmission
import com.vortx.android.ui.normalizeHomeCatalogs
import com.vortx.android.ui.components.PosterCardMenu
import com.vortx.android.ui.components.posterMenuFor
import org.junit.Assert.*
import org.junit.Test
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

class ContinueWatchingSelectionTest {
    private val now = parseContinueWatchingActivity("2026-10-09T00:00:00Z")!!
    private fun item(id: String, at: Long? = now) = MetaItem(id, MediaType.MOVIE, id, continueWatchingActivityAtMillis = at)

    @Test fun `new profile defaults and unknown source fail closed`() {
        assertEquals(ContinueWatchingSource.LOCAL, ContinueWatchingSource.fromRaw(null))
        assertEquals(ContinueWatchingWindow.ITEMS_20, ContinueWatchingWindow.fromRaw(null))
        assertEquals(ContinueWatchingSource.UNKNOWN, ContinueWatchingSource.fromRaw("stremio"))
        assertEquals(listOf("last90Days", "20", "40", "60", "80", "100"), ContinueWatchingWindow.entries.map { it.raw })
    }

    @Test fun `all count windows honor caps newest ordering and unknown clocks`() {
        val items = (0 until 130).map { item("item$it", now - it) }.reversed() + item("unknown", null)
        ContinueWatchingWindow.entries.filter { it.cap != null }.forEach { window ->
            val bounded = boundContinueWatching(items, window, now)
            assertEquals(window.cap, bounded.size)
            assertEquals("item0", bounded.first().id)
            assertEquals("item${window.cap!! - 1}", bounded.last().id)
        }
        assertEquals(listOf("dated", "unknown"), boundContinueWatching(listOf(item("unknown", null), item("dated")), ContinueWatchingWindow.ITEMS_20, now).map { it.id })
    }

    @Test fun `production retained engine decoder preserves over one hundred dated progress rows before window`() {
        val payload = JSONObject().put("items", JSONArray((0 until 125).map { index ->
            JSONObject().put("_id", "tt${1000000 + index}").put("type", "movie").put("name", "Real projection $index")
                .put("state", JSONObject().put("timeOffset", 1000).put("duration", 10000)
                    .put("lastWatched", Instant.ofEpochMilli(now - index * 1000L).toString()))
        })).toString()
        val decoded = EngineState.parseContinueWatchingStrict(payload).getOrThrow()
        assertEquals(125, decoded.size)
        assertEquals(100, boundContinueWatching(decoded, ContinueWatchingWindow.ITEMS_100, now).size)
        assertEquals(125, boundContinueWatching(decoded, ContinueWatchingWindow.LAST_90_DAYS, now).size)
        assertEquals(now, decoded.first().continueWatchingActivityAtMillis)
    }

    @Test fun `actual native and retained parsers preserve clocked zero rewind and exact episode without invented offsets`() {
        val native = nativeContinueWatchingItem(JSONObject().put("metaId", "tt1000001").put("type", "series")
            .put("name", "Clocked rewind").put("videoId", "tt1000001:3:8").put("offsetMs", 0)
            .put("durationMs", 2700000).put("updatedAt", now), emptyList())
        assertEquals(0.0, native.resumeSeconds!!, 0.0)
        assertEquals(PreferredEpisode(3, 8, "tt1000001:3:8"), native.preferredEpisode)
        assertEquals(listOf(native), boundContinueWatching(listOf(native), ContinueWatchingWindow.LAST_90_DAYS, now))
        val retainedRows = JSONArray().put(
            JSONObject().put("_id", "imdb:tt1000001").put("type", "series").put("name", "Older positive progress")
                .put("state", JSONObject().put("timeOffset", 120000).put("duration", 2700000)
                    .put("video_id", "tt1000001:3:7").put("lastWatched", Instant.ofEpochMilli(now - 1000).toString()))).put(
            JSONObject().put("_id", "tt1000001").put("type", "series").put("name", "Clocked rewind")
                .put("state", JSONObject().put("timeOffset", 0).put("duration", 2700000)
                    .put("video_id", "tt1000001:3:8").put("lastWatched", Instant.ofEpochMilli(now).toString())))
        val retained = EngineState.parseContinueWatchingStrict(JSONObject().put("items", retainedRows).toString()).getOrThrow().single()
        assertEquals(0.0, retained.resumeSeconds!!, 0.0); assertNull(retained.progress)
        assertEquals(native.preferredEpisode, retained.preferredEpisode)
        val unknown = nativeContinueWatchingItem(JSONObject().put("metaId", "tt1000001").put("type", "series")
            .put("name", "Unknown episode").put("videoId", "tt1000001:unknown").put("offsetMs", 0)
            .put("durationMs", 0), emptyList())
        assertNull(unknown.preferredEpisode); assertNull(unknown.continueWatchingActivityAtMillis)
        assertTrue(boundContinueWatching(listOf(unknown), ContinueWatchingWindow.LAST_90_DAYS, now).isEmpty())
    }

    @Test fun `ninety days includes exact boundary excludes unknown old and future timestamps`() {
        val boundary = now - 90L * 24 * 60 * 60 * 1000
        val bounded = boundContinueWatching(listOf(item("old", boundary - 1), item("edge", boundary), item("today"),
            item("unknown", null), item("future", now + 1)), ContinueWatchingWindow.LAST_90_DAYS, now)
        assertEquals(listOf("today", "edge"), bounded.map { it.id })
        assertNull(parseContinueWatchingActivity("not-a-clock"))
        assertEquals(parseContinueWatchingActivity("2026-10-09T00:00:00Z"), parseContinueWatchingActivity("2026-10-09T02:00:00+02:00"))
    }

    @Test fun `service selection replaces primary row and disconnected remote retains explicit status`() {
        val rows = listOf(Catalog("continue", "Continue Watching", listOf(item("local"))),
            Catalog(TRAKT_CONTINUE_WATCHING_CATALOG_ID, "Old Trakt", listOf(item("old"))), Catalog("ordinary", "Popular", listOf(item("ordinary"))))
        val remote = withSelectedContinueWatchingRail(rows, ContinueWatchingSelection(ContinueWatchingSource.SIMKL), listOf(item("remote")), null, now)
        assertEquals(listOf("continue", "ordinary"), remote.map { it.id })
        assertEquals(listOf("remote"), remote.first().items.map { it.id })
        assertTrue(remote.first().readOnly)
        assertEquals(PosterCardMenu.NONE, posterMenuFor(remote.first()))
        val disconnected = withSelectedContinueWatchingRail(rows, ContinueWatchingSelection(ContinueWatchingSource.TRAKT), emptyList(), "Connect Trakt", now)
        assertTrue(disconnected.first().items.isEmpty())
        assertEquals("Connect Trakt", normalizeHomeCatalogs(disconnected).first().statusMessage)
    }

    @Test fun `migration requires exact acknowledged profile account and session before default projection`() {
        val a = UserProfile(name = "A", avatar = "a", isOwner = true)
        val b = UserProfile(name = "B", avatar = "b", usesOwnAccount = true)
        assertTrue(eligibleLegacyContinueWatchingMigration(a, a, a.id, false, true, true))
        assertFalse(eligibleLegacyContinueWatchingMigration(null, a, a.id, false, true, true))
        assertFalse(eligibleLegacyContinueWatchingMigration(a, b, b.id, false, true, true))
        assertFalse(eligibleLegacyContinueWatchingMigration(a, a, a.id, true, true, true))
        assertFalse(eligibleLegacyContinueWatchingMigration(a, a, a.id, false, true, false))
        assertFalse(eligibleLegacyContinueWatchingMigration(a.copy(isOwner = false), a, a.id, false, true, true))
        assertFalse(eligibleLegacyContinueWatchingMigration(a, a.copy(discovery = ProfileDiscoveryPreferences(continueWatchingSource = "local")), a.id, false, true, true))
    }

    @Test fun `owner and preference and session receipts distinguish retired content`() {
        val owner = ContinueWatchingOwner("profile-a", "slot-a", "account-a", true, 1)
        assertTrue(continueWatchingOwnerIsKnown(owner, "profile-a"))
        assertFalse(continueWatchingOwnerIsKnown(owner.copy(principal = "native-unavailable"), "profile-a"))
        assertFalse(continueWatchingOwnerIsKnown(owner, "profile-b"))
        val permit = ContinueWatchingPermit(owner, "profile-a", "signed-in:account-a", ContinueWatchingSelection(ContinueWatchingSource.SIMKL), 1)
        assertTrue(continueWatchingPermitIsCurrent(permit, permit, owner, "capture", "capture"))
        listOf(permit.copy(owner = owner.copy(revision = 2)), permit.copy(selection = permit.selection.copy(revision = 1)),
            permit.copy(sessionEpoch = 2), permit.copy(profileId = "profile-b"), permit.copy(accountId = "signed-in:account-b"),
            permit.copy(selection = permit.selection.copy(source = ContinueWatchingSource.TRAKT)), permit.copy(sessionEpoch = null))
            .forEach { retired -> assertFalse(continueWatchingPermitIsCurrent(permit, retired, retired.owner, "capture", "capture")) }
        assertFalse(continueWatchingPermitIsCurrent(permit, permit, owner, "old", "new"))
        assertFalse(continueWatchingPermitIsCurrent(permit, permit, null, "capture", "capture"))
    }

    @Test fun `first migration capture cannot adopt same profile roster from another account generation`() {
        assertTrue(sameContinueWatchingMigrationAuthority("account-a:1", "account-a:1", 7, 7))
        assertFalse(sameContinueWatchingMigrationAuthority(null, "account-b:2", null, 7))
        assertFalse(sameContinueWatchingMigrationAuthority("account-a:1", "account-b:2", 7, 7))
        assertFalse(sameContinueWatchingMigrationAuthority("account-a:1", "account-a:2", 7, 7))
        assertFalse(sameContinueWatchingMigrationAuthority("account-a:1", "account-a:1", 7, 8))
    }

    @Test fun `same identity remote source and account replacements stay outside generic hero artwork`() {
        val remoteA = Catalog("continue", "SIMKL", listOf(item("same").copy(continueWatchingPermit = "a")), readOnly = true)
        val remoteB = remoteA.copy(items = listOf(item("same").copy(continueWatchingPermit = "b")))
        val ordinary = Catalog("popular", "Popular", listOf(item("ordinary")))
        assertEquals(listOf(ordinary), continueWatchingHeroCatalogs(listOf(remoteA, ordinary)))
        assertEquals(listOf(ordinary), continueWatchingHeroCatalogs(listOf(remoteB, ordinary)))
        assertEquals(listOf(remoteA.copy(readOnly = false)), continueWatchingHeroCatalogs(listOf(remoteA.copy(readOnly = false))))
        assertFalse(continueWatchingMayUseGenericEnrichment(remoteA.items.single()))
        assertFalse(continueWatchingMayUseGenericEnrichment(remoteB.items.single()))
        val localA = remoteA.items.single().copy(progress = .1f)
        val localB = localA.copy(progress = .9f, continueWatchingPermit = "local-owner-b")
        assertFalse(continueWatchingMayUseGenericEnrichment(localA)); assertFalse(continueWatchingMayUseGenericEnrichment(localB))
        assertTrue(continueWatchingMayUseGenericEnrichment(ordinary.items.single()))
    }

    @Test fun `captured remote Detail hint and delayed source admission expire on preference ABA`() = runBlocking {
        val owner = ContinueWatchingOwner("profile-a", "slot-a", "account-a", true, 1)
        val captured = ContinueWatchingPermit(owner, "profile-a", "signed-in:account-a", ContinueWatchingSelection(ContinueWatchingSource.SIMKL), 7)
        var current = captured
        val admission = ContinueWatchingAdmission { continueWatchingPermitIsCurrent(captured, current, current.owner, "capture", "capture") }
        val hint = PreferredEpisode(2, 3)
        assertEquals(hint, detailPreferredEpisodeForAdmission(hint, admission))
        assertNull(saveableContinueWatchingEpisode(hint, admission))
        assertEquals(hint, saveableContinueWatchingEpisode(hint, null))
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        var discarded = false
        val pending = async { continueWatchingAdmittedResult(admission, discard = { _: String -> discarded = true }) {
            entered.complete(Unit); release.await(); Result.success("resolved-source")
        } }
        entered.await()
        current = current.copy(selection = current.selection.copy(source = ContinueWatchingSource.TRAKT, revision = 1))
        current = current.copy(selection = current.selection.copy(source = ContinueWatchingSource.SIMKL, revision = 2))
        release.complete(Unit)
        assertTrue(pending.await().isFailure); assertTrue(discarded)
        assertNull(detailPreferredEpisodeForAdmission(hint, admission))
        assertEquals(hint, detailPreferredEpisodeForAdmission(hint, null)) // ordinary user-selected route
    }

    @Test fun `published local CW admission fences delayed Detail and direct resume after source profile or window retirement`() = runBlocking {
        val owner = ContinueWatchingOwner("profile-a", "slot-a", "account-a", true, 1)
        val captured = ContinueWatchingPermit(owner, "profile-a", "signed-in:account-a", ContinueWatchingSelection(), null)
        listOf(captured.copy(selection = captured.selection.copy(source = ContinueWatchingSource.SIMKL, revision = 1)),
            captured.copy(owner = owner.copy(profileId = "profile-b", revision = 2), profileId = "profile-b"),
            captured.copy(selection = captured.selection.copy(window = ContinueWatchingWindow.ITEMS_100, revision = 2)))
            .forEach { replacement ->
                var current = captured
                val admission = ContinueWatchingAdmission { continueWatchingPermitIsCurrent(captured, current, current.owner, "local", "local") }
                val card = continueWatchingItemWithAdmission(item("local").copy(preferredEpisode = PreferredEpisode(3, 8)), "local", admission)
                assertSame(admission, card.continueWatchingAdmission)
                assertEquals(card.preferredEpisode, detailPreferredEpisodeForAdmission(card.preferredEpisode, card.continueWatchingAdmission))
                val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
                var finalAdmissions = 0; var discarded = 0
                val pending = async { continueWatchingAdmittedResult(card.continueWatchingAdmission, discard = { _: String -> discarded++ }) {
                    entered.complete(Unit); release.await(); Result.success("inert-resolved-source")
                }.also { if (it.isSuccess) finalAdmissions++ } }
                entered.await(); current = replacement; release.complete(Unit)
                assertTrue(pending.await().isFailure); assertEquals(0, finalAdmissions); assertEquals(1, discarded)
                assertNull(detailPreferredEpisodeForAdmission(card.preferredEpisode, card.continueWatchingAdmission))
            }
    }

    @Test fun `synchronous source writers retire ABA before deferred preference callbacks`() {
        val before = ContinueWatchingSelectionRevision.current()
        ContinueWatchingSelectionRevision.changed() // SIMKL -> Trakt write admission
        ContinueWatchingSelectionRevision.changed() // Trakt -> SIMKL write admission
        assertTrue(ContinueWatchingSelectionRevision.current() > before)
    }

    @Test fun `migration retries only same capture and publishes only exact durable checkpoint`() {
        val profile = UserProfile(name = "Existing", avatar = "moon", isOwner = true)
        val state = ContinueWatchingMigrationCheckpoint<String>()
        state.capture(profile.id, "account-a:1", 7)
        assertNull(state.attempt(profile, profile.id, "account-a:1", 7, save = { error("secure save failed") }, authorityIsCurrent = { true }))
        assertNotNull(state.witness)
        val saved = state.attempt(profile, profile.id, "account-a:1", 7,
            save = { NativeProfileGateway.Projection(listOf(it), profile.id) }, authorityIsCurrent = { true })!!
        assertEquals("trakt", saved.profiles.single().discovery?.continueWatchingSource)
        assertEquals("20", saved.profiles.single().discovery?.continueWatchingWindow); assertNull(state.witness)
        state.capture(profile.id, "account-a:1", 7)
        var saves = 0
        assertNull(state.attempt(profile, profile.id, "account-b:2", 7, save = { saves++; null }, authorityIsCurrent = { true }))
        assertEquals(0, saves); assertNull(state.witness)
        state.capture(profile.id, "account-a:1", 7)
        assertNull(state.attempt(profile, profile.id, "account-a:1", 7,
            save = { NativeProfileGateway.Projection(listOf(it), profile.id) }, authorityIsCurrent = { true }, readbackIsCurrent = { false }))
        assertNotNull(state.witness)
        assertNull(state.attempt(profile.copy(discovery = ProfileDiscoveryPreferences(continueWatchingSource = "local")), profile.id,
            "account-a:1", 7, save = { saves++; null }, authorityIsCurrent = { true }))
        assertNull(state.witness)
        state.capture(profile.id, "account-a:1", 7)
        var authority = true
        assertNull(state.attempt(profile, profile.id, "account-a:1", 7,
            save = { NativeProfileGateway.Projection(listOf(it), profile.id) }, authorityIsCurrent = { authority },
            readbackIsCurrent = { authority = false; true }))
        assertNull(state.witness)
    }

    @Test fun `unrelated discovery edit preserves failed migration witness and joins exact checkpoint`() {
        val profile = UserProfile(name = "Existing", avatar = "moon", isOwner = true,
            discovery = ProfileDiscoveryPreferences(continueWatchingWindow = "40"))
        val state = ContinueWatchingMigrationCheckpoint<String>()
        state.capture(profile.id, "account-a:1", 7)
        assertNull(state.attempt(profile, profile.id, "account-a:1", 7, save = { null }, authorityIsCurrent = { true }))
        state.retainDiscoveryCapture(profile,
            ProfileDiscoveryPreferences(hiddenCatalogs = listOf("hide-this"), continueWatchingSource = "local", continueWatchingWindow = "20"))
        val saved = state.attempt(profile, profile.id, "account-a:1", 7,
            save = { NativeProfileGateway.Projection(listOf(it), profile.id) }, authorityIsCurrent = { true })!!
        val discovery = saved.profiles.single().discovery!!
        assertEquals("trakt", discovery.continueWatchingSource); assertEquals("40", discovery.continueWatchingWindow)
        assertEquals(listOf("hide-this"), discovery.hiddenCatalogs); assertNull(state.witness)
    }

    @Test fun `pending discovery survives two failed actual checkpoints and a fresh same authority projection retry`() {
        val old = UserProfile(name = "Existing", avatar = "moon", isOwner = true,
            discovery = ProfileDiscoveryPreferences(catalogOrder = listOf("old"), continueWatchingWindow = "40"))
        val state = ContinueWatchingMigrationCheckpoint<String>()
        state.capture(old.id, "account-a:1", 7)
        assertNull(state.attempt(old, old.id, "account-a:1", 7, save = { null }, authorityIsCurrent = { true }))
        // This is the same retained-capture hook used by ProfileStore before its guarded save.
        state.retainDiscoveryCapture(old, ProfileDiscoveryPreferences(catalogOrder = listOf("user-edited", "old"),
            continueWatchingSource = "local", continueWatchingWindow = "20"))
        assertNull(state.attempt(old, old.id, "account-a:1", 7, save = { null }, authorityIsCurrent = { true }))
        val freshProjection = old.copy(discovery = old.discovery!!.copy(catalogOrder = listOf("old")))
        val acknowledged = state.attempt(freshProjection, old.id, "account-a:1", 7,
            save = { NativeProfileGateway.Projection(listOf(it), old.id) }, authorityIsCurrent = { true })!!
        val discovery = acknowledged.profiles.single().discovery!!
        assertEquals("trakt", discovery.continueWatchingSource); assertEquals("40", discovery.continueWatchingWindow)
        assertEquals(listOf("user-edited", "old"), discovery.catalogOrder); assertNull(state.witness)
        state.capture(old.id, "account-a:1", 7)
        state.retainDiscoveryCapture(old, ProfileDiscoveryPreferences(catalogOrder = listOf("private-a")))
        assertNull(state.attempt(freshProjection, old.id, "account-b:2", 7, save = { error("must not save") }, authorityIsCurrent = { true }))
        state.capture(old.id, "account-b:2", 9)
        val other = state.attempt(freshProjection, old.id, "account-b:2", 9,
            save = { NativeProfileGateway.Projection(listOf(it), old.id) }, authorityIsCurrent = { true })!!
        assertEquals(listOf("old"), other.profiles.single().discovery?.catalogOrder)
    }

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    @Test fun `TV focus dwell rejects local to remote profile and preference ABA before warming`() = runTest {
        val owner = ContinueWatchingOwner("profile-a", "slot-a", "account-a", true, 1)
        val captured = ContinueWatchingPermit(owner, "profile-a", "signed-in:account-a", ContinueWatchingSelection(), null)
        val retired = listOf(captured.copy(selection = captured.selection.copy(source = ContinueWatchingSource.SIMKL, revision = 1)),
            captured.copy(owner = owner.copy(profileId = "profile-b", revision = 2), profileId = "profile-b"),
            captured.copy(selection = captured.selection.copy(revision = 2)))
        retired.forEach { replacement ->
            var current = captured
            val admission = ContinueWatchingAdmission { continueWatchingPermitIsCurrent(captured, current, current.owner, "capture", "capture") }
            val pending = async { continueWatchingFocusDwell(admission) { delay(500) } }
            runCurrent(); current = replacement; advanceTimeBy(500); runCurrent()
            assertFalse(pending.await())
        }
    }

    @Test fun `CW warm IO source await never adopts replacement source profile or preference capture`() = runBlocking {
        val owner = ContinueWatchingOwner("profile-a", "slot-a", "account-a", true, 1)
        val captured = ContinueWatchingPermit(owner, "profile-a", "signed-in:account-a", ContinueWatchingSelection(), null)
        listOf(captured.copy(selection = captured.selection.copy(source = ContinueWatchingSource.TRAKT, revision = 1)),
            captured.copy(owner = owner.copy(principal = "account-b", revision = 2)),
            captured.copy(selection = captured.selection.copy(revision = 2))).forEach { replacement ->
            var current = captured; var rangeReads = 0
            val admission = ContinueWatchingAdmission { continueWatchingPermitIsCurrent(captured, current, current.owner, "capture", "capture") }
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            val pending = async { continueWatchingWarmAdmission(admission::isCurrent,
                streams = { entered.complete(Unit); release.await(); "inert-direct-url" }, warm = { rangeReads++ }) }
            entered.await(); current = replacement; release.complete(Unit)
            assertFalse(pending.await()); assertEquals(0, rangeReads)
        }
        var reads = 0
        assertTrue(continueWatchingWarmAdmission({ true }, streams = { "inert" }, warm = { reads++ }))
        assertEquals(1, reads)
    }
}
