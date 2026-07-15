package com.vortx.android.engine

import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import java.util.concurrent.ConcurrentHashMap

/// Ranks loaded streams so the strongest source surfaces first and the hero "Watch" button can
/// auto-pick one. The Android port of `app/SourcesShared/StreamRanking.swift`, adapted to the fields the
/// Android engine seam exposes on a [StreamSource] ([title] / [description] / [quality] / [isTorrent]).
///
/// The dominant signals mirror the Apple ranker's, in strict priority order:
///   1. source-type tier (debrid/cached > usenet > torrent > direct), 15000-spaced so it is the top key
///   2. debrid-cached / instant (+8000, clears the whole quality spread within a tier)
///   3. resolution (2160/4K > 1440 > 1080 > 720 > ...), then source ladder (remux > bluray > web > ...)
///   4. HDR/DV, audio (Atmos > TrueHD > DTS-HD > ...), file size as a small tiebreak, seeder health
///   5. junk / fake-quality / implausible-size guards sink a source below every legitimate stream
///
/// Quality is parsed from the stream's name + description (where add-ons put their tags), exactly like
/// Apple's `qualityText`. Deliberately fail-soft: an unrankable stream still scores (and still plays), so
/// a title with tag-less sources degrades to add-on order rather than dropping streams.
///
/// NOT ported (the Apple ranker's preference-driven layers): the user's Smart-Source chips, per-provider
/// order, keyword include/exclude filters, pins, continuity/binge next-episode bonuses, and the
/// audio-language demotion. Those all read `SourcePreferences`/`TrackPreferences`/`SourcePinStore`, which
/// the Android engine seam does not surface yet; when it does, fold them in here (this is the single
/// ranking source of truth on Android, the analogue of Apple's SourcesShared/StreamRanking).
object StreamRanking {

    // ---- Public ranking entry points ----

    /// Each group's streams sorted best-first (stable within equal scores, so add-on order is preserved
    /// among ties), and the GROUPS themselves ordered by their strongest member so the best add-on block
    /// leads. Mirrors Apple `rankedGroups`, with the extra group ordering the Android grouped-list UI wants.
    fun rankedGroups(groups: List<StreamGroup>): List<StreamGroup> {
        val ranked = groups.map { group ->
            val sorted = group.streams
                .mapIndexed { index, s -> ScoredStream(s, score(s), index) }
                .sortedWith(compareByDescending<ScoredStream> { it.score }.thenBy { it.index })
                .map { it.stream }
            group.copy(streams = sorted)
        }
        return ranked.sortedByDescending { g -> g.streams.firstOrNull()?.let { score(it) } ?: Int.MIN_VALUE }
    }

    /// The single best playable stream across ALL groups, for the one-press "Watch". Mirrors Apple
    /// `best(_:)`. Null when there is nothing to play.
    fun best(groups: List<StreamGroup>): StreamSource? =
        groups.flatMap { it.streams }.maxByOrNull { score(it) }

