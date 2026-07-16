package com.vortx.android.engine

import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.sources.ResolvedPin
import com.vortx.android.sources.SourcePinStore
import com.vortx.android.sources.SourcePrefsSnapshot
import com.vortx.android.sources.SourceType
import java.util.concurrent.ConcurrentHashMap

/// Ranks loaded streams so the strongest source surfaces first and the hero "Watch" button can
/// auto-pick one. The Android port of `app/SourcesShared/StreamRanking.swift`.
///
/// The dominant signals mirror the Apple ranker's, in strict priority order:
///   1. source-type tier (media-server > debrid/cached > usenet > torrent > direct), 15000-spaced
///   2. debrid-cached / instant (+8000, clears the whole quality spread within a tier)
///   3. resolution, then source ladder (remux > bluray > web > ...)
///   4. HDR/DV, audio (Atmos > TrueHD > DTS-HD > ...), file size tiebreak, seeder health
///   5. junk / fake-quality / implausible-size guards sink a source below every legitimate stream
///
/// ON TOP of that core scorer sits the FULL user-preference layer (the Android port of Apple's
/// preference-driven ranking, previously absent here): source-type order + add-on-order mode, keyword
/// Hide/Require filters (substring or regex), Smart Source Selection Prefer/Avoid chips, safety mode,
/// instant-only / dead-torrent / AV1 / HDR / max&min resolution / unknown-resolution / preferred-audio /
/// max-file-size filters, the foreign-audio language demotion, per-title + provider pins, and the
/// continuity + bingeGroup next-episode bonuses. The layer reads an immutable [SourcePrefsSnapshot]
/// (Apple's frozen-snapshot race fix), so an off-thread rank never races a Settings edit. With the DEFAULT
/// (empty) snapshot every filter is a no-op and scoring is byte-identical to the pre-layer core scorer.
object StreamRanking {

    // ---- Installed preference snapshot (the frozen copy the ranker reads) ----

    /// The active reading, the Android analogue of Apple's globally-reachable `SourcePreferences.reading`.
    /// A caller with a stream list installs a fresh snapshot (built off the store) before ranking; every
    /// entry point below reads it via the default parameter. Defaults to [SourcePrefsSnapshot.DEFAULT] so
    /// a call made before any store installs one ranks exactly like the old core-only scorer.
    @Volatile
    private var installedReading: SourcePrefsSnapshot = SourcePrefsSnapshot.DEFAULT

    /// Install the active reading. Invalidates the memoized score cache when the fingerprint changed
    /// (scores embed the tier weights + language/chip offsets), mirroring Apple's `invalidateCaches()` on a
    /// preference change.
    fun installReading(snapshot: SourcePrefsSnapshot) {
        if (snapshot.cacheTag != installedReading.cacheTag) invalidateCaches()
        installedReading = snapshot
    }

    /// The active reading (installed snapshot, or the empty default). Mirrors Apple `reading`.
    fun reading(): SourcePrefsSnapshot = installedReading

    // ---- Public ranking entry points ----

    /// Each group's streams sorted best-first (stable within equal scores, so add-on order is preserved
    /// among ties), and the GROUPS themselves ordered by their strongest member so the best add-on block
    /// leads. Applies the user filters first. In the user's explicit add-on-order mode the streams keep
    /// add-on order (the "don't re-rank" choice) and groups are not reordered, matching Apple. Mirrors
    /// Apple `rankedGroups`, with the extra group ordering the Android grouped-list UI wants.
    fun rankedGroups(
        groups: List<StreamGroup>,
        prefs: SourcePrefsSnapshot = installedReading,
        pin: ResolvedPin? = null,
    ): List<StreamGroup> {
        val filtered = applyUserFilters(groups, prefs)
        if (prefs.useAddonOrder) return filtered
        val ranked = filtered.map { group ->
            val sorted = group.streams
                .mapIndexed { index, s ->
                    ScoredStream(s, score(s, prefs) + pinBonus(s, group.addon, pin), index)
                }
                .sortedWith(compareByDescending<ScoredStream> { it.score }.thenBy { it.index })
                .map { it.stream }
            group.copy(streams = sorted)
        }
        return ranked.sortedByDescending { g ->
            g.streams.firstOrNull()?.let { score(it, prefs) + pinBonus(it, g.addon, pin) } ?: Int.MIN_VALUE
        }
    }

    /// The single best playable stream across ALL groups, for the one-press "Watch". Applies the user
    /// filters + pin bonus; excludes YouTube-trailer sources (never the feature auto-pick). Null when there
    /// is nothing to play. Mirrors Apple `best(_:pin:)`.
    fun best(
        groups: List<StreamGroup>,
        prefs: SourcePrefsSnapshot = installedReading,
        pin: ResolvedPin? = null,
    ): StreamSource? {
        val filtered = applyUserFilters(groups, prefs)
        if (prefs.useAddonOrder) {
            if (pin != null) firstPinned(filtered, pin)?.let { return it }
            return playablePairs(filtered).firstOrNull()?.stream
        }
        return playablePairs(filtered)
            .maxByOrNull { score(it.stream, prefs) + pinBonus(it.stream, it.addon, pin) }
            ?.stream
    }

    /// best() with the continuity and bingeGroup bonuses applied on top of the base score. bingeGroup
    /// (exact, from the add-on) outweighs the quality-signature heuristic; both fall back to the plain best
    /// when absent. An applicable pin wins in add-on-order mode too. Mirrors Apple
    /// `best(_:continuity:binge:pin:)`.
    fun best(
        groups: List<StreamGroup>,
        continuity: String?,
        binge: String? = null,
        pin: ResolvedPin? = null,
        prefs: SourcePrefsSnapshot = installedReading,
    ): StreamSource? {
        val filtered = applyUserFilters(groups, prefs)
        if (prefs.useAddonOrder) {
            if (pin != null) firstPinned(filtered, pin)?.let { return it }
            return playablePairs(filtered).firstOrNull()?.stream
        }
        val hasHint = !continuity.isNullOrEmpty()
        val hasBinge = !binge.isNullOrEmpty()
        if (!hasHint && !hasBinge && pin == null) return best(groups, prefs, pin)
        return playablePairs(filtered).maxByOrNull {
            score(it.stream, prefs) +
                continuityBonus(it.stream, continuity) +
                bingeBonus(it.stream, binge) +
                pinBonus(it.stream, it.addon, pin)
        }?.stream
    }

    /// The full ranked candidate list, best-first, ranked EXACTLY as [best] picks its winner (score +
    /// continuity + binge + pin), de-duplicated by playable handle. Feeds the batch-download auto-retry
    /// (#119 remainder): on a failed episode it drops the winning source and queues the NEXT distinct
    /// source with the identical ranking. Mirrors Apple `rankedCandidates`.
    fun rankedCandidates(
        groups: List<StreamGroup>,
        continuity: String?,
        binge: String? = null,
        pin: ResolvedPin? = null,
        prefs: SourcePrefsSnapshot = installedReading,
    ): List<StreamSource> {
        val filtered = applyUserFilters(groups, prefs)
        val pairs = playablePairs(filtered)
        val ordered: List<StreamSource> = if (prefs.useAddonOrder) {
            if (pin != null) {
                firstPinned(filtered, pin)?.let { listOf(it) + pairs.map { p -> p.stream } }
                    ?: pairs.map { it.stream }
            } else {
                pairs.map { it.stream }
            }
        } else {
            pairs.mapIndexed { offset, pair ->
                Triple(
                    offset,
                    pair.stream,
                    score(pair.stream, prefs) +
                        continuityBonus(pair.stream, continuity) +
                        bingeBonus(pair.stream, binge) +
                        pinBonus(pair.stream, pair.addon, pin),
                )
            }
                .sortedWith(compareByDescending<Triple<Int, StreamSource, Int>> { it.third }.thenBy { it.first })
                .map { it.second }
        }
        val seenHandles = HashSet<String>()
        return ordered.filter { seenHandles.add(handleOf(it)) }
    }

