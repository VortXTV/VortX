import Foundation
import os

// MARK: - Stremio account: login + addon collection + library (HTTP api.strem.io)

/// A resource entry in an addon manifest, can be a bare string ("stream") or an object
/// ({ name: "stream", types: [...] }). Decoded flexibly.
struct AddonResource: Decodable {
    let name: String
    let types: [String]?
    let idPrefixes: [String]?
    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            name = s; types = nil; idPrefixes = nil; return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        types = try? c.decode([String].self, forKey: .types)
        idPrefixes = try? c.decode([String].self, forKey: .idPrefixes)
    }
    enum CodingKeys: String, CodingKey { case name, types, idPrefixes }
}

/// A catalog (board row) declared in a manifest. `extra`/`extraRequired` flag catalogs that
/// need a parameter (search, genre), those can't load as a plain board row.
struct AddonCatalog: Decodable, Hashable {
    let type: String
    let id: String
    let name: String?
    let extra: [CatalogExtra]?
    let extraRequired: [String]?
    // `options` carries the selectable values for a parameter, e.g. the genre list for filtering.
    struct CatalogExtra: Decodable, Hashable { let name: String; let isRequired: Bool?; let options: [String]? }

    /// Genres this catalog can be filtered by (from its optional `genre` extra), or [] if none.
    var genreOptions: [String] { extra?.first { $0.name == "genre" }?.options ?? [] }

    /// Names of all REQUIRED extras (from either `extraRequired` or `extra[].isRequired`).
    private var requiredExtras: [String] {
        (extraRequired ?? []) + (extra?.filter { $0.isRequired == true }.map { $0.name } ?? [])
    }

    /// Home-row eligible: needs no required parameter at all.
    var isBoardEligible: Bool { requiredExtras.isEmpty }

    /// Discover-eligible: needs no required parameter OTHER than `genre` (Discover supplies that via
    /// the genre chips). Search-only catalogs are excluded, they belong in Search. This is what was
    /// wrongly dropping ~95% of catalogs from Discover.
    var isDiscoverEligible: Bool { requiredExtras.allSatisfy { $0 == "genre" } }

    /// True when a genre MUST be supplied to load this catalog (Discover defaults to the first one).
    var requiresGenre: Bool { requiredExtras.contains("genre") }
}

struct AddonManifest: Decodable {
    let id: String
    let name: String
    let resources: [AddonResource]
    let types: [String]?
    let catalogs: [AddonCatalog]?
    let idPrefixes: [String]?
}

struct AddonDescriptor: Decodable {
    let transportUrl: String
    let manifest: AddonManifest
    /// Base URL for resource requests (manifest URL minus the trailing /manifest.json).
    var baseUrl: String { transportUrl.replacingOccurrences(of: "/manifest.json", with: "") }
    var providesStreams: Bool { manifest.resources.contains { $0.name == "stream" } }
    var providesMeta: Bool { manifest.resources.contains { $0.name == "meta" } }
    /// id-prefixes this addon handles for meta lookups (resource-level first, else manifest-level).
    var metaIdPrefixes: [String] {
        (manifest.resources.first { $0.name == "meta" }?.idPrefixes) ?? manifest.idPrefixes ?? []
    }
}

/// A library entry from the account datastore, used by the player's resume lookup.
struct LibraryItem: Identifiable, Decodable, Hashable {
    let id: String
    let name: String?
    let type: String?
    let poster: String?
    let removed: Bool?
    let state: State?
    struct State: Decodable, Hashable {
        let timeOffset: Double?
        let duration: Double?
        let lastWatched: String?     // ISO timestamp, used to order Continue Watching, newest first
    }
    enum CodingKeys: String, CodingKey { case id = "_id", name, type, poster, removed, state }

