import Foundation

/// Buffering only: this does not authorize a URL, forward credentials, or select a player engine.
/// Recognize the embedded NZB endpoint before its redirect, not every loopback/torrent/proxy URL.
enum LocalNNTPBufferPolicy {
    static func waitSeconds(url: URL, live: Bool, preview: Bool) -> Double {
        guard !live, !preview, url.scheme?.lowercased() == "http",
              ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host?.lowercased() ?? ""),
              url.path == "/nzb/stream" else { return 1 }
        return 6
    }
}

/// The only finite sources allowed to request the bounded cache re-anchor. Keeping this beside the value gate
/// makes the gate dependency-free while preventing an arbitrary diagnostic string from becoming ownership data.
enum CacheFlushReason: String, Equatable {
    case pausedCacheClamp = "paused-cache-clamp"
    case memoryWarning = "memory-warning"
    case proactiveMemoryPressure = "proactive-memory-pressure"
}

/// Result returned by the controller's cache-reanchor admission point. A started flight may still terminate
/// with a command error, observed-seek settlement, or cancellation; those outcomes are recorded by the
/// controller's bounded receipts rather than added to this finite admission surface.
enum CacheFlushDisposition: Equatable {
    case started
    case coalesced
    case skipped
}

/// One controller-local forced-low-level-seek operation. `Owner` is the exact loaded-file token in production; the
/// standalone policy harness uses an integer so these lifecycle rules remain testable without libmpv/UIKit.
struct CacheFlushFlight<Owner: Equatable> {
    enum Phase: String, Equatable {
        case seeking
        case awaitingSeekEvent
        case settling
        case terminal
    }

    enum Result: String, Equatable {
        case pending
        case commandAccepted = "command-accepted"
        case seekCommandError = "seek-command-error"
        case canceled
    }

    let id: UInt64
    let owner: Owner
    let reason: CacheFlushReason
    let target: Double
    let targetArgument: String
    let startUptime: TimeInterval
    var coalescedCount = 0
    var phase: Phase = .seeking
    var result: Result = .pending
    var timeoutWorkItem: DispatchWorkItem?
}

/// Main-queue-owned single flight for a forced-low-level exact seek. This is a value
/// type, not a reusable operation framework: one instance belongs to one MPVMetalViewController.
struct CacheFlushSingleFlight<Owner: Equatable> {
    private(set) var nextFlightID: UInt64 = 0
    private(set) var current: CacheFlushFlight<Owner>?

    /// Return `.coalesced` only for the exact current owner. A different owner drops the old flight and lets the
    /// caller revalidate before installing a new one; no command is issued by this value type.
    mutating func admit(owner: Owner) -> CacheFlushDisposition {
        guard var flight = current else { return .started }
        guard flight.owner == owner else {
            flight.timeoutWorkItem?.cancel()
            current = nil
            return .started
        }
        flight.coalescedCount += 1
        current = flight
        return .coalesced
    }

    /// Install the complete immutable target snapshot before any destructive command is attempted.
    @discardableResult
    mutating func install(
        owner: Owner,
        reason: CacheFlushReason,
        target: Double,
        targetArgument: String,
        startUptime: TimeInterval,
        timeoutWorkItem: DispatchWorkItem
    ) -> CacheFlushFlight<Owner> {
        precondition(target.isFinite && target > 0)
        precondition(!targetArgument.isEmpty)
        precondition(startUptime.isFinite)
        precondition(current == nil)
        precondition(nextFlightID < UInt64.max)
        nextFlightID += 1
        let flight = CacheFlushFlight(
            id: nextFlightID,
            owner: owner,
            reason: reason,
            target: target,
            targetArgument: targetArgument,
            startUptime: startUptime,
            timeoutWorkItem: timeoutWorkItem
        )
        current = flight
        return flight
    }

    func matches(id: UInt64, owner: Owner) -> Bool {
        current?.id == id && current?.owner == owner
    }

