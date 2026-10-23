package com.vortx.android.engine

// Repository support shared by the VortX engine repository: stream-load gating, playback and Home
// privacy fences, and resolve targets.

import android.content.Context
import android.util.Log
import com.vortx.android.BuildConfig
import com.vortx.android.VortXApplication
import com.vortx.android.auth.AuthIdentityStore
import com.vortx.android.data.AddonPrefsStore
import com.vortx.android.data.AddonTombstones
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.ContinueWatchingDismissal
import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.data.ContinueWatchingSnapshot
import com.vortx.android.data.DurableWatchedPlaybackReceipt
import com.vortx.android.data.HomeSnapshot
import com.vortx.android.data.HomeUpdate
import com.vortx.android.data.PlaybackSessionToken
import com.vortx.android.data.StreamLoadUpdate
import com.vortx.android.model.AddonOrder
import com.vortx.android.debrid.DebridCoordinator
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.debrid.DebridResolver
import com.vortx.android.usenet.UsenetProviderStore
import com.vortx.android.model.AuthState
import com.vortx.android.model.Catalog
import com.vortx.android.model.CoreLocalSearchState
import com.vortx.android.model.CoreSearchSuggestion
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
import com.vortx.android.model.PlaybackContext
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.model.TrackPreferencesStore
import com.vortx.android.nzb.NzbIndexerStore
import com.vortx.android.nzb.NzbSearch
import com.vortx.android.library.WatchedIndex
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.ContinueWatchingOwnerGate
import com.vortx.android.profile.UserProfile
import com.vortx.android.sources.SourcePinContext
import com.vortx.android.sources.SourcePinStore
import com.vortx.android.sources.SourcePreferencesStore
import com.vortx.android.sync.AccountLibrarySync
import com.vortx.android.sync.AccountLibrarySyncGateway
import com.vortx.android.sync.AccountLibraryRestoreResult
import com.vortx.android.sync.NativeLibraryOwner
import com.vortx.android.sync.OwnerLibraryPublicationLease
import com.vortx.android.sync.LocalLibraryPublicationPolicy
import com.vortx.android.sync.AddonPublicationProofs
import com.vortx.android.sync.OwnerWatchedIntentStore
import com.vortx.android.sync.OwnerLibraryOperation
import com.vortx.android.sync.OwnerLibraryHistoryPolicy
import com.vortx.android.sync.OwnerLibraryPendingTransitions
import com.vortx.android.sync.AccountAddonSyncGateway
import com.vortx.android.sync.AccountAddonGatewayLease
import com.vortx.android.sync.LibraryTombstones
import com.vortx.android.sync.VortXSyncDoc
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.last
import kotlinx.coroutines.flow.shareIn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import org.json.JSONArray
import java.net.URI
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import kotlin.time.Duration.Companion.seconds

internal data class DebridResolveTarget(
    val infoHash: String,
    val episode: DebridResolver.Episode?,
    val fileIdx: Int?,
)

internal class StreamLoadDispatchGate {
    private val lock = Any()
    private var generation = 0L

    fun begin(): Long = synchronized(lock) {
        generation += 1L
        generation
    }

    fun isCurrent(candidate: Long): Boolean = synchronized(lock) { candidate == generation }

    /** Runs a native action sequence with one uninterrupted generation owner. */
    fun dispatchCurrent(generation: Long, actions: List<String>, dispatch: (String) -> Unit) = synchronized(lock) {
        if (this.generation != generation) throw CancellationException("Superseded by a newer stream target")
        actions.forEach(dispatch)
        if (this.generation != generation) throw CancellationException("Superseded by a newer stream target")
    }
}

/** Supersession is control flow, not a failed stream result. */
internal suspend fun <T> runCatchingStreamLoad(block: suspend () -> T): Result<T> = try {
    Result.success(block())
} catch (cancelled: CancellationException) {
    throw cancelled
} catch (error: Throwable) {
    Result.failure(error)
}

/**
 * Subscribe to field ticks before dispatch, then serialize every state pull through one reader. A conflated
 * tick is sufficient because engine state is cumulative; a missed intermediate notification is recovered by
 * the next pull. The final read on timeout preserves the freshest bounded best-effort snapshot.
 */
