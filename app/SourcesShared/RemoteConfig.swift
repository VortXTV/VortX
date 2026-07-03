import Foundation

/// VortX RemoteConfig: tune / kill / upgrade shipped app behavior from a backend JSON with NO app update.
///
/// DESIGN CONTRACT (why this is safe on hot paths and safe when the backend is gone):
///
///   1. EVERY accessor has a HARDCODED fallback equal to the current shipping value. Deleting this service,
///      or the remote field being null, is behaviorally identical to today. `RemoteConfigDefaults` holds one
///      named constant per wired dial; the accessors read the (already-resolved) value or that default.
///
///   2. Reads are SYNCHRONOUS and LOCK-FREE. Ranking runs per-stream over large lists and the player reads at
///      init, so a read must never touch the actor or take a lock. `RemoteConfig.snapshot` is a
///      `nonisolated(unsafe) static var` pointing at an IMMUTABLE `ResolvedConfig` class instance. It is only
///      ever REPLACED (atomic pointer store) under the actor, never mutated. Readers see either the old or the
///      new fully-formed value; there is no torn state.
///
///   3. Clamp ONCE, at swap time. `validate(_:)` turns raw decoded JSON into a `ResolvedConfig` whose every
///      field is already range-clamped and defaults-filled. A bad remote value reverts to the baked default;
///      it can never brick the app or breach a jetsam ceiling / ranking invariant.
///
///   4. DEFAULTS DO NOT CHANGE. A field defaulting to null => baked default. `features.dvRemux` stays
///      effectively OFF unless the owner's user toggle (UserDefaults `stremiox.dvRemux`) or a remote value
///      turns it on; the user's EXPLICIT toggle always wins over the remote default (see PlayerEngineRouter).
///
///   5. FAIL-SOFT everywhere. Any fetch / decode / disk error keeps the last-good snapshot (or baked defaults);
///      nothing throws out of `bootstrap`/`refresh`. `master.remoteConfigEnabled == false` discards a fetched
///      config back to baked. A corrupt cache is treated as absent => baked.
///
/// SIGNING: the config GET is signed with the SAME HMAC helper (`VortXEdgeAuth.sign`) every other gated
/// `*.vortx.tv` worker uses (skip / trickplay / ratings / …). `config.vortx.tv` was added to that helper's
/// `gatedHosts`. With no secret provisioned the signature is a safe no-op the worker's observe mode allows.
enum RemoteConfigDefaults {
    // Player read-ahead ceilings (MPVMetalViewController.loadFile). These MUST equal the shipping literals.
    static let debridCeilingMiB = 768        // non-reduced iOS/tvOS debrid RAM ceiling (was `768 * 1024 * 1024`)
    static let reducedCeilingMiB = 128       // Apple TV HD (PerformanceMode.reduced) ceiling (was `128 * 1024 * 1024`)
    static let macCeilingMiB = 1024          // macOS ceiling (was `1_024 * 1024 * 1024`)
    static let offFloorMiB = 64              // hard floor: no ceiling may drop below this
    static let vodReadaheadSecs = 300        // demuxer-readahead-secs for VOD (configureLiveMode else-branch)
    static let dvRemuxWindowMiB = 64         // DV-for-MKV remux buffer sliding-window re-read floor (VortXRemuxBuffer)

    // Timeouts (detail settle / debrid resolve). Present for future wiring; clamped in validate.
    static let detailSettleIOSSecs = 12
    static let detailSettleTVSecs = 12
    static let debridResolveSecs = 15

    // Trickplay capture params.
    static let captureIntervalSecs = 10      // ScrubThumbnails.captureInterval
    static let trickplayMinFrames = 1        // CommunityTrickplay lower bound (`sorted.count >= 1`)
    static let trickplayMaxFrames = 600      // CommunityTrickplay upper bound (`sorted.count <= 600`)

    // Endpoints.
    static let endpointTrickplay = "https://trickplay.vortx.tv"   // CommunityTrickplay.baseURL
    static let endpointCatalogs = "https://catalogs.vortx.tv/3"   // TMDBClient.edgeBase
    static let endpointSubtitles = "https://subtitles.vortx.tv"   // SubtitlePoolClient / LanguageIndexClient base
    static let endpointSources = "https://sources.vortx.tv"       // SourceIndexClient base (Singularity source index)