    mutating func markSeekCommandAccepted(id: UInt64, owner: Owner) -> Bool {
        guard var flight = current, flight.id == id, flight.owner == owner else { return false }
        guard flight.phase == .seeking, flight.result == .pending else { return false }
        flight.phase = .awaitingSeekEvent
        current = flight
        return true
    }

    @discardableResult
    mutating func seekCommandError(id: UInt64, owner: Owner) -> CacheFlushFlight<Owner>? {
        finishIfExact(id: id, owner: owner, phase: .seeking, result: .seekCommandError)
    }

    /// A libmpv seek event, observed for the exact active source, proves that the queued command crossed from
    /// command acceptance into the demuxer's seek path. Old time-pos samples are not sufficient for this edge.
    mutating func markSeekEventObserved(owner: Owner) -> Bool {
        guard var flight = current,
              flight.owner == owner,
              flight.phase == .awaitingSeekEvent,
              flight.result == .pending else { return false }
        flight.phase = .settling
        current = flight
        return true
    }

    /// The single bounded settle-window edge accepts a successful seek. It
    /// requires the exact flight identity and never consults a replacement's current ID.
    @discardableResult
    mutating func settle(id: UInt64, owner: Owner) -> CacheFlushFlight<Owner>? {
        guard let flight = current,
              flight.id == id,
              flight.owner == owner,
              flight.phase == .awaitingSeekEvent || flight.phase == .settling,
              flight.result == .pending else { return nil }
        return finish(result: .commandAccepted)
    }

    /// A token-fenced recovery edge proves the forced seek has crossed mpv's transport restart boundary.
    @discardableResult
    mutating func completeOnProgress(
        owner: Owner,
        observedPosition: Double,
        progressEpsilon: Double
    ) -> CacheFlushFlight<Owner>? {
        guard let flight = current,
              flight.owner == owner,
              flight.phase == .settling,
              flight.result == .pending,
              observedPosition.isFinite,
              progressEpsilon.isFinite,
              progressEpsilon >= 0,
              observedPosition >= flight.target + progressEpsilon else { return nil }
        return finish(result: .commandAccepted)
    }

    @discardableResult
    mutating func completeOnPlaybackRestart(owner: Owner) -> CacheFlushFlight<Owner>? {
        guard let flight = current,
              flight.owner == owner,
              flight.phase == .settling,
              flight.result == .pending else { return nil }
        return finish(result: .commandAccepted)
    }

    @discardableResult
    mutating func reset() -> CacheFlushFlight<Owner>? {
        guard current != nil else { return nil }
        return finish(result: .canceled)
    }

    @discardableResult
    mutating func reset(owner: Owner) -> CacheFlushFlight<Owner>? {
        guard current?.owner == owner else { return nil }
        return reset()
    }

    private mutating func finishIfExact(
        id: UInt64,
        owner: Owner,
        phase: CacheFlushFlight<Owner>.Phase? = nil,
        result: CacheFlushFlight<Owner>.Result
    ) -> CacheFlushFlight<Owner>? {
        guard let current,
              current.id == id,
              current.owner == owner,
              phase == nil || current.phase == phase,
              current.result == .pending else { return nil }
        return finish(result: result)
    }

    private mutating func finish(result: CacheFlushFlight<Owner>.Result) -> CacheFlushFlight<Owner>? {
        guard var flight = current else { return nil }
        flight.timeoutWorkItem?.cancel()
        flight.phase = .terminal
        flight.result = result
        current = nil
        return flight
    }
}

