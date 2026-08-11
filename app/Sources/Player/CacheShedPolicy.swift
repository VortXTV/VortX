import Foundation

/// The only finite sources allowed to request the destructive cache drop. Keeping this beside the value gate
/// makes the gate dependency-free while preventing an arbitrary diagnostic string from becoming ownership data.
enum CacheFlushReason: String, Equatable {
    case pausedCacheClamp = "paused-cache-clamp"
    case memoryWarning = "memory-warning"
    case proactiveMemoryPressure = "proactive-memory-pressure"
}

/// Result returned by the controller's destructive-cache admission point. A started flight may still terminate
/// with a command error, settle-window acceptance, or cancellation; those outcomes are recorded by the
/// controller's bounded receipts rather than added to this finite admission surface.
enum CacheFlushDisposition: Equatable {
    case started
    case coalesced
    case skipped
}

/// One controller-local destructive cache operation. `Owner` is the exact loaded-file token in production; the
/// standalone policy harness uses an integer so these lifecycle rules remain testable without libmpv/UIKit.
struct CacheFlushFlight<Owner: Equatable> {
    enum Phase: String, Equatable {
        case dropping
        case seeking
        case settling
        case terminal
    }

    enum Result: String, Equatable {
        case pending
        case commandAccepted = "command-accepted"
        case dropCommandError = "drop-command-error"
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
    var phase: Phase = .dropping
    var result: Result = .pending
    var timeoutWorkItem: DispatchWorkItem?
}

/// Main-queue-owned single flight for the destructive cache drop plus exact re-anchor seek. This is a value
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

    mutating func markDropSucceeded(id: UInt64, owner: Owner) -> Bool {
        guard var flight = current, flight.id == id, flight.owner == owner else { return false }
        guard flight.phase == .dropping, flight.result == .pending else { return false }
        flight.phase = .seeking
        current = flight
        return true
    }

    mutating func markSeekCommandAccepted(id: UInt64, owner: Owner) -> Bool {
        guard var flight = current, flight.id == id, flight.owner == owner else { return false }
        guard flight.phase == .seeking, flight.result == .pending else { return false }
        flight.phase = .settling
        current = flight
        return true
    }

    @discardableResult
    mutating func dropCommandError(id: UInt64, owner: Owner) -> CacheFlushFlight<Owner>? {
        finishIfExact(id: id, owner: owner, phase: .dropping, result: .dropCommandError)
    }

    /// A seek command error is latched in the settling phase, not retried or resampled. The settle window remains
    /// the one bounded exit.
    mutating func seekCommandError(id: UInt64, owner: Owner) -> Bool {
        guard var flight = current, flight.id == id, flight.owner == owner else { return false }
        guard flight.phase == .seeking, flight.result == .pending else { return false }
        flight.phase = .settling
        flight.result = .seekCommandError
        current = flight
        return true
    }

    /// The single 15-second settle-window edge accepts a successful seek or preserves its latched error. It
    /// requires the exact flight identity and never consults a replacement's current ID.
    @discardableResult
    mutating func settle(id: UInt64, owner: Owner) -> CacheFlushFlight<Owner>? {
        guard let flight = current,
              flight.id == id,
              flight.owner == owner,
              flight.phase == .settling,
              flight.result == .pending || flight.result == .seekCommandError else { return nil }
        let result: CacheFlushFlight<Owner>.Result =
            flight.result == .seekCommandError ? .seekCommandError : .commandAccepted
        return finish(result: result)
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
    /// (`flushDemuxerCachePreservingPosition`, a drop-buffers plus an exact re-anchor seek)?
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

    /// Parse the two cap spellings the controller actually applies to mpv: plain byte counts
    /// ("268435456", the Streaming-cache branch) and MiB-suffixed ("256MiB", the static tiers).
    /// nil for anything else, so a surprise never silently becomes a 0-byte cache.
    static func capBytes(_ value: String) -> Int? {
        if let plain = Int(value) { return plain > 0 ? plain : nil }
        if value.hasSuffix("MiB"), let mib = Int(value.dropLast(3)) { return mib > 0 ? mib << 20 : nil }
        return nil
    }
}
