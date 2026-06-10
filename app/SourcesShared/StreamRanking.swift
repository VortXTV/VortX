import Foundation

/// Ranks loaded streams so the strongest source surfaces first and "Watch Now" can auto-pick one.
///
/// For a debrid user the dominant signals are whether the source is **cached / direct** (instant, a
/// non-torrent URL) and its **resolution**; REMUX / BluRay / HDR act as tiebreakers. Quality is parsed
/// from the stream's name + description + filename, where add-ons put their tags. Deliberately simple:
/// seeders matter mainly for raw torrents, which a debrid user rarely lands on.
enum StreamRanking {
    static func score(_ s: CoreStream) -> Int {
        let text = qualityText(s)
        var score = resolution(text)
        if text.contains("remux") { score += 250 }
        else if text.contains("bluray") || text.contains("blu-ray") { score += 120 }
        if text.contains("hdr") || text.contains("dolby vision") || text.contains("dolbyvision") || text.contains("dovi") {
            score += 80
        }
        if isCached(s, text) { score += 8000 }   // cached / direct = instant; outranks any non-cached quality
        if isRealDebrid(text) { score -= 20000 } // RD purged its cache + throttles; last resort only
        return score
    }

    /// Real-Debrid sources sink below every other option (the service purged its cache and now
    /// blocks/throttles aggressively), so they only play when nothing else exists. Matches the
    /// service name plus the bracketed/delimited "RD"/"RD+" tags add-ons put in stream names; the
    /// word-boundary regex cannot match inside words like HDR.
    static func isRealDebrid(_ qualityText: String) -> Bool {
        if qualityText.contains("realdebrid") || qualityText.contains("real-debrid")
            || qualityText.contains("real debrid") { return true }
        return qualityText.range(of: #"\brd\+?\b"#, options: .regularExpression) != nil
    }

    /// Each group's streams sorted best-first, stable within equal scores (so add-on order is preserved
    /// among ties). Scores are computed once per stream, not per comparison.
    static func rankedGroups(_ groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        groups.map { group in
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
        groups.flatMap { $0.streams }.filter { $0.playableURL != nil }.max { score($0) < score($1) }
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
        return best.map { (label: $0.key, stream: $0.value.stream) }
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
        [s.name, s.description, s.behaviorHints?.filename].compactMap { $0 }.joined(separator: " ").lowercased()
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
