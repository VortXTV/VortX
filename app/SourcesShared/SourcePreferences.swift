import Foundation

/// The four source categories the ranking system recognises.
enum SourceType: String, CaseIterable, Codable {
    case debrid  = "debrid"
    case usenet  = "usenet"
    case torrent = "torrent"
    case direct  = "direct"

    var label: String {
        switch self {
        case .debrid:  return "Debrid"
        case .usenet:  return "Usenet"
        case .torrent: return "Torrent"
        case .direct:  return "Direct"
        }
    }

    var detail: String {
        switch self {
        case .debrid:  return "Real-Debrid, AllDebrid, Premiumize, TorBox, Debrid-Link"
        case .usenet:  return "NZB / Usenet sources"
        case .torrent: return "BitTorrent info-hash streams"
        case .direct:  return "Plain HTTP/HTTPS streams from add-ons"
        }
    }
}

/// One-tap source presets that set the quality caps + source-type order together, so a viewer can pick a
/// taste ("biggest/best files" vs "save data") without tuning each control. Applying one writes the same
/// `@Published` knobs the Settings controls bind to, so their `didSet`s persist + invalidate caches, and the
/// source-type order it sets is captured per-profile by the Settings `onChange(of: typeOrder)` exactly like a
/// manual reorder. Presets leave the keyword/regex filters and safety mode alone (those are user-owned).
enum SourcePreset: String, CaseIterable, Identifiable {
    case bestQuality, balanced, dataSaver
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bestQuality: return "Best Quality"
        case .balanced:    return "Balanced"
        case .dataSaver:   return "Data Saver"
        }
    }
    var detail: String {
        switch self {
        case .bestQuality: return "Highest resolution, no size cap. Best for fast connections and big screens."
        case .balanced:    return "High quality with a sane size cap, so nothing absurdly large auto-plays."
        case .dataSaver:   return "Caps at 1080p and small files, instant sources only. Best on cellular or a tight plan."
        }
    }
}

/// Persisted source-ranking preferences.
/// Observed by SettingsView and read by StreamRanking at score time.
final class SourcePreferences: ObservableObject {
    static let shared = SourcePreferences()

    private static let orderKey      = "stremiox.streaming.sourceTypeOrder"
    private static let addonOrderKey = "stremiox.streaming.useAddonOrder"
    static let excludeKey            = "stremiox.streaming.excludeKeywords"
    static let includeKey            = "stremiox.streaming.includeKeywords"
    static let safetyKey             = "stremiox.streaming.safetyMode"
    static let hideDeadKey           = "stremiox.streaming.hideDeadTorrents"
    static let instantOnlyKey        = "stremiox.streaming.instantOnly"
    static let maxResolutionKey      = "stremiox.streaming.maxResolution"
    static let maxFileSizeKey        = "stremiox.streaming.maxFileSizeGB"
    static let hdrOnlyKey            = "stremiox.streaming.hdrOnly"
    static let excludeAV1Key         = "stremiox.streaming.excludeAV1"
    static let defaultSortKey        = "stremiox.streaming.defaultSourceSort"
    static let regexKey              = "stremiox.streaming.keywordsAreRegex"

    // Max possible quality score is ~13,800 (4K + cached + remux + HDR + atmos + file-size cap).
    // A 15,000-point tier gap means the preferred type ALWAYS beats a lower type regardless of quality.
    private static let tierWeights = [45_000, 30_000, 15_000, 0]

    @Published var typeOrder: [SourceType] {
        didSet {
            UserDefaults.standard.set(
                typeOrder.map(\.rawValue).joined(separator: ","),
                forKey: Self.orderKey
            )
            StreamRanking.invalidateCaches()   // memoized scores embed the tier weights
        }
    }

    @Published var useAddonOrder: Bool {
        didSet { UserDefaults.standard.set(useAddonOrder, forKey: Self.addonOrderKey) }
    }