    // Refresh cadence.
    static let refreshIntervalHours = 6

    // Community-subtitle system tunables (clamped in validate). Baked == the client-side shipping defaults.
    static let subtitleDownloadTimeoutMs = 12000   // per-sub download budget
    static let subtitleUploadMaxBytes = 1_048_576  // 1 MiB text cap (mirrors the worker's cap)
    static let subtitleOffsetBucketMs = 250        // offset quantization (worker also buckets to 250 ms)
    static let langIndexMinSeen = 1                // min pool `seenCount` before an availability read is trusted

    // Community-subtitle feature flags, baked defaults (call sites pass these to isFeatureOn).
    static let featureCommunitySubtitles = true    // pooled-subtitle read + upload master gate
    static let featureSubtitleSync = true          // learned-offset read + contribute
    static let featureLanguageIndex = true         // audio/sub language availability read + contribute
    static let featureSourceIndex = true           // community source-index hoard (contribute) + serve (read)

    // Feature flags, baked defaults (used as `isFeatureOn(_:default:)` argument by each call site).
    static let featureDiskCache = true          // gate is force-OFF only; user setting still governs arming
    static let featureTrailers = true           // stremiox.autoplayTrailers default
    static let featureCommunityTrickplay = true // CommunityTrickplay.isEnabled default
    static let featureCollectionsHub = true     // CollectionsHubModel.isAvailable
    static let featureSpoilerBlur = true        // vortx.spoilerBlur default (user setting wins)
}

// MARK: - Decodable schema (decode ALL; wire a subset). Every field Optional; unknown keys ignored.

struct RemoteConfigData: Decodable {
    struct Master: Decodable {
        let remoteConfigEnabled: Bool?
        let rankingConfigEnabled: Bool?
    }
    struct Features: Decodable {
        let communityTrickplay: Bool?
        let dvRemux: Bool?
        let diskCache: Bool?
        let trailers: Bool?
        let vortxRatings: Bool?
        let xrdbPosters: Bool?
        let erdbPosters: Bool?
        let collectionsHub: Bool?
        let skipVortxLayer: Bool?
        let aniSkip: Bool?
        let spoilerBlur: Bool?
        let debridCacheCheck: Bool?
        let debridInlineResolve: Bool?
        let hdrDisplayModeSwitch: Bool?
        let iosPassthroughAudio: Bool?
        let dvToAVPlayerRouting: Bool?
        let hlsToAVPlayerRouting: Bool?
        let av1Penalty: Bool?
        let communitySubtitles: Bool?
        let subtitleSync: Bool?
        let languageIndex: Bool?
        let localizedMetadata: Bool?
        let sourceIndex: Bool?
    }
    struct Player: Decodable {
        struct ReadAhead: Decodable {
            let debridCeilingMiB: Int?
            let reducedCeilingMiB: Int?
            let macCeilingMiB: Int?
            let offFloorMiB: Int?
            let dvRemuxWindowMiB: Int?
        }
        struct ReadAheadOff: Decodable {
            let reducedLocalMiB: Int?
            let reducedRemoteMiB: Int?
            let mobileLocalMiB: Int?
            let mobileRemoteMiB: Int?
            let macLocalMiB: Int?
            let macRemoteMiB: Int?
        }
        struct Live: Decodable {
            let readAheadMiB: Int?
            let readaheadSecs: Int?
            let maxBackBytesMiB: Int?
            let startIndex: Int?
            let reconnectDelayMax: Int?
        }
        struct Routing: Decodable {
            let dvToAVPlayer: Bool?
            let hlsToAVPlayer: Bool?
        }
        let readAhead: ReadAhead?
        let readAheadOff: ReadAheadOff?
        let vodReadaheadSecs: Int?
        let live: Live?
        let perfConstrainedThresholdBytes: Int?
        let hdrToneMapMode: String?
        let hdrToneMapCurve: String?
        let routing: Routing?
    }
    struct Trickplay: Decodable {
        struct LocalCache: Decodable {
            let maxDiskMiB: Int?
            let ttlHours: Int?
            let maxLookbackBuckets: Int?
            let nsCacheCountMobile: Int?
            let nsCacheCountMac: Int?
        }
        let captureIntervalSecs: Int?
        let minFrames: Int?
        let maxFrames: Int?
        let sheetCapBytes: Int?
        let tileW: Int?
        let tileH: Int?
        let jpegQuality: Double?
        let progressiveSeconds: Int?
        let localCache: LocalCache?
    }
    /// Ranking is decoded as an opaque JSON blob for now (only master.rankingConfigEnabled is honored). The
    /// full shape is documented in the schema; wiring individual ranking dials is future work and would go
    /// through validate + a rankingConfigEnabled short-circuit.
    struct Endpoints: Decodable {
        let trickplay: String?
        let catalogs: String?
        let skip: String?
        let trailer: String?
        let ratings: String?
        let erdb: String?
        let poster: String?
        let subtitles: String?
        let sources: String?
    }
    /// Community-subtitle tunables. Every field optional + backward-compatible: an old config with no
    /// `subtitle` / `langIndex` block decodes fine and every value falls back to its baked default.
    struct Subtitle: Decodable {
        let downloadTimeoutMs: Int?
        let uploadMaxBytes: Int?
        let offsetBucketMs: Int?
    }
    struct LangIndex: Decodable {
        let minSeen: Int?
    }
    struct Timeouts: Decodable {
        let detailSettleIOSSecs: Int?
        let detailSettleTVSecs: Int?
        let debridResolveSecs: Int?
        let resolveSettledFreshSecs: Int?
        let resolveSettledCeilingSecs: Int?
    }

