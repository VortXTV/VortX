package com.vortx.android.engine

import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.singularity.SourceIndexClient
import com.vortx.android.singularity.SourceIndexServeSource
import com.vortx.android.sources.ResolvedPin
import com.vortx.android.sources.SourcePrefsSnapshot
import com.vortx.android.torbox.TorBoxSearchSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.launch
import java.util.Collections

/// Owns a detail screen's source-list ASSEMBLY pipeline off the render path: raw engine stream groups ->
/// merge (TorBox search + Singularity + media-server groups) -> disabled-add-on subtraction -> direct-links
/// filter -> [StreamRanking], all coalesced and run OFF the caller's thread, publishing ONE immutable ranked
/// [SourceListState] per real change. The Kotlin port of Apple `app/SourcesShared/SourceListModel.swift`.
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
/// The engine's own [EngineStremioRepository.streams] already ranks the raw add-on groups, and
/// [com.vortx.android.ui.viewmodel.DetailViewModel] already merges the media-server groups. This model is the
/// unified assembler that folds ALL the lanes (add-on + TorBox + Singularity + media-server) into ONE ranked
/// list through the SAME [StreamRanking] the rest of the app uses, so every lane is ranked together. Wiring it
/// into [com.vortx.android.ui.viewmodel.DetailViewModel] is a follow-up wave; the model is complete + testable
/// standalone here.
///
/// One instance per detail screen. The source-list UI consumes ONLY [state].
class SourceListModel(
    /// The scope the coalescer + off-thread assembly + the fire-and-forget HOARD run on. Owned by the caller
    /// (e.g. a ViewModel's scope); [close] stops the coalescer.
    private val scope: CoroutineScope,
    private val coalesceMs: Long = COALESCE_MS,
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
    private var job: Job? = null
    private var publishedSignature: Signature? = null

    /// The view-owned ranking inputs the assembly needs, the Kotlin analogue of Apple's `Context` struct.
    /// [prefs] is the FROZEN [SourcePrefsSnapshot] the off-thread rank reads (never a live store); [contentId]
    /// is the Singularity pool id used only to seed the fire-and-forget HOARD (null = do not hoard).
    data class Context(
        val metaId: String = "",
        val streamId: String? = null, // null = all loaded groups (movie); set = one episode's groups
        val continuity: String? = null, // remembered quality signature for the best() pick (null for live)
        val pin: ResolvedPin? = null,
        val prefs: SourcePrefsSnapshot = SourcePrefsSnapshot.DEFAULT,
        val directLinksOnly: Boolean = false, // drop torrent sources entirely
        val disabledAddons: Set<String> = emptySet(), // per-profile disabled add-on labels
        val contentId: String? = null, // Singularity pool content id, for the HOARD seed only
    )

    // ---- Binding + input setters ----

    /// Wire the model to its per-screen TorBox + Singularity sources and start the coalesced rebuild pipeline.
    /// Idempotent. Paints once immediately (back-navigation can arrive with streams already resident), then
    /// coalesces subsequent input changes. Mirrors Apple `bind`.
    fun bind(torbox: TorBoxSearchSource, singularity: SourceIndexServeSource) {
        if (job != null) return
        this.torbox = torbox
        this.singularity = singularity
        job = scope.launch(Dispatchers.Default) {
            rebuild() // immediate first paint
            combine(
                rawGroups,
                mediaServerGroups,
                context,
                torbox.streams,
                singularity.streams,
            ) { _, _, _, _, _ -> Unit }
                .conflate()
                .collect {
                    // Trailing coalesce window: a burst of input changes collapses to the latest, and the
                    // rebuild below always reads the freshest .value of every input.
                    kotlinx.coroutines.delay(coalesceMs)
                    rebuild()
                }
        }
    }

    /// Replace the raw engine stream groups (the ranked add-on lane from [EngineStremioRepository.streams]).
    fun setRawGroups(groups: List<StreamGroup>) { rawGroups.value = groups }

    /// Replace the media-server direct-play groups (the lane [com.vortx.android.ui.viewmodel.DetailViewModel]
    /// resolves from [com.vortx.android.mediaserver.MediaServerRepository]).
    fun setMediaServerGroups(groups: List<StreamGroup>) { mediaServerGroups.value = groups }

    /// Update the view-owned ranking inputs. Publishes nothing synchronously; only nudges the coalescer.
    /// Mirrors Apple `setContext`.
    fun setContext(ctx: Context) { context.value = ctx }

    /// Stop the coalescer. The TorBox / Singularity sources own their own scopes (close them separately).
    fun close() { job?.cancel() }

    // ---- Rebuild (coalesced; assemble off-thread, publish once) ----

    private fun rebuild() {
        val tb = torbox ?: return
        val sing = singularity ?: return
        val ctx = context.value
        val raw = rawGroups.value
        val media = mediaServerGroups.value
        val torboxStreams = tb.streams.value
        val singularityStreams = sing.streams.value

        val signature = Signature(
            rawHash = raw.hashCode(),
            mediaHash = media.hashCode(),
            torboxEpoch = tb.epoch,
            singularityEpoch = sing.epoch,
            inputsHash = inputsHash(ctx),
        )
        if (signature == publishedSignature) return // published output already correct: skip the assembly
        publishedSignature = signature

        val assembled = assemble(raw, torboxStreams, singularityStreams, media, ctx)
        _state.value = assembled

        // HOARD (fire-and-forget): seed the community pool from the assembled groups. Not a capture pipeline;
        // the assembly IS the capture point (descriptors are pure, extracted from the ranked groups). Deduped
        // per content id per process so re-assembling the same title does not re-POST. Gated + fail-soft.
        val cid = ctx.contentId
        if (cid != null && SourceIndexClient.isEnabled && assembled.groups.isNotEmpty() && markHoarded(cid)) {
            scope.launch(Dispatchers.IO) {
                SourceIndexClient.hoard(cid, assembled.groups)
            }
        }
    }

    /// A stable hash of exactly the ranking inputs that move the assembly, mirroring Apple's `Hasher.combine`
    /// fold. Uses [SourcePrefsSnapshot.cacheTag] (a stable string) rather than the snapshot's identity, so an
    /// equal-but-rebuilt preference snapshot does not force a spurious rebuild.
    private fun inputsHash(ctx: Context): Int = listOf(
        ctx.metaId,
        ctx.streamId,
        ctx.continuity,
        ctx.pin?.let { "${it.scope}:${it.pin.label}:${it.pin.bingeGroup}" },
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
        val inputsHash: Int,
    )

    companion object {
        /// The coalescing window. At most ~4 rebuilds/sec while an engine burst streams sources in. Mirrors
        /// Apple's `coalesceMs`.
        const val COALESCE_MS = 250L

        /// Per-process dedup of full-title HOARD seeds, so re-assembling the same title in one launch does not
        /// re-POST (the worker upserts by UNIQUE(content_id, kind, id), so a duplicate is harmless anyway).
        private val hoardedContentIds: MutableSet<String> = Collections.synchronizedSet(HashSet())

        private fun markHoarded(contentId: String): Boolean = hoardedContentIds.add(contentId)

        /// The PURE assembly: subtract disabled add-ons, merge the TorBox + Singularity + media-server lanes in
        /// Apple's order (TorBox first, then Singularity, then media-server groups), apply the direct-links
        /// filter, then rank through the SAME [StreamRanking] the app uses (calling `rankedGroups` / `best` /
        /// `tiers` / `resolutionOptions` as-is). Value types in, value types out, no state. Mirrors the
        /// detached-task body of Apple `SourceListModel.rebuild`.
        fun assemble(
            raw: List<StreamGroup>,
            torboxStreams: List<StreamSource>,
            singularityStreams: List<StreamSource>,
            mediaServerGroups: List<StreamGroup>,
            ctx: Context,
        ): SourceListState {
            // Belt-and-suspenders disabled-add-on subtraction (Android has no add-on tombstone surface yet, so
            // this is inert until [Context.disabledAddons] is populated). Matched on the group's add-on label
            // (Android groups carry no transport-url id, unlike Apple's `group.id`).
            var assembled = if (ctx.disabledAddons.isEmpty()) {
                raw
            } else {
                val disabled = ctx.disabledAddons.map { it.trim().lowercase() }.toSet()
                raw.filter { it.addon.trim().lowercase() !in disabled }
            }

            // Merge order preserved from Apple's displayGroups: TorBox search first, then the Singularity pool,
            // then the media-server direct-play groups. Final rank order is decided by StreamRanking, not merge
            // order.
            assembled = mergeMediaServer(
                mediaServerGroups,
                SourceIndexServeSource.merge(
                    singularityStreams,
                    TorBoxSearchSource.merge(torboxStreams, assembled),
                ),
            )

            if (ctx.directLinksOnly) {
                assembled = assembled.mapNotNull { group ->
                    val streams = group.streams.filter { !it.isTorrent }
                    if (streams.isEmpty()) null else group.copy(streams = streams)
                }
            }

            // Install the frozen snapshot so tiers()/resolutionOptions() (which read the installed reading) and
            // the explicit-prefs rankedGroups()/best() all rank against the SAME frozen copy, never a live
            // store, mirroring Apple's task-local prefs binding.
            StreamRanking.installReading(ctx.prefs)
            val ranked = StreamRanking.rankedGroups(assembled, prefs = ctx.prefs, pin = ctx.pin)
            val best = StreamRanking.best(ranked, continuity = ctx.continuity, pin = ctx.pin, prefs = ctx.prefs)
            val tiers = StreamRanking.tiers(ranked)
            val resolutionOptions = StreamRanking.resolutionOptions(ranked)
            return SourceListState(groups = ranked, best = best, tiers = tiers, resolutionOptions = resolutionOptions)
        }

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

/// The assembled, filtered, ranked source-list output the detail UI renders. The Kotlin analogue of Apple
/// SourceListModel's four `@Published` outputs (`groups` / `best` / `tiers` / `resolutionOptions`), collapsed
/// into one immutable value so an unchanged list is a single [StateFlow] no-op.
data class SourceListState(
    val groups: List<StreamGroup> = emptyList(),
    val best: StreamSource? = null,
    val tiers: List<String> = emptyList(),
    val resolutionOptions: List<Pair<String, StreamSource>> = emptyList(),
)
