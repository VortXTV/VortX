import Foundation

/// The source categories the ranking system recognises. `mediaServer` is FIRST so `allCases` (the fresh-install
/// default order) puts your own servers at the top, which is what a person who connects one expects.
enum SourceType: String, CaseIterable, Codable {
    case mediaServer = "mediaServer"
    case debrid  = "debrid"
    case usenet  = "usenet"
    case torrent = "torrent"
    case direct  = "direct"

    var label: String {
        switch self {
        case .mediaServer: return "My Servers"
        case .debrid:  return "Debrid"
        case .usenet:  return "Usenet"
        case .torrent: return "Torrent"
        case .direct:  return "Direct"
        }
    }

    var detail: String {
        switch self {
        case .mediaServer: return "Direct play from your Plex, Jellyfin, and Emby servers"
        case .debrid:  return "Real-Debrid, AllDebrid, Premiumize, TorBox, Debrid-Link"
        case .usenet:  return "NZB / Usenet sources"
        case .torrent: return "BitTorrent info-hash streams"
        case .direct:  return "Plain HTTP/HTTPS streams from add-ons"
        }
    }
}

/// One-tap source presets that set the quality caps + source-type order together, so a viewer can pick a
/// taste ("biggest/best files" vs "save data") without tuning each control. Applying one writes the same
/// `@Published` knobs the Settings controls bind to, so their `didSet`s persist + invalidate caches, and every
/// knob it sets is captured per-profile by the Settings `onChange(of: rankingSignature)` trigger exactly like a
/// manual edit. Presets leave the keyword/regex filters and safety mode alone (those are user-owned).
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

/// The read surface `StreamRanking` needs from source preferences at score / filter time. Both the live
/// singleton and an immutable `Snapshot` conform, so the ranker can run on a captured snapshot instead of
/// reading (and racing) the mutable singleton across threads. Keep it in lockstep with what the ranker reads.
protocol SourcePrefsReading {
    var useAddonOrder: Bool { get }
    var typeOrder: [SourceType] { get }
    var noFiltersActive: Bool { get }
    var keywordsAreRegex: Bool { get }
    var excludeRegex: NSRegularExpression? { get }
    var includeRegex: NSRegularExpression? { get }
    var excludeTerms: [String] { get }
    var includeTerms: [String] { get }
    /// Smart Source Selection (Lane A): parsed Prefer terms (a ranking BOOST, never a filter), the Avoid
    /// behavior ("hide" = today's exact drop, "rank" = sink but keep visible), and the auto-pick-my-best
    /// routing flag. All read via the frozen Snapshot so the off-main rank never races the singleton.
    var preferTerms: [String] { get }
    var avoidBehavior: String { get }
    var autoPickBest: Bool { get }
    var safetyMode: String { get }
    var instantOnly: Bool { get }
    var hideDeadTorrents: Bool { get }
    var excludeAV1: Bool { get }
    var hdrOnly: Bool { get }
    var maxResolution: Int { get }
    var minResolution: Int { get }
    var hideUnknownResolution: Bool { get }
    var preferredAudioOnly: Bool { get }
    var maxFileSizeGB: Double { get }
    func tierWeight(for type: SourceType) -> Int
    func matches(_ regex: NSRegularExpression, _ text: String) -> Bool
}

/// Persisted source-ranking preferences.
/// Observed by SettingsView and read by StreamRanking at score time.
final class SourcePreferences: ObservableObject, SourcePrefsReading {
    static let shared = SourcePreferences()