    let master: Master?
    let features: Features?
    let player: Player?
    let trickplay: Trickplay?
    let endpoints: Endpoints?
    let timeouts: Timeouts?
    let subtitle: Subtitle?
    let langIndex: LangIndex?
    let skipProvider: String?
    let schemaVersion: Int?
    let configRevision: String?   // opaque ISO string (e.g. "2026-07-01T00:00:00Z"); NOT an Int. A wrong
                                  // type here would throw typeMismatch and fail the whole decode => the
                                  // entire remote config would silently never apply. Keep this a String.
    let minAppBuild: Int?
    let refreshIntervalHours: Int?
}

// MARK: - Resolved, already-clamped, defaults-filled snapshot (immutable; read lock-free on hot paths).

/// A `final class` so `RemoteConfig.snapshot` can be swapped as a single atomic pointer store. Every stored
/// value is ALREADY clamped and defaults-filled by `validate`, so accessors are trivial reads. Never mutated
/// after construction.
final class ResolvedConfig: @unchecked Sendable {
    // Master gates.
    let remoteConfigEnabled: Bool
    let rankingConfigEnabled: Bool

    // Player ceilings (MiB), already clamped and floor-raised.
    let debridCeilingMiB: Int
    let reducedCeilingMiB: Int
    let macCeilingMiB: Int
    let offFloorMiB: Int
    let vodReadaheadSecsValue: Int
    let dvRemuxWindowMiB: Int

    // Timeouts (secs), clamped.
    let detailSettleIOSSecs: Int
    let detailSettleTVSecs: Int
    let debridResolveSecs: Int

    // Trickplay params, clamped.
    let captureIntervalSecsValue: Int
    let trickplayMinFrames: Int
    let trickplayMaxFrames: Int

    // Endpoints, validated (https + *.vortx.tv) or baked default.
    let trickplayEndpoint: URL
    let catalogsEndpoint: URL
    let subtitlesEndpoint: URL
    let sourcesEndpoint: URL

    // Community-subtitle tunables, clamped.
    let subtitleDownloadTimeoutMs: Int
    let subtitleUploadMaxBytes: Int
    let subtitleOffsetBucketMs: Int
    let langIndexMinSeen: Int

    // Feature tri-state (nil = baked default; the accessor substitutes the call site's `default:`).
    private let features: [String: Bool]

    // Refresh cadence, clamped.
    let refreshIntervalHours: Int

