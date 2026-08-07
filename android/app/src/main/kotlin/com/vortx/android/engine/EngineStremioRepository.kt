package com.vortx.android.engine

import android.content.Context
import android.util.Log
import com.vortx.android.auth.AuthIdentityStore
import com.vortx.android.data.AddonPrefsStore
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.ContinueWatchingDismissal
import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.data.ContinueWatchingSnapshot
import com.vortx.android.data.HomeSnapshot
import com.vortx.android.data.HomeUpdate
import com.vortx.android.data.PlaybackSessionToken
import com.vortx.android.model.AddonOrder
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.debrid.DebridResolver
import com.vortx.android.model.AuthState
import com.vortx.android.model.Catalog
import com.vortx.android.model.DiscoverResult
import com.vortx.android.model.Episode
import com.vortx.android.model.InstalledAddon
import com.vortx.android.model.LibraryItemInfo
import com.vortx.android.model.LibraryPortability
import com.vortx.android.model.LibraryResult
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.MetaItem
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.model.TrackPreferencesStore
import com.vortx.android.library.WatchedIndex
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.ContinueWatchingOwnerGate
import com.vortx.android.profile.UserProfile
import com.vortx.android.sources.SourcePinContext
import com.vortx.android.sources.SourcePinStore
import com.vortx.android.sources.SourcePreferencesStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
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
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.net.URI
import kotlin.time.Duration.Companion.seconds

internal data class DebridResolveTarget(
    val infoHash: String,
    val episode: DebridResolver.Episode?,
    val fileIdx: Int?,
)

internal class StreamLoadGenerationFence {
    private var generation = 0L

    @Synchronized
    fun begin(): Long {
        generation += 1L
        return generation
    }

    @Synchronized
    fun isCurrent(candidate: Long): Boolean = candidate == generation
}

internal fun StreamSource.debridResolveTarget(
    fallbackHandle: String,
    selectedEpisode: Episode?,
): DebridResolveTarget = DebridResolveTarget(
    infoHash = infoHash ?: fallbackHandle,
    episode = selectedEpisode?.let {
        DebridResolver.Episode(
            season = it.season,
            episode = it.episode,
        )
    },
    fileIdx = fileIdx,
)

internal data class UsenetResolveTarget(
    val nzbUrl: String,
    val knownHash: String?,
    val fileMustInclude: String?,
    val episode: DebridResolver.Episode?,
    val fileIdx: Int?,
)

/** Bare-id native removal is allowed only when the carried media type uniquely identifies that id. */
internal fun validateContinueWatchingRemovalTarget(
    items: List<MetaItem>,
    target: ContinueWatchingDismissal,
): Boolean {
    val matching = items.filter { it.id == target.id }
    check(matching.none { it.type != target.type }) {
        "Continue Watching removal cannot disambiguate duplicate media types."
    }
    return matching.any { it.type == target.type }
}

internal fun StreamSource.usenetResolveTarget(
    selectedEpisode: Episode?,
): UsenetResolveTarget = UsenetResolveTarget(
    nzbUrl = requireNotNull(nzbUrl) { "Usenet source is missing its NZB URL." },
    knownHash = usenetKnownHash,
    fileMustInclude = fileMustInclude,
    episode = selectedEpisode?.let {
        DebridResolver.Episode(
            season = it.season,
            episode = it.episode,
        )
    },
    fileIdx = fileIdx,
)

internal fun usenetPlaybackFailure(error: Throwable): Throwable = when (error) {
    DebridResolver.DebridException.NoKey ->
        UnsupportedOperationException("Usenet playback needs a TorBox debrid key.", error)
    DebridResolver.DebridException.InvalidKey ->
        IllegalStateException("TorBox rejected the configured debrid key.", error)
    DebridResolver.DebridException.NoMatchingFile ->
        IllegalStateException("No playable video matched this Usenet source.", error)
    DebridResolver.DebridException.NotReady ->
        IllegalStateException("This Usenet source is still preparing in TorBox.", error)
    DebridResolver.DebridException.NotCached ->
        IllegalStateException("This Usenet source is not available in TorBox yet.", error)
    DebridResolver.DebridException.OwnerChanged ->
        IllegalStateException("The debrid account changed while resolving this Usenet source.", error)
    is DebridResolver.DebridException.Provider ->
        IllegalStateException("TorBox could not resolve this Usenet source: ${error.message}.", error)
    else -> error
}

/** One immutable authorization view carried through a complete Home snapshot build. */
internal data class HomeProfileIdentity(
    val profileId: String,
    val usesEngineHistory: Boolean,
    val accountKey: String,
    val expectedPrincipal: String? = null,
)

internal fun engineHistoryPrincipalMatches(profile: UserProfile?, state: AuthState): Boolean {
    if (profile == null || profile.isOwner || !profile.usesOwnAccount) return true
    val expected = profile.email?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return false
    val actual = (state as? AuthState.SignedIn)?.email
        ?.trim()
        ?.lowercase()
        ?.takeIf { it.isNotEmpty() }
        ?: return false
    return expected == actual
}

internal data class PlaybackHistorySession(
    val token: PlaybackSessionToken,
    val owner: ContinueWatchingOwner,
    val enginePlayerLoaded: Boolean,
    val type: String?,
    val videoId: String?,
    val overlayMetaId: String?,
    val name: String?,
    val poster: String?,
)

/** Holds exactly one playback session and rejects every callback carrying a replaced generation. */
internal class PlaybackHistorySessions {
    private val lock = Any()
    private var generation = 0L
    private var current: PlaybackHistorySession? = null

    fun replace(
        unloadPrevious: (PlaybackHistorySession) -> Unit,
        create: (PlaybackSessionToken) -> PlaybackHistorySession,
    ): PlaybackSessionToken = synchronized(lock) {
        current?.let(unloadPrevious)
        current = null
        check(generation < Long.MAX_VALUE) { "Playback session generation exhausted." }
        generation += 1L
        val token = PlaybackSessionToken(generation)
        val replacement = create(token)
        check(replacement.token == token) { "Playback session token mismatch." }
        current = replacement
        token
    }

    fun withCurrent(token: PlaybackSessionToken, block: (PlaybackHistorySession) -> Unit): Boolean =
        synchronized(lock) {
            val session = current?.takeIf { it.token == token } ?: return@synchronized false
            block(session)
            true
        }

    fun finish(token: PlaybackSessionToken, block: (PlaybackHistorySession) -> Unit): Boolean =
        synchronized(lock) {
            val session = current?.takeIf { it.token == token } ?: return@synchronized false
            try {
                block(session)
            } finally {
                if (current === session) current = null
            }
            true
        }
}

internal data class HomePrivacyPermit(
    val generation: Long,
    val profile: HomeProfileIdentity,
    val suppressAccountHistory: Boolean,
    val suppressContinueWatchingPreview: Boolean,
)

/** Ownership evidence captured synchronously with the native callback that announced a preview. */
internal data class HomePreviewTicket(
    val privacy: HomePrivacyPermit,
    val eventSequence: Long,
)

/** An exact local authentication attempt bound to the core request digest it dispatched. */
internal data class HomeSignInAttempt(
    val id: Long,
    val requestId: String,
    val privacyGeneration: Long,
    val profile: HomeProfileIdentity,
)

private data class FencedHomeSnapshot(
    val privacy: HomePrivacyPermit,
    val snapshot: HomeSnapshot,
)

/** Fail-closed gate for account-derived Home history across authentication transitions. */
internal class HomePrivacyFence(
    initiallySuppressed: Boolean = true,
    initialProfile: HomeProfileIdentity = HomeProfileIdentity(
        profileId = "default",
        usesEngineHistory = true,
        accountKey = "default",
        expectedPrincipal = null,
    ),
) {
    private var generation = 0L
    private var nextSignInAttemptId = 0L
    private var profile = initialProfile
    private var minimumPreviewEventSequence = 0L
    private var suppressAccountHistory = initiallySuppressed
    private var suppressContinueWatchingPreview = initiallySuppressed
    private var pendingSignIn: HomeSignInAttempt? = null
    private var activeAccountUid: String? = null
    private var activeAccountGeneration: Long? = null
    private var previewObservation: PreviewObservation? = null

    val isRaised: Boolean
        @Synchronized get() = suppressAccountHistory || suppressContinueWatchingPreview

    @Synchronized
    fun capture(): HomePrivacyPermit = HomePrivacyPermit(
        generation = generation,
        profile = profile,
        suppressAccountHistory = suppressAccountHistory,
        suppressContinueWatchingPreview = suppressContinueWatchingPreview,
    )

    @Synchronized
    fun isCurrent(permit: HomePrivacyPermit): Boolean =
        permit.generation == generation && permit.profile == profile

    /** Validate and publish while holding the same monitor every privacy transition advances. */
    @Synchronized
    fun publishIfCurrent(permit: HomePrivacyPermit, publish: () -> Boolean): Boolean =
        permit.generation == generation && permit.profile == profile && publish()

    /** Called once after a newly constructed engine has hydrated its own coherent persisted model. */
    @Synchronized
    fun establishFreshEngineState(
        isSignedIn: Boolean,
        signedInUid: String?,
        accountUidVerified: Boolean,
        activeProfile: HomeProfileIdentity = profile,
        nextPreviewEventSequence: Long = minimumPreviewEventSequence,
    ) {
        generation += 1
        profile = activeProfile
        minimumPreviewEventSequence = nextPreviewEventSequence
        pendingSignIn = null
        previewObservation = null
        activeAccountUid = signedInUid?.takeIf { isSignedIn && accountUidVerified }
        activeAccountGeneration = activeAccountUid?.let { generation }
        val accountIsFresh = !isSignedIn || (!signedInUid.isNullOrBlank() && accountUidVerified)
        suppressAccountHistory = !accountIsFresh
        // A newly constructed engine derived this preview from the same hydrated state. A UID-less
        // signed-in ctx is not an owned account and therefore remains fail-closed.
        suppressContinueWatchingPreview = !accountIsFresh
    }

    /** Advance the Home generation at the instant the active profile identity moves. */
    @Synchronized
    fun switchProfile(
        activeProfile: HomeProfileIdentity,
        nextPreviewEventSequence: Long,
    ): Boolean {
        if (profile == activeProfile) return false
        val accountChanged = profile.accountKey != activeProfile.accountKey
        val principalChanged = profile.expectedPrincipal != activeProfile.expectedPrincipal
        generation += 1
        profile = activeProfile
        minimumPreviewEventSequence = nextPreviewEventSequence
        pendingSignIn = null
        previewObservation = null
        if (accountChanged || principalChanged) {
            suppressAccountHistory = true
            suppressContinueWatchingPreview = true
            activeAccountUid = null
            activeAccountGeneration = null
        }
        return true
    }

    @Synchronized
    fun beginSignIn(
        requestId: String,
        nextPreviewEventSequence: Long = minimumPreviewEventSequence,
    ): HomeSignInAttempt {
        generation += 1
        nextSignInAttemptId += 1
        minimumPreviewEventSequence = nextPreviewEventSequence
        suppressAccountHistory = true
        suppressContinueWatchingPreview = true
        activeAccountUid = null
        activeAccountGeneration = null
        previewObservation = null
        return HomeSignInAttempt(
            id = nextSignInAttemptId,
            requestId = requestId,
            privacyGeneration = generation,
            profile = profile,
        ).also { pendingSignIn = it }
    }

    @Synchronized
    fun invalidateAccount(
        nextPreviewEventSequence: Long = minimumPreviewEventSequence,
    ): HomePrivacyPermit {
        generation += 1
        minimumPreviewEventSequence = nextPreviewEventSequence
        suppressAccountHistory = true
        suppressContinueWatchingPreview = true
        pendingSignIn = null
        activeAccountUid = null
        activeAccountGeneration = null
        previewObservation = null
        return capture()
    }

    fun beforeLogout(
        nextPreviewEventSequence: Long = minimumPreviewEventSequence,
        dispatch: () -> Unit,
    ) {
        invalidateAccount(nextPreviewEventSequence)
        dispatch()
    }

    /**
     * Establish account-owned buckets for this exact attempt. A UID-less preview remains suppressed;
     * it becomes readable only after a preview event from this attempt is observed with the same uid.
     */
    @Synchronized
    fun completeSignIn(attempt: HomeSignInAttempt, accountUid: String?): Boolean {
        if (attempt != pendingSignIn || attempt.profile != profile || accountUid.isNullOrBlank()) return false
        activeAccountUid = accountUid
        activeAccountGeneration = attempt.privacyGeneration
        suppressAccountHistory = false
        suppressContinueWatchingPreview = previewObservation != PreviewObservation(
            generation = attempt.privacyGeneration,
            profile = attempt.profile,
            uid = accountUid,
        )
        pendingSignIn = null
        generation += 1
        return true
    }

    /**
     * Record a UID-less preview only when its producing engine event belongs to the current account
     * generation and the caller independently verified the current ctx plus persisted bucket uid.
     */
    @Synchronized
    fun previewTicket(eventSequence: Long): HomePreviewTicket = HomePreviewTicket(
        privacy = capture(),
        eventSequence = eventSequence,
    )

    @Synchronized
    fun noteContinueWatchingRefresh(ticket: HomePreviewTicket, accountUid: String): Boolean {
        if (accountUid.isBlank()) return false
        if (ticket.eventSequence < minimumPreviewEventSequence) return false
        if (ticket.privacy.profile != profile) return false
        val eventGeneration = ticket.privacy.generation
        val pending = pendingSignIn
        if (
            pending != null &&
            pending.privacyGeneration == eventGeneration &&
            pending.profile == ticket.privacy.profile
        ) {
            previewObservation = PreviewObservation(eventGeneration, ticket.privacy.profile, accountUid)
            return false
        }
        if (
            activeAccountUid == accountUid &&
            (activeAccountGeneration == eventGeneration || generation == eventGeneration) &&
            suppressContinueWatchingPreview
        ) {
            suppressContinueWatchingPreview = false
            generation += 1
            return true
        }
        return false
    }

    private data class PreviewObservation(
        val generation: Long,
        val profile: HomeProfileIdentity,
        val uid: String,
    )
}