    /// The full ranked candidate list, best-first, de-duplicated by playable handle and capped per add-on
    /// so a single flooding add-on cannot bury the rest. Feeds a flat quality-labelled picker; the grouped
    /// UI uses [rankedGroups] instead. Applies the user filters. Stable within equal scores.
    fun rankedFlat(
        groups: List<StreamGroup>,
        prefs: SourcePrefsSnapshot = installedReading,
        perAddonCap: Int = PER_ADDON_CAP,
    ): List<StreamSource> {
        val filtered = applyUserFilters(groups, prefs)
        val perAddonCount = HashMap<String, Int>()
        val seenHandles = HashSet<String>()
        return playablePairs(filtered)
            .mapIndexed { index, pair -> ScoredStream(pair.stream, score(pair.stream, prefs), index) }
            .sortedWith(compareByDescending<ScoredStream> { it.score }.thenBy { it.index })
            .map { it.stream }
            .filter { s ->
                val handle = handleOf(s)
                if (!seenHandles.add(handle)) return@filter false
                val count = perAddonCount.getOrDefault(s.addon, 0)
                if (count >= perAddonCap) return@filter false
                perAddonCount[s.addon] = count + 1
                true
            }
    }

    // ---- Next-episode + pin bonuses (applied on top of score) ----

    /// The stream's quality text, exposed for source-continuity hints (the "rememberedQuality" the player
    /// carries between episodes). Mirrors Apple `signature`.
    fun signature(s: StreamSource): String = qualityText(s)

    /// Prefer the next episode from the same release family as what is playing: same resolution and flavor
    /// usually means the same release group, which the provider often already has hot. Mirrors Apple
    /// `continuityBonus`.
    fun continuityBonus(s: StreamSource, hint: String?): Int {
        if (hint.isNullOrEmpty()) return 0
        val text = qualityText(s)
        var bonus = 0
        for (res in listOf("2160", "1080", "720")) {
            if (boundedMatch(hint, "${res}p?")) {
                if (boundedMatch(text, "${res}p?")) bonus += 800
                break
            }
        }
        if (hint.contains("remux") && text.contains("remux")) {
            bonus += 500
        } else if (hint.contains("web") && text.contains("web")) {
            bonus += 300
        }
        val hdrTokens = listOf("hdr", "dovi", "dolby vision", "dolbyvision")
        if (hdrTokens.any { hint.contains(it) } && hdrTokens.any { text.contains(it) }) bonus += 300
        return bonus
    }

    /// An exact bingeGroup match is the strongest next-episode signal there is: the add-on is telling us
    /// this stream is the same release as the last one, so auto-next stays on the same group with no quality
    /// jump mid-binge. Mirrors Apple `bingeBonus`.
    fun bingeBonus(s: StreamSource, group: String?): Int {
        if (group.isNullOrEmpty() || s.bingeGroup != group) return 0
        return 2500
    }

    /// A user-pinned source floats above everything else. The bonus dwarfs the entire score range (quality
    /// spread 4313, cached +8000, source-type tier gap 15000) so a matching stream wins the one-press
    /// auto-pick and tops the list, yet it is still only a *score*, so the player's invisible failover hops
    /// straight off it if it turns out to be dead. Mirrors Apple `pinBonus`.
    fun pinBonus(s: StreamSource, addon: String, pin: ResolvedPin?): Int {
        if (pin == null || !SourcePinStore.matches(s, addon, pin)) return 0
        return 1_000_000
    }

    /// Coarse release flavor for a pin's human label only: Remux > BluRay > WEB, "" when none is tagged.
    /// Mirrors Apple `releaseFlavor`.
    fun releaseFlavor(s: StreamSource): String {
        val text = qualityText(s)
        if (text.contains("remux")) return "Remux"
        if (text.contains("bluray") || text.contains("blu-ray") || boundedMatch(text, """b[dr][ .\-_]?rip""")) return "BluRay"
        if (boundedMatch(text, "web")) return "WEB"
        return ""
    }

    /// Whether a streams-loading wait should stop now and hand the result to [best]. For a RESUME
    /// ([rememberedQuality] set), it holds out until a stream MATCHING that quality has loaded, and (unless
    /// the user ranks torrents on top, or uses add-on order) a NON-TORRENT one, with a generous ceiling so a
    /// quality that never returns cannot hang the resume. With no remembered quality it keeps the short
    /// snappy window. Mirrors Apple `resolveSettled`.
    fun resolveSettled(
        groups: List<StreamGroup>,
        loaded: Int,
        total: Int,
        secondsSinceFirstPlayable: Double,
        rememberedQuality: String?,
        prefs: SourcePrefsSnapshot = installedReading,
    ): Boolean {
        if (groups.isEmpty()) return false
        if (total > 0 && loaded >= total) return true
        val hint = rememberedQuality
        if (hint.isNullOrEmpty()) return secondsSinceFirstPlayable > 4
        val torrentOK = prefs.useAddonOrder || prefs.typeOrder.firstOrNull() == SourceType.TORRENT
        val qualityReady = groups.any { group ->
            group.streams.any { s ->
                !s.isYouTubeTrailer && continuityBonus(s, hint) > 0 && (torrentOK || !s.isTorrent)
            }
        }
        return qualityReady || secondsSinceFirstPlayable > 16
    }

    // ---- Playable pairing + pin resolution ----

    /// Streams paired with their source group's add-on, the form pin matching needs (a flattened stream
    /// loses which add-on it came from, which a `global`/provider pin keys on). Excludes YouTube-trailer
    /// sources (a trailer is never the feature auto-pick). Mirrors Apple `playablePairs`.
    ///
    /// Note the Android predicate is `!isYouTubeTrailer`, where Apple's is `playableURL != nil &&
    /// !isYouTubeTrailer`: on Android a raw torrent has no pre-resolved playable URL (it resolves through
    /// the debrid path at play time, not a local streaming server), yet is still rankable + playable, so
    /// requiring a URL here would wrongly drop every torrent.
    private fun playablePairs(groups: List<StreamGroup>): List<PlayablePair> =
        groups.flatMap { g -> g.streams.map { PlayablePair(g.addon, it) } }
            .filter { !it.stream.isYouTubeTrailer }

    /// The first playable stream that matches a pin, in add-on/list order. Used by the add-on-order path.
    /// Mirrors Apple `firstPinned`.
    private fun firstPinned(groups: List<StreamGroup>, pin: ResolvedPin?): StreamSource? {
        if (pin == null) return null
        return playablePairs(groups).firstOrNull { SourcePinStore.matches(it.stream, it.addon, pin) }?.stream
    }

    private data class PlayablePair(val addon: String, val stream: StreamSource)

    // ---- Display helpers (labels the source UI renders) ----

