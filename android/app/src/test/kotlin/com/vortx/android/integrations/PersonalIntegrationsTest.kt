package com.vortx.android.integrations

import com.vortx.android.home.ImportedCatalogCodec
import com.vortx.android.home.ImportedListCatalog
import com.vortx.android.home.ImportedListProvider
import com.vortx.android.home.ImportedPrivateRows
import com.vortx.android.home.ImportedCatalogPublication
import com.vortx.android.home.IMPORTED_CATALOG_PREFIX
import com.vortx.android.home.admitImportedCatalogPublication
import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Offline tests run actual clients/controllers/codecs. Fixtures contain synthetic IDs and no credentials. */
class PersonalIntegrationsTest {
    private val movie = RatingTitle(false, "tt1000001", 101)
    private val show = RatingTitle(true, "tt1000002", 102)

    @Test fun `Trakt read dispatch and changed rating use real routes and title ids`() = runBlocking {
        val access = FakeAccess()
        val controller = PersonalRatingsController(access)
        val owner = access.owner(RatingProvider.TRAKT)!!
        access.respond = { request -> when (request.path) {
            "/sync/ratings/movies" -> ok("""[{"type":"movie","rating":6,"rated_at":"2026-01-01T00:00:00Z","movie":{"ids":{"imdb":"tt1000001","tmdb":101}}}]""")
            "/sync/ratings/shows" -> ok("[]")
            else -> ok("""{"updated":{"movies":1},"not_found":{"movies":[]}}""")
        } }
        assertTrue(controller.refresh(owner))
        assertEquals(6, controller.state(owner, movie).value)
        assertTrue(controller.set(owner, movie, 9))
        assertEquals(9, controller.state(owner, movie).value)
        assertEquals(listOf("GET /sync/ratings/movies", "GET /sync/ratings/shows", "POST /sync/ratings"), access.requests.map { "${it.method} ${it.path}" })
        val payload = JSONObject(access.requests.last().body!!).getJSONArray("movies").getJSONObject(0)
        assertEquals(9, payload.getInt("rating"))
        assertEquals("tt1000001", payload.getJSONObject("ids").getString("imdb"))
        assertFalse(payload.has("season"))
    }

    @Test fun `SIMKL reads movies shows anime and writes anime as a show`() = runBlocking {
        val access = FakeAccess(RatingProvider.SIMKL)
        val controller = PersonalRatingsController(access)
        val owner = access.owner(RatingProvider.SIMKL)!!
        access.respond = { request -> when (request.path) {
            "/sync/ratings/movies/1,2,3,4,5,6,7,8,9,10" -> ok("{\"movies\":[]}")
            "/sync/ratings/shows/1,2,3,4,5,6,7,8,9,10" -> ok("{\"shows\":[]}")
            "/sync/ratings/anime/1,2,3,4,5,6,7,8,9,10" -> ok("""{"anime":[{"user_rating":8,"user_rated_at":"2026-01-01T00:00:00Z","show":{"ids":{"imdb":"tt1000002"}}}]}""")
            "/sync/ratings/remove" -> ok("")
            else -> ok("{\"added\":{\"shows\":1}}")
        } }
        assertTrue(controller.refresh(owner))
        assertEquals(8, controller.state(owner, show).value)
        assertTrue(access.requests.all { it.method == "GET" && it.body == null })
        assertEquals(listOf("movies", "shows", "anime").map { "/sync/ratings/$it/1,2,3,4,5,6,7,8,9,10" }, access.requests.map { it.path })
        assertTrue(controller.set(owner, show, 10))
        val body = JSONObject(access.requests.last().body!!)
        assertTrue(body.has("shows"))
        assertFalse(body.has("anime"))
        assertTrue(controller.set(owner, show, null))
        assertNull(controller.state(owner, show).value)
        val remove = JSONObject(access.requests.last().body!!).getJSONArray("shows").getJSONObject(0)
        assertFalse(remove.has("rating"))
        assertFalse(remove.has("rated_at"))
    }

    @Test fun `invalid values and unsupported title ids cannot dispatch`() = runBlocking {
        val access = FakeAccess()
        val controller = PersonalRatingsController(access)
        val owner = access.owner(RatingProvider.TRAKT)!!
        assertFalse(controller.set(owner, movie, 0))
        assertFalse(controller.set(owner, movie, 11))
        assertNull(RatingTitle.fromId("tmdb:tv:12", false))
        assertNull(RatingTitle.fromId("ttbad", false))
        assertEquals(12, RatingTitle.fromId("tmdb:tv:12", true)?.tmdb)
        assertTrue(access.requests.isEmpty())
    }

