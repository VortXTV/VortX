import Foundation

/// Issue #81: when a user plays a magnet / torrent from "Play a link", try to recognise WHAT it is
/// (clean the torrent name, match it to a real Cinemeta title) and save THAT to the library, so the
/// thing they just watched shows up in their library like any catalog item.
///
/// Hard invariant (see SavedLinksStore + ProfileSync.swift): a raw magnet has no catalog meta id, and
/// injecting a synthetic item into the stremio-core library corrupts account-wide sync for the official
/// Stremio clients. So we ONLY ever add a *resolved* item (a real `tt…` / `tmdb:…` id from Cinemeta). If
/// nothing matches, we add nothing here — the raw link still lives in SavedLinksStore. Per-profile
/// invariant is honoured: the main profile goes through the engine (account library); overlay profiles
/// go to their private ProfileStore overlay and never touch the account library.
@MainActor
enum PlayedLinkLibrary {
    /// Best-effort, fire-and-forget. Resolve `displayName` (a magnet `dn=` / torrent file name) to a
    /// Cinemeta title and save it to the active profile's library. No-op on no confident match.
    static func savePlayedTorrent(displayName raw: String) async {
        let parsed = cleanTitle(raw)
        guard parsed.query.count >= 2, !isPlaceholder(parsed.query) else { return }

        let client = AddonClient()
        // Filenames misclassify, so try the guessed type first, then the other.
        let primary = parsed.isSeries ? "series" : "movie"
        let secondary = parsed.isSeries ? "movie" : "series"
        var hit = (try? await client.search(type: primary, query: parsed.query))?.first
        if hit == nil { hit = (try? await client.search(type: secondary, query: parsed.query))?.first }
        guard let preview = hit else { return }   // unknown title: leave it in SavedLinksStore only

        if ProfileStore.shared.activeUsesEngineHistory {
            // Main profile → account library. Hand the engine the full Cinemeta meta object (the same
            // shape addDetailToLibrary dispatches); a real catalog id, safe for official-client sync.
            if let meta = await rawMeta(type: preview.type, id: preview.id) {
                CoreBridge.shared.addRawMetaToLibrary(meta)
            }
        } else {
            // Overlay profile → private local overlay only.
            ProfileStore.shared.addLibraryEntry(metaId: preview.id, name: preview.name,
                                                type: preview.type, poster: preview.poster)
        }
    }

    /// Fetch Cinemeta's raw `meta` object untyped, so it can be handed straight to the engine without
    /// re-encoding a decoded model (and losing fields the engine's library item expects).
    private static func rawMeta(type: String, id: String) async -> [String: Any]? {
        let safeId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        guard let url = URL(string: "\(AddonClient.cinemeta)/meta/\(type)/\(safeId).json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = obj["meta"] as? [String: Any] else { return nil }
        return meta
    }

    /// Turn a torrent / magnet display name into a searchable title and a movie-vs-series guess.
    /// The clean title is whatever precedes the earliest "junk" marker (release year, resolution,
    /// source, codec) or season/episode marker. Uses NSRegularExpression (works on every SDK CI runs).
    static func cleanTitle(_ raw: String) -> (query: String, isSeries: Bool) {
        var s = raw
        // Drop a trailing file extension (".mkv", ".mp4", …).
        if let dot = s.lastIndex(of: "."), s.distance(from: dot, to: s.endIndex) <= 5 {
            let ext = s[s.index(after: dot)...]
            if !ext.isEmpty, ext.allSatisfy({ $0.isLetter || $0.isNumber }) { s = String(s[..<dot]) }
        }
        // Separators → spaces.
        s = s.components(separatedBy: CharacterSet(charactersIn: "._[](){}+-")).joined(separator: " ")

        let seriesPatterns = ["[sS][0-9]{1,2} ?[eE][0-9]{1,2}", "\\b[0-9]{1,2}x[0-9]{1,2}\\b", "\\b[sS]eason\\b"]
        let junkPatterns = [
            "\\b(19|20)[0-9]{2}\\b",
            "\\b(480p|576p|720p|1080p|1440p|2160p|4k|uhd)\\b",
            "\\b(bluray|blu ?ray|brrip|bdrip|webrip|web ?dl|web|hdrip|dvdrip|hdtv|hdcam|cam|ts)\\b",
            "\\b(x264|x265|h264|h265|hevc|avc|xvid|divx|aac|ac3|dts|ddp?5 1|atmos)\\b",
            "\\b(remux|proper|repack|extended|unrated|imax|multi|dual)\\b",
        ]
        let ns = s as NSString
        var cut = ns.length
        var isSeries = false
        func scan(_ patterns: [String], markSeries: Bool) {
            for p in patterns {
                guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
                      let m = re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length))
                else { continue }
                if markSeries { isSeries = true }
                if m.range.location < cut { cut = m.range.location }
            }
        }
        scan(seriesPatterns, markSeries: true)
        scan(junkPatterns, markSeries: false)

        let title = ns.substring(to: cut)
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, isSeries)
    }

    /// Generic placeholders the magnet resolver hands back when it has no real name.
    private static func isPlaceholder(_ q: String) -> Bool {
        ["torrent", "file", "stream", "video", "magnet link"].contains(q.lowercased())
    }
}
