import Foundation
import CryptoKit

/// One viewer of the app: local view settings (name, avatar, theme, parental PIN) plus an optional
/// binding to its own Stremio account. Profiles without their own account share the primary one,
/// so a "Kids" profile can be the same account with a different look and a PIN on the way out.
struct UserProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var avatar: String                 // an emoji
    var accentID: String = "ember"
    var oled: Bool = false
    /// App UI text scale (0.80 to 1.40). Per-profile appearance, mirrored into ThemeManager on
    /// switch alongside accent/oled, so a Kids profile can run big text without changing an adult's.
    var textScale: Double = 1.0
    var pin: String? = nil             // 4-digit parental gate, nil = open
    var usesOwnAccount: Bool = false   // true = its own Stremio session in its own Keychain slot
    var email: String? = nil           // bound account email, display only
    /// The account's main profile (the one created by migration). It uses the account's own watch
    /// history, exactly like before profiles existed. Every other shared profile keeps its own.
    var isOwner: Bool = false
    /// Family head (the account owner) may edit this profile from the vortx.tv dashboard WITHOUT its
    /// PIN. Per-secondary, set from the dashboard. Default false. Governs WEB edit permission only,
    /// not the on-device profile-switch PIN gate (see vortx-dashboard-profile-mgmt-design).
    var familyEdit: Bool = false
    /// Per-profile playback preferences (audio/subtitle language plus subtitle style), mirrored
    /// into the flat UserDefaults keys the player reads when this profile becomes active.
    /// nil = never customized (pre-feature roster); seeded from the flat values on first load.
    var playback: PlaybackPrefs? = nil

    /// Add-on transport URLs this profile has turned OFF. A per-profile, local overlay: the add-on
    /// stays installed on the account, it is just hidden from THIS profile's Home rows, Discover,
    /// and stream sources. nil/empty = every installed add-on is on, so older rosters and freshly
    /// installed add-ons default to visible. A Kids profile can drop the adult/torrent add-ons
    /// without touching anyone else. Follows the profile across devices like the rest of the roster.
    var disabledAddons: [String]? = nil

    /// Kids profile: a parental-controls flag. When this profile is active the source list hides adult
    /// content and CAM/fake junk regardless of the global source filters (see
    /// `StreamRanking.passesUserFilters`). Pair it with a PIN on the adult profiles (so a child can't
    /// switch into them) and per-profile add-on hiding. Default false; follows the profile across devices.
    var isKids: Bool = false

    /// What follows a viewer between profiles: track languages and the subtitle look. Synced
    /// with the roster, so a profile keeps its preferences across devices. Raw-string fields
    /// mirror the UserDefaults representations one-to-one.
    struct PlaybackPrefs: Codable, Equatable {
        var audioLang: String
        var subtitleLang: String
        var forcedPolicy: String
        var subFont: String
        var subSize: String
        var subColor: String
        var subBackground: String
        var subSizeScale: Double? = nil   // optional so older rosters decode
        /// Stream source-ranking taste (Debrid-first vs Torrent-first, trust add-on order vs app
        /// order). Optional so older rosters decode; nil means "leave the flat keys as they are".
        var sourceTypeOrder: [String]? = nil   // raw SourceType values, top priority first
        var useAddonOrder: Bool? = nil
    }

    var hasPin: Bool { !(pin ?? "").isEmpty }

    /// Salted hash for a PIN, stored instead of the raw digits so a PIN can be
    /// changed but never read back. The salt is the profile id, which is stable
    /// across devices, so hashed PINs survive roster sync.
    ///
    /// NOTE: this is a parental gate, NOT a security boundary. The salt (the profile id) travels in
    /// the synced roster payload, so it is not secret; the hash only stops trivial plaintext
    /// readback, not an attacker who can read the roster. Do not rely on it to protect anything
    /// sensitive. The legacy plaintext path in pinMatches is migration-only.
    static func pinHash(_ raw: String, profileID: UUID) -> String {
        let digest = SHA256.hash(data: Data("\(profileID.uuidString):\(raw)".utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the input unlocks this profile. Accepts hashed entries and the
    /// legacy plaintext ones from rosters saved before hashing existed.
    func pinMatches(_ input: String) -> Bool {
        guard let stored = pin, !stored.isEmpty else { return true }
        if stored.hasPrefix("sha256:") { return stored == Self.pinHash(input, profileID: id) }
        return stored == input
    }
    /// Whether this profile's history is the account library itself (the owner, and any profile on
    /// its own account) or a private synced overlay (every other shared profile).
    var usesEngineHistory: Bool { isOwner || usesOwnAccount }

    /// Tolerant decoding so rosters saved by older builds (without the newer keys) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Profile"
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar) ?? "🍿"
        accentID = try c.decodeIfPresent(String.self, forKey: .accentID) ?? "ember"
        oled = try c.decodeIfPresent(Bool.self, forKey: .oled) ?? false
        textScale = try c.decodeIfPresent(Double.self, forKey: .textScale) ?? 1.0
        pin = try c.decodeIfPresent(String.self, forKey: .pin)
        usesOwnAccount = try c.decodeIfPresent(Bool.self, forKey: .usesOwnAccount) ?? false
        email = try c.decodeIfPresent(String.self, forKey: .email)
        isOwner = try c.decodeIfPresent(Bool.self, forKey: .isOwner) ?? false
        familyEdit = try c.decodeIfPresent(Bool.self, forKey: .familyEdit) ?? false
        playback = try c.decodeIfPresent(PlaybackPrefs.self, forKey: .playback)
        disabledAddons = try c.decodeIfPresent([String].self, forKey: .disabledAddons)
        isKids = try c.decodeIfPresent(Bool.self, forKey: .isKids) ?? false
    }

    init(id: UUID = UUID(), name: String, avatar: String, accentID: String = "ember",
         oled: Bool = false, textScale: Double = 1.0, pin: String? = nil, usesOwnAccount: Bool = false,
         email: String? = nil, isOwner: Bool = false, familyEdit: Bool = false, playback: PlaybackPrefs? = nil,
         disabledAddons: [String]? = nil, isKids: Bool = false) {
        self.id = id; self.name = name; self.avatar = avatar; self.accentID = accentID
        self.oled = oled; self.textScale = textScale; self.pin = pin; self.usesOwnAccount = usesOwnAccount
        self.email = email; self.isOwner = isOwner; self.familyEdit = familyEdit; self.playback = playback
        self.disabledAddons = disabledAddons
        self.isKids = isKids
    }
}