internal fun streamLoadStateUpdates(
    changes: Flow<Unit>,
    dispatch: () -> Unit,
    readState: () -> String,
    snapshot: (String) -> StreamLoadUpdate,
    isCurrent: () -> Boolean,
    timeoutMs: Long,
): Flow<StreamLoadUpdate> = channelFlow {
    fun requireCurrent() {
        if (!isCurrent()) throw CancellationException("Superseded by a newer stream target")
    }

    val ticks = Channel<Unit>(Channel.CONFLATED)
    val subscription = launch(start = CoroutineStart.UNDISPATCHED) {
        changes.collect { ticks.trySend(Unit) }
    }
    var last: StreamLoadUpdate? = null
    suspend fun publishCurrent(): Boolean {
        requireCurrent()
        val current = snapshot(readState())
        requireCurrent()
        if (current != last) {
            send(current)
            last = current
        }
        return current.terminal
    }

    try {
        requireCurrent()
        dispatch()
        val terminal = withTimeoutOrNull(timeoutMs) {
            if (publishCurrent()) return@withTimeoutOrNull true
            while (true) {
                ticks.receive()
                if (publishCurrent()) return@withTimeoutOrNull true
            }
            @Suppress("UNREACHABLE_CODE")
            false
        } ?: false
        if (!terminal) {
            requireCurrent()
            val timedOut = snapshot(readState()).copy(terminal = true, timedOut = true, selectionReady = true)
            requireCurrent()
            if (timedOut != last) send(timedOut)
        }
    } finally {
        subscription.cancel()
        ticks.close()
    }
}

/** Keeps the source list reactive while preserving a bounded provider/quality hold for auto-next. */
internal fun streamSelectionReady(
    groups: List<StreamGroup>,
    loaded: Int,
    total: Int,
    terminal: Boolean,
    episodeId: String?,
    rememberedQuality: String?,
    wantedAddon: String?,
    firstPlayableAtMs: Long?,
    nowMs: Long,
): Boolean {
    if (episodeId == null || rememberedQuality.isNullOrBlank() || wantedAddon.isNullOrBlank()) {
        return groups.isNotEmpty() || terminal
    }
    val firstPlayableAt = firstPlayableAtMs ?: return terminal
    return StreamRanking.resolveSettled(
        groups = groups,
        loaded = loaded,
        total = total,
        secondsSinceFirstPlayable = (nowMs - firstPlayableAt) / 1_000.0,
        rememberedQuality = rememberedQuality,
        wantedAddon = wantedAddon,
    ) || terminal
}

/**
 * Applies the persisted Add-ons-screen priority to raw source groups before the optional "Use add-on
 * order" ranking mode preserves that order. Groups absent from the saved order remain in engine order.
 */
internal fun orderStreamGroupsByAppliedAddonOrder(
    groups: List<StreamGroup>,
    appliedAddonOrder: List<String>,
): List<StreamGroup> {
    if (groups.size < 2 || appliedAddonOrder.isEmpty()) return groups
    val rank = HashMap<String, Int>(appliedAddonOrder.size)
    appliedAddonOrder.forEachIndexed { index, base -> rank[AddonOrder.normalize(base)] = index }
    return groups.withIndex()
        .sortedWith(compareBy<IndexedValue<StreamGroup>> { rank[AddonOrder.normalize(it.value.base)] ?: Int.MAX_VALUE }
            .thenBy { it.index })
        .map { it.value }
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
    val nzbUrls: List<String> = listOf(nzbUrl),
    val servers: List<String> = emptyList(),
) {
    override fun toString(): String = "UsenetResolveTarget(<transient transport>)"
}

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
    nzbUrl = requireNotNull(usenetUrls.firstOrNull()) { "Usenet source is missing its NZB URL." },
    nzbUrls = com.vortx.android.usenet.NativeNzbInputs.mirrors(nzbUrl, nzbUrls),
    servers = com.vortx.android.usenet.NativeNzbInputs.servers(usenetServers),
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

/** Uses a structured direct URL when an add-on supplied one, then retains the legacy id handle fallback. */
internal fun StreamSource.directPlaybackUrl(fallbackHandle: String): String? =
    url?.takeIf(::isHttpPlaybackUrl) ?: fallbackHandle.takeIf(::isHttpPlaybackUrl)

private fun isHttpPlaybackUrl(value: String): Boolean =
    runCatching { URI(value.trim()) }.getOrNull()?.let { uri ->
        (uri.scheme.equals("http", true) || uri.scheme.equals("https", true)) && !uri.host.isNullOrBlank()
    } == true

