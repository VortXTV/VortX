import Foundation
import StremioXCore

/// Bridges the native Rust **stremio-core** engine (StremioXCore.xcframework) to Swift.
///
/// The engine owns catalogs, library, Continue-Watching, meta and streams, the same way the official
/// app does. We dispatch JSON actions into it, read JSON state out, and it calls us back (on a Rust
/// worker thread) whenever model fields change, so the UI can re-pull exactly what changed.
final class CoreBridge: ObservableObject {
    static let shared = CoreBridge()

    /// Bumped on every `RuntimeEvent::NewState`; SwiftUI observes this to refresh. `changedFields`
    /// holds the field names that changed since the last bump (e.g. ["board", "ctx"]).
    @Published private(set) var revision = 0
    private(set) var changedFields: Set<String> = []

    /// Decoded screen state, refreshed on the main queue as the engine emits field changes.
    @Published private(set) var continueWatching: [CoreCWItem] = []
    @Published private(set) var boardRows: [CoreBoardRow] = []
    @Published private(set) var metaDetails: CoreMetaDetails?
    @Published private(set) var discover: CoreDiscover?
    @Published private(set) var library: CoreLibrary?
    @Published private(set) var searchResults: [CoreMeta] = []
    @Published private(set) var searchIsLoading = false
    @Published private(set) var searchSuggestions: [CoreSearchSuggestion] = []
    @Published private(set) var addons: [CoreDescriptor] = []

    /// Raw addon descriptors keyed by transportUrl, kept so we can round-trip a full Descriptor back
    /// to the engine for UninstallAddon (which takes the whole descriptor, not just a URL).
    private var rawAddonsByUrl: [String: [String: Any]] = [:]
    private var started = false
    /// True while we're seeding the engine from the old app's authKey and waiting for the user fetch.
    private var awaitingAuthMigration = false
    /// Set while a profile account switch is in flight: the uid we're leaving (nil = was signed out).
    private var switchInFlight = false
    private var switchFromUID: String?

    /// The Keychain slot holding the ACTIVE profile's session key (shared profiles use the primary
    /// slot, own-account profiles their own). Resolved per read so a profile switch re-points it.
    private var activeTokenAccount: String { ProfileStore.shared.activeKeychainAccount }

    private init() {}

