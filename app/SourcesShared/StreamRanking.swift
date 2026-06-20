import Foundation

/// Ranks loaded streams so the strongest source surfaces first and "Watch Now" can auto-pick one.
///
/// For a debrid user the dominant signals are whether the source is **cached / direct** (instant, a
/// non-torrent URL) and its **resolution**; REMUX / BluRay / HDR act as tiebreakers. Quality is parsed
/// from the stream's name + description + filename, where add-ons put their tags. Deliberately simple:
/// seeders matter mainly for raw torrents, which a debrid user rarely lands on.
enum StreamRanking {
    // MARK: - Caches

    /// `String.range(of:options:.regularExpression)` recompiles the ICU pattern on EVERY call,
    /// and one score() runs ~15 patterns; a long stream list re-ranked per render meant
    /// thousands of regex compilations per pass (the 0.2.45 sluggishness). Patterns compile
    /// once, and each stream's parsed text and final score are memoized.
    private static let cacheLock = NSLock()
    private static var regexCache: [String: NSRegularExpression] = [:]
    private static var textCache: [Int: String] = [:]
    private static var scoreCache: [Int: Int] = [:]

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let hit = regexCache[pattern] { return hit }
        guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
        if regexCache.count > 256 { regexCache.removeAll() }   // defensive cap; the pattern set is fixed today
        regexCache[pattern] = compiled
        return compiled
    }

    /// Whether `pattern` matches anywhere in `text`, via the compiled-pattern cache.
    static func matches(_ text: String, _ pattern: String) -> Bool {
        guard let re = regex(pattern) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The first match of `pattern` in `text`, via the compiled-pattern cache.
    private static func firstMatch(_ text: String, _ pattern: String) -> String? {
        guard let re = regex(pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }

    /// Per-stream memoization key over every field that feeds the text parse.
    private static func streamKey(_ s: CoreStream) -> Int {
        var hasher = Hasher()
        hasher.combine(s.url); hasher.combine(s.infoHash); hasher.combine(s.name)
        hasher.combine(s.description); hasher.combine(s.behaviorHints?.filename)
        return hasher.finalize()
    }

    /// Drop memoized scores; called when ranking preferences change (scores embed them).
    static func invalidateCaches() {
        cacheLock.lock(); scoreCache.removeAll(); cacheLock.unlock()
    }

    /// The stream's quality text, exposed for source-continuity hints.
    static func signature(_ s: CoreStream) -> String { qualityText(s) }

    /// Prefer the next episode from the same release family as what is playing:
    /// same resolution and flavor usually means the same release group, which the
    /// provider often already has hot.
    static func continuityBonus(_ s: CoreStream, hint: String?) -> Int {
        guard let hint, !hint.isEmpty else { return 0 }
        let text = qualityText(s)
        var bonus = 0
        for res in ["2160", "1080", "720"] where boundedMatch(hint, "\(res)p?") {
            if boundedMatch(text, "\(res)p?") { bonus += 800 }
            break
        }
        if hint.contains("remux"), text.contains("remux") { bonus += 500 }
        else if hint.contains("web"), text.contains("web") { bonus += 300 }
        let hdrTokens = ["hdr", "dovi", "dolby vision", "dolbyvision"]
        if hdrTokens.contains(where: hint.contains), hdrTokens.contains(where: text.contains) { bonus += 300 }
        return bonus
    }

    /// An exact bingeGroup match is the strongest next-episode signal there is:
    /// the add-on is telling us this stream is the same release as the last one,
    /// so auto-next stays on the same group with no quality jump mid-binge.
    static func bingeBonus(_ s: CoreStream, group: String?) -> Int {
        guard let group, !group.isEmpty, s.behaviorHints?.bingeGroup == group else { return 0 }
        return 2500
    }

    /// best() with the continuity and bingeGroup bonuses applied on top of the base
    /// score. bingeGroup (exact, from the add-on) outweighs the quality-signature
    /// heuristic; both fall back to the plain best when absent.
    static func best(_ groups: [CoreStreamSourceGroup], continuity hint: String?, binge: String? = nil) -> CoreStream? {
        let groups = applyUserFilters(groups)
        if SourcePreferences.shared.useAddonOrder {
            return groups.flatMap { $0.streams }.first { $0.playableURL != nil }
        }
        let hasHint = hint?.isEmpty == false
        let hasBinge = binge?.isEmpty == false
        guard hasHint || hasBinge else { return best(groups) }
        let candidates = groups.flatMap { $0.streams }.filter { $0.playableURL != nil }
        return candidates.max { lhs, rhs in
            (score(lhs) + continuityBonus(lhs, hint: hint) + bingeBonus(lhs, group: binge)) <
            (score(rhs) + continuityBonus(rhs, hint: hint) + bingeBonus(rhs, group: binge))
        }
    }

    /// Whether a streams-loading wait should stop now and hand the result to `best(continuity:)`.
    ///
    /// For a RESUME (`rememberedQuality` set), it holds out until a stream MATCHING that quality has
    /// loaded, and (unless the user ranks torrents on top, or uses add-on order) a NON-TORRENT one:
    /// torrents answer in ~4s while the user's debrid/direct stream of that quality usually lands
    /// ~10-12s later, so a flat short cutoff auto-picked the fast torrent and a Continue-Watching
    /// resume "tried a torrent first" before reaching the user's stream. A generous ceiling stops a
    /// quality that never returns from hanging the resume. With no remembered quality (a fresh play),
    /// it keeps the original short window so picking stays snappy. `best()` still ranks the final
    /// choice, so a torrent-first user's order is honored once their stream is in hand.
    static func resolveSettled(_ groups: [CoreStreamSourceGroup], loaded: Int, total: Int,
                               secondsSinceFirstPlayable seconds: TimeInterval,
                               rememberedQuality: String?) -> Bool {
        guard !groups.isEmpty else { return false }
        if total > 0, loaded >= total { return true }                  // every add-on has answered
        guard let hint = rememberedQuality, !hint.isEmpty else {
            return seconds > 4                                         // fresh play: original snappy window
        }
        let prefs = SourcePreferences.shared
        let torrentOK = prefs.useAddonOrder || prefs.typeOrder.first == .torrent
        let qualityReady = groups.contains { group in
            group.streams.contains { s in
                s.playableURL != nil && continuityBonus(s, hint: hint) > 0 && (torrentOK || !s.isTorrent)
            }
        }
        return qualityReady || seconds > 16                            // ceiling so a vanished quality cannot hang it
    }

    static func score(_ s: CoreStream) -> Int {
        let key = streamKey(s)
        cacheLock.lock()
        if let hit = scoreCache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let value = computeScore(s)
        cacheLock.lock()
        // Cap above the largest realistic source list (popular titles return a few thousand
        // streams across add-ons). At 4096 a single big title thrashed the cache mid-render
        // (clear, refill, clear) and lost the memoization it exists for; 32768 clears that while
        // still bounding a runaway.
        if scoreCache.count > 32_768 { scoreCache.removeAll() }
        scoreCache[key] = value
        cacheLock.unlock()
        return value
    }

    private static func computeScore(_ s: CoreStream) -> Int {
        let text = qualityText(s)
        var score = resolution(text)
        // Source ladder: STRICT and the dominant WITHIN-resolution key (issue #68 — a remux must beat
        // a bigger WEB-DL). The gaps (remux->bluray 80, bluray->web 75) both exceed the most a lower
        // source can earn from features + size (56 + 12 = 68), so source type strictly outranks them.
        // remux > bluray > web-dl > webrip > hdtv > dvdrip > tv captures.
        if text.contains("remux") { score += 230 }
        else if text.contains("bluray") || text.contains("blu-ray") || boundedMatch(text, #"b[dr][ .\-_]?rip"#) { score += 150 }
        else if boundedMatch(text, #"web[ .\-_]?dl"#) { score += 75 }
        else if boundedMatch(text, #"web[ .\-_]?rip"#) { score += 50 }
        else if boundedMatch(text, "web") { score += 75 }   // scene bare "WEB" tag = WEB-DL
        else if text.contains("hdtv") { score -= 150 }
        else if boundedMatch(text, #"dvd[ .\-_]?rip"#) { score -= 200 }
        else if text.contains("tvrip") || text.contains("satrip") || boundedMatch(text, #"pdtv"#) { score -= 300 }
        // Video range, fine-grained: DV > HDR10+ > HDR10/HLG > SDR. Checked specific-first so HDR10+
        // is not swallowed by the generic "hdr" test. Any HDR is effectively strict over SDR; the
        // gradations between HDR flavours are soft (a size tiebreak can nudge), which is fine.
        if text.contains("dolby vision") || text.contains("dolbyvision") || text.contains("dovi") { score += 30 }
        else if text.contains("hdr10+") || text.contains("hdr10plus") { score += 24 }
        else if text.contains("hdr") || text.contains("hlg") { score += 18 }
        // File size is now a SMALL final tiebreaker (cap +12), not a primary signal: it only orders
        // otherwise-equal streams (same resolution, source, and features) toward the bigger, higher-
        // bitrate file. It used to score up to +600 and could lift a big WEB-DL over a smaller remux
        // (the #68 bug); source type and features now sit strictly above it.
        score += min(Int(sizeGB(text) * 0.15), 12)
        // Audio quality ladder (object-based > lossless > lossy), additive with the video range above.
        if text.contains("atmos") { score += 26 }
        else if text.contains("dts:x") || text.contains("dtsx") || text.contains("dts-x") { score += 24 }
        else if text.contains("truehd") || text.contains("true-hd") { score += 20 }
        else if text.contains("dts-hd ma") || text.contains("dts-hd.ma") || text.contains("dts-ma") { score += 16 }
        else if text.contains("dts-hd") || text.contains("dts hd") || text.contains("dtshd") || text.contains("flac") || text.contains("lpcm") || boundedMatch(text, "pcm") { score += 12 }
        else if text.contains("eac3") || text.contains("e-ac3") || text.contains("dd+") || text.contains("ddp") || text.contains("ddplus") { score += 8 }
        else if text.contains("dts") { score += 6 }
        else if text.contains("ac3") || boundedMatch(text, "dd") || text.contains("dolby digital") { score += 4 }
        // Apple TV has no AV1 hardware decode on any model, so 4K AV1 lands on software decode
        // and struggles; 1080p AV1 is fine but still worth a nudge toward HEVC/H.264 peers.
        if boundedMatch(text, "av1") {
            score -= (text.contains("2160") || text.contains("4k") || text.contains("uhd")) ? 1500 : 150
        }
        // 3D releases render as a split frame on a flat TV. Bare "sbs" is NOT matched: it is
        // also a broadcaster tag on perfectly flat TV releases; the 3D forms below suffice.
        if boundedMatch(text, "3d") || boundedMatch(text, #"hsbs|half[ .\-_]?sbs|sbs[ .\-_]?3d"#) { score -= 2000 }
        // Hardcoded subtitle rips are watchable but defaced; nudge below clean peers.
        if text.contains("korsub") || boundedMatch(text, "hc") { score -= 200 }
        // Preferred-language demotion: a release that clearly advertises a foreign audio
        // language (and no preferred one) sinks 5,000 points, enough to fall below a
        // same-cache, same-type peer one resolution tier down. So a 4K labelled Chinese
        // loses to a 1080p English when the viewer's audio preference is English, which is
        // exactly the reported case. Smaller than the cached (+8000) and tier (15000) gaps,
        // so cache and the source-type order still win first. Untagged releases (most
        // English originals) are never penalised.
        score += languageScore(text)
        // Cached dominates WITHIN its tier: +8000 clears the maximum quality spread (~4300), so
        // a cached stream always beats an uncached one of the same source type, which is the
        // "uncached debrid kept winning" fix. It stays SMALLER than the 15k tier gap on purpose:
        // the user's source-type order is the top-level key, so someone who ranks Torrent or
        // Usenet above Debrid genuinely gets that order, cached or not.
        if isCached(s, text) { score += 8000 }
        // Source type is the dominant sort key: user-ranked tier (debrid > usenet > torrent >
        // direct by default) contributes a 15k-spaced weight that overrules quality and cache.
        let type = sourceType(s, text)
        score += SourcePreferences.shared.tierWeight(for: type)
        // Provider offset: a small INTRA-tier nudge that orders equal-quality streams between
        // providers without ever crossing a quality or tier boundary.
        score += providerOffset(for: provider(text))
        // Raw torrents live or die by swarm health; cached/debrid streams don't care. A dead
        // swarm sinks within its tier, a hot one earns a capped tiebreak bonus.
        if type == .torrent, let seeders = seederCount(text) {
            score += seeders == 0 ? -800 : min(seeders * 8, 400)
        }
        // Fake-quality guard: a file far too small for the resolution it claims is mislabelled
        // (Comet and other raw-passthrough add-ons surface these; a 50 MB "4K" has been seen
        // labelled and auto-picked as best). Only fires when the size is KNOWN and implausibly
        // small for the claimed resolution, so a genuinely small low-res episode is never hit.
        if implausibleForResolution(text) { score -= 100_000 }
        // Theatrical rips and fake "quality" releases rank below every legitimate stream of any
        // tier, cached or not (the legit ceiling is ~60k). The shift is uniform, so if only
        // junk exists the least-bad junk still wins.
        if junkClass(text) != nil { score -= 100_000 }
        return score
    }

    /// `pattern` matched only at delimiter boundaries: no alphanumeric on either side, so "ts"
    /// can't fire inside DTS, "cam" inside camera, or "hc" inside HEVC tags. Text is lowercase.
    static func boundedMatch(_ text: String, _ pattern: String) -> Bool {
        matches(text, "(?<![a-z0-9])(?:\(pattern))(?![a-z0-9])")
    }

    /// Theatrical-rip / fake-release class parsed from the stream text, nil for anything
    /// legitimate. Two pattern lists, after the Radarr / parse-torrent-title playbook:
    /// long unambiguous forms always match; bare ambiguous tokens (cam/ts/tc/scr) only count
    /// when NO good-source marker is present, so "Cam.2018.1080p.WEB-DL" stays a WEB-DL.
    static func junkClass(_ text: String) -> String? {
        if boundedMatch(text, #"h[dq][ .\-_]?cam(rip)?|cam[ .\-_]?rip|s[ .\-]+print"#) { return "CAM" }
        if boundedMatch(text, #"telesynch?|hd[ .\-_]?ts(rip)?|ts[ .\-_]?rip"#) { return "TS" }
        if boundedMatch(text, #"telecine|hd[ .\-_]?tc"#) { return "TC" }
        // "screener" by substring: run-together compounds (DVDScreener) defeat the boundary check.
        if text.contains("screener") || boundedMatch(text, #"(dvd|bd|br|web|hd)[ .\-_]?scr|p(re)?dvd(rip)?"#) { return "SCR" }
        if text.contains("workprint") { return "Workprint" }
        if boundedMatch(text, "r5") { return "R5" }
        // Negation guard: "real 4K, NOT upscaled" advertises the opposite.
        if boundedMatch(text, #"1xbet|read[ .\-_]?note|(?<!not[ .\-_])(?<!non[ .\-_])(upscaled?|up[ .\-_]?rez)|ai[ .\-_]?(upscaled?|enhanced?)|re[ .\-_]?graded?"#) {
            return "Upscaled"
        }
        // Bare tokens: honoured only when nothing marks the release as a real source.
        // Substring checks for remux/bluray on purpose: compounds like BDRemux must count.
        let hasGoodSource = text.contains("remux") || text.contains("bluray") || text.contains("blu-ray")
            || boundedMatch(text, #"b[dr][ .\-_]?rip|web[ .\-_]?(dl|rip)?|hdtv|dvd[ .\-_]?rip"#)
        guard !hasGoodSource else { return nil }
        if boundedMatch(text, "cam") { return "CAM" }
        if boundedMatch(text, "ts") { return "TS" }
        if boundedMatch(text, "scr") { return "SCR" }
        return nil
    }

    /// Audio-language markers per ISO code. Full words use substring matching; short codes and
    /// CJK glyphs are checked too. Deliberately conservative: only strong, unambiguous tokens,
    /// so an untagged English release is never flagged foreign.
    private static let langTokens: [String: [String]] = [
        "en": ["english", "🇬🇧", "🇺🇸"],
        "es": ["spanish", "español", "espanol", "castellano", "latino"],
        "fr": ["french", "français", "francais", "truefrench", "vostfr"],
        "de": ["german", "deutsch"],
        "it": ["italian", "italiano"],
        "pt": ["portuguese", "português", "portugues", "dublado", "legendado"],
        "hi": ["hindi", "🇮🇳"],
        "ja": ["japanese", "日本", "日本語"],
        "ko": ["korean", "한국", "korsub"],
        "zh": ["chinese", "mandarin", "cantonese", "中文", "中字", "国语", "粤语", "简体", "繁體"],
        "ar": ["arabic", "العربية"],
        "ru": ["russian", "русск"],
    ]

    /// Demote ONLY a release that clearly advertises a single foreign audio language (and not the
    /// viewer's). Priority is the viewer's SELECTED audio language, not English; a release carrying
    /// that language, or any multi-language release, is never demoted. So a 4K that is ONLY Chinese
    /// loses to a 1080p in the viewer's language, but a multi-language 4K (which almost always
    /// carries or can select the viewer's track) keeps its resolution rank. The earlier version
    /// only exempted the literal words "multi"/"dual", so a release tagging several real languages
    /// it could not perfectly match was wrongly sunk below a single-language lower resolution.
    static func languageScore(_ text: String) -> Int {
        let preferred = Set(TrackPreferences.current.audioLanguages)
        guard !preferred.isEmpty else { return 0 }
        // Carries the viewer's selected language (anywhere): rank normally.
        if preferred.contains(where: { claimsLanguage(text, $0) }) { return 0 }
        // Multi-language release: never demote (it likely carries or can select the viewer's track).
        if isMultiLanguage(text) { return 0 }
        // Single, clearly-foreign release: demote so the viewer's language wins over resolution.
        // Only match the foreign token in the TECHNICAL-TAGS portion (after the year/resolution), not
        // the title, so a foreign word in an English title is not mistaken for foreign audio
        // ("The French Dispatch" / "The Italian Job" are English). Conservative: if no year or
        // resolution marker is present, the whole text is treated as tags (current behaviour).
        let tags = technicalTags(text)
        let foreign = langTokens.keys.filter { !preferred.contains($0) }
        return foreign.contains(where: { claimsLanguage(tags, $0) }) ? -5000 : 0
    }

    /// The technical-tags substring (from the first year or resolution marker onward), where audio
    /// language tags live. The title precedes it; a language WORD in the title is not an audio claim.
    private static func technicalTags(_ text: String) -> String {
        guard let marker = firstMatch(text, #"(?:19|20)\d{2}|2160p?|1080p?|720p?|480p?"#),
              let r = text.range(of: marker) else { return text }
        return String(text[r.lowerBound...])
    }

    /// True when `text` advertises audio language `code` (full words by substring, short codes and
    /// CJK glyphs boundary-checked).
    private static func claimsLanguage(_ text: String, _ code: String) -> Bool {
        (langTokens[code] ?? []).contains { token in
            token.count <= 3 ? boundedMatch(text, token) : text.contains(token)
        }
    }

    /// True when a release advertises more than one audio language, so demoting it for "not being
    /// in your language" would be wrong. Catches the explicit markers (multi, multilang,
    /// multi-audio, dual, dual audio), any release tagging two or more distinct languages, and any
    /// release carrying two or more country flags (a common multi-audio convention).
    static func isMultiLanguage(_ text: String) -> Bool {
        if text.contains("multi") || text.contains("dual") { return true }
        if langTokens.keys.filter({ claimsLanguage(text, $0) }).count >= 2 { return true }
        return flagCount(text) >= 2
    }

    /// Number of country-flag emoji in `text`. A flag is a pair of Unicode regional-indicator
    /// scalars (U+1F1E6 to U+1F1FF), so the scalar count over two is the flag count, regardless of
    /// which countries, and works for flags not listed in langTokens.
    private static func flagCount(_ text: String) -> Int {
        text.unicodeScalars.filter { (0x1F1E6...0x1F1FF).contains($0.value) }.count / 2
    }

    /// True when the stream advertises a resolution but its KNOWN file size is far too small to
    /// be real at that resolution (a mislabelled or fake file). Conservative floors, well below
    /// any legitimate release, so real content is never caught; returns false when no size is
    /// parseable (we can't judge) or for sub-1080p where small files are normal.
    static func implausibleForResolution(_ text: String) -> Bool {
        let gb = sizeGB(text)
        let mb = gb > 0 ? gb * 1024 : sizeMB(text)
        guard mb > 0 else { return false }   // unknown size: cannot judge
        if text.contains("2160") || boundedMatch(text, "4k") || boundedMatch(text, "uhd") {
            return mb < 250   // a real 4K movie is multi-GB; even a 4K episode clears this easily
        }
        if boundedMatch(text, "1080p?") {
            return mb < 50    // a 1080p feature under 50 MB is not real video
        }
        return false           // 720p and below: small files are legitimately common
    }

    /// File size in MB parsed from the add-on's stream text, when given in MB (not GB).
    private static func sizeMB(_ t: String) -> Double {
        guard let m = firstMatch(t, #"(\d+(?:\.\d+)?)\s*m(i)?b"#) else { return 0 }
        let digits = m.lowercased()
            .replacingOccurrences(of: "mib", with: "").replacingOccurrences(of: "mb", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(digits) ?? 0
    }

    /// Seeder count parsed from the stream text, where torrent add-ons print it
    /// (e.g. "👤 47" or "Seeders: 47"). The emoji form wins over the worded form, and the
    /// worded form requires its colon, so a title like "The Bad Seed 2018" can't supply a
    /// phantom count. nil when absent.
    static func seederCount(_ text: String) -> Int? {
        let patterns = [#"👤[:\s]*([0-9]+)"#, #"(?<![a-z0-9])seed(er)?s?\s*:\s*([0-9]+)"#]
        for pattern in patterns {
            if let m = firstMatch(text, pattern) {
                return Int(m.filter(\.isNumber))
            }
        }
        return nil
    }

    /// File size in GB for a user-chosen "by size" sort of the source list, folding both spellings an
    /// add-on uses ("12.4 GB" or "850 MB"); 0 when no size is advertised, so unknown-size streams sink
    /// to the bottom of a size sort instead of floating to the top.
    static func sizeForSort(_ s: CoreStream) -> Double {
        let text = qualityText(s)
        let gb = sizeGB(text)
        return gb > 0 ? gb : sizeMB(text) / 1024
    }

    /// Seeder count for a user-chosen "by seeders" sort; -1 when none is advertised (debrid / direct
    /// streams never print one), so health-sorting keeps real torrents above link-only sources.
    static func seedersForSort(_ s: CoreStream) -> Int { seederCount(qualityText(s)) ?? -1 }

    /// Classify a stream into the four source categories used for user-rankable tier scoring.
    /// The tag grammar below is verified against the formatter source of the four major
    /// stream add-ons; missing a form here drops a debrid stream into the DIRECT tier
    /// (weight 0, below raw torrents), which is exactly the "played a torrent over my
    /// debrid" failure.
    static func sourceType(_ s: CoreStream, _ text: String) -> SourceType {
        // Usenet first: a debrid service's usenet results carry the same service code.
        if text.contains("usenet") || text.contains("nzb") || text.contains("easynews")
            || text.contains("📰") { return .usenet }
        // Resolved torrent = debrid/cached, detected STRUCTURALLY (add-on-agnostic). A RAW torrent has an
        // infoHash and NO url; once a debrid/cached service resolves it, the stream gains a direct `url`
        // while keeping the original infoHash. So url + infoHash together means "a torrent a service already
        // resolved to an instant link" -> debrid tier, no matter how the add-on formats its service tag.
        // This is the fix for a debrid stream sinking to .direct (tier 0, BELOW raw torrents) when its tag
        // text is not in the grammar below: every add-on / user config writes those tags differently, so the
        // structural signal is the reliable one. Raw torrents (url == nil) still fall to .torrent below.
        if s.url != nil, s.infoHash != nil { return .debrid }
        // Bracketed service tag with any cache suffix: [RD+], [AD⚡], [TB⏳], [PM download],
        // [RD⬇], [RD C]/[RD U] (kodi forms), [RD🔄].
        if matches(text, #"\[(rd|ad|pm|tb|dl|oc|ed|st|db|pp|putio)([+⚡⏳⬇🔄]|\s+download|\s+[cu])?\]"#) {
            return .debrid
        }
        // Unbracketed short code adjacent to a cache marker: "RD ⚡" / "AD ⏳" (MediaFusion),
        // "(Instant RD)" / "(RD)" (AIOStreams torbox format).
        if matches(text, #"(?<![a-z0-9])(rd|ad|pm|tb|dl|oc|ed|st|db|pp)(?![a-z0-9])\s*[⚡⏳⬇)]"#)
            || matches(text, #"\(instant\s+(rd|ad|pm|tb|dl|oc|ed|st|db|pp)\)"#) {
            return .debrid
        }
        // Full service names ("debrid" covers realdebrid / alldebrid / debrid-link / easydebrid).
        if text.contains("debrid") || text.contains("premiumize") || text.contains("torbox")
            || text.contains("offcloud") || text.contains("pikpak") || text.contains("put.io") {
            return .debrid
        }
        if s.isTorrent { return .torrent }
        // A non-torrent stream that advertises a cache marker is a resolved/cached link from a
        // debrid-like service whose name/tag we didn't recognise above. Rank it debrid-equivalent
        // rather than DIRECT (tier weight 0, below raw torrents), the exact "played a torrent over
        // my cached debrid" failure when a new add-on uses a tag form not in the grammar. Plain
        // direct HTTP streams from add-ons do not carry cache markers, so this won't catch them.
        if isCached(s, text) { return .debrid }
        return .direct
    }

    /// Known debrid / usenet services detected from the stream text. Foundation for a future
    /// user-rankable provider order (like the source-type order); for now only the default
    /// offsets below apply.
    enum ServiceProvider {
        case realDebrid, allDebrid, premiumize, torbox, debridLink, offcloud, easynews, unknown
    }

    /// Service detection. The two-letter tags are only honoured with their "+" suffix or in
    /// brackets: bare "ad" is an Audio Description tag and bare "tb" is a terabyte size, so the
    /// loose forms misclassified ordinary streams as debrid. "rd" alone stays matched (no
    /// release-name collision in practice, and AIOStreams prints it unbracketed).
    static func provider(_ text: String) -> ServiceProvider {
        if isRealDebrid(text) { return .realDebrid }
        if text.contains("alldebrid") || text.contains("all-debrid") || text.contains("[ad+]")
            || matches(text, #"\bad\+"#) { return .allDebrid }
        if text.contains("premiumize") || text.contains("[pm+]")
            || matches(text, #"\bpm\+"#) { return .premiumize }
        if text.contains("torbox") || text.contains("[tb+]")
            || matches(text, #"\btb\+"#) { return .torbox }
        if text.contains("debrid-link") || text.contains("debridlink") || text.contains("[dl+]") { return .debridLink }
        if text.contains("offcloud") || text.contains("[oc+]") { return .offcloud }
        if text.contains("easynews") { return .easynews }
        return .unknown
    }

    /// Intra-tier provider preference. NEUTRAL: no service is favoured or penalised, so debrid providers
    /// rank purely by the user's source-type order + quality. The old Real-Debrid -150 penalty was removed
    /// (do not single out any one service). Kept as the hook for a future user-configurable per-provider
    /// order, which will populate this table.
    static func providerOffset(for provider: ServiceProvider) -> Int {
        _ = provider
        return 0
    }

    /// File size in GB parsed from the add-on's stream text (name / description / filename),
    /// where most add-ons print it (e.g. "💾 54.3 GB"). 0 when absent or only MB-sized.
    private static func sizeGB(_ t: String) -> Double {
        guard let m = firstMatch(t, #"(\d+(?:\.\d+)?)\s*g(i)?b"#) else { return 0 }
        let digits = m.lowercased()
            .replacingOccurrences(of: "gib", with: "")
            .replacingOccurrences(of: "gb", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(digits) ?? 0
    }

    /// Matches the Real-Debrid service name plus the bracketed/delimited "RD"/"RD+" tags add-ons
    /// put in stream names; the word-boundary regex cannot match inside words like HDR. Feeds the
    /// provider() detection, where RD carries a small intra-tier penalty.
    static func isRealDebrid(_ qualityText: String) -> Bool {
        if qualityText.contains("realdebrid") || qualityText.contains("real-debrid")
            || qualityText.contains("real debrid") { return true }
        return matches(qualityText, #"\brd\+?\b"#)
    }

    /// Each group's streams sorted best-first, stable within equal scores (so add-on order is preserved
    /// among ties). Scores are computed once per stream, not per comparison.
    /// Whether a stream survives the user's keyword + safety filters (Settings > Streams). Default
    /// preferences pass everything, so this is a no-op until the user opts in.
    static func passesUserFilters(_ s: CoreStream) -> Bool {
        let prefs = SourcePreferences.shared
        let kids = ProfileStore.activeIsKids()
        if !kids, prefs.noFiltersActive { return true }   // fast path: nothing opted in (and not a Kids profile)
        let text = qualityText(s)
        if kids {
            // Kids profile: always hide explicit content and CAM/fake junk, whatever the user filters say.
            if isAdultContent(text) || junkClass(text) != nil { return false }
        }
        if prefs.noFiltersActive { return true }
        if prefs.keywordsAreRegex {
            // Power-user regex mode: Hide = drop on match, Require = drop on no-match. An invalid pattern
            // compiled to nil, so it imposes no constraint (fail-open).
            if let rx = prefs.excludeRegex, prefs.matches(rx, text) { return false }
            if let rx = prefs.includeRegex, !prefs.matches(rx, text) { return false }
        } else {
            let exclude = prefs.excludeTerms, include = prefs.includeTerms
            if exclude.contains(where: { text.contains($0) }) { return false }
            if !include.isEmpty, !include.contains(where: { text.contains($0) }) { return false }
        }
        switch prefs.safetyMode {
        case "balanced": if junkClass(text) != nil { return false }
        case "strict":   if junkClass(text) != nil || implausibleForResolution(text) { return false }
        default: break
        }
        if prefs.instantOnly, !isCached(s, text) { return false }                       // only cached / direct
        if prefs.hideDeadTorrents, sourceType(s, text) == .torrent,
           let seeders = seederCount(text), seeders == 0 { return false }               // explicitly-dead swarm
        if prefs.excludeAV1, boundedMatch(text, "av1") { return false }                 // no Apple AV1 hw decode
        if prefs.hdrOnly, !(text.contains("hdr") || text.contains("dolby vision")
            || text.contains("dolbyvision") || text.contains("dovi")) { return false }
        if prefs.maxResolution > 0, resolution(text) > prefs.maxResolution { return false }  // cap known resolutions
        if prefs.maxFileSizeGB > 0 {                                                          // cap advertised file size
            let gb = sizeGB(text) > 0 ? sizeGB(text) : sizeMB(text) / 1024
            if gb > 0, gb > prefs.maxFileSizeGB { return false }                              // unknown-size sources pass
        }
        return true
    }

    /// Explicit-content blocklist for Kids profiles, matched as bounded tokens in the lowercased
    /// name+description+filename so an ordinary title is not tripped while an adult release is. This is a
    /// best-effort source guard (it can't see a catalog's age rating); pair it with PIN-locked adult
    /// profiles and per-profile add-on hiding for fuller parental control.
    private static func isAdultContent(_ text: String) -> Bool {
        let terms = ["xxx", "porn", "porno", "hentai", "brazzers", "onlyfans", "nsfw", "jav", "camgirl"]
        return terms.contains { boundedMatch(text, $0) }
    }

    /// Drop streams that fail the user filters, and any group left empty. No-op when nothing is set.
    /// Aggregator "reasons / statistics" pseudo-streams (AIOStreams Stream-Expression output, SeaDex/SEL
    /// setups, etc.) are a filter EXPLANATION, not playable video. They inherit the resolution-group tag
    /// they describe (often "4K"), which wrongly made them the top "Watch in 4K" pick and inflated the 4K
    /// bucket while every real stream was 1080p. Detect by the diagnostic headings these add-ons emit and
    /// drop them from EVERY path (ranking, the quality buckets, the Watch-in label, the dropdown).
    static func isNonVideo(_ s: CoreStream) -> Bool {
        let t = qualityText(s)
        let markers = ["included reasons", "removal reasons", "excluded resolution", "stream expression",
                       "year matching", "no streams found", "no results found", "stream statistics"]
        return markers.contains { t.contains($0) }
    }

    /// Strip the non-video diagnostic pseudo-streams unconditionally (BEFORE the user-filter early-out),
    /// so they are gone even when the user has no quality filters active.
    private static func stripNonVideo(_ groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        groups.compactMap { group in
            let kept = group.streams.filter { !isNonVideo($0) }
            return kept.isEmpty ? nil : CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: kept)
        }
    }

    static func applyUserFilters(_ groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        let groups = stripNonVideo(groups)   // always: diagnostic/info pseudo-streams are never real video
        let prefs = SourcePreferences.shared
        // A Kids profile must run passesUserFilters even with zero manual filters (its content guard
        // lives there), so only take the no-op fast path when not a Kids profile.
        guard !prefs.noFiltersActive || ProfileStore.activeIsKids() else { return groups }
        return groups.compactMap { group in
            let kept = group.streams.filter { passesUserFilters($0) }
            return kept.isEmpty ? nil : CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: kept)
        }
    }

    static func rankedGroups(_ groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        let groups = applyUserFilters(groups)
        guard !SourcePreferences.shared.useAddonOrder else { return groups }
        return groups.map { group in
            var scored: [(stream: CoreStream, score: Int, index: Int)] = []
            for (i, stream) in group.streams.enumerated() {
                scored.append((stream: stream, score: score(stream), index: i))
            }
            scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            return CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: scored.map { $0.stream })
        }
    }

    /// The single best playable stream across all groups, for the one-press "Watch Now".
    static func best(_ groups: [CoreStreamSourceGroup]) -> CoreStream? {
        let groups = applyUserFilters(groups)
        if SourcePreferences.shared.useAddonOrder {
            return groups.flatMap { $0.streams }.first { $0.playableURL != nil }
        }
        return groups.flatMap { $0.streams }.filter { $0.playableURL != nil }.max { score($0) < score($1) }
    }

    /// The best playable stream for each distinct resolution (4K, 1080p, …), best-first — feeds the
    /// "Watch in 4K" button's resolution dropdown.
    static func resolutionOptions(_ groups: [CoreStreamSourceGroup]) -> [(label: String, stream: CoreStream)] {
        let playable = groups.flatMap { $0.streams }.filter { $0.playableURL != nil }
        var bestByLabel: [String: CoreStream] = [:]
        for s in playable {
            let label = qualityLabel(s)
            if let existing = bestByLabel[label], score(existing) >= score(s) { continue }
            bestByLabel[label] = s
        }
        return bestByLabel.map { (label: $0.key, stream: $0.value) }
            .sorted { score($0.stream) > score($1.stream) }
    }

    /// Distinct choices for the visible quality picker: the best stream per resolution-and-flavor
    /// combination, labeled the way people actually choose ("4K · Dolby Vision · Remux",
    /// "1080p · BluRay · Atmos"). Best-first, so the top option is what Watch Now would play.
    static func qualityOptions(_ groups: [CoreStreamSourceGroup]) -> [(label: String, stream: CoreStream)] {
        let playable = groups.flatMap { $0.streams }.filter { $0.playableURL != nil }
        var best: [String: (score: Int, stream: CoreStream)] = [:]
        for s in playable {
            let t = qualityText(s)
            var tags = [qualityLabel(s)]
            if t.contains("dolby vision") || t.contains("dolbyvision") || t.contains("dovi") || t.contains(" dv ") {
                tags.append("Dolby Vision")
            } else if t.contains("hdr") {
                tags.append("HDR")
            }
            if t.contains("remux") { tags.append("Remux") }
            else if t.contains("bluray") || t.contains("blu-ray") { tags.append("BluRay") }
            else if t.contains("web") { tags.append("WEB") }
            if t.contains("atmos") { tags.append("Atmos") }
            else if t.contains("truehd") { tags.append("TrueHD") }
            else if t.contains("dts-hd") || t.contains("dts hd") { tags.append("DTS-HD") }
            let label = tags.joined(separator: " · ")
            let sc = score(s)
            if let current = best[label], current.score >= sc { continue }
            best[label] = (sc, s)
        }
        return best.map { (label: $0.key, stream: $0.value.stream) }
            .sorted { score($0.stream) > score($1.stream) }
    }

    /// The resolution tiers that actually have playable sources, in fixed order, for the first
    /// level of the quality picker. Everything that is not 4K/1080p/720p lands in "Others".
    static func tiers(_ groups: [CoreStreamSourceGroup]) -> [String] {
        let playable = groups.flatMap { $0.streams }.filter { $0.playableURL != nil }
        var present = Set<String>()
        for s in playable { present.insert(tier(of: s)) }
        return ["4K", "1080p", "720p", "Others"].filter { present.contains($0) }
    }

    /// Second level of the quality picker: distinct flavor variants inside one resolution tier
    /// ("Dolby Vision · Remux", "HDR · Atmos", "BluRay"), best variant of each, best-first, capped.
    static func variantOptions(_ groups: [CoreStreamSourceGroup], tier wanted: String)
        -> [(label: String, stream: CoreStream)] {
        let playable = groups.flatMap { $0.streams }
            .filter { $0.playableURL != nil && tier(of: $0) == wanted }
        var best: [String: (score: Int, stream: CoreStream)] = [:]
        for s in playable {
            let t = qualityText(s)
            var tags: [String] = []
            if t.contains("dolby vision") || t.contains("dolbyvision") || t.contains("dovi") || t.contains(" dv ") {
                tags.append("Dolby Vision")
            } else if t.contains("hdr") {
                tags.append("HDR")
            }
            if t.contains("remux") { tags.append("Remux") }
            else if t.contains("bluray") || t.contains("blu-ray") { tags.append("BluRay") }
            else if t.contains("web") { tags.append("WEB") }
            if t.contains("atmos") { tags.append("Atmos") }
            else if t.contains("truehd") { tags.append("TrueHD") }
            else if t.contains("dts-hd") || t.contains("dts hd") { tags.append("DTS-HD") }
            let label = tags.isEmpty ? "Standard" : tags.joined(separator: " · ")
            let sc = score(s)
            if let current = best[label], current.score >= sc { continue }
            best[label] = (sc, s)
        }
        return best.map { entry -> (label: String, stream: CoreStream) in
            // The dedup key is the flavor; append the chosen stream's size for display.
            let size = sourceDetail(entry.value.stream).size
            let label = size.map { "\(entry.key)  ·  \($0)" } ?? entry.key
            return (label: label, stream: entry.value.stream)
        }
        .sorted { score($0.stream) > score($1.stream) }
        .prefix(8).map { $0 }
    }

    private static func tier(of s: CoreStream) -> String {
        switch qualityLabel(s) {
        case "4K": return "4K"
        case "1080p": return "1080p"
        case "720p": return "720p"
        default: return "Others"
        }
    }

    /// Everything a switcher row should say about a source: parsed tags
    /// (resolution, remux/web class, DV/HDR, audio, codec, cached) and the file
    /// size when the add-on includes one.
    /// The flavour tags WITHOUT the resolution label: Remux · HDR · Atmos · HEVC · Cached (+ a junk
    /// class when the source ranks at the bottom). For rows that show the resolution *separately* —
    /// the iOS/Mac source row renders it as a prominent badge, so repeating it in the tag line read
    /// as a doubled "4K · 4K · HDR". The in-player lists, which have no badge, use `sourceDetail`.
    static func flavorTags(_ s: CoreStream) -> [String] {
        let t = qualityText(s)
        var tags: [String] = []
        // Source / encode
        if t.contains("remux") { tags.append("Remux") }
        else if t.contains("bluray") || t.contains("blu-ray") { tags.append("BluRay") }
        else if t.contains("web") { tags.append("WEB") }
        // HDR formats are layered (Dolby Vision often sits over an HDR10 base), so they're additive
        // rather than exclusive — mirrors Stremio's "HDR10 | DV | HDR" line.
        if t.contains("dolby vision") || t.contains("dolbyvision") || t.contains("dovi")
            || matches(t, #"\bdv\b"#) { tags.append("DV") }
        if t.contains("hdr10+") || t.contains("hdr10plus") { tags.append("HDR10+") }
        else if t.contains("hdr10") { tags.append("HDR10") }
        else if t.contains("hdr") { tags.append("HDR") }
        // Audio format (one, best-first)
        if t.contains("atmos") { tags.append("Atmos") }
        else if t.contains("truehd") || t.contains("true-hd") { tags.append("TrueHD") }
        else if t.contains("dts-hd") || t.contains("dts hd") || t.contains("dtshd") { tags.append("DTS-HD") }
        else if t.contains("dts") { tags.append("DTS") }
        else if t.contains("eac3") || t.contains("e-ac3") || t.contains("ddp") || t.contains("dd+") { tags.append("DD+") }
        else if t.contains("ac3") || matches(t, #"\bdd\b"#) { tags.append("DD") }
        else if t.contains("aac") { tags.append("AAC") }
        // Channel layout
        if t.contains("7.1") { tags.append("7.1") }
        else if t.contains("5.1") { tags.append("5.1") }
        // Video codec
        if t.contains("hevc") || t.contains("x265") || t.contains("h265") || t.contains("h.265") { tags.append("HEVC") }
        else if t.contains("av1") { tags.append("AV1") }
        else if t.contains("x264") || t.contains("h264") || t.contains("h.264") { tags.append("H.264") }
        if isCached(s, t) { tags.append("Cached") }
        if let junk = junkClass(t) { tags.append(junk) }   // why this source sits at the bottom
        return tags
    }

    /// The parsed file size ("12.4 GB" / "850 MB"), or nil when the add-on didn't advertise one.
    static func sizeText(_ s: CoreStream) -> String? {
        let t = qualityText(s)
        if let m = firstMatch(t, #"(\d+(?:\.\d+)?)\s*(gb|gib)"#) {
            return m.uppercased().replacingOccurrences(of: "GIB", with: "GB")
        } else if let m = firstMatch(t, #"(\d+(?:\.\d+)?)\s*(mb|mib)"#) {
            return m.uppercased().replacingOccurrences(of: "MIB", with: "MB")
        }
        return nil
    }

    static func sourceDetail(_ s: CoreStream) -> (tags: String, size: String?) {
        let tags = [qualityLabel(s)] + flavorTags(s)
        return (tags.joined(separator: " · "), sizeText(s))
    }

    /// Explicit numeric resolution token ("1080p", "2160p", ...) parsed boundary-checked.
    /// It must WIN over the marketing tokens ("UHD", "4K"): a "UHD.BluRay.1080p.Remux" is a
    /// 1080p encode OF a UHD disc, and reading it as 4K both mislabelled the Watch button
    /// and made best() pick that 1080p file over genuine peers.
    private static func explicitResolution(_ t: String) -> Int? {
        for (token, value) in [("2160", 4000), ("1440", 1440), ("1080", 1080),
                               ("720", 720), ("576", 540), ("540", 540), ("480", 480)] {
            if boundedMatch(t, "\(token)p?") { return value }
        }
        return nil
    }

    /// A short resolution tag for the Watch-Now button ("4K" / "1080p" / …), or "Other" when the
    /// resolution can't be determined. ("Other", not "Best": an untagged source is unknown quality,
    /// not the best one.) A bare "4k"/"uhd" tag is only trusted when the file size isn't implausibly
    /// small for 4K, so a low-res file that merely carries a 4k tag isn't promoted to the 4K bucket.
    static func qualityLabel(_ s: CoreStream) -> String {
        let t = qualityText(s)
        if let r = explicitResolution(t) { return r >= 4000 ? "4K" : "\(r)p" }
        if (boundedMatch(t, "4k") || boundedMatch(t, "uhd")), !implausibleForResolution(t) { return "4K" }
        return "Other"
    }

    /// Enriched label for the Watch-Now button, derived from the EXACT stream best() will
    /// play so the button can never promise a quality it doesn't deliver:
    /// "4K · HDR · Remux", "1080p · WEB".
    static func watchLabel(_ s: CoreStream) -> String {
        let t = qualityText(s)
        var tags = [qualityLabel(s)]
        if t.contains("dolby vision") || t.contains("dolbyvision") || t.contains("dovi")
            || matches(t, #"\bdv\b"#) { tags.append("DV") }
        else if t.contains("hdr") { tags.append("HDR") }
        if t.contains("remux") { tags.append("Remux") }
        else if t.contains("bluray") || t.contains("blu-ray") { tags.append("BluRay") }
        else if boundedMatch(t, #"web[ .\-_]?(dl|rip)?"#) { tags.append("WEB") }
        return tags.joined(separator: " · ")
    }

    /// True when a stream's quality text advertises Dolby Vision. This is the only DV signal available
    /// before playback (a text parse); the engine router uses it to route DV to AVPlayer for true DV
    /// passthrough, which libmpv/MoltenVK cannot do (it only tone-maps DV to SDR). HDR10 is intentionally
    /// NOT included: libmpv's gpu-next renders HDR10 correctly, so only DV needs the AVPlayer path.
    static func isDolbyVision(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("dolby vision") || t.contains("dolbyvision") || t.contains("dovi") || matches(t, #"\bdv\b"#)
    }

    private static func qualityText(_ s: CoreStream) -> String {
        let key = streamKey(s)
        cacheLock.lock()
        if let hit = textCache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        // Container extensions are stripped from the WHOLE text, not just the filename field:
        // add-ons embed file names in the stream name or description too, and a plain ".ts"
        // (MPEG-TS) must never read as a TeleSync marker to the junk detector. Boundary-checked
        // so only a real dot-extension token disappears.
        // The variation selector comes off first: add-ons emit "⚡️" (U+26A1 U+FE0F), and Swift's
        // grapheme-cluster contains() would never match a bare "⚡" against it.
        var text = [s.name, s.description, s.behaviorHints?.filename]
            .compactMap { $0 }.joined(separator: " ").lowercased()
            .replacingOccurrences(of: "\u{FE0F}", with: "")
        if let re = regex(#"\.(ts|m2ts|mkv|mp4|avi|webm|mov)(?![a-z0-9])"#) {
            text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                               withTemplate: "")
        }
        cacheLock.lock()
        if textCache.count > 4096 { textCache.removeAll() }
        textCache[key] = text
        cacheLock.unlock()
        return text
    }

    private static func resolution(_ t: String) -> Int {
        if let r = explicitResolution(t) { return r }
        if boundedMatch(t, "4k") || boundedMatch(t, "uhd") { return 4000 }
        return 100   // unknown resolution: below any labelled stream, above nothing
    }

    /// Whether this stream plays instantly. Explicit add-on markers override the URL-shape
    /// heuristic: an UNCACHED debrid result is ALSO a plain URL (the resolve link), which the
    /// old shape-only check happily called cached, so Watch Now kept picking sources that then
    /// had to download into the debrid first (the "first pick always fails" reports).
    /// Marker sets verified against the four major add-ons' formatter source.
    /// Order matters: "uncached" contains "cached", so the negative markers test first.
    static func isCached(_ s: CoreStream, _ text: String) -> Bool {
        // "[RD download]" forms, "⏳" hourglass, "⬇" download arrow, "❌ not ready", "🎟" ticket.
        if text.contains("⏳") || text.contains("⬇") || text.contains("uncached")
            || text.contains("not ready") || text.contains("🎟")
            || boundedMatch(text, "download") {
            return false
        }
        // "[RD+]"-style plus tags, "⚡" bolt, "(Instant RD)", plain "cached", "🎫" ticket.
        if text.contains("⚡") || text.contains("+]") || text.contains("instant")
            || text.contains("cached") || text.contains("🎫") {
            return true
        }
        return s.url != nil && s.infoHash == nil   // plain URL with no contrary marker
    }
}
