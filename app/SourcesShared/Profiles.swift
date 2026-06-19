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
    /// Per-profile playback preferences (audio/subtitle language plus subtitle style), mirrored
    /// into the flat UserDefaults keys the player reads when this profile becomes active.
    /// nil = never customized (pre-feature roster); seeded from the flat values on first load.
    var playback: PlaybackPrefs? = nil

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
        playback = try c.decodeIfPresent(PlaybackPrefs.self, forKey: .playback)
    }

    init(id: UUID = UUID(), name: String, avatar: String, accentID: String = "ember",
         oled: Bool = false, textScale: Double = 1.0, pin: String? = nil, usesOwnAccount: Bool = false,
         email: String? = nil, isOwner: Bool = false, playback: PlaybackPrefs? = nil) {
        self.id = id; self.name = name; self.avatar = avatar; self.accentID = accentID
        self.oled = oled; self.textScale = textScale; self.pin = pin; self.usesOwnAccount = usesOwnAccount
        self.email = email; self.isOwner = isOwner; self.playback = playback
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
        // The active profile owns the theme; resync in case the stored values drifted.
        if let active { applyTheme(active) }
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
        let incomingByID = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localByID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Start from the live order, then append any ids that exist only in the incoming roster, so
        // the union keeps every profile from both sides and preserves a stable, local-first ordering.
        var merged: [UserProfile] = profiles.map { local in
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

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
