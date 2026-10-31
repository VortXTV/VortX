package com.vortx.android.engine

import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.singularity.SourceIndexClient
import com.vortx.android.singularity.SourceIndexServeSource
import com.vortx.android.sources.ResolvedPin
import com.vortx.android.sources.ProviderHealth
import com.vortx.android.sources.SeriesSourceSticky
import com.vortx.android.sources.SourcePrefsSnapshot
import com.vortx.android.torbox.TorBoxSearchSource
import com.vortx.android.communityjs.CommunityJsProviderSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

data class SourceContributorSettlement(
    val requestGeneration: Long = -1L,
    val settled: Boolean = true,
)

/// Owns a detail screen's source-list ASSEMBLY pipeline off the render path: raw engine stream groups ->
/// merge (TorBox search + media-server groups) -> disabled-add-on subtraction -> direct-links
/// filter -> [StreamRanking], all coalesced and run OFF the caller's thread, publishing ONE immutable ranked
/// [SourceListState] per real change. The Kotlin port of Apple `app/SourcesShared/SourceListModel.swift`.
/// Authorized pool groups arrive inside the repository's raw publication; the legacy source is settlement-only.
///
/// WHY (from Apple): the detail bodies used to re-assemble the whole list on EVERY engine bump (a `revision`
/// storm 6-7x/sec while sources load), saturating the main thread on a 1200+ stream title. This model inverts
/// the flow, exactly like the Apple original:
///
///   1. O(1) EPOCH SIGNATURE: a tuple of the raw/media group hashes plus the TorBox / Singularity source
///      epochs plus one hash of the small ranking inputs. Comparing signatures skips the whole assembly when
///      the published output is already correct.
///   2. 250 ms TRAILING COALESCER: a [conflate] + [kotlinx.coroutines.delay] window over the input flows, so
///      a burst of engine events during source loading produces at most ~4 rebuilds/sec and the LAST event of
///      a burst always lands. It subscribes to the SPECIFIC input flows, never a global "something changed".
///   3. OFF-THREAD ASSEMBLY, PUBLISH ONCE: on a coalesced change it snapshots the immutable inputs, runs the
///      merge + subtraction + rank on [Dispatchers.Default], and publishes ONE [SourceListState] to [state].
///
/// The engine's own [NativeCatalogRepository.streams] already ranks the raw add-on groups, and
/// [com.vortx.android.ui.viewmodel.DetailViewModel] already merges the media-server groups. This model is the
/// unified assembler that folds ALL the lanes (add-on + TorBox + Singularity + media-server) into ONE ranked
/// list through the SAME [StreamRanking] the rest of the app uses, so every lane is ranked together. Wiring it
/// into [com.vortx.android.ui.viewmodel.DetailViewModel] is a follow-up wave; the model is complete + testable
/// standalone here.
///
/// One instance per detail screen. The source-list UI consumes ONLY [state].
class SourceListModel(
    /// The scope the coalescer and off-thread assembly run on. Owned by the caller
    /// (e.g. a ViewModel's scope); [close] stops the coalescer.
    private val scope: CoroutineScope,
    private val coalesceMs: Long = COALESCE_MS,
    private val sourceSticky: SeriesSourceSticky? = null,
) {
    private val _state = MutableStateFlow(SourceListState())

    /// The assembled, filtered, ranked source list, ready to render. Replaced atomically per rebuild.
    val state: StateFlow<SourceListState> = _state.asStateFlow()

    // ---- Inputs (set by the owner as the engine / sources settle) ----

    private val rawGroups = MutableStateFlow<List<StreamGroup>>(emptyList())
    private val mediaServerGroups = MutableStateFlow<List<StreamGroup>>(emptyList())
    private val context = MutableStateFlow(Context())

    private var torbox: TorBoxSearchSource? = null
    private var singularity: SourceIndexServeSource? = null
    private var communityJs: CommunityJsProviderSource? = null
    private var job: Job? = null
    private var publishedSignature: Signature? = null

    /// The view-owned ranking inputs the assembly needs, the Kotlin analogue of Apple's `Context` struct.
    /// [prefs] is the FROZEN [SourcePrefsSnapshot] the off-thread rank reads (never a live store); [contentId]
    /// owns target-scoped TorBox rows. Repository source contexts own pool reads and contributions.
    data class Context(
        val metaId: String = "",
        val streamId: String? = null, // null = all loaded groups (movie); set = one episode's groups
        val requestGeneration: Long = 0L,
        val continuity: String? = null, // remembered quality signature for the best() pick (null for live)
        val binge: String? = null,
        val pin: ResolvedPin? = null,
        val sticky: SeriesSourceSticky.Preference? = null,
        val unhealthyAddons: Set<String> = emptySet(),
        val prefs: SourcePrefsSnapshot = SourcePrefsSnapshot.DEFAULT,
        val directLinksOnly: Boolean = false, // drop unresolved raw torrents, preserve resolved direct links
        val disabledAddons: Set<String> = emptySet(), // per-profile disabled add-on labels
        val contentId: String? = null, // canonical auxiliary target id
    )

    // ---- Binding + input setters ----

    /// Wire the model to its per-screen TorBox + Singularity sources and start the coalesced rebuild pipeline.
    /// Idempotent. Paints once immediately (back-navigation can arrive with streams already resident), then
    /// coalesces subsequent input changes. Mirrors Apple `bind`.
    fun bind(torbox: TorBoxSearchSource, singularity: SourceIndexServeSource) = bind(torbox, singularity, null)

    fun bind(torbox: TorBoxSearchSource, singularity: SourceIndexServeSource, communityJs: CommunityJsProviderSource?) {
        if (job != null) return
        this.torbox = torbox
        this.singularity = singularity
        this.communityJs = communityJs
        job = scope.launch(Dispatchers.Default) {
            rebuild() // immediate first paint
            val baseChanges = combine(
                rawGroups,
                mediaServerGroups,
                context,
                torbox.streams,
                singularity.streams,
            ) { _, _, _, _, _ -> Unit }
            val contributorChanges = communityJs?.let { js -> baseChanges.combine(js.groups) { _, _ -> Unit } } ?: baseChanges
            val settlementChanges = contributorChanges
                .combine(torbox.settlement) { _, _ -> Unit }
                .combine(singularity.settlement) { _, _ -> Unit }
            val allChanges = communityJs?.let { js -> settlementChanges.combine(js.settled) { _, _ -> Unit } } ?: settlementChanges
            allChanges
                .conflate()
                .collect {
                    // Trailing coalesce window: a burst of input changes collapses to the latest, and the
                    // rebuild below always reads the freshest .value of every input.
                    kotlinx.coroutines.delay(coalesceMs)
                    rebuild()
                }
        }
    }

    /// Replace the raw engine stream groups (the ranked add-on lane from [NativeCatalogRepository.streams]).
    fun setRawGroups(groups: List<StreamGroup>) { rawGroups.value = groups }

    /// Replace the media-server direct-play groups (the lane [com.vortx.android.ui.viewmodel.DetailViewModel]
    /// resolves from [com.vortx.android.mediaserver.MediaServerRepository]).
    fun setMediaServerGroups(groups: List<StreamGroup>) { mediaServerGroups.value = groups }

    /// Update the view-owned ranking inputs. Publishes nothing synchronously; only nudges the coalescer.
    /// Mirrors Apple `setContext`.
    fun setContext(ctx: Context) {
        // This method is called by DetailViewModel on Main. Snapshot the preferences here before the background
        // assembly starts, matching Apple's main-actor snapshot and keeping SharedPreferences out of ranking.
        val sticky = if (ctx.streamId != null && ctx.metaId.isNotEmpty()) {
            sourceSticky?.preference(ctx.metaId) ?: ctx.sticky
        } else {
            null
        }
        context.value = ctx.copy(
            sticky = sticky,
            unhealthyAddons = ProviderHealth.activeAddons(),
        )
    }

    /// Stop the coalescer. The TorBox / Singularity sources own their own scopes (close them separately).
    fun close() { job?.cancel() }

    /**
     * Wait until the target's unified list has been assembled after both asynchronous contributor lanes settle.
     * The outer deadline is unconditional; on timeout the freshest target-scoped snapshot is returned, never a
     * previous episode's state. Media-server groups are already awaited before the raw lane is installed.
     */
    suspend fun awaitSettledTarget(
        requestGeneration: Long,
        streamId: String?,
        deadlineMs: Long,
    ): SourceListState? {
        val tb = torbox ?: return null
        val sing = singularity ?: return null
        val js = communityJs
        val jsSettled = js?.settled ?: MutableStateFlow(true)
        val jsEpoch = js?.epoch ?: MutableStateFlow(0)
        val settled = withTimeoutOrNull(deadlineMs) {
            combine(state, tb.settlement, sing.settlement, jsSettled, jsEpoch) { current, torboxState, singularityState, communitySettled, communityEpoch ->
                current.takeIf { sourceAssemblySettledForTarget(it, requestGeneration, streamId,
                    torboxState, singularityState, tb.epoch, sing.epoch, communityEpoch, communitySettled,
                    rawGroups.value.hashCode(), mediaServerGroups.value.hashCode()) }
            }.first { it != null }
        }
        return settled ?: state.value.takeIf {
            it.requestGeneration == requestGeneration && it.streamId == streamId
        }
    }

    // ---- Rebuild (coalesced; assemble off-thread, publish once) ----

    private fun rebuild() {
        val tb = torbox ?: return
        val sing = singularity ?: return
        val js = communityJs
        val ctx = context.value
        val raw = rawGroups.value
        val media = mediaServerGroups.value
        val torboxSnapshot = tb.snapshotFor(ctx.contentId)
        val singularitySnapshot = stableContributorSnapshot(
            readEpoch = { sing.epoch },
            readStreams = { sing.streams.value },
        )
        val jsSnapshot = js?.let { source ->
            stableContributorSnapshot(
                readEpoch = { source.epoch.value },
                readStreams = { source.groups.value },
            )
        } ?: ContributorSnapshot(emptyList<StreamGroup>(), 0)

        val signature = Signature(
            rawHash = raw.hashCode(),
            mediaHash = media.hashCode(),
            torboxEpoch = torboxSnapshot.epoch,
            singularityEpoch = singularitySnapshot.epoch,
            communityJsEpoch = jsSnapshot.epoch,
            inputsHash = inputsHash(ctx),
        )
        if (signature == publishedSignature) return // published output already correct: skip the assembly
        publishedSignature = signature

        // The repository has already attached any authorized pool rows to raw. A second frontend snapshot
        // carries no repository binding authority and must never be merged into the live list.
        val assembled = assemble(raw, torboxSnapshot.streams, emptyList(), jsSnapshot.streams, media, ctx).copy(
            torboxEpoch = torboxSnapshot.epoch,
            singularityEpoch = singularitySnapshot.epoch,
            communityJsEpoch = jsSnapshot.epoch,
            rawGroupsHash = raw.hashCode(),
            mediaServerGroupsHash = media.hashCode(),
        )
        _state.value = assembled
    }

    /// A stable hash of exactly the ranking inputs that move the assembly, mirroring Apple's `Hasher.combine`
    /// fold. Uses [SourcePrefsSnapshot.cacheTag] (a stable string) rather than the snapshot's identity, so an
    /// equal-but-rebuilt preference snapshot does not force a spurious rebuild.
    private fun inputsHash(ctx: Context): Int = listOf(
        ctx.metaId,
        ctx.streamId,
        ctx.requestGeneration,
        ctx.continuity,
        ctx.binge,
        ctx.pin?.let { "${it.scope}:${it.pin.label}:${it.pin.bingeGroup}" },
        ctx.sticky?.addon,
        ctx.sticky?.bingeGroup,
        ctx.unhealthyAddons.sorted().joinToString(","),
        ctx.prefs.cacheTag,
        ctx.directLinksOnly,
        ctx.disabledAddons.sorted().joinToString(","),
        ctx.contentId,
    ).hashCode()

    /// O(1) rebuild signature: input hashes + source epochs. Equal signature = the published output is already
    /// correct, so the whole assembly is skipped. Mirrors Apple's `Signature`.
    private data class Signature(
        val rawHash: Int,
        val mediaHash: Int,
        val torboxEpoch: Int,
        val singularityEpoch: Int,
        val communityJsEpoch: Int,
        val inputsHash: Int,
    )

    internal data class ContributorSnapshot<T>(
        val streams: T,
        val epoch: Int,
    )

    companion object {
        /// The coalescing window. At most ~4 rebuilds/sec while an engine burst streams sources in. Mirrors
        /// Apple's `coalesceMs`.
        const val COALESCE_MS = 250L

        /**
         * Read one contributor's rows and epoch as a coherent publication snapshot. Contributors replace
         * their rows before incrementing the epoch. Without the second epoch read, an interleaving can pair
         * old rows with the new epoch; the signature then suppresses the later rebuild carrying the real rows.
         */
        internal fun <T> stableContributorSnapshot(
            readEpoch: () -> Int,
            readStreams: () -> T,
        ): ContributorSnapshot<T> {
            while (true) {
                val epochBefore = readEpoch()
                val streams = readStreams()
                val epochAfter = readEpoch()
                if (epochBefore == epochAfter) return ContributorSnapshot(streams, epochAfter)
            }
        }

        /// The PURE assembly: subtract disabled add-ons, merge the TorBox + Singularity + media-server lanes in
        /// Apple's order (TorBox first, then Singularity, then media-server groups), apply the direct-links
        /// filter, then rank through the SAME [StreamRanking] the app uses (calling `rankedGroups` / `best` /
        /// `tiers` / `resolutionOptions` as-is). Value types in, value types out, no state. Mirrors the
        /// detached-task body of Apple `SourceListModel.rebuild`.
        fun assemble(
            raw: List<StreamGroup>,
            torboxStreams: List<StreamSource>,
            singularityStreams: List<StreamSource>,
            communityJsGroups: List<StreamGroup>,
            mediaServerGroups: List<StreamGroup>,
            ctx: Context,
        ): SourceListState {
            // Repository-authorized pool groups already travel in raw and remain visible. Contribution
            // eligibility is a separate boundary below, so displaying raw cannot recapture pooled rows.
            var assembled = TorBoxSearchSource.merge(torboxStreams, enabledRawGroups(raw, ctx.disabledAddons))

            // Merge order preserved from Apple's displayGroups: Singularity after raw + TorBox, then the
            // media-server direct-play groups. Final rank order is decided by StreamRanking, not merge order.
            assembled = mergeMediaServer(
                mediaServerGroups,
                CommunityJsProviderSource.merge(
                    SourceIndexServeSource.merge(
                    singularityStreams,
                    assembled,
                    ),
                    communityJsGroups,
                ),
            )

            assembled = directLinkDisplayGroups(assembled, ctx.directLinksOnly)

            // Install the frozen snapshot so tiers()/resolutionOptions() (which read the installed reading) and
            // the explicit-prefs rankedGroups()/best() all rank against the SAME frozen copy, never a live
            // store, mirroring Apple's task-local prefs binding.
            StreamRanking.installReading(ctx.prefs)
            val ranked = StreamRanking.rankedGroups(assembled, prefs = ctx.prefs, pin = ctx.pin)
            val best = StreamRanking.best(
                ranked,
                continuity = ctx.continuity,
                binge = ctx.binge,
                pin = ctx.pin,
                sticky = ctx.sticky,
                providerPenalty = { addon -> addon.trim().lowercase() in ctx.unhealthyAddons },
                prefs = ctx.prefs,
            )
            val tiers = StreamRanking.tiers(ranked)
            val resolutionOptions = StreamRanking.resolutionOptions(ranked)
            return SourceListState(
                groups = ranked,
                best = best,
                tiers = tiers,
                resolutionOptions = resolutionOptions,
                requestGeneration = ctx.requestGeneration,
                streamId = ctx.streamId,
            )
        }

        /**
         * Apply the viewer's direct-links-only display preference without mistaking an already-resolved
         * debrid row for a raw torrent. Some resolvers retain [StreamSource.infoHash] and [StreamSource.isTorrent]
         * as provenance after attaching a direct [StreamSource.url]; those rows are playable direct links and
         * must stay. A media-server row also stays even if malformed upstream metadata set the torrent flag.
         * [StreamSource.externalUrl] is only a hand-off descriptor and cannot make a torrent directly playable.
         * This pure filter is shared by the coalesced assembly and Detail's immediate paint and Smart Source
         * pick, so no pre-coalescer path can publish or rank a forbidden raw torrent.
         */
        fun directLinkDisplayGroups(
            groups: List<StreamGroup>,
            enabled: Boolean,
        ): List<StreamGroup> {
            if (!enabled) return groups
            return groups.mapNotNull { group ->
                val streams = group.streams.filterNot { stream ->
                    val directUrl = stream.url?.trim().orEmpty()
                    val hasDirectUrl =
                        directUrl.startsWith("https://", ignoreCase = true) ||
                            directUrl.startsWith("http://", ignoreCase = true)
                    stream.isTorrent &&
                        !hasDirectUrl &&
                        !stream.isMediaServer
                }
                if (streams.isEmpty()) null else group.copy(streams = streams)
            }
        }

        /// The only groups eligible for contribution: enabled raw add-on results plus TorBox search results.
        /// This is evaluated before any direct-links-only display filter. Repository pool groups are excluded
        /// by their stable base, preserving configured add-on identity even when its label is "Singularity".
        /// The media-server lane has no input here, so private server URLs are structurally ineligible.
        fun contributionGroups(
            raw: List<StreamGroup>,
            torboxStreams: List<StreamSource>,
            disabledAddons: Set<String>,
        ): List<StreamGroup> {
            val enabledRaw = enabledRawGroups(raw, disabledAddons)
                .filterNot { it.base == SourceIndexClient.GROUP_ID }
            return TorBoxSearchSource.merge(torboxStreams, enabledRaw)
        }

        private fun enabledRawGroups(raw: List<StreamGroup>, disabledAddons: Set<String>): List<StreamGroup> {
            if (disabledAddons.isEmpty()) return raw
            val disabled = disabledAddons.map { it.trim().lowercase() }.toSet()
            return raw.filter { it.addon.trim().lowercase() !in disabled }
        }

        /// Extract canonical torrent descriptors from the contribution-only group boundary.
        fun contributionDescriptors(
            raw: List<StreamGroup>,
            torboxStreams: List<StreamSource>,
            disabledAddons: Set<String>,
        ): List<SourceIndexClient.Descriptor> =
            SourceIndexClient.descriptors(contributionGroups(raw, torboxStreams, disabledAddons))

        /// Append the pre-built media-server direct-play groups (one per server), deduped against streams
        /// already present by playable handle so a server copy never duplicates an add-on's identical direct
        /// link. Mirrors Apple `MediaServerSource.merge` (append + handle dedup).
        private fun mergeMediaServer(media: List<StreamGroup>, groups: List<StreamGroup>): List<StreamGroup> {
            if (media.isEmpty()) return groups
            val seen = HashSet<String>()
            for (group in groups) for (s in group.streams) seen.add(handleOf(s))
            val fresh = media.mapNotNull { group ->
                val streams = group.streams.filter { seen.add(handleOf(it)) }
                if (streams.isEmpty()) null else group.copy(streams = streams)
            }
            return if (fresh.isEmpty()) groups else groups + fresh
        }

        /// The playable handle (url / infoHash / nzbUrl before the `#name#desc` suffix the engine encodes into
        /// [StreamSource.id]) used to de-dup a media-server copy against an identical add-on stream.
        private fun handleOf(s: StreamSource): String = s.id.substringBefore('#')
    }
}

