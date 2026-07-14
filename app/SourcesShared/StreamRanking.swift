import Foundation

/// Ranks loaded streams so the strongest source surfaces first and "Watch Now" can auto-pick one.
///
/// For a debrid user the dominant signals are whether the source is **cached / direct** (instant, a
/// non-torrent URL) and its **resolution**; REMUX / BluRay / HDR act as tiebreakers. Quality is parsed
/// from the stream's name + description + filename, where add-ons put their tags. Deliberately simple:
/// seeders matter mainly for raw torrents, which a debrid user rarely lands on.
enum StreamRanking {
    // MARK: - Tier-step budget

    /// The within-tier seeder tiebreak cap, held STRICTLY below the headroom left under the 15000
    /// source-type tier step after the other within-tier lifts: 15000 - prefer(2500) - cache(8000) -
    /// max quality spread(4313) = 187, so any cap <= 186 keeps the sum strictly under 15000. The max
    /// quality spread is the EXACT worst case from computeScore: resolution 4000 (2160/4K/UHD, no 8K
    /// token) + remux 230 + DV 45 + size 12 + Atmos 26 = 4313 (providerOffset is 0, languageScore is
    /// never positive). Capping at 180 keeps a preferred, cached, top-quality torrent with a hot swarm
    /// (the corner case) at most at 14813 + 180 = 14993 < 15000, strictly inside its source-type tier,
    /// so this last within-tier bonus can never be what pushes the sum past the step and lets a lower
    /// tier leapfrog a higher one, and leaves a 6-point margin under the 186 ceiling. min() against it
    /// stays monotonic in seeders, so relative swarm-health order within the tier is preserved.
    static let seederTiebreakCap = 180

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

    /// A user-pinned source floats above everything else. The bonus dwarfs the entire score range (the
    /// quality spread is 4313, cached is +8000, the source-type tier gap is 15000) so a matching stream
    /// wins the one-press auto-pick and tops the list - yet it is still only a *score*, so the player's
    /// invisible failover hops straight off it if it turns out to be dead. See `SourcePinStore.matches`.
    static func pinBonus(_ s: CoreStream, addon: String, pin: ResolvedPin?) -> Int {
        guard let pin, SourcePinStore.matches(s, addon: addon, pin: pin) else { return 0 }
        return 1_000_000
    }

    /// Coarse release flavor for a pin's human label only: Remux > BluRay > WEB, "" when none is tagged.
    static func releaseFlavor(_ s: CoreStream) -> String {
        let text = qualityText(s)
        if text.contains("remux") { return "Remux" }
        if text.contains("bluray") || text.contains("blu-ray") || boundedMatch(text, #"b[dr][ .\-_]?rip"#) { return "BluRay" }
        if boundedMatch(text, "web") { return "WEB" }
        return ""
    }

    /// best() with the continuity and bingeGroup bonuses applied on top of the base
    /// score. bingeGroup (exact, from the add-on) outweighs the quality-signature
    /// heuristic; both fall back to the plain best when absent.
    static func best(_ groups: [CoreStreamSourceGroup], continuity hint: String?, binge: String? = nil,
                     pin: ResolvedPin? = nil, debridCachedHashes: Set<String> = []) -> CoreStream? {
        let groups = applyUserFilters(groups, debridCachedHashes: debridCachedHashes)
        if SourcePreferences.reading.useAddonOrder {
            // Add-on order is the user's explicit "don't re-rank" choice, but a pin is an even more
            // explicit "play THIS" - so an applicable pin still wins, falling back to add-on order.
            if pin != nil, let hit = firstPinned(groups, pin: pin) { return hit }
            return groups.flatMap { $0.streams }.first { $0.playableURL != nil && !$0.isYouTubeTrailer }
        }
        let hasHint = hint?.isEmpty == false
        let hasBinge = binge?.isEmpty == false
        guard hasHint || hasBinge || pin != nil else { return best(groups, pin: pin, debridCachedHashes: debridCachedHashes) }
        let candidates = playablePairs(groups)
        return candidates.max { lhs, rhs in
            (score(lhs.stream, debridCachedHashes: debridCachedHashes) + continuityBonus(lhs.stream, hint: hint) + bingeBonus(lhs.stream, group: binge) + pinBonus(lhs.stream, addon: lhs.addon, pin: pin)) <
            (score(rhs.stream, debridCachedHashes: debridCachedHashes) + continuityBonus(rhs.stream, hint: hint) + bingeBonus(rhs.stream, group: binge) + pinBonus(rhs.stream, addon: rhs.addon, pin: pin))
        }?.stream
    }

    /// The full playable candidate list ranked EXACTLY as `best(_:continuity:binge:pin:)` picks its winner
    /// (score + continuity + binge + pin), best-first, de-duplicated by playable URL. Feeds the batch-download
    /// auto-retry (#119 remainder): on a failed episode it drops the winning source and queues the NEXT distinct
    /// source with the identical ranking the batch used. Returns [] when nothing is playable. In the user's
    /// explicit add-on-order mode the list keeps add-on/list order (the "don't re-rank" choice) but still fronts
    /// an applicable pin, matching best()'s add-on-order branch, so candidates.first is best()'s winner.
    static func rankedCandidates(_ groups: [CoreStreamSourceGroup], continuity hint: String?, binge: String? = nil,
                                 pin: ResolvedPin? = nil, debridCachedHashes: Set<String> = []) -> [CoreStream] {
        let groups = applyUserFilters(groups, debridCachedHashes: debridCachedHashes)
        let pairs = playablePairs(groups)
        let ordered: [CoreStream]
        if SourcePreferences.reading.useAddonOrder {
            // Mirror best()'s add-on-order branch EXACTLY: an applicable pin is the user's explicit
            // "play THIS", so front the pinned stream ahead of add-on/list order. The URL de-dup below
            // drops the pinned stream's second appearance, so candidates.first == best()'s winner.
            if pin != nil, let hit = firstPinned(groups, pin: pin) {
                ordered = [hit] + pairs.map { $0.stream }
            } else {
                ordered = pairs.map { $0.stream }
            }
        } else {
            ordered = pairs.enumerated()
                .map { (offset: $0.offset,
                        stream: $0.element.stream,
                        score: score($0.element.stream, debridCachedHashes: debridCachedHashes)
                            + continuityBonus($0.element.stream, hint: hint)
                            + bingeBonus($0.element.stream, group: binge)
                            + pinBonus($0.element.stream, addon: $0.element.addon, pin: pin)) }
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }   // stable within ties
                .map { $0.stream }
        }
        var seenURLs = Set<String>()
        return ordered.filter { s in
            guard let u = s.playableURL?.absoluteString else { return false }
            return seenURLs.insert(u).inserted
        }
    }