/// Narrow ownership state for an EOF that arrives immediately after a seek.  This is deliberately
/// not a timer-based EOF filter: command acceptance is insufficient, and an EOF is recoverable only
/// after libmpv emitted the seek boundary, for the same source, at a target provably away from a known
/// finite duration.  The short lifetime only prevents an old seek from reclassifying a genuine EOF much
/// later in playback.
struct SeekEOFRecoveryPolicy<Owner: Equatable> {
    enum Origin: Equatable { case viewer, cacheReanchor }
    enum Phase: Equatable {
        case awaitingSeekEvent
        case seekObserved
        case awaitingReloadFile
        case awaitingReloadSeekEvent
        case awaitingReloadPosition
    }
    struct Intent: Equatable {
        var owner: Owner
        let target: Double
        /// Latest explicit viewer transport intent. The recovery itself temporarily parks output, but must
        /// never overwrite a Play/Pause request made while the reopen is in flight.
        var wasPaused: Bool
        let transportGeneration: UInt64
        /// Finite duration sampled while this exact source was still loaded. END_FILE may already have
        /// unloaded mpv's duration property, so terminal classification must never read it lazily.
        let durationAtIssue: Double?
        /// A source-fenced time-pos callback received after SEEK. It proves the player remained transportable
        /// before EOF, without imposing a brittle keyframe-distance threshold on ordinary absolute seeks.
        var positionAfterSeek: Double?
        /// libmpv SEEK callbacks have no command id. If this request replaced any unsettled same-source seek,
        /// a queued callback from the old request is indistinguishable from this one and may not authorise
        /// automatic reopen.
        let inheritedUnsettledSeekAmbiguity: Bool
        let issuedAt: TimeInterval
        let origin: Origin
        var phase: Phase
    }

    private(set) var current: Intent?
    private var nextTransportGeneration: UInt64 = 0
    /// Survives `supersedeForNewExplicitSeek()` through the caller's cancel -> begin sequence.
    private var pendingUnsettledSeekAmbiguity = false

    mutating func begin(owner: Owner, target: Double, wasPaused: Bool, duration: Double,
                        origin: Origin, now: TimeInterval) {
        guard target.isFinite, target >= 0, now.isFinite else { current = nil; return }
        precondition(nextTransportGeneration < UInt64.max)
        nextTransportGeneration += 1
        let inheritedAmbiguity = pendingUnsettledSeekAmbiguity || current != nil
        current = Intent(owner: owner, target: target, wasPaused: wasPaused,
                         transportGeneration: nextTransportGeneration,
                         durationAtIssue: duration.isFinite && duration > 0 ? duration : nil,
                         positionAfterSeek: nil,
                         inheritedUnsettledSeekAmbiguity: inheritedAmbiguity,
                         issuedAt: now, origin: origin, phase: .awaitingSeekEvent)
        pendingUnsettledSeekAmbiguity = false
    }

    /// This is the required libmpv boundary. A successful `mpv_command` alone must never arm recovery.
    mutating func observeSeek(owner: Owner) -> Phase? {
        guard var intent = current, intent.owner == owner else { return nil }
        switch intent.phase {
        case .awaitingSeekEvent:
            // A and B share one libmpv source token. Do not guess whether this untagged event belongs to
            // B after B superseded A; the EOF route will fail closed as an error instead.
            guard !intent.inheritedUnsettledSeekAmbiguity else { return nil }
            intent.phase = .seekObserved
            current = intent
            return .seekObserved
        case .awaitingReloadSeekEvent:
            intent.phase = .awaitingReloadPosition
            current = intent
            return .awaitingReloadPosition
        default:
            return nil
        }
    }

    mutating func observePosition(owner: Owner, position: Double) {
        guard var intent = current, intent.owner == owner, position.isFinite,
              intent.phase == .seekObserved,
              !intent.inheritedUnsettledSeekAmbiguity else { return }
        intent.positionAfterSeek = position
        current = intent
    }