internal data class AuthAttemptLease(
    val id: Long,
    val requestId: String,
    val outcome: CompletableDeferred<AuthAttemptOutcome>,
)

/**
 * Owns the one native login request that may currently produce a terminal CoreEvent. An identical
 * retry is refused while its predecessor is unresolved, because the native AuthRequest has no nonce
 * and therefore cannot distinguish their responses. Different requests supersede safely: their exact
 * request digests differ, so a late predecessor response cannot complete the replacement lease.
 */
internal class AuthAttemptCoordinator {
    private var nextId = 0L
    private var active: AuthAttemptLease? = null
    private val retiredRequestIds = mutableSetOf<String>()

    @Synchronized
    fun begin(requestId: String): AuthAttemptLease? {
        val current = active
        if (current?.requestId == requestId || requestId in retiredRequestIds) return null
        current?.outcome?.complete(
            AuthAttemptOutcome.Failed(current.requestId, "Sign-in was replaced by a newer attempt."),
        )
        current?.let { retiredRequestIds += it.requestId }
        nextId += 1
        return AuthAttemptLease(
            id = nextId,
            requestId = requestId,
            outcome = CompletableDeferred(),
        ).also { active = it }
    }

    @Synchronized
    fun complete(outcome: AuthAttemptOutcome): Boolean {
        if (retiredRequestIds.remove(outcome.requestId)) return false
        val current = active ?: return false
        if (current.requestId != outcome.requestId) return false
        active = null
        return current.outcome.complete(outcome)
    }

    /** Release a lease whose native dispatch threw before a request could be accepted. */
    @Synchronized
    fun releaseBeforeDispatch(lease: AuthAttemptLease): Boolean {
        if (active !== lease) return false
        active = null
        return lease.outcome.complete(
            AuthAttemptOutcome.Failed(lease.requestId, "Sign-in could not be dispatched."),
        )
    }

    /**
     * Quarantine a dispatched request whose caller timed out or was cancelled. Its eventual terminal
     * event is consumed as stale before an identical retry can begin.
     */
    @Synchronized
    fun abandon(lease: AuthAttemptLease): Boolean {
        if (active !== lease) return false
        active = null
        retiredRequestIds += lease.requestId
        return lease.outcome.complete(
            AuthAttemptOutcome.Failed(lease.requestId, "Sign-in attempt was abandoned."),
        )
    }

    @Synchronized
    fun abandonActive(): Boolean {
        val current = active ?: return false
        return abandon(current)
    }
}