    /// Hydrate the engine from persisted storage and start the event loop. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        let storageDir = Self.makeDir(.applicationSupportDirectory, "stremio-core")
        let cacheDir = Self.makeDir(.cachesDirectory, "stremio-core-http")
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let ok = storageDir.withCString { storage in
            cacheDir.withCString { cache in
                stremiox_core_init(storage, cache, ctx, coreEventCallback)
            }
        }
        if !ok { NSLog("[CoreBridge] stremiox_core_init failed"); return }
        bootstrapAuth()
        seedInitialState()
    }

    /// Pull state the engine populated at construction (e.g. `continue_watching_preview` from the
    /// hydrated library), it emits no `NewState`, so capture it once after init; events keep it fresh.
    private func seedInitialState() {
        let items = decode(CoreCWPreview.self, field: "continue_watching_preview")?.items ?? []
        let rows = buildBoardRows()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !items.isEmpty { self.continueWatching = items }
            if !rows.isEmpty { self.boardRows = rows }
        }
        refreshAddons()
    }

    /// Refresh the installed-addons list (and the raw descriptors for uninstall) from ctx.profile.
    private func refreshAddons() {
        let typed = decode(CoreCtx.self, field: "ctx")?.profile.addons ?? []
        var raw: [String: [String: Any]] = [:]
        if let data = stateData("ctx"),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let profile = object["profile"] as? [String: Any],
           let addons = profile["addons"] as? [[String: Any]] {
            for addon in addons { if let url = addon["transportUrl"] as? String { raw[url] = addon } }
        }
        DispatchQueue.main.async { [weak self] in
            self?.addons = typed
            self?.rawAddonsByUrl = raw
        }
    }

    /// Remove an installed addon. UninstallAddon takes a full Descriptor, so we send back the raw one
    /// the engine gave us (matched by transportUrl).
    func uninstallAddon(_ descriptor: CoreDescriptor) {
        guard let raw = rawAddonsByUrl[descriptor.transportUrl] else { return }
        dispatchCtx(["action": "UninstallAddon", "args": raw])
    }

    /// stremio-core's storage schema version, a smoke check that the FFI is wired end-to-end.
    var schemaVersion: UInt32 { stremiox_core_schema_version() }

    // MARK: Auth bootstrap / migration

    /// Get the engine into a logged-in state with library + addons populated.
    ///  - Engine already has a session (hydrated from its own storage on a later launch) → refresh.
    ///  - Else migrate the legacy authKey: fetch the real User (PullUserFromAPI builds profile.auth),
    ///    then, once the `ctx` event confirms we're logged in, pull addons + sync the library.
    private func bootstrapAuth() {
        if isLoggedIn() {
            refreshFromAPI()
            loadBoard() // addons already hydrated from the engine's own storage
            scheduleSessionRepair()
            return
        }
        guard let key = Keychain.string(activeTokenAccount), !key.isEmpty else {
            NSLog("[CoreBridge] no auth token in Keychain; engine stays signed out")
            return
        }
        awaitingAuthMigration = true
        NSLog("[CoreBridge] seeding engine from legacy authKey…")
        dispatchCtx(["action": "PullUserFromAPI", "args": ["token": key]])
    }

    /// Self-heal a stale engine session. The engine can be "logged in" with a session the API no
    /// longer honors (it happened in the wild after an account-slot bug): every sync then silently
    /// returns nothing and the library + Continue Watching sit empty forever. If no account data
    /// has arrived a while after the launch refresh, re-establish the session from the stored
    /// token, which makes the engine pull addons + the full library fresh.
    private func scheduleSessionRepair() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self else { return }
            let cwItems = self.decode(CoreCWPreview.self, field: "continue_watching_preview")?.items ?? []
            let libraryEmpty = self.library?.catalog.isEmpty ?? true
            guard self.continueWatching.isEmpty, cwItems.isEmpty, libraryEmpty,
                  let key = Keychain.string(self.activeTokenAccount), !key.isEmpty else { return }
            NSLog("[CoreBridge] session present but no account data arrived; re-authenticating with the stored token")
            self.switchAccount(token: key)
        }
    }

    /// Refresh installed addons + library from api.strem.io (needs an authenticated session).
    private func refreshFromAPI() {
        dispatchCtx(["action": "PullAddonsFromAPI"])
        dispatchCtx(["action": "SyncLibraryWithAPI"])
    }

    /// Seed the engine right after a fresh sign-in (LoginView wrote the authKey to the active
    /// profile's slot). When the engine still holds ANOTHER profile's session, this routes through
    /// the switch path instead, because bootstrapAuth would see "logged in" and keep the old session.
    func signedInWithLegacyAuthKey() {
        if isLoggedIn(), let key = Keychain.string(activeTokenAccount), !key.isEmpty {
            switchAccount(token: key)
        } else {
            bootstrapAuth()
        }
    }

    /// Switch the engine to a different Stremio session WITHOUT logging the current one out.
    /// (Engine Logout destroys its session server-side, which would permanently invalidate the
    /// profile we're leaving.) LoginWithToken installs the new session in place and the engine then
    /// pulls that account's addons + library itself; completion is detected in handleEvent when the
    /// ctx uid changes.
    func switchAccount(token: String) {
        switchInFlight = true
        switchFromUID = currentUID()
        clearUserState()
        NSLog("[CoreBridge] switching engine session (profile change)…")
        dispatchCtx(["action": "Authenticate", "args": ["type": "LoginWithToken", "token": token]])
        // A re-auth into the SAME account never changes the uid, so the uid-watch in handleEvent
        // cannot see it complete and the cleared UI would stay empty. Refresh unconditionally once
        // the round trip has had time to land; harmless when the uid-watch already did it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.switchInFlight else { return }
            self.switchInFlight = false
            self.switchFromUID = nil
            NSLog("[CoreBridge] account switch backstop → reloading")
            self.refreshFromAPI()
            self.seedInitialState()
            self.loadBoard()
        }
    }

    /// Log out of the engine (clears the persisted profile + library, and kills the session
    /// server-side) and the published UI state. For explicit sign-out, never for profile switching.
    func logOut() {
        dispatchCtx(["action": "Logout"])
        clearUserState()
    }

    /// Clear the published per-account UI state (rails, library, details).
    private func clearUserState() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.continueWatching = []
            self.boardRows = []
            self.discover = nil
            self.library = nil
            self.metaDetails = nil
        }
    }

    /// Load the Home board: every catalog of every installed addon, then fetch the first `rows`.
    /// (Targets the `board` field specifically, `search` is also a CatalogsWithExtra.)
    func loadBoard(rows: Int = 30) {
        dispatch(action: ["action": "Load",
                          "args": ["model": "CatalogsWithExtra",
                                   "args": ["type": NSNull(), "extra": []]]],
                 field: "board")
        dispatch(action: ["action": "CatalogsWithExtra",
                          "args": ["action": "LoadRange", "args": ["start": 0, "end": rows]]],
                 field: "board")
    }

    // MARK: Discover / Library

    /// Load Discover's default catalog (the engine picks the first selectable type).
    func loadDiscover() {
        dispatch(action: ["action": "Load", "args": ["model": "CatalogWithFilters", "args": NSNull()]],
                 field: "discover")
    }

    /// Switch Discover's type / catalog / genre, pass the chip's own `request` back verbatim.
    func selectDiscover(_ request: CoreRequest) {
        guard let requestDict = Self.encodeToDict(request) else { return }
        dispatch(action: ["action": "Load", "args": ["model": "CatalogWithFilters", "args": ["request": requestDict]]],
                 field: "discover")
    }

    /// Load the Library (all types, most-recent first). Auto-refreshes on library changes.
    func loadLibrary() {
        dispatch(action: ["action": "Load",
                          "args": ["model": "LibraryWithFilters",
                                   "args": ["request": ["type": NSNull(), "sort": "lastwatched", "page": 1]]]],
                 field: "library")
    }

    /// Switch the Library's type / sort, pass the chip's own `request` back verbatim.
    func selectLibrary(_ request: CoreLibraryRequest) {
        guard let requestDict = Self.encodeToDict(request) else { return }
        dispatch(action: ["action": "Load", "args": ["model": "LibraryWithFilters", "args": ["request": requestDict]]],
                 field: "library")
    }

    /// Search across the installed addons (engine `search` field = CatalogsWithExtra with a search
    /// extra). Results land in `searchResults`, flattened and de-duplicated into one grid.
    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        setSearchLoading(trimmed.count >= 2)
        guard trimmed.count >= 2 else {
            DispatchQueue.main.async { [weak self] in self?.searchResults = [] }
            return
        }
        dispatch(action: ["action": "Load",
                          "args": ["model": "CatalogsWithExtra",
                                   "args": ["type": NSNull(), "extra": [["search", trimmed]]]]],
                 field: "search")
        dispatch(action: ["action": "CatalogsWithExtra",
                          "args": ["action": "LoadRange", "args": ["start": 0, "end": 30]]],
                 field: "search")
    }

    private func setSearchLoading(_ loading: Bool) {
        if Thread.isMainThread {
            searchIsLoading = loading
        } else {
            DispatchQueue.main.async { [weak self] in self?.searchIsLoading = loading }
        }
    }

    /// Load Cinemeta's local-search index and ask it for autocomplete suggestions as the user types.
    func loadSearchSuggestions() {
        dispatch(action: ["action": "Load", "args": ["model": "LocalSearch"]], field: "local_search")
    }

    func suggestSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async { [weak self] in self?.searchSuggestions = [] }
        guard trimmed.count >= 2 else { return }
        dispatch(action: ["action": "Search",
                          "args": ["searchQuery": trimmed, "maxResults": 10]],
                 field: "local_search")
    }

    private static func encodeToDict<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return dict
    }

    // MARK: Meta details

    /// Load a title's meta + streams. For a series episode, pass the episode's video id as the stream
    /// path so the engine fetches that episode's streams.
    func loadMeta(type: String, id: String, streamType: String? = nil, streamId: String? = nil) {
        var args: [String: Any] = [
            "metaPath": ["resource": "meta", "type": type, "id": id, "extra": []],
            "guessStream": true,
        ]
        if let streamType, let streamId {
            args["streamPath"] = ["resource": "stream", "type": streamType, "id": streamId, "extra": []]
        } else {
            args["streamPath"] = NSNull()
        }
        dispatch(action: ["action": "Load", "args": ["model": "MetaDetails", "args": args]], field: "meta_details")
        // If the engine already had this exact meta loaded, ActionLoad is a no-op (eq_update) and no
        // meta_details NewState fires, so the page would stick on the spinner. Read the current state:
        // keep it when the requested meta is already ready, otherwise clear to the spinner until it loads.
        let current = decode(CoreMetaDetails.self, field: "meta_details")
        let alreadyLoaded = current?.meta?.id == id
        DispatchQueue.main.async { [weak self] in self?.metaDetails = alreadyLoaded ? current : nil }
    }

    func unloadMeta() {
        dispatch(action: ["action": "Unload"], field: "meta_details")
        DispatchQueue.main.async { [weak self] in self?.metaDetails = nil }
    }

    /// Loaded streams grouped by their source addon (for the per-addon filter + source labels).
    func streamGroups() -> [CoreStreamSourceGroup] {
        guard let details = metaDetails else { return [] }
        let names = addonNamesByBase()
        var groups: [CoreStreamSourceGroup] = []
        for group in details.streams {
            guard let streams = group.content?.ready, !streams.isEmpty else { continue }
            groups.append(CoreStreamSourceGroup(id: group.request.base,
                                                addon: names[group.request.base] ?? "Add-on",
                                                streams: streams))
        }
        return groups
    }

    /// Stream-addon load progress: `total` = add-ons queried for this title's streams, `loaded` = those
    /// that have finished (returned streams or errored). The engine creates one loadable per stream
    /// add-on up front (all `.loading`), so `total` is stable and the UI can show "Loaded X/Y add-ons"
    /// to tell users whether to keep waiting or whether loading has stalled.
    func streamLoadProgress() -> (loaded: Int, total: Int) {
        guard let details = metaDetails else { return (0, 0) }
        var loaded = 0
        for group in details.streams {
            switch group.content {
            case .some(.ready), .some(.err): loaded += 1
            default: break   // .loading or nil → not done yet
            }
        }
        return (loaded, details.streams.count)
    }

    /// Ready stream groups for a specific stream/episode id, matched on the stream request's own
    /// path id. An in-player episode switch uses this so it never grabs the previous episode's
    /// streams that are still loaded in `metaDetails` during the brief window before the new ones
    /// arrive, and so it can RANK across every add-on instead of taking whoever answered first.
    func streamGroups(forStreamId streamId: String) -> [CoreStreamSourceGroup] {
        guard let details = metaDetails else { return [] }
        let names = addonNamesByBase()
        var groups: [CoreStreamSourceGroup] = []
        for group in details.streams where group.request.path.id == streamId {
            guard let streams = group.content?.ready, !streams.isEmpty else { continue }
            groups.append(CoreStreamSourceGroup(id: group.request.base,
                                                addon: names[group.request.base] ?? "Add-on",
                                                streams: streams))
        }
        return groups
    }

    /// Stream-addon load progress for one stream/episode id (see `streamLoadProgress`).
    func streamLoadProgress(forStreamId streamId: String) -> (loaded: Int, total: Int) {
        guard let details = metaDetails else { return (0, 0) }
        var loaded = 0, total = 0
        for group in details.streams where group.request.path.id == streamId {
            total += 1
            switch group.content {
            case .some(.ready), .some(.err): loaded += 1
            default: break
            }
        }
        return (loaded, total)
    }

    private func addonNamesByBase() -> [String: String] {
        guard let ctx = decode(CoreCtx.self, field: "ctx") else { return [:] }
        var map: [String: String] = [:]
        for addon in ctx.profile.addons { map[addon.transportUrl] = addon.manifest.name }
        return map
    }

    // MARK: Mark watched / unwatched (updates the library + syncs; markers refresh live)

    /// Mark the whole title (all episodes of a series, or a movie) watched/unwatched.
    func markWatched(_ isWatched: Bool) {
        if overlayMarkWatched(isWatched, videoIds: { meta in (meta.videos ?? []).map(\.id) }) { return }
        // MarkAsWatched(false) did not clear the per-video watched state the episode
        // ticks read from, so "Mark Whole Series Unwatched" left every tick in place.
        // Clear each video explicitly (the same path single-episode unwatch uses) so
        // the ticks actually drop; watched stays the efficient aggregate action.
        if isWatched {
            dispatchMetaDetails(["action": "MarkAsWatched", "args": true])
            return
        }
        guard let videos = metaDetails?.meta?.videos, !videos.isEmpty else {
            dispatchMetaDetails(["action": "MarkAsWatched", "args": false]); return
        }
        for v in videos {
            var payload: [String: Any] = ["id": v.id]
            if let season = v.season { payload["season"] = season }
            if let episode = v.episode { payload["episode"] = episode }
            dispatchMetaDetails(["action": "MarkVideoAsWatched", "args": [payload, false]])
        }
    }

    /// Mark every episode of a season watched/unwatched.
    func markSeasonWatched(_ season: Int, _ isWatched: Bool) {
        if overlayMarkWatched(isWatched, videoIds: { meta in
            (meta.videos ?? []).filter { $0.season == season }.map(\.id)
        }) { return }
        dispatchMetaDetails(["action": "MarkSeasonAsWatched", "args": [season, isWatched]])
    }

    /// Mark a single episode watched/unwatched. The engine's `Video` only needs `id`.
    func markVideoWatched(_ video: CoreVideo, _ isWatched: Bool) {
        if overlayMarkWatched(isWatched, videoIds: { _ in [video.id] }) { return }
        var payload: [String: Any] = ["id": video.id]
        if let season = video.season { payload["season"] = season }
        if let episode = video.episode { payload["episode"] = episode }
        dispatchMetaDetails(["action": "MarkVideoAsWatched", "args": [payload, isWatched]])
    }

    /// Route a detail-page watched toggle into the overlay when the active profile keeps
    /// its own history, so a non-owner profile can never touch the account's library.
    /// Returns false for engine profiles, which then dispatch as before.
    private func overlayMarkWatched(_ isWatched: Bool, videoIds: (CoreMetaItem) -> [String]) -> Bool {
        guard !ProfileStore.shared.activeUsesEngineHistory else { return false }
        guard let meta = metaDetails?.meta else { return true }   // no detail context: drop, never mutate the account
        let ids = videoIds(meta)
        ProfileStore.shared.setWatched(isWatched, metaId: meta.id,
                                       videoIds: ids.isEmpty ? [meta.id] : ids,
                                       name: meta.name, type: meta.type, poster: meta.poster)
        return true
    }

    /// Display info for an overlay watch entry when a toggle arrives by bare id (the
    /// Library tab and poster menus). Resolved from whatever state already holds the
    /// title; nil means nothing knows it and the toggle is dropped rather than creating
    /// a nameless Continue Watching card.
    private func overlayDisplayInfo(forId id: String) -> (name: String, type: String, poster: String?)? {
        if let meta = metaDetails?.meta, meta.id == id { return (meta.name, meta.type, meta.poster) }
        if let item = continueWatching.first(where: { $0.id == id }) { return (item.name, item.type, item.poster) }
        if let item = library?.catalog.first(where: { $0.id == id }) { return (item.name, item.type, item.poster) }
        return nil
    }

    /// Id-only watched toggle into the overlay. Without an episode list the id itself is
    /// the marker (exactly how movies are tracked); unwatch clears everything recorded.
    private func overlaySetWatchedById(_ id: String, _ isWatched: Bool) {
        if isWatched {
            guard let info = overlayDisplayInfo(forId: id) else { return }
            ProfileStore.shared.setWatched(true, metaId: id, videoIds: [id],
                                           name: info.name, type: info.type, poster: info.poster)
        } else {
            let recorded = Array(ProfileStore.shared.watchedVideoIds(forMeta: id))
            guard !recorded.isEmpty else { return }
            ProfileStore.shared.setWatched(false, metaId: id, videoIds: recorded,
                                           name: "", type: "", poster: nil)
        }
    }

    /// Called by the player when a title is effectively watched (~end of playback) so the marker
    /// flips live instead of waiting for a library sync. Relies on meta_details being loaded (it is,
    /// since playback is launched from the detail screen).
    func markPlaybackWatched(_ meta: PlaybackMeta) {
        guard ProfileStore.shared.activeUsesEngineHistory else {
            ProfileStore.shared.markWatched(meta: meta)   // overlay profile: private history only
            return
        }
        if meta.type == "series" {
            var payload: [String: Any] = ["id": meta.videoId]
            if let season = meta.season { payload["season"] = season }
            if let episode = meta.episode { payload["episode"] = episode }
            dispatchMetaDetails(["action": "MarkVideoAsWatched", "args": [payload, true]])
        } else {
            dispatchMetaDetails(["action": "MarkAsWatched", "args": true])
        }
    }

    /// Resume position (seconds) from the engine's library item for `meta`, or nil if the engine has
    /// no entry (the caller then falls back to the account). For a series, only resume when the saved
    /// video matches the episode being opened. (timeOffset is stored in ms.)
    func engineResumeSeconds(for meta: PlaybackMeta) -> Double? {
        guard let item = metaDetails?.libraryItem else { return nil }
        if meta.type == "series", let videoId = item.state.videoId, videoId != meta.videoId { return 0 }
        return max(0, item.state.timeOffset / 1000.0)
    }

    // MARK: Library / Continue Watching mutations (Ctx actions; CW + library refresh live via events)

    /// Remove a title from the library entirely (the engine sets `removed = true`). Used by both the
    /// Continue Watching "dismiss" (Stremio auto-adds to the library on play, so dismissing is a library
    /// removal, matching the reference apps) and the Library tab's "Remove from Library". The engine
    /// re-emits `continue_watching_preview` + `library`, so both rails update on their own.
    func removeFromLibrary(id: String) {
        dispatchCtx(["action": "RemoveFromLibrary", "args": id])
    }

    /// Mark a library item watched / unwatched by id. `LibraryItemMarkAsWatched` acts on the existing
    /// library entry (no `MetaItemPreview` needed), so it fits the Library tab, where items are library
    /// entries rather than full catalog previews. A no-op if the id isn't in the library.
    func setLibraryItemWatched(id: String, _ isWatched: Bool) {
        guard ProfileStore.shared.activeUsesEngineHistory else {
            overlaySetWatchedById(id, isWatched)   // overlay profile: private history only
            return
        }
        dispatchCtx(["action": "LibraryItemMarkAsWatched", "args": ["id": id, "is_watched": isWatched]])
    }

    /// Drop a finished title (a movie, or the last episode of a series) out of Continue Watching by
    /// rewinding its saved position to zero. `is_in_continue_watching()` is just `time_offset > 0`, so a
    /// title finished at its end position would otherwise linger forever. Rewind keeps the library entry
    /// (still marked watched) and its new-episode notifications, unlike a full removal.
    func finishedWatching(libraryId: String) {
        guard ProfileStore.shared.activeUsesEngineHistory else {
            ProfileStore.shared.finishedWatching(metaId: libraryId)   // overlay profile
            return
        }
        dispatchCtx(["action": "RewindLibraryItem", "args": libraryId])
    }

    /// Whether the open detail page's title is saved to the library proper (present,
    /// not removed, not a temporary watched-marker entry). Drives the Library button.
    var detailInLibrary: Bool {
        guard let item = metaDetails?.libraryItem else { return false }
        return item.removed != true && item.temp != true
    }

    /// Add the OPEN detail page's title to the library. Catalog adds round-trip a
    /// `MetaItemPreview` found in a catalog, but a detail page reached from the
    /// Library tab or Continue Watching is in no catalog, so this hands the engine
    /// its own full meta JSON instead (a superset of the preview it expects).
    func addDetailToLibrary() {
        guard let data = stateData("meta_details"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metaItems = object["metaItems"] as? [[String: Any]] else { return }
        for entry in metaItems {
            if let content = entry["content"] as? [String: Any],
               let ready = content["ready"] as? [String: Any] {
                dispatchCtx(["action": "AddToLibrary", "args": ready])
                return
            }
        }
    }

    /// Add a catalog item to the library. Round-trips the engine's own `MetaItemPreview` JSON (found by id
    /// in whichever catalog field holds it) so the shape is exactly what the engine expects back.
    func addToLibrary(metaId: String) {
        guard let raw = rawMetaPreview(forId: metaId) else { return }
        dispatchCtx(["action": "AddToLibrary", "args": raw])
    }

    /// Mark a catalog item watched / unwatched without opening its detail page first. `MetaItemMarkAsWatched`
    /// creates a temporary library item if one doesn't exist, which is exactly this discover use case.
    func setCatalogWatched(metaId: String, _ isWatched: Bool) {
        guard ProfileStore.shared.activeUsesEngineHistory else {
            overlaySetWatchedById(metaId, isWatched)   // overlay profile: private history only
            return
        }
        guard let raw = rawMetaPreview(forId: metaId) else { return }
        dispatchCtx(["action": "MetaItemMarkAsWatched", "args": ["meta_item": raw, "is_watched": isWatched]])
    }

    /// The raw `MetaItemPreview` JSON for a catalog item id, pulled verbatim from whichever catalog field
    /// currently holds it (board / discover / search). `MetaItemPreview` deserializes through a legacy
    /// shape, so we hand the engine back its own serialization rather than reconstruct it.
    private func rawMetaPreview(forId metaId: String) -> [String: Any]? {
        for field in ["board", "discover", "search"] {
            guard let data = stateData(field),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let found = Self.findMetaPreview(in: object, id: metaId) { return found }
        }
        return nil
    }

    /// Depth-first search for a meta preview (`{id, type, name, …}`) with the given id inside an engine
    /// state object: catalog state nests previews under `content` arrays a few levels down.
    private static func findMetaPreview(in node: Any, id: String) -> [String: Any]? {
        if let dict = node as? [String: Any] {
            if dict["id"] as? String == id, dict["type"] is String, dict["name"] is String { return dict }
            for value in dict.values { if let found = findMetaPreview(in: value, id: id) { return found } }
        } else if let array = node as? [Any] {
            for value in array { if let found = findMetaPreview(in: value, id: id) { return found } }
        }
        return nil
    }

    // MARK: - Live playback progress (engine Player)

    /// Load the engine Player for the picked stream, so it records progress against the right library
    /// item. Built from the raw meta_details JSON (the engine wants back the exact Stream + the stream
    /// and meta requests it gave us). Best-effort: a shape mismatch is a silent no-op, never a crash.
    func loadEnginePlayer(for stream: CoreStream) {
        guard let data = stateData("meta_details"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let metaItems = object["metaItems"] as? [[String: Any]] ?? []
        let metaRequest = (metaItems.first { ($0["content"] as? [String: Any])?["type"] as? String == "Ready" }
                           ?? metaItems.first)?["request"]
        var rawStream: [String: Any]?
        var streamRequest: Any?
        for group in (object["streams"] as? [[String: Any]] ?? []) {
            guard let content = group["content"] as? [String: Any],
                  content["type"] as? String == "Ready",
                  let streams = content["content"] as? [[String: Any]] else { continue }
            if let match = streams.first(where: { streamMatches($0, stream) }) {
                rawStream = match; streamRequest = group["request"]; break
            }
        }
        guard let rawStream, let streamRequest, let metaRequest else { return }
        let selected: [String: Any] = [
            "stream": rawStream,
            "streamRequest": streamRequest,
            "metaRequest": metaRequest,
            "subtitlesPath": NSNull(),
        ]
        dispatch(action: ["action": "Load", "args": ["model": "Player", "args": selected]], field: "player")
    }

    private func streamMatches(_ raw: [String: Any], _ stream: CoreStream) -> Bool {
        if let url = stream.url { return raw["url"] as? String == url }
        if let hash = stream.infoHash { return raw["infoHash"] as? String == hash }
        if let yt = stream.ytId { return raw["ytId"] as? String == yt }
        return false
    }

    /// Report the playback position to the engine Player (in ms), so Continue Watching reflects it live.
    func reportProgress(timeSeconds: Double, durationSeconds: Double) {
        // Overlay profiles never feed the engine Player: it would write their progress into the
        // ACCOUNT library bucket and sync it, which is exactly what profile separation prevents.
        guard ProfileStore.shared.activeUsesEngineHistory else { return }
        guard durationSeconds > 0, timeSeconds >= 0 else { return }
        #if os(tvOS)
        let device = "tvOS"
        #else
        let device = "iOS"
        #endif
        let payload: [String: Any] = ["time": Int(timeSeconds * 1000),
                                      "duration": Int(durationSeconds * 1000),
                                      "device": device]
        dispatch(action: ["action": "Player", "args": ["action": "TimeChanged", "args": payload]],
                 field: "player")
    }

    private func dispatchMetaDetails(_ action: [String: Any]) {
        dispatch(action: ["action": "MetaDetails", "args": action], field: "meta_details")
    }

    /// Is `ctx.profile.auth` present? (auth serializes as an object when signed in, null otherwise.)
    func isLoggedIn() -> Bool {
        guard let data = stateData("ctx"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = object["profile"] as? [String: Any] else { return false }
        return profile["auth"] is [String: Any]
    }

    /// The signed-in account's uid (`ctx.profile.auth.user._id`), nil when signed out. Used to
    /// detect when an account switch has actually landed.
    private func currentUID() -> String? {
        guard let data = stateData("ctx"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = object["profile"] as? [String: Any],
              let auth = profile["auth"] as? [String: Any],
              let user = auth["user"] as? [String: Any] else { return nil }
        return (user["_id"] as? String) ?? (user["email"] as? String)
    }

    /// Dispatch an `Action::Ctx(...)` to the whole model (field = nil).
    private func dispatchCtx(_ ctxAction: [String: Any]) {
        dispatch(action: ["action": "Ctx", "args": ctxAction])
    }

    // MARK: Dispatch

    /// Dispatch an action. `field` targets one model field (nil broadcasts to the whole model).
    /// `action` is the engine's `Action` JSON, e.g.
    /// `["action": "Load", "args": ["model": "CatalogsWithExtra", "args": ["type": NSNull(), "extra": []]]]`.
    func dispatch(action: [String: Any], field: String? = nil) {
        let payload: [String: Any] = ["field": field ?? NSNull(), "action": action]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        json.withCString { stremiox_core_dispatch($0) }
    }

    // MARK: State

    /// Raw JSON bytes for a model field (e.g. "board", "continue_watching_preview"). Heavy fields
    /// (library, catalogs) serialize on the calling thread, prefer a background queue for those.
    func stateData(_ field: String) -> Data? {
        let quoted = "\"\(field)\"" // get_state expects a JSON field name
        guard let ptr = quoted.withCString({ stremiox_core_get_state($0) }) else { return nil }
        defer { stremiox_core_string_free(ptr) }
        return Data(bytes: ptr, count: strlen(ptr))
    }

    /// Decode a model field into a Codable type.
    func decode<T: Decodable>(_ type: T.Type, field: String) -> T? {
        guard let data = stateData(field) else { return nil }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            NSLog("[CoreBridge] decode \(field) failed: \(error)")
            return nil
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    // MARK: Event callback (invoked from a Rust worker thread)

    fileprivate func handleEvent(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String else { return }
        guard name == "NewState", let fields = object["args"] as? [String] else {
            return // "CoreEvent" (auth results, errors, …) handled in a later step.
        }

        // Legacy authKey finished seeding (ctx now logged in) → pull addons + library + board, once.
        if awaitingAuthMigration, fields.contains("ctx"), isLoggedIn() {
            awaitingAuthMigration = false
            NSLog("[CoreBridge] authKey migrated → pulling addons + syncing library")
            refreshFromAPI()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.loadBoard() }
        }

        // A profile's account switch landed (the ctx uid moved off the old session) → reload all
        // per-account state. Authenticate already pulls addons + library; the explicit refresh and
        // board load repopulate our published screens.
        if switchInFlight, fields.contains("ctx"), isLoggedIn(), currentUID() != switchFromUID {
            switchInFlight = false
            switchFromUID = nil
            NSLog("[CoreBridge] account switch complete → reloading")
            refreshFromAPI()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.loadBoard() }
        }

        // Decode the changed screens off the main thread, then publish on main.
        if fields.contains("continue_watching_preview") {
            let items = decode(CoreCWPreview.self, field: "continue_watching_preview")?.items ?? []
            DispatchQueue.main.async { [weak self] in self?.continueWatching = items }
        }
        // The board needs ctx (addon manifests) for row titles, so rebuild on either change.
        if fields.contains("board") || fields.contains("ctx") {
            let rows = buildBoardRows()
            DispatchQueue.main.async { [weak self] in self?.boardRows = rows }
        }
        if fields.contains("ctx") { refreshAddons() }
        if fields.contains("meta_details") {
            let details = decode(CoreMetaDetails.self, field: "meta_details")
            DispatchQueue.main.async { [weak self] in self?.metaDetails = details }
        }
        if fields.contains("discover") {
            let value = decode(CoreDiscover.self, field: "discover")
            DispatchQueue.main.async { [weak self] in self?.discover = value }
            // A null first load derives the default catalog before the selectable is refreshed from
            // addons, so it can land with catalogs available but nothing selected (Discover stuck on
            // the spinner). If so, load the first catalog to unstick it.
            if let value, value.items.isEmpty,
               !value.selectable.types.contains(where: { $0.selected }),
               let first = value.selectable.types.first {
                selectDiscover(first.request)
            }
        }
        if fields.contains("library") {
            let value = decode(CoreLibrary.self, field: "library")
            DispatchQueue.main.async { [weak self] in self?.library = value }
        }
        if fields.contains("search") {
            let board = decode(CoreBoardState.self, field: "search")
            let pages = board?.catalogs.flatMap { $0 } ?? []
            let hasLoadingPages = pages.isEmpty || pages.contains { page in
                guard let content = page.content else { return true }
                return content.isLoading
            }
            let items = pages.compactMap { $0.content?.ready }.flatMap { $0 }
            var seen = Set<String>(); var unique: [CoreMeta] = []
            for item in items where seen.insert(item.id).inserted { unique.append(item) }
            DispatchQueue.main.async { [weak self] in
                self?.searchIsLoading = hasLoadingPages
                if !hasLoadingPages || !unique.isEmpty {
                    self?.searchResults = unique
                }
            }
        }
        if fields.contains("local_search") {
            let value = decode(CoreLocalSearchState.self, field: "local_search")
            DispatchQueue.main.async { [weak self] in self?.searchSuggestions = value?.searchResults ?? [] }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.changedFields = Set(fields)
            self.revision &+= 1
        }
    }

    // MARK: Board assembly

    /// Build titled board rows: merge each catalog's ready pages into one item list and resolve a
    /// human title from the installed-addon manifests. Rows with no loaded items are skipped, so they
    /// appear as their content arrives (no empty placeholders).
    private func buildBoardRows() -> [CoreBoardRow] {
        guard let board = decode(CoreBoardState.self, field: "board") else { return [] }
        let titles = catalogTitleMap()
        var rows: [CoreBoardRow] = []
        for catalog in board.catalogs {
            guard let request = catalog.first?.request else { continue }
            let items = catalog.compactMap { $0.content?.ready }.flatMap { $0 }
            guard !items.isEmpty else { continue }
            let key = Self.catalogKey(base: request.base, type: request.path.type, id: request.path.id)
            rows.append(CoreBoardRow(id: key, title: titles[key] ?? request.path.id, items: items))
        }
        return rows
    }

    /// `{base|type|id → "Catalog name"}` from the installed addons' manifests. The addon's own catalog
    /// name is already descriptive (e.g. "Debridio TMDB - Trending Movies"), so we don't prefix the
    /// addon name.
    private func catalogTitleMap() -> [String: String] {
        guard let ctx = decode(CoreCtx.self, field: "ctx") else { return [:] }
        var map: [String: String] = [:]
        for addon in ctx.profile.addons {
            for catalog in addon.manifest.catalogs {
                let key = Self.catalogKey(base: addon.transportUrl, type: catalog.type, id: catalog.id)
                map[key] = Self.displayCatalogTitle(name: catalog.name ?? catalog.id, type: catalog.type)
            }
        }
        return map
    }

    /// Distinguish same-named movie/series catalogs, addons routinely name both "Trending", which renders
    /// as two identical "Trending" rows. Append the content type unless the name already says it (so an
    /// already-descriptive "… Trending Movies" isn't doubled).
    private static func displayCatalogTitle(name: String, type: String) -> String {
        let lower = name.lowercased()
        let t = type.lowercased()
        let label: String
        switch t {
        case "movie":   label = "Movies"
        case "series":  label = "Shows"
        case "channel": label = "Channels"
        case "tv":      label = "TV"
        default:        return name
        }
        if lower.contains(t) || lower.contains(label.lowercased()) { return name }
        return "\(name) \(label)"
    }

    private static func catalogKey(base: String, type: String, id: String) -> String {
        "\(base)|\(type)|\(id)"
    }

    private static func makeDir(_ directory: FileManager.SearchPathDirectory, _ name: String) -> String {
        let base = FileManager.default.urls(for: directory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path
    }
}

/// Top-level C callback (no captures allowed). Recovers the `CoreBridge` from the opaque `ctx`.
private func coreEventCallback(ctx: UnsafeMutableRawPointer?, data: UnsafePointer<UInt8>?, len: Int) {
    guard let ctx, let data, len > 0 else { return }
    let bytes = Data(bytes: data, count: len) // copy synchronously, `data` is only valid during this call
    Unmanaged<CoreBridge>.fromOpaque(ctx).takeUnretainedValue().handleEvent(bytes)
}
