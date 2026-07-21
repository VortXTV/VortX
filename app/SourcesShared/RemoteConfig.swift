import Foundation

/// VortX RemoteConfig: tune / kill / upgrade shipped app behavior from a backend JSON with NO app update.
///
/// DESIGN CONTRACT (why this is safe on hot paths and safe when the backend is gone):
///
///   1. EVERY accessor has a HARDCODED fallback equal to the current shipping value. Deleting this service,
///      or the remote field being null, is behaviorally identical to today. `RemoteConfigDefaults` holds one
///      named constant per wired dial; the accessors read the (already-resolved) value or that default.
///
///   2. Reads are SYNCHRONOUS and take one short, uncontended lock. Ranking runs per-stream over large lists and
///      the player reads at init, so a read must never hop through the actor. `RemoteConfig.snapshot` returns an
///      IMMUTABLE `ResolvedConfig` class instance while the same lock protects replacement. Readers see either
///      the old or the new fully-formed value; there is no torn state or ARC load/store race.
///
///   3. Clamp ONCE, at swap time. `validate(_:)` turns raw decoded JSON into a `ResolvedConfig` whose every
///      field is already range-clamped and defaults-filled. It can never brick the app or breach a jetsam
///      ceiling / ranking invariant.
///
///      PRECISELY WHAT HAPPENS TO A BAD VALUE, because this used to say "reverts to the baked default" and
///      that is not what the code does: an ABSENT (null / missing / wrong-typed) field falls back to the baked
///      default, and an OUT-OF-RANGE field is CLAMPED TO THE NEAREST EDGE of its range. Remote 0 for a knob
///      whose range is 1100...30000 resolves to 1100, not to the baked value (which here happens to also be
///      1100). The two readings coincide on the risk side for every knob in the Singularity block only
///      because each of those ranges deliberately puts the baked value ON the protective edge -- which is why
///      the wrong description survived review. They do NOT coincide in general, and a future knob whose baked
///      value sits mid-range would behave nothing like the old sentence claimed.
///
///   4. DEFAULTS DO NOT CHANGE. A field defaulting to null => baked default. `features.dvRemux` stays
///      effectively OFF unless the owner's user toggle (UserDefaults `stremiox.dvRemux`) or a remote value
///      turns it on; the user's EXPLICIT toggle always wins over the remote default (see PlayerEngineRouter).
///
///   5. FAIL-SOFT everywhere. Any fetch / decode / disk error keeps the last-good snapshot (or baked defaults);
///      nothing throws out of `bootstrap`/`refresh`. `master.remoteConfigEnabled == false` durably latches the
///      service off and installs baked behavior until a later valid fetched config explicitly re-enables it.
///      A corrupt cache is treated as absent => baked unless that durable disable latch is set.
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
    static let dvRemuxWindowMiB = 64         // Re-read floor, in MiB. MUST stay >= two full HLS segments
                                             // (2 x hlsMaxSegmentBytes = 2 x 32 MiB = 64), the worst-case
                                             // concurrent two-segment read skew. A floor below that can evict a
                                             // range still being served on an open connection: the reader's next
                                             // request falls below the window, the HLS connection is cut, and
                                             // AVPlayer demotes DV to HDR10. (It is NOT a startup guard;
                                             // producerLeadBytes supplies startup headroom independently.) 64 is
                                             // both the design minimum and the shipped value, so the clamp and
                                             // VortXRemuxBuffer.windowFloorMinMiB agree. Widening (never lowering)
                                             // is trialable on the fleet via the RemoteConfig dial without a build.

    // Timeouts (detail settle / debrid resolve). Present for future wiring; clamped in validate.
    static let detailSettleIOSSecs = 12
    static let detailSettleTVSecs = 12
    static let debridResolveSecs = 15

    // Trickplay capture params.
    static let captureIntervalSecs = 10      // ScrubThumbnails.captureInterval
    static let trickplayMinFrames = 1        // CommunityTrickplay lower bound (`sorted.count >= 1`)
    static let trickplayMaxFrames = 600      // CommunityTrickplay upper bound (`sorted.count <= 600`)
    static let trickplayMaxTiles = 80        // CommunityTrickplay per-sheet tile budget (3 MB-safe at 320x180/q0.7:
                                             // 80 tiles => ~2880x1620 with headroom); a longer watch is decimated
                                             // across the whole duration, not truncated. Any RemoteConfig override
                                             // up to the 400 clamp is made byte-safe by buildAndUpload's re-decimation.

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

    // Singularity source-pool upload/rate tunables (clamped in validate). Baked == the shipping literals in
    // SourceIndexClient, so an absent or garbage `sourceIndex` block is behaviorally identical to today.
    //
    // ONE RULE governs this whole block: remote config may make Singularity quieter, slower, or smaller without
    // a build; it may never make it louder, faster, or larger than the value the app shipped with, and it may
    // never touch a bound whose job is rejecting bad input. Nothing that gates admission or validates a response
    // is wired here: SourceIndexContract's minimumServedCorroboration, maxServedSources, maxSeeders and
    // maxSafeSizeBytes stay compile-time constants precisely because a remote value could only weaken them.
    static let sourceIndexInterBatchDelayMs = 1100        // SourceIndexClient.interBatchDelayMs
    // Descriptors per POST. PINNED, NOT A REMOTE DIAL. See the note in `validate` for the derivation that
    // removed it: lowering this raises both the request count and the total D1 work, so as an emergency
    // control it amplifies the incident it exists to contain.
    static let sourceIndexBatchSize = 16                  // SourceIndexClient.batchSize == worker MAX_SOURCES_PER_CONTRIBUTE
    static let sourceIndexMaxDescriptorsPerTitle = 2000   // SourceIndexClient.maxDescriptorsPerTitle
    static let sourceIndexResumeHoardMaxWaitMs = 5000     // hoardResumedGroups(maxWaitMs:) default
    static let sourceIndexResumeHoardPollIntervalMs = 250 // hoardResumedGroups(pollIntervalMs:) default
    // The CAP is a constant guard, not a mirror of a shipping literal: the resume poll count is
    // maxWaitMs / pollIntervalMs, so two individually in-range remote values can multiply into far more
    // MainActor polling during playback start than either looks like it buys. The cap trims that product.
    static let sourceIndexResumeHoardAttemptCap = 60
    static let sourceIndexRequestTimeoutSecs = 8          // SourceIndexClient POST + GET timeoutInterval

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
        let dvRemuxHLS: Bool?   // b166: local-HLS delivery of the DV remux (kill-switch back to the loader path)
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
        let maxTiles: Int?
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
    /// Singularity upload/rate tunables. Every field optional and backward-compatible: a config with no
    /// `sourceIndex` block decodes fine and every value falls back to its baked default. No admission or
    /// response-validation bound appears here by design; see `RemoteConfigDefaults` for why.
    struct SourceIndex: Decodable {
        let interBatchDelayMs: Int?
        // `batchSize` DELIBERATELY ABSENT. It was a remote dial and was removed; see validate for the
        // derivation. A config that still carries the key decodes fine and the key is ignored, which is the
        // intended migration path (the field is pinned at RemoteConfigDefaults.sourceIndexBatchSize).
        let maxDescriptorsPerTitle: Int?
        let resumeHoardMaxWaitMs: Int?
        let resumeHoardPollIntervalMs: Int?
        let requestTimeoutSecs: Int?
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
    let sourceIndex: SourceIndex?
    let skipProvider: String?
    let schemaVersion: Int?
    let configRevision: String?   // opaque ISO string (e.g. "2026-07-01T00:00:00Z"); NOT an Int. A wrong
                                  // type here would throw typeMismatch and fail the whole decode => the
                                  // entire remote config would silently never apply. Keep this a String.
    let minAppBuild: Int?
    let refreshIntervalHours: Int?
}