    /// A short resolution tag for the quality badge ("4K" / "1080p" / …), or "Other" when the resolution
    /// can't be determined. Mirrors Apple `qualityLabel`.
    fun qualityLabel(source: StreamSource): String {
        val t = qualityText(source)
        explicitResolution(t)?.let { r ->
            if (r >= 4000) return if (implausibleForResolution(t)) "Other" else "4K"
            return "${r}p"
        }
        if ((boundedMatch(t, "4k") || boundedMatch(t, "uhd")) && !implausibleForResolution(t)) return "4K"
        return "Other"
    }

    /// The flavour tags WITHOUT the resolution label (Remux · HDR · Atmos · HEVC · Cached, plus a junk
    /// class when the source ranks at the bottom), for the source row's detail line. Mirrors Apple
    /// `flavorTags`.
    fun flavorTags(source: StreamSource): List<String> {
        val t = qualityText(source)
        val tags = mutableListOf<String>()
        if (t.contains("remux")) tags += "Remux"
        else if (t.contains("bluray") || t.contains("blu-ray")) tags += "BluRay"
        else if (boundedMatch(t, "web")) tags += "WEB"
        if (isDolbyVisionText(t)) tags += "DV"
        if (t.contains("hdr10+") || t.contains("hdr10plus")) tags += "HDR10+"
        else if (t.contains("hdr10")) tags += "HDR10"
        else if (t.contains("hdr")) tags += "HDR"
        if (t.contains("atmos")) tags += "Atmos"
        else if (t.contains("truehd") || t.contains("true-hd")) tags += "TrueHD"
        else if (t.contains("dts-hd") || t.contains("dts hd") || t.contains("dtshd")) tags += "DTS-HD"
        else if (t.contains("dts")) tags += "DTS"
        else if (t.contains("eac3") || t.contains("e-ac3") || t.contains("ddp") || t.contains("dd+")) tags += "DD+"
        if (t.contains("hevc") || t.contains("x265") || t.contains("h265") || t.contains("h.265")) tags += "HEVC"
        else if (boundedMatch(t, "av1")) tags += "AV1"
        else if (t.contains("x264") || t.contains("h264") || t.contains("h.264")) tags += "H.264"
        // A media-server copy is direct-play from your own box, not a debrid cache: label it honestly
        // ("Direct") and never as "Cached", and skip the junk class (it is the user's own file).
        if (source.isMediaServer) {
            tags += "Direct"
        } else {
            if (isCached(source, t)) tags += "Cached"
            junkClass(t)?.let { tags += it }
        }
        return tags
    }

    /// The parsed file size ("12.4 GB" / "850 MB"), or null when the add-on didn't advertise one. Mirrors
    /// Apple `sizeText`.
    fun sizeText(source: StreamSource): String? {
        val t = qualityText(source)
        firstMatch(t, """(\d+(?:\.\d+)?)\s*(gb|gib)""")?.let { return it.uppercase().replace("GIB", "GB") }
        firstMatch(t, """(\d+(?:\.\d+)?)\s*(mb|mib)""")?.let { return it.uppercase().replace("MIB", "MB") }
        return null
    }

    /// Everything a switcher row should say: the resolution label plus the flavor tags, and the file size
    /// when advertised. Mirrors Apple `sourceDetail`.
    fun sourceDetail(source: StreamSource): Pair<String, String?> {
        val tags = listOf(qualityLabel(source)) + flavorTags(source)
        return tags.joinToString(" · ") to sizeText(source)
    }

    /// Enriched label for the Watch-Now button, derived from the EXACT stream [best] will play so the
    /// button can never promise a quality it doesn't deliver: "4K · HDR · Remux", "1080p · WEB". Mirrors
    /// Apple `watchLabel`.
    fun watchLabel(source: StreamSource): String {
        val t = qualityText(source)
        val tags = mutableListOf(qualityLabel(source))
        if (isDolbyVisionText(t)) tags += "DV"
        else if (t.contains("hdr")) tags += "HDR"
        if (t.contains("remux")) tags += "Remux"
        else if (t.contains("bluray") || t.contains("blu-ray")) tags += "BluRay"
        else if (boundedMatch(t, """web[ .\-_]?(dl|rip)?""")) tags += "WEB"
        return tags.joinToString(" · ")
    }

    /// A one-line rationale for WHY the auto-pick chose this source (#16), shown ONCE on the recommended
    /// pick. Surfaces the two decisive factors the per-row tags do not convey (instant-from-cache, and
    /// top of the viewer's source-type order) plus the Smart-Source Prefer/Avoid reason. Null when neither
    /// applies. Mirrors Apple `pickReason`.
    fun pickReason(source: StreamSource, prefs: SourcePrefsSnapshot = installedReading): String? {
        val t = qualityText(source)
        val why = mutableListOf<String>()
        if (isCached(source, t)) why += "instant from cache"
        if (prefs.typeOrder.firstOrNull() == sourceType(source, t)) why += "your preferred source type"
        prefs.preferTerms.firstOrNull { t.contains(it) }?.let { why += "preferred: $it" }
        if (prefs.avoidBehavior == "rank") {
            if (prefs.keywordsAreRegex) {
                prefs.excludeRegex?.let { if (it.containsMatchIn(t)) why += "ranked down" }
            } else {
                prefs.excludeTerms.firstOrNull { t.contains(it) }?.let { why += "ranked down: $it" }
            }
        }
        return if (why.isEmpty()) null else why.joinToString(" · ")
    }

    /// True when a source advertises Dolby Vision (the only pre-play DV signal, a text parse). Mirrors
    /// Apple `isDolbyVision`.
    fun isDolbyVision(source: StreamSource): Boolean = isDolbyVisionText(qualityText(source))

    /// True when a source advertises Dolby Atmos / object audio, routed to the ExoPlayer engine for
    /// bitstream passthrough. Text parse, the only pre-play signal.
    fun isAtmos(source: StreamSource): Boolean = qualityText(source).contains("atmos")

    // ---- Quality picker builders (the visible resolution + flavor dropdowns) ----

    /// The best stream per distinct resolution label (4K, 1080p, …), best-first. Mirrors Apple
    /// `resolutionOptions`.
    fun resolutionOptions(groups: List<StreamGroup>): List<Pair<String, StreamSource>> {
        val playable = groups.flatMap { it.streams }.filter { !it.isYouTubeTrailer }
        val bestByLabel = HashMap<String, StreamSource>()
        for (s in playable) {
            val label = qualityLabel(s)
            val existing = bestByLabel[label]
            if (existing != null && score(existing) >= score(s)) continue
            bestByLabel[label] = s
        }
        return bestByLabel.map { it.key to it.value }.sortedByDescending { score(it.second) }
    }

    /// Distinct choices for the visible quality picker: the best stream per resolution-and-flavor
    /// combination, labelled "4K · Dolby Vision · Remux" etc. Best-first. Mirrors Apple `qualityOptions`.
    fun qualityOptions(groups: List<StreamGroup>): List<Pair<String, StreamSource>> {
        val playable = groups.flatMap { it.streams }.filter { !it.isYouTubeTrailer }
        val best = HashMap<String, Pair<Int, StreamSource>>()
        for (s in playable) {
            val label = pickerLabel(s)
            val sc = score(s)
            val current = best[label]
            if (current != null && current.first >= sc) continue
            best[label] = sc to s
        }
        return best.map { it.key to it.value.second }.sortedByDescending { score(it.second) }
    }