    init(remoteConfigEnabled: Bool,
         rankingConfigEnabled: Bool,
         debridCeilingMiB: Int,
         reducedCeilingMiB: Int,
         macCeilingMiB: Int,
         offFloorMiB: Int,
         vodReadaheadSecs: Int,
         dvRemuxWindowMiB: Int,
         detailSettleIOSSecs: Int,
         detailSettleTVSecs: Int,
         debridResolveSecs: Int,
         captureIntervalSecs: Int,
         trickplayMinFrames: Int,
         trickplayMaxFrames: Int,
         trickplayEndpoint: URL,
         catalogsEndpoint: URL,
         subtitlesEndpoint: URL,
         sourcesEndpoint: URL,
         subtitleDownloadTimeoutMs: Int,
         subtitleUploadMaxBytes: Int,
         subtitleOffsetBucketMs: Int,
         langIndexMinSeen: Int,
         features: [String: Bool],
         refreshIntervalHours: Int) {
        self.remoteConfigEnabled = remoteConfigEnabled
        self.rankingConfigEnabled = rankingConfigEnabled
        self.debridCeilingMiB = debridCeilingMiB
        self.reducedCeilingMiB = reducedCeilingMiB
        self.macCeilingMiB = macCeilingMiB
        self.offFloorMiB = offFloorMiB
        self.vodReadaheadSecsValue = vodReadaheadSecs
        self.dvRemuxWindowMiB = dvRemuxWindowMiB
        self.detailSettleIOSSecs = detailSettleIOSSecs
        self.detailSettleTVSecs = detailSettleTVSecs
        self.debridResolveSecs = debridResolveSecs
        self.captureIntervalSecsValue = captureIntervalSecs
        self.trickplayMinFrames = trickplayMinFrames
        self.trickplayMaxFrames = trickplayMaxFrames
        self.trickplayEndpoint = trickplayEndpoint
        self.catalogsEndpoint = catalogsEndpoint
        self.subtitlesEndpoint = subtitlesEndpoint
        self.sourcesEndpoint = sourcesEndpoint
        self.subtitleDownloadTimeoutMs = subtitleDownloadTimeoutMs
        self.subtitleUploadMaxBytes = subtitleUploadMaxBytes
        self.subtitleOffsetBucketMs = subtitleOffsetBucketMs
        self.langIndexMinSeen = langIndexMinSeen
        self.features = features
        self.refreshIntervalHours = refreshIntervalHours
    }

    /// The all-baked snapshot: identical to shipping. Built when no cache exists / config is disabled / any
    /// validation short-circuits.
    static var baked: ResolvedConfig {
        ResolvedConfig(
            remoteConfigEnabled: true,
            rankingConfigEnabled: true,
            debridCeilingMiB: RemoteConfigDefaults.debridCeilingMiB,
            reducedCeilingMiB: RemoteConfigDefaults.reducedCeilingMiB,
            macCeilingMiB: RemoteConfigDefaults.macCeilingMiB,
            offFloorMiB: RemoteConfigDefaults.offFloorMiB,
            vodReadaheadSecs: RemoteConfigDefaults.vodReadaheadSecs,
            dvRemuxWindowMiB: RemoteConfigDefaults.dvRemuxWindowMiB,
            detailSettleIOSSecs: RemoteConfigDefaults.detailSettleIOSSecs,
            detailSettleTVSecs: RemoteConfigDefaults.detailSettleTVSecs,
            debridResolveSecs: RemoteConfigDefaults.debridResolveSecs,
            captureIntervalSecs: RemoteConfigDefaults.captureIntervalSecs,
            trickplayMinFrames: RemoteConfigDefaults.trickplayMinFrames,
            trickplayMaxFrames: RemoteConfigDefaults.trickplayMaxFrames,
            trickplayEndpoint: URL(string: RemoteConfigDefaults.endpointTrickplay)!,
            catalogsEndpoint: URL(string: RemoteConfigDefaults.endpointCatalogs)!,
            subtitlesEndpoint: URL(string: RemoteConfigDefaults.endpointSubtitles)!,
            sourcesEndpoint: URL(string: RemoteConfigDefaults.endpointSources)!,
            subtitleDownloadTimeoutMs: RemoteConfigDefaults.subtitleDownloadTimeoutMs,
            subtitleUploadMaxBytes: RemoteConfigDefaults.subtitleUploadMaxBytes,
            subtitleOffsetBucketMs: RemoteConfigDefaults.subtitleOffsetBucketMs,
            langIndexMinSeen: RemoteConfigDefaults.langIndexMinSeen,
            features: [:],
            refreshIntervalHours: RemoteConfigDefaults.refreshIntervalHours)
    }

    // MARK: Synchronous clamped accessors (each fallback literal == the current shipping constant).

