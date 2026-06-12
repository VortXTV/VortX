import Foundation

/// Ranks loaded streams so the strongest source surfaces first and "Watch Now" can auto-pick one.
///
/// For a debrid user the dominant signals are whether the source is **cached / direct** (instant, a
/// non-torrent URL) and its **resolution**; REMUX / BluRay / HDR act as tiebreakers. Quality is parsed
/// from the stream's name + description + filename, where add-ons put their tags. Deliberately simple:
/// seeders matter mainly for raw torrents, which a debrid user rarely lands on.
enum StreamRanking {
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
        if isCached(s, text) { score += 8000 }   // cached / direct = instant; outranks any non-cached quality
        // Source type is the dominant sort key: user-ranked tier (debrid > usenet > torrent > direct
        // by default) contributes a 15k-spaced weight that always overrules quality within a tier.
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
        // tier. The shift is uniform, so if only junk exists the least-bad junk still wins.
        if junkClass(text) != nil { score -= 100_000 }
        return score
    }

    /// `pattern` matched only at delimiter boundaries: no alphanumeric on either side, so "ts"
    /// can't fire inside DTS, "cam" inside camera, or "hc" inside HEVC tags. Text is lowercase.
    static func boundedMatch(_ text: String, _ pattern: String) -> Bool {
        text.range(of: "(?<![a-z0-9])(?:\(pattern))(?![a-z0-9])", options: .regularExpression) != nil
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
            if let m = text.range(of: pattern, options: .regularExpression) {
                return Int(text[m].filter(\.isNumber))
            }
        }
        return nil
    }

    /// Classify a stream into the four source categories used for user-rankable tier scoring.
    static func sourceType(_ s: CoreStream, _ text: String) -> SourceType {
        if text.contains("debrid") || text.contains("premiumize") || text.contains("torbox")
            || text.contains("offcloud") || text.contains("[rd") || text.contains("[ad+]")
            || text.contains("[pm+]") || text.contains("[tb+]") || text.contains("[dl+]")
            || text.contains("[oc+]") {
            return .debrid
        }
        if text.contains("usenet") || text.contains("nzb") || text.contains("easynews") { return .usenet }
        if s.isTorrent { return .torrent }
        return .direct
    }

    /// Known debrid / usenet services detected from the stream text. Foundation for a future
    /// user-rankable provider order (like the source-type order); for now only the default
    /// offsets below apply.
    enum ServiceProvider {
        case realDebrid, allDebrid, premiumize, torbox, debridLink, offcloud, easynews, unknown
    }

    static func provider(_ text: String) -> ServiceProvider {
        if isRealDebrid(text) { return .realDebrid }
        if text.contains("alldebrid") || text.contains("all-debrid") || text.contains("[ad+]")
            || text.range(of: #"\bad\+?\b"#, options: .regularExpression) != nil { return .allDebrid }
        if text.contains("premiumize") || text.contains("[pm+]")
            || text.range(of: #"\bpm\+?\b"#, options: .regularExpression) != nil { return .premiumize }
        if text.contains("torbox") || text.contains("[tb+]")
            || text.range(of: #"\btb\+?\b"#, options: .regularExpression) != nil { return .torbox }
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
        guard let m = t.range(of: #"(\d+(?:\.\d+)?)\s*g(i)?b"#, options: .regularExpression) else { return 0 }
        let digits = t[m].lowercased()
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
        return qualityText.range(of: #"\brd\+?\b"#, options: .regularExpression) != nil
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
            || t.range(of: #"\bdv\b"#, options: .regularExpression) != nil { tags.append("DV") }
        else if t.contains("hdr") { tags.append("HDR") }
        if t.contains("atmos") { tags.append("Atmos") }
        else if t.contains("dts-hd") || t.contains("dts hd") { tags.append("DTS-HD") }
        else if t.contains("dts") { tags.append("DTS") }
        if t.contains("hevc") || t.contains("x265") || t.contains("h265") || t.contains("h.265") { tags.append("HEVC") }
        else if t.contains("av1") { tags.append("AV1") }
        if isCached(s, t) { tags.append("Cached") }
        if let junk = junkClass(t) { tags.append(junk) }   // why this source sits at the bottom
        var size: String?
        if let m = t.range(of: #"(\d+(?:\.\d+)?)\s*(gb|gib)"#, options: .regularExpression) {
            size = String(t[m]).uppercased().replacingOccurrences(of: "GIB", with: "GB")
        } else if let m = t.range(of: #"(\d+(?:\.\d+)?)\s*(mb|mib)"#, options: .regularExpression) {
            size = String(t[m]).uppercased().replacingOccurrences(of: "MIB", with: "MB")
        }
        return (tags.joined(separator: " · "), size)
    }

    /// A short resolution tag for the Watch-Now button ("4K" / "1080p" / …), or "Best" when unknown.
    static func qualityLabel(_ s: CoreStream) -> String {
        let t = qualityText(s)
        if t.contains("2160") || t.contains("4k") || t.contains("uhd") { return "4K" }
        if t.contains("1440") { return "1440p" }
        if t.contains("1080") { return "1080p" }
        if t.contains("720") { return "720p" }
        if t.contains("480") { return "480p" }
        return "Best"
    }

    private static func qualityText(_ s: CoreStream) -> String {
        // Container extensions are stripped from the WHOLE text, not just the filename field:
        // add-ons embed file names in the stream name or description too, and a plain ".ts"
        // (MPEG-TS) must never read as a TeleSync marker to the junk detector. Boundary-checked
        // so only a real dot-extension token disappears.
        [s.name, s.description, s.behaviorHints?.filename]
            .compactMap { $0 }.joined(separator: " ").lowercased()
            .replacingOccurrences(of: #"\.(ts|m2ts|mkv|mp4|avi|webm|mov)(?![a-z0-9])"#,
                                  with: "", options: .regularExpression)
    }

    private static func resolution(_ t: String) -> Int {
        if t.contains("2160") || t.contains("4k") || t.contains("uhd") { return 4000 }
        if t.contains("1440") { return 1440 }
        if t.contains("1080") { return 1080 }
        if t.contains("720") { return 720 }
        if t.contains("540") { return 540 }
        if t.contains("480") { return 480 }
        return 100   // unknown resolution: below any labelled stream, above nothing
    }

    private static func isCached(_ s: CoreStream, _ text: String) -> Bool {
        if s.url != nil && s.infoHash == nil { return true }   // a direct / debrid URL plays instantly
        return text.contains("cached") || text.contains("⚡") || text.contains("instant")
            || text.contains("[rd+]") || text.contains("[pm+]") || text.contains("[ad+]") || text.contains("[tb+]")
    }
}