    var isRemoved: Bool { removed == true }
    /// 0…1 watched fraction, for the continue-watching progress bar (0 if duration unknown).
    var progress: Double {
        guard let t = state?.timeOffset, let d = state?.duration, d > 0 else { return 0 }
        return min(1, max(0, t / d))
    }
    /// In the Continue Watching shelf? Matches Stremio: keep anything you've actually watched, and
    /// for a SERIES keep it even when the current episode is finished, the *next* episode is what
    /// you continue (the old "must be mid-progress" test dropped these, leaving only the 1-2 titles
    /// you were literally paused inside). Only a finished MOVIE is excluded.
    var inProgress: Bool {
        guard !isRemoved else { return false }
        let watched = (state?.timeOffset ?? 0) > 0 || !lastWatched.isEmpty
        guard watched else { return false }
        if type == "movie", let t = state?.timeOffset, let d = state?.duration, d > 0, t >= d * 0.95 {
            return false                                            // a finished movie isn't "continue"
        }
        return true
    }
    var lastWatched: String { state?.lastWatched ?? "" }
}

/// The context the tvOS player needs to record watch progress against the right library item.
/// (`libraryId` is the movie/series id = the libraryItem `_id`; `videoId` is the movie id, or
/// `imdbId:season:episode` for an episode.)
struct PlaybackMeta: Hashable {
    let libraryId: String
    let videoId: String
    let type: String
    let name: String
    let poster: String?
    let season: Int?
    let episode: Int?

    var usesSeriesLifecycle: Bool {
        EpisodePlaybackIdentity.usesSeriesLifecycle(type: type)
    }
}

/// Immutable ownership captured when a player session is mounted. Long-lived callbacks must use this
/// rather than asking which profile happens to be selected when the callback finally fires.
typealias PlaybackMutationTarget = PlaybackMutationOwnershipPolicy.Target

extension PlaybackMutationTarget {

    static func capture(core: CoreBridge) -> PlaybackMutationTarget {
#if VORTX_NATIVE_DATA_ENGINE
        return core.captureNativePlaybackTarget()
#else
        let profiles = ProfileStore.shared
        if profiles.activeUsesEngineHistory {
            // History is an owner-account carrier, never a generic native-engine carrier. A
            // secondary profile may use its own Stremio account, but its callbacks must not
            // manufacture rows in the fixed owner bucket.
            let ownerHistoryCapture: CredentialScopeRegistry.Capture? =
                profiles.activeID == UserProfile.ownerID && profiles.active?.isOwner == true
                ? CredentialScopeRegistry.shared.capture()
                : nil
            return .engine(profileID: profiles.activeID,
                           keychainAccount: profiles.activeKeychainAccount,
                           uid: core.currentUID(), historyCapture: ownerHistoryCapture)
        }
        guard let profileID = profiles.activeID else {
            // A missing active id means no profile can own a local write. The engine route is
            // deliberately fail-closed below when the active context no longer matches.
            return .engine(profileID: nil, keychainAccount: profiles.activeKeychainAccount,
                           uid: core.currentUID(), historyCapture: nil)
        }
        return .overlay(profileID: profileID)
#endif
    }

    func stillOwnsCurrentContext(core: CoreBridge) -> Bool {
#if VORTX_NATIVE_DATA_ENGINE
        return core.nativePlaybackTargetIsCurrent(self)
#else
        let profiles = ProfileStore.shared
        let context = PlaybackMutationOwnershipPolicy.Context(
            activeProfileID: profiles.activeID,
            activeUsesEngineHistory: profiles.activeUsesEngineHistory,
            activeKeychainAccount: profiles.activeKeychainAccount,
            activeUID: core.currentUID(),
            extantOverlayProfileIDs: Set(profiles.profiles.filter { !$0.usesEngineHistory }.map(\.id))
        )
        return PlaybackMutationOwnershipPolicy.allows(self, in: context)
#endif
    }

    func stillOwnsAccountContext(core: CoreBridge) -> Bool {
#if VORTX_NATIVE_DATA_ENGINE
        return stillOwnsCurrentContext(core: core)
#else
        let profiles = ProfileStore.shared
        let context = PlaybackMutationOwnershipPolicy.Context(
            activeProfileID: profiles.activeID,
            activeUsesEngineHistory: profiles.activeUsesEngineHistory,
            activeKeychainAccount: profiles.activeKeychainAccount,
            activeUID: core.currentUID(),
            extantOverlayProfileIDs: Set(profiles.profiles.filter { !$0.usesEngineHistory }.map(\.id))
        )
        return PlaybackMutationOwnershipPolicy.allowsAccountMutation(self, in: context)
#endif
    }