    /// The RAM read-ahead ceiling (bytes) for a REMOTE (debrid/direct) VOD stream, as applied to
    /// `demuxer-max-bytes`. Preserves the shipping split: macOS gets the generous ceiling, Apple TV HD
    /// (reduced) the tight one, everything else the debrid ceiling. Already clamped + floor-raised.
    func readAheadDebridCeilingBytes(reduced: Bool, isMac: Bool) -> Int {
        let mib: Int
        if isMac {
            mib = macCeilingMiB
        } else if reduced {
            mib = reducedCeilingMiB
        } else {
            mib = debridCeilingMiB
        }
        return mib * 1024 * 1024
    }

    /// demuxer-readahead-secs for VOD (baked 300).
    var vodReadaheadSecs: Int { vodReadaheadSecsValue }

    /// Detail-settle timeout for the current platform (baked 12 both).
    func detailSettleSecs(tv: Bool) -> Int { tv ? detailSettleTVSecs : detailSettleIOSSecs }

    /// Trickplay capture cadence (baked 10).
    var captureIntervalSecs: Int { captureIntervalSecsValue }

    /// Trickplay frame bounds (baked min 1, max 600).
    var trickplayFrameBounds: (min: Int, max: Int) { (trickplayMinFrames, trickplayMaxFrames) }

    /// A validated endpoint URL by key ("trickplay" / "catalogs"). Returns nil for any unwired key; the two
    /// wired endpoints also have dedicated stored properties, this is the generic form.
    func endpoint(_ key: String) -> URL? {
        switch key {
        case "trickplay": return trickplayEndpoint
        case "catalogs": return catalogsEndpoint
        case "subtitles": return subtitlesEndpoint
        case "sources": return sourcesEndpoint
        default: return nil
        }
    }

    /// Community-subtitle download budget as a `TimeInterval` (seconds); baked 12 s.
    var subtitleDownloadTimeout: TimeInterval { TimeInterval(subtitleDownloadTimeoutMs) / 1000.0 }

    /// Tri-state feature read: remote true/false wins; remote null (absent) => the call site's baked default.
    func isFeatureOn(_ key: String, default fallback: Bool) -> Bool {
        features[key] ?? fallback
    }
}

// MARK: - The actor: fetch / validate / persist. Reads never go through here.