    /// Comma-separated words to hide from the stream list (matched in the lowercased name+description+
    /// filename). Empty = no filtering. e.g. "cam, ts, hindi".
    @Published var excludeKeywords: String {
        didSet { UserDefaults.standard.set(excludeKeywords, forKey: Self.excludeKey); rebuildKeywordRegexes() }
    }
    /// Comma-separated words a stream MUST contain to be shown. Empty = no allow-list. e.g. "remux, atmos".
    @Published var includeKeywords: String {
        didSet { UserDefaults.standard.set(includeKeywords, forKey: Self.includeKey); rebuildKeywordRegexes() }
    }
    /// Treat Hide / Require words as full case-insensitive REGEX patterns instead of comma-separated
    /// substrings, for power users (e.g. require `2160p.*(remux|bluray)`, hide `\b(cam|ts|hdts)\b`). Off by
    /// default. An invalid pattern compiles to nil and simply applies no keyword filter (fail-open), so a
    /// typo can never hide every source. The two fields keep their own meaning: Hide = drop on match,
    /// Require = drop on no-match.
    @Published var keywordsAreRegex: Bool {
        didSet { UserDefaults.standard.set(keywordsAreRegex, forKey: Self.regexKey); rebuildKeywordRegexes() }
    }
    /// Compiled forms of the keyword fields when `keywordsAreRegex` is on; nil when off, empty, or the
    /// pattern is invalid. Rebuilt whenever a field or the toggle changes, so the per-stream filter never
    /// recompiles in its hot loop.
    private(set) var excludeRegex: NSRegularExpression?
    private(set) var includeRegex: NSRegularExpression?
    /// "off" (default), "balanced" (drop CAM/TS/SCR junk), or "strict" (also drop implausible-for-resolution
    /// fakes). Reuses the existing junk classifiers.
    @Published var safetyMode: String {
        didSet { UserDefaults.standard.set(safetyMode, forKey: Self.safetyKey) }
    }
    /// Drop torrents an add-on EXPLICITLY reports as 0-seeders (dead swarms). Off by default. Torrents
    /// with no reported seeder count are kept (unknown is not the same as dead).
    @Published var hideDeadTorrents: Bool {
        didSet { UserDefaults.standard.set(hideDeadTorrents, forKey: Self.hideDeadKey) }
    }
    /// Show only sources that play instantly: cached debrid and plain direct links, never an uncached
    /// debrid result or a raw torrent that has to download first. Off by default.
    @Published var instantOnly: Bool {
        didSet { UserDefaults.standard.set(instantOnly, forKey: Self.instantOnlyKey) }
    }
    /// Cap the resolution of shown sources (0 = unlimited, else 4000 / 1080 / 720). Only drops a source
    /// whose KNOWN resolution exceeds the cap, so unlabelled sources are kept. Off (0) by default.
    @Published var maxResolution: Int {
        didSet { UserDefaults.standard.set(maxResolution, forKey: Self.maxResolutionKey) }
    }
    /// Cap the file size of shown sources in GB (0 = unlimited). Only drops a source whose ADVERTISED
    /// size exceeds the cap, so sources with no stated size (many cached / debrid links) are kept.
    /// Off (0) by default. Pairs with `maxResolution` for "1080p but not a 20 GB file".
    @Published var maxFileSizeGB: Double {
        didSet { UserDefaults.standard.set(maxFileSizeGB, forKey: Self.maxFileSizeKey) }
    }
    /// Show only HDR / Dolby Vision sources. Off by default (aggressive, hides most SDR releases).
    @Published var hdrOnly: Bool {
        didSet { UserDefaults.standard.set(hdrOnly, forKey: Self.hdrOnlyKey) }
    }
    /// Hide AV1 sources (Apple devices have no AV1 hardware decode, so 4K AV1 struggles). Off by default.
    @Published var excludeAV1: Bool {
        didSet { UserDefaults.standard.set(excludeAV1, forKey: Self.excludeAV1Key) }
    }
    /// The remembered Sources-list sort ("best" / "size" / "seeders"), so the list opens the way the user
    /// last left it. "best" (the engine ranking) by default.
    @Published var defaultSourceSort: String {
        didSet { UserDefaults.standard.set(defaultSourceSort, forKey: Self.defaultSortKey) }
    }

    /// True when none of the opt-in filters are engaged, so the ranking can take its no-op fast path.
    var noFiltersActive: Bool {
        !keywordFilterActive && safetyMode == "off"
            && !hideDeadTorrents && !instantOnly && !hdrOnly && !excludeAV1 && maxResolution == 0
            && maxFileSizeGB == 0
    }

    /// Whether the Hide / Require fields impose any filter, accounting for regex vs substring mode.
    var keywordFilterActive: Bool {
        keywordsAreRegex ? (excludeRegex != nil || includeRegex != nil)
                         : (!excludeTerms.isEmpty || !includeTerms.isEmpty)
    }

    /// Parsed, lowercased, non-empty exclude / include terms (substring mode).
    var excludeTerms: [String] { Self.terms(excludeKeywords) }
    var includeTerms: [String] { Self.terms(includeKeywords) }
    private static func terms(_ csv: String) -> [String] {
        csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    /// True if `text` matches `regex` anywhere. Used by the stream filter when regex mode is on.
    func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
    }

