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
///   4. DEFAULTS DO NOT CHANGE. A field defaulting to null => baked default. For `features.dvRemux` the baked
///      default is NOT "off": with no remote value and no user toggle the lane is ON wherever the display can
///      actually present Dolby Vision (`PlayerEngineRouter.dvRemuxEnabled`, the DV mandate), and OFF only on a
///      display that cannot show DV. This description used to say the lane stayed "effectively OFF" by default,
///      which is what a Settings row was written against; the row then reported Off on a virgin device while
///      true DV was playing. The resolution order is: the user's EXPLICIT toggle (UserDefaults
///      `stremiox.dvRemux`) wins over everything, else a PRESENT remote value is the fleet kill-switch, else
///      the display-capability baked default. An explicit "Prefer AVPlayer" pick also engages the lane on a
///      DV-capable display regardless of the toggle (`dvRemuxEngaged`).
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
    static let debridCeilingMiB = 256        // non-reduced iOS/tvOS hard ceiling; diag 12 measured 1.2 GB RSS at 768 MiB
    static let reducedCeilingMiB = 128       // Apple TV HD (PerformanceMode.reduced) ceiling (was `128 * 1024 * 1024`)
    static let macCeilingMiB = 1024          // macOS ceiling (was `1_024 * 1024 * 1024`)
    static let offFloorMiB = 64              // hard floor: no ceiling may drop below this
    // tvOS forward-buffer dials (the "smoother Apple TV playback" fix). The client scales the floor DOWN on
    // PerformanceMode.reduced (the 2 GB Apple TV HD); the reduced remote read-ahead itself stays the shipped
    // 96 MiB. All four are jetsam-bounded in `validate`: floor and baseline never below the hard-min, ceiling
    // never past 448 MiB so the in-RAM cap stays under the ~700 MiB wall the field logs proved fatal on 4K.
    static let tvosReadAheadBaselineMiB = 384   // tvOS NORMAL remote-VOD load cap (demuxer-max-bytes). Was 128.
                                                // 384 is the RAM-safe max: at the field-min 712 MiB free it
                                                // leaves ~456 MiB headroom, still above the ~384 MiB pressure
                                                // threshold and well under the ~700 MiB fatal wall. Bigger
                                                // buffers need disk-offload, a separate track. Equal to the
                                                // ceiling below (baseline == ceiling is intentional here).
    static let tvosReadAheadFloorMiB = 192      // NORMAL-tier shed floor: a warning/clamp never drops below this
    static let tvosReadAheadHardMinMiB = 150    // absolute never-below for the NORMAL tier
    static let tvosReadAheadCeilingMiB = 384    // upper bound on the tvOS RAM cap (stays under the ~700 MiB wall)
    static let vodReadaheadSecs = 300        // demuxer-readahead-secs for VOD (configureLiveMode else-branch)
    static let dvRemuxWindowMiB = 64         // Re-read floor, in MiB. THE 64 IS EMPIRICAL, not derived.
                                             // It used to be justified here as "2 x hlsMaxSegmentBytes = 2 x 32
                                             // MiB", the worst-case concurrent two-segment read skew. That
                                             // derivation is dead: there is no `hlsMaxSegmentBytes` anywhere in
                                             // the app any more, and VortXRemuxBuffer calls 32 MiB "the retired
                                             // 32 MiB threshold" (VortXRemuxBuffer.swift:318-323) because legal
                                             // GOPs may exceed it, so the window is not a segment multiple at all.
                                             // The eviction-under-an-open-response hazard the old text described
                                             // is now held by ACTIVE READ LEASES (VortXRemuxBuffer.activeReadRanges),
                                             // which block eviction beneath any in-flight response independently
                                             // of this floor. What the floor still buys is keeping ordinary
                                             // near-frontier re-reads from churning. (It is NOT a startup guard;
                                             // producerLeadBytes supplies startup headroom independently.) 64 is
                                             // simply the shipped value, and VortXRemuxBuffer.windowFloorMinMiB is
                                             // the same 64, so the clamp is a fleet no-op today. Widening (never
                                             // lowering) is trialable on the fleet via the RemoteConfig dial
                                             // without a build.

    // On-disk Streaming Cache knobs (DiskCacheSetting + MPVMetalViewController.loadFile). Baked == the
    // shipping-safe literals, so an absent / garbage `player` block is behaviorally identical to today.
    static let diskCacheMetadataCapMiB = 128 // `demuxer-max-bytes` applied when `cache-on-disk` is ARMED. Under
                                             // working offload mpv frees each forward packet's payload to the
                                             // cache dir and keeps only a file offset, so this bounds packet
                                             // METADATA (~50 MB per hour of media), NOT payload. It is therefore
                                             // modest by design and may sit BELOW the RAM read-ahead baseline
                                             // (metadata is cheap). It is ALSO the RAM-payload guardrail on the
                                             // silent RAM-fallback path (dir not writable): 128 MiB is the
                                             // shipping-safe tvOS payload cap.
    static let diskCacheReadaheadSecs = 900  // `cache-secs` (15 min) applied when `cache-on-disk` is armed: the
                                             // REAL forward-depth lever once payloads live on disk, because
                                             // demuxer-max-bytes no longer binds. The full 15-min depth is kept
                                             // on purpose (deep seek-ahead protection); the frame-drops-while-
                                             // filling are addressed by PACING the fill (see cacheReadaheadRampSecs
                                             // + the read-rate cap in MPVMetalViewController) rather than by
                                             // shrinking the window. mpv's default is ~10 hours, which is exactly
                                             // the runaway read-ahead that
                                             // jetsam-killed the 0.2.11 disk-cache experiment.
    static let diskCacheReadaheadStartSecs = 45  // `cache-secs` the forward-cache ramp STARTS at (loadFile), then
                                             // steps up to diskCacheReadaheadSecs (900) so the initial fill is a
                                             // smooth trickle instead of one max-rate burst that starves the Metal
                                             // present thread (the climb-time output frame drops). Baked, not
                                             // remote-tunable in this cut; 900 stays the tunable ceiling. Must stay
                                             // >= MPVMetalViewController.diskCacheRampReadaheadFloorSecs so cache-secs,
                                             // not demuxer-readahead-secs, governs the forward depth from the start.

    // Timeouts (detail settle / debrid resolve). Present for future wiring; clamped in validate.
    //
    // NONE of these three is wired to a call site yet: no code outside this file reads
    // `detailSettleSecs(tv:)` or `debridResolveSecs`. That is exactly why two of them had gone STALE, and why
    // that staleness was a landmine rather than a cosmetic error. A baked default is the promise that wiring
    // the accessor is a NO-OP; a stale one converts a change meant to be inert into a silent behaviour
    // regression on first wiring. Corrected below to the values the code actually uses today. Runtime
    // behaviour is unchanged by these edits precisely because nothing reads them yet.
    static let detailSettleIOSSecs = 20      // iOSDetailView.swift:654 and :3630, both `.seconds(20)`.
                                             // WAS 12, which is the tvOS value (DetailView.swift:2221); the
                                             // iOS twin is 20 and was never separately checked.
    static let detailSettleTVSecs = 12       // DetailView.swift:2221, `.seconds(12)`. Correct as-is.
    static let debridResolveSecs = 5         // DebridResolver.swift:1178, `resolveTimeout = .seconds(5)`.
                                             // WAS 15, and that file's own comment says "Kept tight (was
                                             // 15s)", so this constant had frozen the PRE-change value.
                                             // Wiring it at 15 would have TRIPLED the play-action resolve
                                             // budget for every user.

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
    static let subtitleDownloadTimeoutMs = 20000  // per-sub download budget (was 12s: big-remux bandwidth contention starved subtitle downloads)
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
    // TWO DISTINCT QUANTITIES, kept apart because conflating them broke the baked-equivalence contract.
    //
    // The CAP is a constant guard, not a mirror of a shipping literal: the resume poll count is
    // maxWaitMs / pollIntervalMs, so two individually in-range remote values can multiply into far more
    // MainActor polling during playback start than either looks like it buys. The cap trims that product.
    static let sourceIndexResumeHoardAttemptCap = 60
    // The COUNT is what the app actually polls with the baked pair: 5000 / 250 = 20, well under the cap.
    //
    // WHY THE SPLIT. `ResolvedConfig.baked` used to store the CAP (60) in the same field that
    // `validate({})` fills with the DERIVED COUNT (20), so the all-baked snapshot and the snapshot produced
    // by an empty remote config disagreed on a value the app reads -- while the whole point of `.baked` is
    // that the two are byte-for-value identical. They now hold separate fields and agree on both.
    static let sourceIndexResumeHoardAttempts =
        min(sourceIndexResumeHoardAttemptCap,
            max(1, sourceIndexResumeHoardMaxWaitMs / sourceIndexResumeHoardPollIntervalMs))
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
    static let featureTorBoxSearch = true       // TorBox SEARCH-as-a-source master gate. Baked ON, so an
                                                // unreachable RemoteConfig is behaviorally identical to today;
                                                // an explicit remote OFF disables the source with NO app update
                                                // (its search host, search-api.torbox.app, went DNS-dead).
    static let featureRefindSources = true      // "Re-find sources" control master gate. Baked ON, so it is on
                                                // by default; an explicit remote OFF hides the control on every
                                                // detail screen and the terminal-failure overlay, NO app update.
    static let featureCommunityJSPlugins = false // Community JS provider runtime (JSProviderSource) master gate.
                                                // Baked OFF: the feature ships DARK, so an unreachable RemoteConfig
                                                // (and every existing install) runs NO provider code. A device
                                                // toggle must ALSO be on; an explicit remote ON is what lets the
                                                // feature light up with no app update once it is ready.
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
        let dvRemuxMultiAudio: Bool?           // VortXMKVRemuxStream.multiAudioEnabled (baked ON)
        let dvRemuxSubtitles: Bool?            // VortXMKVRemuxStream.subtitleRenditionsEnabled (baked ON)
        let dvWindowConsumptionAnchor: Bool?   // VortXRemuxHLSServer.consumptionAnchorEnabled (baked ON)
        // External engine mode: hosting the remux on a Mac for another device. FLEET KILL SWITCH ONLY.
        // Baked true means "not disabled"; it can never turn the feature ON for anyone, because the user
        // default is off and `VortXExternalEngine.mountPlan` also requires a paired, configured host.
        let externalEngine: Bool?
        let diskCache: Bool?
        let trailers: Bool?
        let vortxRatings: Bool?
        let xrdbPosters: Bool?
        let erdbPosters: Bool?
        let collectionsHub: Bool?
        let torBoxSearch: Bool?        // TorBoxSearchSource master gate (baked ON; remote OFF kills the dead path)
        let refindSources: Bool?       // "Re-find sources" control master gate (baked ON; backend kill switch)
        let communityJSPlugins: Bool?  // JSProviderSource master gate (baked OFF; ships dark, remote ON enables)
        let skipVortxLayer: Bool?
        let aniSkip: Bool?
        let spoilerBlur: Bool?
        let debridCacheCheck: Bool?
        let debridInlineResolve: Bool?
        let hdrDisplayModeSwitch: Bool?
        let iosPassthroughAudio: Bool?
        let tvosSpdif: Bool?           // AudioOutputMode.tvosSpdifExperimentEnabled (baked OFF)
        let dvToAVPlayerRouting: Bool?
        let hlsToAVPlayerRouting: Bool?
        let plainRemux: Bool?          // PlayerEngineRouter.plainRemuxEnabled (baked ON, two-probe read)
        let avPlayerDefault: Bool?     // PlayerEngineRouter.avPlayerDefaultEnabled (baked ON, two-probe read)
        let av1Penalty: Bool?
        let communitySubtitles: Bool?
        let subtitleSync: Bool?
        let subtitleUpload: Bool?           // SubtitlePoolClient.swift:426 (baked ON)
        let languageIndex: Bool?
        let languageIndexContribute: Bool?  // LanguageIndexClient.swift:180 (baked ON)
        let localizedMetadata: Bool?
        let sourceIndex: Bool?
        // Dolby Vision Profile 7 enhancement-layer (FEL) compositing on the libmpv lane. Baked ON.
        // Setting this false remotely makes libmpv discard the EL and render the base layer alone,
        // i.e. exactly the pre-FEL behaviour, without shipping a build.
        let dvEnhancementLayer: Bool?
    }
    struct Player: Decodable {
        struct ReadAhead: Decodable {
            let debridCeilingMiB: Int?
            let reducedCeilingMiB: Int?
            let macCeilingMiB: Int?
            let offFloorMiB: Int?
            let dvRemuxWindowMiB: Int?
            // tvOS forward-buffer dials (see RemoteConfigDefaults). Every field optional; a config with no
            // tvos* keys decodes fine and falls back to the baked defaults.
            let tvosBaselineMiB: Int?
            let tvosFloorMiB: Int?
            let tvosHardMinMiB: Int?
            let tvosCeilingMiB: Int?
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
        let diskCacheMetadataCapMiB: Int?   // demuxer-max-bytes (metadata cap) when cache-on-disk is armed
        let diskCacheReadaheadSecs: Int?    // cache-secs forward-time bound when cache-on-disk is armed
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
    // On-disk Streaming Cache, already clamped.
    let diskCacheMetadataCapMiB: Int
    let diskCacheReadaheadSecs: Int

    // tvOS forward-buffer dials (MiB), already clamped: hardMin <= floor <= baseline <= ceiling <= 448.
    let tvosReadAheadBaselineMiB: Int
    let tvosReadAheadFloorMiB: Int
    let tvosReadAheadHardMinMiB: Int
    let tvosReadAheadCeilingMiB: Int

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
    /// The RESOLVED current attempt count for the default pair: min(cap, maxWaitMs / pollIntervalMs). Baked
    /// and validate-with-empty-config must agree on this exactly; they disagreed (60 vs 20) while one field
    /// carried both meanings.
    let sourceIndexResumeHoardAttempts: Int
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
         tvosReadAheadBaselineMiB: Int,
         tvosReadAheadFloorMiB: Int,
         tvosReadAheadHardMinMiB: Int,
         tvosReadAheadCeilingMiB: Int,
         diskCacheMetadataCapMiB: Int,
         diskCacheReadaheadSecs: Int,
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
         sourceIndexResumeHoardAttempts: Int,
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
        self.tvosReadAheadBaselineMiB = tvosReadAheadBaselineMiB
        self.tvosReadAheadFloorMiB = tvosReadAheadFloorMiB
        self.tvosReadAheadHardMinMiB = tvosReadAheadHardMinMiB
        self.tvosReadAheadCeilingMiB = tvosReadAheadCeilingMiB
        self.diskCacheMetadataCapMiB = diskCacheMetadataCapMiB
        self.diskCacheReadaheadSecs = diskCacheReadaheadSecs
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
        self.sourceIndexResumeHoardAttempts = sourceIndexResumeHoardAttempts
        self.sourceIndexRequestTimeoutSecs = sourceIndexRequestTimeoutSecs
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
            tvosReadAheadBaselineMiB: RemoteConfigDefaults.tvosReadAheadBaselineMiB,
            tvosReadAheadFloorMiB: RemoteConfigDefaults.tvosReadAheadFloorMiB,
            tvosReadAheadHardMinMiB: RemoteConfigDefaults.tvosReadAheadHardMinMiB,
            tvosReadAheadCeilingMiB: RemoteConfigDefaults.tvosReadAheadCeilingMiB,
            diskCacheMetadataCapMiB: RemoteConfigDefaults.diskCacheMetadataCapMiB,
            diskCacheReadaheadSecs: RemoteConfigDefaults.diskCacheReadaheadSecs,
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
            sourceIndexResumeHoardAttempts: RemoteConfigDefaults.sourceIndexResumeHoardAttempts,
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

    /// The tvOS NORMAL-tier remote-VOD forward-buffer load cap in MiB (baked 256). The controller applies this
    /// only on the normal tvOS branch (via a "\(...)MiB" spelling); the reduced (2 GB Apple TV HD) remote
    /// read-ahead stays the shipped 96 MiB, untouched.
    var tvosReadAheadBaseline: Int { tvosReadAheadBaselineMiB }

    /// The device-scaled shed floor in BYTES for the memory-warning and proactive clamp/restore paths. On the
    /// NORMAL tier it is the floor knob (>= the 150 MiB hard-min by construction, baked 192). On
    /// PerformanceMode.reduced it scales down to at most the reduced RAM ceiling (128 MiB) and can never exceed
    /// the normal floor, so a shed stays non-increasing and crash-safe on the 2 GB Apple TV HD.
    func tvosShedFloorBytes(reduced: Bool) -> Int {
        let mib = reduced ? min(reducedCeilingMiB, tvosReadAheadFloorMiB) : tvosReadAheadFloorMiB
        return mib << 20
    }

    /// demuxer-readahead-secs for VOD (baked 300).
    var vodReadaheadSecs: Int { vodReadaheadSecsValue }

    /// `demuxer-max-bytes` (BYTES) applied when the on-disk Streaming Cache is armed (baked 128 MiB). Under
    /// working `cache-on-disk` offload this bounds packet METADATA (file offsets), not payload, so it is modest
    /// by design and may sit BELOW the RAM read-ahead baseline; it is also the RAM-payload guardrail if disk
    /// offload silently falls back to memory. `diskCacheReadaheadSecs` is the real forward-depth lever alongside.
    var diskCacheMetadataCapBytes: Int { diskCacheMetadataCapMiB * 1024 * 1024 }

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
    private static let lastFetchKey = "vortx.remoteConfig.lastFetchEpoch"
    private static let foregroundThrottle: TimeInterval = 30 * 60   // once / 30 min for a foreground refresh

    /// The raw last-good JSON currently installed (nil = none / baked). Kept so `304 Not Modified` is a
    /// genuine no-op and a foreground refresh does not need to re-decode.
    private var currentRaw: Data?
    private var periodicStarted = false

    // MARK: Bootstrap (call once at launch).

    /// (1) Synchronously load the last-good cached JSON from Application Support and build the snapshot (else
    /// all-baked). (2) Kick a background refresh. Never throws.
    func bootstrap() async {
        // The launch-health guard sits BETWEEN loading the cache and applying it: a cached config that has
        // already failed `unhealthyStartThreshold` consecutive launches is dropped here and never reaches
        // `validate`. See `admitCachedConfig` for why "abnormal" is deliberately imprecise.
        if let cached = Self.loadCachedJSON(),
           Self.admitCachedConfig(hash: Self.stableHash(cached)),
           let decoded = try? JSONDecoder().decode(RemoteConfigData.self, from: cached) {
            currentRaw = cached
            await installAndAnnounce(Self.validate(decoded))   // clamp once at swap time
        } else {
            currentRaw = nil
            await installAndAnnounce(.baked)
        }
        startPeriodicIfNeeded()
        Self.scheduleLaunchHealthMark()
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
            if http.statusCode == 304 {
                // A 304 is a successful "still fresh" fetch, so stamp the fetch time too: otherwise
                // refreshIfForegroundDue never sees a recent lastFetch in the steady state (the config rarely
                // changes, so every foreground refresh 304s), the 30-minute throttle never engages, and we
                // re-hit the network on every scene activation. Keep last-good either way.
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastFetchKey)
                return
            }
            guard http.statusCode == 200 else { return }                // any other status: keep last-good

            // A config the launch-health guard already condemned is not re-installed just because the server
            // still serves it: without this, a boot-time discard would be silently undone by this refresh
            // moments later and the device would wedge again on the next launch. Stamp the fetch time so the
            // throttle still applies, but do NOT persist it. A genuinely new config hashes differently and is
            // therefore never caught here, so an operator's fix installs normally.
            if Self.isQuarantined(Self.stableHash(data)) {
                await installAndAnnounce(.baked)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastFetchKey)
                return
            }

            let decoded = try JSONDecoder().decode(RemoteConfigData.self, from: data)

            // master.remoteConfigEnabled == false => discard fetched config to baked (kill switch for the
            // whole system). Do NOT persist a disabling config as last-good, so removing the field restores it.
            if decoded.master?.remoteConfigEnabled == false {
                await installAndAnnounce(.baked)
                return
            }

            let resolved = Self.validate(decoded)
            await installAndAnnounce(resolved)       // locked replace; readers see old-or-new, never torn
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
        guard Self.shouldRefreshOnForeground(lastFetchEpoch: last,
                                             now: Date().timeIntervalSince1970,
                                             throttle: Self.foregroundThrottle) else { return }
        await refresh()
    }

    /// The throttle decision, pure so it can be tested without a clock, a network, or UserDefaults. Called on
    /// every foreground transition now that the scene hooks are wired, so "it cheaply no-ops when the last
    /// fetch is recent" is a claim that has to be checkable rather than asserted in a comment.
    static func shouldRefreshOnForeground(lastFetchEpoch: Double, now: Double, throttle: TimeInterval) -> Bool {
        guard lastFetchEpoch > 0 else { return true }   // never fetched: always allowed
        // A clock that moved BACKWARDS (timezone edit, NTP correction, a restored backup) must not lock the
        // device out of refreshing until real time catches up, so a negative age is treated as due.
        let age = now - lastFetchEpoch
        if age < 0 { return true }
        return age >= throttle
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
        let debrid = max(floor, clamp(data.player?.readAhead?.debridCeilingMiB, RemoteConfigDefaults.debridCeilingMiB, 64, 256))
        let reduced = max(floor, clamp(data.player?.readAhead?.reducedCeilingMiB, RemoteConfigDefaults.reducedCeilingMiB, 64, 192))
        let mac = max(floor, clamp(data.player?.readAhead?.macCeilingMiB, RemoteConfigDefaults.macCeilingMiB, 128, 1536))
        let vodSecs = clamp(data.player?.vodReadaheadSecs, RemoteConfigDefaults.vodReadaheadSecs, 30, 600)
        // DV-remux buffer window floor: keep at least 64 MiB (matching VortXRemuxBuffer.windowFloorMinMiB) and
        // cap at 512 MiB. The lower bound is EMPIRICAL, not a two-segment derivation: see the note on
        // RemoteConfigDefaults.dvRemuxWindowMiB for why that derivation is dead (no hlsMaxSegmentBytes exists,
        // and 32 MiB is a retired threshold). Eviction beneath a range still being served is held by
        // VortXRemuxBuffer's active read leases, not by this floor; the floor keeps ordinary near-frontier
        // re-reads from churning. It is NOT a startup-starvation guard; producerLeadBytes supplies the startup
        // headroom independently. The upper cap keeps a widened re-read floor from approaching the whole-movie
        // RAM this window replaced.
        let dvWindow = clamp(data.player?.readAhead?.dvRemuxWindowMiB, RemoteConfigDefaults.dvRemuxWindowMiB, 64, 512)

        // --- tvOS forward-buffer dials (THE jetsam knob's other half). The static clamp is followed by an
        //     explicit ordering enforcement so the invariant hardMin <= floor <= baseline <= ceiling <= 448
        //     holds no matter which fields are present, absent, or out of range. The 448 hi keeps the in-RAM
        //     cap under the ~700 MiB wall the 4K field logs proved fatal. `clamp` returns the baked fallback
        //     un-ranged when a field is ABSENT, so max()/min() re-impose the ordering (mirrors debrid/reduced
        //     above). Baked all-absent resolves to 150/192/384/384 (hardMin/floor/baseline/ceiling). ---
        let tvosHardMin = clamp(data.player?.readAhead?.tvosHardMinMiB, RemoteConfigDefaults.tvosReadAheadHardMinMiB, 96, 256)
        let tvosCeiling = max(tvosHardMin, clamp(data.player?.readAhead?.tvosCeilingMiB, RemoteConfigDefaults.tvosReadAheadCeilingMiB, 128, 448))
        let tvosFloor = min(tvosCeiling, max(tvosHardMin, clamp(data.player?.readAhead?.tvosFloorMiB, RemoteConfigDefaults.tvosReadAheadFloorMiB, 96, 448)))
        let tvosBaseline = min(tvosCeiling, max(tvosFloor, clamp(data.player?.readAhead?.tvosBaselineMiB, RemoteConfigDefaults.tvosReadAheadBaselineMiB, 96, 448)))

        // --- On-disk Streaming Cache. Metadata cap 48..256 MiB: deliberately allowed BELOW the RAM read-ahead
        //     baseline because under cache-on-disk it bounds packet metadata, not payload (metadata is cheap),
        //     and is only the RAM guardrail on the offload-fallback path. Forward time bound 60..3600 s: mpv's
        //     ~10 h default is the 0.2.11 runaway, so the ceiling stays well under an hour by default. ---
        let diskCacheMetaMiB = clamp(data.player?.diskCacheMetadataCapMiB, RemoteConfigDefaults.diskCacheMetadataCapMiB, 48, 256)
        let diskCacheReadSecs = clamp(data.player?.diskCacheReadaheadSecs, RemoteConfigDefaults.diskCacheReadaheadSecs, 60, 3600)

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
        // permits 20000 ms, which at the pinned 250 ms floor is 80 attempts, trimmed by the derived cap below
        // to 60 attempts over ~15 s. So the worst case a remote value can buy is 3x the shipped attempt count
        // and 3x the shipped wall time, on a path that is a bounded poll and whose every timeout is a silent
        // no-op. Nothing here can run unbounded and nothing here weakens an admission or validation bound.
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
        // The DERIVED quantity gets its own clamp. Clamping the pair above is not sufficient: 20000 / 250 is 80
        // in-range attempts, each one MainActor work. With the baked pair this resolves to 20, so the cap is
        // inert today and only ever trims a remote combination.
        let siResumeAttempts = min(RemoteConfigDefaults.sourceIndexResumeHoardAttemptCap,
                                   max(1, siResumeWaitMs / max(1, siResumePollMs)))
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
            put("dvRemuxMultiAudio", f.dvRemuxMultiAudio)
            put("dvRemuxSubtitles", f.dvRemuxSubtitles)
            put("dvWindowConsumptionAnchor", f.dvWindowConsumptionAnchor)
            put("externalEngine", f.externalEngine)
            put("diskCache", f.diskCache)
            put("trailers", f.trailers)
            put("vortxRatings", f.vortxRatings)
            put("xrdbPosters", f.xrdbPosters)
            put("erdbPosters", f.erdbPosters)
            put("collectionsHub", f.collectionsHub)
            put("torBoxSearch", f.torBoxSearch)
            put("refindSources", f.refindSources)
            put("communityJSPlugins", f.communityJSPlugins)
            put("skipVortxLayer", f.skipVortxLayer)
            put("aniSkip", f.aniSkip)
            put("spoilerBlur", f.spoilerBlur)
            put("debridCacheCheck", f.debridCacheCheck)
            put("debridInlineResolve", f.debridInlineResolve)
            put("hdrDisplayModeSwitch", f.hdrDisplayModeSwitch)
            put("iosPassthroughAudio", f.iosPassthroughAudio)
            put("tvosSpdif", f.tvosSpdif)
            put("dvToAVPlayerRouting", f.dvToAVPlayerRouting)
            put("hlsToAVPlayerRouting", f.hlsToAVPlayerRouting)
            put("plainRemux", f.plainRemux)
            put("avPlayerDefault", f.avPlayerDefault)
            put("av1Penalty", f.av1Penalty)
            put("communitySubtitles", f.communitySubtitles)
            put("subtitleSync", f.subtitleSync)
            put("subtitleUpload", f.subtitleUpload)
            put("languageIndex", f.languageIndex)
            put("languageIndexContribute", f.languageIndexContribute)
            put("localizedMetadata", f.localizedMetadata)
            put("sourceIndex", f.sourceIndex)
            put("dvEnhancementLayer", f.dvEnhancementLayer)
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
            tvosReadAheadBaselineMiB: tvosBaseline,
            tvosReadAheadFloorMiB: tvosFloor,
            tvosReadAheadHardMinMiB: tvosHardMin,
            tvosReadAheadCeilingMiB: tvosCeiling,
            diskCacheMetadataCapMiB: diskCacheMetaMiB,
            diskCacheReadaheadSecs: diskCacheReadSecs,
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
            sourceIndexResumeHoardAttempts: siResumeAttempts,
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

    // MARK: - Launch-health guard: the valid-but-HARMFUL config

    /// MALFORMED config is already handled well (corrupt / undecodable / out-of-range => absent => baked).
    /// This guards the OTHER case, and it is the only one that can brick the fleet PERMANENTLY: a config that
    /// decodes cleanly, passes every clamp, is persisted as last-known-good, and then wedges the app. It is
    /// re-applied on every launch, so if it wedges the app before the next fetch completes, the very
    /// mechanism built to deliver the fix can never reach the device.
    ///
    /// THE GUARD: count launches that applied a given cached config and did not survive to a responsive main
    /// thread. `unhealthyStartThreshold` consecutive such launches discard that config, quarantine it by
    /// content hash, and boot baked.
    ///
    /// WHAT "ABNORMAL" CAN AND CANNOT MEAN HERE, stated plainly. We cannot distinguish a crash from a jetsam
    /// kill, a force-quit, or a fast Home press: all four look identical, in that the healthy mark never ran.
    /// That imprecision is ACCEPTED because the two error directions are wildly asymmetric. A false NEGATIVE
    /// strands a user forever. A false POSITIVE boots them on baked defaults, which is byte-identical to the
    /// shipping build, and the next good fetch restores remote behavior. So this is deliberately tuned to
    /// tolerate false positives and never to tolerate a false negative.
    ///
    /// SCOPE, also stated plainly: this protects the LAUNCH path, which is the unrecoverable case. A config
    /// that only misbehaves later (during playback, say) still lets the app start and fetch, so the fleet
    /// stays reachable and does not need this guard.
    ///
    /// Consecutive unhealthy starts before a cached config is discarded. THREE, deliberately: 1 would throw
    /// away good config on any single unrelated crash or a quick quit; 2 is still ordinary user behavior
    /// (open the app and immediately background it, twice); 3 consecutive launches that each failed to keep
    /// the main thread responsive for `healthySurvivalSecs` is a strong signal, and it costs a genuinely
    /// affected user at most three bad launches before the device self-heals.
    static let unhealthyStartThreshold = 3
    /// How long a launch must keep the MAIN thread responsive to count as healthy. Scheduled on the MAIN
    /// queue on purpose: a hang, not only a crash, must fail to mark healthy, and a main-queue block that
    /// never runs is exactly the signature of a wedged app.
    static let healthySurvivalSecs: TimeInterval = 10

    private static let healthCounterKey = "vortx.remoteConfig.unhealthyStarts"
    private static let healthHashKey = "vortx.remoteConfig.healthConfigHash"
    private static let quarantineHashKey = "vortx.remoteConfig.quarantinedHash"
    private static let lastDiscardKey = "vortx.remoteConfig.lastDiscardEpoch"
    private static let discardCountKey = "vortx.remoteConfig.discardCount"

    /// FNV-1a over the raw config bytes. Hand-rolled because `Hasher` is randomly seeded PER PROCESS, so its
    /// output cannot be compared across launches, which is the only thing this hash is for.
    static func stableHash(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    enum LaunchHealthDecision: Equatable {
        /// Apply the cached config. `nextCounter` is persisted BEFORE applying, so a wedge during apply is
        /// still counted on the next launch.
        case apply(nextCounter: Int)
        /// Discard the cached config and boot baked.
        case discard
    }

    /// The whole decision, as a PURE function of persisted state, so it can be exhaustively tested without
    /// UserDefaults, a filesystem, or an app lifecycle.
    static func launchHealthDecision(cachedHash: String,
                                     storedHash: String?,
                                     storedCounter: Int,
                                     quarantinedHash: String?,
                                     threshold: Int) -> LaunchHealthDecision {
        if let quarantinedHash, quarantinedHash == cachedHash { return .discard }
        // A config this device has not applied before starts its own count. Unhealthy starts charged against
        // a PREVIOUS config must never be inherited by a new one, or an operator's fix would arrive
        // pre-condemned.
        let counter = (storedHash == cachedHash) ? max(0, storedCounter) : 0
        if counter >= threshold { return .discard }
        return .apply(nextCounter: counter + 1)
    }

    /// Record this launch's attempt against `cachedHash`. Returns true when the cached config may be applied,
    /// false when it must be discarded (in which case it is quarantined and the on-disk cache is dropped).
    private static func admitCachedConfig(hash cachedHash: String) -> Bool {
        let defaults = UserDefaults.standard
        let decision = launchHealthDecision(
            cachedHash: cachedHash,
            storedHash: defaults.string(forKey: healthHashKey),
            storedCounter: defaults.integer(forKey: healthCounterKey),
            quarantinedHash: defaults.string(forKey: quarantineHashKey),
            threshold: unhealthyStartThreshold)

        switch decision {
        case .discard:
            // Quarantine by CONTENT hash so `refresh` cannot re-install the same bytes minutes later and undo
            // this. Drop the cache file and the ETag together: keeping the ETag would make the next GET 304
            // into a cache that no longer exists.
            defaults.set(cachedHash, forKey: quarantineHashKey)
            defaults.set(Date().timeIntervalSince1970, forKey: lastDiscardKey)
            defaults.set(defaults.integer(forKey: discardCountKey) + 1, forKey: discardCountKey)
            defaults.set(0, forKey: healthCounterKey)
            defaults.removeObject(forKey: healthHashKey)
            defaults.removeObject(forKey: etagKey)
            if let file = cacheFile() { try? FileManager.default.removeItem(at: file) }
            return false
        case .apply(let next):
            defaults.set(cachedHash, forKey: healthHashKey)
            defaults.set(next, forKey: healthCounterKey)
            return true
        }
    }

    static func isQuarantined(_ hash: String) -> Bool {
        UserDefaults.standard.string(forKey: quarantineHashKey) == hash
    }

    /// Called once per launch on the MAIN queue, `healthySurvivalSecs` after bootstrap. Reaching it proves the
    /// process started AND the main thread is servicing work, which is what "healthy" must mean for the guard
    /// to catch hangs rather than only crashes.
    static func markLaunchHealthy() {
        UserDefaults.standard.set(0, forKey: healthCounterKey)
    }

    private static func scheduleLaunchHealthMark() {
        DispatchQueue.main.asyncAfter(deadline: .now() + healthySurvivalSecs) { markLaunchHealthy() }
    }

    /// Read-only diagnostics for the guard, so a discard is visible after the fact rather than silent.
    struct LaunchHealthState {
        let unhealthyStarts: Int
        let trackedConfigHash: String?
        let quarantinedHash: String?
        let lastDiscardEpoch: Double
        let discardCount: Int
    }

    static var launchHealth: LaunchHealthState {
        let defaults = UserDefaults.standard
        return LaunchHealthState(
            unhealthyStarts: defaults.integer(forKey: healthCounterKey),
            trackedConfigHash: defaults.string(forKey: healthHashKey),
            quarantinedHash: defaults.string(forKey: quarantineHashKey),
            lastDiscardEpoch: defaults.double(forKey: lastDiscardKey),
            discardCount: defaults.integer(forKey: discardCountKey))
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