actor RemoteConfig {
    static let shared = RemoteConfig()

    /// The snapshot every reader consults. Backed by a lock, not a bare `var`: a plain `static var` of a class
    /// type read on the player path while the actor swaps it would race ARC (the reader's retain-on-load vs the
    /// writer's release-of-old), a rare use-after-free that `nonisolated(unsafe)` would only hide. Reads here
    /// are human-scale (player init, detail open, trickplay capture) so the uncontended lock (~tens of ns) is
    /// imperceptible while making the read/replace correct. Starts baked so a read before bootstrap is
    /// shipping-correct.
    nonisolated(unsafe) private static var _snapshot: ResolvedConfig = .baked
    private static let snapshotLock = NSLock()
    static var snapshot: ResolvedConfig {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return _snapshot
    }
    /// Atomically replace the snapshot (writer side; called only under the actor).
    private static func install(_ resolved: ResolvedConfig) {
        snapshotLock.lock(); _snapshot = resolved; snapshotLock.unlock()
    }

    // Networking.
    private static let configURL = URL(string: "https://config.vortx.tv/v1/config.json")!
    private static let fetchTimeout: TimeInterval = 8
    private static let etagKey = "vortx.remoteConfig.etag"
    private static let lastFetchKey = "vortx.remoteConfig.lastFetchEpoch"
    private static let foregroundThrottle: TimeInterval = 30 * 60   // once / 30 min for a foreground refresh

    /// The raw last-good JSON currently installed (nil = none / baked). Kept so `304 Not Modified` is a
    /// genuine no-op and a foreground refresh does not need to re-decode.
    private var currentRaw: Data?
    private var periodicStarted = false

    // MARK: Bootstrap (call once at launch).

    /// (1) Synchronously load the last-good cached JSON from Application Support and build the snapshot (else
    /// all-baked). (2) Kick a background refresh. Never throws.
    func bootstrap() {
        if let cached = Self.loadCachedJSON(), let decoded = try? JSONDecoder().decode(RemoteConfigData.self, from: cached) {
            currentRaw = cached
            Self.install(Self.validate(decoded))   // clamp once at swap time
        } else {
            currentRaw = nil
            Self.install(.baked)
        }
        startPeriodicIfNeeded()
        Task { await refresh() }
    }

    // MARK: Refresh.

    /// GET the config with `If-None-Match: <etag>`. 304 => keep. 200 => decode -> validate/clamp -> if
    /// master.remoteConfigEnabled == false discard to baked, else atomically swap snapshot + persist JSON +
    /// ETag. ANY error => keep last-good. Never throws.
    func refresh() async {
        var req = URLRequest(url: Self.configURL, timeoutInterval: Self.fetchTimeout)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "accept")
        if let etag = UserDefaults.standard.string(forKey: Self.etagKey), !etag.isEmpty {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        // Sign with the shared edge-auth helper (config.vortx.tv is a gated host). No-op without a secret;
        // the worker's observe mode lets an empty-key / unsigned request through, so a fetch never bricks.
        VortXEdgeAuth.sign(&req)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return }   // keep last-good
            if http.statusCode == 304 { return }                        // unchanged, keep last-good
            guard http.statusCode == 200 else { return }                // any other status: keep last-good

            let decoded = try JSONDecoder().decode(RemoteConfigData.self, from: data)

            // master.remoteConfigEnabled == false => discard fetched config to baked (kill switch for the
            // whole system). Do NOT persist a disabling config as last-good, so removing the field restores it.
            if decoded.master?.remoteConfigEnabled == false {
                Self.install(.baked)
                return
            }

            let resolved = Self.validate(decoded)
            Self.install(resolved)                   // locked replace; readers see old-or-new, never torn
            currentRaw = data
            Self.persist(json: data, etag: http.value(forHTTPHeaderField: "Etag"))
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastFetchKey)
        } catch {
            // Timeout / offline / decode failure: keep last-good. Never throw.
            return
        }
    }

    /// Foreground refresh, throttled to at most once per 30 minutes. Safe to call on every `.active` scene
    /// phase; it cheaply no-ops when the last fetch is recent.
    func refreshIfForegroundDue() async {
        let last = UserDefaults.standard.double(forKey: Self.lastFetchKey)
        if last > 0, Date().timeIntervalSince1970 - last < Self.foregroundThrottle { return }
        await refresh()
    }

    // MARK: Periodic loop.

    private func startPeriodicIfNeeded() {
        guard !periodicStarted else { return }
        periodicStarted = true
        Task { [weak self] in
            while !Task.isCancelled {
                let hours = Self.snapshot.refreshIntervalHours   // already clamped 1..24
                let seconds = UInt64(max(1, hours)) * 3600 * 1_000_000_000
                try? await Task.sleep(nanoseconds: seconds)
                await self?.refresh()
            }
        }
    }

    // MARK: Validation + clamping (the ONE place ranges are enforced).

    /// Turn raw decoded JSON into a fully clamped, defaults-filled `ResolvedConfig`. Every out-of-range or
    /// non-conforming value falls back to its baked default, so the result is always safe to read on a hot
    /// path. `master.rankingConfigEnabled == false` short-circuits ranking sections to baked (ranking dials
    /// are not wired yet, but the gate is honored so a future wiring degrades correctly).
    static func validate(_ data: RemoteConfigData) -> ResolvedConfig {
        let remoteEnabled = data.master?.remoteConfigEnabled ?? true
        let rankingEnabled = data.master?.rankingConfigEnabled ?? true

        // --- Player read-ahead ceilings (THE jetsam knob). Clamp, then raise anything below the floor. ---
        let floor = clamp(data.player?.readAhead?.offFloorMiB, RemoteConfigDefaults.offFloorMiB, 64, 64)   // fixed 64
        let debrid = max(floor, clamp(data.player?.readAhead?.debridCeilingMiB, RemoteConfigDefaults.debridCeilingMiB, 64, 900))
        let reduced = max(floor, clamp(data.player?.readAhead?.reducedCeilingMiB, RemoteConfigDefaults.reducedCeilingMiB, 64, 192))
        let mac = max(floor, clamp(data.player?.readAhead?.macCeilingMiB, RemoteConfigDefaults.macCeilingMiB, 128, 1536))
        let vodSecs = clamp(data.player?.vodReadaheadSecs, RemoteConfigDefaults.vodReadaheadSecs, 30, 600)
        // DV-remux buffer window floor: keep at least 4 MiB (a fragment or two) and cap at 512 MiB so a remote
        // value can widen the re-read floor without ever letting it approach the whole-movie RAM this replaced.
        let dvWindow = clamp(data.player?.readAhead?.dvRemuxWindowMiB, RemoteConfigDefaults.dvRemuxWindowMiB, 4, 512)

        // --- Timeouts. ---
        let settleIOS = clamp(data.timeouts?.detailSettleIOSSecs, RemoteConfigDefaults.detailSettleIOSSecs, 5, 60)
        let settleTV = clamp(data.timeouts?.detailSettleTVSecs, RemoteConfigDefaults.detailSettleTVSecs, 5, 60)
        let debridResolve = clamp(data.timeouts?.debridResolveSecs, RemoteConfigDefaults.debridResolveSecs, 5, 30)

        // --- Trickplay params. ---
        let capture = clamp(data.trickplay?.captureIntervalSecs, RemoteConfigDefaults.captureIntervalSecs, 2, 60)
        let minFrames = clamp(data.trickplay?.minFrames, RemoteConfigDefaults.trickplayMinFrames, 1, 10)
        let maxFrames = clamp(data.trickplay?.maxFrames, RemoteConfigDefaults.trickplayMaxFrames, 30, 600)

        // --- Endpoints: https + host ends ".vortx.tv" or baked default. ---
        let trickplayURL = validatedEndpoint(data.endpoints?.trickplay, fallback: RemoteConfigDefaults.endpointTrickplay)
        let catalogsURL = validatedEndpoint(data.endpoints?.catalogs, fallback: RemoteConfigDefaults.endpointCatalogs)
        let subtitlesURL = validatedEndpoint(data.endpoints?.subtitles, fallback: RemoteConfigDefaults.endpointSubtitles)
        let sourcesURL = validatedEndpoint(data.endpoints?.sources, fallback: RemoteConfigDefaults.endpointSources)

        // --- Community-subtitle tunables. ---
        let subDownloadMs = clamp(data.subtitle?.downloadTimeoutMs, RemoteConfigDefaults.subtitleDownloadTimeoutMs, 3000, 30000)
        let subUploadMax = clamp(data.subtitle?.uploadMaxBytes, RemoteConfigDefaults.subtitleUploadMaxBytes, 65536, 2_097_152)
        let subOffsetBucket = clamp(data.subtitle?.offsetBucketMs, RemoteConfigDefaults.subtitleOffsetBucketMs, 50, 2000)
        let langMinSeen = clamp(data.langIndex?.minSeen, RemoteConfigDefaults.langIndexMinSeen, 1, 50)

        // --- Refresh cadence. ---
        let refreshHours = clamp(data.refreshIntervalHours, RemoteConfigDefaults.refreshIntervalHours, 1, 24)

        // --- Feature tri-state map (only present, boolean-valued keys are stored; null / non-bool => absent
        //     => the call site's baked default is used at read time). ---
        var features: [String: Bool] = [:]
        if let f = data.features {
            func put(_ key: String, _ value: Bool?) { if let value { features[key] = value } }
            put("communityTrickplay", f.communityTrickplay)
            put("dvRemux", f.dvRemux)
            put("diskCache", f.diskCache)
            put("trailers", f.trailers)
            put("vortxRatings", f.vortxRatings)
            put("xrdbPosters", f.xrdbPosters)
            put("erdbPosters", f.erdbPosters)
            put("collectionsHub", f.collectionsHub)
            put("skipVortxLayer", f.skipVortxLayer)
            put("aniSkip", f.aniSkip)
            put("spoilerBlur", f.spoilerBlur)
            put("debridCacheCheck", f.debridCacheCheck)
            put("debridInlineResolve", f.debridInlineResolve)
            put("hdrDisplayModeSwitch", f.hdrDisplayModeSwitch)
            put("iosPassthroughAudio", f.iosPassthroughAudio)
            put("dvToAVPlayerRouting", f.dvToAVPlayerRouting)
            put("hlsToAVPlayerRouting", f.hlsToAVPlayerRouting)
            put("av1Penalty", f.av1Penalty)
            put("communitySubtitles", f.communitySubtitles)
            put("subtitleSync", f.subtitleSync)
            put("languageIndex", f.languageIndex)
            put("localizedMetadata", f.localizedMetadata)
            put("sourceIndex", f.sourceIndex)
        }

        return ResolvedConfig(
            remoteConfigEnabled: remoteEnabled,
            rankingConfigEnabled: rankingEnabled,
            debridCeilingMiB: debrid,
            reducedCeilingMiB: reduced,
            macCeilingMiB: mac,
            offFloorMiB: floor,
            vodReadaheadSecs: vodSecs,
            dvRemuxWindowMiB: dvWindow,
            detailSettleIOSSecs: settleIOS,
            detailSettleTVSecs: settleTV,
            debridResolveSecs: debridResolve,
            captureIntervalSecs: capture,
            trickplayMinFrames: minFrames,
            trickplayMaxFrames: maxFrames,
            trickplayEndpoint: trickplayURL,
            catalogsEndpoint: catalogsURL,
            subtitlesEndpoint: subtitlesURL,
            sourcesEndpoint: sourcesURL,
            subtitleDownloadTimeoutMs: subDownloadMs,
            subtitleUploadMaxBytes: subUploadMax,
            subtitleOffsetBucketMs: subOffsetBucket,
            langIndexMinSeen: langMinSeen,
            features: features,
            refreshIntervalHours: refreshHours)
    }

    /// Clamp an optional Int into [lo, hi], falling back to `fallback` when nil. `fallback` is assumed already
    /// in range (it is a shipping constant).
    private static func clamp(_ value: Int?, _ fallback: Int, _ lo: Int, _ hi: Int) -> Int {
        guard let value else { return fallback }
        return min(hi, max(lo, value))
    }

    /// Accept `raw` only if it parses as an https URL whose host ends with ".vortx.tv"; otherwise the baked
    /// default. Guards against a hijacked / malformed endpoint (highest blast radius). `fallback` is a trusted
    /// shipping literal, force-unwrapped safely.
    private static func validatedEndpoint(_ raw: String?, fallback: String) -> URL {
        let bakedURL = URL(string: fallback)!
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "vortx.tv" || host.hasSuffix(".vortx.tv") else { return bakedURL }
        return url
    }

    // MARK: Application Support cache (raw JSON bytes; UserDefaults holds only ETag + lastFetch).

    private static func cacheDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("RemoteConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheFile() -> URL? { cacheDirectory()?.appendingPathComponent("config.json") }

    /// Load the cached JSON, or nil when absent / unreadable / not valid JSON (corrupt => treated as absent).
    private static func loadCachedJSON() -> Data? {
        guard let file = cacheFile(), let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        // A corrupt cache must decode to nothing rather than crash bootstrap.
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        return data
    }

    /// Persist the raw JSON bytes to Application Support and the ETag to UserDefaults. Best-effort; a failed
    /// write just means the next launch re-fetches.
    private static func persist(json: Data, etag: String?) {
        if let file = cacheFile() { try? json.write(to: file, options: .atomic) }
        if let etag, !etag.isEmpty { UserDefaults.standard.set(etag, forKey: etagKey) }
    }
}

// MARK: - Spoiler blur: remote sets the fleet DEFAULT only; the user's explicit setting always wins.

/// Resolves the effective "blur unwatched episode thumbnails" value. Unlike the pure kill-switches above,
/// `features.spoilerBlur` only supplies the FLEET DEFAULT: if the user has explicitly toggled
/// `vortx.spoilerBlur` in Settings, that choice wins; otherwise the remote default; otherwise baked true.
/// The Settings `@AppStorage("vortx.spoilerBlur")` toggle stays the source of truth for the user's choice; the
/// read sites (the episode-thumbnail blur decision) call this resolver so the fleet default applies only when
/// the user has not overridden it.
enum SpoilerBlurSetting {
    static let key = "vortx.spoilerBlur"
    /// True when unwatched episode art should be blurred. User-explicit value wins; else remote fleet default;
    /// else baked true (identical to shipping when no remote config is present).
    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)   // explicit user choice wins
        }
        return RemoteConfig.snapshot.isFeatureOn("spoilerBlur", default: true)   // fleet default, baked true
    }
}