    /// A player progress event may enter the owner-history carrier only if its immutable launch
    /// epoch is still current and both the captured and current profiles are the canonical owner.
    /// `usesEngineHistory` alone is deliberately insufficient: secondary profiles can have their
    /// own native account but must never write the owner's membership-neutral history.
    func stillOwnsOwnerHistoryContext(core: CoreBridge) -> Bool {
#if VORTX_NATIVE_DATA_ENGINE
        return false // nativeSync is the account carrier; never duplicate native writes into legacy caches
#else
        guard case let .engine(profileID, _, _, historyCapture?) = self,
              profileID == UserProfile.ownerID,
              ProfileStore.shared.activeID == UserProfile.ownerID,
              ProfileStore.shared.active?.isOwner == true,
              CredentialScopeRegistry.shared.isCurrent(historyCapture),
              stillOwnsCurrentContext(core: core) else { return false }
        return true
#endif
    }

    var ownerHistoryCapture: CredentialScopeRegistry.Capture? {
        guard case let .engine(_, _, _, historyCapture) = self else { return nil }
        return historyCapture
    }

    var overlayProfileID: UUID? {
        if case .overlay(let id) = self { return id }
        return nil
    }
}

/// Manages the signed-in Stremio session: auth token (persisted), installed addons, and the
/// chosen stream addon. The token + addon URLs (which carry debrid keys) stay on-device only.
@MainActor
final class StremioAccount: ObservableObject {
    /// Posted after a successful credential replacement. The notification carries only a process-local
    /// monotonic generation, prior sign-in state, and the non-secret profile/keychain owner identity; it
    /// never carries the auth key, email, or any other credential material. CoreBridge uses the true-to-true
    /// case to rotate its settled binding because SwiftUI's `isSignedIn` publisher intentionally suppresses
    /// true -> true.
    nonisolated static let credentialBoundaryDidChange = Notification.Name("StremioAccount.credentialBoundaryDidChange")

    @Published var isSignedIn = false
    @Published var email: String?                       // shown on the Settings/Account screen
    @Published var streamSources: [StreamSource] = []   // stream addons (base + name), for tagging/filtering
    @Published var addons: [AddonDescriptor] = []       // for the Addons screen
    @Published var signInError: String?
    /// Non-secret account-boundary revision for same-slot replacements. This is deliberately separate from
    /// `isSignedIn`, whose true -> true assignment is suppressed to avoid re-entrant login observers.
    @Published private(set) var credentialBoundaryGeneration: UInt64 = 0

    /// Convenience: just the stream-addon base URLs (count shown in Settings, etc.).
    var streamAddonBases: [String] { streamSources.map(\.base) }

    private let api = "https://api.strem.io/api"
    /// The active profile's Keychain slot (shared profiles use the primary slot), so a profile
    /// switch re-points every token read and write at once.
    private var tokenKey: String { ProfileStore.shared.activeKeychainAccount }
    private let emailKey = "stremiox.email"
    private let log = Logger(subsystem: "com.stremiox.app", category: "account")
    /// An auth operation captures the active profile before its first await. ProfileStore increments
    /// this local generation on every reload/sign-out/new sign-in, so a late response cannot write into
    /// whichever profile happens to be selected when it resumes.
    private struct AuthOperationContext: Equatable {
        let profileID: UUID?
        let keychainAccount: String
        let generation: UInt64
    }
    private var authOperationGeneration: UInt64 = 0

    private var authKey: String? {
        get { Keychain.string(tokenKey) }
        set { Self.storeAuthKey(newValue, account: tokenKey) }
    }
    private static func storeAuthKey(_ value: String?, account: String) {
#if VORTX_NATIVE_DATA_ENGINE
        VortxNativeOwnAccountProducer.withCredentialMutation(slot: account) { _ = Keychain.set(value, for: account) }
#else
        Keychain.set(value, for: account)
#endif
    }

    private func captureAuthOperationContext() -> AuthOperationContext {
        AuthOperationContext(
            profileID: ProfileStore.shared.active?.id,
            keychainAccount: ProfileStore.shared.activeKeychainAccount,
            generation: authOperationGeneration)
    }