    @Test fun `not found 200 token failure and server failure do not claim rating saved`() = runBlocking {
        val access = FakeAccess()
        val controller = PersonalRatingsController(access)
        val owner = access.owner(RatingProvider.TRAKT)!!
        access.respond = { ok("{\"added\":{\"movies\":1}}") }
        assertTrue(controller.set(owner, movie, 4))
        for (failure in listOf(null, IntegrationsHttp.Response(401, ""), IntegrationsHttp.Response(503, ""),
            ok("{\"added\":{\"movies\":0},\"not_found\":{\"movies\":[{\"ids\":{\"tmdb\":101}}]}}"), ok("{}"))) {
            access.respond = { failure }
            assertFalse(controller.set(owner, movie, 8))
            assertEquals(4, controller.state(owner, movie).value)
            assertFalse(controller.state(owner, movie).busy)
            assertTrue(controller.state(owner, movie).message!!.contains("could not"))
        }
    }

    @Test fun `duplicate in flight rating tap is refused at controller boundary`() = runBlocking {
        val access = FakeAccess()
        val pending = CompletableDeferred<IntegrationsHttp.Response>()
        access.respond = { pending.await() }
        val controller = PersonalRatingsController(access)
        val owner = access.owner(RatingProvider.TRAKT)!!
        val first = async(start = CoroutineStart.UNDISPATCHED) { controller.set(owner, movie, 7) }
        assertTrue(controller.state(owner, movie).busy)
        assertFalse(controller.set(owner, movie, 3))
        assertEquals(1, access.requests.size)
        pending.complete(ok("{\"added\":{\"movies\":1}}"))
        assertTrue(first.await())
        assertEquals(7, controller.state(owner, movie).value)
    }

    @Test fun `already removed Trakt rating clears stale cache idempotently`() = runBlocking {
        val access = FakeAccess()
        val controller = PersonalRatingsController(access)
        val owner = access.active!!
        access.respond = { ok("{\"added\":{\"movies\":1}}") }
        assertTrue(controller.set(owner, movie, 7))
        access.respond = { ok("{\"deleted\":{\"movies\":0},\"not_found\":{\"movies\":[]}}") }
        assertTrue(controller.set(owner, movie, null))
        assertNull(controller.state(owner, movie).value)
    }

    @Test fun `account profile preference or unlink change drops late rating completion`() = runBlocking {
        for (change in listOf<(ExternalIntegrationOwner) -> ExternalIntegrationOwner?>(
            { it.copy(sessionEpoch = 2) }, { it.copy(profileId = "profile-b") },
            { it.copy(accountRevision = 2) }, { it.copy(preferenceRevision = 2) }, { null })) {
            val access = FakeAccess()
            val old = access.active!!
            val pending = CompletableDeferred<IntegrationsHttp.Response>()
            access.respond = { pending.await() }
            val controller = PersonalRatingsController(access)
            val first = async(start = CoroutineStart.UNDISPATCHED) { controller.set(old, movie, 8) }
            access.active = change(old)
            pending.complete(ok("{\"added\":{\"movies\":1}}"))
            assertFalse(first.await())
            assertNull(controller.state(old, movie).value)
            access.active?.let { assertNull(controller.state(it, movie).value) }
        }
    }

    @Test fun `old read cannot replace a newer local rating or erase a missing title`() = runBlocking {
        val access = FakeAccess()
        val oldRead = CompletableDeferred<IntegrationsHttp.Response>()
        val owner = access.active!!
        val controller = PersonalRatingsController(access)
        access.respond = { if (it.path == "/sync/ratings/movies") oldRead.await() else if (it.method == "GET") ok("[]") else ok("{\"added\":{\"movies\":1}}") }
        val refresh = async(start = CoroutineStart.UNDISPATCHED) { controller.refresh(owner) }
        assertTrue(controller.set(owner, movie, 10))
        oldRead.complete(ok("""[{"type":"movie","rating":1,"rated_at":"2026-01-01T00:00:00Z","movie":{"ids":{"imdb":"tt1000001"}}}]"""))
        assertFalse(refresh.await())
        assertEquals(10, controller.state(owner, movie).value)
        access.respond = { ok("[]") }
        assertTrue(controller.refresh(owner))
        assertEquals(10, controller.state(owner, movie).value)
    }