    /// The resolution tiers that actually have playable sources, in fixed order, for the first level of the
    /// quality picker. Everything that is not 4K/1080p/720p lands in "Others". Mirrors Apple `tiers`.
    fun tiers(groups: List<StreamGroup>): List<String> {
        val playable = groups.flatMap { it.streams }.filter { !it.isYouTubeTrailer }
        val present = HashSet<String>()
        for (s in playable) present += tier(s)
        return listOf("4K", "1080p", "720p", "Others").filter { present.contains(it) }
    }

    /// Second level of the quality picker: distinct flavor variants inside one resolution tier, best
    /// variant of each, best-first, capped at 8. Mirrors Apple `variantOptions`.
    fun variantOptions(groups: List<StreamGroup>, wantedTier: String): List<Pair<String, StreamSource>> {
        val playable = groups.flatMap { it.streams }
            .filter { !it.isYouTubeTrailer && tier(it) == wantedTier }
        val best = HashMap<String, Pair<Int, StreamSource>>()
        for (s in playable) {
            val t = qualityText(s)
            val tags = mutableListOf<String>()
            if (isDolbyVisionText(t)) tags += "Dolby Vision"
            else if (t.contains("hdr")) tags += "HDR"
            if (t.contains("remux")) tags += "Remux"
            else if (t.contains("bluray") || t.contains("blu-ray")) tags += "BluRay"
            else if (t.contains("web")) tags += "WEB"
            if (t.contains("atmos")) tags += "Atmos"
            else if (t.contains("truehd")) tags += "TrueHD"
            else if (t.contains("dts-hd") || t.contains("dts hd")) tags += "DTS-HD"
            val label = if (tags.isEmpty()) "Standard" else tags.joinToString(" · ")
            val sc = score(s)
            val current = best[label]
            if (current != null && current.first >= sc) continue
            best[label] = sc to s
        }
        return best.map { entry ->
            val size = sourceDetail(entry.value.second).second
            val label = if (size != null) "${entry.key}  ·  $size" else entry.key
            label to entry.value.second
        }
            .sortedByDescending { score(it.second) }
            .take(8)
    }

    /// The flavor tags for the [qualityOptions] / [variantOptions] label of one stream (Apple's inline
    /// tag-building in those builders).
    private fun pickerLabel(s: StreamSource): String {
        val t = qualityText(s)
        val tags = mutableListOf(qualityLabel(s))
        if (isDolbyVisionText(t)) tags += "Dolby Vision"
        else if (t.contains("hdr")) tags += "HDR"
        if (t.contains("remux")) tags += "Remux"
        else if (t.contains("bluray") || t.contains("blu-ray")) tags += "BluRay"
        else if (t.contains("web")) tags += "WEB"
        if (t.contains("atmos")) tags += "Atmos"
        else if (t.contains("truehd")) tags += "TrueHD"
        else if (t.contains("dts-hd") || t.contains("dts hd")) tags += "DTS-HD"
        return tags.joinToString(" · ")
    }

    private fun tier(s: StreamSource): String = when (qualityLabel(s)) {
        "4K" -> "4K"
        "1080p" -> "1080p"
        "720p" -> "720p"
        else -> "Others"
    }

    // ---- Auto-failover helpers (the player's silent quality-plunge guard) ----

    /// The stream's resolution as a comparable tier number, the same scale [score] uses, so the player's
    /// auto-failover can compare how far a candidate would drop below the best cached option. Mirrors Apple
    /// `resolutionRank`.
    fun resolutionRank(s: StreamSource): Int = resolution(qualityText(s))

    /// Whether a source plays instantly (debrid-cached / direct), parsing the quality text for the caller.
    /// Mirrors Apple `isCachedSource`.
    fun isCachedSource(s: StreamSource): Boolean = isCached(s, qualityText(s))

    /// The resolution tier of the best CACHED (instant) playable source across the loaded groups, or 0 when
    /// nothing cached is loaded yet. The auto-failover uses this as the ceiling reference. Mirrors Apple
    /// `bestCachedResolution`.
    fun bestCachedResolution(groups: List<StreamGroup>): Int {
        var best = 0
        for (group in groups) {
            for (s in group.streams) {
                if (s.isYouTubeTrailer) continue
                val text = qualityText(s)
                if (!isCached(s, text)) continue
                best = maxOf(best, resolution(text))
            }
        }
        return best
    }

    /// The coarse resolution TIER for the one-tier-drop cap. Mirrors Apple `resolutionTierStep`.
    fun resolutionTierStep(res: Int): Int = when {
        res >= 2160 -> 4
        res >= 1440 -> 3
        res >= 1080 -> 3
        res >= 720 -> 2
        res >= 480 -> 1
        else -> 0
    }

    /// File size in GB for a "by size" sort of the source list; 0 when no size is advertised. Mirrors Apple
    /// `sizeForSort`.
    fun sizeForSort(s: StreamSource): Double {
        val text = qualityText(s)
        val gb = sizeGB(text)
        return if (gb > 0) gb else sizeMB(text) / 1024
    }

    /// Seeder count for a "by seeders" sort; -1 when none is advertised. Mirrors Apple `seedersForSort`.
    fun seedersForSort(s: StreamSource): Int = seederCount(qualityText(s)) ?: -1

    // ---- User filters ----

    /// Aggregator "reasons / statistics" pseudo-streams (AIOStreams Stream-Expression output, SeaDex/SEL
    /// setups, etc.) are a filter EXPLANATION, not playable video. Detect by the diagnostic headings these
    /// add-ons emit and drop them from EVERY path. Mirrors Apple `isNonVideo`.
    fun isNonVideo(s: StreamSource): Boolean {
        val t = qualityText(s)
        val markers = listOf(
            "included reasons", "removal reasons", "excluded resolution", "stream expression",
            "year matching", "no streams found", "no results found", "stream statistics",
        )
        return markers.any { t.contains(it) }
    }

    /// Strip the non-video diagnostic pseudo-streams unconditionally (BEFORE the user-filter early-out), so
    /// they are gone even when the user has no quality filters active. Mirrors Apple `stripNonVideo`.
    private fun stripNonVideo(groups: List<StreamGroup>): List<StreamGroup> =
        groups.mapNotNull { group ->
            val kept = group.streams.filter { !isNonVideo(it) }
            if (kept.isEmpty()) null else group.copy(streams = kept)
        }