    // Internal (not private) so ProfileStore.applyPlayback writes the same flat keys the singleton reads,
    // instead of re-typing the literal strings (they were the last two duplicated literals in that path).
    static let orderKey              = "stremiox.streaming.sourceTypeOrder"
    static let addonOrderKey         = "stremiox.streaming.useAddonOrder"
    static let excludeKey            = "stremiox.streaming.excludeKeywords"
    static let includeKey            = "stremiox.streaming.includeKeywords"
    static let safetyKey             = "stremiox.streaming.safetyMode"
    static let hideDeadKey           = "stremiox.streaming.hideDeadTorrents"
    static let instantOnlyKey        = "stremiox.streaming.instantOnly"
    static let maxResolutionKey      = "stremiox.streaming.maxResolution"
    static let minResolutionKey      = "stremiox.streaming.minResolution"
    static let hideUnknownResKey     = "stremiox.streaming.hideUnknownResolution"
    static let preferredAudioKey     = "stremiox.streaming.preferredAudioOnly"
    static let maxFileSizeKey        = "stremiox.streaming.maxFileSizeGB"
    static let hdrOnlyKey            = "stremiox.streaming.hdrOnly"
    static let excludeAV1Key         = "stremiox.streaming.excludeAV1"
    static let defaultSortKey        = "stremiox.streaming.defaultSourceSort"
    static let regexKey              = "stremiox.streaming.keywordsAreRegex"
    // Smart Source Selection (Lane A). NEW keys use the vortx.* namespace (the 0.4 rename lands the older
    // stremiox.* keys via a separate dual-read directive; these fresh keys are born vortx.* directly, no
    // migration). Per-profile: they ARE part of Profiles.PlaybackPrefs (folded in exactly like the 13
    // sibling stream-filter knobs), so ProfileStore.applyPlayback captures-before-switch and writes these
    // keys, reload() re-syncs the singleton on a switch, and a Kids profile keeps its own parent-set
    // Avoid words + Avoid behavior instead of a global setting leaking across profiles.
    static let preferKey             = "vortx.streaming.preferKeywords"
    static let avoidBehaviorKey      = "vortx.streaming.avoidBehavior"
    static let autoPickBestKey       = "vortx.streaming.autoPickBest"

    /// Documented per-profile stream-filter defaults, in ONE place. `init()` / `reload()` seed the
    /// string-valued props from these (an absent flat key already reads as the same intrinsic zero /
    /// false for the numeric and Bool ones), and `ProfileStore.applyPlayback` writes these back to the
    /// flat keys when a profile SWITCH lands on a profile that never recorded a field, so the new
    /// profile no longer INHERITS the previously active profile's value (b176 / #117). Change a default
    /// here and both the seed and the switch-reset move together, so the two can never drift.
    static let defaultSafetyMode            = "off"
    static let defaultInstantOnly           = false
    static let defaultHideDeadTorrents      = false
    static let defaultHDROnly               = false
    static let defaultExcludeAV1            = false
    static let defaultExcludeKeywords       = ""
    static let defaultIncludeKeywords       = ""
    static let defaultKeywordsAreRegex      = false
    static let defaultMaxResolution         = 0
    static let defaultMaxFileSizeGB         = 0.0
    static let defaultMinResolution         = 0
    static let defaultHideUnknownResolution = false
    static let defaultPreferredAudioOnly    = false
    static let defaultUseAddonOrder         = false
    // Smart Source Selection (Lane A) defaults. `avoidBehavior` defaults to "hide" so out of the box the
    // Avoid words behave EXACTLY as today's exclude-keyword drop; the viewer opts into "rank" to keep
    // avoided sources visible but demoted. Prefer is empty and auto-pick is off by default.
    static let defaultPreferKeywords        = ""
    static let defaultAvoidBehavior         = "hide"
    static let defaultAutoPickBest          = false
    /// A fresh install's source-type priority: the declared `SourceType` order (Debrid, Usenet,
    /// Torrent, Direct), which is exactly the order `readOrder()` fills in for any missing type.
    static let defaultTypeOrder: [SourceType] = SourceType.allCases
    /// The default type order as the comma-joined raw string the flat key stores.
    static var defaultTypeOrderCSV: String { defaultTypeOrder.map(\.rawValue).joined(separator: ",") }