    /// The full ranked candidate list, best-first, de-duplicated by playable handle and capped per add-on
    /// so a single flooding add-on cannot bury the rest. Feeds a flat quality-labelled picker; the grouped
    /// UI uses [rankedGroups] instead. Stable within equal scores.
    fun rankedFlat(groups: List<StreamGroup>, perAddonCap: Int = PER_ADDON_CAP): List<StreamSource> {
        val perAddonCount = HashMap<String, Int>()
        val seenHandles = HashSet<String>()
        return groups.flatMap { it.streams }
            .mapIndexed { index, s -> ScoredStream(s, score(s), index) }
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

    // ---- Display helpers (labels the source UI renders) ----

    /// A short resolution tag for the quality badge ("4K" / "1080p" / …), or "Other" when the resolution
    /// can't be determined (an untagged source is unknown, not "best"). A bare 4K/UHD tag is only trusted
    /// when the file size isn't implausibly small for 4K. Mirrors Apple `qualityLabel`.
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
        if (isCached(source, t)) tags += "Cached"
        junkClass(t)?.let { tags += it }
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

    /// True when a source advertises Dolby Vision (the only pre-play DV signal, a text parse). Used to set
    /// [com.vortx.android.model.Playable.isDolbyVision] at resolve time so [com.vortx.android.player.PlayerEngineRouter]
    /// routes DV to the ExoPlayer engine. Mirrors Apple `isDolbyVision`.
    fun isDolbyVision(source: StreamSource): Boolean = isDolbyVisionText(qualityText(source))

    /// True when a source advertises Dolby Atmos / object audio, routed to the ExoPlayer engine for
    /// bitstream passthrough. Text parse, the only pre-play signal.
    fun isAtmos(source: StreamSource): Boolean = qualityText(source).contains("atmos")

    // ---- Scoring ----

    private data class ScoredStream(val stream: StreamSource, val score: Int, val index: Int)

    /// The within-tier seeder tiebreak cap, held strictly below the tier-step headroom (see the Apple
    /// ranker's derivation) so a hot swarm never lets a torrent cross its source-type tier.
    private const val SEEDER_TIEBREAK_CAP = 180

    /// Default per-add-on cap for the flat picker so one add-on returning thousands of near-duplicate
    /// sources cannot bury every other add-on's answers.
    private const val PER_ADDON_CAP = 12

    private val scoreCache = ConcurrentHashMap<String, Int>()

    fun score(source: StreamSource): Int {
        val key = source.id
        scoreCache[key]?.let { return it }
        val value = computeScore(source)
        if (scoreCache.size > 32_768) scoreCache.clear()
        scoreCache[key] = value
        return value
    }

    private fun computeScore(source: StreamSource): Int {
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
        // Cached dominates within its tier (+8000 clears the max quality spread).
        if (isCached(source, text)) score += 8000
        // Source type is the top-level key (15000-spaced tier weight).
        val type = sourceType(source, text)
        score += tierWeight(type)
        // Raw torrents live or die by swarm health; a dead swarm sinks, a hot one earns a capped tiebreak.
        if (type == SourceKind.TORRENT) {
            seederCount(text)?.let { seeders ->
                score += if (seeders == 0) -800 else minOf(seeders * 8, SEEDER_TIEBREAK_CAP)
            }
        }
        // Fake-quality + junk guards sink a source below every legitimate stream.
        if (implausibleForResolution(text)) score -= 100_000
        if (junkClass(text) != null) score -= 100_000
        return score
    }

    // ---- Source-type classification + tier weights ----

    private enum class SourceKind { DEBRID, USENET, TORRENT, DIRECT }

    /// Default tier order (debrid/cached > usenet > torrent > direct), 15000-spaced so source type is the
    /// dominant sort key. Matches the Apple ranker's DEFAULT `typeOrder` (there is no user-configurable
    /// order on Android yet, so the default is authoritative here).
    private fun tierWeight(kind: SourceKind): Int = when (kind) {
        SourceKind.DEBRID -> 45_000
        SourceKind.USENET -> 30_000
        SourceKind.TORRENT -> 15_000
        SourceKind.DIRECT -> 0
    }

    /// Classify a stream into the four user-rankable source categories. Mirrors Apple `sourceType`,
    /// dropping the media-server tier (no `vortxProvider` on Android). A raw torrent that a debrid service
    /// already resolved keeps a direct handle while still being flagged [StreamSource.isTorrent] == false,
    /// so it lands in DEBRID here.
    private fun sourceType(source: StreamSource, text: String): SourceKind {
        if (text.contains("usenet") || text.contains("nzb") || text.contains("easynews") || text.contains("📰")) return SourceKind.USENET
        // Bracketed service tag with a cache suffix, unbracketed short code adjacent to a cache marker, or
        // a full service name -> debrid.
        if (matches(text, """\[(rd|ad|pm|tb|dl|oc|ed|st|db|pp|putio)([+⚡⏳⬇🔄]|\s+download|\s+[cu])?\]""")) return SourceKind.DEBRID
        if (matches(text, """(?<![a-z0-9])(rd|ad|pm|tb|dl|oc|ed|st|db|pp)(?![a-z0-9])\s*[⚡⏳⬇)]""") ||
            matches(text, """\(instant\s+(rd|ad|pm|tb|dl|oc|ed|st|db|pp)\)""")
        ) return SourceKind.DEBRID
        if (text.contains("debrid") || text.contains("premiumize") || text.contains("torbox") ||
            text.contains("offcloud") || text.contains("pikpak") || text.contains("put.io")
        ) return SourceKind.DEBRID
        if (source.isTorrent) return SourceKind.TORRENT
        // A non-torrent stream advertising a cache marker is a resolved/cached link from a service whose
        // tag we didn't recognise; rank it debrid-equivalent, never DIRECT (below raw torrents).
        if (isCached(source, text)) return SourceKind.DEBRID
        return SourceKind.DIRECT
    }

    /// Whether this stream plays instantly (debrid-cached / direct). Explicit add-on markers override the
    /// handle-shape heuristic. Order matters: "uncached" contains "cached", so negatives test first.
    /// Mirrors Apple `isCached`, with Android's [StreamSource.isTorrent] standing in for the url/infoHash
    /// shape (a non-torrent handle with no contrary marker is an instant direct/resolved link).
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

    private fun matches(text: String, pattern: String): Boolean = re(pattern).containsMatchIn(text)

    /// `pattern` matched only at delimiter boundaries (no alphanumeric on either side), so "ts" can't fire
    /// inside DTS or "hc" inside HEVC. Text is lowercase. Mirrors Apple `boundedMatch`.
    private fun boundedMatch(text: String, pattern: String): Boolean =
        matches(text, "(?<![a-z0-9])(?:$pattern)(?![a-z0-9])")

    private fun firstMatch(text: String, pattern: String): String? = re(pattern).find(text)?.value

    /// The stream's quality text: name + description + quality label, lowercased, with the variation
    /// selector and container extensions stripped and add-on template blobs removed BEFORE any token is
    /// parsed (a broken `{…}` template can leak literal "4k"/"2160p" that poisons classification). Mirrors
    /// Apple `qualityText`; memoized per stream id.
    private fun qualityText(source: StreamSource): String {
        val key = source.id
        textCache[key]?.let { return it }
        var text = listOfNotNull(source.title, source.description, source.quality)
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
    /// language tags live. The title precedes it, so a title word is not read as a tag. Mirrors Apple.
    private fun technicalTags(text: String): String {
        val marker = firstMatch(text, """(?:19|20)\d{2}|2160p?|1080p?|720p?|480p?""") ?: return text
        val idx = text.indexOf(marker)
        return if (idx >= 0) text.substring(idx) else text
    }

    /// Explicit numeric resolution token, boundary-checked, winning over marketing tokens (a
    /// "UHD.BluRay.1080p.Remux" is a 1080p encode of a UHD disc). Mirrors Apple `explicitResolution`.
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

    /// True when the text advertises Dolby Vision, via the SAME wide predicate the Apple router trusts (a
    /// profile-only label like DV.P8 / Profile 8 / BL+RPU still counts). A false positive only routes to
    /// ExoPlayer (which plays the file regardless). Mirrors Apple `isDolbyVision`.
    private fun isDolbyVisionText(text: String): Boolean =
        matches(text, """(dolby[ ._-]?vision|dolbyvision|\bdovi\b|dovihdr|\bdv\b|\bdvhdr\b|bl\+?rpu|\bp(?:rofile[ ._-]?)?[578](?:\.[0-9])?\b|\bdv[ ._-]?p?[578]\b)""")

    /// File size in GB, folding "GiB"/"GB"; 0 when absent or only MB-sized. Clamped at a generous ceiling
    /// so adversarial add-on text can't overflow the Int conversion. Mirrors Apple `sizeGB`.
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
    /// boundary so `seeders * 8` can't overflow. Mirrors Apple `seederCount`.
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
    /// that resolution (a mislabelled/fake file). Conservative floors; false when size is unknown. Mirrors
    /// Apple `implausibleForResolution`.
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

    /// Theatrical-rip / fake-release class, null for anything legitimate. Long unambiguous forms always
    /// match; bare ambiguous tokens only count when no good-source marker is present. Mirrors Apple
    /// `junkClass`.
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
    /// [com.vortx.android.engine.EngineState] encodes into [StreamSource.id]. Matches the same handle
    /// [EngineStremioRepository.resolve] extracts.
    private fun handleOf(source: StreamSource): String = source.id.substringBefore('#')
}