    /// Whether a stream survives the user's keyword + safety + numeric filters (Settings > Streams). Default
    /// preferences pass everything, so this is a no-op until the user opts in. Mirrors Apple
    /// `passesUserFilters`.
    fun passesUserFilters(s: StreamSource, prefs: SourcePrefsSnapshot = installedReading): Boolean {
        val kids = prefs.isKids
        if (!kids && prefs.noFiltersActive) return true // fast path: nothing opted in (and not a Kids profile)
        val text = qualityText(s)
        if (kids) {
            // Kids profile: always hide explicit content and CAM/fake junk, whatever the user filters say.
            if (isAdultContent(text) || junkClass(text) != null) return false
        }
        if (prefs.noFiltersActive) return true
        // The Require (include) terms are ALWAYS a hard require in both Avoid modes. The Hide (exclude)
        // terms only DROP here when avoidBehavior == "hide"; in "rank" mode they stop dropping and instead
        // sink the score in computeScore. On a Kids profile the Avoid words always DROP (a parental hide
        // tool), whatever avoidBehavior says.
        val avoidRanks = prefs.avoidBehavior == "rank" && !kids
        if (prefs.keywordsAreRegex) {
            if (!avoidRanks) prefs.excludeRegex?.let { if (it.containsMatchIn(text)) return false }
            prefs.includeRegex?.let { if (!it.containsMatchIn(text)) return false }
        } else {
            val exclude = prefs.excludeTerms
            val include = prefs.includeTerms
            if (!avoidRanks && exclude.any { text.contains(it) }) return false
            if (include.isNotEmpty() && include.none { text.contains(it) }) return false
        }
        when (prefs.safetyMode) {
            "balanced" -> if (junkClass(text) != null) return false
            "strict" -> if (junkClass(text) != null || implausibleForResolution(text)) return false
            else -> {}
        }
        // Instant-only keeps cached debrid + plain direct links; a media-server direct play from your own
        // box is instant by definition, so exempt it or it would be hidden by this filter.
        if (prefs.instantOnly && !s.isMediaServer && !isCached(s, text)) return false
        if (prefs.hideDeadTorrents && sourceType(s, text) == SourceType.TORRENT) {
            val seeders = seederCount(text)
            if (seeders == 0) return false // explicitly-dead swarm
        }
        if (prefs.excludeAV1 && boundedMatch(text, "av1")) return false // no Apple AV1 hw decode
        if (prefs.hdrOnly && !(text.contains("hdr") || text.contains("dolby vision") ||
                text.contains("dolbyvision") || text.contains("dovi"))) {
            return false
        }
        if (prefs.maxResolution > 0 && resolution(text) > prefs.maxResolution) return false // cap known res
        if (prefs.minResolution > 0) {
            val res = knownResolution(text)
            if (res != null && res < prefs.minResolution) return false // floor KNOWN res; unlabelled kept (#117)
        }
        if (prefs.hideUnknownResolution && knownResolution(text) == null) return false // (#117)
        // Best-effort audio-language filter (#117): drop ONLY when the parse POSITIVELY identifies a single
        // foreign-audio release (languageScore's conservative negative case).
        if (prefs.preferredAudioOnly && languageScore(text, prefs) < 0) return false
        if (prefs.maxFileSizeGB > 0) {
            val gb = if (sizeGB(text) > 0) sizeGB(text) else sizeMB(text) / 1024
            if (gb > 0 && gb > prefs.maxFileSizeGB) return false // unknown-size sources pass
        }
        return true
    }

    /// Explicit-content blocklist for Kids profiles, matched as bounded tokens. Mirrors Apple
    /// `isAdultContent`.
    private fun isAdultContent(text: String): Boolean {
        val terms = listOf("xxx", "porn", "porno", "hentai", "brazzers", "onlyfans", "nsfw", "jav", "camgirl")
        return terms.any { boundedMatch(text, it) }
    }

    /// Drop streams that fail the user filters, and any group left empty. Always strips non-video
    /// diagnostic pseudo-streams first (unconditional on Apple too). No-op filtering when nothing is set
    /// (and not a Kids profile). Mirrors Apple `applyUserFilters`.
    fun applyUserFilters(
        groups: List<StreamGroup>,
        prefs: SourcePrefsSnapshot = installedReading,
    ): List<StreamGroup> {
        val stripped = stripNonVideo(groups)
        if (prefs.noFiltersActive && !prefs.isKids) return stripped
        return stripped.mapNotNull { group ->
            val kept = group.streams.filter { passesUserFilters(it, prefs) }
            if (kept.isEmpty()) null else group.copy(streams = kept)
        }
    }

    // ---- Smart Source Selection (Lane A) score offsets ----

    /// The Prefer-term boost plus, when Avoid behavior is "rank", the Avoid-term demotion. +2500 is a
    /// within-tier lift small enough that prefer + cache (+8000) + the max quality spread (4313) stays under
    /// the 15000 tier step; -20000 sinks a source below the quality spread but keeps it above the -100000
    /// junk floor so it stays visible. Mirrors Apple `chipScoreOffset`.
    fun chipScoreOffset(text: String, prefs: SourcePrefsSnapshot): Int {
        var offset = 0
        if (prefs.preferTerms.isNotEmpty() && prefs.preferTerms.any { text.contains(it) }) {
            offset += 2500
        }
        if (prefs.avoidBehavior == "rank" && avoidMatches(text, prefs)) {
            offset -= 20_000
        }
        return offset
    }

    /// Whether the stream text matches the viewer's Avoid (Hide / exclude) terms, honoring regex vs
    /// substring mode. Used only by the "rank" Avoid path. Mirrors Apple `avoidMatches`.
    private fun avoidMatches(text: String, prefs: SourcePrefsSnapshot): Boolean {
        if (prefs.keywordsAreRegex) {
            return prefs.excludeRegex?.containsMatchIn(text) ?: false
        }
        return prefs.excludeTerms.any { text.contains(it) }
    }

    // ---- Audio-language demotion ----

    /// Audio-language markers per ISO code. Full words use substring matching; short codes and CJK glyphs
    /// are checked bounded. Deliberately conservative. Mirrors Apple `langTokens`.
    private val langTokens: Map<String, List<String>> = mapOf(
        "en" to listOf("english", "🇬🇧", "🇺🇸"),
        "es" to listOf("spanish", "español", "espanol", "castellano", "latino"),
        "fr" to listOf("french", "français", "francais", "truefrench", "vostfr"),
        "de" to listOf("german", "deutsch"),
        "it" to listOf("italian", "italiano"),
        "pt" to listOf("portuguese", "português", "portugues", "dublado", "legendado"),
        "hi" to listOf("hindi", "🇮🇳"),
        "ja" to listOf("japanese", "日本", "日本語"),
        "ko" to listOf("korean", "한국", "korsub"),
        "zh" to listOf("chinese", "mandarin", "cantonese", "中文", "中字", "国语", "粤语", "简体", "繁體"),
        "ar" to listOf("arabic", "العربية"),
        "ru" to listOf("russian", "русск"),
    )

    /// Subtitle-context tokens that also live in [langTokens] (korsub = Korean SUBS, vostfr = French SUBS,
    /// legendado = Portuguese SUBS): they must NOT drive the foreign-AUDIO demotion. Mirrors Apple
    /// `subtitleContextTokens`.
    private val subtitleContextTokens: Set<String> = setOf("korsub", "vostfr", "legendado")

    /// Demote ONLY a release that clearly advertises a single foreign audio language (and not the viewer's).
    /// Priority is the viewer's SELECTED audio language; a release carrying that language, or any
    /// multi-language release, is never demoted. If NONE of the preferred codes are detectable by
    /// [langTokens], keep the release (score 0) rather than over-hide (#136). Mirrors Apple `languageScore`.
    fun languageScore(text: String, prefs: SourcePrefsSnapshot = installedReading): Int {
        val preferred = prefs.audioLanguages.toSet()
        if (preferred.isEmpty()) return 0
        if (preferred.any { claimsLanguage(text, it) }) return 0 // carries the viewer's language: rank normally
        if (isMultiLanguage(text)) return 0 // multi-language: never demote
        // We can only judge "clearly foreign" against a viewer language we can actually detect (#136).
        if (preferred.none { langTokens[it] != null }) return 0
        // Single, clearly-foreign release: match the foreign token only in the technical-tags portion.
        val tags = technicalTags(text)
        val foreign = langTokens.keys.filter { !preferred.contains(it) }
        return if (foreign.any { claimsAudioLanguage(tags, it) }) -5000 else 0
    }