    // Max possible quality score is ~13,800 (4K + cached + remux + HDR + atmos + file-size cap).
    // A 15,000-point tier gap means the preferred type ALWAYS beats a lower type regardless of quality.
    // FIVE slots now (media servers is the added top tier): the 15k step is preserved, so the ladder
    // invariant (cache +8000 clears the ~5,800 quality spread but stays under the step; junk -100,000 sinks
    // below the ~73.8k legit ceiling) still holds. See architecture.md "StreamRanking weight relationships".
    fileprivate static let tierWeights = [60_000, 45_000, 30_000, 15_000, 0]

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
    /// Smart Source Selection (Lane A) - Prefer words: comma-separated terms that BOOST a matching source
    /// within its tier (a ranking nudge, never a filter, so it can never empty a list). Always matched as
    /// substrings (comma-separated), independent of the Hide/Require regex toggle. Empty = no boost.
    @Published var preferKeywords: String {
        didSet { UserDefaults.standard.set(preferKeywords, forKey: Self.preferKey); StreamRanking.invalidateCaches() }
    }
    /// Smart Source Selection (Lane A) - what "Avoid" (the Hide words / exclude terms) does. "hide" (default)
    /// DROPS a matching source exactly as today's exclude-keyword filter; "rank" keeps it VISIBLE but sinks
    /// its score far below the tier spread. CAM/TS and other junkClass sources stay HARD-hidden by the Safety
    /// filter in BOTH modes regardless of this setting.
    @Published var avoidBehavior: String {
        didSet { UserDefaults.standard.set(avoidBehavior, forKey: Self.avoidBehaviorKey); StreamRanking.invalidateCaches() }
    }
    /// Smart Source Selection (Lane A) - Auto-pick my best source: when on, the detail Play action plays the
    /// single best ranked source straight away (the existing settle + `StreamRanking.best` auto-pick) instead
    /// of surfacing the source list; a secondary/long-press still opens the full list. Off by default.
    @Published var autoPickBest: Bool {
        didSet { UserDefaults.standard.set(autoPickBest, forKey: Self.autoPickBestKey) }
    }
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
    /// Floor the resolution of shown sources (0 = off, else 720 / 1080 / 2160): "hide everything below
    /// 1080p" (#117). The inverse of `maxResolution`, with the SAME unknown-keeps rule mirrored: it only
    /// drops a source whose KNOWN resolution sits below the floor, so an unlabelled source is never
    /// mistaken for a low one. Off (0) by default.
    @Published var minResolution: Int {
        didSet { UserDefaults.standard.set(minResolution, forKey: Self.minResolutionKey) }
    }
    /// Hide sources with no recognizable resolution token at all (#117). The resolution cap and floor
    /// both deliberately KEEP unlabelled sources; this is the separate opt-in for viewers who want only
    /// sources that state their quality. Off by default.
    @Published var hideUnknownResolution: Bool {
        didSet { UserDefaults.standard.set(hideUnknownResolution, forKey: Self.hideUnknownResKey) }
    }
    /// Best-effort audio-language filter (#117): hide a source only when its parsed language signals
    /// POSITIVELY identify a foreign-audio release (the same conservative detection as the ranking's
    /// foreign-audio demotion, `StreamRanking.languageScore`). A source that states no language, carries
    /// the viewer's language, or is multi-language is ALWAYS kept, so this can never empty a list just
    /// because add-ons do not tag languages. Off by default.
    @Published var preferredAudioOnly: Bool {
        didSet { UserDefaults.standard.set(preferredAudioOnly, forKey: Self.preferredAudioKey) }
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
    /// Prefer terms count as "active" too: even though they only BOOST (never filter), keeping the fast
    /// path off when any exist means the ranker always applies the prefer nudge (Lane A). Avoid terms in
    /// "rank" mode still register through `keywordFilterActive` (they are exclude terms), so they too keep
    /// the fast path off, which is what the rank-mode scoring needs.
    var noFiltersActive: Bool {
        !keywordFilterActive && preferTerms.isEmpty && safetyMode == "off"
            && !hideDeadTorrents && !instantOnly && !hdrOnly && !excludeAV1 && maxResolution == 0
            && minResolution == 0 && !hideUnknownResolution && !preferredAudioOnly && maxFileSizeGB == 0
    }

    /// Whether the Hide / Require fields impose any filter, accounting for regex vs substring mode.
    var keywordFilterActive: Bool {
        keywordsAreRegex ? (excludeRegex != nil || includeRegex != nil)
                         : (!excludeTerms.isEmpty || !includeTerms.isEmpty)
    }

    /// A compact fingerprint of every preference that changes stream FILTERING or RANKING order. The detail
    /// source list memoizes its expensive ranked-groups computation and folds this into the cache key, so a
    /// settings change (a new keyword filter, a different sort, add-on order on or off) invalidates that cache
    /// even when the stream set itself is unchanged. Keep in sync with what `applyUserFilters` / `rankedGroups`
    /// / `best` actually read.
    var rankingSignature: String {
        [typeOrder.map(\.rawValue).joined(separator: ","),
         useAddonOrder ? "1" : "0",
         defaultSourceSort,
         excludeKeywords, includeKeywords, keywordsAreRegex ? "1" : "0",
         safetyMode,
         hideDeadTorrents ? "1" : "0",
         instantOnly ? "1" : "0",
         String(maxResolution),
         String(minResolution),
         hideUnknownResolution ? "1" : "0",
         preferredAudioOnly ? "1" : "0",
         String(maxFileSizeGB),
         hdrOnly ? "1" : "0",
         excludeAV1 ? "1" : "0",
         // Smart Source Selection (Lane A): the Prefer words and the Avoid behavior both change RANK order,
         // and the auto-pick flag changes which source Play lands on, so all three must invalidate the
         // detail memo when they change (per the off-main race + memo contract).
         preferKeywords, avoidBehavior, autoPickBest ? "1" : "0",
         // Preferred audio languages live in TrackPreferences (a separate UserDefaults key), but the ranker's
         // score() reads them via languageScore -> a -5000 foreign-audio demotion that reorders results. Fold them
         // in so the detail memo invalidates when the viewer changes preferred audio language.
         TrackPreferences.current.audioLanguages.joined(separator: ",")].joined(separator: "|")
    }

    /// Parsed, lowercased, non-empty exclude / include terms (substring mode).
    var excludeTerms: [String] { Self.terms(excludeKeywords) }
    var includeTerms: [String] { Self.terms(includeKeywords) }
    /// Parsed, lowercased, non-empty Prefer terms (Lane A). Always substring mode (the Prefer boost never
    /// uses regex), so it mirrors excludeTerms/includeTerms exactly.
    var preferTerms: [String] { Self.terms(preferKeywords) }
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
        excludeKeywords = UserDefaults.standard.string(forKey: Self.excludeKey) ?? Self.defaultExcludeKeywords
        includeKeywords = UserDefaults.standard.string(forKey: Self.includeKey) ?? Self.defaultIncludeKeywords
        safetyMode      = UserDefaults.standard.string(forKey: Self.safetyKey) ?? Self.defaultSafetyMode
        hideDeadTorrents = UserDefaults.standard.bool(forKey: Self.hideDeadKey)
        instantOnly     = UserDefaults.standard.bool(forKey: Self.instantOnlyKey)
        maxResolution   = UserDefaults.standard.integer(forKey: Self.maxResolutionKey)
        minResolution   = UserDefaults.standard.integer(forKey: Self.minResolutionKey)
        hideUnknownResolution = UserDefaults.standard.bool(forKey: Self.hideUnknownResKey)
        preferredAudioOnly = UserDefaults.standard.bool(forKey: Self.preferredAudioKey)
        maxFileSizeGB   = UserDefaults.standard.double(forKey: Self.maxFileSizeKey)
        hdrOnly         = UserDefaults.standard.bool(forKey: Self.hdrOnlyKey)
        excludeAV1      = UserDefaults.standard.bool(forKey: Self.excludeAV1Key)
        defaultSourceSort = UserDefaults.standard.string(forKey: Self.defaultSortKey) ?? "best"
        keywordsAreRegex = UserDefaults.standard.bool(forKey: Self.regexKey)
        // Smart Source Selection (Lane A). Absent keys read as the documented defaults ("" / "hide" / false),
        // so a fresh install reproduces today's exact behavior (empty Prefer, Avoid hides, no auto-pick).
        preferKeywords = UserDefaults.standard.string(forKey: Self.preferKey) ?? Self.defaultPreferKeywords
        avoidBehavior  = UserDefaults.standard.string(forKey: Self.avoidBehaviorKey) ?? Self.defaultAvoidBehavior
        autoPickBest   = UserDefaults.standard.object(forKey: Self.autoPickBestKey) as? Bool ?? Self.defaultAutoPickBest
        rebuildKeywordRegexes()   // didSet does not fire for initial assignment, so seed the compiled forms
    }