/// The profile roster and the active selection. The roster persists as JSON in UserDefaults; each
/// own-account profile keeps its Stremio authKey in its own Keychain slot, and the pre-profiles
/// primary slot keeps serving every shared profile. Mutate from the main thread only (the
/// ThemeManager pattern; views observe via @EnvironmentObject).
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published private(set) var profiles: [UserProfile] = []
    @Published private(set) var activeID: UUID?
    /// The launch picker shows once per cold start, and only when there is a real choice to make.
    /// Settings re-opens it by flipping this back to false.
    @Published var pickedThisLaunch = false
    /// The ACTIVE overlay profile's private watch state, keyed by meta id. Drives its Continue
    /// Watching rail, resume, and watched markers. Empty for the owner profile (it uses the
    /// account library directly).
    @Published private(set) var watch: [String: WatchEntry] = [:]

    private static let listKey = "stremiox.profiles"
    private static let activeKey = "stremiox.profiles.active"
    private static let modifiedKey = "stremiox.profiles.modified"
    private static func watchCacheKey(_ id: UUID) -> String { "stremiox.profiles.watch." + id.uuidString }
    /// The pre-profiles single-account Keychain slot; shared profiles keep using it.
    static let primaryTokenAccount = "stremiox.authKey"

    /// Flat mirror of the ACTIVE profile's disabled add-on set, rewritten on every profile apply so
    /// the off-main board build (`buildBoardRows`) and the main-actor `streamGroups` can both read it
    /// cheaply without decoding the whole roster. Same pattern as `applyPlayback` flattening playback
    /// prefs and `CatalogPrefsStore` exposing static UserDefaults reads.
    static let activeDisabledAddonsKey = "stremiox.profile.disabledAddons"
    /// Add-on transport URLs hidden for the active profile (thread-safe, off-main read). Callers hoist
    /// this once per pass and test `.contains` inside their loop, cheaper than a per-item lookup that
    /// would re-read UserDefaults and rebuild the set on the off-main board path.
    static func activeDisabledAddons() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: activeDisabledAddonsKey) ?? [])
    }

    /// Flat mirror of the active profile's Kids flag, same off-main pattern as `activeDisabledAddonsKey`,
    /// so the stream filter (which may run off the main actor) can force the parental content guard on
    /// without decoding the roster.
    static let activeKidsKey = "stremiox.profile.isKids"
    static func activeIsKids() -> Bool { UserDefaults.standard.bool(forKey: activeKidsKey) }

    private var pushRosterTask: Task<Void, Never>?
    private var pushWatchTask: Task<Void, Never>?

    private init() {
        load()
        if profiles.isEmpty { migrateFromSingleAccount() }
        hashLegacyPins()
        // Rosters saved before history separation existed have no owner; the migrated first
        // profile is the account's main one.
        if !profiles.contains(where: { $0.isOwner }), !profiles.isEmpty {
            profiles[0].isOwner = true
            persist(touch: false)
        }
        normalizeOwner()
        if activeID == nil || !profiles.contains(where: { $0.id == activeID }) {
            activeID = profiles.first?.id
        }
        // The active profile owns the theme; resync in case the stored values drifted. Seed the
        // add-on-visibility flat key too, so the first board build at launch honors the active
        // profile's set (no CoreBridge call here: the board is built later from the engine event).
        if let active {
            applyTheme(active)
            UserDefaults.standard.set(active.disabledAddons ?? [], forKey: Self.activeDisabledAddonsKey)
            UserDefaults.standard.set(active.isKids, forKey: Self.activeKidsKey)
        }
        // One-time seed: pre-feature rosters share one flat set of playback preferences, so
        // copying it into every profile preserves today's behavior exactly; from then on each
        // profile diverges as its viewer customizes.
        if profiles.contains(where: { $0.playback == nil }) {
            let seed = currentPlaybackPrefs()
            for index in profiles.indices where profiles[index].playback == nil {
                profiles[index].playback = seed
            }
            persist(touch: false)
        }
        loadWatchCache()
    }

    var activeUsesEngineHistory: Bool { active?.usesEngineHistory ?? true }

    var active: UserProfile? { profiles.first { $0.id == activeID } }
    var needsPicker: Bool { profiles.count > 1 && !pickedThisLaunch }

    /// The Keychain slot the rest of the app reads the session from right now. StremioAccount and
    /// CoreBridge resolve their token through this, so a profile switch re-points both at once.
    var activeKeychainAccount: String {
        active.map(keychainAccount(for:)) ?? Self.primaryTokenAccount
    }

    func keychainAccount(for profile: UserProfile) -> String {
        // The owner IS the primary account: it always reads the primary slot, no matter what the
        // usesOwnAccount flag says. (A synced roster once arrived with the flag flipped on the
        // owner, which pointed sign-in at an empty per-profile slot and "signed out" every device.)
        if profile.isOwner { return Self.primaryTokenAccount }
        return profile.usesOwnAccount ? Self.primaryTokenAccount + "." + profile.id.uuidString
                                      : Self.primaryTokenAccount
    }

    /// What the account layer must do after a switch. `.switchAccount` carries the new profile's
    /// stored token; `.needsSignIn` means the profile wants its own account but has no session yet.
    enum SwitchOutcome { case sameAccount, switchAccount(token: String), needsSignIn }

    /// Make `profile` active: applies its theme immediately and reports the account work left.
    @discardableResult
    func select(_ profile: UserProfile) -> SwitchOutcome {
        let beforeAccount = active.map(keychainAccount(for:))
        activeID = profile.id
        pickedThisLaunch = true
        persist(touch: false)   // selection is per-device, not a roster edit
        applyTheme(profile)
        applyPlayback(profile)
        SourcePreferences.shared.reload()   // re-sync the singleton's @Published order on a switch
        loadWatchCache()
        refreshWatchFromServer()
        let nowAccount = keychainAccount(for: profile)
        if nowAccount == beforeAccount { return .sameAccount }
        if let token = Keychain.string(nowAccount), !token.isEmpty { return .switchAccount(token: token) }
        return .needsSignIn
    }

    func add(_ profile: UserProfile) {
        profiles.append(profile)
        persist()
    }

    func update(_ profile: UserProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        persist()
        if profile.id == activeID {
            applyTheme(profile)
            applyPlayback(profile)
        }
    }

    /// Flip an add-on on/off for the ACTIVE profile. A local per-profile overlay, NOT an account
    /// change: the add-on stays installed and stays on for every other profile. update() persists the
    /// roster, schedules the cross-device push, and re-applies prefs, where applyPlayback flattens the
    /// new set into the read key and rebuilds Home so the change shows at once.
    func toggleAddon(base: String) {
        guard var profile = active else { return }
        var set = Set(profile.disabledAddons ?? [])
        if set.contains(base) { set.remove(base) } else { set.insert(base) }
        profile.disabledAddons = set.isEmpty ? nil : set.sorted()
        update(profile)
    }

    /// Whether an add-on (by transport URL) is currently turned off for the active profile.
    func isAddonDisabledForActive(base: String) -> Bool {
        Set(active?.disabledAddons ?? []).contains(base)
    }

    /// Remove a profile (never the last one). Its private session key is deleted with it. Returns
    /// the switch outcome when the removed profile was the active one, nil otherwise.
    @discardableResult
    func remove(_ profile: UserProfile) -> SwitchOutcome? {
        guard profiles.count > 1, profiles.contains(where: { $0.id == profile.id }) else { return nil }
        profiles.removeAll { $0.id == profile.id }
        if profile.usesOwnAccount { Keychain.set(nil, for: keychainAccount(for: profile)) }
        UserDefaults.standard.removeObject(forKey: Self.watchCacheKey(profile.id))
        persist()
        if activeID == profile.id, let first = profiles.first { return select(first) }
        return nil
    }

    /// Apply web-authored profile edits (the vortx.tv dashboard writes doc.profileEdits; the app reads it
    /// on sync-down): update name / familyEdit / pin on existing profiles, CREATE a web-authored new
    /// profile (an id not seen locally), DELETE a tombstoned one (HARD-GATED: never the owner, and
    /// remove() itself refuses the last profile), and feed per-profile library adds into the overlay.
    /// Union-safe: a profile absent from the edits is left untouched. See [[vortx-dashboard-profile-mgmt-design]].
    func applyProfileEdits(_ edits: [String: Any]) {
        if let roster = edits["roster"] as? [[String: Any]] {
            for e in roster {
                guard let idStr = e["id"] as? String, let uuid = UUID(uuidString: idStr) else { continue }
                let existing = profiles.first(where: { $0.id == uuid })
                if e["deleted"] as? Bool == true {
                    // DELETE, hard-gated: only a non-owner profile; remove() refuses the last one and
                    // clears that profile's watch cache + per-profile keychain slot.
                    if let target = existing, !target.isOwner { remove(target) }
                    continue
                }
                if var p = existing {
                    var changed = false
                    if let name = (e["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !name.isEmpty, name != p.name { p.name = name; changed = true }
                    if let fe = e["familyEdit"] as? Bool, fe != p.familyEdit { p.familyEdit = fe; changed = true }
                    if e.keys.contains("pin") {
                        let newPin = (e["pin"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        if newPin != p.pin { p.pin = newPin; changed = true }
                    }
                    // Per-profile app settings managed from the dashboard (appearance + playback). update()
                    // re-applies theme + playback to the live app when this is the active profile.
                    if let st = e["settings"] as? [String: Any] {
                        if let a = st["avatar"] as? String, !a.isEmpty, a != p.avatar { p.avatar = a; changed = true }
                        if let ac = st["accent"] as? String, !ac.isEmpty, ac != p.accentID { p.accentID = ac; changed = true }
                        if let o = st["oled"] as? Bool, o != p.oled { p.oled = o; changed = true }
                        if let ts = st["textScale"] as? Double, ts != p.textScale { p.textScale = ts; changed = true }
                        if let pbDict = st["playback"] as? [String: Any] {
                            let next = Self.playbackPrefs(from: pbDict, base: p.playback)
                            if next != p.playback { p.playback = next; changed = true }
                        }
                    }
                    if changed { update(p) }
                } else {
                    // CREATE: a new secondary the dashboard added (never an owner). Defaults match a
                    // normal new profile; playback is seeded on the next load like any pre-feature roster.
                    guard let name = (e["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !name.isEmpty else { continue }
                    add(UserProfile(id: uuid, name: name, avatar: "🍿",
                                    pin: (e["pin"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                    isOwner: false, familyEdit: (e["familyEdit"] as? Bool) ?? false))
                }
            }
        }
        if let adds = edits["libraryAdds"] as? [String: Any] {
            for (idStr, raw) in adds {
                guard let uuid = UUID(uuidString: idStr), let items = raw as? [[String: Any]] else { continue }
                if let target = profiles.first(where: { $0.id == uuid }), target.usesEngineHistory {
                    // Owner / own-account profile: its library IS the account (engine) library, not an
                    // overlay. Add each resolved Cinemeta title to the engine (real catalog id, safe for
                    // account sync). applyRemoteOverlay would skip it (it refuses engine-backed profiles).
                    for it in items {
                        guard let metaId = it["id"] as? String, !metaId.isEmpty else { continue }
                        let type = (it["type"] as? String) ?? "movie"
                        Task { await CoreBridge.shared.addCatalogItemToAccount(id: metaId, type: type) }
                    }
                    continue
                }
                var entries: [String: WatchEntry] = [:]
                for it in items {
                    guard let metaId = it["id"] as? String, !metaId.isEmpty else { continue }
                    entries[metaId] = WatchEntry(videoId: nil, timeOffsetMs: 0, durationMs: 0,
                        lastWatched: Self.isoNow(), name: it["name"] as? String ?? "",
                        type: it["type"] as? String ?? "movie",
                        poster: (it["poster"] as? String).flatMap { $0.isEmpty ? nil : $0 })
                }
                applyRemoteOverlay(profileID: uuid, entries: entries)
            }
        }
    }

    /// Build a PlaybackPrefs from a dashboard `settings.playback` dict, falling back to the profile's
    /// current prefs (then sane empties) for any field the dashboard did not send.
    private static func playbackPrefs(from d: [String: Any], base: UserProfile.PlaybackPrefs?) -> UserProfile.PlaybackPrefs {
        UserProfile.PlaybackPrefs(
            audioLang: d["audioLang"] as? String ?? base?.audioLang ?? "",
            subtitleLang: d["subtitleLang"] as? String ?? base?.subtitleLang ?? "",
            forcedPolicy: d["forced"] as? String ?? base?.forcedPolicy ?? "",
            subFont: d["subFont"] as? String ?? base?.subFont ?? "",
            subSize: d["subSize"] as? String ?? base?.subSize ?? "",
            subColor: d["subColor"] as? String ?? base?.subColor ?? "",
            subBackground: d["subBackground"] as? String ?? base?.subBackground ?? "",
            subSizeScale: d["subSizeScale"] as? Double ?? base?.subSizeScale,
            sourceTypeOrder: d["sourceTypeOrder"] as? [String] ?? base?.sourceTypeOrder,
            useAddonOrder: d["useAddonOrder"] as? Bool ?? base?.useAddonOrder)
    }

    /// Push a profile's appearance (accent, OLED chrome, UI text scale) into the live ThemeManager.
    /// The single place every switch/update/sync site goes through, so adding a per-profile
    /// appearance field only touches here and captureTheme().
    private func applyTheme(_ profile: UserProfile) {
        let tm = ThemeManager.shared
        tm.accentID = profile.accentID
        tm.oled = profile.oled
        tm.textScale = min(max(profile.textScale, ThemeManager.textScaleRange.lowerBound),
                           ThemeManager.textScaleRange.upperBound)
    }

    /// The Settings appearance controls write to ThemeManager; mirror the result into the active
    /// profile so it survives a switch and a relaunch.
    func captureTheme() {
        guard var profile = active else { return }
        let tm = ThemeManager.shared
        guard profile.accentID != tm.accentID || profile.oled != tm.oled || profile.textScale != tm.textScale else { return }
        profile.accentID = tm.accentID
        profile.oled = tm.oled
        profile.textScale = tm.textScale
        update(profile)
    }

    // MARK: Per-profile playback preferences (languages + subtitle style)

    /// The flat-key values as a PlaybackPrefs snapshot, using the same fallbacks the readers use.
    private func currentPlaybackPrefs() -> UserProfile.PlaybackPrefs {
        let d = UserDefaults.standard
        let lang = TrackPreferences.deviceLanguages.first ?? "en"
        return UserProfile.PlaybackPrefs(
            audioLang: d.string(forKey: TrackPreferences.Key.audio) ?? lang,
            subtitleLang: d.string(forKey: TrackPreferences.Key.subtitle) ?? lang,
            forcedPolicy: d.string(forKey: TrackPreferences.Key.forced) ?? TrackPreferences.ForcedPolicy.forced.rawValue,
            subFont: d.string(forKey: SubtitleStyle.Key.font) ?? SubtitleStyle.defaultFont,
            subSize: d.string(forKey: SubtitleStyle.Key.size) ?? SubtitleStyle.defaultSize,
            subColor: d.string(forKey: SubtitleStyle.Key.color) ?? SubtitleStyle.defaultColor,
            subBackground: d.string(forKey: SubtitleStyle.Key.background) ?? SubtitleStyle.defaultBackground,
            subSizeScale: d.object(forKey: SubtitleStyle.Key.sizeScale) as? Double ?? 1.0,
            sourceTypeOrder: SourcePreferences.shared.typeOrder.map(\.rawValue),
            useAddonOrder: SourcePreferences.shared.useAddonOrder)
    }

    /// Write `profile`'s playback preferences into the flat UserDefaults keys that
    /// TrackPreferences, SubtitleStyle, and the @AppStorage bindings all read. The player and
    /// Settings need no changes: the flat keys simply always reflect the active profile.
    private func applyPlayback(_ profile: UserProfile) {
        let d = UserDefaults.standard
        // Per-profile add-on visibility: flatten this profile's disabled set into the key the off-main
        // board build and streamGroups read, so Home, Discover, and stream sources all honor it the
        // moment this profile becomes active. (Empty array = nothing hidden, the default.)
        d.set(profile.disabledAddons ?? [], forKey: Self.activeDisabledAddonsKey)
        d.set(profile.isKids, forKey: Self.activeKidsKey)   // Kids content guard for the stream filter
        if let p = profile.playback {
            d.set(p.audioLang, forKey: TrackPreferences.Key.audio)
            d.set(p.subtitleLang, forKey: TrackPreferences.Key.subtitle)
            d.set(p.forcedPolicy, forKey: TrackPreferences.Key.forced)
            d.set(p.subFont, forKey: SubtitleStyle.Key.font)
            d.set(p.subSize, forKey: SubtitleStyle.Key.size)
            d.set(p.subColor, forKey: SubtitleStyle.Key.color)
            d.set(p.subBackground, forKey: SubtitleStyle.Key.background)
            d.set(p.subSizeScale ?? 1.0, forKey: SubtitleStyle.Key.sizeScale)
            // Source-ranking taste (older rosters have nil here, so leave the flat keys untouched).
            if let order = p.sourceTypeOrder {
                d.set(order.joined(separator: ","), forKey: "stremiox.streaming.sourceTypeOrder")
            }
            if let addon = p.useAddonOrder {
                d.set(addon, forKey: "stremiox.streaming.useAddonOrder")
            }
        } else {
            for key in [TrackPreferences.Key.audio, TrackPreferences.Key.subtitle,
                        TrackPreferences.Key.forced, SubtitleStyle.Key.font, SubtitleStyle.Key.size,
                        SubtitleStyle.Key.color, SubtitleStyle.Key.background, SubtitleStyle.Key.sizeScale,
                        "stremiox.streaming.sourceTypeOrder", "stremiox.streaming.useAddonOrder"] {
                d.removeObject(forKey: key)
            }
        }
        // Stream scores embed the preferred audio language (the language demotion) and source-type
        // tier weights, so any flat-key change here must drop the memoized scores. NOTE: the
        // SourcePreferences singleton is re-synced (reload()) only on an actual profile SWITCH
        // (select / adoptRemoteRoster), NOT here. applyPlayback also runs from the capture path
        // (capturePlayback -> update -> applyPlayback), where SourcePreferences is already the
        // source of truth; reloading there would re-fire its @Published didSet and the
        // SettingsView .onChange(typeOrder) observer, echoing back into capturePlayback.
        StreamRanking.invalidateCaches()
        // Home is per-profile now (it hides this profile's disabled add-ons), so drop the memoized
        // board on every apply. Cheap: rebuildBoardRows recomputes the same rows and re-publishes,
        // so an unchanged set diffs to a no-op in SwiftUI.
        CoreBridge.shared.rebuildBoardRows()
    }

    /// Mirror of captureTheme for playback preferences: Settings and the in-player options write
    /// the flat keys; this folds the result back into the active profile so it survives a switch
    /// and follows the profile across devices. The equality guard stops select()'s own flat-key
    /// writes from echoing back as roster edits.
    func capturePlayback() {
        guard var profile = active else { return }
        let now = currentPlaybackPrefs()
        guard profile.playback != now else { return }
        profile.playback = now
        update(profile)
    }

    // MARK: Persistence

    /// First run after the upgrade: wrap the existing single account in a profile so nothing about
    /// the current setup changes until the user adds a second one.
    private func migrateFromSingleAccount() {
        let email = UserDefaults.standard.string(forKey: "stremiox.email")
        let name = email.flatMap { $0.split(separator: "@").first.map(String.init) }?.capitalized ?? "Main"
        let first = UserProfile(name: name, avatar: "🍿",
                                accentID: ThemeManager.shared.accentID,
                                oled: ThemeManager.shared.oled,
                                textScale: ThemeManager.shared.textScale,
                                usesOwnAccount: false, email: email, isOwner: true)
        profiles = [first]
        activeID = first.id
        persist(touch: false)   // migration isn't an edit; don't race a remote roster pull
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.listKey),
           let list = try? JSONDecoder().decode([UserProfile].self, from: data) {
            profiles = list
        }
        if let raw = UserDefaults.standard.string(forKey: Self.activeKey) {
            activeID = UUID(uuidString: raw)
        }
    }

    /// `touch` marks a real roster edit (add/update/remove): it bumps the local modification time
    /// and schedules a push, so the roster follows the account to other devices.
    /// One-time migration: rosters from before PIN hashing carry raw digits;
    /// replace them with salted hashes on first load.
    private func hashLegacyPins() {
        var changed = false
        for i in profiles.indices {
            if let raw = profiles[i].pin, !raw.isEmpty, !raw.hasPrefix("sha256:") {
                profiles[i].pin = UserProfile.pinHash(raw, profileID: profiles[i].id)
                changed = true
            }
        }
        if changed { persist(touch: false) }
    }

    private func persist(touch: Bool = true) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.listKey)
        }
        UserDefaults.standard.set(activeID?.uuidString, forKey: Self.activeKey)
        if touch {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.modifiedKey)
            schedulePushRoster()
        }
    }

    // MARK: Roster sync (the profile list follows the primary account across devices)

    /// Pull the remote roster once the account is reachable; newest side wins wholesale. AuthKeys
    /// never sync (each device signs into own-account profiles once); looks, PINs, and identity do.
    /// Runs the libraryItem repair FIRST: the old transport's documents break the official apps'
    /// library sync until scrubbed (see ProfileSync), and any watch history found in them is
    /// migrated into the local cache so nothing is lost.
    func bootstrapSync() {
        guard let key = Keychain.string(Self.primaryTokenAccount), !key.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let salvaged = await ProfileSync.prepare(authKey: key)
            if !salvaged.isEmpty { await MainActor.run { self.migrateSalvagedWatch(salvaged) } }
            guard ProfileSync.cloudAvailable == true else { return }   // per-device profiles only
            if let remote = await ProfileSync.fetchRoster(authKey: key) {
                let localModified = Date(timeIntervalSince1970:
                    UserDefaults.standard.double(forKey: Self.modifiedKey))
                if remote.mtime > localModified {
                    await MainActor.run { self.adoptRemoteRoster(remote.profiles) }
                } else if localModified > remote.mtime {
                    await ProfileSync.pushRoster(self.profiles, authKey: key)
                }
            } else if !profiles.isEmpty {
                await ProfileSync.pushRoster(profiles, authKey: key)   // first device seeds the roster
            }
            refreshWatchFromServer()
        }
    }

    /// One-time rescue of overlay history written through the old (poisonous) transport: merge it
    /// into each profile's local cache, then push it through the new transport on the next change.
    private func migrateSalvagedWatch(_ salvaged: [String: String]) {
        for profile in profiles {
            guard let payload = salvaged[ProfileSync.salvagedWatchKey(for: profile.id)],
                  let entries = ProfileSync.decodeWatchPayload(payload), !entries.isEmpty else { continue }
            var cached: [String: WatchEntry] = [:]
            if let data = UserDefaults.standard.data(forKey: Self.watchCacheKey(profile.id)),
               let existing = try? JSONDecoder().decode([String: WatchEntry].self, from: data) {
                cached = existing
            }
            for (metaId, entry) in entries where (cached[metaId]?.lastWatched ?? "") < entry.lastWatched {
                cached[metaId] = entry
            }
            if let data = try? JSONEncoder().encode(cached) {
                UserDefaults.standard.set(data, forKey: Self.watchCacheKey(profile.id))
            }
            if profile.id == activeID, !profile.usesEngineHistory { watch = cached }
        }
    }

    private func adoptRemoteRoster(_ remote: [UserProfile]) {
        profiles = remote
        normalizeOwner()
        if !profiles.contains(where: { $0.id == activeID }) { activeID = profiles.first?.id }
        if let active {
            applyTheme(active)
            applyPlayback(active)
            SourcePreferences.shared.reload()   // re-sync the singleton's @Published order on adopt
        }
        persist(touch: false)
        loadWatchCache()
    }

    /// Apply a roster that a VortX account sync just restored into UserDefaults (SettingsBackup.restore)
    /// to the LIVE store, so another device's profile changes appear WITHOUT a relaunch. This is the fix
    /// for "use account data did nothing" and the cross-device ping-pong: previously the synced defaults
    /// were written but the in-memory roster never re-read, so the device kept (and re-pushed) its own.
    /// Mirrors adoptRemoteRoster, but reads the restored defaults and KEEPS this device's active selection
    /// (selection is per-device, not synced). Never schedules a push (touch: false), so it cannot loop.
    func reloadFromDefaults() {
        guard let data = UserDefaults.standard.data(forKey: Self.listKey),
              let list = try? JSONDecoder().decode([UserProfile].self, from: data) else { return }
        let keepActive = activeID
        profiles = list
        normalizeOwner()
        if let keepActive, profiles.contains(where: { $0.id == keepActive }) {
            activeID = keepActive
        } else if !profiles.contains(where: { $0.id == activeID }) {
            activeID = profiles.first?.id
        }
        if let active {
            applyTheme(active)
            applyPlayback(active)
            SourcePreferences.shared.reload()
        }
        persist(touch: false)
        loadWatchCache()
    }

    /// The owner profile can never be an own-account profile; scrub the flag wherever a roster
    /// comes from (old build, remote sync) so no device ends up reading an empty token slot.
    private func normalizeOwner() {
        for index in profiles.indices where profiles[index].isOwner {
            profiles[index].usesOwnAccount = false
        }
    }

    // MARK: Roster merge (UNION by id, so cross-device sync never silently drops a profile)

    /// The roster-level modification time this device last recorded (a `persist(touch:true)` stamp).
    /// Used as the tiebreaker when the SAME profile id exists on both sides of a merge.
    var rosterModified: Date {
        Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: Self.modifiedKey))
    }

    /// Whether `incoming` is a genuinely different roster from the live one, compared by the SET of
    /// profile ids (the symmetric difference). Drives the explicit "Sync now" conflict prompt: if the
    /// id sets match, there is nothing to ask about and the sync can proceed silently.
    func rosterDiffers(from incoming: [UserProfile]) -> Bool {
        Set(profiles.map(\.id)) != Set(incoming.map(\.id))
    }

    /// UNION the live roster with `incoming` by profile `id`. The core safety guarantee for
    /// cross-device sync: a profile present on only ONE side is ALWAYS kept, so a cloud blob carrying
    /// fewer profiles can never delete a richer local roster (the data-loss bug), and a fewer-profile
    /// local roster can never shrink the cloud (see VortXSyncManager.syncUp).
    ///
    /// For an id present on BOTH sides we keep one deterministically: prefer the side whose roster
    /// `modifiedKey` is newer (`incomingModified` vs this device's `rosterModified`); when that cannot
    /// decide (older rosters carry no stamp, so both read 0), prefer the LOCAL copy. Either way the id
    /// is retained; only its fields are chosen.
    ///
    /// Per-profile watch overlays are NOT touched here: a unioned-back profile keeps its own
    /// `watchCacheKey(id)` cache (SettingsBackup.restore only ever SETS keys, it never deletes one),
    /// so re-adding a profile preserves its Continue Watching / library overlay.
    ///
    /// NOTE: explicit cross-device DELETE propagation (tombstones) is deferred. Until it exists,
    /// union-merge means a profile that was deliberately deleted on one device may reappear from
    /// another device that still has it. That is the intended, safe tradeoff: a profile coming BACK
    /// is recoverable; a profile silently DELETED with its history is not.
    func mergeInRoster(_ incoming: [UserProfile], incomingModified: Date? = nil) {
        guard !incoming.isEmpty else { return }
        let preferIncoming = (incomingModified ?? .distantPast) > rosterModified

        // The account's OWNER profile is a singleton: one account, one owner profile. A fresh install
        // creates a local placeholder owner ("main") with a NEW uuid, so signing into an account that
        // already has an owner would union two owner profiles and leave a duplicate, undeletable "main"
        // (the reported bug). When the incoming roster carries an owner with a DIFFERENT id than the
        // local one, drop the local placeholder so the account's owner is adopted instead of duplicated.
        // No-op on the normal path (same owner id), so it only fires on fresh-install-into-existing-account.
        var localRoster = profiles
        if let incomingOwner = incoming.first(where: { $0.isOwner }),
           let localOwner = localRoster.first(where: { $0.isOwner }),
           localOwner.id != incomingOwner.id {
            localRoster.removeAll { $0.isOwner && $0.id != incomingOwner.id }
        }

        let incomingByID = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localByID = Dictionary(localRoster.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Start from the live order, then append any ids that exist only in the incoming roster, so
        // the union keeps every profile from both sides and preserves a stable, local-first ordering.
        var merged: [UserProfile] = localRoster.map { local in
            guard let remote = incomingByID[local.id] else { return local }
            return preferIncoming ? remote : local
        }
        for remote in incoming where localByID[remote.id] == nil {
            merged.append(remote)
        }

        // No change once the ids and chosen fields already match: skip the write so this never loops
        // (reloadFromDefaults / syncDown call into here on the foreground/auto path).
        guard merged != profiles else { return }
        profiles = merged
        normalizeOwner()
        if activeID == nil || !profiles.contains(where: { $0.id == activeID }) {
            activeID = profiles.first?.id
        }
        if let active {
            applyTheme(active)
            applyPlayback(active)
            SourcePreferences.shared.reload()
        }
        persist(touch: false)   // a merge is not a local edit; never schedule a push from here
        loadWatchCache()
    }

    private func schedulePushRoster() {
        pushRosterTask?.cancel()
        guard let key = Keychain.string(Self.primaryTokenAccount), !key.isEmpty else { return }
        let snapshot = profiles
        pushRosterTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await ProfileSync.pushRoster(snapshot, authKey: key)
        }
    }

    // MARK: Watch overlay (a non-owner profile's own history, synced through the account)

    /// Continue Watching for the active overlay profile, newest first. Mirrors the account rail's
    /// rules: anything actually watched stays; a finished MOVIE leaves (a series continues with
    /// the next episode).
    var cwItems: [CoreCWItem] {
        var dated: [(lastWatched: String, item: CoreCWItem)] = []
        for (metaId, entry) in watch {
            if entry.type == "movie", entry.durationMs > 0,
               Double(entry.timeOffsetMs) >= Double(entry.durationMs) * 0.95 { continue }
            guard entry.timeOffsetMs > 0 || !entry.watchedVideoIds.isEmpty else { continue }
            let item = CoreCWItem(id: metaId, type: entry.type, name: entry.name, poster: entry.poster,
                                  state: CoreLibState(timeOffset: Double(entry.timeOffsetMs),
                                                      duration: Double(entry.durationMs),
                                                      videoId: entry.videoId))
            dated.append((entry.lastWatched, item))
        }
        return dated.sorted { $0.lastWatched > $1.lastWatched }.prefix(30).map(\.item)
    }

    /// The active overlay profile's full Library: EVERY title it has watched, newest first. Unlike
    /// cwItems it keeps finished movies and titles with no progress yet, so it reads as a "saved
    /// titles" library rather than a Continue Watching rail. Built exactly like cwItems otherwise.
    var libraryItems: [CoreCWItem] {
        var dated: [(lastWatched: String, item: CoreCWItem)] = []
        for (metaId, entry) in watch {
            let item = CoreCWItem(id: metaId, type: entry.type, name: entry.name, poster: entry.poster,
                                  state: CoreLibState(timeOffset: Double(entry.timeOffsetMs),
                                                      duration: Double(entry.durationMs),
                                                      videoId: entry.videoId))
            dated.append((entry.lastWatched, item))
        }
        return dated.sorted { $0.lastWatched > $1.lastWatched }.map(\.item)
    }

    /// Player progress for an overlay profile (the StremioAccount/CoreBridge layers route here
    /// when the active profile keeps its own history).
    func recordProgress(meta: PlaybackMeta, positionSeconds: Double, durationSeconds: Double) {
        guard durationSeconds > 0 else { return }
        var entry = watch[meta.libraryId] ?? WatchEntry(
            videoId: meta.videoId, timeOffsetMs: 0, durationMs: 0, lastWatched: "",
            name: meta.name, type: meta.type, poster: meta.poster)
        entry.videoId = meta.videoId
        entry.timeOffsetMs = Int((positionSeconds * 1000).rounded())
        entry.durationMs = Int((durationSeconds * 1000).rounded())
        entry.lastWatched = Self.isoNow()
        entry.name = meta.name
        entry.poster = meta.poster ?? entry.poster
        watch[meta.libraryId] = entry
        saveWatchCache()
        schedulePushWatch()
    }

    /// Saved resume position in seconds (0 = start fresh); series only resume the same episode.
    func resumeOffset(for meta: PlaybackMeta) -> Double {
        guard let entry = watch[meta.libraryId] else { return 0 }
        if meta.type == "series", let saved = entry.videoId, saved != meta.videoId { return 0 }
        return entry.timeOffsetMs > 0 ? Double(entry.timeOffsetMs) / 1000 : 0
    }

    /// Episode ids the active overlay profile has watched for a title; drives the
    /// detail page's per-profile ticks.
    func watchedVideoIds(forMeta metaId: String) -> Set<String> {
        Set(watch[metaId]?.watchedVideoIds ?? [])
    }

    /// Bulk watched toggle for the detail page's episode, season, and whole-series
    /// menus on overlay profiles. Engine profiles never come through here.
    func setWatched(_ isWatched: Bool, metaId: String, videoIds: [String],
                    name: String, type: String, poster: String?) {
        guard !videoIds.isEmpty else { return }
        var entry = watch[metaId] ?? WatchEntry(
            videoId: nil, timeOffsetMs: 0, durationMs: 0, lastWatched: Self.isoNow(),
            name: name, type: type, poster: poster)
        if isWatched {
            for id in videoIds where !entry.watchedVideoIds.contains(id) {
                entry.watchedVideoIds.append(id)
            }
        } else {
            entry.watchedVideoIds.removeAll { videoIds.contains($0) }
        }
        watch[metaId] = entry
        saveWatchCache()
        schedulePushWatch()
    }

    func markWatched(meta: PlaybackMeta) {
        var entry = watch[meta.libraryId] ?? WatchEntry(
            videoId: meta.videoId, timeOffsetMs: 0, durationMs: 0, lastWatched: Self.isoNow(),
            name: meta.name, type: meta.type, poster: meta.poster)
        if !entry.watchedVideoIds.contains(meta.videoId) { entry.watchedVideoIds.append(meta.videoId) }
        watch[meta.libraryId] = entry
        saveWatchCache()
        schedulePushWatch()
    }

    /// Save a title to the overlay profile's Library without marking it watched (the "Add to
    /// Library" button). Writes a zero-offset, zero-watched entry so libraryItems shows it while
    /// cwItems correctly skips it (no progress, no watched episodes) until it is actually played.
    /// A no-op when the title is already tracked, so an add never clobbers existing progress.
    func addLibraryEntry(metaId: String, name: String, type: String, poster: String?) {
        guard watch[metaId] == nil else { return }
        watch[metaId] = WatchEntry(videoId: nil, timeOffsetMs: 0, durationMs: 0,
                                   lastWatched: Self.isoNow(), name: name, type: type, poster: poster)
        saveWatchCache()
        schedulePushWatch()
    }

    /// A title finished (movie, or a series' last episode): zero the offset so it leaves the rail.
    func finishedWatching(metaId: String) {
        guard var entry = watch[metaId] else { return }
        entry.timeOffsetMs = 0
        watch[metaId] = entry
        saveWatchCache()
        schedulePushWatch()
    }

    /// The Continue Watching "dismiss" for overlay profiles: drop the whole entry. Zeroing the
    /// offset is not enough, because the rail keeps anything with watched episode ids.
    func removeWatchEntry(metaId: String) {
        guard watch.removeValue(forKey: metaId) != nil else { return }
        saveWatchCache()
        schedulePushWatch()
    }

    /// Background refresh from the account, so history follows the profile across devices.
    func refreshWatchFromServer() {
        guard let profile = active, !profile.usesEngineHistory,
              let key = Keychain.string(keychainAccount(for: profile)), !key.isEmpty else { return }
        let id = profile.id
        Task { [weak self] in
            guard let remote = await ProfileSync.fetchWatch(profileID: id, authKey: key) else { return }
            await MainActor.run {
                guard let self, self.activeID == id else { return }
                // Merge by newest lastWatched per title, so a stale device can't roll back progress.
                var merged = remote
                for (metaId, local) in self.watch where (merged[metaId]?.lastWatched ?? "") < local.lastWatched {
                    merged[metaId] = local
                }
                self.watch = merged
                self.saveWatchCache()
            }
        }
    }

    private func schedulePushWatch() {
        pushWatchTask?.cancel()
        // An overlay profile's library/CW just changed: nudge the VortX E2E sync so doc.vortx.byProfile
        // refreshes and the SyncRoom broadcast fires, so sibling devices pull within ~5s and
        // applyRemoteOverlay shows it (real-time per-profile sync). Runs regardless of the legacy
        // ProfileSync key below; requestSyncSoon no-ops when not signed into a VortX account.
        Task { @MainActor in VortXSyncManager.shared.requestSyncSoon() }
        guard let profile = active, !profile.usesEngineHistory,
              let key = Keychain.string(keychainAccount(for: profile)), !key.isEmpty else { return }
        let snapshot = watch
        let id = profile.id
        pushWatchTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await ProfileSync.pushWatch(snapshot, profileID: id, authKey: key)
        }
    }

    private func loadWatchCache() {
        guard let profile = active, !profile.usesEngineHistory else { watch = [:]; return }
        if let data = UserDefaults.standard.data(forKey: Self.watchCacheKey(profile.id)),
           let cached = try? JSONDecoder().decode([String: WatchEntry].self, from: data) {
            watch = cached
        } else {
            watch = [:]
        }
    }

    private func saveWatchCache() {
        guard let profile = active else { return }
        if let data = try? JSONEncoder().encode(watch) {
            UserDefaults.standard.set(data, forKey: Self.watchCacheKey(profile.id))
        }
    }

    /// The stored watch overlay for ANY profile, read straight from its cache, so the VortX sync can
    /// emit each profile's Continue Watching / library to the dashboard. The engine-backed owner
    /// profile returns empty here (its history lives in the account library, not an overlay cache).
    func watchEntries(for profileID: UUID) -> [String: WatchEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.watchCacheKey(profileID)),
              let cache = try? JSONDecoder().decode([String: WatchEntry].self, from: data) else { return [:] }
        return cache
    }

    /// Hydrate an OVERLAY profile's local watch overlay from a synced byProfile payload (cloud -> device,
    /// the missing sync-down leg, so a secondary profile's library + CW show in the app on every device,
    /// not just the dashboard). Merges per item last-writer-wins by lastWatched and UNIONs watchedVideoIds
    /// so neither side's progress or watched-episodes are lost. Only ever writes overlay caches; an
    /// engine-backed (owner) profile is skipped so the account library is never touched (the invariant).
    func applyRemoteOverlay(profileID: UUID, entries: [String: WatchEntry]) {
        guard !entries.isEmpty else { return }
        if let p = profiles.first(where: { $0.id == profileID }), p.usesEngineHistory { return }
        var current = watchEntries(for: profileID)
        var changed = false
        for (metaId, incoming) in entries {
            guard var existing = current[metaId] else { current[metaId] = incoming; changed = true; continue }
            let union = Array(Set(existing.watchedVideoIds).union(incoming.watchedVideoIds))
            if incoming.lastWatched > existing.lastWatched {
                var merged = incoming; merged.watchedVideoIds = union
                current[metaId] = merged; changed = true
            } else if union.count != existing.watchedVideoIds.count {
                existing.watchedVideoIds = union
                current[metaId] = existing; changed = true
            }
        }
        guard changed else { return }
        if let data = try? JSONEncoder().encode(current) {
            UserDefaults.standard.set(data, forKey: Self.watchCacheKey(profileID))
        }
        if active?.id == profileID { watch = current }   // refresh the live overlay if this is the active profile
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

// MARK: - Library import / export (portable file, per-profile-invariant-safe)

extension ProfileStore {
    /// The active profile's saved library + watch history as portable items. Honours the per-profile
    /// invariant on the READ side too: the owner profile's library lives in the engine/account, so it
    /// reads `CoreBridge.library` (folding in Continue Watching progress by id); every other profile
    /// reads its own private `watch` overlay at full fidelity. Pure read - mutates nothing.
    func exportActiveLibraryItems() -> [LibraryPortability.Item] {
        if activeUsesEngineHistory {
            // Owner: the account library is the source of truth. Merge CW progress in by id so a
            // half-watched title exports with its offset, not just "saved".
            let progress = Dictionary(
                CoreBridge.shared.continueWatching.map { ($0.id, $0.state) },
                uniquingKeysWith: { first, _ in first })
            let now = Self.isoNow()
            return (CoreBridge.shared.library?.catalog ?? [])
                .filter { $0.removed != true && $0.temp != true }
                .map { item in
                    let state = progress[item.id] ?? item.state
                    return LibraryPortability.Item(
                        metaId: item.id, type: item.type, name: item.name, poster: item.poster,
                        videoId: state.videoId, timeOffsetMs: Int(state.timeOffset),
                        durationMs: Int(state.duration), lastWatched: now, watchedVideoIds: [])
                }
        }
        // Overlay: the private watch overlay already carries everything (progress + watched episodes).
        return watch.map { metaId, entry in
            LibraryPortability.Item(
                metaId: metaId, type: entry.type, name: entry.name, poster: entry.poster,
                videoId: entry.videoId, timeOffsetMs: entry.timeOffsetMs, durationMs: entry.durationMs,
                lastWatched: entry.lastWatched, watchedVideoIds: entry.watchedVideoIds)
        }
    }

    /// Merge imported items into the ACTIVE profile, honouring the per-profile invariant on the WRITE
    /// side: the owner adds each real catalog title to the account library through the engine (which
    /// re-resolves the canonical meta - never a synthetic shape that would poison official-client
    /// sync); every other profile merges into its private overlay, last-writer-wins by `lastWatched`
    /// so an import can never roll back newer local progress, and unioning watched episodes so neither
    /// side loses ticks. Returns the number of items applied.
    @discardableResult
    @MainActor
    func importLibraryItems(_ items: [LibraryPortability.Item]) async -> (applied: Int, skipped: Int) {
        guard !items.isEmpty else { return (0, 0) }

        if activeUsesEngineHistory {
            // Only real catalog ids are engine-safe; a synthetic / add-on-specific id (kitsu:, etc.)
            // would be rejected or poison official-client sync, so it is skipped and reported, never
            // silently dropped.
            let accepted = items.filter { $0.metaId.hasPrefix("tt") || $0.metaId.hasPrefix("tmdb") }
            for item in accepted {
                await CoreBridge.shared.addCatalogItemToAccount(id: item.metaId, type: item.type)
            }
            if !accepted.isEmpty { CoreBridge.shared.loadLibrary() }
            return (accepted.count, items.count - accepted.count)
        }

        for item in items {
            let incoming = WatchEntry(
                videoId: item.videoId, timeOffsetMs: item.timeOffsetMs, durationMs: item.durationMs,
                lastWatched: item.lastWatched, name: item.name, type: item.type, poster: item.poster,
                watchedVideoIds: item.watchedVideoIds)
            watch[item.metaId] = watch[item.metaId].map { Self.mergedWatch(existing: $0, incoming: incoming) } ?? incoming
        }
        saveWatchCache()
        schedulePushWatch()
        return (items.count, 0)
    }

    /// Loss-free merge of two overlay entries for the same title. Unions watched episodes from both
    /// sides, and for the in-progress episode keeps whichever resume point is further along, so an
    /// import can never roll back local progress or drop a watched tick (and vice versa) regardless of
    /// the timestamps involved. Non-progress fields follow the more recently watched side.
    private static func mergedWatch(existing: WatchEntry, incoming: WatchEntry) -> WatchEntry {
        let incomingNewer = incoming.lastWatched >= existing.lastWatched
        var merged = incomingNewer ? incoming : existing
        let other = incomingNewer ? existing : incoming
        for vid in other.watchedVideoIds where !merged.watchedVideoIds.contains(vid) {
            merged.watchedVideoIds.append(vid)
        }
        // Same in-progress episode (or both movies, videoId == nil): never reduce the resume point.
        if existing.videoId == incoming.videoId {
            merged.timeOffsetMs = max(existing.timeOffsetMs, incoming.timeOffsetMs)
            merged.durationMs = max(existing.durationMs, incoming.durationMs)
        }
        return merged
    }
}