    /// Accept only the diagnosed shape: same source, observed seek, a finite duration snapshot, a mid-file
    /// target, and one source-fenced position event after SEEK. mpv may report keyframe positions before an
    /// absolute target, so equality to the requested timestamp is intentionally not a correctness condition.
    func shouldRecoverEOF(owner: Owner, now: TimeInterval,
                          minimumDistanceFromEnd: Double = 8,
                          maximumAdjacency: TimeInterval = 5) -> Bool {
        guard let intent = current, intent.owner == owner, intent.phase == .seekObserved,
              !intent.inheritedUnsettledSeekAmbiguity,
              let duration = intent.durationAtIssue, intent.positionAfterSeek != nil, now.isFinite,
              minimumDistanceFromEnd.isFinite, minimumDistanceFromEnd > 0,
              maximumAdjacency.isFinite, maximumAdjacency > 0 else { return false }
        return intent.target < duration - minimumDistanceFromEnd
            && now >= intent.issuedAt
            && now - intent.issuedAt <= maximumAdjacency
    }

    /// A command accepted for the exact current mid-file target is still not a successful seek. If libmpv
    /// terminalizes before it emits SEEK, fail closed as a recoverable player error instead of forwarding EOF
    /// to watched/advance. This deliberately does not retry: without the event boundary there is insufficient
    /// evidence to reopen safely.
    func shouldRejectUnprovenEOF(owner: Owner, now: TimeInterval,
                                 minimumDistanceFromEnd: Double = 8,
                                 maximumAdjacency: TimeInterval = 5) -> Bool {
        guard let intent = current, intent.owner == owner, intent.phase == .awaitingSeekEvent,
              let duration = intent.durationAtIssue, now.isFinite,
              minimumDistanceFromEnd.isFinite, minimumDistanceFromEnd > 0,
              maximumAdjacency.isFinite, maximumAdjacency > 0 else { return false }
        return intent.target < duration - minimumDistanceFromEnd
            && now >= intent.issuedAt
            && now - intent.issuedAt <= maximumAdjacency
    }

    /// SEEK arrived but no owned time-pos callback followed before EOF. This remains ambiguous, so protect the
    /// episode with the same recoverable-error outcome rather than treating the target as natural completion.
    func shouldRejectUnsettledEOF(owner: Owner, now: TimeInterval,
                                  minimumDistanceFromEnd: Double = 8,
                                  maximumAdjacency: TimeInterval = 5) -> Bool {
        guard let intent = current, intent.owner == owner, intent.phase == .seekObserved,
              intent.positionAfterSeek == nil, let duration = intent.durationAtIssue, now.isFinite,
              minimumDistanceFromEnd.isFinite, minimumDistanceFromEnd > 0,
              maximumAdjacency.isFinite, maximumAdjacency > 0 else { return false }
        return intent.target < duration - minimumDistanceFromEnd
            && now >= intent.issuedAt
            && now - intent.issuedAt <= maximumAdjacency
    }

    /// Consumes the one allowed recovery attempt. A later EOF while reloading is a failure, not a new
    /// completion candidate, so it cannot mark the episode watched or advance the playlist.
    mutating func consumeEOFForReload(owner: Owner) -> Intent? {
        guard var intent = current, intent.owner == owner, intent.phase == .seekObserved else { return nil }
        intent.phase = .awaitingReloadFile
        current = intent
        return intent
    }

    mutating func adoptReload(owner: Owner) -> Intent? {
        guard var intent = current, intent.phase == .awaitingReloadFile else { return nil }
        intent.owner = owner
        current = intent
        return intent
    }

    mutating func beginReloadSeek(owner: Owner) -> Intent? {
        guard var intent = current, intent.owner == owner, intent.phase == .awaitingReloadFile else { return nil }
        intent.phase = .awaitingReloadSeekEvent
        current = intent
        return intent
    }

    mutating func completeReloadAtPosition(owner: Owner, position: Double) -> Intent? {
        guard let intent = current, intent.owner == owner,
              intent.phase == .awaitingReloadPosition,
              position.isFinite else { return nil }
        current = nil
        return intent
    }

    func reloadIsInFlight(owner: Owner) -> Bool {
        guard let intent = current, intent.owner == owner else { return false }
        switch intent.phase {
        case .awaitingReloadFile, .awaitingReloadSeekEvent, .awaitingReloadPosition: return true
        default: return false
        }
    }

