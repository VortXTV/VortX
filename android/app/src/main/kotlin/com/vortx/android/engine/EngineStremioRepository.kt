package com.vortx.android.engine

import android.content.Context
import android.util.Log
import com.vortx.android.auth.AuthIdentityStore
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.debrid.DebridResolver
import com.vortx.android.model.AuthState
import com.vortx.android.model.Catalog
import com.vortx.android.model.DiscoverResult
import com.vortx.android.model.InstalledAddon
import com.vortx.android.model.LibraryResult
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.MetaItem
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URI
import kotlin.time.Duration.Companion.seconds

/// The real engine implementation of the UI seams. Drop-in replacement for `PreviewCatalogRepository`
/// AND `PreviewAuthRepository`: it satisfies the SAME [CatalogRepository] (alias `StremioRepository`)
/// and [AuthRepository] contracts the Compose screens were built against, so wiring it in is a
/// one-line change at the injection site (see `VortXApplication`) with zero UI churn.
///
/// How it bridges the request/response gap: stremio-core is event-driven, not request/response -- a
/// Load is not one response but a STREAM of partial settlements (an immediate Loading flip, then one
/// NewState per add-on answer). One-shot calls use [loadFieldUntil]: dispatch, then re-pull the field
/// on every NewState naming it until a ready-predicate accepts the JSON (timeout falls back to the
/// current state). The Home screen goes further and collects [homeUpdates], a continuous snapshot
/// stream, so rails render incrementally and react to sign-in/sign-out live. `signIn`/`signOut`
/// dispatch whole-model broadcasts (see [EngineActions.authenticateLogin]) and additionally race a
/// `CoreEvent` sign-in error so a bad password surfaces the engine's own message.
///
/// Threading (hardened, S03): [StremioCoreNative.EventListener.onEvent] fires on a native worker thread
/// (a stremio-core tokio worker attached to the JVM, see `android_jni.rs`). [onEngineEvent] does the
/// minimum JSON parse there and publishes into two `MutableSharedFlow`s via `tryEmit`, which NEVER
/// suspends -- a slow/absent collector can never block the native callback, satisfying the engine's
/// "return promptly" contract on [StremioCoreNative.EventListener.onEvent]. Both flows use
/// `BufferOverflow.DROP_OLDEST`: if a burst of events outruns every collector (bounded buffer full),
/// we drop the STALEST entry, not the callback -- the next field pull always sees the latest state
/// regardless of which individual "it changed" notifications were conflated away. [authState] is
/// additionally re-published (off the native thread, via [engineScope]) so every subscriber gets a
/// live, conflated `StateFlow` rather than having to replay the shared-flow history themselves.
class EngineStremioRepository(
    context: Context,
    /// How long to wait for a field's NewState before falling back to the current state. The engine is
    /// local except for add-on HTTP, so a few seconds covers a cold add-on fan-out.
    private val loadTimeoutSeconds: Long = 12,
) : CatalogRepository, AuthRepository {

    private val appContext = context.applicationContext

    /// Native in-client debrid resolver: turns a raw-torrent infoHash into a DIRECT, playable HTTPS URL
    /// through the user's own debrid account (keys in EncryptedSharedPreferences). Built lazily so no
    /// key store is opened until a torrent is actually resolved; with no key configured it is a no-op
    /// and torrents keep today's behavior (a clear error the player layer surfaces).
    private val debridResolver by lazy { DebridResolver(DebridKeys(appContext)) }

    /// The Keystore-backed "who was last signed in" display cache (ANDROID-PLAN.md §0 invariant #5);
    /// the engine's own persisted `ctx.profile.auth` remains the actual source of truth, see
    /// [AuthIdentityStore]'s doc comment.
    private val identityStore by lazy { AuthIdentityStore(appContext) }

    /// Field names that changed in the most recent engine event. extraBufferCapacity + DROP_OLDEST
    /// keeps a burst of back-to-back events from ever suspending (blocking) the native callback thread
    /// that publishes them -- see the class doc.
    private val changedFields = MutableSharedFlow<Set<String>>(
        extraBufferCapacity = 16,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    /// Sign-in failure messages, published only for `CoreEvent` `Error`s whose `source` is
    /// `UserAuthenticated` (see [EngineState.parseAuthErrorMessage]) so an unrelated background error
    /// (a library sync hiccup, say) can never masquerade as a sign-in failure.
    private val authErrors = MutableSharedFlow<String>(
        extraBufferCapacity = 4,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    /// A small supervisor-scoped coroutine scope this repository owns for work that must outlive any
    /// single caller's coroutine (republishing [authState] off engine events). `SupervisorJob` so one
    /// failure (e.g. a malformed ctx JSON on a single event) can't cancel the whole scope.
    private val engineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val _authState = MutableStateFlow<AuthState>(AuthState.SignedOut)
    override val authState: StateFlow<AuthState> = _authState.asStateFlow()

    @Volatile
    private var started = false

    /// Set on [signOut], cleared on the next [signIn]. Works around a stremio-core engine quirk: on
    /// `Logout` the engine clears `ctx.library` but emits `Internal::LibraryChanged(false)` (the
    /// "don't persist" variant), and `ContinueWatchingPreview`'s `update` only recomputes on
    /// `LibraryChanged(true)` -- so the engine's `continue_watching_preview` field keeps serving the
    /// PREVIOUS (signed-in) user's stale items forever, until the process restarts and the model is
    /// rebuilt from the (now-empty, persisted) library bucket from scratch. That's exactly the device
    /// finding: "Continue Watching posters persist after Logout" until relaunch. Board rails do NOT
    /// have this problem (Logout's `ProfileChanged` correctly drives `catalogs_update`), but we clear
    /// both defensively in [homeSnapshot] so a signed-out Home is never rendered from ANY leftover
    /// per-account state while this flag is set.
    @Volatile
    private var suppressHomeUntilFreshLoad = false

    init {
        start()
    }

    /// Initialize the engine once. Idempotent; safe to call from multiple repositories (the native
    /// side is also idempotent). Storage goes to the durable filesDir, the HTTP cache to cacheDir.
    ///
    /// Fail-soft: if the native library failed to load or init throws (e.g. a missing/incompatible
    /// `libstremiox_core.so`), we log and leave [started] false. Every dispatch/getState below is then
    /// a no-op that yields the engine's `"null"` sentinel, so the parsers return empty state and the UI
    /// renders an empty (not crashed) screen. The boundary must never take down the whole app.
    @Synchronized
    private fun start() {
        if (started) return
        val storageDir = appContext.filesDir.absolutePath
        val cacheDir = appContext.cacheDir.absolutePath
        started = runCatching {
            StremioCoreNative.init(storageDir, cacheDir) { json -> onEngineEvent(json) }
        }.getOrElse { error ->
            Log.e(TAG, "stremio-core init failed; UI will render empty until the engine is available", error)
            false
        }
        // The engine hydrates `ctx.profile` (including a persisted sign-in) from its own storage
        // DURING init, before this call returns -- so a restored sign-in is visible immediately, no
        // extra dispatch/round-trip needed ("kill and relaunch restores state from engine
        // persistence", ANDROID-PLAN.md S03 DoD). Runs on whatever thread constructed this repository
        // (the engine's own lock, not the native callback thread), matching every other getState call.
        if (started) {
            Log.i(TAG, "engine initialized (schemaVersion=${runCatching { StremioCoreNative.schemaVersion() }.getOrDefault(-1)})")
            refreshAuthState()
        }
    }

    /// Decode a `RuntimeEvent`: publish changed field names on a NewState, or a sign-in failure
    /// message on a matching CoreEvent (see [EngineState.parseAuthErrorMessage]). Called on a native
    /// worker thread (see the class doc) -- every branch here is a cheap parse + a non-suspending
    /// `tryEmit`, so this always returns promptly regardless of collector speed.
    private fun onEngineEvent(json: ByteArray) {
        val event = runCatching { JSONObject(String(json, Charsets.UTF_8)) }.getOrNull() ?: return
        when (event.optString("name")) {
            "NewState" -> {
                val args = event.optJSONArray("args") ?: return
                val fields = buildSet {
                    for (i in 0 until args.length()) {
                        val field = args.optString(i)
                        if (field.isNotEmpty()) add(field)
                    }
                }
                if (fields.isEmpty()) return
                // Diagnostic contract with the on-device test script: `adb logcat -s StremioXEngine`
                // MUST show these lines while Home loads -- their absence proves the native event
                // path is broken (vs. a parsing/reactivity bug on this side).
                Log.d(TAG, "engine event NewState fields=$fields")
                changedFields.tryEmit(fields)
                // ctx changed (a sign-in, sign-out, or a persisted-profile hydration racing this
                // listener registration): refresh the published AuthState off this thread so
                // subscribers see it without polling. Cheap to check on every event; ctx changes are
                // infrequent (account actions), not per-frame.
                if (EngineActions.FIELD_CTX in fields) engineScope.launch { refreshAuthState() }
            }
            "CoreEvent" -> {
                Log.d(TAG, "engine event CoreEvent ${event.optJSONObject("args")?.optString("event")}")
                EngineState.parseAuthErrorMessage(json.toString(Charsets.UTF_8))?.let { authErrors.tryEmit(it) }
            }
        }
    }

    /// Pull `ctx`, parse it into [AuthState], publish it, and keep [identityStore] in sync (a display
    /// cache only -- see its doc comment; the engine's own `ctx.profile.auth` stays authoritative).
    private fun refreshAuthState() {
        val state = EngineState.parseAuthState(StremioCoreNative.getState(EngineActions.ctxField()))
        _authState.value = state
        when (state) {
            is AuthState.SignedIn -> identityStore.rememberSignedIn(state.email)
            AuthState.SignedOut -> identityStore.forget()
        }
    }

    /// Dispatch [actionJson], then keep re-pulling [field] on every NewState that names it until
    /// [ready] accepts the JSON or [loadTimeoutSeconds] elapses; on timeout, return the current state
    /// anyway (best effort -- covers a cached no-op load AND lost/undelivered events). Returns
    /// [field]'s JSON, never null ("null" on engine error).
    ///
    /// WHY a predicate and not "first event wins" (the S03 device-round bug): `Runtime::dispatch`
    /// runs the model update SYNCHRONOUSLY -- a Load action flips the field to `Loading` and emits a
    /// NewState immediately, long before any add-on HTTP answers. Awaiting a single event therefore
    /// either (a) catches that immediate all-Loading emission and parses an empty result, or (b)
    /// loses the subscribe race to it and rides the full timeout. The predicate loop instead treats
    /// NewState as what it is -- "something changed, look again" -- and only returns when the state
    /// actually has what the caller needs.
    private suspend fun loadFieldUntil(field: String, actionJson: String, ready: (String) -> Boolean): String {
        val settled = withTimeoutOrNull(loadTimeoutSeconds.seconds) {
            StremioCoreNative.dispatch(actionJson)
            // The state may already satisfy the caller (engine had it cached; Load was a no-op that
            // emits nothing) -- check before waiting on events at all.
            val immediate = StremioCoreNative.getState("\"$field\"")
            if (ready(immediate)) return@withTimeoutOrNull immediate
            changedFields
                .filter { field in it }
                .map { StremioCoreNative.getState("\"$field\"") }
                .first { ready(it) }
        }
        return settled ?: StremioCoreNative.getState("\"$field\"")
    }

    /// One-shot Home (kept for the [CatalogRepository] contract; the Home screen itself collects
    /// [homeUpdates]): waits until at least one board row has content, then snapshots.
    // withContext(Dispatchers.Default): the loadFieldUntil dispatch/getState + homeSnapshot()/parse
    // must run off the caller's (Main) context -- JNI + org.json never on the UI thread.
    override suspend fun home(): Result<List<Catalog>> = withContext(Dispatchers.Default) { runCatching {
        StremioCoreNative.dispatch(EngineActions.loadBoard())
        loadFieldUntil(EngineActions.FIELD_BOARD, EngineActions.loadBoardRange(DEFAULT_BOARD_ROWS)) {
            EngineState.parseCatalogs(it).isNotEmpty()
        }
        homeSnapshot()
    } }

    /// The continuous Home stream (see [CatalogRepository.homeUpdates]). Emits a snapshot immediately,
    /// then again on every board/ctx/Continue-Watching NewState -- rails appear incrementally as each
    /// add-on answers -- and re-dispatches the board load whenever the signed-in identity changes, so
    /// sign-in swaps in the account's catalogs and sign-out swaps back to the defaults with no app
    /// restart (S03 device-round finding #3).
    ///
    /// A slow poll (every [HOME_POLL_MS]) is merged in as a safety net: if engine events are ever
    /// lost/undelivered on some device, Home still converges on the real state within a few seconds
    /// instead of hanging forever -- and the `onEvent` logcat lines (see [onEngineEvent]) tell us
    /// whether the events actually flowed. distinctUntilChanged suppresses the no-change poll spam;
    /// conflate keeps a slow collector from ever queueing stale snapshots.
    override fun homeUpdates(): Flow<List<Catalog>> = channelFlow {
        var lastUid = (EngineState.parseAuthState(StremioCoreNative.getState(EngineActions.ctxField())) as? AuthState.SignedIn)?.uid
        dispatchHomeLoad()
        send(homeSnapshot())
        launch {
            changedFields.collect { fields ->
                if (fields.none { it in HOME_FIELDS }) return@collect
                if (EngineActions.FIELD_CTX in fields) {
                    val uid = (EngineState.parseAuthState(StremioCoreNative.getState(EngineActions.ctxField())) as? AuthState.SignedIn)?.uid
                    val identityChanged = uid != lastUid
                    lastUid = uid
                    // Re-dispatch the board Load on ANY ctx change, not just a sign-in/out identity
                    // swap: an add-on install/remove is ALSO a ctx broadcast (see
                    // [EngineActions.ctxEnvelope]), and the board's `CatalogsWithExtra` rows only
                    // reflect the installed-add-on set as of whichever Load last ran -- without this,
                    // "install an add-on -> its catalogs appear on Home" needed a restart (Group-1
                    // device finding 1c). Cheap: a re-Load of already-cached add-on answers is a no-op
                    // fast path at the engine level (mirrors [dispatchHomeLoad]'s existing use on every
                    // uid change).
                    if (identityChanged) {
                        Log.i(TAG, "auth identity changed (uid=${uid != null}) -> reloading board")
                    }
                    dispatchHomeLoad()
                }
                send(homeSnapshot())
            }
        }
        launch {
            while (isActive) {
                delay(HOME_POLL_MS)
                send(homeSnapshot())
            }
        }
        // flowOn so the channelFlow producer -- every homeSnapshot()/getState()/parse below -- runs on
        // Dispatchers.Default, never the collector's (Main) context: JNI + org.json off the UI thread.
    }.distinctUntilChanged().conflate().flowOn(Dispatchers.Default)

    private fun dispatchHomeLoad() {
        StremioCoreNative.dispatch(EngineActions.loadBoard())
        StremioCoreNative.dispatch(EngineActions.loadBoardRange(DEFAULT_BOARD_ROWS))
    }

    /// The Group-1 reactivity primitive (see [CatalogRepository.ctxUpdates]'s doc comment): a
    /// continuous tick every time a ctx-shaped broadcast lands -- covers AddToLibrary/RemoveFromLibrary,
    /// InstallAddon/UninstallAddon, and sign-in/sign-out, all of which dispatch with `field = null` (see
    /// [EngineActions.ctxEnvelope]) and therefore always report [EngineActions.FIELD_CTX] among the
    /// NewState's changed fields; [EngineActions.FIELD_LIBRARY] is included too since a library mutation
    /// re-derives that field independently of whether `ctx` itself is named in the same event.
    override fun ctxUpdates(): Flow<Unit> = channelFlow {
        send(Unit)
        launch {
            changedFields.collect { fields ->
                if (fields.any { it in CTX_UPDATE_FIELDS }) send(Unit)
            }
        }
        // flowOn Default: keep the changedFields collection + fan-out off the collector's (Main) context,
        // consistent with homeUpdates -- collectors re-read the engine on each tick, so never on Main.
    }.conflate().flowOn(Dispatchers.Default)

    /// Parse the CURRENT engine state into Home rails: titled board rows (real "<add-on> · <catalog>"
    /// names from the installed manifests) with Continue Watching prepended (id = "continue" is the
    /// contract HomeScreen keys its editorial eyebrow off of). Pure read -- no dispatch, no await --
    /// so [homeUpdates] can call it on every event/poll tick cheaply.
    private fun homeSnapshot(): List<Catalog> {
        val titleMap = EngineState.parseAddonCatalogTitles(StremioCoreNative.getState(EngineActions.ctxField()))
        val boardRows = EngineState.parseCatalogs(StremioCoreNative.getState(EngineActions.boardField()), titleMap)
        // Suppressed right after sign-out: see [suppressHomeUntilFreshLoad]'s doc comment. The engine's
        // continue_watching_preview field keeps serving the PREVIOUS account's items indefinitely (an
        // engine quirk, not a race), so trusting it here would render a signed-out Home with another
        // account's "Continue Watching" posters. Board rows are unaffected (Logout correctly drives a
        // real reload) so they still render live.
        val continueWatching = if (suppressHomeUntilFreshLoad) {
            emptyList()
        } else {
            runCatching {
                EngineState.parseContinueWatching(StremioCoreNative.getState(EngineActions.continueWatchingPreviewField()))
            }.getOrDefault(emptyList())
        }
        return if (continueWatching.isEmpty()) {
            boardRows
        } else {
            listOf(Catalog(id = "continue", title = "Continue Watching", items = continueWatching)) + boardRows
        }
    }

    override suspend fun discover(requestJson: String?): Result<DiscoverResult> = withContext(Dispatchers.Default) { runCatching {
        // Discover is one selectable rail in the engine (a CatalogWithFilters: the selected catalog's
        // flat pages, not the board's list-of-rails). [requestJson] null = the engine's own default
        // selection (first load); non-null = a verbatim echo of a chip's own `request` -- see
        // [EngineActions.loadDiscoverSelect] for why a reconstructed request is wrong. Ready =
        // [EngineState.discoverCatalogSettled] (every page Ready/errored, not still Loading), which
        // correctly resolves a GENUINELY empty result (a filter with zero matches) instead of riding
        // the full timeout the old "has any items" gate would have.
        val dispatchAction = if (requestJson != null) EngineActions.loadDiscoverSelect(requestJson) else EngineActions.loadDiscover()
        val state = loadFieldUntil(EngineActions.FIELD_DISCOVER, dispatchAction) { EngineState.discoverCatalogSettled(it) }
        discoverResultFrom(state)
    } }

    override suspend fun discoverNextPage(): Result<DiscoverResult> = withContext(Dispatchers.Default) { runCatching {
        val state = loadFieldUntil(EngineActions.FIELD_DISCOVER, EngineActions.loadDiscoverNextPage()) {
            EngineState.discoverCatalogSettled(it)
        }
        discoverResultFrom(state)
    } }

    /// Parse a `discover` field snapshot into the [DiscoverResult] the ViewModel renders: the selected
    /// catalog's items (flattened from [EngineState.parseCatalogWithFilters]'s one-row shape) plus the
    /// type/catalog/genre pivot chips. One state pull, two parses -- a type/catalog/genre switch is a
    /// single engine round-trip, not two.
    private fun discoverResultFrom(discoverStateJson: String): DiscoverResult {
        val titleMap = EngineState.parseAddonCatalogTitles(StremioCoreNative.getState(EngineActions.ctxField()))
        val rows = EngineState.parseCatalogWithFilters(discoverStateJson, titleMap)
        return DiscoverResult(items = rows.firstOrNull()?.items.orEmpty(), filters = EngineState.parseDiscoverFilters(discoverStateJson))
    }

    override suspend fun library(requestJson: String?): Result<LibraryResult> = withContext(Dispatchers.Default) { runCatching {
        // Library is DERIVED from the persisted ctx.library bucket (no add-on HTTP), so the immediate
        // post-dispatch snapshot is already the real answer -- ready = always, no event wait. A
        // genuinely empty library must return [] instantly, not ride a timeout. [requestJson] null =
        // the default (all types, last-watched); non-null = a verbatim echo of a
        // [com.vortx.android.model.LibraryTypeOption]/[com.vortx.android.model.LibrarySortOption]'s
        // `request`, mirroring Discover's selection contract.
        val dispatchAction = if (requestJson != null) EngineActions.loadLibrarySelect(requestJson) else EngineActions.loadLibrary()
        val state = loadFieldUntil(EngineActions.FIELD_LIBRARY, dispatchAction) { true }
        LibraryResult(items = EngineState.parseLibrary(state), filters = EngineState.parseLibraryFilters(state))
    } }

    override suspend fun addToLibrary(item: MetaItem): Result<Unit> = runCatching {
        // AddToLibrary is a synchronous local ctx mutation (no add-on HTTP), so a dispatch-and-return is
        // enough; the caller re-pulls [library] afterward to see the change (same pattern [signOut] uses
        // for its own synchronous ctx mutation).
        StremioCoreNative.dispatch(EngineActions.addToLibrary(id = item.id, type = item.type.id, name = item.name, poster = item.poster))
    }

    override suspend fun removeFromLibrary(id: String): Result<Unit> = runCatching {
        StremioCoreNative.dispatch(EngineActions.removeFromLibrary(id))
    }

    override suspend fun installedAddons(): Result<List<InstalledAddon>> = runCatching {
        EngineState.parseInstalledAddons(StremioCoreNative.getState(EngineActions.ctxField()))
    }

    override suspend fun installAddon(url: String): Result<Unit> = runCatching {
        val normalized = normalizeAddonUrl(url)
            ?: throw IllegalArgumentException("Enter a valid add-on URL (https://…/manifest.json).")
        // Same SSRF-shaped guard Apple's AddonURLGuard applies before ever fetching a pasted URL: never
        // let an install form turn the app into a private-network prober. Not a full parity port (no
        // DNS-rebinding / redirect-hop re-validation), but blocks the obvious loopback/RFC1918/link-
        // local targets a pasted or shared URL could carry.
        if (isPrivateNetworkHost(normalized)) {
            throw IllegalArgumentException("That URL points to a private network address and can't be installed.")
        }
        // The engine has no HTTP-fetch action for a bare add-on URL (mirrors Apple: CoreBridge.installAddon
        // fetches client-side too) -- fetch + validate the manifest here, then hand the engine the fully
        // resolved Descriptor. InstallAddon upserts by transportUrl (stremio-core update_profile.rs), so
        // re-installing an already-installed URL updates it in place with no separate uninstall step.
        val manifest = fetchAddonManifest(normalized)
            ?: throw IllegalStateException("That URL did not return a valid add-on manifest.")
        StremioCoreNative.dispatch(EngineActions.installAddon(normalized, manifest))
    }

    override suspend fun removeAddon(addon: InstalledAddon): Result<Unit> = runCatching {
        StremioCoreNative.dispatch(EngineActions.uninstallAddon(addon.rawDescriptorJson))
    }

    /// Trim + validate scheme + ensure a `/manifest.json` suffix, mirroring Apple
    /// `CoreBridge.normalizedAddonURL`. Null for anything that isn't a plausible http(s) URL.
    private fun normalizeAddonUrl(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        val uri = runCatching { URI(trimmed) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") return null
        return if (trimmed.lowercase().endsWith("manifest.json")) trimmed else trimmed.trimEnd('/') + "/manifest.json"
    }

    /// True for loopback / RFC1918 / link-local hosts (see [installAddon]'s doc comment for scope).
    private fun isPrivateNetworkHost(urlString: String): Boolean {
        val host = runCatching { URI(urlString).host }.getOrNull()?.lowercase() ?: return true
        if (host == "localhost" || host == "::1" || host.startsWith("127.")) return true
        if (host.startsWith("10.") || host.startsWith("192.168.") || host.startsWith("169.254.")) return true
        val octets = host.split(".")
        if (octets.size == 4 && octets[0] == "172") {
            val second = octets[1].toIntOrNull()
            if (second != null && second in 16..31) return true
        }
        return false
    }

    /// Fetch a manifest.json body and validate it looks like an add-on manifest (`id` + `name` present,
    /// mirroring Apple `CoreBridge.installAddon`'s validation). Runs on [Dispatchers.IO]; fail-soft to
    /// null on any network/parse error so [installAddon] can surface one clear user-facing message.
    private suspend fun fetchAddonManifest(url: String): JSONObject? = withContext(Dispatchers.IO) {
        runCatching {
            val connection = URL(url).openConnection() as HttpURLConnection
            try {
                connection.requestMethod = "GET"
                connection.connectTimeout = MANIFEST_FETCH_TIMEOUT_MS
                connection.readTimeout = MANIFEST_FETCH_TIMEOUT_MS
                connection.instanceFollowRedirects = true
                connection.setRequestProperty("User-Agent", "VortX-Android/1.0")
                if (connection.responseCode !in 200..299) return@runCatching null
                val body = connection.inputStream.bufferedReader().use { it.readText() }
                val manifest = JSONObject(body)
                if (manifest.has("id") && manifest.has("name")) manifest else null
            } finally {
                connection.disconnect()
            }
        }.getOrNull()
    }

    override suspend fun search(query: String): Result<List<MetaItem>> = withContext(Dispatchers.Default) { runCatching {
        if (query.isBlank()) return@runCatching emptyList()
        StremioCoreNative.dispatch(EngineActions.searchLoad(query))
        // search is a CatalogsWithExtra (rails); flatten the rails to a flat result list for the UI.
        // Ready = first add-on answered with rows; a genuinely zero-hit query rides the timeout and
        // returns [] (acceptable until S04 makes Search reactive like Home).
        val state = loadFieldUntil(EngineActions.FIELD_SEARCH, EngineActions.searchRange(DEFAULT_SEARCH_ROWS)) {
            EngineState.parseCatalogs(it).any { row -> row.items.isNotEmpty() }
        }
        EngineState.parseCatalogs(state).flatMap { it.items }
    } }

    override suspend fun meta(type: MediaType, id: String): Result<MetaDetail> = withContext(Dispatchers.Default) { runCatching {
        // Ready = the meta actually parsed (first Ready Loadable in metaItems). The immediate
        // post-Load state is Loading, so a single-event await would leak a not-ready miss to the UI
        // (the "meta_details not ready" string the S03 device round saw rendered raw).
        val state = loadFieldUntil(EngineActions.FIELD_META_DETAILS, EngineActions.loadMeta(type.id, id)) {
            EngineState.parseMetaDetail(it) != null
        }
        EngineState.parseMetaDetail(state)
            ?: throw IllegalStateException("Couldn't load this title's details. Check your connection and try again.")
    } }

    override suspend fun streams(type: MediaType, id: String, episodeId: String?): Result<List<StreamGroup>> = withContext(Dispatchers.Default) { runCatching {
        // Meta + a guessed stream were already requested by meta(); re-pull meta_details for its
        // stream groups. If meta() was not called first, this Load brings both in.
        //
        // For a series with a chosen [episodeId], pass a streamPath so the engine fetches THAT episode's
        // streams (the engine stream resource type is the meta type, its id is the episode's video id);
        // otherwise (movie, or no episode chosen yet) leave the streamPath null and take the guessed set.
        val action = if (episodeId != null) {
            EngineActions.loadMeta(type.id, id, streamType = type.id, streamId = episodeId)
        } else {
            EngineActions.loadMeta(type.id, id)
        }
        // Ready = at least one add-on's stream group settled; later groups keep landing in engine
        // state and S05's reactive detail work will surface them incrementally.
        val state = loadFieldUntil(EngineActions.FIELD_META_DETAILS, action) {
            EngineState.parseStreamGroups(it).isNotEmpty()
        }
        EngineState.parseStreamGroups(state)
    } }

    override suspend fun resolve(source: StreamSource): Result<Playable> = runCatching {
        // A stream id encodes its handle (see EngineState.parseStream: id = handle#name#desc, handle is
        // url/externalUrl/infoHash). Direct URLs are playable as-is. A raw torrent (handle = infoHash)
        // resolves through the user's own debrid account when a key is configured (native in-client
        // debrid, the Android port of the Apple DebridResolver); without a key it still needs the
        // in-process streaming server (nodejs-mobile, not yet wired), so it surfaces a clear error the
        // player layer can show instead of failing opaquely.
        val handle = source.id.substringBefore('#')
        if (!source.isTorrent && (handle.startsWith("http://") || handle.startsWith("https://"))) {
            Playable(url = handle, title = source.title, viaStreamingServer = false)
        } else if (source.isTorrent) {
            // Raw torrent: the handle IS the infoHash (see EngineState.parseStream: for a torrent
            // url == null, so the id-handle is the infoHash). If the user has a debrid key configured,
            // resolve it to a DIRECT, cached-instant HTTPS link through their own account (the Android
            // port of the Apple DebridResolver). The resolved URL is a plain direct stream, NOT a
            // torrent, so it plays without the streaming-server bridge (viaStreamingServer = false).
            //
            // Fail-soft: DebridResolver.resolve returns null on ANY failure (no key, not actually
            // cached, no playable file, provider/network error). With no key it never opens the key
            // store. On null we surface the SAME clear error as before so the player layer shows a real
            // message rather than failing opaquely, and torrents keep today's behavior when no debrid
            // is configured.
            val resolved = debridResolver.resolve(infoHash = handle)
            if (resolved != null) {
                Playable(url = resolved, title = source.title, viaStreamingServer = false, isTorrent = false)
            } else {
                throw UnsupportedOperationException(
                    "Torrent playback needs a debrid key or the streaming-server bridge (not yet wired on Android).",
                )
            }
        } else {
            throw UnsupportedOperationException(
                "This source type is not playable on Android yet.",
            )
        }
    }

    // ---- S05: Detail watched-state + library mutations ----
    //
    // Every dispatch below is followed by an IMMEDIATE re-read of `meta_details` (no loadFieldUntil
    // wait): stremio-core's `Runtime::dispatch` runs synchronously and `MetaDetails::update` recomputes
    // `library_item` from `ctx.library` on every dispatched message, so the post-dispatch snapshot
    // already carries the mutation -- see [EngineActions]'s "S05" doc comment for the full reasoning.
    // Returning the refreshed [MetaDetail] lets the ViewModel swap its state in one step instead of a
    // separate re-load, so ticks/progress/library-chip state flip live the instant the action returns.

    private fun currentMetaDetail(): MetaDetail? =
        EngineState.parseMetaDetail(StremioCoreNative.getState(EngineActions.metaDetailsField()))

    override suspend fun setWatched(type: MediaType, id: String, isWatched: Boolean): Result<MetaDetail> = runCatching {
        StremioCoreNative.dispatch(EngineActions.markAsWatched(isWatched))
        currentMetaDetail() ?: throw IllegalStateException("Couldn't update watched state.")
    }

    override suspend fun setVideoWatched(
        type: MediaType,
        id: String,
        videoId: String,
        season: Int?,
        episode: Int?,
        isWatched: Boolean,
    ): Result<MetaDetail> = runCatching {
        StremioCoreNative.dispatch(EngineActions.markVideoAsWatched(videoId, season, episode, isWatched))
        currentMetaDetail() ?: throw IllegalStateException("Couldn't update watched state.")
    }

    override suspend fun setSeasonWatched(type: MediaType, id: String, season: Int, isWatched: Boolean): Result<MetaDetail> =
        runCatching {
            StremioCoreNative.dispatch(EngineActions.markSeasonAsWatched(season, isWatched))
            currentMetaDetail() ?: throw IllegalStateException("Couldn't update watched state.")
        }

    override suspend fun addToLibrary(type: MediaType, id: String, name: String, poster: String?): Result<MetaDetail> =
        runCatching {
            StremioCoreNative.dispatch(EngineActions.addToLibrary(id, type.id, name, poster))
            currentMetaDetail() ?: throw IllegalStateException("Couldn't add this title to your library.")
        }

    override suspend fun removeFromLibrary(type: MediaType, id: String): Result<MetaDetail> = runCatching {
        StremioCoreNative.dispatch(EngineActions.removeFromLibrary(id))
        currentMetaDetail() ?: throw IllegalStateException("Couldn't remove this title from your library.")
    }

    /// A pure local re-read (see [CatalogRepository.peekMeta]): no dispatch at all, just the same
    /// synchronous `meta_details` snapshot [currentMetaDetail] already uses after every S05 mutation --
    /// safe to call on every [ctxUpdates] tick without re-triggering the add-on stream fan-out. Null if
    /// nothing is currently loaded for [id] (a different title's meta_details, or none yet).
    // withContext(Dispatchers.Default): called on every ctxUpdates tick, so its getState + parse
    // (via currentMetaDetail) must stay off the collector's (Main) context.
    override suspend fun peekMeta(type: MediaType, id: String): MetaDetail? = withContext(Dispatchers.Default) {
        currentMetaDetail()?.takeIf { it.id == id }
    }

    // ---- AuthRepository ----

    override suspend fun signIn(email: String, password: String): Result<Unit> = runCatching {
        if (email.isBlank() || password.isBlank()) {
            throw IllegalArgumentException("Enter your email and password.")
        }
        // A fresh sign-in always resolves the truth: the engine syncs the account's real library from
        // the server (a genuine `LibraryChanged(true)`), which correctly repopulates
        // continue_watching_preview -- so it's safe to stop overriding it with empty from here on.
        suppressHomeUntilFreshLoad = false
        // Race a `ctx` NewState (success: profile.auth now set) against a CoreEvent sign-in error (bad
        // password, no network, ...) by merging both into one flow and taking whichever lands first --
        // mirrors how Apple `StremioAccount.signIn` surfaces `res.error?.message` instead of a generic
        // failure. The await is launched before the dispatch (and login is a full network round-trip,
        // so the subscription is up long before the engine can answer); if an event is somehow still
        // missed, the post-timeout ctx re-read below resolves the true outcome -- the race exists to
        // make the common path fast and the error message specific, not for correctness.
        val ctxChanged: Flow<AuthWait> = changedFields.filter { EngineActions.FIELD_CTX in it }.map { AuthWait.CtxChanged }
        val failed: Flow<AuthWait> = authErrors.map { AuthWait.Failed(it) }
        val awaitOutcome = withTimeoutOrNull(loadTimeoutSeconds.seconds) {
            val outcome = async { merge(ctxChanged, failed).first() }
            StremioCoreNative.dispatch(EngineActions.authenticateLogin(email, password))
            outcome.await()
        }
        if (awaitOutcome is AuthWait.Failed) throw IllegalStateException(awaitOutcome.message)
        // Whether we won the race on ctx, timed out (a dropped/coalesced event -- current state is
        // best, the same fallback [loadField] uses), the actual signed-in-ness is the real check.
        refreshAuthState()
        if (_authState.value !is AuthState.SignedIn) {
            throw IllegalStateException("Sign-in failed. Check your connection and try again.")
        }
    }

    /// The two outcomes [signIn] races: a `ctx` change (assume success; the real check afterward is
    /// `authState is SignedIn`) or an explicit failure message from the engine.
    private sealed interface AuthWait {
        data object CtxChanged : AuthWait
        data class Failed(val message: String) : AuthWait
    }

    override suspend fun signOut() {
        // Broadcast dispatch (field = null): mirrors Apple's plain Logout, an explicit user sign-out.
        // Fail-soft by design -- if the engine is unavailable the dispatch is a no-op, but we still
        // clear the LOCAL published state + identity cache so the UI never shows a stale signed-in
        // account it can't actually act on.
        runCatching { StremioCoreNative.dispatch(EngineActions.logout()) }
        _authState.value = AuthState.SignedOut
        identityStore.forget()
        // See [suppressHomeUntilFreshLoad]'s doc comment: the engine's Continue Watching field will
        // NOT clear itself on Logout, so from this point on homeSnapshot() must not trust it until the
        // next real sign-in. Also re-dispatch the board load directly (not just relying on homeUpdates'
        // uid-change reload, which only fires while something is actively collecting the flow) so the
        // board rails deterministically swap to the signed-out defaults too.
        suppressHomeUntilFreshLoad = true
        runCatching { dispatchHomeLoad() }
    }

    private companion object {
        // Match CoreBridge's initial board fetch and search range so behavior tracks the reference app.
        const val DEFAULT_BOARD_ROWS = 12
        const val DEFAULT_SEARCH_ROWS = 30
        const val TAG = "StremioXEngine"

        /// Connect/read timeout for a pasted add-on's manifest.json fetch ([fetchAddonManifest]).
        const val MANIFEST_FETCH_TIMEOUT_MS = 8_000

        /// The NewState fields that affect the Home composition (board rails, add-on titles + auth
        /// from ctx, the Continue Watching rail).
        val HOME_FIELDS = setOf(
            EngineActions.FIELD_BOARD,
            EngineActions.FIELD_CTX,
            EngineActions.FIELD_CONTINUE_WATCHING_PREVIEW,
        )

        /// The NewState fields [ctxUpdates] treats as "something Library/Detail/Discover/Add-ons should
        /// re-read" -- see [ctxUpdates]'s doc comment.
        val CTX_UPDATE_FIELDS = setOf(EngineActions.FIELD_CTX, EngineActions.FIELD_LIBRARY)

        /// Safety-net poll cadence for [homeUpdates]. Each tick is a cheap local getState + parse;
        /// distinctUntilChanged means an unchanged snapshot never reaches the UI.
        const val HOME_POLL_MS = 3_000L
    }
}
