import Foundation

/// Dependency-free memory-warning cache-shedding decisions for `MPVMetalViewController`, split out so the
/// executable test harness can run them without UIKit/libmpv (the DVPlaybackContractTests pattern).
///
/// WHY THIS EXISTS (#148, "caches then stops caching ~40s in"): the old handler answered EVERY system
/// memory warning by slamming `demuxer-max-bytes` to the 48 MiB floor for the rest of the file. On the
/// Apple TV the big read-ahead (256 MiB base, up to 768 MiB with the Streaming cache armed) fills at link
/// speed, RSS balloons within ~35-50 s of an mpv mount, tvOS posts a warning, and the field log shows the
/// exact reported symptom on six consecutive plays: the cache bar fills, "the cache is gone and buffered
/// again" (drop-buffers + re-anchor seek), and "caching is not happening after that" (a 48 MiB budget is
/// ~12-25 s of 4K, visually nothing). The REAL relief is the buffer DROP, which frees the resident bytes
/// immediately either way; the refill budget decides only the next peak. So: the FIRST warning halves the
/// current budget (768 -> 384, 256 -> 128; caching stays visibly alive), and any LATER warning in the same
/// file goes straight to the floor (exactly the old terminal state, so sustained pressure ends where it
/// always did, at most one extra warning-cycle later). A new file still resets to its full budget.
enum VortXCacheShedPolicy {

    /// The historical clamp floor (48 MiB): small enough for jetsam relief, enough for a rolling buffer.
    static let floorBytes = 48 << 20

    /// The forward-cache cap to apply when a system memory warning arrives.
    /// - First warning for this file (`previouslyShed == false`): half the current budget, floored.
    /// - Any later warning: the floor, the old handler's terminal state.
    static func forwardCapAfterWarning(currentBytes: Int, previouslyShed: Bool) -> Int {
        guard !previouslyShed else { return floorBytes }
        return max(floorBytes, currentBytes / 2)
    }

    /// diag-23 FIX-C: should a SOFT memory warning SKIP the immediate buffer flush the shed otherwise
    /// performs (`flushDemuxerCachePreservingPosition`, a drop-buffers plus an exact re-anchor seek)?
    ///
    /// That flush is the JETSAM tool: it frees the resident forward buffer NOW, the last line of defence
    /// before tvOS/iOS kills the app. It is also the source of a visible frame-drop burst - drop-buffers
    /// discards the decoded/demuxed packets and the exact seek re-anchors playback. diag-23 (00:51, the
    /// biggest sustained frame-drop cluster) caught it firing on a SOFT warning with roughly 940 MiB free
    /// against a 384 MiB pressure threshold: no jetsam anywhere near, so the cure (the burst) was worse
    /// than the disease.
    ///
    /// Return true (defer the flush) ONLY when BOTH hold, so the guard can never weaken jetsam relief:
    ///  1. `availableBytes` is at the RESTORE-grade bar (`restoreThresholdBytes`, twice the pressure
    ///     threshold) - the exact headroom the recovery path already trusts enough to GROW the cache, so
    ///     a kill is provably not imminent; and
    ///  2. the live forward cache (`cacheFillBytes`) already fits inside the reduced cap this warning
    ///     applies (`forwardCapAfterWarning`), so dropping it would free nothing that simply lowering the
    ///     cap does not already bound - the flush would be pure cost.
    ///
    /// Whenever headroom is not provably ample, or the cache overflows the reduced cap (the flush WOULD
    /// free real resident bytes), this returns false and the drastic shed+flush fires unchanged. The
    /// caller lowers the forward cap either way (non-increasing, the jetsam-safe part); only the immediate
    /// DROP is gated. The controller passes `cacheFillBytes = Int.max` when it cannot read the live fill,
    /// so an unknown cache also fails condition 2 and keeps the drastic path.
    ///
    /// The threshold is reused from `TVOSProactiveMemoryPressurePolicy` deliberately: "provably ample"
    /// here means exactly what it means to the recovery path, one definition, no drift.
    static func shouldDeferFlushOnWarning(
        availableBytes: UInt64,
        physicalBytes: UInt64,
        currentCapBytes: Int,
        cacheFillBytes: Int,
        previouslyShed: Bool
    ) -> Bool {
        let reducedCapBytes = forwardCapAfterWarning(currentBytes: currentCapBytes, previouslyShed: previouslyShed)
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