    private func beginAuthOperation() -> AuthOperationContext {
#if VORTX_NATIVE_DATA_ENGINE
        VortxNativeOwnAccountProducer.invalidate(slot: tokenKey)
#endif
        authOperationGeneration &+= 1
        return captureAuthOperationContext()
    }

    private func authOperationStillCurrent(_ context: AuthOperationContext) -> Bool {
        authOperationGeneration == context.generation
            && ProfileStore.shared.active?.id == context.profileID
            && ProfileStore.shared.activeKeychainAccount == context.keychainAccount
    }

    init() {
        email = Self.displayEmail()
        migrateTokenToKeychain()
        let context = captureAuthOperationContext()
        if Keychain.string(context.keychainAccount) != nil {
            isSignedIn = true
            Task { [weak self] in await self?.loadAddons(for: context) }
        }
    }

    /// Re-read the session for the newly active profile (called after a profile switch).
    func reloadForActiveProfile() {
#if VORTX_NATIVE_DATA_ENGINE
        VortxNativeOwnAccountProducer.invalidateContext()
#endif
        authOperationGeneration &+= 1
        signInError = nil
        streamSources = []
        addons = []
        email = Self.displayEmail()
        // Only publish when the value actually changes. `@Published` re-fires its publisher on every
        // assignment (even true→true), so an unconditional write here can re-enter any
        // `.onReceive($isSignedIn)` sink that calls back into this method, the loop that froze the
        // iOS sign-in. Assigning only on change keeps this method safe for any observer.
        let context = captureAuthOperationContext()
        let signedIn = Keychain.string(context.keychainAccount) != nil
        if isSignedIn != signedIn { isSignedIn = signedIn }
        if signedIn { Task { [weak self] in await self?.loadAddons(for: context) } }
    }

    /// Own-account profiles carry their email; shared profiles show the primary account's.
    private static func displayEmail() -> String? {
        if let profile = ProfileStore.shared.active, profile.usesOwnAccount { return profile.email }
        return UserDefaults.standard.string(forKey: "stremiox.email")
    }

    /// Move a token saved by an older build (UserDefaults) into the Keychain, once.
    private func migrateTokenToKeychain() {
        guard authKey == nil,
              let legacy = UserDefaults.standard.string(forKey: tokenKey), !legacy.isEmpty else { return }
        Self.storeAuthKey(legacy, account: tokenKey)
        UserDefaults.standard.removeObject(forKey: tokenKey)
    }

    func signIn(email rawEmail: String, password: String) async {
        signInError = nil
        // tvOS text fields tend to auto-capitalize / add stray whitespace; normalize the email so
        // it matches the registered account. The password is sent exactly as typed.
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        struct Req: Encodable { let email: String; let password: String; let facebook = false }
        struct Res: Decodable {
            struct R: Decodable { let authKey: String; let user: U? }
            struct U: Decodable { let email: String? }
            let result: R?; let error: ErrObj?
        }
        struct ErrObj: Decodable { let message: String? }
        guard !email.isEmpty, !password.isEmpty else { signInError = "Enter your email and password."; return }
        let context = beginAuthOperation()
        do {
            let res: Res = try await post("login", body: Req(email: email, password: password))
            guard authOperationStillCurrent(context) else { return }
            guard let key = res.result?.authKey else {
                let msg = res.error?.message ?? "Sign-in failed"
                signInError = msg
                log.error("signIn failed: \(msg, privacy: .public)")
                return
            }
            let wasSignedIn = isSignedIn
            // The active profile/keychain slot was captured before the await. Never resolve the
            // destination dynamically from the profile selected after the response returned.
            // Never use a dynamically selected credential destination after this await: the selected
            // profile may have changed. Write only to the slot captured before the request started.
            Self.storeAuthKey(key, account: context.keychainAccount)
            guard authOperationStillCurrent(context) else { return }
            publishCredentialBoundary(wasSignedIn: wasSignedIn)
            // Publish the credential boundary before the email publisher so CoreBridge can rotate its
            // settled binding before Home performs its account-bound recommendation refresh.
            setEmail(res.result?.user?.email ?? email, for: context)
            if !isSignedIn { isSignedIn = true }   // guard the @Published write so true->true can't re-fire observers
            log.info("signed in ok")
            await loadAddons(for: context)
        } catch {
            guard authOperationStillCurrent(context) else { return }
            signInError = "Couldn't reach Stremio. Check your connection."
            log.error("signIn network error: \(error.localizedDescription, privacy: .public)")
        }
    }