    /// Accept a viewer transport action while recovery has intentionally forced mpv paused. The generation is
    /// monotonic per recovery request, and the owner fence prevents a late control action from an old source
    /// changing a newer reload's eventual completion state.
    mutating func updateTransportIntent(owner: Owner, paused: Bool) -> UInt64? {
        guard var intent = current, intent.owner == owner else { return nil }
        switch intent.phase {
        case .awaitingReloadFile, .awaitingReloadSeekEvent, .awaitingReloadPosition:
            intent.wasPaused = paused
            current = intent
            return intent.transportGeneration
        default:
            return nil
        }
    }

    /// An explicit new seek supersedes a forced-pause recovery. Return its latest intent so the controller can
    /// restore it before issuing the new seek; otherwise the new seek inherits the recovery's temporary pause.
    mutating func supersedeReload() -> Intent? {
        guard let intent = current else { return nil }
        switch intent.phase {
        case .awaitingReloadFile, .awaitingReloadSeekEvent, .awaitingReloadPosition:
            current = nil
            return intent
        default:
            return nil
        }
    }

    /// Retire any seek lifecycle before a new explicit seek. Unlike ordinary cancellation this deliberately
    /// carries an ambiguity bit forward: callbacks already queued for the old same-source seek cannot be
    /// attributed to the replacement because MPV_EVENT_SEEK exposes no request identifier.
    mutating func supersedeForNewExplicitSeek() -> Intent? {
        guard let intent = current else { return nil }
        pendingUnsettledSeekAmbiguity = true
        current = nil
        return intent
    }

    mutating func cancel(owner: Owner? = nil) {
        guard let owner else { current = nil; return }
        if current?.owner == owner { current = nil }
    }

    /// A real source replacement/invalidation ends the same-source ambiguity domain. Explicit seek
    /// supersession intentionally uses `supersedeForNewExplicitSeek` instead, so it retains the bit until B.
    mutating func reset() {
        current = nil
        pendingUnsettledSeekAmbiguity = false
    }
}

/// Dependency-free memory-warning cache-shedding decisions for `MPVMetalViewController`, split out so the
/// executable test harness can run them without UIKit/libmpv/RemoteConfig (the DVPlaybackContractTests pattern).
/// Every device-scaled, RemoteConfig-backed number (`floorBytes`, `stepBytes`) is PASSED IN by the controller,
/// which is the only layer that may read `RemoteConfig.snapshot` and `PerformanceMode`; this file stays pure.
///
/// WHY THIS EXISTS, and why the logic changed (the "buffers constantly after Beta 8" field campaign):
/// twelve device logs proved the buffering was a SPURIOUS reactive shed, not real pressure. Across 743
/// `os_proc_available_memory` samples during playback the MINIMUM free was 712 MiB and NONE ever dipped
/// below the ~384 MiB pressure threshold, yet the old handler slammed `demuxer-max-bytes` toward the floor
/// 65+ times, because it answered tvOS ADVISORY memory warnings (a system-wide signal, not our process's
/// headroom) by lowering the cap unconditionally. A 48-128 MiB forward buffer is only ~5-25 s of 4K, so it
/// underran constantly. The ROOT FIX is here: a warning may lower the cap ONLY when this process's real
/// headroom is genuinely low; with provably ample headroom the cap is returned UNCHANGED.
///
/// HARD SAFETY BOUND (also from the field logs, mirrored in MPVMetalViewController): `demuxer-max-bytes` is a
/// HARD in-RAM cap and `cache-on-disk` does NOT offload it on this MPVKit build, so a ~700 MiB in-RAM buffer
/// jetsam-KILLED even the 3 GB Apple TV 4K at 47 s. The cap must stay well under ~400 MiB on 4K and lower on
/// the 2 GB Apple TV HD (`PerformanceMode.reduced`). Shedding under GENUINE low headroom is therefore
/// preserved unchanged: the guard only removes the FALSE positives.
enum VortXCacheShedPolicy {

