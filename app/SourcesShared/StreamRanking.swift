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
        for res in ["2160", "1080", "720"] where hint.contains(res) {
            if text.contains(res) { bonus += 800 }
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

    static func score(_ s: CoreStream) -> Int {
        let key = streamKey(s)
        cacheLock.lock()
        if let hit = scoreCache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let value = computeScore(s)
        cacheLock.lock()
        if scoreCache.count > 4096 { scoreCache.removeAll() }   // runaway guard, never hit in practice
        scoreCache[key] = value
        cacheLock.unlock()
        return value
    }

    private static func computeScore(_ s: CoreStream) -> Int {
        let text = qualityText(s)
        var score = resolution(text)
        // Source ladder, the consensus ordering every parser converges on:
        // remux > bluray > web-dl > webrip > hdtv > dvdrip > tv captures.
        if text.contains("remux") { score += 250 }
        else if text.contains("bluray") || text.contains("blu-ray") || boundedMatch(text, #"b[dr][ .\-_]?rip"#) { score += 120 }
        else if boundedMatch(text, #"web[ .\-_]?dl"#) { score += 100 }
        else if boundedMatch(text, #"web[ .\-_]?rip"#) { score += 40 }
        else if boundedMatch(text, "web") { score += 100 }   // scene bare "WEB" tag = WEB-DL
        else if text.contains("hdtv") { score -= 150 }
        else if boundedMatch(text, #"dvd[ .\-_]?rip"#) { score -= 200 }
        else if text.contains("tvrip") || text.contains("satrip") || boundedMatch(text, #"pdtv"#) { score -= 300 }
        if text.contains("hdr") || text.contains("dolby vision") || text.contains("dolbyvision") || text.contains("dovi") {
            score += 80
        }
        // File size is the strongest objective quality signal WITHIN a resolution tier: a 4K remux is
        // 30-80 GB, a 4K WEB-DL is 3-10 GB, and bigger means higher bitrate. Without this, Watch Now
        // saw a basic 4K and a 4K remux as near-ties and played whichever add-on answered first. Scaled
        // and capped (~600) so it decides between same-resolution sources but never lifts a 1080p over a 4K.
        score += min(Int(sizeGB(text) * 6), 600)
        // Lossless / object-based audio is a real upgrade on a capable system (eARC soundbar, AV receiver),
        // so it breaks remaining ties toward the better-sounding source.
        if text.contains("atmos") || text.contains("truehd") || text.contains("true-hd") { score += 70 }
        else if text.contains("dts-hd") || text.contains("dts hd") || text.contains("dts-ma") { score += 50 }
        else if text.contains("dts") { score += 20 }
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
        // CACHED IS KING: an instant stream beats ANY uncached stream of any type or quality.
        // This is the split every serious ranking tool makes first; quality and the type tiers
        // below then order sources WITHIN the cached and uncached halves.
        if isCached(s, text) { score += 100_000 }
        // Source type is the next sort key: user-ranked tier (debrid > usenet > torrent > direct
        // by default) contributes a 15k-spaced weight that always overrules quality within a half.
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
        // Theatrical rips and fake "quality" releases rank below every legitimate stream of any
        // tier, cached or not (cached ceiling is ~160k, so -250k clears it). The shift is
        // uniform, so if only junk exists the least-bad junk still wins.
        if junkClass(text) != nil { score -= 250_000 }
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

    /// Classify a stream into the four source categories used for user-rankable tier scoring.
    /// The tag grammar below is verified against the formatter source of the four major
    /// stream add-ons; missing a form here drops a debrid stream into the DIRECT tier
    /// (weight 0, below raw torrents), which is exactly the "played a torrent over my
    /// debrid" failure.
    static func sourceType(_ s: CoreStream, _ text: String) -> SourceType {
        // Usenet first: a debrid service's usenet results carry the same service code.
        if text.contains("usenet") || text.contains("nzb") || text.contains("easynews")
            || text.contains("📰") { return .usenet }
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

    /// Small intra-tier provider preference. Real-Debrid sinks slightly (cache purges plus
    /// throttling make it the least reliable of the majors), so at EQUAL quality any other
    /// provider wins, while a better-quality RD stream still beats a worse one elsewhere.
    /// When per-provider ranking becomes user-configurable this table becomes the default.
    static func providerOffset(for provider: ServiceProvider) -> Int {
        switch provider {
        case .realDebrid: return -150
        default:          return 0
        }
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
    static func rankedGroups(_ groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
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
    static func sourceDetail(_ s: CoreStream) -> (tags: String, size: String?) {
        let t = qualityText(s)
        var tags: [String] = [qualityLabel(s)]
        if t.contains("remux") { tags.append("Remux") }
        else if t.contains("bluray") || t.contains("blu-ray") { tags.append("BluRay") }
        else if t.contains("web") { tags.append("WEB") }
        if t.contains("dolby vision") || t.contains("dolbyvision") || t.contains("dovi")
            || matches(t, #"\bdv\b"#) { tags.append("DV") }
        else if t.contains("hdr") { tags.append("HDR") }
        if t.contains("atmos") { tags.append("Atmos") }
        else if t.contains("dts-hd") || t.contains("dts hd") { tags.append("DTS-HD") }
        else if t.contains("dts") { tags.append("DTS") }
        if t.contains("hevc") || t.contains("x265") || t.contains("h265") || t.contains("h.265") { tags.append("HEVC") }
        else if t.contains("av1") { tags.append("AV1") }
        if isCached(s, t) { tags.append("Cached") }
        if let junk = junkClass(t) { tags.append(junk) }   // why this source sits at the bottom
        var size: String?
        if let m = firstMatch(t, #"(\d+(?:\.\d+)?)\s*(gb|gib)"#) {
            size = m.uppercased().replacingOccurrences(of: "GIB", with: "GB")
        } else if let m = firstMatch(t, #"(\d+(?:\.\d+)?)\s*(mb|mib)"#) {
            size = m.uppercased().replacingOccurrences(of: "MIB", with: "MB")
        }
        return (tags.joined(separator: " · "), size)
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

    /// A short resolution tag for the Watch-Now button ("4K" / "1080p" / …), or "Best" when unknown.
    static func qualityLabel(_ s: CoreStream) -> String {
        let t = qualityText(s)
        if let r = explicitResolution(t) { return r >= 4000 ? "4K" : "\(r)p" }
        if boundedMatch(t, "4k") || boundedMatch(t, "uhd") { return "4K" }
        return "Best"
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
