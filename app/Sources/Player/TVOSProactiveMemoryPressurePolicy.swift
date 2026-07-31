import Foundation

/// Pure decision policy for tvOS dirty-memory headroom checks.
///
/// The controller samples `os_proc_available_memory()` at a low rate and passes the snapshot here.
/// A transition is one-way for the current file: once pressure has reduced the cache, recovered
/// headroom never raises it again. The next file starts with its normal budget and a fresh state.
enum TVOSProactiveMemoryPressurePolicy {
    static let sampleInterval: TimeInterval = 15
    static let receiptInterval: TimeInterval = 60

    private static let minimumThresholdBytes: UInt64 = 192 << 20
    private static let maximumThresholdBytes: UInt64 = 384 << 20
    private static let normalRemoteVODLimitBytes: Int64 = 128 << 20
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
}