    /// Pause duration alone is not a pressure signal. A foreground viewer may be deliberately
    /// accumulating a streaming cushion; flushing it after a timer expires defeats that buffer.
    /// Background parking and genuinely low process headroom still permit jetsam relief.
    static func shouldClampPausedCache(
        isBackgrounded: Bool,
        availableBytes: UInt64,
        physicalBytes: UInt64
    ) -> Bool {
        isBackgrounded || availableBytes < TVOSProactiveMemoryPressurePolicy.pressureThresholdBytes(
            physicalMemoryBytes: physicalBytes
        )
    }

    /// The pinned MPVKit build does not move the forward demuxer payload out of process RAM when
    /// `cache-on-disk` is enabled. Keep this as the single capability authority for both setup and per-load
    /// decisions: a saved user preference expresses intent, but must not be treated as proof of offload.
    ///
    /// Flip this only after an on-device diagnostic proves that forward payload bytes leave resident memory
    /// and the configured byte budget is actually enforced. Until then, the ordinary RAM baselines are the
    /// only truthful and safe cache budgets.
    static let diskCachePayloadOffloadConfirmed = false

    /// Settings may retain a viewer's disk-cache choice for a future verified MPVKit build, but must not
    /// render that dormant choice as an active cache size while payloads still remain in RAM.
    static var diskCacheSizeSelectionAvailable: Bool {
        diskCachePayloadOffloadConfirmed
    }

    /// A nil selection deliberately represents the unavailable state, rather than silently substituting
    /// "Off" and overwriting a saved preference that can become valid after capability confirmation.
    static func presentedDiskCacheSizeSelection(storedBytes: Int64) -> Int64? {
        diskCacheSizeSelectionAvailable ? storedBytes : nil
    }

    static let unavailableDiskCacheState = "Automatic RAM-bounded buffer"
    static let unavailableDiskCacheAccessibilityHint =
        "Disk cache sizes are unavailable until this MPVKit build confirms payload offload. Playback uses an automatic RAM-bounded buffer. Your saved cache size is preserved for a future supported build."

    /// Whether setup may arm mpv's disk-cache options. Muted preview players never participate even after a
    /// future capability confirmation.
    static func shouldArmDiskCache(payloadOffloadRequested: Bool, muted: Bool) -> Bool {
        diskCachePayloadOffloadConfirmed && payloadOffloadRequested && !muted
    }

    /// Whether one file may use the disk-offload metadata cap and read-ahead ramp. Requiring the capability
    /// again here is intentional defense in depth: a stale runtime `armed` bit must not lower the RAM payload
    /// cap when the pinned build is known not to offload.
    static func shouldUseDiskCacheForLoad(
        payloadOffloadRequested: Bool,
        diskCacheOnDiskArmed: Bool,
        live: Bool,
        local: Bool
    ) -> Bool {
        diskCachePayloadOffloadConfirmed
            && payloadOffloadRequested
            && diskCacheOnDiskArmed
            && !live
            && !local
    }

    /// Baked defaults, mirroring `RemoteConfigDefaults`. The controller passes the RemoteConfig-resolved,
    /// device-scaled values at runtime (`shedFloorBytes` / `shedStepBytes`); the tests use these constants.
    ///
    /// `floorBytes` is the NORMAL-tier shed floor (192 MiB, up from the old 48 MiB): once the root fix stops
    /// the spurious sheds, the rare GENUINE shed must still leave a buffer big enough to play 4K, not a
    /// razor-thin 48 MiB that underruns. It is never below the 150 MiB hard-never-below. The controller scales
    /// it down on `PerformanceMode.reduced` (the 2 GB Apple TV HD) so that tier stays crash-safe.
    static let floorBytes = 192 << 20
    /// The absolute never-below for the NORMAL tier: no shed/clamp path may take the cap under this.
    static let hardMinFloorBytes = 150 << 20
    /// The `PerformanceMode.reduced` (2 GB Apple TV HD) scaled shed floor. Kept crash-safe: the reduced load
    /// cap is a tight 96 MiB, so with the non-increasing rule below this floor never RAISES that buffer.
    static let reducedFloorBytes = 128 << 20
    /// One shed rung: a genuine-low warning steps the cap DOWN by this much toward the floor, rather than
    /// halving it or slamming it to the floor in one move, so a single false-ish reading costs at most one rung.
    static let stepBytes = 64 << 20