    /// Streams paired with their source group's add-on, the form pin matching needs (a flattened stream
    /// loses which add-on it came from, which the `global`/provider pin keys on).
    private static func playablePairs(_ groups: [CoreStreamSourceGroup]) -> [(addon: String, stream: CoreStream)] {
        groups.flatMap { g in g.streams.map { (addon: g.addon, stream: $0) } }
            .filter { $0.stream.playableURL != nil && !$0.stream.isYouTubeTrailer }
    }

    /// The first playable stream that matches a pin, in add-on/list order. Used by the add-on-order path.
    private static func firstPinned(_ groups: [CoreStreamSourceGroup], pin: ResolvedPin?) -> CoreStream? {
        guard let pin else { return nil }
        return playablePairs(groups).first { SourcePinStore.matches($0.stream, addon: $0.addon, pin: pin) }?.stream
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
        let prefs = SourcePreferences.reading
        let torrentOK = prefs.useAddonOrder || prefs.typeOrder.first == .torrent
        let qualityReady = groups.contains { group in
            group.streams.contains { s in
                s.playableURL != nil && !s.isYouTubeTrailer && continuityBonus(s, hint: hint) > 0 && (torrentOK || !s.isTorrent)
            }
        }
        return qualityReady || seconds > 16                            // ceiling so a vanished quality cannot hang it
    }