/// Process-lifetime contribution dedup keyed by content id plus canonical torrent identity. It marks only the
/// descriptors actually returned to the caller, so a per-run limit cannot strand an unsubmitted tail forever.
/// Capacity is fail-closed: once [maxEntries] is reached, new unique claims stop and existing process-lifetime
/// claims are never evicted. Retained only for pure compatibility fixtures; live repository capture and
/// process-wide client reservations do not use this legacy ledger.
internal class SourceHoardLedger(private val maxEntries: Int = 40_000) {
    private val seen = LinkedHashSet<String>()

    @Synchronized
    fun takeNew(
        contentId: String,
        descriptors: List<SourceIndexClient.Descriptor>,
        limit: Int = Int.MAX_VALUE,
    ): List<SourceIndexClient.Descriptor> {
        if (limit <= 0 || maxEntries <= 0 || SourceIndexClient.canonicalContentId(contentId) != contentId) {
            return emptyList()
        }
        val fresh = ArrayList<SourceIndexClient.Descriptor>(minOf(descriptors.size, limit))
        for (descriptor in descriptors) {
            if (fresh.size >= limit) break
            val key = "$contentId|${descriptor.kind}|${descriptor.id}"
            if (key in seen) continue
            if (seen.size >= maxEntries) break
            seen.add(key)
            fresh.add(descriptor)
        }
        return fresh
    }
}

