import Foundation

// Synthetic dependencies for compiling the full ACTUAL TraktSyncEngine source. These never call
// Keychain, URLSession, UserDefaults, Application Support, OAuth, or real provider/account APIs.
// Actual TraktModels and actual TraktSessionID/AuthBoundary declarations are compiled separately.
final class WatchedEngineEnvironment: @unchecked Sendable {
    static let shared = WatchedEngineEnvironment()
    private let lock = NSLock()
    private var session: TraktSessionID?
    private var loaded: Data?
    private var saved: [Data] = []
    private var fixture: WatchedPageFixture?
    private var tokenGate: WatchedPageFixture?
    private var status = 200
    private var failWrites = false
    private var importEnabled = true
    private var credentialReads = 0
    private var providerCalls: [String] = []
    func configure(
        session: TraktSessionID, loaded: Data, fixture: WatchedPageFixture,
        tokenGate: WatchedPageFixture? = nil, status: Int = 200, failWrites: Bool = false,
        importEnabled: Bool = true
    ) {
        lock.lock(); defer { lock.unlock() }
        self.session = session; self.loaded = loaded; self.fixture = fixture
        self.tokenGate = tokenGate; self.status = status; saved = []
        self.failWrites = failWrites
        self.importEnabled = importEnabled; credentialReads = 0; providerCalls = []
    }
    func current() -> TraktSessionID? {
        lock.lock(); defer { lock.unlock() }; credentialReads += 1; return session
    }
    func reads() -> Int { lock.lock(); defer { lock.unlock() }; return credentialReads }
    func imports() -> Bool { lock.lock(); defer { lock.unlock() }; return importEnabled }
    func record(_ value: String) { lock.lock(); providerCalls.append(value); lock.unlock() }
    func calls() -> [String] { lock.lock(); defer { lock.unlock() }; return providerCalls }
    func changeSession(_ value: TraktSessionID) { lock.lock(); session = value; lock.unlock() }
    func data() -> Data? { lock.lock(); defer { lock.unlock() }; return loaded }
    func saves() -> [Data] { lock.lock(); defer { lock.unlock() }; return saved }
    func save(_ value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw WatchedTestFailure.transport }
        saved.append(value); loaded = value
    }
    func reset() { lock.lock(); loaded = nil; lock.unlock() }
    func network() -> (WatchedPageFixture?, Int) {
        lock.lock(); defer { lock.unlock() }; return (fixture, status)
    }
    func gate() -> WatchedPageFixture? { lock.lock(); defer { lock.unlock() }; return tokenGate }
}

actor TraktAuth {
    static let shared = TraktAuth()
    static let apiBase = "https://api.trakt.tv"
    static let clientID = "fixture-public-client"
    static let isConfigured = true
    nonisolated static var storedSessionID: TraktSessionID? { WatchedEngineEnvironment.shared.current() }
    func validToken(for expectedSession: TraktSessionID) async throws -> String {
        if let gate = WatchedEngineEnvironment.shared.gate() { _ = try await gate.request("token") }
        return "fixture-not-a-live-token"
    }
}

enum AuthenticatedHTTPTransportError: Error { case invalidResponse }
struct AuthenticatedHTTPResponse: Sendable { let data: Data; let statusCode: Int }
struct AuthenticatedHTTPTransport: Sendable {
    static let shared = AuthenticatedHTTPTransport()
    static let snapshotResponseLimit = 8 * 1024 * 1024
    func send(_ request: URLRequest, allowedHosts: Set<String>, maxResponseBytes: Int) async throws
        -> AuthenticatedHTTPResponse {
        try watchedExpect(allowedHosts == ["api.trakt.tv"], "engine host allowlist changed")
        try watchedExpect(maxResponseBytes == 8 * 1024 * 1024, "engine byte cap changed")
        try watchedExpect(request.url?.scheme == "https" && request.url?.host == "api.trakt.tv",
                          "engine destination changed")
        try watchedExpect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-not-a-live-token",
                          "engine must use captured session token")
        let (fixture, status) = WatchedEngineEnvironment.shared.network()
        guard let fixture, let url = request.url else { throw WatchedTestFailure.transport }
        let data = try await fixture.request(url.path + (url.query.map { "?" + $0 } ?? ""))
        return AuthenticatedHTTPResponse(data: data, statusCode: status)
    }
}