// MARK: - Resolved, already-clamped, defaults-filled snapshot (immutable; read under a short lock).

/// A `final class` so `RemoteConfig.snapshot` can replace one immutable reference while holding its lock. Every
/// stored value is ALREADY clamped and defaults-filled by `validate`, so accessors are trivial reads. Never
/// mutated after construction.
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
    let trickplayMaxTiles: Int

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

    // Singularity upload/rate tunables, clamped one-directionally (see validate for which side is the risk side).
    let sourceIndexInterBatchDelayMs: Int
    let sourceIndexBatchSize: Int
    let sourceIndexMaxDescriptorsPerTitle: Int
    let sourceIndexResumeHoardMaxWaitMs: Int
    let sourceIndexResumeHoardPollIntervalMs: Int
    /// The CONSTANT ceiling on resume poll attempts. Never derived from the two values above; it exists to
    /// trim their product. Read by the client, which is handed caller-supplied wait/interval values and so
    /// must apply the cap itself rather than trust a precomputed count.
    let sourceIndexResumeHoardAttemptCap: Int
    let sourceIndexRequestTimeoutSecs: Int

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
         trickplayMaxTiles: Int,
         trickplayEndpoint: URL,
         catalogsEndpoint: URL,
         subtitlesEndpoint: URL,
         sourcesEndpoint: URL,
         subtitleDownloadTimeoutMs: Int,
         subtitleUploadMaxBytes: Int,
         subtitleOffsetBucketMs: Int,
         langIndexMinSeen: Int,
         sourceIndexInterBatchDelayMs: Int,
         sourceIndexBatchSize: Int,
         sourceIndexMaxDescriptorsPerTitle: Int,
         sourceIndexResumeHoardMaxWaitMs: Int,
         sourceIndexResumeHoardPollIntervalMs: Int,
         sourceIndexResumeHoardAttemptCap: Int,
         sourceIndexRequestTimeoutSecs: Int,
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
        self.trickplayMaxTiles = trickplayMaxTiles
        self.trickplayEndpoint = trickplayEndpoint
        self.catalogsEndpoint = catalogsEndpoint
        self.subtitlesEndpoint = subtitlesEndpoint
        self.sourcesEndpoint = sourcesEndpoint
        self.subtitleDownloadTimeoutMs = subtitleDownloadTimeoutMs
        self.subtitleUploadMaxBytes = subtitleUploadMaxBytes
        self.subtitleOffsetBucketMs = subtitleOffsetBucketMs
        self.langIndexMinSeen = langIndexMinSeen
        self.sourceIndexInterBatchDelayMs = sourceIndexInterBatchDelayMs
        self.sourceIndexBatchSize = sourceIndexBatchSize
        self.sourceIndexMaxDescriptorsPerTitle = sourceIndexMaxDescriptorsPerTitle
        self.sourceIndexResumeHoardMaxWaitMs = sourceIndexResumeHoardMaxWaitMs
        self.sourceIndexResumeHoardPollIntervalMs = sourceIndexResumeHoardPollIntervalMs
        self.sourceIndexResumeHoardAttemptCap = sourceIndexResumeHoardAttemptCap
        self.sourceIndexRequestTimeoutSecs = sourceIndexRequestTimeoutSecs
        self.features = features
        self.refreshIntervalHours = refreshIntervalHours
    }

    /// The all-baked enabled snapshot: identical to shipping when no cached or fetched config exists.
    static var baked: ResolvedConfig { makeBaked(remoteConfigEnabled: true) }

    /// Baked behavior with the durable remote master-disable state represented explicitly.
    static var masterDisabled: ResolvedConfig { makeBaked(remoteConfigEnabled: false) }

    private static func makeBaked(remoteConfigEnabled: Bool) -> ResolvedConfig {
        ResolvedConfig(
            remoteConfigEnabled: remoteConfigEnabled,
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
            trickplayMaxTiles: RemoteConfigDefaults.trickplayMaxTiles,
            trickplayEndpoint: URL(string: RemoteConfigDefaults.endpointTrickplay)!,
            catalogsEndpoint: URL(string: RemoteConfigDefaults.endpointCatalogs)!,
            subtitlesEndpoint: URL(string: RemoteConfigDefaults.endpointSubtitles)!,
            sourcesEndpoint: URL(string: RemoteConfigDefaults.endpointSources)!,
            subtitleDownloadTimeoutMs: RemoteConfigDefaults.subtitleDownloadTimeoutMs,
            subtitleUploadMaxBytes: RemoteConfigDefaults.subtitleUploadMaxBytes,
            subtitleOffsetBucketMs: RemoteConfigDefaults.subtitleOffsetBucketMs,
            langIndexMinSeen: RemoteConfigDefaults.langIndexMinSeen,
            sourceIndexInterBatchDelayMs: RemoteConfigDefaults.sourceIndexInterBatchDelayMs,
            sourceIndexBatchSize: RemoteConfigDefaults.sourceIndexBatchSize,
            sourceIndexMaxDescriptorsPerTitle: RemoteConfigDefaults.sourceIndexMaxDescriptorsPerTitle,
            sourceIndexResumeHoardMaxWaitMs: RemoteConfigDefaults.sourceIndexResumeHoardMaxWaitMs,
            sourceIndexResumeHoardPollIntervalMs: RemoteConfigDefaults.sourceIndexResumeHoardPollIntervalMs,
            sourceIndexResumeHoardAttemptCap: RemoteConfigDefaults.sourceIndexResumeHoardAttemptCap,
            sourceIndexRequestTimeoutSecs: RemoteConfigDefaults.sourceIndexRequestTimeoutSecs,
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

    /// Trickplay per-sheet tile budget (baked 80). A watch with more captured frames than this is decimated
    /// evenly across its whole duration into one sheet, so a long film uploads coarse full-span previews
    /// instead of failing the 3 MB sheet cap.
    var trickplayMaxTilesValue: Int { trickplayMaxTiles }

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

    /// Singularity per-request budget as a `TimeInterval` (seconds); baked 8 s. Shared by the contribute POST and
    /// the serve GET so one dial cannot pace the two verbs apart.
    var sourceIndexRequestTimeout: TimeInterval { TimeInterval(sourceIndexRequestTimeoutSecs) }

    /// Tri-state feature read: remote true/false wins; remote null (absent) => the call site's baked default.
    func isFeatureOn(_ key: String, default fallback: Bool) -> Bool {
        features[key] ?? fallback
    }
}

// MARK: - The actor: fetch / validate / persist. Reads never go through here.

actor RemoteConfig {
    static let shared = RemoteConfig()
    static let sourceIndexFeatureDidInstall = Notification.Name("vortx.remoteConfig.sourceIndexDidInstall")
    static let sourceIndexOldValueKey = "oldSourceIndexEnabled"
    static let sourceIndexNewValueKey = "newSourceIndexEnabled"

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
    private struct SourceIndexInstallEvent {
        let oldValue: Bool
        let newValue: Bool
        let transition: SourceIndexLifecycleTransition?
    }

    /// Atomically replace the snapshot, then synchronously retire the old Source Index generation on this
    /// installing thread. The later MainActor notification only clears UI state; stale work is fenced now.
    private static func install(_ resolved: ResolvedConfig) -> SourceIndexInstallEvent {
        snapshotLock.lock()
        let oldValue = _snapshot.isFeatureOn(
            "sourceIndex", default: RemoteConfigDefaults.featureSourceIndex
        )
        let newValue = resolved.isFeatureOn(
            "sourceIndex", default: RemoteConfigDefaults.featureSourceIndex
        )
        _snapshot = resolved
        snapshotLock.unlock()
        let transition = oldValue && !newValue ? SourceIndexLifecycleClock.closeSource() : nil
        return SourceIndexInstallEvent(oldValue: oldValue, newValue: newValue, transition: transition)
    }

    private func installAndAnnounce(_ resolved: ResolvedConfig) async {
        let event = Self.install(resolved)
        await MainActor.run {
            NotificationCenter.default.post(
                name: Self.sourceIndexFeatureDidInstall,
                object: event.transition,
                userInfo: [
                    Self.sourceIndexOldValueKey: event.oldValue,
                    Self.sourceIndexNewValueKey: event.newValue,
                ]
            )
        }
    }

    // Networking.
    private static let configURL = URL(string: "https://config.vortx.tv/v1/config.json")!
    private static let fetchTimeout: TimeInterval = 8
    private static let etagKey = "vortx.remoteConfig.etag"
    /// The ETag known to have been written only after the matching cache body. Existing installs have no
    /// marker, so their first refresh is unconditional and repairs any pre-fix partial commit.
    private static let bodyETagKey = "vortx.remoteConfig.bodyETag"
    private static let lastFetchKey = "vortx.remoteConfig.lastFetchEpoch"
    private static let masterDisabledKey = "vortx.remoteConfig.masterDisabled"
    private static let maximumCachedBodyBytes = 1_048_576
    private static let foregroundThrottle: TimeInterval = 30 * 60   // once / 30 min for a foreground refresh

    private let defaults: UserDefaults
    private let cacheDirectoryOverride: URL?
    private let session: URLSession

    /// The raw last-good JSON currently installed (nil = none / baked). Kept so `304 Not Modified` is a
    /// genuine no-op and a foreground refresh does not need to re-decode.
    private var currentRaw: Data?
    private var periodicStarted = false
    private var refreshInFlight = false
    private var refreshPending = false

    init(defaults: UserDefaults = .standard,
         cacheDirectory: URL? = nil,
         session: URLSession = .shared) {
        self.defaults = defaults
        cacheDirectoryOverride = cacheDirectory
        self.session = session
    }

    // MARK: Bootstrap (call once at launch).

    /// (1) Synchronously load the last-good cached JSON from Application Support and build the snapshot (else
    /// all-baked). (2) Kick a background refresh. Never throws.
    func bootstrap() async {
        if defaults.bool(forKey: Self.masterDisabledKey) {
            // The explicit latch wins over cached bytes. This is deliberately stronger than trusting config.json:
            // a stale enabled cache must never resurrect remote behavior after an incident disable.
            currentRaw = nil
            await installAndAnnounce(.masterDisabled)
        } else if let cached = loadCachedJSON(),
                  let decoded = try? JSONDecoder().decode(RemoteConfigData.self, from: cached) {
            currentRaw = cached
            if decoded.master?.remoteConfigEnabled == false {
                // Backward/crash recovery: a disabling cache is authoritative even if its UserDefaults latch
                // was not committed. Restore the latch before exposing the disabled snapshot.
                defaults.set(true, forKey: Self.masterDisabledKey)
                await installAndAnnounce(.masterDisabled)
            } else {
                await installAndAnnounce(Self.validate(decoded))   // clamp once at swap time
            }
        } else {
            currentRaw = nil
            await installAndAnnounce(.baked)
        }
        startPeriodicIfNeeded()
        Task { await refresh() }
    }

    // MARK: Refresh.

    /// GET the config conditionally only when a readable decoded cache, its body binding, and its ETag agree,
    /// and no durable master disable is set. A latched or incoherent state forces a full body so 304 cannot
    /// preserve a partial commit. 200 applies the ordered durable transitions below. Any error keeps last-good.
    func refresh() async {
        if refreshInFlight {
            refreshPending = true
            return
        }

        refreshInFlight = true
        while true {
            refreshPending = false
            await performRefresh()
            if !refreshPending {
                // No suspension is allowed between this final pending check and clearing the owner flag. An
                // overlapping caller must either set refreshPending before the check or become the next owner.
                refreshInFlight = false
                return
            }
        }
    }

    private func performRefresh() async {
        var req = URLRequest(url: Self.configURL, timeoutInterval: Self.fetchTimeout)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "accept")
        let requestETag = coherentRequestETag()
        if let requestETag {
            req.setValue(requestETag, forHTTPHeaderField: "If-None-Match")
        }
        // Sign with the shared edge-auth helper (config.vortx.tv is a gated host). No-op without a secret;
        // the worker's observe mode lets an empty-key / unsigned request through, so a fetch never bricks.
        VortXEdgeAuth.sign(&req)

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return }   // keep last-good
            if http.statusCode == 304 {
                // A conditional 304 is a successful "still fresh" fetch, so stamp the fetch time too: otherwise
                // refreshIfForegroundDue never sees a recent lastFetch in the steady state (the config rarely
                // changes, so every foreground refresh 304s), the 30-minute throttle never engages, and we
                // re-hit the network on every scene activation. An unexpected 304 on an unconditional repair
                // request is not freshness evidence and must not throttle the next repair attempt.
                guard let requestETag, coherentRequestETag() == requestETag else { return }
                defaults.set(Date().timeIntervalSince1970, forKey: Self.lastFetchKey)
                return
            }
            guard http.statusCode == 200 else { return }                // any other status: keep last-good
            // Apply the same bound used by bootstrap before decoding or committing any response state. This
            // must precede the disable latch too: an oversized body is not an authoritative config update.
            guard Self.isAcceptableCacheBody(data) else { return }

            let decoded = try JSONDecoder().decode(RemoteConfigData.self, from: data)

            let responseETag = http.value(forHTTPHeaderField: "Etag")

            // False is safety-first. Commit the latch before any fallible body write. If persistence fails or
            // the process dies at any later point, bootstrap still installs disabled behavior and forces a full
            // repair fetch. The validator is committed only after its matching body and binding are durable.
            if decoded.master?.remoteConfigEnabled == false {
                defaults.set(true, forKey: Self.masterDisabledKey)
                if persistBody(json: data, etag: responseETag) {
                    currentRaw = data
                    persistETag(responseETag)
                    defaults.set(Date().timeIntervalSince1970, forKey: Self.lastFetchKey)
                }
                await installAndAnnounce(.masterDisabled)
                return
            }

            if defaults.bool(forKey: Self.masterDisabledKey),
               decoded.master?.remoteConfigEnabled != true {
                // Missing and null mean "use the baked default" only before a durable incident latch exists.
                // Once disabled, omission is not authority to re-enable. Persist its body before advancing the
                // bound validator, but keep both the latch and disabled snapshot until an explicit true arrives.
                if persistBody(json: data, etag: responseETag) {
                    currentRaw = data
                    persistETag(responseETag)
                    defaults.set(Date().timeIntervalSince1970, forKey: Self.lastFetchKey)
                }
                await installAndAnnounce(.masterDisabled)
                return
            }

            let resolved = Self.validate(decoded)
            // Enabled installs, including an explicit re-enable, require a durable body first. The binding is
            // written after the body, then an old disable latch is cleared, then the request validator commits
            // last. Any crash between those points leaves either a latch or a BV/V mismatch, both of which
            // force an unconditional repair. A failed body write changes no durable metadata or memory state.
            guard persistBody(json: data, etag: responseETag) else { return }
            currentRaw = data
            if decoded.master?.remoteConfigEnabled == true {
                defaults.removeObject(forKey: Self.masterDisabledKey)
            }
            persistETag(responseETag)
            defaults.set(Date().timeIntervalSince1970, forKey: Self.lastFetchKey)
            await installAndAnnounce(resolved)       // locked replace; readers see old-or-new, never torn
        } catch {
            // Timeout / offline / decode failure: keep last-good. Never throw.
            return
        }
    }

    /// Foreground refresh, throttled to at most once per 30 minutes. Safe to call on every `.active` scene
    /// phase; it cheaply no-ops when the last fetch is recent.
    func refreshIfForegroundDue() async {
        let last = defaults.double(forKey: Self.lastFetchKey)
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

    /// Turn raw decoded JSON into a fully clamped, defaults-filled `ResolvedConfig`. Missing fields fall back
    /// to baked defaults, numeric values clamp to their nearest range edge, and invalid endpoints fall back to
    /// baked URLs, so the result is always safe to read on a hot path. `master.rankingConfigEnabled == false`
    /// short-circuits ranking sections to baked (ranking dials are not wired yet, but the gate is honored so a
    /// future wiring degrades correctly).
    static func validate(_ data: RemoteConfigData) -> ResolvedConfig {
        let remoteEnabled = data.master?.remoteConfigEnabled ?? true
        let rankingEnabled = data.master?.rankingConfigEnabled ?? true

        // --- Player read-ahead ceilings (THE jetsam knob). Clamp, then raise anything below the floor. ---
        let floor = clamp(data.player?.readAhead?.offFloorMiB, RemoteConfigDefaults.offFloorMiB, 64, 64)   // fixed 64
        let debrid = max(floor, clamp(data.player?.readAhead?.debridCeilingMiB, RemoteConfigDefaults.debridCeilingMiB, 64, 900))
        let reduced = max(floor, clamp(data.player?.readAhead?.reducedCeilingMiB, RemoteConfigDefaults.reducedCeilingMiB, 64, 192))
        let mac = max(floor, clamp(data.player?.readAhead?.macCeilingMiB, RemoteConfigDefaults.macCeilingMiB, 128, 1536))
        let vodSecs = clamp(data.player?.vodReadaheadSecs, RemoteConfigDefaults.vodReadaheadSecs, 30, 600)
        // DV-remux buffer window floor: keep at least 64 MiB (two full HLS segments, matching
        // VortXRemuxBuffer.windowFloorMinMiB) and cap at 512 MiB. The lower bound is the design invariant, not a
        // convenience: a floor below the two-segment skew can evict a range still being served on an open
        // connection (reader request drops below storageBase -> HLS connection cut -> AVPlayer demotes DV to
        // HDR10). It is NOT a startup-starvation guard; producerLeadBytes supplies the startup headroom
        // independently. The upper cap keeps a widened re-read floor from approaching the whole-movie RAM this
        // window replaced.
        let dvWindow = clamp(data.player?.readAhead?.dvRemuxWindowMiB, RemoteConfigDefaults.dvRemuxWindowMiB, 64, 512)

        // --- Timeouts. ---
        let settleIOS = clamp(data.timeouts?.detailSettleIOSSecs, RemoteConfigDefaults.detailSettleIOSSecs, 5, 60)
        let settleTV = clamp(data.timeouts?.detailSettleTVSecs, RemoteConfigDefaults.detailSettleTVSecs, 5, 60)
        let debridResolve = clamp(data.timeouts?.debridResolveSecs, RemoteConfigDefaults.debridResolveSecs, 5, 30)

        // --- Trickplay params. ---
        let capture = clamp(data.trickplay?.captureIntervalSecs, RemoteConfigDefaults.captureIntervalSecs, 2, 60)
        let minFrames = clamp(data.trickplay?.minFrames, RemoteConfigDefaults.trickplayMinFrames, 1, 10)
        let maxFrames = clamp(data.trickplay?.maxFrames, RemoteConfigDefaults.trickplayMaxFrames, 30, 600)
        let maxTiles = clamp(data.trickplay?.maxTiles, RemoteConfigDefaults.trickplayMaxTiles, 30, 400)

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

        // --- Singularity upload/rate tunables. Each range is deliberately one-directional: the endpoint on a
        //     knob's RISK side equals the protective value, so no in-range remote value can push the client past
        //     a bound it already relies on. The two reviews differed on three of these bounds and the SAFER
        //     bound is taken below, named at each site.
        //
        // Pacing floor between contribute POSTs. Risk side is DOWN: a shorter delay multiplies POSTs per minute
        // against the worker's 240/minute per-IP budget, which several devices behind one NAT already share. The
        // safer of the two proposed floors is taken: 1100 (the baked value) rather than 500, making this knob
        // slow-only. That loses nothing, because the operator need this dial exists for is throttling the fleet
        // DOWN during a D1 incident; going faster than the shipped cadence was never the point. The 30 s ceiling
        // bounds that throttle so the batch loop stalls but never halts.
        let siDelayMs = clamp(data.sourceIndex?.interBatchDelayMs,
                              RemoteConfigDefaults.sourceIndexInterBatchDelayMs, 1100, 30000)
        // Descriptors per POST: PINNED at the baked 16, NOT remotely tunable. It was a dial with a 1...16
        // clamp, and the justification given for keeping it ("16 sources cost 49 D1 statements against the
        // 50-query invocation limit, so 8 halves that") is wrong about the quantity that matters.
        //
        // THE DERIVATION, so the next reader can check this rather than trust it. The worker's documented cost
        // is `3 * sources + 1` D1 operations per request (three statements per source plus one retention
        // prune). With the per-title cap at 2000 descriptors:
        //
        //     batch 16 -> ceil(2000/16) = 125 POSTs, 125 * (3*16 + 1) = 6125 D1 ops
        //     batch  8 -> ceil(2000/ 8) = 250 POSTs, 250 * (3* 8 + 1) = 6250 D1 ops
        //     batch  1 ->      2000      POSTs, 2000 * (3* 1 + 1) = 8000 D1 ops
        //
        // Lowering the dial RAISES the request count AND the total work, because the per-request `+1` prune is
        // paid once per POST no matter how few sources it carries. Only the PER-INVOCATION statement count
        // falls, and that is not the resource an incident exhausts. So the emergency control amplifies the
        // incident it exists to contain, which violates this block's own governing rule (remote config may
        // make Singularity quieter, slower or smaller, never louder, faster or larger).
        //
        // The dial that genuinely sheds load is `maxDescriptorsPerTitle` (fewer POSTs and less work, in the
        // same direction), and the kill switch is the `sourceIndex` feature flag. Both remain.
        //
        // 16 is also the worker's MAX_SOURCES_PER_CONTRIBUTE: a POST above it is rejected whole, so the value
        // has a hard ceiling at exactly the point it is pinned.
        let siBatchSize = RemoteConfigDefaults.sourceIndexBatchSize
        // Per-title descriptor cap. DOWN-ONLY: raising it only ever buys more background POSTs, and at 16 per
        // POST the baked 2000 is already up to 125 of them holding the process-wide pacer. The floor keeps one
        // full batch, so no remote value can silently zero out contribution by this path; the reviewed kill
        // switch for that is the `sourceIndex` feature flag, which has a real lifecycle retirement.
        let siPerTitle = clamp(data.sourceIndex?.maxDescriptorsPerTitle,
                               RemoteConfigDefaults.sourceIndexMaxDescriptorsPerTitle, 16, 2000)
        // Resume-hoard poll budget. NAMED EXCEPTION to this block's "never louder than shipping" rule, stated
        // here rather than left hidden under the universal wording, because it is the only knob in the block
        // that can raise client work above the shipped value.
        //
        // THE EXCEPTION, and its exact bound. Shipping polls 20 attempts over ~5 s (5000 / 250). This ceiling
        // permits 20000 ms, which at the pinned 250 ms floor is 80 attempts; the client applies the separate
        // 60-attempt constant cap at the polling loop, limiting the remote expansion to ~15 s. Nothing here can
        // run unbounded and nothing here weakens an admission or validation bound.
        //
        // WHY IT IS WORTH THAT. The Continue Watching resume path plays a stored source WITHOUT opening the
        // detail view, so when meta settles slower than the budget on a cold network the most common playback
        // population contributes nothing at all, and there is no other backend lever for it. This is an
        // AVAILABILITY exception, deliberately taken, not an oversight in the rule.
        let siResumeWaitMs = clamp(data.sourceIndex?.resumeHoardMaxWaitMs,
                                   RemoteConfigDefaults.sourceIndexResumeHoardMaxWaitMs, 250, 20000)
        // Resume-hoard poll interval. Risk side is DOWN: each attempt resolves groups on the MainActor during
        // playback start, the one place this otherwise cold feature brushes a hot path. Safer floor taken again:
        // 250 (the baked value) rather than 100, so the interval is lengthen-only.
        let siResumePollMs = clamp(data.sourceIndex?.resumeHoardPollIntervalMs,
                                   RemoteConfigDefaults.sourceIndexResumeHoardPollIntervalMs, 250, 2000)
        // Per-request budget, shared by the contribute POST and the serve GET. Availability lever, not a security
        // one: every timeout path is already a silent no-op. Safer ceiling taken: 8 (the baked value) rather than
        // 20, making it shorten-only, since a timeout longer than the pacing interval lets attempts stack against
        // the same worker a slowdown is already straining. The 3 s floor keeps a normal mobile round trip alive.
        let siTimeoutSecs = clamp(data.sourceIndex?.requestTimeoutSecs,
                                  RemoteConfigDefaults.sourceIndexRequestTimeoutSecs, 3, 8)

        // --- Refresh cadence. ---
        let refreshHours = clamp(data.refreshIntervalHours, RemoteConfigDefaults.refreshIntervalHours, 1, 24)

        // --- Feature tri-state map (only present, boolean-valued keys are stored; null / non-bool => absent
        //     => the call site's baked default is used at read time). ---
        var features: [String: Bool] = [:]
        if let f = data.features {
            func put(_ key: String, _ value: Bool?) { if let value { features[key] = value } }
            put("communityTrickplay", f.communityTrickplay)
            put("dvRemux", f.dvRemux)
            put("dvRemuxHLS", f.dvRemuxHLS)
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
            trickplayMaxTiles: maxTiles,
            trickplayEndpoint: trickplayURL,
            catalogsEndpoint: catalogsURL,
            subtitlesEndpoint: subtitlesURL,
            sourcesEndpoint: sourcesURL,
            subtitleDownloadTimeoutMs: subDownloadMs,
            subtitleUploadMaxBytes: subUploadMax,
            subtitleOffsetBucketMs: subOffsetBucket,
            langIndexMinSeen: langMinSeen,
            sourceIndexInterBatchDelayMs: siDelayMs,
            sourceIndexBatchSize: siBatchSize,
            sourceIndexMaxDescriptorsPerTitle: siPerTitle,
            sourceIndexResumeHoardMaxWaitMs: siResumeWaitMs,
            sourceIndexResumeHoardPollIntervalMs: siResumePollMs,
            sourceIndexResumeHoardAttemptCap: RemoteConfigDefaults.sourceIndexResumeHoardAttemptCap,
            sourceIndexRequestTimeoutSecs: siTimeoutSecs,
            features: features,
            refreshIntervalHours: refreshHours)
    }

    /// Clamp an optional Int into [lo, hi], falling back to `fallback` when nil. `fallback` is assumed already
    /// in range (it is a shipping constant).
    /// ABSENT -> `fallback` (the baked default). PRESENT BUT OUT OF RANGE -> the nearest edge, `lo` or `hi`,
    /// NOT the fallback. Both behaviours are intended; they are spelled out here because the file's design
    /// contract used to describe only the first and claim it covered the second.
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

    // MARK: Application Support cache (raw JSON; UserDefaults holds body binding, ETag, fetch time, and latch).

    private func cacheDirectory() -> URL? {
        if let cacheDirectoryOverride {
            try? FileManager.default.createDirectory(at: cacheDirectoryOverride, withIntermediateDirectories: true)
            return cacheDirectoryOverride
        }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("RemoteConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cacheFile() -> URL? { cacheDirectory()?.appendingPathComponent("config.json") }

    /// Load bounded cached JSON, or nil when absent, unreadable, oversized, or not valid JSON.
    private func loadCachedJSON() -> Data? {
        guard let data = readBoundedCache(), !data.isEmpty else { return nil }
        // A corrupt cache must decode to nothing rather than crash bootstrap.
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        return data
    }

    /// The validator this actor may send. Durable bytes must still exist, decode, and exactly match the installed
    /// raw body. The latch must be clear, and the nonempty request and body validators must name the same body.
    private func coherentRequestETag() -> String? {
        guard !defaults.bool(forKey: Self.masterDisabledKey),
              let etag = defaults.string(forKey: Self.etagKey), !etag.isEmpty,
              let bodyETag = defaults.string(forKey: Self.bodyETagKey), !bodyETag.isEmpty,
              bodyETag == etag,
              let currentRaw,
              let durableRaw = readBoundedCache(), durableRaw == currentRaw,
              (try? JSONDecoder().decode(RemoteConfigData.self, from: durableRaw)) != nil else { return nil }
        return etag
    }

    /// Read at most one byte beyond the cache limit, so an oversized or changing file cannot allocate without
    /// bound. The caller still validates both schema and byte identity before trusting these bytes.
    private func readBoundedCache() -> Data? {
        guard let file = cacheFile(), let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        var data = Data()
        do {
            while data.count <= Self.maximumCachedBodyBytes {
                let remaining = Self.maximumCachedBodyBytes + 1 - data.count
                guard remaining > 0,
                      let chunk = try handle.read(upToCount: min(64 * 1024, remaining)),
                      !chunk.isEmpty else { break }
                data.append(chunk)
            }
        } catch {
            return nil
        }
        guard Self.isAcceptableCacheBody(data) else { return nil }
        return data
    }

    private static func isAcceptableCacheBody(_ data: Data) -> Bool {
        !data.isEmpty && data.count <= maximumCachedBodyBytes
    }

    /// Atomically persist the raw body, then record which ETag was bound after that successful write. The
    /// request validator itself is deliberately not changed here; each transition commits it last.
    private func persistBody(json: Data, etag: String?) -> Bool {
        guard Self.isAcceptableCacheBody(json) else { return false }
        guard let file = cacheFile() else { return false }
        do {
            try json.write(to: file, options: .atomic)
        } catch {
            return false
        }
        persistBodyETag(etag)
        return true
    }

    private func persistBodyETag(_ etag: String?) {
        if let etag, !etag.isEmpty {
            defaults.set(etag, forKey: Self.bodyETagKey)
        } else {
            defaults.removeObject(forKey: Self.bodyETagKey)
        }
    }

    private func persistETag(_ etag: String?) {
        if let etag, !etag.isEmpty {
            defaults.set(etag, forKey: Self.etagKey)
        } else {
            defaults.removeObject(forKey: Self.etagKey)
        }
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