    func signInWithAuthKey(_ token: String) async {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { signInError = "Sign-in failed."; return }
        signInError = nil
        let context = beginAuthOperation()
        let wasSignedIn = isSignedIn
        Self.storeAuthKey(token, account: context.keychainAccount)
        guard authOperationStillCurrent(context) else { return }
        publishCredentialBoundary(wasSignedIn: wasSignedIn)
        await backfillEmail(for: context)
        guard authOperationStillCurrent(context) else { return }
        if !isSignedIn { isSignedIn = true }   // guard the @Published write so true->true can't re-fire observers
        log.info("signed in with link ok")
        await loadAddons(for: context)
    }

    func signOut() {
#if VORTX_NATIVE_DATA_ENGINE
        VortxNativeOwnAccountProducer.invalidate(slot: tokenKey)
#endif
        authOperationGeneration &+= 1
        authKey = nil; isSignedIn = false; streamSources = []; addons = []
        setEmail(nil)
    }

    private func setEmail(_ value: String?, for context: AuthOperationContext? = nil) {
        if let context, !authOperationStillCurrent(context) { return }
        email = value
        let store = ProfileStore.shared
        if var profile = store.active, profile.usesOwnAccount {
            if let context,
               (profile.id != context.profileID || store.activeKeychainAccount != context.keychainAccount) {
                return
            }
            profile.email = value          // the bound account belongs to this profile only
            store.update(profile)
        } else {
            UserDefaults.standard.setValue(value, forKey: emailKey)
        }
    }

    private func publishCredentialBoundary(wasSignedIn: Bool) {
        // Dispatch the CoreBridge rebind notification before publishing the SwiftUI-visible revision.
        // Home may refresh from either surface, so this ordering guarantees the rebind has at least
        // started before any owner-key change can reach the recommendation model.
        let generation = credentialBoundaryGeneration &+ 1
        NotificationCenter.default.post(
            name: Self.credentialBoundaryDidChange,
            object: nil,
            userInfo: [
                "generation": generation,
                "wasSignedIn": wasSignedIn,
                "profileID": ProfileStore.shared.active?.id.uuidString ?? "",
                "keychainAccount": ProfileStore.shared.activeKeychainAccount
            ]
        )
        credentialBoundaryGeneration = generation
    }

    func loadAddons() async {
        await loadAddons(for: captureAuthOperationContext())
    }

