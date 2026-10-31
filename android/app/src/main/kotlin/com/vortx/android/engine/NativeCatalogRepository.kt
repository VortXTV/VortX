package com.vortx.android.engine

import com.vortx.android.diagnostics.DiagnosticsLog
import com.vortx.android.data.*
import com.vortx.android.model.*
import com.vortx.android.xperience.XperienceAddonBinding
import java.net.URI
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.withContext
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import org.json.JSONArray
import org.json.JSONObject

/** Exact ProfilePlayback projection, including a clocked rewind at zero; never synthesizes an episode. */
internal fun nativeContinueWatchingItem(item: JSONObject, saved: List<MetaItem>): MetaItem {
    val id = item.getString("metaId")
    val matches = saved.filter { it.id == id }
    check(matches.size <= 1) { "Ambiguous native watch media identity" }
    val type = item.optStringOrNull("type")?.let(MediaType::fromId) ?: matches.singleOrNull()?.type
        ?: if (item.optStringOrNull("videoId")?.let { it != id } == true) MediaType.SERIES else MediaType.MOVIE
    val offset = item.getLong("offsetMs"); val duration = item.getLong("durationMs")
    return MetaItem(id, type, item.getString("name"), poster = item.optStringOrNull("poster") ?: matches.singleOrNull()?.poster,
        progress = if (duration > 0) (offset.toFloat() / duration).coerceIn(0f, 1f) else 0f, resumeSeconds = offset / 1000.0,
        preferredEpisode = continueWatchingEpisodeFromVideoIdentity(type, item.optStringOrNull("videoId"))
            // A finished latest episode keeps its series here with no offset, flagged watched: up next.
            ?.let { if (item.optBoolean("watched") && offset == 0L) it.copy(upNext = true) else it },
        continueWatchingActivityAtMillis = item.optLong("updatedAt", 0).takeIf { it > 0 })
}

/** Immutable installed projection bound to one original owner/bucket. Neither candidates nor
 * rejected identities grant fetch/write authority. The private pairings keep the exact original
 * configured addon with its Candidate object; filtering never creates an index-based fallback. */
internal class XperienceInstalledCatalogSnapshot private constructor(
    val owner: VortxNativeOwner,
    val installedAddonProfileID: String,
    pairings: List<Pair<XperienceAddonBinding.Candidate, VortxResourceAddon>>,
    rejectedIDs: Set<String>,
    rejectedConfiguredIdentities: Map<String, Set<String>>,
) {
    private val pairings = pairings.toList()
    val candidates: List<XperienceAddonBinding.Candidate> = java.util.Collections.unmodifiableList(this.pairings.map { it.first })
    // Strings have already passed scalar admission. Java String equality is exact UTF16;
    // no NFC/casefold/name/URL normalization is used to identify a rejected manifest.
    private val rejectedIDs = rejectedIDs.toSet()
    private val rejectedConfiguredIdentities = rejectedConfiguredIdentities.mapValues { it.value.toSet() }

    fun resolve(source: com.vortx.android.xperience.XperienceCollections.Source,
                mapping: XperienceAddonBinding.Mapping? = null): XperienceAddonBinding.Resolution {
        val result = XperienceAddonBinding.resolve(source, candidates, mapping)
        if (mapping == null && source.isAddon && (source.addonId?.let { it in rejectedIDs } == true)) {
            return XperienceAddonBinding.Resolution.InvalidRegistry
        }
        if (result is XperienceAddonBinding.Resolution.Resolved &&
            result.candidate.transportFingerprint in rejectedConfiguredIdentities[result.candidate.manifestID].orEmpty()) {
            return XperienceAddonBinding.Resolution.InvalidRegistry
        }
        return result
    }
    /** Only the same captured Candidate OBJECT selects its original immutable configured addon.
     * This is pairing evidence, not a reusable load/owner capability. */
    fun pairedAddon(candidate: XperienceAddonBinding.Candidate): VortxResourceAddon =
        pairings.singleOrNull { it.first === candidate }?.second
            ?: throw IllegalArgumentException("Installed addon snapshot changed")

    companion object {
        internal fun capture(owner: VortxNativeOwner, bucket: String,
            pairings: List<Pair<XperienceAddonBinding.Candidate, VortxResourceAddon>>,
            rejectedIDs: Set<String>, rejectedConfiguredIdentities: Map<String, Set<String>>,
        ) = XperienceInstalledCatalogSnapshot(owner, bucket, pairings, rejectedIDs, rejectedConfiguredIdentities)
    }
}

/** A live guarded request result. A resolved candidate is paired only for this result; it does not
 * create a reusable install, fetch, or profile-write capability. */
internal sealed interface XperienceCatalogRequestOutcome {
    data class Loaded(
        val candidate: XperienceAddonBinding.Candidate,
        val response: VortxResourceSnapshot,
        val items: List<MetaItem>,
        val rawItemCount: Int,
        val supportsSkip: Boolean,
    ) : XperienceCatalogRequestOutcome

    data class Unresolved(val resolution: XperienceAddonBinding.Resolution) : XperienceCatalogRequestOutcome
}

/** Opaque fixed-size identity for one long-lived catalog consumer. Reuse it across refreshes;
 * distinct consumers must allocate distinct IDs. It contains no URL or source authority. */
@JvmInline
internal value class XperienceCatalogConsumerID private constructor(val slotToken: String) {
    companion object {
        fun create(): XperienceCatalogConsumerID =
            XperienceCatalogConsumerID(java.util.UUID.randomUUID().toString())
    }
}

/** Actual UI repository for the explicit native compile gate. Never constructs the legacy engine.
 * The authenticated host provides the session; absence/unavailable/migration required is an error.
 * VortX authentication and complete legacy bootstrap are admitted only by the captured account host.
 */
