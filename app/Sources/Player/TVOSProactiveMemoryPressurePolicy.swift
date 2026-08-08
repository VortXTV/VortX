import Foundation

/// Pure decision policy for tvOS dirty-memory headroom checks.
///
/// The controller samples `os_proc_available_memory()` at a low rate and passes the snapshot here.
///
/// The two directions are deliberately asymmetric. Shrinking is immediate: one sample below the pressure
/// threshold halves the cache. Growing back is hysteresis-gated (FAIL-260804-04: a shed cap sat at the
/// 48 MiB floor for the remaining 66 minutes of a film with roughly 900 MiB free, because nothing in the
/// lane could ever raise it again). A restore needs headroom at TWICE the clamp threshold, held for
/// `restoreSustainedSamples` consecutive samples, and then steps up a single rung toward the per-file
/// baseline the controller recorded at load. The gap between the two thresholds is what keeps the cap
/// from chattering across one boundary, and the baseline is a hard ceiling because a larger tvOS cap is
/// not device-safe. Restores are also CAPPED per file (`maxRestoreCyclesPerFile`), so external pressure that
/// oscillates around the threshold cannot turn a one-shot clamp into an endless clamp/restore ladder; past the
/// cap the clamp is one-way again. The next file starts with its normal budget and a fresh state.
enum TVOSProactiveMemoryPressurePolicy {
    static let sampleInterval: TimeInterval = 15
    static let receiptInterval: TimeInterval = 60

    private static let minimumThresholdBytes: UInt64 = 192 << 20
    private static let maximumThresholdBytes: UInt64 = 384 << 20
    /// The tvOS NORMAL-tier RAM wall for the remote VOD forward buffer. Raised 128 -> 384 MiB so the new
    /// RemoteConfig-backed 384 MiB read-ahead baseline (the RAM-safe max for the "smoother playback" fix)
    /// passes through rather than being clamped back down. 384 MiB stays well under the ~700 MiB jetsam wall
    /// the 3 GB Apple TV 4K field logs proved fatal (at the field-min 712 MiB free it leaves ~328 MiB), and the
    /// RemoteConfig ceiling (default 384, clamped <= 448) bounds any operator-raised baseline in
    /// `RemoteConfig.validate`.
    private static let normalRemoteVODLimitBytes: Int64 = 384 << 20
    /// The 2 GB Apple TV HD (`PerformanceMode.reduced`) RAM wall. UNCHANGED at 96 MiB: that tier is
    /// jetsam-critical and its tight buffers must stay exactly as shipped.
    private static let reducedRemoteVODLimitBytes: Int64 = 96 << 20

    /// Select the remote VOD budget, then enforce the tvOS process-memory ceiling. The disk cache
    /// changes where bytes may persist, but it does not make mpv's forward buffer leave process RAM.
    /// Other platforms pass `enforceTVOSLimit: false` and receive their selected value unchanged.
    static func remoteVODCapBytes(
        diskCacheEnabled: Bool,
        baselineBytes: Int64,
        configuredDiskCacheBytes: Int64,
        performanceReduced: Bool,
        enforceTVOSLimit: Bool
    ) -> Int64 {
        let selected = diskCacheEnabled ? configuredDiskCacheBytes : baselineBytes
        guard enforceTVOSLimit else { return selected }
        let limit = performanceReduced ? reducedRemoteVODLimitBytes : normalRemoteVODLimitBytes
        return min(selected, limit)
    }

    /// Start shedding before the process reaches its dirty-memory limit. The ratio scales from
    /// Apple TV HD to Apple TV 4K while the absolute bounds keep the trigger useful on future devices.
    static func pressureThresholdBytes(physicalMemoryBytes: UInt64) -> UInt64 {
        let scaled = physicalMemoryBytes / 8
        return min(max(scaled, minimumThresholdBytes), maximumThresholdBytes)
    }