    /// The forward-cache cap (bytes) to apply when a system memory warning arrives.
    ///
    /// ROOT FIX: a warning lowers the cap ONLY on GENUINE low headroom - `availableBytes` strictly below the
    /// PRESSURE threshold (`pressureThresholdBytes`, ~384 MiB on the 3 GB Apple TV 4K), the exact same bar the
    /// proactive clamp uses. At or above it the warning is advisory noise and the cap is returned UNCHANGED.
    ///
    /// WHY THE PRESSURE BAR, NOT THE RESTORE BAR: the field-min headroom was 712 MiB, but on the real 3 GB box
    /// the restore-grade bar (`restoreThresholdBytes`, twice the pressure threshold) is 768 MiB, so 712 < 768
    /// would STILL have shed the buffer at the device's low-headroom moments - re-creating the very
    /// rebuffering this fix removes. Against the ~384 MiB pressure bar, 712 MiB is comfortably ample and the
    /// buffer HOLDS. The expensive flush stays on the conservative restore bar (`shouldDeferFlushOnWarning`);
    /// only this cap-lowering bar moves down to match the proactive clamp.
    ///
    /// When it does lower, it steps down by one `stepBytes` rung toward `floorBytes`. The result is
    /// NON-INCREASING by construction (`min(currentBytes, ...)`), so on the reduced tier - where the load cap
    /// (96 MiB) can sit below the reduced floor (128 MiB) - a warning can never inflate a parked 2 GB device's
    /// buffer.
    static func forwardCapAfterWarning(
        currentBytes: Int,
        availableBytes: UInt64,
        physicalBytes: UInt64,
        floorBytes: Int,
        stepBytes: Int
    ) -> Int {
        guard availableBytes < TVOSProactiveMemoryPressurePolicy.pressureThresholdBytes(
            physicalMemoryBytes: physicalBytes
        ) else {
            return currentBytes   // headroom meets the pressure bar: an advisory warning must NOT lower the cap
        }
        let stepped = max(floorBytes, currentBytes - stepBytes)
        return min(currentBytes, stepped)   // non-increasing: never raise the cap even if floor > current
    }