    /// True when `text` advertises language `code` (full words by substring, short codes + CJK glyphs
    /// bounded). Mirrors Apple `claimsLanguage`.
    private fun claimsLanguage(text: String, code: String): Boolean =
        (langTokens[code] ?: emptyList()).any { token ->
            if (token.length <= 3) boundedMatch(text, token) else text.contains(token)
        }

    /// True when `text` advertises AUDIO language `code`, ignoring subtitle-context tokens (korsub / vostfr
    /// / legendado) so a burned-in-subtitle release is never read as foreign audio. Mirrors Apple
    /// `claimsAudioLanguage`.
    private fun claimsAudioLanguage(text: String, code: String): Boolean =
        (langTokens[code] ?: emptyList()).any { token ->
            if (subtitleContextTokens.contains(token)) return@any false
            if (token.length <= 3) boundedMatch(text, token) else text.contains(token)
        }

    /// The ISO codes `text` plausibly advertises, using the SAME [langTokens] map + boundary matching the
    /// ranker uses. Case-insensitive; sorted, de-duplicated. Public reuse point for a language-index client.
    /// Mirrors Apple `languageCodesAdvertised`.
    fun languageCodesAdvertised(text: String): List<String> {
        val lowered = text.lowercase()
        return langTokens.keys.filter { claimsLanguage(lowered, it) }.sorted()
    }

    /// True when a release advertises more than one audio language (explicit multi/dual markers, two or more
    /// distinct detected languages, or two or more country flags). Mirrors Apple `isMultiLanguage`.
    fun isMultiLanguage(text: String): Boolean {
        if (text.contains("multi") || text.contains("dual")) return true
        if (langTokens.keys.count { claimsLanguage(text, it) } >= 2) return true
        return flagCount(text) >= 2
    }