    /// Return the smaller forward-cache budget for the single allowed proactive transition.
    /// `os_proc_available_memory()` returns zero when the process has exhausted its dirty-memory
    /// allowance, so zero is the strongest pressure signal and must clamp rather than fail open.
    static func clampTargetBytes(
        availableMemoryBytes: UInt64,
        physicalMemoryBytes: UInt64,
        currentCapBytes: Int,
        floorBytes: Int,
        alreadyClamped: Bool
    ) -> Int? {
        guard !alreadyClamped,
              availableMemoryBytes < pressureThresholdBytes(physicalMemoryBytes: physicalMemoryBytes),
              currentCapBytes > floorBytes else {
            return nil
        }

        let target = max(floorBytes, currentCapBytes / 2)
        return target < currentCapBytes ? target : nil
    }

    /// How much clearer than the clamp threshold headroom must be before a restore is considered. Restore
    /// and clamp must never share a boundary: a raise refills the cache, which lowers headroom, which
    /// would re-trip a clamp whose only tool is drop-buffers plus an exact re-anchor seek.
    private static let restoreHysteresisMultiplier: UInt64 = 2

    /// Consecutive recovered samples a restore requires: 8 times the 15 s sample interval, so two minutes
    /// of held headroom rather than one lucky reading between two allocations.
    static let restoreSustainedSamples = 8

    /// The headroom a restore requires, deliberately well clear of `pressureThresholdBytes`.
    static func restoreThresholdBytes(physicalMemoryBytes: UInt64) -> UInt64 {
        pressureThresholdBytes(physicalMemoryBytes: physicalMemoryBytes) * restoreHysteresisMultiplier
    }

    /// How many restores ONE file may be granted. The clamp used to be strictly one-shot per file; allowing a
    /// restore necessarily RE-ARMS it, so under external pressure that oscillates around the threshold (another
    /// app allocating and freeing) one clamp would become an endless ladder - and every rung DOWN pays
    /// `flushDemuxerCachePreservingPosition`, a drop-buffers plus an exact re-anchor seek, which is the
    /// "jumps forward after a pause" regression surface.
    ///
    /// Two is sized for what FAIL-260804-04 actually reported: a warning halves the budget, one proactive clamp
    /// halves it again, and a SINGLE rung back up already returns the file to its load budget - so the common
    /// recovery costs one cycle and the spare covers a second dip. Past the cap the clamp is one-way for the
    /// rest of the file, which is exactly the behavior this whole policy is a bounded relaxation of. The cost
    /// of the bound is that a file which shed several rungs recovers only two of them; a partial cache beats
    /// both the floor-forever bug and an unbounded flush/seek ladder.
    static let maxRestoreCyclesPerFile = 2

    /// Return the LARGER forward-cache budget once a reduced file has held restore-grade headroom long
    /// enough, or nil to leave the cap where it is. One rung per call (double, capped at the per-file
    /// baseline) so the way back up is gradual and every rung re-earns its own sustained window.
    ///
    /// `baselineCapBytes` is the cap `loadFile` applied and is a HARD ceiling: it already passed the
    /// device-safe tvOS limit, and a large `os_proc_available_memory()` reading is not permission to
    /// exceed it. Zero available memory is the strongest pressure signal, and it fails the threshold test
    /// like every other reading below it, so recovery stays fail-closed for exactly the same reason the
    /// clamp above does.
    ///
    /// `completedRestoreCycles` is how many restores this file has already been granted (see
    /// `maxRestoreCyclesPerFile`); at the cap this returns nil for every remaining sample of the file and the
    /// clamp is one-way again. Defaults to 0 so a caller that does not track cycles - the pure ladder cases in
    /// the tests - behaves exactly as before.
    static func restoreTargetBytes(
        availableMemoryBytes: UInt64,
        physicalMemoryBytes: UInt64,
        currentCapBytes: Int,
        baselineCapBytes: Int,
        consecutiveRecoveredSamples: Int,
        completedRestoreCycles: Int = 0
    ) -> Int? {
        guard currentCapBytes < baselineCapBytes,
              completedRestoreCycles < maxRestoreCyclesPerFile,
              consecutiveRecoveredSamples >= restoreSustainedSamples,
              availableMemoryBytes
                >= restoreThresholdBytes(physicalMemoryBytes: physicalMemoryBytes) else {
            return nil
        }

        let target = min(currentCapBytes * 2, baselineCapBytes)
        return target > currentCapBytes ? target : nil
    }
}