    @Test fun `failed read preserves previous score and clear has a tombstone`() = runBlocking {
        val access = FakeAccess()
        val owner = access.active!!
        val controller = PersonalRatingsController(access)
        access.respond = { ok("{\"added\":{\"movies\":1}}") }
        assertTrue(controller.set(owner, movie, 5))
        access.respond = { ok("{\"error\":\"unavailable\"}") }
        assertFalse(controller.refresh(owner))
        assertEquals(5, controller.state(owner, movie).value)
        access.respond = { ok("{\"deleted\":{\"movies\":1}}") }
        assertTrue(controller.set(owner, movie, null))
        access.respond = { if (it.path.endsWith("movies")) ok("""[{"rating":9,"rated_at":"2026-01-01T00:00:00Z","movie":{"ids":{"imdb":"tt1000001"}}}]""") else ok("[]") }
        assertTrue(controller.refresh(owner))
        assertNull(controller.state(owner, movie).value)
    }

    @Test fun `list picker dispatches exact personal liked and settings reads deduplicating own like`() = runBlocking {
        val access = listAccess()
        val controller = TraktMyListsController(access, { true }, {})
        controller.load()
        assertEquals(listOf("/users/settings", "/users/me/lists", "/users/likes/lists?limit=100"), access.requests.map { it.path })
        assertTrue(access.requests.all { it.method == "GET" && it.body == null })
        assertEquals(2, controller.state.value.lists.size)
        assertFalse(controller.state.value.lists.first().liked)
        assertTrue(controller.state.value.lists.last().liked)
        assertEquals("friends", controller.state.value.lists.last().privacy)
    }

    @Test fun `authenticated private import uses refreshed privacy and stores no credential or private metadata`() = runBlocking {
        val access = listAccess()
        val registered = mutableListOf<ImportedListCatalog>()
        val controller = TraktMyListsController(access, { registered.add(it) }, {})
        controller.load()
        val list = controller.state.value.lists.first()
        assertEquals("public", list.privacy)
        assertTrue(controller.add(access.active!!, list))
        val imported = registered.single()
        assertTrue(imported.requiresConnection) // Metadata changed from public to private after picker load.
        assertEquals(access.active, imported.connectionOwner)
        assertEquals(2, imported.items.size)
        assertEquals(MediaType.SERIES, imported.items.last().type)
        assertEquals("[]", ImportedCatalogCodec.encode(registered))
        assertEquals(listOf("/users/synthetic-user/lists/one", "/users/synthetic-user/lists/one/items/movie,show?extended=full"), access.requests.takeLast(2).map { it.path })
    }

    @Test fun `unlink removes private rows and they cannot reappear when prior owner returns`() {
        var owner: ExternalIntegrationOwner? = FakeAccess().active
        val captured = owner!!
        val rows = ImportedPrivateRows { it == owner }
        val catalog = privateCatalog(captured)
        assertTrue(rows.register(catalog))
        assertTrue(rows.register(catalog))
        assertEquals(1, rows.visible().size)
        owner = null
        assertTrue(rows.visible().isEmpty())
        assertFalse(rows.register(catalog))
        owner = captured
        assertTrue(rows.visible().isEmpty())
        assertTrue(ImportedCatalogCodec.decode(ImportedCatalogCodec.encode(listOf(catalog))).isEmpty())
    }

    @Test fun `private rows reject a missing or different owner`() {
        val captured = FakeAccess().active!!
        val rows = ImportedPrivateRows { it == captured.copy(profileId = "profile-b") }
        assertFalse(rows.register(privateCatalog(captured)))
        assertFalse(rows.register(privateCatalog(captured).copy(connectionOwner = null)))
        assertTrue(rows.visible().isEmpty())
    }

    @Test fun `final Home publication drops old private rows before async registry collector`() {
        val owner = FakeAccess().active!!
        val private = privateCatalog(owner)
        val public = private.copy(id = "imported:trakt:synthetic-user:public", requiresConnection = false, connectionOwner = null)
        val captured = ImportedCatalogPublication(listOf(private, public))
        val other = Catalog("other", "Public catalog", emptyList())
        val rendered = listOf(other, Catalog("$IMPORTED_CATALOG_PREFIX${private.id}", private.title, private.items),
            Catalog("$IMPORTED_CATALOG_PREFIX${public.id}", public.title, public.items))
        // Registry observer deliberately has NOT run. Only final admission sees replacement ownership.
        val afterUnlink = admitImportedCatalogPublication(captured, captured, rendered) { false }
        assertEquals(listOf(other.id, "$IMPORTED_CATALOG_PREFIX${public.id}"), afterUnlink.map { it.id })
        val replacement = owner.copy(profileId = "profile-b", accountRevision = 2)
        val afterProfile = admitImportedCatalogPublication(captured, captured, rendered) { it == replacement }
        assertEquals(afterUnlink, afterProfile)
        assertEquals(rendered, admitImportedCatalogPublication(captured, captured, rendered) { it == owner })
    }

