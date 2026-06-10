import Foundation

/// One viewer of the app: local view settings (name, avatar, theme, parental PIN) plus an optional
/// binding to its own Stremio account. Profiles without their own account share the primary one,
/// so a "Kids" profile can be the same account with a different look and a PIN on the way out.
struct UserProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var avatar: String                 // an emoji
    var accentID: String = "ember"
    var oled: Bool = false
    var pin: String? = nil             // 4-digit parental gate, nil = open
    var usesOwnAccount: Bool = false   // true = its own Stremio session in its own Keychain slot
    var email: String? = nil           // bound account email, display only

    var hasPin: Bool { !(pin ?? "").isEmpty }
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

    private static let listKey = "stremiox.profiles"
    private static let activeKey = "stremiox.profiles.active"
    /// The pre-profiles single-account Keychain slot; shared profiles keep using it.
    static let primaryTokenAccount = "stremiox.authKey"

    private init() {
        load()
        if profiles.isEmpty { migrateFromSingleAccount() }
        if activeID == nil || !profiles.contains(where: { $0.id == activeID }) {
            activeID = profiles.first?.id
        }
        // The active profile owns the theme; resync in case the stored values drifted.
        if let active {
            ThemeManager.shared.accentID = active.accentID
            ThemeManager.shared.oled = active.oled
        }
    }

    var active: UserProfile? { profiles.first { $0.id == activeID } }
    var needsPicker: Bool { profiles.count > 1 && !pickedThisLaunch }

    /// The Keychain slot the rest of the app reads the session from right now. StremioAccount and
    /// CoreBridge resolve their token through this, so a profile switch re-points both at once.
    var activeKeychainAccount: String {
        active.map(keychainAccount(for:)) ?? Self.primaryTokenAccount
    }

    func keychainAccount(for profile: UserProfile) -> String {
        profile.usesOwnAccount ? Self.primaryTokenAccount + "." + profile.id.uuidString
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
        persist()
        ThemeManager.shared.accentID = profile.accentID
        ThemeManager.shared.oled = profile.oled
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
            ThemeManager.shared.accentID = profile.accentID
            ThemeManager.shared.oled = profile.oled
        }
    }

    /// Remove a profile (never the last one). Its private session key is deleted with it. Returns
    /// the switch outcome when the removed profile was the active one, nil otherwise.
    @discardableResult
    func remove(_ profile: UserProfile) -> SwitchOutcome? {
        guard profiles.count > 1, profiles.contains(where: { $0.id == profile.id }) else { return nil }
        profiles.removeAll { $0.id == profile.id }
        if profile.usesOwnAccount { Keychain.set(nil, for: keychainAccount(for: profile)) }
        persist()
        if activeID == profile.id, let first = profiles.first { return select(first) }
        return nil
    }

    /// The Settings appearance controls write to ThemeManager; mirror the result into the active
    /// profile so it survives a switch and a relaunch.
    func captureTheme() {
        guard var profile = active else { return }
        guard profile.accentID != ThemeManager.shared.accentID || profile.oled != ThemeManager.shared.oled else { return }
        profile.accentID = ThemeManager.shared.accentID
        profile.oled = ThemeManager.shared.oled
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
                                usesOwnAccount: false, email: email)
        profiles = [first]
        activeID = first.id
        persist()
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

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.listKey)
        }
        UserDefaults.standard.set(activeID?.uuidString, forKey: Self.activeKey)
    }
}