    /// Number of country-flag emoji in `text` (a pair of regional-indicator scalars U+1F1E6..U+1F1FF, so
    /// the scalar count over two is the flag count). Mirrors Apple `flagCount`.
    private fun flagCount(text: String): Int {
        var indicators = 0
        var i = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            if (cp in 0x1F1E6..0x1F1FF) indicators++
            i += Character.charCount(cp)
        }
        return indicators / 2
    }

    // ---- Provider classification (intra-tier hook; offset is neutral 0 today) ----

    /// Known debrid / usenet services detected from the stream text. Mirrors Apple `ServiceProvider`.
    enum class ServiceProvider {
        REAL_DEBRID, ALL_DEBRID, PREMIUMIZE, TORBOX, DEBRID_LINK, OFFCLOUD, EASYNEWS, UNKNOWN
    }

    /// Service detection. The two-letter tags are only honoured with their "+" suffix or in brackets.
    /// Mirrors Apple `provider`.
    fun provider(text: String): ServiceProvider {
        if (isRealDebrid(text)) return ServiceProvider.REAL_DEBRID
        if (text.contains("alldebrid") || text.contains("all-debrid") || text.contains("[ad+]") ||
            matches(text, """\bad\+""")) return ServiceProvider.ALL_DEBRID
        if (text.contains("premiumize") || text.contains("[pm+]") ||
            matches(text, """\bpm\+""")) return ServiceProvider.PREMIUMIZE
        if (text.contains("torbox") || text.contains("[tb+]") ||
            matches(text, """\btb\+""")) return ServiceProvider.TORBOX
        if (text.contains("debrid-link") || text.contains("debridlink") || text.contains("[dl+]")) return ServiceProvider.DEBRID_LINK
        if (text.contains("offcloud") || text.contains("[oc+]")) return ServiceProvider.OFFCLOUD
        if (text.contains("easynews")) return ServiceProvider.EASYNEWS
        return ServiceProvider.UNKNOWN
    }

    /// Intra-tier provider preference. NEUTRAL: no service is favoured or penalised. Kept as the hook for a
    /// future user-configurable per-provider order. Mirrors Apple `providerOffset`.
    fun providerOffset(provider: ServiceProvider): Int = 0

    /// Matches the Real-Debrid service name plus the bracketed/delimited "RD"/"RD+" tags. Mirrors Apple
    /// `isRealDebrid`.
    fun isRealDebrid(text: String): Boolean {
        if (text.contains("realdebrid") || text.contains("real-debrid") || text.contains("real debrid")) return true
        return matches(text, """\brd\+?\b""")
    }

    // ---- Scoring ----

    private data class ScoredStream(val stream: StreamSource, val score: Int, val index: Int)

    /// The within-tier seeder tiebreak cap, held strictly below the tier-step headroom so a hot swarm never
    /// lets a torrent cross its source-type tier. Mirrors Apple `seederTiebreakCap`.
    private const val SEEDER_TIEBREAK_CAP = 180

    /// Default per-add-on cap for the flat picker so one add-on returning thousands of near-duplicate
    /// sources cannot bury every other add-on's answers.
    private const val PER_ADDON_CAP = 12

    private val scoreCache = ConcurrentHashMap<String, Int>()

    /// Drop memoized scores; called when ranking preferences or pins change (scores embed them). Mirrors
    /// Apple `invalidateCaches`.
    fun invalidateCaches() {
        scoreCache.clear()
    }

    /// The score for [source] under [prefs]. Memoized by (stream id + preference fingerprint) so two
    /// different snapshots never share a cached score, mirroring Apple's per-preference cache invalidation.
    fun score(source: StreamSource, prefs: SourcePrefsSnapshot = installedReading): Int {
        val key = source.id + "\u0000" + prefs.cacheTag
        scoreCache[key]?.let { return it }
        val value = computeScore(source, prefs)
        if (scoreCache.size > 32_768) scoreCache.clear()
        scoreCache[key] = value
        return value
    }

    private fun computeScore(source: StreamSource, prefs: SourcePrefsSnapshot): Int {
        val text = qualityText(source)
        var score = resolution(text)
        // Source ladder: STRICT, the dominant within-resolution key (a remux must beat a bigger WEB-DL).
        if (text.contains("remux")) score += 230
        else if (text.contains("bluray") || text.contains("blu-ray") || boundedMatch(text, """b[dr][ .\-_]?rip""")) score += 150
        else if (boundedMatch(text, """web[ .\-_]?dl""")) score += 75
        else if (boundedMatch(text, """web[ .\-_]?rip""")) score += 50
        else if (boundedMatch(text, "web")) score += 75
        else if (text.contains("hdtv")) score -= 150
        else if (boundedMatch(text, """dvd[ .\-_]?rip""")) score -= 200
        else if (text.contains("tvrip") || text.contains("satrip") || boundedMatch(text, "pdtv")) score -= 300
        // Video range: DV > HDR10+ > HDR10/HLG > SDR. DV uses the wide predicate the router trusts.
        if (isDolbyVisionText(text)) score += 45
        else if (text.contains("hdr10+") || text.contains("hdr10plus")) score += 24
        else if (text.contains("hdr") || text.contains("hlg")) score += 18
        // File size: a small final tiebreak (cap +12), never a primary signal.
        score += minOf((sizeGB(text) * 0.15), 12.0).toInt()
        // Audio ladder (object-based > lossless > lossy).
        if (text.contains("atmos")) score += 26
        else if (text.contains("dts:x") || text.contains("dtsx") || text.contains("dts-x")) score += 24
        else if (text.contains("truehd") || text.contains("true-hd")) score += 20
        else if (text.contains("dts-hd ma") || text.contains("dts-hd.ma") || text.contains("dts-ma")) score += 16
        else if (text.contains("dts-hd") || text.contains("dts hd") || text.contains("dtshd") || text.contains("flac") || text.contains("lpcm") || boundedMatch(text, "pcm")) score += 12
        else if (text.contains("eac3") || text.contains("e-ac3") || text.contains("dd+") || text.contains("ddp") || text.contains("ddplus")) score += 8
        else if (text.contains("dts")) score += 6
        else if (text.contains("ac3") || boundedMatch(text, "dd") || text.contains("dolby digital")) score += 4
        // AV1: many Android TV boxes still software-decode 4K AV1; nudge toward HEVC/H.264 peers.
        if (boundedMatch(text, "av1")) {
            score -= if (text.contains("2160") || text.contains("4k") || text.contains("uhd")) 1500 else 150
        }
        // 3D releases render as a split frame on a flat panel.
        if (boundedMatch(text, "3d") || boundedMatch(text, """hsbs|half[ .\-_]?sbs|sbs[ .\-_]?3d""")) score -= 2000
        // Hardcoded-subtitle rips are watchable but defaced.
        if (text.contains("korsub") || boundedMatch(text, "hc")) score -= 200
        // Preferred-language demotion: a release that clearly advertises a foreign audio language (and no
        // preferred one) sinks 5,000 points, enough to fall below a same-cache same-type peer one resolution
        // tier down. Untagged releases (most English originals) are never penalised.
        score += languageScore(text, prefs)
        // Smart Source Selection (Lane A): the Prefer boost and, in "rank" mode, the Avoid demotion.
        score += chipScoreOffset(text, prefs)
        // Cached dominates within its tier (+8000 clears the max quality spread).
        if (isCached(source, text)) score += 8000
        // Source type is the top-level key (15000-spaced tier weight, from the user's typeOrder).
        val type = sourceType(source, text)
        score += prefs.tierWeight(type)
        // Provider offset: a small INTRA-tier nudge (neutral 0 today), kept for parity with the future hook.
        score += providerOffset(provider(text))
        // Raw torrents live or die by swarm health; a dead swarm sinks, a hot one earns a capped tiebreak.
        if (type == SourceType.TORRENT) {
            seederCount(text)?.let { seeders ->
                score += if (seeders == 0) -800 else minOf(seeders * 8, SEEDER_TIEBREAK_CAP)
            }
        }
        // Fake-quality + junk guards sink a source below every legitimate stream. NOT applied to a
        // media-server source: that is the user's OWN file on their OWN box.
        if (!source.isMediaServer) {
            if (implausibleForResolution(text)) score -= 100_000
            if (junkClass(text) != null) score -= 100_000
        }
        return score
    }

    // ---- Source-type classification ----

    /// Classify a stream into the five user-rankable source categories. Mirrors Apple `sourceType`. A
    /// media-server direct-play copy is tiered purely by its [StreamSource.isMediaServer] provenance flag
    /// (the Android analogue of the Apple `vortxProvider != nil` check), regardless of the text below.
    private fun sourceType(source: StreamSource, text: String): SourceType {
        if (source.isMediaServer) return SourceType.MEDIA_SERVER
        if (text.contains("usenet") || text.contains("nzb") || text.contains("easynews") || text.contains("📰")) return SourceType.USENET
        // Resolved torrent = debrid/cached, detected STRUCTURALLY (add-on-agnostic). A RAW torrent has an
        // infoHash and NO url; once a debrid/cached service resolves it, the stream gains a direct url while
        // keeping the original infoHash. So url + infoHash together means "a torrent a service already
        // resolved to an instant link" -> debrid tier, no matter how the add-on formats (or fails to tag)
        // its service tag, and regardless of any negative cache marker. Without this, a url+infoHash stream
        // carrying an unrecognized/uncached tag form falls through to .direct (tier 0, below torrents) -- the
        // "played a torrent over my debrid" regression. Mirrors Apple StreamRanking.swift:624
        // (`if s.url != nil, s.infoHash != nil { return .debrid }`), in the same position (after usenet,
        // before the tag branches).
        if (source.url != null && source.infoHash != null) return SourceType.DEBRID
        if (matches(text, """\[(rd|ad|pm|tb|dl|oc|ed|st|db|pp|putio)([+⚡⏳⬇🔄]|\s+download|\s+[cu])?\]""")) return SourceType.DEBRID
        if (matches(text, """(?<![a-z0-9])(rd|ad|pm|tb|dl|oc|ed|st|db|pp)(?![a-z0-9])\s*[⚡⏳⬇)]""") ||
            matches(text, """\(instant\s+(rd|ad|pm|tb|dl|oc|ed|st|db|pp)\)""")
        ) return SourceType.DEBRID
        if (text.contains("debrid") || text.contains("premiumize") || text.contains("torbox") ||
            text.contains("offcloud") || text.contains("pikpak") || text.contains("put.io")
        ) return SourceType.DEBRID
        if (source.isTorrent) return SourceType.TORRENT
        if (isCached(source, text)) return SourceType.DEBRID
        return SourceType.DIRECT
    }

    /// Whether this stream plays instantly (debrid-cached / direct). Explicit add-on markers override the
    /// handle-shape heuristic. Order matters: "uncached" contains "cached", so negatives test first. Mirrors
    /// Apple `isCached`.
    private fun isCached(source: StreamSource, text: String): Boolean {
        if (text.contains("⏳") || text.contains("⬇") || text.contains("uncached") ||
            text.contains("not ready") || text.contains("🎟") ||
            matches(text, """\[(rd|ad|pm|tb|dl|oc|ed|st|db|pp|putio)\s+download\]""")
        ) return false
        if (text.contains("⚡") || matches(text, """\[(rd|ad|pm|tb|dl|oc|ed|st|db|pp|putio)\+\]""") ||
            matches(text, """instant\s*(rd|ad|pm|tb|dl|oc|ed|st|db|pp|putio)(?![a-z0-9])""") ||
            boundedMatch(technicalTags(text), "cached") || text.contains("🎫")
        ) return true
        return !source.isTorrent
    }

    // ---- Text parsing ----

    private val regexCache = ConcurrentHashMap<String, Regex>()
    private val textCache = ConcurrentHashMap<String, String>()

    private fun re(pattern: String): Regex = regexCache.getOrPut(pattern) {
        runCatching { Regex(pattern) }.getOrElse { Regex(Regex.escape(pattern)) }
    }

    /// Whether `pattern` matches anywhere in `text`, via the compiled-pattern cache. Mirrors Apple
    /// `matches`.
    fun matches(text: String, pattern: String): Boolean = re(pattern).containsMatchIn(text)

    /// `pattern` matched only at delimiter boundaries (no alphanumeric on either side), so "ts" can't fire
    /// inside DTS or "hc" inside HEVC. Text is lowercase. Mirrors Apple `boundedMatch`.
    fun boundedMatch(text: String, pattern: String): Boolean =
        matches(text, "(?<![a-z0-9])(?:$pattern)(?![a-z0-9])")

    private fun firstMatch(text: String, pattern: String): String? = re(pattern).find(text)?.value

    /// The stream's quality text: name + description + quality + filename, lowercased, with the variation
    /// selector + container extensions stripped and add-on template blobs removed BEFORE any token is
    /// parsed. Mirrors Apple `qualityText` (name + description + behaviorHints.filename); memoized per stream
    /// id. The [StreamSource.filename] (behaviorHints.filename) carries the real release tags many
    /// debrid/torrent add-ons put there, so it is folded in exactly as Apple does.
    private fun qualityText(source: StreamSource): String {
        val key = source.id
        textCache[key]?.let { return it }
        var text = listOfNotNull(source.title, source.description, source.quality, source.filename)
            .joinToString(" ")
            .lowercase()
            .replace("\uFE0F", "") // strip the emoji variation selector so "bolt+VS16" matches a bare bolt
        text = stripTemplateBlobs(text)
        text = re("""\.(ts|m2ts|mkv|mp4|avi|webm|mov)(?![a-z0-9])""").replace(text, "")
        if (textCache.size > 32_768) textCache.clear()
        textCache[key] = text
        return text
    }

    /// Remove add-on template blobs (any `{ … }` run) before classification. Bounded passes so a
    /// pathological input can't spin. Mirrors Apple `stripTemplateBlobs`.
    private fun stripTemplateBlobs(text: String): String {
        if (!text.contains("{")) return text
        val re = re("""\{[^{}]*\}""")
        var out = text
        repeat(4) {
            if (!out.contains("{")) return out
            val replaced = re.replace(out, " ")
            if (replaced == out) return out
            out = replaced
        }
        return out
    }

    /// The technical-tags substring (from the first year or resolution marker onward), where cache/audio
    /// language tags live. Mirrors Apple `technicalTags`.
    private fun technicalTags(text: String): String {
        val marker = firstMatch(text, """(?:19|20)\d{2}|2160p?|1080p?|720p?|480p?""") ?: return text
        val idx = text.indexOf(marker)
        return if (idx >= 0) text.substring(idx) else text
    }

    /// Explicit numeric resolution token, boundary-checked, winning over marketing tokens. Mirrors Apple
    /// `explicitResolution`.
    private fun explicitResolution(t: String): Int? {
        val tokens = listOf("2160" to 4000, "1440" to 1440, "1080" to 1080, "720" to 720, "576" to 576, "540" to 540, "480" to 480)
        for ((token, value) in tokens) if (boundedMatch(t, "${token}p?")) return value
        return null
    }

    /// The parsed resolution when the text carries a recognizable token, null when none. Mirrors Apple
    /// `knownResolution`.
    private fun knownResolution(t: String): Int? {
        explicitResolution(t)?.let { return it }
        if (boundedMatch(t, "4k") || boundedMatch(t, "uhd")) return 4000
        return null
    }

    private fun resolution(t: String): Int = knownResolution(t) ?: 100

    /// True when the text advertises Dolby Vision, via the SAME wide predicate the Apple router trusts.
    /// Mirrors Apple `isDolbyVision`.
    private fun isDolbyVisionText(text: String): Boolean =
        matches(text, """(dolby[ ._-]?vision|dolbyvision|\bdovi\b|dovihdr|\bdv\b|\bdvhdr\b|bl\+?rpu|\bp(?:rofile[ ._-]?)?[578](?:\.[0-9])?\b|\bdv[ ._-]?p?[578]\b)""")

    /// File size in GB, folding "GiB"/"GB"; 0 when absent or only MB-sized. Clamped so adversarial text
    /// can't overflow. Mirrors Apple `sizeGB`.
    private fun sizeGB(t: String): Double {
        val m = firstMatch(t, """(\d+(?:\.\d+)?)\s*g(i)?b""") ?: return 0.0
        val digits = m.lowercase().replace("gib", "").replace("gb", "").trim()
        return minOf(digits.toDoubleOrNull() ?: 0.0, 100_000.0)
    }

    private fun sizeMB(t: String): Double {
        val m = firstMatch(t, """(\d+(?:\.\d+)?)\s*m(i)?b""") ?: return 0.0
        val digits = m.lowercase().replace("mib", "").replace("mb", "").trim()
        return digits.toDoubleOrNull() ?: 0.0
    }

    /// Seeder count where torrent add-ons print it ("👤 47" or "Seeders: 47"). Clamped at the parse
    /// boundary. Mirrors Apple `seederCount`.
    private fun seederCount(text: String): Int? {
        val patterns = listOf("""👤[:\s]*([0-9]+)""", """(?<![a-z0-9])seed(er)?s?\s*:\s*([0-9]+)""")
        for (pattern in patterns) {
            firstMatch(text, pattern)?.let { m ->
                val digits = m.filter { it.isDigit() }
                digits.toLongOrNull()?.let { return minOf(it, 1_000_000L).toInt() }
            }
        }
        return null
    }

    /// True when the stream advertises a resolution but its KNOWN file size is far too small to be real at
    /// that resolution. Conservative floors; false when size is unknown. Mirrors Apple
    /// `implausibleForResolution`.
    private fun implausibleForResolution(text: String): Boolean {
        val gb = sizeGB(text)
        val mb = if (gb > 0) gb * 1024 else sizeMB(text)
        if (mb <= 0) return false
        val isEpisode = firstMatch(text, """s\d{1,2}[ ._-]?e\d{1,2}""") != null ||
            text.contains("season") || text.contains("episode")
        if (text.contains("2160") || boundedMatch(text, "4k") || boundedMatch(text, "uhd")) {
            return mb < (if (isEpisode) 700 else 1800)
        }
        if (boundedMatch(text, "1080p?")) {
            return mb < (if (isEpisode) 150 else 600)
        }
        return false
    }

    /// Theatrical-rip / fake-release class, null for anything legitimate. Mirrors Apple `junkClass`.
    private fun junkClass(text: String): String? {
        if (boundedMatch(text, """h[dq][ .\-_]?cam(rip)?|cam[ .\-_]?rip|s[ .\-]+print""")) return "CAM"
        if (boundedMatch(text, """telesynch?|hd[ .\-_]?ts(rip)?|ts[ .\-_]?rip""")) return "TS"
        if (boundedMatch(text, """telecine|hd[ .\-_]?tc""")) return "TC"
        if (text.contains("screener") || boundedMatch(text, """(dvd|bd|br|web|hd)[ .\-_]?scr|p(re)?dvd(rip)?""")) return "SCR"
        if (text.contains("workprint")) return "Workprint"
        if (boundedMatch(text, "r5")) return "R5"
        if (boundedMatch(text, """1xbet|read[ .\-_]?note|(?<!not[ .\-_])(?<!non[ .\-_])(upscaled?|up[ .\-_]?rez)|ai[ .\-_]?(upscaled?|enhanced?)|re[ .\-_]?graded?""")) return "Upscaled"
        val hasGoodSource = text.contains("remux") || text.contains("bluray") || text.contains("blu-ray") ||
            boundedMatch(text, """b[dr][ .\-_]?rip|web[ .\-_]?(dl|rip)?|hdtv|dvd[ .\-_]?rip""")
        if (hasGoodSource) return null
        if (boundedMatch(text, "cam")) return "CAM"
        if (boundedMatch(text, "ts")) return "TS"
        if (boundedMatch(text, "scr")) return "SCR"
        return null
    }

    /// The playable handle for de-duplication: the url/infoHash before the `#name#desc` suffix
    /// [com.vortx.android.engine.EngineState] encodes into [StreamSource.id].
    private fun handleOf(source: StreamSource): String = source.id.substringBefore('#')
}