    @Test fun `final Home publication cannot restore removed or replaced list content`() {
        val owner = FakeAccess().active!!
        val catalog = privateCatalog(owner)
        val captured = ImportedCatalogPublication(listOf(catalog))
        val row = Catalog("$IMPORTED_CATALOG_PREFIX${catalog.id}", catalog.title, catalog.items)
        assertTrue(admitImportedCatalogPublication(captured, ImportedCatalogPublication(emptyList()), listOf(row)) { true }.isEmpty())
        val replacement = ImportedCatalogPublication(listOf(catalog.copy(title = "Replacement")))
        assertTrue(admitImportedCatalogPublication(captured, replacement, listOf(row)) { true }.isEmpty())
    }

    @Test fun `SIMKL shared POST pacing serializes writes and rechecks owner after suspension`() = runBlocking {
        var time = 0L
        val sends = mutableListOf<Long>()
        var active = true
        var revokeWhileWaiting = false
        val pacer = SimklPostPacer(nowMillis = { time }, waitMillis = { delay ->
            time += delay
            if (revokeWhileWaiting) active = false
        })
        assertEquals(true, pacer.dispatch({ active }) { sends.add(time); true })
        assertEquals(true, pacer.dispatch({ active }) { sends.add(time); true })
        assertEquals(listOf(0L, 1_100L), sends)
        revokeWhileWaiting = true
        assertNull(pacer.dispatch({ active }) { sends.add(time); true })
        assertEquals(2, sends.size)
    }

    @Test fun `SIMKL pacing keeps one in-flight dispatch across different titles`() = runBlocking {
        var time = 0L
        val sends = mutableListOf<Long>()
        val hold = CompletableDeferred<Unit>()
        val pacer = SimklPostPacer(nowMillis = { time }, waitMillis = { time += it })
        val first = async(start = CoroutineStart.UNDISPATCHED) { pacer.dispatch({ true }) { sends.add(time); hold.await() } }
        val second = async(start = CoroutineStart.UNDISPATCHED) { pacer.dispatch({ true }) { sends.add(time) } }
        assertEquals(listOf(0L), sends)
        hold.complete(Unit)
        first.await(); second.await()
        assertEquals(listOf(0L, 1_100L), sends)
    }

    @Test fun `late private import after switch cannot register into new account`() = runBlocking {
        val access = listAccess()
        val registered = mutableListOf<ImportedListCatalog>()
        val controller = TraktMyListsController(access, { registered.add(it) }, {})
        controller.load()
        val list = controller.state.value.lists.first()
        val original = access.respond
        val items = CompletableDeferred<IntegrationsHttp.Response>()
        access.respond = { if (it.path.contains("/items/")) items.await() else original(it) }
        val pending = async(start = CoroutineStart.UNDISPATCHED) { controller.add(access.active!!, list) }
        access.active = access.active!!.copy(sessionEpoch = 2)
        items.complete(ok(itemsJson))
        assertFalse(pending.await())
        assertTrue(registered.isEmpty())
        assertTrue(controller.state.value.lists.isEmpty())
    }

    @Test fun `duplicate import taps are refused and removing a row only calls local store`() = runBlocking {
        val access = listAccess()
        val removed = mutableListOf<String>()
        val controller = TraktMyListsController(access, { true }, { removed.add(it) })
        controller.load()
        val owner = access.active!!
        val list = controller.state.value.lists.first()
        val original = access.respond
        val items = CompletableDeferred<IntegrationsHttp.Response>()
        access.respond = { if (it.path.contains("/items/")) items.await() else original(it) }
        val pending = async(start = CoroutineStart.UNDISPATCHED) { controller.add(owner, list) }
        val count = access.requests.size
        assertFalse(controller.add(owner, list))
        assertEquals(count, access.requests.size)
        items.complete(ok(itemsJson))
        assertTrue(pending.await())
        controller.remove(owner, list)
        assertEquals(listOf(list.id), removed)
        assertEquals(count, access.requests.size)
    }

    @Test fun `failed list refresh retains existing rows while account replacement clears them`() = runBlocking {
        val access = listAccess()
        val controller = TraktMyListsController(access, { true }, {})
        controller.load()
        val prior = controller.state.value.lists
        access.respond = { null }
        controller.load()
        assertEquals(prior, controller.state.value.lists)
        assertNotNull(controller.state.value.message)
        access.active = access.active!!.copy(accountRevision = 2)
        controller.reconcile()
        assertTrue(controller.state.value.lists.isEmpty())
        assertNull(controller.state.value.message)
    }