    static func score(_ s: CoreStream, debridCachedHashes: Set<String> = []) -> Int {
        // A coordinator-confirmed debrid cache hit adjusts the score, so it must NOT share a memo entry with
        // the same stream scored without the cached set (that would leak a hit-adjusted score into an empty-set
        // call and vice-versa). Earlier this BYPASSED the memo for cached hits, but that made every cached
        // stream re-run full computeScore on every call: on iOS the control bar re-ranks per body eval, so
        // 4000 cached streams times N evals of unmemoized regex scoring saturated the main thread. Instead fold
        // the cached bit INTO the Int memo key (re-hash of the base key plus the hit flag, the same 64-bit
        // collision class streamKey itself already tolerates) so both variants coexist and both stay memoized.
        // Folding a single BIT is sound because computeScore reads the set only through membership of this
        // stream's own infoHash (the isCached +8000 override), so the score depends on the set through
        // exactly that bit. The empty set, which is every existing non-debrid call site, keeps the plain
        // streamKey and is byte-identical to before.
        let isCachedHit = !debridCachedHashes.isEmpty
            && (s.infoHash?.lowercased()).map(debridCachedHashes.contains) == true
        let key: Int
        if isCachedHit {
            var hasher = Hasher()
            hasher.combine(streamKey(s))
            hasher.combine(true)
            key = hasher.finalize()
        } else {
            key = streamKey(s)
        }
        cacheLock.lock()
        if let hit = scoreCache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let value = isCachedHit ? computeScore(s, debridCachedHashes: debridCachedHashes) : computeScore(s)
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

    private static func computeScore(_ s: CoreStream, debridCachedHashes: Set<String> = []) -> Int {
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
        // is not swallowed by the generic "hdr" test. Any HDR is effectively strict over SDR.
        //
        // DV uses the SAME wide predicate the engine router trusts (isDolbyVision), not a narrow
        // "dolby vision"/"dovi" token match. Two reasons: (1) a source labeled only by profile
        // (DV.P8, Profile 8, BL+RPU, DoViHDR) routes to the true-DV AVPlayer lane at play time but,
        // under the old narrow match, scored as pure SDR here, so any "hdr" peer (+18) outranked it
        // and the auto-pick took HDR10 over a real DV source; using isDolbyVision makes ranking and
        // routing agree. (2) The bonus is raised to +45 so a real DV source beats an equal-resolution
        // HDR10 source (+18) by MORE than the size tiebreak can swing (cap +12 below), so an equal-res
        // HDR10 file cannot overtake DV on file size alone. +45 still sits well below the source and
        // resolution tiers (remux +230, bluray +150, and the resolution ladder), so a 1080p DV source
        // never leapfrogs a 4K HDR10 remux: DV stays a within-tier preference, not a cross-tier override.
        if StreamRanking.isDolbyVision(text) { score += 45 }
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
        // Smart Source Selection (Lane A): the Prefer boost and, in "rank" mode, the Avoid demotion. Read
        // through SourcePreferences.reading so the off-main rank uses the frozen Snapshot (race contract).
        // Prefer +2500 lifts a matching source WITHIN its tier but is sized so prefer + cache (+8000) + the
        // max quality spread (4313) stays UNDER the 15000 source-type tier step, so a preferred-and-cached
        // lower-tier source can never leapfrog a higher tier (the anti-regression invariant that source-type
        // order is the top-level key). Avoid -20000 sinks a matching source well past the quality spread yet
        // stays above the -100000 junk floor, so an avoided source is demoted but still VISIBLE (the whole
        // point of "rank"). Neither touches the HARD junkClass / Kids drops, which remain in passesUserFilters.
        score += chipScoreOffset(text)
        // Cached dominates WITHIN its tier: +8000 clears the maximum quality spread (4313), so
        // a cached stream always beats an uncached one of the same source type, which is the
        // "uncached debrid kept winning" fix. It stays SMALLER than the 15k tier gap on purpose:
        // the user's source-type order is the top-level key, so someone who ranks Torrent or
        // Usenet above Debrid genuinely gets that order, cached or not.
        if isCached(s, text, debridCachedHashes: debridCachedHashes) { score += 8000 }
        // Source type is the dominant sort key: user-ranked tier (debrid > usenet > torrent >
        // direct by default) contributes a 15k-spaced weight that overrules quality and cache.
        // A coordinator-confirmed cached raw torrent KEEPS its .torrent type here: this is an
        // awareness-only slice, so it still plays via the torrent server, not debrid. The +8000 cached
        // bonus above lifts it WITHIN the torrent tier; the .debrid retag waits for the cached-PLAY path.
        let type = sourceType(s, text)
        score += SourcePreferences.reading.tierWeight(for: type)
        // Provider offset: a small INTRA-tier nudge that orders equal-quality streams between
        // providers without ever crossing a quality or tier boundary.
        score += providerOffset(for: provider(text))
        // Raw torrents live or die by swarm health; cached/debrid streams don't care. A dead
        // swarm sinks within its tier, a hot one earns a capped tiebreak bonus. The cap is held
        // below the tier-step headroom (see seederTiebreakCap) so a preferred + cached + top-quality
        // hot-swarm torrent still cannot cross its source-type tier step.
        if type == .torrent, let seeders = seederCount(text) {
            score += seeders == 0 ? -800 : min(seeders * 8, seederTiebreakCap)
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

    /// Smart Source Selection (Lane A) score offset for a stream's quality text: a Prefer-term boost plus,
    /// when Avoid behavior is "rank", an Avoid-term demotion. Both magnitudes are chosen against the same
    /// ladder the cache/junk bonuses use (see `computeScore`): +2500 is a within-tier lift small enough that
    /// prefer + cache (+8000) + the max quality spread (4313) stays under the 15000 tier step (so a
    /// preferred-and-cached source never crosses its source-type tier); -20000 sinks a source below the
    /// quality spread but keeps it above the -100000 junk floor so it stays visible.
    static func chipScoreOffset(_ text: String) -> Int {
        let prefs = SourcePreferences.reading
        var offset = 0
        if !prefs.preferTerms.isEmpty, prefs.preferTerms.contains(where: { text.contains($0) }) {
            offset += 2500
        }
        if prefs.avoidBehavior == "rank", avoidMatches(text, prefs) {
            offset -= 20_000
        }
        return offset
    }

    /// Whether the stream text matches the viewer's Avoid (Hide / exclude) terms, honoring regex vs
    /// substring mode the same way `passesUserFilters` does. Used only by the "rank" Avoid path.
    private static func avoidMatches(_ text: String, _ prefs: SourcePrefsReading) -> Bool {
        if prefs.keywordsAreRegex {
            if let rx = prefs.excludeRegex { return prefs.matches(rx, text) }
            return false
        }
        return prefs.excludeTerms.contains(where: { text.contains($0) })
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
        return foreign.contains(where: { claimsAudioLanguage(tags, $0) }) ? -5000 : 0
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

    /// Subtitle-context tokens that also live in `langTokens` (korsub = Korean SUBS, vostfr = French SUBS,
    /// legendado = Portuguese SUBS). They stay in `langTokens` so `languageCodesAdvertised` and the subtitle
    /// index keep detecting them, but they must NOT drive the foreign-AUDIO demotion: such a release is
    /// usually the original audio with those subtitles burned in, not that language's audio.
    private static let subtitleContextTokens: Set<String> = ["korsub", "vostfr", "legendado"]

    /// True when `text` advertises AUDIO language `code`. Like `claimsLanguage`, but ignores subtitle-context
    /// tokens so a burned-in-subtitle release (korsub / vostfr / legendado) is never read as foreign audio.
    private static func claimsAudioLanguage(_ text: String, _ code: String) -> Bool {
        (langTokens[code] ?? []).contains { token in
            guard !subtitleContextTokens.contains(token) else { return false }
            return token.count <= 3 ? boundedMatch(text, token) : text.contains(token)
        }
    }

    /// PUBLIC reuse point for the language-index client: the ISO codes `text` plausibly advertises, using the
    /// SAME `langTokens` map + boundary matching the ranker uses (single source of truth, no duplication). Case
    /// insensitive; returns the sorted, de-duplicated set of matched codes. Empty when none match. No user data
    /// is involved -- only language codes derived from the passed strings.
    static func languageCodesAdvertised(in text: String) -> [String] {
        let lowered = text.lowercased()
        return langTokens.keys.filter { claimsLanguage(lowered, $0) }.sorted()
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
        // An episode is a fraction of a feature's runtime, so it gets a lower floor than a movie. The
        // SxxEyy token (or "season"/"episode") is the only content-type signal in the stream text.
        let isEpisode = firstMatch(text, #"s\d{1,2}[ ._-]?e\d{1,2}"#) != nil
            || text.contains("season") || text.contains("episode")
        if text.contains("2160") || boundedMatch(text, "4k") || boundedMatch(text, "uhd") {
            // A real 4K movie is multi-GB; a 4K episode is hundreds of MB. A 720p file merely TAGGED 4K
            // (the "200 MB 4K" case) sits far below these floors and is distrusted.
            return mb < (isEpisode ? 700 : 1800)
        }
        if boundedMatch(text, "1080p?") {
            return mb < (isEpisode ? 150 : 600)   // a 1080p feature/episode below this is not real video
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
    static func passesUserFilters(_ s: CoreStream, debridCachedHashes: Set<String> = []) -> Bool {
        let prefs = SourcePreferences.reading
        let kids = ProfileStore.activeIsKids()
        if !kids, prefs.noFiltersActive { return true }   // fast path: nothing opted in (and not a Kids profile)
        let text = qualityText(s)
        if kids {
            // Kids profile: always hide explicit content and CAM/fake junk, whatever the user filters say.
            if isAdultContent(text) || junkClass(text) != nil { return false }
        }
        if prefs.noFiltersActive { return true }
        // Smart Source Selection (Lane A): the Require (include / "Only") terms are ALWAYS a hard require in
        // both Avoid modes. The Hide (exclude / "Avoid") terms only DROP here when avoidBehavior == "hide"
        // (today's exact behavior); in "rank" mode they stop dropping and instead sink the score in
        // computeScore, so the avoided source stays visible but demoted.
        // On a Kids profile the Avoid words are a PARENTAL hide tool: they always DROP here, never merely
        // demote, whatever avoidBehavior says, so a parent can hard-hide words for a child even when the
        // profile (or a synced setting) has Avoid behavior on "rank". Defense in depth over the per-profile
        // fold: the guard holds even if a "rank" value ever reaches a Kids profile's flat keys.
        let avoidRanks = prefs.avoidBehavior == "rank" && !kids
        if prefs.keywordsAreRegex {
            // Power-user regex mode: Hide = drop on match, Require = drop on no-match. An invalid pattern
            // compiled to nil, so it imposes no constraint (fail-open).
            if !avoidRanks, let rx = prefs.excludeRegex, prefs.matches(rx, text) { return false }
            if let rx = prefs.includeRegex, !prefs.matches(rx, text) { return false }
        } else {
            let exclude = prefs.excludeTerms, include = prefs.includeTerms
            if !avoidRanks, exclude.contains(where: { text.contains($0) }) { return false }
            if !include.isEmpty, !include.contains(where: { text.contains($0) }) { return false }
        }
        switch prefs.safetyMode {
        case "balanced": if junkClass(text) != nil { return false }
        case "strict":   if junkClass(text) != nil || implausibleForResolution(text) { return false }
        default: break
        }
        if prefs.instantOnly, !isCached(s, text, debridCachedHashes: debridCachedHashes) { return false }  // only cached / direct or account-cached
        if prefs.hideDeadTorrents, sourceType(s, text) == .torrent,
           let seeders = seederCount(text), seeders == 0 { return false }               // explicitly-dead swarm
        if prefs.excludeAV1, boundedMatch(text, "av1") { return false }                 // no Apple AV1 hw decode
        if prefs.hdrOnly, !(text.contains("hdr") || text.contains("dolby vision")
            || text.contains("dolbyvision") || text.contains("dovi")) { return false }
        if prefs.maxResolution > 0, resolution(text) > prefs.maxResolution { return false }  // cap known resolutions
        if prefs.minResolution > 0, let res = knownResolution(text),
           res < prefs.minResolution { return false }   // floor KNOWN resolutions; unlabelled sources are kept (#117)
        if prefs.hideUnknownResolution, knownResolution(text) == nil { return false }  // no recognizable resolution token (#117)
        // Best-effort audio-language filter (#117): drop ONLY when the parse POSITIVELY identifies a
        // single foreign-audio release (languageScore's conservative -5000 case). A release with no
        // language stated, the viewer's language, or multiple languages scores 0 and is always kept,
        // so untagged add-on output can never be emptied by this toggle.
        if prefs.preferredAudioOnly, languageScore(text) < 0 { return false }
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

    static func applyUserFilters(_ groups: [CoreStreamSourceGroup], debridCachedHashes: Set<String> = []) -> [CoreStreamSourceGroup] {
        let groups = stripNonVideo(groups)   // always: diagnostic/info pseudo-streams are never real video
        let prefs = SourcePreferences.reading
        // A Kids profile must run passesUserFilters even with zero manual filters (its content guard
        // lives there), so only take the no-op fast path when not a Kids profile.
        guard !prefs.noFiltersActive || ProfileStore.activeIsKids() else { return groups }
        return groups.compactMap { group in
            let kept = group.streams.filter { passesUserFilters($0, debridCachedHashes: debridCachedHashes) }
            return kept.isEmpty ? nil : CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: kept)
        }
    }

    static func rankedGroups(_ groups: [CoreStreamSourceGroup], pin: ResolvedPin? = nil,
                             debridCachedHashes: Set<String> = []) -> [CoreStreamSourceGroup] {
        let groups = applyUserFilters(groups, debridCachedHashes: debridCachedHashes)
        guard !SourcePreferences.reading.useAddonOrder else { return groups }
        return groups.map { group in
            var scored: [(stream: CoreStream, score: Int, index: Int)] = []
            for (i, stream) in group.streams.enumerated() {
                scored.append((stream: stream, score: score(stream, debridCachedHashes: debridCachedHashes) + pinBonus(stream, addon: group.addon, pin: pin), index: i))
            }
            scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            return CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: scored.map { $0.stream })
        }
    }

    /// The single best playable stream across all groups, for the one-press "Watch Now".
    static func best(_ groups: [CoreStreamSourceGroup], pin: ResolvedPin? = nil,
                     debridCachedHashes: Set<String> = []) -> CoreStream? {
        let groups = applyUserFilters(groups, debridCachedHashes: debridCachedHashes)
        if SourcePreferences.reading.useAddonOrder {
            if pin != nil, let hit = firstPinned(groups, pin: pin) { return hit }
            return groups.flatMap { $0.streams }.first { $0.playableURL != nil && !$0.isYouTubeTrailer }
        }
        return playablePairs(groups).max { (score($0.stream, debridCachedHashes: debridCachedHashes) + pinBonus($0.stream, addon: $0.addon, pin: pin)) < (score($1.stream, debridCachedHashes: debridCachedHashes) + pinBonus($1.stream, addon: $1.addon, pin: pin)) }?.stream
    }

    /// The best playable stream for each distinct resolution (4K, 1080p, …), best-first — feeds the
    /// "Watch in 4K" button's resolution dropdown.
    static func resolutionOptions(_ groups: [CoreStreamSourceGroup]) -> [(label: String, stream: CoreStream)] {
        let playable = groups.flatMap { $0.streams }.filter { $0.playableURL != nil && !$0.isYouTubeTrailer }
        var bestByLabel: [String: CoreStream] = [:]
        for s in playable {
            let label = qualityLabel(s)
            if let existing = bestByLabel[label], score(existing) >= score(s) { continue }
            bestByLabel[label] = s
        }
        return bestByLabel.map { (label: $0.key, stream: $0.value) }
            .sorted { score($0.stream) > score($1.stream) }
    }

    /// The stream's resolution as a comparable tier number (4000 / 2160 / 1080 / 720 / …), the same
    /// scale `resolution(_:)` scores on, exposed so the player's auto-failover can compare how far a
    /// candidate would drop below the best cached option and refuse a >1-tier quality plunge (the
    /// "picked 4K, got 480p" report). Reads only the parsed quality text, so it is add-on-agnostic.
    static func resolutionRank(_ s: CoreStream) -> Int { resolution(qualityText(s)) }

    /// Whether a source plays instantly (debrid-cached / direct), the convenience form of `isCached`
    /// that parses the quality text for the caller. Used by the player's failover to prefer a cached
    /// source over an uncached one when hopping automatically.
    static func isCachedSource(_ s: CoreStream, debridCachedHashes: Set<String> = []) -> Bool {
        isCached(s, qualityText(s), debridCachedHashes: debridCachedHashes)
    }

    /// The resolution tier of the best CACHED (instant) playable source across the loaded groups, or 0
    /// when nothing cached is loaded yet. The auto-failover uses this as the ceiling reference so it
    /// never hops down more than one tier below a genuinely-cached higher-quality option that exists.
    static func bestCachedResolution(_ groups: [CoreStreamSourceGroup],
                                     debridCachedHashes: Set<String> = []) -> Int {
        var best = 0
        for group in groups {
            for s in group.streams where s.playableURL != nil && !s.isYouTubeTrailer {
                guard isCached(s, qualityText(s), debridCachedHashes: debridCachedHashes) else { continue }
                best = max(best, resolution(qualityText(s)))
            }
        }
        return best
    }

    /// The coarse resolution TIER for the one-tier-drop cap: adjacent labelled tiers are one step apart
    /// (4K → 1080p → 720p → 480p → lower), so a hop that lands more than one step below the best cached
    /// option is the silent quality plunge we refuse on the auto path. Unknown/low resolutions collapse
    /// into the bottom step, so a bare-tag source is treated as low, not promoted.
    static func resolutionTierStep(_ res: Int) -> Int {
        switch res {
        case 4000...: return 4
        case 2160...: return 4
        case 1440...: return 3
        case 1080...: return 3
        case 720...:  return 2
        case 480...:  return 1
        default:      return 0
        }
    }

    /// Distinct choices for the visible quality picker: the best stream per resolution-and-flavor
    /// combination, labeled the way people actually choose ("4K · Dolby Vision · Remux",
    /// "1080p · BluRay · Atmos"). Best-first, so the top option is what Watch Now would play.
    static func qualityOptions(_ groups: [CoreStreamSourceGroup]) -> [(label: String, stream: CoreStream)] {
        let playable = groups.flatMap { $0.streams }.filter { $0.playableURL != nil && !$0.isYouTubeTrailer }
        var best: [String: (score: Int, stream: CoreStream)] = [:]
        for s in playable {
            let t = qualityText(s)
            var tags = [qualityLabel(s)]
            if StreamRanking.isDolbyVision(t) {
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
        let playable = groups.flatMap { $0.streams }.filter { $0.playableURL != nil && !$0.isYouTubeTrailer }
        var present = Set<String>()
        for s in playable { present.insert(tier(of: s)) }
        return ["4K", "1080p", "720p", "Others"].filter { present.contains($0) }
    }

    /// Second level of the quality picker: distinct flavor variants inside one resolution tier
    /// ("Dolby Vision · Remux", "HDR · Atmos", "BluRay"), best variant of each, best-first, capped.
    static func variantOptions(_ groups: [CoreStreamSourceGroup], tier wanted: String)
        -> [(label: String, stream: CoreStream)] {
        let playable = groups.flatMap { $0.streams }
            .filter { $0.playableURL != nil && !$0.isYouTubeTrailer && tier(of: $0) == wanted }
        var best: [String: (score: Int, stream: CoreStream)] = [:]
        for s in playable {
            let t = qualityText(s)
            var tags: [String] = []
            if StreamRanking.isDolbyVision(t) {
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
                               ("720", 720), ("576", 576), ("540", 540), ("480", 480)] {
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
        if let r = explicitResolution(t) {
            // Even an explicit "2160p" token is only badged 4K when the file size isn't implausibly
            // small for 4K, so a 720p file carrying a "2160p" tag isn't shown as 4K.
            if r >= 4000 { return implausibleForResolution(t) ? "Other" : "4K" }
            return "\(r)p"
        }
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

    /// A one-line rationale for WHY the auto-pick chose this source (#16), shown ONCE on the recommended
    /// pick - never per row, so it explains the ranking DECISION instead of duplicating the per-row
    /// attribute tags (`flavorTags`). It surfaces the two decisive factors those tags do not convey as a
    /// reason: that the source is instant (resolved from a debrid cache, so it beats uncached peers of the
    /// same quality), and that it sits at the top of the viewer's own source-type order. Returns nil when
    /// neither applies, so the caption only appears when there is a real reason to show.
    ///
    /// NOTE (bitrate / ping, the rest of #16): a true bitrate weight needs per-stream runtime the add-on
    /// protocol does not carry, and a ping/latency weight needs an async per-source probe; both belong in
    /// the engine (structured stream metadata + async I/O), see [[vortx-engine-needs]] #2 and #4. They are
    /// deliberately NOT faked here.
    static func pickReason(_ s: CoreStream) -> String? {
        let prefs = SourcePreferences.reading
        let t = qualityText(s)
        var why: [String] = []
        if isCached(s, t) { why.append("instant from cache") }
        if prefs.typeOrder.first == sourceType(s, t) { why.append("your preferred source type") }
        // Smart Source Selection (Lane A): surface WHY the chips nudged this source, using the actual term
        // that matched so the reason is concrete. Prefer applies in both modes; "ranked down" only in "rank".
        if let term = prefs.preferTerms.first(where: { t.contains($0) }) { why.append("preferred: \(term)") }
        // "ranked down" whenever the Avoid demotion actually applied (avoidBehavior == "rank"), derived the
        // SAME way computeScore's -20000 demotion decides it: substring terms in plain mode, the compiled
        // excludeRegex in regex mode. The regex badge is generic (a regex match has no single "term").
        if prefs.avoidBehavior == "rank" {
            if prefs.keywordsAreRegex {
                if let rx = prefs.excludeRegex, prefs.matches(rx, t) { why.append("ranked down") }
            } else if let term = prefs.excludeTerms.first(where: { t.contains($0) }) {
                why.append("ranked down: \(term)")
            }
        }
        guard !why.isEmpty else { return nil }
        return why.joined(separator: " · ")
    }

    /// True when a stream's quality text advertises Dolby Vision. This is the only DV signal available
    /// before playback (a text parse); the engine router uses it to route DV to AVPlayer for true DV
    /// passthrough, which libmpv/MoltenVK cannot do (it only tone-maps DV to SDR). HDR10 is intentionally
    /// NOT included: libmpv's gpu-next renders HDR10 correctly, so only DV needs the AVPlayer path.
    static func isDolbyVision(_ text: String) -> Bool {
        let t = text.lowercased()
        // Widened token set so DV actually FIRES: many DV releases never write "dolby vision"/"dovi" - they
        // only label the profile (DV.P8, Profile 8, 8.1/8.4, DoViHDR, DVHDR, BL+RPU). The \b / \bp guards keep
        // "2160p" from reading as profile 5. A false positive is harmless here: it only routes to AVPlayer
        // (which plays the file regardless) and the AVPlayer -> libmpv fallback backstops any mis-route.
        return matches(t, #"(dolby[ ._-]?vision|dolbyvision|\bdovi\b|dovihdr|\bdv\b|\bdvhdr\b|bl\+?rpu|\bp(?:rofile[ ._-]?)?[578](?:\.[0-9])?\b|\bdv[ ._-]?p?[578]\b)"#)
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
        // Strip add-on TEMPLATE BLOBS first (H6): a failed add-on template can leak a raw expression like
        // "{cannot_apply_modifier_to_null(replace('2160p','4k'))}" into the stream text. Its literal "2160p"/
        // "4k" then POISONS resolution classification (a 720p file mislabelled 4K and auto-picked). Any
        // "{ ... }" run is a template artifact, never real release-name text, so remove every one BEFORE any
        // resolution / quality / source token is parsed. Non-greedy so adjacent blobs are each removed.
        text = stripTemplateBlobs(text)
        if let re = regex(#"\.(ts|m2ts|mkv|mp4|avi|webm|mov)(?![a-z0-9])"#) {
            text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                               withTemplate: "")
        }
        cacheLock.lock()
        // Cap matched to scoreCache (32768): textCache is the substrate under score/qualityLabel/tiers/
        // flavorTags/sizeText/isNonVideo. At 4096 a popular title returning a few thousand UNIQUE stream
        // keys (TorBox/Singularity duplicates carry distinct names) thrashed this mid-render (clear, refill,
        // clear), turning every per-stream text access into a full rebuild and saturating the main thread on
        // a 4000+ source title (the Infinity War watchdog kill). 32768 clears that while still bounding a runaway.
        if textCache.count > 32_768 { textCache.removeAll() }
        textCache[key] = text
        cacheLock.unlock()
        return text
    }

    /// Remove add-on template blobs — any `{ ... }` run — from stream text before it is classified (H6). A
    /// broken add-on template (AIOStreams stream-expressions and similar) can emit a raw, unevaluated
    /// expression such as `{cannot_apply_modifier_to_null(replace('2160p','4k'))}`; left in place its literal
    /// resolution tokens poison `resolution` / `qualityLabel`. Non-greedy per-blob removal, up to a small cap
    /// of blobs so a pathological string can never loop; a single unmatched `{` (no closing brace) is left as
    /// harmless text. Nested braces are rare in these artifacts; the innermost-first non-greedy pass clears
    /// the common single-level case.
    static func stripTemplateBlobs(_ text: String) -> String {
        guard text.contains("{"), let re = regex(#"\{[^{}]*\}"#) else { return text }
        var out = text
        // A blob can itself contain a nested blob; a few passes flattens realistic nesting depth. Bounded so
        // a degenerate input can't spin.
        for _ in 0..<4 {
            guard out.contains("{") else { break }
            let replaced = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                       withTemplate: " ")
            if replaced == out { break }
            out = replaced
        }
        return out
    }

    /// The parsed resolution when the text carries a recognizable token (an explicit "1080p"-style
    /// number, or a bare 4K/UHD marketing tag), nil when the release advertises none. The minimum-
    /// resolution floor needs "unknown" kept apart from "low" (an unlabelled source must never be
    /// dropped as if it were small), which `resolution(_:)`'s scoring sentinel deliberately conflates.
    static func knownResolution(_ t: String) -> Int? {
        if let r = explicitResolution(t) { return r }
        if boundedMatch(t, "4k") || boundedMatch(t, "uhd") { return 4000 }
        return nil
    }

    private static func resolution(_ t: String) -> Int {
        knownResolution(t) ?? 100   // unknown resolution: below any labelled stream, above nothing
    }

    /// Whether this stream plays instantly. Explicit add-on markers override the URL-shape
    /// heuristic: an UNCACHED debrid result is ALSO a plain URL (the resolve link), which the
    /// old shape-only check happily called cached, so Watch Now kept picking sources that then
    /// had to download into the debrid first (the "first pick always fails" reports).
    /// Marker sets verified against the four major add-ons' formatter source.
    /// Order matters: "uncached" contains "cached", so the negative markers test first.
    ///
    /// `debridCachedHashes` is an OPTIONAL set of infoHashes the user's own debrid account confirmed
    /// cached (via `DebridCoordinator.cacheCheck`), lowercased. A raw torrent whose infoHash is in it
    /// gets the SAME instant treatment as a text-marked cached stream. The set defaults to empty, in
    /// which case this is byte-identical to the marker/URL heuristic alone.
    static func isCached(_ s: CoreStream, _ text: String, debridCachedHashes: Set<String> = []) -> Bool {
        // Coordinator-confirmed cache: the user's debrid account holds this exact torrent, so it plays
        // instantly even if the add-on text carries no cache marker. Checked first (a positive override),
        // and a no-op when the set is empty.
        if !debridCachedHashes.isEmpty, let hash = s.infoHash?.lowercased(),
           debridCachedHashes.contains(hash) {
            return true
        }
        // "[RD download]" forms, "⏳" hourglass, "⬇" download arrow, "❌ not ready", "🎟" ticket.
        // "download" is only a cache signal inside a bracketed service tag ([PM download]); the bare
        // word appears in ordinary release names ("Download.2005") and must not force uncached.
        if text.contains("⏳") || text.contains("⬇") || text.contains("uncached")
            || text.contains("not ready") || text.contains("🎟")
            || matches(text, #"\[(rd|ad|pm|tb|dl|oc|ed|st|db|pp|putio)\s+download\]"#) {
            return false
        }
        // "[RD+]"-style plus tags, "⚡" bolt, "(Instant RD)" (instant bound to a service code, so the movie
        // title "Instant Family" is not read as cached, T9), a bounded "cached" inside the technical tags
        // (after the year/resolution marker, so a title word does not force it), "🎫" ticket.
        // The "+" plus tag only counts bound to a known service code inside brackets; a bare "+]"
        // substring occurs in ordinary release names and would misclassify them as cached.
        if text.contains("⚡") || matches(text, #"\[(rd|ad|pm|tb|dl|oc|ed|st|db|pp|putio)\+\]"#)
            || matches(text, #"instant\s*(rd|ad|pm|tb|dl|oc|ed|st|db|pp|putio)(?![a-z0-9])"#)
            || boundedMatch(technicalTags(text), "cached") || text.contains("🎫") {
            return true
        }
        return s.url != nil && s.infoHash == nil   // plain URL with no contrary marker
    }
}