struct PrivateExternalSyncStorage: Sendable {
    static func live(provider: String, file: String, legacyFiles: [String]) throws -> Self { Self() }
    func load() throws -> Data? { WatchedEngineEnvironment.shared.data() }
    func save(_ data: Data) throws { try WatchedEngineEnvironment.shared.save(data) }
    func reset() throws { WatchedEngineEnvironment.shared.reset() }
}
enum ExternalSyncToggle {
    static let traktImportWatched = "import"; static let traktRatings = "ratings"
    static func isOn(_ key: String, default defaultValue: Bool = true) -> Bool {
        key == traktImportWatched && WatchedEngineEnvironment.shared.imports()
    }
}
struct WatchedIndex: Sendable {
    static let shared = WatchedIndex()
    func externalShadowChanged() {}
}
enum DiagnosticsLog { static func log(_ category: String, _ message: String) {} }
enum TraktCollectionType: Sendable { case movies, shows }
enum TraktScrobbleItem: Sendable {
    case movie(TraktMovie)
    case episodeInShow(show: TraktShow, episode: TraktEpisode)
}
struct TraktService: Sendable {
    static let shared = TraktService()
    func ratings(type: TraktCollectionType, expectedSession: TraktSessionID) async throws -> [TraktRatingEntry] {
        WatchedEngineEnvironment.shared.record("ratings-read"); return []
    }
    func addToWatchlist(_ items: TraktSyncItems, expectedSession: TraktSessionID) async throws -> Int {
        WatchedEngineEnvironment.shared.record(items.shows == nil ? "watchlist-add-movie" : "watchlist-add-show"); return 0
    }
    func removeFromWatchlist(_ items: TraktSyncItems, expectedSession: TraktSessionID) async throws -> Int {
        WatchedEngineEnvironment.shared.record(items.shows == nil ? "watchlist-remove-movie" : "watchlist-remove-show"); return 0
    }
    func scrobbleStop(item: TraktScrobbleItem, progress: Double, expectedSession: TraktSessionID) async throws -> Int {
        switch item {
        case .movie: WatchedEngineEnvironment.shared.record("watched-movie")
        case .episodeInShow(_, let episode):
            WatchedEngineEnvironment.shared.record("watched-episode-\(episode.season ?? -1)-\(episode.number ?? -1)")
        }
        return 0
    }
    func addRatings(_ items: TraktRatingItems, expectedSession: TraktSessionID) async throws -> Int {
        WatchedEngineEnvironment.shared.record("rating-set"); return 0
    }
    func removeRatings(_ items: TraktRatingItems, expectedSession: TraktSessionID) async throws -> Int {
        WatchedEngineEnvironment.shared.record("rating-remove"); return 0
    }
}
struct TraktRatingsStore: Sendable {
    static let shared = TraktRatingsStore()
    static let changedNote = Notification.Name("fixture-ratings")
    var currentContext: (generation: Int, sessionID: TraktSessionID?) { (0, TraktAuth.storedSessionID) }
    func merge(entries: [TraktRatingEntry], isSeries: Bool, gen: Int, sessionID: TraktSessionID) -> Bool { false }
    func markPushed(imdb: String?, tmdb: Int?, isSeries: Bool, rating: Int?, ratedAtEpoch: Double?, sessionID: TraktSessionID) {}
}