    private static func readOrder() -> [SourceType] {
        let saved = UserDefaults.standard.string(forKey: orderKey) ?? ""
        var order = saved.split(separator: ",").compactMap { SourceType(rawValue: String($0)) }
        // Media servers migrate to the FRONT when a stored order predates the tier (your own copy outranks
        // everything by default). Idempotent: a user who later reorders it away is never re-migrated (the token
        // is then present). New installs have an empty stored order, so the general append below already fronts
        // it (mediaServer is the first `allCases`).
        if !order.isEmpty, !order.contains(.mediaServer) { order.insert(.mediaServer, at: 0) }
        for t in SourceType.allCases where !order.contains(t) { order.append(t) }
        return order
    }

    /// Re-read both keys from UserDefaults into the published props. The singleton reads them only
    /// at init, so a profile switch (which rewrites the flat keys) must call this to take effect
    /// live. The didSet observers re-persist the same values (a no-op write) and invalidate the
    /// ranking cache, which is exactly what a source-preference change needs. Call on the main
    /// thread (same contract as the rest of the profile/theme switch path).
    func reload() {
        let d = UserDefaults.standard
        let order = Self.readOrder()
        if typeOrder != order { typeOrder = order }
        let addon = d.bool(forKey: Self.addonOrderKey)
        if useAddonOrder != addon { useAddonOrder = addon }
        // Stream filters, so a per-profile switch re-syncs the in-memory @Published values (not just the
        // type order). Guarded so an unchanged value never churns @Published or rebuilds keyword regexes.
        let safety = d.string(forKey: Self.safetyKey) ?? Self.defaultSafetyMode
        if safetyMode != safety { safetyMode = safety }
        let instant = d.bool(forKey: Self.instantOnlyKey)
        if instantOnly != instant { instantOnly = instant }
        let dead = d.bool(forKey: Self.hideDeadKey)
        if hideDeadTorrents != dead { hideDeadTorrents = dead }
        let hdr = d.bool(forKey: Self.hdrOnlyKey)
        if hdrOnly != hdr { hdrOnly = hdr }
        let av1 = d.bool(forKey: Self.excludeAV1Key)
        if excludeAV1 != av1 { excludeAV1 = av1 }
        let exc = d.string(forKey: Self.excludeKey) ?? Self.defaultExcludeKeywords
        if excludeKeywords != exc { excludeKeywords = exc }
        let inc = d.string(forKey: Self.includeKey) ?? Self.defaultIncludeKeywords
        if includeKeywords != inc { includeKeywords = inc }
        let rx = d.bool(forKey: Self.regexKey)
        if keywordsAreRegex != rx { keywordsAreRegex = rx }
        let maxRes = d.integer(forKey: Self.maxResolutionKey)
        if maxResolution != maxRes { maxResolution = maxRes }
        let minRes = d.integer(forKey: Self.minResolutionKey)
        if minResolution != minRes { minResolution = minRes }
        let hideUnknown = d.bool(forKey: Self.hideUnknownResKey)
        if hideUnknownResolution != hideUnknown { hideUnknownResolution = hideUnknown }
        let prefAudio = d.bool(forKey: Self.preferredAudioKey)
        if preferredAudioOnly != prefAudio { preferredAudioOnly = prefAudio }
        let maxGB = d.double(forKey: Self.maxFileSizeKey)
        if maxFileSizeGB != maxGB { maxFileSizeGB = maxGB }
        // Smart Source Selection (Lane A). Per-profile now (folded into PlaybackPrefs): a profile switch
        // rewrites these flat keys via applyPlayback, so this guarded re-read re-syncs the singleton's
        // in-memory @Published values on a switch, exactly like the filters above (and also picks up a
        // settings-backup restore). Guarded so an unchanged value never churns @Published.
        let prefer = d.string(forKey: Self.preferKey) ?? Self.defaultPreferKeywords
        if preferKeywords != prefer { preferKeywords = prefer }
        let avoid = d.string(forKey: Self.avoidBehaviorKey) ?? Self.defaultAvoidBehavior
        if avoidBehavior != avoid { avoidBehavior = avoid }
        let autoPick = d.object(forKey: Self.autoPickBestKey) as? Bool ?? Self.defaultAutoPickBest
        if autoPickBest != autoPick { autoPickBest = autoPick }
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
        typeOrder = [.mediaServer, .debrid, .usenet, .torrent, .direct]
        hideDeadTorrents = true
        // Presets own the quality CAPS, so they also clear any resolution floor: leaving a user's 4K
        // floor under Data Saver's 1080p cap would filter out every labelled source.
        minResolution = 0
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

// MARK: - Off-main snapshot (the race fix for SourceListModel's detached rank)

extension SourcePreferences {

    /// An immutable capture of the ranking-relevant preferences, taken ON THE MAIN ACTOR. `StreamRanking`
    /// installs one as a task-local (`readingOverride`) around its off-main rank so it never reads the
    /// mutable singleton's in-memory state across threads. The singleton's `@Published` props and the
    /// `excludeRegex` / `includeRegex` references are reassigned on the main thread (Settings edits,
    /// `reload()` on a profile switch); the old main-actor `DetailRankMemo` ran the rank on the main actor,
    /// so moving it into `Task.detached` made this the first off-main reader. Carrying the compiled regex
    /// references is safe: `NSRegularExpression` is documented immutable + thread-safe for matching, so only
    /// the singleton's concurrent REASSIGNMENT was the race, and a snapshot freezes that out.
    struct Snapshot: SourcePrefsReading, @unchecked Sendable {   // @unchecked: NSRegularExpression is thread-safe for matching but not Sendable-marked
        let useAddonOrder: Bool
        let typeOrder: [SourceType]
        let noFiltersActive: Bool
        let keywordsAreRegex: Bool
        let excludeRegex: NSRegularExpression?
        let includeRegex: NSRegularExpression?
        let excludeTerms: [String]
        let includeTerms: [String]
        let preferTerms: [String]
        let avoidBehavior: String
        let autoPickBest: Bool
        let safetyMode: String
        let instantOnly: Bool
        let hideDeadTorrents: Bool
        let excludeAV1: Bool
        let hdrOnly: Bool
        let maxResolution: Int
        let minResolution: Int
        let hideUnknownResolution: Bool
        let preferredAudioOnly: Bool
        let maxFileSizeGB: Double

        /// Same logic as `SourcePreferences.tierWeight`, over the snapshotted `typeOrder`.
        func tierWeight(for type: SourceType) -> Int {
            let idx = typeOrder.firstIndex(of: type) ?? (typeOrder.count - 1)
            return idx < SourcePreferences.tierWeights.count ? SourcePreferences.tierWeights[idx] : 0
        }
        /// Same matching as `SourcePreferences.matches` (pure; `NSRegularExpression` matching is thread-safe).
        func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
            regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    /// Capture the ranking-relevant prefs into an immutable, thread-safe `Snapshot`. MUST be called on the
    /// main actor (the singleton is only ever mutated there), so every captured value is mutually consistent.
    func snapshot() -> Snapshot {
        Snapshot(useAddonOrder: useAddonOrder, typeOrder: typeOrder, noFiltersActive: noFiltersActive,
                 keywordsAreRegex: keywordsAreRegex, excludeRegex: excludeRegex, includeRegex: includeRegex,
                 excludeTerms: excludeTerms, includeTerms: includeTerms, preferTerms: preferTerms,
                 avoidBehavior: avoidBehavior, autoPickBest: autoPickBest, safetyMode: safetyMode,
                 instantOnly: instantOnly, hideDeadTorrents: hideDeadTorrents, excludeAV1: excludeAV1,
                 hdrOnly: hdrOnly, maxResolution: maxResolution, minResolution: minResolution,
                 hideUnknownResolution: hideUnknownResolution, preferredAudioOnly: preferredAudioOnly,
                 maxFileSizeGB: maxFileSizeGB)
    }

    /// The off-main override for the ranker. When installed (by `SourceListModel`'s detached rank via
    /// `$readingOverride.withValue(...)`), `reading` returns this frozen snapshot instead of the live
    /// singleton, so the off-main rank cannot race the main-thread mutation. `Task.detached` does NOT
    /// inherit task-locals, so the `withValue` MUST wrap the rank inside the detached task.
    @TaskLocal static var readingOverride: Snapshot?

    /// What the ranker reads: the installed off-main snapshot if present, else the live singleton. Main-actor
    /// callers install nothing, so they read `shared` exactly as before (identical behavior, zero allocation).
    static var reading: SourcePrefsReading { readingOverride ?? shared }
}