    private func loadAddons(for context: AuthOperationContext) async {
        guard authOperationStillCurrent(context),
              let key = Keychain.string(context.keychainAccount), !key.isEmpty else { return }
        struct Req: Encodable { let authKey: String; let update = true }
        struct Res: Decodable { struct R: Decodable { let addons: [AddonDescriptor] }; let result: R? }
        do {
            let res: Res = try await post("addonCollectionGet", body: Req(authKey: key))
            guard authOperationStillCurrent(context) else { return }
            let addons = res.result?.addons ?? []
            self.addons = addons
            // Keep the user's addon order (addonCollectionGet = their Stremio order) so the sources
            // and catalogs they prioritised come first. (A broken `.sorted` was scrambling it.)
            streamSources = addons.filter { $0.providesStreams }
                .map { StreamSource(base: $0.baseUrl, name: $0.manifest.name) }
            log.info("loaded \(self.addons.count) addons, \(self.streamSources.count) stream addons")
            if email == nil { await backfillEmail(for: context) }   // older sessions saved no email
        } catch {
            guard authOperationStillCurrent(context) else { return }
            // keep whatever we had, but surface why the refresh failed
            log.error("loadAddons failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Backfill the account email (for sessions that predate email capture).
    private func backfillEmail(for context: AuthOperationContext) async {
        guard authOperationStillCurrent(context),
              let key = Keychain.string(context.keychainAccount), !key.isEmpty else { return }
        struct Req: Encodable { let authKey: String }
        struct Res: Decodable { struct U: Decodable { let email: String? }; let result: U? }
        if let res: Res = try? await post("getUser", body: Req(authKey: key)),
           authOperationStillCurrent(context), let e = res.result?.email {
            setEmail(e, for: context)
        }
    }

    // MARK: - Watch progress (tvOS writes the playback position back to the account library)

    /// Saved resume position in **seconds** for `meta` (0 = start fresh). For series, only resumes
    /// when the stored progress is for the same episode the user is opening. Overlay profiles
    /// (a non-owner shared profile) resume from their own private history instead.
    func resumeOffset(for meta: PlaybackMeta) async -> Double {
#if VORTX_NATIVE_DATA_ENGINE
        if CoreBridge.shared.usesNativeProfileState {
            let target = PlaybackMutationTarget.capture(core: CoreBridge.shared)
            return await CoreBridge.shared.nativeResumeSeconds(for: meta, target: target)
        }
#endif
        if !ProfileStore.shared.activeUsesEngineHistory {
            return ProfileStore.shared.resumeOffset(for: meta)
        }
        // Wave 4: VortX owns the MAIN profile's resume. Read the engine's LOCAL library bucket BY ID (mirrored
        // from doc.vortx.library, re-hydrated on cold devices) instead of the Stremio account datastore. Callers
        // already try `core.engineResumeSeconds(for:)` first and only fall through to here when meta_details is
        // not yet loaded (the Continue-Watching direct-resume race); this by-id read still finds the position, so
        // gating the Stremio read off cannot lose resume. Only consult api.strem.io when the user opted into the
        // two-way mirror (default OFF).
        if let engine = CoreBridge.shared.engineResumeSecondsByLibraryId(for: meta) { return engine }
        guard ProfileSync.alsoSyncToStremio else { return 0 }
        guard let key = authKey,
              let item = await rawLibraryItem(id: meta.libraryId, authKey: key),
              let state = item["state"] as? [String: Any] else { return 0 }
        if EpisodePlaybackIdentity.savedResumeTargetsDifferentEpisode(
            usesSeriesLifecycle: meta.usesSeriesLifecycle,
            savedVideoID: state["video_id"] as? String,
            requestedVideoID: meta.videoId
        ) { return 0 }
        let ms = Self.numeric(state["timeOffset"])
        return ms > 0 ? ms / 1000 : 0
    }

    /// Upsert the library item with the current playback position so Continue Watching reflects what
    /// was watched on Apple TV. Fetches the existing item and mutates only the progress fields so no
    /// other client's data is clobbered; creates a minimal item only if it's new to the library.
    /// Overlay profiles write to their own private synced history and never touch the account library.
    func saveProgress(for meta: PlaybackMeta, positionSeconds: Double, durationSeconds: Double,
                      target: PlaybackMutationTarget? = nil) async {
        let target = target ?? PlaybackMutationTarget.capture(core: CoreBridge.shared)
        guard target.stillOwnsCurrentContext(core: CoreBridge.shared) else { return }
#if VORTX_NATIVE_DATA_ENGINE
        if CoreBridge.shared.usesNativeProfileState {
            CoreBridge.shared.reportNativeProgress(for: meta, positionSeconds: positionSeconds, durationSeconds: durationSeconds, target: target)
            return
        }
#endif
        if let profileID = target.overlayProfileID {
            ProfileStore.shared.recordProgress(meta: meta, positionSeconds: positionSeconds,
                                               durationSeconds: durationSeconds, profileID: profileID)
            return
        }
        // This is the only shared Apple callback that still carries the committed playback identity
        // after the player has passed its first-frame/integrity gates.  Capture before the optional
        // Stremio mirror gate: VortX-only accounts must retain genuine watch history too.  The captured
        // target/capture fence prevents a delayed callback from writing under a newly-selected account.
        if let credentialCapture = target.ownerHistoryCapture,
           target.stillOwnsOwnerHistoryContext(core: CoreBridge.shared),
           durationSeconds > 0, positionSeconds >= 0 {
            _ = await MainActor.run {
                guard CredentialScopeRegistry.shared.isCurrent(credentialCapture),
                      target.stillOwnsOwnerHistoryContext(core: CoreBridge.shared) else { return false }
                return OwnerHistoryStore.recordPlayback(
                    titleID: meta.libraryId, type: meta.type, name: meta.name, poster: meta.poster,
                    videoID: meta.videoId, positionSeconds: positionSeconds, durationSeconds: durationSeconds,
                    capture: credentialCapture)
            }
        }
        // Wave 4: VortX owns the MAIN profile's Continue Watching + resume. The position is already persisted to
        // the engine's LOCAL library bucket by the co-located `CoreBridge.reportProgress` at every player call
        // site (the engine Player's TimeChanged), and that bucket is mirrored to doc.vortx.library and re-hydrated
        // on cold devices, so Continue Watching + resume survive with NO Stremio dependency. Do NOT write to the
        // Stremio account datastore by default; only ALSO write it when the user opted into two-way sync (OFF).
        guard ProfileSync.alsoSyncToStremio else { return }
        guard let key = authKey, durationSeconds > 0, positionSeconds >= 0 else { return }
        let now = Self.isoNow()
        var item = await rawLibraryItem(id: meta.libraryId, authKey: key) ?? Self.newLibraryItem(meta, now: now)
        var state = (item["state"] as? [String: Any]) ?? [:]
        state["timeOffset"] = Int((positionSeconds * 1000).rounded())
        state["duration"] = Int((durationSeconds * 1000).rounded())
        state["lastWatched"] = now
        state["video_id"] = meta.videoId
        item["state"] = state
        item["_mtime"] = now
        item["removed"] = false
        if item["name"] == nil { item["name"] = meta.name }
        if item["type"] == nil { item["type"] = meta.type }
        guard target.stillOwnsCurrentContext(core: CoreBridge.shared) else { return }
        await datastorePut(authKey: key, change: item)
    }

    /// Fetch a single library item as raw JSON so all its fields survive a progress update.
    private func rawLibraryItem(id: String, authKey: String) async -> [String: Any]? {
        let body: [String: Any] = ["authKey": authKey, "collection": "libraryItem", "ids": [id], "all": false]
        guard let data = try? await postRaw("datastoreGet", body: body),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["result"] as? [[String: Any]] else { return nil }
        return arr.first
    }

    private func datastorePut(authKey: String, change: [String: Any]) async {
        let body: [String: Any] = ["authKey": authKey, "collection": "libraryItem", "changes": [change]]
        do {
            _ = try await postRaw("datastorePut", body: body)
        } catch {
            // Progress saves are best-effort, but don't drop the failure silently: log it and retry once.
            log.error("datastorePut failed: \(error.localizedDescription, privacy: .public); retrying once")
            do {
                _ = try await postRaw("datastorePut", body: body)
            } catch {
                log.error("datastorePut retry failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Like `post`, but with an untyped JSON body/response, for library items whose full shape we
    /// deliberately don't model (we preserve unknown fields rather than round-trip through Codable).
    private func postRaw(_ path: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: "\(api)/\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    private static func numeric(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    /// A minimal but valid libraryItem for content not yet in the library (field names match the
    /// shape `library()` already decodes successfully).
    private static func newLibraryItem(_ meta: PlaybackMeta, now: String) -> [String: Any] {
        var item: [String: Any] = [
            "_id": meta.libraryId,
            "name": meta.name,
            "type": meta.type,
            "posterShape": "poster",
            "removed": false,
            "temp": false,
            "_ctime": now,
            "_mtime": now,
            "state": [
                "lastWatched": now, "timeWatched": 0, "timeOffset": 0, "overallTimeWatched": 0,
                "timesWatched": 0, "flaggedWatched": 0, "duration": 0, "video_id": meta.videoId,
                "watched": "", "noNotif": false,
            ],
            "behaviorHints": ["defaultVideoId": NSNull()],
        ]
        if let poster = meta.poster { item["poster"] = poster }
        return item
    }

    private func post<B: Encodable, R: Decodable>(_ path: String, body: B) async throws -> R {
        guard let url = URL(string: "\(api)/\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(R.self, from: data)
    }
}