    @Test fun `list parser refuses traversal and does not invent owner or public privacy`() {
        val missing = JSONObject("""{"name":"Missing owner","ids":{"slug":"one"}}""")
        assertNull(TraktMyListsWire.list(missing, false, null))
        assertNull(TraktMyListsWire.list(missing, false, "../other"))
        assertEquals("private", TraktMyListsWire.list(missing, false, "synthetic-user")?.privacy)
        assertEquals("42", TraktMyListsWire.list(JSONObject("""{"name":"Numeric","ids":{"trakt":42}}"""), false, "synthetic-user")?.slug)
        assertNull(TraktMyListsWire.list(JSONObject("""{"name":"Unsafe","ids":{"slug":"one?token=none"}}"""), false, "synthetic-user"))
    }

    @Test fun `ratings aliases preserve movie show separation and invalid values are dropped`() {
        val parsed = PersonalRatingsWire.parse(RatingProvider.SIMKL, """{"movies":[{"user_rating":6,"movie":{"ids":{"tmdb":101}}},{"user_rating":11,"movie":{"ids":{"imdb":"tt1000001"}}}],"shows":[{"user_rating":2,"show":{"ids":{"tmdb":101}}}]}""")!!
        assertEquals(2, parsed.size)
        assertTrue(parsed[0].title.aliases.intersect(parsed[1].title.aliases).isEmpty())
        assertNull(PersonalRatingsWire.parse(RatingProvider.TRAKT, "{}"))
        assertNull(PersonalRatingsWire.parse(RatingProvider.SIMKL, "{\"movies\":{}}"))
    }

    private fun privateCatalog(owner: ExternalIntegrationOwner) = ImportedListCatalog(
        "imported:trakt:synthetic-user:one", "Synthetic private list", ImportedListProvider.TRAKT,
        "https://trakt.tv/users/synthetic-user/lists/one", listOf(MetaItem("tt1000001", MediaType.MOVIE, "Synthetic movie")),
        requiresConnection = true, connectionOwner = owner)

    private fun listAccess() = FakeAccess().apply {
        respond = { request -> when (request.path) {
            "/users/settings" -> ok("""{"user":{"ids":{"slug":"synthetic-user"}}}""")
            "/users/me/lists" -> ok("[$personalJson]")
            "/users/likes/lists?limit=100" -> ok("""[{"list":$personalJson},{"list":{"name":"Liked synthetic","ids":{"slug":"two"},"user":{"ids":{"slug":"other-user"}},"privacy":"friends"}}]""")
            "/users/synthetic-user/lists/one" -> ok(personalJson.replace("public", "private"))
            "/users/synthetic-user/lists/one/items/movie,show?extended=full" -> ok(itemsJson)
            else -> IntegrationsHttp.Response(404, "")
        } }
    }

    private data class Request(val method: String, val path: String, val body: String?)
    private class FakeAccess(provider: RatingProvider = RatingProvider.TRAKT) : ExternalIntegrationAccess {
        var active: ExternalIntegrationOwner? = ExternalIntegrationOwner(provider, 1, "profile-a", 1, 0)
        val requests = mutableListOf<Request>()
        var respond: suspend (Request) -> IntegrationsHttp.Response? = { IntegrationsHttp.Response(503, "") }
        override fun owner(provider: RatingProvider, ratings: Boolean) = active?.takeIf { it.provider == provider }
        override suspend fun request(owner: ExternalIntegrationOwner, method: String, path: String, body: String?, ratings: Boolean): IntegrationsHttp.Response? {
            if (!current(owner, ratings)) return null
            val request = Request(method, path, body)
            requests.add(request)
            // Deliberately returns late bodies: publication must independently fence the owner.
            return respond(request)
        }
    }
    private fun ok(body: String) = IntegrationsHttp.Response(200, body)
    private val personalJson = """{"name":"Synthetic one","ids":{"slug":"one"},"user":{"ids":{"slug":"synthetic-user"}},"item_count":3,"privacy":"public"}"""
    private val itemsJson = """[{"type":"movie","movie":{"title":"Synthetic movie","ids":{"imdb":"tt1000001"}}},{"type":"movie","movie":{"title":"Duplicate","ids":{"imdb":"tt1000001"}}},{"type":"show","show":{"title":"Synthetic show","ids":{"tmdb":102}}}]"""
}