enum WatchedEngineCases {
    static let session = TraktSessionID(rawValue: "fixture-session-A")
    static let otherSession = TraktSessionID(rawValue: "fixture-session-B")
    struct Envelope: Decodable {
        let sessionID: TraktSessionID
        let watchedIDs: Set<String>
        let watchedEpisodeKeys: Set<String>
        let pendingPushes: [TraktSyncEngine.PendingPush]
        let lastActivityFingerprint: String?
        let watchedReadVersion: Int?
        let watchedShowInventory: [TraktWatchedShowInventoryEntry]?
        let watchedInventoryRevision: UUID?
    }
    static func legacyData() throws -> Data {
        let push = TraktSyncEngine.PendingPush(kind: .ratingSet, isSeries: false,
            imdb: "tt900", tmdb: nil, season: nil, episode: nil,
            sessionID: session, rating: 7, ratedAtEpoch: 123)
        let rawPush = try JSONSerialization.jsonObject(with: JSONEncoder().encode(push))
        let rawSession = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session), options: [.fragmentsAllowed])
        return try JSONSerialization.data(withJSONObject: [
            "sessionID": rawSession, "watchedIDs": ["tt-old"],
            "watchedEpisodeKeys": ["tt-old|1|2"], "pendingPushes": [rawPush],
            "lastActivityFingerprint": WatchedReaderCases.fingerprint,
            "futureEnvelopeField": ["keptByOlderCodecPolicy": true]
        ])
    }
    static func seed(
        _ fixture: WatchedPageFixture, data: Data? = nil,
        tokenGate: WatchedPageFixture? = nil, status: Int = 200, failWrites: Bool = false
    ) throws -> TraktSyncEngine {
        WatchedEngineEnvironment.shared.configure(session: session,
            loaded: try data ?? legacyData(), fixture: fixture, tokenGate: tokenGate, status: status, failWrites: failWrites)
        return TraktSyncEngine.fixtureNew()
    }
    static func requireOld(_ engine: TraktSyncEngine, _ label: String) throws {
        let state = engine.fixtureState()
        try watchedExpect(state.0 == ["tt-old"] && state.1 == ["tt-old|1|2"], label + ": old sets")
        try watchedExpect(state.2 == WatchedReaderCases.fingerprint && state.3 == nil, label + ": old cursor/version")
        try watchedExpect(state.4.count == 1 && state.4[0].rating == 7 &&
                          state.4[0].ratedAtEpoch == 123 && state.4[0].sessionID == session,
                          label + ": pending push preserved")
        try watchedExpect(WatchedEngineEnvironment.shared.saves().isEmpty, label + ": no partial persistence")
    }
    static func run() async throws {
        let good = WatchedPageFixture(WatchedReaderCases.fullSteps())
        let engine = try seed(good)
        try requireOld(engine, "legacy decode before first corrected pull")
        try watchedExpect(engine.currentWatchedShowInventory(expectedSession: session) == nil,
                          "legacy badge cache is not a proven complete show inventory")
        await engine.fixturePull(session)
        let saves = WatchedEngineEnvironment.shared.saves()
        try watchedExpect(saves.count == 1, "one complete envelope save, never an early cursor-only save")
        let saved = try JSONDecoder().decode(Envelope.self, from: saves[0])
        try watchedExpect(saved.watchedIDs.count == 12 && saved.watchedEpisodeKeys.count == 6,
                          "the only persisted envelope contains all title and episode pages")
        try watchedExpect(saved.lastActivityFingerprint == WatchedReaderCases.fingerprint &&
                          saved.watchedReadVersion == TraktWatchedSnapshotReader.readVersion,
                          "corrected cursor/version saved with its own sets")
        try watchedExpect(saved.pendingPushes.count == 1 && saved.pendingPushes[0].rating == 7,
                          "migration never wipes pending pushes")
        let memory = engine.fixtureState()
        try watchedExpect(memory.0 == saved.watchedIDs && memory.1 == saved.watchedEpisodeKeys,
                          "persisted and published sets are the same transaction")
        let inventory = engine.currentWatchedShowInventory(expectedSession: session)
        try watchedExpect(inventory?.entries.map(\.traktID) == [3, 4] &&
                          inventory?.revision == saved.watchedInventoryRevision &&
                          inventory?.sessionID == session && inventory?.activityFingerprint == saved.lastActivityFingerprint,
                          "same transaction exposes complete account-bound inventory with a persisted revision")
        try watchedExpect(engine.currentWatchedShowInventory(expectedSession: otherSession) == nil,
                          "inventory getter cannot cross an account boundary")
        let rootMembers = try VortxNativeBootstrapArchive.rawJSONObjectMembers(saves[0], maximumBytes: saves[0].count)
        try watchedExpect(rootMembers.contains(where: { $0.key == "futureEnvelopeField" }),
                          "forced migration retains unknown envelope members at the same path")

        // Reload the actual new codec and prove it skips only after the completed corrected read.
        let skipFixture = WatchedPageFixture([WatchedReaderCases.step("/sync/last_activities", WatchedReaderCases.activity)])
        let reloaded = try seed(skipFixture, data: saves[0])
        await reloaded.fixturePull(session)
        let skippedCalls = await skipFixture.paths()
        try watchedExpect(skippedCalls.count == 1 && WatchedEngineEnvironment.shared.saves().isEmpty,
                          "current corrected cursor skips without rewriting the envelope")
        try watchedExpect(reloaded.currentWatchedShowInventory(expectedSession: session)?.revision == inventory?.revision,
                          "skip preserves transaction identity")

        // An unchanged set still needs a cursor/version persistence write on migration.
        var oldSame = try JSONSerialization.jsonObject(with: saves[0]) as! [String: Any]
        oldSame.removeValue(forKey: "watchedReadVersion")
        let unchangedFixture = WatchedPageFixture(WatchedReaderCases.fullSteps())
        let unchanged = try seed(unchangedFixture, data: JSONSerialization.data(withJSONObject: oldSame))
        await unchanged.fixturePull(session)
        try watchedExpect(WatchedEngineEnvironment.shared.saves().count == 1,
                          "same sets still persist the proven read version")
        try watchedExpect(unchanged.currentWatchedShowInventory(expectedSession: session)?.revision != inventory?.revision,
                          "successful replacement invalidates consumers of an earlier inventory revision")

        // A failed second leg or terminal page never persists a newer cursor ahead of the old sets.
        for index in 1..<WatchedReaderCases.fullSteps().count {
            var steps = WatchedReaderCases.fullSteps()
            steps[index].fails = true
            let fixture = WatchedPageFixture(steps)
            let failed = try seed(fixture)
            await failed.fixturePull(session)
            try requireOld(failed, "engine failure at page \(index)")
            let paths = await fixture.paths()
            try watchedExpect(paths == Array(steps.prefix(index + 1)).map(\.path),
                              "failure witness must reach the chosen page and stop there")
        }
        let unauthorized = try seed(WatchedPageFixture(WatchedReaderCases.fullSteps()), status: 401)
        await unauthorized.fixturePull(session)
        try requireOld(unauthorized, "non-200")

        // Token acquisition is a separate suspension from each HTTP page.
        for retire in [false, true] {
            let tokenGate = WatchedPageFixture([WatchedReaderCases.step("token", "[]")], pauseIndex: 0)
            let network = WatchedPageFixture(WatchedReaderCases.fullSteps())
            let blocked = try seed(network, tokenGate: tokenGate)
            let task = Task { await blocked.fixturePull(session) }
            try await tokenGate.waitForPause()
            if retire { WatchedEngineEnvironment.shared.changeSession(otherSession) } else { task.cancel() }
            await tokenGate.resume()
            await task.value
            try requireOld(blocked, "token suspension fence")
            let calls = await network.paths()
            try watchedExpect(calls.isEmpty, "retired/cancelled token cannot start a bearer request")
        }
        for index in WatchedReaderCases.fullSteps().indices {
            for retire in [false, true] {
                let fixture = WatchedPageFixture(WatchedReaderCases.fullSteps(), pauseIndex: index)
                let blocked = try seed(fixture)
                let task = Task { await blocked.fixturePull(session) }
                try await fixture.waitForPause()
                if retire { WatchedEngineEnvironment.shared.changeSession(otherSession) } else { task.cancel() }
                await fixture.resume()
                await task.value
                try requireOld(blocked, "engine HTTP suspension \(index)")
                let calls = await fixture.paths()
                try watchedExpect(calls.count == index + 1, "engine must stop after invalidated page")
            }
        }
        // Real reset increments the actual engine generation while the last page is suspended.
        let lastIndex = WatchedReaderCases.fullSteps().count - 1
        let fixture = WatchedPageFixture(WatchedReaderCases.fullSteps(), pauseIndex: lastIndex)
        let resetEngine = try seed(fixture)
        let task = Task { await resetEngine.fixturePull(session) }
        try await fixture.waitForPause()
        resetEngine.reset()
        await fixture.resume()
        await task.value
        let resetState = resetEngine.fixtureState()
        try watchedExpect(resetState.0.isEmpty && resetState.1.isEmpty &&
                          resetState.2 == nil && resetState.3 == nil && resetState.4.isEmpty,
                          "generation reset never resurrects any retired snapshot or pending push")
        try watchedExpect(WatchedEngineEnvironment.shared.saves().isEmpty, "no post-reset save")
        try watchedExpect(resetEngine.currentWatchedShowInventory(expectedSession: session) == nil,
                          "reset revokes complete inventory")
        let original = try legacyData()
        let writeFixture = WatchedPageFixture(WatchedReaderCases.fullSteps())
        let readOnly = try seed(writeFixture, data: original, failWrites: true)
        await readOnly.fixturePull(session)
        let readOnlyPaths = await writeFixture.paths()
        try watchedExpect(readOnlyPaths == WatchedReaderCases.fullSteps().map(\.path),
                          "write-failure witness must complete every network leg first")
        try requireOld(readOnly, "protected-storage write failure")
        try watchedExpect(readOnly.currentWatchedShowInventory(expectedSession: session) == nil &&
                          WatchedEngineEnvironment.shared.data() == original,
                          "failed save cannot publish a complete inventory/cursor or claim persisted replacement")
        WatchedEngineEnvironment.shared.configure(session: session, loaded: original,
            fixture: WatchedPageFixture(WatchedReaderCases.fullSteps()))
        await readOnly.fixturePull(session)
        try watchedExpect(WatchedEngineEnvironment.shared.saves().count == 1 &&
                          readOnly.currentWatchedShowInventory(expectedSession: session)?.entries.count == 2,
                          "successful retry publishes only after acknowledged complete persistence")
        try await opaqueRetention()
        try await actionAdmission()
        try await selectedContinueWatching()
        try await parsingCredentialCost()
    }

    static func replacingPending(_ rows: [Data]) throws -> Data {
        let base = try legacyData()
        let fields = try VortxNativeBootstrapArchive.rawJSONObjectMembers(base, maximumBytes: base.count)
        let pending = "[" + rows.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ",") + "]"
        let pairs = fields.map {
            String(decoding: $0.keyJSON, as: UTF8.self) + ":"
                + ($0.key == "pendingPushes" ? pending : String(decoding: $0.valueJSON, as: UTF8.self))
        }
        return Data(("{" + pairs.joined(separator: ",") + "}").utf8)
    }

    static func actionAdmission() async throws {
        let owner = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        func row(_ body: String) -> Data { Data(("{\"sessionID\":" + owner + "," + body + "}").utf8) }
        // These all decode as PendingPush and belong to the current session, but cannot safely
        // execute their stated action. Their raw number spellings must survive the quarantine.
        let unusable = [
            row(#""kind":"watched","isSeries":true,"tmdb":123"#),
            row(#""kind":"watched","isSeries":true,"tmdb":123,"season":1"#),
            row(#""kind":"watched","isSeries":true,"tmdb":123,"episode":2"#),
            row(#""kind":"watched","isSeries":true,"tmdb":123,"season":-1,"episode":2"#),
            row(#""kind":"watched","isSeries":true,"tmdb":123,"season":1,"episode":-1"#),
            row(#""kind":"watched","isSeries":false"#),
            row(#""kind":"watched","isSeries":false,"tmdb":0"#),
            row(#""kind":"watchlistAdd","isSeries":true,"imdb":"not-an-imdb-id""#),
            row(#""kind":"ratingSet","isSeries":false,"tmdb":123,"ratedAtEpoch":1.2300e+02"#),
            row(#""kind":"ratingSet","isSeries":false,"tmdb":123,"rating":0"#),
            row(#""kind":"ratingSet","isSeries":false,"tmdb":123,"rating":11"#),
            row(#""kind":"ratingSet","isSeries":true,"tmdb":123,"rating":7,"season":1,"episode":2"#),
            row(#""kind":"ratingRemove","isSeries":false,"tmdb":123,"rating":7"#)
        ]
        // Real caller-compatible controls: whole-title watchlist with and without copied episode
        // coordinates, actual episode watch, movie watch, score boundaries and a legacy nil stamp.
        let usable = [
            row(#""kind":"watched","isSeries":true,"tmdb":123,"season":0,"episode":2"#),
            row(#""kind":"watched","isSeries":false,"tmdb":124"#),
            row(#""kind":"watchlistAdd","isSeries":true,"tmdb":125"#),
            row(#""kind":"watchlistAdd","isSeries":true,"tmdb":126,"season":1,"episode":2"#),
            row(#""kind":"watchlistRemove","isSeries":false,"tmdb":127"#),
            row(#""kind":"ratingSet","isSeries":false,"tmdb":128,"rating":1"#),
            row(#""kind":"ratingSet","isSeries":true,"tmdb":129,"rating":10,"ratedAtEpoch":123.25"#),
            row(#""kind":"ratingRemove","isSeries":true,"tmdb":130,"ratedAtEpoch":123"#)
        ]
        for raw in usable + unusable {
            let decoded = try JSONDecoder().decode(TraktSyncEngine.PendingPush.self, from: raw)
            try watchedExpect(decoded.sessionID == session, "negative row must pass old Codable/session-only gate")
        }
        func preserved(_ data: Data, knownCount: Int) throws {
            let fields = try VortxNativeBootstrapArchive.rawJSONObjectMembers(data, maximumBytes: data.count)
            let pending = fields.first(where: { $0.key == "pendingPushes" })!.valueJSON
            let rows = try VortxNativeBootstrapArchive.rawJSONArrayValues(pending, maximumBytes: data.count)
            try watchedExpect(rows.count == knownCount + unusable.count && Array(rows.suffix(unusable.count)) == unusable,
                              "unusable known rows remain byte-identical at their original queue path")
        }
        let input = try replacingPending(usable + unusable)
        let engine = try seed(WatchedPageFixture(WatchedReaderCases.fullSteps()), data: input)
        try watchedExpect(engine.fixtureState().4.count == usable.count, "only action-usable rows enter execution projection")
        await engine.fixturePull(session)
        guard let saved = WatchedEngineEnvironment.shared.saves().last else {
            throw WatchedTestFailure.check("action admission positive pull did not save")
        }
        try preserved(saved, knownCount: usable.count)
        let reloaded = try seed(WatchedPageFixture([]), data: saved)
        await reloaded.fixtureDrain(session)
        try watchedExpect(WatchedEngineEnvironment.shared.calls() == [
            "watched-episode-0-2", "watched-movie", "watchlist-add-show", "watchlist-add-show",
            "watchlist-remove-movie", "rating-set", "rating-set", "rating-remove"
        ], "valid actions execute their exact shape; no quarantined row becomes a movie or silent successful deletion")
        guard let drained = WatchedEngineEnvironment.shared.saves().last else {
            throw WatchedTestFailure.check("valid action controls did not drain")
        }
        try preserved(drained, knownCount: 0)
        let quarantined = try seed(WatchedPageFixture([]), data: drained)
        try watchedExpect(quarantined.fixtureState().4.isEmpty, "quarantine survives a second reload")
        await quarantined.fixtureDrain(session)
        try watchedExpect(WatchedEngineEnvironment.shared.calls().isEmpty &&
                          WatchedEngineEnvironment.shared.data() == drained,
                          "unusable known rows never execute or disappear on a later drain")
    }

    static func selectedContinueWatching() async throws {
        let fixture = WatchedPageFixture(WatchedReaderCases.fullSteps())
        WatchedEngineEnvironment.shared.configure(session: session, loaded: try legacyData(),
            fixture: fixture, importEnabled: false)
        let engine = TraktSyncEngine.fixtureNew()
        let fence = WatchedSessionFence()
        let purpose = TraktWatchedReadPurpose.selectedContinueWatching(isCurrent: { fence.isCurrent() })
        let denied = await engine.refreshWatchedShowInventory(expectedSession: session, purpose: .badgeImport)
        let deniedPaths = await fixture.paths()
        try watchedExpect(denied == nil && deniedPaths.isEmpty, "badge-purpose reads stay toggle gated")
        let inventory = await engine.refreshWatchedShowInventory(expectedSession: session, purpose: purpose)
        try watchedExpect(inventory?.entries.map(\.traktID) == [3, 4], "selected Home intent can obtain a complete inventory")
        try watchedExpect(engine.currentWatchedShowInventory(expectedSession: session) == nil &&
                          engine.shadowWatchedIDs().isEmpty && !engine.hasEpisodeShadow(),
                          "selected-CW read never enables badge visibility")
        try watchedExpect(engine.fixtureState().4.count == 1 && WatchedEngineEnvironment.shared.calls().isEmpty,
                          "selected-CW refresh never drains a write or reads ratings")
        let cached = await engine.refreshWatchedShowInventory(expectedSession: session, purpose: purpose)
        let cachedPaths = await fixture.paths()
        try watchedExpect(cached?.revision == inventory?.revision &&
                          cachedPaths == WatchedReaderCases.fullSteps().map(\.path),
                          "selected-CW repeat reads use the same bounded refresh throttle")
        fence.retire()
        let retired = await engine.refreshWatchedShowInventory(expectedSession: session, purpose: purpose)
        try watchedExpect(retired == nil &&
                          engine.currentWatchedShowInventory(expectedSession: session, purpose: purpose) == nil,
                          "retired Home intent cannot read even a complete cached inventory")

        for index in WatchedReaderCases.fullSteps().indices {
            let fixture = WatchedPageFixture(WatchedReaderCases.fullSteps(), pauseIndex: index)
            WatchedEngineEnvironment.shared.configure(session: session, loaded: try legacyData(),
                fixture: fixture, importEnabled: false)
            let pending = TraktSyncEngine.fixtureNew()
            let fence = WatchedSessionFence()
            let purpose = TraktWatchedReadPurpose.selectedContinueWatching(isCurrent: { fence.isCurrent() })
            let task = Task { await pending.refreshWatchedShowInventory(expectedSession: session, purpose: purpose) }
            try await fixture.waitForPause()
            // A competing current intent may inspect the old cache, but cannot begin a second flight.
            let competitor = await pending.refreshWatchedShowInventory(expectedSession: session,
                purpose: .selectedContinueWatching(isCurrent: { true }))
            try watchedExpect(competitor == nil, "in-flight legacy cache cannot masquerade as complete")
            fence.retire()
            await fixture.resume()
            let result = await task.value
            try watchedExpect(result == nil, "retired selected intent returns no inventory")
            try requireOld(pending, "Home intent retired at page \(index)")
            let calls = await fixture.paths()
            try watchedExpect(calls.count == index + 1 && WatchedEngineEnvironment.shared.calls().isEmpty,
                              "intent retirement stops before another request and never triggers provider writes")
        }
    }

    static func parsingCredentialCost() async throws {
        var counts: [Int] = []
        for episodeCount in [1, 1_000] {
            let episodeRows = (1...episodeCount).map { #"{"number":\#($0)}"# }.joined(separator: ",")
            let show = #"{"show":{"ids":{"trakt":3,"tmdb":3}},"seasons":[{"number":1,"episodes":[\#(episodeRows)]}]}"#
            let steps = [WatchedReaderCases.step("/sync/last_activities", WatchedReaderCases.activity),
                WatchedReaderCases.step(WatchedReaderCases.path("movies", 1), "[]"),
                WatchedReaderCases.step(WatchedReaderCases.path("shows", 1), "[\(show)]"),
                WatchedReaderCases.step(WatchedReaderCases.path("shows", 2), "[]")]
            let fixture = WatchedPageFixture(steps)
            let engine = try seed(fixture)
            await engine.fixturePull(session)
            try watchedExpect(engine.fixtureState().1.count == episodeCount * 2 &&
                              WatchedEngineEnvironment.shared.saves().count == 1,
                              "credential-cost witness must actually fold and persist every episode")
            counts.append(WatchedEngineEnvironment.shared.reads())
        }
        try watchedExpect(counts[0] == counts[1] && counts[0] > 0,
                          "credential checks depend on await/commit boundaries, not provider-controlled episode count")
    }

    static func opaqueRetention() async throws {
        let base = try legacyData()
        let fields = try VortxNativeBootstrapArchive.rawJSONObjectMembers(base, maximumBytes: base.count)
        let pending = fields.first(where: { $0.key == "pendingPushes" })!.valueJSON
        let known = try VortxNativeBootstrapArchive.rawJSONArrayValues(pending, maximumBytes: pending.count)[0]
        let owner = fields.first(where: { $0.key == "sessionID" })!.valueJSON
        let opaqueAction = Data((#"{"kind":"futureAction","sessionID":"# + String(decoding: owner, as: UTF8.self)
            + #","future":18446744073709551615}"#).utf8)
        let opaqueRating = Data((String(decoding: known.dropLast(), as: UTF8.self)
            + #","futureRatingPolicy":{"weight":0.123456789012345678901}}"#).utf8)
        let rawUnknown = Data(#"{"exact":1.2300e+02,"large":18446744073709551615,"text":"escaped\/value"}"#.utf8)
        var pairs = fields.map { field -> String in
            let value = field.key == "pendingPushes"
                ? Data(("[" + [opaqueAction, known, opaqueRating].map { String(decoding: $0, as: UTF8.self) }.joined(separator: ",") + "]").utf8)
                : field.valueJSON
            return String(decoding: field.keyJSON, as: UTF8.self) + ":" + String(decoding: value, as: UTF8.self)
        }
        pairs.append(#""futureExact":"# + String(decoding: rawUnknown, as: UTF8.self))
        let input = Data(("{" + pairs.joined(separator: ",") + "}").utf8)
        let fixture = WatchedPageFixture(WatchedReaderCases.fullSteps())
        let engine = try seed(fixture, data: input)
        try watchedExpect(engine.fixtureState().4.count == 1, "only the understood same-session queue row is executable")
        await engine.fixturePull(session)
        guard let saved = WatchedEngineEnvironment.shared.saves().last else {
            throw WatchedTestFailure.check("opaque-preserving successful pull did not save")
        }
        func verifyOpaque(_ data: Data, knownCount: Int) throws {
            let fields = try VortxNativeBootstrapArchive.rawJSONObjectMembers(data, maximumBytes: data.count)
            try watchedExpect(fields.first(where: { $0.key == "futureExact" })?.valueJSON == rawUnknown,
                              "unknown nested numbers and string escapes retain original bytes at original path")
            let rows = try VortxNativeBootstrapArchive.rawJSONArrayValues(
                fields.first(where: { $0.key == "pendingPushes" })!.valueJSON, maximumBytes: data.count
            )
            try watchedExpect(rows.count == knownCount + 2 && rows.first == opaqueAction && rows.last == opaqueRating,
                              "unknown action and unknown rating fields stay raw in their original row order")
        }
        try verifyOpaque(saved, knownCount: 1)
        let reloaded = try seed(WatchedPageFixture([]), data: saved)
        try watchedExpect(reloaded.fixtureState().4.count == 1, "quarantined rows stay non-executable on reload")
        await reloaded.fixtureDrain(session)
        guard let drained = WatchedEngineEnvironment.shared.saves().last else {
            throw WatchedTestFailure.check("actual known-row queue drain did not save")
        }
        try verifyOpaque(drained, knownCount: 0)
        try watchedExpect(reloaded.fixtureState().4.isEmpty, "known queue row drains without executing opaque actions")

        // A proven other-session envelope is reset; opaque extensions never migrate to the successor.
        WatchedEngineEnvironment.shared.configure(session: otherSession, loaded: input,
            fixture: WatchedPageFixture(WatchedReaderCases.emptySteps()))
        let successor = TraktSyncEngine.fixtureNew()
        await successor.fixturePull(otherSession)
        guard let successorData = WatchedEngineEnvironment.shared.saves().last else {
            throw WatchedTestFailure.check("successor complete empty account was not persisted")
        }
        let successorFields = try VortxNativeBootstrapArchive.rawJSONObjectMembers(successorData, maximumBytes: successorData.count)
        try watchedExpect(!successorFields.contains(where: { $0.key == "futureExact" || $0.key == "futureEnvelopeField" }),
                          "same-path opaque carrier is not copied to a successor owner")
        try watchedExpect(successor.currentWatchedShowInventory(expectedSession: otherSession)?.entries.isEmpty == true,
                          "complete empty inventory is distinct from unavailable")

        // Uninspectable carriers stay untouched; they cannot be silently overwritten by a new read.
        let excessive = Data((String(decoding: base.dropLast(), as: UTF8.self)
            + ",\"tooMuch\":\"" + String(repeating: "x", count: 1024 * 1024 + 1) + "\"}").utf8)
        let duplicate = Data((String(decoding: base.dropLast(), as: UTF8.self) + ",\"watchedIDs\":[]}").utf8)
        for invalid in [excessive, duplicate, Data("{malformed".utf8)] {
            let network = WatchedPageFixture(WatchedReaderCases.emptySteps())
            let blocked = try seed(network, data: invalid)
            await blocked.fixturePull(session)
            try watchedExpect(WatchedEngineEnvironment.shared.data() == invalid &&
                              WatchedEngineEnvironment.shared.saves().isEmpty,
                              "unretainable source remains byte-identical and blocks replacement")
            let requests = await network.paths()
            try watchedExpect(requests.isEmpty, "blocked retention performs no lossy replacement read")
        }
    }
}