internal fun usenetPlaybackFailure(error: Throwable): Throwable = when (error) {
    DebridResolver.DebridException.NoKey ->
        UnsupportedOperationException("Usenet playback needs a TorBox debrid key or configured native NNTP provider.", error)
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

/** A native detail mutation is safe only when its resident model is the title the UI requested. */
internal fun matchesDetailMutationTarget(detail: MetaDetail?, type: MediaType, id: String): Boolean =
    detail?.type == type && detail.id == id

/** Detail screens additionally need local watched/video state broadcasts, not only ctx/library changes. */
internal fun isDetailStateUpdate(fields: Set<String>): Boolean =
    fields.any {
        it == EngineActions.FIELD_CTX ||
            it == EngineActions.FIELD_LIBRARY ||
            it == EngineActions.FIELD_META_DETAILS
    }

/** The exact, deterministic episode action order for a whole-series watched toggle. */
internal fun wholeSeriesWatchedVideos(detail: MetaDetail): List<Episode> =
    detail.videos.sortedWith(compareBy({ it.season }, { it.episode }, { it.id }))

/**
 * The native engine exposes exactly one mutable MetaDetails model. Every Load, Re-find, stream-detail
 * request and id-less detail mutation must use this cancellable gate so a different title cannot replace
 * the resident model between mutation validation and dispatch.
 */
internal class MetaDetailsTransactionGate {
    private val mutex = Mutex()

    suspend fun <T> exclusive(block: suspend () -> T): T = mutex.withLock { block() }
}

/// Synthetic, clearly-local request base for locally-bound playback sessions. The engine's
/// `ResourceRequest` requires a well-formed absolute base URL even though a local play never fetches
/// through it; `vortx.local` parses as a Url while never colliding with a real add-on origin.
internal const val LOCAL_PLAYBACK_REQUEST_BASE = "https://vortx.local/"

/// Synthesize the engine Player `selected` struct PURELY from a LOCAL session's immutable
/// [PlaybackContext] -- no resident state is read. This is the Android port of Apple's identity
/// binding for plays that skip the detail page (offline downloads / direct resumes): the engine keys
/// TimeChanged attribution on `stream_request.path.id`, resolves the Player's own library item from
/// `ctx.library` by `meta_request.path.id`, and runs its watched threshold + Continue Watching push
/// against that item, so a context-derived selected attributes every write to THIS title even when
/// the resident detail page still describes an earlier one. The stream carries only a source-bearing
/// marker URL (the engine parses the `Selected` struct but never opens it; actual media lives outside
/// the engine), and both paths carry the required `extra: []`. Pure and deterministic: identical
/// contexts produce byte-identical payloads on phone and TV.
internal fun buildLocalPlayerSelected(context: PlaybackContext): JSONObject {
    fun resourcePath(resource: String, id: String): JSONObject =
        JSONObject()
            .put("resource", resource)
            .put("type", context.type)
            .put("id", id)
            .put("extra", JSONArray())
    val streamUrl = LOCAL_PLAYBACK_REQUEST_BASE + "offline/" +
        URLEncoder.encode(context.identityKey, StandardCharsets.UTF_8)
    return JSONObject()
        .put("stream", JSONObject().put("url", streamUrl))
        .put(
            "streamRequest",
            JSONObject()
                .put("base", LOCAL_PLAYBACK_REQUEST_BASE)
                .put("path", resourcePath("stream", context.videoId)),
        )
        .put(
            "metaRequest",
            JSONObject()
                .put("base", LOCAL_PLAYBACK_REQUEST_BASE)
                .put("path", resourcePath("meta", context.contentId)),
        )
        .put("subtitlesPath", JSONObject.NULL)
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
    /** Retained verbatim for a local-play durable receipt; never rebuilt from ambient engine state. */
    val playbackContext: PlaybackContext? = null,
    /// True when the identity was bound EXPLICITLY from an immutable local [PlaybackContext] at
    /// begin time. Such a session never scrapes resident metadata, and its end must skip the
    /// resident-keyed MarkVideoAsWatched / MarkAsWatched belt-and-suspenders: after a stream-A then
    /// offline-B play the resident detail page can still describe A, and the loaded Player already
    /// marks the bound identity watched through its own threshold path (stremio-core `Player` sets
    /// `flagged_watched` + `send_watched` keyed on its OWN loaded requests).
    val localIdentityBound: Boolean = false,
    val libraryMetaId: String? = null,
    val publication: OwnerLibraryPublicationLease? = null,
)

/** Holds exactly one playback session and rejects every callback carrying a replaced generation. */
internal class PlaybackHistorySessions {
    private val lock = Any()
    private var generation = 0L
    private var current: PlaybackHistorySession? = null
    private var lastPublication: OwnerLibraryPublicationLease? = null

    fun replace(
        unloadPrevious: (PlaybackHistorySession) -> Unit,
        create: (PlaybackSessionToken) -> PlaybackHistorySession,
    ): PlaybackSessionToken = synchronized(lock) {
        lastPublication?.invalidate()
        current?.let(unloadPrevious)
        current = null
        check(generation < Long.MAX_VALUE) { "Playback session generation exhausted." }
        generation += 1L
        val token = PlaybackSessionToken(generation)
        val replacement = create(token)
        check(replacement.token == token) { "Playback session token mismatch." }
        current = replacement
        lastPublication = replacement.publication
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

internal class HomePrincipalBindingProof internal constructor(
    internal val attempt: HomeSignInAttempt,
    internal val uid: String,
    internal val previewVerified: Boolean,
    internal val minimumEventSequence: Long,
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
    private var principalBindingPreview: Pair<HomePrincipalBindingProof, HomeSignInAttempt>? = null

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
        principalBindingPreview = null
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
        principalBindingPreview = null
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
        principalBindingPreview = null
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
        principalBindingPreview = null
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

    /** Retain actual preview provenance while adding a verified email to this same account slot. */
    @Synchronized
    fun capturePrincipalBinding(attempt: HomeSignInAttempt, uid: String): HomePrincipalBindingProof {
        check(pendingSignIn == attempt && profile == attempt.profile && uid.isNotBlank())
        return HomePrincipalBindingProof(attempt, uid, previewObservation == PreviewObservation(
            attempt.privacyGeneration, attempt.profile, uid), minimumPreviewEventSequence)
    }

    @Synchronized
    fun resumeAfterPrincipalBinding(proof: HomePrincipalBindingProof, nextPreviewEventSequence: Long): HomeSignInAttempt {
        check(proof.attempt.profile.expectedPrincipal == null &&
            proof.attempt.profile.copy(expectedPrincipal = profile.expectedPrincipal) == profile &&
            generation == proof.attempt.privacyGeneration + (if (profile == proof.attempt.profile) 0L else 1L)) {
            "The profile account changed while its identity was being saved."
        }
        val next = beginSignIn(proof.attempt.requestId, nextPreviewEventSequence)
        principalBindingPreview = proof to next
        if (proof.previewVerified) previewObservation = PreviewObservation(next.privacyGeneration, next.profile, proof.uid)
        return next
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
        // A verifier already running for this exact successful login may finish after the email bind.
        // Preserve only that witnessed ticket; any unrelated account/profile transition clears it.
        val rebound = principalBindingPreview?.takeIf { (proof, next) ->
            proof.uid == accountUid && proof.attempt.privacyGeneration == ticket.privacy.generation &&
                proof.attempt.profile == ticket.privacy.profile && ticket.eventSequence >= proof.minimumEventSequence &&
                next.profile == profile && (pendingSignIn == next || activeAccountGeneration == next.privacyGeneration)
        }?.second
        if (rebound == null && ticket.eventSequence < minimumPreviewEventSequence) return false
        val eventProfile = rebound?.profile ?: ticket.privacy.profile
        if (eventProfile != profile) return false
        val eventGeneration = rebound?.privacyGeneration ?: ticket.privacy.generation
        val pending = pendingSignIn
        if (
            pending != null &&
            pending.privacyGeneration == eventGeneration &&
            pending.profile == eventProfile
        ) {
            previewObservation = PreviewObservation(eventGeneration, eventProfile, accountUid)
            return false
        }
        if (
            activeAccountUid == accountUid &&
            (activeAccountGeneration == eventGeneration || generation == eventGeneration) &&
            suppressContinueWatchingPreview
        ) {
            suppressContinueWatchingPreview = false
            principalBindingPreview = null
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