    private func rebuildKeywordRegexes() {
        excludeRegex = Self.compilePattern(excludeKeywords, enabled: keywordsAreRegex)
        includeRegex = Self.compilePattern(includeKeywords, enabled: keywordsAreRegex)
    }

    /// Compile a user pattern case-insensitively, or nil when regex mode is off, the field is blank, or the
    /// pattern is invalid (fail-open: a bad regex applies no filter rather than hiding everything).
    private static func compilePattern(_ pattern: String, enabled: Bool) -> NSRegularExpression? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !trimmed.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])
    }

    private init() {
        typeOrder       = Self.readOrder()
        useAddonOrder   = UserDefaults.standard.bool(forKey: Self.addonOrderKey)
        excludeKeywords = UserDefaults.standard.string(forKey: Self.excludeKey) ?? ""
        includeKeywords = UserDefaults.standard.string(forKey: Self.includeKey) ?? ""
        safetyMode      = UserDefaults.standard.string(forKey: Self.safetyKey) ?? "off"
        hideDeadTorrents = UserDefaults.standard.bool(forKey: Self.hideDeadKey)
        instantOnly     = UserDefaults.standard.bool(forKey: Self.instantOnlyKey)
        maxResolution   = UserDefaults.standard.integer(forKey: Self.maxResolutionKey)
        maxFileSizeGB   = UserDefaults.standard.double(forKey: Self.maxFileSizeKey)
        hdrOnly         = UserDefaults.standard.bool(forKey: Self.hdrOnlyKey)
        excludeAV1      = UserDefaults.standard.bool(forKey: Self.excludeAV1Key)
        defaultSourceSort = UserDefaults.standard.string(forKey: Self.defaultSortKey) ?? "best"
        keywordsAreRegex = UserDefaults.standard.bool(forKey: Self.regexKey)
        rebuildKeywordRegexes()   // didSet does not fire for initial assignment, so seed the compiled forms
    }

    private static func readOrder() -> [SourceType] {
        let saved = UserDefaults.standard.string(forKey: orderKey) ?? ""
        var order = saved.split(separator: ",").compactMap { SourceType(rawValue: String($0)) }
        for t in SourceType.allCases where !order.contains(t) { order.append(t) }
        return order
    }

    /// Re-read both keys from UserDefaults into the published props. The singleton reads them only
    /// at init, so a profile switch (which rewrites the flat keys) must call this to take effect
    /// live. The didSet observers re-persist the same values (a no-op write) and invalidate the
    /// ranking cache, which is exactly what a source-preference change needs. Call on the main
    /// thread (same contract as the rest of the profile/theme switch path).
    func reload() {
        let order = Self.readOrder()
        if typeOrder != order { typeOrder = order }
        let addon = UserDefaults.standard.bool(forKey: Self.addonOrderKey)
        if useAddonOrder != addon { useAddonOrder = addon }
    }

    /// Dominant-tier score added to a stream so its source type is the primary sort key.
    func tierWeight(for type: SourceType) -> Int {
        let idx = typeOrder.firstIndex(of: type) ?? (typeOrder.count - 1)
        return idx < Self.tierWeights.count ? Self.tierWeights[idx] : 0
    }

    /// Move the type at `index` one step toward the top (direction = -1) or bottom (+1).
    func moveType(at index: Int, direction: Int) {
        let target = index + direction
        guard target >= 0, target < typeOrder.count else { return }
        typeOrder.swapAt(index, target)
    }

    /// Apply a one-tap quality preset. Sets instant sources first (debrid/usenet play immediately) and the
    /// per-preset caps; each assignment goes through the published knobs so the Settings UI, the per-profile
    /// capture, and the ranking caches all update as if the user had set them by hand.
    func apply(_ preset: SourcePreset) {
        typeOrder = [.debrid, .usenet, .torrent, .direct]
        hideDeadTorrents = true
        switch preset {
        case .bestQuality:
            maxResolution = 0;    maxFileSizeGB = 0;  instantOnly = false; hdrOnly = false; excludeAV1 = false
        case .balanced:
            maxResolution = 0;    maxFileSizeGB = 15; instantOnly = false; hdrOnly = false; excludeAV1 = false
        case .dataSaver:
            maxResolution = 1080; maxFileSizeGB = 4;  instantOnly = true;  hdrOnly = false; excludeAV1 = true
        }
    }
}