/** Convert ordinary failures to [Result] without turning structured cancellation into a value. */
internal suspend fun <T> runCatchingPreservingCancellation(block: suspend () -> T): Result<T> =
    try {
        Result.success(block())
    } catch (error: CancellationException) {
        throw error
    } catch (error: Throwable) {
        Result.failure(error)
    }

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
    private val addonManifestFetcher = AddonManifestFetcher(MANIFEST_FETCH_TIMEOUT_MS)

    /// Native in-client debrid resolver: turns a raw-torrent infoHash into a DIRECT, playable HTTPS URL
    /// through the user's own debrid account (keys in EncryptedSharedPreferences). Built lazily so no
    /// key store is opened until a torrent is actually resolved; with no key configured it is a no-op
    /// and torrents keep today's behavior (a clear error the player layer surfaces).
    private val debridResolver by lazy { DebridResolver(DebridKeys(appContext)) }

    /// The Keystore-backed "who was last signed in" display cache (ANDROID-PLAN.md §0 invariant #5);
    /// the engine's own persisted `ctx.profile.auth` remains the actual source of truth, see
    /// [AuthIdentityStore]'s doc comment.
    private val identityStore by lazy { AuthIdentityStore(appContext) }

    /// Source-ranking preferences + pins, the Android port of Apple `SourcePreferences` / `SourcePinStore`.
    /// Read by [StreamRanking] through an immutable snapshot installed before each source rank (the frozen
    /// snapshot pattern, so an off-thread rank never races a Settings edit). With no preferences set these
    /// are all defaults, so ranking stays byte-identical to the core-only scorer.
    private val sourcePrefs by lazy { SourcePreferencesStore(appContext) }
    /// Per-profile pins: the store reads the ACTIVE profile id from [ProfileStore] for its per-profile
    /// key, so one profile's pins can never leak into another (falls back to the shared default before
    /// [ProfileStore] is initialized). Reload wave: [ProfileStore.select] fires the switch listener that
    /// calls [SourcePinStore.reload] on a switch.
    private val sourcePins by lazy {
        SourcePinStore(appContext) { ProfileStore.sharedOrNull()?.activeProfileId ?: SourcePinStore.DEFAULT_PROFILE }
    }
    private val trackPrefs by lazy { TrackPreferencesStore(appContext) }

    /// Add-on order + per-profile on/off overlay (the Android port of Apple's
    /// `VortXSyncManager.appliedAddonOrder` + `ProfileStore.activeDisabledAddons` pair). Per-profile
    /// keying reads the ACTIVE profile id live on each call (same provider-lambda pattern as
    /// [sourcePins]), so a profile switch needs no reload hook here.
    private val addonPrefs by lazy {
        AddonPrefsStore(appContext) { ProfileStore.sharedOrNull()?.activeProfileId ?: AddonPrefsStore.DEFAULT_PROFILE }
    }
    private val homePagination = HomePaginationState(DEFAULT_BOARD_ROWS, DEFAULT_BOARD_ROWS)
    private val watchedIndex = WatchedIndex(appContext.filesDir)

    /// One-time flag read for the vortx-core SHADOW ranking lane (engine cutover Phase 7 slice 1,
    /// the Android analogue of the Apple VortxBridge shadow). Forced on the first stream rank; after
    /// that the call-site guard is a single volatile read, so the default-OFF flag costs nothing and
    /// the app behaves byte-identically until it is switched on. See [VortxRankingShadow].
    private val shadowRankingConfigured by lazy { VortxRankingShadow.configure(appContext); true }

    /// Field names that changed in the most recent engine event. extraBufferCapacity + DROP_OLDEST
    /// keeps a burst of back-to-back events from ever suspending (blocking) the native callback thread
    /// that publishes them -- see the class doc.
    private val changedFields = MutableSharedFlow<Set<String>>(
        extraBufferCapacity = 16,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    /** Transition signals folded into the same ordered [homeUpdates] stream as row snapshots. */
    private val homePrivacyClears = MutableSharedFlow<HomePrivacyPermit>(
        extraBufferCapacity = 4,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    /// A small supervisor-scoped coroutine scope this repository owns for work that must outlive any
    /// single caller's coroutine (republishing [authState] off engine events). `SupervisorJob` so one
    /// failure (e.g. a malformed ctx JSON on a single event) can't cancel the whole scope.
    private val engineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val streamLoadLock = Any()
    private val streamLoadFence = StreamLoadGenerationFence()
    private var streamLoadJob: Job? = null

    private val _authState = MutableStateFlow<AuthState>(AuthState.SignedOut)
    override val authState: StateFlow<AuthState> = _authState.asStateFlow()

    @Volatile
    private var started = false

    /** Dismissals fail closed while a network-backed account transition is unresolved. */
    private val authTransition = ContinueWatchingAuthTransition()

    private sealed interface HistoryRoute {
        data class Overlay(val profiles: ProfileStore, val profileId: String) : HistoryRoute
        data object Engine : HistoryRoute
    }

    private val historyOwnerFence = HistoryOwnerFence(
        captureOwner = ::continueWatchingOwnerLocked,
        ownerRouteMatches = ::historyOwnerRouteMatchesLocked,
        transitionInProgress = { authTransition.inProgress },
    )

    /// Raised before [signOut]'s Logout dispatch and cleared in layers only after [signIn] verifies
    /// the signed-in ctx, persisted library buckets, and a current-generation Continue Watching
    /// refresh for that exact account uid. Works around a
    /// stremio-core engine quirk: on
    /// `Logout` the engine clears `ctx.library` but emits `Internal::LibraryChanged(false)` (the
    /// "don't persist" variant), and `ContinueWatchingPreview`'s `update` only recomputes on
    /// `LibraryChanged(true)` -- so the engine's `continue_watching_preview` field keeps serving the
    /// PREVIOUS (signed-in) user's stale items forever, until the process restarts and the model is
    /// rebuilt from the (now-empty, persisted) library bucket from scratch. That's exactly the device
    /// finding: "Continue Watching posters persist after Logout" until relaunch. Board rails do NOT
    /// have this problem (Logout's `ProfileChanged` correctly drives `catalogs_update`), but we clear
    /// both defensively in [homeRowsLocked] so a signed-out Home is never rendered from ANY leftover
    /// per-account state while this flag is set.
    /** Serializes native preview callback tickets with account/profile transition barriers. */
    private val homeEventOrder = Any()
    private var homeEventSequence = 0L
    private val authAttemptCoordinator = AuthAttemptCoordinator()
    private val homePrivacyFence = HomePrivacyFence(initialProfile = currentHomeProfileIdentity())

    init {
        start()
        // Reload-hook wiring (the seam earlier waves left): on a profile switch / sync fold, re-sync the
        // per-profile source-ranking layer. SourcePreferences.reload() drops the memoized scores computed
        // under the previous profile's flat filter keys (which ProfileStore.applyPlayback has just
        // rewritten); SourcePinStore.reload() re-reads the new active profile's pins. No-op until
        // ProfileStore is initialized (VortXApplication.onCreate), which always precedes engine
        // construction, so this registers exactly once for the process.
        ProfileStore.sharedOrNull()?.let { profiles ->
            profiles.addHomeTransitionListener {
                val clear = synchronized(homeEventOrder) {
                    val changed = homePrivacyFence.switchProfile(
                        activeProfile = currentHomeProfileIdentity(),
                        nextPreviewEventSequence = homeEventSequence + 1,
                    )
                    if (changed) homePrivacyFence.capture() else null
                }
                clear?.let(homePrivacyClears::tryEmit)
            }
            profiles.addSwitchListener {
                sourcePrefs.reload()
                sourcePins.reload()
            }
        }
        // Home is per-profile (the CW rail swaps between the engine rail and the overlay rail on a
        // switch, and a per-profile prefs apply can change what the board shows). Mirrors the tail of
        // Apple `applyPlayback` calling `CoreBridge.rebuildBoardRows()`: a switch/fold re-dispatches the
        // board load so homeUpdates converges immediately instead of riding the 3s safety poll.
        ProfileStore.sharedOrNull()?.onRebuildBoard = { runCatching { dispatchHomeLoad() } }
    }

    // ---- Per-profile watch gate (Apple `ProfileStore.activeUsesEngineHistory`, Profiles.swift:275) ----

    /// The profile store when an OVERLAY profile is active (a non-owner shared profile that keeps its
    /// own PRIVATE watch history), else null (the owner and own-account profiles use the engine/account
    /// library, exactly like before profiles existed). Every watch read/write in this repository
    /// consults this FIRST — the Android mirror of Apple CoreBridge routing through
    /// `ProfileStore.activeUsesEngineHistory`. The invariant it enforces: an overlay profile can never
    /// READ the account's Continue Watching / library / watched ticks, and can never WRITE its progress
    /// or marks into the account library (the never-poison rule from the documented sync incident).
    private fun overlayProfiles(): ProfileStore? =
        ProfileStore.sharedOrNull()?.takeIf { !it.activeUsesEngineHistory }

    private fun currentNativeAuthState(): AuthState = if (started) {
        runCatching {
            EngineState.parseAuthState(StremioCoreNative.getState(EngineActions.ctxField()))
        }.getOrDefault(_authState.value)
    } else {
        _authState.value
    }

    private fun continueWatchingOwnerLocked(revision: Long): ContinueWatchingOwner {
        val profiles = ProfileStore.sharedOrNull()
        val profileId = profiles?.activeProfileId ?: UserProfile.OWNER_ID
        val accountSlot = profiles?.activeKeychainAccount ?: "primary"
        val principal = authPrincipal(currentNativeAuthState())
        return ContinueWatchingOwner(
            profileId = profileId,
            accountSlot = accountSlot,
            principal = principal,
            usesEngineHistory = profiles?.activeUsesEngineHistory ?: true,
            revision = revision,
        )
    }

    private fun historyOwnerRouteMatchesLocked(owner: ContinueWatchingOwner): Boolean {
        val profiles = ProfileStore.sharedOrNull()
        val profileId = profiles?.activeProfileId ?: UserProfile.OWNER_ID
        val accountSlot = profiles?.activeKeychainAccount ?: "primary"
        val usesEngineHistory = profiles?.activeUsesEngineHistory ?: true
        if (
            owner.profileId != profileId ||
            owner.accountSlot != accountSlot ||
            owner.usesEngineHistory != usesEngineHistory
        ) return false

        val nativeState = currentNativeAuthState()
        if (owner.principal != authPrincipal(nativeState)) return false
        return if (owner.usesEngineHistory) {
            engineHistoryPrincipalMatches(profiles?.active, nativeState)
        } else {
            profiles?.active?.id == owner.profileId
        }
    }

    private fun historyRouteLocked(owner: ContinueWatchingOwner): HistoryRoute {
        check(historyOwnerRouteMatchesLocked(owner)) { "History owner or account principal changed." }
        return if (owner.usesEngineHistory) {
            HistoryRoute.Engine
        } else {
            HistoryRoute.Overlay(
                profiles = requireNotNull(ProfileStore.sharedOrNull()) { "History overlay is unavailable." },
                profileId = owner.profileId,
            )
        }
    }

    override fun continueWatchingOwner(): ContinueWatchingOwner =
        ContinueWatchingOwnerGate.serialized(::continueWatchingOwnerLocked)

    private fun continueWatchingSnapshot(): List<MetaItem> {
        val overlayStore = overlayProfiles()
        return when {
            overlayStore != null -> runCatching { overlayStore.continueWatching() }.getOrDefault(emptyList())
            homePrivacyFence.isRaised || !engineHistoryPrincipalMatches() -> emptyList()
            else -> runCatching {
                EngineState.parseContinueWatching(StremioCoreNative.getState(EngineActions.continueWatchingPreviewField()))
            }.getOrDefault(emptyList())
        }
    }

    private fun strictContinueWatchingItemsLocked(): List<MetaItem> {
        val overlayStore = overlayProfiles()
        if (overlayStore != null) return overlayStore.continueWatching()
        check(started) { "Continue Watching native engine is not started." }
        requireEngineHistoryPrincipalMatch()
        check(!homePrivacyFence.isRaised) { "Continue Watching native state is not trustworthy after sign-out." }
        val json = StremioCoreNative.getState(EngineActions.continueWatchingPreviewField())
        return EngineState.parseContinueWatchingStrict(json).getOrThrow()
    }

    override suspend fun continueWatchingSnapshot(
        expectedOwner: ContinueWatchingOwner,
    ): Result<ContinueWatchingSnapshot> = withContext(Dispatchers.Default) { runCatching {
        ContinueWatchingOwnerGate.serialized { revision ->
            check(!authTransition.inProgress) { "Continue Watching account transition is in progress." }
            val owner = continueWatchingOwnerLocked(revision)
            check(owner == expectedOwner) { "Continue Watching owner changed." }
            val items = strictContinueWatchingItemsLocked()
            check(continueWatchingOwnerLocked(revision) == expectedOwner) { "Continue Watching owner changed." }
            ContinueWatchingSnapshot(owner, items)
        }
    } }

    private fun currentHomeProfileIdentity(): HomeProfileIdentity {
        val profiles = ProfileStore.sharedOrNull()
        val active = profiles?.active
        return HomeProfileIdentity(
            profileId = profiles?.activeProfileId ?: "default",
            usesEngineHistory = profiles?.activeUsesEngineHistory ?: true,
            accountKey = profiles?.activeKeychainAccount ?: "default",
            expectedPrincipal = active?.takeIf { it.usesOwnAccount }
                ?.email
                ?.trim()
                ?.lowercase()
                ?.takeIf { it.isNotEmpty() },
        )
    }

    private fun engineHistoryPrincipalMatches(): Boolean {
        val nativeState = currentNativeAuthState()
        return engineHistoryPrincipalMatches(ProfileStore.sharedOrNull()?.active, nativeState)
    }

    private fun requireEngineHistoryPrincipalMatch() {
        check(engineHistoryPrincipalMatches()) {
            "This profile's own account is not authenticated in the native engine."
        }
    }
    /// Re-shape an engine [MetaDetail] for the owner captured by [permit]. Overlay resume and watched
    /// fields come from one immutable entry read while that exact profile is active. A transition before
    /// or after the read returns null instead of publishing a mixed-profile detail snapshot.
    private fun withOverlayState(detail: MetaDetail, permit: HistoryReadPermit): MetaDetail? {
        val shaped = try {
            when (val route = historyRouteLocked(permit.owner)) {
                HistoryRoute.Engine -> detail
                is HistoryRoute.Overlay -> route.profiles.withActiveOverlayProfile(route.profileId) { overlay ->
                    val entry = overlay.watch[detail.id]
                    val libraryItem = entry?.let {
                        LibraryItemInfo(
                            id = detail.id,
                            removed = false,
                            temp = false,
                            videoId = it.videoId,
                            timeOffsetMs = it.timeOffsetMs.toLong(),
                            durationMs = it.durationMs.toLong(),
                            // A movie is watched in the overlay when its OWN meta id is in watchedVideoIds.
                            timesWatched = if (detail.id in it.watchedVideoIds) 1 else 0,
                            flaggedWatched = if (detail.id in it.watchedVideoIds) 1 else 0,
                        )
                    }
                    detail.copy(
                        libraryItem = libraryItem,
                        watchedVideoIds = entry?.watchedVideoIds?.toSet() ?: emptySet(),
                    )
                }
            }
        } catch (_: IllegalStateException) {
            return null
        }
        return shaped.takeIf { historyOwnerFence.readIsCurrent(permit) }
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
            val restoredUid = (_authState.value as? AuthState.SignedIn)?.uid?.takeIf { it.isNotBlank() }
            synchronized(homeEventOrder) {
                homePrivacyFence.establishFreshEngineState(
                    isSignedIn = _authState.value is AuthState.SignedIn,
                    signedInUid = restoredUid,
                    accountUidVerified = restoredUid?.let {
                        engineHistoryPrincipalMatches() && WatchedIndex.storageMatchesUid(appContext.filesDir, it)
                    } ?: (_authState.value is AuthState.SignedOut),
                    activeProfile = currentHomeProfileIdentity(),
                    nextPreviewEventSequence = homeEventSequence + 1,
                )
            }
        }
    }

    /// Decode a `RuntimeEvent`: publish changed field names on a NewState, or an attempt-bound login
    /// result on a matching CoreEvent (see [EngineState.parseAuthAttemptOutcome]). Called on a native
    /// worker thread (see the class doc) -- every branch here is a cheap parse + a non-suspending
    /// `tryEmit`, so this always returns promptly regardless of collector speed.
    private fun onEngineEvent(json: ByteArray) {
        // Capture sequence + privacy ownership at callback ENTRY. A callback that entered before a
        // profile/account transition therefore keeps the old generation even if JSON parsing or its
        // async uid proof completes after that transition.
        val callbackTicket = synchronized(homeEventOrder) {
            homeEventSequence += 1
            homePrivacyFence.previewTicket(homeEventSequence)
        }
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
                val continueWatchingTicket = callbackTicket.takeIf {
                    EngineActions.FIELD_CONTINUE_WATCHING_PREVIEW in fields
                }
                // Diagnostic contract with the on-device test script: `adb logcat -s StremioXEngine`
                // MUST show these lines while Home loads -- their absence proves the native event
                // path is broken (vs. a parsing/reactivity bug on this side).
                Log.d(TAG, "engine event NewState fields=$fields")
                // ctx changed (a sign-in, sign-out, or a persisted-profile hydration racing this
                // listener registration): refresh the owner before publishing the field tick. That
                // prevents a Home collector from pairing newly loaded native state with the previous
                // account token. The callback itself still returns immediately.
                if (EngineActions.FIELD_CTX in fields) {
                    engineScope.launch {
                        runCatching { refreshAuthState() }
                            .onFailure { Log.w(TAG, "could not refresh auth state after ctx event", it) }
                        changedFields.tryEmit(fields)
                    }
                } else {
                    changedFields.tryEmit(fields)
                }
                // The preview carries no uid. Establish its owner only off the native callback thread,
                // after independently reading a non-empty ctx uid and matching persisted buckets, and
                // bind that proof to the privacy generation captured with this exact engine event.
                if (continueWatchingTicket != null) {
                    engineScope.launch {
                        val uid = (EngineState.parseAuthState(
                            StremioCoreNative.getState(EngineActions.ctxField()),
                        ) as? AuthState.SignedIn)?.uid?.takeIf { it.isNotBlank() } ?: return@launch
                        if (WatchedIndex.storageMatchesUid(appContext.filesDir, uid)) {
                            val becameReadable = homePrivacyFence.noteContinueWatchingRefresh(
                                ticket = continueWatchingTicket,
                                accountUid = uid,
                            )
                            if (becameReadable) {
                                changedFields.tryEmit(setOf(EngineActions.FIELD_CONTINUE_WATCHING_PREVIEW))
                            }
                        }
                    }
                }
            }
            "CoreEvent" -> {
                Log.d(TAG, "engine event CoreEvent ${event.optJSONObject("args")?.optString("event")}")
                EngineState.parseAuthAttemptOutcome(json.toString(Charsets.UTF_8))?.let {
                    authAttemptCoordinator.complete(it)
                }
            }
        }
    }

    /// Pull `ctx`, parse it into [AuthState], publish it, and keep [identityStore] in sync (a display
    /// cache only -- see its doc comment; the engine's own `ctx.profile.auth` stays authoritative).
    private fun refreshAuthState() {
        val state = EngineState.parseAuthState(StremioCoreNative.getState(EngineActions.ctxField()))
        ContinueWatchingOwnerGate.serialized {
            val ownerChanged = authPrincipal(_authState.value) != authPrincipal(state)
            val unexpectedIdentityClear = if (ownerChanged && !authTransition.inProgress) {
                synchronized(homeEventOrder) {
                    homePrivacyFence.invalidateAccount(homeEventSequence + 1)
                }
            } else {
                null
            }
            _authState.value = state
            if (ownerChanged) ContinueWatchingOwnerGate.advance()
            when (state) {
                is AuthState.SignedIn -> identityStore.rememberSignedIn(state.email)
                AuthState.SignedOut -> identityStore.forget()
            }
            unexpectedIdentityClear?.let(homePrivacyClears::tryEmit)
        }
    }

    private fun authPrincipal(state: AuthState): String = when (state) {
        is AuthState.SignedIn -> state.uid ?: state.email ?: "signed-in"
        AuthState.SignedOut -> "signed-out"
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
        val settled = withTimeoutOrNull<String>(loadTimeoutSeconds.seconds) {
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

    private suspend fun <T> runLatestStreamLoad(block: suspend (Long) -> T): T {
        val ownerJob = currentCoroutineContext()[Job]
            ?: throw IllegalStateException("A stream load requires a coroutine Job")
        val generation = synchronized(streamLoadLock) {
            streamLoadJob?.takeIf { it !== ownerJob }?.cancel(
                CancellationException("Superseded by a newer stream target"),
            )
            streamLoadJob = ownerJob
            streamLoadFence.begin()
        }
        return try {
            block(generation)
        } finally {
            synchronized(streamLoadLock) {
                if (streamLoadJob === ownerJob) streamLoadJob = null
            }
        }
    }

    private fun requireCurrentStreamLoad(generation: Long) {
        if (!streamLoadFence.isCurrent(generation)) {
            throw CancellationException("Superseded by a newer stream target")
        }
    }

    private suspend fun loadStreamFieldUntil(
        generation: Long,
        actionJson: String,
        streamId: String?,
    ): String {
        val field = EngineActions.FIELD_META_DETAILS
        val settled = withTimeoutOrNull(loadTimeoutSeconds.seconds) {
            requireCurrentStreamLoad(generation)
            StremioCoreNative.dispatch(actionJson)
            val immediate = StremioCoreNative.getState("\"$field\"")
            requireCurrentStreamLoad(generation)
            if (EngineState.parseStreamGroups(immediate, streamId).isNotEmpty()) return@withTimeoutOrNull immediate
            changedFields
                .filter { field in it }
                .map {
                    requireCurrentStreamLoad(generation)
                    StremioCoreNative.getState("\"$field\"")
                }
                .first { EngineState.parseStreamGroups(it, streamId).isNotEmpty() }
        }
        requireCurrentStreamLoad(generation)
        return settled ?: StremioCoreNative.getState("\"$field\"")
    }

    /**
     * Wait for a series' remembered source provider after the first playable answer arrives. With no
     * playable source the normal field timeout still applies; once playback is possible, the remembered
     * provider gets at most [StreamRanking.WANTED_SOURCE_DEADLINE_SECONDS] to settle. Polling the resident
     * state also survives a dropped NewState notification and mirrors the Apple wait policy.
     */
    private suspend fun loadStreamsUntilWanted(
        actionJson: String,
        streamId: String,
        rememberedQuality: String,
        wantedAddon: String,
        generation: Long,
    ): String {
        val settled = withTimeoutOrNull<String>(loadTimeoutSeconds.seconds) {
            requireCurrentStreamLoad(generation)
            StremioCoreNative.dispatch(actionJson)
            var firstPlayableAtMs: Long? = null
            var answer: String? = null
            while (answer == null) {
                requireCurrentStreamLoad(generation)
                val state = StremioCoreNative.getState("\"${EngineActions.FIELD_META_DETAILS}\"")
                val groups = EngineState.parseStreamGroups(state, streamId)
                val nowMs = monotonicMs()
                if (groups.isNotEmpty() && firstPlayableAtMs == null) firstPlayableAtMs = nowMs

                val firstAt = firstPlayableAtMs
                if (firstAt != null) {
                    val progress = EngineState.parseStreamLoadProgress(state, streamId)
                    if (
                        StreamRanking.resolveSettled(
                            groups = groups,
                            loaded = progress.loaded,
                            total = progress.total,
                            secondsSinceFirstPlayable = (nowMs - firstAt) / 1_000.0,
                            rememberedQuality = rememberedQuality,
                            wantedAddon = wantedAddon,
                        )
                    ) {
                        answer = state
                    }
                }
                if (answer == null) delay(STREAM_SETTLEMENT_POLL_MS)
            }
            answer
        }
        requireCurrentStreamLoad(generation)
        return settled ?: StremioCoreNative.getState("\"${EngineActions.FIELD_META_DETAILS}\"")
    }

    /// One-shot Home (kept for the [CatalogRepository] contract; the Home screen itself collects
    /// [homeUpdates]): waits until at least one board row has content, then snapshots.
    // withContext(Dispatchers.Default): the loadFieldUntil dispatch/getState + ownedHomeSnapshot()/parse
    // must run off the caller's (Main) context -- JNI + org.json never on the UI thread.
    override suspend fun home(): Result<List<Catalog>> = withContext(Dispatchers.Default) { runCatching {
        val rows = homePagination.reset()
        StremioCoreNative.dispatch(EngineActions.loadBoard())
        val state = loadFieldUntil(EngineActions.FIELD_BOARD, EngineActions.loadBoardRange(rows)) {
            EngineState.parseCatalogs(it).isNotEmpty()
        }
        homePagination.onBoardEvent(
            total = EngineState.boardCatalogCount(state),
            rows = EngineState.parseCatalogs(state),
        )
        currentHomeSnapshot().rows
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
    /// whether the events actually flowed. distinctUntilChanged suppresses the no-change poll spam.
    /// This stream is deliberately not conflated: an authoritative clear must precede the new rows.
    override fun homeUpdates(): Flow<HomeUpdate> = channelFlow {
        val publicationLock = Any()
        val initialPermit = homePrivacyFence.capture()
        var announcedGeneration = initialPermit.generation
        var announcedProfile = initialPermit.profile
        var updateSequence = 0L

        fun sendClearIfNeeded(
            permit: HomePrivacyPermit,
            owner: ContinueWatchingOwner,
        ): Boolean = synchronized(publicationLock) {
            if (permit.generation == announcedGeneration && permit.profile == announcedProfile) {
                return@synchronized true
            }
            updateSequence += 1
            val sent = trySend(
                HomeUpdate(
                    rows = emptyList(),
                    generation = permit.generation,
                    sequence = updateSequence,
                    profileId = permit.profile.profileId,
                    authoritative = true,
                    owner = owner,
                ),
            ).isSuccess
            if (sent) {
                announcedGeneration = permit.generation
                announcedProfile = permit.profile
            }
            sent
        }
        fun publishHomeSnapshot(reconcilePagination: Boolean = false) {
            while (isActive) {
                val fenced = fencedOwnedHomeSnapshot(reconcilePagination) ?: return
                var publishAttempted = false
                val published = homePrivacyFence.publishIfCurrent(fenced.privacy) {
                    publishAttempted = true
                    if (!sendClearIfNeeded(fenced.privacy, fenced.snapshot.owner)) {
                        return@publishIfCurrent false
                    }
                    synchronized(publicationLock) {
                        updateSequence += 1
                        trySend(
                            HomeUpdate(
                                rows = fenced.snapshot.rows,
                                generation = fenced.privacy.generation,
                                sequence = updateSequence,
                                profileId = fenced.privacy.profile.profileId,
                                owner = fenced.snapshot.owner,
                            ),
                        ).isSuccess
                    }
                }
                // A stale build is rebuilt. A closed/full channel is not a privacy race and should
                // not spin; the next event/poll will carry a fresh conflated snapshot if still open.
                if (published || publishAttempted) return
            }
        }

        // Subscribe before the first board dispatch so no sign-out/sign-in clear can fall into the
        // launch gap between an initial account snapshot and the long-lived collectors.
        launch(start = CoroutineStart.UNDISPATCHED) {
            homePrivacyClears.collect { permit ->
                val owner = continueWatchingOwner()
                homePrivacyFence.publishIfCurrent(permit) {
                    sendClearIfNeeded(permit, owner)
                }
            }
        }
        var lastUid = (EngineState.parseAuthState(StremioCoreNative.getState(EngineActions.ctxField())) as? AuthState.SignedIn)?.uid
        dispatchHomeLoad()
        // Both dispatches update the local model synchronously. Reconcile that authoritative state
        // immediately so a fully cached board does not depend on a later network event to enable paging.
        publishHomeSnapshot(reconcilePagination = true)
        launch {
            changedFields.collect { fields ->
                if (fields.none { it in HOME_FIELDS }) return@collect
                val reloaded = EngineActions.FIELD_CTX in fields
                if (reloaded) {
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
                publishHomeSnapshot(
                    reconcilePagination = EngineActions.FIELD_BOARD in fields || reloaded,
                )
            }
        }
        launch {
            while (isActive) {
                delay(HOME_POLL_MS)
                publishHomeSnapshot()
            }
        }
        // flowOn so the channelFlow producer -- every ownedHomeSnapshot()/getState()/parse below -- runs on
        // Dispatchers.Default, never the collector's (Main) context: JNI + org.json off the UI thread.
    }.distinctUntilChanged { old, new ->
        old.generation == new.generation &&
            old.profileId == new.profileId &&
            old.owner == new.owner &&
            old.authoritative == new.authoritative &&
            old.rows == new.rows
    }.flowOn(Dispatchers.Default)

    private fun dispatchHomeLoad() {
        val rows = homePagination.reset()
        StremioCoreNative.dispatch(EngineActions.loadBoard())
        StremioCoreNative.dispatch(EngineActions.loadBoardRange(rows))
    }

    override suspend fun loadHomeRowNextPage(catalog: Catalog): Result<Unit> =
        withContext(Dispatchers.Default) {
            val engineIndex = homePagination.claimNextPage(catalog)
                ?: return@withContext Result.success(Unit)
            runCatching {
                StremioCoreNative.dispatch(EngineActions.loadBoardRowNextPage(engineIndex))
                Unit
            }.onFailure {
                homePagination.abortNextPage(engineIndex)
            }
        }

    override suspend fun loadMoreHomeRows(): Result<Unit> = withContext(Dispatchers.Default) {
        val rows = homePagination.claimMoreRows() ?: return@withContext Result.success(Unit)
        runCatching {
            StremioCoreNative.dispatch(EngineActions.loadBoardRange(rows))
            Unit
        }.onFailure {
            homePagination.abortMoreRows()
        }
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
    private fun fencedOwnedHomeSnapshot(reconcilePagination: Boolean = false): FencedHomeSnapshot? =
        ContinueWatchingOwnerGate.serialized { revision ->
            if (authTransition.inProgress) return@serialized null
            val privacy = homePrivacyFence.capture()
            FencedHomeSnapshot(
                privacy = privacy,
                snapshot = HomeSnapshot(
                    owner = continueWatchingOwnerLocked(revision),
                    rows = homeRowsLocked(privacy, reconcilePagination),
                ),
            )
        }

    /** Called only while [ContinueWatchingOwnerGate] is held, so rows and owner cannot straddle a switch. */
    private fun homeRowsLocked(
        privacy: HomePrivacyPermit,
        reconcilePagination: Boolean = false,
    ): List<Catalog> {
        val ctxJson = StremioCoreNative.getState(EngineActions.ctxField())
        val titleMap = EngineState.parseAddonCatalogTitles(ctxJson)
        val boardJson = StremioCoreNative.getState(EngineActions.boardField())
        val parsedBoardRows = EngineState.parseCatalogs(boardJson, titleMap)
        if (reconcilePagination) {
            homePagination.onBoardEvent(
                total = EngineState.boardCatalogCount(boardJson),
                rows = parsedBoardRows,
            )
        }
        val pagedBoardRows = parsedBoardRows.map { row ->
            row.copy(hasNextPage = homePagination.rowHasNextPage(row.engineIndex))
        }
        val profileStore = ProfileStore.sharedOrNull()
        val principalMatches = engineHistoryPrincipalMatches(
            profileStore?.active,
            EngineState.parseAuthState(ctxJson),
        )
        val suppressEngineHistory = privacy.suppressAccountHistory || !principalMatches
        val watchedIds = if (profileStore != null && !profileStore.activeUsesEngineHistory) {
            WatchedIndex.overlayIds(profileStore.watch)
        } else {
            val uid = (EngineState.parseAuthState(ctxJson) as? AuthState.SignedIn)?.uid
            WatchedIndex.engineHomeIds(
                bucketIds = if (suppressEngineHistory) emptySet() else watchedIndex.engineIds(uid),
                libraryIds = if (suppressEngineHistory) {
                    emptySet()
                } else {
                    EngineState.parseWatchedLibraryIds(
                        StremioCoreNative.getState(EngineActions.libraryField()),
                    )
                },
                continueWatchingIds = if (privacy.suppressContinueWatchingPreview || !principalMatches) {
                    emptySet()
                } else {
                    EngineState.parseWatchedContinueWatchingIds(
                        StremioCoreNative.getState(EngineActions.continueWatchingPreviewField()),
                    )
                },
                suppressAccountHistory = suppressEngineHistory,
            )
        }
        val allBoardRows = WatchedIndex.apply(pagedBoardRows, watchedIds)
        // Per-profile add-on on/off overlay (Apple `buildBoardRows`' disabledAddons guard,
        // CoreBridge.swift:2191): a disabled add-on's catalog rows must not render on this profile's
        // Home. The row id is "<base>|<type>|<id>" (see [EngineState.parseCatalogs]); rows with no
        // base ("row-N" fallbacks, the "continue" rail prepended below) are never filtered.
        val disabledAddons = addonPrefs.disabledBases()
        val boardRows = if (disabledAddons.isEmpty()) {
            allBoardRows
        } else {
            allBoardRows.filter { row ->
                val base = row.id.substringBefore('|', "")
                base.isEmpty() || AddonOrder.normalize(base) !in disabledAddons
            }
        }
        // Suppressed right after sign-out: see [homePrivacyFence]'s doc comment. The engine's
        // continue_watching_preview field keeps serving the PREVIOUS account's items indefinitely (an
        // engine quirk, not a race), so trusting it here would render a signed-out Home with another
        // account's "Continue Watching" posters. Board rows are unaffected (Logout correctly drives a
        // real reload) so they still render live.
        // Per-profile gate: an OVERLAY profile's Continue Watching is its private overlay, never the
        // account's engine rail (Apple `ProfileStore.cwItems` vs the engine preview — the
        // activeUsesEngineHistory split).
        val overlayStore = overlayProfiles()
        val continueWatching = when {
            overlayStore != null -> runCatching { overlayStore.continueWatching() }.getOrDefault(emptyList())
            privacy.suppressContinueWatchingPreview || !principalMatches -> emptyList()
            else -> runCatching {
                EngineState.parseContinueWatching(StremioCoreNative.getState(EngineActions.continueWatchingPreviewField()))
            }.getOrDefault(emptyList())
        }
        val rows = if (continueWatching.isEmpty()) {
            boardRows
        } else {
            listOf(Catalog(id = "continue", title = "Continue Watching", items = continueWatching)) + boardRows
        }
        return rows
    }

    /** One-shot callers retry if an auth transition crossed their synchronous JNI/JSON build. */
    private fun currentHomeSnapshot(reconcilePagination: Boolean = false): HomeSnapshot {
        while (true) {
            val fenced = fencedOwnedHomeSnapshot(reconcilePagination)
                ?: throw IllegalStateException("Home owner is changing.")
            if (homePrivacyFence.isCurrent(fenced.privacy)) return fenced.snapshot
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
        // Per-profile gate: an OVERLAY profile's Library is its private overlay (every title it has
        // watched or saved), never the account's engine library (Apple `ProfileStore.libraryItems`).
        // Slice note: the overlay list ignores the type/sort chips for now (no pivot row renders).
        val permit = historyOwnerFence.captureRead()
            ?: return@runCatching LibraryResult(items = emptyList())
        val result = if (!permit.owner.usesEngineHistory) {
            val items = runCatching {
                ProfileStore.sharedOrNull()?.withActiveOverlayProfile(permit.owner.profileId) { overlay ->
                    overlay.libraryItems()
                }.orEmpty()
            }.getOrDefault(emptyList())
            LibraryResult(items = items)
        } else {
            val dispatchAction = if (requestJson != null) {
                EngineActions.loadLibrarySelect(requestJson)
            } else {
                EngineActions.loadLibrary()
            }
            val state = loadFieldUntil(EngineActions.FIELD_LIBRARY, dispatchAction) { true }
            LibraryResult(
                items = EngineState.parseLibrary(state),
                filters = EngineState.parseLibraryFilters(state),
            )
        }
        if (historyOwnerFence.readIsCurrent(permit)) result else LibraryResult(items = emptyList())
    } }

    override suspend fun libraryPortableItems(now: String): Result<List<LibraryPortability.Item>> =
        withContext(Dispatchers.Default) { runCatching {
            val permit = historyOwnerFence.captureRead() ?: return@runCatching emptyList()
            // Overlay export has no portable representation yet. Never fall through to the engine
            // account's library while a private-history profile is active.
            if (!permit.owner.usesEngineHistory) return@runCatching emptyList()
            // Same field + same dispatch as [library] above (a derived read of the persisted ctx.library
            // bucket, no add-on HTTP, ready immediately), differing only in the parse: the portable shape
            // keeps each entry's resume state and drops the engine's removed/temp bookkeeping entries.
            // Always the DEFAULT selection (no requestJson): an export is the whole library, never the
            // type/sort pivot the Library screen happens to be showing.
            val state = loadFieldUntil(EngineActions.FIELD_LIBRARY, EngineActions.loadLibrary()) { true }
            val items = EngineState.parseLibraryPortable(state, now)
            if (historyOwnerFence.readIsCurrent(permit)) items else emptyList()
        } }

    override suspend fun addToLibrary(item: MetaItem): Result<Unit> = runCatching {
        historyOwnerFence.mutate { owner ->
            when (val route = historyRouteLocked(owner)) {
                is HistoryRoute.Overlay -> route.profiles.withActiveOverlayProfile(route.profileId) { overlay ->
                    overlay.addLibraryEntry(
                        metaId = item.id,
                        name = item.name,
                        type = item.type.id,
                        poster = item.poster,
                    )
                }
                HistoryRoute.Engine -> StremioCoreNative.dispatch(
                    EngineActions.addToLibrary(
                        id = item.id,
                        type = item.type.id,
                        name = item.name,
                        poster = item.poster,
                    ),
                )
            }
        }
    }

    override suspend fun removeFromLibrary(id: String): Result<Unit> = runCatching {
        historyOwnerFence.mutate { owner ->
            when (val route = historyRouteLocked(owner)) {
                is HistoryRoute.Overlay -> route.profiles.withActiveOverlayProfile(route.profileId) { overlay ->
                    overlay.removeWatchEntry(id)
                }
                HistoryRoute.Engine -> StremioCoreNative.dispatch(EngineActions.removeFromLibrary(id))
            }
        }
    }

    override suspend fun removeFromContinueWatching(
        target: ContinueWatchingDismissal,
    ): Result<Unit> = withContext(Dispatchers.Default) { runCatching {
        historyOwnerFence.mutate(expectedOwner = target.owner) { owner ->
            when (val route = historyRouteLocked(owner)) {
                is HistoryRoute.Overlay -> route.profiles.withActiveOverlayProfile(route.profileId) { overlay ->
                    if (validateContinueWatchingRemovalTarget(overlay.continueWatching(), target)) {
                        overlay.removeWatchEntry(target.id)
                    }
                }
                HistoryRoute.Engine -> {
                    // ActionCtx::RemoveFromLibrary accepts only a bare id. Carry type to this boundary and
                    // fail closed when the current native snapshot contains the same id under another type.
                    if (validateContinueWatchingRemovalTarget(strictContinueWatchingItemsLocked(), target)) {
                        StremioCoreNative.dispatch(EngineActions.removeFromLibrary(target.id))
                    }
                }
            }
            // Overlay mutation is local and native events may be coalesced. Force one off-Main authoritative
            // Home re-read so the optimistic UI can observe confirmation without waiting for the safety poll.
            changedFields.tryEmit(setOf(EngineActions.FIELD_CONTINUE_WATCHING_PREVIEW))
        }
        Unit
    } }

    override suspend fun installedAddons(): Result<List<InstalledAddon>> = withContext(Dispatchers.Default) { runCatching {
        // Display order = the user's applied add-on order (Apple `orderedByApplied` on the add-on
        // list); newly installed add-ons fold in at the end in engine order. Each entry is stamped
        // with the ACTIVE profile's on/off overlay so the Add-ons screen renders the eye toggle
        // state without a second query.
        val addons = EngineState.parseInstalledAddons(StremioCoreNative.getState(EngineActions.ctxField()))
        val disabledAddons = addonPrefs.disabledBases()
        addonPrefs.orderedByApplied(addons) { it.transportUrl }.map { addon ->
            val disabled = AddonOrder.normalize(addon.transportUrl) in disabledAddons
            if (disabled) addon.copy(isDisabled = true) else addon
        }
    } }

    override suspend fun setAddonDisabled(transportUrl: String, disabled: Boolean): Result<Unit> =
        withContext(Dispatchers.Default) { runCatching {
            addonPrefs.setDisabled(transportUrl, disabled)
            // A LOCAL overlay change the engine knows nothing about: poke our own reactive surfaces
            // (ctxUpdates listeners re-read the add-on list; homeUpdates re-snapshots the filtered
            // board) so the toggle shows everywhere immediately instead of riding the 3s safety poll.
            changedFields.tryEmit(setOf(EngineActions.FIELD_CTX))
            Unit
        } }

    override suspend fun applyAddonOrder(transportUrls: List<String>): Result<Unit> =
        withContext(Dispatchers.Default) { runCatching {
            addonPrefs.setAppliedOrder(transportUrls)
            // Same local-poke as [setAddonDisabled]: the list order + future meta picks changed.
            changedFields.tryEmit(setOf(EngineActions.FIELD_CTX))
            Unit
        } }

    override suspend fun setCatalogWatched(item: MetaItem, isWatched: Boolean): Result<Unit> =
        withContext(Dispatchers.Default) { runCatching {
            historyOwnerFence.mutate { owner ->
                when (val route = historyRouteLocked(owner)) {
                    is HistoryRoute.Overlay -> route.profiles.withActiveOverlayProfile(route.profileId) { overlay ->
                        overlay.setWatched(
                            isWatched,
                            item.id,
                            listOf(item.id),
                            item.name,
                            item.type.id,
                            item.poster,
                        )
                    }
                    HistoryRoute.Engine -> {
                        // Hand the native action its resident preview when available. The minimal fallback
                        // is the same shape accepted by AddToLibrary.
                        val preview = rawMetaPreview(item.id) ?: JSONObject()
                            .put("id", item.id)
                            .put("type", item.type.id)
                            .put("name", item.name)
                            .also { if (item.poster != null) it.put("poster", item.poster) }
                        StremioCoreNative.dispatch(EngineActions.metaItemMarkAsWatched(preview, isWatched))
                    }
                }
                changedFields.tryEmit(setOf(EngineActions.FIELD_CTX))
            }
            Unit
        } }

    /// The raw `MetaItemPreview` JSON for a catalog item id, pulled verbatim from whichever catalog
    /// field currently holds it. Mirrors Apple `CoreBridge.rawMetaPreview(forId:)`: catalog state
    /// nests previews under `content` arrays a few levels down, so this is a bounded depth-first
    /// search over the three catalog-shaped fields. Null when no resident field holds the id.
    private fun rawMetaPreview(metaId: String): JSONObject? {
        for (field in listOf(EngineActions.FIELD_BOARD, EngineActions.FIELD_DISCOVER, EngineActions.FIELD_SEARCH)) {
            val root = runCatching { JSONObject(StremioCoreNative.getState("\"$field\"")) }.getOrNull() ?: continue
            findMetaPreview(root, metaId)?.let { return it }
        }
        return null
    }

    /// Depth-first search for a meta preview (`{id, type, name, …}`) with the given id inside an
    /// engine state object (Apple `CoreBridge.findMetaPreview`).
    private fun findMetaPreview(node: Any?, metaId: String): JSONObject? {
        when (node) {
            is JSONObject -> {
                if (node.optString("id") == metaId && node.opt("type") is String && node.opt("name") is String) return node
                for (key in node.keys()) {
                    findMetaPreview(node.opt(key), metaId)?.let { return it }
                }
            }
            is org.json.JSONArray -> {
                for (i in 0 until node.length()) {
                    findMetaPreview(node.opt(i), metaId)?.let { return it }
                }
            }
        }
        return null
    }

    override suspend fun installAddon(url: String): Result<Unit> = runCatching {
        val normalized = normalizeAddonUrl(url)
            ?: throw IllegalArgumentException("Enter a valid add-on URL (https://…/manifest.json).")
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

    /// Fetch a manifest.json body and validate it looks like an add-on manifest (`id` + `name` present,
    /// mirroring Apple `CoreBridge.installAddon`'s validation). Runs on [Dispatchers.IO]; fail-soft to
    /// null on any network/parse error so [installAddon] can surface one clear user-facing message.
    private suspend fun fetchAddonManifest(url: String): JSONObject? = withContext(Dispatchers.IO) {
        addonManifestFetcher.fetch(url)
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
        val permit = historyOwnerFence.captureRead()
            ?: throw IllegalStateException("History owner is changing. Try again.")
        // Ready = the meta actually parsed (first Ready Loadable in metaItems). The immediate
        // post-Load state is Loading, so a single-event await would leak a not-ready miss to the UI
        // (the "meta_details not ready" string the S03 device round saw rendered raw).
        val state = loadFieldUntil(EngineActions.FIELD_META_DETAILS, EngineActions.loadMeta(type.id, id)) {
            EngineState.parseMetaDetail(it) != null
        }
        // The applied add-on order rides the meta pick (#144 on Apple): the detail meta resolves from
        // the user's #1 add-on (e.g. a localized meta provider), not whichever the engine lists first.
        // An empty order (never reordered) keeps the old first-Ready pick byte-identically.
        val detail = EngineState.parseMetaDetail(state, addonPrefs.appliedOrder())
            ?: throw IllegalStateException("Couldn't load this title's details. Check your connection and try again.")
        // Per-profile gate: replace the account-derived saved/resume/ticks with the overlay's for an
        // overlay profile (no-op for engine-backed profiles).
        withOverlayState(detail, permit)
            ?: throw IllegalStateException("History owner changed while loading this title.")
    } }

    override suspend fun streams(
        type: MediaType,
        id: String,
        episodeId: String?,
        rememberedQuality: String?,
        wantedAddon: String?,
    ): Result<List<StreamGroup>> = runLatestStreamLoad { generation ->
        withContext(Dispatchers.Default) { runCatching {
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
        val state = if (episodeId != null && !wantedAddon.isNullOrBlank() && !rememberedQuality.isNullOrBlank()) {
            loadStreamsUntilWanted(action, episodeId, rememberedQuality, wantedAddon, generation)
        } else {
            loadStreamFieldUntil(generation, action, episodeId)
        }
        requireCurrentStreamLoad(generation)
        // Rank before the UI ever sees them: strongest source (debrid-cached > resolution > source ladder)
        // first within each add-on block, and the strongest add-on block first. This is what makes the
        // hero "Watch" auto-pick and the source picker meaningful, mirroring Apple's ranked source list.
        //
        // Build + install the user-preference snapshot FIRST (Apple's frozen snapshot: the ranker reads a
        // stable copy off-thread, never the live store). Installing it also lets DetailViewModel's later
        // media-server re-rank + best-source pick inherit the same preferences. The effective pin for this
        // title (per-title, else provider) rides the rank so a pinned source floats to the top.
        // isKids rides the snapshot so a Kids profile's content guard (hard-hide adult/junk; Avoid words
        // always DROP, never merely demote) is live in the frozen reading, mirroring Apple's
        // `ProfileStore.activeIsKids()` read inside `passesUserFilters`.
        val snapshot = sourcePrefs.snapshot(
            trackPrefs.current.audioLanguages,
            isKids = ProfileStore.sharedOrNull()?.activeIsKids == true,
        )
        StreamRanking.installReading(snapshot)
        val pin = sourcePins.effectivePin(SourcePinContext(id, type == MediaType.SERIES))
        // Per-profile add-on on/off overlay (Apple `assembleStreamGroups`' disabledAddons guard,
        // CoreBridge.swift:984): a disabled add-on's sources never reach ranking or the picker for
        // this profile. Groups with no base (a malformed request) are kept, never dropped.
        val disabledAddons = addonPrefs.disabledBases()
        val groups = EngineState.parseStreamGroups(state, episodeId).filter { group ->
            group.base.isEmpty() || AddonOrder.normalize(group.base) !in disabledAddons
        }
        // vortx-core SHADOW lane: with the flag ON, rank the SAME inputs through the own engine
        // kernel fire-and-forget and log the agreement (a diff count). It never touches the ranked
        // list returned below; with the flag at its default OFF this line is one volatile read.
        if (shadowRankingConfigured && VortxRankingShadow.enabled) VortxRankingShadow.compareAsync(groups, snapshot)
        StreamRanking.rankedGroups(groups, prefs = snapshot, pin = pin)
        } }
    }

    override suspend fun resolve(
        source: StreamSource,
        episode: Episode?,
    ): Result<Playable> = runCatching {
        // A stream id encodes its handle (see EngineState.parseStream: id = handle#name#desc, handle is
        // url/externalUrl/infoHash). Direct URLs are playable as-is. A raw torrent (handle = infoHash)
        // resolves through the user's own debrid account when a key is configured (native in-client
        // debrid, the Android port of the Apple DebridResolver); without a key it plays through the
        // OWN in-process streaming server ([VortxServer], the vortx-core rqbit embed), and only when
        // THAT is unavailable (no .so in this build, start failure, kill-switch flag off) does it
        // surface a clear error the player layer can show instead of failing opaquely.
        val handle = source.id.substringBefore('#')
        // Flag DV/Atmos from the source's own tags so [PlayerEngineRouter] routes those to the ExoPlayer
        // engine (its DefaultRenderersFactory does the DV codec fallback + DefaultAudioSink negotiates
        // Atmos passthrough); a text parse is the only pre-play signal, same as Apple.
        val isDolbyVision = StreamRanking.isDolbyVision(source)
        val isAtmos = StreamRanking.isAtmos(source)
        if (source.isUsenet) {
            val target = source.usenetResolveTarget(episode)
            val resolved = try {
                debridResolver.resolveUsenet(
                    nzbUrl = target.nzbUrl,
                    knownHash = target.knownHash,
                    fileMustInclude = target.fileMustInclude,
                    fileIdx = target.fileIdx,
                    episode = target.episode,
                )
            } catch (error: Throwable) {
                throw usenetPlaybackFailure(error)
            }
            Playable(
                url = resolved,
                title = source.title,
                viaStreamingServer = false,
                isTorrent = false,
                isDolbyVision = isDolbyVision,
                isAtmos = isAtmos,
            )
        } else if (!source.isTorrent && (handle.startsWith("http://") || handle.startsWith("https://"))) {
            // The stream's declared proxyHeaders ride onto the Playable so a header-gated CDN (a
            // Referer / User-Agent requirement) actually plays: both engines already apply
            // [Playable.headers] (mpv http-header-fields, ExoPlayer data-source factory), and the
            // download path forwards them off the same Playable. Direct-URL streams only: a
            // debrid-resolved link below is a DIFFERENT host the add-on's headers were never meant for.
            Playable(
                url = handle,
                title = source.title,
                viaStreamingServer = false,
                isDolbyVision = isDolbyVision,
                isAtmos = isAtmos,
                headers = source.requestHeaders,
            )
        } else if (source.isTorrent) {
            // Raw torrent: the handle IS the infoHash (see EngineState.parseStream: for a torrent
            // url == null, so the id-handle is the infoHash). If the user has a debrid key configured,
            // resolve it to a DIRECT, cached-instant HTTPS link through their own account (the Android
            // port of the Apple DebridResolver). The resolved URL is a plain direct stream, NOT a
            // torrent, so it plays without the streaming-server bridge (viaStreamingServer = false).
            //
            // Fail-soft: DebridResolver.resolve returns null on ANY failure (no key, not actually
            // cached, no playable file, provider/network error). With no key it never opens the key
            // store. On null the raw torrent falls through to the in-process streaming server below,
            // so a debrid-configured user keeps the exact direct path they have today.
            val target = source.debridResolveTarget(handle, episode)
            val resolved = debridResolver.resolve(
                infoHash = target.infoHash,
                episode = target.episode,
                fileIdx = target.fileIdx,
            )
            if (resolved != null) {
                Playable(url = resolved, title = source.title, viaStreamingServer = false, isTorrent = false, isDolbyVision = isDolbyVision, isAtmos = isAtmos)
            } else {
                // No debrid (or not cached): serve the raw torrent through the OWN in-process
                // streaming server, the same loopback contract the desktop node server speaks:
                // GET {base}/{infoHash}/{fileIdx} is the Range-capable playback endpoint and
                // auto-creates the torrent on first read (crates/streaming-server http routes).
                // startIfNeeded is idempotent and BLOCKS briefly on the first call (bind), so it
                // runs on IO, never the caller's dispatcher. Gated by the default-ON kill-switch
                // flag [VortxServer.FLAG_KEY]: serving beats throwing, but the lane can be killed
                // from Settings without a build. isTorrent = true keeps playback on the mpv
                // engine and sizes its read-ahead for a local stream ([PlayerEngineRouter]);
                // viaStreamingServer = true gives the player its "buffering from source" chrome.
                val serverBase = withContext(Dispatchers.IO) {
                    // Flag read + server start both on IO: resolve() may be entered from a
                    // viewModelScope (Main), and the first prefs-file load and the first
                    // nativeStart (bind) are real I/O.
                    if (VortxServer.streamingEnabled(appContext)) VortxServer.startIfNeeded(appContext) else null
                }
                if (serverBase != null) {
                    val infoHash = (source.infoHash ?: handle).lowercase()
                    val fileIdx = source.fileIdx ?: 0
                    Playable(
                        url = "$serverBase/$infoHash/$fileIdx",
                        title = source.title,
                        viaStreamingServer = true,
                        isTorrent = true,
                        isDolbyVision = isDolbyVision,
                        isAtmos = isAtmos,
                    )
                } else {
                    throw UnsupportedOperationException(
                        "Torrent playback needs a debrid key or the streaming server (unavailable in this build).",
                    )
                }
            }
        } else {
            throw UnsupportedOperationException(
                "This source type is not playable on Android yet.",
            )
        }
    }

    // ---- Live playback progress (engine Player) ----
    //
    // The Android port of Apple CoreBridge's loadEnginePlayer / reportProgress / unloadEnginePlayer
    // (app/SourcesShared/CoreBridge.swift). The engine's `player` model attributes every TimeChanged tick
    // to the library item keyed on the META (not the specific stream), so [beginPlaybackSession] scrapes
    // the RESIDENT meta_details for any Ready stream + this title's requests and Loads the Player with
    // them -- exactly Apple's fallback path. Every dispatch is fail-soft: a shape mismatch is a silent
    // no-op (the engine records no progress), never a crash. Continue Watching then updates off the
    // engine's own `continue_watching_preview` re-derivation, which [homeUpdates] already streams live.

    /// One immutable history owner, media context, and generation for the active playback. A callback
    /// can act only when its token still names that exact session; replacement makes every older callback
    /// a no-op, including an old end that must never unload the replacement player.
    private val playbackHistorySessions = PlaybackHistorySessions()

    override suspend fun beginPlaybackSession(): Result<PlaybackSessionToken> = withContext(Dispatchers.Default) { runCatching {
        playbackHistorySessions.replace(
            unloadPrevious = { previous ->
                if (previous.enginePlayerLoaded) StremioCoreNative.dispatch(EngineActions.unloadPlayer())
            },
        ) { token ->
            historyOwnerFence.mutate { owner ->
                val route = historyRouteLocked(owner)
                val selected = buildPlayerSelected()
                val detail = if (route is HistoryRoute.Overlay) currentMetaDetail() else null
                val type = selected?.optJSONObject("metaRequest")
                    ?.optJSONObject("path")
                    ?.optString("type")
                    ?.ifBlank { null }
                    ?: detail?.type?.id
                val videoId = selected?.optJSONObject("streamRequest")
                    ?.optJSONObject("path")
                    ?.optString("id")
                    ?.ifBlank { null }
                val overlayMetaId = if (route is HistoryRoute.Overlay) {
                    selected?.optJSONObject("metaRequest")
                        ?.optJSONObject("path")
                        ?.optString("id")
                        ?.ifBlank { null }
                        ?: detail?.id
                } else {
                    null
                }
                val enginePlayerLoaded = route is HistoryRoute.Engine && selected != null
                if (enginePlayerLoaded) StremioCoreNative.dispatch(EngineActions.loadPlayer(selected!!))
                PlaybackHistorySession(
                    token = token,
                    owner = owner,
                    enginePlayerLoaded = enginePlayerLoaded,
                    type = type,
                    videoId = videoId,
                    overlayMetaId = overlayMetaId,
                    name = detail?.name,
                    poster = detail?.poster,
                )
            }
        }
    } }

    override suspend fun reportProgress(
        session: PlaybackSessionToken,
        positionMs: Long,
        durationMs: Long,
    ): Result<Unit> = withContext(Dispatchers.Default) { runCatching {
        if (durationMs <= 0L || positionMs < 0L) return@runCatching
        playbackHistorySessions.withCurrent(session) { active ->
            historyOwnerFence.mutate(expectedOwner = active.owner) { owner ->
                when (val route = historyRouteLocked(owner)) {
                    is HistoryRoute.Overlay -> {
                        val metaId = active.overlayMetaId
                        if (metaId != null) {
                            route.profiles.withActiveOverlayProfile(route.profileId) { overlay ->
                                overlay.recordProgress(
                                    metaId = metaId,
                                    videoId = active.videoId ?: metaId,
                                    positionSeconds = positionMs / 1000.0,
                                    durationSeconds = durationMs / 1000.0,
                                    name = active.name ?: "",
                                    type = active.type ?: MediaType.MOVIE.id,
                                    poster = active.poster,
                                )
                            }
                        }
                    }
                    HistoryRoute.Engine -> if (active.enginePlayerLoaded) {
                        StremioCoreNative.dispatch(
                            EngineActions.playerTimeChanged(positionMs, durationMs, PROGRESS_DEVICE),
                        )
                    }
                }
            }
        }
        Unit
    } }

    override suspend fun endPlaybackSession(
        session: PlaybackSessionToken,
        positionMs: Long,
        durationMs: Long,
    ): Result<Unit> = withContext(Dispatchers.Default) { runCatching {
        playbackHistorySessions.finish(session) { active ->
            try {
                historyOwnerFence.mutate(expectedOwner = active.owner) { owner ->
                    when (val route = historyRouteLocked(owner)) {
                        is HistoryRoute.Overlay -> {
                            val metaId = active.overlayMetaId
                            if (metaId != null && durationMs > 0L && positionMs >= 0L) {
                                val videoId = active.videoId ?: metaId
                                val type = active.type ?: MediaType.MOVIE.id
                                route.profiles.withActiveOverlayProfile(route.profileId) { overlay ->
                                    overlay.recordProgress(
                                        metaId = metaId,
                                        videoId = videoId,
                                        positionSeconds = positionMs / 1000.0,
                                        durationSeconds = durationMs / 1000.0,
                                        name = active.name ?: "",
                                        type = type,
                                        poster = active.poster,
                                    )
                                    if (positionMs.toDouble() / durationMs.toDouble() >= WATCHED_THRESHOLD) {
                                        overlay.markWatched(
                                            metaId,
                                            videoId,
                                            active.name ?: "",
                                            type,
                                            active.poster,
                                        )
                                        if (type != MediaType.SERIES.id) overlay.finishedWatching(metaId)
                                    }
                                }
                            }
                        }
                        HistoryRoute.Engine -> if (
                            active.enginePlayerLoaded && durationMs > 0L && positionMs >= 0L
                        ) {
                            StremioCoreNative.dispatch(
                                EngineActions.playerTimeChanged(positionMs, durationMs, PROGRESS_DEVICE),
                            )
                            if (positionMs.toDouble() / durationMs.toDouble() >= WATCHED_THRESHOLD) {
                                val type = active.type
                                val videoId = active.videoId
                                if (type == MediaType.SERIES.id && !videoId.isNullOrEmpty()) {
                                    val (season, episode) = seasonEpisodeFromVideoId(videoId)
                                    StremioCoreNative.dispatch(
                                        EngineActions.markVideoAsWatched(videoId, season, episode, true),
                                    )
                                } else if (type != null && type != MediaType.SERIES.id) {
                                    StremioCoreNative.dispatch(EngineActions.markAsWatched(true))
                                }
                            }
                        }
                    }
                }
            } finally {
                if (active.enginePlayerLoaded) StremioCoreNative.dispatch(EngineActions.unloadPlayer())
            }
        }
        Unit
    } }

    /// Best-effort season/episode from a stremio series video id (`<metaId>:<season>:<episode>`): the
    /// trailing two colon-separated integers, or null when the id doesn't follow that shape. The engine's
    /// MarkVideoAsWatched keys on the video id itself and treats season/episode as optional extras (see
    /// [EngineActions.markVideoAsWatched]), so a null pair still marks the correct episode.
    private fun seasonEpisodeFromVideoId(videoId: String): Pair<Int?, Int?> {
        val parts = videoId.split(':')
        if (parts.size < 3) return null to null
        return parts[parts.size - 2].toIntOrNull() to parts.last().toIntOrNull()
    }

    /// Build the engine Player `selected` struct from the resident `meta_details`: any Ready stream + its
    /// group's request + the title's meta request, mirroring Apple `loadEnginePlayer`'s fallback (the
    /// library item keys on the meta, so any Ready stream attributes correctly). Null when nothing Ready
    /// is resident (no title open, or streams not answered yet), in which case the Player Load is skipped.
    private fun buildPlayerSelected(): JSONObject? {
        val root = runCatching { JSONObject(StremioCoreNative.getState(EngineActions.metaDetailsField())) }.getOrNull() ?: return null
        val metaItems = root.optJSONArray("metaItems") ?: return null
        var metaRequest: JSONObject? = null
        for (i in 0 until metaItems.length()) {
            val item = metaItems.optJSONObject(i) ?: continue
            val request = item.optJSONObject("request") ?: continue
            if (item.optJSONObject("content")?.optString("type") == "Ready") { metaRequest = request; break }
            if (metaRequest == null) metaRequest = request
        }
        val meta = metaRequest ?: return null

        val streamGroups = root.optJSONArray("streams") ?: return null
        for (g in 0 until streamGroups.length()) {
            val group = streamGroups.optJSONObject(g) ?: continue
            val content = group.optJSONObject("content") ?: continue
            if (content.optString("type") != "Ready") continue
            val rawStream = content.optJSONArray("content")?.optJSONObject(0) ?: continue
            val streamRequest = group.optJSONObject("request") ?: continue
            return JSONObject()
                .put("stream", rawStream)
                .put("streamRequest", streamRequest)
                .put("metaRequest", meta)
                .put("subtitlesPath", JSONObject.NULL)
        }
        return null
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
        EngineState.parseMetaDetail(StremioCoreNative.getState(EngineActions.metaDetailsField()), addonPrefs.appliedOrder())

    override suspend fun setWatched(type: MediaType, id: String, isWatched: Boolean): Result<MetaDetail> = withContext(Dispatchers.Default) { runCatching {
        historyOwnerFence.mutate { owner ->
            val detail = currentMetaDetail() ?: throw IllegalStateException("Couldn't update watched state.")
            when (val route = historyRouteLocked(owner)) {
                is HistoryRoute.Overlay -> route.profiles.withActiveOverlayProfile(route.profileId) { overlay ->
                    overlay.setWatched(isWatched, id, listOf(id), detail.name, type.id, detail.poster)
                }
                HistoryRoute.Engine -> StremioCoreNative.dispatch(EngineActions.markAsWatched(isWatched))
            }
            currentMetaDetail()?.let { withOverlayState(it, HistoryReadPermit(owner)) }
                ?: throw IllegalStateException("Couldn't update watched state.")
        }
    } }

    override suspend fun setVideoWatched(
        type: MediaType,
        id: String,
        videoId: String,
        season: Int?,
        episode: Int?,
        isWatched: Boolean,
    ): Result<MetaDetail> = withContext(Dispatchers.Default) { runCatching {
        historyOwnerFence.mutate { owner ->
            val detail = currentMetaDetail() ?: throw IllegalStateException("Couldn't update watched state.")
            when (val route = historyRouteLocked(owner)) {
                is HistoryRoute.Overlay -> route.profiles.withActiveOverlayProfile(route.profileId) { overlay ->
                    overlay.setWatched(
                        isWatched,
                        id,
                        listOf(videoId),
                        detail.name,
                        type.id,
                        detail.poster,
                    )
                }
                HistoryRoute.Engine -> StremioCoreNative.dispatch(
                    EngineActions.markVideoAsWatched(videoId, season, episode, isWatched),
                )
            }
            currentMetaDetail()?.let { withOverlayState(it, HistoryReadPermit(owner)) }
                ?: throw IllegalStateException("Couldn't update watched state.")
        }
    } }

    override suspend fun setSeasonWatched(type: MediaType, id: String, season: Int, isWatched: Boolean): Result<MetaDetail> =
        withContext(Dispatchers.Default) { runCatching {
            historyOwnerFence.mutate { owner ->
                val detail = currentMetaDetail() ?: throw IllegalStateException("Couldn't update watched state.")
                when (val route = historyRouteLocked(owner)) {
                    is HistoryRoute.Overlay -> route.profiles.withActiveOverlayProfile(route.profileId) { overlay ->
                        val ids = detail.videos.filter { it.season == season }.map { it.id }
                        overlay.setWatched(isWatched, id, ids, detail.name, type.id, detail.poster)
                    }
                    HistoryRoute.Engine -> StremioCoreNative.dispatch(
                        EngineActions.markSeasonAsWatched(season, isWatched),
                    )
                }
                currentMetaDetail()?.let { withOverlayState(it, HistoryReadPermit(owner)) }
                    ?: throw IllegalStateException("Couldn't update watched state.")
            }
        } }

    override suspend fun addToLibrary(type: MediaType, id: String, name: String, poster: String?): Result<MetaDetail> =
        withContext(Dispatchers.Default) { runCatching {
            historyOwnerFence.mutate { owner ->
                when (val route = historyRouteLocked(owner)) {
                    is HistoryRoute.Overlay -> route.profiles.withActiveOverlayProfile(route.profileId) { overlay ->
                        overlay.addLibraryEntry(metaId = id, name = name, type = type.id, poster = poster)
                    }
                    HistoryRoute.Engine -> StremioCoreNative.dispatch(
                        EngineActions.addToLibrary(id, type.id, name, poster),
                    )
                }
                currentMetaDetail()?.let { withOverlayState(it, HistoryReadPermit(owner)) }
                    ?: throw IllegalStateException("Couldn't add this title to your library.")
            }
        } }

    override suspend fun removeFromLibrary(type: MediaType, id: String): Result<MetaDetail> = withContext(Dispatchers.Default) { runCatching {
        historyOwnerFence.mutate { owner ->
            when (val route = historyRouteLocked(owner)) {
                is HistoryRoute.Overlay -> route.profiles.withActiveOverlayProfile(route.profileId) { overlay ->
                    overlay.removeWatchEntry(id)
                }
                HistoryRoute.Engine -> StremioCoreNative.dispatch(EngineActions.removeFromLibrary(id))
            }
            currentMetaDetail()?.let { withOverlayState(it, HistoryReadPermit(owner)) }
                ?: throw IllegalStateException("Couldn't remove this title from your library.")
        }
    } }

    /// A pure local re-read (see [CatalogRepository.peekMeta]): no dispatch at all, just the same
    /// synchronous `meta_details` snapshot [currentMetaDetail] already uses after every S05 mutation --
    /// safe to call on every [ctxUpdates] tick without re-triggering the add-on stream fan-out. Null if
    /// nothing is currently loaded for [id] (a different title's meta_details, or none yet).
    // withContext(Dispatchers.Default): called on every ctxUpdates tick, so its getState + parse
    // (via currentMetaDetail) must stay off the collector's (Main) context.
    override suspend fun peekMeta(type: MediaType, id: String): MetaDetail? = withContext(Dispatchers.Default) {
        val permit = historyOwnerFence.captureRead() ?: return@withContext null
        currentMetaDetail()?.takeIf { it.id == id }?.let { withOverlayState(it, permit) }
    }

    // ---- AuthRepository ----

    override suspend fun signIn(email: String, password: String): Result<Unit> {
        if (email.isBlank() || password.isBlank()) {
            return Result.failure(IllegalArgumentException("Enter your email and password."))
        }
        val authAttempt = runCatching { authTransition.begin() }
            .getOrElse { return Result.failure(it) }
        val authRequestId = EngineState.authRequestId(email, password)
        val authLease = authAttemptCoordinator.begin(authRequestId)
        if (authLease == null) {
            authTransition.finish(authAttempt)
            return Result.failure(
                IllegalStateException(
                    "This exact sign-in is still settling. Wait for its native result before retrying.",
                ),
            )
        }
        val privacyAttempt = synchronized(homeEventOrder) {
            homePrivacyFence.beginSignIn(
                requestId = authRequestId,
                nextPreviewEventSequence = homeEventSequence + 1,
            )
        }
        homePrivacyClears.tryEmit(homePrivacyFence.capture())
        var dispatched = false
        val result = try {
            runCatchingPreservingCancellation {
                val attemptOutcome = withTimeoutOrNull(loadTimeoutSeconds.seconds) {
                    StremioCoreNative.dispatch(EngineActions.authenticateLogin(email, password))
                    dispatched = true
                    authLease.outcome.await()
                } ?: throw IllegalStateException("Sign-in timed out. Check your connection and try again.")
                if (attemptOutcome is AuthAttemptOutcome.Failed) {
                    throw IllegalStateException(attemptOutcome.message)
                }
                withContext(Dispatchers.Default) { refreshAuthState() }
                val signedIn = _authState.value as? AuthState.SignedIn
                    ?: throw IllegalStateException("Sign-in failed. Check your connection and try again.")
                if (!engineHistoryPrincipalMatches(ProfileStore.sharedOrNull()?.active, signedIn)) {
                    throw IllegalStateException(
                        "The signed-in account does not match this profile's own-account identity.",
                    )
                }
                val uid = signedIn.uid?.takeIf { it.isNotBlank() }
                    ?: throw IllegalStateException("Sign-in completed without an account identifier. Try again.")
                val accountUidVerified = withContext(Dispatchers.Default) {
                    withTimeoutOrNull(loadTimeoutSeconds.seconds) {
                        while (!WatchedIndex.storageMatchesUid(appContext.filesDir, uid)) {
                            delay(AUTH_STORAGE_POLL_MS)
                        }
                        true
                    } ?: false
                }
                if (!accountUidVerified) {
                    throw IllegalStateException("Sign-in completed, but account data did not finish loading. Try again.")
                }
                check(homePrivacyFence.completeSignIn(privacyAttempt, uid)) {
                    "The active profile or account changed while sign-in was finishing."
                }
                Unit
            }
        } finally {
            if (!authLease.outcome.isCompleted) {
                if (dispatched) {
                    authAttemptCoordinator.abandon(authLease)
                } else {
                    authAttemptCoordinator.releaseBeforeDispatch(authLease)
                }
            }
            authTransition.finish(authAttempt)
        }
        if (result.isSuccess) changedFields.tryEmit(HOME_FIELDS)
        return result
    }

    override suspend fun signOut() {
        ContinueWatchingOwnerGate.serialized {
            // Broadcast dispatch (field = null): mirrors Apple's plain Logout, an explicit user sign-out.
            // The dispatch, published state, suppression flag, and revision are one owner transition, so a
            // Continue Watching mutation cannot enter between them.
            authTransition.cancelActive()
            authAttemptCoordinator.abandonActive()
            val clear = synchronized(homeEventOrder) {
                var permit: HomePrivacyPermit? = null
                homePrivacyFence.beforeLogout(
                    nextPreviewEventSequence = homeEventSequence + 1,
                ) {
                    permit = homePrivacyFence.capture()
                }
                requireNotNull(permit)
            }
            homePrivacyClears.tryEmit(clear)
            runCatching { StremioCoreNative.dispatch(EngineActions.logout()) }
            _authState.value = AuthState.SignedOut
            identityStore.forget()
            ContinueWatchingOwnerGate.advance()
            runCatching { dispatchHomeLoad() }
        }
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
            EngineActions.FIELD_LIBRARY,
            EngineActions.FIELD_CONTINUE_WATCHING_PREVIEW,
        )

        /// The NewState fields [ctxUpdates] treats as "something Library/Detail/Discover/Add-ons should
        /// re-read" -- see [ctxUpdates]'s doc comment.
        val CTX_UPDATE_FIELDS = setOf(EngineActions.FIELD_CTX, EngineActions.FIELD_LIBRARY)

        /// Safety-net poll cadence for [homeUpdates]. Each tick is a cheap local getState + parse;
        /// distinctUntilChanged means an unchanged snapshot never reaches the UI.
        const val HOME_POLL_MS = 3_000L

        /** Resident meta-details poll interval while a remembered series provider is outstanding. */
        const val STREAM_SETTLEMENT_POLL_MS = 250L

        fun monotonicMs(): Long = System.nanoTime() / 1_000_000L
        const val AUTH_STORAGE_POLL_MS = 25L

        /// The `device` tag stamped into every engine `TimeChanged` (Apple sends "iOS"/"tvOS").
        const val PROGRESS_DEVICE = "Android"

        /// Fraction of the runtime past which a title is treated as finished (marked watched, dropped from
        /// Continue Watching) when the player closes. Matches the common 90% convention.
        const val WATCHED_THRESHOLD = 0.9
    }
}