    /// diag-23 FIX-C: should a memory warning SKIP the immediate buffer flush the shed otherwise performs
    /// (`flushDemuxerCachePreservingPosition`, a forced low-level exact seek)?
    ///
    /// That flush is the JETSAM tool: it frees the resident forward buffer NOW, the last line of defence
    /// before tvOS/iOS kills the app. It is also the source of a visible frame-drop burst. Return true (defer
    /// the flush) ONLY when BOTH hold, so the guard can never weaken jetsam relief:
    ///  1. `availableBytes` is at the RESTORE-grade bar (`restoreThresholdBytes`, twice the pressure
    ///     threshold) - a kill is provably not imminent; and
    ///  2. the live forward cache (`cacheFillBytes`) already fits inside the cap this warning leaves in place
    ///     (`forwardCapAfterWarning`), so dropping it would free nothing lowering the cap does not already
    ///     bound - the flush would be pure cost.
    ///
    /// The flush DELIBERATELY stays on the stricter RESTORE bar even though `forwardCapAfterWarning`'s
    /// cap-lowering bar moved down to the PRESSURE threshold. The two are decoupled on purpose: the cap is
    /// cheap to hold big and starves playback when lowered, so it holds until headroom is genuinely low
    /// (pressure bar); the flush is the expensive last-ditch jetsam tool and stays conservative, firing until
    /// headroom is provably ample (restore bar). So in the [pressure, restore) band the cap HOLDS while the
    /// flush still fires - fully jetsam-safe, and no worse than the shipped diag-23 flush behavior.
    ///
    /// Whenever headroom is below the restore bar, or the cache overflows the held cap, this returns false and
    /// the drastic flush fires unchanged. The controller passes `cacheFillBytes = Int.max` when it cannot read
    /// the live fill, so an unknown cache also fails condition 2 and keeps the drastic path.
    static func shouldDeferFlushOnWarning(
        availableBytes: UInt64,
        physicalBytes: UInt64,
        currentCapBytes: Int,
        cacheFillBytes: Int,
        floorBytes: Int,
        stepBytes: Int
    ) -> Bool {
        let reducedCapBytes = forwardCapAfterWarning(
            currentBytes: currentCapBytes,
            availableBytes: availableBytes,
            physicalBytes: physicalBytes,
            floorBytes: floorBytes,
            stepBytes: stepBytes
        )
        guard availableBytes >= TVOSProactiveMemoryPressurePolicy.restoreThresholdBytes(
            physicalMemoryBytes: physicalBytes
        ) else { return false }
        return cacheFillBytes <= reducedCapBytes
    }

    /// Beta 26 stutter fix: the EDGE-TRIGGERED wrapper around `shouldDeferFlushOnWarning` for the advisory band.
    ///
    /// The level-triggered gate above was correct for occasional warnings, but field logs from beta 25/26 show a
    /// different regime on the Apple TV 4K: headroom PARKS at roughly 400-420 MiB - permanently inside the
    /// [pressure, restore) band - and tvOS keeps posting advisory warnings every minute or two. Each one re-ran
    /// the forced low-level exact-reanchor seek (~15 s of main-thread IPC and a documented
    /// frame-drop burst), so the viewer saw a visible stutter on a metronome. Flushing repeatedly at a stable
    /// in-band headroom frees nothing durable (the cache refills to the same held cap), so every repetition is
    /// pure cost with no jetsam benefit.
    ///
    /// This gate makes the IN-BAND flush fire ONCE per headroom episode: the controller passes
    /// `hasFlushedSinceHeadroomRecovered`, latched true after an in-band flush and cleared only when headroom
    /// actually recovers to the restore bar (or the item changes). Below the pressure bar nothing changes -
    /// genuine low headroom always flushes immediately, jetsam relief intact. At or above the restore bar the
    /// strict level-triggered gate alone decides, exactly as shipped.
    static func shouldDeferInBandFlush(
        availableBytes: UInt64,
        pressureThresholdBytes: UInt64,
        restoreThresholdBytes: UInt64,
        policyDefer: Bool,
        hasFlushedSinceHeadroomRecovered: Bool
    ) -> Bool {
        // Genuine low headroom: the drastic flush is the last defence before jetsam and must never wait.
        guard availableBytes >= pressureThresholdBytes else { return false }
        // Provably ample headroom: the existing strict gate owns the decision, unchanged.
        if availableBytes >= restoreThresholdBytes { return policyDefer }
        // Advisory band: one flush per episode, then hold until headroom genuinely recovers.
        return policyDefer || hasFlushedSinceHeadroomRecovered
    }

    /// Parse the two cap spellings the controller actually applies to mpv: plain byte counts
    /// ("268435456", the Streaming-cache branch) and MiB-suffixed ("256MiB", the static tiers).
    /// nil for anything else, so a surprise never silently becomes a 0-byte cache.
    static func capBytes(_ value: String) -> Int? {
        if let plain = Int(value) { return plain > 0 ? plain : nil }
        if value.hasSuffix("MiB"), let mib = Int(value.dropLast(3)) { return mib > 0 ? mib << 20 : nil }
        return nil
    }
}
