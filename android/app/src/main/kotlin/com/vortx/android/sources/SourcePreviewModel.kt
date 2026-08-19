package com.vortx.android.sources

import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Live preview for Smart Source Selection, the Android port of Apple `SourcePreviewModel`. Given the viewer's
 * current chip state it shows which sources the ranker would surface (top 5) and how many the current filters
 * would hide, so the Settings panel can answer "what would these chips actually do?" without opening a title.
 *
 * It reuses the EXACT rank path [StreamRanking] uses. On each recompute it captures an immutable
 * [SourcePrefsSnapshot] from [snapshotProvider] on the model's own dispatcher (the Settings chips have already
 * persisted the draft state into the store the provider reads), then runs [StreamRanking.rankedGroups] /
 * [StreamRanking.best] with that snapshot passed EXPLICITLY on [Dispatchers.Default], so the off-thread rank
 * never touches the global installed reading the live source list uses. Chip changes are debounced so typing
 * into the Prefer / Avoid fields does not thrash the rank.
 */
class SourcePreviewModel(
    private val snapshotProvider: () -> SourcePrefsSnapshot = { SourcePrefsSnapshot.DEFAULT },
    sampleGroups: List<StreamGroup>? = null,
    private val scope: CoroutineScope = CoroutineScope(Dispatchers.Main.immediate),
    private val debounceMs: Long = DEBOUNCE_MS,
    private val topN: Int = TOP_N,
    private val computeDispatcher: CoroutineDispatcher = Dispatchers.Default,
) {
    /** One preview row: the parsed quality label, the pick reason badges, and whether it is the auto-pick. */
    data class Row(
        val id: String,
        val qualityLabel: String,
        val reason: String?,
        val isBest: Boolean,
    )

    private val _rows = MutableStateFlow<List<Row>>(emptyList())
    /** The top-N surfaced sources, best first. */
    val rows: StateFlow<List<Row>> = _rows.asStateFlow()

    private val _hiddenCount = MutableStateFlow(0)
    /** How many sources the current chips would HIDE from the sample set (drops, not demotions). */
    val hiddenCount: StateFlow<Int> = _hiddenCount.asStateFlow()

    private val _sampleCount = MutableStateFlow(0)
    /** The size of the sample set the preview is computed over, so the UI can say "5 of 12 shown". */
    val sampleCount: StateFlow<Int> = _sampleCount.asStateFlow()

    /** The sample stream set the preview ranks; a small bundled fixture unless a caller feeds real groups. */
    @Volatile
    private var sample: List<StreamGroup> = sampleGroups?.takeIf { it.isNotEmpty() } ?: fixtureGroups()

    private var debounceJob: Job? = null

    @Volatile
    private var generation = 0L

    init {
        refresh()
    }

    /**
     * Swap in a real sample set (e.g. the last detail's loaded groups) and recompute. An empty set restores
     * the bundled fixture, so the preview is never blank.
     */
    fun update(sampleGroups: List<StreamGroup>) {
        sample = sampleGroups.ifEmpty { fixtureGroups() }
        refresh()
    }

    /** Recompute after a chip change, debounced so a burst of keystrokes coalesces into one rank. */
    fun refresh() {
        debounceJob?.cancel()
        debounceJob = scope.launch {
            delay(debounceMs)
            recompute()
        }
    }

    /** Cancel any in-flight debounce/rank. Call when the owning screen goes away. */
    fun close() {
        scope.coroutineContext[Job]?.cancel()
    }

    private suspend fun recompute() {
        generation += 1
        val gen = generation
        // Capture the frozen prefs snapshot on the model's dispatcher (Apple captures on the main actor), so
        // the detached rank cannot race the store the chips are writing.
        val snapshot = snapshotProvider()
        val groups = sample
        val inputCount = groups.sumOf { it.streams.size }
        val (computedRows, keptCount) = withContext(computeDispatcher) {
            val ranked = StreamRanking.rankedGroups(groups, prefs = snapshot)
            val best = StreamRanking.best(groups, prefs = snapshot)
            val bestId = best?.id
            // Match Apple's kept set: playable, non-trailer survivors of the filters. Android has no
            // pre-resolved playable URL for a raw torrent (it resolves at play time), so a URL is not
            // required here, mirroring [StreamRanking.playablePairs]'s `!isYouTubeTrailer` predicate.
            val flat = ranked.flatMap { it.streams }.filter { !it.isYouTubeTrailer }
            val top = flat.take(topN).map { s ->
                Row(
                    id = s.id,
                    qualityLabel = StreamRanking.watchLabel(s),
                    reason = StreamRanking.pickReason(s, snapshot),
                    isBest = s.id == bestId,
                )
            }
            top to flat.size
        }
        if (gen != generation) return
        _rows.value = computedRows
        _sampleCount.value = inputCount
        // Hidden = sample inputs that did NOT survive the filters (drops). Demoted-but-visible sources in
        // "rank" mode are still kept, so they are NOT counted here.
        _hiddenCount.value = (inputCount - keptCount).coerceAtLeast(0)
    }

    companion object {
        private const val TOP_N = 5
        private const val DEBOUNCE_MS = 250L

        /**
         * A small, representative sample used when no real groups are supplied: a cached 4K remux, a 1080p
         * WEB-DL, an HEVC 4K, a CAM (safety-hidden once a safety chip is on), and a 720p, enough to make
         * Prefer / Avoid / Only / resolution chips visibly change the ordering and the hidden count. Mirrors
         * Apple `SourcePreviewModel.fixtureGroups`.
         */
        fun fixtureGroups(): List<StreamGroup> = listOf(
            StreamGroup(
                addon = "4K Remux Cached",
                streams = listOf(
                    StreamSource(
                        id = "fixture-0",
                        addon = "4K Remux Cached",
                        title = "Movie 2023 2160p BluRay REMUX HDR DV Atmos [RD+] 54.3 GB",
                        infoHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    ),
                ),
            ),
            StreamGroup(
                addon = "1080p WEB-DL",
                streams = listOf(
                    StreamSource(
                        id = "fixture-1",
                        addon = "1080p WEB-DL",
                        title = "Movie 2023 1080p WEB-DL H.264 DDP5.1 6.2 GB",
                        url = "https://cdn.example.com/b.mp4",
                    ),
                ),
            ),
            StreamGroup(
                addon = "4K HEVC",
                streams = listOf(
                    StreamSource(
                        id = "fixture-2",
                        addon = "4K HEVC",
                        title = "Movie 2023 2160p WEB-DL HEVC HDR10 18.4 GB",
                        url = "https://cdn.example.com/c.mkv",
                    ),
                ),
            ),
            StreamGroup(
                addon = "CAM",
                streams = listOf(
                    StreamSource(
                        id = "fixture-3",
                        addon = "CAM",
                        title = "Movie 2023 HDCAM x264 1.8 GB",
                        url = "https://cdn.example.com/d.mp4",
                    ),
                ),
            ),
            StreamGroup(
                addon = "720p",
                streams = listOf(
                    StreamSource(
                        id = "fixture-4",
                        addon = "720p",
                        title = "Movie 2023 720p WEBRip x264 2.1 GB",
                        url = "https://cdn.example.com/e.mp4",
                    ),
                ),
            ),
        )
    }
}
