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

    private var started = false
    /// True while we're seeding the engine from the old app's authKey and waiting for the user fetch.
    private var awaitingAuthMigration = false

    /// Where the legacy hand-rolled client (StremioAccount) stores the Stremio session key.
    private static let legacyAuthKeyDefaultsKey = "stremiox.authKey"

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
            return
        }
        guard let key = UserDefaults.standard.string(forKey: Self.legacyAuthKeyDefaultsKey),
              !key.isEmpty else {
            NSLog("[CoreBridge] no legacy authKey; engine stays signed out")
            return
        }
        awaitingAuthMigration = true
        NSLog("[CoreBridge] seeding engine from legacy authKey…")
        dispatchCtx(["action": "PullUserFromAPI", "args": ["token": key]])
    }

    /// Refresh installed addons + library from api.strem.io (needs an authenticated session).
    private func refreshFromAPI() {
        dispatchCtx(["action": "PullAddonsFromAPI"])
        dispatchCtx(["action": "SyncLibraryWithAPI"])
    }

    /// Seed the engine right after a fresh sign-in (the legacy LoginView wrote the authKey), so a
    /// brand-new user doesn't have to relaunch for the engine to pick up their session. Idempotent.
    func signedInWithLegacyAuthKey() { bootstrapAuth() }

    /// Log out of the engine (clears the persisted profile + library) and the published UI state.
    func logOut() {
        dispatchCtx(["action": "Logout"])
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
        DispatchQueue.main.async { [weak self] in self?.searchResults = [] }
        guard trimmed.count >= 2 else { return }
        dispatch(action: ["action": "Load",
                          "args": ["model": "CatalogsWithExtra",
                                   "args": ["type": NSNull(), "extra": [["search", trimmed]]]]],
                 field: "search")
        dispatch(action: ["action": "CatalogsWithExtra",
                          "args": ["action": "LoadRange", "args": ["start": 0, "end": 30]]],
                 field: "search")
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
        DispatchQueue.main.async { [weak self] in self?.metaDetails = nil } // avoid showing the previous title
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

    private func addonNamesByBase() -> [String: String] {
        guard let ctx = decode(CoreCtx.self, field: "ctx") else { return [:] }
        var map: [String: String] = [:]
        for addon in ctx.profile.addons { map[addon.transportUrl] = addon.manifest.name }
        return map
    }

    // MARK: Mark watched / unwatched (updates the library + syncs; markers refresh live)

    /// Mark the whole title (all episodes of a series, or a movie) watched/unwatched.
    func markWatched(_ isWatched: Bool) {
        dispatchMetaDetails(["action": "MarkAsWatched", "args": isWatched])
    }

    /// Mark every episode of a season watched/unwatched.
    func markSeasonWatched(_ season: Int, _ isWatched: Bool) {
        dispatchMetaDetails(["action": "MarkSeasonAsWatched", "args": [season, isWatched]])
    }

    /// Mark a single episode watched/unwatched. The engine's `Video` only needs `id`.
    func markVideoWatched(_ video: CoreVideo, _ isWatched: Bool) {
        var payload: [String: Any] = ["id": video.id]
        if let season = video.season { payload["season"] = season }
        if let episode = video.episode { payload["episode"] = episode }
        dispatchMetaDetails(["action": "MarkVideoAsWatched", "args": [payload, isWatched]])
    }

    /// Called by the player when a title is effectively watched (~end of playback) so the marker
    /// flips live instead of waiting for a library sync. Relies on meta_details being loaded (it is,
    /// since playback is launched from the detail screen).
    func markPlaybackWatched(_ meta: PlaybackMeta) {
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
        if fields.contains("meta_details") {
            let details = decode(CoreMetaDetails.self, field: "meta_details")
            DispatchQueue.main.async { [weak self] in self?.metaDetails = details }
        }
        if fields.contains("discover") {
            let value = decode(CoreDiscover.self, field: "discover")
            DispatchQueue.main.async { [weak self] in self?.discover = value }
        }
        if fields.contains("library") {
            let value = decode(CoreLibrary.self, field: "library")
            DispatchQueue.main.async { [weak self] in self?.library = value }
        }
        if fields.contains("search") {
            let board = decode(CoreBoardState.self, field: "search")
            let items = board?.catalogs.flatMap { page in page.compactMap { $0.content?.ready }.flatMap { $0 } } ?? []
            var seen = Set<String>(); var unique: [CoreMeta] = []
            for item in items where seen.insert(item.id).inserted { unique.append(item) }
            DispatchQueue.main.async { [weak self] in self?.searchResults = unique }
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
                map[key] = catalog.name ?? catalog.id
            }
        }
        return map
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
