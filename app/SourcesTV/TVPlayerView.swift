import SwiftUI
import UIKit
import os

/// Stable, opaque identities for the player's virtual accessibility rows. Async panel refreshes may reorder
/// rows or change their detail text while VoiceOver is focused. Identity therefore uses the panel, semantic
/// label, role, and same-label occurrence, never the mutable detail and never raw provider data in the output.
/// Kept pure so focus retention can be exercised without compiling the full SwiftUI player.
enum TVPlayerAccessibilityRowIdentityPolicy {
    struct Candidate: Equatable {
        let explicitID: String?
        let label: String
        let isHeader: Bool
    }

    static func identities(panelKey: String, rows: [Candidate]) -> [String] {
        var semanticOccurrences: [String: Int] = [:]
        var emittedOccurrences: [String: Int] = [:]
        return rows.map { row in
            let base: String
            if let explicitID = row.explicitID, !explicitID.isEmpty {
                base = explicitID
            } else {
                let semanticKey = "\(panelKey)|\(row.isHeader ? "header" : "row")|\(row.label)"
                let occurrence = semanticOccurrences[semanticKey, default: 0]
                semanticOccurrences[semanticKey] = occurrence + 1
                base = "panel.row.\(opaqueHash(semanticKey)).\(occurrence)"
            }
            let emitted = emittedOccurrences[base, default: 0]
            emittedOccurrences[base] = emitted + 1
            return emitted == 0 ? base : "\(base).duplicate.\(emitted)"
        }
    }

    static func restoredFocusIndex(previousID: String?, identities: [String], fallback: Int) -> Int {
        guard let previousID, let restored = identities.firstIndex(of: previousID) else { return fallback }
        return restored
    }

    /// FNV-1a over a bounded UTF-8 prefix is deterministic and intentionally opaque. This is an identity key,
    /// not a security decision; the bound prevents a provider-controlled label from creating unbounded work.
    private static func opaqueHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8.prefix(1_024) {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
// END TVPlayerAccessibilityRowIdentityPolicy

/// Pure startup decision for the tvOS AVPlayer watchdog. Kept outside `TVPlayerView` so the boundary cases can
/// run in a standalone harness without compiling the full SwiftUI player surface.
enum TVAVStartWatchdogPolicy {
    static let remoteAttachSchedulingMarginSeconds: Double = 3

    enum AwaitingMountDecision: Equatable {
        case cancel
        case keepWaiting
        case monitorRemux
        case demote
    }

    /// A direct AVPlayer start keeps its short deadline. A source whose route is expected to produce a remux
    /// gets the bounded attach budget because the external engine sets `isRemuxMounted` asynchronously after
    /// signalling. The instant that runtime truth appears, the caller moves to the progress-aware watchdog.
    static func awaitingMountDecision(elapsed: Double,
                                      ownerCurrent: Bool,
                                      remuxMounted: Bool,
                                      remuxExpected: Bool,
                                      directTimeout: Double,
                                      remuxAttachTimeout: Double) -> AwaitingMountDecision {
        guard ownerCurrent else { return .cancel }
        if remuxMounted { return .monitorRemux }
        if elapsed < directTimeout { return .keepWaiting }
        if remuxExpected, elapsed < remuxAttachTimeout { return .keepWaiting }
        return .demote
    }

    /// Session creation and signalling are sequential bounded stages. The surface watchdog must cover both
    /// real transport budgets plus a small scheduling margin, or it can demote a healthy remote mount first.
    static func remoteAttachTimeout(controlResourceTimeout: Double,
                                    signallingTimeout: Double) -> Double {
        max(0, controlResourceTimeout)
            + max(0, signallingTimeout)
            + remoteAttachSchedulingMarginSeconds
    }
}

/// The direct AVPlayer no-frame path is intentionally a two-engine, one-source check: AVFoundation gets its
/// short opportunity first, then libmpv gets one bounded opportunity on the exact same source. If neither
/// engine produces a frame, this is a source-level failure and the normal hop choke point must run rather than
/// spending the ordinary retry budget reopening the same URL again. Keeping this decision pure makes the
/// generation/identity fence visible to a tiny deterministic harness.
enum TVDirectAVStartRecoveryPolicy {
    enum Decision: Equatable {
        case cancel
        case hop
    }

    static func fallbackTimedOut(
        recoveryRecorded: Bool,
        sourceStillCurrent: Bool,
        fallbackIsLibMPV: Bool,
        firstFrameRendered: Bool
    ) -> Decision {
        guard recoveryRecorded,
              sourceStillCurrent,
              fallbackIsLibMPV,
              !firstFrameRendered else { return .cancel }
        return .hop
    }
}

/// A cold libmpv resume deliberately defers its absolute seek until the first frame because an early absolute
/// seek empties the cache and can wedge video output. For the narrow direct-AV fallback case, a single tiny
/// relative seek is safe (it does not arm that absolute-seek cache hold) and can wake an input that has opened
/// but has not started decoding. It is never retried: an unframed source after this nudge is failed over.
enum TVLibMPVStartupNudgePolicy {
    enum Decision: Equatable {
        case cancel
        case nudge
        case hop
    }

    static func decision(
        recoveryRecorded: Bool,
        sourceStillCurrent: Bool,
        firstFrameRendered: Bool,
        nudgeAlreadyIssued: Bool
    ) -> Decision {
        guard recoveryRecorded, sourceStillCurrent, !firstFrameRendered else { return .cancel }
        return nudgeAlreadyIssued ? .hop : .nudge
    }
}

/// Recovery choices arrive before either track list is guaranteed complete. Keep each semantic choice pending
/// until its own media type can perform a real action; an early empty subtitle list must never turn a manual
/// language pick into Off just because audio happened to arrive first.
enum TVTrackRecoveryPolicy {
    enum AudioAction: Equatable {
        case retain
        case reapply(Int)
        case automatic(Int)
    }

    enum SubtitleAction: Equatable {
        case retain
        case selectEmbedded(Int)
        case applyImmediately
    }

    static func audioAction(
        choice: PlayerRecoveryAudioChoice,
        tracks: [MPVTrack],
        automaticID: Int?
    ) -> AudioAction {
        let candidates = tracks.map {
            PlayerRecoveryAudioChoice.Candidate(
                id: $0.id, language: $0.lang, title: $0.title, selectable: $0.isSelectable
            )
        }
        guard candidates.contains(where: \.selectable) else { return .retain }
        if let id = PlayerRecoveryAudioChoice.matchingID(for: choice, in: candidates) {
            return .reapply(id)
        }
        return automaticID.map(AudioAction.automatic) ?? .retain
    }

    static func subtitleAction(
        choice: SubtitleChoice,
        tracks: [MPVTrack],
        pooledChoiceAvailable: Bool
    ) -> SubtitleAction {
        switch choice {
        case .off, .external:
            return .applyImmediately
        case .pooled:
            return pooledChoiceAvailable ? .applyImmediately : .retain
        case let .embedded(lang, title):
            let normalizedLanguage = lang.lowercased()
            let normalizedTitle = title.lowercased()
            if let exact = tracks.first(where: {
                $0.isSelectable
                    && $0.lang.lowercased() == normalizedLanguage
                    && $0.title.lowercased() == normalizedTitle
            }) {
                return .selectEmbedded(exact.id)
            }
            if let language = tracks.first(where: {
                $0.isSelectable && $0.lang.lowercased() == normalizedLanguage
            }) {
                return .selectEmbedded(language.id)
            }
            return .retain
        }
    }
}

// BEGIN native-debrid recovery switch state machine
/// The provider request is one transaction per current native-debrid mount. A user engine request that lands
/// while it is in flight joins the transaction, so the new player can only be mounted from the accepted fresh
/// URL rather than racing ahead on the stale transport URL.
enum TVNativeDebridRecoveryStateMachine {
    struct State: Equatable {
        struct Completion: Equatable {
            let requestedEngine: Bool?
        }

        private(set) var freshLinkUsed = false
        private(set) var freshLinkInFlight = false
        private(set) var requestedEngine: Bool?
        private(set) var activeRecoveryID: UInt64?
        private var nextRecoveryID: UInt64 = 0

        mutating func beginFreshLink(requestedEngine: Bool? = nil) -> UInt64? {
            guard !freshLinkUsed, !freshLinkInFlight else { return nil }
            nextRecoveryID &+= 1
            freshLinkUsed = true
            freshLinkInFlight = true
            self.requestedEngine = requestedEngine
            activeRecoveryID = nextRecoveryID
            return nextRecoveryID
        }

        /// Returns false when there is no live recovery to join. The latest user request wins while the stale
        /// URL is deliberately kept mounted; no provider call and no player surface swap happens here.
        mutating func joinEngineSwitch(_ engine: Bool) -> Bool {
            guard freshLinkInFlight else { return false }
            requestedEngine = engine
            return true
        }

        /// Consumes the joined engine request exactly once with the accepted fresh URL. A stale or cancelled
        /// task has no authority to finish a later transaction after the source state has been reset.
        mutating func finishFreshLink(ownedBy recoveryID: UInt64) -> Completion? {
            guard freshLinkInFlight, activeRecoveryID == recoveryID else { return nil }
            freshLinkInFlight = false
            activeRecoveryID = nil
            defer { requestedEngine = nil }
            return Completion(requestedEngine: requestedEngine)
        }

        /// Cancellation and stale ownership failures make the provider retryable again. The exact owner check
        /// is essential: an old request may complete after an episode/source reset but cannot retire that new
        /// mount's transaction.
        @discardableResult
        mutating func retireFreshLink(ownedBy recoveryID: UInt64) -> Bool {
            guard freshLinkInFlight, activeRecoveryID == recoveryID else { return false }
            freshLinkUsed = false
            freshLinkInFlight = false
            requestedEngine = nil
            activeRecoveryID = nil
            return true
        }

        mutating func reset() {
            freshLinkUsed = false
            freshLinkInFlight = false
            requestedEngine = nil
            activeRecoveryID = nil
        }
    }
}
// END native-debrid recovery switch state machine
// END tvOS track recovery policy

/// Pure ownership and first-frame gates shared by the 30-second source-hop timer and the event surface.
/// Position zero is a valid rendered first frame for AVPlayer, while every timer must still prove it belongs
/// to the exact episode, source, retry generation and logical player load that armed it.
enum TVPlaybackStartPolicy {
    static func hasStarted(positionSeconds: Double, avPlayerRenderedFrame: Bool) -> Bool {
        positionSeconds > 0 || avPlayerRenderedFrame
    }

    static func shouldIgnoreIssuedAdvanceTick(
        positionSeconds: Double,
        avPlayerRenderedFrame: Bool
    ) -> Bool {
        positionSeconds <= 0 && !avPlayerRenderedFrame
    }

    /// A remux start has its own exact-owner, progress-aware watchdog. The generic source-hop timer must not
    /// race it using AVPlayer's still-empty loaded ranges and tear down a mount whose mux counters are moving.
    static func genericLoadTimeoutDefersToRemuxWatchdog(
        avPlayerActive: Bool,
        remuxPendingOrMounted: Bool
    ) -> Bool {
        avPlayerActive && remuxPendingOrMounted
    }

    static func loadTimeoutOwnerIsCurrent<Token: Equatable>(
        capturedEpisodeGeneration: Int,
        currentEpisodeGeneration: Int,
        capturedSourceGeneration: Int,
        currentSourceGeneration: Int,
        capturedResumeGeneration: Int,
        currentResumeGeneration: Int,
        capturedLoadToken: Token?,
        currentLoadToken: Token?
    ) -> Bool {
        let loadOwnerCurrent = capturedLoadToken == nil || capturedLoadToken == currentLoadToken
        return capturedEpisodeGeneration == currentEpisodeGeneration
            && capturedSourceGeneration == currentSourceGeneration
            && capturedResumeGeneration == currentResumeGeneration
            && loadOwnerCurrent
    }
}

/// Full-screen libmpv player for tvOS. All remote input is handled at the UIKit level by a focusable
/// `RemoteCatcher` (pressesBegan), and the control bar / options panel are driven by plain state with
/// no SwiftUI focus, because SwiftUI `@FocusState` is unreliable inside a full-screen cover on tvOS.
/// Shares the MPVKit core with the iOS app.
struct TVPlayerView: View {
    private struct DirectAVNoFrameRecovery: Equatable {
        let url: URL
        let episodeGeneration: Int
        let sourceGeneration: Int
        let resumeGeneration: Int
        let attemptID: String
        let mpvLoadToken: PlayerLoadToken?
    }
    private struct AVToMPVHandoff: Equatable {
        let url: URL
        let episodeGeneration: Int
        let sourceGeneration: Int
        let resumeGeneration: Int
        let attemptID: String
    }
    let url: URL
    let title: String
    var meta: PlaybackMeta? = nil          // when set, resume + record watch progress to the library
    var episodes: [CoreVideo] = []             // series' launch episodes (empty for movies) → Next/Prev/list
    var seriesInventoryAuthority: AppleCWSeriesInventory.Authority = .launch
    var sourceHint: String? = nil              // quality signature of the launching stream (source continuity)
    var torrent: Bool = false                  // stream rides the embedded torrent engine (gets warm-up patience)
    var bingeGroup: String? = nil              // the launching stream's release-group tag, for sticky auto-next
    var headers: [String: String]? = nil       // HTTP headers the stream's add-on requires (proxyHeaders)
    var forceMPV: Bool = false                 // last-resort escape hatch: skip AVPlayer routing, mount libmpv directly
    var initialEnginePreference: PlayerEngineRouter.Override? = nil
    var isTrailer: Bool = false                // FIX I: a trailer clip, not a content stream → never fail over to engine streams
    var trailerYouTubeID: String? = nil        // #95: the trailer's YouTube id, so a dead in-app trailer is handed to the YouTube app before "Trailer unavailable"
    var audioSidecarURL: URL? = nil            // yt-direct adaptive pair: external audio mpv mounts with the video-only url (forces libmpv)
    var debridRef: DebridPlaybackRef? = nil    // native-debrid provenance of the launching link, for CW reresolve of an expired link
    var initialSourceStream: CoreStream? = nil // exact launch row, including a raw torrent's proven fileIdx
    var initialEnginePlayerVideoId: String? = nil   // confirmed exact series binding from the presenter
    /// Account-confirmed debrid-cache snapshot captured at launch, so the cached-advance / binge / failover
    /// re-rank (`rankedCandidates` / `best` / `bestCachedResolution`) sees the same cache awareness the source
    /// list ranked with (Beta 26 A2). Default empty keeps every other construction site compiling unchanged.
    var debridCachedHashes: Set<String> = []
    /// True when the LAUNCH source was an explicit user choice (a tapped source-list row / quality pick),
    /// false for an auto-pick (Watch Now / a Continue-Watching resume). An explicit pick is HONORED on a
    /// start-timeout: retry the SAME source in place with a longer first-buffer grace rather than silently
    /// hopping to a different, often lower-quality, source. Only the auto path may auto-hop.
    var startedFromExplicitPick: Bool = false
    /// True when this launch is a Continue-Watching resume: play the exact stored source first, but hop to a
    /// fresh source on a HARD load failure (a stale debrid link) instead of dead-ending like a manual pick.
    var startedFromResume: Bool = false
    /// "Play from start" (backlog E): start at 0:00 regardless of any saved resume position. Skips the
    /// engine/account resume lookup below and pins resumeSeconds to 0, leaving the stored resume untouched.
    var startFromZero: Bool = false
    /// An explicit start position in seconds (the Trakt "Resume from <time>" chip). Skips the engine/account
    /// resume lookup exactly as `startFromZero` does and seeks here instead, leaving the stored resume point
    /// untouched. The engine records its own position from here on, so VortX stays the sole authority.
    var startAtSeconds: Double? = nil
    /// Publishes only a media identity that reached the first-frame commit point. The detail page uses it to
    /// return to the episode actually watched while engine Continue Watching persistence catches up.
    var onPlaybackIdentityCommitted: (PlaybackMeta) -> Void = { _ in }
    var onClose: () -> Void = {}           // dismiss the dedicated player window

    /// The pinned source for this title (#15), so in-player failover, auto-next, and preload keep using the
    /// user's pinned provider/quality across episodes - and still hop off it if it dies.
    private var sourcePin: ResolvedPin? {
        // Use the LIVE episode meta (curMeta), falling back to the launch prop before it is set. For a
        // series both carry the same show libraryId, but curMeta is the canonical source of truth across
        // auto-next transitions. Read fresh at each failover/auto-next/preload, so a new pin is honoured.
        guard let m = curMeta ?? meta else { return nil }
        return SourcePinStore.shared.effectivePin(SourcePinContext(metaId: m.libraryId, isSeries: m.type == "series"))
    }

    /// The key a remembered manual source pick is stored and looked up under (`SeriesSourceSticky`). It is the
    /// SAME identity `sourcePin` above uses - `libraryId`, the SHOW's id, which every episode of a series shares
    /// (the per-episode identity is `videoId`, which would give a "sticky" that reset every episode and defeat
    /// the whole point). Read live off `curMeta` so it tracks the episode auto-next moved to, exactly like the
    /// pin. Series only: the durable per-show memory is what the binge loop needs, and keying movies here would
    /// spend the store's per-profile cap on titles that never get a next episode.
    private var seriesStickyKey: String? {
        guard let m = curMeta ?? meta, m.type == "series" else { return nil }
        return m.libraryId
    }

    /// The remembered manual pick for this show, in the shape `StreamRanking.best` / `rankedCandidates` take.
    private var seriesSticky: (addon: String?, bingeGroup: String?)? {
        seriesStickyKey.flatMap { SeriesSourceSticky.preference(for: $0) }
    }

    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    /// Episode-scoped auxiliary contributors owned by the player's preload generation. They are separate from
    /// the covered detail page so preparing E2 never mutates the E1 rows behind the player.
    @StateObject private var preloadTorboxSearch = TorBoxSearchSource()
    @StateObject private var preloadSourceIndex = SourceIndexServeSource()
    @StateObject private var preloadMediaServers = MediaServerSource()
    @State private var markedWatched = false   // mark the engine watched once, near end of playback
    @State private var autoAddedThisPlayback = false   // D8/D9: the ~60s auto-add + watch-ping fires once per playback
    @AppStorage("stremiox.autoAddLibrary") private var autoAddLibrary = true   // "Auto-add watched to Library" (default ON)
    @AppStorage("stremiox.playerVolume") private var playerVolume = 100.0   // "Default volume" (D5): level a new playback starts at, SAME key as iOS/Mac
    @StateObject private var coordinator = MPVMetalPlayerView.Coordinator()
    @State private var buffering = true
    @State private var isPaused = false
    @State private var currentTime = 0.0
    @State private var duration = 0.0
    @State private var bufferedTime = 0.0       // buffered-ahead edge (seconds) for the YouTube-style grey scrubber band
    @State private var videoWidth = 0           // metadata line: encoded width (resolution is by WIDTH, so 2.40:1 4K is not mislabeled 1440p)
    @State private var videoHeight = 0          // metadata line: encoded height
    @State private var audioCodec = ""          // metadata line: active audio codec (e.g. "eac3")
    @State private var audioChannels = 0        // metadata line: produced remux channels when known
    @State private var isHDR = false            // metadata line: HDR/DV detected (sig-peak > 1)
    @State private var resumeSeconds: Double? = nil   // nil until fetched; applied once duration known
    // Set when a resume seek was SUPPRESSED because the forward-only DV remux is mounted (maybeResume):
    // playback restarts at 0, and progress saves below this floor are skipped so the viewer's real resume
    // point is not regressed by the replay. Cleared once playback passes the floor or on the next title.
    @State private var suppressedResumeFloor: Double? = nil
    // A libmpv resume seek stashed by maybeResume and applied at the first-frame commit instead of immediately.
    // A pre-first-frame absolute seek on a cold libmpv pipeline arms mpv's cache-emptying hold and wedges video
    // output (blank screen + frozen timer); deferring it until the first frame has rendered makes it land as an
    // ordinary warm-pipeline scrub, which is proven to render. Cleared at every fresh mount / teardown so it can
    // never leak onto the wrong mount.
    @State private var pendingLibmpvResumeSeek: Double? = nil
    /// One bounded relative-seek nudge for the direct-AV fallback's cold libmpv resume only. Reset for every
    /// new source/episode and at first frame; it must never become a periodic seek loop.
    @State private var libmpvStartupNudgeIssued = false
    @State private var appliedResume = false
    @State private var lastSaved = -1.0               // last position persisted (throttle)
    @State private var showInfo = true
    @State private var hideTask: Task<Void, Never>?
    @State private var hideDeadline: Date = .distantFuture   // controls auto-hide once now passes this
    @State private var audioTracks: [MPVTrack] = []
    @State private var subtitleTracks: [MPVTrack] = []
    @State private var appliedAutoTracks = false       // auto-select audio/subtitle once per load
    // External subtitles from the account's subtitle add-ons (e.g. OpenSubtitles), listed in the
    // subtitles panel next to the file's embedded tracks. Picking one sub-adds it into mpv, after
    // which it lives in the normal track list; addedSubURLs hides its add-on row.
    @State private var addonSubs: [AddonSubtitle] = []
    @State private var addedSubURLs: Set<String> = []
    @State private var subtitleLoadingURL: String?     // an add-on subtitle is downloading (shows Loading… in its row)
    @State private var addonSubsKey = ""               // type:videoId the fetched list belongs to
    // One-shot latch for the ADD-ON subtitle auto-select fallback (fires when the container has no track in
    // the preferred language chain but an add-on does). Reset wherever appliedAutoTracks resets, so a source
    // hop / episode switch / reload re-evaluates cleanly; latched after one attempt so a failed or declined
    // auto-load never loops.
    @State private var autoAddonSubTried = false
    // Set on ANY manual subtitle choice this load (panel Off / embedded / add-on / community row). Hard-stops
    // every later ASYNC auto-select re-application, so a list that lands after a manual pick never overrides it.
    // Reset wherever autoAddonSubTried resets.
    @State private var userPickedSubtitle = false
    // One-shot latch: the tmdb->tt resolve for the add-on/pooled query id has been kicked off this load. Reset
    // wherever autoAddonSubTried resets, so a reload / stall-recovery can retry a failed resolve exactly once.
    @State private var addonSubsResolveTried = false

    // Community-subtitle system (pooled subs P2, sync offset P3, embedded upload P4). All fail-soft + gated.
    @State private var pooledSubs: [SubtitlePoolClient.PooledSubtitle] = []
    @State private var subtitlePoolRequests = SubtitlePoolClient.RequestOwnership()
    @State private var addedPooledIDs: Set<Int> = []
    @State private var pooledSeededOffset = false
    @State private var embeddedUploadDone = false
    @State private var langContributeDone = false      // the container language-index contribute ran once this session
    @State private var offsetCaptureTask: Task<Void, Never>?
    /// Debounced persist of the manual subtitle offset (W2-B FIX 2). One write per nudge burst instead of one
    /// per press; `pendingSubOffsetSave` carries the value the task will write so a teardown can flush it.
    @State private var subOffsetSaveTask: Task<Void, Never>?
    @State private var pendingSubOffsetSave: (delay: Double, scope: SubtitleTimingScope?)?
    /// Stable local subtitle-timing identity. This is independent from the richer community fingerprint below.
    @State private var subtitleTimingScope: SubtitleTimingScope?
    @State private var subtitleTimingGeneration = 0
    @State private var subtitleDelayAppliedLoadToken: PlayerLoadToken?
    @State private var subFingerprint: String?
    @State private var subFingerprintKey = ""
    @State private var showOptions = false             // options panel (audio / subtitles / aspect / episodes)
    @State private var panelKind: PanelKind = .audio   // which list the options panel shows
    /// The language drilled into from the subtitle list (its canonical key), so the `.subtitleLanguage`
    /// panel lists every sub in that language across embedded + add-on + community sources.
    @State private var subtitleLanguageCode: String? = nil
    /// Session audio-language filter for the IN-PLAYER source panel (iOS parity, #204); nil = Auto, which
    /// falls back to the persisted profile preference.
    @State private var sessionAudioLanguages: [String]? = nil
    @State private var subDelay: Double = 0            // manual subtitle sync, seconds
    @State private var audioDelay: Double = 0          // manual audio sync, seconds
    @AppStorage(SubtitleStyle.Key.font) private var subFont = SubtitleStyle.defaultFont
    @AppStorage(SubtitleStyle.Key.size) private var subSize = SubtitleStyle.defaultSize
    @AppStorage(SubtitleStyle.Key.sizeScale) private var subSizeScale = 1.0
    @AppStorage(SubtitleStyle.Key.color) private var subColor = SubtitleStyle.defaultColor
    @AppStorage(SubtitleStyle.Key.brightness) private var subBrightness = SubtitleStyle.defaultBrightness
    @AppStorage(SubtitleStyle.Key.background) private var subBackground = SubtitleStyle.defaultBackground
    @State private var optionRow = 0                   // highlighted row in the options panel
    // Skip-segment editor (tvOS): the inline iOS/Mac editor bar is unavailable here, so the editor
    // lives in its own focus-driven options panel. State is tvOS-local; submission reuses SkipDBClient
    // (keyless to skip.vortx.tv, plus skipdb.tv / custom when keyed), exactly like the iOS path. The
    // editor is offered for any tt####### title (the same gate the iOS control-bar button uses).
    @State private var skipEditType: SkipDBSubmitView.SegmentType = .intro
    @State private var skipEditStart: Double = 0       // segment start, seconds; Left/Right adjust, Select = playhead
    @State private var skipEditEnd: Double = 30        // segment end, seconds
    @State private var skipEditSubmitting = false
    @State private var skipEditDone = false            // true once the current segment posted (shows the success row)
    @State private var skipEditError: String?          // last submit failure message, shown inline
    @State private var skipEditSubmittedKeys: Set<String> = []   // imdb:S:E:type already submitted this session
    // Time-row adjust acceleration, mirroring the scrubber's press-repeat ramp (10s → 75s on a hold).
    @State private var skipEditStep = 10.0
    @State private var skipEditLastAdjustAt = 0.0
    @State private var skipEditLastDir = 0   // last adjust direction; a reversal resets the ramp so it does not overshoot
    // Cached so the player body does not rebuild a string and rescan skip spans on
    // every playhead tick (audit #1): updated only when their inputs change.
    @State private var metadataLine = ""
    @State private var currentSkip: SkipSegment?
    // Same caching contract as metadataLine above, for the three control-bar gates that were the most
    // expensive thing in the player's body: two full walks of every loaded stream (URL parse per stream,
    // 3315 of them in the field log) and a synchronous mpv chapter fetch, all re-run on every pass.
    @State private var altSourceCount = 0        // playable streams loaded for this title / episode
    @State private var qualityOptionCount = 0    // distinct resolutions across those streams
    @State private var chapterCount = 0          // embedded chapters, refreshed with the skip segments
    @State private var autoSkippedStarts: Set<Double> = []   // segment starts already auto-skipped this episode
    @State private var skipPillDismissedStart: Double?   // segment start whose pill Back dismissed: hides the pill without skipping; re-armed when the playhead leaves that segment
    /// Cumulative seek amount shown in a brief pill while seeking with the chrome HIDDEN (Netflix-style
    /// L/R seek that doesn't reveal the control bar). nil = no pill. Cleared after a short delay.
    @State private var hiddenSeekDelta: Double?
    @State private var hiddenSeekTask: Task<Void, Never>?
    // The open panel's rows, computed ONCE per open/refresh. The rows used to be a
    // computed property read by the panel body, which re-rendered ~4x a second with
    // the clock; for Sources that meant re-ranking a thousand-plus streams on the
    // main thread per frame, freezing the whole player (the "remote stopped
    // responding / sources came up a minute later" reports).
    @State private var panelRows: [OptionRow] = []
    @State private var loadFailed = false              // playback couldn't start
    @State private var loadErrorMsg = ""
    /// CW-resume only: set once we've waited for a freshly-loaded source after the stored link failed, so the
    /// wait-and-hop runs at most once per playback (TVPlayerView is fresh per playback, so it starts false).
    @State private var awaitedFreshSources = false
    @State private var hasStartedPlaying = false
    /// Wall-clock uptime of the genuine first-frame event (set only alongside the true `hasStartedPlaying =
    /// true` transition below, never at the "foreground re-mount was not issued, restore the playing state"
    /// sites - those never actually stopped presentation, so resetting this there would wrongly reopen the
    /// trickplay settle window). Nil until the first real frame of this playback has rendered. Drives
    /// `TrickplayPresentationReadinessPolicy` so a capture cannot land in the startup window the report ties
    /// to a drop burst (report item 8).
    @State private var firstFrameRenderedAt: TimeInterval?
    /// A per-playback token for external-sync sessions. TVPlayerView is fresh per playback, so a rewatch of
    /// the same title carries a new token and scrobbles again; the same-title recovery reloads (switchStream
    /// hop, AVPlayer->libmpv demote, retry) keep it unchanged so the coordinator's once-latches survive and a
    /// completion recorded before the reload is never re-sent as a duplicate history record.
    @State private var playbackSessionID = UUID().uuidString
    @State private var appliedVolume = false   // D5: the persisted default-volume apply runs once per load (re-armed on source switch/reload)
    @State private var appliedSize = false     // the persisted aspect-ratio pick applies once per load, mirroring iOS PlayerScreen
    @AppStorage("stremiox.videoSize") private var videoSize = "original"   // same key iOS uses; re-applied on every load
    // #76: AVPlayer could not open this stream (item status .failed); fell back to libmpv for it in place.
    // Flipping this re-renders `playerSurface` from AVPlayer to the mpv surface on the SAME TVPlayerView,
    // so the heavyweight forceMPV window rebuild is no longer needed for the common AVPlayer load failure.
    @State private var avEngineFailed = false
    /// The engine routing decision, LATCHED once per playback (seeded in onAppear), mirroring
    /// PlayerScreen.engineLatch. `useAVPlayerEngine` is read by `playerSurface` on every SwiftUI body pass
    /// (4-9x/sec during playback), and re-running the full route each render (regex + UserDefaults +
    /// RemoteConfig reads + two log lines) flooded the exported diagnostic log with hundreds of identical
    /// [dv] route lines and cost main-thread time under 4K memory pressure (#76 b163 stutter). Every new
    /// stream mints a new PlaybackRequest that rebuilds this view via `.id(req.id)`, resetting the latch.
    @State private var engineLatch: Bool?
    /// User-invoked mid-title engine override (P3, #76). nil = automatic (the latch/route decides); true =
    /// the viewer forced AVPlayer; false = the viewer forced libmpv. Set by `switchPlayerEngine`, it supersedes
    /// the latch so `playerSurface` re-renders the other engine on the SAME view. `avEngineFailed` still wins
    /// over a manual AVPlayer pick (a failed manual switch falls back to libmpv, no loop), and a fresh
    /// PlaybackRequest resets it via `.id(req.id)` like the latch.
    @State private var manualEngineAVPlayer: Bool?
    /// A user engine switch constructs a new surface. A fresh native-debrid URL must be available to that
    /// surface immediately, rather than mounting the immutable launch URL and correcting it later.
    @State private var engineSurfaceURLOverride: URL?
    @State private var engineSurfaceHeadersOverride: [String: String]?
    @State private var engineSurfaceUsesActiveTuple = false
    /// Source-timeline origin handed to a newly mounted AVPlayer surface. nil means the initial account resume
    /// is still unresolved; a manual engine swap replaces it with the live position before the host is built.
    @State private var avSurfaceResumeOrigin: Double?
    // Timestamp of the last engine switch / demote. A KVO .failed queued on the main thread from the outgoing
    // AVPlayer can land AFTER the surface swap; within a short grace window (and once the AV engine is no
    // longer mounted) endFileError swallows it so it never cancels the fresh mpv load's watchdog or burns the
    // retry budget. iOS port of PlayerScreen.avDemotedAt.
    @State private var engineSwitchedAt: Date?
    // ENGINE OF ORIGIN for that grace window (W2-A item 3a). `endFileError` is a SHARED channel: the AVPlayer
    // engine emits on it and so does libmpv, so "the AV engine is no longer mounted" alone cannot tell the
    // outgoing engine's stale error from the INCOMING engine's own honest, fast failure - and swallowing the
    // latter silently costs the whole post-demote timeout before anything recovers. The demote captures the
    // dismounted AVPlayer's load token here (PlayerLoadToken is UUID-backed, so it can never collide with the
    // mpv load that follows); the swallow then applies only to that exact load. Untagged events keep the old
    // behaviour: an event we cannot attribute is still assumed to be the outgoing engine's, which is the
    // fail-open direction (the grace exists because a stale KVO .failed used to burn the fresh load's budget).
    @State private var demotedEngineLoadToken: PlayerLoadToken?
    // An explicit in-session subtitle pick captured before an engine switch (#76, mandated check 8), re-applied
    // on the new engine's first trackList instead of the preference-derived auto pick. Consumed in
    // autoSelectTracks; only read while userPickedSubtitle is true. Mirror of PlayerScreen.
    @State private var pendingSubtitleReapply: SubtitleChoice?
    // Automatic same-title recovery is allowed to carry the currently selected audio semantically. Unlike a
    // preference, this is one mount-to-mount intent and must never leak into a manual title or episode change.
    @State private var pendingAudioReapply: PlayerRecoveryAudioChoice?
    /// Transport intent belongs to a replacement mount, not to a particular engine.  A surface hand-off can
    /// construct a new controller that defaults to playing before its first property callback, so bind the
    /// intent to the accepted load token and apply it only when that exact load has rendered.
    private struct PendingTransportIntent {
        let paused: Bool
        let episodeGeneration: Int
        let sourceGeneration: Int
        var loadToken: PlayerLoadToken?
    }
    @State private var pendingTransportIntent: PendingTransportIntent?
    // A brief, transient note explaining WHY the engine fell back (e.g. AVPlayer cannot demux DV-in-MKV),
    // so the silent demote the owner reported becomes an actionable explanation. Auto-clears after a few s.
    @State private var engineNote: String?
    @State private var engineNoteTask: Task<Void, Never>?
    // AVPlayer-only START watchdog: AVPlayer can mount, show the chrome, and silently never produce a
    // playable frame (no item error, no timePos tick). The real fix is in AVPlayerEngineController
    // (automaticallyWaitsToMinimizeStalling = false + explicit play() + the [.initial,.new] status race fix),
    // so a working stream now starts within a second or two; this watchdog is only the SAFETY NET for a
    // genuinely stuck stream. A working AVPlayer stream produces its first frame within a second or two, so a
    // no-frame mount is dead weight, not slow-buffering: 5s is long enough to clear a real start yet short
    // enough that the SILENT in-place demote to libmpv (which just tone-maps a DV link to HDR10) plays the SAME
    // source in about 5s instead of stalling 12s on dead chrome. It routes to the SAME libmpv fallback the
    // .failed case uses. AVPlayer-only: libmpv torrents warm up far longer under the 30s loadTimeout budget.
    @State private var avStartWatchdog: Task<Void, Never>?
    // 10s (was 5s, then 20s). A cold-debrid Dolby Vision remux needs ~8-15s
    // to open the mount + run find_stream_info + write its first fragment before AVPlayer shows a frame; the
    // 5s watchdog fired mid-open and CANCELLED the remux before the Profile-7 -> 8.1 RPU converter ever ran
    // (Apple TV device log: mount at 06.851s, classify at 15.129s, converted=0 bytes=0), so every DV file on
    // Apple TV fell back to HDR10. 20s over-covered the remux but left a genuinely dead mount stalling too long;
    // 10s (b165) is the deliberate middle ground: past the 5s mid-open cancel, yet a fast-fail to libmpv, while
    // the 30s loadTimeout + AVPlayer .failed path stay as backstops for a genuinely dead mount.
    private let avStartWatchdogSeconds: Double = 10
    // libmpv resume START watchdog (safety net for the deferred resume seek). maybeResume defers a cold
    // pre-first-frame libmpv resume seek to the first-frame commit; if that first frame never arrives (a
    // genuinely slow or dead source, not the cold-seek wedge the deferral removes) nothing else recovers a
    // libmpv resume - avStartWatchdog is AVPlayer-only and the mid-play stall watchdog needs hasStartedPlaying,
    // which never flips here. This bounds it: reload the SAME source from 0 with a progress floor + a note.
    @State private var libmpvResumeWatchdog: Task<Void, Never>?
    private let libmpvResumeWatchdogSeconds: Double = 12
    // Remux-only start headroom (b170). Once the local HLS master survives AVFoundation's variant filter (the
    // -1002 fix in VortXRemuxHLSServer: a range-unlabeled lifeboat variant now always survives), a real first
    // frame is classify (3.8-8.2s observed) + the startup-segment publish + fetch/decode, so the flat 10s
    // clips a healthy DV remux mount. ONLY the remux lane waits this long; a non-remux AVPlayer no-frame still
    // demotes on the short deadline, and the .failed instant-demote path is untouched (a real "Cannot Open"
    // still bails in ~1s). NO LONGER a demote wall: the remux watchdog is PROGRESS-AWARE (see
    // startAVStartWatchdog), so this is now only the point past which it starts logging hold decisions.
    private let avRemuxStartWatchdogSeconds: Double = 20
    // External-engine remux attachment is asynchronous: first the Mac control request opens the session, then
    // the client waits for classify/init signalling. Cover both real transport budgets plus scheduling margin
    // so the surface cannot demote a healthy mount before its own bounded startup work completes. Once mounted,
    // the normal progress-aware stall policy takes over.
    private let avRemuxAttachWatchdogSeconds = TVAVStartWatchdogPolicy.remoteAttachTimeout(
        controlResourceTimeout: VortXExternalEngine.controlResourceTimeoutSeconds,
        signallingTimeout: VortXRemoteRemuxMount.signallingTimeoutSeconds)
    // Progress-aware remux demote thresholds (the 0.3.13 field fix: a heavy 4K DV title that was still
    // steadily downloading produced its first frame AFTER a fixed 20s wall, so the watchdog demoted a
    // perfectly healthy true-DV session to HDR10 + PCM). Demote only on a TRUE stall: NOTHING moved (no new
    // muxed bytes, no new segment, no classify/init flip) for avRemuxStallDemoteSeconds; a slowly-but-surely
    // producing mount is left alone up to a generous hard ceiling that bounds the spinner for the pathological
    // "always trickling yet never framing" mount. A genuinely dead source is still caught FASTER than the old
    // wall in most cases: the remux fails its open/read within its own 10s rw_timeout (+1 warm retry) and the
    // HLS 404 -> AVPlayer .failed path demotes in ~1s, independent of this watchdog.
    private let avRemuxStallDemoteSeconds: Double = 15
    private let avRemuxStartHardCeilingSeconds: Double = 120
    /// Post-demote start budget for the libmpv leg (W2-A item 3b). A demote disarms the fast progress-aware
    /// watchdog by construction (`startAVStartWatchdog` early-returns once `avEngineFailed` is set), so the ONLY
    /// owner of the mpv re-load used to be the plain 30s `startLoadTimeout` timer: 15s of stall plus 30s of mpv
    /// on the very same URL before any code marked the source dead and hopped. 12s is the same order as the
    /// stall window that just expired and is safe to shorten because it is not a wall: `handleStartTimeout`
    /// EXTENDS by 20s whenever the buffered edge has advanced since it armed, so an mpv leg that is genuinely
    /// pulling bytes keeps its long budget and only a second silent leg on the same dead URL pays the 12s.
    private let avPostDemoteStartTimeoutSeconds: Double = 12
    /// A direct AVPlayer mount that never frames has already consumed its short native budget. libmpv still
    /// gets a meaningful chance for an engine/container-only incompatibility, but the second engine cannot be
    /// allowed to spend the normal 30s plus retry loop on the exact same dead signed link.
    private let directAVFallbackMPVStartTimeoutSeconds: Double = 20
    /// When the AVPlayer start watchdog was armed for the current mount; drives the [dv] time-to-first-frame
    /// line when the timePos handler disarms it. Cleared (one-shot) by that handler.
    @State private var avWatchdogArmedAt: Date?
    @State private var loadTimeout: Task<Void, Never>?
    @State private var autoRetryCount = 0              // bounded auto-recovery attempts before the error overlay
    @State private var reconnecting = false            // showing the "Reconnecting…" auto-retry state
    @State private var autoRetryTask: Task<Void, Never>?
    private let maxAutoRetries = 2                     // transient source hiccups recover; a dead link still falls through fast
    private let autoRetryBackoff = 1.2                 // seconds between auto-retries
    // Auto-failover: when a source spends its retry / stall / warm-up budget, hop to the
    // best-ranked UNTRIED source instead of dropping the viewer at the error overlay.
    @State private var exhaustedURLs: Set<URL> = []    // sources already given up on for this video
    @State private var sourceHops = 0                  // automatic source switches so far for this video
    @State private var refinding = false               // a terminal-failure "Re-find sources" is in flight
    @State private var refindTask: Task<Void, Never>? = nil   // bounded settle-then-retry after a re-find
    @State private var triedYouTubeAppRescue = false   // #95: the YouTube-app trailer hand-off fires at most once per playback
    private let maxSourceHops = 4                      // a fully-dead title still errors out, just later
    // Whether the CURRENTLY loading source was explicitly chosen by the user (seeded from
    // `startedFromExplicitPick`, updated on every in-player source/quality pick and auto-hop). An explicit
    // pick is retried in place on a start-timeout instead of hopping to a different, lower-quality source.
    @State private var currentPickWasExplicit = false
    /// True while the INITIAL source is a Continue-Watching resume (see startedFromResume). Cleared once the
    /// player switches to any other source, so only the first stored-link attempt gets resume-hop treatment.
    @State private var currentPlaybackIsResume = false
    /// Compatibility receipt for the former Continue-Watching-only recovery path. The real gate is now the
    /// joinable `nativeDebridFreshLinkRecovery` transaction, which applies to every native-debrid mount.
    @State private var resumeSourceReresolved = false
    /// Exactly one same-source provider refresh is permitted for the current native-debrid mount. While its
    /// fresh URL is in flight, an engine switch joins rather than mounting the known-stale URL.
    @State private var nativeDebridFreshLinkRecovery = TVNativeDebridRecoveryStateMachine.State()
    /// When the app was last suspended while this player stayed mounted, so the foreground hook knows HOW LONG
    /// it was away. Nothing on-device can tell a live debrid link from an expired one, and re-minting a healthy
    /// one would cost the viewer a reload for nothing, so the suspension length is the only honest gate.
    @State private var suspendedAt: Date?
    /// The play head at that same moment. A backgrounded player keeps its audio running, so a position that
    /// MOVED across the suspension proves the mount survived it - the only cheap, honest evidence that a
    /// revalidation would cost the viewer a reload for nothing. nil (no stamp) is "in doubt": revalidate.
    @State private var suspendedTimePos: Double?
    /// A suspension shorter than this leaves the mount alone: the stored debrid link is almost certainly still
    /// valid and today's recovery ladder covers the rare miss. Past it the link has plausibly expired, and
    /// re-minting here saves the ~18s stall-watchdog wait that used to precede it (diag-21).
    private let mountRevalidationSuspensionSeconds: TimeInterval = 60
    /// How far the play head must have moved across a suspension to count as "it kept playing".
    private let healthyForegroundProgressSeconds: Double = 1
    /// True once this foreground has already booked its one delayed loopback re-check, so a foreground can
    /// never queue more than one (no busy loop). Cleared on every foreground entry.
    @State private var foregroundMountRecheckArmed = false
    /// How long the delayed re-check waits. `VortxNativeServer` clears `publishedPort` on background and only
    /// restarts at scenePhase `.active`, which lands AFTER `willEnterForeground`, so at revalidation time
    /// `StremioServer.base` still names the dead port and the heal below can prove nothing. One re-check past
    /// the restart is what makes the heal reachable at all.
    private let foregroundMountRecheckDelay: TimeInterval = 2.0
    /// The load the mid-play failure handler has already claimed. `PlayerLoadToken` changes on every (re)load,
    /// so recording it makes a SECOND mid-play error on the same mount inert while a genuinely new mount can
    /// still fail - the once-per-load latch that keeps the handler from ping-ponging with the stall watchdog.
    @State private var midPlayFailureOwner: PlayerLoadToken?
    /// Mid-play recoveries handed to the ladder on THIS mount. Deliberately NOT cleared by the first frame:
    /// `autoRetryCount` and `recoveryDeadline` are, so a source that frames for a tick and re-dies replenished
    /// every budget it had just spent and looped at roughly a reload a second, forever (a truncated file, or a
    /// debrid link that 403s after the first range). Cleared only where the mount genuinely changes: a manual
    /// source pick, and a successful hop to a DIFFERENT source.
    @State private var midPlayRecoveryCount = 0
    /// After this many mid-play recoveries on one mount, the source itself is the problem: stop re-loading it
    /// and hop, which is bounded by `sourceHops` and ends on the error overlay.
    private let maxMidPlayRecoveries = 3
    /// PROVENANCE of the value currently in `resumeSeconds`: true only while it is the LIVE PLAY HEAD carried
    /// across a mid-play recovery (`handleMidPlayFailure`, and the hop it spawns), rather than a stored resume
    /// offset from the library. `maybeResume` reads it to skip the near-end guard, which exists to stop a FRESH
    /// play of a nearly-finished title from starting in the credits - a rule that turns a source dying eight
    /// seconds from the end into a restart of the whole episode. One-shot: `maybeResume` clears it as it
    /// consumes the value, and any freshly issued source switch clears it too, so it can never make a stored
    /// near-end offset seek.
    @State private var resumeIsMidPlayRecovery = false
    // First-buffer grace for a big 4K remux on slow debrid: a start-timeout that fires while bytes are
    // still arriving (the demuxer-cache edge advanced since the watchdog armed) extends the wait rather
    // than declaring the source dead. Bounded by the extension count and the overall recovery deadline.
    @State private var lastBufferedAtWatchdog = -1.0
    @State private var bufferGraceUsed = 0
    private let maxBufferGraceExtensions = 3           // up to ~3×20s extra on top of the 30s watchdog, deadline-capped
    /// EVIDENCE, not a control: true only while the demote about to run followed POSITIVE dead-input proof
    /// (`MountProgress.inputProvablyDead` at the start-watchdog branch), as opposed to a renderer-only failure
    /// (AVFoundation cannot demux a source libmpv handles). Only that first case earns the shortened
    /// `avPostDemoteStartTimeoutSeconds` budget; #76 says a healthy-source renderer demote MUST keep the full 30s,
    /// because libmpv legitimately needs more than 12s to first-frame a cold 4K DV url. Set immediately before
    /// the demote call and consumed (cleared) as the first statement of `demoteAVPlayerToMPV`, so it can never
    /// leak into an unrelated later demote.
    @State private var demoteFollowedDeadInput = false
    /// Present only while the direct-AVPlayer -> libmpv one-source fallback is in flight. It carries the exact
    /// URL plus episode/source generations so an old timer can never consume the hop budget for a replacement
    /// source or a pending episode.
    @State private var directAVNoFrameRecovery: DirectAVNoFrameRecovery?
    /// The replacement surface remains absent until the retiring AV/remux producer has acknowledged unwind.
    @State private var avToMPVHandoff: AVToMPVHandoff?
    @State private var avToMPVHandoffBlocked = false
    @State private var avToMPVHandoffTask: Task<Void, Never>?
    // Overall wall-clock cap on PRE-START recovery. The per-budget counters (30s load timeout x
    // retries, 2 torrent warm-ups, 4 source hops, stall reloads) are independent, so on a fully
    // dead title they could chain into minutes of spinner before the error overlay. This single
    // deadline spans the whole attempt (started once on the first load, persists across hops) and
    // gives up after maxRecoverySeconds regardless of which budget is live.
    @State private var recoveryDeadline: Task<Void, Never>?
    private let maxRecoverySeconds: Double = 150
    @State private var skipSegments: [SkipSegment] = []   // resolved skip spans (chapters + crowd timestamps)
    @State private var chapterFractions: [Double] = []    // chapter boundary positions (0...1) for scrubber ticks
    @State private var upNextSuppressed = false           // user chose Watch Credits: hide band + don't auto-advance this episode
    @State private var upNextWantsCredits = false         // which band button is focused (false = Play Now, true = Watch Credits)
    // Sleep timer (parity with iOS/Mac): pause playback after a set time, or stop at the end of the current
    // episode. Transport input never cancels it; only picking "Off" (or a genuine dismiss) does.
    @State private var sleepMinutes: Int? = nil           // nil = off (unless sleepAtEpisodeEnd)
    @State private var sleepAtEpisodeEnd = false          // stop at episode end instead of auto-advancing
    @State private var sleepTask: Task<Void, Never>? = nil
    @AppStorage("stremiox.seekStep") private var seekStep = "10"   // skip step in seconds ("10"/"15"/"30"), shared with iOS
    @AppStorage("stremiox.autoSkip") private var autoSkip = false  // auto-skip intro/credits, shared with iOS/Mac
    private var seekStepSeconds: Double { Double(seekStep) ?? 10 }
    @State private var apiSkipCandidates: [SegmentCandidate] = []   // crowd-sourced spans for the current title
    @State private var skipFetchKey = ""                   // imdb:S:E the crowd spans belong to
    @State private var skipFetchTask: Task<Void, Never>?
    // Current episode (changes when switching via Next/Prev/Episodes or auto-advance). Seeded from
    // the passed url/title/meta in onAppear so the first load is unchanged.
    @State private var curURL: URL?
    /// True when the current source is a direct play from one of the user's connected media servers (its host
    /// matches a stored server url). Used to show the honest "can't direct-play, no transcode in this version"
    /// error instead of the generic source-failure copy (Phase 1 has no transcode negotiation).
    private var curIsMediaServer: Bool {
        guard let host = curURL?.host?.lowercased() else { return false }
        return MediaServerStore.shared.servers.contains { rec in
            rec.urls.contains { (URL(string: $0)?.host?.lowercased()) == host }
        }
    }
    @State private var curHeaders: [String: String]?   // the playing stream's required HTTP headers
    @State private var curTitle: String = ""
    @State private var curMeta: PlaybackMeta?
    /// Session ownership is fixed at presentation. Player callbacks must not re-route writes through
    /// whichever profile is selected after the player has already started.
    @State private var playbackMutationTarget = PlaybackMutationTarget.capture(core: CoreBridge.shared)
    // The episode id the engine Player is ACTUALLY loaded for. Progress attribution (the engine's TimeChanged)
    // keys on the engine Player's own stream request, so writing progress while this disagrees with `curMeta`
    // lands it on the wrong episode. Seeded at launch to the launch episode (the detail page loaded the engine
    // Player for it); re-pointed on every binge advance the moment the engine re-point succeeds, cleared to nil
    // when a re-point could not be confirmed. The periodic tick + exit flush gate on `== curMeta?.videoId`, so a
    // missed re-point degrades to "no engine write" (the correct-identity account write still lands and
    // syncLibraryNow pulls it) instead of a wrong-episode write that clobbers it on mtime.
    @State private var enginePlayerVideoId: String?
    @State private var engineAttributionInitialized = false
    @State private var curDebridRef: DebridPlaybackRef?
    @State private var curSourceStream: CoreStream?
    @State private var sourceSwitchGeneration = 0
    @State private var resumeRetryGeneration = 0
    @State private var episodeSwitchGeneration = 0
    /// Retains only the newest manual Next/Previous request while direct-resume metadata is still becoming
    /// an accepted episode inventory. The pure policy fences it to this exact playback before consuming it.
    @State private var pendingManualEpisodeNavigation: AppleManualEpisodeNavigationIntent?
    // UNIFIED CURRENT-EPISODE IDENTITY (binge-desync fix, publish-at-first-frame). A binge advance used to
    // publish `curMeta`/`curTitle` OPTIMISTICALLY at advance start, before the new stream produced a frame,
    // so an advance interrupted across a background boundary stranded the five episode pointers on THREE
    // different episodes (label E18, playing file E17, Back target E15). Now an advance parks everything it
    // wants to publish here, and the ONE commit point is the incoming file's FIRST FRAME (timePos handler):
    // display identity (curMeta/curTitle), the engine attribution gate (enginePlayerVideoId, re-pointed at
    // engine-load time, only OPENS when curMeta catches up), and the LastStreamStore record all move
    // together, so no surface can ever name an episode the player is not actually rendering. The loading
    // chrome runs off this being non-nil. `issued` flips when the incoming load is actually handed to the
    // player, so OUTGOING-file ticks during the resolve window are never mistaken for the incoming
    // episode's first frame; `url` is what a foreground reconcile re-issues if the load died suspended.
    private struct PendingEpisodeAdvance {
        let meta: PlaybackMeta
        let title: String
        var generation: Int
        var debridRef: DebridPlaybackRef? = nil
        var url: URL? = nil
        var issued = false
        var loadToken: PlayerLoadToken? = nil
        var terminal = false
        var deferredDuration: Double? = nil
        var deferredTrackList = false
        var subtitleTimingScope: SubtitleTimingScope? = nil
    }
    /// A same-token AVPlayer replacement changes item generation without recreating this SwiftUI view. Its
    /// first-frame deadline therefore needs both identities, or a retired replacement task could hop a later
    /// source/episode that happens to share the outer player view.
    private struct AVPostReplacementFirstFrameDeadlineOwner {
        let loadToken: PlayerLoadToken
        let itemGeneration: UInt64
    }
    private struct EpisodeSourceSnapshot {
        let url: URL?
        let headers: [String: String]?
        let stream: CoreStream?
        let debridRef: DebridPlaybackRef?
        let hint: String?
        let binge: String?
        let isTorrent: Bool
        let isLive: Bool
        let engineVideoID: String?
        let engineAddonBase: String?
        let resumeSeconds: Double?
    }
    private struct SupersededEpisodeAdvance {
        var pending: PendingEpisodeAdvance
        let source: EpisodeSourceSnapshot
    }
    @State private var pendingAdvance: PendingEpisodeAdvance?
    @State private var supersededAdvance: SupersededEpisodeAdvance?
    @State private var committedLoadToken: PlayerLoadToken?
    @State private var episodeResolutionTask: Task<Void, Never>?
    @State private var episodeResolutionDeadlineTask: Task<Void, Never>?
    @State private var episodeResolutionOwner: EpisodeResolutionOwner?
    @State private var episodeResolutionAdmitted = false
    private static let episodeResolutionDeadlineSeconds: Double = 30
    // Bounded terminal (EOF) fallback (diag-22). When the EOF handler cannot advance or exit because the
    // requested next target is still resolving (`.persistOutgoingCompletionOnly` / `.markSupersededTerminal`),
    // it arms this deadline instead of trusting an unbounded external resolve - a dead TorBox otherwise froze
    // S7E1 ~15 min on its final frame. `eofFrozenAtTerminal` also un-blinds the stall watchdog, which stands
    // down while mpv reports paused-for-cache (mapped to `buffering`) on that final frame. On expiry - or when
    // the watchdog sees the frame frozen at pos ~= duration - the session advances (if the next load already
    // took, via loadIntoPlayer) or clean-exits, exactly like the last-episode finish path. Retired on any real
    // new load (`loadIntoPlayer`) or exit (`leavePlayback`). 20s: at the binge auto-next resolution's own ~20s
    // hard cap (see BingeSourceMemoryRaceContractTests), so a next source the binge loop can still commit will
    // have issued its load (clearing the flag) before this fires; it sits below the 30s episodeResolution-
    // deadline so the graceful clean-exit pre-empts the harsher "No playable source" error overlay.
    @State private var eofFrozenAtTerminal = false
    @State private var terminalAdvanceDeadlineTask: Task<Void, Never>?
    private static let terminalAdvanceDeadlineSeconds: Double = 20
    /// EOF while the viewer has paused is a completion, not permission to begin the next episode.  The
    /// completion still persists immediately; an explicit later Play releases this one-shot boundary advance.
    @State private var pendingBoundaryAdvanceAfterPlay = false
    @State private var uncommittedIdentityBlocked = false
    @State private var persistenceBlockedForExit = false
    private var hasUncommittedIssuedMedia: Bool {
        uncommittedIdentityBlocked
            || pendingAdvance?.issued == true
            || supersededAdvance?.pending.issued == true
    }
    // Next-episode preparation: settle, rank, and warm the source before the transition. The one live player
    // still mounts and decodes it at admission.
    @State private var preloaded: PreloadedEpisode?
    @State private var preloadPolicy = NextEpisodePreloadPolicy()
    @State private var preloadTask: Task<Void, Never>?
    @State private var preloadTorrentLease: NextEpisodeTorrentPreparationLease?
    @State private var preloadGeneration = 0
    @State private var switchingEpisode = false        // re-entrancy guard: a rapid double Next / Up-Next-Select must not launch two overlapping episode resolves (mirrors iOS goToEpisode)
    @State private var terminalFinalityRefreshTarget: AppleCWTerminalRefreshTarget?
    @State private var terminalFinalityRefreshGeneration: Int?
    @State private var terminalFinalityRefreshTask: Task<Void, Never>?
    /// Continue Watching can seed a direct-resume series with only the local/current-season rows. Keep a
    /// separate request-owned refresh so manual Next can gain a later episode without waiting for EOF.
    @State private var directResumeInventoryRefreshTarget: AppleCWTerminalRefreshTarget?
    @State private var directResumeInventoryRefreshGeneration: Int?
    @State private var directResumeInventoryRefreshTask: Task<Void, Never>?
    /// Set only while this player owns a direct-resume authoritative inventory request. A provisional launch
    /// list is not, by itself, permission to defer a boundary button press.
    @State private var directResumeInventoryRefreshPending = false
    @State private var authoritativeSeriesEpisodes: [CoreVideo]?
    @State private var terminalRewindGate = AppleCWTerminalProgressGate()
    // "Still watching?" idle guard: after a long unattended stretch (no remote input for `idleWatchTimeout`,
    // or `idleAutoAdvanceLimit` back-to-back auto-advances with zero input) pause and ask, so a binge does
    // not run all night. ANY press / swipe re-arms it, so an attended session never trips. Mirrors PlayerScreen.
    @State private var stillWatching = false             // the modal is up (playback paused, awaiting Continue / Stop)
    // Settings toggle (#200): default ON = current behavior. Off disables BOTH triggers below; playback then
    // runs uninterrupted (no idle pause, auto-advance proceeds without asking). SAME key PlayerScreen binds.
    @AppStorage("vortx.stillWatchingPrompt") private var stillWatchingPromptEnabled = true
    // How many back-to-back auto-advances (zero remote input between them) before the binge guard asks
    // "Still watching?". User-configurable in Settings; clamped to >= 1 at the comparison so a stray 0 can
    // never disable the guard silently (the toggle above is the off switch).
    @AppStorage("vortx.stillWatchingAfterEpisodes") private var stillWatchingAfterEpisodes = 4
    @State private var stillWatchingWantsStop = false    // remote focus: false = Continue (default), true = Stop
    @State private var idleDeadline: Date = .distantFuture   // wall-clock idle deadline; pushed forward on every press
    @State private var consecutiveAutoAdvances = 0        // back-to-back auto-advances with no interaction between them
    @State private var stillWatchingPendingAdvance = false  // roll to the next episode when Continue is chosen at a binge boundary
    private static let idleWatchTimeout: TimeInterval = 4 * 60 * 60   // 4h of no interaction -> "Still watching?"
    private static let idleAutoAdvanceLimit = 4                       // 4 back-to-back auto-advances, zero input -> same
    @State private var leftPlayback = false             // set the instant leavePlayback() runs, so a pending EOF backfill never resurrects a stopped player
    @State private var warmedID: String?               // next episode whose source was pre-warmed
    @State private var warmNextTask: Task<Void, Never>?
    @State private var curHint: String?                // quality signature of what is playing now
    @State private var curBinge: String?               // bingeGroup of what is playing now (drives sticky auto-next)
    // Mid-playback stall recovery: a watchdog reloads the stream in place when the
    // position freezes while NOT buffering or paused (the black-screen / hard-stall
    // case), bounded so a genuinely dead source still falls through to the overlay.
    @State private var stallWatchdog: Task<Void, Never>?
    /// Exact AVPlayer-item ownership captured when the post-first-frame watchdog starts observing. A
    /// same-token fresh-item transaction advances this generation, so a delayed watchdog can never recover a
    /// retired item or turn ordinary buffering into the legacy full re-load path.
    @State private var avStallWatchdogItemGeneration: UInt64?
    @State private var avPostReplacementFirstFrameDeadline: Task<Void, Never>?
    @State private var avPostReplacementFirstFrameDeadlineOwner: AVPostReplacementFirstFrameDeadlineOwner?
    private let avPostReplacementFirstFrameDeadlineSeconds: Double = 12
    @State private var lastObservedTime = -1.0
    @State private var stalledTicks = 0
    @State private var stallRecoveries = 0
    @State private var stallStableProgressTicks = 0
    @State private var stallNudgesIssued = 0          // B2 seek-nudge counter, per continuous stall episode
    // The six-second playhead watchdog cannot see a source that advances briefly between 0-byte cache refills.
    // This is a separate, edge-driven owner for that rapid loop, bounded to one reload then one source hop.
    @State private var rapidBufferingRecovery = PlayerRapidBufferingRecoveryState()
    @State private var rapidBufferingSuppressedUntilUptime: TimeInterval = 0
    @State private var midPlayBufferedReloadUsed = false  // B3 one same-engine reload before any mid-play demote
    // Direct-resume launches (Continue Watching) start without an episode list;
    // it loads in the background so Next/auto-advance still work.
    @State private var loadedEpisodes: [CoreVideo] = []
    @State private var curIsTorrent = false             // current stream is a torrent (switches/auto-next update it)
    @State private var curIsLive = false                // current stream is live HLS/IPTV (switches/auto-next update it)
    @State private var torrentStatus: String?           // live warm-up line ("Connecting to peers · 12 connected")
    @State private var torrentWarmupsUsed = 0           // bounded warm-up rounds before the error overlay
    @State private var playSpeed = 1.0                  // mpv playback speed (sticky for the session)
    @State private var showStats = false                // live playback info overlay
    @State private var statsRows: [(String, String)] = []
    @State private var showStreamQR = false             // QR overlay sharing the playing link to a phone
    @StateObject private var scrubThumbnails = ScrubThumbnailsStore()
    @State private var localTrickplayCaptureBreaker = TrickplayLocalCaptureBreaker()
    @State private var lastLocalTrickplayCapture = -1000.0
    @State private var localTrickplayCaptureInFlight = false
    @State private var localTrickplayCaptureGeneration: UInt64 = 0
    @State private var assetSanityAttempt = EpisodicAssetSanityAttempt<PlayerLoadToken>()
    @State private var assetSanityTrackListToken: PlayerLoadToken?
    @State private var assetSanityRequestedResume = 0.0
    @State private var assetSanityDeferredStartToken: PlayerLoadToken?
    @State private var assetSanityDeferredStartPosition = 0.0
    @State private var assetSanityStartEffectsToken: PlayerLoadToken?
    @State private var assetSanityObservationTask: Task<Void, Never>?
    @State private var assetSanityObservationToken: PlayerLoadToken?
    @State private var exitAcceptedLoadToken: PlayerLoadToken?
    /// Wall-clock trickplay capture driver (player-agnostic backstop to the timePos tick). See startTrickplayCaptureTimer.
    @State private var trickplayCaptureTimer: Task<Void, Never>?
    @State private var lastFrameDropReceiptAt = 0.0
    @State private var lastFrameDropCount = 0
    @State private var trickplayCaptureAttemptsSinceReceipt = 0
    @State private var trickplayCaptureCompletionsSinceReceipt = 0
    @State private var trickplayCaptureNilSinceReceipt = 0
    /// Both engines use the same clamped cadence that community coverage/VTT advertises. The libmpv GPU
    /// path remains bounded to one in-flight capture with a watchdog; frame-drop telemetry never suppresses it.
    private static var trickplayCaptureIntervalSecs: Double {
        Double(RemoteConfig.snapshot.captureIntervalSecs)
    }

    /// Which on-screen control is currently highlighted (driven by remote left/right, not SwiftUI focus).
    private enum Control: Hashable { case close, scrub, restart, back, play, fwd, audio, subs, aspect, playback, prev, next, episodes, chapters, sources, quality, settings, skipEdit }
    private enum PanelKind: String { case audio, audioSettings, subtitles, subtitleSettings, subtitleLanguage, aspect, playback, episodes, chapters, sources, sourceAudio, quality, playerSettings, engine, sleep, skipEditor }
    @State private var selected: Control = .play
    @State private var lastButton: Control = .play     // remembered button-row spot, so up-then-down returns to it
    // Scrub-to-seek: left/right on the scrubber moves a preview playhead (accelerating on rapid/held
    // presses); the seek commits ~0.6s after the last move, or on Select. One mpv seek per gesture, so
    // holding to travel far doesn't thrash the decoder.
    @State private var scrubbing = false
    @State private var scrubTarget = 0.0
    @State private var scrubStep = 10.0
    @State private var lastScrubAt = 0.0
    @State private var scrubCommit: Task<Void, Never>?
    /// Seek-in-flight guard: the target of the last user-committed absolute seek (scrub commit, Restart,
    /// the resume seek), plus when it was issued. While set, incoming timePos ticks that are still FAR
    /// from the target are ignored instead of overwriting `currentTime`: after a committed seek, mpv can
    /// keep emitting ticks from the OLD position for seconds (an exact seek on a big remux decodes from
    /// the keyframe + refills the cache first, and back-and-forth scrubbing queues several seeks), and
    /// those stale ticks clobbered the freshly committed position - so exiting right after HEAVY
    /// scrubbing saved a stale spot ("progress stuck at 12:20 after scrubbing far past it"). Cleared as
    /// soon as a tick lands near the target (the seek settled) or the settle window expires (the seek
    /// genuinely ended elsewhere - clamped at EOF, failed - so live ticks win again).
    @State private var inFlightSeekTarget: Double?
    @State private var inFlightSeekIssuedAt = 0.0
    private let inFlightSeekSettleWindow = 10.0   // seconds before stale-looking ticks are trusted again
    private let inFlightSeekSnapRadius = 5.0      // a tick this close to the target means the seek landed
    /// The engine's REAL time-pos from the latest raw tick, recorded BEFORE the in-flight seek guard drops
    /// stale ticks. The post-first-frame resume watchdog uses it to tell a landed seek from a wedged one
    /// (the UI-side currentTime stays optimistically pinned to the seek target while the guard is active).
    @State private var lastRawTimePos: Double = -1
    /// Safety net for the deferred resume seek issued at first frame (see armPostFrameResumeSeekWatchdog).
    /// A slow / non-Range source can leave mpv parked at the pre-seek position indefinitely, and the plain
    /// stall ladder answers that with a same-source reload at the SAME offset, wedging again and re-arming
    /// the DV->HDR10 display switch every cycle (the Harry Potter stall loop).
    @State private var postFrameResumeSeekWatchdog: Task<Void, Never>?
    /// The exact deferred-resume obligation owned by the current libmpv mount.  A plain task is not
    /// enough: a late tick from an old source must not settle, or cancel, a newer source's watchdog.
    @State private var postFrameResumeSeekWatchdogTarget: Double?
    @State private var postFrameResumeSeekWatchdogOwner: PlayerLoadToken?
    private let postFrameResumeSeekWatchdogSeconds: Double = 12
    /// Wall-clock when settled playback first ticked inside the last-10% "watched" zone, nil while
    /// outside it (or while scrubbing). The watched marker requires a few seconds of dwell here, so a
    /// scrub commit that merely LANDS past 90% can no longer mark the episode watched on its first tick.
    @State private var watchedZoneSince: Double?
    private let plog = Logger(subsystem: "com.stremiox.app", category: "tvplayer")

    private var controlsHidden: Bool { !showInfo && !showOptions && !loadFailed }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            playerSurface

            // BINGE-ADVANCE SURFACE GATE: while an episode advance is in flight (parked by play(episode:),
            // cleared exactly at commitPendingAdvanceOnFirstFrame), the surface underneath still holds the
            // OUTGOING episode: during the resolve window the old file is literally still rendering, and
            // after the incoming load is issued AVPlayerLayer retains its last decoded contents across
            // replaceCurrentItem (the mpv Metal layer likewise keeps its last drawable) until the incoming
            // file's first frame. That read as "plays seconds of the OLD episode" on a binge advance. Hold
            // an opaque cover for the whole pendingAdvance window; it drops on the same main-actor turn as
            // the first-frame commit, so the first visible frame IS the committed episode. The published
            // identity itself is untouched (still first-frame commit); this gates only what is VISIBLE.
            // Source switches (switchStream) never park a pendingAdvance and are deliberately not covered.
            if pendingAdvance?.issued == true {
                Color.black.ignoresSafeArea()
            }

            // UIKit owns ALL remote input. Presented in a dedicated key window so the focus engine has no
            // competitor and every press falls through to here. Swipes come via the pan recognizer.
            RemoteCatcher(
                onPress: { handlePress($0) },
                onSwipe: { noteInteraction(); if !stillWatching { showControls() } },
                accessibilityItems: remoteAccessibilityItems,
                accessibilityFocusedID: remoteAccessibilityFocusedID,
                accessibilityAnnouncement: remoteAccessibilityAnnouncement,
                onAccessibilityFocus: remoteAccessibilityFocus,
                onAccessibilityActivate: remoteAccessibilityActivate,
                onAccessibilityAdjust: remoteAccessibilityAdjust,
                onAccessibilityEscape: { handlePress(.menu) }
            )

            if buffering && !loadFailed {
                VStack(spacing: Theme.Space.md) {
                    BigSpinner()
                    if let torrentStatus {
                        Text(torrentStatus)
                            .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    } else if let pending = pendingAdvance {
                        // Publish-at-first-frame: the label/selector deliberately stay on the OUTGOING
                        // episode until the incoming file renders, so THIS line is what says an advance
                        // is in flight (the directive's "Loading episode…" chrome, keyed off the pending
                        // advance, never off a prematurely-advanced curMeta).
                        Text("Loading S\(pending.meta.season ?? 0)E\(pending.meta.episode ?? 0)…")
                            .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    } else if reconnecting {
                        Text(isCurrentLiveStream ? "Reconnecting live stream…" : "Reconnecting…  (\(autoRetryCount)/\(maxAutoRetries))")
                            .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    } else if sourceHops > 0, !hasStartedPlaying {
                        Text("Source failed, trying another…  (\(sourceHops)/\(maxSourceHops))")
                            .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showInfo && !showOptions && !loadFailed { controlBar }
            if showOptions { optionsPanel }
            if loadFailed { loadErrorOverlay }
            if refinding { refindingOverlay }
            if let seg = skipPillSegment { skipPill(seg) }
            if controlsHidden, let d = hiddenSeekDelta { hiddenSeekPill(d) }
            if controlsHidden, upNextRemaining != nil || isCreditsUpNext { upNextBand }
            if showStats, !loadFailed { statsOverlay }
            if showStreamQR, let link = shareLink {
                StreamLinkQRView(title: isTorrentPlayback ? "Magnet link" : "Stream link", link: link)
            }
            if let note = engineNote {
                Text(note)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.lg)
                    .padding(.vertical, Theme.Space.md)
                    .frame(maxWidth: 900)
                    // Floating engine note over the video: Liquid Glass on tvOS 26, the frosted material below.
                    .glassChrome(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)) {
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(.ultraThinMaterial)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, Theme.Space.xl)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            if stillWatching { stillWatchingOverlay }
        }
        .onAppear {
            VXProbeState.shared.setRoute("player")
            // #130 mitigation: hold a short background assertion while a loopback (torrent) stream plays, so a
            // quick app-switch away does not immediately suspend us and tear down the server listener. No-op
            // for direct/debrid URLs; the in-node rebind is the real recovery for the long-background case.
            LoopbackPlaybackAssertion.begin(for: url)
            // Mark the engine player-active so CoreBridge skips the library-branch In-Library re-decode of
            // the meta_details payload while the player is up (the detail page is not on screen). Cleared in
            // onDisappear. Depth-counted so a nested mount cannot clear it early.
            core.setPlayerActive(true)
            if !engineAttributionInitialized {
                enginePlayerVideoId = initialEnginePlayerVideoId ?? (isEpisodePlaybackContext ? nil : meta?.videoId)
                curDebridRef = debridRef
                curSourceStream = initialSourceStream
                engineAttributionInitialized = true
            }
            if curURL == nil {   // seed from initial request
                curURL = url; curTitle = title; curMeta = meta
                curIsTorrent = torrent; curHeaders = headers; curIsLive = initialLiveMode
                currentPickWasExplicit = startedFromExplicitPick   // honor an explicit launch pick on the first start-timeout
                currentPlaybackIsResume = startedFromResume        // a resume plays exact first but hops on a HARD failure
                maybeRouteToDefaultExternalPlayer()
            }
            refreshSourceOptionCounts()   // seed the cached control-bar gates for this playback
            scrubThumbnails.configure(localCacheKey: trickplayLocalCacheKey)
            configureCommunityTrickplayProvisional()
            startTrickplayCaptureTimer()   // wall-clock capture backstop (fires on both engines)
            if curHint == nil { curHint = sourceHint }
            if curBinge == nil { curBinge = bingeGroup }
            establishSubtitleTimingScopeIfAvailable()
            // Engine picked ONCE per playback (mirrors PlayerScreen.engineLatch). The seed writes the same
            // Bool the nil-latch renders just computed, so `playerSurface` does not remount; a new stream
            // rebuilds the whole view via `.id(req.id)` and reseeds. In-place switchStream deliberately
            // keeps the launch route, and the demote lane (avEngineFailed) stays outside the latch.
            if engineLatch == nil { engineLatch = routedToAVPlayer }
            // Guardrail (message-only): an "Always libmpv" engine override short-circuits the router BEFORE
            // the DV rules, silently disabling the true-DV remux lane; a DV title then tone-maps to HDR10
            // with no clue why. Say so once, in the log AND on screen, so the setting is discoverable.
            if StreamRanking.isDolbyVision(sourceHint ?? ""), PlayerEngineRouter.currentOverride == .mpv {
                DiagnosticsLog.log("dv", "engine override 'Always libmpv' is forcing libmpv on a Dolby Vision stream; the DV remux lane is disabled")
                showEngineNote("Player engine override is forcing libmpv, so Dolby Vision plays as HDR10. Set Settings > Player engine to Auto for true Dolby Vision.")
            } else if StreamRanking.isDolbyVision(sourceHint ?? ""),
                      DVDisplaySupport.isCapable,
                      PlayerEngineRouter.isDVRemuxCandidate(url),
                      !PlayerEngineRouter.dvRemuxEngaged(dvDisplayCapable: DVDisplaySupport.isCapable) {
                // Same guardrail, second cause: the DV-for-MKV lane is OFF, so the router sent a Dolby Vision
                // title this display COULD have shown in true DV down the libmpv tone-map lane. That decision
                // was invisible to the viewer (the engine only writes an internal "requesting HDR10 output"
                // line), which is how a stray Off went hours unnoticed. Gated on a DV-CAPABLE display and a
                // real remux candidate so it names the SETTING and never a hardware limit: a display that
                // cannot present DV keeps the honest "HDR10 output" note at first frame instead.
                DiagnosticsLog.log("dv", "Dolby Vision for MKV is off: a DV title routed to the libmpv HDR10 lane on a DV-capable display")
                showEngineNote("Dolby Vision for MKV is Off, so this plays as HDR10. Settings > Dolby Vision for MKV.")
            }
            startStallWatchdog()
            scheduleHide(); startHideLoop(); noteInteraction()   // arm the "Still watching?" idle deadline at open
            hydrateDirectResumeMetadataForPlayerUI()
            hydrateDirectResumeSeriesInventory()
            showInfo = true; selected = .play; scheduleHide()
            // The AV surface is intentionally withheld while an account resume lookup is unresolved, so its
            // synchronous `makeHostView` cannot mount a remux at zero before the real origin arrives.
            if !useAVPlayerEngine || initialAVResumeOrigin != nil { startLoadTimeout() }
            UIApplication.shared.isIdleTimerDisabled = true   // stop the Apple TV screensaver during playback
            if let explicit = startAtSeconds {
                // Trakt "Resume from <time>": the viewer tapped a position another device reported. Seek there
                // WITHOUT consulting the engine/account resume, and leave the stored resume point untouched:
                // this is one playback's start position, not a new source of truth. From here the engine
                // records its own position exactly as if the viewer had scrubbed to this spot by hand, so
                // VortX's resume authority is never written by Trakt. Checked before startFromZero because a
                // caller sets one or the other, never both.
                resumeSeconds = explicit; maybeResume()
            } else if startFromZero {
                // "Play from start": begin at 0:00 without consulting the engine/account resume. The stored
                // resume point is deliberately left untouched (only WHERE playback begins changes), so a later
                // Resume still seeks to it. resumeSeconds = 0 makes maybeResume a no-op seek (its r > 5 guard).
                resumeSeconds = 0; maybeResume()
            } else if let m = curMeta {
                if let engineResume = core.engineResumeSeconds(for: m), engineResume > 5 {
                    resumeSeconds = engineResume; maybeResume()       // engine has a real position: use it
                } else {
                    // Engine has no entry - OR answered "start fresh" (0, including its stale-video_id
                    // mismatch branch). The engine's library copy can lag the account: it hears TimeChanged
                    // on a throttle and its video_id can be left stale by a watched/unwatched toggle, while
                    // this device's exit save already put the fresh position on the account. Trusting the
                    // bare 0 replayed the title from 0:00 and the early exit then SAVED ~0 over the real
                    // position (the "scrubbed to 06:20, reopened at the beginning, position lost" report).
                    // Consulting the account here is episode-safe by construction: resumeOffset does its
                    // own video_id match and returns 0 for a different episode, so the wrong-episode resume
                    // the engine's 0-answer guards against cannot happen. Overlay profiles keep their own
                    // private-history path inside resumeOffset, exactly as before.
                    Task { @MainActor in
                        resumeSeconds = await account.resumeOffset(for: m)
                        startLoadTimeout()
                        maybeResume()
                    }
                }
            } else {
                resumeSeconds = 0   // selftest / no library context, nothing to resume
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: HDRDisplayMode.userHintNotification)) { note in
            // HDRDisplayMode refused a display-mode switch because Match Dynamic Range is OFF (posted once
            // per process): surface the exact tvOS setting to the viewer instead of only logging it. This is
            // the #1 silent-defeat path for DV/HDR (the toggle is OFF by default on every Apple TV).
            if let message = note.userInfo?["message"] as? String { showEngineNote(message) }
        }
        // FOREGROUND RECONCILE (binge-desync fix, leg 2): the player is deliberately NOT torn down on
        // background (see onDisappear), so an episode advance can straddle a background boundary. Outside
        // an advance the published episode and the loaded file agree BY CONSTRUCTION (the advance is
        // published only at the incoming file's first frame), so the only state a suspension can strand
        // is a pending advance - reconcile exactly that on return to foreground. Pairs with (never
        // replaces) MPVMetalViewController.enterForeground, which restores video decode + play state.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            suspendedAt = Date()   // only read on the way back in; see revalidateMountOnForeground
            suspendedTimePos = currentTime   // ... paired with the play head, so a mount that kept playing is provable
            // A backgrounded app can be killed outright (jetsam, or the user swiping it away) with no further
            // callback, and `leavePlayback` would then never run. Flush the debounced sync offset here too, so
            // the last window in which a write is still possible is the one that takes it.
            flushPendingSubOffsetSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            let suspended = suspendedAt.map { Date().timeIntervalSince($0) } ?? 0
            let playHead = suspendedTimePos
            suspendedAt = nil
            suspendedTimePos = nil
            foregroundMountRecheckArmed = false   // one delayed re-check per foreground, never a queue of them
            reconcileAdvanceOnForeground()
            // The advance reconcile owns a straddled episode switch; this owns the mount underneath a
            // playback that never moved. They are mutually exclusive by their own guards (a re-issued
            // advance clears hasStartedPlaying, which is exactly what this one requires).
            revalidateMountOnForeground(suspendedFor: suspended, playHeadAtSuspension: playHead)
        }
        // Sources keep arriving after playback starts (add-ons answer at their own pace), and the Sources /
        // Quality buttons must appear when they do. `streamsEpoch` bumps ONLY when the engine's ready-stream
        // set actually changed, so this is the exact, cheap edge the cached counts need: no per-body-pass walk,
        // and no waiting for the viewer to open a panel before the buttons show up.
        .onChange(of: core.streamsEpoch) { _ in
            refreshSourceOptionCounts()
            establishSubtitleTimingScopeIfAvailable()
            if appliedAutoTracks {
                restoreSubtitleTimingOffsetIfReady()
                applyCurrentSubtitleDelayIfReady(force: false)
            }
        }
        .onChange(of: account.streamSources) { _ in
            // Account/profile changes replace the add-on and credential authority behind a preload. A source
            // resolved under the old account must never be published into the new one.
            invalidateNextEpisodePreparation(reason: "stream sources changed")
        }
        .onChange(of: allEpisodes.map(\.id)) { _ in
            consumePendingManualEpisodeNavigationIfReady()
        }
        .onChange(of: sourceSwitchGeneration) { _ in
            cancelDirectResumeInventoryRefresh()
            clearPendingManualEpisodeNavigation(reason: "source replacement")
        }
        .onDisappear {
            let integrityOwner = exitAcceptedLoadToken ?? coordinator.player?.activeLoadToken
            let assetSanityAccepted = assetSanityAttempt.isAccepted(owner: integrityOwner)
            core.setPlayerActive(false)   // balance the onAppear +1; re-enables the In-Library re-decode
            LoopbackPlaybackAssertion.end()   // #130: release the loopback-playback background assertion
            invalidateNextEpisodePreparation(reason: "player view disappeared")
            invalidateLocalTrickplayCapture()
            cancelAssetSanityObservationDeadline()
            hideTask?.cancel(); loadTimeout?.cancel(); recoveryDeadline?.cancel(); autoRetryTask?.cancel(); skipFetchTask?.cancel(); stallWatchdog?.cancel(); avStartWatchdog?.cancel(); avPostReplacementFirstFrameDeadline?.cancel(); libmpvResumeWatchdog?.cancel(); clearPostFrameResumeSeekWatchdog(); avToMPVHandoffTask?.cancel(); engineNoteTask?.cancel(); trickplayCaptureTimer?.cancel(); sleepTask?.cancel(); terminalAdvanceDeadlineTask?.cancel()
            cancelTerminalFinalityRefresh()
            cancelDirectResumeInventoryRefresh()
            invalidateEpisodeResolution()
            // Community trickplay: contribute this device's captured frames as a shared sprite-sheet
            // (first-writer-wins, background, gated; no-op if the community already had a set). Both engines
            // capture frames now (AVPlayer via AVPlayerItemVideoOutput). Independent of the engine-teardown rules below.
            if assetSanityAccepted {
                scrubThumbnails.finishAndUploadIfNeeded(srcHeight: videoHeight)
            }
            NowPlayingCenter.clear()   // #157: drop the system Now Playing card + its transport targets on close
            if terminalRewindGate.permitsExitProgressFlush {
                saveProgress(
                    at: currentTime, thenSyncEngine: true, acceptedOwner: integrityOwner
                )   // exit flush: save, THEN pull the engine's library fresh (no-op for live)
            }
            // R9: same floor guard the periodic (:562) and saveProgress paths use. A suppressed DV-remux resume
            // restarted playback at 0, so this final flush must not regress the ENGINE resume point below where
            // the viewer actually was. saveProgress(at:) just above already cleared the floor if playback passed it.
            // Attribution gate (binge-desync fix): only write to the engine Player when it is loaded for the
            // episode curMeta names. After a binge advance whose engine re-point could not be confirmed, this
            // skips the wrong-episode flush; the correct-identity account write (saveProgress above) still lands.
            if terminalRewindGate.permitsExitProgressFlush,
               assetSanityAccepted, !isCurrentLiveStream,
               enginePlayerVideoId == curMeta?.videoId,
               suppressedResumeFloor == nil || currentTime >= (suppressedResumeFloor ?? 0) {
                core.reportProgress(timeSeconds: currentTime, durationSeconds: duration,
                                    target: playbackMutationTarget)   // flush final position (never for live)
            }
            exitAcceptedLoadToken = nil
            // The engine is NOT torn down here: RootView presents the player with `.id(req.id)`, so any
            // path that mints a fresh PlaybackRequest id rebuilds the player → onDisappear → would
            // destroy an engine that's about to be reused. (In-player source picks go through switchStream
            // in place and never rebuild, but tearing the engine down on every disappear is still wrong.)
            // Teardown happens only on genuine exits (see leavePlayback()), which onClose routes through.
            // App-backgrounding is deliberately NOT a teardown trigger: tvOS suspends the app AND the
            // embedded server together, the same player stays mounted, and returning to .active resumes
            // on the same engine - closing it on .background would kill background-resume without
            // preventing any leak (an app the system kills while suspended takes the server, and every
            // engine with it, down too). In-session leaks are covered by the switch / advance / exit paths.
            UIApplication.shared.isIdleTimerDisabled = false   // let the screensaver resume once the player closes
        }
    }

    // MARK: - Video surface (engine-routed under the same chrome)

    /// Whether to mount the AVFoundation engine instead of libmpv for this stream (#76). The decision comes
    /// from `engineLatch` (seeded ONCE in onAppear); the 1-2 pre-onAppear renders fall through the nil latch
    /// to the same computed value, so the seed cannot swap the mounted surface. The demote lane
    /// (`avEngineFailed`) stays OUTSIDE the latch so an AVPlayer failure still falls back to libmpv in place.
    private var useAVPlayerEngine: Bool {
        if forceMPV || avEngineFailed || avToMPVHandoff != nil || avToMPVHandoffBlocked { return false }
        if let forced = manualEngineAVPlayer { return forced }
        if initialEnginePreference == .mpv { return false }
        if initialEnginePreference == .avfoundation, canUseAVPlayerEngine { return true }
        return engineLatch ?? routedToAVPlayer
    }

    /// Whether AVPlayer can actually PLAY the ACTIVE stream, gating the "AVPlayer" row in the engine picker.
    /// The old form forced `.avfoundation` through the router, which returns AVPlayer for ANY non-torrent URL
    /// (the override bypasses every container rule), so it offered AVPlayer for a plain non-DV MKV/AVI/TS,
    /// then a pick mounted the DV remux on non-DV content (shouldDVRemux checks container only), classify
    /// rejected, and demote-bounced. Gate on real playability instead: an AVPlayer-native container
    /// (mp4/mov/m4v/HLS), a Dolby Vision title the DV remux lane can carry, OR (#147) a non-DV Matroska
    /// title the PLAIN remux lane can carry (which restores the AVPlayer pick for ordinary MKVs, this time
    /// on a lane built for them). And gate on the ACTIVE source
    /// (curURL / curIsTorrent), not the immutable LAUNCH url, so an in-player switch to a torrent no longer
    /// offers a dead AVPlayer row that would feed a loopback torrent URL into AVPlayer.
    private var canUseAVPlayerEngine: Bool {
        if audioSidecarURL != nil { return false }
        let activeURL = curURL ?? url
        let loopback = activeURL.host == "127.0.0.1" || activeURL.host == "localhost"
        if curIsTorrent || loopback { return false }
        return PlayerEngineRouter.isAVPlayerContainer(activeURL) || activeAVPlayerWouldRemux
            || activeAVPlayerWouldPlainRemux
    }

    /// True when routing the ACTIVE source to AVPlayer would mount the forward-only DV remux (a Dolby Vision
    /// title in a container AVFoundation cannot demux, with the remux lane enabled for this display). Drives
    /// both the engine-picker gate and the resume-floor handling on a switch. Uses the router's non-isolated
    /// predicates (dvRemuxEngaged + isDVRemuxCandidate), i.e. the exact condition
    /// AVPlayerEngine.loadFile's shouldDVRemux evaluates, without the @MainActor wrapper. `dvRemuxEngaged`
    /// (not `dvRemuxEnabled`) so an explicit "Prefer AVPlayer" pick predicts the same DV mount the engine
    /// will actually make; a mismatch here would hide the AVPlayer row for the very title it was picked for.
    private var activeAVPlayerWouldRemux: Bool {
        let activeURL = curURL ?? url
        let isDV = StreamRanking.isDolbyVision(curHint ?? sourceHint ?? "")
        return isDV
            && PlayerEngineRouter.dvRemuxEngaged(dvDisplayCapable: DVDisplaySupport.isCapable)
            && PlayerEngineRouter.isDVRemuxCandidate(activeURL)
    }

    /// #147: true when routing the ACTIVE source to AVPlayer would mount the forward-only PLAIN (non-DV)
    /// remux: a non-DV Matroska source with the plain lane enabled and HLS delivery live. Re-opens the
    /// engine-picker AVPlayer row for plain MKVs (Picture in Picture lives on AVPlayer); the resume handling
    /// needs no twin here because maybeResume gates on the runtime `isRemuxMounted`, which a plain mount sets
    /// too. Mirrors AVPlayerEngine.loadFile's `wantsPlainRemux` (minus the reactive force flag); mirrors
    /// PlayerScreen.activeAVPlayerWouldPlainRemux on iOS/macOS.
    private var activeAVPlayerWouldPlainRemux: Bool {
        let activeURL = curURL ?? url
        let isDV = StreamRanking.isDolbyVision(curHint ?? sourceHint ?? "")
        return !isDV
            && VortXRemuxHLSServer.deliveryEnabled
            && PlayerEngineRouter.shouldPlainRemux(url: activeURL)
    }

    /// Origin available before AVPlayer's initial synchronous mount. A nonzero engine resume is synchronous;
    /// when only the account can answer, nil keeps the AV surface unmounted until `onAppear` resolves it.
    private var initialAVResumeOrigin: Double? {
        if initialLiveMode || startFromZero { return 0 }
        if let explicit = startAtSeconds { return explicit }
        if let configured = avSurfaceResumeOrigin ?? resumeSeconds { return configured }
        guard let m = curMeta ?? meta else { return 0 }
        if let engineResume = core.engineResumeSeconds(for: m), engineResume > 5 { return engineResume }
        return nil
    }

    /// The raw routing computation, mirroring PlayerScreen.routedToAVPlayer. Consulted only for the pre-onAppear
    /// renders and once to seed `engineLatch`; never re-consulted mid-playback, so a Settings / RemoteConfig
    /// refresh cannot flip the engine live. Routes on the RAW (un-proxied) launch URL: torrents and loopback
    /// URLs always stay on libmpv (the router enforces this), and Dolby Vision in an AVPlayer-playable
    /// container / remote HLS auto-routes to AVPlayer for true DV passthrough, AirPlay, and Picture in
    /// Picture. The DV flag comes from the launching stream's quality text (`sourceHint`).
    private var routedToAVPlayer: Bool {
        // A yt-direct adaptive pair NEEDS libmpv (the audio sidecar rides mpv --audio-files; AVPlayer
        // would play the video-only stream silent), so it bypasses AVPlayer routing entirely.
        if audioSidecarURL != nil { return false }
        // V2 (trailerClientResolverV2): the resolver's HLS-master fallback hands a googlevideo manifest as the
        // trailer URL with NO sidecar, and router rule (4) below would divert any remote .m3u8 to AVPlayer,
        // which replays it under its own UA (googlevideo 403s a UA that does not match the minting client) and
        // bypasses the mpv trailer pipeline. So under the flag pin EVERY trailer to libmpv (identical to what
        // rule (5) already picks for today's mp4 trailer URLs). Inert when the flag is off. Mirrors
        // PlayerScreen.routedToAVPlayer on iOS/macOS.
        if isTrailer, YouTubeDirectResolver.isV2Enabled { return false }
        // Hard invariant: a trailer manifest must NEVER reach the router's AVPlayer HLS diversion. Debug-only.
        assert(!(isTrailer && PlayerEngineRouter.isHLS(url)),
               "trailer manifest must route to libmpv, never AVPlayer")
        let loopback = url.host == "127.0.0.1" || url.host == "localhost"
        let isDV = StreamRanking.isDolbyVision(sourceHint ?? "")
        // tvOS: DVDisplaySupport.isCapable is constant true (the Apple TV negotiates DV over HDMI), so the DV
        // mandate's remux lane engages for DV MKVs here too. Stable across renders (no engine flip mid-play).
        // The live delivery flag gates rule (4b)'s Matroska half: with the HLS delivery lane rolled back a
        // plain MKV stays on libmpv instead of attempting an AVPlayer mount the engine could not remux.
        let chosen = PlayerEngineRouter.engine(for: url, isTorrent: torrent || loopback, isDolbyVision: isDV,
                                               dvDisplayCapable: DVDisplaySupport.isCapable,
                                               plainRemuxDelivery: VortXRemuxHLSServer.deliveryEnabled)
        // [dv] routing probe: first line of the DV trail (route -> mount -> classify -> fallback -> demote).
        // With the engineLatch this fires only on the pre-onAppear renders plus the single seed, so the
        // exported log gets the route trail once per stream instead of once per body pass (#76 b163 flood).
        // AVPlayer on a DV source is the true-DV lane (VideoToolbox); mpv here means HDR10 tone-map.
        let candidacy = PlayerEngineRouter.dvRemuxCandidacy(url)
        // The file name is an identifier in practice (a release name names the title), and this line goes to
        // BOTH the opt-in probe log and, via DVRouteBreadcrumb, the always-on diagnostics.log. Its iOS twin
        // in PlayerScreen.routedToAVPlayer already redacts it; this one did not, which is the whole reason
        // "the sink will catch it" is not a plan.
        // The dvRemux field carries the VALUE and its SOURCE (user toggle / remote fleet value / display
        // default / explicit AVPlayer pick). A DV title landing on mpv used to be diagnosed by elimination,
        // which is how a stray user Off went three hours unnoticed; the line now says which rule decided it.
        let routeLine = "route file=\(VXProbeRedaction.identityToken(url.lastPathComponent)) isDV=\(isDV) dvDisplayCapable=\(DVDisplaySupport.isCapable) candidate=\(candidacy.candidate) [\(candidacy.reason)] container=\(PlayerEngineRouter.isAVPlayerContainer(url)) \(PlayerEngineRouter.dvRemuxRouteDescription(dvDisplayCapable: DVDisplaySupport.isCapable)) -> engine=\(chosen.rawValue)"
        // ONE emitter (b210). This used to be a `VXProbe.log` immediately followed by the breadcrumb, and
        // since DiagnosticsLog mirrors into the SAME probe file when probing is on, every pre-latch render
        // pass wrote the identical text to the export twice (diag-21: the decision logged 3-4x per load).
        // The breadcrumb alone already reaches both channels, and it deduplicates.
        DVRouteBreadcrumb.log(routeLine)
        return chosen == .avfoundation
    }

    /// The video surface: the AVFoundation engine when routed there, otherwise libmpv. Both bind to the same
    /// Coordinator and feed the same `handleProperty`, so the surrounding chrome drives either unchanged. This
    /// mirrors `PlayerScreen.playerSurface` on iOS / macOS.
    @ViewBuilder private var playerSurface: some View {
        if avToMPVHandoff != nil || avToMPVHandoffBlocked {
            Color.black.ignoresSafeArea()
        } else if useAVPlayerEngine {
            if let resumeOrigin = initialAVResumeOrigin {
                AVPlayerEngineView(coordinator: coordinator)
                    // AVFoundation and the remux server apply required headers themselves. A loopback proxy
                    // would hide the original container from remux routing and defeat the resume-origin mount.
                    .play(engineSurfacePlayback.url, headers: engineSurfacePlayback.headers,
                          isDolbyVision: StreamRanking.isDolbyVision(sourceHint ?? ""))
                    .live(initialLiveMode)
                    .resumeOrigin(resumeOrigin)
                    .onPropertyChange { _, name, data, token in handleProperty(name, data, loadToken: token) }
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
        } else {
            MPVMetalPlayerView(coordinator: coordinator)
                .play(mpvSurfacePlayback.url, headers: mpvSurfacePlayback.headers,
                      audioSidecar: mpvSurfacePlayback.audioSidecar,
                      isDolbyVision: mpvSurfacePlayback.isDolbyVision)
                .live(mpvSurfacePlayback.live)
                .onPropertyChange { _, name, data, token in handleProperty(name, data, loadToken: token) }
                .onAppear {
                    coordinator.player?.isFullPlayerPresentation = true
                }
                .ignoresSafeArea()
        }
    }

    /// Whether the active player engine is AVFoundation (so the chrome can hide the rows AVPlayer has no
    /// equivalent for: audio sync (setAudioDelay), audio output mode, and the hardware-decoding toggle).
    /// External add-on subtitles and trickplay frame capture DO work on AVPlayer, so those rows stay shown.
    private var isAVPlayerActive: Bool { coordinator.player is AVPlayerEngineController }

    // MARK: - Property handling (shared by both engines via the MPVProperty event bus)

    private func terminalRoute(for loadToken: PlayerLoadToken?) -> EpisodePlaybackIdentity.TerminalEventRoute {
        EpisodePlaybackIdentity.terminalEventRoute(
            callbackToken: loadToken, activeToken: coordinator.player?.activeLoadToken,
            committedToken: committedLoadToken,
            pendingToken: pendingAdvance?.loadToken, pendingIssued: pendingAdvance?.issued == true,
            supersededToken: supersededAdvance?.pending.loadToken,
            supersededIssued: supersededAdvance?.pending.issued == true,
            switchingEpisode: switchingEpisode
        )
    }

    private func terminalAction(for loadToken: PlayerLoadToken?,
                                kind: EpisodePlaybackIdentity.TerminalEventKind)
        -> EpisodePlaybackIdentity.TerminalEventAction {
        EpisodePlaybackIdentity.terminalEventAction(
            route: terminalRoute(for: loadToken), kind: kind
        )
    }

    private func callbackBelongsToCommittedMedia(_ loadToken: PlayerLoadToken?) -> Bool {
        guard let loadToken, let committedLoadToken else { return false }
        return loadToken == committedLoadToken
            && loadToken == coordinator.player?.activeLoadToken
    }

    private func beginAssetSanityAttemptIfNeeded(
        loadToken: PlayerLoadToken,
        requestedResumeOrigin: Double
    ) {
        guard loadToken == coordinator.player?.activeLoadToken,
              assetSanityAttempt.owner != loadToken else { return }
        assetSanityAttempt.begin(owner: loadToken)
        assetSanityTrackListToken = nil
        assetSanityRequestedResume = max(0, requestedResumeOrigin)
        assetSanityDeferredStartToken = nil
        assetSanityStartEffectsToken = nil
        cancelAssetSanityObservationDeadline()
    }

    private func assetSanityExpectedRuntimeSeconds(for metadata: PlaybackMeta? = nil) -> Double? {
        guard let m = metadata ?? curMeta,
              let loaded = core.metaDetails?.meta,
              loaded.id == m.libraryId,
              let seconds = loaded.runtimeSeconds,
              seconds > 0 else { return nil }
        return seconds
    }

    private func assetSanityEvidence(
        loadToken: PlayerLoadToken,
        metadata: PlaybackMeta? = nil
    ) -> EpisodicAssetSanityPolicy.Evidence {
        let player = coordinator.player
        let summary = player?.mediaSummary()
        let engineDuration = player?.mediaDurationSeconds() ?? 0
        // Pending properties must not borrow the outgoing episode's duration, tracks, or metadata.
        let pending = pendingAdvance.flatMap { $0.issued && $0.loadToken == loadToken ? $0 : nil }
        let observedMetadata = pending?.meta ?? metadata ?? curMeta
        let observedDuration = pending.map { $0.deferredDuration ?? engineDuration }
            ?? (duration > 0 ? duration : engineDuration)
        return .init(
            isLibMPV: !(player is AVPlayerEngineController),
            season: observedMetadata?.season,
            episode: observedMetadata?.episode,
            isLive: isCurrentLiveStream,
            isTrailer: isTrailer,
            claimedResolutionRank: curSourceStream.map(StreamRanking.resolutionRank) ?? 0,
            actualWidth: summary?.width ?? (pending == nil ? videoWidth : 0),
            actualHeight: summary?.height ?? (pending == nil ? videoHeight : 0),
            framesPerSecond: player?.containerFrameRate() ?? 0,
            durationSeconds: observedDuration,
            trackListObserved: pending?.deferredTrackList ?? (assetSanityTrackListToken == loadToken),
            audioTrackCount: pending == nil ? audioTracks.count : (player?.tracks(ofType: "audio").count ?? 0),
            expectedRuntimeSeconds: assetSanityExpectedRuntimeSeconds(for: observedMetadata)
        )
    }

    private func publishAssetSanityStartEffectsIfNeeded(
        loadToken: PlayerLoadToken,
        position: Double
    ) {
        guard assetSanityAttempt.isAccepted(owner: loadToken),
              assetSanityStartEffectsToken != loadToken else { return }
        assetSanityStartEffectsToken = loadToken
        localTrickplayCaptureBreaker.reset()
        if !isCurrentLiveStream, pendingAdvance == nil, let m = curMeta, let u = curURL {
            let ref = curDebridRef
            let rawTorrent = curIsTorrent ? curSourceStream : nil
            LastStreamStore.record(libraryId: m.libraryId, entry: .init(
                videoId: m.videoId, url: u.absoluteString, title: curTitle,
                season: m.season, episode: m.episode, name: m.name,
                poster: m.poster, type: m.type, qualityText: curHint,
                // The playing release group, so a Continue-Watching resume's prev/next keeps the SAME release
                // across episodes. tvOS skipped this defaulted argument, which left the cross-launch memory the
                // readers in HomeView/DetailView already consult permanently nil on Apple TV while the iOS twin
                // wrote it; every launch therefore started binge continuity from scratch (diag-21). Safe here
                // only because this whole record is fenced behind `pendingAdvance == nil` above, so it can never
                // pair an old URL with a new episode's group.
                bingeGroup: curBinge,
                torrent: curIsTorrent, savedAt: Date(), headers: curHeaders,
                debridService: ref?.service.rawValue,
                infoHash: curIsTorrent ? rawTorrent?.infoHash : ref?.infoHash,
                debridFileId: ref?.fileId, debridTorrentId: ref?.torrentId,
                fileIdx: curIsTorrent ? rawTorrent?.fileIdx : ref?.fileIdx,
                linkSavedAt: ref != nil ? Date() : nil),
                profileID: ProfileStore.shared.activeID)
        }
        if !isCurrentLiveStream, let m = curMeta {
            ScrobbleCoordinator.shared.playbackStarted(
                m, position: position, duration: duration,
                sessionToken: playbackSessionID
            )
        }
        publishAcceptedDurationSideEffectsIfNeeded(
            loadToken: loadToken, durationSeconds: duration
        )
    }

    private func publishAcceptedDurationSideEffectsIfNeeded(
        loadToken: PlayerLoadToken?,
        durationSeconds: Double
    ) {
        let acceptedOwner = assetSanityAttempt.isAccepted(owner: loadToken) ? loadToken : nil
        guard EpisodicAssetSanityPolicy.canPublishDurationSideEffects(
            callbackOwner: loadToken,
            acceptedOwner: acceptedOwner,
            durationSeconds: durationSeconds
        ) else { return }
        if let m = curMeta {
            scrubThumbnails.configureCommunity(
                imdbId: m.libraryId, season: m.season, episode: m.episode,
                duration: durationSeconds, isRealDuration: true
            )
        }
        refreshSubFingerprint(force: true)
        fetchPooledSubtitles()
    }

    private func cancelAssetSanityObservationDeadline() {
        assetSanityObservationTask?.cancel()
        assetSanityObservationTask = nil
        assetSanityObservationToken = nil
    }

    private func armAssetSanityObservationDeadlineIfNeeded(
        loadToken: PlayerLoadToken
    ) {
        guard assetSanityObservationToken != loadToken,
              assetSanityDeferredStartToken == loadToken else { return }
        cancelAssetSanityObservationDeadline()
        assetSanityObservationToken = loadToken
        assetSanityObservationTask = Task { @MainActor in
            try? await Task.sleep(
                for: .seconds(EpisodicAssetSanityPolicy.incompleteEvidenceGraceSeconds)
            )
            guard !Task.isCancelled,
                  assetSanityObservationToken == loadToken else { return }
            guard loadToken == coordinator.player?.activeLoadToken,
                  (loadToken == committedLoadToken ||
                   (pendingAdvance?.issued == true && pendingAdvance?.loadToken == loadToken)),
                  assetSanityDeferredStartToken == loadToken else {
                cancelAssetSanityObservationDeadline()
                return
            }
            DiagnosticsLog.log(
                "player",
                "asset sanity telemetry incomplete after bounded observation; accepting exact load"
            )
            _ = acceptIncompleteAssetSanityIfCurrent(
                loadToken: loadToken,
                position: assetSanityDeferredStartPosition
            )
        }
    }

    @discardableResult
    private func acceptIncompleteAssetSanityIfCurrent(
        loadToken: PlayerLoadToken,
        position: Double
    ) -> Bool {
        guard loadToken == coordinator.player?.activeLoadToken,
              (loadToken == committedLoadToken ||
               (pendingAdvance?.issued == true && pendingAdvance?.loadToken == loadToken)) else { return false }
        // Preflight the parked advance before accepting or mutating anything. A delayed grace callback for
        // the old committed item must not alter start/watchdog state while a newer advance owns the surface.
        if let pending = pendingAdvance {
            guard pending.generation == episodeSwitchGeneration,
                  AppleRemuxRecoveryPolicy.canAcceptDeferredEvidence(
                    ownerCurrent: PlayerLoadProvenanceState.canCommit(
                    callbackToken: loadToken,
                    activeToken: coordinator.player?.activeLoadToken,
                    pendingToken: pending.loadToken
                    ),
                    pendingAdvanceExists: true,
                    callbackMatchesPending: true
                  ) else { return false }
        }
        // A late duration/track receipt may now prove a mismatch. Recheck it before accepting missing data.
        let latest = assetSanityAttempt.evaluate(owner: loadToken, evidence: assetSanityEvidence(loadToken: loadToken))
        if latest == .rejected || latest == .settled(.reject) {
            cancelAssetSanityObservationDeadline()
            handleRejectedEpisodicAsset(loadToken: loadToken)
            return false
        }
        switch assetSanityAttempt.acceptIncompleteEvidence(owner: loadToken) {
        case .accepted, .settled(.accept):
            cancelAssetSanityObservationDeadline()
            if pendingAdvance != nil {
                recheckParkedAssetAfterTelemetry(loadToken: loadToken)
                return pendingAdvance == nil && committedLoadToken == loadToken && hasStartedPlaying
            }
            // Pending binge validation can hold `hasStartedPlaying` at false while evidence is incomplete.
            // Bounded acceptance proves the frame is usable, so retire the no-frame watchdogs or a healthy
            // 4K fallback can later be misclassified and hopped as if it never started.
            hasStartedPlaying = true
            loadTimeout?.cancel(); loadTimeout = nil
            recoveryDeadline?.cancel(); recoveryDeadline = nil
            avStartWatchdog?.cancel(); avStartWatchdog = nil
            publishAssetSanityStartEffectsIfNeeded(
                loadToken: loadToken, position: position
            )
            return true
        case .rejected, .settled(.reject):
            cancelAssetSanityObservationDeadline()
            return false
        case .stale, .waiting, .settled(.wait):
            return false
        }
    }

    @discardableResult
    private func settleAssetSanityIfPossible(
        loadToken: PlayerLoadToken,
        position: Double,
        metadata: PlaybackMeta? = nil,
        publishStartEffects: Bool = true
    ) -> Bool {
        guard loadToken == coordinator.player?.activeLoadToken,
              (loadToken == committedLoadToken ||
               (pendingAdvance?.issued == true && pendingAdvance?.loadToken == loadToken)) else { return false }
        switch assetSanityAttempt.evaluate(
            owner: loadToken,
            evidence: assetSanityEvidence(loadToken: loadToken, metadata: metadata)
        ) {
        case .stale:
            return false
        case .waiting, .settled(.wait):
            armAssetSanityObservationDeadlineIfNeeded(loadToken: loadToken)
            return true
        case .accepted, .settled(.accept):
            cancelAssetSanityObservationDeadline()
            if publishStartEffects, pendingAdvance == nil {
                publishAssetSanityStartEffectsIfNeeded(
                    loadToken: loadToken, position: position
                )
            }
            return true
        case .rejected:
            cancelAssetSanityObservationDeadline()
            handleRejectedEpisodicAsset(loadToken: loadToken)
            return false
        case .settled(.reject):
            cancelAssetSanityObservationDeadline()
            return false
        }
    }

    /// Re-enter the single first-frame transaction after exact pending telemetry arrives. The original
    /// rendered-frame token is required; duration or tracks alone can never manufacture playback success.
    private func recheckParkedAssetAfterTelemetry(loadToken: PlayerLoadToken?) {
        guard let loadToken, let pending = pendingAdvance,
              pending.issued, pending.generation == episodeSwitchGeneration,
              pending.loadToken == loadToken,
              coordinator.player?.activeLoadToken == loadToken,
              assetSanityDeferredStartToken == loadToken,
              !hasStartedPlaying else { return }
        handleProperty(MPVProperty.timePos,
                       PlayerTimePositionEvent(seconds: assetSanityDeferredStartPosition, loadToken: loadToken),
                       loadToken: loadToken)
    }

    private func handleRejectedEpisodicAsset(loadToken: PlayerLoadToken) {
        guard loadToken == coordinator.player?.activeLoadToken,
              assetSanityAttempt.isRejected(owner: loadToken) else { return }
        let originalResume = assetSanityRequestedResume
        let hasAlternative = nextUntriedStream() != nil
        DiagnosticsLog.log(
            "player",
            "rejected mismatched asset token=\(loadToken) originalResume=\(Int(originalResume))s alternative=\(hasAlternative)"
        )
        loadTimeout?.cancel()
        recoveryDeadline?.cancel()
        recoveryDeadline = nil
        coordinator.player?.pause()
        invalidateLocalTrickplayCapture()
        assetSanityDeferredStartToken = nil
        cancelAssetSanityObservationDeadline()
        switch EpisodicAssetSanityPolicy.recovery(
            explicitPick: currentPickWasExplicit,
            continueWatching: currentPlaybackIsResume,
            hasAlternative: hasAlternative,
            originalResumeSeconds: originalResume
        ) {
        case .hop(let requestedResume):
            hasStartedPlaying = false
            currentTime = 0
            resumeSeconds = requestedResume
            resumeIsMidPlayRecovery = false   // the ORIGINAL stored resume, not a play head: keep the near-end guard
            if hopToNextSource(
                reason: "source returned a short audio-less preview",
                resumeOverride: requestedResume,
                allowBeyondFailureBudget: true
            ) {
                return
            }
        case .showMismatch:
            break
        }
        loadErrorMsg = "This source returned a stream that does not match the selected title."
        presentTerminalLoadFailure()
    }

    private func handleProperty(_ name: String, _ data: Any?, loadToken: PlayerLoadToken? = nil) {
        if let loadToken, loadToken == coordinator.player?.activeLoadToken {
            beginAssetSanityAttemptIfNeeded(
                loadToken: loadToken,
                requestedResumeOrigin: avSurfaceResumeOrigin
                    ?? (hasStartedPlaying ? currentTime : (resumeSeconds ?? 0))
            )
        }
        if pendingAdvance == nil, supersededAdvance == nil,
           let loadToken, loadToken == coordinator.player?.activeLoadToken {
            committedLoadToken = loadToken
        }
        if name == MPVProperty.duration, let value = data as? Double,
           !callbackBelongsToCommittedMedia(loadToken) {
            if pendingAdvance?.issued == true, loadToken == pendingAdvance?.loadToken {
                pendingAdvance?.deferredDuration = value
                recheckParkedAssetAfterTelemetry(loadToken: loadToken)
            } else if supersededAdvance?.pending.issued == true,
                      loadToken == supersededAdvance?.pending.loadToken {
                supersededAdvance?.pending.deferredDuration = value
            }
            return
        }
        if name == MPVProperty.trackList, !callbackBelongsToCommittedMedia(loadToken) {
            if pendingAdvance?.issued == true, loadToken == pendingAdvance?.loadToken {
                pendingAdvance?.deferredTrackList = true
                recheckParkedAssetAfterTelemetry(loadToken: loadToken)
            } else if supersededAdvance?.pending.issued == true,
                      loadToken == supersededAdvance?.pending.loadToken {
                supersededAdvance?.pending.deferredTrackList = true
            }
            return
        }
        switch name {
        case MPVProperty.pausedForCache:
            if let b = data as? Bool {
                let startedBuffering = b && !buffering
                buffering = b
                if startedBuffering {
                    recordRapidBufferingStartIfEligible()
                }
            }
        case MPVProperty.pause:
            // play()/pause() emit MPVProperty.pause optimistically and the KVO echo then arrives with the same
            // value, so gate every side effect on a real change: the scrobble pause/resume, saveProgress and
            // reportProgress must fire once per press, not twice (this also collapses the pre-existing KVO
            // double-fire). The idle-timer and now-playing writes are idempotent, so running them only on a
            // real change is correct.
            if let b = data as? Bool, b != isPaused {
                isPaused = b
                if b {
                    if let loadToken {
                        suspendAVPostReplacementFirstFrameDeadlineIfOwned(by: loadToken)
                    }
                    resetRapidBufferingRecovery(reason: "user pause")
                    // EOF may have already admitted the next episode. Carry this late user pause into that
                    // replacement rather than letting its default-playing controller restart the series.
                    if let pending = pendingAdvance {
                        queueIncomingTransportIntent(paused: true)
                        if let token = pending.loadToken { bindIncomingTransportIntent(to: token) }
                    }
                } else if let loadToken {
                    resumeAVPostReplacementFirstFrameDeadlineIfOwned(by: loadToken)
                }
                UIApplication.shared.isIdleTimerDisabled = !b   // hold the TV awake while playing; let it sleep when paused
                // #157: reflect play/pause on the system card AT ONCE. The play head stops ticking while
                // paused, so without this the published rate would stay at "playing" and the Control Center
                // clock would keep running against a frozen picture.
                refreshNowPlaying(force: true)
                // External sync (Trakt) live scrobble pause/resume, ADDED ALONGSIDE the existing persistence
                // below (which is unchanged). Fail-soft + gated inside the coordinator; a no-op with empty
                // creds. SIMKL has no live scrobble, so it is skipped by capability.
                if callbackBelongsToCommittedMedia(loadToken),
                   assetSanityAttempt.isAccepted(owner: loadToken),
                   !isCurrentLiveStream, let m = curMeta {
                    let pos = max(currentTime, suppressedResumeFloor ?? 0)
                    if b { ScrobbleCoordinator.shared.playbackPaused(m, position: pos, duration: duration) }
                    else { ScrobbleCoordinator.shared.playbackResumed(m, position: pos, duration: duration) }
                }
                if b {
                    saveProgress(at: currentTime)   // persist on pause
                    // Keep the ENGINE's library copy in step too (same floor rule as the 20s tick).
                    // The engine previously only heard the throttled tick + the exit flush, so its
                    // copy could lag far behind the account writes - and any engine-side push (the
                    // watched/unwatched toggle, a sync) then resurrected that stale position over
                    // the newer account value (the "unmarked watched, an old scrub position came
                    // back" report). Engine dispatches are ordered, so this can never race backward.
                    if assetSanityAttempt.isAccepted(owner: loadToken),
                       !isCurrentLiveStream, enginePlayerVideoId == curMeta?.videoId,
                       suppressedResumeFloor == nil || currentTime >= (suppressedResumeFloor ?? 0) {
                        core.reportProgress(timeSeconds: currentTime, durationSeconds: duration,
                                            target: playbackMutationTarget)
                    }
                } else if pendingBoundaryAdvanceAfterPlay {
                    pendingBoundaryAdvanceAfterPlay = false
                    autoAdvance()
                }
            }
        case MPVProperty.timePos:
            if let event = data as? PlayerTimePositionEvent,
               PlayerLoadProvenanceState.accepts(
                callbackToken: event.loadToken,
                activeToken: coordinator.player?.activeLoadToken
               ) {
                let d = event.seconds
                if pendingAdvance?.issued != true, supersededAdvance == nil {
                    committedLoadToken = event.loadToken
                }
                let supersededTick = supersededAdvance?.pending.issued == true
                    && event.loadToken == supersededAdvance?.pending.loadToken
                if supersededTick { return }
                let avPlayerRenderedFrame =
                    (coordinator.player as? AVPlayerEngineController)?
                        .hasProducedPlayableVideoFrame == true
                if pendingAdvance?.issued == true,
                   event.loadToken == pendingAdvance?.loadToken,
                   TVPlaybackStartPolicy.shouldIgnoreIssuedAdvanceTick(
                    positionSeconds: d,
                    avPlayerRenderedFrame: avPlayerRenderedFrame
                   ) { return }
                // Publish-at-first-frame guard: a tick of the OUTGOING file during an advance's resolve
                // window (the incoming load has NOT been handed to the player yet, so the previous episode
                // is still the one rendering) must not be mistaken for the incoming episode's first frame.
                // Skip only the start-of-playback block; the normal tick handling below still runs, and its
                // attribution reads (`curMeta`) still name the outgoing episode - exactly what is playing.
                let outgoingResolveTick = pendingAdvance != nil && pendingAdvance?.issued != true
                if TVPlaybackStartPolicy.hasStarted(
                    positionSeconds: d,
                    avPlayerRenderedFrame: avPlayerRenderedFrame),
                   !hasStartedPlaying, !outgoingResolveTick {            // playback actually began
                    if let pending = pendingAdvance {
                        guard pending.generation == episodeSwitchGeneration,
                              PlayerLoadProvenanceState.canCommit(
                            callbackToken: event.loadToken,
                            activeToken: coordinator.player?.activeLoadToken,
                            pendingToken: pending.loadToken
                        ) else { return }
                    }
                    let startupResume = resumeSeconds.map {
                        String(format: "%.3f", $0)
                    } ?? "nil"
                    DiagnosticsLog.log(
                        "playback",
                        String(
                            format: "first frame position=%.3fs lane=%@ resume=%@ autoSkip=%@",
                            d,
                            isAVPlayerActive ? "avplayer" : "libmpv",
                            startupResume,
                            autoSkip ? "on" : "off"
                        )
                    )
                    hasStartedPlaying = true
                    rearmAVStallWatchdogItemGenerationIfOwned(by: event.loadToken)
                    cancelAVPostReplacementFirstFrameDeadlineIfOwned(by: event.loadToken)
                    applyIncomingTransportIntentIfOwned(by: event.loadToken)
                    // A real frame from the same-source fallback completes its recovery obligation. Clearing
                    // this before any later callbacks makes a retired watchdog inert for this source.
                    directAVNoFrameRecovery = nil
                    libmpvStartupNudgeIssued = false
                    firstFrameRenderedAt = ProcessInfo.processInfo.systemUptime
                    // Deferred libmpv resume seek: the pipeline is now warm (first frame rendered), so this lands
                    // as an ordinary scrub instead of the cold pre-first-frame seek that wedged video output.
                    // AVPlayer never stashes one (its resume is a pre-mount remux origin), so this is a no-op there.
                    if let t = pendingLibmpvResumeSeek {
                        pendingLibmpvResumeSeek = nil
                        coordinator.player?.seekForResume(to: t)
                        armPostFrameResumeSeekWatchdog(target: t, owner: event.loadToken)
                    }
                    // FIRST-FRAME COMMIT (binge-desync fix): the incoming episode's file actually rendered,
                    // so publish the advance NOW, before anything below (the LastStreamStore record, the
                    // scrobble start) reads curMeta. enginePlayerVideoId was already re-pointed at
                    // engine-load time; publishing curMeta here is what OPENS its `==` gates (the pause
                    // persist, the ~20s periodic tick, and the exit flush all compare against curMeta), so
                    // the engine writes, the display identity, and the stream store all move as one.
                    let deferredDuration = pendingAdvance?.deferredDuration
                    let deferredTrackList = pendingAdvance?.deferredTrackList == true
                    let pendingAdvanceMetadata = pendingAdvance?.meta
                    let validatingPendingAdvance = pendingAdvanceMetadata != nil
                    // Validate while the incoming identity is still parked. A short audio-less preview can
                    // render one frame; committing first made the decoy current before mismatch recovery.
                    assetSanityDeferredStartToken = event.loadToken
                    assetSanityDeferredStartPosition = d
                    guard settleAssetSanityIfPossible(
                        loadToken: event.loadToken,
                        position: d,
                        metadata: pendingAdvanceMetadata,
                        publishStartEffects: !validatingPendingAdvance
                    ) else { return }
                    if validatingPendingAdvance {
                        guard assetSanityAttempt.isAccepted(owner: event.loadToken) else {
                            hasStartedPlaying = false
                            return
                        }
                        guard commitPendingAdvanceOnFirstFrame(loadToken: event.loadToken) else { return }
                        publishAssetSanityStartEffectsIfNeeded(
                            loadToken: event.loadToken, position: d
                        )
                    }
                    if let deferredDuration {
                        handleProperty(MPVProperty.duration, deferredDuration, loadToken: event.loadToken)
                    }
                    if deferredTrackList {
                        handleProperty(MPVProperty.trackList, nil, loadToken: event.loadToken)
                    }
                    if let m = curMeta {
                        onPlaybackIdentityCommitted(m)
                    }
                    loadTimeout?.cancel(); recoveryDeadline?.cancel(); recoveryDeadline = nil; loadFailed = false
                    avStartWatchdog?.cancel(); avStartWatchdog = nil   // a playable frame arrived: cancel the AVPlayer fallback
                    libmpvResumeWatchdog?.cancel(); libmpvResumeWatchdog = nil   // the deferred resume landed on a warm pipeline: cancel its safety net
                    // [dv] time-to-first-frame for the watchdog trail (one-shot: armedAt self-clears). Only
                    // the remux lane logs it; the mpv lane / plain AVPlayer starts are not the diag target.
                    if let armed = avWatchdogArmedAt {
                        avWatchdogArmedAt = nil
                        if (coordinator.player as? AVPlayerEngineController)?.isRemuxMounted == true {
                            DiagnosticsLog.log("dv", String(format: "remux first frame in %.1fs (start watchdog disarmed)", Date().timeIntervalSince(armed)))
                        }
                    }
                    autoRetryCount = 0; reconnecting = false; autoRetryTask?.cancel()   // playback started: clear auto-recovery
                    applyDefaultVolume()            // D5: start at the user's saved "Default volume" (the launch mount begins at 100%)
                    // Honest badge (message-only): a Dolby Vision title on the libmpv lane (a DV torrent, or
                    // a demoted remux) outputs tone-mapped HDR10, and the mpv lane no longer requests the
                    // panel's DV mode over decoded pixels. Say so once, so an HDR10 badge on a DV title is
                    // understood instead of being reported as "DV doesn't work".
                    if !isAVPlayerActive, StreamRanking.isDolbyVision(curHint ?? sourceHint ?? "") {
                        showEngineNote("Dolby Vision title, HDR10 output (this source is playing on the built-in player)")
                    }
                    // #157: register this playback with the system. Until this landed the Apple TV held an
                    // active .playback audio session while telling the OS nothing was playing, so the Control
                    // Center Now Playing card was empty and no system-level transport reached the player.
                    // Wired ONCE per playback at first frame (the same moment iOS wires it); the position and
                    // state then ride the ordinary tick / pause handlers below. Seeks go through the engine
                    // RELATIVE/ABSOLUTE calls so they always act on the LIVE position, never a captured one.
                    NowPlayingCenter.wireCommands(
                        play: { coordinator.player?.play() },
                        pause: { coordinator.player?.pause() },
                        togglePause: { coordinator.player?.togglePause() },
                        seekBy: { delta in
                            cancelPendingLibmpvResumeForUserSeek()
                            coordinator.player?.seek(by: delta)
                        },
                        seekTo: { position in
                            cancelPendingLibmpvResumeForUserSeek()
                            coordinator.player?.seek(to: position)
                        },
                        stepSeconds: seekStepSeconds,
                        canScrub: NowPlayingPolicy.allowsScrubbing(duration: duration, isLive: isCurrentLiveStream))
                    refreshNowPlaying(at: d, force: true)   // publish the card immediately, not on the next tick
                    fetchPooledSubtitles()          // community-subtitle pool (P2/P3), fail-soft + gated
                    uploadEmbeddedSubtitlesIfNeeded()   // best-effort pooling of the file's own text tracks (P4)
                    // Add-on subtitles were fetched only from the `duration` event, which a debrid direct-HTTP
                    // MKV frequently never delivers, so the panel's "From add-ons" section stayed empty for
                    // exactly that content. Fetch at playback start too (key-latched, so at most one real
                    // fetch runs); the duration-event call remains for streams that deliver it first.
                    fetchAddonSubtitles()
                }
                // Seek-in-flight guard (see the state declaration): drop stale pre-seek ticks so they
                // cannot clobber the freshly committed position; everything downstream of a tick
                // (progress saves, watched-at-90%, skip spans) waits with it. The RAW position is recorded
                // first so the post-first-frame resume watchdog can still see the real playhead.
                lastRawTimePos = d
                if let target = inFlightSeekTarget {
                    let landedNearTarget = abs(d - target) <= inFlightSeekSnapRadius
                    if landedNearTarget
                        || Date().timeIntervalSinceReferenceDate - inFlightSeekIssuedAt > inFlightSeekSettleWindow {
                        inFlightSeekTarget = nil   // settled near the target, or the window expired: trust ticks again
                        if landedNearTarget {
                            // The deferred resume obligation is complete. Retire its watchdog now, while
                            // the landed tick still proves the target, so a later user seek backward cannot
                            // make the old target look failed when the 12-second task wakes.
                            settlePostFrameResumeSeekIfOwned(
                                target: target,
                                loadToken: event.loadToken
                            )
                        }
                    } else {
                        return
                    }
                }
                currentTime = d
                if assetSanityDeferredStartToken == event.loadToken,
                   !assetSanityAttempt.isAccepted(owner: event.loadToken),
                   !assetSanityAttempt.isRejected(owner: event.loadToken),
                   !settleAssetSanityIfPossible(
                    loadToken: event.loadToken, position: d
                   ) {
                    return
                }
                let assetSanityAccepted = assetSanityAttempt.isAccepted(owner: event.loadToken)
                maybeLogFrameDropReceipt()
                // Durationless-stream fallback (the "watch position never saved / no resume on some
                // debrid MKVs" report): many debrid direct-HTTP MKVs never DELIVER mpv's `duration`
                // EVENT, yet the property itself reads fine (the subtitle-fingerprint path already
                // relies on that). Everything downstream keys off `duration > 0` - the resume seek,
                // the ~20s progress saves, watched-at-90%, Up Next - so those streams lost their watch
                // position entirely and always restarted from 0. Poll the engine each (coalesced) tick
                // until a real value lands and route it through the same handling as the event; one C
                // property read at ~2-4 Hz, and it stops the moment duration is known. The AVPlayer
                // engine returns 0 here (it delivers its duration event reliably), so this is mpv-only.
                if duration <= 0, !isCurrentLiveStream,
                   let engineDur = coordinator.player?.mediaDurationSeconds(), engineDur.isFinite, engineDur > 0 {
                    handleProperty(MPVProperty.duration, engineDur, loadToken: event.loadToken)
                }
                updateCurrentSkip(at: d)
                // #157: keep the system Now Playing card's clock honest. Self-throttling, so this is a couple
                // of pushes a second at most, not one per 4 Hz tick (the system extrapolates the play head
                // from the last elapsed+rate pair it was given). A duration that only lands mid-playback
                // (durationless debrid MKVs) also turns the system's position controls on at that moment.
                refreshNowPlaying()
                NowPlayingCenter.setScrubbingEnabled(
                    NowPlayingPolicy.allowsScrubbing(duration: duration, isLive: isCurrentLiveStream))
                // Ensure the community key is provisioned off meta.runtime the moment the behind-playback
                // meta lands (idempotent; no-op once keyed), so capture starts even without a duration event.
                if assetSanityAccepted { configureCommunityTrickplayProvisional() }
                maybeCaptureLocalTrickplay(at: d)
                // Live: no progress is persisted (saveProgress no-ops) and nothing is reported
                // to the engine - a live stream has no meaningful watch position.
                if assetSanityAccepted, !isCurrentLiveStream,
                   (lastSaved < 0 || abs(d - lastSaved) >= 20) {   // persist ~every 20s
                    lastSaved = d
                    saveProgress(at: d)
                    // Attribution gate (binge-desync fix): this ~20s periodic tick is the highest-frequency
                    // engine writer, so it must honor the same identity gate as the pause-persist (:641) and
                    // exit-flush (:504) sites. Only write to the engine Player when it is loaded for the
                    // episode curMeta names; after a binge advance whose re-point could not be confirmed, a
                    // missed re-point degrades to no engine write (the account write from saveProgress still
                    // lands) rather than clobbering the previous episode's position with a fresh mtime.
                    // Same floor as saveProgress: a remux replay that restarted at 0 (suppressed resume) must
                    // not regress the ENGINE library's resume point either, until playback passes it.
                    if enginePlayerVideoId == curMeta?.videoId,
                       suppressedResumeFloor == nil || d >= (suppressedResumeFloor ?? 0) {
                        core.reportProgress(timeSeconds: d, durationSeconds: duration,
                                            target: playbackMutationTarget)   // engine progress
                    }
                }
                // ~90% in → flip the watched marker live. DWELL-GATED: a single tick past 90% is not
                // proof of watching - a scrub commit that lands there (easy mid back-and-forth, since a
                // held press ramps to 75s steps) used to mark the episode watched instantly, and the mark
                // stuck even when the viewer scrubbed straight back and exited early: Continue Watching
                // dropped the episode and the selector moved on (the same wipe as the EOF overshoot).
                // Require a few seconds of SETTLED playback in the zone (not scrubbing, ticks flowing)
                // before marking; leaving the zone re-arms. A natural finish is unaffected: the last 10%
                // of any episode dwarfs the dwell, and a true EOF still marks watched via endFileEof.
                if assetSanityAccepted, !markedWatched, duration > 0, d / duration >= 0.9 {
                    let now = Date().timeIntervalSinceReferenceDate
                    if scrubbing {
                        watchedZoneSince = nil          // previewing, not watching: reset the dwell
                    } else if let since = watchedZoneSince {
                        if now - since >= 5, let m = curMeta {
                            markedWatched = true
                            core.markPlaybackWatched(
                                m, target: playbackMutationTarget, allowEngineWrite: EpisodePlaybackIdentity.engineWritesAllowed(
                                    boundVideoID: isEpisodePlaybackContext ? enginePlayerVideoId : m.videoId,
                                    displayedVideoID: m.videoId
                                )
                            )
                        }
                    } else {
                        watchedZoneSince = now          // entered the zone: start the dwell clock
                    }
                } else {
                    watchedZoneSince = nil              // below the zone (scrubbed back out): re-arm
                }
                // ~60s in → the user is really watching this: auto-add to the Library (D8) + send the anon
                // fleet watch ping (D9), once per playback. Idempotent + gated (D8 setting + per-profile dedup;
                // D9 MoatConsent + per-title/day dedup); skipped for live and ad-hoc plays.
                if assetSanityAccepted, !autoAddedThisPlayback,
                   !isCurrentLiveStream, d >= 60, let m = curMeta {
                    autoAddedThisPlayback = true
                    LibraryAutoAdd.addIfNeeded(meta: m, core: core, enabled: autoAddLibrary,
                                               target: playbackMutationTarget)
                    // Resolve a tmdb:… hub/catalog id to its tt identity first (fire-and-forget on a cache
                    // miss) so those plays feed the pool too; a tt id still pings inline. Never blocks.
                    WatchSignalClient.pingResolvingTMDB(contentId: m.libraryId, type: m.type, seriesHint: m.season != nil)
                }
                // Prefetch + rank the next episode once we're clearly committed to this one: past the halfway
                // mark when the duration is known, or after ~2 min of playback when it ISN'T. Many debrid MKVs
                // (the 4K remuxes the owner watches) never emit mpv's `duration` event, so the duration>0
                // triggers alone never fired for them and the next episode never prewarmed - the "next episode
                // used to prefetch/prewarm, now it cold-starts" regression. preload/warm are idempotent per ep.
                if assetSanityAccepted,
                   ((duration > 0 && d / duration >= 0.4) || (duration <= 0 && d >= 90)) {
                    preloadNextIfNeeded()
                }
                // Wake the provider (ranged read of the preloaded source): near the end when duration is known,
                // or once we're a few minutes in when it isn't (best-effort for durationless streams).
                if assetSanityAccepted,
                   NextEpisodePreloadPolicy.isTransportWarmEligible(
                    position: d,
                    duration: duration
                   ) {
                    warmNextIfReady()
                }
            }
        case MPVProperty.videoParamsSigPeak:
            if let p = data as? Double { isHDR = p > 1.0; metadataLine = computeMetadataLine() }
        case MPVProperty.duration:
            if let d = data as? Double {
                duration = d; maybeResume(); refreshSkipSegments(); fetchSkipTimestamps(); fetchAddonSubtitles()
                // Re-apply the persisted aspect-ratio pick on every (re)load, the same iOS does (aspect
                // parity: a tvOS pick previously reset to Fit on the next source or episode).
                if !appliedSize, d > 0 {
                    appliedSize = true
                    coordinator.player?.setVideoSize(videoSize)
                }
                // The real duration sharpens the community trickplay key and subtitle release fingerprint,
                // but only after the exact load has passed asset sanity. A rejected short preview can share the
                // episode's local cache key, so publishing its duration here would poison the replacement load.
                publishAcceptedDurationSideEffectsIfNeeded(
                    loadToken: loadToken, durationSeconds: d
                )
                if let loadToken,
                   assetSanityDeferredStartToken == loadToken,
                   !settleAssetSanityIfPossible(
                    loadToken: loadToken,
                    position: assetSanityDeferredStartPosition
                   ) {
                    return
                }
            }
        case MPVProperty.demuxerCacheTime:
            // Buffered-ahead edge (absolute seconds) for the YouTube-style grey scrubber band. Fail-soft:
            // ignore non-finite / behind-playhead values so the band never jumps backward or breaks.
            if let d = data as? Double, d.isFinite, d >= currentTime { bufferedTime = d }
        case MPVProperty.trackList:
            refreshTracks()
            if let loadToken, callbackBelongsToCommittedMedia(loadToken) {
                assetSanityTrackListToken = loadToken
            }
            let summary = coordinator.player?.mediaSummary()
            videoWidth = summary?.width ?? 0; videoHeight = summary?.height ?? 0; audioCodec = summary?.audioCodec ?? ""
            audioChannels = summary?.audioChannels ?? 0
            metadataLine = computeMetadataLine()
            // Gap A (#76): on AVPlayer, chapters() is [] at readyToPlay (loadChapters is async) and the engine
            // re-emits trackList once they resolve, so re-pull skip candidates + scrubber chapter marks here.
            // On libmpv chapters() is already synchronous at duration, so this is a cheap no-op re-run there.
            refreshSkipSegments()
            let firstAutomaticTrackPass = !appliedAutoTracks
            if firstAutomaticTrackPass, !(audioTracks.isEmpty && subtitleTracks.isEmpty) {
                appliedAutoTracks = true
                let langs = subtitleTracks.map { langName($0.lang) }.joined(separator: ",")
                VXProbe.log("subs", "subs available n=\(subtitleTracks.count) langs=\(langs)")
            }
            // AVPlayer and mpv may publish audio and subtitle topology in separate events. Defaults remain
            // one-shot, while recovery choices are retried on every owned track-list publication until the
            // matching media type can act; this prevents audio-first delivery from consuming a subtitle pick.
            if firstAutomaticTrackPass || pendingAudioReapply != nil || pendingSubtitleReapply != nil {
                autoSelectTracks(applyAutomaticSelections: firstAutomaticTrackPass)
            }
            applyCurrentSubtitleDelayIfReady(force: false)
            if let loadToken,
               assetSanityDeferredStartToken == loadToken,
               !settleAssetSanityIfPossible(
                loadToken: loadToken,
                position: assetSanityDeferredStartPosition
               ) {
                return
            }
        case MPVProperty.endFileError:
            switch terminalAction(for: loadToken, kind: .error) {
            case .handleCommitted:
                break
            case .handlePending:
                pendingAdvance?.terminal = true
                uncommittedIdentityBlocked = true
            case .markSupersededTerminal:
                supersededAdvance?.pending.terminal = true
                uncommittedIdentityBlocked = true
                return
            case .ignoreOutgoingError, .ignoreStale:
                return
            case .persistOutgoingCompletionOnly:
                return
            }
            // Stale event from the just-dismounted AVPlayer engine after a user engine switch / demote: a KVO
            // .failed queued on the main thread can land AFTER the surface swap. Swallow it (and DON'T cancel
            // the fresh mpv load's watchdog) when the AV engine is no longer the mounted one, so it never burns
            // the retry budget, hops sources, or kills the load timeout while the user's chosen mpv engine is
            // loading fine. Mirrors iOS PlayerScreen's avDemotedAt grace.
            // W2-A item 3a: `endFileError` is a SHARED channel (AVPlayerEngine emits on it, so does libmpv), so
            // the two conditions above cannot separate the outgoing engine's stale error from the INCOMING
            // engine's own fast, honest failure - and eating the latter costs the whole post-demote timeout on a
            // url libmpv already rejected. Only an event PROVEN to come from a different load than the dismounted
            // AVPlayer's escapes the grace. Untagged events, or a demote whose outgoing token we never captured,
            // keep today's swallow: that is the fail-open direction this grace was added for.
            let provenFromIncomingEngine: Bool = {
                guard let loadToken, let outgoing = demotedEngineLoadToken else { return false }
                return loadToken != outgoing
            }()
            if let t = engineSwitchedAt, Date().timeIntervalSince(t) < 2,
               !(coordinator.player is AVPlayerEngineController),
               !provenFromIncomingEngine {
                DiagnosticsLog.log("dv", "endFileError swallowed stage=outgoing-stale class=\(safeFailureClass((data as? String) ?? ""))")
                break
            }
            if provenFromIncomingEngine, let t = engineSwitchedAt, Date().timeIntervalSince(t) < 2 {
                DiagnosticsLog.log(
                    "dv",
                    "endFileError inside the post-switch grace but from the INCOMING engine's own load "
                        + "(not the dismounted AVPlayer) -> handled class=\(safeFailureClass((data as? String) ?? ""))")
            }
            if !isAVPlayerActive, !hasStartedPlaying,
               let recovery = directAVNoFrameRecovery,
               recovery.url == (curURL ?? url),
               recovery.episodeGeneration == episodeSwitchGeneration,
               recovery.sourceGeneration == sourceSwitchGeneration,
               recovery.resumeGeneration == resumeRetryGeneration,
               recovery.mpvLoadToken == loadToken,
               loadToken == coordinator.player?.activeLoadToken {
                loadTimeout?.cancel()
                directAVNoFrameRecovery = nil
                DiagnosticsLog.log(
                    "playback",
                    "fallback attempt=\(recovery.attemptID) stage=mpv-terminal outcome=no-first-frame")
                // A viewer-selected source and a saved Continue-Watching source retain their established
                // in-place / one-time re-resolution policy. Automatic playback otherwise hops immediately:
                // the AV and MPV attempts already consumed this source's one bounded opportunity.
                if recoverCurrentNativeDebridLink(reason: "fallback MPV produced no frame") {
                    return
                }
                if currentPickWasExplicit {
                    loadErrorMsg = "This source didn't produce playable media. Choose another source."
                    presentTerminalLoadFailure()
                    return
                }
                if hopToNextSource(reason: "fallback MPV produced no frame") { return }
                if loadErrorMsg.isEmpty { loadErrorMsg = "This source did not produce playable media." }
                presentTerminalLoadFailure()
                return
            }
            loadTimeout?.cancel()
            if !hasStartedPlaying {
                let failureMessage = (data as? String) ?? ""
                // A strict low-resolution, audio-less, non-DV classification is not a decoder fallback case.
                // It is the wrong asset behind a DV-ranked source, so preserve the typed reason and move the
                // existing automatic path to another source instead of reopening the same preview in libmpv.
                if DVPlaybackPolicy.isSourceCapabilityMismatch(failureMessage) {
                    handleLoadFailure(failureMessage)
                    return
                }
                // #76: an AVPlayer item failure before playback started (e.g. a Profile 7 DV remux or a
                // Matroska AVFoundation cannot demux) demotes to libmpv IN PLACE: flipping `avEngineFailed`
                // re-renders `playerSurface` to the mpv surface on the SAME view, which re-loads the stream.
                // This is the true last resort the owner asked for, replacing the heavyweight forceMPV window
                // rebuild for the common case. Genuine mpv failures fall through to the existing recovery.
                // The engine consumes one exact CoreMedia -12927 on a healthy DV mount and mounts its explicit
                // HDR-only recovery item before it emits endFileError. Reaching this chrome edge therefore
                // means recovery was unavailable or already failed, so demotion is final and loop-free.
                // A terminal zero-packet source (the remux pre-scan proved EOF before any timestamped
                // base-video packet) can never produce a frame on libmpv either: it is the same dead bytes,
                // not a decoder problem. Hop to the next source instead of burning a demote on a second
                // engine that is guaranteed to fail the same way.
                if !hasStartedPlaying, RemuxFirstPacketFailure.isTerminalZeroPacket(failureMessage) {
                    DiagnosticsLog.log("dv", "endFileError terminal zero-packet source -> hop instead of demote class=\(safeFailureClass(failureMessage))")
                    if hopToNextSource(reason: "remux terminal zero-packet source") { return }
                    if loadErrorMsg.isEmpty { loadErrorMsg = "This source did not produce playable media." }
                    presentTerminalLoadFailure()
                    return
                }
                if demoteAVPlayerToMPV() { return }
                handleLoadFailure((data as? String) ?? "")
            } else if isAVPlayerActive {
                // #76 residual: a MID-PLAY AVPlayer failure. The audio-over-black watchdog is the canonical
                // emitter here (native DV that plays Atmos over a black screen: the audio clock advances
                // timePos, so hasStartedPlaying flipped and the start watchdog disarmed long ago), and a
                // genuine mid-play item .failed / failed-to-play-to-end lands here too (previously it was
                // silently IGNORED and the session just died on a frozen frame). Demote to libmpv in place,
                // exactly like the pre-start path: mpv re-opens the same stream with an honest HDR10 picture
                // and decoded audio. Mirrors iOS PlayerScreen, which already demotes mid-play. Genuine mpv
                // mid-play errors are untouched (isAVPlayerActive is false): the stall recovery owns those.
                let midPlayAVFailureMessage = (data as? String) ?? "-"
                // A terminal zero-packet source is provably empty end to end, so a hop beats retrying the
                // same dead bytes on libmpv even here. hasStartedPlaying is already true whenever this
                // branch runs in practice, so the guard rarely fires; it stays for parity with the pre-start
                // branch above and to fail safe if that invariant ever loosens.
                if !hasStartedPlaying, RemuxFirstPacketFailure.isTerminalZeroPacket(midPlayAVFailureMessage) {
                    DiagnosticsLog.log("dv", "endFileError terminal zero-packet source (mid-play branch) -> hop instead of demote class=\(safeFailureClass(midPlayAVFailureMessage))")
                    if hopToNextSource(reason: "remux terminal zero-packet source") { return }
                    if loadErrorMsg.isEmpty { loadErrorMsg = "This source did not produce playable media." }
                    presentTerminalLoadFailure()
                    return
                }
                // Buffered-retirement gate (Beta 26 workstream B3): a mid-play item failure that still
                // holds a real loaded cushion is frequently a transient mount fault rather than dead
                // bytes, and the demote below reopens the SAME url through libmpv anyway. ONE
                // same-engine reload at the playhead is strictly cheaper and keeps native DV alive when
                // the retry succeeds. The one-shot flag resets only after a minute of stable progress,
                // so a genuinely dead source cannot loop here.
                let bufferedAheadAtFailure = max(0, bufferedTime - currentTime)
                if !midPlayBufferedReloadUsed, firstFrameRenderedAt != nil,
                   PlayerMidPlaybackStallPolicy.prefersBufferedReloadBeforeRetirement(
                       bufferedAheadSeconds: bufferedAheadAtFailure) {
                    midPlayBufferedReloadUsed = true
                    DiagnosticsLog.log("player", "mid-play AV failure with \(Int(bufferedAheadAtFailure))s buffered -> one same-engine reload before any demote")
                    reloadAtPlayhead()
                    return
                }
                DiagnosticsLog.log("dv", "mid-play AVPlayer endFileError class=\(safeFailureClass(midPlayAVFailureMessage)) -> demote to libmpv in place")
                if demoteAVPlayerToMPV() { return }
                // The demotion was not issued (already demoted, or no surface to swap to), so this failure is
                // still nobody's - which is exactly the unowned state the branch below exists to end. Hand it
                // to the same mid-play ladder rather than leaving the session frozen on its last frame.
                if !isCurrentLiveStream { handleMidPlayFailure((data as? String) ?? "", loadToken: loadToken) }
            } else if !isCurrentLiveStream {
                handleMidPlayFailure((data as? String) ?? "", loadToken: loadToken)
            }
        case MPVProperty.endFileEof:
            let terminalEOFAction = terminalAction(for: loadToken, kind: .eof)
            // A terminal action that persists a completion or parks a superseded terminal cannot advance or
            // exit here: it waits on the requested next target to resolve. NEVER trust that resolve to be
            // bounded (diag-22). This pure policy names exactly those routes; the branches below enforce it by
            // arming the bounded EOF fallback so the session advances-or-exits either way.
            let armsTerminalDeadline =
                EpisodePlaybackIdentity.terminalActionRequiresBoundedDeadline(terminalEOFAction)
            let completionOnly: Bool
            switch terminalEOFAction {
            case .handleCommitted:
                completionOnly = false
            case .handlePending:
                pendingAdvance?.terminal = true
                uncommittedIdentityBlocked = true
                loadTimeout?.cancel()
                handleLoadFailure("Episode ended before its first frame")
                return
            case .markSupersededTerminal:
                supersededAdvance?.pending.terminal = true
                uncommittedIdentityBlocked = true
                if armsTerminalDeadline { armTerminalAdvanceDeadline(reason: "superseded terminal EOF") }
                return
            case .persistOutgoingCompletionOnly:
                completionOnly = true
            case .ignoreOutgoingError, .ignoreStale:
                return
            }
            if !completionOnly, let loadToken {
                guard EpisodicAssetSanityPolicy.canAcceptIncompleteEvidenceAtEOF(
                    callbackOwner: loadToken,
                    deferredFirstFrameOwner: assetSanityDeferredStartToken,
                    hasStartedPlaying: hasStartedPlaying
                ) else {
                    loadTimeout?.cancel()
                    handleLoadFailure("Media ended before its first frame")
                    return
                }
                guard settleAssetSanityIfPossible(
                    loadToken: loadToken, position: currentTime
                ) else {
                    return
                }
                if !assetSanityAttempt.isAccepted(owner: loadToken) {
                    guard acceptIncompleteAssetSanityIfCurrent(
                        loadToken: loadToken, position: currentTime
                    ) else { return }
                }
            }
            if !completionOnly, handleLiveStreamEOF() { break }
            if !markedWatched, let m = curMeta {
                markedWatched = true
                core.markPlaybackWatched(
                    m, target: playbackMutationTarget, allowEngineWrite: EpisodePlaybackIdentity.engineWritesAllowed(
                        boundVideoID: isEpisodePlaybackContext ? enginePlayerVideoId : m.videoId,
                        displayedVideoID: m.videoId
                    )
                )
            }
            // External sync (Trakt/SIMKL): scrobble STOP at end-of-file (a completion). Additive + fail-soft +
            // gated + once-latched inside the coordinator (dedupes against the watched record above), no-op with
            // empty creds. Fired for the finishing episode before any in-place advance opens a new session.
            if !isCurrentLiveStream, let m = curMeta { ScrobbleCoordinator.shared.playbackStopped(m, position: max(currentTime, suppressedResumeFloor ?? 0), duration: duration) }
            if completionOnly {
                // Route was .outgoingCommittedWhileResolving: the outgoing completion is now persisted +
                // scrobbled, but we cannot advance or exit while the requested next target resolves. Arm the
                // bounded fallback instead of trusting that resolve to land (diag-22: a dead TorBox hung this
                // ~15 min). If the next source resolves in time, its load clears the flag and cancels this.
                if armsTerminalDeadline { armTerminalAdvanceDeadline(reason: "persist-completion, next target resolving") }
                return
            }
            if isPaused {
                pendingBoundaryAdvanceAfterPlay = true
                DiagnosticsLog.log("player", "EOF completion parked until explicit play")
                return
            }
            autoAdvance()                                // episode finished → play next, else exit
        default: break
        }
    }

    // MARK: - Remote handling (all input arrives here from the UIKit catcher)

    private func handlePress(_ type: UIPress.PressType) {
        noteInteraction()   // any remote press is presence: re-arm the "Still watching?" idle guard
        if stillWatching {
            switch type {
            case .leftArrow:  stillWatchingWantsStop = false        // focus Continue
            case .rightArrow: stillWatchingWantsStop = true         // focus Stop
            case .select:     if stillWatchingWantsStop { stopStillWatching() } else { continueStillWatching() }
            case .playPause:  continueStillWatching()               // Play/Pause = keep watching
            case .menu:       continueStillWatching()               // Back proves presence: dismiss + resume, never a surprise exit
            default: break
            }
            return
        }
        if showStreamQR {
            if type == .menu || type == .select || type == .playPause { showStreamQR = false }
            return
        }
        if refinding {
            // A re-find is settling fresh sources: only Back cancels it (returns to the details page).
            if type == .menu { refindTask?.cancel(); refinding = false; saveProgress(at: currentTime); leavePlayback() }
            return
        }
        if loadFailed {
            switch type {
            case .menu: saveProgress(at: currentTime); leavePlayback()
            case .select:
                if sourcesExhausted {
                    // Every known source has been tried (or there were none): re-query the add-ons for FRESH
                    // links instead of reopening a panel of already-dead sources.
                    refindSourcesAndRetry()
                } else if !currentSourceGroups.isEmpty {     // jump straight to another (still-untried) source
                    withAnimation { loadFailed = false }
                    openPanel(.sources)
                } else { retryLoad() }
            case .playPause: retryLoad()
            default: break
            }
            return
        }
        if showOptions {
            switch type {
            case .menu:
                switch panelKind {                       // Back from a settings sub-panel returns to its list
                case .audioSettings:    openPanel(.audio)
                case .subtitleSettings: openPanel(.subtitles)
                case .subtitleLanguage: openPanel(.subtitles)
                case .sourceAudio:      openPanel(.sources, preferredAccessibilityID: "sources.audio")
                case .engine:           openPanel(.playerSettings)
                case .sleep:            openPanel(.playerSettings)
                default:                closePanel()
                }
            case .upArrow: moveOption(-1)
            case .downArrow: moveOption(1)
            case .select: activateOption()
            // Left/Right adjust a focused Start/End row in the skip editor (the only panel that uses
            // horizontal input); every other panel ignores it, so the default no-op is unchanged.
            case .leftArrow:  if let f = focusedSkipField { adjustSkipTime(f, -1) }
            case .rightArrow: if let f = focusedSkipField { adjustSkipTime(f, 1) }
            default: break
            }
            return
        }
        if controlsHidden {
            // Up Next band visible: it owns Left/Right/Select/Down (pick + activate + dismiss) so they
            // never fall through to the seek-while-hidden nudge below. Menu (exit), Play/Pause, and Up
            // still behave normally, so the band never traps the remote.
            if upNextRemaining != nil || isCreditsUpNext {
                switch type {
                case .leftArrow:  upNextWantsCredits = false; return   // focus Play Now
                case .rightArrow: upNextWantsCredits = true;  return   // focus Watch Credits
                case .select:
                    if upNextWantsCredits { upNextSuppressed = true } else { requestManualEpisodeNavigation(.next) }
                    return
                case .downArrow:  upNextSuppressed = true; return      // dismiss, keep watching
                default: break                                        // menu / playPause / up fall through
                }
            }
            switch type {
            case .menu:
                // Back consumes a visible skip pill (hide it, keep playing); it exits only when no
                // transient prompt is up - the same dismiss-not-exit precedent as the Up Next band.
                if let seg = skipPillSegment { skipPillDismissedStart = seg.start }
                else { saveProgress(at: currentTime); leavePlayback() }
            case .playPause: toggle()
            case .select:
                if let seg = skipPillSegment { skipTo(seg) } else { showControls() }   // pill up → skip, else reveal
            // Netflix-style seek-while-hidden: Left/Right nudge -/+10s directly, with a brief time pill,
            // WITHOUT revealing the whole control bar. Up/Down (and any other press) still reveal it.
            case .leftArrow: hiddenSeek(-seekStepSeconds)
            case .rightArrow: hiddenSeek(seekStepSeconds)
            default: showControls()                       // up/down + any swipe reveals the bar
            }
            return
        }
        // Control bar is shown: 2D navigation. Up/down moves between rows (close ↔ scrubber ↔ buttons);
        // left/right seeks on the scrubber or moves within the button row.
        switch type {
        case .menu:
            if scrubbing { cancelScrub() } else { saveProgress(at: currentTime); leavePlayback() }
        case .playPause: toggle()
        case .select: activate(selected)
        case .leftArrow: horizontal(-1)
        case .rightArrow: horizontal(1)
        case .upArrow: vertical(-1)
        case .downArrow: vertical(1)
        default: break
        }
    }

    /// True for an IMDb tt####### title, the same gate the iOS control-bar uses to offer the skip editor.
    /// The decision lives in `SkipEditPolicy` so BOTH chromes share it and it is unit-tested: it keys on
    /// CONTENT liveness (`isCurrentLiveStream`, meta type), never on the player's duration/seekability, so a
    /// Dolby-Vision remux (which reports an indefinite/non-seekable HLS to AVPlayer) still offers the editor.
    /// Live streams and non-tt ids (e.g. add-on/Kitsu ids) are excluded: the worker keys off imdb:S:E, so a
    /// non-tt id has nothing to submit against.
    private var canEditSkip: Bool {
        guard let m = curMeta else { return false }
        return SkipEditPolicy.canEdit(isLiveContent: isCurrentLiveStream, contentId: m.libraryId)
    }

    /// The SYNTHESIZED runtime (source seconds) for a skip submission when the engine has not emitted a
    /// finite `duration` (the DV-remux INDEFINITE edge). Reuses the loaded meta's human runtime, the same
    /// value the provisional trickplay key uses, and only when it is THIS title's meta. nil when unknown.
    private var skipSubmissionFallbackRuntimeSeconds: Double? {
        guard let m = curMeta, let loaded = core.metaDetails?.meta, loaded.id == m.libraryId,
              let secs = loaded.runtimeSeconds, secs > 0 else { return nil }
        return secs
    }

    /// The bottom transport row in remote left/right order. `.close` (top bar) and `.scrub` (the seek
    /// bar) are separate rows above this one; up/down moves between the three.
    private var buttonRow: [Control] {
        // Remote left/right order mirrors the on-screen left→right layout (controlBar): the left
        // settings cluster (gear, aspect, speed, sources, quality), then the centre transport, then
        // the right track cluster (audio, subs, episodes, chapters). Keeping this in step with the
        // visual order is what makes d-pad focus land where the eye expects.
        var c: [Control] = [.settings, .aspect, .playback]
        if hasAlternateSources { c.append(.sources) }
        if hasQualityOptions { c.append(.quality) }
        c.append(.restart)
        c.append(.back)
        if showsPreviousEpisodeControl { c.append(.prev) }
        c.append(.play)
        if showsNextEpisodeControl { c.append(.next) }
        c.append(.fwd)
        if !audioTracks.isEmpty { c.append(.audio) }
        c.append(.subs)
        if canEditSkip { c.append(.skipEdit) }
        if allEpisodes.count > 1 { c.append(.episodes) }
        if hasChapters { c.append(.chapters) }
        return c
    }

    /// Left/right: seek when on the scrubber, otherwise move within the button row. `.close` is alone.
    private func horizontal(_ d: Int) {
        switch selected {
        case .scrub: scrubBy(d)
        case .close: flashControls()
        default:
            let row = buttonRow
            let i = row.firstIndex(of: selected) ?? 0
            selected = row[max(0, min(row.count - 1, i + d))]
            lastButton = selected
            flashControls()
        }
    }

    /// Up/down moves between the three rows: close (top) ↔ scrubber ↔ buttons (bottom). A direction
    /// press while scrubbing commits the pending seek first. This makes "Down from the Back button drops
    /// into the controls" work, replacing the old flat left/right-only list.
    private func vertical(_ d: Int) {
        commitScrubIfNeeded()
        // Live has no scrubber row (it shows a LIVE indicator instead), so up/down skips straight
        // between the close button and the transport row, never landing on the absent `.scrub`.
        if isCurrentLiveStream {
            switch selected {
            case .close: if d > 0 { selected = lastButton }
            default:     if d < 0 { selected = .close }
            }
            flashControls()
            return
        }
        switch selected {
        case .close:
            if d > 0 { selected = .scrub }
        case .scrub:
            selected = d < 0 ? .close : lastButton
        default:                                   // a button-row control
            if d < 0 { selected = .scrub }
        }
        flashControls()
    }

    private func activate(_ c: Control) {
        switch c {
        case .close:   saveProgress(at: currentTime); leavePlayback()
        case .scrub:   scrubbing ? commitScrub() : toggle()
        case .restart: restart()
        case .back:    seek(-seekStepSeconds)
        case .fwd:     seek(seekStepSeconds)
        case .play:    toggle()
        case .prev:    requestManualEpisodeNavigation(.previous)
        case .next:    requestManualEpisodeNavigation(.next)
        case .audio:    openPanel(.audio)
        case .subs:     openPanel(.subtitles)
        case .aspect:   openPanel(.aspect)
        case .playback: openPanel(.playback)
        case .episodes: openPanel(.episodes)
        case .chapters: openPanel(.chapters)
        case .sources:  openPanel(.sources)
        case .quality:  openPanel(.quality)
        case .settings: openPanel(.playerSettings)
        case .skipEdit: openSkipEditor()
        }
    }

    /// Seed the skip editor from the current playhead and open its panel. Reset on every open so a fresh
    /// segment never inherits stale times / type / result from a prior submission, matching the iOS bar.
    private func openSkipEditor() {
        DiagnosticsLog.log("skip", SkipEditPolicy.visibilityDiagnostic(
            canEdit: canEditSkip, isLiveContent: isCurrentLiveStream,
            hasSubmittableId: (curMeta.map { SkipEditPolicy.isSubmittableContentId($0.libraryId) } ?? false),
            engine: isAVPlayerActive ? "avplayer" : "libmpv"))
        let snapped = (currentTime * 2).rounded() / 2
        skipEditStart = max(0, snapped)
        skipEditEnd = min(snapped + 30, duration > 0 ? duration : snapped + 60)
        skipEditType = .intro
        skipEditDone = false
        skipEditError = nil
        skipEditSubmitting = false
        skipEditStep = 10
        openPanel(.skipEditor)
    }

    /// The loaded source currently on screen (its playable URL matches what mpv is playing), used to
    /// label the stats overlay with the release name and file size. Nil for a direct-resume link with
    /// no matching loaded source.
    private var currentStream: CoreStream? {
        curSourceStream ?? currentSourceGroups.flatMap(\.streams).first { playableURL(for: $0) == curURL }
    }

    /// Source rows prepended to the live stats: release name + size. The raw filename is omitted here
    /// (the fixed-width overlay can't hold it); the iOS Playback Info list shows it in full.
    private var sourceStatRows: [(String, String)] {
        guard let s = currentStream else { return [] }
        var rows: [(String, String)] = []
        let release = String(sourceLabel(s).prefix(40))
        if !release.isEmpty { rows.append(("Source", release)) }
        if let size = StreamRanking.sizeText(s) { rows.append(("Size", size)) }
        return rows
    }

    /// A low-rate receipt for the user-visible frame-drop counter and its likely causes. The snapshot reads
    /// a handful of mpv properties, so do it once per 30 seconds rather than on the four-Hz player clock.
    /// AVPlayer leaves the mpv-only snapshot empty and therefore emits nothing here.
    private func maybeLogFrameDropReceipt() {
        let now = ProcessInfo.processInfo.systemUptime
        guard lastFrameDropReceiptAt == 0 || now - lastFrameDropReceiptAt >= 30 else { return }
        guard let player = coordinator.player else { return }
        let receipt = player.playbackDiagnostics()
        guard receipt.hasValues else { return }
        lastFrameDropReceiptAt = now
        let count = receipt.frameDropCount ?? 0
        // `frameDropCount` is mpv's raw output-drop counter. The presentation receipt intentionally excludes
        // unsettled renderer/display-switch drops from its scored total, so log both values. Cache state is
        // sampled only at this receipt and is never used to assign a cause to the preceding interval.
        let rawOutputDelta = count >= lastFrameDropCount ? count - lastFrameDropCount : count
        let settledOutputDelta = receipt.framePresentation?.frameDropsSinceReceipt ?? rawOutputDelta
        let cacheStateAtReceipt: String
        if receipt.pausedForCache == true || receipt.cacheUnderrun == true {
            cacheStateAtReceipt = "starved"
        } else if receipt.pausedForCache == nil && receipt.cacheUnderrun == nil {
            cacheStateAtReceipt = "unavailable"
        } else {
            cacheStateAtReceipt = "not-starved"
        }
        lastFrameDropCount = count
        func intText(_ value: Int?) -> String { value.map(String.init) ?? "na" }
        func boolText(_ value: Bool?) -> String {
            value.map { $0 ? "true" : "false" } ?? "na"
        }
        func doubleText(_ value: Double?, decimals: Int = 3) -> String {
            guard let value else { return "na" }
            return String(format: "%.*f", decimals, value)
        }
        let presentationText: String = {
            guard let frame = receipt.framePresentation else { return "" }
            let vo: String
            if let passes = frame.voPasses {
                vo = String(
                    format: "%d/%.2f/%.2f/%@",
                    passes.count, passes.averageMilliseconds,
                    passes.peakMilliseconds, passes.slowest ?? "na"
                )
            } else {
                vo = "pending"
            }
            return String(
                format: " fp=g%llu gate=%@ cscale=%@ priorCscale=%@ drawableAcquire=%d/%d drawableAcquireWaitMs=%.2f/%.2f presentCallback=unavailable-tvos decoderDelta30s=%d sub=%@/%@ cues=%d/%.1fpm vo=%@",
                frame.generation, frame.mitigationGate,
                frame.activeCscale ?? "na",
                frame.mitigationPriorCscale ?? "na",
                frame.drawableRequests, frame.drawableNil,
                frame.drawableWaitAverageMilliseconds,
                frame.drawableWaitMaximumMilliseconds,
                frame.decoderDropsSinceReceipt, frame.subtitleSource,
                frame.subtitleCodec ?? "na", frame.subtitleCueCount,
                frame.subtitleCuesPerMinute, vo
            )
        }()
        VXProbe.log(
            "perf",
            "libmpv outputDrop=\(count) rawOutputDelta30s=\(rawOutputDelta) settledOutputDelta30s=\(settledOutputDelta) cacheStateAtReceipt=\(cacheStateAtReceipt) decoderDrop=\(intText(receipt.decoderFrameDropCount)) mistimed=\(intText(receipt.mistimedFrameCount)) voDelayed=\(intText(receipt.delayedFrameCount)) avsync=\(doubleText(receipt.avSync)) totalAvsyncChange=\(doubleText(receipt.totalAVSyncChange)) pausedForCache=\(boolText(receipt.pausedForCache)) cacheUnderrun=\(boolText(receipt.cacheUnderrun)) cacheIdle=\(boolText(receipt.cacheIdle)) cacheFill=\(intText(receipt.cacheBufferingPercent)) cacheSeconds=\(doubleText(receipt.cacheDuration, decimals: 1)) hwdec=\(receipt.hardwareDecoder ?? "na") vfFps=\(doubleText(receipt.estimatedVideoFPS)) containerFps=\(doubleText(receipt.containerFPS)) displayFps=\(doubleText(receipt.displayFPS)) videoSync=\(receipt.videoSyncMode ?? "na") videoSpeedCorrection=\(doubleText(receipt.videoSpeedCorrection, decimals: 6)) audioSpeedCorrection=\(doubleText(receipt.audioSpeedCorrection, decimals: 6)) ao=\(receipt.audioOutput ?? "na") uiBuffering=\(buffering ? "true" : "false") statsOverlay=\(showStats ? "visible" : "hidden") trickplayCaptureInFlight=\(localTrickplayCaptureInFlight ? "true" : "false") trickplayCaptureIntervalS=\(Int(Self.trickplayCaptureIntervalSecs)) trickplayCaptureAttempts=\(trickplayCaptureAttemptsSinceReceipt) trickplayCaptureCompleted=\(trickplayCaptureCompletionsSinceReceipt) trickplayCaptureNil=\(trickplayCaptureNilSinceReceipt) trickplayContribution=\(scrubThumbnails.isCommunityUploadInFlight ? "active" : "idle") preload=\(preloadTask == nil ? "idle" : "active") warm=\(warmNextTask == nil ? "idle" : "active")\(presentationText)"
        )
        trickplayCaptureAttemptsSinceReceipt = 0
        trickplayCaptureCompletionsSinceReceipt = 0
        trickplayCaptureNilSinceReceipt = 0
    }

    /// Live playback numbers, top-left, refreshed every second while visible.
    private var statsOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(statsRows, id: \.0) { row in
                HStack(spacing: 12) {
                    Text(row.0).foregroundStyle(Theme.Palette.textTertiary)
                    Spacer(minLength: 8)
                    Text(row.1).foregroundStyle(Theme.Palette.textPrimary)
                }
            }
        }
        .font(.system(size: 20, design: .monospaced))
        .padding(Theme.Space.md)
        .frame(width: 440)
        // Compact non-interactive stats notice: warm glass container (field-weight fill keeps the
        // monospace numbers legible over bright video). The number text stays opaque; glass is the
        // container background only.
        .vortxGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                    fillAlpha: VortXGlass.fieldFillAlpha, shadow: .toast)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Theme.Space.xl)
        .task(id: showStats) {
            while showStats, !Task.isCancelled {
                statsRows = sourceStatRows + (coordinator.player?.playbackStats() ?? [])
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Control bar

    /// Resolution / HDR / audio summary under the title, read live from mpv.
    private func computeMetadataLine() -> String {
        var parts: [String] = []
        // Resolution is defined by WIDTH (4K is ~3840 wide at ANY aspect), so a 2.40:1 4K film (3840x1600)
        // is NOT mislabeled "1440p" off its 1600 height. Width when known, else a 16:9 height estimate while
        // the first frame is still loading.
        let res = videoWidth > 0 ? videoWidth : Int(Double(videoHeight) * 16.0 / 9.0)
        switch res {
        case 3000...:     parts.append("4K")
        case 2200..<3000: parts.append("1440p")
        case 1500..<2200: parts.append("1080p")
        case 1000..<1500: parts.append("720p")
        case 1..<1000:    if videoHeight > 0 { parts.append("\(videoHeight)p") }
        default:          break
        }
        if isHDR { parts.append("HDR") }
        if !audioCodec.isEmpty {
            let channelSuffix = audioChannels > 0 ? " \(audioChannels)ch" : ""
            parts.append("\(audioLabel(audioCodec))\(channelSuffix)")
        }
        return parts.joined(separator: "  ·  ")
    }

    /// Clear produced AVPlayer audio facts at every physical-load boundary. A following track-list event
    /// republishes truth from the newly mounted engine; until then the chrome must show no prior engine's
    /// codec or channel count, especially during an AVPlayer-to-libmpv demotion.
    private func clearCachedAudioOutputTruth() {
        audioCodec = ""
        audioChannels = 0
        metadataLine = computeMetadataLine()
    }

    private func audioLabel(_ c: String) -> String {
        switch c.lowercased() {
        case "eac3":               return "EAC3"
        case "ac3":                return "AC3"
        case "truehd":             return "TrueHD"
        case "dts", "dts-hd", "dca": return "DTS"
        case "aac":                return "AAC"
        case "flac":               return "FLAC"
        case "opus":               return "Opus"
        case "mp3":                return "MP3"
        default:                   return c.uppercased()
        }
    }

    private var controlBar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Theme.Space.lg) {
                ctrlButton(.close, "chevron.left")
                Spacer(minLength: Theme.Space.lg)
                VStack(alignment: .trailing, spacing: 6) {
                    if !curTitle.isEmpty {
                        Text(displayTitle).font(Theme.Typography.sectionTitle)
                            .foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
                    }
                    if !metadataLine.isEmpty {
                        Text(metadataLine).font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 60).padding(.top, 50)
            .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))

            Spacer()

            VStack(spacing: Theme.Space.lg) {
                if isCurrentLiveStream {
                    // Live: no seekable scrubber (there's no fixed duration to scrub within), just a
                    // LIVE indicator. The user pauses/resumes; there's nothing to seek to. The `.scrub`
                    // control row is unreachable for live (see vertical()), so this stays presentation-only.
                    liveIndicator
                } else {
                    trickplayControls
                }
                ZStack {
                    HStack(spacing: Theme.Space.md) {
                        ctrlButton(.restart, "arrow.counterclockwise")
                        ctrlButton(.back, "gobackward.\(seekStep)")
                        if showsPreviousEpisodeControl { ctrlButton(.prev, "backward.end.fill") }
                        ctrlButton(.play, isPaused ? "play.fill" : "pause.fill", big: true)
                        if showsNextEpisodeControl { ctrlButton(.next, "forward.end.fill") }
                        ctrlButton(.fwd, "goforward.\(seekStep)")
                    }
                    // Left cluster: the gear plus the "how it plays" controls (aspect, speed, source and
                    // quality switching). Grouping them here unclutters the right side, which was
                    // crowding the centre transport so the skip and audio buttons overlapped.
                    HStack(spacing: Theme.Space.md) {
                        ctrlButton(.settings, "gearshape.fill")
                        ctrlButton(.aspect, "aspectratio")
                        ctrlButton(.playback, "speedometer")
                        if hasAlternateSources { ctrlButton(.sources, "rectangle.2.swap") }
                        if hasQualityOptions { ctrlButton(.quality, "4k.tv") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Right cluster: the "what plays" controls - audio/subtitle tracks and navigation.
                    HStack(spacing: Theme.Space.md) {
                        if !audioTracks.isEmpty { ctrlButton(.audio, "waveform") }
                        ctrlButton(.subs, "captions.bubble")
                        if canEditSkip { ctrlButton(.skipEdit, "checkmark.bubble") }
                        if allEpisodes.count > 1 { ctrlButton(.episodes, "list.bullet") }
                        if hasChapters { ctrlButton(.chapters, "list.bullet.below.rectangle") }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 60).padding(.bottom, 50)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom))
        }
        .transition(.opacity)
    }

    /// Seekable ember bar with a knob. When the scrubber row is focused it thickens; while scrubbing it
    /// shows the preview playhead (the not-yet-committed target). Left/right move the preview and the seek
    /// commits shortly after the last move (see scrubBy / commitScrub), so it works like a YouTube scrubber.
    private var scrubber: some View {
        let focused = (selected == .scrub)
        let shown = scrubbing ? scrubTarget : currentTime
        return GeometryReader { geo in
            let frac = duration > 0 ? min(1, max(0, shown / duration)) : 0
            let w = geo.size.width
            let barH: CGFloat = focused ? 10 : 6
            let knob: CGFloat = focused ? 28 : 18
            ZStack(alignment: .leading) {
                // Track + played fill in the viewer's chosen seek-bar style (classic/wave/heartbeat/…).
                // Only the visual swaps; the knob, chapter ticks, and scrub logic below are unchanged.
                SeekBarTrack(style: SeekBarStyle.current, progress: frac,
                             accent: Theme.Palette.accent,
                             track: Theme.Palette.textPrimary.opacity(0.22),
                             buffered: duration > 0 ? min(1, max(0, bufferedTime / duration)) : 0)
                    .frame(width: w, height: focused ? 24 : 16)
                // Chapter boundary ticks along the bar (decorative; the knob still reads over them).
                ForEach(chapterFractions, id: \.self) { f in
                    Capsule().fill(.white.opacity(0.5)).frame(width: 2, height: barH).offset(x: w * f)
                }
                Circle().fill(Theme.Palette.accent).frame(width: knob, height: knob)
                    .overlay(Circle().stroke(Theme.Palette.canvas, lineWidth: focused ? 3 : 0))
                    .shadow(color: Theme.Palette.accent.opacity(0.6), radius: focused ? 10 : 6)
                    .offset(x: max(0, w * frac - knob / 2))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.15), value: focused)
            // Linear so consecutive scrub steps blend into one continuous glide instead of each easing
            // out and stuttering against the next; slightly longer when not scrubbing so the play head
            // drifts smoothly between the position updates.
            .animation(
                accessibilityReduceMotion ? nil : (scrubbing ? .linear(duration: 0.16) : .linear(duration: 0.28)),
                value: frac
            )
        }
        .frame(height: 28)
    }

    /// The Live position indicator shown in place of the scrubber: a red dot + "LIVE", and a running
    /// elapsed timer so the user can still see playback is advancing. Mirrors PlayerScreen.liveIndicator.
    private var liveIndicator: some View {
        HStack(spacing: Theme.Space.md) {
            HStack(spacing: 9) {
                Circle().fill(Theme.Palette.danger).frame(width: 12, height: 12)
                Text("LIVE").font(.callout.weight(.heavy)).foregroundStyle(Theme.Palette.textPrimary).tracking(1.5)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            // Glass LIVE pill: the danger dot + label stay opaque (status colour); glass is the
            // container only. Flat shadow so it reads inline within the transport chrome.
            .vortxGlass(in: Capsule(), fillAlpha: VortXGlass.pillFillAlpha, shadow: .flat)
            Spacer(minLength: 0)
            if currentTime > 0 {
                Text(timeString(currentTime)).font(.callout.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .frame(height: 28)
    }

    /// Circular control, highlighted (ember fill + lift) when it is the selected control. Visual only;
    /// activation is driven by the remote handler, not a tap.
    private func ctrlButton(_ c: Control, _ icon: String, big: Bool = false) -> some View {
        let sel = (selected == c)
        let d: CGFloat = big ? 92 : 64
        return Image(systemName: icon)
            .font(.system(size: big ? 38 : 26, weight: .semibold))
            .foregroundStyle(sel ? Theme.Palette.canvas : Theme.Palette.textPrimary)
            .frame(width: d, height: d)
            .background { ctrlButtonBackground(sel) }
            .scaleEffect(accessibilityReduceMotion ? 1.0 : (sel ? 1.12 : 1.0))
            .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.18), value: sel)
    }

    /// The SELECTED (remote-focused) button keeps the solid accent fill: that bold ember disc IS the
    /// 10-foot focus indicator and must stay legible from the couch, so it is deliberately not softened.
    /// The RESTING discs wear the shared VortX glass (mockup transport discs), which renders warm glass on
    /// older tvOS and upgrades to Apple Liquid Glass on tvOS 26, matching the nav chrome. Background only:
    /// the remote-driven `selected` focus state and navigation are untouched.
    @ViewBuilder private func ctrlButtonBackground(_ selected: Bool) -> some View {
        if selected {
            Circle().fill(Theme.Palette.accent)
        } else {
            Circle().fill(.clear).vortxGlass(in: Circle(), fillAlpha: VortXGlass.pillFillAlpha, shadow: .disc)
        }
    }

    // MARK: - Options panel (audio / subtitles / episodes), driven by optionRow

    /// Tags a skip-editor row so the remote handler knows a focused Start/End row takes Left/Right to
    /// adjust the time (every other panel ignores Left/Right). nil for all non-editor rows.
    private enum SkipField { case start, end }

    private struct OptionRow: Identifiable {
        let id: String
        let accessibilityID: String
        let explicitAccessibilityID: String?
        let label: String
        var detail: String = ""        // right-aligned secondary text (e.g. current value)
        var isSelected: Bool = false
        var isHeader: Bool = false     // section header, not focusable, skipped in navigation
        var isEnabled: Bool = true
        var skipField: SkipField? = nil   // non-nil only on the skip editor's Start/End rows
        var action: () -> Void = {}

        init(
            accessibilityID: String? = nil,
            label: String,
            detail: String = "",
            isSelected: Bool = false,
            isHeader: Bool = false,
            isEnabled: Bool = true,
            skipField: SkipField? = nil,
            action: @escaping () -> Void = {}
        ) {
            let identity = accessibilityID ?? "row.\(UUID().uuidString)"
            self.id = identity
            self.accessibilityID = identity
            self.explicitAccessibilityID = accessibilityID
            self.label = label
            self.detail = detail
            self.isSelected = isSelected
            self.isHeader = isHeader
            self.isEnabled = isEnabled
            self.skipField = skipField
            self.action = action
        }

        func replacingAccessibilityID(_ identity: String) -> OptionRow {
            OptionRow(
                accessibilityID: identity,
                label: label,
                detail: detail,
                isSelected: isSelected,
                isHeader: isHeader,
                isEnabled: isEnabled,
                skipField: skipField,
                action: action
            )
        }
    }

    // Subtitle-sync nudge steps. Primary is 0.5s so a multi-second offset takes a few taps (5s = 10 taps, not
    // 50 at the old 0.1s); a fine 0.1s trim stays for exact alignment. Hardcoded for now (RemoteConfig later).
    private static let subSyncStep = 0.5
    private static let subSyncFine = 0.1
    private static let subSyncStepLabel = "0.5s"
    private static let subSyncFineLabel = "0.1s"

    /// Localize a display label whose English text is only known at runtime (e.g. a `SubtitleStyle` preset
    /// name). The English string doubles as the catalog key, so it resolves through `Localizable.xcstrings`
    /// and falls back to itself when no translation exists.
    private static func l10n(_ key: String) -> String { String(localized: LocalizedStringResource(stringLiteral: key)) }

    /// Rows for the currently-open panel only, never mixed. Tracks are grouped by language; a "Settings"
    /// row drills into a dedicated sub-panel (sync / size / colour for subtitles, sync for audio).
    private var optionRows: [OptionRow] {
        switch panelKind {
        case .audio:
            var rows = groupedTrackRows(audioTracks) { id in
                suppressRapidBufferingRecovery(reason: "user audio track")
                optimisticSelect(type: "audio", id: id); coordinator.player?.setAudioTrack(id); refreshTracksSoon()
            }
            // Audio Sync is libmpv-only (setAudioDelay is a no-op on AVPlayer, which offers no track offset), so
            // hide the drill-in when the AVFoundation engine is active (#76). Track selection itself works on both.
            if !isAVPlayerActive {
                rows.append(OptionRow(label: String(localized: "Audio Settings"), detail: "›") { openPanel(.audioSettings) })
            }
            return rows
        case .audioSettings:
            // Reached only on libmpv (the drill-in above is hidden on AVPlayer); guard anyway so a stale
            // navigation never shows inert controls.
            if isAVPlayerActive {
                return [OptionRow(label: String(localized: "Audio sync isn't available on the Dolby Vision player"), isHeader: true)]
            }
            let now = String(format: "%+.1fs", audioDelay)
            var rows = [OptionRow(label: String(localized: "Sync"), isHeader: true),
                        OptionRow(label: String(localized: "Earlier  −0.1s"), detail: now) { adjustAudioDelay(-0.1) },
                        OptionRow(label: String(localized: "Later  +0.1s"), detail: now) { adjustAudioDelay(0.1) }]
            if audioDelay != 0 { rows.append(OptionRow(label: String(localized: "Reset")) { adjustAudioDelay(-audioDelay) }) }
            // Output mode, mirrored from Settings so it is reachable mid-playback (iOS parity: the iOS
            // player ships the same section). Applies live; mpv re-opens the audio output on the change.
            let mode = AudioOutputMode.current
            rows.append(OptionRow(label: String(localized: "Output"), isHeader: true))
            for m in AudioOutputMode.allCases {
                rows.append(OptionRow(label: m.label, isSelected: m == mode) {
                    coordinator.player?.setAudioOutputMode(m)
                })
            }
            return rows
        case .subtitles:
            // Settings FIRST (the user's primary in-session action), then Off, then one row per language.
            // Each language row drills into `.subtitleLanguage`, which lists every sub in that language
            // across embedded + add-on + community sources, so a title with dozens of subs no longer
            // forces one endless flat scroll.
            var rows = [OptionRow(label: String(localized: "Subtitle Settings"), detail: "›") { openPanel(.subtitleSettings) }]
            rows.append(OptionRow(
                label: String(localized: "Off"),
                isSelected: subtitleTracks.allSatisfy { !$0.selected || !$0.isSelectable }
            ) {
                userPickedSubtitle = true
                suppressRapidBufferingRecovery(reason: "user subtitle off")
                optimisticSelect(type: "sub", id: -1)
                coordinator.player?.setSubtitleTrack(-1); refreshTracksSoon()
                VXProbe.event("subs", "subs selected off")
            })
            // External subtitles from the installed subtitle add-ons. Work on BOTH engines now: libmpv sub-adds
            // the downloaded file (it joins the embedded list above); AVPlayer parses it and renders the cues
            // over the video itself. When the opt-in "only preferred languages" toggle is on, non-preferred
            // languages are hidden (unknown-language subs always kept so the list never empties).
            let availableAddon = TrackSelector.keepingPreferredSubtitleLanguages(
                addonSubs.filter { !addedSubURLs.contains($0.url) }, language: { $0.lang })
            // Community-pooled subtitles (P2): other users' extracted subs for this title. Same opt-in
            // preferred-language filter as the add-on rows above.
            let availablePooled = TrackSelector.keepingPreferredSubtitleLanguages(
                pooledSubs.filter { !addedPooledIDs.contains($0.id) }, language: { $0.lang })
            // Union of every language offered by ANY source, each with its total count.
            var languageCounts: [String: Int] = [:]
            for t in subtitleTracks { languageCounts[subtitleLanguageKey(t.lang), default: 0] += 1 }
            for s in availableAddon { languageCounts[subtitleLanguageKey(s.lang), default: 0] += 1 }
            for s in availablePooled { languageCounts[subtitleLanguageKey(s.lang), default: 0] += 1 }
            for code in languageCounts.keys.sorted(by: { langName($0) < langName($1) }) {
                let count = languageCounts[code] ?? 0
                let hasSelection = subtitleTracks.contains {
                    $0.isSelectable && $0.selected && subtitleLanguageKey($0.lang) == code
                }
                rows.append(OptionRow(label: langName(code), detail: "\(count) ›", isSelected: hasSelection) {
                    subtitleLanguageCode = code
                    openPanel(.subtitleLanguage)
                })
            }
            if languageCounts.isEmpty {
                rows.append(OptionRow(label: String(localized: "No subtitles available"), isHeader: true))
            }
            return rows
        case .subtitleLanguage:
            guard let code = subtitleLanguageCode else { return [] }
            var rows: [OptionRow] = []
            // Embedded tracks in this language first (a sub-added external file also lands here on libmpv).
            let embedded = subtitleTracks.filter { subtitleLanguageKey($0.lang) == code }
            if !embedded.isEmpty {
                rows.append(OptionRow(label: String(localized: "Embedded"), isHeader: true))
                for (i, t) in embedded.enumerated() {
                    rows.append(OptionRow(
                        label: t.title.isEmpty ? "Track \(i + 1)" : t.title,
                        detail: t.unavailableReason ?? "",
                        isSelected: t.isSelectable && t.selected,
                        isEnabled: t.isSelectable
                    ) {
                        guard t.isSelectable else { return }
                        userPickedSubtitle = true
                        suppressRapidBufferingRecovery(reason: "user embedded subtitle")
                        optimisticSelect(type: "sub", id: t.id)
                        coordinator.player?.setSubtitleTrack(t.id); refreshTracksSoon()
                        let lang = langName(t.lang)
                        VXProbe.event("subs", "subs selected \(lang)")
                    })
                }
            }
            let languageAddon = TrackSelector.keepingPreferredSubtitleLanguages(
                addonSubs.filter { !addedSubURLs.contains($0.url) && subtitleLanguageKey($0.lang) == code },
                language: { $0.lang })
            if !languageAddon.isEmpty {
                rows.append(OptionRow(label: String(localized: "From add-ons"), isHeader: true))
                for sub in languageAddon.prefix(60) {
                    let loading = subtitleLoadingURL == sub.url
                    rows.append(OptionRow(label: sub.addonName,
                                          detail: loading ? String(localized: "Loading…") : String(localized: "Add-on")) {
                        // Non-blocking: download + sub-add happen off the main thread with a timeout, so a
                        // slow / hanging subtitle endpoint can't freeze the player. The row shows Loading…
                        // until the track arrives (then it moves into the embedded list above).
                        // Bind the engine BEFORE latching subtitleLoadingURL: `coordinator.player` is a weak
                        // reference that is nil in the engine demote/switch render gap (see
                        // demoteAVPlayerToMPV's deferral note), and an optional-chained call there would
                        // swallow the completion, stranding the latch so EVERY later subtitle pick is
                        // silently dead for the session (the "stuck on Loading…" report).
                        guard subtitleLoadingURL == nil, let player = coordinator.player else { return }
                        userPickedSubtitle = true
                        suppressRapidBufferingRecovery(reason: "user external subtitle")
                        subtitleLoadingURL = sub.url
                        refreshTracksSoon()
                        let subtitleLoadToken = player.activeLoadToken
                        let subtitleVideoID = curMeta?.videoId
                        player.addExternalSubtitle(url: sub.url, title: sub.addonName, lang: sub.lang) { ok in
                            guard permitsSubtitlePublication(
                                loadToken: subtitleLoadToken, videoID: subtitleVideoID
                            ) else { return }
                            subtitleLoadingURL = nil
                            // Record the add ONLY when it landed on the still-live engine: a demote/switch
                            // mid-download applies the sub to the dead engine, and recording it would drop
                            // the row from the list with nothing rendering (dead until panel re-open).
                            if ok, player === coordinator.player { addedSubURLs.insert(sub.url); hoardAddonSubtitle(sub) }
                            else if !ok { showEngineNote(String(localized: "Subtitle failed to load")) }   // honest failure (iOS shows an alert; tvOS showed nothing)
                            if ok, player === coordinator.player {
                                applyCurrentSubtitleDelayIfReady(force: false)
                            }
                            refreshTracksSoon()
                            VXProbe.event("subs", "subs selected \(langName(sub.lang)) (add-on ok=\(ok))")
                        }
                    })
                }
            }
            let languagePooled = TrackSelector.keepingPreferredSubtitleLanguages(
                pooledSubs.filter { !addedPooledIDs.contains($0.id) && subtitleLanguageKey($0.lang) == code },
                language: { $0.lang })
            if !languagePooled.isEmpty {
                rows.append(OptionRow(label: String(localized: "Community"), isHeader: true))
                for sub in languagePooled.prefix(60) {
                    let loading = subtitleLoadingURL == sub.url.absoluteString
                    rows.append(OptionRow(label: pooledLabel(sub),
                                          detail: loading ? String(localized: "Loading…") : String(localized: "Community")) {
                        userPickedSubtitle = true
                        suppressRapidBufferingRecovery(reason: "user pooled subtitle")
                        selectPooledSubtitle(sub)
                    })
                }
            }
            return rows
        case .subtitleSettings:
            let now = String(format: "%+.1fs", subDelay)
            var rows: [OptionRow] = []
            if coordinator.player?.subtitleDelayAvailable == true {
                rows.append(OptionRow(label: String(localized: "Sync"), isHeader: true))
                rows.append(OptionRow(label: String(localized: "Earlier  −\(Self.subSyncStepLabel)"), detail: now) { adjustSubDelay(-Self.subSyncStep) })
                rows.append(OptionRow(label: String(localized: "Later  +\(Self.subSyncStepLabel)"), detail: now) { adjustSubDelay(Self.subSyncStep) })
                rows.append(OptionRow(label: String(localized: "Earlier  −\(Self.subSyncFineLabel)"), detail: now) { adjustSubDelay(-Self.subSyncFine) })
                rows.append(OptionRow(label: String(localized: "Later  +\(Self.subSyncFineLabel)"), detail: now) { adjustSubDelay(Self.subSyncFine) })
                if subDelay != 0 { rows.append(OptionRow(label: String(localized: "Reset")) { adjustSubDelay(-subDelay) }) }
            } else {
                rows.append(OptionRow(label: "Sync unavailable · external subtitles only", isHeader: true))
            }
            rows.append(OptionRow(label: String(localized: "Font"), isHeader: true))
            for f in SubtitleStyle.fonts { rows.append(OptionRow(label: Self.l10n(f.label), isSelected: subFont == f.id) { setSubtitleFont(f.id) }) }
            rows.append(OptionRow(label: String(localized: "Size"), isHeader: true))
            for s in SubtitleStyle.sizes { rows.append(OptionRow(label: Self.l10n(s.label), isSelected: subSize == s.id) { setSubtitleSize(s.id) }) }
            let scalePct = "\(Int((subSizeScale * 100).rounded()))%"
            rows.append(OptionRow(label: String(localized: "Smaller  −"), detail: scalePct) { adjustSubScale(-1) })
            rows.append(OptionRow(label: String(localized: "Bigger  +"), detail: scalePct) { adjustSubScale(1) })
            rows.append(OptionRow(label: String(localized: "Colour"), isHeader: true))
            for c in SubtitleStyle.colors { rows.append(OptionRow(label: Self.l10n(c.label), isSelected: subColor == c.id) { setSubtitleColor(c.id) }) }
            rows.append(OptionRow(label: String(localized: "Brightness"), isHeader: true))
            for b in SubtitleStyle.brightnessLevels { rows.append(OptionRow(label: b.label, isSelected: subBrightness == b.id) { setSubtitleBrightness(b.id) }) }
            rows.append(OptionRow(label: String(localized: "Background"), isHeader: true))
            for b in SubtitleStyle.backgrounds { rows.append(OptionRow(label: Self.l10n(b.label), isSelected: subBackground == b.id) { setSubtitleBackground(b.id) }) }
            return rows
        case .aspect:
            // Live mode wins while mounted (the engine's state is authoritative); the persisted pick is the
            // fallback for the brief mount gap and the value the next load re-applies (iOS parity).
            let mode = coordinator.player?.videoSizeMode ?? videoSize
            return [
                OptionRow(label: "Fit  ·  default", isSelected: mode == "original") { videoSize = "original"; coordinator.player?.setVideoSize("original") },
                OptionRow(label: "Fill  ·  crop to screen", isSelected: mode == "fill" || mode == "zoom") { videoSize = "fill"; coordinator.player?.setVideoSize("fill") },
                OptionRow(label: "Stretch  ·  fill, distort", isSelected: mode == "stretch") { videoSize = "stretch"; coordinator.player?.setVideoSize("stretch") },
            ]
        case .playback:
            var rows: [OptionRow] = [OptionRow(label: "Speed", isHeader: true)]
            for s in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
                rows.append(OptionRow(label: s == 1.0 ? "Normal  ·  1×" : "\(s.formatted())×",
                                      isSelected: abs(playSpeed - s) < 0.01) {
                    playSpeed = s
                    coordinator.player?.setSpeed(s)
                })
            }
            return rows
        case .playerSettings:
            return playerSettingsRows()
        case .engine:
            return engineRows()
        case .sleep:
            return sleepRows()
        case .skipEditor:
            return skipEditorRows()
        case .episodes:
            return allEpisodes.map { ep in
                OptionRow(label: "E\(ep.episodeNumber)  ·  \(ep.episodeTitle)", isSelected: ep.id == curMeta?.videoId) {
                    // Re-picking the CURRENT episode (an immediate replay of the one that just finished) keeps the
                    // same ScrobbleCoordinator session key, so without a fresh per-playback token the scrobble start
                    // is suppressed as a same-session re-entry (startSent still latched) and the replay never
                    // scrobbles. Mint a new token so the coordinator opens a fresh session. A DIFFERENT episode
                    // changes the key and resets the latches on its own, so it needs no re-mint here.
                    if ep.id == curMeta?.videoId { playbackSessionID = UUID().uuidString }
                    play(episode: ep)
                }
            }
        case .chapters:
            let chs = coordinator.player?.chapters() ?? []
            if chs.isEmpty { return [OptionRow(label: "No chapters", isHeader: true)] }
            // Current chapter = the last one starting at or before the play head; selecting seeks to it.
            let currentIdx = chs.lastIndex { $0.start <= currentTime + 0.5 }
            return chs.enumerated().map { i, ch in
                OptionRow(label: ch.title.isEmpty ? "Chapter \(i + 1)" : ch.title,
                          detail: timeString(ch.start), isSelected: i == currentIdx) {
                    cancelPendingLibmpvResumeForUserSeek()
                    coordinator.player?.seek(to: ch.start)
                }
            }
        case .sources:
            return sourceRows()
        case .sourceAudio:
            return audioLanguageFilterRows()
        case .quality:
            // Best playable stream per distinct resolution (4K / 1080p / …), best-first, mirroring the
            // iOS in-player quality picker. Picking one switches the stream in place at the same spot.
            let opts = StreamRanking.resolutionOptions(currentSourceGroups)
            guard opts.count > 1 else { return [OptionRow(label: "Only one quality available", isHeader: true)] }
            return opts.map { opt in
                OptionRow(label: opt.label, detail: StreamRanking.sourceDetail(opt.stream).size ?? "",
                          isSelected: playableURL(for: opt.stream) == curURL) {
                    resolveAndSwitchStream(to: opt.stream, addon: addonName(for: opt.stream))
                }
            }
        }
    }

    /// Group tracks by language so multiple same-language tracks read clearly (e.g. an "English" header
    /// with two variants), instead of a flat list of identical "English" rows.
    private func groupedTrackRows(_ tracks: [MPVTrack], select: @escaping (Int) -> Void) -> [OptionRow] {
        let groups = Dictionary(grouping: tracks) { $0.lang.isEmpty ? "und" : $0.lang.lowercased() }
        var rows: [OptionRow] = []
        for code in groups.keys.sorted(by: { langName($0) < langName($1) }) {
            guard let ts = groups[code] else { continue }   // defensive; key comes from groups.keys so always present (mirrors iOS)
            if ts.count == 1 {
                let t = ts[0]
                let detail = [
                    t.title.isEmpty ? nil : t.title,
                    t.unavailableReason
                ].compactMap { $0 }.joined(separator: " · ")
                rows.append(OptionRow(
                    label: langName(code),
                    detail: detail,
                    isSelected: t.isSelectable && t.selected,
                    isEnabled: t.isSelectable
                ) {
                    guard t.isSelectable else { return }
                    select(t.id)
                })
            } else {
                rows.append(OptionRow(label: langName(code), isHeader: true))
                for (i, t) in ts.enumerated() {
                    rows.append(OptionRow(
                        label: t.title.isEmpty ? "Track \(i + 1)" : t.title,
                        detail: t.unavailableReason ?? "",
                        isSelected: t.isSelectable && t.selected,
                        isEnabled: t.isSelectable
                    ) {
                        guard t.isSelectable else { return }
                        select(t.id)
                    })
                }
            }
        }
        return rows
    }

    private func langName(_ code: String) -> String {
        // Delegate to the shared helper so tvOS shows FULL names (English/French/Italian) and handles
        // 3-letter ISO 639-2 codes (eng/fre/ita) and region-tagged codes (pt-BR) gracefully, matching iOS/Mac.
        fullLanguageName(code)
    }

    /// Canonical key for the per-language subtitle groups: lowercase, with 3-letter ISO 639-2 codes folded
    /// to their 2-letter base (eng -> en) so embedded, add-on and community subs share one language row.
    /// Empty / und / unknown all fold to "und" (one "Unknown" bucket), mirroring `groupedTrackRows`.
    private func subtitleLanguageKey(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, trimmed != "und", trimmed != "unknown" else { return "und" }
        if Locale.current.localizedString(forLanguageCode: trimmed) != nil { return trimmed }
        if let base = Locale(identifier: trimmed).language.languageCode?.identifier, base != trimmed {
            return base
        }
        return trimmed
    }

    // MARK: - Skip-segment editor panel (tvOS)

    /// The skip editor's rows. Type section (intro / recap / outro / preview), Start + End time rows
    /// (Left/Right adjust, Select snaps to the playhead), then a Submit row that reflects in-flight /
    /// success / error / already-submitted state. A previously-submitted type shows a check in its row.
    private func skipEditorRows() -> [OptionRow] {
        guard let m = curMeta else { return [OptionRow(label: "Unavailable for this title", isHeader: true)] }
        let key = skipSubmitKey(m, type: skipEditType)
        let already = skipEditSubmittedKeys.contains(key)
        let segLen = max(0, skipEditEnd - skipEditStart)

        var rows: [OptionRow] = [OptionRow(label: "Type", isHeader: true)]
        for t in SkipDBSubmitView.SegmentType.allCases {
            let tKey = skipSubmitKey(m, type: t)
            rows.append(OptionRow(label: t.label, detail: skipEditSubmittedKeys.contains(tKey) ? "submitted" : "",
                                  isSelected: skipEditType == t) {
                guard skipEditType != t else { return }
                skipEditType = t
                skipEditDone = false
                skipEditError = nil
            })
        }

        rows.append(OptionRow(label: "Times", isHeader: true))
        rows.append(OptionRow(label: "Start", detail: timeString(skipEditStart),
                              skipField: .start) { skipEditStart = max(0, (currentTime * 2).rounded() / 2) })
        rows.append(OptionRow(label: "End", detail: timeString(skipEditEnd),
                              skipField: .end) { skipEditEnd = max((currentTime * 2).rounded() / 2, skipEditStart + 0.5) })
        rows.append(OptionRow(label: "Length", detail: String(format: "%.1fs", segLen), isHeader: true))

        rows.append(OptionRow(label: "Submit", isHeader: true))
        if skipEditSubmitting {
            rows.append(OptionRow(label: "Submitting…"))
        } else if skipEditDone {
            rows.append(OptionRow(label: "Submitted. Thank you", isSelected: true))
        } else if already {
            rows.append(OptionRow(label: "Resubmit this \(skipEditType.label.lowercased())") { submitSkipEditor(meta: m) })
        } else {
            rows.append(OptionRow(label: "Submit \(skipEditType.label.lowercased())") { submitSkipEditor(meta: m) })
        }
        if let err = skipEditError {
            rows.append(OptionRow(label: err, isHeader: true))
        }
        return rows
    }

    /// imdb:S:E:type key for the "already submitted" check, matching the iOS editor's key shape.
    private func skipSubmitKey(_ m: PlaybackMeta, type: SkipDBSubmitView.SegmentType) -> String {
        "\(m.libraryId):\(m.season ?? 0):\(m.episode ?? 0):\(type.rawValue)"
    }

    /// Adjust the focused Start/End row by one accelerating step, reusing the scrubber's press-repeat ramp
    /// (fine 10s taps, growing to 75s on a hold) so crossing a long film takes a few presses, not dozens.
    /// Clamped so Start stays >= 0 and End stays > Start; both within the file duration when it is known.
    private func adjustSkipTime(_ field: SkipField, _ dir: Int) {
        let now = Date().timeIntervalSinceReferenceDate
        if now - skipEditLastAdjustAt < 0.4, dir == skipEditLastDir {
            skipEditStep = min(skipEditStep + 6, 75)
        } else {
            skipEditStep = 10   // a pause, or a direction reversal, resets to fine steps so it does not overshoot
        }
        skipEditLastAdjustAt = now
        skipEditLastDir = dir
        let upper = duration > 0 ? duration : .greatestFiniteMagnitude
        let delta = Double(dir) * skipEditStep
        switch field {
        case .start:
            skipEditStart = min(max(0, skipEditStart + delta), max(0, min(upper, skipEditEnd) - 0.5))
        case .end:
            skipEditEnd = min(max(skipEditStart + 0.5, skipEditEnd + delta), upper)
        }
        skipEditDone = false
        skipEditError = nil
        // Preview the new boundary under the playhead so the user sees where it lands, like the scrubber.
        let target = field == .start ? skipEditStart : skipEditEnd
        cancelPendingLibmpvResumeForUserSeek()
        coordinator.player?.seek(to: target)
        currentTime = target
        if showOptions { refreshPanelRowsPreservingAccessibilityFocus() }   // refresh the time readout in place
        scheduleHide()
    }

    /// Submit the edited segment. Reuses SkipDBClient.submit (keyless skip.vortx.tv, plus skipdb.tv /
    /// custom provider when keyed) exactly like the iOS editor; on success it invalidates the cache and
    /// re-fetches so the new span shows on the scrubber. The panel stays open to show the result.
    private func submitSkipEditor(meta: PlaybackMeta) {
        guard !skipEditSubmitting else { return }
        skipEditSubmitting = true
        skipEditError = nil
        skipEditDone = false
        if showOptions { refreshPanelRowsPreservingAccessibilityFocus() }
        let req = SkipDBClient.SubmitRequest(
            imdb_id: meta.libraryId,
            season: meta.season,
            episode: meta.episode,
            segment_type: skipEditType.rawValue,
            start_ms: Int(skipEditStart * 1000),
            end_ms: Int(skipEditEnd * 1000),
            duration_ms: SkipEditPolicy.submissionDurationMs(
                playerDurationSeconds: duration,
                fallbackRuntimeSeconds: skipSubmissionFallbackRuntimeSeconds)
        )
        let key = skipSubmitKey(meta, type: skipEditType)
        Task { @MainActor in
            do {
                try await SkipDBClient.submit(req)
                await SkipDBClient.invalidateCache(imdbId: meta.libraryId, season: meta.season,
                                                   episode: meta.episode, durationSeconds: duration)
                skipEditSubmittedKeys.insert(key)
                skipEditDone = true
                skipFetchKey = ""        // force a re-fetch so the submitted span resolves onto the bar
                fetchSkipTimestamps()
            } catch {
                skipEditError = error.localizedDescription
            }
            skipEditSubmitting = false
            if showOptions { refreshPanelRowsPreservingAccessibilityFocus() }
        }
    }

    // MARK: - Source switching (swap to another loaded source without leaving the player)

    private var isEpisodePlaybackContext: Bool {
        let target = pendingAdvance?.meta ?? curMeta ?? meta
        if let target, EpisodePlaybackIdentity.isEpisodicContext(
            type: target.type, season: target.season, episode: target.episode,
            videoID: target.videoId
        ) { return true }
        return pendingAdvance != nil || !episodes.isEmpty
    }

    private var sourceTargetMeta: PlaybackMeta? { pendingAdvance?.meta ?? curMeta }

    private func episodeHint(for meta: PlaybackMeta?) -> DebridEpisode? {
        guard isEpisodePlaybackContext, let season = meta?.season, season >= 0,
              let episode = meta?.episode, episode > 0 else { return nil }
        return DebridEpisode(season: season, episode: episode)
    }

    /// Episode panels and failover use only the explicitly targeted stream id. Movies retain the resident
    /// fallback because their engine request has no sibling episode slots to leak across.
    private var currentSourceGroups: [CoreStreamSourceGroup] {
        if isEpisodePlaybackContext, let id = sourceTargetMeta?.videoId {
            return core.streamGroups(forStreamId: id)
        }
        if let id = sourceTargetMeta?.videoId {
            let scoped = core.streamGroups(forStreamId: id)
            if !scoped.isEmpty { return scoped }
        }
        return core.streamGroups()
    }

    private func playableURL(for stream: CoreStream) -> URL? {
        EpisodePlaybackIdentity.resolvedEpisodeMediaURL(
            isUsenet: stream.isUsenet, resolvedURL: nil,
            fallbackURL: stream.playableURL(isEpisode: isEpisodePlaybackContext)
        )
    }

    /// The add-on NAME that supplied `stream` - the app-owned identity `StreamRanking` matches a pin, the
    /// sticky record and the provider-health penalty on (`manifest.name`), as opposed to `engineAddonBase`'s
    /// base URL, which the engine uses for attribution. nil when the stream is not in the loaded groups
    /// (a pasted link, or a Continue-Watching resume whose sources have not arrived yet).
    private func addonName(for stream: CoreStream) -> String? {
        currentSourceGroups.first { $0.streams.contains(stream) }?.addon
    }

    private func engineAddonBase(for stream: CoreStream,
                                 groups: [CoreStreamSourceGroup]? = nil) -> String? {
        guard let id = (groups ?? currentSourceGroups).first(where: { $0.streams.contains(stream) })?.id,
              URL(string: id)?.scheme != nil else { return nil }
        return id
    }

    private func resolvedEpisodeRef(for stream: CoreStream,
                                    meta: PlaybackMeta?) async -> DebridPlaybackRef? {
        let hint = episodeHint(for: meta)
        if isEpisodePlaybackContext, stream.url == nil, hint == nil { return nil }
        return await DebridCoordinator.shared.resolvedPlaybackRef(for: stream, episode: hint)
    }

    @discardableResult
    private func bindEngine(to stream: CoreStream, meta: PlaybackMeta,
                            resolvedURL: URL? = nil,
                            groups: [CoreStreamSourceGroup]? = nil) -> String? {
        guard isEpisodePlaybackContext else {
            core.loadEnginePlayer(for: stream)
            return meta.videoId
        }
        let succeeded = core.loadEnginePlayer(
            for: stream, videoId: meta.videoId,
            base: engineAddonBase(for: stream, groups: groups), resolvedURL: resolvedURL
        )
        return EpisodePlaybackIdentity.boundVideoID(
            requestedVideoID: meta.videoId, bindingSucceeded: succeeded
        )
    }

    /// True when more than one playable source is loaded for the current title / episode. Reads the CACHED
    /// count (see `refreshSourceOptionCounts`): the underlying walk parses a URL per loaded stream, and a
    /// field log had 3315 of them, twice per body pass at 4-12 passes a second.
    private var hasAlternateSources: Bool { altSourceCount > 1 }

    /// True when the loaded sources span more than one distinct resolution, so an in-player quality
    /// picker (4K / 1080p / …) is worth showing. A single-resolution title hides the button. Cached for the
    /// same reason as `hasAlternateSources`.
    private var hasQualityOptions: Bool { qualityOptionCount > 1 }

    /// Recompute the two source-derived button gates. Called only where the answer can actually change: play
    /// start, a stream-set change published by the engine, opening a panel, activating a row, and the panel's
    /// existing revision-gated 1 Hz loop. Mirrors this file's metadataLine / currentSkip caching (:241-244).
    private func refreshSourceOptionCounts() {
        let groups = currentSourceGroups
        altSourceCount = groups.reduce(0) { $0 + $1.streams.filter { playableURL(for: $0) != nil }.count }
        qualityOptionCount = StreamRanking.resolutionOptions(groups).count
    }

    /// The file carries embedded chapter markers (beyond the implicit whole-file chapter), so the Chapters
    /// navigator is worth offering. Same mpv chapter-list the skip-intro detector reads, but from the CACHED
    /// count that `refreshSkipSegments` already fetches: the live form ran 1 + 2N synchronous
    /// `mpv_get_property` calls on the main thread on every body pass.
    private var hasChapters: Bool { chapterCount > 1 }

    /// Up to `maxInPlayerSources` loaded sources, grouped by add-on in their existing priority order, so
    /// switching is quick. The full (sometimes thousands-long) source list stays on the detail page;
    /// capping here keeps the panel light, since the options panel renders its rows eagerly.
    private func sourceRows() -> [OptionRow] {
        // Every add-on contributes its ranked best few, so a single add-on with
        // hundreds of results can no longer flood the panel and bury the rest.
        let perAddon = 5
        let maxInPlayerSources = 60
        var count = 0
        let groups = currentSourceGroups
        if groups.isEmpty {
            return [OptionRow(label: "Loading sources…", isHeader: true)]
        }
        var rows: [OptionRow] = []
        let qualityOptions = StreamRanking.resolutionOptions(groups)
        if !qualityOptions.isEmpty {
            rows.append(OptionRow(accessibilityID: "sources.quality", label: "Quality", detail: "›") {
                openPanel(.quality)
            })
        }
        rows.append(OptionRow(accessibilityID: "sources.audio", label: "Audio", detail: "›") {
            openPanel(.sourceAudio)
        })
        rows.append(OptionRow(accessibilityID: "sources.heading", label: "Sources", isHeader: true))
        // Install the session audio-language filter as a task-local for the ranking reads only (iOS parity,
        // #204): `StreamRanking.score` -> `languageScore` reads `TrackPreferences.current.audioLanguages` live
        // at score time, so this floats the chosen-audio release above a same-resolution foreign-audio one.
        // Nil (Auto) installs nothing and falls back to the persisted profile preference.
        TrackPreferences.$audioLanguagesOverride.withValue(sessionAudioLanguages) {
            for group in groups {
                // T22: at the source cap, BREAK (stop scanning further groups) instead of continuing, so we do not
                // pointlessly re-score every remaining group's streams. The empty-group case below still continues.
                guard count < maxInPlayerSources else { break }
                // Score each stream ONCE; the old sort recomputed the (string-heavy)
                // score inside the comparator, which is what melted the main thread
                // on thousand-source titles.
                let best = group.streams.filter { playableURL(for: $0) != nil }
                    .map { (stream: $0, rank: StreamRanking.score($0)) }
                    .sorted { $0.rank > $1.rank }
                    .prefix(perAddon)
                    .map(\.stream)
                guard !best.isEmpty else { continue }
                let groupIdentity = VXProbeRedaction.identityToken(group.id)
                rows.append(OptionRow(
                    accessibilityID: "sources.group.\(groupIdentity)",
                    label: group.addon,
                    isHeader: true
                ))
                for stream in best {
                    guard count < maxInPlayerSources else { break }
                    count += 1
                    let info = StreamRanking.sourceDetail(stream)
                    let name = String(sourceLabel(stream).prefix(40))
                    rows.append(OptionRow(
                        accessibilityID: "sources.stream.\(groupIdentity).\(VXProbeRedaction.identityToken(stream.id))",
                        label: "\(info.tags)   \(name)",
                        detail: info.size ?? "",
                        isSelected: playableURL(for: stream) == curURL
                    ) {
                        resolveAndSwitchStream(to: stream, addon: group.addon)
                    })
                }
            }
        }
        return rows
    }

    /// The in-player source panel's session audio-language filter (iOS parity, #204): an "Audio" header with
    /// "Auto" + the curated language list. Selecting a language sets `sessionAudioLanguages`, which re-ranks
    /// the rows built above so releases carrying that audio float up.
    private func audioLanguageFilterRows() -> [OptionRow] {
        var rs: [OptionRow] = [OptionRow(
            accessibilityID: "source-audio.heading",
            label: String(localized: "Audio"),
            isHeader: true
        )]
        rs.append(OptionRow(
            accessibilityID: "source-audio.auto",
            label: String(localized: "Auto"),
            isSelected: sessionAudioLanguages == nil
        ) {
            sessionAudioLanguages = nil
            openPanel(.sources, preferredAccessibilityID: "sources.audio")
        })
        for lang in TrackPreferences.commonLanguages {
            rs.append(OptionRow(
                accessibilityID: "source-audio.language.\(lang.id)",
                label: lang.label,
                isSelected: sessionAudioLanguages == [lang.id]
            ) {
                sessionAudioLanguages = [lang.id]
                openPanel(.sources, preferredAccessibilityID: "sources.audio")
            })
        }
        return rs
    }

    /// The gear panel: player-wide settings that aren't tied to one media kind. Handoff to an
    /// installed external player (direct/debrid URLs only; a torrent's local-server URL dies when
    /// this app suspends), the decoder choice, and the info/QR rows that used to crowd Playback.
    private func playerSettingsRows() -> [OptionRow] {
        var rows: [OptionRow] = []
        // Handoff only when the URL is self-contained. A header-gated stream needs specific request
        // headers (it is either playing through our embedded /proxy/ on a loopback URL, or as a
        // bare CDN URL whose headers live on mpv); an external player gets neither and cannot
        // replay it, so it would just fail. Hide handoff in that case.
        let handoffEligible = !isTorrentPlayback && (curHeaders?.isEmpty ?? true)
        if handoffEligible, let url = curURL {
            let players = ExternalPlayers.menu()
            if !players.isEmpty {
                rows.append(OptionRow(label: "Play in", isHeader: true))
                for player in players {
                    rows.append(OptionRow(label: player.name, detail: "›") {
                        saveProgress(at: currentTime)
                        coordinator.player?.pause()
                        ExternalPlayers.open(url, in: player, metadata: curMeta)
                        withAnimation { showOptions = false }
                    })
                }
            }
        }
        // Decoder toggle is libmpv-only: AVPlayer always decodes in hardware and setHardwareDecoding is a
        // no-op there, so hide the Hardware/Software rows when the AVFoundation engine is active (#76).
        if !isAVPlayerActive {
            rows.append(OptionRow(label: "Decoder", isHeader: true))
            let hw = coordinator.player?.hardwareDecoding ?? true
            let hardwareDetail = (coordinator.player as? MPVMetalViewController)?
                .hardwareDecoderSettingDetail ?? "recommended"
            rows.append(OptionRow(label: "Hardware", detail: hardwareDetail, isSelected: hw) {
                coordinator.player?.setHardwareDecoding(true)
            })
            rows.append(OptionRow(label: "Software  ·  if video misbehaves", isSelected: !hw) {
                coordinator.player?.setHardwareDecoding(false)
            })
        }
        // Player engine picker (P3, #76): reachable only when AVPlayer is a real option for this stream (DV /
        // HLS / debrid; never torrents or a yt-direct sidecar pair). Lets the viewer flip libmpv <-> AVPlayer
        // mid-title for true Dolby Vision (AVPlayer) or wider format / libass subtitle support (libmpv).
        if canUseAVPlayerEngine {
            rows.append(OptionRow(label: "Playback", isHeader: true))
            rows.append(OptionRow(label: "Player engine",
                                  detail: isAVPlayerActive ? "AVPlayer  ·  ›" : "VortX Player  ·  ›") {
                openPanel(.engine)
            })
        }
        // Sleep timer (parity with iOS/Mac): drill-in mirrors the "Player engine" row above. The detail
        // reflects the current arm state so the viewer sees it without opening the sub-panel.
        rows.append(OptionRow(label: "Sleep", isHeader: true))
        let sleepDetail = sleepAtEpisodeEnd ? "End of episode  ·  ›"
            : sleepMinutes.map { "\($0) min  ·  ›" } ?? "Off  ·  ›"
        rows.append(OptionRow(label: "Sleep timer", detail: sleepDetail) { openPanel(.sleep) })
        rows.append(OptionRow(label: "Info", isHeader: true))
        rows.append(OptionRow(label: showStats ? "Hide playback info" : "Show playback info",
                              isSelected: showStats) {
            showStats.toggle()
            withAnimation { showOptions = false }
        })
        if shareLink != nil {
            rows.append(OptionRow(label: isTorrentPlayback ? "Magnet link  ·  QR for your phone"
                                                           : "Stream link  ·  QR for your phone") {
                withAnimation { showOptions = false }
                showStreamQR = true
            })
        }
        return rows
    }

    /// The Player Engine picker rows (P3, #76): flip libmpv <-> AVPlayer mid-title. The AVPlayer row appears
    /// only when it is a valid engine for this stream (guarded by the caller via `canUseAVPlayerEngine`).
    private func engineRows() -> [OptionRow] {
        let onAV = isAVPlayerActive
        var rows: [OptionRow] = []
        rows.append(OptionRow(label: "VortX Player  ·  all formats, styled subtitles", isSelected: !onAV) {
            switchPlayerEngine(toAVPlayer: false)
        })
        if canUseAVPlayerEngine {
            rows.append(OptionRow(label: "AVPlayer  ·  Dolby Vision, HLS", isSelected: onAV) {
                switchPlayerEngine(toAVPlayer: true)
            })
        }
        return rows
    }

    /// The Sleep Timer picker rows (parity with iOS/Mac): Off, a set of timed auto-pauses, and, for a series
    /// with a next episode, "End of episode" (stop at the current item's end instead of auto-advancing).
    /// Option set matches the shipped iOS/Mac picker exactly so the two chromes stay in parity.
    private func sleepRows() -> [OptionRow] {
        var rows: [OptionRow] = [OptionRow(label: "Off", isSelected: sleepMinutes == nil && !sleepAtEpisodeEnd) {
            armSleep(minutes: nil, atEpisodeEnd: false)
        }]
        for m in [15, 30, 45, 60, 90] {
            rows.append(OptionRow(label: "\(m) minutes", isSelected: sleepMinutes == m && !sleepAtEpisodeEnd) {
                armSleep(minutes: m, atEpisodeEnd: false)
            })
        }
        // Only meaningful for a series with a next episode; it stops the auto-advance at the end of this one.
        if hasNextEpisode {
            rows.append(OptionRow(label: "End of episode", isSelected: sleepAtEpisodeEnd) {
                armSleep(minutes: nil, atEpisodeEnd: true)
            })
        }
        return rows
    }

    /// (Re)arm the sleep timer. `minutes` runs a timed auto-pause; `atEpisodeEnd` lets the current episode
    /// finish then stops (no auto-advance, handled in `autoAdvance`). Both nil/false = off. Cancels any prior
    /// timer. Transport input never touches this task, so only "Off"/re-arm (or a dismiss) cancels it. Mirrors
    /// PlayerScreen.armSleep; the timed pause reuses the existing togglePause path.
    private func armSleep(minutes: Int?, atEpisodeEnd: Bool) {
        sleepTask?.cancel(); sleepTask = nil
        sleepAtEpisodeEnd = atEpisodeEnd
        sleepMinutes = minutes
        guard let minutes else { return }
        let seconds = Double(minutes) * 60
        sleepTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if !isPaused { coordinator.player?.togglePause() }   // pause via the existing path
            showEngineNote("Sleep timer: playback paused.")
            sleepMinutes = nil
        }
    }

    /// When the user has chosen a default external player (Settings → Play in), hand the launch stream
    /// straight to it instead of the built-in player, mirroring iOS. Only direct/debrid remote streams
    /// are eligible: torrents and header-gated streams play through our embedded server, whose loopback
    /// URL an external app can't replay. Trailers also stay native so their resolver path retains the
    /// in-app YouTube fallback. If the chosen app isn't actually installed the open() no-ops and the
    /// built-in player just keeps playing, so a missing app never strands the user on a dead screen.
    private func maybeRouteToDefaultExternalPlayer() {
        guard let player = ExternalPlayers.defaultPlayer(),
              !isTrailer,
              !isTorrentPlayback, (curHeaders?.isEmpty ?? true),
              let u = curURL, let host = u.host, host != "127.0.0.1", host != "localhost", host != "::1"
        else { return }
        ExternalPlayers.open(u, in: player, metadata: curMeta)
    }

    /// A concise one-line label for a source: the first line of its name, else its description.
    private func sourceLabel(_ s: CoreStream) -> String {
        func firstLine(_ t: String?) -> String {
            (t ?? "").split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
        let name = firstLine(s.name)
        if !name.isEmpty { return name }
        let desc = firstLine(s.description)
        return desc.isEmpty ? "Source" : desc
    }

    /// Hand a stream to mpv, routing header-gated HTTP streams through the embedded server's
    /// proxy when it can (the official-Stremio path that makes picky CDNs like ok.ru play). The
    /// server applies the headers and rewrites the HLS playlist, so mpv fetches plain loopback
    /// and needs no headers of its own; everything else loads directly with mpv-applied headers.
    /// Values and header names are intentionally never emitted: both can carry credentials or caller data.
    private func safeHeaderReceipt(_ headers: [String: String]?) -> String {
        let values = headers ?? [:]
        // Providers control these keys. Bound classification before allocating a normalised set.
        let names = Set(values.keys.prefix(32).map { $0.prefix(64).lowercased() })
        return "count=\(min(values.count, 32)) hasRange=\(names.contains("range")) hasReferer=\(names.contains("referer")) hasUserAgent=\(names.contains("user-agent"))"
    }

    /// Failure text can originate in a provider, a remote server, AVFoundation, or libmpv. Keep the exportable
    /// source-hop record useful without accidentally emitting an upstream URL, filename, title, or response
    /// body carried inside that text.
    private func safeFailureClass(_ reason: String) -> String {
        let normalized = String(reason.prefix(512)).lowercased()
        if normalized.contains("zero-packet") { return "zero-packet" }
        if normalized.contains("no frame") { return "no-first-frame" }
        if normalized.contains("timeout") { return "timeout" }
        if normalized.contains("cancel") { return "cancelled" }
        if normalized.contains("remux") { return "remux" }
        if normalized.contains("resume") { return "resume" }
        if normalized.contains("stall") { return "stall" }
        return "other"
    }

    @discardableResult
    private func loadIntoPlayer(_ url: URL, headers: [String: String]?, live: Bool,
                                reusing loadToken: PlayerLoadToken? = nil,
                                contentHint: String? = nil,
                                resumeOrigin: Double? = nil,
                                preparedRemux: VortXPreparedRemuxAttachment? = nil,
                                expectedPreparedRemuxOwner: VortXPreparedRemuxOwnerIdentity? = nil) -> PlayerLoadToken? {
        // A load command supersedes any deferred-resume watchdog before it can issue a new token.  Keep
        // this central guard in addition to the named lifecycle exits below: foreground reconcile and
        // prepared episode admission also issue loads without passing through the ordinary retry path.
        clearPostFrameResumeSeekWatchdog()
        // Keep the yt-direct audio sidecar ONLY when reloading the launch URL itself (a trailer retry);
        // any other target (episode/source switch) is a normal content stream and must load sidecar-free.
        let sidecar = (url == self.url) ? audioSidecarURL : nil
        // Tell the libmpv lane whether the stream being loaded is Dolby Vision (same flag the engine router
        // uses) so a DV file that lands on libmpv (a DV torrent, or a DV MKV the remux lane could not run)
        // drives the Apple TV into DV display mode instead of HDR10. Use curHint (the CURRENTLY-playing stream's
        // signature, updated on every switch + binge auto-advance BEFORE this runs), NOT the immutable launch
        // sourceHint, so switching to a non-DV source clears DV mode and switching to a DV source engages it.
        coordinator.player?.contentIsDolbyVision = StreamRanking.isDolbyVision(
            contentHint ?? curHint ?? sourceHint ?? ""
        )
        // Real DV-profile evidence only ever survives from demoteAVPlayerToMPV's Coordinator handoff into a
        // FRESH mpv controller at makeController time, never through this function. Every load THIS
        // function issues targets an already-configured engine instance directly, so any evidence already
        // sitting on it belongs to a DIFFERENT prior source (or, in the demote-reissue race where curURL
        // changed underneath it, the WRONG url) and must not leak forward into this load. Mirrors iOS
        // PlayerScreen.loadIntoPlayer.
        if let mpv = coordinator.player as? MPVMetalViewController {
            mpv.dolbyVisionFallbackInfo = .unknown
        }
        guard let player = coordinator.player else { return nil }
        clearCachedAudioOutputTruth()
        let requestedResumeOrigin = live ? 0 : (
            resumeOrigin ?? avSurfaceResumeOrigin ?? (hasStartedPlaying ? currentTime : (resumeSeconds ?? 0))
        )
        avSurfaceResumeOrigin = requestedResumeOrigin
        player.configureResumeOrigin(seconds: requestedResumeOrigin)
        // Revalidate the exact episode/source owner and the live engine route immediately before the existing
        // AVPlayer load. If the viewer enabled the Mac engine or changed engines since preloading, retire the
        // local candidate and execute the ordinary cold load exactly once.
        if let preparedRemux {
            let mountIsOnDevice: Bool
            if case .onDevice = VortXExternalEngine.shared.mountPlan {
                mountIsOnDevice = true
            } else {
                mountIsOnDevice = false
            }
            let admission = expectedPreparedRemuxOwner.map {
                VortXPreparedRemuxCallerPolicy.admission(
                    actualOwner: preparedRemux.ownerIdentity,
                    expectedOwner: $0,
                    avPlayerActive: player is AVPlayerEngineController,
                    mountIsOnDevice: mountIsOnDevice
                )
            } ?? .abandonAndColdLoad
            if admission == .configure,
               let avPlayer = player as? AVPlayerEngineController,
               let expectedPreparedRemuxOwner {
                _ = avPlayer.configurePreparedRemuxForNextLoad(
                    preparedRemux.handle,
                    ownerIdentity: expectedPreparedRemuxOwner
                )
            } else {
                preparedRemux.abandon(reason: "tvOS admission owner or engine mismatch")
            }
        }
        let candidateToken: PlayerLoadToken
        // AVFoundation and the remux server consume the raw URL + headers. Only libmpv needs the embedded
        // proxy's server-side header injection and playlist rewriting.
        let route: String
        if player is AVPlayerEngineController {
            route = "avplayer"
            candidateToken = player.loadFile(
                url, headers: headers, live: live, audioSidecar: sidecar,
                reusing: loadToken
            )
        } else if let h = headers, !h.isEmpty, let proxied = StremioServer.proxiedURL(for: url, headers: h) {
            route = "libmpv-proxy"
            candidateToken = player.loadFile(
                proxied, headers: nil, live: live, audioSidecar: sidecar,
                reusing: loadToken
            )
        } else {
            route = "libmpv-direct"
            candidateToken = player.loadFile(
                url, headers: headers, live: live, audioSidecar: sidecar,
                reusing: loadToken
            )
        }
        let issuedToken = candidateToken == player.activeLoadToken ? candidateToken : nil
        DiagnosticsLog.log(
            "playback",
            "source attempt route=\(route) headers=\(safeHeaderReceipt(headers)) issued=\(issuedToken != nil) hop=\(sourceHops)"
        )
        if issuedToken != nil {
            // A real new load took: no longer frozen on the previous session's final frame. Retire the bounded
            // terminal (EOF) fallback - the fresh load's own start watchdog / load timeout owns recovery now. A
            // REFUSED load (issuedToken == nil) leaves the old mount in place, so the freeze stays covered.
            eofFrozenAtTerminal = false
            terminalAdvanceDeadlineTask?.cancel()
            terminalAdvanceDeadlineTask = nil
        }
        if let issuedToken {
            beginAssetSanityAttemptIfNeeded(
                loadToken: issuedToken,
                requestedResumeOrigin: requestedResumeOrigin
            )
            bindIncomingTransportIntent(to: issuedToken)
        }
        if pendingAdvance != nil {
            pendingAdvance?.loadToken = issuedToken
            pendingAdvance?.issued = issuedToken != nil
            if issuedToken != nil {
                pendingAdvance?.terminal = false
                pendingAdvance?.deferredDuration = nil
                pendingAdvance?.deferredTrackList = false
                supersededAdvance = nil
                admitEpisodeResolutionIfCurrent()
            }
        } else if let issuedToken {
            committedLoadToken = issuedToken
        }
        return issuedToken
    }

    /// Switch the playing source in place: reload the picked stream's URL and resume at the current
    /// position (via `resumeSeconds`), so a buffering or low-quality source can be swapped without
    /// leaving the player. Resets the auto-recovery budget for the fresh source.
    /// `addon` is the NAME of the add-on the viewer picked from, carried through so a MANUAL pick can be
    /// remembered for the rest of the series (`SeriesSourceSticky`). The panels have it in hand already, so
    /// threading it beats re-deriving it after the async resolve, where the groups may have moved on.
    private func resolveAndSwitchStream(to stream: CoreStream, userInitiated: Bool = true,
                                        addon: String? = nil) {
        sourceSwitchGeneration &+= 1
        let generation = sourceSwitchGeneration
        guard let target = sourceTargetMeta, !leftPlayback else { return }
        let replacementOwner: EpisodeResolutionOwner?
        if let pending = pendingAdvance, !pending.issued {
            let owner = EpisodeResolutionOwner(
                episodeGeneration: pending.generation,
                sourceGeneration: generation,
                videoID: pending.meta.videoId
            )
            armEpisodeResolutionDeadline(owner: owner)
            replacementOwner = owner
        } else {
            replacementOwner = nil
        }
        let resolutionTask = Task { @MainActor in
            let ref = await resolvedEpisodeRef(for: stream, meta: target)
            guard !Task.isCancelled, !leftPlayback,
                  generation == sourceSwitchGeneration,
                  sourceTargetMeta?.videoId == target.videoId else { return }
            guard let newURL = EpisodePlaybackIdentity.resolvedEpisodeMediaURL(
                isUsenet: stream.isUsenet, resolvedURL: ref?.url,
                fallbackURL: playableURL(for: stream)
            ) else {
                if let replacementOwner {
                    failEpisodeResolutionIfCurrent(
                        owner: replacementOwner,
                        message: "That source did not resolve a playable episode file."
                    )
                }
                return
            }
            switchStream(
                to: stream, url: newURL, debridRef: ref,
                targetMeta: target, userInitiated: userInitiated,
                sourceGenerationAlreadyClaimed: true, addon: addon
            )
        }
        if replacementOwner != nil {
            episodeResolutionTask = resolutionTask
        }
    }

    private func resetRuntimeForIssuedSourceSwitch(
        userInitiated: Bool,
        preservingSubtitleChoice: SubtitleChoice? = nil,
        preservingAudioChoice: PlayerRecoveryAudioChoice? = nil
    ) {
        clearCachedAudioOutputTruth()
        avToMPVHandoffTask?.cancel()
        avToMPVHandoff = nil
        avToMPVHandoffBlocked = false
        currentPickWasExplicit = userInitiated
        currentPlaybackIsResume = false
        directAVNoFrameRecovery = nil
        libmpvStartupNudgeIssued = false
        bufferGraceUsed = 0; lastBufferedAtWatchdog = -1
        resetRapidBufferingRecovery(reason: "issued source switch")
        sourceHops = 0; exhaustedURLs = []
        nativeDebridFreshLinkRecovery.reset()
        if userInitiated {
            avEngineFailed = false
            recoveryDeadline?.cancel(); recoveryDeadline = nil
            // The viewer picked this mount themselves: a fresh source gets a fresh mid-play budget. The
            // automatic lane deliberately does NOT reset here - `hopToNextSource` clears it only once its
            // switch is actually issued, so a hop that is refused keeps counting toward the overlay.
            midPlayRecoveryCount = 0
        }
        torrentWarmupsUsed = 0; torrentStatus = nil; stallRecoveries = 0
        appliedResume = false
        // The incoming load owns its own resume provenance; switchStream re-states it (carriedPlayHead) right
        // after this reset, so a stale marker can never survive into a load that resumes from a stored offset.
        resumeIsMidPlayRecovery = false
        bufferedTime = 0
        buffering = true; hasStartedPlaying = false; appliedAutoTracks = false
        isHDR = false
        autoAddonSubTried = false; userPickedSubtitle = preservingSubtitleChoice != nil
        addonSubsResolveTried = false; appliedVolume = false; appliedSize = false; loadErrorMsg = ""
        pendingSubtitleReapply = preservingSubtitleChoice
        pendingAudioReapply = preservingAudioChoice
        suppressedResumeFloor = nil
        inFlightSeekTarget = nil; pendingLibmpvResumeSeek = nil
        clearPostFrameResumeSeekWatchdog()
        watchedZoneSince = nil
        autoRetryCount = 0; reconnecting = false; autoRetryTask?.cancel()
        subFingerprint = nil; subFingerprintKey = ""; pooledSubs = []
        subtitlePoolRequests.invalidate(); subtitleLoadingURL = nil
        addedPooledIDs = []; embeddedUploadDone = false
        langContributeDone = false
    }

    @discardableResult
    private func switchStream(to stream: CoreStream, url newURL: URL,
                              debridRef: DebridPlaybackRef? = nil,
                              targetMeta: PlaybackMeta? = nil,
                              userInitiated: Bool = true,
                              resumeOverride: Double? = nil,
                              sourceGenerationAlreadyClaimed: Bool = false,
                              addon: String? = nil,
                              preservingSubtitleChoice: SubtitleChoice? = nil,
                              preservingAudioChoice: PlayerRecoveryAudioChoice? = nil) -> Bool {
        guard newURL != curURL else {
            if let pending = pendingAdvance, !pending.issued,
               pending.meta.videoId != curMeta?.videoId {
                invalidateEpisodeResolution()
                pendingAdvance = nil
                if restoreSupersededAdvance() { return false }
                switchingEpisode = false; reconnecting = false
                loadErrorMsg = "That episode resolved to the current episode's file."
                presentTerminalLoadFailure()
                return false
            }
            if userInitiated { closePanel() }
            return false
        }
        // Continuity, binge-group and account ranking were snapshotted from the source being replaced.
        // Cancel that preparation so the next player tick ranks against the source that actually won.
        invalidateNextEpisodePreparation(reason: "source switch")
        if !sourceGenerationAlreadyClaimed {
            sourceSwitchGeneration &+= 1
        }
        resumeRetryGeneration &+= 1
        // closePanel forces the control bar up and teleports the highlight; right for a manual
        // pick, hostile when an automatic hop fires while the viewer is browsing a panel.
        if userInitiated { closePanel() }
        // Cleanly destroy the torrent engine we're leaving BEFORE starting the next source, so
        // engines never pile up on the embedded server (the regression that bloated its RSS and
        // took it offline). A hop into another torrent is fine now that the old one is closed.
        let oldHash = currentTorrentHash
        // `currentTime` is deliberately optimistic while a Continue Watching seek is unresolved.  A fresh
        // source must start from decoder-confirmed media, not repeat a speculative 15-minute cold-range
        // request.  Preserve that requested offset only as the persistence floor until real playback catches up.
        let unresolvedResumeTarget = inFlightSeekTarget
        let confirmedCarry = lastRawTimePos.isFinite && lastRawTimePos >= 0 ? lastRawTimePos : nil
        let carryFloor = unresolvedResumeTarget.map { max(suppressedResumeFloor ?? 0, $0) }
        let resume = unresolvedResumeTarget != nil
            ? (confirmedCarry ?? 0)
            : (resumeOverride ?? (hasStartedPlaying ? currentTime : (resumeSeconds ?? 0)))
        // Is `resume` a LIVE PLAY HEAD rather than a stored library offset? Captured HERE, before the reset
        // below clears both inputs. True for a mid-title switch (currentTime) and for the hop a mid-play
        // failure spawns (which cleared `hasStartedPlaying` before calling, so only the marker still says so).
        // Carried into `resumeIsMidPlayRecovery` after the reset so maybeResume keeps a near-the-credits
        // position instead of restarting the title.
        let carriedPlayHead = hasStartedPlaying || resumeIsMidPlayRecovery
        // A source switch DURING a pending advance (the auto-hop lane when the incoming episode's first
        // source is dead) swaps WHICH FILE will first-frame, not which episode: keep the pending record
        // pointed at the live URL (and issued - this loads synchronously below) so the first-frame commit
        // and a foreground reconcile both act on the file actually in the player.
        let priorPending = pendingAdvance
        if pendingAdvance != nil {
            pendingAdvance?.url = newURL
            pendingAdvance?.debridRef = debridRef
            pendingAdvance?.issued = false
            pendingAdvance?.loadToken = nil
        }
        let nextIsTorrent = debridRef == nil && stream.isTorrent
        let target = targetMeta ?? sourceTargetMeta
        let nextIsLive = isLiveMeta(target) && !nextIsTorrent
        // Keep curHint (the "what is playing now" signature) in step with the switched-to source, so BOTH source
        // continuity ranking (which already updates curBinge here) and the libmpv DV display-mode flag (set from
        // curHint in loadIntoPlayer) track the CURRENT source, not the launch source. A different rip can differ
        // in Dolby Vision and quality, so a manual switch to a non-DV source must clear DV mode and vice versa.
        let nextHint = StreamRanking.signature(stream)
        let nextHeaders = stream.requestHeaders
        let issuedToken = loadIntoPlayer(
            newURL, headers: nextHeaders, live: nextIsLive, contentHint: nextHint,
            resumeOrigin: resume
        )
        if pendingAdvance != nil {
            guard let issuedToken else {
                if let priorPending, priorPending.issued, !priorPending.terminal,
                   priorPending.loadToken == coordinator.player?.activeLoadToken {
                    pendingAdvance = priorPending
                    switchingEpisode = true; reconnecting = true
                    return false
                }
                invalidateEpisodeResolution()
                pendingAdvance = nil
                if restoreSupersededAdvance() { return false }
                switchingEpisode = false
                loadErrorMsg = "The player could not issue this episode."
                presentTerminalLoadFailure()
                return false
            }
            pendingAdvance?.loadToken = issuedToken
            pendingAdvance?.issued = true
        } else if issuedToken == nil {
            return false
        }
        if debridRef == nil { prepareTorrent(stream) }
        resetRuntimeForIssuedSourceSwitch(
            userInitiated: userInitiated,
            preservingSubtitleChoice: preservingSubtitleChoice,
            preservingAudioChoice: preservingAudioChoice
        )
        if let carryFloor {
            suppressedResumeFloor = carryFloor
            lastSaved = max(lastSaved, carryFloor)
        }
        curURL = newURL
        curDebridRef = debridRef
        curSourceStream = stream
        curIsTorrent = nextIsTorrent
        curIsLive = nextIsLive
        curBinge = stream.behaviorHints?.bingeGroup
        let acceptedSubtitleTimingScope = subtitleTimingScope(
            for: pendingAdvance?.meta ?? target ?? curMeta,
            stream: stream
        )
        if pendingAdvance != nil {
            pendingAdvance?.subtitleTimingScope = acceptedSubtitleTimingScope
            coordinator.player?.setSubDelay(0)
        } else {
            acceptSubtitleTimingReplacement(scope: acceptedSubtitleTimingScope)
        }
        // REMEMBER A MANUAL PICK (diag-21). `curBinge` above is in-session only and, being add-on-authored text
        // worth +2500, loses to the cached (+8000) and source-type (15000) terms on the very next rank - so the
        // viewer re-picked the same provider every single episode. Record the choice durably here, the one place
        // a picked stream and its add-on are both in hand. Only MANUAL picks: on tvOS `userInitiated` is exactly
        // that (the two callers are the sources and quality panels; `hopToNextSource` passes false and auto-next
        // never reaches switchStream), and recording an auto-hop would teach the store the failure, not the taste.
        if userInitiated, let key = seriesStickyKey {
            SeriesSourceSticky.record(seriesKey: key, addon: addon, bingeGroup: curBinge)
        }
        curHint = nextHint
        curHeaders = nextHeaders
        if let oldHash, oldHash != stream.infoHash?.lowercased() { closeTorrent(hash: oldHash) }
        invalidateLocalTrickplayCapture()
        if pendingAdvance == nil {
            scrubThumbnails.configure(localCacheKey: trickplayLocalCacheKey)
            lastLocalTrickplayCapture = -1000
            configureCommunityTrickplayProvisional()
        }
        resumeSeconds = resume
        resumeIsMidPlayRecovery = carriedPlayHead
        if let target {
            enginePlayerVideoId = bindEngine(
                to: stream, meta: target, resolvedURL: debridRef?.url
            )
        }
        startLoadTimeout()
        // Re-arm the next-episode preload against the source that JUST won. The invalidation at the top of
        // switchStream cancelled the preparation snapshotted from the OUTGOING source; kicking preload here -
        // AFTER the sticky record + curHint/curBinge are updated above, so it warms the NEW preference, not
        // the old one - stops a late source re-pick (or an automatic failover hop) from leaving the seamless
        // lane cold until the next halfway tick. Fail-open: preloadNextIfNeeded no-ops unless we are already
        // past the preload commit gate, so an early re-pick simply warms on the normal halfway tick instead.
        preloadNextIfNeeded()
        return true
    }

    /// The best playable stream not yet tried (and failed) for this video. Goes through
    /// StreamRanking.best so the pick honours the user's source-type order, the add-on-order
    /// toggle, and the continuity / binge hints, exactly like the original auto-pick did.
    private func nextUntriedStream() -> CoreStream? {
        let remaining = currentSourceGroups.map { group in
            CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: group.streams.filter { s in
                guard let url = playableURL(for: s) else { return false }
                return url != curURL && !exhaustedURLs.contains(url)
            })
        }
        // QUALITY-DROP CAP (auto path): never plunge more than one resolution tier below the best CACHED
        // option that exists (the "picked/expected 4K, silently got 480p" report). Prefer candidates within
        // one tier of the best cached resolution; fall back to the unfiltered ranking only when the cap
        // leaves nothing untried, so a title whose only remaining sources are low-res still plays.
        let cachedRes = StreamRanking.bestCachedResolution(remaining, debridCachedHashes: debridCachedHashes)
        if cachedRes > 0 {
            let floorStep = StreamRanking.resolutionTierStep(cachedRes) - 1
            let capped = remaining.map { group in
                CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: group.streams.filter { s in
                    StreamRanking.resolutionTierStep(StreamRanking.resolutionRank(s)) >= floorStep
                })
            }
            if let hit = StreamRanking.best(capped, continuity: curHint, binge: curBinge, pin: sourcePin,
                                            sticky: seriesSticky,
                                            providerPenalty: { ProviderHealth.penaltyActive(addonName: $0) },
                                            debridCachedHashes: debridCachedHashes) {
                return hit
            }
        }
        return StreamRanking.best(remaining, continuity: curHint, binge: curBinge, pin: sourcePin,
                                  sticky: seriesSticky,
                                  providerPenalty: { ProviderHealth.penaltyActive(addonName: $0) },
                                  debridCachedHashes: debridCachedHashes)
    }

    /// The playing source is dead (its retry, stall, or warm-up budget ran out): mark it
    /// exhausted and hop to the next-best untried source automatically. Returns false when the
    /// hop budget is spent or nothing untried remains; the caller then shows the error overlay.
    @discardableResult
    private func hopToNextSource(
        reason: String,
        resumeOverride: Double? = nil,
        allowBeyondFailureBudget: Bool = false
    ) -> Bool {
        // FIX I: a TRAILER never fails over to the engine's content streams. The trailer request carries no
        // content stream of its own; nextUntriedStream() would return whatever the engine last loaded for
        // this (or a still-resident) title, so a dead /yt route would silently play the actual/random movie.
        // Instead show the load-error overlay ("Trailer unavailable") and stop. Return true so the caller
        // treats the failure as handled and does not also paint its own (content-stream) error message.
        if isTrailer {
            // #95: before dead-ending, hand the trailer to the YouTube app (the SAME id the in-app path
            // played, so the user's trailer-language preference carries over). Attempted at most once per
            // playback (a stall watchdog can re-fire this guard); only when the open fails (no YouTube app
            // installed) or no YouTube id exists does the "Trailer unavailable" note show. On a successful
            // hand-off the dead player is torn down through leavePlayback() (stop() before dismiss, the
            // straddle rule), so returning from the YouTube app lands on the detail page, not a dead player.
            if let yt = trailerYouTubeID, !triedYouTubeAppRescue {
                triedYouTubeAppRescue = true
                YouTubeAppOpener.openTrailer(youTubeID: yt) { opened in
                    if opened {
                        DiagnosticsLog.log("player", "trailer served by the YouTube app (in-app load failed: \(reason)) id=\(yt)")
                        leavePlayback()
                    } else {
                        DiagnosticsLog.log("player", "trailer load failed (\(reason)); YouTube app unavailable, showing the note")
                        loadErrorMsg = "Trailer unavailable."
                        presentTerminalLoadFailure()
                    }
                }
                return true
            }
            DiagnosticsLog.log("player", "trailer load failed (\(reason)); not hopping to content streams")
            loadErrorMsg = "Trailer unavailable."
            presentTerminalLoadFailure()
            return true
        }
        // The playing source is being abandoned for FAILURE, whatever the caller's reason: this is the one
        // choke point every failure lane funnels through (start timeout, load failure, stall exhaustion,
        // torrent warm-up exhaustion, a gone resume source). Remember the PROVIDER, not just the URL:
        // `exhaustedURLs` is keyed by exact URL and is wiped on every source switch and every episode advance,
        // so a provider that true-stalled on episode N was fully re-eligible on N+1 - and, answering fastest,
        // was re-picked (diag-21). Recorded HERE rather than at the failure sites so a source that recovers in
        // place is never demoted; the penalty decays on its own and is a demotion, never an exclusion.
        // DELIBERATELY BEFORE the hop-budget guard below: the penalty is a verdict on the SOURCE, not on
        // whether we still have a hop left to spend. A source that just died with the budget exhausted is
        // exactly as guilty as one that died with hops to spare, and the penalty is a decaying demotion (never
        // an exclusion), so booking it on the way to the error overlay is the point, not a leak.
        if let dying = currentStream, let dyingAddon = addonName(for: dying) {
            ProviderHealth.noteFailure(addonName: dyingAddon)
        }
        guard (allowBeyondFailureBudget || sourceHops < maxSourceHops),
              let stream = nextUntriedStream(),
              let newURL = playableURL(for: stream) else { return false }
        // switchStream clears the budget (it doubles as the manual-pick path) and resumes at
        // currentTime; snapshot both around the call so the hop keeps its own bookkeeping and a
        // pre-start failure keeps the original resume offset.
        var tried = exhaustedURLs
        if let dead = curURL { tried.insert(dead) }
        let hops = sourceHops + 1
        let resume: Double? = resumeOverride
            ?? (hasStartedPlaying ? currentTime : resumeSeconds)
        // A hop is an automatic replacement of the same title, not a new viewer choice. Preserve the explicit
        // subtitle intent before switchStream resets per-load state; autoSelectTracks re-applies it on the new
        // mount instead of silently returning to language preferences.
        let subtitleChoice = userPickedSubtitle ? captureSubtitleChoice() : nil
        let audioChoice = captureSelectedAudioChoice()
        DiagnosticsLog.log(
            "player",
            "source hop \(hops)/\(maxSourceHops) reason=\(safeFailureClass(reason)) next=candidate"
        )
        guard switchStream(
            to: stream, url: newURL, targetMeta: sourceTargetMeta,
            userInitiated: false, resumeOverride: resume,
            preservingSubtitleChoice: subtitleChoice,
            preservingAudioChoice: audioChoice
        ) else {
            DiagnosticsLog.log(
                "player",
                "source hop not issued reason=\(safeFailureClass(reason)); keeping failure bookkeeping unchanged"
            )
            return false
        }
        exhaustedURLs = tried
        sourceHops = hops
        resumeSeconds = resume
        midPlayRecoveryCount = 0   // a DIFFERENT source is a different mount: it earns its own mid-play budget
        return true
    }

    /// The RemoteConfig kill switch for the terminal-failure "Re-find sources" action (backend-first mandate).
    /// Baked ON, so a device that cannot reach RemoteConfig behaves exactly as today.
    private var refindEnabled: Bool {
        RemoteConfig.snapshot.isFeatureOn("refindSources", default: RemoteConfigDefaults.featureRefindSources)
    }

    /// Terminal-failure "Re-find sources": every known source has been tried and none worked, so re-query the
    /// add-ons FRESH for this exact title/episode (engine Unload -> Load, not an eq_update no-op) and, once
    /// fresh sources settle, retry playback on the best untried one. This is offered ONLY from the terminal
    /// load-error overlay (playback already stopped), never mid-play, so the warmed next-episode lane is never
    /// disturbed. Resets the tried-source budget so the re-queried set gets a clean set of attempts.
    private func refindSourcesAndRetry() {
        guard refindEnabled, !isTrailer, let m = curMeta else { retryLoad(); return }
        refindTask?.cancel()
        sourceHops = 0
        exhaustedURLs = []
        loadErrorMsg = ""
        refinding = true
        withAnimation { loadFailed = false }
        DiagnosticsLog.log("player", "re-find sources requested (\(m.type):\(VXProbeRedaction.identityToken(m.videoId)))")
        core.refindSources(type: m.type, id: m.libraryId, streamType: m.type, streamId: m.videoId)
        let videoId = m.videoId
        refindTask = Task { @MainActor in
            let startedAt = Date()
            while !Task.isCancelled {
                // Bail if a navigation/teardown changed the target or the re-find was cancelled out from under us.
                guard refinding, curMeta?.videoId == videoId else { refinding = false; return }
                let elapsed = Date().timeIntervalSince(startedAt)
                let groups = currentSourceGroups
                let progress = (isEpisodePlaybackContext ? sourceTargetMeta?.videoId : nil)
                    .map { core.streamLoadProgress(forStreamId: $0) } ?? core.streamLoadProgress()
                let settled = StreamRanking.resolveSettled(
                    groups, loaded: progress.loaded, total: progress.total,
                    secondsSinceRequestStart: elapsed, rememberedQuality: curHint
                )
                if settled, nextUntriedStream() != nil {
                    refinding = false
                    // Reuse the proven failover choke point: it books the dead provider, excludes the dead URL,
                    // picks the best fresh untried source, and switches. Beyond the ordinary hop budget because
                    // this is a deliberate user retry, not an automatic cascade.
                    if !hopToNextSource(reason: "re-find fresh sources", allowBeyondFailureBudget: true) {
                        presentTerminalLoadFailure()
                    }
                    return
                }
                if elapsed >= StreamRanking.completeSetDeadline {
                    refinding = false
                    // Nothing fresh turned up within the settle deadline: fall back to the terminal overlay.
                    presentTerminalLoadFailure()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { refinding = false; return }
            }
        }
    }

    /// Nudge subtitle sync by `delta` seconds (rounded to 0.1); keeps the panel open to repeat.
    private func adjustSubDelay(_ delta: Double) {
        guard coordinator.player?.subtitleDelayAvailable == true else { return }
        subDelay = ((subDelay + delta) * 10).rounded() / 10
        pooledSeededOffset = true
        applyCurrentSubtitleDelayIfReady(force: true)
        VXProbe.event("subs", "subs sync \(subDelay)s")
        captureSubOffset()   // P3: pool the user-corrected offset (debounced, gated, fail-soft)
        scheduleSubOffsetSave()   // remember this title's manual offset (debounced: one write per burst)
    }

    /// Persist the manual subtitle offset ONCE per nudge burst instead of once per press (W2-B FIX 2). Each
    /// press used to run `SubtitleOffsetMemory.save` synchronously on the main actor, and a burst on the remote
    /// is easily a dozen presses a second; the save is a UserDefaults write plus the settings-changed fan-out it
    /// triggers, all on the same actor the player's own start-up work runs on. Coalescing to one write ~1s after
    /// the LAST press keeps the identical stored value (the last one wins either way) at a fraction of the cost.
    /// `setSubDelay` stays immediate: the picture must move on every press.
    private func scheduleSubOffsetSave() {
        subOffsetSaveTask?.cancel()
        let pending = subDelay
        let scope = subtitleTimingScope
        pendingSubOffsetSave = (pending, scope)
        subOffsetSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1000))
            // No scope recheck: the scope was captured WITH the value, so this write is correct even if the
            // session has since advanced to another episode. Only cancellation may suppress it.
            guard !Task.isCancelled else { return }
            SubtitleOffsetMemory.save(pending, for: scope)
            pendingSubOffsetSave = nil
        }
    }

    /// Write a debounced offset immediately. Debouncing trades durability for cost, so the exit path flushes
    /// first: a viewer who nudges sync and then presses Back must not lose the offset they just dialled in.
    /// Nothing else needs a flush - the pending write carries its own scope, so an in-session source or episode
    /// switch still lands it against the title it was dialled in on.
    private func flushPendingSubOffsetSave() {
        subOffsetSaveTask?.cancel(); subOffsetSaveTask = nil
        guard let pending = pendingSubOffsetSave else { return }
        pendingSubOffsetSave = nil
        SubtitleOffsetMemory.save(pending.delay, for: pending.scope)
    }
    private func adjustAudioDelay(_ delta: Double) {
        audioDelay = ((audioDelay + delta) * 10).rounded() / 10
        coordinator.player?.setAudioDelay(audioDelay)
    }
    /// Apply the persisted "Default volume" (D5) to the live engine at playback start. The launch mount begins
    /// at the engine's default (100%), so this restores the user's chosen level; re-armed on source switch /
    /// reload (which re-mount the engine). Idempotent per load. tvOS has no in-player volume/mute control, so
    /// this only sets the starting level and never touches mute. SAME `stremiox.playerVolume` key as iOS/Mac.
    private func applyDefaultVolume() {
        guard !appliedVolume else { return }
        appliedVolume = true
        coordinator.player?.setVolume(playerVolume)
    }
    // In-player style tweaks also stick to the active profile (Settings does the same). The profile
    // capture is DEBOUNCED: pressing Bigger five times fast must not encode + persist the whole roster
    // five times on the main thread (the subtitle-settings lag), only once, 0.7s after the last press.
    @State private var stylePrefsSaveTask: Task<Void, Never>?
    private func schedulePlaybackPrefsSave() {
        stylePrefsSaveTask?.cancel()
        stylePrefsSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            ProfileStore.shared.capturePlayback()
        }
    }
    private func setSubtitleFont(_ id: String) {
        subFont = id; coordinator.player?.applySubtitleStyle(); schedulePlaybackPrefsSave()
    }
    private func setSubtitleSize(_ id: String) {
        subSize = id; coordinator.player?.applySubtitleStyle(); schedulePlaybackPrefsSave()
    }
    private func adjustSubScale(_ direction: Int) {
        let next = subSizeScale + Double(direction) * SubtitleStyle.sizeScaleStep
        let clamped = min(max(next, SubtitleStyle.sizeScaleRange.lowerBound), SubtitleStyle.sizeScaleRange.upperBound)
        subSizeScale = (clamped * 100).rounded() / 100
        coordinator.player?.applySubtitleStyle()
        schedulePlaybackPrefsSave()
        if showOptions { refreshPanelRowsPreservingAccessibilityFocus() }   // refresh the % readout in place
    }
    private func setSubtitleColor(_ id: String) {
        subColor = id; coordinator.player?.applySubtitleStyle(); schedulePlaybackPrefsSave()
    }
    private func setSubtitleBrightness(_ id: String) {
        subBrightness = id; coordinator.player?.applySubtitleStyle(); schedulePlaybackPrefsSave()
    }
    private func setSubtitleBackground(_ id: String) {
        subBackground = id; coordinator.player?.applySubtitleStyle(); schedulePlaybackPrefsSave()
    }

    /// True while a subtitle panel is open (the language menu or one language's sub list), so async
    /// subtitle arrivals (add-on fetch, pooled downloads) refresh the open panel instead of only the
    /// flat list that used to be the single subtitles surface.
    private var panelShowsSubtitleList: Bool { panelKind == .subtitles || panelKind == .subtitleLanguage }

    private var panelTitle: String {
        switch panelKind {
        case .audio:            return "Audio"
        case .audioSettings:    return "Audio Settings"
        case .subtitles:        return "Subtitles"
        case .subtitleSettings: return "Subtitle Settings"
        case .subtitleLanguage: return langName(subtitleLanguageCode ?? "und")
        case .aspect:           return "Aspect Ratio"
        case .playback:         return "Playback"
        case .episodes:         return "Episodes"
        case .chapters:         return "Chapters"
        case .sources:          return "Sources"
        case .sourceAudio:      return "Audio"
        case .quality:          return "Quality"
        case .playerSettings:   return "Player Settings"
        case .engine:           return "Player Engine"
        case .sleep:            return "Sleep Timer"
        case .skipEditor:       return "Edit Skip Segment"
        }
    }

    private var optionsPanel: some View {
        let rows = panelRows
        return HStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                Text(panelTitle)
                    .font(Theme.Typography.sectionTitle).foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.horizontal, Theme.Space.xl).padding(.top, Theme.Space.xl).padding(.bottom, Theme.Space.sm)
                ScrollViewReader { proxy in
                    ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            if row.isHeader {
                                Text(row.label.uppercased())
                                    .font(Theme.Typography.eyebrow).tracking(1)
                                    .foregroundStyle(Theme.Palette.textTertiary)
                                    .padding(.horizontal, Theme.Space.lg).padding(.top, Theme.Space.md).padding(.bottom, 2)
                                    .id(i)
                            } else {
                                HStack {
                                    Text(row.label).lineLimit(1)
                                        .foregroundStyle(i == optionRow ? Theme.Palette.canvas : Theme.Palette.textPrimary)
                                    Spacer()
                                    if row.isSelected {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(i == optionRow ? Theme.Palette.canvas : Theme.Palette.accent)
                                    } else if !row.detail.isEmpty {
                                        Text(row.detail)
                                            .foregroundStyle(i == optionRow ? Theme.Palette.canvas.opacity(0.85) : Theme.Palette.textSecondary)
                                    }
                                }
                                .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm)
                                .background(i == optionRow ? Theme.Palette.accent : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                                .opacity(row.isEnabled ? 1 : 0.55)
                                .id(i)
                            }
                        }
                    }
                    .padding(Theme.Space.lg)
                }
                .onChange(of: optionRow) { _ in
                    if accessibilityReduceMotion {
                        proxy.scrollTo(optionRow, anchor: .center)
                    } else {
                        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(optionRow, anchor: .center) }
                    }
                }
                }
            }
            .frame(width: 760)
            .frame(maxHeight: .infinity)
            // High-alpha side panel glass that stays legible over bright moving video. Docked to the
            // trailing edge so its shadow is thrown inward, grounding the right-edge slide-in.
            .vortxGlassPanel(in: Rectangle(), dockedTo: .trailing)
        }
        .ignoresSafeArea()
        .transition(accessibilityReduceMotion ? .identity : .move(edge: .trailing))
        .task(id: showOptions) {
            // Backstop: rebuild the cached rows of WHATEVER panel is open, ~1 Hz, so no async
            // completion can leave a stale row. Sources/episodes keep arriving after the panel opens
            // (add-ons answer at their own pace; direct-resume loads meta in the background), and the
            // other panels read state that lands asynchronously too (a subtitle download callback
            // clearing "Loading…", late add-on subtitles, a track list the engine fills in). Call
            // sites still refresh instantly where they can; this loop is the catch-all for the ones
            // that cannot, so a missed or wrongly-guarded refresh can never strand a row (the tvOS twin
            // of iOS PlayerScreen's refreshSoon, which already rebuilds the open panel on its tick).
            //
            // Preserves the f874120 perf property (no per-frame recompute): the ranking-heavy
            // Sources/Episodes panels still rebuild ONLY when the engine emitted something since the
            // last tick (core.revision), so an idle source list does zero re-ranking; every other panel
            // rebuilds from cheap in-memory track/subtitle state, which does no ranking work.
            var seenRevision = -1
            while showOptions, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard showOptions else { continue }
                if panelKind == .sources || panelKind == .episodes {
                    guard core.revision != seenRevision else { continue }
                    seenRevision = core.revision
                    refreshSourceOptionCounts()   // same gate, same tick: late sources move the button gates too
                }
                refreshPanelRowsPreservingAccessibilityFocus()
            }
        }
    }

    private func stabilizedOptionRows(_ rows: [OptionRow], for kind: PanelKind) -> [OptionRow] {
        let candidates = rows.map {
            TVPlayerAccessibilityRowIdentityPolicy.Candidate(
                explicitID: $0.explicitAccessibilityID,
                label: $0.label,
                isHeader: $0.isHeader
            )
        }
        let identities = TVPlayerAccessibilityRowIdentityPolicy.identities(
            panelKey: kind.rawValue,
            rows: candidates
        )
        return zip(rows, identities).map { row, identity in
            row.replacingAccessibilityID(identity)
        }
    }

    /// Rebuild an asynchronously changing panel without moving assistive focus. The old implementation kept
    /// only `optionRow`, so inserting a subtitle or source above it silently focused a different action. Stable
    /// semantic identity lets the row move while VoiceOver and the custom visual cursor stay on the same action.
    private func refreshPanelRowsPreservingAccessibilityFocus() {
        let previousID = panelRows.indices.contains(optionRow)
            ? panelRows[optionRow].accessibilityID
            : nil
        let refreshed = stabilizedOptionRows(optionRows, for: panelKind)
        let fallback = refreshed.indices.first(where: {
            !refreshed[$0].isHeader && refreshed[$0].isEnabled
        }) ?? 0
        let restored = TVPlayerAccessibilityRowIdentityPolicy.restoredFocusIndex(
            previousID: previousID,
            identities: refreshed.map(\.accessibilityID),
            fallback: fallback
        )
        panelRows = refreshed
        optionRow = restored
    }

    private func moveOption(_ d: Int) {
        let rows = panelRows
        let selectable = rows.indices.filter {
            !rows[$0].isHeader && rows[$0].isEnabled
        }
        guard !selectable.isEmpty else { return }
        let cur = selectable.firstIndex(of: optionRow) ?? 0
        optionRow = selectable[max(0, min(selectable.count - 1, cur + d))]
    }
    private func activateOption() {
        let rows = panelRows
        guard optionRow >= 0,
              optionRow < rows.count,
              !rows[optionRow].isHeader,
              rows[optionRow].isEnabled else { return }
        rows[optionRow].action()
        // Selection state may have changed (speed, tracks, aspect, stats); one
        // recompute per press keeps the checkmarks honest.
        refreshSourceOptionCounts()   // a row can switch source / episode, changing the button gates
        if showOptions { refreshPanelRowsPreservingAccessibilityFocus() }
    }

    /// The skip-editor Start/End field under the cursor, or nil when the highlighted row is not a time
    /// row (or the panel is not the editor). Drives whether Left/Right adjusts a time vs. does nothing.
    private var focusedSkipField: SkipField? {
        guard panelKind == .skipEditor else { return nil }
        let rows = panelRows
        guard optionRow >= 0, optionRow < rows.count else { return nil }
        return rows[optionRow].skipField
    }

    private func openPanel(_ kind: PanelKind, preferredAccessibilityID: String? = nil) {
        panelKind = kind
        refreshTracks()
        refreshSourceOptionCounts()
        scheduleHide()   // loop won't hide while showOptions; this just keeps the deadline fresh
        // Late add-on subtitle recovery: if the start-of-playback fetch raced an empty add-on collection,
        // retry now. Key-latched inside (no-op once a real fetch ran); the async result refreshes the rows.
        if kind == .subtitles { fetchAddonSubtitles() }
        panelRows = stabilizedOptionRows(optionRows, for: kind)
        // Single-choice panels open on the current selection; the mixed settings panel opens
        // at the top (its decoder radio would otherwise swallow the seed and skip "Play in").
        let seedOnSelection = kind != .playerSettings
        optionRow = preferredAccessibilityID.flatMap { identity in
            panelRows.firstIndex { $0.accessibilityID == identity && !$0.isHeader && $0.isEnabled }
        } ?? (seedOnSelection
            ? panelRows.firstIndex { $0.isSelected && $0.isEnabled }
            : nil)
            ?? panelRows.firstIndex { !$0.isHeader && $0.isEnabled } ?? 0
        withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.2)) { showOptions = true }
    }
    private func closePanel() {
        withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.2)) { showOptions = false }
        showInfo = true; selected = .play; scheduleHide()
    }

    private func refreshTracks() {
        audioTracks = coordinator.player?.tracks(ofType: "audio") ?? []
        subtitleTracks = coordinator.player?.tracks(ofType: "sub") ?? []
    }
    private func refreshTracksSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            refreshTracks()
            // panelRows is a SNAPSHOT (the f874120 sources-panel perf fix), so an async completion that
            // changes track state (an add-on subtitle finishing its download, an engine re-read) must
            // rebuild an OPEN panel or its rows go stale: the clicked add-on row otherwise says
            // "Loading…" forever, success or failure (the stuck-on-loading report). Mirrors iOS
            // PlayerScreen.refreshSoon, which has always rebuilt the open panel here. The sources /
            // episodes panels additionally keep their own 1 Hz refresher.
            if showOptions { refreshPanelRowsPreservingAccessibilityFocus() }
        }
    }

    /// Reflect a track choice in the panel IMMEDIATELY, before mpv confirms on the next refreshTracksSoon re-read
    /// (a ~0.25s round trip), so the checkmark moves on tap instead of a beat later. id = the chosen track
    /// (-1 = subtitles off). refreshTracksSoon reconciles from mpv's real track-list right after.
    private func optimisticSelect(type: String, id: Int) {
        func remap(_ tracks: [MPVTrack]) -> [MPVTrack] {
            tracks.map {
                MPVTrack(
                    id: $0.id,
                    type: $0.type,
                    title: $0.title,
                    lang: $0.lang,
                    selected: $0.isSelectable && $0.id == id,
                    forced: $0.forced,
                    unavailableReason: $0.unavailableReason)
            }
        }
        if type == "audio" { audioTracks = remap(audioTracks) } else { subtitleTracks = remap(subtitleTracks) }
        if showOptions { refreshPanelRowsPreservingAccessibilityFocus() }
    }

    /// Auto-pick defaults once per load, while retaining explicit recovery intent across staged track-list events.
    private func autoSelectTracks(applyAutomaticSelections: Bool = true) {
        let pick = TrackSelector.select(audio: audioTracks, subtitles: subtitleTracks, preferences: TrackPreferences.current)
        let remuxOwnsInitialAudio =
            (coordinator.player as? AVPlayerEngineController)?.isRemuxMounted == true
        let automaticAudio = TrackSelector.automaticAudioSelection(
            pick.audio,
            remuxOwnsInitialSelection: remuxOwnsInitialAudio)
        if let pendingAudioReapply {
            switch TVTrackRecoveryPolicy.audioAction(
                choice: pendingAudioReapply,
                tracks: audioTracks,
                automaticID: automaticAudio
            ) {
            case .retain:
                break
            case let .reapply(id):
                coordinator.player?.setAudioTrack(id)
                DiagnosticsLog.log("audio", "re-applied recovery audio choice")
                self.pendingAudioReapply = nil
            case let .automatic(id):
                coordinator.player?.setAudioTrack(id)
                DiagnosticsLog.log("audio", "recovery audio unavailable; applied automatic fallback")
                self.pendingAudioReapply = nil
            }
        } else if applyAutomaticSelections, let automaticAudio {
            coordinator.player?.setAudioTrack(automaticAudio)
        }
        // Mandated check 8: an explicit in-session subtitle pick captured before an engine switch must SURVIVE
        // the switch. Re-apply it instead of the preference-derived auto pick, which would otherwise override
        // an explicit Off / language choice on the fresh mount. Only fall back to TrackSelector when there was
        // no explicit pick.
        if userPickedSubtitle {
            if let choice = pendingSubtitleReapply {
                let pooledChoiceAvailable: Bool
                if case let .pooled(id) = choice,
                   let pooled = pooledSubs.first(where: { $0.id == id }) {
                    pooledChoiceAvailable = subtitleLoadingURL == nil
                        && communityContentKey == pooled.contentKey
                        && MoatConsent.contributeAndConsume
                        && VortXSyncManager.shared.isSignedIn
                } else {
                    pooledChoiceAvailable = false
                }
                switch TVTrackRecoveryPolicy.subtitleAction(
                    choice: choice,
                    tracks: subtitleTracks,
                    pooledChoiceAvailable: pooledChoiceAvailable
                ) {
                case .retain:
                    break
                case let .selectEmbedded(id):
                    coordinator.player?.setSubtitleTrack(id)
                    DiagnosticsLog.log("subs", "re-applied explicit embedded pick across engine switch")
                    pendingSubtitleReapply = nil
                case .applyImmediately:
                    reapplySubtitleChoice(choice)
                    pendingSubtitleReapply = nil
                }
            }
            // else: an explicit pick with no snapshot to restore; leave the engine's current selection.
        } else if applyAutomaticSelections, let s = pick.subtitle {
            coordinator.player?.setSubtitleTrack(s)   // -1 = off
            let lang = s < 0 ? "off" : (subtitleTracks.first { $0.id == s }.map { langName($0.lang) } ?? "\(s)")
            VXProbe.event("subs", "subs selected \(lang) (auto)")
        }
        contributeContainerLanguagesIfNeeded()   // pool the file's REAL track langs (provenance "container")
        refreshTracksSoon()
        // The container had no track in the preferred language chain (subs stayed off): try the add-on list.
        // Either completion point can land first (tracks vs the add-on fetch), so both call this; the guards
        // + the one-shot latch inside make the double call safe. No-op when userPickedSubtitle is set.
        autoSelectAddonSubtitleIfNeeded()
        // Restore the viewer's OWN last manual sync offset for this title (device-local, instant, offline).
        // Only when nothing is dialed in this session and the pooled seed hasn't fired; claiming the pooled
        // latch here suppresses the crowd seed so the viewer's own correction wins.
        restoreSubtitleTimingOffsetIfReady()
    }

    /// Snapshot the viewer's CURRENT explicit subtitle selection so a following engine switch can re-apply it
    /// (mandated check 8). Off when no track is selected; otherwise an add-on / pooled external sub (matched
    /// back by language against the added set) or an embedded track (by lang/title).
    private func captureSubtitleChoice() -> SubtitleChoice {
        guard let sel = subtitleTracks.first(where: {
            $0.selected && $0.isSelectable
        }) else { return .off }
        let selLang = sel.lang.lowercased()
        if let ext = addonSubs.first(where: { addedSubURLs.contains($0.url) && $0.lang.lowercased() == selLang }) {
            return .external(url: ext.url, title: ext.addonName, lang: ext.lang)
        }
        if let p = pooledSubs.first(where: { addedPooledIDs.contains($0.id) && $0.lang.lowercased() == selLang }) {
            return .pooled(id: p.id)
        }
        return .embedded(lang: sel.lang, title: sel.title)
    }

    /// Capture only the semantic attributes shared by unrelated mounts. The raw audio id is intentionally never
    /// carried across a recovery because each engine rebuild assigns its own id space.
    private func captureSelectedAudioChoice() -> PlayerRecoveryAudioChoice? {
        guard let selected = audioTracks.first(where: { $0.selected && $0.isSelectable }) else { return nil }
        return PlayerRecoveryAudioChoice(language: selected.lang, title: selected.title)
    }

    /// Same-title automatic replacements recreate both engines' track id spaces.  Preserve semantic choices
    /// before the old controller disappears, then consume them once on the replacement track list.
    private func captureRecoverySelections() {
        pendingAudioReapply = captureSelectedAudioChoice()
        pendingSubtitleReapply = userPickedSubtitle ? captureSubtitleChoice() : nil
    }

    private func queueIncomingTransportIntent(paused: Bool) {
        pendingTransportIntent = PendingTransportIntent(
            paused: paused,
            episodeGeneration: episodeSwitchGeneration,
            sourceGeneration: sourceSwitchGeneration,
            loadToken: nil
        )
    }

    private func bindIncomingTransportIntent(to loadToken: PlayerLoadToken) {
        guard var intent = pendingTransportIntent,
              intent.episodeGeneration == episodeSwitchGeneration,
              intent.sourceGeneration == sourceSwitchGeneration else { return }
        intent.loadToken = loadToken
        pendingTransportIntent = intent
    }

    private func applyIncomingTransportIntentIfOwned(by loadToken: PlayerLoadToken) {
        guard let intent = pendingTransportIntent,
              intent.episodeGeneration == episodeSwitchGeneration,
              intent.sourceGeneration == sourceSwitchGeneration,
              intent.loadToken == loadToken,
              coordinator.player?.activeLoadToken == loadToken else { return }
        pendingTransportIntent = nil
        if intent.paused { coordinator.player?.pause() }
        else { coordinator.player?.play() }
        DiagnosticsLog.log("player", "applied replacement transport intent paused=\(intent.paused)")
    }

    /// Re-apply a captured subtitle choice on the NEW engine after a switch. Track id spaces differ per engine,
    /// so an embedded pick matches by lang/title (Off if it can't be found, never a different auto pick), and
    /// an external / pooled pick is re-added by URL / pool id (both engines auto-select the added track).
    private func reapplySubtitleChoice(_ choice: SubtitleChoice) {
        switch choice {
        case .off:
            coordinator.player?.setSubtitleTrack(-1)
        case let .embedded(lang, title):
            let l = lang.lowercased(), t = title.lowercased()
            let match = subtitleTracks.first {
                $0.isSelectable
                    && $0.lang.lowercased() == l
                    && $0.title.lowercased() == t
            } ?? subtitleTracks.first {
                $0.isSelectable && $0.lang.lowercased() == l
            }
            coordinator.player?.setSubtitleTrack(match?.id ?? -1)
        case let .external(urlStr, title, lang):
            guard let player = coordinator.player else { return }
            let subtitleLoadToken = player.activeLoadToken
            let subtitleVideoID = curMeta?.videoId
            player.addExternalSubtitle(url: urlStr, title: title, lang: lang) { ok in
                guard permitsSubtitlePublication(loadToken: subtitleLoadToken, videoID: subtitleVideoID) else { return }
                if ok, player === coordinator.player {
                    addedSubURLs.insert(urlStr)
                    applyCurrentSubtitleDelayIfReady(force: false)
                }
            }
        case let .pooled(id):
            if let sub = pooledSubs.first(where: { $0.id == id }) { selectPooledSubtitle(sub) }
        }
        DiagnosticsLog.log("subs", "re-applied explicit pick across engine switch")
    }

    // MARK: - Load failure

    private var loadErrorOverlay: some View {
        ZStack {
            Theme.Palette.canvas.opacity(0.94).ignoresSafeArea()
            VStack(spacing: Theme.Space.md) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 60)).foregroundStyle(Theme.Palette.danger)
                Text(sourceHops > 0 ? "Tried \(sourceHops + 1) sources, none worked" : "This source didn't load")
                    .font(Theme.Typography.sectionTitle).foregroundStyle(Theme.Palette.textPrimary)
                Text(loadErrorMsg.isEmpty
                     ? "It may still be downloading on your source, offline, or an unsupported link."
                     : "It may be unavailable, offline, or unsupported.  (\(loadErrorMsg))")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 900)
                // When every known source has been tried, Select re-queries the add-ons for fresh links
                // instead of reopening a panel of dead sources; otherwise it opens the source picker.
                Text(sourcesExhausted
                     ? "Select = re-find sources    ·    Play/Pause = retry    ·    Menu = back"
                     : "Select = choose another source    ·    Play/Pause = retry    ·    Menu = back")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary).padding(.top, Theme.Space.xs)
            }
            .padding(Theme.Space.screenEdge)
        }
        .transition(.opacity)
    }

    /// True when the terminal-failure overlay's Select should re-find (every known source tried) rather than
    /// open the source picker. Gated by the RemoteConfig kill switch and never for a trailer (FIX I).
    private var sourcesExhausted: Bool { refindEnabled && !isTrailer && nextUntriedStream() == nil }

    /// Shown while a terminal-failure "Re-find sources" settles fresh sources before retrying playback.
    private var refindingOverlay: some View {
        ZStack {
            Theme.Palette.canvas.opacity(0.94).ignoresSafeArea()
            VStack(spacing: Theme.Space.md) {
                ProgressView().tint(Theme.Palette.accent)
                Text("Finding fresh sources…")
                    .font(Theme.Typography.sectionTitle).foregroundStyle(Theme.Palette.textPrimary)
                Text("Re-querying your add-ons for this title. Menu = back")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(Theme.Space.screenEdge)
        }
        .transition(.opacity)
    }

    /// Clear rapid-buffering edges at every semantic boundary. The optional retained budget is exclusively for
    /// the automatic same-source recovery, so the next proved burst promotes to the existing bounded hop.
    private func resetRapidBufferingRecovery(
        reason: String,
        preservingProgressBudget: Bool = false,
        clearingSuppression: Bool = true
    ) {
        rapidBufferingRecovery.reset(preservingProgressBudget: preservingProgressBudget)
        if clearingSuppression { rapidBufferingSuppressedUntilUptime = 0 }
        DiagnosticsLog.log("player", "rapid-buffer reset reason=\(reason) retain=\(preservingProgressBudget)")
    }

    /// Track changes and seeks can initiate a legitimate demux refill after their immediate callback has already
    /// completed. Suppress an entire detector window, rather than relying on the shorter-lived in-flight seek bit.
    private func suppressRapidBufferingRecovery(reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        rapidBufferingRecovery.reset()
        rapidBufferingSuppressedUntilUptime = max(
            rapidBufferingSuppressedUntilUptime,
            PlayerRapidBufferingRecoveryState.suppressionDeadline(from: now)
        )
        DiagnosticsLog.log("player", "rapid-buffer suppress reason=\(reason) until=\(Int(rapidBufferingSuppressedUntilUptime))")
    }

    /// Admit only on-demand, post-first-frame cache starts. A seek or fresh track list may legitimately refill
    /// the cache and must never be confused with a source that cannot sustain delivery.
    private func recordRapidBufferingStartIfEligible() {
        let now = ProcessInfo.processInfo.systemUptime
        guard hasStartedPlaying,
              firstFrameRenderedAt != nil,
              coordinator.player is MPVMetalViewController,
              !isPaused,
              !loadFailed,
              !isCurrentLiveStream,
              duration > 0,
              inFlightSeekTarget == nil,
              pendingLibmpvResumeSeek == nil,
              !PlayerRapidBufferingRecoveryState.isSuppressed(
                  now: now,
                  until: rapidBufferingSuppressedUntilUptime
              ),
              !switchingEpisode else { return }

        switch rapidBufferingRecovery.recordBufferingStart(at: now) {
        case .none:
            return
        case .reloadSameSource:
            DiagnosticsLog.log("player", "rapid-buffer burst 6/12s -> same-source reload at \(Int(currentTime))s")
            resetRapidBufferingRecovery(
                reason: "rapid same-source recovery",
                preservingProgressBudget: true,
                clearingSuppression: false
            )
            reloadAtPlayhead()
        case .hopSource:
            let resume = max(currentTime, suppressedResumeFloor ?? 0)
            DiagnosticsLog.log("player", "rapid-buffer burst repeated before stable progress -> source hop at \(Int(resume))s")
            resetRapidBufferingRecovery(reason: "rapid source hop")
            if !hopToNextSource(reason: "rapid cache starvation", resumeOverride: resume) {
                loadErrorMsg = "Playback kept running out of buffered data on this source."
                presentTerminalLoadFailure()
            }
        }
    }

    /// Watch for a hard stall after the first frame. Buffering is deliberately observable: AVPlayer can
    /// remain in its waiting state indefinitely (root-cause report section 1), so the visible spinner must
    /// still have a bounded recovery owner instead of the old `!buffering` exemption resetting the counter
    /// forever. Live/paused/failed/pre-first-frame states remain excluded via `PlayerMidPlaybackStallPolicy`,
    /// the SAME shared policy `PlayerScreen` already uses on iOS/macOS (ports it here identically).
    private func startStallWatchdog() {
        stallWatchdog?.cancel()
        avStallWatchdogItemGeneration = (coordinator.player as? AVPlayerEngineController)?
            .currentItemGeneration
        lastObservedTime = -1
        stalledTicks = 0
        stallStableProgressTicks = 0
        stallWatchdog = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(PlayerMidPlaybackStallPolicy.pollIntervalSeconds)
                )
                // A terminal freeze - the play head parked on the FINAL frame at EOF while the next target
                // resolves - reports paused-for-cache=true (mapped to `buffering`), so the normal buffering-
                // aware stand-down just below would wait on it forever (diag-22). It is NOT a mid-stream
                // rebuffer: treat it as recoverable regardless of buffering and drive it into the SAME bounded
                // advance-or-exit as the LAYER-1 deadline (idempotent, so the two can never double-fire).
                let atEOFFrozen = TerminalPlaybackWatchdogPolicy.eofFreezeIsRecoverable(
                    atEOF: eofFrozenAtTerminal, currentTime: currentTime, duration: duration,
                    hasStartedPlaying: hasStartedPlaying, loadFailed: loadFailed
                )

                if atEOFFrozen {
                    if lastObservedTime >= 0, abs(currentTime - lastObservedTime) < 0.25 {
                        stalledTicks += 1
                        if stalledTicks >= PlayerMidPlaybackStallPolicy.ordinaryRecoveryTicks {
                            stalledTicks = 0
                            resolveTerminalAdvanceOrExit(reason: "stall watchdog at EOF")
                        }
                    } else {
                        stalledTicks = 0
                    }
                    lastObservedTime = currentTime
                    continue
                }

                guard PlayerMidPlaybackStallPolicy.shouldObserve(
                    hasStartedPlaying: hasStartedPlaying,
                    isPaused: isPaused,
                    loadFailed: loadFailed,
                    isLive: isCurrentLiveStream,
                    duration: duration,
                    buffering: buffering
                ) else {
                    // Mirrors iOS PlayerScreen.startStallWatchdog: -1 is the sentinel "not observing yet",
                    // not the last real position. Stamping currentTime here would let the FIRST tick after
                    // observation resumes compare against a position from an unobserved gap (paused,
                    // buffering-exempt, pre-first-frame) instead of skipping that tick, which could count a
                    // pause/resume as a stall or as stable progress it never actually measured.
                    lastObservedTime = -1
                    stalledTicks = 0
                    stallStableProgressTicks = 0
                    continue
                }

                if lastObservedTime < 0 {
                    // Just resumed observing: no prior position to compare against, so this tick is neither
                    // a stall nor progress. Mirrors iOS PlayerScreen.
                    stalledTicks = 0
                    stallStableProgressTicks = 0
                } else if abs(currentTime - lastObservedTime) < 0.25 {
                    stallStableProgressTicks = 0
                    stalledTicks += 1
                    if stalledTicks >= PlayerMidPlaybackStallPolicy.recoveryTickThreshold(
                        buffering: buffering
                    ) {
                        let ticksAtRecovery = stalledTicks
                        stalledTicks = 0
                        recoverFromStall(stalledTicksAtRecovery: ticksAtRecovery)
                    }
                } else {
                    stalledTicks = 0
                    stallStableProgressTicks += 1
                    if stallStableProgressTicks >= PlayerMidPlaybackStallPolicy.stableProgressTicksToResetRecoveryBudget {
                        // Rapid starvation owns a separate one-reload budget.  It must renew after the same
                        // stable window even when the ordinary freeze lane never spent a recovery.
                        rapidBufferingRecovery.resetAfterStableProgress()
                        DiagnosticsLog.log("player", "rapid-buffer reset after stable progress")
                    }
                    if PlayerMidPlaybackStallPolicy.shouldResetRecoveryBudget(
                        recoveries: stallRecoveries,
                        stableProgressTicks: stallStableProgressTicks
                    ) {
                        stallRecoveries = 0
                        stallStableProgressTicks = 0
                        stallNudgesIssued = 0
                        midPlayBufferedReloadUsed = false
                    }
                    if stallStableProgressTicks >= PlayerMidPlaybackStallPolicy.stableProgressTicksToResetRecoveryBudget {
                        stallStableProgressTicks = 0
                    }
                }
                lastObservedTime = currentTime
            }
        }
    }

    /// A normal source switch, episode advance, foreground re-issue, or manual switch back to AVPlayer all
    /// create a new exact AVPlayer item while retaining the outer SwiftUI view and its watchdog task. Refresh
    /// the captured generation only when the first frame's load token is still the controller's active token.
    /// That makes the newly rendered item recoverable while a late tick from the retired item stays fenced out.
    private func rearmAVStallWatchdogItemGenerationIfOwned(by loadToken: PlayerLoadToken) {
        guard let avPlayer = coordinator.player as? AVPlayerEngineController else {
            avStallWatchdogItemGeneration = nil
            return
        }
        guard PlayerLoadProvenanceState.accepts(
            callbackToken: loadToken,
            activeToken: avPlayer.activeLoadToken
        ) else { return }
        avStallWatchdogItemGeneration = avPlayer.currentItemGeneration
    }

    private func armAVPostReplacementFirstFrameDeadline(
        loadToken: PlayerLoadToken,
        itemGeneration: UInt64
    ) {
        avPostReplacementFirstFrameDeadline?.cancel()
        let owner = AVPostReplacementFirstFrameDeadlineOwner(
            loadToken: loadToken,
            itemGeneration: itemGeneration
        )
        avPostReplacementFirstFrameDeadlineOwner = owner
        avPostReplacementFirstFrameDeadline = Task { @MainActor in
            try? await Task.sleep(for: .seconds(avPostReplacementFirstFrameDeadlineSeconds))
            guard !Task.isCancelled else { return }
            guard avPostReplacementFirstFrameDeadlineOwner?.loadToken == owner.loadToken,
                  avPostReplacementFirstFrameDeadlineOwner?.itemGeneration == owner.itemGeneration else { return }
            // A user pause suspends this one-shot timer. The matching play callback re-arms a fresh,
            // bounded window only when this exact AVPlayer item is still active.
            if isPaused {
                avPostReplacementFirstFrameDeadline = nil
                return
            }
            guard !hasStartedPlaying,
                  !loadFailed,
                  let avPlayer = coordinator.player as? AVPlayerEngineController,
                  PlayerLoadProvenanceState.accepts(
                    callbackToken: owner.loadToken,
                    activeToken: avPlayer.activeLoadToken
                  ),
                  avPlayer.currentItemGeneration == owner.itemGeneration else { return }
            avPostReplacementFirstFrameDeadline = nil
            avPostReplacementFirstFrameDeadlineOwner = nil
            DiagnosticsLog.log("player", "AVPlayer replacement produced no frame within \(Int(avPostReplacementFirstFrameDeadlineSeconds))s generation=\(owner.itemGeneration)")
            if !hopToNextSource(reason: "AVPlayer replacement produced no frame") {
                loadErrorMsg = "Playback did not recover on this source."
                presentTerminalLoadFailure()
            }
        }
    }

    /// Suspending retains the exact replacement owner but retires its one-shot task. A paused user must
    /// never be moved to another source merely because the fresh AVPlayer item has not rendered yet.
    private func suspendAVPostReplacementFirstFrameDeadlineIfOwned(by loadToken: PlayerLoadToken) {
        guard let owner = avPostReplacementFirstFrameDeadlineOwner,
              owner.loadToken == loadToken,
              let avPlayer = coordinator.player as? AVPlayerEngineController,
              PlayerLoadProvenanceState.accepts(
                callbackToken: loadToken,
                activeToken: avPlayer.activeLoadToken
              ),
              avPlayer.currentItemGeneration == owner.itemGeneration else { return }
        avPostReplacementFirstFrameDeadline?.cancel()
        avPostReplacementFirstFrameDeadline = nil
    }

    /// Resume begins a new bounded first-frame observation only for the suspended AVPlayer replacement that
    /// still owns the active load and item generation. A source or episode transition makes the old owner inert.
    private func resumeAVPostReplacementFirstFrameDeadlineIfOwned(by loadToken: PlayerLoadToken) {
        guard !isPaused,
              !hasStartedPlaying,
              !loadFailed,
              let owner = avPostReplacementFirstFrameDeadlineOwner,
              owner.loadToken == loadToken,
              let avPlayer = coordinator.player as? AVPlayerEngineController,
              PlayerLoadProvenanceState.accepts(
                callbackToken: loadToken,
                activeToken: avPlayer.activeLoadToken
              ),
              avPlayer.currentItemGeneration == owner.itemGeneration else { return }
        armAVPostReplacementFirstFrameDeadline(
            loadToken: owner.loadToken,
            itemGeneration: owner.itemGeneration
        )
    }

    private func cancelAVPostReplacementFirstFrameDeadlineIfOwned(by loadToken: PlayerLoadToken) {
        guard let owner = avPostReplacementFirstFrameDeadlineOwner,
              owner.loadToken == loadToken,
              let avPlayer = coordinator.player as? AVPlayerEngineController,
              avPlayer.currentItemGeneration == owner.itemGeneration else { return }
        avPostReplacementFirstFrameDeadline?.cancel()
        avPostReplacementFirstFrameDeadline = nil
        avPostReplacementFirstFrameDeadlineOwner = nil
    }

    /// Arm the bounded terminal (EOF) fallback. The outgoing episode reached true end-of-file but the EOF
    /// handler cannot advance or exit yet because the requested next target is still resolving. NEVER trust
    /// that resolve to be bounded (diag-22: a dead TorBox left an episode frozen ~15 min on its final frame).
    /// Also raises `eofFrozenAtTerminal`, which un-blinds the stall watchdog (it otherwise stands down while
    /// mpv reports paused-for-cache on the final frame). Retired on any real new load (`loadIntoPlayer`) or
    /// exit (`leavePlayback`); re-arming is safe (it cancels any prior deadline first).
    private func armTerminalAdvanceDeadline(reason: String) {
        eofFrozenAtTerminal = true
        terminalAdvanceDeadlineTask?.cancel()
        DiagnosticsLog.log("player", "EOF terminal deadline armed (\(reason)); bounded \(Int(Self.terminalAdvanceDeadlineSeconds))s advance-or-exit")
        terminalAdvanceDeadlineTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.terminalAdvanceDeadlineSeconds))
            guard !Task.isCancelled else { return }
            resolveTerminalAdvanceOrExit(reason: "bounded EOF deadline")
        }
    }

    /// Fail-safe resolution of a frozen terminal (EOF). A genuine advance issues its next load through
    /// `loadIntoPlayer`, which clears `eofFrozenAtTerminal` and cancels the deadline, so reaching here proves
    /// the requested next target never became playable within the bounded window. Clean-exit exactly like the
    /// last-episode finish path: the outgoing episode is already marked watched + scrobbled (persist-completion
    /// ran before the return that armed this), so Continue Watching rolls forward to the next episode and the
    /// viewer lands back on the detail page. Idempotent - the `eofFrozenAtTerminal` latch plus the
    /// `leftPlayback` guard make a second caller a no-op - so the LAYER-1 deadline and the LAYER-2 stall
    /// watchdog can both drive it without racing.
    private func resolveTerminalAdvanceOrExit(reason: String) {
        guard eofFrozenAtTerminal, !leftPlayback else { return }
        eofFrozenAtTerminal = false
        terminalAdvanceDeadlineTask?.cancel()
        terminalAdvanceDeadlineTask = nil
        if pendingAdvance?.issued == true {
            // Defensive: a next load is already in flight; its own start watchdog / load timeout owns recovery.
            return
        }
        DiagnosticsLog.log("player", "EOF terminal fallback (\(reason)): next source unresolved within \(Int(Self.terminalAdvanceDeadlineSeconds))s -> clean exit")
        saveProgress(at: currentTime)
        leavePlayback()
    }

    /// The URL to (re)mount for the CURRENTLY playing source. Normally that is exactly what is already
    /// loaded - but a loopback mount can go stale WITHOUT the source changing: the in-process engine server
    /// is stopped on background and rebinds a FRESH ephemeral port on every foreground start, while
    /// `CoreStream.playableURL` builds its loopback URL from `StremioServer.base` AT CALL TIME. After one
    /// background cycle the stored `curURL` therefore names a port nothing is listening on, and every reload
    /// path that replayed it verbatim re-failed forever (diag-21). Re-deriving here self-heals that.
    ///
    /// Deliberately narrow, and FAIL-OPEN in every other case (MIS-260731-03 - a control that cannot prove
    /// its precondition must fall through to today's behavior, never to a new dead end):
    ///  - `StremioServer.isCustom` means the viewer pointed the app at their own remote server; its base must
    ///    never be rewritten under a playing stream.
    ///  - Both the current and the re-derived URL must be loopback AND share the same path, so this can only
    ///    ever move the AUTHORITY of one identical route. A header-gated stream keeps its raw URL in `curURL`
    ///    (`loadIntoPlayer` re-derives the `/proxy/` wrapper on every load, so that lane already self-heals),
    ///    and swapping a proxied URL for a raw one here would strip the server-side header injection.
    /// Returns `curURL` untouched (nil included) whenever it cannot prove a better mount, so callers keep
    /// their existing `curURL ?? url` shape and no control flow changes.
    private func liveMountURL() -> URL? {
        guard let current = curURL, !StremioServer.isCustom, isLoopback(current),
              let stream = currentStream,
              let derived = playableURL(for: stream),
              isLoopback(derived), derived != current,
              derived.path == current.path else { return curURL }
        DiagnosticsLog.log("player", "mount re-derived: the embedded server moved port under the playing source")
        return derived
    }

    /// A raw torrent mount is served by the local engine, so a changed loopback port proves the old engine
    /// endpoint disappeared. Reissue its idempotent create before the replacement player opens the new route.
    /// `prepareTorrent` is intentionally asynchronous because server configuration/create cannot be awaited by
    /// the synchronous load call; the existing torrent warm-up and retry owners remain responsible for startup.
    /// Direct add-on URLs and native-debrid links do not own a local engine and are strict no-ops here.
    private func prepareRawTorrentAfterLoopbackRebind(from previous: URL?, to replacement: URL?) {
        guard curDebridRef == nil,
              let stream = curSourceStream,
              stream.url == nil,
              let previous, let replacement,
              isLoopback(previous), isLoopback(replacement),
              previous.port != replacement.port,
              streamingServerTorrentHash(of: previous) == streamingServerTorrentHash(of: replacement),
              streamingServerTorrentHash(of: replacement) != nil else { return }
        DiagnosticsLog.log("torrent", "loopback authority changed under raw torrent; creating engine before replacement load")
        prepareTorrent(stream)
    }

    /// A URL served by this device's own streaming server. Host-based, NOT port-based: the port is exactly
    /// what drifts across a background cycle, so comparing it is what went stale in the first place.
    private func isLoopback(_ u: URL) -> Bool {
        guard let host = u.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// FOREGROUND MOUNT REVALIDATION (diag-21). Backgrounding is deliberately NOT a teardown (see
    /// `onDisappear`), so the same engine stays mounted across a suspension - but what it is mounted ON can
    /// die underneath it: the embedded server restarts on a fresh port, and a debrid link expires. Nothing
    /// revalidated either, so the dead mount surfaced ~18 seconds later through the stall watchdog, which
    /// then replayed the SAME dead URL verbatim and looped ("Reconnecting…  (n/2)") until the viewer re-picked
    /// a source by hand. Heal it here instead, before the mpv seam's `enterForeground` play() hits a dead socket.
    ///
    /// This is a re-mount of the SAME source, never a failover: `sourceHops` and `exhaustedURLs` stay untouched,
    /// so it neither shows the "Source failed, trying another…" banner nor burns the hop budget the viewer needs
    /// for a genuinely dead source. Every branch that cannot prove a better mount returns and leaves exactly
    /// today's behavior in place (MIS-260731-03).
    private func revalidateMountOnForeground(suspendedFor seconds: TimeInterval,
                                             playHeadAtSuspension stamp: Double?) {
        guard hasStartedPlaying, !loadFailed, !leftPlayback, pendingAdvance == nil else { return }
        // DEMONSTRABLY HEALTHY playback is left alone. A suspended player keeps its audio running, so a play
        // head that MOVED across the suspension proves the mount survived it - and re-minting a live debrid
        // link then costs the viewer a reload plus a re-seek of a stream that was fine, and makes the
        // double-recovery race routine (the in-flight re-resolve the identity guard silently drops). Every
        // signal must agree, and with no stamp nothing is proven, so the unprovable case keeps the
        // revalidation below exactly as it is (MIS-260731-03).
        if let stamp, !isPaused, !buffering, !reconnecting,
           currentTime - stamp >= healthyForegroundProgressSeconds {
            DiagnosticsLog.log(
                "player",
                "foreground: playback kept running across the \(Int(seconds))s suspension (+\(Int(currentTime - stamp))s), mount left alone"
            )
            return
        }
        let resume = max(currentTime, suppressedResumeFloor ?? 0)   // R9 floor: never re-mount below where the viewer was
        if let ref = curDebridRef, !ref.infoHash.isEmpty {
            guard seconds >= mountRevalidationSuspensionSeconds else { return }
            // `retryResumeSameSource()` reloads at `resumeSeconds`, which still holds the ORIGIN of this load
            // rather than the play head (it was only ever called before the first frame). Move it first, or a
            // proactive re-mount would restart the episode where it began.
            resumeSeconds = resume
            resumeIsMidPlayRecovery = true   // a live play head carried across the re-mount, not a stored offset
            resumeSourceReresolved = false
            nativeDebridFreshLinkRecovery.reset()   // one proactive fresh link per suspension
            if recoverCurrentNativeDebridLink(reason: "foreground") {
                DiagnosticsLog.log("player", "foreground: re-resolving the debrid mount after \(Int(seconds))s suspended")
            }
            return
        }
        healLoopbackMountOnForeground(allowRecheck: true)
    }

    /// The loopback half of the foreground revalidation, split out so the ONE delayed re-check below can re-run
    /// exactly it and nothing else.
    ///
    /// The re-check is what makes this lane reachable at all: `VortxNativeServer.stopOnBackground()` clears
    /// `publishedPort`, and the restart happens at scenePhase `.active`, which lands AFTER
    /// `willEnterForeground`. At first call `StremioServer.base` therefore still names the dead port, so the
    /// re-derived URL is either nil or identical to the stale one and the heal proves nothing. One re-check
    /// past the restart sees the republished port. Bounded to a single re-arm per foreground - a watcher, not
    /// a poll - and every path still returns to today's behavior when it cannot prove a better mount.
    private func healLoopbackMountOnForeground(allowRecheck: Bool) {
        guard hasStartedPlaying, !loadFailed, !leftPlayback, pendingAdvance == nil else { return }
        guard let healed = liveMountURL(), healed != curURL else {
            guard allowRecheck, !foregroundMountRecheckArmed else { return }
            foregroundMountRecheckArmed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + foregroundMountRecheckDelay) {
                healLoopbackMountOnForeground(allowRecheck: false)
            }
            return
        }
        DiagnosticsLog.log("player", "foreground: embedded server moved port, re-mounting the same source in place")
        let previousURL = curURL
        curURL = healed
        prepareRawTorrentAfterLoopbackRebind(from: previousURL, to: healed)
        let resume = max(currentTime, suppressedResumeFloor ?? 0)   // R9 floor: never re-mount below where the viewer was
        resumeSeconds = resume
        resumeIsMidPlayRecovery = true   // a live play head carried across the re-mount, not a stored offset
        // Preserve explicit in-session audio and subtitle picks across the same-source re-mount, exactly as an
        // engine switch does. Track IDs are mount-local, so audio carries its semantic language/title identity;
        // the subtitle snapshot carries its explicit Off/language/external choice. Without these snapshots the
        // fresh mount silently replaces manual choices with preference-derived automatic selection.
        pendingAudioReapply = captureSelectedAudioChoice()
        pendingSubtitleReapply = userPickedSubtitle ? captureSubtitleChoice() : nil
        appliedResume = false; appliedAutoTracks = false; autoAddonSubTried = false
        addonSubsResolveTried = false; pendingLibmpvResumeSeek = nil
        buffering = true
        hasStartedPlaying = false
        let issuedToken = loadIntoPlayer(curURL ?? url, headers: curHeaders, live: isCurrentLiveStream,
                                         resumeOrigin: resume)
        // Arm the watchdog ONLY for a load the engine actually took. A refused load leaves the OLD mount in
        // place, so a watchdog armed over it would declare a source dead 30s later and hop off it for nothing,
        // and the cleared flags above would strand the viewer on a spinner nothing owns. Put the playing state
        // back instead and let the stall watchdog - the owner this whole lane exists to pre-empt - have it, which
        // is exactly today's behavior (MIS-260731-03). `curURL` deliberately keeps the healed value: the old port
        // is provably dead, so the next reload down any path should use the re-derived one.
        guard issuedToken != nil else {
            DiagnosticsLog.log("player", "foreground re-mount was not issued; restoring the playing state")
            hasStartedPlaying = true
            buffering = false
            reconnecting = false
            appliedResume = true
            // The OLD mount is still live and still carries the viewer's pick, so drop the snapshot: re-applying
            // it would re-add an external subtitle that was never removed (a duplicate row in the picker).
            pendingAudioReapply = nil
            pendingSubtitleReapply = nil
            return
        }
        // The load was issued, so this is a FRESH mount that carries no external subtitles: drop the added-set
        // tracking so the picker is honest and the reapply above can re-add cleanly (same clear, same reason, as
        // switchPlayerEngine). Deliberately after the guard - the refused-load branch keeps the OLD mount alive,
        // and its rows are still real.
        addedSubURLs = []; addedPooledIDs = []
        startLoadTimeout()
    }

    private func recoverFromStall(stalledTicksAtRecovery: Int) {
        if let avPlayer = coordinator.player as? AVPlayerEngineController,
           let expectedItemGeneration = avStallWatchdogItemGeneration {
            let action = avPlayer.recoverFreshItemForProvenSurfaceStall(
                expectedItemGeneration: expectedItemGeneration,
                surfaceStalled: true
            )
            switch action {
            case .retain(let reason):
                // The first frozen sample intentionally only establishes the engine-owned producer baseline.
                // Keep observing this item. In particular, AVPlayer's ordinary rebuffering must never fall
                // through to reloadAtPlayhead(), which destroys a healthy remux and looks like a restart.
                DiagnosticsLog.log("player", "AVPlayer stall retained reason=\(String(describing: reason)) generation=\(expectedItemGeneration)")
                return
            case .replaceFreshItem:
                // The engine transaction retains the mounted producer, source-time origin, transport intent,
                // DV signalling, and semantic media selections. Re-arm only the surface-owned first-frame
                // state for its NEW exact item generation; do not call the legacy player re-load path.
                let replacementItemGeneration = avPlayer.currentItemGeneration
                avStallWatchdogItemGeneration = replacementItemGeneration
                buffering = true
                hasStartedPlaying = false
                firstFrameRenderedAt = nil
                appliedResume = true
                appliedAutoTracks = true
                if let replacementLoadToken = avPlayer.activeLoadToken {
                    armAVPostReplacementFirstFrameDeadline(
                        loadToken: replacementLoadToken,
                        itemGeneration: replacementItemGeneration
                    )
                }
                DiagnosticsLog.log("player", "AVPlayer proven surface stall replaced fresh item generation=\(replacementItemGeneration)")
                return
            case .terminal(let proof):
                DiagnosticsLog.log("player", "AVPlayer stall terminal proof=\(String(describing: proof))")
                if !hopToNextSource(reason: "AVPlayer terminal stall") {
                    loadErrorMsg = "Playback stopped on this source."
                    presentTerminalLoadFailure()
                }
                return
            }
        }
        guard stallRecoveries < 3 else {
            // Repeated stalls on the same source: stop reloading and let the viewer
            // pick another source from the error overlay.
            // Repeated stalls on one source: hop to another at the current position,
            // falling back to the error overlay once candidates run out.
            DiagnosticsLog.log("player", "stall recovery exhausted")
            if hopToNextSource(reason: "stall budget exhausted") { return }
            loadErrorMsg = "Playback kept stalling on this source."
            presentTerminalLoadFailure()
            return
        }
        // Seek-nudge tier (Beta 26 workstream B2): a stall whose demuxer still holds a real cushion is
        // usually a wedged decode pipeline rather than dead bytes. A tiny same-item seek re-kicks the
        // engine without paying the reload cost (fresh spool, subtitle re-OCR, first-frame wait). Two
        // nudges max per stall episode, never charged to the reload budget; beyond that the proven
        // reload ladder takes over unchanged.
        let bufferedAhead = max(0, bufferedTime - currentTime)
        let stallOpenSeconds = Double(stalledTicksAtRecovery) * PlayerMidPlaybackStallPolicy.pollIntervalSeconds
        if PlayerMidPlaybackStallPolicy.shouldSeekNudge(
            stallOpenSeconds: stallOpenSeconds,
            bufferedAheadSeconds: bufferedAhead,
            nudgesIssued: stallNudgesIssued
        ) {
            stallNudgesIssued += 1
            plog.info("mid-playback stall, seek-nudge \(stallNudgesIssued) at \(currentTime, privacy: .public)")
            DiagnosticsLog.log("player", "stall seek-nudge \(stallNudgesIssued)/\(PlayerMidPlaybackStallPolicy.maxSeekNudgesPerStallEpisode) at \(Int(currentTime))s buffered=\(Int(bufferedAhead))s")
            coordinator.player?.seek(to: currentTime + 0.25)
            return
        }
        stallNudgesIssued = 0
        stallRecoveries += 1
        plog.info("mid-playback stall, reloading at \(currentTime, privacy: .public)")
        DiagnosticsLog.log("player", "mid-playback stall \(stallRecoveries), reloading at \(Int(currentTime))s")
        reloadAtPlayhead()
    }

    /// The shared mid-play same-engine reload: replays the current mount at the live play head. Used by
    /// the stall ladder and by the buffered-retirement gate ahead of an AVPlayer-to-libmpv demote (B3).
    private func reloadAtPlayhead() {
        let recoveryToken = coordinator.player is AVPlayerEngineController
            ? coordinator.player?.activeLoadToken : nil
        // A refused load leaves the old controller alive. Keep enough surface state to make that controller
        // authoritative again rather than exposing a permanent spinner over a still-playing mount.
        let previousResumeSeconds = resumeSeconds
        let previousResumeIsMidPlayRecovery = resumeIsMidPlayRecovery
        let previousAppliedResume = appliedResume
        let previousAppliedAutoTracks = appliedAutoTracks
        let previousAutoAddonSubTried = autoAddonSubTried
        let previousAddonSubsResolveTried = addonSubsResolveTried
        let previousUserPickedSubtitle = userPickedSubtitle
        let previousPendingSubtitleReapply = pendingSubtitleReapply
        let previousPendingAudioReapply = pendingAudioReapply
        let previousPendingLibmpvResumeSeek = pendingLibmpvResumeSeek
        let previousBuffering = buffering
        let previousHasStartedPlaying = hasStartedPlaying
        let previousFirstFrameRenderedAt = firstFrameRenderedAt
        let previousURL = curURL
        // Same-title automatic recovery must retain the viewer's explicit subtitle intent. libmpv creates a
        // fresh mount here (unlike AVPlayer's token reuse), so clearing this flag used to turn an explicit Off
        // or language selection back into the preference-derived automatic selection after every stall.
        let subtitleChoice = userPickedSubtitle ? captureSubtitleChoice() : nil
        let audioChoice = captureSelectedAudioChoice()
        resumeSeconds = currentTime
        resumeIsMidPlayRecovery = true   // the live play head of the stalled mount, not a stored offset
        appliedResume = false; appliedAutoTracks = false; autoAddonSubTried = false; addonSubsResolveTried = false
        if recoveryToken == nil {
            userPickedSubtitle = subtitleChoice != nil
        }
        pendingSubtitleReapply = subtitleChoice
        pendingAudioReapply = audioChoice
        // An ordinary reload must not inherit stale edges, but it must retain whether the rapid lane already
        // spent its one same-source reload so a fresh burst still escalates instead of looping.
        resetRapidBufferingRecovery(
            reason: "ordinary same-source reload",
            preservingProgressBudget: true,
            clearingSuppression: false
        )
        pendingLibmpvResumeSeek = nil   // reloading the same source at a fresh mount: drop any deferred resume seek
        buffering = true
        hasStartedPlaying = false
        // The stalled mount already had a first frame; this reload earns its own. Without clearing it,
        // elapsedSinceFirstFrame (the playback-diagnostics receipt) keeps measuring from the ORIGINAL,
        // now-stale first frame across the reload instead of the fresh one this recovery is about to render.
        // Mirrors iOS PlayerScreen.recoverFromStall.
        firstFrameRenderedAt = nil
        let mountPreviousURL = curURL
        let replacementURL = liveMountURL()
        prepareRawTorrentAfterLoopbackRebind(from: mountPreviousURL, to: replacementURL)
        curURL = replacementURL   // self-heal a drifted embedded-server port before replaying the mount
        let issuedToken = loadIntoPlayer(curURL ?? url, headers: curHeaders, live: isCurrentLiveStream,
                                         reusing: recoveryToken, resumeOrigin: currentTime)
        guard issuedToken != nil else {
            // The old mount remains authoritative if the replacement was refused, including its external
            // subtitle rows. Restore every live-state bit changed above; dropping only the subtitle snapshot
            // left the old controller playing beneath a spinner with first-frame logic permanently disarmed.
            resumeSeconds = previousResumeSeconds
            resumeIsMidPlayRecovery = previousResumeIsMidPlayRecovery
            appliedResume = previousAppliedResume
            appliedAutoTracks = previousAppliedAutoTracks
            autoAddonSubTried = previousAutoAddonSubTried
            addonSubsResolveTried = previousAddonSubsResolveTried
            userPickedSubtitle = previousUserPickedSubtitle
            pendingSubtitleReapply = previousPendingSubtitleReapply
            pendingAudioReapply = previousPendingAudioReapply
            pendingLibmpvResumeSeek = previousPendingLibmpvResumeSeek
            buffering = previousBuffering
            hasStartedPlaying = previousHasStartedPlaying
            firstFrameRenderedAt = previousFirstFrameRenderedAt
            curURL = previousURL
            return
        }
        // A newly accepted libmpv mount does not own external subtitle rows from the retired controller. Clear
        // bookkeeping only now, never before an accepted load, so a refused recovery cannot duplicate rows.
        if recoveryToken == nil { addedSubURLs = []; addedPooledIDs = [] }
        startLoadTimeout()
    }

    /// REQ-260721-78 option A (surface side): the ONE way this view publishes a terminal load
    /// failure. On a terminal native-HLS Dolby Vision failure the old code set `loadFailed` and left
    /// the AV controller live, so a delayed `preferredDisplayCriteria` completion could still switch
    /// the display mode, attach the item, and start playback BEHIND the terminal overlay. Retire the
    /// engine synchronously FIRST (stop() invalidates the load token, advances the item generation,
    /// cancels the native pre-attach task and criteria work, and tears down item/remux/observers),
    /// and only then publish: every completion minted before this moment fails the engine's
    /// ownership gate and is inert, while loadFile() rebuilds everything, so the overlay's Retry
    /// still works. Native engine only (see TerminalLoadFailurePolicy: libmpv's stop() destroys the
    /// core, which would turn Retry into a dead end, and libmpv parks no deferred display work).
    /// Idempotent: stop() and a repeated publication are both safe, so every terminal branch and a
    /// later dismissal can each call this. Same shape as the debrid-crash straddle root cause
    /// (stop-before-dismiss): engine down first, then the surface state change.
    private func presentTerminalLoadFailure() {
        TerminalLoadFailurePolicy.presentTerminal(
            retire: {
                guard TerminalLoadFailurePolicy.shouldRetireBeforePublish(
                    engineIsNative: coordinator.player is AVPlayerEngineController) else { return }
                DiagnosticsLog.log("player", "terminal failure: retiring AVPlayer engine before the overlay (option A)")
                coordinator.player?.stop()
            },
            publish: { withAnimation { loadFailed = true } }
        )
    }

    /// The ordinary 30s start budget. Every caller uses this one except the post-demote mpv leg.
    private func startLoadTimeout() { startLoadTimeout(seconds: 30) }

    /// `seconds` is the ordinary 30s start budget for every caller except the post-demote mpv leg, which passes
    /// the shorter `avPostDemoteStartTimeoutSeconds` (W2-A item 3b). Everything else about the timer - the
    /// generation/token ownership guards and the handleStartTimeout ladder it falls into - is identical.
    private func startLoadTimeout(seconds: Double) {
        loadTimeout?.cancel()
        startRecoveryDeadline()   // first call arms the overall cap; later calls (hops) leave it running
        startAVStartWatchdog()    // AVPlayer-only fast fallback to libmpv when it mounts but never plays
        lastBufferedAtWatchdog = bufferedTime   // snapshot the buffered edge so the fire path can tell if bytes moved
        let capturedEpisodeGeneration = episodeSwitchGeneration
        let capturedSourceGeneration = sourceSwitchGeneration
        let capturedResumeGeneration = resumeRetryGeneration
        let capturedLoadToken = coordinator.player?.activeLoadToken
        loadTimeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            // A cancelled watchdog (superseded by a hop / reload / new load) must NOT fire: Task.sleep throws
            // CancellationError on cancel and `try?` swallows it, so without this guard the cancelled timer runs
            // handleStartTimeout immediately, and each hop arms+cancels the next, cascading through every source
            // in milliseconds ("Tried N sources") over a source that was actually still loading.
            guard !Task.isCancelled, !hasStartedPlaying, !loadFailed,
                  TVPlaybackStartPolicy.loadTimeoutOwnerIsCurrent(
                      capturedEpisodeGeneration: capturedEpisodeGeneration,
                      currentEpisodeGeneration: episodeSwitchGeneration,
                      capturedSourceGeneration: capturedSourceGeneration,
                      currentSourceGeneration: sourceSwitchGeneration,
                      capturedResumeGeneration: capturedResumeGeneration,
                      currentResumeGeneration: resumeRetryGeneration,
                      capturedLoadToken: capturedLoadToken,
                      currentLoadToken: coordinator.player?.activeLoadToken) else { return }
            handleStartTimeout()
        }
    }

    /// The 30s start-watchdog fired without playback beginning. Decide between EXTEND (bytes still
    /// arriving on a slow big source), WARM (a cold torrent), HONOR (retry an explicit pick in place), or
    /// HOP (the auto path), preserving every existing recovery path:
    ///  - A cold torrent still warms up (mpv never errors a peerless torrent).
    ///  - A big 4K first-buffer that is genuinely progressing (the demuxer-cache edge advanced since the
    ///    watchdog armed) EXTENDS instead of hopping, bounded by `maxBufferGraceExtensions` and the
    ///    overall recovery deadline, so a 4K remux on slow debrid isn't declared dead mid-fill.
    ///  - An EXPLICIT pick (a user-chosen source/quality) is retried IN PLACE, never silently swapped for
    ///    a different lower-quality source; once its grace is spent it surfaces a clear "not ready" error.
    ///  - Only the AUTO path (Watch Now / resume) hops to another source.
    private func handleStartTimeout() {
        let directFallbackDecision = TVDirectAVStartRecoveryPolicy.fallbackTimedOut(
            recoveryRecorded: directAVNoFrameRecovery != nil,
            sourceStillCurrent: directAVNoFrameRecovery?.url == (curURL ?? url)
                && directAVNoFrameRecovery?.episodeGeneration == episodeSwitchGeneration
                && directAVNoFrameRecovery?.sourceGeneration == sourceSwitchGeneration
                && directAVNoFrameRecovery?.resumeGeneration == resumeRetryGeneration
                && directAVNoFrameRecovery?.mpvLoadToken == coordinator.player?.activeLoadToken,
            fallbackIsLibMPV: !isAVPlayerActive,
            firstFrameRendered: hasStartedPlaying
        )
        if directFallbackDecision == .hop {
            let recovery = directAVNoFrameRecovery
            let attemptID = recovery?.attemptID ?? "none"
            directAVNoFrameRecovery = nil
            DiagnosticsLog.log(
                "playback",
                "source attempt route=libmpv-after-avplayer attempt=\(attemptID) outcome=no-first-frame"
            )
            // A fallback watchdog is still part of the viewer's original request. Preserve the
            // established explicit-pick and Continue Watching recovery contracts before an
            // automatic route spends the source-hop budget. In particular, Continue Watching
            // gets its one same-source re-resolution through `handleLoadFailure`.
            if recoverCurrentNativeDebridLink(reason: "direct AVPlayer and libmpv produced no frame") {
                return
            }
            if currentPickWasExplicit {
                loadErrorMsg = "This source didn't produce playable media. Choose another source."
                presentTerminalLoadFailure()
                return
            }
            if hopToNextSource(reason: "direct AVPlayer and libmpv produced no frame") { return }
            if loadErrorMsg.isEmpty { loadErrorMsg = "This source did not produce playable media." }
            presentTerminalLoadFailure()
            return
        }
        if isTorrentPlayback { warmUpTorrent(); return }   // a peerless torrent never errors; warm it up
        let avController = coordinator.player as? AVPlayerEngineController
        if TVPlaybackStartPolicy.genericLoadTimeoutDefersToRemuxWatchdog(
            avPlayerActive: avController != nil,
            remuxPendingOrMounted: avController?.remuxStartupSignal.pendingOrMounted == true
        ) {
            DiagnosticsLog.log(
                "dv",
                "generic load timeout deferred to exact-owner progress-aware remux watchdog")
            return
        }
        // Bytes still arriving on a slow (typically 4K remux) first-buffer: extend rather than give up.
        if bufferGraceUsed < maxBufferGraceExtensions, bufferedTime > lastBufferedAtWatchdog + 0.25 {
            bufferGraceUsed += 1
            reconnecting = true
            buffering = true
            lastBufferedAtWatchdog = bufferedTime
            loadTimeout?.cancel()
            let capturedEpisodeGeneration = episodeSwitchGeneration
            let capturedSourceGeneration = sourceSwitchGeneration
            let capturedResumeGeneration = resumeRetryGeneration
            let capturedLoadToken = coordinator.player?.activeLoadToken
            loadTimeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, !hasStartedPlaying, !loadFailed,
                      TVPlaybackStartPolicy.loadTimeoutOwnerIsCurrent(
                          capturedEpisodeGeneration: capturedEpisodeGeneration,
                          currentEpisodeGeneration: episodeSwitchGeneration,
                          capturedSourceGeneration: capturedSourceGeneration,
                          currentSourceGeneration: sourceSwitchGeneration,
                          capturedResumeGeneration: capturedResumeGeneration,
                          currentResumeGeneration: resumeRetryGeneration,
                          capturedLoadToken: capturedLoadToken,
                          currentLoadToken: coordinator.player?.activeLoadToken) else { return }
                handleStartTimeout()
            }
            return
        }
        // Honor an explicit user pick: retry the SAME source in place instead of hopping to a different,
        // possibly lower-quality, source. Once the grace is spent, surface a clear error, not a silent drop.
        if currentPickWasExplicit {
            if bufferGraceUsed < maxBufferGraceExtensions {
                bufferGraceUsed += 1
                reconnecting = true
                retryLoad(resetAutoRetries: false)
                return
            }
            reconnecting = false
            if loadErrorMsg.isEmpty { loadErrorMsg = "This source isn't ready (still downloading on your debrid, or slow). Choose another source." }
            presentTerminalLoadFailure()
            return
        }
        // Auto path (Watch Now / resume): hop to the next-best untried source (quality-drop-capped inside).
        if hopToNextSource(reason: "load timeout") { return }
        if loadErrorMsg.isEmpty { loadErrorMsg = "Timed out, the source never started." }
        presentTerminalLoadFailure()
    }

    /// Demote the active AVFoundation engine to libmpv IN PLACE (the #76 fallback). Tears the AVPlayer
    /// engine down NOW (cancels its periodic time observer + KVO) before flipping `avEngineFailed`, so no
    /// stray timePos tick can land in the surface-swap window and set hasStartedPlaying (which would
    /// suppress a later genuine libmpv failure). SwiftUI's dismantleUIView also calls stop(); it is
    /// idempotent, so the double-stop is safe. Returns true when it actually demoted (caller should bail),
    /// false when AVPlayer is not the active engine and the caller should run its normal failure path.
    @discardableResult
    private func demoteAVPlayerToMPV() -> Bool {
        // Consume the one-shot dead-input evidence FIRST, before the guard: a refused demote must not leave a
        // stale true behind for the next one. See `demoteFollowedDeadInput`.
        let followedDeadInput = demoteFollowedDeadInput
        demoteFollowedDeadInput = false
        guard useAVPlayerEngine,
              let retiringAVPlayer = coordinator.player as? AVPlayerEngineController else { return false }
        let desiredPaused = isPaused
        captureRecoverySelections()
        queueIncomingTransportIntent(paused: desiredPaused)
        resetRapidBufferingRecovery(reason: "engine demote")
        resumeRetryGeneration &+= 1
        let reissueEpisodeGeneration = episodeSwitchGeneration
        let reissueSourceGeneration = sourceSwitchGeneration
        let reissueMediaGeneration = resumeRetryGeneration
        if !hasStartedPlaying {
            directAVNoFrameRecovery = DirectAVNoFrameRecovery(
                url: curURL ?? url,
                episodeGeneration: episodeSwitchGeneration,
                sourceGeneration: sourceSwitchGeneration,
                resumeGeneration: resumeRetryGeneration,
                attemptID: UUID().uuidString,
                mpvLoadToken: nil
            )
        }
        let fallbackAttemptID = directAVNoFrameRecovery?.attemptID ?? UUID().uuidString
        let followedDirectNoFrame = directAVNoFrameRecovery != nil
        avStartWatchdog?.cancel(); avStartWatchdog = nil
        loadTimeout?.cancel(); loadTimeout = nil
        libmpvResumeWatchdog?.cancel(); libmpvResumeWatchdog = nil   // fresh mount incoming: retire any deferred-resume safety net
        clearPostFrameResumeSeekWatchdog()
        let engineRequestedResume =
            retiringAVPlayer.pendingRequestedSourcePositionSeconds
        // Real DV-profile evidence from the outgoing AVPlayer's own remux parse (#148), captured for the
        // SAME reason as engineRequestedResume above: stop() below tears the remux session down, so this
        // MUST read before it. Feeds the fresh mpv mount's pre-probe colour fallback via the Coordinator
        // (MPVMetalPlayerView.makeController copies it onto the new controller). Mirrors iOS PlayerScreen.
        coordinator.dolbyVisionFallbackInfo =
            retiringAVPlayer.dolbyVisionFallbackInfo
        // Engine of origin for the 2s post-switch grace (W2-A item 3a). Captured BEFORE stop(), which clears the
        // engine's active token: this is the exact load whose queued .failed the grace exists to swallow.
        demotedEngineLoadToken = retiringAVPlayer.activeLoadToken
        // Always-on [dv] breadcrumb: the demotion edge, recorded in the exportable log (the VXProbe lines
        // around it are gated off in user builds). After this line the session is libmpv = HDR10 tone-map
        // + decoded multichannel PCM; true DV/Atmos for this play is over.
        DiagnosticsLog.log("playback", "fallback attempt=\(fallbackAttemptID) stage=av-retire route=avplayer")
        invalidateNextEpisodePreparation(reason: "AV-to-mpv handoff")
        let quiescence = retiringAVPlayer.stopForMPVFallback()
        clearCachedAudioOutputTruth()
        engineSwitchedAt = Date()   // grace window swallows a stale KVO .failed from the outgoing AV engine
        // SILENT demote. Flipping `avEngineFailed` re-renders `playerSurface` to the mpv surface on the SAME
        // view, which re-loads the SAME stream URL (initialPlayback.url) on libmpv. It does NOT increment
        // `sourceHops` and never calls `hopToNextSource`, so this is not a failover attempt and the
        // "Source failed, trying another (N/4)" banner (gated on `sourceHops > 0`) never shows. libmpv just
        // tone-maps a DV link to HDR10, an acceptable fallback, so no toast is surfaced.
        // Re-arm the load state + start watchdog for the libmpv re-load. Without this the mpv re-open after the
        // AVPlayer->mpv demote runs with NO start watchdog, so a stalled mpv re-open never fails over or surfaces
        // an error (mirrors iOS PlayerScreen.demoteAVPlayerToMPV).
        // An engine-owned target is a newer explicit seek and is authoritative in BOTH directions. In
        // particular, a backward MediaRemote, chapter, or skip seek from 3600s to 600s must not be replaced by
        // the stale 3600s chrome clock. Retire the old anti-regression floor first; maybeResume and the
        // in-flight seek guard own the exact target on the fresh libmpv item. With no engine transaction, keep
        // the existing floor behavior for a remux that had to restart near zero.
        let reconcileResume: Double?
        if let engineRequestedResume {
            suppressedResumeFloor = nil
            reconcileResume = engineRequestedResume
        } else if hasStartedPlaying {
            reconcileResume = max(currentTime, suppressedResumeFloor ?? 0)
        } else {
            reconcileResume = resumeSeconds ?? suppressedResumeFloor
        }
        // Same provenance question switchStream asks, captured before the flags below clear the answer: a
        // mid-play demote carries the live play head, a pre-start one carries the stored offset unchanged.
        // `engineRequestedResume` is deliberately NOT part of that answer, even though the VALUE selection
        // above prefers it: pre-first-sample the intent's sourceSeconds IS the stored library offset (the
        // engine reports the remux timeline origin, AVPlayerEngine.swift), and an intent survives an
        // intent-bearing remount (HDR fallback, audio replacement). Counting it here would stamp a fresh
        // Continue-Watching launch's STORED offset as a live play head on a pre-start demote, and maybeResume
        // would then bypass its near-end guard and auto-resume a fresh play straight into the credits.
        let carriedPlayHead = hasStartedPlaying || resumeIsMidPlayRecovery
        hasStartedPlaying = false; buffering = true; appliedVolume = false; appliedSize = false; appliedResume = false; loadErrorMsg = ""
        // The outgoing AVPlayer mount already had a first frame (or never got one); either way this fresh
        // mpv mount earns its own. Without clearing it, elapsedSinceFirstFrame keeps measuring from the
        // OUTGOING engine's stale timestamp instead of the incoming mpv leg's. Mirrors iOS PlayerScreen.
        firstFrameRenderedAt = nil
        subtitleLoadingURL = nil   // self-heal: an in-flight subtitle load died with the AVPlayer engine; a stranded latch would gate every later pick
        inFlightSeekTarget = nil   // any seek in flight died with the AVPlayer engine; mpv's fresh ticks are authoritative
        pendingLibmpvResumeSeek = nil   // fresh mpv mount: any deferred resume seek from the outgoing engine is stale
        // Carry the live position into the mpv re-load UNCONDITIONALLY (maybeResume reads resumeSeconds once
        // duration lands; appliedResume was re-armed above). Pre-start this is an exact no-op (reconcileResume
        // IS resumeSeconds). It matters for the MID-PLAY demotes (the audio-over-black watchdog, a mid-play
        // .failed) on the LAUNCH url: the curURL!=url branch below never runs there, so without this the mpv
        // re-open would rewind to the original launch offset instead of where the failure struck.
        resumeSeconds = reconcileResume
        resumeIsMidPlayRecovery = carriedPlayHead
        let handoff = AVToMPVHandoff(
            url: curURL ?? url,
            episodeGeneration: reissueEpisodeGeneration,
            sourceGeneration: reissueSourceGeneration,
            resumeGeneration: reissueMediaGeneration,
            attemptID: fallbackAttemptID
        )
        avToMPVHandoff = handoff
        avToMPVHandoffTask?.cancel()
        avToMPVHandoffTask = Task { @MainActor in
            let quiescent = await quiescence.wait(timeout: .seconds(2))
            guard !Task.isCancelled,
                  !leftPlayback,
                  avToMPVHandoff == handoff,
                  handoff.episodeGeneration == episodeSwitchGeneration,
                  handoff.sourceGeneration == sourceSwitchGeneration,
                  handoff.resumeGeneration == resumeRetryGeneration,
                  handoff.url == (curURL ?? url) else { return }
            guard VortXRemuxHandoffPolicy.canMountMPV(
                routeStillCurrent: true,
                producerQuiescent: quiescent
            ) else {
                avToMPVHandoff = nil
                avToMPVHandoffBlocked = true
                directAVNoFrameRecovery = nil
                loadErrorMsg = "Playback cleanup did not complete. Try another source."
                DiagnosticsLog.log("playback", "fallback attempt=\(handoff.attemptID) stage=teardown outcome=timeout")
                presentTerminalLoadFailure()
                return
            }
            bufferGraceUsed = 0; lastBufferedAtWatchdog = -1; bufferedTime = 0
            avToMPVHandoff = nil
            avEngineFailed = true
            engineSwitchedAt = Date()
            DiagnosticsLog.log("playback", "fallback attempt=\(handoff.attemptID) stage=teardown outcome=ack next=mpv-mount")
            let mounted = await awaitReplacementMPVMount(for: handoff)
            guard !Task.isCancelled,
                  let mounted else { return }
            let mpv = mounted.controller
            let mpvToken = mounted.token
            if let recovery = directAVNoFrameRecovery,
               recovery.url == handoff.url,
               recovery.episodeGeneration == handoff.episodeGeneration,
               recovery.sourceGeneration == handoff.sourceGeneration,
               recovery.resumeGeneration == handoff.resumeGeneration {
                directAVNoFrameRecovery = DirectAVNoFrameRecovery(
                    url: recovery.url,
                    episodeGeneration: recovery.episodeGeneration,
                    sourceGeneration: recovery.sourceGeneration,
                    resumeGeneration: recovery.resumeGeneration,
                    attemptID: recovery.attemptID,
                    mpvLoadToken: mpvToken)
            }
            guard mpv.activeLoadToken == mpvToken else {
                avToMPVHandoffBlocked = true
                loadErrorMsg = "The replacement player did not start."
                presentTerminalLoadFailure()
                return
            }
            if followedDeadInput {
                startLoadTimeout(seconds: avPostDemoteStartTimeoutSeconds)
            } else if followedDirectNoFrame {
                startLoadTimeout(seconds: directAVFallbackMPVStartTimeoutSeconds)
            } else {
                startLoadTimeout()
            }
            DiagnosticsLog.log("playback", "fallback attempt=\(handoff.attemptID) stage=mpv-load outcome=issued")
        }
        return true
    }

    /// SwiftUI construction has no synchronous completion callback. Poll the actual coordinator identity for a
    /// bounded interval instead of assuming a display-frame delay is a mount receipt.
    private func awaitReplacementMPVMount(
        for handoff: AVToMPVHandoff
    ) async -> (controller: MPVMetalViewController, token: PlayerLoadToken)? {
        let deadline = ContinuousClock.now + .seconds(2)
        while !Task.isCancelled, ContinuousClock.now < deadline {
            guard !leftPlayback,
                  avToMPVHandoff == nil,
                  !avToMPVHandoffBlocked,
                  handoff.episodeGeneration == episodeSwitchGeneration,
                  handoff.sourceGeneration == sourceSwitchGeneration,
                  handoff.resumeGeneration == resumeRetryGeneration,
                  handoff.url == (curURL ?? url) else { return nil }
            if let controller = coordinator.player as? MPVMetalViewController,
               let token = controller.activeLoadToken {
                return (controller, token)
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        avToMPVHandoffBlocked = true
        loadErrorMsg = "The replacement player did not start."
        presentTerminalLoadFailure()
        return nil
    }

    /// User-invoked mid-title engine swap entry point. When the active native-debrid mount is reconnecting, a
    /// fresh provider URL is acquired before either surface is constructed. Healthy switches retain their
    /// current URL and never make a provider request.
    private func switchPlayerEngine(toAVPlayer: Bool) {
        guard toAVPlayer != isAVPlayerActive else { withAnimation { showOptions = false }; return }
        if toAVPlayer, !canUseAVPlayerEngine {
            showEngineNote("This source can only play on the built-in (libmpv) engine.")
            withAnimation { showOptions = false }; return
        }
        if nativeDebridFreshLinkRecovery.freshLinkInFlight {
            _ = nativeDebridFreshLinkRecovery.joinEngineSwitch(toAVPlayer)
            DiagnosticsLog.log("player", "user engine switch joined native-debrid fresh-link recovery")
            withAnimation { showOptions = false }
            return
        }
        let needsFreshNativeDebridLink = reconnecting || autoRetryTask != nil
        if needsFreshNativeDebridLink,
           recoverCurrentNativeDebridLink(reason: "engine switch", requestedEngine: toAVPlayer) {
            withAnimation { showOptions = false }
            return
        }
        performPlayerEngineSwitch(toAVPlayer: toAVPlayer)
    }

    /// User-invoked mid-title engine swap (P3, #76). Generalizes `demoteAVPlayerToMPV` into a bidirectional,
    /// user-driven switch: tears the live engine down synchronously (straddle invariant) BEFORE flipping the
    /// manual override so `playerSurface` re-renders the other engine on the SAME view, carries the live
    /// position, and re-arms the one-shot latches so tracks / size / resume re-apply on the fresh mount. Speed
    /// and subtitle sync are re-applied once the new engine's controller mounts. Track choices re-derive from
    /// `TrackPreferences` via the automatic trackList -> `TrackSelector` flow (engine id spaces differ by
    /// design; matching is by lang/title). No-op when already on the requested engine.
    private func performPlayerEngineSwitch(
        toAVPlayer: Bool,
        preservingNativeDebridRecoveryGeneration: Bool = false
    ) {
        guard toAVPlayer != isAVPlayerActive else { withAnimation { showOptions = false }; return }
        if !toAVPlayer, coordinator.player is AVPlayerEngineController {
            _ = demoteAVPlayerToMPV()
            withAnimation { showOptions = false }
            return
        }
        // Re-validate against the ACTIVE source before committing: the picker row is gated by
        // canUseAVPlayerEngine, but stand down defensively if the active stream can't play on AVPlayer (a
        // non-DV MKV, or a mid-session switch to a torrent) so we never feed a dead URL into AVPlayer.
        if toAVPlayer, !canUseAVPlayerEngine {
            showEngineNote("This source can only play on the built-in (libmpv) engine.")
            withAnimation { showOptions = false }; return
        }
        resetRapidBufferingRecovery(reason: "user engine switch")
        let desiredPaused = isPaused
        captureRecoverySelections()
        queueIncomingTransportIntent(paused: desiredPaused)
        DiagnosticsLog.log("player", "user engine switch -> \(toAVPlayer ? "AVPlayer" : "libmpv") (mid-title, carry position)")
        if !preservingNativeDebridRecoveryGeneration {
            resumeRetryGeneration &+= 1
        }
        let reissueEpisodeGeneration = episodeSwitchGeneration
        let reissueSourceGeneration = sourceSwitchGeneration
        let reissueMediaGeneration = resumeRetryGeneration
        let reissuePendingVideoID = pendingAdvance?.meta.videoId
        avStartWatchdog?.cancel(); avStartWatchdog = nil
        libmpvResumeWatchdog?.cancel(); libmpvResumeWatchdog = nil   // fresh mount incoming: retire any deferred-resume safety net
        clearPostFrameResumeSeekWatchdog()
        // Carry the HIGHER of the live position and any suppressed resume floor. A DV-remux session that
        // started at 0 (its resume seek was dropped, forward-only) holds the REAL resume point ONLY in
        // suppressedResumeFloor, so carrying currentTime alone would regress the account resume to ~0 when the
        // new engine saves. Keep the floor across the switch (do NOT nil it) so saveProgress still refuses to
        // write below it until the playhead passes it; on an mpv target maybeResume seeks to reconcileResume
        // and the floor clears naturally, on another remux target maybeResume re-suppresses it.
        let carried = max(currentTime, suppressedResumeFloor ?? 0)
        let reconcileResume: Double? = hasStartedPlaying ? carried : (resumeSeconds ?? suppressedResumeFloor)
        // Provenance of that value, captured before the reset below clears `hasStartedPlaying` (see switchStream).
        let carriedPlayHead = hasStartedPlaying || resumeIsMidPlayRecovery
        // Engine of origin for the grace window below (W2-A item 3a). Captured before stop() clears it, and for
        // WHICHEVER engine is outgoing here: leaving a stale token from an earlier demote in place would make the
        // grace treat this switch's own stale error as "from the incoming engine" and stop swallowing it.
        demotedEngineLoadToken = coordinator.player?.activeLoadToken
        coordinator.player?.stop()          // straddle invariant: old engine fully down before the surface swap
        clearCachedAudioOutputTruth()
        engineSurfaceURLOverride = curURL ?? url
        engineSurfaceHeadersOverride = curHeaders
        engineSurfaceUsesActiveTuple = true
        avSurfaceResumeOrigin = reconcileResume
        manualEngineAVPlayer = toAVPlayer
        avEngineFailed = false              // a manual pick gets a fresh chance even after a prior demote
        engineSwitchedAt = Date()           // grace window swallows a stale event from the outgoing engine
        hasStartedPlaying = false; buffering = true; appliedVolume = false; appliedSize = false; appliedResume = false
        appliedAutoTracks = false; loadErrorMsg = ""
        // Mirrors demoteAVPlayerToMPV: the outgoing engine's first frame belongs to a mount this session is
        // leaving, so elapsedSinceFirstFrame must not keep measuring from it once the new engine mounts.
        firstFrameRenderedAt = nil
        subtitleLoadingURL = nil   // self-heal: an in-flight subtitle load died with the old engine; a stranded latch would gate every later pick
        // The new engine loads no external subtitles yet: drop the added-set tracking so the picker is honest
        // and the subtitle reapply can re-add cleanly.
        addedSubURLs = []; addedPooledIDs = []
        inFlightSeekTarget = nil
        pendingLibmpvResumeSeek = nil   // fresh mount on the new engine: drop any deferred resume seek from the old one
        resumeSeconds = reconcileResume
        resumeIsMidPlayRecovery = carriedPlayHead
        startLoadTimeout()
        if toAVPlayer { startAVStartWatchdog() }   // arm the AV no-frame demote on the new mount
        // The fresh mount auto-loads the immutable LAUNCH url; re-point at the ACTIVE source if this session
        // switched source/episode in place (same deferred re-point demoteAVPlayerToMPV uses; the mpv/AVPlayer
        // controller only becomes coordinator.player on the NEXT SwiftUI render).
        if let cu = curURL, cu != url || pendingAdvance?.issued == true {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard manualEngineAVPlayer == toAVPlayer, !Task.isCancelled, curURL == cu,
                      reissueEpisodeGeneration == episodeSwitchGeneration,
                      reissueSourceGeneration == sourceSwitchGeneration,
                      reissueMediaGeneration == resumeRetryGeneration,
                      reissuePendingVideoID == pendingAdvance?.meta.videoId else { return }
                appliedResume = false; pendingLibmpvResumeSeek = nil
                loadIntoPlayer(cu, headers: curHeaders, live: curIsLive,
                               resumeOrigin: reconcileResume)
            }
        }
        // Re-apply speed once the new engine's controller is mounted (next render).
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard manualEngineAVPlayer == toAVPlayer, !Task.isCancelled,
                  reissueEpisodeGeneration == episodeSwitchGeneration,
                  reissueSourceGeneration == sourceSwitchGeneration,
                  reissueMediaGeneration == resumeRetryGeneration,
                  reissuePendingVideoID == pendingAdvance?.meta.videoId else { return }
            if abs(playSpeed - 1.0) > 0.01 { coordinator.player?.setSpeed(playSpeed) }
        }
        withAnimation { showOptions = false }
    }

    /// Show a brief player toast and auto-clear it. Used to surface the AVPlayer->libmpv fallback reason.
    private func showEngineNote(_ text: String) {
        engineNote = text
        engineNoteTask?.cancel()
        engineNoteTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            engineNote = nil
        }
    }

    /// Key community trickplay EARLY off a PROVISIONAL duration from the title's `meta.runtime`, so capture
    /// begins at the first positive timePos even when mpv never emits its `duration` event (a debrid
    /// direct-HTTP MKV frequently doesn't). Fail-soft + idempotent: no-op without a tt id or a parseable
    /// runtime; the real mpv duration later re-keys the exact bucket and unblocks uploads. Mirrors the
    /// duration-event call's identity (libraryId + season/episode).
    private func configureCommunityTrickplayProvisional() {
        guard let m = curMeta else { return }
        // The loaded meta carries the human runtime; use it only when it is THIS title's meta.
        if let loaded = core.metaDetails?.meta, loaded.id == m.libraryId,
           let secs = loaded.runtimeSeconds, secs > 0 {
            // A tmdb-keyed hub play often carries its imdb id in the loaded meta for free
            // (behaviorHints.defaultVideoId = "tt…" / "tt…:s:e"); prefer it so the store skips its
            // network resolve. The store resolves any remaining tmdb id itself.
            let freeTT = m.libraryId.hasPrefix("tt") ? nil : CommunityTrickplay.ttPrefix(loaded.behaviorHints?.defaultVideoId)
            scrubThumbnails.configureCommunity(imdbId: freeTT ?? m.libraryId, season: m.season, episode: m.episode,
                                               duration: secs, isRealDuration: false)
            return
        }
        // The engine's metaDetails can be nil or holding ANOTHER title at play time (a hub detail ->
        // add-on detail -> play replaces it, or the load raced), which silently killed the provisional
        // key on tvOS too: whole sessions captured frames that never became eligible to upload. Port the
        // iOS self-heal: log the miss, then one-shot the runtime (movie then series) and key
        // provisionally. A tmdb-keyed play resolves its tt id FIRST (Cinemeta only speaks imdb), and the
        // resolver caches the mapping for the store's own keying. mpv's real `duration` still re-keys.
        VXProbe.log("tp", "provisional key MISS (tvOS): playing=\(VXProbeRedaction.identityToken(m.libraryId)) metaDetails=\(VXProbeRedaction.identityToken(core.metaDetails?.meta?.id)) (fetching runtime)")
        Task {
            var ttId = m.libraryId
            if !ttId.hasPrefix("tt") {
                guard ttId.lowercased().hasPrefix("tmdb"),
                      let tt = await CommunityTrickplay.resolveIMDbID(rawId: m.libraryId, seriesHint: m.season != nil) else {
                    VXProbe.log("tp", "provisional key MISS stays (tvOS): unresolvable id \(VXProbeRedaction.identityToken(m.libraryId))")
                    return
                }
                ttId = tt
            }
            var secs = await Self.cinemetaRuntimeSeconds(kind: "movie", id: ttId)
            if secs <= 0 { secs = await Self.cinemetaRuntimeSeconds(kind: "series", id: ttId) }
            guard secs > 0 else {
                VXProbe.log("tp", "provisional key MISS stays (tvOS): no cinemeta runtime for \(VXProbeRedaction.identityToken(ttId))")
                return
            }
            await MainActor.run {
                guard curMeta?.libraryId == m.libraryId,
                      curMeta?.videoId == m.videoId else { return }   // still the same episode
                scrubThumbnails.configureCommunity(imdbId: ttId, season: m.season, episode: m.episode,
                                                   duration: secs, isRealDuration: false)
            }
        }
    }

    /// One-shot Cinemeta runtime for the provisional trickplay key when the engine meta is unavailable or
    /// mismatched at play time (tvOS twin of PlayerScreen.cinemetaRuntimeSeconds). Returns 0 on any miss.
    private static func cinemetaRuntimeSeconds(kind: String, id: String) async -> Double {
        guard let url = URL(string: "https://v3-cinemeta.strem.io/meta/\(kind)/\(id).json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let meta = obj["meta"] as? [String: Any] else { return 0 }
        return parseRuntimeSeconds(meta["runtime"] as? String)
    }

    /// Minimal twin of CoreMeta.runtimeSeconds for a raw Cinemeta runtime string ("92 min", "1h 32m",
    /// "2:05:00"), used by the provisional-key self-heal above.
    private static func parseRuntimeSeconds(_ raw: String?) -> Double {
        guard let r = raw?.lowercased().trimmingCharacters(in: .whitespaces), !r.isEmpty else { return 0 }
        // R23 twin (mirrors PlayerScreen.parseRuntimeSeconds / CoreMeta.runtimeSeconds): the raw string is
        // add-on/Cinemeta-supplied, so compute in Double and cap each field. A garbage value like
        // "3000000000000000:00:00" must yield 0, not trap on Int overflow or poison the trickplay bucket key.
        // A field over 24h (86_400s) is rejected; the total must be finite and positive, clamped to a 24h ceiling.
        let maxSeconds = 86_400.0
        func field(_ rawField: Substring) -> Double? {
            guard let n = Double(rawField.trimmingCharacters(in: .whitespaces)),
                  n.isFinite, n >= 0, n <= maxSeconds else { return nil }
            return n
        }
        func finalize(_ seconds: Double) -> Double {
            guard seconds.isFinite, seconds > 0 else { return 0 }
            return min(seconds, maxSeconds)
        }
        if r.contains(":") {
            let p = r.split(separator: ":").compactMap { field($0) }
            if p.count == 3 { return finalize(p[0] * 3600 + p[1] * 60 + p[2]) }
            if p.count == 2 { return finalize(p[0] * 60 + p[1]) }
        }
        if let hRange = r.range(of: #"\d+\s*h"#, options: .regularExpression) {
            let h = Double(r[hRange].filter(\.isNumber)) ?? 0
            var mins = 0.0
            if let mRange = r.range(of: #"\d+\s*m"#, options: .regularExpression,
                                    range: hRange.upperBound..<r.endIndex) {
                mins = Double(r[mRange].filter(\.isNumber)) ?? 0
            }
            guard h <= maxSeconds, mins <= maxSeconds else { return 0 }
            return finalize(h * 3600 + mins * 60)
        }
        let minutes = Double(r.prefix { $0.isNumber }) ?? 0
        guard minutes <= maxSeconds else { return 0 }
        return finalize(minutes * 60)
    }

    /// libmpv resume START watchdog (safety net; see `libmpvResumeWatchdogSeconds`). maybeResume defers a cold
    /// pre-first-frame libmpv resume seek to the first-frame commit. If that first frame never lands - a slow or
    /// dead source, not the cold-seek wedge the deferral removes - reload the SAME source from 0 with a progress
    /// floor + a note, so the viewer keeps their resume point and can scrub forward on a warm pipeline instead of
    /// staring at a frozen timer. Cancelled the instant the first frame arrives (the timePos handler) or the view
    /// goes away, exactly like avStartWatchdog. No-op if the mount changed or the stash was already cleared.
    private func startLibmpvResumeWatchdog(target: Double) {
        libmpvResumeWatchdog?.cancel()
        let armedToken = coordinator.player?.activeLoadToken
        libmpvResumeWatchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(libmpvResumeWatchdogSeconds))
            guard !Task.isCancelled, !hasStartedPlaying,
                  pendingLibmpvResumeSeek != nil,
                  coordinator.player?.activeLoadToken == armedToken else { return }
            let sourceStillCurrent = directAVNoFrameRecovery?.url == (curURL ?? url)
                && directAVNoFrameRecovery?.episodeGeneration == episodeSwitchGeneration
                && directAVNoFrameRecovery?.sourceGeneration == sourceSwitchGeneration
            switch TVLibMPVStartupNudgePolicy.decision(
                recoveryRecorded: directAVNoFrameRecovery != nil,
                sourceStillCurrent: sourceStillCurrent,
                firstFrameRendered: hasStartedPlaying,
                nudgeAlreadyIssued: libmpvStartupNudgeIssued
            ) {
            case .cancel:
                break
            case .nudge:
                // `seek(by:)` stays on libmpv's relative-seek path and therefore avoids the absolute-seek
                // cache hold that the deferred-resume policy is protecting against. One tenth of a second is
                // imperceptible, but it asks an opened demuxer to advance and matches the field observation
                // that a manual scrub can release this exact cold-start wedge.
                libmpvStartupNudgeIssued = true
                coordinator.player?.seek(by: 0.1)
                DiagnosticsLog.log(
                    "playback",
                    "libmpv cold-resume no-frame -> one relative startup nudge; waiting 4s before source hop"
                )
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, !hasStartedPlaying,
                      coordinator.player?.activeLoadToken == armedToken else { return }
                if TVLibMPVStartupNudgePolicy.decision(
                    recoveryRecorded: directAVNoFrameRecovery != nil,
                    sourceStillCurrent: directAVNoFrameRecovery?.url == (curURL ?? url)
                        && directAVNoFrameRecovery?.episodeGeneration == episodeSwitchGeneration
                        && directAVNoFrameRecovery?.sourceGeneration == sourceSwitchGeneration
                        && directAVNoFrameRecovery?.resumeGeneration == resumeRetryGeneration
                        && directAVNoFrameRecovery?.mpvLoadToken == armedToken,
                    firstFrameRendered: hasStartedPlaying,
                    nudgeAlreadyIssued: libmpvStartupNudgeIssued
                ) == .hop {
                    handleStartTimeout()
                    return
                }
                return
            case .hop:
                handleStartTimeout()
                return
            }
            // No first frame within the deadline: abandon the deferred byte-offset seek and reload from the
            // start. Keep a progress floor at the resume point so the stored Continue Watching position is never
            // regressed and the viewer can scrub forward on a warm pipeline. Mirrors the remux `.unreachable`
            // recovery (progress floor + note) plus the existing same-source reload.
            pendingLibmpvResumeSeek = nil
            let floor = min(max(0, target), max(0, duration - 5))
            suppressedResumeFloor = floor
            lastSaved = floor
            resumeSeconds = nil   // reload from 0, not the offset that never framed
            showEngineNote("That resume point is unavailable for this source. Playing from the earliest available position.")
            DiagnosticsLog.log("playback", "resume watchdog: no first frame in \(Int(libmpvResumeWatchdogSeconds))s, falling back to start")
            retryLoad()
        }
    }

    /// Safety net for the DEFERRED resume seek issued at first frame (the warm-pipeline scrub). On a slow or
    /// non-Range source that absolute seek can leave mpv parked at the pre-seek position indefinitely (the
    /// playhead frozen at ~1s with paused-for-cache false, and the UI's currentTime optimistically pinned to
    /// the target by the in-flight guard). The plain stall ladder answers that with a same-source reload AT THE
    /// SAME OFFSET, which wedges again and re-arms the DV->HDR10 display switch every cycle (the observed
    /// Harry Potter stall loop). If the seek has not landed within 12s, abandon the offset instead: a relative
    /// +0.1s nudge (the same proven wedge release as the cold-start nudge) resumes playback from wherever the
    /// source actually is. Presentation reconciles to the first proven engine position while persistence retains
    /// the valid resume floor, because one source's failed seek must not erase Continue Watching progress.
    private func clearPostFrameResumeSeekWatchdog() {
        postFrameResumeSeekWatchdog?.cancel()
        postFrameResumeSeekWatchdog = nil
        postFrameResumeSeekWatchdogTarget = nil
        postFrameResumeSeekWatchdogOwner = nil
    }

    /// A user seek supersedes a cold-start resume seek. Without clearing the deferred target, the first-frame
    /// callback can apply the old library position after the viewer has explicitly moved elsewhere.
    private func cancelPendingLibmpvResumeForUserSeek() {
        let oldTarget = pendingLibmpvResumeSeek ?? postFrameResumeSeekWatchdogTarget
        guard let oldTarget else { return }
        pendingLibmpvResumeSeek = nil
        libmpvResumeWatchdog?.cancel()
        libmpvResumeWatchdog = nil
        if postFrameResumeSeekWatchdogTarget == oldTarget {
            clearPostFrameResumeSeekWatchdog()
        }
        // This marker belongs to the deferred resume seek, not to the user's new seek. The next real tick
        // should therefore be authoritative for the explicit destination and must not be filtered as stale.
        if inFlightSeekTarget == oldTarget { inFlightSeekTarget = nil }
    }

    private func settlePostFrameResumeSeekIfOwned(target: Double, loadToken: PlayerLoadToken) {
        guard postFrameResumeSeekWatchdogTarget == target,
              postFrameResumeSeekWatchdogOwner == loadToken else { return }
        clearPostFrameResumeSeekWatchdog()
    }

    private func armPostFrameResumeSeekWatchdog(target: Double, owner: PlayerLoadToken) {
        clearPostFrameResumeSeekWatchdog()
        postFrameResumeSeekWatchdogTarget = target
        postFrameResumeSeekWatchdogOwner = owner
        postFrameResumeSeekWatchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(postFrameResumeSeekWatchdogSeconds))
            guard !Task.isCancelled,
                  postFrameResumeSeekWatchdogTarget == target,
                  postFrameResumeSeekWatchdogOwner == owner,
                  let reconciliation = DeferredResumeSeekReconciliationPolicy.abandonment(
                    targetSeconds: target,
                    actualPositionSeconds: lastRawTimePos,
                    landingToleranceSeconds: inFlightSeekSnapRadius,
                    watchdogStillOwnsGeneration: coordinator.player?.activeLoadToken == owner
                  ) else { return }
            DiagnosticsLog.log(
                "playback",
                String(format: "deferred resume seek did not land in %ds (target %.1f, real pos %.1f): reconciling presentation while preserving the resume floor",
                       Int(postFrameResumeSeekWatchdogSeconds), target, reconciliation.presentationSeconds)
            )
            inFlightSeekTarget = nil
            pendingLibmpvResumeSeek = nil
            clearPostFrameResumeSeekWatchdog()
            currentTime = reconciliation.presentationSeconds
            suppressedResumeFloor = max(suppressedResumeFloor ?? 0, reconciliation.persistenceFloorSeconds)
            lastSaved = max(lastSaved, reconciliation.persistenceFloorSeconds)
            coordinator.player?.seek(by: 0.1)
        }
    }

    /// AVPlayer-only START watchdog. AVPlayer can mount and present its chrome yet never produce a playable
    /// frame (no item .failed, no timePos tick), so the only existing guard was the shared 30s loadTimeout,
    /// which the owner saw as ~30s of dead chrome before libmpv finally took over. If AVFoundation is the
    /// active engine and playback still has not begun after avStartWatchdogSeconds, route to the SAME libmpv
    /// fallback the .failed case uses. NOT armed for libmpv (torrents legitimately warm up far longer, which
    /// is what the 30s loadTimeout / torrent warm-up budget cover). Cancelled the moment playback starts
    /// (the timePos handler cancels loadTimeout/recoveryDeadline and clears this) or the view goes away.
    private func startAVStartWatchdog() {
        avStartWatchdog?.cancel()
        guard useAVPlayerEngine, !forceMPV, !avEngineFailed else { return }
        // HLS belongs on AVPlayer (native ABR quality selector; libmpv has no equivalent), and a slow-network
        // HLS start can legitimately take more than the short watchdog to first-frame. Never demote HLS on the
        // no-frame timer: a genuinely-dead HLS link is still recovered by AVPlayer's own .failed path. The
        // watchdog exists only for the DV/remux mount-but-never-frames case, which is never HLS.
        // T16: key the HLS exemption off the CURRENTLY-playing stream, not the immutable launch url, so an
        // in-place switch to an HLS source is exempted and a switch away from one re-arms the watchdog.
        if PlayerEngineRouter.isHLS(curURL ?? url) { return }
        avWatchdogArmedAt = Date()
        avStartWatchdog = Task { @MainActor in
            // The AVPlayer no-frame safety net (#76 b165/b166/b170, PROGRESS-AWARE since the 0.3.13 field
            // diag). Historically this lane first-framed 0% of the time on 4K debrid DV MKVs because the
            // local HLS master was rejected outright (-1002, the VIDEO-RANGE single-variant filter, now fixed
            // in VortXRemuxHLSServer with a range-unlabeled lifeboat variant). With the master accepted a
            // healthy DV remux DOES reach readyToPlay, but only after classify (3.8-8.2s) + the
            // startup-segment publish, and on a heavy/slow 4K source that whole chain can legitimately exceed
            // ANY fixed wall (the 0.3.13 device diag: still-downloading titles demoted at 20s, losing true DV
            // AND Atmos in one flip). So the remux lane no longer demotes on elapsed time alone: it polls the
            // mount's monotonic progress counters (muxed bytes, published segments, classify/init flips) at
            // ~1 Hz and only demotes on a TRUE stall (nothing moved for avRemuxStallDemoteSeconds) or at a
            // generous hard ceiling (avRemuxStartHardCeilingSeconds) that bounds the spinner for a mount that
            // trickles forever without framing. Local remuxes mount synchronously, but the external-engine path
            // publishes `isRemuxMounted` only after its async open + signalling round trip. Re-read runtime state
            // on every poll and transition when it appears; otherwise a one-shot false sample sends a healthy
            // hosted remux down the direct 10s path and tears it down as segment zero becomes ready.
            // Native/direct AVPlayer keeps the exact short deadline. Only a route expected to remux gets the
            // bounded attach grace above, after which a never-attached route still demotes. The .failed
            // instant-demote path is untouched. A working stream cancels this via the timePos handler.
            let armed = Date()
            let surfaceRemuxExpected = activeAVPlayerWouldRemux || activeAVPlayerWouldPlainRemux
            var watchedController = coordinator.player as? AVPlayerEngineController
            var watchedLoadToken = watchedController?.activeLoadToken
            var monitoringRemux = false
            var lastProgressAt = armed
            var last: VortXMKVRemuxStream.MountProgress?
            var lastHoldLogAt = armed
            while true {
                guard !Task.isCancelled, !hasStartedPlaying else { return }
                let now = Date()
                let controller = coordinator.player as? AVPlayerEngineController
                if watchedController == nil, let controller {
                    watchedController = controller
                    watchedLoadToken = controller.activeLoadToken
                }
                let ownerCurrent: Bool
                if let watchedController {
                    ownerCurrent = controller === watchedController
                        && watchedLoadToken != nil
                        && controller?.activeLoadToken == watchedLoadToken
                } else {
                    ownerCurrent = true
                }
                let remuxSignal = controller?.remuxStartupSignal
                let mountedNow = remuxSignal?.mounted == true
                let remuxExpectedNow = surfaceRemuxExpected
                    || (remuxSignal?.pendingOrMounted == true)
                let elapsed = now.timeIntervalSince(armed)
                let awaitingDecision = TVAVStartWatchdogPolicy.awaitingMountDecision(
                    elapsed: elapsed,
                    ownerCurrent: ownerCurrent,
                    remuxMounted: mountedNow,
                    remuxExpected: remuxExpectedNow,
                    directTimeout: avStartWatchdogSeconds,
                    remuxAttachTimeout: avRemuxAttachWatchdogSeconds
                )
                if awaitingDecision == .cancel { return }
                if !monitoringRemux {
                    switch awaitingDecision {
                    case .cancel:
                        return
                    case .keepWaiting:
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    case .monitorRemux:
                        monitoringRemux = true
                        lastProgressAt = now
                        last = controller?.remuxMountProgress
                        DiagnosticsLog.log(
                            "dv",
                            "start watchdog transitioned to progress-aware remux monitoring "
                                + "(attached after \(String(format: "%.1f", elapsed))s)")
                    case .demote:
                        // Before SwiftUI has installed the AV controller there is nothing to demote. This
                        // matches the old fixed path's post-sleep active-engine guard.
                        guard isAVPlayerActive else { return }
                        let reason = remuxExpectedNow
                            ? "expected remux did not attach within \(Int(avRemuxAttachWatchdogSeconds))s"
                            : "direct AVPlayer produced no frame within \(Int(avStartWatchdogSeconds))s"
                        DiagnosticsLog.log(
                            "player",
                            "AVPlayer start watchdog demoting (\(reason)), falling back to libmpv")
                        DiagnosticsLog.log(
                            "playback",
                            "source attempt route=\(remuxExpectedNow ? "avplayer-remux" : "avplayer-direct") "
                                + "outcome=no-first-frame headers=\(safeHeaderReceipt(curHeaders)) next=retire")
                        demoteAVPlayerToMPV()
                        return
                    }
                }
                guard isAVPlayerActive else { return }   // already on libmpv (or torn down): nothing to demote
                if let cur = controller?.remuxMountProgress {
                    // Progress = any monotonic counter moved since the last poll. A FAILED mount never counts
                    // as progress; its demote belongs to the HLS-404 -> .failed path, and if that somehow
                    // never fires the stall window below still bounds it.
                    let progressed = last.map { prev in
                        cur.producedBytes > prev.producedBytes
                            || cur.segmentCount > prev.segmentCount
                            || (cur.initPublished && !prev.initPublished)
                            || (cur.signalingPublished && !prev.signalingPublished)
                            || (cur.ended && !prev.ended)
                            // Input liveness is progress too: during avformat_open_input (a 10s rw_timeout) plus
                            // find_stream_info nothing has been MUXED yet, so the output counters above all sit
                            // at zero while the source is still legitimately opening. Count growing input bytes
                            // so a slow-but-alive open does not accrue the stall window and get demoted blind.
                            || ((cur.inputBytesRead ?? 0) > (prev.inputBytesRead ?? 0))
                    } ?? true
                    if progressed, !cur.failed { lastProgressAt = now }
                    last = cur
                }
                // A producer failure is terminal evidence, not a stalled/progressing sample. Handle it on
                // the first owned poll so a failed remux cannot sit in the old watchdog hold (log13 showed
                // failed=true, produced=0 held for 15s). Dead input hops immediately; a remux/mux failure
                // with input evidence keeps the existing same-source AV -> libmpv fallback.
                if let terminal = last {
                    switch AppleRemuxRecoveryPolicy.terminalDecision(
                        failed: terminal.failed,
                        inputProvablyDead: terminal.inputProvablyDead,
                        ownerCurrent: ownerCurrent,
                        hasStartedPlaying: hasStartedPlaying
                    ) {
                    case .cancel:
                        break
                    case .hopSource:
                        let inputReceipt = terminal.inputBytesRead.map(String.init) ?? "-"
                        DiagnosticsLog.log(
                            "dv",
                            "remux terminal failure -> source hop (\(terminal.producedBytes)B output, input=\(inputReceipt))"
                        )
                        if hopToNextSource(reason: "remux terminal failure") { return }
                        DiagnosticsLog.log("dv", "remux terminal failure had no source hop; demoting engine")
                        demoteFollowedDeadInput = true
                        demoteAVPlayerToMPV()
                        return
                    case .demoteEngine:
                        DiagnosticsLog.log("dv", "remux terminal failure -> libmpv demote")
                        demoteAVPlayerToMPV()
                        return
                    }
                }
                let stalled = now.timeIntervalSince(lastProgressAt)
                // W2-A: the input-side receipts ride the same line as the output counters, so the exportable
                // trail shows WHY a stall was called dead (or not) instead of only that it was called.
                let inBytes: String = {
                    guard let bytes = last.flatMap({ $0.inputBytesRead }) else { return "-" }
                    return "\(bytes)"
                }()
                let state = "produced=\(last?.producedBytes ?? -1)B segs=\(last?.segmentCount ?? -1) init=\(last?.initPublished ?? false) classify=\(last?.signalingPublished ?? false) failed=\(last?.failed ?? false) inBytes=\(inBytes) inOpen=\(last?.inputOpened ?? false) inOpening=\(last?.inputOpenInFlight ?? false)"
                // A stall while an input open is still in flight is not a true stall: the source is legitimately
                // blocked inside avformat_open_input / find_stream_info and has produced no output yet. Do not
                // demote on that; the hard ceiling below still bounds a source that stays inOpening forever, so
                // a genuinely dead source always fails soft to libmpv eventually.
                let trueStall = stalled >= avRemuxStallDemoteSeconds && !(last?.inputOpenInFlight ?? false)
                if trueStall || elapsed >= avRemuxStartHardCeilingSeconds {
                    let why = trueStall
                        ? "TRUE STALL, no remux progress for \(Int(stalled))s"
                        : "hard ceiling \(Int(avRemuxStartHardCeilingSeconds))s with no playable frame"
                    // W2-A item 2: a demote is an ENGINE-level fallback that re-loads the SAME url on libmpv. It
                    // is the right answer when AVFoundation cannot demux a healthy source, and the WRONG one when
                    // the shared upstream fetch delivered nothing at all: libmpv cannot help with bytes that were
                    // never sent, so the session pays another full timeout before anything hops. Branch to a
                    // SOURCE-level failure only on the narrow, positively-evidenced case (`inputProvablyDead`:
                    // zero input bytes, no completed open, no open attempt still running). Every other shape -
                    // any input byte, an open that succeeded, a warm retry still in flight, a delivery that
                    // reports no input receipts at all - keeps today's demote. MIS-260731-03: any doubt fails
                    // open, because a hop is strictly more destructive than a demote (it spends one of four
                    // source hops, writes the url into exhaustedURLs and books a provider penalty).
                    // hopToNextSource is the single choke point that already does all of that bookkeeping.
                    let inputDead = stalled >= avRemuxStallDemoteSeconds && last?.inputProvablyDead == true
                    if inputDead {
                        DiagnosticsLog.log(
                            "dv",
                            "remux input dead (no input bytes, no open, none in flight) -> source hop instead of "
                                + "an engine demote (\(state))")
                        if hopToNextSource(reason: "remux input dead") { return }
                        DiagnosticsLog.log(
                            "dv",
                            "remux input dead but no source hop was issued; falling back to the engine demote")
                    }
                    DiagnosticsLog.log("player", "AVPlayer start watchdog demoting (remux mounted=true, \(why), elapsed=\(Int(elapsed))s, \(state)), falling back to libmpv")
                    // The [dv] demote reason for the exportable trail: this is the exact edge that turns a DV
                    // + Atmos session into HDR10 + multichannel PCM, so name it explicitly.
                    DiagnosticsLog.log("dv", "remux demoted: \(why) -> libmpv HDR10")
                    // Carry the dead-input verdict INTO the demote: only a leg whose upstream provably delivered
                    // nothing pays the shortened post-demote budget (this is the hop-was-refused fallback, so the
                    // same url is about to be handed to libmpv). Every other demote keeps the full 30s.
                    demoteFollowedDeadInput = inputDead
                    demoteAVPlayerToMPV()
                    return
                }
                // Past the old fixed wall and still holding: say WHY (progress is flowing), every ~10s, so
                // the next device log shows extend-vs-demote decisions instead of a silent gap.
                if elapsed >= avRemuxStartWatchdogSeconds, now.timeIntervalSince(lastHoldLogAt) >= 10 {
                    lastHoldLogAt = now
                    DiagnosticsLog.log("dv", "start watchdog holding: remux progressing (elapsed=\(Int(elapsed))s, quiet=\(Int(stalled))s, \(state))")
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Arm the overall pre-start recovery cap once per attempt. Idempotent: a hop calls
    /// startLoadTimeout again, but the deadline keeps running so the whole sequence is bounded.
    /// Reset (cancelled to nil) on a deliberate fresh pick and on playback actually starting.
    private func startRecoveryDeadline() {
        guard recoveryDeadline == nil else { return }
        recoveryDeadline = Task { @MainActor in
            try? await Task.sleep(for: .seconds(maxRecoverySeconds))
            guard !Task.isCancelled, !hasStartedPlaying, !loadFailed else { return }
            DiagnosticsLog.log("player", "recovery deadline \(Int(maxRecoverySeconds))s reached after \(sourceHops) hops, giving up")
            loadTimeout?.cancel(); autoRetryTask?.cancel(); stallWatchdog?.cancel()
            if loadErrorMsg.isEmpty { loadErrorMsg = "Couldn't start playback after trying several sources." }
            presentTerminalLoadFailure()
        }
    }

    /// What another device can actually use: the stream URL for direct and debrid
    /// links, a magnet rebuilt from the info hash for torrents (the local server
    /// URL is meaningless off this Apple TV).
    private var shareLink: String? {
        guard let u = curURL else { return nil }
        if isTorrentPlayback {
            let hash = u.pathComponents.count >= 2 ? u.pathComponents[1] : ""
            guard hash.count == 40 else { return nil }
            return "magnet:?xt=urn:btih:\(hash)"
        }
        return u.absoluteString
    }

    /// Decided by the URL shape alone ({server}:11470/{40-hex-hash}/{idx}), which
    /// every torrent URL has and nothing else does; the launch-path flag can go
    /// stale across engine-resolved episode switches, so it is only recorded, not
    /// trusted here.
    private var isTorrentPlayback: Bool {
        // A torrent mount also carries the file index, so the route must have BOTH components; the hash test
        // itself lives in the shared classifier so this and `currentTorrentHash` cannot drift apart.
        guard let u = curURL, u.pathComponents.count >= 3 else { return false }
        return streamingServerTorrentHash(of: u) != nil
    }

    /// The 40-hex info-hash a streaming-server torrent route carries at `/{hash}/…`, or nil when the URL is not
    /// that shape or is not served by a streaming server this app owns. THE one classifier for "is this mount a
    /// torrent": `isTorrentPlayback` and `currentTorrentHash` both read it, so they cannot disagree again - and
    /// they did, which is how a port drift made `leavePlayback` skip `closeTorrent` and leak the swarm that
    /// `currentTorrentHash`'s own comment warns about.
    ///
    /// Matched by HOST for loopback, not by port. The original concern was a hardcoded 11470 (server.js silently
    /// drifts to 11471-11474 on EADDRINUSE), and following `StremioServer.embeddedPort` fixed that - but the
    /// in-process engine server rebinds a FRESH ephemeral port on every foreground start, so after one background
    /// cycle the LIVE port no longer matches the port baked into a still-mounted torrent URL. That made a
    /// stale-port torrent answer "not a torrent", which skipped `warmUpTorrent()` and drove the dead loopback URL
    /// down the direct-link ladder instead (diag-21). Loopback host + the 40-hex route is the part of the shape
    /// that cannot drift, and nothing but a torrent mount has it. A custom/remote streaming server serves the
    /// same route off its own host and its port never drifts, so that one is still matched exactly.
    private func streamingServerTorrentHash(of u: URL?) -> String? {
        guard let u, u.pathComponents.count >= 2 else { return nil }
        let hash = u.pathComponents[1]
        guard hash.count == 40, hash.allSatisfy(\.isHexDigit) else { return nil }
        if isLoopback(u) { return hash }
        guard let serverBase = URL(string: StremioServer.base),
              u.host == serverBase.host, u.port == serverBase.port else { return nil }
        return hash
    }

    /// What official Stremio does that a bare mpv open does not: wait for the
    /// torrent engine. A cold swarm needs tens of seconds before its first useful
    /// bytes (22s TTFB measured on a WELL-seeded torrent), and early reads come
    /// back truncated, so mpv fails its demux instantly and the quick auto-retries
    /// burn out in seconds. Poll the engine's stats until a few MB are actually
    /// down, narrating peer count and speed, then hand mpv the URL again.
    private func warmUpTorrent() {
        guard torrentWarmupsUsed < 2, let u = curURL, u.pathComponents.count >= 2 else {
            reconnecting = false; torrentStatus = nil
            if hopToNextSource(reason: "torrent warm-up exhausted") { return }
            if loadErrorMsg.isEmpty { loadErrorMsg = "The torrent never started sending data. Try another source." }
            presentTerminalLoadFailure()
            return
        }
        torrentWarmupsUsed += 1
        let hash = u.pathComponents[1]
        buffering = true
        withAnimation { reconnecting = true }
        torrentStatus = "Starting torrent…"
        plog.info("torrent warm-up round \(torrentWarmupsUsed) for \(hash, privacy: .public)")
        DiagnosticsLog.log("player", "torrent warm-up round \(torrentWarmupsUsed) for \(hash)")
        loadTimeout?.cancel()
        autoRetryTask?.cancel()
        autoRetryTask = Task { @MainActor in
            let deadline = Date().addingTimeInterval(90)
            var warm = false
            while Date() < deadline, !Task.isCancelled, !hasStartedPlaying {
                if let stats = await Self.torrentStats(hash: hash) {
                    DiagnosticsLog.log("torrent", "stats \(hash.prefix(8)): peers=\(stats.peers ?? -1) conn=\(stats.swarmConnections ?? -1) tries=\(stats.connectionTries ?? -1) searching=\(String(describing: stats.peerSearchRunning)) down=\(Int(stats.downloaded ?? -1)) speed=\(Int(stats.downloadSpeed ?? -1))")
                    let peers = stats.swarmConnections ?? stats.peers ?? 0
                    let speed = stats.downloadSpeed ?? 0
                    var line = "Connecting to peers · \(peers) connected"
                    if speed > 10_000 { line += String(format: " · %.1f MB/s", speed / 1_048_576) }
                    torrentStatus = line
                    if (stats.downloaded ?? 0) > 3_000_000 { warm = true; break }   // a few MB down = mpv can demux
                }
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled, !hasStartedPlaying else { torrentStatus = nil; return }
            torrentStatus = nil
            if warm {
                plog.info("torrent warm, handing back to mpv")
                DiagnosticsLog.log("player", "torrent warm, reloading")
                retryLoad(resetAutoRetries: true)
            } else {
                loadErrorMsg = "The torrent never started sending data. Try another source."
                reconnecting = false
                presentTerminalLoadFailure()
            }
        }
    }

    private struct TorrentStats: Decodable {
        let peers: Int?
        let swarmConnections: Int?
        let connectionTries: Int?
        let peerSearchRunning: Bool?
        let downloaded: Double?
        let downloadSpeed: Double?
    }

    private static func torrentStats(hash: String) async -> TorrentStats? {
        guard let url = URL(string: "\(StremioServer.base)/\(hash)/stats.json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode(TorrentStats.self, from: data)
    }

    /// Re-resolve one fresh URL for the active native-debrid source. This is intentionally the sole owner of
    /// same-source provider recovery for pre-play failure, mid-play failure, foreground reconciliation, and a
    /// user engine switch made while a source is reconnecting. It never changes the semantic stream or failure
    /// bookkeeping: source hops and exhausted URLs remain owned by the caller that decides the refresh failed.
    ///
    /// A fresh URL is accepted only when the original episode/source/retry generation, player token, metadata,
    /// provider reference, stream identity, and URL are all still current. A late provider answer after a user
    /// source or engine switch is therefore inert rather than resurrecting stale audio/subtitle/position state.
    @discardableResult
    private func recoverCurrentNativeDebridLink(
        reason: String,
        requestedEngine: Bool? = nil
    ) -> Bool {
        if nativeDebridFreshLinkRecovery.freshLinkInFlight {
            if let requestedEngine {
                _ = nativeDebridFreshLinkRecovery.joinEngineSwitch(requestedEngine)
            }
            return true
        }
        let retryRef = pendingAdvance?.debridRef ?? curDebridRef
        let retryMeta = pendingAdvance?.meta ?? curMeta
        let retrySource = curSourceStream
        guard !nativeDebridFreshLinkRecovery.freshLinkUsed,
              let ref = retryRef else { return false }
        let isUsenetRecovery = ref.usenetRoute != nil && retrySource?.isUsenet == true
        guard !ref.infoHash.isEmpty || isUsenetRecovery else { return false }
        // Do not infer NNTP provenance from a loopback hostname or reuse an outgoing episode's route.
        if isUsenetRecovery, ref.url != curURL { return false }
        let hint = episodeHint(for: retryMeta)
        let retryRequiresSemanticSelection = isEpisodePlaybackContext
        let hasExactProviderIDs = ref.service == .torBox && ref.torrentId != nil && ref.fileId != nil
        // Raw fileIdx is not a provider-array selector. Missing semantic identity may try only TorBox's exact
        // provider-ID path; the resolver closes before any re-add if that fast path fails.
        if retryRequiresSemanticSelection, hint == nil, !hasExactProviderIDs { return false }
        resumeRetryGeneration &+= 1
        let generation = resumeRetryGeneration
        let targetVideoID = retryMeta?.videoId
        let retryURL = curURL
        let retryToken = coordinator.player?.activeLoadToken
        let retryEpisodeGeneration = episodeSwitchGeneration
        let retrySourceGeneration = sourceSwitchGeneration
        let resume = max(currentTime, suppressedResumeFloor ?? (resumeSeconds ?? 0))
        let pausedIntent = isPaused
        captureRecoverySelections()
        queueIncomingTransportIntent(paused: pausedIntent)
        guard let recoveryID = nativeDebridFreshLinkRecovery.beginFreshLink(requestedEngine: requestedEngine) else {
            return false
        }
        resumeSourceReresolved = true
        withAnimation { reconnecting = true }
        autoRetryTask?.cancel()
        autoRetryTask = Task { @MainActor in
            // Every return below, including cooperative cancellation and a generation/token ownership fence,
            // must retire only THIS request. Otherwise a late first frame can cancel this task and strand the
            // source forever in an in-flight state that all later recovery/engine-switch attempts merely join.
            defer { _ = nativeDebridFreshLinkRecovery.retireFreshLink(ownedBy: recoveryID) }
            let resolvedRef: DebridPlaybackRef?
            if isUsenetRecovery, let retrySource {
                resolvedRef = try? await DebridCoordinator.shared.recoverUsenetPlayback(
                    for: retrySource, previous: ref, episode: hint
                )
            } else {
                let fresh = try? await DebridCoordinator.shared.reresolve(
                    service: ref.service, infoHash: ref.infoHash,
                    torrentId: ref.torrentId, fileId: ref.fileId, fileIdx: ref.fileIdx,
                    episode: hint, requiresSemanticSelection: retryRequiresSemanticSelection)
                resolvedRef = fresh.map {
                    DebridPlaybackRef(url: $0, service: ref.service, infoHash: ref.infoHash,
                                      torrentId: ref.torrentId, fileId: ref.fileId, fileIdx: ref.fileIdx)
                }
            }
            let activeMeta = pendingAdvance?.meta ?? curMeta
            let activeRef = pendingAdvance?.debridRef ?? curDebridRef
            guard !Task.isCancelled, !leftPlayback,
                  EpisodePlaybackIdentity.asyncMediaResultIsCurrent(
                    capturedGeneration: generation, currentGeneration: resumeRetryGeneration,
                    capturedVideoID: targetVideoID, currentVideoID: activeMeta?.videoId
                  ),
                  retryEpisodeGeneration == episodeSwitchGeneration,
                  retrySourceGeneration == sourceSwitchGeneration,
                  coordinator.player?.activeLoadToken == retryToken,
                  activeRef == ref, curURL == retryURL, curSourceStream == retrySource else { return }
            guard let recoveryCompletion = nativeDebridFreshLinkRecovery.finishFreshLink(ownedBy: recoveryID) else {
                return
            }
            if let freshRef = resolvedRef {
                let fresh = freshRef.url
                DiagnosticsLog.log("player", "native-debrid fresh-link accepted service=\(ref.service) reason=\(safeFailureClass(reason)) generation=\(generation)")
                reconnecting = false
                curURL = fresh
                // A native-debrid URL is a provider-owned transport boundary. The original add-on headers may
                // contain credentials scoped to a different origin, and DebridCoordinator currently returns no
                // provider-scoped replacement headers. Never forward those credentials across this handoff.
                curHeaders = nil
                if pendingAdvance != nil {
                    pendingAdvance?.url = fresh
                    pendingAdvance?.debridRef = freshRef
                } else {
                    curDebridRef = freshRef
                }
                if let target = retryMeta, let source = curSourceStream {
                    enginePlayerVideoId = bindEngine(
                        to: source, meta: target, resolvedURL: fresh
                    )
                }
                resumeSeconds = resume
                if let requestedEngine = recoveryCompletion.requestedEngine {
                    // `engineSurfacePlayback` seeds the next SwiftUI controller with this fresh URL. The
                    // actual mount remains owned by the normal switch transaction, which preserves all
                    // stop-before-swap and token fencing guarantees.
                    engineSurfaceURLOverride = fresh
                    engineSurfaceHeadersOverride = curHeaders
                    performPlayerEngineSwitch(
                        toAVPlayer: requestedEngine,
                        preservingNativeDebridRecoveryGeneration: true
                    )
                } else {
                    coordinator.player?.invalidateLoadToken()
                    hasStartedPlaying = false; buffering = true; appliedVolume = false; appliedSize = false
                    appliedResume = false; pendingLibmpvResumeSeek = nil; loadErrorMsg = ""
                    autoRetryCount = 0; bufferGraceUsed = 0; lastBufferedAtWatchdog = -1
                    let issuedToken = loadIntoPlayer(fresh, headers: curHeaders, live: curIsLive,
                                                     resumeOrigin: resume)
                    if pendingAdvance != nil { pendingAdvance?.loadToken = issuedToken }
                    if issuedToken != nil { startLoadTimeout() }
                }
            } else {
                // The source's semantic provider selection is genuinely unavailable. Keep the one-refresh
                // receipt, then let the original caller honor explicit-pick terminal behavior or auto-hop.
                DiagnosticsLog.log("player", "native-debrid fresh-link unavailable service=\(ref.service) reason=\(safeFailureClass(reason)) generation=\(generation)")
                reconnecting = false
                if currentPickWasExplicit {
                    if loadErrorMsg.isEmpty { loadErrorMsg = "This source didn't load. Choose another source." }
                    presentTerminalLoadFailure()
                } else if !hopToNextSource(reason: "native debrid source unavailable", resumeOverride: resume) {
                    presentTerminalLoadFailure()
                }
            }
        }
        return true
    }

    /// Compatibility spelling retained for source-contract consumers. It delegates to the generalized owner,
    /// so Continue Watching no longer owns a distinct recovery path.
    private func retryResumeSameSource() -> Bool {
        recoverCurrentNativeDebridLink(reason: "resume")
    }

    /// MID-PLAY libmpv FAILURE (diag-21). Before wave-1 this fell off the end of the endFileError switch with
    /// no owner at all: `handleLoadFailure` is gated on `!hasStartedPlaying`, and so are the start watchdog and
    /// the recovery deadline, so the only thing left was the 6s-poll stall watchdog - three frozen ticks (~18s)
    /// before it reloaded, and it reloaded the same URL verbatim. A background-resume death, an expired debrid
    /// link mid-episode and a server that moved port all land here, and all of them have a real recovery behind
    /// `handleLoadFailure` (auto-retry -> same-source re-resolve -> failover hop -> fresh-sources wait).
    /// Preserve where the viewer was, clear the started flag so the ladder can admit, and hand it over.
    ///
    /// BOUNDED PER MOUNT by `midPlayRecoveryCount`, because `handleLoadFailure`'s own budgets cannot bound this
    /// lane: a retry that reaches even one frame clears `autoRetryCount` AND `recoveryDeadline` at first frame,
    /// so a source that frames for a tick and re-dies replenishes everything it just spent and loops at roughly
    /// a reload a second, forever (a truncated file; a debrid link that 403s after its first range). Past the
    /// cap the SOURCE is the problem rather than the load, so hop instead - bounded in turn by `sourceHops`,
    /// and ending on the error overlay.
    ///
    /// Live streams never reach here: their reconnect lane is owned by `scheduleLiveStreamReconnect` off the
    /// EOF path, and widening this into it is not the fix.
    private func handleMidPlayFailure(_ failureMessage: String, loadToken: PlayerLoadToken?) {
        // Once per load, and FAIL-CLOSED on a missing token: with no token this cannot tell a second error on
        // the same mount from a first one on a fresh mount, and doing nothing is exactly the pre-wave-1
        // behavior for a mid-play error, so the unprovable case costs no regression.
        guard let failureOwner = loadToken ?? coordinator.player?.activeLoadToken,
              midPlayFailureOwner != failureOwner else { return }
        midPlayFailureOwner = failureOwner
        let resume = max(currentTime, suppressedResumeFloor ?? 0)   // R9 floor: never restart below the play head
        midPlayRecoveryCount += 1
        resumeSeconds = resume
        resumeIsMidPlayRecovery = true   // a live play head, not a stored offset: maybeResume must honor it near the end
        hasStartedPlaying = false
        guard midPlayRecoveryCount <= maxMidPlayRecoveries else {
            DiagnosticsLog.log(
                "player",
                "mid-play endFileError class=\(safeFailureClass(failureMessage)) x\(midPlayRecoveryCount) on one mount -> hop instead of another reload, at \(Int(resume))s"
            )
            loadErrorMsg = failureMessage
            reconnecting = false
            if !hopToNextSource(reason: "mid-play failure budget spent", resumeOverride: resume) {
                presentTerminalLoadFailure()
            }
            return
        }
        DiagnosticsLog.log(
            "player",
            "mid-play endFileError class=\(safeFailureClass(failureMessage)) -> recovery ladder at \(Int(resume))s (\(midPlayRecoveryCount)/\(maxMidPlayRecoveries))"
        )
        handleLoadFailure(failureMessage)
    }

    private func handleLoadFailure(_ msg: String) {
        guard !hasStartedPlaying, !loadFailed else { return }
        loadErrorMsg = msg
        if isTorrentPlayback {
            // The engine simply isn't warm yet; quick mpv retries just burn out.
            warmUpTorrent()
            return
        }
        if isCurrentLiveStream {
            scheduleLiveStreamReconnect(reason: "load failure: \(msg)")
            return
        }
        if DVPlaybackPolicy.isSourceCapabilityMismatch(msg) {
            reconnecting = false
            if recoverCurrentNativeDebridLink(reason: msg) { return }
            if currentPickWasExplicit && !currentPlaybackIsResume {
                presentTerminalLoadFailure()
                return
            }
            if hopToNextSource(reason: msg) { return }
            presentTerminalLoadFailure()
            return
        }
        guard autoRetryCount < maxAutoRetries else {
            reconnecting = false
            // Honor an explicit user pick: a hard failure after the in-place retries surfaces a clear
            // "choose another source" error instead of silently hopping to a different (often lower-quality)
            // source. Only the auto path (Watch Now) dead-ends this way. A Continue-Watching RESUME is NOT a
            // manual pick: its stored debrid link expires, so a hard failure must fall through to the failover
            // hop + fresh-sources wait below (get the viewer watching) rather than dead-ending on the overlay.
            if recoverCurrentNativeDebridLink(reason: msg) { return }
            if currentPickWasExplicit && !currentPlaybackIsResume {
                if loadErrorMsg.isEmpty {
                    loadErrorMsg = curIsMediaServer
                        ? "This file's format can't direct-play on this device yet. Server transcoding isn't supported in this version."
                        : "This source didn't load. Choose another source."
                }
                presentTerminalLoadFailure()
                return
            }
            // The single native-debrid fresh-link chance was consumed above. If it could not prove a usable
            // replacement, the existing explicit terminal / auto-hop policy owns the next step.
            if hopToNextSource(reason: "load failed: \(msg)") { return }
            // CW-resume of a debrid/direct stream whose stored link expired (debrid URLs are time-limited):
            // HomeView.directResume kicks off a background reload of the title's streams, but they may not
            // have arrived yet. Wait briefly for them and retry the hop to a FRESH source, rather than
            // dead-ending on the "sources didn't load" overlay. One wait-cycle per playback, non-torrent only.
            if curMeta != nil, !isTorrentPlayback, !awaitedFreshSources {
                awaitedFreshSources = true
                withAnimation { reconnecting = true }
                autoRetryTask?.cancel()
                autoRetryTask = Task { @MainActor in
                    for _ in 0 ..< 16 {   // up to ~4s for the background stream load to land
                        try? await Task.sleep(for: .milliseconds(250))
                        if Task.isCancelled { return }
                        if hopToNextSource(reason: "fresh sources after wait") { reconnecting = false; return }
                    }
                    reconnecting = false
                    presentTerminalLoadFailure()
                }
                return
            }
            presentTerminalLoadFailure()
            return
        }
        autoRetryCount += 1
        buffering = true
        withAnimation { reconnecting = true }
        autoRetryTask?.cancel()
        autoRetryTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(autoRetryBackoff))
            guard !Task.isCancelled, !hasStartedPlaying else { return }
            retryLoad(resetAutoRetries: false)
        }
    }

    /// Reload the current stream. Manual retries and fresh loads reset the auto-recovery budget; the
    /// auto-retry path passes `false` so its bounded count keeps counting down toward the overlay.
    private func retryLoad(resetAutoRetries: Bool = true) {
        if resetAutoRetries { autoRetryCount = 0; reconnecting = false; bufferGraceUsed = 0; lastBufferedAtWatchdog = -1; recoveryDeadline?.cancel(); recoveryDeadline = nil }
        autoRetryTask?.cancel()
        clearPostFrameResumeSeekWatchdog()
        captureRecoverySelections()
        let resume = hasStartedPlaying ? currentTime : (resumeSeconds ?? 0)
        avToMPVHandoffBlocked = false
        withAnimation { loadFailed = false }
        bufferedTime = 0   // reload: clear the buffered-ahead band until the demuxer re-reports
        buffering = true; hasStartedPlaying = false; appliedResume = false; appliedAutoTracks = false; autoAddonSubTried = false; userPickedSubtitle = false; addonSubsResolveTried = false; appliedVolume = false; appliedSize = false; loadErrorMsg = ""; pendingLibmpvResumeSeek = nil
        subtitleLoadingURL = nil   // self-heal: a subtitle load stranded by the old engine must not gate the reload's picks
        let previousURL = curURL
        let replacementURL = liveMountURL()
        prepareRawTorrentAfterLoopbackRebind(from: previousURL, to: replacementURL)
        curURL = replacementURL   // self-heal a drifted embedded-server port before replaying the mount
        loadIntoPlayer(curURL ?? url, headers: curHeaders, live: isCurrentLiveStream,
                       resumeOrigin: resume)
        startLoadTimeout()
    }

    /// Live HLS providers sometimes surface a transient playlist reload failure as EOF
    /// instead of an mpv error. For VOD EOF means "finished"; for live streams it means
    /// reconnect to the playlist rather than marking watched and closing the player.
    private func handleLiveStreamEOF() -> Bool {
        guard isCurrentLiveStream else { return false }
        scheduleLiveStreamReconnect(reason: "EOF")
        return true
    }

    private func scheduleLiveStreamReconnect(reason: String) {
        buffering = true
        withAnimation { reconnecting = true }
        plog.info("live stream \(reason, privacy: .public), reconnecting")
        DiagnosticsLog.log("player", "live stream \(reason), reconnecting")
        autoRetryTask?.cancel()
        autoRetryTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            retryLoad(resetAutoRetries: false)
        }
    }

    /// Pull external subtitles for the playing title from the account's subtitle add-ons,
    /// once per episode. Movies query by their id; episodes by id:season:episode.
    private func fetchAddonSubtitles() {
        guard let m = curMeta else { return }
        // Subtitle add-ons come from the ENGINE's installed set (`core.addons`, the source of truth since VortX
        // went account-primary), unioned with the legacy Stremio collection (`account.addons`) as a fallback.
        // Reading account.addons alone showed NO add-on subtitles on a VortX-primary device (#148). Both load
        // async, so latching an empty union here would hide add-on subtitles for the whole session: bail before
        // touching the key so a later call (playback start / panel open) fetches once the add-ons have arrived.
        let sources = SubtitleAddonService.installedSources(engine: core.addons, account: account.addons)
        guard !sources.isEmpty else { return }
        // A hub / TMDB-catalog play carries a `tmdb:` library id that OpenSubtitles-class add-ons cannot answer,
        // so the raw id returns nothing and add-on subtitles never appear. Resolve tmdb -> tt ONCE (the same
        // persistent trickplay resolver), then re-enter with the tt id. A failed resolve falls through to the
        // raw-id path below exactly once (= today's behavior); addonSubsResolveTried keeps it loop-proof.
        if m.libraryId.lowercased().hasPrefix("tmdb:"),
           CommunityTrickplay.cachedIMDbID(for: m.libraryId) == nil,
           !addonSubsResolveTried {
            addonSubsResolveTried = true
            Task { @MainActor in
                _ = await CommunityTrickplay.resolveIMDbID(rawId: m.libraryId, seriesHint: m.season != nil)
                fetchAddonSubtitles()      // cache hit now, or raw-id fallback below exactly once
                fetchPooledSubtitles()     // re-key the pooled path under the resolved identity (see communityContentKey)
            }
            return
        }
        // Rewrite the tmdb: prefix of the query id to the resolved tt id when we have one; all other ids pass
        // through unchanged. "tmdb:456:1:2" -> "tt789:1:2".
        let effectiveVideoId: String = {
            guard m.libraryId.lowercased().hasPrefix("tmdb:"),
                  let tt = CommunityTrickplay.cachedIMDbID(for: m.libraryId),
                  m.videoId.hasPrefix(m.libraryId) else { return m.videoId }
            return tt + m.videoId.dropFirst(m.libraryId.count)
        }()
        let key = "\(m.type):\(effectiveVideoId)"
        guard key != addonSubsKey else { return }
        addonSubsKey = key
        addonSubs = []
        addedSubURLs = []
        Task { @MainActor in
            let subs = await SubtitleAddonService.fetch(sources: sources, type: m.type, videoId: effectiveVideoId)
            guard addonSubsKey == key else { return }   // episode changed / re-keyed mid-fetch
            addonSubs = subs
            if showOptions, panelShowsSubtitleList { refreshPanelRowsPreservingAccessibilityFocus() }
            // The add-on list can land AFTER autoSelectTracks already ran (and left subs off because the
            // container had no chain match): re-evaluate the add-on fallback now that candidates exist.
            autoSelectAddonSubtitleIfNeeded()
        }
    }

    /// Auto-load an ADD-ON subtitle in the user's preferred language when the container itself has none.
    /// The embedded auto-select (autoSelectTracks) already honors the preference chain for EMBEDDED tracks;
    /// this is the missing half: a title whose file carries no track in the chain used to end "subs selected
    /// off (auto)" even when an installed subtitle add-on had the language. Fires at most once per load
    /// (latched), never overrides an already-selected track or a manual pick, respects the off/forced-only
    /// policies via TrackSelector.wantsExternalSubtitle, and fails soft: a download failure just leaves
    /// subtitles off exactly as before.
    private func autoSelectAddonSubtitleIfNeeded() {
        guard appliedAutoTracks, !autoAddonSubTried, !userPickedSubtitle,
              !(addonSubs.isEmpty && pooledSubs.isEmpty), subtitleLoadingURL == nil else { return }
        // Whether to pull an add-on sub is decided ENTIRELY by wantsExternalSubtitle (does any EMBEDDED track
        // match the preferred language chain). A stale or off-chain embedded selection must NOT short-circuit
        // this: a default English track being auto-selected while the viewer wants Turkish was latching the
        // add-on fetch off, missing the exact case the feature exists for. wantsExternalSubtitle already keeps
        // a real chain match (returns false) and respects the off / forced-only policies.
        let prefs = TrackPreferences.current
        guard TrackSelector.wantsExternalSubtitle(audio: audioTracks, subtitles: subtitleTracks, preferences: prefs) else {
            autoAddonSubTried = true
            return
        }
        // Tier 1 - installed subtitle add-ons. Walk the preference chain in priority order (same tolerant
        // language match the embedded selector uses, so "tur"/"tr-TR" still hit a "tr" preference).
        var pick: AddonSubtitle?
        for lang in prefs.subtitleLanguages {
            if let s = addonSubs.first(where: { TrackSelector.matches($0.lang, lang) }) { pick = s; break }
        }
        if let sub = pick {
            // Bind the engine BEFORE latching anything: in the engine demote/switch render gap
            // `coordinator.player` is nil, and an optional-chained call would swallow the completion,
            // stranding `subtitleLoadingURL` (every later pick then silently no-ops). Returning WITHOUT
            // latching `autoAddonSubTried` lets the next list/track completion retry on the live engine.
            guard let player = coordinator.player else { return }
            autoAddonSubTried = true
            subtitleLoadingURL = sub.url
            let subtitleLoadToken = player.activeLoadToken
            let subtitleVideoID = curMeta?.videoId
            player.addExternalSubtitle(url: sub.url, title: sub.addonName, lang: sub.lang) { ok in
                guard permitsSubtitlePublication(loadToken: subtitleLoadToken, videoID: subtitleVideoID) else { return }
                subtitleLoadingURL = nil
                // Same still-live-engine gate as the manual row: never record an add the live engine never saw.
                if ok, player === coordinator.player { addedSubURLs.insert(sub.url); hoardAddonSubtitle(sub) }
                if ok, player === coordinator.player {
                    applyCurrentSubtitleDelayIfReady(force: false)
                }
                refreshTracksSoon()
                VXProbe.event("subs", "subs selected \(langName(sub.lang)) (add-on auto ok=\(ok))")
            }
            return
        }
        // Tier 2 - community-pooled subtitles, when no add-on had the chain language. Same tolerant match.
        var pooledPick: SubtitlePoolClient.PooledSubtitle?
        for lang in prefs.subtitleLanguages {
            if let s = pooledSubs.first(where: { TrackSelector.matches($0.lang, lang) }) { pooledPick = s; break }
        }
        if let sub = pooledPick {
            autoAddonSubTried = true
            VXProbe.event("subs", "subs selected \(langName(sub.lang)) (community auto)")
            selectPooledSubtitle(sub, auto: true)   // shared path: moat-gated download -> addExternalSubtitle -> addedPooledIDs
            return
        }
        // No chain match. Latch only once BOTH async lists have arrived (each completion re-calls this), so a
        // pooled list landing after an empty add-on list still gets its turn.
        if !addonSubs.isEmpty && !pooledSubs.isEmpty { autoAddonSubTried = true }
    }

    // MARK: - Community subtitles (pool + sync + embedded upload)

    /// Build the community content key for a supplied metadata identity. The caller can use a staged episode
    /// identity before it is published, while the live property below keeps the existing runtime live gate.
    private func communityContentKey(for targetMeta: PlaybackMeta?) -> String? {
        guard let m = targetMeta, !LiveTypes.contains(m.type) else { return nil }
        // A tmdb-backed play carries a `tmdb:` library id; feeding it straight into contentKey mints a bogus
        // `tt<tmdb-number>` via the bare-digit fallback. Route those through the persistent tmdb->tt resolver
        // cache instead: nil until it resolves (the whole community path no-ops rather than running under a wrong
        // identity), then the correct tt key. fetchAddonSubtitles' post-resolve fetchPooledSubtitles() re-keys it.
        if m.libraryId.lowercased().hasPrefix("tmdb:") {
            guard let tt = CommunityTrickplay.cachedIMDbID(for: m.libraryId) else { return nil }
            return SubtitleReleaseFingerprint.contentKey(imdbId: tt, season: m.season, episode: m.episode)
        }
        return SubtitleReleaseFingerprint.contentKey(imdbId: m.libraryId, season: m.season, episode: m.episode)
    }

    /// The pool content key for the published current media. Runtime live playback keeps the community path
    /// disabled even when its metadata resembles a normal title.
    private var communityContentKey: String? {
        guard !isCurrentLiveStream else { return nil }
        return communityContentKey(for: curMeta)
    }

    /// Stable local timing scope. It requires the actual stream's release description and never falls back to
    /// a URL, title, duration, or display label when that authority is absent.
    private func subtitleTimingScope(for targetMeta: PlaybackMeta?, stream: CoreStream?) -> SubtitleTimingScope? {
        guard let contentKey = communityContentKey(for: targetMeta),
              let stream else { return nil }
        let releaseDescription = StreamRanking.signature(stream)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !releaseDescription.isEmpty,
              releaseDescription.caseInsensitiveCompare("unknown") != .orderedSame else {
            return nil
        }
        let releaseFingerprint = SubtitleReleaseFingerprint.releaseFingerprint(releaseName: releaseDescription)
        return SubtitleTimingScope(contentKey: contentKey, releaseFingerprint: releaseFingerprint)
    }

    /// Establish a local scope when metadata or the actual source becomes authoritative. A late identity fill
    /// may establish a previously nil scope, but it never clears timing or advances the timing generation.
    private func establishSubtitleTimingScopeIfAvailable() {
        guard pendingAdvance == nil else { return }
        guard subtitleTimingScope == nil else { return }
        subtitleTimingScope = subtitleTimingScope(
            for: curMeta,
            stream: curSourceStream ?? currentStream
        )
    }

    /// Local v2 restore is state-only. The track-list seam applies that state once subtitle timing is ready.
    private func restoreSubtitleTimingOffsetIfReady() {
        establishSubtitleTimingScopeIfAvailable()
        guard subDelay == 0, !pooledSeededOffset,
              let scope = subtitleTimingScope,
              let savedOffset = SubtitleOffsetMemory.savedOffset(for: scope) else { return }
        subDelay = savedOffset
        pooledSeededOffset = true
    }

    /// Admit a true source or episode replacement at the accepted-load boundary. Preservation paths do not
    /// call this helper, so their timing state and generation remain intact while their new load token earns
    /// one track-ready reapplication.
    private func acceptSubtitleTimingReplacement(
        scope: SubtitleTimingScope?,
        clearNewEngineDelay: Bool = true
    ) {
        flushPendingSubOffsetSave()
        offsetCaptureTask?.cancel()
        offsetCaptureTask = nil
        subtitleTimingGeneration &+= 1
        subtitleTimingScope = scope
        let savedOffset = SubtitleOffsetMemory.savedOffset(for: scope)
        subDelay = savedOffset ?? 0
        pooledSeededOffset = savedOffset != nil
        subtitleDelayAppliedLoadToken = nil
        if clearNewEngineDelay { coordinator.player?.setSubDelay(0) }
    }

    /// Apply a nonzero restored or pooled delay once for an exact engine load token. Explicit user actions use
    /// force so Reset also reaches the engine with zero, while ordinary track-list replays stay idempotent.
    private func applyCurrentSubtitleDelayIfReady(force: Bool = false) {
        guard let player = coordinator.player,
              player.subtitleDelayAvailable,
              let loadToken = player.activeLoadToken else { return }
        if !force {
            guard subDelay != 0 else { return }
            if subtitleDelayAppliedLoadToken == loadToken { return }
        }
        player.setSubDelay(subDelay)
        subtitleDelayAppliedLoadToken = loadToken
    }

    /// A subtitle request may finish after an episode load or same-episode reload replaced the player item.
    /// Require both its opaque load token and its content identity before publishing completion state.
    private func permitsSubtitlePublication(loadToken: PlayerLoadToken?, videoID: String?) -> Bool {
        guard let loadToken, coordinator.player?.activeLoadToken == loadToken else { return false }
        return curMeta?.videoId == videoID
    }

    /// The release name for the fingerprint: the playing stream's display name / release text.
    private var communityReleaseName: String? {
        if let s = currentStream { return sourceLabel(s) }
        return curTitle.isEmpty ? nil : curTitle
    }

    /// Build (or rebuild) the one release fingerprint for this playback session, keyed on the active URL so a
    /// source switch recomputes it. `force` rebuilds even when the key is unchanged (e.g. once the real
    /// duration/fps land). Kept consistent so fetch/upload/offset all agree.
    private func refreshSubFingerprint(force: Bool = false) {
        let key = (curURL ?? url).absoluteString
        if !force, key == subFingerprintKey, subFingerprint != nil { return }
        subFingerprintKey = key
        let fps = coordinator.player?.containerFrameRate() ?? 0
        let dur = coordinator.player?.mediaDurationSeconds() ?? duration
        subFingerprint = SubtitleReleaseFingerprint.releaseFingerprint(
            frameRate: fps > 0 ? fps : nil,
            durationSecs: dur > 0 ? dur : nil,
            releaseName: communityReleaseName)
    }

    /// P2/P3: fetch pooled community subtitles + the learned sync offset for this title, then (P3) seed the
    /// offset onto the player once. Gated + fail-soft inside the client. De-duped per content key + fingerprint.
    private func fetchPooledSubtitles() {
        guard assetSanityAttempt.isAccepted(
            owner: coordinator.player?.activeLoadToken
        ) else { return }
        guard let contentKey = communityContentKey else { return }
        establishSubtitleTimingScopeIfAvailable()
        if appliedAutoTracks {
            restoreSubtitleTimingOffsetIfReady()
            applyCurrentSubtitleDelayIfReady(force: false)
        }
        refreshSubFingerprint()
        let fp = subFingerprint
        let poolTimingScope = SubtitleTimingScope(contentKey: contentKey, releaseFingerprint: fp)
        let capturedTimingGeneration = subtitleTimingGeneration
        let key = "\(contentKey)#\(fp ?? "")"
        guard let requestID = subtitlePoolRequests.beginFetch(dedupeKey: key) else { return }
        Task { @MainActor in
            // SERVE moat gate: the pooled-subtitle READ is login-only on the worker (no VortX sign-in -> empty
            // list, the pool "shows nothing" bug). Thread the real account flag like SourceIndexClient does, so a
            // signed-in device stamps X-VX-Moat and the worker serves the pool.
            let signedIn = VortXSyncManager.shared.isSignedIn
            let publicationFence = SubtitlePoolClient.PublicationFence(contentKey: contentKey)
            let result = await SubtitlePoolClient.fetchPooled(contentKey: contentKey, lang: nil, fingerprint: fp,
                                                              isSignedIn: signedIn)
            let mayPublish = publicationFence.permits(
                currentContentKey: communityContentKey,
                isSignedIn: VortXSyncManager.shared.isSignedIn
            )
            guard mayPublish else {
                subtitlePoolRequests.finishFetch(requestID, published: false)
                return
            }
            guard subtitlePoolRequests.finishFetch(requestID, published: true) else { return }
            pooledSubs = result.subs
            VXProbe.log("subs", "subs pooled n=\(result.subs.count)")
            if pendingSubtitleReapply != nil {
                autoSelectTracks(applyAutomaticSelections: false)
            }
            // The pooled list can land AFTER autoSelectTracks already ran (and after an empty add-on list): give
            // the language-chain auto-select its turn on these candidates too (guards above keep it safe).
            autoSelectAddonSubtitleIfNeeded()
            // P3 seed: remember the community-learned offset once. Apply it only when the active subtitle path
            // advertises live delay support (all libmpv subtitles, or AVPlayer's external cue overlay).
            let timingGenerationMatches = capturedTimingGeneration == subtitleTimingGeneration
            if let poolTimingScope, !pooledSeededOffset,
               poolTimingScope == SubtitleTimingScope(
                   contentKey: communityContentKey,
                   releaseFingerprint: subFingerprint
               ),
               timingGenerationMatches,
               subDelay == 0,
               let offsetMs = result.offsetMs,
               offsetMs != 0 {
                pooledSeededOffset = true
                let seconds = (Double(offsetMs) / 1000.0 * 10).rounded() / 10
                subDelay = seconds
                applyCurrentSubtitleDelayIfReady(force: false)
                VXProbe.log("subs", "subs sync \(seconds)s (community seed)")
            }
            if showOptions, panelShowsSubtitleList { refreshPanelRowsPreservingAccessibilityFocus() }
        }
    }

    /// P2: load a pooled subtitle into the player, reusing the exact external-subtitle path (download to a
    /// local file, then mpv `sub-add`). Shows the shared Loading… row state. Fail-soft.
    private func selectPooledSubtitle(_ sub: SubtitlePoolClient.PooledSubtitle, auto: Bool = false) {
        guard subtitleLoadingURL == nil, communityContentKey == sub.contentKey,
              MoatConsent.contributeAndConsume,
              VortXSyncManager.shared.isSignedIn else { return }
        let marker = sub.url.absoluteString
        let downloadID = subtitlePoolRequests.beginDownload()
        subtitleLoadingURL = marker
        if showOptions, panelShowsSubtitleList { refreshPanelRowsPreservingAccessibilityFocus() }
        Task { @MainActor in
            // The pool-hosted sub TEXT is moat-gated too, so pass the same account flag the fetch used.
            let signedIn = VortXSyncManager.shared.isSignedIn
            let publicationFence = SubtitlePoolClient.PublicationFence(contentKey: sub.contentKey)
            let downloaded = await SubtitlePoolClient.download(sub, isSignedIn: signedIn)
            let mayPublishDownload = publicationFence.permits(
                currentContentKey: communityContentKey,
                isSignedIn: VortXSyncManager.shared.isSignedIn
            )
            guard mayPublishDownload else {
                if subtitlePoolRequests.finishDownload(downloadID) {
                    subtitleLoadingURL = nil
                    if showOptions, panelShowsSubtitleList { refreshPanelRowsPreservingAccessibilityFocus() }
                }
                return
            }
            guard let localURL = downloaded else {
                if subtitlePoolRequests.finishDownload(downloadID) {
                    subtitleLoadingURL = nil
                    if showOptions, panelShowsSubtitleList { refreshPanelRowsPreservingAccessibilityFocus() }
                }
                // Honest failure on a manual pick; the automatic tier-2 pick stays silent (mirrors iOS).
                if !auto { showEngineNote(String(localized: "Subtitle failed to load")) }
                return
            }
            guard let externalID = subtitlePoolRequests.beginExternal(after: downloadID) else { return }
            let title = pooledLabel(sub)
            // The engine can vanish DURING the await above (demote/switch render gap): an optional-chained
            // call would swallow the completion and strand the Loading… latch, so unlatch, close the
            // request ledger entry, and revert.
            guard let player = coordinator.player else {
                if subtitlePoolRequests.finishExternal(externalID) {
                    subtitleLoadingURL = nil
                    if showOptions, panelShowsSubtitleList { refreshPanelRowsPreservingAccessibilityFocus() }
                }
                return
            }
            let subtitleLoadToken = player.activeLoadToken
            let subtitleVideoID = curMeta?.videoId
            player.addExternalSubtitle(url: localURL.absoluteString, title: title, lang: sub.lang) { ok in
                let mayPublishExternal = publicationFence.permits(
                    currentContentKey: communityContentKey,
                    isSignedIn: VortXSyncManager.shared.isSignedIn
                )
                let loadStillCurrent = permitsSubtitlePublication(
                    loadToken: subtitleLoadToken, videoID: subtitleVideoID
                )
                guard mayPublishExternal, loadStillCurrent else {
                    if subtitlePoolRequests.finishExternal(externalID) {
                        subtitleLoadingURL = nil
                        if showOptions, panelShowsSubtitleList { refreshPanelRowsPreservingAccessibilityFocus() }
                    }
                    return
                }
                guard subtitlePoolRequests.finishExternal(externalID) else { return }
                subtitleLoadingURL = nil
                // Same still-live-engine gate as the add-on rows: never record an add the live engine never saw.
                if ok, player === coordinator.player { addedPooledIDs.insert(sub.id) }
                else if !ok, !auto { showEngineNote(String(localized: "Subtitle failed to load")) }
                if ok, player === coordinator.player {
                    applyCurrentSubtitleDelayIfReady(force: false)
                }
                if showOptions, panelShowsSubtitleList { refreshPanelRowsPreservingAccessibilityFocus() }
                VXProbe.event("subs", "subs selected \(langName(sub.lang)) (community ok=\(ok))")
            }
        }
    }

    /// The label for a pooled subtitle row: the language name. NO add-on wording (framing rule) - pooled subs
    /// are just "subtitles" with a subtle community provenance shown in the row detail.
    private func pooledLabel(_ sub: SubtitlePoolClient.PooledSubtitle) -> String { langName(sub.lang) }

    /// P3 capture: debounce a manual sync change, then submit the learned offset to the pool. Works on BOTH
    /// engines now: on libmpv it is the `sub-delay`, on AVPlayer it is the offset applied to VortX's own
    /// external-subtitle overlay (add-on/pooled srt/vtt) - the same signed cue offset for this fingerprint.
    /// Gated + fail-soft inside the client.
    private func captureSubOffset() {
        guard let capturedContentKey = communityContentKey,
              let capturedFingerprint = subFingerprint else { return }
        guard let capturedTimingScope = SubtitleTimingScope(
                  contentKey: capturedContentKey,
                  releaseFingerprint: capturedFingerprint
              ) else { return }
        offsetCaptureTask?.cancel()
        let delaySeconds = subDelay
        guard delaySeconds.isFinite, abs(delaySeconds) <= 120 else { return }
        let capturedTimingGeneration = subtitleTimingGeneration
        offsetCaptureTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled,
                  capturedTimingGeneration == subtitleTimingGeneration,
                  capturedTimingScope == SubtitleTimingScope(
                      contentKey: communityContentKey,
                      releaseFingerprint: subFingerprint
                  ) else { return }
            let offsetMs = Int((delaySeconds * 1000).rounded())
            await SubtitlePoolClient.postOffset(contentKey: capturedContentKey, lang: "",
                                                fingerprint: capturedFingerprint, offsetMs: offsetMs)
        }
    }

    /// P4: extract the file's own embedded TEXT subtitle tracks off-main and upload each to the pool so users
    /// on a different rip benefit. Best-effort, once per session, never blocks playback; ignores failures.
    /// LOCAL FILES (finished downloads) ONLY: extraction demuxes the whole container, so on a streamed play it
    /// re-downloaded the entire file next to the player - the Apple TV "remux builds up frame drops and
    /// distorted audio" regression, stacking a further never-cancelled full-file read on every restart and
    /// episode switch. The extractor hard-refuses remote inputs too; checking here skips spawning the task.
    private func uploadEmbeddedSubtitlesIfNeeded() {
        guard !embeddedUploadDone, let contentKey = communityContentKey else { return }
        embeddedUploadDone = true
        let inputStr = (curURL ?? url).absoluteString
        guard SubtitleEmbeddedExtractor.isLocalFileInput(inputStr) else { return }
        refreshSubFingerprint()
        let fp = subFingerprint
        Task.detached(priority: .utility) {
            let tracks = SubtitleEmbeddedExtractor.extractTextSubtitles(input: inputStr)
            for track in tracks where track.cueCount > 0 {
                await SubtitlePoolClient.upload(contentKey: contentKey, lang: track.lang, fingerprint: fp,
                                                origin: "embedded", format: track.format, text: track.srt)
            }
        }
    }

    /// Hoard a successfully-loaded ADD-ON subtitle into the community pool (origin "addon") so the next user
    /// gets it without hitting the add-on. Best-effort, off-main, gated + size-capped + fail-soft inside
    /// `SubtitlePoolClient.upload`; never blocks playback. The sub text is downloaded once from the add-on URL.
    private func hoardAddonSubtitle(_ sub: AddonSubtitle) {
        guard let contentKey = communityContentKey, let subURL = URL(string: sub.url) else { return }
        refreshSubFingerprint()
        let fp = subFingerprint
        let lang = sub.lang
        let ext = subURL.pathExtension.lowercased()
        let format = ["srt", "vtt", "ass"].contains(ext) ? ext : "srt"
        Task.detached(priority: .utility) {
            guard let data = try? await URLSession.shared.data(from: subURL).0,
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  !text.isEmpty else { return }
            await SubtitlePoolClient.upload(contentKey: contentKey, lang: lang, fingerprint: fp,
                                            origin: "addon", format: format, text: text)
        }
    }

    /// Contribute the file's REAL audio + subtitle track languages to the community language index with
    /// provenance "container" -- the strongest signal, since these come from libmpv's own track list rather
    /// than a parsed release name. Fires once per session on every play (incl. Continue-Watching / card
    /// resumes that never open the detail view). Resolves a `tmdb:` library id to its `tt` id first so
    /// tmdb-only titles are not dropped. Fail-soft: an unresolvable tmdb id contributes nothing.
    private func contributeContainerLanguagesIfNeeded() {
        guard !langContributeDone, LanguageIndexClient.isEnabled else { return }
        let audio = audioTracks.map { $0.lang }.filter { !$0.isEmpty }
        let subs = subtitleTracks.map { $0.lang }.filter { !$0.isEmpty }
        guard !audio.isEmpty || !subs.isEmpty else { return }
        langContributeDone = true

        // A tmdb-backed play carries a `tmdb:` library id. communityContentKey is now tmdb-safe, but it only
        // reads the resolver CACHE and returns nil on a miss. The language index wants the strongest signal even
        // for a title seen for the first time, so resolve tmdb -> tt HERE (cache, then network) and only fall
        // through to the direct communityContentKey for real tt / other ids.
        if let m = curMeta, !isCurrentLiveStream, m.libraryId.lowercased().hasPrefix("tmdb:") {
            let rawId = m.libraryId
            let season = m.season, episode = m.episode
            Task.detached(priority: .utility) {
                let tt: String?
                if let cached = CommunityTrickplay.cachedIMDbID(for: rawId) {
                    tt = cached
                } else {
                    tt = await CommunityTrickplay.resolveIMDbID(rawId: rawId, seriesHint: season != nil)
                }
                guard let tt, let contentKey = SubtitleReleaseFingerprint.contentKey(imdbId: tt, season: season, episode: episode) else { return }
                await LanguageIndexClient.contribute(contentKey: contentKey, audioLangs: audio,
                                                     subLangs: subs, provenance: "container")
            }
            return
        }
        if let contentKey = communityContentKey {
            Task.detached(priority: .utility) {
                await LanguageIndexClient.contribute(contentKey: contentKey, audioLangs: audio,
                                                     subLangs: subs, provenance: "container")
            }
            return
        }
        langContributeDone = false   // no resolvable id yet; allow a later retry once tracks/meta firm up
    }

    private var isCurrentLiveStream: Bool { curIsLive && !isTorrentPlayback }
    private var initialLiveMode: Bool { !torrent && isLiveMeta(meta) }

    // MARK: - System Now Playing (#157)

    /// What the Apple TV Control Center card / system transport should show for what is playing RIGHT NOW.
    /// Built from the LIVE identity (`curTitle` / `curMeta`), never the immutable launch props, so a binge
    /// advance or an in-player source hop re-publishes the new episode instead of leaving the card on the
    /// outgoing one. Series carry the show name + season/episode separately; a movie leaves them nil.
    private var nowPlayingItem: NowPlayingItem {
        let m = curMeta ?? meta
        let isSeries = m?.usesSeriesLifecycle == true
        let displayTitle = curTitle.isEmpty ? (m?.name ?? title) : curTitle
        return NowPlayingItem(title: displayTitle,
                              showName: isSeries ? m?.name : nil,
                              season: isSeries ? m?.season : nil,
                              episode: isSeries ? m?.episode : nil,
                              artworkURL: m?.poster,
                              isLive: isCurrentLiveStream)
    }

    /// Push the current position / state to the system Now Playing surface. Cheap and self-throttling
    /// (`NowPlayingPolicy.refreshInterval`), so it is safe on the 4 Hz tick; `force` is for the moments the
    /// system cannot extrapolate, i.e. right after a committed seek.
    ///
    /// Engine-agnostic by construction: it reads only the chrome's own `currentTime` / `duration` /
    /// `isPaused`, which BOTH engines drive through the same property stream, so libmpv and AVPlayer (incl.
    /// the Dolby Vision remux lane) publish identically with no engine branch here.
    ///
    /// `at` overrides the published position for the ONE caller that runs before `currentTime` has been
    /// assigned this tick's value: the first-frame publish. Without it a resumed title publishes 0 and is
    /// only corrected on the next tick, so the card would briefly show the start of a film resumed at 40
    /// minutes.
    private func refreshNowPlaying(at elapsed: Double? = nil, force: Bool = false) {
        guard hasStartedPlaying else { return }
        NowPlayingCenter.update(item: nowPlayingItem,
                                elapsed: elapsed ?? currentTime,
                                duration: duration,
                                paused: isPaused,
                                speed: playSpeed,
                                force: force)
    }

    /// The first load's URL/headers, proxied through the embedded server when the launch stream
    /// declares request headers (same routing as loadIntoPlayer, applied to the initial play).
    private var initialPlayback: (url: URL, headers: [String: String]?) {
        if let h = headers, !h.isEmpty, let proxied = StremioServer.proxiedURL(for: url, headers: h) {
            return (proxied, nil)
        }
        return (url, headers)
    }

    /// The launch tuple remains the normal initial surface input. A user-driven engine replacement may supply
    /// the active tuple first, notably after a native-debrid fresh-link recovery, so the new controller never
    /// opens a URL whose failure already triggered the recovery.
    private var engineSurfacePlayback: (url: URL, headers: [String: String]?) {
        if engineSurfaceUsesActiveTuple {
            return (engineSurfaceURLOverride ?? url, engineSurfaceHeadersOverride)
        }
        return (url, headers)
    }

    /// A fallback surface receives the live source before its controller is constructed. Mounting the immutable
    /// launch tuple first can produce a frame for a previous episode and disarm the wrong watchdog.
    private var mpvSurfacePlayback: (url: URL, headers: [String: String]?, audioSidecar: URL?, live: Bool, isDolbyVision: Bool) {
        let activeURL = avEngineFailed ? (curURL ?? url) : url
        let activeHeaders = avEngineFailed ? curHeaders : headers
        let input: (url: URL, headers: [String: String]?)
        if let activeHeaders, !activeHeaders.isEmpty,
           let proxied = StremioServer.proxiedURL(for: activeURL, headers: activeHeaders) {
            input = (proxied, nil)
        } else {
            input = (activeURL, activeHeaders)
        }
        return (
            input.url,
            input.headers,
            activeURL == url ? audioSidecarURL : nil,
            avEngineFailed ? curIsLive : initialLiveMode,
            StreamRanking.isDolbyVision(avEngineFailed ? (curHint ?? sourceHint ?? "") : (sourceHint ?? ""))
        )
    }

    /// Live content carries the live meta types; everything else keeps VOD behavior. The
    /// id-scheme heuristic (any id the skip service can't parse = live) would misclassify
    /// VOD from add-ons with custom id schemes, trapping whole drama catalogs in the live
    /// EOF-reconnect loop so episodes could never finish or auto-advance.
    private func isLiveMeta(_ meta: PlaybackMeta?) -> Bool {
        guard let type = meta?.type else { return false }
        return LiveTypes.contains(type)   // shared definition of "live" (tv / channel / events)
    }

    // MARK: - Skip intro / outro (chapter-derived; AniSkip crowd-sourced timings can feed the same model later)

    /// The skip segment the playhead is currently inside, if any. Gated on `hasStartedPlaying` so a stale
    /// segment from the previous file never flashes during a load.
    /// Recompute the active skip span for a playhead value, assigning only on change
    /// so the player body re-renders when the pill appears/disappears, not per tick.
    private func updateCurrentSkip(at time: Double) {
        let skip = hasStartedPlaying ? skipSegments.first { time >= $0.start && time < $0.end } : nil
        // Auto-skip: when the playhead enters a NEW skip segment and the setting is on, jump past it once.
        // Recording the start means a manual seek back into the same segment won't auto-skip it again.
        if autoSkip, let skip, !autoSkippedStarts.contains(skip.start) {
            autoSkippedStarts.insert(skip.start)
            DiagnosticsLog.log(
                "playback",
                String(
                    format: "automatic skip kind=%@ start=%.3fs end=%.3fs observed=%.3fs",
                    skip.kind.rawValue,
                    skip.start,
                    skip.end,
                    time
                )
            )
            skipTo(skip)
            if currentSkip != nil { currentSkip = nil }
            return
        }
        if skip?.start != currentSkip?.start { currentSkip = skip }
        // Re-arm a Back-dismissed pill once the playhead leaves that segment (seek-out, natural exit,
        // or a new file's spans): the dismissal is scoped to one continuous stay inside the segment.
        if let dismissed = skipPillDismissedStart, skip?.start != dismissed { skipPillDismissedStart = nil }
    }

    /// Re-resolve skip spans from every available layer (named chapters + crowd timestamps), once the
    /// file's duration is known. The resolver's sanity guards keep any one bad span from mis-skipping.
    private func refreshSkipSegments() {
        let chapters = coordinator.player?.chapters() ?? []
        chapterCount = chapters.count   // the Chapters button reads this instead of re-fetching per body pass
        let chapterCandidates = SkipSegments.chapterCandidates(chapters: chapters, duration: duration)
        skipSegments = SegmentResolver.resolve(chapterCandidates + apiSkipCandidates, duration: duration)
        chapterFractions = ChapterMarks.fractions(chapters: chapters, duration: duration)
        updateCurrentSkip(at: currentTime)
    }

    /// Pull crowd-sourced intro/credits spans for the current title (disk-cached, non-blocking): the
    /// pill simply appears once the result lands, normally well before the intro is reached.
    private func fetchSkipTimestamps() {
        guard let m = curMeta else { plog.info("skip: no curMeta, not fetching"); return }
        let key = "\(m.libraryId):\(m.season ?? 0):\(m.episode ?? 0)"
        guard SkipTimestampService.supports(metaId: m.libraryId) else {
            skipFetchTask?.cancel()
            apiSkipCandidates = []
            // T18: an unsupported title still resolves chapter-derived skip segments, so a NEW episode must reset
            // the per-episode auto-skip dedup + pill dismissal here too (the supported branch below already does).
            // Guard on the key so a same-episode re-fetch (a source switch re-fires the duration event) does not
            // clobber mid-episode; store the real key (not "") so the next unsupported episode is detectable.
            if key != skipFetchKey { autoSkippedStarts = []; skipPillDismissedStart = nil }
            skipFetchKey = key
            refreshSkipSegments()
            return
        }
        if key != skipFetchKey { apiSkipCandidates = []; autoSkippedStarts = []; skipPillDismissedStart = nil }   // new episode: reset auto-skip + pill dismissal
        skipFetchKey = key
        let dur = duration
        plog.info("skip: fetching key=\(key, privacy: .public) dur=\(Int(dur), privacy: .public)")
        skipFetchTask?.cancel()
        skipFetchTask = Task { @MainActor in
            let found = await SkipTimestampService.candidates(imdbId: m.libraryId, season: m.season,
                                                              episode: m.episode, durationSeconds: dur)
            guard !Task.isCancelled, skipFetchKey == key else { return }
            apiSkipCandidates = found
            refreshSkipSegments()
            plog.info("skip: \(found.count, privacy: .public) crowd spans, \(skipSegments.count, privacy: .public) resolved segments")
        }
    }

    /// Jump past a skip segment to its end, updating the playhead so the pill clears immediately.
    private func skipTo(_ segment: SkipSegment) {
        issueSeek(to: segment.end, reason: "skip")
        currentTime = segment.end
    }

    /// Seek by `delta` seconds while the chrome is HIDDEN, without revealing the control bar. A direct
    /// relative seek plus a brief cumulative time pill, so quick Left/Right nudges don't force the whole
    /// bar up (the competitor-parity "seek-while-hidden"). No media yet (duration 0) falls back to reveal.
    private func hiddenSeek(_ delta: Double) {
        guard duration > 0 else { showControls(); return }
        seek(delta)
        withAnimation { hiddenSeekDelta = (hiddenSeekDelta ?? 0) + delta }   // accumulate rapid presses
        hiddenSeekTask?.cancel()
        hiddenSeekTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled else { return }
            withAnimation { hiddenSeekDelta = nil }
        }
    }

    /// The seek-amount pill shown bottom-center while seeking with the chrome hidden (mirrors skipPill).
    private func hiddenSeekPill(_ delta: Double) -> some View {
        let s = Int(delta)
        return VStack {
            Spacer()
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: s >= 0 ? "goforward" : "gobackward")
                Text(s >= 0 ? "+\(s)s" : "\(s)s").fontWeight(.semibold).monospacedDigit()
            }
            .padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.md)
            .foregroundStyle(Theme.Palette.textPrimary)
            // Floating seek feedback over the video: warm toast glass (legible field-weight fill + soft toast
            // shadow), Liquid Glass on tvOS 26, opaque warm fallback under Reduce Transparency. A compact
            // non-interactive notice, like the stats overlay.
            .vortxGlassToast(in: Capsule())
            .padding(.bottom, Theme.Space.screenEdge * 3)
        }
        .transition(.opacity)
    }

    /// The skip pill actually on screen right now - one source of truth shared by the body render
    /// and the remote handler: chrome hidden, a segment active, the Up Next band not owning the
    /// corner, and not Back-dismissed for this segment.
    private var skipPillSegment: SkipSegment? {
        guard controlsHidden, let seg = currentSkip, upNextRemaining == nil, !isCreditsUpNext,
              seg.start != skipPillDismissedStart else { return nil }
        return seg
    }

    /// The "Skip Intro / Skip Outro" pill, bottom-trailing. Shown only while watching (controls hidden);
    /// pressing Select skips it (see `handlePress`).
    private func skipPill(_ segment: SkipSegment) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "forward.fill").foregroundStyle(Theme.Palette.accent)
                    Text(segment.label).fontWeight(.semibold)
                }
                .padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.md)
                // Glass ember skip pill (mockup .skippill): warm glass with an ember hairline and ember
                // glyph, upgrading to Liquid Glass on tvOS 26. Ink label, ember icon.
                .foregroundStyle(Theme.Palette.textPrimary)
                .vortxGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous),
                            fillAlpha: VortXGlass.barFillAlpha, shadow: .pill)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(Theme.Palette.accent.opacity(0.5), lineWidth: 1)
                }
                .padding(Theme.Space.screenEdge * 1.5)
            }
        }
        .transition(.opacity)
    }

    /// End-of-episode Up Next card (controls hidden): next episode + countdown + Play Now / Watch Credits.
    /// The remote drives it directly via handlePress (Left/Right pick, Select activates), so there is no
    /// SwiftUI @FocusState here - `upNextWantsCredits` is the highlighted button.
    private var upNextBand: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 28) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("UP NEXT").font(.caption.weight(.bold)).tracking(2)
                            .foregroundStyle(Theme.Palette.textTertiary)
                        if let label = nextEpisodeLabel {
                            Text(label).font(.title3.weight(.semibold))
                                .foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
                        }
                        if let r = upNextRemaining {
                            Text("Playing in \(r)s").font(.callout).foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    upNextButton("Play Now", systemImage: "play.fill", highlighted: !upNextWantsCredits)
                    upNextButton("Watch Credits", systemImage: nil, highlighted: upNextWantsCredits)
                }
                .padding(.horizontal, 32).padding(.vertical, 22)
                .frame(maxWidth: 820, alignment: .leading)
                // Floating Up Next card on the warm card glass, matching the iOS end-of-episode card.
                .vortxGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                            fillAlpha: VortXGlass.cardFillAlpha, shadow: .card)
                .padding(Theme.Space.screenEdge * 1.5)
            }
        }
        .transition(accessibilityReduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
        .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.15), value: upNextWantsCredits)
    }

    private func upNextButton(_ title: String, systemImage: String?, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            if let img = systemImage { Image(systemName: img) }
            Text(title).lineLimit(1)
        }
        .font(.headline.weight(.semibold))
        .foregroundStyle(highlighted ? Theme.Palette.onAccent : Theme.Palette.textPrimary)
        .padding(.horizontal, 24).padding(.vertical, 13)
        // Highlighted (Play Now / focused) stays a prominent solid-ember pill for 10-foot legibility;
        // the idle pill (Watch Credits) rides the warm glass. The opaque accent layer sits above the
        // glass so, when highlighted, it reads as solid ember rather than tinted glass.
        .background { if highlighted { Capsule().fill(Theme.Palette.accent) } }
        .vortxGlass(in: Capsule(), fillAlpha: VortXGlass.pillFillAlpha, shadow: .flat)
        .overlay(Capsule().stroke(Theme.Palette.canvas, lineWidth: highlighted ? 3 : 0))
        .scaleEffect(accessibilityReduceMotion ? 1.0 : (highlighted ? 1.06 : 1.0))
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Episode navigation (series only; launch and loaded metadata share one ordered view)

    private var navigationEpisodeSource: [CoreVideo] {
        guard !episodes.isEmpty else { return loadedEpisodes }
        return loadedEpisodes.count > episodes.count ? loadedEpisodes : episodes
    }

    private var allEpisodes: [CoreVideo] { navigationEpisodeSource.orderedBySeasonEpisode }

    private var terminalEpisodeSource: [CoreVideo] {
        authoritativeSeriesEpisodes ?? (episodes.isEmpty ? loadedEpisodes : episodes)
    }

    private var terminalInventoryAuthority: AppleCWSeriesInventory.Authority {
        authoritativeSeriesEpisodes == nil ? seriesInventoryAuthority : .authoritativeFullSeries
    }

    private func terminalRefreshTarget(for m: PlaybackMeta) -> AppleCWTerminalRefreshTarget {
        AppleCWTerminalRefreshTarget(
            libraryID: m.libraryId,
            videoID: m.videoId,
            sessionID: playbackSessionID,
            episodeGeneration: episodeSwitchGeneration,
            sourceGeneration: sourceSwitchGeneration,
            resumeGeneration: resumeRetryGeneration,
            loadOwner: coordinator.player?.activeLoadToken.map { String(describing: $0) }
        )
    }

    private func terminalRefreshTargetIsCurrent(
        _ captured: AppleCWTerminalRefreshTarget,
        loadToken: PlayerLoadToken
    ) -> Bool {
        guard !leftPlayback, let current = curMeta,
              current.libraryId == captured.libraryID,
              current.videoId == captured.videoID,
              AppleCWTerminalRefreshFence.accepts(
                  captured: captured, current: terminalRefreshTarget(for: current)
              ) else { return false }
        guard coordinator.player?.activeLoadToken == loadToken else { return false }
        return true
    }

    private var terminalFinalityRefreshUsed: Bool {
        guard let captured = terminalFinalityRefreshTarget, let current = curMeta else { return false }
        return AppleCWTerminalRefreshFence.accepts(
            captured: captured, current: terminalRefreshTarget(for: current)
        )
    }

    /// Cancel only this player's bridge refresh generation. SwiftUI may tear down this view after a
    /// replacement player has started a newer request against the same title, so the captured generation
    /// must be retained through teardown and passed to CoreBridge rather than using global cancellation.
    private func cancelTerminalFinalityRefresh() {
        terminalFinalityRefreshTask?.cancel()
        terminalFinalityRefreshTask = nil
        if let generation = terminalFinalityRefreshGeneration {
            core.cancelAppleCWMetaRefresh(generation: generation)
        }
        terminalFinalityRefreshGeneration = nil
        terminalFinalityRefreshTarget = nil
    }

    /// A direct Continue Watching launch is allowed to upgrade its navigation inventory only from this
    /// refresh's exact settled title response. In particular, `core.metaDetails` is a shared slot and may
    /// still contain a covered detail page, so it is never read as authority here.
    private func hydrateDirectResumeMetadataForPlayerUI() {
        guard startedFromResume, let current = curMeta else { return }
        // Sources and the in-player title panel retain their ordinary direct-resume hydration for movies
        // and series. Episode inventory deliberately does not consume this shared slot; the fenced method
        // below separately certifies a same-title response before changing Next/Prev navigation.
        core.loadMeta(
            type: current.type, id: current.libraryId,
            streamType: current.type, streamId: current.videoId
        )
    }

    private func hydrateDirectResumeSeriesInventory() {
        guard startedFromResume, let launchMeta = curMeta, launchMeta.usesSeriesLifecycle else { return }
        cancelDirectResumeInventoryRefresh()
        directResumeInventoryRefreshTask = Task { @MainActor in
            // The player surface may appear before its physical load token is published. Wait behind
            // playback rather than delaying startup, then bind the request to that exact load.
            for _ in 0..<40 {
                guard !Task.isCancelled, !leftPlayback,
                      let current = curMeta,
                      current.libraryId == launchMeta.libraryId,
                      current.videoId == launchMeta.videoId else { return }
                guard let loadToken = coordinator.player?.activeLoadToken else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                let target = terminalRefreshTarget(for: current)
                guard terminalRefreshTargetIsCurrent(target, loadToken: loadToken) else { return }
                directResumeInventoryRefreshTarget = target
                let requestGeneration = core.beginAppleCWAuthoritativeMetaRefresh(
                    type: current.type, id: current.libraryId,
                    streamType: current.type, streamId: current.videoId
                )
                directResumeInventoryRefreshGeneration = requestGeneration
                directResumeInventoryRefreshPending = true
                defer {
                    if directResumeInventoryRefreshGeneration == requestGeneration {
                        directResumeInventoryRefreshPending = false
                    }
                }
                for attempt in 0..<16 {
                    guard !Task.isCancelled,
                          terminalRefreshTargetIsCurrent(target, loadToken: loadToken) else { return }
                    let receipt = AppleCWMetaRefreshReceipt(
                        requestGeneration: core.appleCWMetaRefreshReceipt?.requestGeneration,
                        selectedMetaID: core.appleCWMetaRefreshReceipt?.selectedMetaID,
                        loadedMetaID: core.appleCWMetaRefreshReceipt?.loadedMetaID,
                        settled: core.appleCWMetaRefreshReceipt?.settled == true,
                        requestedStreamID: core.appleCWMetaRefreshReceipt?.requestedStreamID
                    )
                    if AppleCWMetaRefreshAuthorityPolicy.accepts(
                        receipt, forRequestGeneration: requestGeneration,
                        expectedLibraryID: current.libraryId, expectedStreamID: current.videoId
                    ), let loaded = core.appleCWMetaRefreshDetails?.appleCWTerminalFullMeta(
                        for: current.libraryId, streamID: current.videoId
                    ), let candidate = EpisodePlaybackIdentity.appleCWAuthoritativeBackfill(
                        from: loaded.videos ?? [],
                        replacing: episodes.isEmpty ? loadedEpisodes : episodes
                    ) {
                        guard !Task.isCancelled,
                              terminalRefreshTargetIsCurrent(target, loadToken: loadToken) else { return }
                        loadedEpisodes = candidate
                        authoritativeSeriesEpisodes = candidate
                        plog.info("episode inventory refreshed behind direct resume: \(candidate.count)")
                        return
                    }
                    guard attempt < 15 else { return }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                return
            }
        }
    }

    private func cancelDirectResumeInventoryRefresh() {
        clearPendingManualEpisodeNavigation(reason: "inventory refresh cancelled")
        directResumeInventoryRefreshTask?.cancel()
        directResumeInventoryRefreshTask = nil
        if let generation = directResumeInventoryRefreshGeneration {
            core.cancelAppleCWMetaRefresh(generation: generation)
        }
        directResumeInventoryRefreshGeneration = nil
        directResumeInventoryRefreshTarget = nil
        directResumeInventoryRefreshPending = false
    }

    private var terminalRefreshResult: AppleCWSeriesRefreshResult {
        if terminalInventoryAuthority == .authoritativeFullSeries,
           EpisodePlaybackIdentity.appleCWSeriesInventory(
               from: terminalEpisodeSource,
               authority: .authoritativeFullSeries
           ) != nil {
            return .completedWithFullInventory
        }
        return terminalFinalityRefreshUsed ? .completedWithoutFullInventory : .notAttempted
    }

    private func terminalSeriesDecision(for m: PlaybackMeta) -> AppleCWSeriesTerminalDecision {
        EpisodePlaybackIdentity.appleCWTerminalDecision(
            currentVideoID: m.videoId,
            episodes: terminalEpisodeSource,
            authority: terminalInventoryAuthority,
            refresh: terminalRefreshResult
        )
    }

    private func refreshTerminalSeriesInventory(for m: PlaybackMeta) {
        guard let loadToken = coordinator.player?.activeLoadToken else { return }
        let target = terminalRefreshTarget(for: m)
        guard terminalRefreshTargetIsCurrent(target, loadToken: loadToken) else { return }
        cancelDirectResumeInventoryRefresh()
        cancelTerminalFinalityRefresh()
        terminalFinalityRefreshTarget = target
        let requestGeneration = core.beginAppleCWAuthoritativeMetaRefresh(
            type: m.type, id: m.libraryId, streamType: m.type, streamId: m.videoId
        )
        terminalFinalityRefreshGeneration = requestGeneration
        terminalFinalityRefreshTask = Task { @MainActor in
            guard !Task.isCancelled,
                  terminalRefreshTargetIsCurrent(target, loadToken: loadToken) else { return }
            var candidate: [CoreVideo]?
            for attempt in 0..<16 {
                guard !Task.isCancelled,
                      terminalRefreshTargetIsCurrent(target, loadToken: loadToken) else { return }
                let receipt = AppleCWMetaRefreshReceipt(
                    requestGeneration: core.appleCWMetaRefreshReceipt?.requestGeneration,
                    selectedMetaID: core.appleCWMetaRefreshReceipt?.selectedMetaID,
                    loadedMetaID: core.appleCWMetaRefreshReceipt?.loadedMetaID,
                    settled: core.appleCWMetaRefreshReceipt?.settled == true,
                    requestedStreamID: core.appleCWMetaRefreshReceipt?.requestedStreamID
                )
                if AppleCWMetaRefreshAuthorityPolicy.accepts(
                    receipt, forRequestGeneration: requestGeneration, expectedLibraryID: m.libraryId,
                    expectedStreamID: m.videoId
                ), let loaded = core.appleCWMetaRefreshDetails?.appleCWTerminalFullMeta(
                    for: m.libraryId, streamID: m.videoId
                ),
                   let vids = loaded.videos, !vids.isEmpty {
                    candidate = vids
                    break
                }
                guard attempt < 15 else { break }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled,
                      terminalRefreshTargetIsCurrent(target, loadToken: loadToken) else { return }
            }
            guard !Task.isCancelled,
                  terminalRefreshTargetIsCurrent(target, loadToken: loadToken) else { return }
            if let candidate,
               let accepted = EpisodePlaybackIdentity.appleCWAuthoritativeBackfill(
                   from: candidate,
                   replacing: episodes.isEmpty ? loadedEpisodes : episodes
               ) {
                guard !Task.isCancelled,
                      terminalRefreshTargetIsCurrent(target, loadToken: loadToken) else { return }
                loadedEpisodes = accepted
                authoritativeSeriesEpisodes = accepted
            }
            guard !Task.isCancelled,
                  terminalRefreshTargetIsCurrent(target, loadToken: loadToken) else { return }
            autoAdvance()
        }
    }

    private var manualEpisodeNavigationInventory: [AppleManualEpisodeNavigationCandidate] {
        allEpisodes.map {
            AppleManualEpisodeNavigationCandidate(id: $0.id, season: $0.season, episode: $0.episode)
        }
    }

    private var showsPreviousEpisodeControl: Bool {
        isEpisodePlaybackContext && (directResumeInventoryRefreshPending || hasPrevEpisode)
    }

    private var showsNextEpisodeControl: Bool {
        isEpisodePlaybackContext && (directResumeInventoryRefreshPending || hasNextEpisode)
    }

    private var episodeIndex: Int? {
        guard let m = curMeta else { return nil }
        return AppleManualEpisodeNavigationPolicy.currentIndex(
            currentID: m.videoId,
            currentSeason: m.season,
            currentEpisode: m.episode,
            inventory: manualEpisodeNavigationInventory
        )
    }
    private var hasNextEpisode: Bool { episodeIndex.map { $0 + 1 < allEpisodes.count } ?? false }
    private var hasPrevEpisode: Bool { (episodeIndex ?? 0) > 0 }

    /// The `CoreVideo` for the episode currently playing, resolved from the loaded episode list.
    /// Matches on the engine video id first (canonical), falling back to season+episode for direct
    /// resumes whose `curMeta.videoId` predates the freshly loaded list. Nil for movies / live.
    private var currentEpisodeVideo: CoreVideo? {
        guard let m = curMeta, m.usesSeriesLifecycle else { return nil }
        if let v = allEpisodes.first(where: { $0.id == m.videoId }) { return v }
        guard let s = m.season, let e = m.episode else { return nil }
        return allEpisodes.first { $0.season == s && $0.episode == e }
    }

    /// Top-right label text. Appends the episode title to the launch title when a *distinct* one
    /// is known (the model's `episodeTitle` falls back to a generic "Episode N", which we suppress
    /// to avoid noise). `play(episode:)` already bakes the title into `curTitle`, so guard against
    /// duplicating it there. Movies / live / title-less episodes show `curTitle` unchanged.
    private var displayTitle: String {
        guard let v = currentEpisodeVideo,
              let t = v.title, !t.isEmpty,           // a real episode title, not the "Episode N" fallback
              !curTitle.contains(t)                  // don't double-append (play(episode:) already added it)
        else { return curTitle }
        return "\(curTitle) · \(t)"
    }

    private func requestManualEpisodeNavigation(_ direction: AppleManualEpisodeNavigationIntent.Direction) {
        guard isEpisodePlaybackContext, !leftPlayback, let m = curMeta else { return }
        let intent = AppleManualEpisodeNavigationIntent(
            direction: direction,
            sessionID: playbackSessionID,
            episodeGeneration: episodeSwitchGeneration,
            sourceGeneration: sourceSwitchGeneration,
            loadOwner: coordinator.player?.activeLoadToken.map { String(describing: $0) }
        )
        switch AppleManualEpisodeNavigationPolicy.decision(
            intent: intent,
            sessionID: playbackSessionID,
            episodeGeneration: episodeSwitchGeneration,
            sourceGeneration: sourceSwitchGeneration,
            loadOwner: coordinator.player?.activeLoadToken.map { String(describing: $0) },
            currentID: m.videoId,
            currentSeason: m.season,
            currentEpisode: m.episode,
            inventory: manualEpisodeNavigationInventory,
            inventoryRefreshPending: directResumeInventoryRefreshPending
        ) {
        case .navigate(let target):
            guard let episode = allEpisodes.first(where: { $0.id == target }) else {
                clearPendingManualEpisodeNavigation(reason: "accepted episode target missing")
                return
            }
            clearPendingManualEpisodeNavigation(reason: "manual target available")
            play(episode: episode)
            return
        case .waitForInventory:
            pendingManualEpisodeNavigation = intent
            plog.info("manual episode navigation queued direction=\(direction == .next ? "next" : "previous")")
        default:
            clearPendingManualEpisodeNavigation(reason: "accepted episode boundary")
        }
    }

    private func consumePendingManualEpisodeNavigationIfReady() {
        guard let intent = pendingManualEpisodeNavigation, let m = curMeta else { return }
        let activeLoadOwner = coordinator.player?.activeLoadToken.map { String(describing: $0) }
        guard AppleManualEpisodeNavigationPolicy.owns(
            intent,
            sessionID: playbackSessionID,
            episodeGeneration: episodeSwitchGeneration,
            sourceGeneration: sourceSwitchGeneration,
            loadOwner: activeLoadOwner
        ) else {
            clearPendingManualEpisodeNavigation(reason: "newer playback load")
            return
        }
        switch AppleManualEpisodeNavigationPolicy.decision(
            intent: intent,
            sessionID: playbackSessionID,
            episodeGeneration: episodeSwitchGeneration,
            sourceGeneration: sourceSwitchGeneration,
            loadOwner: activeLoadOwner,
            currentID: m.videoId,
            currentSeason: m.season,
            currentEpisode: m.episode,
            inventory: manualEpisodeNavigationInventory,
            inventoryRefreshPending: directResumeInventoryRefreshPending
        ) {
        case .navigate(let target):
            guard let episode = allEpisodes.first(where: { $0.id == target }) else {
                clearPendingManualEpisodeNavigation(reason: "accepted episode target missing")
                return
            }
            pendingManualEpisodeNavigation = nil
            plog.info("manual episode navigation consumed target=\(target)")
            play(episode: episode)
        case .waitForInventory:
            return
        default:
            clearPendingManualEpisodeNavigation(reason: "accepted episode boundary")
        }
    }

    private func clearPendingManualEpisodeNavigation(reason: String) {
        guard pendingManualEpisodeNavigation != nil else { return }
        pendingManualEpisodeNavigation = nil
        plog.info("manual episode navigation cleared reason=\(reason)")
    }

    /// Automatic boundary advance must remain a no-op until a real successor is already known. It must not
    /// create the manual inventory intent, because a late inventory refresh after EOF cannot start playback.
    private func playNext() {
        if let i = episodeIndex, i + 1 < allEpisodes.count { play(episode: allEpisodes[i + 1]) }
    }

    private func playPrevious() {
        if let i = episodeIndex, i > 0 { play(episode: allEpisodes[i - 1]) }
    }

    /// Seconds left until auto-advance, when the Up Next band should be on screen: a next episode queued,
    /// a real runtime, the play head in the final stretch, and the user hasn't chosen to watch the credits.
    private var upNextRemaining: Int? {
        guard hasNextEpisode, !upNextSuppressed, duration > 60, currentTime > 0 else { return nil }
        let remaining = duration - currentTime
        guard remaining > 0, remaining <= 20 else { return nil }
        return Int(remaining.rounded(.up))
    }
    /// Show the Up Next band IN PLACE of the credits Skip pill: the moment the play head enters a
    /// credits segment (the same detection that drove the old Skip-Credits pill) and a next episode
    /// exists, the band owns the bottom-right corner so the two never fight for it (the band used to
    /// only appear in the last 20s, surfacing "after the credits were gone"). The last episode (no
    /// next) keeps its plain Skip pill. Its countdown line still appears only inside the last-20s window.
    private var isCreditsUpNext: Bool {
        currentSkip?.kind == .credits && hasNextEpisode && !upNextSuppressed && duration > 60
    }
    /// Label of the episode that plays next, for the Up Next band.
    private var nextEpisodeLabel: String? {
        guard let i = episodeIndex, i + 1 < allEpisodes.count else { return nil }
        let e = allEpisodes[i + 1]
        return "E\(e.episodeNumber) · \(e.episodeTitle)"
    }

    /// Wall-clock time the title will finish ("Ends 10:45 PM"), from the remaining runtime. Tracks the
    /// scrub position while scrubbing. nil for live / before the duration is known.
    private var endsAtClock: String? {
        guard duration > 0 else { return nil }
        let remaining = max(0, duration - (scrubbing ? scrubTarget : currentTime))
        return "Ends \(Date().addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened))"
    }

    /// Auto-advance when an episode ends: next episode if there is one, otherwise leave the player.
    private func autoAdvance() {
        if sleepAtEpisodeEnd {
            // Sleep timer set to "End of episode": this episode finished, so stop here instead of
            // auto-advancing. It is already marked watched (endFileEof), so Continue Watching rolls
            // forward on its own; do NOT finishedWatching (that would clear the whole series). Mirrors
            // PlayerScreen's endFileEof sleep-end branch.
            sleepAtEpisodeEnd = false
            saveProgress(at: currentTime)
            leavePlayback()
            return
        }
        if upNextSuppressed {
            // User chose Watch Credits: play through to the end, then stop here instead of auto-jumping.
            // The episode is marked watched, so Continue Watching rolls forward on its own.
            saveProgress(at: currentTime)
            leavePlayback()
            return
        }
        if hasNextEpisode {
            // "Still watching?" binge guard: after N back-to-back auto-advances with zero remote input,
            // pause at this boundary and ask instead of rolling straight on (Continue resumes the roll).
            consecutiveAutoAdvances += 1
            if stillWatchingPromptEnabled, consecutiveAutoAdvances >= max(1, stillWatchingAfterEpisodes) {
                presentStillWatching(pendingAdvance: true)
            } else {
                playNext()
            }
            return
        }
        guard let m = curMeta else {
            saveProgress(at: currentTime)
            leavePlayback()
            return
        }
        if m.usesSeriesLifecycle {
            let decision = terminalSeriesDecision(for: m)
            if decision == .refresh, !terminalFinalityRefreshUsed {
                refreshTerminalSeriesInventory(for: m)
                return
            }
        } else if terminalRewindGate.issueTerminalRewind() {
            core.finishedWatching(libraryId: m.libraryId, target: playbackMutationTarget)
        }
        // A movie/explicit owner rewind owns the final state. Do not write a stale end-position
        // TimeChanged/progress flush after it; series no-successor state remains engine/account-owned.
        if terminalRewindGate.permitsExitProgressFlush { saveProgress(at: currentTime) }
        leavePlayback()   // terminal: free the engine, then dismiss
    }

    private func episodeSwitchIsCurrent(generation: Int, sourceGeneration: Int,
                                        videoID: String) -> Bool {
        !leftPlayback
            && generation == episodeSwitchGeneration
            && sourceGeneration == sourceSwitchGeneration
            && pendingAdvance?.generation == generation
            && pendingAdvance?.meta.videoId == videoID
    }

    private var currentEpisodeResolutionOwner: EpisodeResolutionOwner? {
        guard let pending = pendingAdvance else { return nil }
        return EpisodeResolutionOwner(
            episodeGeneration: episodeSwitchGeneration,
            sourceGeneration: sourceSwitchGeneration,
            videoID: pending.meta.videoId
        )
    }

    private func armEpisodeResolutionDeadline(owner: EpisodeResolutionOwner) {
        episodeResolutionTask?.cancel()
        episodeResolutionDeadlineTask?.cancel()
        episodeResolutionOwner = owner
        episodeResolutionAdmitted = false
        episodeResolutionDeadlineTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.episodeResolutionDeadlineSeconds))
            guard !Task.isCancelled else { return }
            let decision = EpisodeResolutionDeadlinePolicy.decision(
                captured: owner,
                current: currentEpisodeResolutionOwner,
                pendingVideoID: pendingAdvance?.meta.videoId,
                admitted: episodeResolutionAdmitted,
                exited: leftPlayback
            )
            guard decision == .timeOut else { return }
            episodeResolutionTask?.cancel()
            episodeResolutionTask = nil
            episodeResolutionDeadlineTask = nil
            episodeResolutionOwner = nil
            episodeResolutionAdmitted = false
            pendingAdvance = nil
            if restoreSupersededAdvance() { return }
            switchingEpisode = false
            reconnecting = false
            buffering = false
            loadErrorMsg = "No playable source resolved within 30 seconds."
            DiagnosticsLog.log(
                "binge",
                "episode resolve deadline reached before player admission for \(VXProbeRedaction.identityToken(owner.videoID))"
            )
            presentTerminalLoadFailure()
        }
    }

    private func failEpisodeResolutionIfCurrent(
        owner: EpisodeResolutionOwner,
        message: String
    ) {
        guard owner == currentEpisodeResolutionOwner,
              !episodeResolutionAdmitted else { return }
        episodeResolutionDeadlineTask?.cancel()
        episodeResolutionTask = nil
        episodeResolutionDeadlineTask = nil
        episodeResolutionOwner = nil
        episodeResolutionAdmitted = false
        pendingAdvance = nil
        if restoreSupersededAdvance() { return }
        switchingEpisode = false
        reconnecting = false
        buffering = false
        loadErrorMsg = message
        presentTerminalLoadFailure()
    }

    /// Player admission and deadline retirement happen in the same MainActor turn as the exact
    /// active load-token publication. A deadline can therefore never race a successfully issued load.
    private func admitEpisodeResolutionIfCurrent() {
        guard let owner = episodeResolutionOwner,
              owner == currentEpisodeResolutionOwner else { return }
        episodeResolutionAdmitted = true
        episodeResolutionDeadlineTask?.cancel()
        episodeResolutionDeadlineTask = nil
    }

    private func invalidateEpisodeResolution() {
        clearPendingManualEpisodeNavigation(reason: "episode resolution cancelled")
        episodeResolutionTask?.cancel()
        episodeResolutionDeadlineTask?.cancel()
        episodeResolutionTask = nil
        episodeResolutionDeadlineTask = nil
        episodeResolutionOwner = nil
        episodeResolutionAdmitted = false
    }

    private func currentEpisodeSourceSnapshot() -> EpisodeSourceSnapshot {
        let stream = curSourceStream
        return EpisodeSourceSnapshot(
            url: curURL, headers: curHeaders, stream: stream, debridRef: curDebridRef,
            hint: curHint, binge: curBinge, isTorrent: curIsTorrent, isLive: curIsLive,
            engineVideoID: enginePlayerVideoId,
            engineAddonBase: stream.flatMap { engineAddonBase(for: $0) },
            resumeSeconds: resumeSeconds
        )
    }

    private func restoreEpisodeSourceSnapshot(_ source: EpisodeSourceSnapshot,
                                              for pending: PendingEpisodeAdvance) {
        curURL = source.url
        curHeaders = source.headers
        curSourceStream = source.stream
        curDebridRef = source.debridRef
        curHint = source.hint
        curBinge = source.binge
        curIsTorrent = source.isTorrent
        curIsLive = source.isLive
        resumeSeconds = source.resumeSeconds
        // A snapshot resume is a STORED offset, never a live play head, so retire the recovery marker with it:
        // this restore is reachable with the marker still set (handleMidPlayFailure -> hopToNextSource ->
        // switchStream bails before its own clear), and leaving it true lets maybeResume skip the near-end guard.
        resumeIsMidPlayRecovery = false
        if let stream = source.stream {
            let succeeded = core.loadEnginePlayer(
                for: stream, videoId: pending.meta.videoId,
                base: source.engineAddonBase, resolvedURL: source.debridRef?.url
            )
            enginePlayerVideoId = EpisodePlaybackIdentity.boundVideoID(
                requestedVideoID: pending.meta.videoId, bindingSucceeded: succeeded
            )
        } else {
            enginePlayerVideoId = source.engineVideoID
        }
    }

    @discardableResult
    private func restoreSupersededAdvance() -> Bool {
        guard let superseded = supersededAdvance,
              !superseded.pending.terminal,
              PlayerLoadProvenanceState.accepts(
                callbackToken: superseded.pending.loadToken,
                activeToken: coordinator.player?.activeLoadToken
              ) else {
            supersededAdvance = nil
            return false
        }
        var restored = superseded.pending
        restored.generation = episodeSwitchGeneration
        pendingAdvance = restored
        pendingAdvance?.generation = episodeSwitchGeneration
        restoreEpisodeSourceSnapshot(superseded.source, for: restored)
        supersededAdvance = nil
        switchingEpisode = true
        reconnecting = true
        buffering = true
        return true
    }

    /// Reset physical-load runtime only after the replacement command has produced an exact active token.
    /// While an episode is merely resolving, every flag below still describes the outgoing file and must
    /// remain intact for its callbacks, engine routing, persistence, and subtitle publication fences.
    private func resetRuntimeForIssuedEpisode() {
        clearCachedAudioOutputTruth()
        clearPostFrameResumeSeekWatchdog()
        buffering = true; hasStartedPlaying = false; appliedResume = false
        loadFailed = false; resumeSeconds = nil
        // A DIFFERENT episode resumes from ITS stored offset, so the near-end guard applies again.
        resumeIsMidPlayRecovery = false
        appliedAutoTracks = false; autoAddonSubTried = false; userPickedSubtitle = false
        addonSubsResolveTried = false; appliedVolume = false; appliedSize = false
        inFlightSeekTarget = nil; pendingLibmpvResumeSeek = nil
        watchedZoneSince = nil
        suppressedResumeFloor = nil
        avEngineFailed = false
        currentPickWasExplicit = false; bufferGraceUsed = 0; lastBufferedAtWatchdog = -1
        currentPlaybackIsResume = false; resumeSourceReresolved = false
        nativeDebridFreshLinkRecovery.reset()
        directAVNoFrameRecovery = nil
        libmpvStartupNudgeIssued = false
        subFingerprint = nil; subFingerprintKey = ""; pooledSubs = []
        subtitlePoolRequests.invalidate(); subtitleLoadingURL = nil
        addedPooledIDs = []; pooledSeededOffset = false; embeddedUploadDone = false
        markedWatched = false
        autoAddedThisPlayback = false
        upNextSuppressed = false; upNextWantsCredits = false
        sourceHops = 0; exhaustedURLs = []
        recoveryDeadline?.cancel(); recoveryDeadline = nil
        midPlayRecoveryCount = 0; midPlayFailureOwner = nil
        stallRecoveries = 0; stallStableProgressTicks = 0; stalledTicks = 0; stallNudgesIssued = 0
        midPlayBufferedReloadUsed = false; lastObservedTime = -1
        resetRapidBufferingRecovery(reason: "accepted episode issue")
        pendingAudioReapply = nil; pendingSubtitleReapply = nil
        pendingTransportIntent = nil
        pendingBoundaryAdvanceAfterPlay = false
    }

    /// Device-local resume for an already-prepared episode. The optional Stremio
    /// two-way mirror is deliberately excluded because it can require a remote
    /// library fetch and must not delay an admitted warm source.
    private func localPreparedResumeOffset(for meta: PlaybackMeta) -> Double {
        if !ProfileStore.shared.activeUsesEngineHistory {
            return ProfileStore.shared.resumeOffset(for: meta)
        }
        return core.engineResumeSeconds(for: meta)
            ?? CoreBridge.shared.engineResumeSecondsByLibraryId(for: meta)
            ?? 0
    }

    /// Switch to another episode in place: flush progress, resolve a stream through the ENGINE (same path
    /// as launch), then reload mpv. If the next episode was prepared in the background, it issues its
    /// already-ranked best source without another source or debrid resolution. The single live player still
    /// mounts and decodes that source here.
    private func play(episode v: CoreVideo) {
        guard let m = curMeta, !leftPlayback else { return }
        cancelDirectResumeInventoryRefresh()
        clearPendingManualEpisodeNavigation(reason: "episode replacement")
        // A repeated Prev/Next press while this exact target is resolving is reentry, not supersession. curMeta
        // deliberately remains on the outgoing episode until first frame, so recomputing the neighbour otherwise
        // selects the same target and cancels/restarts its slow resolve forever. A genuinely different episode
        // still falls through and supersedes as before.
        if let pending = pendingAdvance,
           pending.meta.videoId == v.id,
           !pending.terminal {
            DiagnosticsLog.log(
                "binge",
                "episode reentry ignored target=\(VXProbeRedaction.identityToken(v.id)); pending resolution retained"
            )
            return
        }
        let preparedEpisode = preloaded?.episodeID == v.id ? preloaded : nil
        // The old episode's producer and ranged warm read no longer own the player. Preserve only the engine
        // behind the exact prepared target being consumed below; every stale completion is generation-fenced.
        if preparedEpisode != nil {
            suspendNextEpisodePreparationForAdmission(reason: "episode switch")
        } else {
            invalidateNextEpisodePreparation(reason: "episode switch")
        }
        if let pending = pendingAdvance, pending.issued {
            supersededAdvance = SupersededEpisodeAdvance(
                pending: pending, source: currentEpisodeSourceSnapshot()
            )
        }
        switchingEpisode = true
        episodeSwitchGeneration &+= 1
        let episodeGeneration = episodeSwitchGeneration
        resumeRetryGeneration &+= 1
        sourceSwitchGeneration &+= 1
        let sourceGeneration = sourceSwitchGeneration
        autoRetryTask?.cancel()
        saveProgress(at: currentTime)
        // Snapshot the engine we're leaving so a DIFFERENT-hash next source can free it - but only
        // ONCE the real next hash is known, never speculatively here. Destroying a SAME-hash engine
        // is the harmful case (a season-pack torrent shares one infoHash across every episode, just a
        // different file index; recreate is a harmless no-op since the server is first-create-wins, but
        // destroy-then-recreate leaves warm-up seeing 0 peers / 0 bytes). So the close moves to wherever
        // the next stream is resolved:
        //   • PRELOAD path: the next stream is known synchronously below → close right there if its hash
        //     differs. A same-hash preload (manual ep switch on a season pack) keeps the live engine.
        //   • ENGINE-resolved FALLBACK (manual nav with no preload - episodes panel, Prev, an early Next):
        //     the hash isn't known until the async resolve, so we do NOT pre-close; the fallback closes
        //     the old engine after it resolves a different-hash stream, mirroring switchStream's guard.
        // A genuinely different-hash old engine is still always freed (the resolved-stream close below,
        // or leavePlayback() on a real exit), so nothing piles up.
        let leavingHash = currentTorrentHash
        withAnimation { showOptions = false }
        let newMeta = PlaybackMeta(libraryId: m.libraryId, videoId: v.id, type: "series",
                                   name: m.name, poster: m.poster, season: v.season, episode: v.episode)
        // PUBLISH-AT-FIRST-FRAME (binge-desync fix): do NOT advance curMeta/curTitle here. The old
        // optimistic publish put the label, the episode selector, the watched marker, and every engine/
        // account attribution read on the NEW episode while the player still held (or was still resolving)
        // the OLD file - and an advance interrupted across a background boundary stranded them there
        // forever. The advance is parked in `pendingAdvance` and published atomically at the incoming
        // file's first frame (timePos handler); until then every surface keeps naming the OUTGOING
        // episode, which is what is actually rendering, and the spinner line says what is loading.
        pendingAdvance = PendingEpisodeAdvance(
            meta: newMeta,
            title: "\(m.name) · S\(v.season ?? 0)E\(v.episodeNumber) · \(v.episodeTitle)",
            generation: episodeGeneration)
        let resolutionOwner = EpisodeResolutionOwner(
            episodeGeneration: episodeGeneration,
            sourceGeneration: sourceGeneration,
            videoID: v.id
        )
        armEpisodeResolutionDeadline(owner: resolutionOwner)
        showInfo = true; selected = .play; flashControls()

        // The preload already fetched and ranked this episode across every add-on → play it now.
        if let pre = preparedEpisode {
            guard EpisodePlaybackIdentity.canIssueEpisodeSwitch(
                currentVideoID: curMeta?.videoId, targetVideoID: v.id,
                currentURL: curURL, targetURL: pre.url
            ) else {
                discardPreparedEpisode(pre, reason: "episode admission rejected duplicate media")
                pendingAdvance = nil
                if restoreSupersededAdvance() { return }
                switchingEpisode = false; reconnecting = false
                loadErrorMsg = "That episode resolved to the current episode's file."
                presentTerminalLoadFailure()
                return
            }
            episodeResolutionTask = Task { @MainActor in
                guard episodeSwitchIsCurrent(
                    generation: episodeGeneration, sourceGeneration: sourceGeneration,
                    videoID: v.id
                ) else {
                    discardPreparedEpisode(pre, reason: "episode admission became stale")
                    return
                }
                core.loadMeta(type: "series", id: m.libraryId, streamType: "series", streamId: v.id)
                // The prepared source must issue immediately. Only device-local resume authorities are read
                // here; optional two-way Stremio sync can perform a network fetch and must never put that fetch
                // back in front of an already-warm player command.
                let resolvedResume = localPreparedResumeOffset(for: newMeta)
                guard episodeSwitchIsCurrent(
                    generation: episodeGeneration, sourceGeneration: sourceGeneration,
                    videoID: v.id
                ) else {
                    discardPreparedEpisode(pre, reason: "episode admission became stale before issue")
                    return
                }
                DiagnosticsLog.log("binge", "auto-next PRELOAD: wanted binge=\(curBinge ?? "nil") got=\(pre.bingeGroup ?? "nil") name=\(pre.stream.name?.prefix(60) ?? "")")
                pendingAdvance?.url = pre.url
                pendingAdvance?.debridRef = pre.debridRef
                pendingAdvance?.subtitleTimingScope = subtitleTimingScope(
                    for: newMeta,
                    stream: pre.stream
                )
                let base = pre.addonBase.flatMap { URL(string: $0)?.scheme == nil ? nil : $0 }
                let expectedPreparedRemuxOwner = VortXPreparedRemuxOwnerIdentity(
                    mediaID: v.id,
                    generation: UInt64(max(0, pre.generation)),
                    sourceSignature: pre.signature
                )
                guard let issuedToken = loadIntoPlayer(
                    pre.url, headers: pre.stream.requestHeaders,
                    live: isLiveMeta(newMeta) && !(pre.debridRef == nil && pre.stream.isTorrent),
                    contentHint: pre.signature, resumeOrigin: resolvedResume,
                    preparedRemux: pre.preparedRemux,
                    expectedPreparedRemuxOwner: expectedPreparedRemuxOwner
                ) else {
                    discardPreparedEpisode(pre, reason: "player rejected prepared episode command")
                    if episodeSwitchIsCurrent(
                        generation: episodeGeneration, sourceGeneration: sourceGeneration,
                        videoID: v.id
                    ) {
                        pendingAdvance = nil
                        if restoreSupersededAdvance() { return }
                        switchingEpisode = false
                        loadErrorMsg = "The player could not issue this episode."
                        presentTerminalLoadFailure()
                    }
                    return
                }
                guard episodeSwitchIsCurrent(
                    generation: episodeGeneration, sourceGeneration: sourceGeneration,
                    videoID: v.id
                ) else {
                    discardPreparedEpisode(pre, reason: "prepared command lost admission ownership")
                    return
                }
                // The exact engine accepted the replacement. Only now publish source state and retire the
                // superseded physical source, so a command failure leaves E3 fully recoverable.
                let preparedTorrentAdopted = consumePreparedEpisode(pre)
                let rawTorrent = pre.debridRef == nil && pre.stream.url == nil
                    && pre.stream.infoHash?.isEmpty == false
                if PreparedTorrentAdmissionPolicy.shouldIssuePlaybackCreate(
                    rawTorrent: rawTorrent,
                    leaseAdopted: preparedTorrentAdopted
                ) {
                    prepareTorrent(pre.stream)
                }
                resetRuntimeForIssuedEpisode()
                resumeSeconds = resolvedResume
                curHint = pre.signature
                curBinge = pre.bingeGroup
                curSourceStream = pre.stream
                curIsTorrent = pre.debridRef == nil && pre.stream.isTorrent
                curHeaders = pre.stream.requestHeaders
                curIsLive = isLiveMeta(newMeta) && !curIsTorrent
                curURL = pre.url
                curDebridRef = pre.debridRef
                coordinator.player?.setSubDelay(0)
                torrentWarmupsUsed = 0; torrentStatus = nil; stallRecoveries = 0
                if let oldHash = leavingHash, oldHash != pre.stream.infoHash?.lowercased() {
                    closeTorrent(hash: oldHash)
                }
                let succeeded = core.loadEnginePlayer(
                    for: pre.stream, videoId: v.id, base: base,
                    resolvedURL: pre.debridRef?.url
                )
                enginePlayerVideoId = EpisodePlaybackIdentity.boundVideoID(
                    requestedVideoID: v.id, bindingSucceeded: succeeded
                )
                invalidateLocalTrickplayCapture()
                currentTime = 0; duration = 0; bufferedTime = 0; lastSaved = -1
                pendingAdvance?.loadToken = issuedToken
                pendingAdvance?.issued = true
                startLoadTimeout()
                // Belt-and-braces fallback (kept): once the engine's OWN streams for this episode land, re-point
                // off the resident stream too (idempotent, confirms the gate). Covers a synchronous re-point that
                // could not build a request (missing base / meta), so CW still catches up when the add-ons answer.
                for _ in 0..<60 {
                    guard episodeSwitchIsCurrent(
                        generation: episodeGeneration, sourceGeneration: sourceGeneration,
                        videoID: v.id
                    ) else { return }
                    if enginePlayerVideoId == nil,
                       !core.streamGroups(forStreamId: v.id).isEmpty {
                        let retried = core.loadEnginePlayer(
                            for: pre.stream, videoId: v.id, base: base,
                            resolvedURL: pre.debridRef?.url
                        )
                        enginePlayerVideoId = EpisodePlaybackIdentity.boundVideoID(
                            requestedVideoID: v.id, bindingSucceeded: retried
                        )
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            return
        }

        episodeResolutionTask = Task { @MainActor in
            guard episodeSwitchIsCurrent(
                generation: episodeGeneration, sourceGeneration: sourceGeneration,
                videoID: v.id
            ) else { return }
            let settlementStartedAt = Date()
            core.loadMeta(type: "series", id: m.libraryId, streamType: "series", streamId: v.id)
            // Wait for THIS episode's streams (matched by id), then take the RANKED best across
            // add-ons: either every add-on has answered or the request-owned bounded deadline expires.
            var loggedBingeSourceWait = false
            let wantedAddon = seriesSticky?.addon               // the source the viewer picked BY HAND for this show
            while true {
                guard episodeSwitchIsCurrent(
                    generation: episodeGeneration, sourceGeneration: sourceGeneration,
                    videoID: v.id
                ) else { return }
                let groups = core.streamGroups(forStreamId: v.id)
                let progress = core.streamLoadProgress(forStreamId: v.id)
                // Settlement is contributor-complete or request-deadline bounded. Quality and sticky hints are
                // ranking inputs only, so a fast Comet 1080p cannot open before the user's aggregator lands.
                let elapsed = Date().timeIntervalSince(settlementStartedAt)
                let deadlineReached = elapsed >= StreamRanking.completeSetDeadline
                let settled = StreamRanking.resolveSettled(
                    groups, loaded: progress.loaded, total: progress.total,
                    secondsSinceRequestStart: elapsed, rememberedQuality: curHint,
                    wantedAddon: wantedAddon
                )
                if let wanted = wantedAddon, !wanted.isEmpty {
                    let wantedPresent = groups.contains { g in
                        g.addon.caseInsensitiveCompare(wanted) == .orderedSame
                            && g.streams.contains { $0.playableURL != nil && !$0.isYouTubeTrailer }
                    }
                    if settled {
                        DiagnosticsLog.log("binge", "auto-next gate OPEN wanted=\(wanted) present=\(wantedPresent ? "Y" : "N") elapsed=\(Int(elapsed))s loaded=\(progress.loaded)/\(progress.total)")
                    } else if !loggedBingeSourceWait {
                        loggedBingeSourceWait = true
                        DiagnosticsLog.log("binge", "auto-next gate WAIT holding for wanted=\(wanted) elapsed=\(Int(elapsed))s loaded=\(progress.loaded)/\(progress.total)")
                    }
                }
                if settled {
                    // Same sticky + provider-health terms the preload ranks with, so the fallback lane cannot
                    // quietly pick a different provider than the preload would have for the same episode. This
                    // is an ADVANCE, so sticky is SOFT: it yields to a materially better tier/cache for the new
                    // episode instead of sticking to the hand-picked source, and only holds among near-identical
                    // releases so a binge stays consistent (diag-21). Keep this in lockstep with resolvePreloadedEpisode.
                    let candidates = StreamRanking.rankedCandidates(
                        groups, continuity: curHint, binge: curBinge, pin: sourcePin,
                        sticky: seriesSticky, stickyAuthoritative: false,
                        providerPenalty: { ProviderHealth.penaltyActive(addonName: $0) },
                        debridCachedHashes: debridCachedHashes
                    )
                    let hint = episodeHint(for: newMeta)
                    var selected: (stream: CoreStream, url: URL, ref: DebridPlaybackRef?)?
                    for candidate in candidates {
                        let ref: DebridPlaybackRef?
                        if candidate.url == nil, hint == nil {
                            ref = nil
                        } else {
                            ref = await DebridCoordinator.shared.resolvedPlaybackRef(
                                for: candidate, episode: hint,
                                waitForLocalUsenetNode: candidate.isUsenet,
                                usenetResolveTimeout: candidate.isUsenet ? .seconds(35) : .seconds(5)
                            )
                            guard episodeSwitchIsCurrent(
                                generation: episodeGeneration, sourceGeneration: sourceGeneration,
                                videoID: v.id
                            ) else { return }
                        }
                        if let url = EpisodePlaybackIdentity.resolvedEpisodeMediaURL(
                            isUsenet: candidate.isUsenet, resolvedURL: ref?.url,
                            fallbackURL: candidate.playableURL(isEpisode: true)
                        ) {
                            selected = (candidate, url, ref)
                            break
                        }
                    }
                    guard let selected else {
                        if deadlineReached { break }
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    let s = selected.stream
                    let u = selected.url
                    guard EpisodePlaybackIdentity.canIssueEpisodeSwitch(
                        currentVideoID: curMeta?.videoId, targetVideoID: v.id,
                        currentURL: curURL, targetURL: u
                    ) else {
                        pendingAdvance = nil
                        if restoreSupersededAdvance() { return }
                        switchingEpisode = false; reconnecting = false
                        loadErrorMsg = "That episode resolved to the current episode's file."
                        presentTerminalLoadFailure()
                        return
                    }
                    let resolvedResume = await account.resumeOffset(for: newMeta)
                    guard episodeSwitchIsCurrent(
                        generation: episodeGeneration, sourceGeneration: sourceGeneration,
                        videoID: v.id
                    ) else { return }
                    DiagnosticsLog.log("binge", "auto-next FALLBACK: wanted binge=\(curBinge ?? "nil") got=\(s.behaviorHints?.bingeGroup ?? "nil") name=\(s.name?.prefix(60) ?? "")")
                    pendingAdvance?.url = u
                    pendingAdvance?.debridRef = selected.ref
                    let nextHint = StreamRanking.signature(s)
                    let nextIsTorrent = selected.ref == nil && s.isTorrent
                    let nextIsLive = isLiveMeta(newMeta) && !nextIsTorrent
                    guard let issuedToken = loadIntoPlayer(
                        u, headers: s.requestHeaders, live: nextIsLive,
                        contentHint: nextHint, resumeOrigin: resolvedResume
                    ) else {
                        if episodeSwitchIsCurrent(
                            generation: episodeGeneration, sourceGeneration: sourceGeneration,
                            videoID: v.id
                        ) {
                            pendingAdvance = nil
                            if restoreSupersededAdvance() { return }
                            switchingEpisode = false
                            loadErrorMsg = "The player could not issue this episode."
                            presentTerminalLoadFailure()
                        }
                        return
                    }
                    guard episodeSwitchIsCurrent(
                        generation: episodeGeneration, sourceGeneration: sourceGeneration,
                        videoID: v.id
                    ) else { return }
                    if selected.ref == nil { prepareTorrent(s) }
                    resetRuntimeForIssuedEpisode()
                    resumeSeconds = resolvedResume
                    curBinge = s.behaviorHints?.bingeGroup
                    curHint = nextHint
                    curSourceStream = s
                    curHeaders = s.requestHeaders
                    curURL = u
                    curDebridRef = selected.ref
                    curIsTorrent = nextIsTorrent
                    curIsLive = nextIsLive
                    pendingAdvance?.subtitleTimingScope = subtitleTimingScope(
                        for: newMeta,
                        stream: s
                    )
                    coordinator.player?.setSubDelay(0)
                    if let oldHash = leavingHash, oldHash != s.infoHash?.lowercased() {
                        closeTorrent(hash: oldHash)
                    }
                    invalidateLocalTrickplayCapture()
                    let succeeded = core.loadEnginePlayer(
                        for: s, videoId: v.id,
                        base: engineAddonBase(for: s, groups: groups),
                        resolvedURL: selected.ref?.url
                    )
                    enginePlayerVideoId = EpisodePlaybackIdentity.boundVideoID(
                        requestedVideoID: v.id, bindingSucceeded: succeeded
                    )
                    currentTime = 0; duration = 0; bufferedTime = 0; lastSaved = -1
                    pendingAdvance?.loadToken = issuedToken
                    pendingAdvance?.issued = true
                    startLoadTimeout()
                    return
                }
                if deadlineReached { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard episodeSwitchIsCurrent(
                generation: episodeGeneration, sourceGeneration: sourceGeneration,
                videoID: v.id
            ) else { return }
            pendingAdvance = nil
            if restoreSupersededAdvance() { return }
            loadErrorMsg = "No playable source found for this episode."
            // The advance never ISSUED a load (no source resolved), so the player still coherently holds
            // the OUTGOING episode and every pointer still names it: cancel the pending advance outright.
            // (An advance whose ISSUED load then fails keeps its pendingAdvance, so the error overlay's
            // Retry reloads the incoming URL and a success still commits the right episode.)
            presentTerminalLoadFailure()
            switchingEpisode = false   // fallback resolve gave up: re-arm so the user can retry
        }
    }

    /// FIRST-FRAME COMMIT of a binge advance (the single publish point of the unified current-episode
    /// identity). Called from the timePos handler the moment the incoming file produces a frame:
    /// publishes the display identity (curMeta/curTitle) that play(episode:) parked, which in the same
    /// breath OPENS the enginePlayerVideoId `==` gates (re-pointed at engine-load time) and lets the
    /// LastStreamStore record that follows capture a matching (videoId, url) pair. No-op outside an
    /// advance, so launch playback, source switches, and stall reloads are untouched.
    @discardableResult
    private func commitPendingAdvanceOnFirstFrame(loadToken: PlayerLoadToken) -> Bool {
        guard let pending = pendingAdvance,
              pending.generation == episodeSwitchGeneration,
              PlayerLoadProvenanceState.canCommit(
                callbackToken: loadToken,
                activeToken: coordinator.player?.activeLoadToken,
                pendingToken: pending.loadToken
              ) else { return false }
        let acceptedSubtitleTimingScope = pending.subtitleTimingScope
        pendingAdvance = nil
        supersededAdvance = nil
        committedLoadToken = loadToken
        uncommittedIdentityBlocked = false
        curMeta = pending.meta
        curTitle = pending.title
        curDebridRef = pending.debridRef
        acceptSubtitleTimingReplacement(scope: acceptedSubtitleTimingScope, clearNewEngineDelay: false)
        // The caller replays deferredTrackList only after this scope is accepted.
        switchingEpisode = false
        playbackSessionID = UUID().uuidString
        if EpisodeTrickplayIdentityPolicy.shouldRekey(committedPendingAdvance: true) {
            scrubThumbnails.configure(localCacheKey: trickplayLocalCacheKey)
            lastLocalTrickplayCapture = -1000
            invalidateLocalTrickplayCapture()
            configureCommunityTrickplayProvisional()
        }
        // Code-level invariant (the extractable check; the app has no unit-test bundle): at commit, the
        // published episode IS the episode of the file that just first-framed - pending.url was kept in
        // step with curURL by play(episode:) and switchStream, so a mismatch here means a code path
        // moved curURL without telling the pending advance. Debug builds trap; user builds log.
        assert(pending.url == nil || pending.url == curURL,
               "binge-advance commit: published episode's media (\(pending.url?.lastPathComponent ?? "nil")) != loaded media (\(curURL?.lastPathComponent ?? "nil"))")
        if let u = pending.url, u != curURL {
            DiagnosticsLog.log("binge", "COMMIT MISMATCH: pending url \(VXProbeRedaction.identityToken(u.lastPathComponent)) != curURL \(VXProbeRedaction.identityToken(curURL?.lastPathComponent))")
        }
        DiagnosticsLog.log("binge", "advance committed at first frame -> \(VXProbeRedaction.identityToken(pending.meta.videoId)) (label/selector/store/engine-gate now agree)")
        return true
    }

    /// FOREGROUND RECONCILE of an interrupted binge advance. Outside an advance the published episode and
    /// the loaded file agree BY CONSTRUCTION (publish happens only at the incoming file's first frame), so
    /// there is nothing to re-derive here for normal playback - the mpv seam's enterForeground already
    /// restores decode + play state. The ONE state a background boundary can strand is an advance whose
    /// incoming load was ISSUED but never first-framed (the suspension killed the half-open connection, or
    /// tvOS froze the process mid-load): the chrome correctly still shows the OUTGOING episode plus the
    /// loading line, but the load itself may be dead. Re-issue the pending URL so the advance completes
    /// (and commits at ITS first frame) instead of hanging on a dead half-load. An advance whose load was
    /// never issued needs nothing: its resolve Task resumes with the app and either issues (-> first frame
    /// -> commit) or errors out (pendingAdvance cleared). Presentation NEVER moves here - the display is
    /// only ever advanced by the first-frame commit.
    private func reconcileAdvanceOnForeground() {
        guard let pending = pendingAdvance, pending.issued, !hasStartedPlaying, !loadFailed,
              let u = pending.url else { return }
        DiagnosticsLog.log("binge", "foreground reconcile: re-issuing interrupted advance load for \(VXProbeRedaction.identityToken(pending.meta.videoId))")
        buffering = true
        guard let loadToken = loadIntoPlayer(u, headers: curHeaders, live: curIsLive) else { return }
        pendingAdvance?.loadToken = loadToken
        startLoadTimeout()
    }

    // MARK: - Next-episode preparation (settled winner plus network and torrent-engine warm-up)

    /// The next episode's best stream, resolved in the background mid-episode. Fetched over the
    /// add-on HTTP protocol directly so the engine's `meta_details` (which the screen behind the
    /// player still shows) is never disturbed.
    private struct PreloadedEpisode {
        let episodeID: String
        let generation: Int
        let stream: CoreStream
        let url: URL
        let debridRef: DebridPlaybackRef?
        let signature: String
        let bingeGroup: String?
        let addonBase: String?
        let preparedResumeOrigin: Double
        var preparedRemux: VortXPreparedRemuxAttachment?
    }

    private struct PreloadResolution: Sendable {
        let stream: CoreStream
        let url: URL
        let debridRef: DebridPlaybackRef?
        let addonBase: String?
        let streamCount: Int
        let bingeStreamCount: Int
    }

    private struct PreloadAuxiliarySnapshot {
        let torbox: [CoreStream]
        let sourceIndex: [CoreStream]
        let mediaServers: [CoreStreamSourceGroup]
        let settlement: SourceSettlementDecision
    }

    /// Kick off one owned preload attempt. The pure policy turns the four-Hz player clock into at most three
    /// ordinary attempts plus one last credits attempt, so failure never becomes a fetch storm.
    private func preloadNextIfNeeded() {
        guard !switchingEpisode, !leftPlayback,
              let i = episodeIndex, i + 1 < allEpisodes.count else { return }
        let next = allEpisodes[i + 1]
        var preloadTarget = NextEpisodePreloadPolicy.Target(
            episodeID: next.id, generation: preloadGeneration
        )
        if let owned = preloadPolicy.target, owned != preloadTarget {
            invalidateNextEpisodePreparation(reason: "next episode changed")
            preloadTarget = .init(episodeID: next.id, generation: preloadGeneration)
        }
        guard let attempt = preloadPolicy.evaluate(
            target: preloadTarget,
            position: currentTime,
            duration: duration,
            now: ProcessInfo.processInfo.systemUptime
        ) else { return }

        let sources = account.streamSources
        // Snapshot the main-actor @State continuity hints here (on the main actor) so the background
        // Task never reads them off-main; the heavy fetch + ranking stays off-main and only the @State
        // writes hop back to the main actor.
        let hint = curHint
        let binge = curBinge
        let pin = sourcePin                     // snapshot on-main; the background rank uses it (#15)
        let sticky = seriesSticky               // same, for the remembered manual pick (diag-21)
        let nextID = next.id
        let nextSeason = next.season
        let nextEpisode = next.episodeNumber
        let currentMeta = curMeta ?? meta
        let identityRoles = SourceIndexIdentity.Roles(
            catalogID: currentMeta?.libraryId,
            defaultVideoID: nil,
            currentVideoID: next.id,
            kind: .series
        )
        let titleID = SourceIndexIdentity.resolve(identityRoles).titleID
        let target = SourceIndexIdentity.publicationTarget(
            identityRoles,
            season: next.season,
            episode: next.episode
        )
        let mediaTarget = SourceIndexIdentity.mediaServerTarget(
            preferring: target,
            metaID: currentMeta?.libraryId ?? titleID,
            videoID: next.id
        )
        AuxiliarySourcePipeline.refresh(
            target: target, torBox: preloadTorboxSearch, sourceIndex: preloadSourceIndex,
            isSignedIn: VortXSyncManager.shared.isSignedIn
        )
        preloadMediaServers.refresh(
            imdb: titleID,
            season: next.season,
            episode: next.episode,
            title: currentMeta?.name,
            publicationTarget: mediaTarget
        )
        let episodeToken = VXProbeRedaction.identityToken(next.id)
        plog.info("preloading next episode \(episodeToken, privacy: .public) from \(sources.count, privacy: .public) add-ons")
        // `evaluate` can preempt a timed-out or halfway owner for a credits attempt. Cancel that owner before
        // replacing its task so its URLSession and debrid work do not continue in parallel.
        preloadTask?.cancel()
        preloadTask = Task(priority: .utility) { @MainActor in
            async let rawGroups = Self.fetchPreloadSourceGroups(
                sources: sources,
                attemptSequence: attempt.sequence,
                episodeID: nextID,
                wantedAddonName: sticky?.addon,
                deadline: attempt.deadline
            )
            let auxiliary = await awaitPreloadAuxiliarySettlement(
                target: target,
                mediaTarget: mediaTarget,
                deadline: min(
                    attempt.deadline,
                    ProcessInfo.processInfo.systemUptime
                        + NextEpisodePreloadPolicy.addonFetchBudget
                )
            )
            let fetchedRawGroups = await rawGroups
            guard !Task.isCancelled, preloadPolicy.accepts(attempt) else { return }
            let torboxAuthorization = SourceIndexIdentity.mergeAuthorization(
                published: preloadTorboxSearch.publishedTarget, page: target
            )
            let sourceIndexAuthorization = SourceIndexIdentity.mergeAuthorization(
                published: preloadSourceIndex.publishedTarget, page: target
            )
            let mediaAuthorization = SourceIndexIdentity.mediaServerMergeAuthorization(
                published: preloadMediaServers.publishedTarget, page: mediaTarget
            )
            var completeGroups = TorBoxSearchSource.merge(
                authorizedBy: torboxAuthorization,
                auxiliary.torbox,
                into: fetchedRawGroups
            )
            completeGroups = SourceIndexServeSource.merge(
                authorizedBy: sourceIndexAuthorization,
                auxiliary.sourceIndex,
                into: completeGroups
            )
            completeGroups = MediaServerSource.merge(
                authorizedBy: mediaAuthorization,
                auxiliary.mediaServers,
                into: completeGroups
            )
            // The merged value below owns the rows needed for this attempt. Drop the preload-only publishers
            // now so thousands of auxiliary rows are not retained for the rest of playback. This point is
            // generation-fenced by accepts(attempt), so a preempted owner cannot clear a replacement attempt.
            if torboxAuthorization != nil {
                preloadTorboxSearch.clearResults()
            }
            if sourceIndexAuthorization != nil {
                preloadSourceIndex.clearResults()
            }
            if mediaAuthorization != nil {
                preloadMediaServers.clearResults()
            }
            let selected = await Self.resolvePreloadedEpisode(
                groups: completeGroups,
                season: nextSeason,
                episodeNumber: nextEpisode,
                continuityHint: hint,
                bingeGroup: binge,
                pin: pin,
                sticky: sticky,
                debridCachedHashes: debridCachedHashes,
                attemptDeadline: attempt.deadline
            )
            guard !Task.isCancelled else { return }
            let completion = preloadPolicy.complete(
                attempt,
                success: selected != nil,
                now: ProcessInfo.processInfo.systemUptime
            )
            guard completion != .stale, !Task.isCancelled else { return }
            preloadTask = nil
            DiagnosticsLog.log(
                "binge",
                "preload contributor settlement target=\(episodeToken) decision=\(String(describing: auxiliary.settlement)) groups=\(completeGroups.count)"
            )
            if let selected {
                let best = selected.stream
                let preparedMeta = currentMeta.map {
                    PlaybackMeta(
                        libraryId: $0.libraryId,
                        videoId: nextID,
                        type: "series",
                        name: $0.name,
                        poster: $0.poster,
                        season: nextSeason,
                        episode: next.episode
                    )
                }
                let preparedResumeOrigin = preparedMeta.map {
                    localPreparedResumeOffset(for: $0)
                } ?? 0
                DiagnosticsLog.log(
                    "binge",
                    "preload next ep: want binge=\(binge ?? "nil"), \(selected.bingeStreamCount) of \(selected.streamCount) streams carry a bingeGroup"
                )
                preloaded?.preparedRemux?.abandon(reason: "replacement tvOS prepared episode")
                preloaded = PreloadedEpisode(
                    episodeID: nextID,
                    generation: attempt.target.generation,
                    stream: best,
                    url: selected.url,
                    debridRef: selected.debridRef,
                    signature: StreamRanking.signature(best),
                    bingeGroup: best.behaviorHints?.bingeGroup,
                    addonBase: selected.addonBase,
                    preparedResumeOrigin: preparedResumeOrigin,
                    preparedRemux: nil
                )
                plog.info("preload ready: \(StreamRanking.qualityLabel(best), privacy: .public) for \(episodeToken, privacy: .public)")
            } else {
                plog.info("preload found nothing for \(episodeToken, privacy: .public); state=\(String(describing: completion), privacy: .public)")
            }
        }
    }

    /// Wait for the three auxiliary contributors registered for this exact episode. Empty and failed requests
    /// are terminal outcomes; a hung contributor is bounded by the same generation-owned batch deadline.
    @MainActor
    private func awaitPreloadAuxiliarySettlement(
        target: SourceIndexIdentity.TargetResolution,
        mediaTarget: SourceIndexIdentity.MediaServerTarget?,
        deadline: TimeInterval
    ) async -> PreloadAuxiliarySnapshot {
        var decision: SourceSettlementDecision = .waiting
        repeat {
            let expired = ProcessInfo.processInfo.systemUptime >= deadline
            decision = SourceSettlementPolicy.decide(
                raw: .terminal,
                auxiliary: [
                    preloadTorboxSearch.settlementState(for: target),
                    preloadSourceIndex.settlementState(for: target),
                    preloadMediaServers.settlementState(for: mediaTarget),
                ],
                deadlineExpired: expired
            )
            if decision.isSettled { break }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                break
            }
        } while !Task.isCancelled

        return PreloadAuxiliarySnapshot(
            torbox: SourceIndexIdentity.mergeAuthorization(
                published: preloadTorboxSearch.publishedTarget, page: target
            ) != nil
                ? preloadTorboxSearch.streams : [],
            sourceIndex: SourceIndexIdentity.mergeAuthorization(
                published: preloadSourceIndex.publishedTarget, page: target
            ) != nil
                ? preloadSourceIndex.streams : [],
            mediaServers: SourceIndexIdentity.mediaServerMergeAuthorization(
                published: preloadMediaServers.publishedTarget, page: mediaTarget
            ) != nil
                ? preloadMediaServers.groups : [],
            settlement: decision
        )
    }

    /// Fetch every account add-on inside one bounded attempt. Per-provider terminal nil results still advance
    /// the sliding window, while a whole-batch timeout returns the completed subset for deadline settlement.
    private nonisolated static func fetchPreloadSourceGroups(
        sources: [StreamSource],
        attemptSequence: Int,
        episodeID: String,
        wantedAddonName: String?,
        deadline: TimeInterval
    ) async -> [CoreStreamSourceGroup] {
        let remaining = max(0, min(
            NextEpisodePreloadPolicy.addonFetchBudget,
            deadline - ProcessInfo.processInfo.systemUptime
        ))
        guard remaining > 0, !Task.isCancelled else { return [] }
        let providerOrder = PreloadProviderRotation.order(
            count: sources.count,
            attemptSequence: attemptSequence,
            stride: NextEpisodePreloadPolicy.providerRotationStride,
            prioritizedIndex: wantedAddonName.flatMap { wanted in
                sources.firstIndex {
                    $0.name.caseInsensitiveCompare(wanted) == .orderedSame
                }
            }
        )
        let rotatedSources = providerOrder.map { sources[$0] }
        let rotatedFetched: [CoreStreamSourceGroup?] = await BoundedPreloadWorkPool.map(
            rotatedSources,
            limit: NextEpisodePreloadPolicy.addonConcurrencyLimit,
            timeoutNanoseconds: UInt64(remaining * 1_000_000_000),
            operationTimeoutFor: { source in
                let seconds = NextEpisodePreloadPolicy.requestTimeout(
                    addon: source.name,
                    wantedAddon: wantedAddonName
                )
                return UInt64(seconds * 1_000_000_000)
            }
        ) { source in
            await Self.fetchStreams(
                base: source.base,
                addon: source.name,
                id: episodeID,
                requestTimeout: NextEpisodePreloadPolicy.requestTimeout(
                    addon: source.name,
                    wantedAddon: wantedAddonName
                )
            )
        }
        let fetched = PreloadProviderRotation.restoreOriginalOrder(
            rotatedFetched,
            order: providerOrder,
            count: sources.count
        )
        return fetched.compactMap { $0 }
    }

    /// Rank and resolve only after raw and auxiliary contributor settlement produced one episode-scoped set.
    /// The absolute attempt deadline started before any contributor work, so resolution cannot extend the
    /// preparation beyond its generation owner.
    private nonisolated static func resolvePreloadedEpisode(
        groups: [CoreStreamSourceGroup],
        season: Int?,
        episodeNumber: Int,
        continuityHint: String?,
        bingeGroup: String?,
        pin: ResolvedPin?,
        sticky: (addon: String?, bingeGroup: String?)?,
        debridCachedHashes: Set<String>,
        attemptDeadline: TimeInterval
    ) async -> PreloadResolution? {
        guard !Task.isCancelled else { return nil }

        let allStreams = groups.flatMap(\.streams)
        // Snapshot the cache status BEFORE ranking (Beta 26 A2): the old code derived the hash set from the
        // already-rank-sliced `candidates`, so ranking ran cache-blind and the preload could warm a different
        // provider than the on-screen list would pick (diag-21 / "wanted binge=X got=Y"). Query the whole
        // episode-scoped raw-torrent set here, then feed the confirmed-cached set into rankedCandidates so a
        // cached source gets its +8000 and wins before the settle window closes.
        let episode = EpisodePlaybackIdentity.provenEpisodeNumbers(
            season: season,
            episode: episodeNumber
        ).map { DebridEpisode(season: $0.season, episode: $0.episode) }
        let hashes = Set(allStreams.compactMap { s -> String? in
            guard s.isTorrent, s.url == nil else { return nil }
            return s.infoHash?.lowercased()
        })
        guard !Task.isCancelled else { return nil }
        let cacheResults: DebridCacheCheckResult? = await Self.valueBeforePreloadDeadline(
            deadline: attemptDeadline
        ) {
            await DebridCoordinator.shared.cacheCheck(hashes: Array(hashes))
        }
        let cachedHashes: Set<String>
        switch cacheResults {
        case let .some(.success(results)):
            cachedHashes = Set(results.keys)
        case .some(.failure), .none:
            cachedHashes = []
        }
        guard !Task.isCancelled else { return nil }

        // Union the account-level snapshot the source list ranked with: it may know a hash this episode-scoped
        // cacheCheck did not reach before the deadline, so the preload does not fall cache-blind when its own
        // check came back empty (Beta 26 A2). The account set only ever contains confirmed-cached hashes, so
        // the union is a strict superset of what the launch path already trusted.
        let effectiveCachedHashes = cachedHashes.union(debridCachedHashes)

        // `sticky` is the source the viewer chose BY HAND for this show and `providerPenalty` demotes an add-on
        // that just failed. Both are what stop the preload drifting to whichever provider answers fastest -
        // the drift the "wanted binge=X got=Y" line has been reporting. Preload of the NEXT episode is an
        // ADVANCE, so sticky is SOFT here exactly as in `play(episode:)`: it yields to a materially better
        // tier/cache and otherwise holds among near-identical releases (diag-21). The two MUST match so the
        // preload cannot warm a different source than the advance would then pick.
        let candidates = StreamRanking.rankedCandidates(
            groups,
            continuity: continuityHint,
            binge: bingeGroup,
            pin: pin,
            sticky: sticky, stickyAuthoritative: false,
            providerPenalty: { ProviderHealth.penaltyActive(addonName: $0) },
            debridCachedHashes: effectiveCachedHashes
        )

        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            let ref: DebridPlaybackRef?
            let hash = candidate.infoHash?.lowercased()
            let canResolveCached = episode != nil && hash.map(effectiveCachedHashes.contains) == true
            if !NextEpisodePreloadPolicy.shouldResolveCandidate(
                hasDirectURL: candidate.url != nil,
                isUsenet: candidate.isUsenet, hasCachedEpisodeTorrent: canResolveCached
            ) {
                ref = nil
            } else {
                ref = await Self.valueBeforePreloadDeadline(
                    deadline: attemptDeadline
                ) {
                    await DebridCoordinator.shared.resolvedPlaybackRef(
                        for: candidate,
                        episode: episode,
                        confirmedCachedHashes: effectiveCachedHashes,
                        waitForLocalUsenetNode: candidate.isUsenet,
                        usenetResolveTimeout: candidate.isUsenet ? .seconds(35) : .seconds(5)
                    )
                } ?? nil
                guard !Task.isCancelled else { return nil }
            }
            guard let url = EpisodePlaybackIdentity.resolvedEpisodeMediaURL(
                isUsenet: candidate.isUsenet,
                resolvedURL: ref?.url,
                fallbackURL: candidate.playableURL(isEpisode: true)
            ) else { continue }
            return PreloadResolution(
                stream: candidate,
                url: url,
                debridRef: ref,
                addonBase: groups.first { $0.streams.contains(candidate) }?.id,
                streamCount: allStreams.count,
                bingeStreamCount: allStreams.filter {
                    $0.behaviorHints?.bingeGroup?.isEmpty == false
                }.count
            )
        }
        return nil
    }

    /// Race one remaining preload phase against the attempt's absolute wall
    /// clock deadline. Cancellation reaches the losing child.
    private nonisolated static func valueBeforePreloadDeadline<Value: Sendable>(
        deadline: TimeInterval,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0, !Task.isCancelled else { return nil }
        return await withTaskGroup(of: (Bool, Value?).self) { group in
            group.addTask {
                guard !Task.isCancelled else { return (false, nil) }
                return (true, await operation())
            }
            group.addTask {
                do {
                    try await Task<Never, Never>.sleep(
                        nanoseconds: UInt64(remaining * 1_000_000_000)
                    )
                } catch {
                    return (false, nil)
                }
                return (false, nil)
            }
            let first = await group.next()
            group.cancelAll()
            guard first?.0 == true else { return nil }
            return first?.1
        }
    }

    /// One add-on's streams for an episode, straight over the Stremio addon protocol.
    private nonisolated static func fetchStreams(
        base: String,
        addon: String,
        id: String,
        requestTimeout: TimeInterval
    ) async -> CoreStreamSourceGroup? {
        guard !Task.isCancelled else { return nil }
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        guard let url = URL(string: "\(base)/stream/series/\(escaped).json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        struct Response: Decodable { let streams: [CoreStream]? }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              !Task.isCancelled,
              let response = try? JSONDecoder().decode(Response.self, from: data),
              let streams = response.streams, !streams.isEmpty else { return nil }
        return CoreStreamSourceGroup(id: base, addon: addon, streams: streams)
    }

    /// Retire every async owner behind the prepared episode. Generation invalidation makes a completion that
    /// was already queued on the main actor harmless. A separately primed torrent is closed when it is no
    /// longer useful; a season-pack hash shared with the playing episode remains alive.
    private func invalidateNextEpisodePreparation(reason: String) {
        preloadGeneration &+= 1
        preloadTask?.cancel()
        preloadTask = nil
        warmNextTask?.cancel()
        warmNextTask = nil
        preloadPolicy.invalidate()
        preloadTorboxSearch.clearResults()
        preloadSourceIndex.clearResults()
        preloadMediaServers.clearResults()
        abandonPreparedTorrentEngine(fallback: preloaded)
        preloaded?.preparedRemux?.abandon(reason: reason)
        preloadTorrentLease = nil
        preloaded = nil
        warmedID = nil
        VXProbe.log("binge", "next episode preparation invalidated: \(reason)")
    }

    /// Stop every producer while retaining the exact ready value and engine until
    /// the replacement player command is admitted. A rejection can still clean it
    /// up; a successful admission adopts it.
    private func suspendNextEpisodePreparationForAdmission(reason: String) {
        preloadGeneration &+= 1
        preloadTask?.cancel()
        preloadTask = nil
        warmNextTask?.cancel()
        warmNextTask = nil
        preloadPolicy.invalidate()
        warmedID = nil
        VXProbe.log("binge", "next episode preparation suspended: \(reason)")
    }

    @discardableResult
    private func consumePreparedEpisode(_ episode: PreloadedEpisode) -> Bool {
        guard preloaded?.episodeID == episode.episodeID,
              preloaded?.generation == episode.generation else { return false }
        let adopted = preloadTorrentLease?.adopt() == true
        preloadTorrentLease = nil
        preloaded = nil
        warmedID = nil
        // `engine=` names the TORRENT-ENGINE lease only, and a lease exists only for a RAW torrent preload
        // (`warmNextIfReady`'s `requiresTorrentPreparation` gate). A debrid or plain-URL preload never creates
        // one, so the old blanket "not-prepared" made every perfectly good debrid preload read as a failure -
        // and this line printing at all already proves the preload was admitted and issued. Report the SOURCE
        // KIND instead, and keep "not-prepared" for the one case it actually means something: a raw torrent
        // whose lease genuinely did not come up. Log text only - the lease semantics and every guard above
        // are unchanged.
        let kind: String
        if adopted { kind = "adopted" }
        else if episode.debridRef != nil { kind = "direct(debrid)" }
        else if episode.stream.url != nil { kind = "direct(url)" }
        else { kind = "not-prepared" }
        VXProbe.log("binge", "prepared episode admitted engine=\(kind)")
        return adopted
    }

    private func discardPreparedEpisode(_ episode: PreloadedEpisode, reason: String) {
        guard preloaded?.episodeID == episode.episodeID,
              preloaded?.generation == episode.generation else { return }
        abandonPreparedTorrentEngine(fallback: episode)
        episode.preparedRemux?.abandon(reason: reason)
        preloadTorrentLease = nil
        preloaded = nil
        warmedID = nil
        VXProbe.log("binge", "prepared episode discarded: \(reason)")
    }

    /// Close both an explicitly prepared lease and a raw-torrent fallback. The
    /// lease keeps the hash alive for a create completion that arrives after
    /// cancellation and will issue a second remove if still abandoned.
    private func abandonPreparedTorrentEngine(fallback: PreloadedEpisode?) {
        let lease = preloadTorrentLease
        _ = lease?.abandon()
        var hashes = Set<String>()
        if let lease { hashes.insert(lease.hash) }
        if fallback?.debridRef == nil,
           let hash = fallback?.stream.infoHash?.lowercased() {
            hashes.insert(hash)
        }
        for hash in hashes where hash != currentTorrentHash {
            closeTorrent(hash: hash)
        }
    }

    /// Prefix the libmpv-lane warm reads from the next-episode source. 32 MiB (was 16) so the warmed CDN-edge
    /// window covers what libmpv actually reads at a COLD open of a high-bitrate 4K stream - the container header
    /// PLUS `find_stream_info`'s analyzeduration probe, which on a ~40-80 Mbit/s source runs well past the first
    /// 16 MiB. The AVPlayer/remux lane (DV + debrid) does not use this: it pre-STARTS a real transport
    /// (prepareRemuxTransport) that is adopted at admission, so its jump is already near-instant. The plain
    /// libmpv lane cannot pre-open its demuxer without a second mpv core, which is deliberately not built (a
    /// jetsam-bound tvOS process cannot afford a second 4K pipeline, and a playlist-prefetch mount would bypass
    /// the resume-seek / first-frame-commit / Continue-Watching handoff); warming the edge across the real cold
    /// read window is the lightweight lever that removes most of the remaining gap.
    private static let nextEpisodeLibmpvWarmPrefixBytes = 32 << 20

    /// One ranged read of the chosen next-episode source shortly before the
    /// credits, so the provider has the file hot when auto-advance opens it; the
    /// cold start there is what used to cost 30 to 60 seconds. Torrents start
    /// their peer search at the same moment.
    private func warmNextIfReady() {
        guard NextEpisodePreloadPolicy.isTransportWarmEligible(
            position: currentTime,
            duration: duration
        ) else { return }
        guard let pre = preloaded, warmedID != pre.episodeID else { return }
        let url = pre.url
        let target = NextEpisodePreloadPolicy.Target(
            episodeID: pre.episodeID, generation: preloadGeneration
        )
        guard preloadPolicy.isReady(for: target) else { return }
        warmedID = pre.episodeID
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(Self.nextEpisodeLibmpvWarmPrefixBytes - 1)", forHTTPHeaderField: "Range")   // cover libmpv's cold open+probe read window
        for (name, value) in pre.stream.requestHeaders ?? [:] where name.lowercased() != "range" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.timeoutInterval = 60
        let log = plog
        let id = VXProbeRedaction.identityToken(pre.episodeID)
        log.info("warming next episode source for \(id, privacy: .public)")
        warmNextTask?.cancel()
        warmNextTask = Task(priority: .utility) {
            do {
                let requiresTorrentPreparation = pre.debridRef == nil
                    && pre.stream.url == nil
                    && pre.stream.infoHash?.isEmpty == false
                // Pick one transport warm-up before doing any network work. A prepared remux freezes the
                // same startup cohort the prefix GET would read, while raw torrents and ordinary direct
                // sources retain the existing bounded prefix warm-up.
                let mountIsOnDevice: Bool
                if case .onDevice = VortXExternalEngine.shared.mountPlan {
                    mountIsOnDevice = true
                } else {
                    mountIsOnDevice = false
                }
                let isDolbyVision = StreamRanking.isDolbyVision(pre.signature)
                let preparedMode = VortXPreparedRemuxCallerPolicy.mode(
                    avPlayerActive: coordinator.player is AVPlayerEngineController,
                    mountIsOnDevice: mountIsOnDevice,
                    rawTorrent: requiresTorrentPreparation,
                    dolbyVision: isDolbyVision,
                    dolbyVisionRemuxEligible: isDolbyVision
                        && PlayerEngineRouter.shouldDVRemux(url: pre.url),
                    plainRemuxEligible: !isDolbyVision
                        && PlayerEngineRouter.shouldPlainRemux(url: pre.url)
                )
                if requiresTorrentPreparation {
                    guard await preparePreloadedTorrent(
                        pre.stream,
                        target: target
                    ) else {
                        throw BoundedRangeWarmup.WarmupError.transport
                    }
                }
                let result: BoundedRangeWarmup.Result?
                if VortXPreparedRemuxCallerPolicy.transportWarmPath(
                    preparedMode: preparedMode
                ) == .prefixRange {
                    result = try await BoundedRangeWarmup.fetch(request)
                } else {
                    result = nil
                }
                try Task.checkCancellation()
                // This transport phase deliberately sits outside the source-selection deadline. It may queue
                // behind the current episode's one producer until the credits, but it creates no AVPlayerItem
                // or decoder. Raw torrents keep only the tracker-aware create lease above.
                let preparedRemux: VortXPreparedRemuxAttachment?
                if let preparedMode,
                   VortXRemuxHandoffPolicy.canRetainPreparedTransport(
                    avRouteActive: coordinator.player is AVPlayerEngineController,
                    handoffPending: avToMPVHandoff != nil,
                    taskCancelled: Task.isCancelled
                   ) {
                    let owner = VortXPreparedRemuxOwnerIdentity(
                        mediaID: pre.episodeID,
                        generation: UInt64(max(0, pre.generation)),
                        sourceSignature: pre.signature
                    )
                    if let handle = await AVPlayerEngineController.prepareRemuxTransport(
                        input: pre.url,
                        headers: pre.stream.requestHeaders,
                        mode: preparedMode,
                        startAtSeconds: pre.preparedResumeOrigin,
                        ownerIdentity: owner
                    ) {
                        preparedRemux = VortXPreparedRemuxAttachment(
                            handle: handle,
                            ownerIdentity: owner
                        )
                    } else {
                        preparedRemux = nil
                    }
                } else {
                    preparedRemux = nil
                }
                try Task.checkCancellation()
                if let result {
                    log.info("warm result for \(id, privacy: .public): status=\(result.statusCode, privacy: .public) bytes=\(result.byteCount, privacy: .public)")
                } else {
                    log.info("warm result for \(id, privacy: .public): prepared-remux transport")
                }
                let retained = await MainActor.run {
                    guard target.generation == preloadGeneration,
                          preloaded?.episodeID == target.episodeID,
                          preloaded?.generation == target.generation,
                          VortXRemuxHandoffPolicy.canRetainPreparedTransport(
                            avRouteActive: coordinator.player is AVPlayerEngineController,
                            handoffPending: avToMPVHandoff != nil,
                            taskCancelled: Task.isCancelled
                          ) else { return false }
                    if let preparedRemux {
                        preloaded?.preparedRemux?.abandon(
                            reason: "replacement tvOS prepared remux"
                        )
                        preloaded?.preparedRemux = preparedRemux
                    }
                    warmNextTask = nil
                    return true
                }
                if !retained {
                    preparedRemux?.abandon(reason: "stale tvOS prepared remux completion")
                }
            } catch {
                guard !Task.isCancelled else { return }
                log.info("warm result for \(id, privacy: .public): failed")
                await MainActor.run {
                    guard target.generation == preloadGeneration,
                          preloaded?.episodeID == target.episodeID,
                          preloaded?.generation == target.generation else { return }
                    warmNextTask = nil
                    if preloadPolicy.warmFailed(for: target) {
                        // Keep the already-ranked value as a last-resort admission candidate, but close the
                        // failed prepared engine. The credits refresh replaces it only if a better live value
                        // resolves, so a failed refresh cannot erase the only usable next source.
                        abandonPreparedTorrentEngine(fallback: pre)
                        preloadTorrentLease = nil
                        warmedID = nil
                        preloadNextIfNeeded()
                    }
                }
            }
        }
    }

    /// Prepare the raw-torrent engine under an owned, generation-fenced lease.
    /// Cancellation cannot resurrect a stale engine: an abandoned lease removes
    /// any create that still completes after invalidation.
    private func preparePreloadedTorrent(
        _ stream: CoreStream,
        target: NextEpisodePreloadPolicy.Target
    ) async -> Bool {
        guard !PlaybackSettings.torrentsDisabled else { return false }
        guard stream.url == nil,
              let hash = stream.infoHash?.lowercased(),
              let url = URL(string: "\(StremioServer.base)/\(hash)/create") else {
            return false
        }

        if let old = preloadTorrentLease, old.hash != hash {
            _ = old.abandon()
            if old.hash != currentTorrentHash { closeTorrent(hash: old.hash) }
        }
        let sources = TorrentTrackers.sources(forHash: hash, streamSources: stream.sources)
        let body: [String: Any] = [
            "torrent": ["infoHash": hash],
            "peerSearch": ["sources": sources, "min": 40, "max": 150]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return false
        }
        let lease = NextEpisodeTorrentPreparationLease(target: target, hash: hash)
        preloadTorrentLease = lease

        await StremioServer.applyServerConfig(maxAttempts: 3)
        guard !Task.isCancelled,
              target.generation == preloadGeneration,
              lease.currentDisposition == .active,
              preloadTorrentLease === lease,
              preloaded?.episodeID == target.episodeID,
              preloaded?.generation == target.generation else {
            _ = lease.abandon()
            if preloadTorrentLease === lease { preloadTorrentLease = nil }
            if currentTorrentHash != hash { closeTorrent(hash: hash) }
            return false
        }

        let status: Int
        do {
            status = try await TorrentCreateTransport.shared.create(url: url, jsonBody: data)
        } catch {
            status = 0
        }

        let stillOwned = !Task.isCancelled
            && status / 100 == 2
            && target.generation == preloadGeneration
            && lease.currentDisposition == .active
            && preloadTorrentLease === lease
            && preloaded?.episodeID == target.episodeID
            && preloaded?.generation == target.generation
        if stillOwned {
            _ = lease.markCreateSucceeded()
        } else {
            _ = lease.abandon()
            if preloadTorrentLease === lease { preloadTorrentLease = nil }
            if currentTorrentHash != hash { closeTorrent(hash: hash) }
        }
        VXProbe.log(
            "binge",
            "preload torrent prepare status=\(status) owned=\(stillOwned ? "true" : "false")"
        )
        return stillOwned && lease.canStartRangeWarmup
    }

    /// Torrents: ask the embedded server to start fetching peers before playback. No-op for url/debrid.
    private func prepareTorrent(_ stream: CoreStream) {
        guard !PlaybackSettings.torrentsDisabled else { return }
        guard stream.url == nil, let hash = stream.infoHash?.lowercased(),
              let url = URL(string: "\(StremioServer.base)/\(hash)/create") else { return }
        let sources = TorrentTrackers.sources(forHash: hash, streamSources: stream.sources)
        let body: [String: Any] = ["torrent": ["infoHash": hash],
                                   "peerSearch": ["sources": sources, "min": 40, "max": 150]]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        // Guarantee the TV-safe cache + connection cap is applied BEFORE this engine is created: the server
        // reads cacheSize + btMaxConnections at engine-creation time (enginefs.getDefaults), and the boot-time
        // apply can silently miss on a slow cold start -- leaving this engine at the 2 GB default cache + 55
        // connections, which jetsams the whole 2 GB Apple TV under torrent load (the owner's "server crash /
        // hang after finishing one title and opening another" report). A quick (<=3 try) VERIFIED apply here
        // makes every torrent engine start capped, not just when the one-shot boot POST happened to land.
        // No-op on a custom remote server (applyServerConfig returns immediately when isCustom).
        Task {
            await StremioServer.applyServerConfig(maxAttempts: 3)
            do {
                let status = try await TorrentCreateTransport.shared.create(url: url, jsonBody: data)
                if status / 100 != 2 {
                    DiagnosticsLog.log("torrent", "create HTTP \(status) for \(hash.prefix(8))")
                }
            } catch {
                DiagnosticsLog.log("torrent", "create failed for \(hash.prefix(8)): \(error.localizedDescription)")
            }
        }
    }

    /// Tell the embedded server to destroy a torrent engine (GET /{hash}/remove). Each engine
    /// holds peers, sockets, and a growing disk/RAM cache; leaving them running when we switch
    /// source, auto-fail over, advance an episode, or close the player piled them up until the
    /// server's RSS ballooned and it stopped answering (the 0.2.48 "torrents stopped playing,
    /// server went offline" regression). Symmetric with prepareTorrent's create.
    private func closeTorrent(hash: String) {
        let h = hash.lowercased()
        guard h.count == 40, let url = URL(string: "\(StremioServer.base)/\(h)/remove") else { return }
        DiagnosticsLog.log("torrent", "remove engine \(h.prefix(8))")
        URLSession.shared.dataTask(with: url).resume()
    }

    /// The single "user really left playback" exit. Destroys the live torrent engine (no-op for
    /// direct/debrid) right before dismissing, so the engine is freed on a GENUINE exit but never on
    /// a SwiftUI `.id(req.id)` rebuild - onDisappear no longer tears it down (see Fix B). Every real
    /// exit (Back-to-exit, the close button, the terminal auto-advance) routes through here, so no
    /// engine is leaked.
    private func leavePlayback() {
        resetRapidBufferingRecovery(reason: "playback exit")
        clearPostFrameResumeSeekWatchdog()
        let exitLoadToken = coordinator.player?.activeLoadToken
        let assetSanityAccepted = assetSanityAttempt.isAccepted(owner: exitLoadToken)
        cancelTerminalFinalityRefresh()
        cancelDirectResumeInventoryRefresh()
        exitAcceptedLoadToken = assetSanityAccepted ? exitLoadToken : nil
        leftPlayback = true   // FIRST: a pending EOF last-chance backfill must never resurrect a player the user left
        refindTask?.cancel(); refindTask = nil; refinding = false   // a settling re-find must not retry into a left player
        flushPendingSubOffsetSave()   // a debounced sync nudge must survive the viewer pressing Back immediately
        invalidateEpisodeResolution()
        eofFrozenAtTerminal = false; terminalAdvanceDeadlineTask?.cancel(); terminalAdvanceDeadlineTask = nil
        invalidateNextEpisodePreparation(reason: "playback exit")
        avToMPVHandoffTask?.cancel()
        invalidateLocalTrickplayCapture()
        cancelAssetSanityObservationDeadline()
        persistenceBlockedForExit = hasUncommittedIssuedMedia
        episodeSwitchGeneration &+= 1
        sourceSwitchGeneration &+= 1
        resumeRetryGeneration &+= 1
        pendingAdvance = nil
        supersededAdvance = nil
        switchingEpisode = false
        autoRetryTask?.cancel()
        coordinator.player?.invalidateLoadToken()
        // External sync (Trakt/SIMKL): scrobble STOP on a genuine user exit (Back / close / terminal
        // auto-advance). Additive + fail-soft + gated + once-latched inside the coordinator; a no-op with
        // empty creds. Near the end this records the watch (deduped against the 90%/EOF record); mid-title it
        // saves a resume/pause point (live scrobble only).
        if !persistenceBlockedForExit, assetSanityAccepted,
           !isCurrentLiveStream, let m = curMeta {
            ScrobbleCoordinator.shared.playbackStopped(
                m, position: max(currentTime, suppressedResumeFloor ?? 0), duration: duration
            )
        }
        if let hash = currentTorrentHash { closeTorrent(hash: hash) }
        // F5: capture whether this session had the DV remux mounted BEFORE stop() nils it. The remux lane and
        // the embedded node server share one jetsam budget, and on a stalled-CDN demote the remux thread + its
        // buffer can linger seconds; after teardown we re-assert the TV-safe server cache cap so the server's
        // footprint is nudged back down. Read via the same cast maybeResume uses.
        let wasRemuxMounted = (coordinator.player as? AVPlayerEngineController)?.isRemuxMounted == true
        // Force the OLD engine to halt decode + network and BEGIN teardown synchronously, right now, instead
        // of leaving it to whenever SwiftUI gets around to dismantle*. This is THE debrid crash fix: a debrid
        // title holds the FULL remote demuxer read-ahead + a 4K decoder, and without this stop() that engine
        // was still alive when the next title's player allocated its own buffers -- two decoding players
        // straddling on a 2 GB Apple TV jetsam-killed the whole device (the owner's "finish/stop, browse, open
        // another -> hang"). stop() is idempotent (guards on a live handle/item) so SwiftUI's later dismantle
        // is a harmless no-op, and this runs ONLY on a genuine exit (Back, close, terminal auto-advance), never
        // on an in-place source/episode switch or an onDisappear rebuild, so normal playback is untouched.
        coordinator.player?.stop()
        // Wipe the configurable on-disk streaming cache for the title that just finished/closed, so a
        // completed movie or episode never leaves its buffer on disk (the owner's clear-on-finish
        // guardrail). No-op when the disk cache is off or empty. This runs ONLY on a genuine exit
        // (Back / close / terminal auto-advance), never on an in-place source/episode switch, and is
        // additive: it does not touch the stop() teardown above.
        DiskCacheSetting.clearCache()
        if wasRemuxMounted { Self.replayServerConfigAfterRemux() }
        onClose()
    }

    /// F5: after a remux-mounted session tears down, re-assert the TV-safe streaming-server cache cap
    /// (maxAttempts:1, detached) and log the process resident footprint on either side, so a diagnostics
    /// export shows whether the remux lane's teardown actually returned RAM to the shared jetsam budget.
    /// Deliberately does NOT call malloc_zone_pressure_relief (excluded pending on-device evaluation).
    /// Fire-and-forget: applyServerConfig already fails soft, so this never affects the exit path.
    private static func replayServerConfigAfterRemux() {
        Task.detached(priority: .utility) {
            let before = VXProbe.residentMemoryMB()
            let ok = await StremioServer.applyServerConfig(maxAttempts: 1)
            let after = VXProbe.residentMemoryMB()
            let beforeText = before.map { String(format: "%.0f", $0) } ?? "?"
            let afterText = after.map { String(format: "%.0f", $0) } ?? "?"
            DiagnosticsLog.log("server", "post-remux server-config replay ok=\(ok) rssMB \(beforeText) -> \(afterText)")
        }
    }

    /// The 40-hex info-hash of the currently playing torrent, or nil for a direct/debrid stream. Classified by
    /// `streamingServerTorrentHash`, the SAME matcher `isTorrentPlayback` uses: this used to demand an exact
    /// host AND port of its own, so once the in-process server rebound a fresh ephemeral port under a mounted
    /// torrent this answered nil, `leavePlayback` skipped `closeTorrent`, and the swarm (peers/sockets/cache)
    /// leaked across plays - the RSS balloon the embedded path's remove() exists to prevent.
    private var currentTorrentHash: String? { streamingServerTorrentHash(of: curURL) }

    // MARK: - Playback helpers

    /// Seek to the saved position once BOTH the resume offset is fetched and the duration is known.
    /// No-op for live: a live stream's "position" is just elapsed buffer wall-clock, so seeking into a
    /// stored offset is meaningless (and would jump into the past). Mirrors PlayerScreen's live guard.
    private func maybeResume() {
        guard !isCurrentLiveStream else { return }
        guard !appliedResume, duration > 0, let r = resumeSeconds else { return }
        appliedResume = true
        // One-shot: the marker describes THIS value, and this is the moment it is spent.
        let midPlayRecovery = resumeIsMidPlayRecovery
        resumeIsMidPlayRecovery = false
        // The near-end rule exists for a FRESH play: a stored offset in the credits should start the title at 0
        // rather than drop the viewer into the last few seconds. A mid-play recovery is the opposite case - the
        // value is the live play head of a mount that just died - so applying it there restarted the whole
        // episode for a source that failed eight seconds from the end. The trivial-position floor still applies
        // either way.
        guard r > 5, midPlayRecovery || r < duration - 10 else {
            DiagnosticsLog.log(
                "playback",
                String(format: "resume decision=no-seek value=%.3fs duration=%.3fs", r, duration)
            )
            return
        }   // ignore trivial / (fresh-play) near-end positions
        // A remux resume is fulfilled before mount by rebuilding from the configured source origin. Do not seek
        // AVPlayer into a forward-only playlist after mount. Verify the achieved keyframe origin instead; only
        // a genuinely unreachable request needs the progress floor and an unavailable notice.
        if let av = coordinator.player as? AVPlayerEngineController,
           let origin = av.achievedRemuxTimelineOriginSeconds {
            // A5 mirror: a carried head at or past this asset's own duration is out of range for THIS stream
            // (a wrong or much shorter replacement), so do not land at the tail. Start from the beginning and
            // let A5b's sanity policy route a true decoy to a working source.
            if r >= duration {
                suppressedResumeFloor = nil
                currentTime = 0
                lastSaved = 0
                DiagnosticsLog.log("dv", "resume to \(Int(r))s past asset duration \(Int(duration))s; starting from 0")
                return
            }
            switch RemuxResumePolicy.preStartSeek(target: r, origin: origin) {
            case .satisfied:
                suppressedResumeFloor = nil
                // Never present a landed position past the end of this asset (mirrors the libmpv clamp).
                let landed = min(max(0, origin), max(0, duration - 5))
                currentTime = landed
                lastSaved = landed
                DiagnosticsLog.log("dv", "resume to \(Int(r))s satisfied by remux origin \(Int(origin))s")
            case .hidePreroll:
                // AVPlayerEngine issues the actual corrective local seek (root-cause report section 7); this
                // is only the UI/progress bookkeeping. Once that seek lands, the viewer sees `r`, not `origin`,
                // so report `r` here too - showing `origin` would desync the scrubber from the hidden frames.
                suppressedResumeFloor = nil
                let landed = min(max(0, r), max(0, duration - 5))
                currentTime = landed
                lastSaved = landed
                DiagnosticsLog.log("dv", "resume to \(Int(r))s hides \(String(format: "%.3f", r - origin))s of keyframe preroll from remux origin \(Int(origin))s")
            case .unreachable:
                let floor = min(max(0, r), max(0, duration - 5))
                suppressedResumeFloor = floor
                lastSaved = floor
                showEngineNote("That resume point is unavailable for this source. Playing from the earliest available position.")
                DiagnosticsLog.log("dv", "resume to \(Int(r))s unavailable from remux origin \(Int(origin))s; progress floor retained")
            }
            return
        }
        let resumeLane = coordinator.player is AVPlayerEngineController ? "avplayer" : "libmpv"
        // A5: clamp the carried resume head into THIS stream before seeking. A mid-play source switch hands over
        // the ORIGIN stream's live play head, which can land past the end of a different or much shorter
        // replacement asset (a 19.728s head seeked into an 8.000s decoy). A head at or past this duration is out
        // of range for this stream, so start from the beginning rather than jump to the tail; A5b's sanity policy
        // separately routes a true decoy to a working source. Otherwise clamp to 5s from the end (mirrors
        // scrubCeiling), NOT 10s, which would regress a legitimate near-credits recovery.
        let target = r >= duration ? 0 : min(max(0, r), max(0, duration - 5))
        DiagnosticsLog.log(
            "playback",
            String(format: "resume decision=seek value=%.3fs target=%.3fs duration=%.3fs", r, target, duration)
                + " lane=\(resumeLane) recovery=\(midPlayRecovery ? "Y" : "N")"
        )
        // Defer the seek to the first frame rather than issuing it now: a pre-first-frame absolute seek on a
        // cold libmpv pipeline arms the cache-emptying hold and wedges video output (blank + frozen timer). Once
        // the first frame has rendered the pipeline is warm, so applying it there makes it an ordinary scrub,
        // which is proven to render. The start watchdog recovers the case where that first frame never arrives.
        pendingLibmpvResumeSeek = target
        startLibmpvResumeWatchdog(target: target)
        currentTime = target
        lastSaved = target
        inFlightSeekTarget = target   // same guard as commitScrub: pre-resume ticks near 0 must not clobber the resume point
        inFlightSeekIssuedAt = Date().timeIntervalSinceReferenceDate
    }

    /// Persist the current position to the account library (no-op without a library context). Also a
    /// no-op for live: persisting a live "position" would seed a bogus resume offset / fake Continue
    /// Watching entry the next time the channel opens. Mirrors PlayerScreen's live progress suppression.
    /// `thenSyncEngine` (the EXIT flush only): after this save LANDS on the account API, ask the engine
    /// to reconcile its library copy (CoreBridge.syncLibraryNow). The player writes progress straight to
    /// the API, which the engine cannot see until a library sync - and none ran after playback, so the
    /// Home dashboard's Continue Watching timestamp (and the resume it feeds) stayed at the pre-playback
    /// value until a detail-page load happened to sync. Sequenced INSIDE the save task so the pull can
    /// never race ahead of the write it needs to fetch. Exit-only: the periodic 20s / pause saves must
    /// not each trigger an API library sync.
    private func saveProgress(
        at position: Double,
        thenSyncEngine: Bool = false,
        acceptedOwner: PlayerLoadToken? = nil
    ) {
        let integrityOwner = acceptedOwner ?? coordinator.player?.activeLoadToken
        guard assetSanityAttempt.isAccepted(owner: integrityOwner) else { return }
        guard !isCurrentLiveStream else { return }
        guard !hasUncommittedIssuedMedia, !persistenceBlockedForExit else { return }
        guard let m = curMeta, duration > 0, position >= 0 else { return }
        // A DV-remux play whose resume seek was suppressed (maybeResume) starts from 0: do not let the
        // periodic saves REGRESS the stored resume point below where the viewer actually was. Saves resume
        // once playback passes the old position (or the floor is cleared on the next title).
        if let floor = suppressedResumeFloor {
            if position < floor { return }
            suppressedResumeFloor = nil
        }
        let dur = duration
        Task {
            await account.saveProgress(for: m, positionSeconds: position, durationSeconds: dur,
                                       target: playbackMutationTarget)
            if thenSyncEngine { await MainActor.run { core.syncLibraryNow() } }
        }
    }

    private func toggle() {
        if loadFailed { retryLoad(); return }   // Play/Pause retries a failed source
        coordinator.player?.togglePause()
        showControls()
    }

    /// A9: single logged choke point for an ABSOLUTE seek so the exportable trail shows every jump (reason,
    /// from, to, duration). Relative ±skips stay on `seek(by:)` below to keep their no-cache-hold behavior
    /// (an absolute `seek(to:)` arms the cache hold and empties the forward buffer, which a small hop must
    /// not), but they emit the same line for a complete trail. maybeResume logs its own resume line.
    private func issueSeek(to target: Double, reason: String) {
        cancelPendingLibmpvResumeForUserSeek()
        suppressRapidBufferingRecovery(reason: "user seek")
        DiagnosticsLog.log(
            "playback",
            String(format: "seek reason=%@ from=%.3f to=%.3f duration=%.3f", reason, currentTime, target, duration)
        )
        coordinator.player?.seek(to: target)
    }

    private func seek(_ delta: Double) {
        cancelPendingLibmpvResumeForUserSeek()
        suppressRapidBufferingRecovery(reason: "user relative seek")
        DiagnosticsLog.log(
            "playback",
            String(format: "seek reason=relative from=%.3f to=%.3f duration=%.3f", currentTime, currentTime + delta, duration)
        )
        coordinator.player?.seek(by: delta)
        flashControls()
    }

    /// Jump back to the very start and keep playing.
    private func restart() {
        commitScrubIfNeeded()
        issueSeek(to: 0, reason: "restart")
        currentTime = 0; lastSaved = 0
        inFlightSeekTarget = 0   // same guard as commitScrub: a stale tick must not undo the restart
        inFlightSeekIssuedAt = Date().timeIntervalSinceReferenceDate
        flashControls()
    }

    // MARK: - Scrub-to-seek (the scrubber row)

    /// Move the preview playhead one step in `dir`. The step grows on rapid or held presses (10s up to
    /// 120s) so you cross a long film in a few presses or a single hold, instead of tapping ±10 a hundred
    /// times. Nothing is actually sought until commit.
    private func scrubBy(_ dir: Int) {
        guard duration > 0 else { return }
        let now = Date().timeIntervalSinceReferenceDate
        if !scrubbing {
            scrubbing = true; scrubTarget = currentTime; scrubStep = 10
        } else if now - lastScrubAt < 0.4 {
            // Gentle LINEAR ramp while holding. The old 1.6x exponential hit the 120s cap in a few
            // repeats, so a brief hold flung the play head by wildly different amounts each press,
            // which is the "jumps randomly" feel. A fixed +6 grows predictably and tops out lower, so
            // a hold glides across the timeline at a controllable, even pace.
            scrubStep = min(scrubStep + 6, 75)
        } else {
            scrubStep = 10                               // paused between presses → back to fine steps
        }
        lastScrubAt = now
        // Clamp an overshoot a few seconds BEFORE the end, never AT it. The accelerating ramp reaches the
        // clamp in a few held presses, and a commit at the exact duration seeks straight into end-of-file:
        // mpv fires EOF, the player treats that as "episode finished" - marks it watched and auto-advances
        // - and the viewer's real progress is wiped (the "scrubbed fast, exited, progress and episode
        // selection gone" report). Landing 5s short shows the actual ending and lets natural playback
        // reach EOF with all the finished semantics intact; a short clip keeps the plain full-range clamp.
        let scrubCeiling = duration > 30 ? duration - 5 : duration
        // The AVPlayer engine owns the forward-only boundary. A target inside the mounted HLS window remains a
        // cheap in-item seek; a target outside it opens a fresh remux at the requested source second. Keeping
        // the preview on the full source timeline is therefore truthful and lets a viewer reach an arbitrary
        // point instead of pinning every long scrub to the first few buffered seconds.
        scrubTarget = min(scrubCeiling, max(0, scrubTarget + Double(dir) * scrubStep))
        scrubThumbnails.show(time: scrubTarget)
        flashControls()
        scheduleScrubCommit()
    }

    /// Commit the seek a beat after the last scrub move, so a hold is one seek at the end, not hundreds.
    private func scheduleScrubCommit() {
        scrubCommit?.cancel()
        scrubCommit = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, scrubbing else { return }
            commitScrub()
        }
    }
    private func commitScrub() {
        scrubCommit?.cancel()
        guard scrubbing else { return }
        scrubbing = false
        issueSeek(to: scrubTarget, reason: "scrub")
        currentTime = scrubTarget; lastSaved = scrubTarget
        inFlightSeekTarget = scrubTarget   // stale pre-seek ticks must not clobber this commit
        inFlightSeekIssuedAt = Date().timeIntervalSinceReferenceDate
        // A commit is exactly when the position jumps by minutes, and `lastSaved = scrubTarget` above
        // suppresses the next throttled tick - so without this the ENGINE's library copy only learned
        // the new position at the exit flush, and an engine-side push (watched toggle, sync) in between
        // resurrected the pre-scrub position. Report the committed position immediately; the account
        // write keeps its pause/20s/exit cadence (network saves are unordered, so fewer is safer there).
        // Attribution gate (binge-desync fix): same identity guard as the tick (:728) and exit flush
        // (:504). A scrub committed during a failed-repoint binge episode must not write the wrong
        // episode's position to the engine with a fresh mtime.
        if assetSanityAttempt.isAccepted(owner: coordinator.player?.activeLoadToken),
           !isCurrentLiveStream, duration > 0, enginePlayerVideoId == curMeta?.videoId,
           suppressedResumeFloor == nil || scrubTarget >= (suppressedResumeFloor ?? 0) {
            core.reportProgress(timeSeconds: scrubTarget, durationSeconds: duration,
                                target: playbackMutationTarget)
        }
        scrubThumbnails.clear()
        flashControls()
    }
    private func commitScrubIfNeeded() { if scrubbing { commitScrub() } }
    /// Discard the in-progress scrub preview and keep playing where we are (Menu while scrubbing).
    private func cancelScrub() { scrubCommit?.cancel(); scrubbing = false; scrubThumbnails.clear(); flashControls() }

    // MARK: - Local trickplay

    private var trickplayLocalCacheKey: String {
        if let m = curMeta { return "v:\(m.libraryId):\(m.videoId)" }
        return "u:\((curURL ?? url).absoluteString)"
    }

    private func invalidateLocalTrickplayCapture() {
        localTrickplayCaptureGeneration &+= 1
        localTrickplayCaptureInFlight = false
    }

    private func ownsLocalTrickplayCapture(_ generation: UInt64) -> Bool {
        localTrickplayCaptureInFlight
            && localTrickplayCaptureGeneration == generation
    }

    private func maybeCaptureLocalTrickplay(at time: Double) {
        guard !localTrickplayCaptureBreaker.isOpen else { return }
        guard assetSanityAttempt.isAccepted(owner: coordinator.player?.activeLoadToken) else { return }
        guard TrickplayCaptureCadencePolicy.shouldCapture(
            playbackTime: time,
            lastCaptureTime: lastLocalTrickplayCapture,
            intervalSeconds: Self.trickplayCaptureIntervalSecs,
            playbackActive: !buffering && !isPaused,
            isScrubbing: scrubbing,
            captureInFlight: localTrickplayCaptureInFlight
        ) else { return }
        // UHD HDR aggravator (diag-23): a local frame grab is serviced inline on mpv's VO thread inside
        // MetalLayer.nextDrawable (an MPS scale + cmd.commit). On a heavy UHD HDR frame that extends the
        // next drawable wait and can tip the output pipeline into a drop. Skip only the local/community
        // contribution for UHD Dolby Vision, HDR10, and HLG. Remote/provider previews are read separately
        // by ScrubThumbnailsStore and remain available. This stays after the cadence gate so mediaSummary()
        // is read at capture boundaries, never on every timePos tick.
        let captureDecision = currentLocalTrickplayCaptureDecision()
        guard captureDecision.permitsLocalCapture else { return }
        // Non-UHD SDR and HDR remain eligible after the ordinary first-frame/display-settle threshold.
        guard TrickplayPresentationReadinessPolicy.isReady(
            elapsedSinceFirstFrame: firstFrameRenderedAt.map { ProcessInfo.processInfo.systemUptime - $0 },
            displaySwitchSettled: HDRDisplayMode.isSwitchSettled,
            isUltraHighDefinitionHDR: captureDecision.isUltraHighDefinitionHDR
        ) else { return }
        captureTrickplayFrame(at: time)
    }

    /// Builds a data-only decision before the local capture call. `isHDR` receives the active transfer-function
    /// result on either engine, and the source hint protects HLS before AVFoundation can expose that result.
    /// The HDR state is reset before a source switch, so a prior HDR title cannot suppress later SDR media.
    private func currentLocalTrickplayCaptureDecision() -> TrickplayLocalCaptureEligibilityPolicy.Decision {
        guard let player = coordinator.player else {
            return TrickplayLocalCaptureEligibilityPolicy.decision(
                .init(isUltraHighDefinition: false, dynamicRange: .unknown)
            )
        }
        let hint = (curHint ?? sourceHint ?? "").lowercased()
        let dynamicRange: TrickplayLocalCaptureEligibilityPolicy.DynamicRange
        if player.contentIsDolbyVision || StreamRanking.isDolbyVision(hint) {
            dynamicRange = .dolbyVision
        } else if hint.contains("hdr10") {
            dynamicRange = .hdr10
        } else if hint.contains("hlg") {
            dynamicRange = .hlg
        } else if isHDR || player.hdrAvailable || hint.contains("hdr") {
            dynamicRange = .hdr
        } else {
            dynamicRange = .unknown
        }
        let summary = player.mediaSummary()
        return TrickplayLocalCaptureEligibilityPolicy.decision(
            .init(
                isUltraHighDefinition: TVOSFramePresentationPolicy.isUltraHighDefinition(
                    width: summary.width, height: summary.height),
                dynamicRange: dynamicRange,
                captureBackend: player is AVPlayerEngineController
                    ? .avPlayerVideoOutput
                    : .libmpvInlineDrawable
            )
        )
    }

    /// The one place a trickplay frame is grabbed (from the timePos tick OR the wall-clock timer). Engine-
    /// agnostic + logged so a silent pool can be traced from a terminal run (which stage refused / nil frame).
    private func captureTrickplayFrame(at time: Double) {
        guard assetSanityAttempt.isAccepted(
            owner: coordinator.player?.activeLoadToken
        ) else { return }
        guard !buffering, !isPaused else { return }
        guard !localTrickplayCaptureInFlight else { return }
        guard let player = coordinator.player else { VXProbe.log("tp", "no player mounted at \(Int(time))s (tvOS)"); return }
        lastLocalTrickplayCapture = time
        localTrickplayCaptureGeneration &+= 1
        let captureGeneration = localTrickplayCaptureGeneration
        localTrickplayCaptureInFlight = true
        trickplayCaptureAttemptsSinceReceipt &+= 1
        let engine = (player is AVPlayerEngineController) ? "avplayer" : "libmpv"
        // In-flight watchdog: the libmpv capture is serviced on mpv's VO thread inside nextDrawable(); if that
        // thread is momentarily idle the handler may never fire, so release the guard after 3s to avoid a
        // permanent wedge that would silently skip every later capture.
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled,
                  self.ownsLocalTrickplayCapture(captureGeneration) else { return }
            self.localTrickplayCaptureInFlight = false
            VXProbe.log("tp", "\(engine) capture at \(Int(time))s never serviced (VO idle, tvOS) - releasing guard")
        }
        player.captureFrameJPEGData(maxWidth: 480) { data in
            // MAIN-ACTOR HOP (parity with PlayerScreen; the owner-device zero-contribution fix): the libmpv
            // engine calls this completion on its background capture queue, NOT the main thread, so the
            // @MainActor `localTrickplayCaptureInFlight` reset and `recordCapturedFrameData` (which appends to
            // sessionFrames and fires the community upload) must be hopped onto the main actor here rather than
            // relying on the engine. Otherwise a libmpv play accumulates community frames off-main against
            // main-actor state and can contribute ZERO pool rows. `data` (Data) is Sendable.
            //
            // The heavy JPEG decode runs HERE, off the main actor (this libmpv completion is on a background
            // capture queue), so only the small main-actor tail (in-flight reset + record/upload of the
            // already-decoded frame) hops to the main actor, keeping the ~10s decode off the UI thread.
            guard let data else {
                Task { @MainActor in
                    watchdog.cancel()
                    guard self.ownsLocalTrickplayCapture(captureGeneration) else { return }
                    self.localTrickplayCaptureInFlight = false
                    self.trickplayCaptureCompletionsSinceReceipt &+= 1
                    self.trickplayCaptureNilSinceReceipt &+= 1
                    if self.localTrickplayCaptureBreaker.recordCapture(hadData: false) {
                        VXProbe.log("tp", "local capture breaker OPEN after 3 consecutive nil frames (tvOS); preserving remote/community previews")
                    }
                    VXProbe.log("tp", "\(engine) captureFrameJPEGData returned NIL at \(Int(time))s (tvOS)")
                }
                return
            }
            VXProbe.log("tp", "\(engine) captured \(data.count) bytes at \(Int(time))s (tvOS)")
            let decoded = ScrubThumbnailsStore.decodeCapturedFrame(data, at: time)   // heavy decode OFF main
            Task { @MainActor in
                watchdog.cancel()
                guard self.ownsLocalTrickplayCapture(captureGeneration) else { return }
                self.localTrickplayCaptureInFlight = false
                self.trickplayCaptureCompletionsSinceReceipt &+= 1
                _ = self.localTrickplayCaptureBreaker.recordCapture(hadData: true)
                guard let decoded else { return }   // decode failed / near-black: already logged off-actor
                self.scrubThumbnails.recordDecodedFrame(decoded, data: data, at: time)
            }
        }
    }

    /// Wall-clock capture driver (tvOS twin of PlayerScreen.startTrickplayCaptureTimer): a repeating
    /// ten-second eligibility check for both engines. Frame-drop receipts are telemetry only and never
    /// change this cadence.
    private func startTrickplayCaptureTimer() {
        trickplayCaptureTimer?.cancel()
        trickplayCaptureTimer = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.trickplayCaptureIntervalSecs))
                guard !Task.isCancelled else { return }
                guard hasStartedPlaying else { continue }
                guard let player = coordinator.player else { continue }
                let now = player.playbackPositionSeconds
                let t = now > 0 ? now : currentTime
                maybeCaptureLocalTrickplay(at: t)
            }
        }
    }

    /// Scrubber row that expands upward to show a trickplay bubble when the user is scrubbing.
    private var trickplayControls: some View {
        let shown = scrubbing ? scrubTarget : currentTime
        let frac = duration > 0 ? min(1, max(0, shown / duration)) : 0
        // Wide enough for the longest side label, the "Ends 10:45 PM" wall-clock line, at tvOS caption
        // size. The earlier 130 fit "1:23:45" but clipped the ends-at clock to its first digits (#71).
        let sideWidth: CGFloat = 210
        let spacing = Theme.Space.md
        let bubbleWidth: CGFloat = 480
        let bubbleHeight: CGFloat = 270
        let bubbleVisible = scrubbing
            && scrubThumbnails.previewState != .hidden
        return GeometryReader { geo in
            let scrubWidth = max(1, geo.size.width - sideWidth * 2 - spacing * 2)
            let knobX = sideWidth + spacing + scrubWidth * frac
            ZStack(alignment: .bottomLeading) {
                if scrubbing {
                    if let image = scrubThumbnails.image {
                        trickplayBubble(image, time: shown)
                            .offset(x: min(max(0, knobX - bubbleWidth / 2), max(0, geo.size.width - bubbleWidth)), y: -42)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                    } else {
                        switch scrubThumbnails.previewState {
                        case .hidden:
                            EmptyView()
                        case .loading:
                            trickplayStatusBubble("Loading previews…")
                                .offset(x: min(max(0, knobX - 110), max(0, geo.size.width - 220)), y: -42)
                        case .ready:
                            EmptyView()
                        case .unavailable:
                            trickplayStatusBubble("Previews unavailable")
                                .offset(x: min(max(0, knobX - 110), max(0, geo.size.width - 220)), y: -42)
                        }
                    }
                }
                HStack(spacing: spacing) {
                    Text(timeString(shown)).font(.callout.monospacedDigit())
                        .foregroundStyle(scrubbing ? Theme.Palette.accent : Theme.Palette.textPrimary)
                        .frame(width: sideWidth, alignment: .leading)
                    scrubber
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(timeString(duration)).font(.callout.monospacedDigit())
                            .foregroundStyle(Theme.Palette.textSecondary)
                        if let ends = endsAtClock {
                            Text(ends).font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                    }
                    .frame(width: sideWidth, alignment: .trailing)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .animation(.easeOut(duration: 0.12), value: scrubThumbnails.previewState)
        }
        .frame(height: bubbleVisible ? bubbleHeight + 26 : 28)
    }

    private func trickplayStatusBubble(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.Palette.textPrimary.opacity(0.18), lineWidth: 1))
    }

    private func trickplayBubble(_ image: UIImage, time: Double) -> some View {
        VStack(spacing: 6) {
            Image(uiImage: image)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 480, height: 270)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(timeString(time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .padding(6)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Theme.Palette.textPrimary.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
    }

    /// Reveal the bar from a hidden state, selecting Play, and restart the auto-hide timer.
    private func showControls() {
        if !showInfo { withAnimation { showInfo = true } }
        if controlsHidden || selected == .close { selected = .play }
        scheduleHide()
    }
    /// Keep the bar visible and reset the auto-hide timer, without changing the selection.
    private func flashControls() {
        if !showInfo { withAnimation { showInfo = true } }   // no SwiftUI transaction per repeat-press when already shown
        scheduleHide()
    }

    /// Push the auto-hide deadline forward. A single long-lived poll loop (started in
    /// onAppear) does the hiding, so a remote press here is just a Date assignment, not
    /// a Task cancel-and-recreate 6-8 times a second during held-key navigation.
    private func scheduleHide() {
        hideDeadline = Date().addingTimeInterval(8)
    }

    /// The one hide loop. Polls twice a second; hides the bar once the deadline passes
    /// and no options panel is open. Cancelled in onDisappear.
    private func startHideLoop() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if showInfo, !showOptions, !loadFailed, Date() >= hideDeadline {
                    withAnimation { showInfo = false }
                }
                maybePromptStillWatching()   // "Still watching?" idle guard rides the same 2/s poll
            }
        }
    }

    // MARK: - "Still watching?" idle guard

    /// Record any remote interaction: push the idle deadline out and clear the auto-advance streak, so an
    /// attended session never trips the prompt. Cheap (a Date write); called from the top of handlePress.
    private func noteInteraction() {
        idleDeadline = Date().addingTimeInterval(Self.idleWatchTimeout)
        consecutiveAutoAdvances = 0
    }

    /// Fire the timed prompt iff the session looks unattended AND is actually playing. Never interrupts a
    /// paused / buffering / options / failed session; each is re-checked on the next poll tick.
    private func maybePromptStillWatching() {
        guard stillWatchingPromptEnabled else { return }   // disabled: never interrupt an idle session
        guard hasStartedPlaying, !stillWatching else { return }
        guard !isPaused, !showOptions, !buffering, !loadFailed else { return }
        guard Date() >= idleDeadline else { return }
        presentStillWatching()
    }

    /// Pause playback (unless at an episode boundary, where the file has already ended) and raise the modal,
    /// hiding the transport underneath. `pendingAdvance` rolls to the next episode if Continue is chosen.
    private func presentStillWatching(pendingAdvance: Bool = false) {
        guard !stillWatching else { return }
        stillWatchingPendingAdvance = pendingAdvance
        stillWatchingWantsStop = false
        // Always pause whatever is on screen so the prompt never plays over a running video (a boundary
        // whose file already ended pauses a no-op; a next episode that already began is stopped). Continue
        // resumes: playNext for a boundary, un-pause for a mid-title hold.
        if !isPaused { coordinator.player?.togglePause() }
        withAnimation { showInfo = false; stillWatching = true }
    }

    /// "Continue": re-arm the guard, then resume -- either roll to the pending next episode (binge boundary)
    /// or un-pause the current title.
    private func continueStillWatching() {
        let advance = stillWatchingPendingAdvance
        stillWatchingPendingAdvance = false
        withAnimation { stillWatching = false }
        noteInteraction()
        if advance {
            playNext()
        } else {
            if isPaused { coordinator.player?.togglePause() }
            showControls()
        }
    }

    /// "Stop": save progress, then leave the player entirely (mirrors Back / Close).
    private func stopStillWatching() {
        stillWatching = false
        stillWatchingPendingAdvance = false
        saveProgress(at: currentTime)
        leavePlayback()
    }

    /// "Still watching?" modal: a dimming scrim plus a centered warm-glass card with Continue / Stop. Raised
    /// after a long unattended stretch so a stream does not play all night; the two pills mirror the Up Next
    /// band's focus styling (highlighted = solid ember). Left/Right move focus, Select activates.
    private var stillWatchingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: Theme.Space.md) {
                Text("Still watching?")
                    .font(.title.weight(.bold)).foregroundStyle(Theme.Palette.textPrimary)
                Text("Playback paused after a long stretch with no activity.")
                    .font(.title3).foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 28) {
                    stillWatchingButton("Continue", systemImage: "play.fill", highlighted: !stillWatchingWantsStop)
                    stillWatchingButton("Stop", systemImage: nil, highlighted: stillWatchingWantsStop)
                }
                .padding(.top, Theme.Space.md)
            }
            .padding(.horizontal, 56).padding(.vertical, 44)
            .frame(maxWidth: 820)
            .vortxGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous),
                        fillAlpha: VortXGlass.cardFillAlpha, shadow: .card)
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.15), value: stillWatchingWantsStop)
        .accessibilityElement(children: .contain)
    }

    private func stillWatchingButton(_ title: String, systemImage: String?, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            if let img = systemImage { Image(systemName: img) }
            Text(title).lineLimit(1)
        }
        .font(.headline.weight(.semibold))
        .foregroundStyle(highlighted ? Theme.Palette.onAccent : Theme.Palette.textPrimary)
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background { if highlighted { Capsule().fill(Theme.Palette.accent) } }
        .vortxGlass(in: Capsule(), fillAlpha: VortXGlass.pillFillAlpha, shadow: .flat)
        .overlay(Capsule().stroke(Theme.Palette.canvas, lineWidth: highlighted ? 3 : 0))
        .scaleEffect(accessibilityReduceMotion ? 1.0 : (highlighted ? 1.06 : 1.0))
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Remote-catcher accessibility bridge

    /// The transparent UIKit catcher remains the only physical tvOS focus target, but VoiceOver and Switch
    /// Control need individual semantic targets. These virtual rows mirror the same `selected` / `optionRow`
    /// state and call the same activation functions as the Siri Remote, so accessibility never forks behavior.
    private var remoteAccessibilityItems: [RemoteCatcher.AccessibilityItem] {
        if stillWatching {
            return [
                .init(id: "still-watching.continue", label: "Continue watching", hint: "Resumes playback",
                      traits: stillWatchingWantsStop ? .button : [.button, .selected]),
                .init(id: "still-watching.stop", label: "Stop watching", hint: "Closes the player",
                      traits: stillWatchingWantsStop ? [.button, .selected] : .button)
            ]
        }

        if showOptions {
            var items: [RemoteCatcher.AccessibilityItem] = [
                .init(id: "panel.heading.\(panelTitle)", label: panelTitle, traits: .header, isEnabled: false)
            ]
            items.append(contentsOf: panelRows.map { row in
                let opensSubmenu = row.detail == "›" || row.detail.hasSuffix(" ›")
                let value = row.detail.isEmpty || opensSubmenu ? nil : row.detail
                var traits: UIAccessibilityTraits = row.isHeader ? .header : .button
                if row.isSelected { traits.insert(.selected) }
                if !row.isEnabled { traits.insert(.notEnabled) }
                return .init(
                    id: "option.\(row.accessibilityID)",
                    label: row.label,
                    value: value,
                    hint: opensSubmenu ? "Opens submenu" : nil,
                    traits: traits,
                    isEnabled: row.isEnabled && !row.isHeader
                )
            })
            return items
        }

        if controlsHidden, upNextRemaining != nil || isCreditsUpNext {
            return [
                .init(id: "up-next.play", label: "Play next episode now",
                      traits: upNextWantsCredits ? .button : [.button, .selected]),
                .init(id: "up-next.credits", label: "Watch credits",
                      traits: upNextWantsCredits ? [.button, .selected] : .button)
            ]
        }

        if showInfo {
            var controls: [Control] = [.close]
            if !isCurrentLiveStream { controls.append(.scrub) }
            controls.append(contentsOf: buttonRow)
            return controls.map { control in
                var traits: UIAccessibilityTraits = control == .scrub ? .adjustable : .button
                if selected == control { traits.insert(.selected) }
                return .init(
                    id: "control.\(controlAccessibilityID(control))",
                    label: controlAccessibilityLabel(control),
                    value: control == .scrub ? "\(timeString(scrubbing ? scrubTarget : currentTime)) of \(timeString(duration))" : nil,
                    hint: control == .scrub ? "Swipe up or down to seek" : nil,
                    traits: traits,
                    isAdjustable: control == .scrub
                )
            }
        }

        return [
            .init(id: "hidden.show-controls", label: "Show playback controls", traits: .button),
            .init(id: "hidden.play-pause", label: isPaused ? "Resume playback" : "Pause playback", traits: .button)
        ]
    }

    private var remoteAccessibilityFocusedID: String? {
        if stillWatching { return stillWatchingWantsStop ? "still-watching.stop" : "still-watching.continue" }
        if showOptions, panelRows.indices.contains(optionRow) {
            return "option.\(panelRows[optionRow].accessibilityID)"
        }
        if controlsHidden, upNextRemaining != nil || isCreditsUpNext {
            return upNextWantsCredits ? "up-next.credits" : "up-next.play"
        }
        if showInfo { return "control.\(controlAccessibilityID(selected))" }
        return nil
    }

    /// Only transition edges are spoken. `RemoteCatcher` remembers the last non-nil value, preventing the
    /// player's frequent time updates from repeating an announcement while one recovery remains active.
    private var remoteAccessibilityAnnouncement: String? {
        if let pending = pendingAdvance {
            return "Loading season \(pending.meta.season ?? 0), episode \(pending.meta.episode ?? 0)"
        }
        if reconnecting { return "Reconnecting playback" }
        if sourceHops > 0, !hasStartedPlaying { return "Source failed. Trying another source" }
        return nil
    }

    private func controlAccessibilityID(_ control: Control) -> String {
        switch control {
        case .close: return "close"
        case .scrub: return "scrub"
        case .restart: return "restart"
        case .back: return "seek-back"
        case .play: return "play-pause"
        case .fwd: return "seek-forward"
        case .audio: return "audio"
        case .subs: return "subtitles"
        case .aspect: return "aspect"
        case .playback: return "playback-speed"
        case .prev: return "previous-episode"
        case .next: return "next-episode"
        case .episodes: return "episodes"
        case .chapters: return "chapters"
        case .sources: return "sources"
        case .quality: return "quality"
        case .settings: return "settings"
        case .skipEdit: return "skip-editor"
        }
    }

    private func controlAccessibilityLabel(_ control: Control) -> String {
        switch control {
        case .close: return "Close player"
        case .scrub: return "Playback position"
        case .restart: return "Restart from beginning"
        case .back: return "Skip back \(seekStep) seconds"
        case .play: return isPaused ? "Resume playback" : "Pause playback"
        case .fwd: return "Skip forward \(seekStep) seconds"
        case .audio: return "Audio tracks"
        case .subs: return "Subtitles"
        case .aspect: return "Aspect ratio"
        case .playback: return "Playback speed"
        case .prev: return "Previous episode"
        case .next: return "Next episode"
        case .episodes: return "Episodes"
        case .chapters: return "Chapters"
        case .sources: return "Sources"
        case .quality: return "Quality"
        case .settings: return "Player settings"
        case .skipEdit: return "Edit skip segment"
        }
    }

    private func remoteAccessibilityFocus(_ identity: String) {
        if identity.hasPrefix("option."),
           let index = panelRows.firstIndex(where: { "option.\($0.accessibilityID)" == identity }),
           !panelRows[index].isHeader, panelRows[index].isEnabled {
            optionRow = index
            return
        }
        if let control = ([Control.close] + buttonRow + [.scrub]).first(where: {
            "control.\(controlAccessibilityID($0))" == identity
        }) {
            selected = control
            if control != .close && control != .scrub { lastButton = control }
        }
        if identity == "still-watching.continue" { stillWatchingWantsStop = false }
        if identity == "still-watching.stop" { stillWatchingWantsStop = true }
        if identity == "up-next.play" { upNextWantsCredits = false }
        if identity == "up-next.credits" { upNextWantsCredits = true }
    }

    private func remoteAccessibilityActivate(_ identity: String) {
        noteInteraction()
        if identity.hasPrefix("option."),
           let index = panelRows.firstIndex(where: { "option.\($0.accessibilityID)" == identity }) {
            optionRow = index
            activateOption()
            return
        }
        if let control = ([Control.close] + buttonRow + [.scrub]).first(where: {
            "control.\(controlAccessibilityID($0))" == identity
        }) {
            selected = control
            activate(control)
            return
        }
        switch identity {
        case "hidden.show-controls": showControls()
        case "hidden.play-pause": toggle()
        case "still-watching.continue": continueStillWatching()
        case "still-watching.stop": stopStillWatching()
        case "up-next.play": requestManualEpisodeNavigation(.next)
        case "up-next.credits": upNextSuppressed = true
        default: break
        }
    }

    private func remoteAccessibilityAdjust(_ identity: String, _ direction: Int) {
        guard identity == "control.scrub" else { return }
        selected = .scrub
        scrubBy(direction)
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

// MARK: - UIKit remote catcher

/// A focusable UIView that captures every Siri-remote press and forwards it to SwiftUI. This is far more
/// reliable than SwiftUI `@FocusState` + `onMoveCommand` inside a full-screen cover on tvOS.
private struct RemoteCatcher: UIViewControllerRepresentable {
    fileprivate struct AccessibilityItem {
        let id: String
        let label: String
        var value: String? = nil
        var hint: String? = nil
        var traits: UIAccessibilityTraits = .button
        var isEnabled: Bool = true
        var isAdjustable: Bool = false
    }

    var onPress: (UIPress.PressType) -> Void
    var onSwipe: () -> Void
    var accessibilityItems: [AccessibilityItem]
    var accessibilityFocusedID: String?
    var accessibilityAnnouncement: String?
    var onAccessibilityFocus: (String) -> Void
    var onAccessibilityActivate: (String) -> Void
    var onAccessibilityAdjust: (String, Int) -> Void
    var onAccessibilityEscape: () -> Void

    func makeUIViewController(context: Context) -> CatchVC {
        let vc = CatchVC()
        vc.loadViewIfNeeded()
        update(vc)
        return vc
    }
    func updateUIViewController(_ vc: CatchVC, context: Context) {
        update(vc)
    }

    private func update(_ vc: CatchVC) {
        vc.onPress = onPress
        vc.onSwipe = onSwipe
        vc.onAccessibilityFocus = onAccessibilityFocus
        vc.onAccessibilityActivate = onAccessibilityActivate
        vc.onAccessibilityAdjust = onAccessibilityAdjust
        vc.onAccessibilityEscape = onAccessibilityEscape
        vc.updateAccessibility(
            items: accessibilityItems,
            focusedID: accessibilityFocusedID,
            announcement: accessibilityAnnouncement
        )
    }

    /// Focusable root view for the catcher controller.
    final class FocusableView: UIView {
        override var canBecomeFocused: Bool { true }
    }

    /// A virtual accessibility control hosted by the transparent catcher. UIKit asks this object to activate,
    /// escape, or adjust; each callback is routed back to the exact SwiftUI state machine the remote uses.
    final class ActionAccessibilityElement: UIAccessibilityElement {
        let stableID: String
        var focusAction: (() -> Void)?
        var activateAction: (() -> Void)?
        var incrementAction: (() -> Void)?
        var decrementAction: (() -> Void)?
        var escapeAction: (() -> Void)?

        init(stableID: String, accessibilityContainer container: Any) {
            self.stableID = stableID
            super.init(accessibilityContainer: container)
        }

        override func accessibilityElementDidBecomeFocused() {
            super.accessibilityElementDidBecomeFocused()
            focusAction?()
        }

        override func accessibilityActivate() -> Bool {
            guard let activateAction else { return false }
            activateAction()
            return true
        }

        override func accessibilityIncrement() { incrementAction?() }
        override func accessibilityDecrement() { decrementAction?() }

        override func accessibilityPerformEscape() -> Bool {
            guard let escapeAction else { return false }
            escapeAction()
            return true
        }
    }

    /// Owns the remote. Its root view is the only focusable; `preferredFocusEnvironments` points at it, so
    /// the focus system always has an explicit target to keep, or pull, focus onto the catcher, even when
    /// a directional press would otherwise move focus to nothing (which left the player deaf to the remote).
    final class CatchVC: UIViewController {
        var onPress: ((UIPress.PressType) -> Void)?
        var onSwipe: (() -> Void)?
        var onAccessibilityFocus: ((String) -> Void)?
        var onAccessibilityActivate: ((String) -> Void)?
        var onAccessibilityAdjust: ((String, Int) -> Void)?
        var onAccessibilityEscape: (() -> Void)?
        private var accessibilityControls: [ActionAccessibilityElement] = []
        private var requestedAccessibilityFocusID: String?
        private var lastAccessibilityAnnouncement: String?

        override func loadView() { view = FocusableView() }

        override var preferredFocusEnvironments: [UIFocusEnvironment] {
            isViewLoaded ? [view] : super.preferredFocusEnvironments
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isAccessibilityElement = false
            // Swipes on the Siri-remote touch surface are NOT UIPress events, so pressesBegan never sees
            // them. A pan recognizer for indirect (remote) touches wakes the controls on a swipe.
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSurfaceTouch))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            view.addGestureRecognizer(pan)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            layoutAccessibilityControls()
        }

        func updateAccessibility(
            items: [AccessibilityItem],
            focusedID: String?,
            announcement: String?
        ) {
            guard isViewLoaded else {
                requestedAccessibilityFocusID = focusedID
                if announcement == nil { lastAccessibilityAnnouncement = nil }
                return
            }

            let previous = Dictionary(uniqueKeysWithValues: accessibilityControls.map { ($0.stableID, $0) })
            accessibilityControls = items.map { item in
                let element = previous[item.id]
                    ?? ActionAccessibilityElement(stableID: item.id, accessibilityContainer: view as Any)
                element.accessibilityLabel = item.label
                element.accessibilityValue = item.value
                element.accessibilityHint = item.hint
                element.accessibilityTraits = item.traits
                element.isAccessibilityElement = true
                element.focusAction = { [weak self] in self?.onAccessibilityFocus?(item.id) }
                element.activateAction = item.isEnabled ? { [weak self] in
                    self?.onAccessibilityActivate?(item.id)
                } : nil
                element.incrementAction = item.isAdjustable ? { [weak self] in
                    self?.onAccessibilityAdjust?(item.id, 1)
                } : nil
                element.decrementAction = item.isAdjustable ? { [weak self] in
                    self?.onAccessibilityAdjust?(item.id, -1)
                } : nil
                element.escapeAction = { [weak self] in self?.onAccessibilityEscape?() }
                return element
            }
            view.accessibilityElements = accessibilityControls
            layoutAccessibilityControls()

            if requestedAccessibilityFocusID != focusedID {
                requestedAccessibilityFocusID = focusedID
                if let focusedID,
                   let element = accessibilityControls.first(where: { $0.stableID == focusedID }) {
                    UIAccessibility.post(notification: .layoutChanged, argument: element)
                }
            }

            if let announcement, announcement != lastAccessibilityAnnouncement {
                lastAccessibilityAnnouncement = announcement
                UIAccessibility.post(notification: .announcement, argument: announcement)
            } else if announcement == nil {
                lastAccessibilityAnnouncement = nil
            }
        }

        private func layoutAccessibilityControls() {
            guard !accessibilityControls.isEmpty else { return }
            let sliceHeight = max(1, view.bounds.height / CGFloat(accessibilityControls.count))
            for (index, element) in accessibilityControls.enumerated() {
                element.accessibilityFrameInContainerSpace = CGRect(
                    x: 0,
                    y: CGFloat(index) * sliceHeight,
                    width: view.bounds.width,
                    height: sliceHeight
                )
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            setNeedsFocusUpdate(); updateFocusIfNeeded()
        }

        /// Lock focus on the catcher. It is the ONLY focusable while playing and it handles every remote
        /// input itself (hidden state, control-bar navigation, AND the audio/subtitle panel), so it never
        /// needs to yield focus. Without this, a directional press knocks focus to nil and the controls
        /// stop responding until an async re-grab catches up, a race the input never wins under load.
        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            if isViewLoaded, view.window != nil, context.nextFocusedItem !== view {
                return false
            }
            return super.shouldUpdateFocus(in: context)
        }

        /// Swipes both wake the controls AND navigate them: the pan accumulates into
        /// discrete directional presses (one per threshold crossing, dominant axis wins),
        /// so the touch surface moves the selection exactly like the arrow buttons do.
        private var panAccumulator = CGPoint.zero

        @objc private func handleSurfaceTouch(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                panAccumulator = .zero
                onSwipe?()
            case .changed:
                let t = g.translation(in: view)
                panAccumulator.x += t.x
                panAccumulator.y += t.y
                g.setTranslation(.zero, in: view)
                let threshold: CGFloat = 300   // a deliberate flick, not a resting thumb
                while abs(panAccumulator.x) >= threshold || abs(panAccumulator.y) >= threshold {
                    if abs(panAccumulator.x) >= abs(panAccumulator.y) {
                        onPress?(panAccumulator.x > 0 ? .rightArrow : .leftArrow)
                        panAccumulator.x -= panAccumulator.x > 0 ? threshold : -threshold
                        panAccumulator.y = 0
                    } else {
                        onPress?(panAccumulator.y > 0 ? .downArrow : .upArrow)
                        panAccumulator.y -= panAccumulator.y > 0 ? threshold : -threshold
                        panAccumulator.x = 0
                    }
                }
            default:
                panAccumulator = .zero
            }
        }

        // Hold an arrow → repeat the press, so you can hold to seek (the scrubber) or scroll a long list.
        // tvOS skips its own key-repeat because we own focus, so we synthesize it: fire once on press,
        // then repeat after a short hold delay until release. A hard cap guards a missed pressesEnded.
        private var repeatTimer: Timer?
        private var repeatType: UIPress.PressType?
        private var repeatCount = 0

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handled = false
            for press in presses {
                switch press.type {
                case .select, .menu, .playPause:
                    onPress?(press.type); handled = true
                case .upArrow, .downArrow, .leftArrow, .rightArrow:
                    onPress?(press.type); handled = true
                    startRepeat(press.type)
                default: break
                }
            }
            if !handled { super.pressesBegan(presses, with: event) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            stopRepeat()
            // Swallow the RELEASE of every press type pressesBegan handled, not just
            // the press itself. Forwarding the menu release to UIKit let the system
            // act on it anyway and suspend the app to the home screen, intermittently,
            // raced against the player teardown the menu press had just started.
            let unhandled = presses.filter {
                switch $0.type {
                case .select, .menu, .playPause, .upArrow, .downArrow, .leftArrow, .rightArrow:
                    return false
                default:
                    return true
                }
            }
            if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
        }
        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            stopRepeat(); super.pressesCancelled(presses, with: event)
        }

        private func startRepeat(_ type: UIPress.PressType) {
            stopRepeat()
            repeatType = type; repeatCount = 0
            let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] t in
                guard let self, let type = self.repeatType else { t.invalidate(); return }
                self.repeatCount += 1
                if self.repeatCount > 120 { self.stopRepeat(); return }   // ~14s safety cap
                self.onPress?(type)
            }
            timer.fireDate = Date().addingTimeInterval(0.45)              // hold delay before repeats kick in
            RunLoop.main.add(timer, forMode: .common)
            repeatTimer = timer
        }
        private func stopRepeat() { repeatTimer?.invalidate(); repeatTimer = nil; repeatType = nil }

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            // Keep focus on the catcher: if it drifts off (e.g. a directional press moves focus to nil),
            // re-request. preferredFocusEnvironments gives the system an explicit target (our view), so
            // focus returns reliably with no competitor to fight.
            if isViewLoaded, view.window != nil, (context.nextFocusedItem as? UIView) !== view {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isViewLoaded, self.view.window != nil, !self.view.isFocused else { return }
                    self.setNeedsFocusUpdate()
                    self.updateFocusIfNeeded()
                }
            }
        }
    }
}