/// The assembled, filtered, ranked source-list output the detail UI renders. The Kotlin analogue of Apple
/// SourceListModel's four `@Published` outputs (`groups` / `best` / `tiers` / `resolutionOptions`), collapsed
/// into one immutable value so an unchanged list is a single [StateFlow] no-op.
data class SourceListState(
    val groups: List<StreamGroup> = emptyList(),
    val best: StreamSource? = null,
    val tiers: List<String> = emptyList(),
    val resolutionOptions: List<Pair<String, StreamSource>> = emptyList(),
    val requestGeneration: Long = -1L,
    val streamId: String? = null,
    val torboxEpoch: Int = -1,
    val singularityEpoch: Int = -1,
    val communityJsEpoch: Int = 0,
    val rawGroupsHash: Int = 0,
    val mediaServerGroupsHash: Int = 0,
)

/** Completion is usable only after the coalescer has published every contributor's accepted epoch. */
internal fun sourceAssemblySettledForTarget(
    current: SourceListState, requestGeneration: Long, streamId: String?,
    torbox: SourceContributorSettlement, singularity: SourceContributorSettlement,
    torboxEpoch: Int, singularityEpoch: Int, communityJsEpoch: Int, communityJsSettled: Boolean,
    rawGroupsHash: Int = current.rawGroupsHash, mediaServerGroupsHash: Int = current.mediaServerGroupsHash,
): Boolean = current.requestGeneration == requestGeneration && current.streamId == streamId &&
    torbox.requestGeneration == requestGeneration && torbox.settled &&
    singularity.requestGeneration == requestGeneration && singularity.settled && communityJsSettled &&
    current.torboxEpoch == torboxEpoch && current.singularityEpoch == singularityEpoch && current.communityJsEpoch == communityJsEpoch &&
    current.rawGroupsHash == rawGroupsHash && current.mediaServerGroupsHash == mediaServerGroupsHash