internal class NativeCatalogRepository(
    private val playbackResolver: NativePlaybackResolver = NativePlaybackResolver { source, _ ->
        requireNotNull(nativeDirectPlayable(source)) { "Native platform resolver unavailable" }
    },
    private val sessionChanges: Flow<Unit> = flowOf(Unit),
    private val signOutAccount: (suspend () -> Unit)? = null,
    private val captureReclaimAdmission: ((VortxNativeSession, VortxNativeOwner) -> ((() -> Boolean) -> Boolean)?)? = null,
    private val withReclaimLifecycle: ((() -> Boolean) -> Boolean) = { action -> action() },
    private val nzbSourceAggregator: NzbSourceAggregator? = null,
    private val sourceIndexSource: NativeSourceIndexSource? = null,
    /** Mirrors a deliberate save or removal to Trakt/SIMKL watchlists once the native checkpoint persisted it
     *  (Apple `ScrobbleCoordinator.addedToLibrary` / `removedFromLibrary`): added, type, id. */
    private val mirrorLibrary: (Boolean, MediaType, String) -> Unit = { _, _, _ -> },
    /** Capture on the IO read lane; publication later enters only authenticated/lifecycle metadata
     * admission, never sessionProvider/native serialization on Main. Null rejects a retired mount. */
    private val captureAddonPublication: ((VortxNativeSession, Long) -> ((() -> Unit) -> Boolean)?)? = null,
    private val addonVisibilityDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val sessionProvider: () -> VortxNativeSession,
) : CatalogRepository, AuthRepository {
    private data class CatalogSpec(val addon: VortxResourceAddon, val catalog: JSONObject) {
        val type: String get() = catalog.getString("type")
        val id: String get() = catalog.getString("id")
        val title: String get() = catalog.optString("name", id)
        val key: String get() = "${addon.transportUrl}|$type|$id"
        val extras: List<JSONObject> get() = catalog.optJSONArray("extra").objects()
        fun accepts(name: String) = extras.any { it.getString("name") == name }
        fun request(extra: List<Pair<String, String>> = emptyList()) = VortxResourceRequest(VortxResourceRequest.Resource.CATALOG, type, id, extra)
        fun wire(extra: List<Pair<String, String>> = emptyList()) = JSONObject().put("addon", addon.id).put("request", request(extra).json()).toString()
    }
    private data class DiscoverPage(val owner: VortxNativeOwner, val spec: CatalogSpec, val extra: List<Pair<String, String>>,
                                    val items: List<MetaItem>, val count: Int)
    private data class Playing(val token: PlaybackSessionToken, val owner: VortxNativeOwner, val context: PlaybackContext)
    private var discoverPage: DiscoverPage? = null
    private data class HomePage(val owner: VortxNativeOwner, val spec: CatalogSpec, val catalog: Catalog, val count: Int)
    private val homePages = linkedMapOf<String, HomePage>()
    private val homePageChanges = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    private val detailCache = mutableMapOf<Pair<MediaType, String>, Pair<VortxNativeOwner, MetaDetail>>()
    private var admittedResources: Pair<VortxNativeOwner, Set<Pair<String, String>>>? = null
    private var playing: Playing? = null
    private data class DurableWatchProof(val owner: VortxNativeOwner, val token: PlaybackSessionToken, val watchedAt: Long,
                                        val admit: (() -> Boolean) -> Boolean)
    private val durableWatchReceipts = java.util.IdentityHashMap<DurableWatchedPlaybackReceipt, DurableWatchProof>()
    private class SourceBinding(val owner: VortxNativeOwner, @Volatile var context: PlaybackContext,
        val pooled: NativeSourceIndexBinding? = null)
    private sealed interface StreamEvent {
        data class Providers(val update: NativeProviderUpdate, val ticket: java.util.UUID,
            val accepted: CompletableDeferred<Unit>) : StreamEvent
        data class Indexer(val result: Result<NzbSourceAggregation>) : StreamEvent
        data class Pool(val result: NativeSourceIndexResult?) : StreamEvent
        data object PoolRevoked : StreamEvent
        data object ProvidersFinished : StreamEvent
    }
    private var foregroundSources: SourceContext? = null
    private val sourcePublications = mutableMapOf<String, java.lang.ref.WeakReference<SourceContext>>()
    private data class SourceInvalidation(val sequence: Long, val publicationId: String)
    private var sourceInvalidationSequence = 0L
    private val sourceInvalidations = MutableStateFlow<SourceInvalidation?>(null)
    override fun sourceInvalidations(): Flow<String> = sourceInvalidations.filterNotNull().map { it.publicationId }
    override fun isSourcePoolPublicationCurrent(sourcePublicationId: String): Boolean = synchronized(this) {
        val context = sourcePublications[sourcePublicationId]?.get()
        if (context == null) { sourcePublications.remove(sourcePublicationId); false }
        else !context.isPoolRetired()
    }

    private fun revokePool(context: SourceContext) {
        val retired = synchronized(this) {
            val jobs = listOfNotNull(context.poolJob, context.hoardJob)
            context.poolJob = null
            context.hoardJob = null
            context.poolResult = null
            sourcePublications.remove(context.sourcePublicationId)
            context.poolTokens.forEach(context.bindings::remove)
            context.poolTokens.clear()
            context.latestGroups = context.latestGroups.filterNot { it.base == com.vortx.android.singularity.SourceIndexClient.GROUP_ID }
            val notification = if (foregroundSources === context)
                SourceInvalidation(++sourceInvalidationSequence, context.sourcePublicationId) else null
            Triple(jobs, context.poolRevoked, notification)
        }
        // Job cancellation can invoke a blocking transport disconnect; never do it under repository/host locks.
        retired.first.forEach { it.cancel() }
        retired.second?.invoke()
        retired.third?.let { notification -> sourceInvalidations.update { previous ->
            if (previous == null || previous.sequence < notification.sequence) notification else previous
        } }
    }

    /** Loading, bindings and resolver authority are private to one source consumer. */
    private inner class SourceContext(
        val session: VortxNativeSession,
        val read: VortxNativeRead,
        val type: MediaType,
        val id: String,
        val episodeId: String?,
        val episode: Episode?,
        val slot: String,
        val prepared: Boolean,
    ) : SourcePreparation {
        val addons = registry(read)
        // Capture nullable scope before any provider suspension; never retarget an absent participant.
        val indexerScope = nzbSourceAggregator?.captureNativeScope(read.owner)
        private var poolAuthorization: com.vortx.android.singularity.SourceIndexAuthorization? = null
        private var poolCaptureAttempted = false
        override val sourcePublicationId: String = java.util.UUID.randomUUID().toString()
        @Volatile var poolTarget: NativeSourceIndexTarget? = null
        @Volatile var poolResult: NativeSourceIndexResult? = null
        val poolTokens = mutableSetOf<String>()
        @Volatile var poolJob: Job? = null
        @Volatile var hoardJob: Job? = null
        var hoardPending = emptyList<com.vortx.android.singularity.SourceIndexClient.Descriptor>()
        @Volatile var poolRevoked: (() -> Unit)? = null
        private var poolRetirement: AutoCloseable? = null
        val bindings = mutableMapOf<String, SourceBinding>()
        val resolutionSequence = AtomicLong()
        var ticket: java.util.UUID? = null
        var started = false
        var closed = false
        var adopted = false
        var latestGroups = emptyList<StreamGroup>()
        var indexerResult = NzbSourceAggregation.empty()
        @Volatile private var preparedPoolSelection: NativeSourceIndexBinding? = null
        fun capturePoolOnce() {
            // sourceUpdates runs on IO. Capture once before provider suspension, not on a UI preparation call.
            if (poolCaptureAttempted) return
            poolCaptureAttempted = true
            val captured = sourceIndexSource?.capture(session, read.owner)
            val admitted = synchronized(this@NativeCatalogRepository) {
                if (closed) false else {
                    poolAuthorization = captured
                    if (!isPoolRetired()) sourcePublications[sourcePublicationId] = java.lang.ref.WeakReference(this)
                    true
                }
            }
            if (!admitted) { sourceIndexSource?.retire(captured); return }
            poolRetirement = captured?.onRevoked {
                com.vortx.android.singularity.SourceIndexLifecycle.dispatchTeardown { revokePool(this@SourceContext) }
            }
        }
        fun poolAdmission() = poolAuthorization?.takeIf { it.isCurrent() }
        // Pending authorized publications must stay eligible before their asynchronous pool result arrives.
        fun isPoolRetired(): Boolean = poolAuthorization?.isRetired() != false
        fun retirePool() {
            sourceIndexSource?.retire(poolAuthorization)
            synchronized(this@NativeCatalogRepository) { sourcePublications.remove(sourcePublicationId) }
            poolRetirement?.close()
            poolRetirement = null
            com.vortx.android.singularity.SourceIndexLifecycle.dispatchTeardown { revokePool(this@SourceContext) }
        }
        override val owner: ContinueWatchingOwner get() = owner(read.owner)
        private fun visibleGroups(groups: List<StreamGroup>): List<StreamGroup> =
            if (poolResult?.isRetired(poolTarget) != false)
                groups.filterNot { it.base == com.vortx.android.singularity.SourceIndexClient.GROUP_ID } else groups
        override val groups: List<StreamGroup> get() = synchronized(this@NativeCatalogRepository) { visibleGroups(latestGroups) }

        override fun isCurrent(): Boolean = runCatching {
            session.owned(read.owner) { synchronized(this@NativeCatalogRepository) {
                sessionProvider() === session && !closed && (!adopted || foregroundSources === this) &&
                    (nzbSourceAggregator?.isAdmitted(indexerResult) != false) &&
                    (!prepared || preparedPoolSelection?.isRetired() != true)
            } }
        }.getOrDefault(false)

        override fun updates(): Flow<StreamLoadUpdate> = sourceUpdates(this)

        override suspend fun resolve(source: StreamSource): Result<Playable> = resolveAttempt {
            check(isCurrent()) { "Native preparation expired" }
            val binding = synchronized(this@NativeCatalogRepository) { bindings[source.nativePlaybackToken] }
            check(binding != null && binding.owner == read.owner && binding.context.videoId == episodeId) { "Native prepared source expired" }
            val playable = resolveOwned(session, read, source, episode, binding, this, resolutionSequence)
            preparedPoolSelection = binding.pooled
            playable.copy(playbackContext = binding.context)
        }

        override fun adopt(): SourcePreparationAdoption? = runCatching {
            session.owned(read.owner) { synchronized(this@NativeCatalogRepository) {
                if (!prepared || adopted || !isCurrent() || latestGroups.isEmpty() ||
                    preparedPoolSelection?.isRetired() == true) return@owned null
                val previous = foregroundSources
                adopted = true
                foregroundSources = this
                resolveSequence.incrementAndGet()
                object : SourcePreparationAdoption {
                    private val adoptedGroups = latestGroups
                    override val groups: List<StreamGroup> get() = synchronized(this@NativeCatalogRepository) { visibleGroups(adoptedGroups) }
                    override val sourcePublicationId = this@SourceContext.sourcePublicationId
                    private var rolledBack = false
                    private val published = java.util.concurrent.atomic.AtomicBoolean(false)
                    override fun commitPublished() {
                        if (published.compareAndSet(false, true)) previous?.takeIf { it !== this@SourceContext }?.retirePool()
                    }
                    override fun rollback() {
                        synchronized(this@NativeCatalogRepository) {
                            if (rolledBack || published.get()) return
                            rolledBack = true
                            if (foregroundSources === this@SourceContext) {
                                foregroundSources = previous
                                resolveSequence.incrementAndGet()
                            }
                            closed = true
                            resolutionSequence.incrementAndGet()
                        }
                        retirePool()
                        retireTicket()
                    }
                }
            } }
        }.getOrNull()

        fun retireTicket() {
            val captured = synchronized(this@NativeCatalogRepository) { ticket.also { ticket = null } }
            if (captured != null) session.retireResourceSlot(slot, captured)
        }

        override fun close() {
            synchronized(this@NativeCatalogRepository) {
                if (adopted || closed) return
                closed = true
                resolutionSequence.incrementAndGet()
            }
            retireTicket()
            retirePool()
        }
    }

    private fun sourceContext(type: MediaType, id: String, episodeId: String?, episode: Episode?, prepared: Boolean): SourceContext {
        val session = session(); val read = session.read()
        return session.owned(read.owner) {
            check(sessionProvider() === session) { "Native account changed" }
            SourceContext(session, read, type, id, episodeId, episode,
                if (prepared) "prepared-streams-${java.util.UUID.randomUUID()}" else "streams", prepared)
                .also { check(sessionProvider() === session) { "Native account changed" } }
        }
    }

    override fun openSourcePreparation(type: MediaType, id: String, episode: Episode): SourcePreparation? {
        if (type != MediaType.SERIES || episode.id.isBlank()) return null
        return sourceContext(type, id, episode.id, episode, prepared = true)
    }
    private val resolveSequence = AtomicLong()
    private val playbackSequence = AtomicLong()
    private val nativeAuth = MutableStateFlow<AuthState>(AuthState.SignedOut)
    override val authState: StateFlow<AuthState> = nativeAuth
    fun publishAuthentication(state: AuthState) { nativeAuth.value = state }
    private val unavailableOwner = ContinueWatchingOwner("native-unavailable", "native-unavailable", "native-unavailable", true, 0)

    private suspend fun <T> attempt(dispatcher: CoroutineDispatcher = Dispatchers.IO, action: suspend () -> T): Result<T> = withContext(dispatcher) {
        try { Result.success(action()) } catch (error: CancellationException) { throw error }
        catch (error: Exception) { Result.failure(error) }
        catch (_: LinkageError) { Result.failure(IllegalStateException("Native artifact is missing or incompatible")) }
    }
    /** The IO hop itself can reject a successful return through prompt cancellation. Own the
     * produced lease across that hop; resolveOwned still owns failures before it returns. */
    private suspend fun resolveAttempt(action: suspend () -> Playable): Result<Playable> {
        var produced: Playable? = null
        return try {
            attempt { action().also { produced = it } }
        } catch (failure: Throwable) {
            runCatching { produced?.playbackLease?.close() }
            throw failure
        }
    }
    private fun unsupported(capability: String): Nothing = throw UnsupportedOperationException("Native $capability is not enabled in this build")
    private fun session() = sessionProvider()
    private fun action(type: String) = JSONObject().put("type", type)
    private fun library(read: VortxNativeRead) = read.state.getJSONObject("libraries").getJSONObject(read.owner.profileID)
    private fun profile(read: VortxNativeRead) = read.state.getJSONObject("roster").getJSONObject("profiles").getJSONObject(read.owner.profileID)
    private fun addonOwner(read: VortxNativeRead): String = if (profile(read).getString("addons") == "share_primary") read.owner.scope.ownerProfileID else read.owner.profileID
    private fun addonDescriptors(read: VortxNativeRead): List<JSONObject> = addonDescriptors(session(), read)
    /** Use the caller's captured Session. Xperience never resolves through a late sessionProvider sample. */
    private fun addonDescriptors(session: VortxNativeSession, read: VortxNativeRead): List<JSONObject> {
        require(session.scope == read.owner.scope) { "Native owner changed" }
        val profileId = addonOwner(read)
        val response = session.resolve(JSONObject().put("kind", "installed_addons").put("profileId", profileId), read.owner)
        check(response.getString("kind") == "installed_addons" && response.getString("profileId") == profileId) { "Native addon projection unavailable" }
        return response.getJSONArray("addons").objects()
    }
    private fun registry(read: VortxNativeRead): List<VortxResourceAddon> = registry(session(), read)
    private fun registry(session: VortxNativeSession, read: VortxNativeRead): List<VortxResourceAddon> =
        registry(read, addonDescriptors(session, read))
    /** Shared installed-snapshot projection; also lets focused tests feed synthetic raw descriptors. */
    private fun registry(read: VortxNativeRead, descriptors: List<JSONObject>): List<VortxResourceAddon> {
        val disabled = NativeAddonPreferences.disabled(read)
        val order = NativeAddonPreferences.order(read)
        val ordered = if (order == null) descriptors else descriptors.sortedBy {
            order.indexOf(AddonOrder.normalize(it.getString("transportUrl"))).let { index -> if (index < 0) Int.MAX_VALUE else index }
        }
        return ordered.filterNot { AddonOrder.normalize(it.getString("transportUrl")) in disabled }.map {
            // Transport is the stable membership identity; duplicate manifest IDs are valid configurations.
            VortxResourceAddon.fromTransportUrl(it.getString("transportUrl"), it.getJSONObject("manifest").toString())
        }
    }
    private fun catalogSpecs(addon: VortxResourceAddon, allowMissingCatalogs: Boolean = false): List<CatalogSpec> {
        val manifest = JSONObject(requireNotNull(addon.manifestJson))
        if (allowMissingCatalogs && !manifest.has("catalogs")) return emptyList()
        return manifest.getJSONArray("catalogs").objects().map { CatalogSpec(addon, it) }
    }
    private fun catalogs(read: VortxNativeRead) = catalogs(registry(read))
    private fun catalogs(addons: List<VortxResourceAddon>) = addons.flatMap { catalogSpecs(it) }

    /**
     * Resolve/project from one caller-supplied admitted read and its owning Session. Call only inside
     * that Session's existing withCurrentRead admission; this method performs the existing
     * installed_addons native projection but never recaptures Session/current owner or issues a fetch.
     */
    internal fun xperienceCandidates(session: VortxNativeSession, read: VortxNativeRead): XperienceInstalledCatalogSnapshot =
        projectXperienceCandidates(read, addonDescriptors(session, read))

    /** Snapshot-only projection seam shared with xperienceCandidates; it does not acquire a Session. */
    internal fun xperienceCandidatesFromDescriptorSnapshot(
        read: VortxNativeRead,
        descriptors: List<JSONObject>,
    ): XperienceInstalledCatalogSnapshot = projectXperienceCandidates(read, descriptors)

    /**
     * Resolves and requests one imported Xperience source from the exact caller-owned Session/read.
     * Candidate projection and configured addon pairing happen in one current-read admission. The
     * request then uses the existing per-Session guarded resource bridge and re-admits the original
     * owner before the response is returned. Collection URLs never enter this path.
     * Only a RESOLVED call reaches session.load and can replace a prior request for this consumer.
     * Missing/ambiguous results return before opening a slot, so the caller must cancel its prior
     * coroutine and retain a selection-generation fence for every selection outcome.
     */
    internal suspend fun requestXperienceCatalog(
        session: VortxNativeSession,
        read: VortxNativeRead,
        source: com.vortx.android.xperience.XperienceCollections.Source,
        consumer: XperienceCatalogConsumerID,
        mapping: XperienceAddonBinding.Mapping? = null,
        skip: Int? = null,
        originalCurrent: () -> Boolean = { true },
    ): Result<XperienceCatalogRequestOutcome> = attempt {
        check(read.owner.scope == session.scope) { "Native owner changed" }
        data class Prepared(
            val read: VortxNativeRead,
            val resolution: XperienceAddonBinding.Resolution,
            val candidate: XperienceAddonBinding.Candidate? = null,
            val addon: VortxResourceAddon? = null,
            val request: VortxResourceRequest? = null,
        )
        val prepared = session.withCurrentRead { currentRead ->
            check(originalCurrent()) { "Original Xperience snapshot changed" }
            check(currentRead.owner == read.owner) { "Native owner changed" }
            val snapshot = projectXperienceCandidates(currentRead, addonDescriptors(session, currentRead))
            val resolution = snapshot.resolve(source, mapping)
            if (resolution !is XperienceAddonBinding.Resolution.Resolved) {
                Prepared(currentRead, resolution)
            } else {
                // The same capture seals candidate -> original configured addon directly.
                // A rejected descriptor before this entry cannot shift the request to its index.
                val configuredAddon = snapshot.pairedAddon(resolution.candidate)
                val type = requireNotNull(source.type)
                val catalogId = requireNotNull(source.catalogId)
                val catalog = resolution.candidate.catalogs.single { it.type == type && it.id == catalogId }
                require(skip == null || (skip >= 0 && catalog.supportsSkip)) { "Catalog does not support this cursor" }
                val extras = source.genre?.let { listOf("genre" to it) }.orEmpty() +
                    skip?.let { listOf("skip" to it.toString()) }.orEmpty()
                Prepared(currentRead, resolution, resolution.candidate, configuredAddon,
                    VortxResourceRequest(VortxResourceRequest.Resource.CATALOG, type, catalogId, extras))
            }
        }
        if (prepared.resolution !is XperienceAddonBinding.Resolution.Resolved) {
            return@attempt XperienceCatalogRequestOutcome.Unresolved(prepared.resolution)
        }
        val candidate = requireNotNull(prepared.candidate)
        val addon = requireNotNull(prepared.addon)
        val request = requireNotNull(prepared.request)
        // Only a resolved load reaches this stable per-consumer slot. Independent consumers stay
        // isolated even for the same source; unresolved outcomes above do not retire a prior slot.
        val slot = "xperience:${consumer.slotToken}"
        currentCoroutineContext().ensureActive()
        check(originalCurrent()) { "Original Xperience snapshot changed" }
        val response = session.load(slot, prepared.read.owner, listOf(request to listOf(addon))).single()
        currentCoroutineContext().ensureActive()
        check(originalCurrent()) { "Original Xperience snapshot changed" }
        requireSettled(response)
        val originalCount = rawCount(response) // Before parental filtering; visible count is not a cursor.
        val admitted = policyPage(session, response, prepared.read, slot, listOf(response))
        val items = EngineState.parseCatalogs(VortxResourceProjection.board(listOf(admitted), listOf(addon)))
            .flatMap { it.items }.distinctBy { it.type to it.id }
        val supportsSkip = candidate.catalogs.single { it.type == source.type && it.id == source.catalogId }.supportsSkip
        currentCoroutineContext().ensureActive()
        session.publish(slot, prepared.read.owner, listOf(response)) {
            check(originalCurrent()) { "Original Xperience snapshot changed" }
            XperienceCatalogRequestOutcome.Loaded(candidate, admitted, items, originalCount, supportsSkip)
        }
    }

    private class XperienceDescriptorFault : Exception()
    private class XperienceIdentityBudget {
        // Existing native/source JSON bound, not a new small manifest-ID/URL quota.
        private var remaining = OHJson.MAX
        fun admit(id: String) {
            var count = 0
            var index = 0
            while (index < id.length) {
                val first = id[index]
                val width = when {
                    Character.isHighSurrogate(first) -> {
                        require(index + 1 < id.length && Character.isLowSurrogate(id[index + 1])) { "Invalid installed registry" }
                        index += 2; 4
                    }
                    Character.isLowSurrogate(first) -> throw IllegalArgumentException("Invalid installed registry")
                    else -> { index++; if (first.code < 128) 1 else if (first.code < 2048) 2 else 3 }
                }
                require(count <= remaining - width) { "Invalid installed registry" }
                count += width
            }
            require(id.isNotBlank() && count < remaining) { "Invalid installed registry" }
            remaining -= count + 1
        }
    }
    private fun xperienceString(value: Any?): String {
        val text = value as? String ?: throw XperienceDescriptorFault()
        if (text.isEmpty()) throw XperienceDescriptorFault()
        var index = 0
        while (index < text.length) {
            val char = text[index++]
            if (Character.isHighSurrogate(char)) {
                if (index >= text.length || !Character.isLowSurrogate(text[index++])) throw XperienceDescriptorFault()
            } else if (Character.isLowSurrogate(char)) throw XperienceDescriptorFault()
        }
        return text
    }
    private fun xperienceCandidate(id: String, transport: String, catalogs: List<XperienceAddonBinding.Catalog>): XperienceAddonBinding.Candidate {
        // Catch only this pure factory's documented input rejection, not repository/JNI,
        // programmer, cancellation, linkage or memory failures from a wider operation.
        return try { XperienceAddonBinding.Candidate.fromInstalled(XperienceAddonBinding.InstalledDescriptor(id, transport, catalogs)) }
        catch (_: IllegalArgumentException) { throw XperienceDescriptorFault() }
    }
    private fun xperienceCatalogs(manifest: JSONObject): List<XperienceAddonBinding.Catalog> {
        val catalogs = manifest.opt("catalogs") as? JSONArray ?: throw XperienceDescriptorFault()
        return (0 until catalogs.length()).mapNotNull { index ->
            val catalog = catalogs.opt(index) as? JSONObject ?: throw XperienceDescriptorFault()
            val type = xperienceString(catalog.opt("type"))
            val id = xperienceString(catalog.opt("id"))
            val supported = mutableSetOf<String>()
            val required = mutableSetOf<String>()
            if (catalog.has("extra")) {
                val extras = catalog.opt("extra") as? JSONArray ?: throw XperienceDescriptorFault()
                for (at in 0 until extras.length()) {
                    val extra = extras.opt(at) as? JSONObject ?: throw XperienceDescriptorFault()
                    val name = xperienceString(extra.opt("name")); supported.add(name)
                    if (extra.has("isRequired")) {
                        val needed = extra.opt("isRequired") as? Boolean ?: throw XperienceDescriptorFault()
                        if (needed) required.add(name)
                    }
                }
            }
            for ((key, needed) in listOf("extraSupported" to false, "extraRequired" to true)) {
                if (catalog.has(key)) {
                    val extras = catalog.opt(key) as? JSONArray ?: throw XperienceDescriptorFault()
                    for (at in 0 until extras.length()) {
                        val name = xperienceString(extras.opt(at))
                        if (needed) required.add(name) else supported.add(name)
                    }
                }
            }
            if (required.any { it != "genre" }) return@mapNotNull null
            XperienceAddonBinding.Catalog(type, id, "genre" in supported || "genre" in required,
                "genre" in required, "skip" in supported)
        }
    }
    private fun projectXperienceCandidates(
        read: VortxNativeRead,
        descriptors: List<JSONObject>,
    ): XperienceInstalledCatalogSnapshot {
        data class Identified(val descriptor: JSONObject, val manifest: JSONObject, val id: String)
        val budget = XperienceIdentityBudget()
        // Missing/malformed/scalar-invalid or unbounded identity is global denial, even
        // when some earlier descriptors happened to be usable. No partial capture escapes.
        val identified = descriptors.map { descriptor ->
            val manifest = descriptor.opt("manifest") as? JSONObject
                ?: throw IllegalArgumentException("Invalid installed registry")
            val id = manifest.opt("id") as? String ?: throw IllegalArgumentException("Invalid installed registry")
            budget.admit(id)
            Identified(descriptor, manifest, id)
        }
        val disabled = NativeAddonPreferences.disabled(read)
        val order = NativeAddonPreferences.order(read)
        val pairings = mutableListOf<Pair<XperienceAddonBinding.Candidate, VortxResourceAddon>>()
        val rejectedIDs = mutableSetOf<String>()
        val rejectedConfigurations = mutableMapOf<String, MutableSet<String>>()
        for (entry in identified) {
            val url = entry.descriptor.opt("transportUrl") as? String
            // Existing profile visibility/order policy only. This normalized preference key
            // is never a manifest identity, configured request endpoint, or candidate pairing.
            if (url != null && AddonOrder.normalize(url) in disabled) continue
            // No catalogs means no endpoint. It is not a malformed catalog sibling.
            if (!entry.manifest.has("catalogs")) continue
            var transportIdentity: XperienceAddonBinding.Candidate? = null
            try {
                if (url == null) throw XperienceDescriptorFault()
                transportIdentity = xperienceCandidate(entry.id, url, emptyList())
                val candidate = xperienceCandidate(entry.id, url, xperienceCatalogs(entry.manifest))
                val addon = VortxResourceAddon.fromTransportUrl(url, entry.manifest.toString())
                pairings.add(candidate to addon)
            } catch (_: XperienceDescriptorFault) {
                rejectedIDs.add(entry.id)
                transportIdentity?.transportFingerprint?.let { fingerprint ->
                    rejectedConfigurations.getOrPut(entry.id) { mutableSetOf() }.add(fingerprint)
                }
            }
        }
        val ordered = if (order == null) pairings else pairings.sortedBy { (_, addon) ->
            order.indexOf(AddonOrder.normalize(addon.transportUrl)).let { if (it < 0) Int.MAX_VALUE else it }
        }
        return XperienceInstalledCatalogSnapshot.capture(read.owner, addonOwner(read), ordered, rejectedIDs, rejectedConfigurations)
    }
    private fun canLoad(spec: CatalogSpec, extras: Set<String>) = spec.extras.none { it.optBoolean("isRequired") && it.getString("name") !in extras }
    private fun parental(read: VortxNativeRead): Boolean = profile(read).getJSONObject("parental").let {
        it.getBoolean("kids") || (!it.isNull("maturityCeiling") && it.has("maturityCeiling"))
    }
    private fun policyPage(page: VortxResourceSnapshot, read: VortxNativeRead, slot: String,
                           completed: List<VortxResourceSnapshot>, ticket: java.util.UUID? = null): VortxResourceSnapshot {
        if (!parental(read)) return page
        // Keep the existing generic path's provider resampling behavior unchanged.
        return policyPageUsing({ session() }, page, read, slot, completed, ticket)
    }

    /** Exact-session overload for operations that must not sample sessionProvider after suspension. */
    private fun policyPage(session: VortxNativeSession, page: VortxResourceSnapshot, read: VortxNativeRead, slot: String,
                           completed: List<VortxResourceSnapshot>, ticket: java.util.UUID? = null): VortxResourceSnapshot {
        if (!parental(read)) return page
        return policyPageUsing({ session }, page, read, slot, completed, ticket)
    }

    private fun policyPageUsing(currentSession: () -> VortxNativeSession, page: VortxResourceSnapshot, read: VortxNativeRead,
                                slot: String, completed: List<VortxResourceSnapshot>, ticket: java.util.UUID? = null): VortxResourceSnapshot {
        // A completed load can be superseded while its caller parses. Policy evidence is itself
        // publication: fence the complete admission/revocation, including blocked/null outcomes.
        return currentSession().publish(slot, read.owner, completed, ticket) {
        val kind = when (page.request.resource) {
            VortxResourceRequest.Resource.CATALOG -> "catalog"
            VortxResourceRequest.Resource.META -> "meta"
            else -> error("Parental metadata evidence required")
        }
        page.copy(groups = page.groups.map { group ->
            if (group.status != "ready") return@map group
            val raw = JSONObject(requireNotNull(group.contentJson))
            if (kind == "meta" && !raw.isNull("meta")) {
                val value = raw.getJSONObject("meta")
                require(value.getString("id") == page.request.id && value.getString("type") == page.request.type) { "Native metadata identity mismatch" }
            }
            if (kind == "catalog") {
                val identities = raw.getJSONArray("metas").objects().map { it.getString("type") to it.getString("id") }
                require(identities.distinct().size == identities.size) { "Ambiguous parental catalog identity" }
            }
            val response = if (kind == "meta" && raw.isNull("meta")) JSONObject().put("kind", kind).put("meta", JSONObject.NULL)
            else currentSession().resolve(JSONObject().put("kind", kind).also {
                if (kind == "catalog") it.put("metas", raw.getJSONArray("metas"))
                else it.put("meta", raw.get("meta"))
            }, read.owner)
            check(response.getString("kind") == kind) { "Native parental projection unavailable" }
            val field = if (kind == "catalog") "metas" else "meta"
            // The policy DTO may omit provider extensions (notably embedded streams). Use it
            // only as an admission decision; retain the exact approved provider object.
            val allowed: Any = if (kind == "meta") {
                if (response.isNull("meta")) JSONObject.NULL else raw.get("meta")
            } else {
                val ids = response.getJSONArray("metas").objects().map { it.getString("type") to it.getString("id") }.toSet()
                JSONArray(raw.getJSONArray("metas").objects().filter { (it.getString("type") to it.getString("id")) in ids })
            }
            val admitted = when (allowed) {
                is JSONObject -> setOf(allowed.getString("type") to allowed.getString("id"))
                is JSONArray -> allowed.objects().map { it.getString("type") to it.getString("id") }.toSet()
                else -> emptySet()
            }
            val observed = if (kind == "meta") setOf(page.request.type to page.request.id) else
                raw.getJSONArray("metas").objects().map { it.getString("type") to it.getString("id") }.toSet()
            currentSession().owned(read.owner) { synchronized(this) {
                val prior = admittedResources?.takeIf { it.first == read.owner }?.second.orEmpty()
                admittedResources = read.owner to (prior - observed + admitted).takeLastBounded(20_000)
                detailCache.entries.removeAll { (identity, entry) -> entry.first == read.owner &&
                    (identity.first.id to identity.second) in (observed - admitted) }
            } }
            group.copy(contentJson = JSONObject(raw.toString()).put(field, allowed).toString())
        })
        }
    }
    private fun <T> Set<T>.takeLastBounded(size: Int): Set<T> = if (this.size <= size) this else toList().takeLast(size).toSet()
    private fun board(pages: List<VortxResourceSnapshot>, addons: List<VortxResourceAddon>, read: VortxNativeRead, slot: String) =
        VortxResourceProjection.board(pages.map { policyPage(it, read, slot, pages) }, addons)
    private fun rawCount(page: VortxResourceSnapshot) = page.groups.sumOf { it.items(page.request.resource).size }
    private fun visibleLocal(items: List<MetaItem>, read: VortxNativeRead): List<MetaItem> {
        if (!parental(read) || items.isEmpty()) return items
        // Library/watch records deliberately do not invent a certification. Unknown is blocked by
        // the same kernel policy until authenticated provider metadata supplies evidence.
        val raw = JSONArray(items.map { JSONObject().put("id", it.id).put("type", it.type.id).put("name", it.name) })
        val allowed = session().resolve(JSONObject().put("kind", "catalog").put("metas", raw), read.owner)
        check(allowed.getString("kind") == "catalog")
        val cached = synchronized(this) { detailCache.values.filter { it.first == read.owner }.map { it.second.type.id to it.second.id }.toSet() +
            admittedResources?.takeIf { it.first == read.owner }?.second.orEmpty() }
        val identities = allowed.getJSONArray("metas").objects().map { it.getString("type") to it.getString("id") }.toSet() + cached
        return items.filter { (it.type.id to it.id) in identities }
    }
    private fun owner(value: VortxNativeOwner) = ContinueWatchingOwner(value.profileID, value.scope.digest, value.scope.accountID, true, value.revision)
    override fun continueWatchingOwner() = runCatching { owner(session().read().owner) }.getOrDefault(unavailableOwner)
    override fun admitClientHomeRows(rows: List<Catalog>, expectedOwner: ContinueWatchingOwner): Result<List<Catalog>> = runCatching {
        val session = session(); val read = session.read()
        check(owner(read.owner) == expectedOwner) { "Native client rail owner changed" }
        session.owned(read.owner) { rows.map { it.copy(items = visibleLocal(it.items, read)) } }
    }

    private fun savedItems(read: VortxNativeRead): List<MetaItem> = library(read).getJSONArray("items").objects().filter {
        it.getString("kind") == "standard"
    }.map(::nativeSavedLibraryItem)
    private fun cw(read: VortxNativeRead): List<MetaItem> {
        val saved = savedItems(read)
        return visibleLocal(playback(read).getJSONArray("continueWatching").objects().map { item ->
            nativeContinueWatchingItem(item, saved)
        }, read)
    }
    private fun playback(read: VortxNativeRead): JSONObject = session().resolve(
        JSONObject().put("kind", "profile_playback").put("profileId", read.owner.profileID), read.owner).also {
        check(it.getString("kind") == "profile_playback" && it.getString("profileId") == read.owner.profileID) { "Native playback projection unavailable" }
    }
    override suspend fun continueWatchingSnapshot(expectedOwner: ContinueWatchingOwner) = attempt {
        val session = session(); val read = session.read()
        check(owner(read.owner) == expectedOwner) { "Native owner changed" }
        session.owned(read.owner) { ContinueWatchingSnapshot(expectedOwner, cw(read)) }
    }
    override suspend fun playbackHistorySnapshot(expectedOwner: ContinueWatchingOwner) = attempt {
        val session = session(); val read = session.read()
        check(owner(read.owner) == expectedOwner) { "Native history owner changed" }
        session.owned(read.owner) {
            val saved = savedItems(read)
            val projection = playback(read)
            // Kernel history is completed watches; active partial playback is a separate lane.
            // Both are viewing evidence, unlike saved library membership alone.
            val records = projection.getJSONArray("history").objects() + projection.getJSONArray("continueWatching").objects()
            val items = records.sortedByDescending { it.getLong("updatedAt") }.map { item ->
                val id = item.getString("metaId")
                val matches = saved.filter { it.id == id }
                check(matches.size <= 1) { "Ambiguous native history media identity" }
                val type = item.optStringOrNull("type")?.let(MediaType::fromId) ?: matches.singleOrNull()?.type
                    ?: if (item.optStringOrNull("videoId")?.let { it != id } == true) MediaType.SERIES else MediaType.MOVIE
                val offset = item.getLong("offsetMs"); val duration = item.getLong("durationMs")
                MetaItem(id, type, item.getString("name"), poster = item.optStringOrNull("poster") ?: matches.singleOrNull()?.poster,
                    watched = item.getBoolean("watched"), resumeSeconds = offset / 1000.0,
                    progress = if (duration > 0) (offset.toFloat() / duration).coerceIn(0f, 1f) else 0f)
            }.distinctBy { it.type to it.id }
            ContinueWatchingSnapshot(expectedOwner, visibleLocal(items, read))
        }
    }
    override suspend fun home(): Result<List<Catalog>> = attempt {
        val session = session(); val read = session.read()
        val specs = catalogs(read).filter { canLoad(it, emptySet()) }
        val pages = session.load("board", read.owner, specs.map { it.request() to listOf(it.addon) })
        requireAnySettled(pages)
        val rawCounts = specs.zip(pages).associate { (spec, page) -> spec.key to rawCount(page) }
        val parsedRows = EngineState.parseCatalogs(board(pages, registry(read), read, "board"), specs.associate { it.key to it.title }).associateBy { it.id }
        val rows = specs.mapNotNull { spec ->
            val more = spec.accepts("skip") && (rawCounts[spec.key] ?: 0) > 0
            // The presentation decoder omits empty rows; retain this cursor when policy filtered
            // the entire raw page, otherwise an allowed later page becomes unreachable.
            (parsedRows[spec.key] ?: if (more) Catalog(spec.key, spec.title, emptyList()) else null)?.copy(hasNextPage = more)
        }
        session.publish("board", read.owner, pages) {
            synchronized(this) {
                homePages.clear()
                rows.forEach { row -> specs.find { it.key == row.id }?.let { homePages[row.id] = HomePage(read.owner, it, row, rawCounts[row.id] ?: 0) } }
            }
            listOf(Catalog("continue", "Continue Watching", cw(session.read()))) + rows
        }
    }
    override fun homeUpdates(): Flow<HomeUpdate> = kotlinx.coroutines.flow.channelFlow {
        sessionChanges.collectLatest {
            val session = runCatching { session() }.getOrNull()
            if (session == null) {
                send(HomeUpdate(emptyList(), profileId = unavailableOwner.profileId, authoritative = true, owner = unavailableOwner))
                return@collectLatest
            }
            merge(session.updates.map { true }, homePageChanges.map { false }).collectLatest update@ { reload ->
                val read = runCatching { session.read() }.getOrNull() ?: return@update
                val result = if (reload) home() else runCatching { session.owned(read.owner) {
                    listOf(Catalog("continue", "Continue Watching", cw(read))) + synchronized(this) { homePages.values.filter { it.owner == read.owner }.map { it.catalog } }
                } }
                if (!runCatching { sessionProvider() === session && session.accepts(read.owner) }.getOrDefault(false)) return@update
                send(HomeUpdate(result.getOrThrow(), read.owner.revision, session.updates.value, read.owner.profileID, true, owner(read.owner)))
            }
        }
    }
    override fun ctxUpdates(): Flow<Unit> = kotlinx.coroutines.flow.channelFlow { sessionChanges.collectLatest {
        val session = runCatching { session() }.getOrNull() ?: return@collectLatest
        session.updates.collect {
            if (runCatching { check(sessionProvider() === session); session.read() }.isSuccess) send(Unit)
        }
    } }
    override suspend fun loadHomeRowNextPage(catalog: Catalog) = attempt {
        val session = session(); val read = session.read()
        val previous = synchronized(this) { requireNotNull(homePages[catalog.id]) }
        check(previous.owner == read.owner && previous.spec.accepts("skip")) { "Native catalog changed" }
        if (!previous.catalog.hasNextPage) return@attempt Unit
        val page = session.load("board:${catalog.id}", read.owner,
            listOf(previous.spec.request(listOf("skip" to previous.count.toString())) to listOf(previous.spec.addon))).single()
        requireSettled(page)
        val next = EngineState.parseCatalogs(board(listOf(page), listOf(previous.spec.addon), read, "board:${catalog.id}")).flatMap { it.items }
        session.publish("board:${catalog.id}", read.owner, listOf(page)) {
            synchronized(this) {
                check(homePages[catalog.id] === previous) { "Native catalog reload superseded page" }
                homePages[catalog.id] = previous.copy(catalog = previous.catalog.copy(
                    items = (previous.catalog.items + next).distinctBy { it.type to it.id }, hasNextPage = rawCount(page) > 0), count = previous.count + rawCount(page))
            }
            homePageChanges.tryEmit(Unit)
        }; Unit
    }
    override suspend fun loadMoreHomeRows() = attempt { session(); Unit } // all available catalogs already loaded
    override suspend fun ensureLiveCatalogsLoaded() = home().map { true }

    override suspend fun discover(requestJson: String?): Result<DiscoverResult> = attempt {
        val session = session(); val read = session.read(); val specs = catalogs(read)
        if (specs.isEmpty()) {
            val empty = session.load("discover", read.owner, emptyList())
            return@attempt session.publish("discover", read.owner, empty) { DiscoverResult() }
        }
        val wire = requestJson?.let(::JSONObject)
        val spec = if (wire == null) specs.firstOrNull { canLoad(it, emptySet()) } ?: unsupported("required catalog selection")
            else specs.single { it.addon.id == wire.getString("addon") && it.type == wire.getJSONObject("request").getString("type") && it.id == wire.getJSONObject("request").getString("id") }
        val extras = wire?.getJSONObject("request")?.getJSONArray("extra")?.let { array -> (0 until array.length()).map {
            array.getJSONArray(it).let { pair -> pair.getString(0) to pair.getString(1) }
        } } ?: emptyList()
        require(extras.all { spec.accepts(it.first) && it.first != "skip" && it.first != "search" } && extras.map { it.first }.distinct().size == extras.size)
        check(canLoad(spec, extras.map { it.first }.toSet())) { "Catalog requires a selection" }
        val page = session.load("discover", read.owner, listOf(spec.request(extras) to listOf(spec.addon))).single()
        requireSettled(page)
        val items = EngineState.parseCatalogs(board(listOf(page), listOf(spec.addon), read, "discover")).flatMap { it.items }
        session.publish("discover", read.owner, listOf(page)) {
            synchronized(this) { discoverPage = DiscoverPage(read.owner, spec, extras, items, rawCount(page)) }
            DiscoverResult(items, discoverFilters(specs, spec, extras, rawCount(page) > 0))
        }
    }
    override suspend fun discoverNextPage(): Result<DiscoverResult> = attempt {
        val session = session(); val read = session.read()
        val previous = synchronized(this) { requireNotNull(discoverPage) }
        check(previous.owner == read.owner) { "Native owner changed" }
        check(previous.spec.accepts("skip")) { "Catalog does not support pagination" }
        val request = previous.spec.request(previous.extra + ("skip" to previous.count.toString()))
        val page = session.load("discover", read.owner, listOf(request to listOf(previous.spec.addon))).single()
        requireSettled(page)
        val next = EngineState.parseCatalogs(board(listOf(page), listOf(previous.spec.addon), read, "discover")).flatMap { it.items }
        val items = (previous.items + next).distinctBy { it.type to it.id }
        session.publish("discover", read.owner, listOf(page)) {
            synchronized(this) { check(discoverPage === previous); discoverPage = previous.copy(items = items, count = previous.count + rawCount(page)) }
            DiscoverResult(items, discoverFilters(catalogs(read), previous.spec, previous.extra, rawCount(page) > 0))
        }
    }
    private fun discoverFilters(specs: List<CatalogSpec>, selected: CatalogSpec, extra: List<Pair<String, String>>, more: Boolean): DiscoverFilters {
        val visible = specs.filter { canLoad(it, emptySet()) || it === selected }
        val genres = selected.extras.find { it.getString("name") == "genre" }?.optJSONArray("options")?.strings().orEmpty()
        return DiscoverFilters(
            types = visible.distinctBy { it.type }.map { DiscoverTypeOption(it.type, it.type == selected.type, it.wire()) },
            catalogs = visible.filter { it.type == selected.type }.map { DiscoverCatalogOption(it.title, it.key == selected.key, it.wire()) },
            genres = genres.map { genre -> DiscoverGenreOption(genre, extra.contains("genre" to genre), selected.wire(listOf("genre" to genre))) },
            hasNextPage = selected.accepts("skip") && more)
    }
    override suspend fun search(query: String): Result<List<MetaItem>> = attempt {
        var result = emptyList<MetaItem>()
        searchUpdates(query).collect { (items, _) -> result = items }
        result
    }
    override fun searchUpdates(query: String): Flow<Pair<List<MetaItem>, Boolean>> = flow {
        val session = session(); val read = session.read(); val text = query.trim()
        val addons = if (text.length >= 2) registry(read) else emptyList()
        val specs = catalogs(addons).filter { it.accepts("search") && canLoad(it, setOf("search")) }
        if (text.length >= 2) emit(emptyList<MetaItem>() to true)
        // An empty query starts an empty batch too, revoking the preceding native consumer slot.
        session.loadIncrementally("search", read.owner, specs.map { it.request(listOf("search" to text)) to listOf(it.addon) }) { pages, pending, ticket ->
            if (!pending) requireAnySettled(pages)
            val items = session.publish("search", read.owner, pages, ticket) {
                EngineState.parseCatalogs(board(pages, addons, read, "search")).flatMap { it.items }.distinctBy { it.type to it.id }
            }
            emit(items to pending)
        }
    }.flowOn(Dispatchers.IO)

    override suspend fun meta(type: MediaType, id: String): Result<MetaDetail> = attempt {
        val session = session(); val read = session.read(); val addons = registry(read)
        val request = VortxResourceRequest(VortxResourceRequest.Resource.META, type.id, id)
        flow {
            session.loadProviders("meta", read.owner, addons.map { NativeProviderLeg(request, it) }) { update, ticket ->
                val result = session.publish("meta", read.owner, update.pages, ticket) {
                    check(sessionProvider() === session) { "Native account changed" }
                    val allowed = update.pages.map { policyPage(it, read, "meta", update.pages, ticket) }
                    EngineState.parseMetaDetail(VortxResourceProjection.providerDetails(allowed, request, null, addons), appliedAddonOrder = emptyList())?.let { detail ->
                        check(detail.id == id && detail.type == type) { "Native metadata identity mismatch" }
                        synchronized(this@NativeCatalogRepository) { detailCache[type to id] = read.owner to detail }
                        decorate(detail, session.read())
                    }
                }
                if (result != null) emit(result)
                else if (!update.pending) error("Native metadata unavailable or blocked")
            }
        }.first() // First admitted metadata is usable; cancellation retires the remaining peer requests.
    }
    override suspend fun peekMeta(type: MediaType, id: String): MetaDetail? {
        val session = session(); val read = session.read()
        val cached = synchronized(this) { detailCache[type to id] } ?: return null
        return session.owned(read.owner) { if (cached.first == read.owner) decorate(cached.second, read) else null }
    }
    override suspend fun streams(type: MediaType, id: String, episodeId: String?, rememberedQuality: String?, wantedAddon: String?, forceRefresh: Boolean): Result<List<StreamGroup>> = attempt {
        var groups = emptyList<StreamGroup>()
        streamUpdates(type, id, episodeId, rememberedQuality, wantedAddon, forceRefresh).collect { groups = it.groups }
        groups
    }

    override fun streamUpdates(type: MediaType, id: String, episodeId: String?, rememberedQuality: String?, wantedAddon: String?, forceRefresh: Boolean): Flow<StreamLoadUpdate> = flow {
        sourceUpdates(sourceContext(type, id, episodeId, null, prepared = false)).collect { emit(it) }
    }.flowOn(Dispatchers.IO)

    private fun sourceUpdates(context: SourceContext): Flow<StreamLoadUpdate> = flow {
        synchronized(this@NativeCatalogRepository) {
            check(!context.started && !context.closed) { "Native source consumer already used" }
            context.started = true
        }
        context.capturePoolOnce()
        val session = context.session; val read = context.read; val addons = context.addons
        val type = context.type; val id = context.id; val episodeId = context.episodeId
        val indexerScope = context.indexerScope
        val slot = context.slot
        val stream = VortxResourceRequest(VortxResourceRequest.Resource.STREAM, type.id, episodeId ?: id)
        val metaRequest = VortxResourceRequest(VortxResourceRequest.Resource.META, type.id, id)
        val legs = addons.map { NativeProviderLeg(metaRequest, it) } + addons.map { NativeProviderLeg(stream, it) }
        val coroutine = currentCoroutineContext()
        val tokens = mutableMapOf<Pair<String, String>, String>()
        var initializedBindings = false
        var lastUpdate = NativeProviderUpdate(emptyList(), 0, legs.size)
        var lastTicket: java.util.UUID? = null
        var approvedSearch: com.vortx.android.nzb.NzbSearch? = null
        var direct = NzbSourceAggregation.empty()
        var providersFinished = false
        var indexerStarted = false
        var indexerFinished = indexerScope == null
        fun publish(update: NativeProviderUpdate, ticket: java.util.UUID, terminal: Boolean): StreamLoadUpdate? = session.publishIfLatestReceipt(slot, read.owner, update.pages, ticket) {
            coroutine.ensureActive()
            check(sessionProvider() === session) { "Native account changed" }
            check(synchronized(this@NativeCatalogRepository) { !context.closed }) { "Native source consumer closed" }
            val allowed = update.pages.map { if (it.request.resource == VortxResourceRequest.Resource.META) policyPage(it, read, slot, update.pages, ticket) else it }
            val projection = VortxResourceProjection.providerDetails(allowed, metaRequest, stream, addons)
            val currentDetail: MetaDetail? = EngineState.parseMetaDetail(projection, appliedAddonOrder = emptyList())
            val detail: MetaDetail? = currentDetail ?: synchronized(this) { detailCache[type to id]?.takeIf { it.first == read.owner }?.second }
            check(detail == null || (detail.id == id && detail.type == type)) { "Native metadata identity mismatch" }
            // Prepared metadata must be approved in this exact request, never borrowed from a
            // foreground cached title; include the expected episode coordinates, not just its id.
            val identityDetail = if (context.prepared) currentDetail else detail
            val approved = !context.prepared && !parental(read) || identityDetail != null && if (type == MediaType.SERIES) {
                episodeId != null && identityDetail.videos.any { it.id == episodeId &&
                    (context.episode == null || it.season == context.episode.season && it.episode == context.episode.episode) }
            } else episodeId == null || episodeId == id
            if (!approved) {
                if (terminal) error("Stream identity is not in approved metadata")
                return@publishIfLatestReceipt StreamLoadUpdate(emptyList(), update.settled, update.total, false)
            }
            // A same-owner cached detail is useful for display, not authorization for a fresh
            // indexer query. Wait for this request's identity-checked, parental-approved metadata.
            if (currentDetail != null) approvedSearch = nativeNzbSearch(currentDetail, type, id, episodeId)
            val rawGroups = EngineState.parseStreamGroups(projection, episodeId ?: id)
            if (currentDetail != null) {
                val target = nativeSourceIndexTarget(currentDetail, type, id, episodeId, context.episode)
                val prior = context.poolTarget
                if (prior != null && prior != target) context.retirePool()
                else if (prior == null && target != null) context.poolTarget = target
            }
            val selectedEpisode = detail?.videos?.find { it.id == episodeId }
            val indexerGroups = if (nzbSourceAggregator?.isAdmitted(direct, coroutine.isActive) == true) direct.groups else emptyList()
            val pooled = context.poolResult?.takeIf { it.isCurrent(context.poolTarget) }
            val combined = mergeNzbGroups(rawGroups, indexerGroups) + (pooled?.groups() ?: emptyList())
            val groups = if (parental(read)) combined.map { group -> group.copy(streams = group.streams.filter {
                StreamRanking.passesUserFilters(it, com.vortx.android.sources.SourcePrefsSnapshot.DEFAULT.copy(isKids = true))
            }) } else combined
            if (terminal && groups.none { it.streams.isNotEmpty() } && addons.isNotEmpty()) {
                check(update.pages.any { it.request == stream && it.groups.any { group -> group.status == "ready" } }) { "Native resources unavailable" }
            }
            val bound = synchronized(this) {
                if (detail != null) detailCache[type to id] = read.owner to detail
                if (!initializedBindings) {
                    if (!context.prepared) {
                        foregroundSources?.takeIf { it !== context }?.retirePool()
                        foregroundSources = context
                        resolveSequence.incrementAndGet()
                    }
                    initializedBindings = true
                }
                groups.map { group -> group.copy(streams = group.streams.map { source ->
                    // A later partial must not revoke the source token already being resolved.
                    val poolBinding = if (group.base == com.vortx.android.singularity.SourceIndexClient.GROUP_ID)
                        requireNotNull(pooled?.binding(source)) { "Unadmitted pooled source" } else null
                    val tokenKey = if (poolBinding != null) "repository-pool" to source.id else source.addon to source.id
                    val token = tokens.getOrPut(tokenKey) { java.util.UUID.randomUUID().toString() }
                    val playbackContext = PlaybackContext(
                        PlaybackContext.Owner(read.owner.profileID, true), id, episodeId ?: id, type.id,
                        selectedEpisode?.season, selectedEpisode?.episode, detail?.name ?: id, detail?.poster,
                        PlaybackContext.Provenance(source.addon, source.quality, false, null, null), nativeSessionRevision = read.owner.revision)
                    val binding = context.bindings.getOrPut(token) { SourceBinding(read.owner, playbackContext, poolBinding) }
                    if (poolBinding != null) context.poolTokens += token
                    check(binding.owner == read.owner && binding.context.identityKey == playbackContext.identityKey) { "Native source identity changed" }
                    // Metadata may arrive after this stream. Enrich the stable binding, never replace its
                    // admission identity or revoke a resolver that already captured that exact object.
                    if (detail != null) binding.context = playbackContext
                    source.copy(nativePlaybackToken = token)
                }) }
            }
            val authorization = context.poolAdmission()
            synchronized(this@NativeCatalogRepository) {
                context.latestGroups = bound
                context.indexerResult = direct
                if (context.poolResult?.isRetired(context.poolTarget) == false) {
                    sourcePublications[context.sourcePublicationId] = java.lang.ref.WeakReference(context)
                }
                val target = context.poolTarget
                val sourceIndex = sourceIndexSource
                if (target != null && authorization != null && sourceIndex != null && rawGroups.isNotEmpty()) {
                    context.hoardPending = com.vortx.android.singularity.SourceIndexClient.descriptors(rawGroups)
                    if (context.hoardJob?.isActive != true) {
                        val nextWorker = sourceIndex.launch(start = CoroutineStart.LAZY) {
                            val worker = currentCoroutineContext()[Job]
                            while (authorization.isCurrent()) {
                                val descriptors = synchronized(this@NativeCatalogRepository) {
                                    if (context.hoardPending.isEmpty()) {
                                        // Release the worker slot with the empty decision, before Job completion.
                                        if (context.hoardJob === worker) context.hoardJob = null
                                        null
                                    } else context.hoardPending.also { context.hoardPending = emptyList() }
                                }
                                if (descriptors == null) break
                                sourceIndex.hoard(target, descriptors, authorization)
                            }
                        }
                        // Install ownership before IO can finish the worker body or release its slot.
                        context.hoardJob = nextWorker
                        nextWorker.start()
                    }
                }
            }
            StreamLoadUpdate(bound, update.settled, update.total, terminal,
                selectionReady = terminal || indexerFinished && bound.any { it.streams.isNotEmpty() } &&
                    update.resourceSettled(VortxResourceRequest.Resource.STREAM, addons.size),
                sourcePublicationId = context.sourcePublicationId)
        }
        try { coroutineScope {
            val events = Channel<StreamEvent>(capacity = 1)
            val coordinatorScope = this
            var indexerJob: Job? = null
            var poolStarted = false
            var poolFinished = context.poolAdmission() == null
            context.poolRevoked = { coordinatorScope.launch { runCatching { events.send(StreamEvent.PoolRevoked) } } }
            val ownerWatcher = launch {
                session.updates.first { !session.accepts(read.owner) || sessionProvider() !== session }
                error("Native account changed")
            }
            val providers = launch {
                session.loadProviders(slot, read.owner, legs) { update, ticket ->
                    synchronized(this@NativeCatalogRepository) {
                        check(!context.closed) { "Native source consumer closed" }
                        context.ticket = ticket
                    }
                    val accepted = CompletableDeferred<Unit>()
                    events.send(StreamEvent.Providers(update, ticket, accepted))
                    // Backpressure prevents provider receipts from outrunning this coordinator.
                    accepted.await()
                }
                events.send(StreamEvent.ProvidersFinished)
            }
            try {
                while (!providersFinished || !indexerFinished || !poolFinished) {
                    val event = events.receive()
                    when (event) {
                        is StreamEvent.Providers -> {
                            lastUpdate = event.update; lastTicket = event.ticket
                            val snapshot = publish(lastUpdate, event.ticket, terminal = false)
                            if (!indexerStarted && indexerScope != null) approvedSearch?.let { search ->
                                indexerStarted = true
                                indexerJob = launch {
                                    val result = try { Result.success(nzbSourceAggregator!!.aggregate(search, indexerScope)) }
                                    catch (cancelled: CancellationException) {
                                        // Caller/owner retirement already cancels the coordinator. A
                                        // contributor's own cancellation must reach it too, not strand
                                        // the request forever waiting for an unreported completion.
                                        currentCoroutineContext().ensureActive()
                                        Result.failure(cancelled)
                                    }
                                    catch (_: Exception) { Result.success(NzbSourceAggregation.empty()) }
                                    events.send(StreamEvent.Indexer(result))
                                }
                            }
                            if (!poolStarted && !poolFinished) context.poolTarget?.let { target ->
                                val authorization = context.poolAdmission()
                                if (authorization == null) poolFinished = true else {
                                    poolStarted = true
                                    context.poolJob = launch {
                                        val result = try { sourceIndexSource?.load(target, authorization) }
                                        catch (cancelled: CancellationException) {
                                            currentCoroutineContext().ensureActive()
                                            null
                                        } catch (_: Exception) { null }
                                        events.send(StreamEvent.Pool(result))
                                    }
                                }
                            }
                            snapshot?.let { emit(it) }
                            event.accepted.complete(Unit)
                        }
                        is StreamEvent.Indexer -> { direct = event.result.getOrThrow(); indexerFinished = true }
                        is StreamEvent.Pool -> {
                            context.poolResult = event.result?.takeIf { it.isCurrent(context.poolTarget) }
                            poolFinished = true
                        }
                        StreamEvent.PoolRevoked -> { context.poolResult = null; poolFinished = true }
                        StreamEvent.ProvidersFinished -> {
                            providersFinished = true
                            // No current approved metadata: suppress, rather than retarget, the query.
                            if (!indexerStarted) indexerFinished = true
                            if (!poolStarted) poolFinished = true
                        }
                    }
                    if (event !is StreamEvent.Providers) {
                        // A provider may have advanced its receipt just before sending its event.
                        // Defer that one partial; the queued callback will publish the retained direct
                        // result with the newer receipt. Slot/owner replacement still throws.
                        lastTicket?.let { ticket ->
                            publish(lastUpdate, ticket, providersFinished && indexerFinished && poolFinished)?.let { emit(it) }
                        }
                    }
                }
            } finally {
                providers.cancel(); indexerJob?.cancel(); ownerWatcher.cancel(); events.cancel()
                context.poolJob?.cancel()
                context.poolRevoked = null
            }
        } } finally {
            context.retireTicket()
            if (!initializedBindings) context.retirePool()
        }
    }.flowOn(Dispatchers.IO)
    suspend fun subtitles(type: MediaType, videoID: String, extra: List<Pair<String, String>> = emptyList()): Result<String> = attempt {
        val session = session(); val read = session.read(); val addons = registry(read)
        if (parental(read)) check(synchronized(this) { detailCache.values.any { (owner, meta) -> owner == read.owner && meta.type == type &&
            (meta.id == videoID || meta.videos.any { it.id == videoID }) } }) { "Approved native metadata required for subtitles" }
        val page = session.load("subtitles", read.owner, listOf(VortxResourceRequest(VortxResourceRequest.Resource.SUBTITLES, type.id, videoID, extra) to addons)).single()
        requireSettled(page)
        session.publish("subtitles", read.owner, listOf(page)) { VortxResourceProjection.subtitles(page, addons) }
    }
    private fun requireSettled(page: VortxResourceSnapshot) {
        // Empty registry is a legitimate empty account; failed requested providers are never empty success.
        check(page.groups.isEmpty() || page.groups.any { it.status == "ready" }) { "Native resources unavailable" }
    }
    private fun requireAnySettled(pages: List<VortxResourceSnapshot>) {
        val groups = pages.flatMap { it.groups }
        check(groups.isEmpty() || groups.any { it.status == "ready" }) { "Native resources unavailable" }
    }
    private fun decorate(detail: MetaDetail, read: VortxNativeRead): MetaDetail {
        val saved = savedItems(read).any { it.id == detail.id && it.type == detail.type }
        val playback = playback(read)
        val watched = playback.getJSONObject("watchedVideoIdsByTitle").optJSONArray(detail.id)?.strings()?.toSet().orEmpty()
        val resume = playback.getJSONArray("continueWatching").objects().find { it.getString("metaId") == detail.id }
        return detail.copy(watchedVideoIds = watched, libraryItem = LibraryItemInfo(detail.id, !saved, !saved,
            resume?.optStringOrNull("videoId"), resume?.getLong("offsetMs") ?: 0, resume?.getLong("durationMs") ?: 0,
            playback.getJSONObject("watchedTitles").optInt(detail.id, 0)))
    }

    override suspend fun library(requestJson: String?): Result<LibraryResult> = attempt {
        val session = session(); val read = session.read()
        val request = requestJson?.let(::JSONObject) ?: JSONObject().put("type", "all").put("sort", "recent")
        val type = request.getString("type"); val sort = request.getString("sort")
        require(sort in setOf("recent", "name"))
        // Saved titles, then every title watched or started that the viewer has not removed (twin of Apple).
        val saved = savedItems(read)
        val records = read.state.optJSONObject("nativeSync")?.optJSONObject("libraries")
            ?.optJSONObject(read.owner.profileID)?.optJSONObject("records")
        val watched = NativePreviouslyWatched.titles(playback(read), saved.map { it.id }.toSet()) { kind, id ->
            records?.optJSONObject("$kind:$id")?.optLong("removedAt", 0)
        }
        val all = visibleLocal(saved + watched, read); var items = all.filter { type == "all" || it.type.id == type }
        if (sort == "name") items = items.sortedBy { it.name.lowercase() }
        fun wire(t: String = type, s: String = sort) = JSONObject().put("type", t).put("sort", s).toString()
        session.owned(read.owner) { LibraryResult(items, LibraryFilters(
            types = (listOf("all") + all.map { it.type.id }.distinct()).map { LibraryTypeOption(it, it == type, wire(t = it)) },
            sorts = listOf("recent", "name").map { LibrarySortOption(it, it == sort, wire(s = it)) }), owner = owner(read.owner)) }
    }
    override suspend fun libraryPortableItems(now: String): Result<List<LibraryPortability.Item>> = attempt {
        val session = session(); val read = session.read()
        session.owned(read.owner) { savedItems(read).map { item ->
            val detail = decorate(MetaDetail(item.id, item.type, item.name), read)
            val progress = requireNotNull(detail.libraryItem)
            LibraryPortability.Item(item.id, item.type.id, item.name, item.poster, progress.videoId,
                progress.timeOffsetMs.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(), progress.durationMs.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(), now, detail.watchedVideoIds.toList())
        } }
    }
    private fun addAction(item: MetaItem, read: VortxNativeRead): JSONObject {
        val cached = synchronized(this) { detailCache[item.type to item.id]?.takeIf { it.first == read.owner }?.second }
        return action("add_library_item").put("profileId", read.owner.profileID)
            .put("item", nativeLibraryItemPayload(item, cached))
    }
    override suspend fun addToLibrary(item: MetaItem) = attempt { val session = session(); val read = session.read(); session.dispatch(listOf(addAction(item, read)), read.owner); Unit }
    // A dispatch returns only after the checkpoint committed, so each mirror below follows a persisted change.
    override suspend fun saveToLibrary(item: MetaItem) = addToLibrary(item).onSuccess { mirrorLibrary(true, item.type, item.id) }
    override suspend fun removeFromLibrary(id: String) = attempt {
        DiagnosticsLog.log("library", "action=remove_saved surface=library")
        val session = session(); val read = session.read(); val saved = savedItems(read).filter { it.id == id }
        if (saved.isEmpty()) {
            // Watched-only Library title (twin of Apple): record the removal under its watch type. It was never
            // saved, so no watchlist was written for it and none is edited.
            val kind = checkNotNull(NativePreviouslyWatched.type(playback(read), id)) { "Unknown native library title" }
            session.dispatch(listOf(action("remove_library_item").put("profileId", read.owner.profileID).put("key", "$kind:$id")), read.owner)
        } else {
            val item = saved.single()
            session.dispatch(listOf(action("remove_library_item").put("profileId", read.owner.profileID).put("key", "${item.type.id}:$id")), read.owner)
            mirrorLibrary(false, item.type, id)
        }
        Unit
    }
    override suspend fun addToLibrary(type: MediaType, id: String, name: String, poster: String?): Result<MetaDetail> = attempt {
        addToLibrary(MetaItem(id, type, name, poster)).getOrThrow(); peekMeta(type, id) ?: meta(type, id).getOrThrow()
    }
    override suspend fun saveToLibrary(type: MediaType, id: String, name: String, poster: String?): Result<MetaDetail> = attempt {
        saveToLibrary(MetaItem(id, type, name, poster)).getOrThrow(); peekMeta(type, id) ?: meta(type, id).getOrThrow()
    }
    override suspend fun removeFromLibrary(type: MediaType, id: String): Result<MetaDetail> = attempt {
        DiagnosticsLog.log("library", "action=remove_saved surface=detail")
        val session = session(); val read = session.read()
        session.dispatch(listOf(action("remove_library_item").put("profileId", read.owner.profileID).put("key", "${type.id}:$id")), read.owner)
        mirrorLibrary(false, type, id)
        peekMeta(type, id) ?: meta(type, id).getOrThrow()
    }
    private fun requireWatchIdentity(read: VortxNativeRead, type: MediaType, id: String) {
        require(type == MediaType.MOVIE || type == MediaType.SERIES) { "Native progress supports movies and series only" }
        check(savedItems(read).none { it.id == id && it.type != type }) { "Ambiguous native watch media identity" }
    }
    override suspend fun removeFromContinueWatching(target: ContinueWatchingDismissal) = attempt {
        DiagnosticsLog.log("library", "action=dismiss_continue_watching surface=menu")
        val session = session(); val read = session.read(); check(owner(read.owner) == target.owner)
        requireWatchIdentity(read, target.type, target.id)
        session.dispatch(listOf(action("remove_from_continue_watching").put("metaId", target.id)), read.owner); Unit
    }
    override suspend fun setCatalogWatched(item: MetaItem, isWatched: Boolean) = attempt {
        val session = session(); val read = session.read(); requireWatchIdentity(read, item.type, item.id)
        if (item.type == MediaType.SERIES) {
            mutateWatchInventory(session, read, item.type, item.id, isWatched) { it.videos.map(Episode::id) }
        } else dispatchWatched(session, read, MetaDetail(item.id, item.type, item.name, poster = item.poster), null, isWatched)
        Unit
    }
    override suspend fun setWatched(type: MediaType, id: String, isWatched: Boolean): Result<MetaDetail> = attempt {
        val session = session(); val read = session.read(); requireWatchIdentity(read, type, id)
        mutateWatchInventory(session, read, type, id, isWatched) { if (type == MediaType.SERIES) it.videos.map(Episode::id) else null }
    }
    override suspend fun setVideoWatched(type: MediaType, id: String, videoId: String, season: Int?, episode: Int?, isWatched: Boolean): Result<MetaDetail> = attempt {
        val session = session(); val read = session.read(); requireWatchIdentity(read, type, id)
        mutateWatchInventory(session, read, type, id, isWatched) { detail ->
            if (type == MediaType.MOVIE) {
                require(videoId == id && season == null && episode == null) { "Exact movie identity required" }; null
            } else {
                val selected = requireNotNull(detail.videos.singleOrNull { it.id == videoId }) { "Video is not in the returned inventory" }
                require((season == null || season == selected.season) && (episode == null || episode == selected.episode)) { "Episode identity mismatch" }
                listOf(selected.id)
            }
        }
    }
    override suspend fun setSeasonWatched(type: MediaType, id: String, season: Int, isWatched: Boolean): Result<MetaDetail> = attempt {
        require(type == MediaType.SERIES && season >= 0) { "A series season is required" }
        val session = session(); val read = session.read(); requireWatchIdentity(read, type, id)
        mutateWatchInventory(session, read, type, id, isWatched) { detail ->
            detail.videos.filter { it.season == season }.map(Episode::id).also { require(it.isNotEmpty()) { "Exact season inventory required" } }
        }
    }

    private suspend fun mutateWatchInventory(session: VortxNativeSession, read: VortxNativeRead, type: MediaType, id: String,
                                            watched: Boolean, select: (MetaDetail) -> List<String>?): MetaDetail {
        // An isolated consumer never cancels/replaces the screen's visible meta or stream load.
        val slot = "watch-mutation"; val addons = registry(read)
        val page = session.load(slot, read.owner, listOf(VortxResourceRequest(VortxResourceRequest.Resource.META, type.id, id) to addons)).single()
        requireSettled(page)
        val approved = policyPage(page, read, slot, listOf(page))
        val raw = requireNotNull(approved.groups.firstNotNullOfOrNull { it.items(VortxResourceRequest.Resource.META).firstOrNull() }) {
            "Authoritative watch metadata unavailable or blocked"
        }
        require(raw.getString("id") == id && raw.getString("type") == type.id) { "Watch metadata identity mismatch" }
        if (type == MediaType.SERIES) {
            val videos = raw.getJSONArray("videos").objects()
            require(videos.isNotEmpty() && videos.size <= 10_000 && videos.map { it.getString("id") }.distinct().size == videos.size) { "Complete unambiguous returned inventory required" }
            videos.forEach { video ->
                require(video.getString("id").isNotBlank() && video.getString("id") != id)
                for (key in listOf("season", "episode")) {
                    val value = video.get(key)
                    require(value is Number && java.math.BigDecimal(value.toString()).let { it.signum() >= 0 && it <= java.math.BigDecimal(Int.MAX_VALUE) && it.stripTrailingZeros().scale() <= 0 }) {
                        "Exact episode coordinates required"
                    }
                }
            }
        }
        val detail = requireNotNull(EngineState.parseMetaDetail(VortxResourceProjection.metaDetails(approved, null, null, addons), appliedAddonOrder = emptyList()))
        val videos = select(detail)
        return session.publish(slot, read.owner, listOf(page)) {
            dispatchWatched(session, read, detail, videos, watched)
            decorate(detail, session.read())
        }
    }
    private fun dispatchWatched(session: VortxNativeSession, read: VortxNativeRead, detail: MetaDetail, videos: List<String>?, watched: Boolean) {
        require(videos == null || videos.isNotEmpty())
        val actions = (videos?.map { it as String? } ?: listOf(null)).map { video ->
            action(if (watched) "mark_watched" else "reset_watched").put("metaId", detail.id).put("videoId", video)
                .put("name", detail.name.takeIf { it.isNotBlank() }).put("metadata", JSONObject().put("type", detail.type.id).put("poster", detail.poster))
        }
        session.dispatch(actions, read.owner, verifyCandidate = { candidate ->
            val proof = JSONObject(candidate.resolve(JSONObject().put("kind", "profile_playback").put("profileId", read.owner.profileID).toString()))
            check(proof.getString("kind") == "profile_playback") { "Native watched receipt unavailable" }
            if (videos == null) check((proof.getJSONObject("watchedTitles").optInt(detail.id) > 0) == watched) { "Native watched receipt mismatch" }
            else {
                val marked = proof.getJSONObject("watchedVideoIdsByTitle").optJSONArray(detail.id)?.strings().orEmpty().toSet()
                check(videos.all { (it in marked) == watched }) { "Native episode batch receipt mismatch" }
            }
        })
    }

    private fun installedAddonRows(read: VortxNativeRead): List<InstalledAddon> {
        val disabled = NativeAddonPreferences.disabled(read)
        val ctx = JSONObject().put("profile", JSONObject().put("addons", JSONArray(addonDescriptors(read))))
        return EngineState.parseInstalledAddons(ctx.toString()).map { it.copy(isDisabled = AddonOrder.normalize(it.transportUrl) in disabled) }
    }
    override suspend fun installedAddons() = attempt {
        val session = session()
        session.withCurrentRead { installedAddonRows(it) }
    }
    private class AddonManagementOwner(
        val issuer: NativeCatalogRepository,
        val session: VortxNativeSession,
        val owner: VortxNativeOwner,
        val update: Long,
    )
    /** Called only while the captured Session is held. A successful local mutation may issue its
     * own successor here, but a caller cannot replace the original token with a fresh active owner. */
    private fun addonManagementSnapshot(session: VortxNativeSession, read: VortxNativeRead): AddonManagementSnapshot {
        val update = session.updates.value
        val authority = AddonManagementOwner(this, session, read.owner, update)
        val publication: (() -> Unit) -> Boolean = if (captureAddonPublication != null) {
            captureAddonPublication.invoke(session, update) ?: { _ -> false }
        } else { action ->
            // Deterministic repository fixtures have no account host. Production always injects the
            // same authenticated/mounted publication admission used by native profile metadata.
            if (runCatching { sessionProvider() === session }.getOrDefault(false) && session.updates.value == update) {
                action(); true
            } else false
        }
        return AddonManagementSnapshot(installedAddonRows(read), authority, publication)
    }
    override suspend fun addonManagementSnapshot() = attempt {
        val session = session()
        session.withCurrentRead { read -> addonManagementSnapshot(session, read) }
    }
    override suspend fun setAddonVisibility(snapshot: AddonManagementSnapshot, addon: InstalledAddon, disabled: Boolean) =
        attempt(addonVisibilityDispatcher) {
            val authority = snapshot.visibilityOwner as? AddonManagementOwner
            check(authority != null && authority.issuer === this) { "Add-on management owner expired" }
            val session = authority.session
            check(sessionProvider() === session) { "Native account changed" }
            session.withCurrentRead { read ->
                check(read.owner == authority.owner && session.updates.value == authority.update) { "Add-on management owner changed" }
                var successor: AddonManagementSnapshot? = null
                // Session -> original authenticated account -> original mounted lifecycle. Retirement
                // cannot clear/replace the mount between row validation and the durable checkpoint.
                // The existing descriptor helper also stays inside this original mounted admission.
                check(snapshot.publishIfCurrent {
                    check(snapshot.addons.singleOrNull { it.transportUrl == addon.transportUrl } == addon &&
                        installedAddonRows(read).singleOrNull { it.transportUrl == addon.transportUrl } == addon) {
                        "Add-on changed; reload installed add-ons"
                    }
                    check(!addon.isProtected || !disabled) { "Protected add-ons cannot be turned off" }
                    applyAddonDisabled(session, read, addon.transportUrl, disabled)
                    val acknowledged = session.read()
                    check(acknowledged.owner.scope == authority.owner.scope && acknowledged.owner.profileID == authority.owner.profileID &&
                        installedAddonRows(acknowledged).single { it.transportUrl == addon.transportUrl }.isDisabled == disabled) {
                        "Add-on visibility was not acknowledged"
                    }
                    successor = addonManagementSnapshot(session, acknowledged)
                }) { "Native add-on account changed before commit" }
                checkNotNull(successor)
            }
        }
    override fun normalizedAddonUrl(raw: String): String? = runCatching {
        val uri = URI(raw.trim()); require(uri.scheme in setOf("https", "http") && !uri.host.isNullOrEmpty() && uri.userInfo == null && uri.fragment == null && uri.query == null)
        val path = uri.rawPath.trimEnd('/').let { if (it.endsWith("/manifest.json")) it else "$it/manifest.json" }
        URI("${uri.scheme.lowercase()}://${uri.rawAuthority.lowercase()}$path").toASCIIString()
    }.getOrNull()
    override suspend fun installAddon(url: String) = attempt {
        val session = session(); val read = session.read(); val normalized = requireNotNull(normalizedAddonUrl(url))
        check(addonOwner(read) == read.owner.profileID) { "Shared profiles customize visibility; install add-ons from the owner profile" }
        val addon = VortxResourceAddon.fromTransportUrl(normalized)
        val response = session.load("install", read.owner, listOf(VortxResourceRequest(VortxResourceRequest.Resource.MANIFEST, "", "") to listOf(addon))).single()
        requireSettled(response)
        val manifest = response.groups.single().items(VortxResourceRequest.Resource.MANIFEST).single()
        session.publish("install", read.owner, listOf(response)) {
            session.dispatch(listOf(action("install_addon").put("profileId", addonOwner(read)).put("addon", JSONObject().put("transportUrl", normalized)
                .put("manifest", manifest).put("flags", JSONObject().put("official", false).put("protected", false)))), read.owner)
        }; Unit
    }
    override suspend fun removeAddon(addon: InstalledAddon) = attempt {
        val session = session(); val read = session.read()
        check(addonOwner(read) == read.owner.profileID) { "Shared profiles customize visibility; remove add-ons from the owner profile" }
        session.dispatch(listOf(action("remove_addon").put("profileId", addonOwner(read)).put("transportUrl", addon.transportUrl)), read.owner); Unit
    }
    override suspend fun changeAddonUrl(oldAddon: InstalledAddon, newUrl: String) = attempt {
        val session = session(); val read = session.read(); val bucket = addonOwner(read)
        check(bucket == read.owner.profileID) { "Shared profiles cannot replace account add-ons" }
        val before = addonDescriptors(read)
        val oldKey = AddonOrder.normalize(oldAddon.transportUrl)
        val current = requireNotNull(before.singleOrNull { AddonOrder.normalize(it.getString("transportUrl")) == oldKey }) { "Add-on no longer installed" }
        check(NativeHostPreferences.equal(current, JSONObject(oldAddon.rawDescriptorJson))) { "Add-on descriptor changed; reload installed add-ons" }
        val flags = current.getJSONObject("flags")
        check(!flags.getBoolean("protected") && !flags.getBoolean("official")) { "Protected or official add-ons cannot change endpoint" }
        val target = requireNotNull(normalizedAddonUrl(newUrl)) { "Unsupported add-on endpoint" }
        val targetKey = AddonOrder.normalize(target)
        require(targetKey == oldKey || before.none { AddonOrder.normalize(it.getString("transportUrl")) == targetKey }) { "Replacement endpoint is already installed" }
        val response = session.load("addon-replacement", read.owner,
            listOf(VortxResourceRequest(VortxResourceRequest.Resource.MANIFEST, "", "") to listOf(VortxResourceAddon.fromTransportUrl(target)))).single()
        requireSettled(response)
        val manifest = response.groups.single().items(VortxResourceRequest.Resource.MANIFEST).single()
        require(listOf("id", "name", "version").all { manifest.get(it) is String && manifest.getString(it).isNotBlank() }) { "Invalid replacement manifest" }
        require(listOf("types", "resources", "catalogs").all { manifest.get(it) is JSONArray }) { "Incomplete replacement manifest" }
        require(!manifest.optJSONObject("behaviorHints").let { it?.optBoolean("configurationRequired", false) ?: false }) { "Replacement add-on requires configuration" }
        val replacement = JSONObject(current.toString()).put("transportUrl", target).put("manifest", manifest)
        val order = before.map { if (AddonOrder.normalize(it.getString("transportUrl")) == oldKey) target else it.getString("transportUrl") }
        val host = NativeAddonPreferences.replacingHost(read, bucket, oldKey, targetKey)
        val actions = mutableListOf<JSONObject>()
        // A same-member spelling change must remove the previous value before installing its new
        // descriptor, otherwise the membership register may retain the old spelling on equal clocks.
        if (targetKey == oldKey) actions += action("remove_addon").put("profileId", bucket).put("transportUrl", current.getString("transportUrl"))
        actions += action("install_addon").put("profileId", bucket).put("addon", replacement)
        if (targetKey != oldKey) actions += action("remove_addon").put("profileId", bucket).put("transportUrl", current.getString("transportUrl"))
        actions += action("reorder_addons").put("profileId", bucket).put("transportUrls", JSONArray(order))
        val profiles = read.state.getJSONObject("roster").getJSONObject("profiles")
        profiles.keys().forEach { id ->
            val profile = profiles.getJSONObject(id)
            if (!profile.getBoolean("deleted") && (id == bucket || profile.getString("addons") == "share_primary" && bucket == read.owner.scope.ownerProfileID)) {
                val disabled = profile.getJSONObject("settings").getJSONArray("disabledAddons").strings()
                if (disabled.any { AddonOrder.normalize(it) == oldKey }) actions += action("patch_profile").put("id", id).put("edits", JSONArray().put(
                    JSONObject().put("field", "disabledAddons").put("value", JSONArray(disabled.map { if (AddonOrder.normalize(it) == oldKey) targetKey else it }.distinct()))))
            }
        }
        session.publish("addon-replacement", read.owner, listOf(response)) {
            session.dispatch(actions, read.owner, host, verifyCandidate = { candidate ->
                val query = JSONObject(candidate.resolve(JSONObject().put("kind", "installed_addons").put("profileId", bucket).toString()))
                check(query.getString("kind") == "installed_addons") { "Native replacement receipt unavailable" }
                val installed = query.getJSONArray("addons").objects()
                check(installed.map { AddonOrder.normalize(it.getString("transportUrl")) } == order.map(AddonOrder::normalize)) { "Native replacement order mismatch" }
                val accepted = installed.single { AddonOrder.normalize(it.getString("transportUrl")) == targetKey }
                check(accepted.getString("transportUrl") == target && NativeHostPreferences.equal(accepted.getJSONObject("flags"), flags) &&
                    listOf("id", "name", "version").all { accepted.getJSONObject("manifest").getString(it) == manifest.getString(it) }) { "Native replacement descriptor mismatch" }
                before.filterNot { AddonOrder.normalize(it.getString("transportUrl")) == oldKey }.forEach { unchanged ->
                    check(installed.any { NativeHostPreferences.equal(it, unchanged) }) { "Unrelated add-on changed during replacement" }
                }
            })
        }; Unit
    }
    override suspend fun setAddonDisabled(transportUrl: String, disabled: Boolean) = attempt {
        val session = session()
        session.withCurrentRead { read -> applyAddonDisabled(session, read, transportUrl, disabled) }
    }
    private fun applyAddonDisabled(session: VortxNativeSession, read: VortxNativeRead, transportUrl: String, disabled: Boolean) {
        val values = NativeAddonPreferences.disabled(read).toMutableSet()
        if (disabled) values.add(AddonOrder.normalize(transportUrl)) else values.remove(AddonOrder.normalize(transportUrl))
        val host = read.state.getJSONObject("hostProfilePreferences")
        val raw = host.optJSONObject(read.owner.profileID) ?: NativeProfileAccess.projection(read).profiles.single { it.id == read.owner.profileID }.encode()
        val prefs = raw.optJSONObject("addonPreferences") ?: JSONObject().also { raw.put("addonPreferences", it) }
        prefs.put("disabledAddonURLsOverride", JSONArray(values.toList()))
        raw.put("disabledAddons", JSONArray(values.toList()))
        host.put(read.owner.profileID, raw).put("modifiedSeconds", maxOf(System.currentTimeMillis() / 1000.0, host.optDouble("modifiedSeconds", 0.0) + 0.001))
        session.dispatch(listOf(action("patch_profile").put("id", read.owner.profileID).put("edits", JSONArray().put(JSONObject().put("field", "disabledAddons").put("value", JSONArray(values.toList()))))), read.owner, host)
    }
    override suspend fun applyAddonOrder(transportUrls: List<String>) = attempt {
        val session = session(); val read = session.read()
        val shared = read.owner.profileID != addonOwner(read)
        val actions = if (shared) emptyList() else listOf(action("reorder_addons").put("profileId", addonOwner(read)).put("transportUrls", JSONArray(transportUrls)))
        session.dispatch(actions, read.owner, NativeAddonPreferences.reorderedHost(read, transportUrls, shared)); Unit
    }
    suspend fun profiles(): Result<String> = attempt { session().read().state.getJSONObject("roster").toString() }
    fun watchStatsSnapshot(): NativeWatchStatsSnapshot {
        val session = session(); val read = session.read()
        return session.owned(read.owner) {
            val genres = synchronized(this) { detailCache.values.filter { it.first == read.owner }.associate { it.second.id to it.second.genres } }
            val records = NativeWatchStatsProjection.records(library(read))
            val allowed = if (parental(read)) visibleLocal(records.map { MetaItem(it.id, MediaType.fromId(it.type), it.name) }, read).map { it.id }.toSet() else null
            NativeWatchStatsSnapshot(read.owner, records.filter { allowed == null || it.id in allowed }, genres)
        }
    }
    fun <T> withWatchStatsSnapshot(snapshot: NativeWatchStatsSnapshot, publish: () -> T): T = session().owned(snapshot.owner, publish)
    suspend fun addProfile(id: String, name: String) = attempt { session().dispatch(listOf(action("add_profile").put("id", id).put("name", name))); Unit }
    suspend fun switchProfile(id: String) = attempt {
        val session = session(); val read = session.read(); val target = read.state.getJSONObject("roster").getJSONObject("profiles").getJSONObject(id)
        if (target.optStringOrNull("pin") != null) unsupported("PIN verification")
        session.dispatch(listOf(action("switch_profile").put("id", id)), read.owner); Unit
    }
    suspend fun deleteProfile(id: String) = attempt { session().dispatch(listOf(action("delete_profile").put("id", id))); Unit }
    suspend fun renameProfile(id: String, name: String) = attempt {
        session().dispatch(listOf(action("patch_profile").put("id", id).put("edits", JSONArray().put(JSONObject().put("field", "name").put("value", name))))); Unit
    }
    suspend fun mergeNativeSync(document: String) = attempt { session().dispatch(listOf(action("merge_native_sync").put("document", JSONObject(document)))); Unit }

    override suspend fun beginPlaybackSession(context: PlaybackContext?, ownerToken: ContinueWatchingOwner?) = attempt {
        val session = session(); val read = session.read()
        val captured = context ?: return@attempt PlaybackSessionToken.NOOP
        check(ownerToken == owner(read.owner) && captured.owner.profileId == read.owner.profileID && captured.owner.usesEngineHistory)
        check(captured.nativeSessionRevision == null || captured.nativeSessionRevision == read.owner.revision) { "Native playback owner expired" }
        require(captured.type in setOf("movie", "series"))
        requireWatchIdentity(read, MediaType.fromId(captured.type), captured.contentId)
        require(nativePlaybackIdentityCanRecord(captured)) { "Exact native episode identity required for playback history" }
        if (parental(read)) check(synchronized(this) {
            detailCache[MediaType.fromId(captured.type) to captured.contentId]?.let { (cachedOwner, detail) ->
                cachedOwner == read.owner && (captured.videoId == detail.id || detail.videos.any { it.id == captured.videoId })
            } == true
        }) { "Approved native metadata required for playback" }
        session.owned(read.owner) { synchronized(this) {
            PlaybackSessionToken(playbackSequence.incrementAndGet()).also { playing = Playing(it, read.owner, captured) }
        } }
    }
    private fun progress(sessionToken: PlaybackSessionToken, positionMs: Long, durationMs: Long) {
        val session = session(); val current = synchronized(this) { playing } ?: return
        if (current.token != sessionToken) return
        if (!nativePlaybackIdentityCanRecord(current.context)) return
        require(positionMs >= 0 && durationMs >= 0)
        session.owned(current.owner) {
            synchronized(this) {
                if (playing !== current) return@owned
                session.dispatch(listOf(action("report_progress").put("metaId", current.context.contentId).put("videoId", current.context.videoId)
                    .put("name", current.context.title).put("positionMs", positionMs).put("durationMs", durationMs)
                    .put("metadata", JSONObject().put("type", current.context.type).put("poster", current.context.poster))), current.owner,
                    // A periodic tick: its account upload may wait for playback to go quiet. The final report at
                    // the end of playback stays an ordinary edit, so a finish reaches other devices promptly.
                    progressOnly = true)
            }
        }
    }
    override suspend fun reportProgress(session: PlaybackSessionToken, positionMs: Long, durationMs: Long) = attempt { progress(session, positionMs, durationMs) }
    override suspend fun endPlaybackSession(session: PlaybackSessionToken, positionMs: Long, durationMs: Long) =
        endPlaybackSessionWithDurableWatchReceipt(session, positionMs, durationMs).map { Unit }
    private fun watchedStamp(projection: JSONObject, context: PlaybackContext, requireType: Boolean): Long? =
        projection.getJSONArray("history").objects().filter { row ->
            row.getString("metaId") == context.contentId && row.getBoolean("watched") &&
                (!requireType || row.optStringOrNull("type") == context.type) &&
                (row.optStringOrNull("videoId") == context.videoId ||
                    context.type == "movie" && context.videoId == context.contentId && row.optStringOrNull("videoId") == null)
        }.maxOfOrNull { it.getLong("updatedAt") }

    override suspend fun endPlaybackSessionWithDurableWatchReceipt(session: PlaybackSessionToken, positionMs: Long, durationMs: Long): Result<DurableWatchedPlaybackReceipt?> = attempt {
        val nativeSession = this@NativeCatalogRepository.session(); val current = synchronized(this) { playing } ?: return@attempt null
        if (current.token != session) return@attempt null
        if (!nativePlaybackIdentityCanRecord(current.context)) return@attempt null
        require(positionMs >= 0 && durationMs >= 0)
        nativeSession.owned(current.owner) { synchronized(this) {
            if (playing !== current) return@owned null
            val query = JSONObject().put("kind", "profile_playback").put("profileId", current.owner.profileID)
            val prior = watchedStamp(nativeSession.resolve(query, current.owner), current.context, false) ?: 0L
            try {
                nativeSession.dispatch(listOf(action("report_progress").put("metaId", current.context.contentId).put("videoId", current.context.videoId)
                    .put("name", current.context.title).put("positionMs", positionMs).put("durationMs", durationMs)
                    .put("metadata", JSONObject().put("type", current.context.type).put("poster", current.context.poster))), current.owner)
                val committed = nativeSession.resolveCommitted(query, current.owner)
                check(committed.getString("kind") == "profile_playback" && committed.getString("profileId") == current.owner.profileID)
                val stamp = watchedStamp(committed, current.context, true)
                // The kernel alone decides completion. A prior watch plus a partial/zero terminal
                // report is not a new durable finish from this playback session.
                val admission = if (stamp != null && stamp > prior && durationMs > 0L) captureReclaimAdmission?.invoke(nativeSession, current.owner) else null
                if (stamp == null || admission == null) null else {
                    if (durableWatchReceipts.size >= 128) durableWatchReceipts.clear()
                    DurableWatchedPlaybackReceipt(current.context, owner(current.owner)).also {
                        durableWatchReceipts[it] = DurableWatchProof(current.owner, session, stamp, admission)
                    }
                }
            } finally { if (playing === current) playing = null }
        } }
    }
    override fun reclaimAfterDurableWatchedPlaybackReceipt(receipt: DurableWatchedPlaybackReceipt, action: () -> Boolean): Boolean = runCatching { withReclaimLifecycle {
        val session = session()
        val proof = synchronized(this) { durableWatchReceipts[receipt] } ?: return@withReclaimLifecycle false
        session.owned(proof.owner) { synchronized(this) {
            if (durableWatchReceipts[receipt] !== proof || receipt.owner != owner(proof.owner) ||
                receipt.context.owner != PlaybackContext.Owner(proof.owner.profileID, true)) return@owned false
            // Production enters the download lifecycle first, then Session -> auth -> mounted lifecycle.
            // Point-in-time owner checks
            // alone cannot serialize a destructive callback with logout/epoch retirement.
            proof.admit {
                val committed = session.resolveCommitted(JSONObject().put("kind", "profile_playback").put("profileId", proof.owner.profileID), proof.owner)
                if (committed.getString("kind") != "profile_playback" || watchedStamp(committed, receipt.context, true) != proof.watchedAt) false else {
                    // The UI coordinator independently waits for every decoder/lease to release.
                    durableWatchReceipts.remove(receipt)
                    action()
                }
            }
        } }
    } }.getOrDefault(false)
    override suspend fun resolve(source: StreamSource, episode: Episode?): Result<Playable> = resolveAttempt {
        val session = session(); val read = session.read()
        val context = synchronized(this) { foregroundSources }
        val binding = synchronized(this) { context?.bindings?.get(source.nativePlaybackToken) }
        check(binding != null && binding.owner == read.owner) { "Native source selection expired; reload sources" }
        check(binding.pooled == null || binding.pooled.accepts(source, context?.poolTarget)) { "Pooled source admission expired" }
        check(episode == null || episode.id == binding.context.videoId) { "Native episode selection changed" }
        resolveOwned(session, read, source, episode, binding, context).copy(playbackContext = binding.context)
    }
    private suspend fun resolveOwned(session: VortxNativeSession, read: VortxNativeRead, source: StreamSource,
        episode: Episode?, binding: SourceBinding? = null, context: SourceContext? = null,
        sequenceOwner: AtomicLong = resolveSequence): Playable {
        val sequence = sequenceOwner.incrementAndGet()
        val sourceToken = source.nativePlaybackToken
        val resolutionCoroutine = currentCoroutineContext()
        // The resolver may await local preparation. Its retirement probe uses the same captured
        // owner and selection checks as final admission, without capturing a newer session/owner.
        fun requireCurrent() {
            resolutionCoroutine.ensureActive()
            check(sessionProvider() === session && sequenceOwner.get() == sequence) { "Native playback superseded" }
            if (binding != null) synchronized(this) {
                check(context != null && context.isCurrent() && context.bindings[sourceToken] === binding &&
                    (sequenceOwner !== resolveSequence || foregroundSources === context)) { "Native source selection expired" }
            }
            binding?.pooled?.let { pooled ->
                check(pooled.accepts(source, context?.poolTarget)) { "Pooled source admission expired" }
            }
        }
        session.owned(read.owner) { requireCurrent() }
        val playable = try {
            playbackResolver.resolve(source, episode,
                isCurrent = { try { session.owned(read.owner) { requireCurrent(); true } } catch (_: Exception) { false } },
                // A handed-off lease outlives its resolve Job and later source loads/prewarm.
                // Its durable account/profile/binding authority is the exact captured native owner.
                playbackIsCurrent = { try { sessionProvider() === session && session.accepts(read.owner) } catch (_: Exception) { false } })
        } catch (cancelled: CancellationException) {
            // Resolver retirement is a handled stale selection, not cancellation of its caller.
            // A genuinely cancelled caller or a still-current resolver cancellation stays terminal.
            resolutionCoroutine.ensureActive()
            session.owned(read.owner) { requireCurrent() }
            throw cancelled
        }
        try {
            currentCoroutineContext().ensureActive()
            return session.owned(read.owner) {
                requireCurrent()
                if (binding == null) playable else {
                    val resume = session.resolve(JSONObject().put("kind", "resume_point").put("id", binding.context.videoId), read.owner)
                    check(resume.getString("kind") == "resume_point") { "Native resume projection unavailable" }
                    playable.copy(startPositionMs = resume.optJSONObject("resume")?.getLong("offsetMs") ?: 0L)
                }
            }
        } catch (error: Throwable) { runCatching { playable.playbackLease?.close() }; throw error }
    }
    override suspend fun resolveDirectLink(url: String, title: String): Result<Playable> = resolveAttempt {
        val session = session(); val read = session.read()
        check(!parental(read)) { "Uncertified direct links are blocked by parental settings" }
        val source = StreamSource(id = url, addon = "Direct link", title = title, url = url)
        requireNotNull(nativeDirectPlayable(source)) { "Only HTTP(S) direct links are supported" }
        resolveOwned(session, read, source, null)
    }
    override suspend fun resolveMagnet(infoHash: String, title: String, fileIdx: Int?): Result<Playable> = resolveAttempt {
        val session = session(); val read = session.read()
        check(!parental(read)) { "Uncertified magnets are blocked by parental settings" }
        require(Regex("[a-fA-F0-9]{40}").matches(infoHash) && (fileIdx == null || fileIdx >= 0))
        resolveOwned(session, read, StreamSource(id = infoHash, addon = "Magnet", title = title,
            infoHash = infoHash, fileIdx = fileIdx, isTorrent = true), null)
    }
    override suspend fun signIn(email: String, password: String) = attempt<Unit> { unsupported("Stremio authentication") }
    override suspend fun signOut() {
        if (signOutAccount != null) signOutAccount.invoke() else session().close()
        nativeAuth.value = AuthState.SignedOut
    }
}

private fun JSONArray?.objects(): List<JSONObject> = this?.let { array -> (0 until array.length()).map(array::getJSONObject) }.orEmpty()
private fun JSONArray.strings(): List<String> = (0 until length()).map(::getString)
private fun JSONObject.optStringOrNull(key: String): String? = if (isNull(key) || !has(key)) null else getString(key)
