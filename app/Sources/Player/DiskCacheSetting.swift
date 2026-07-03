import Foundation
import os

/// User-configurable streaming/seek cache for the libmpv player.
///
/// libmpv keeps a forward read-ahead buffer (`demuxer-max-bytes`) so the play head can run ahead of
/// the network. By default that buffer lives in RAM, which on the in-process, jetsam-bound iOS/tvOS
/// targets is tightly capped (see MPVMetalViewController's per-file read-ahead sizing). This setting
/// moves the big buffer to an ON-DISK cache (`cache-on-disk=yes` + `cache-dir`), so a viewer can pick
/// a large forward buffer (seek minutes ahead without re-buffering, pre-cache) WITHOUT spending RAM.
///
/// CRITICAL SAFETY (the two owner guardrails):
///   1. Unbounded growth is impossible. `UNLIMITED` and any large finite value are still capped at a
///      fraction of CURRENT FREE DISK at the moment the player starts (`resolvedMaxBytes`), so the
///      cache can never fill the device. The cap is recomputed every time a file loads.
///   2. A finished title does not persist. The cache directory is wiped on a genuine playback exit
///      (the finish / leavePlayback path) and again as a safety sweep on app launch, so a crash can
///      never leave an unbounded cache behind.
///
/// `cache-on-disk` has been a stable libmpv option since mpv 0.30 (2019); MPVKit 0.41.0 (mpv 0.41.x)
/// includes it. If a future mpv build ever drops it, the options simply no-op and mpv falls back to
/// the in-memory cache bounded by `demuxer-max-bytes`, which is still clamped by `resolvedMaxBytes`.
enum DiskCacheSetting {
    /// UserDefaults key. Stored as the raw byte count (Int64) the viewer asked for; `0` == OFF,
    /// `unlimitedSentinel` == UNLIMITED. Any other value is a literal finite byte budget.
    static let key = "stremiox.diskCacheBytes"

    private static let log = Logger(subsystem: "com.stremiox.app", category: "diskCache")

    static let gib: Int64 = 1024 * 1024 * 1024

    /// Sentinel stored for UNLIMITED. Not a real byte count: `resolvedMaxBytes` turns it into the
    /// free-disk ceiling. Distinct from any plausible literal budget.
    static let unlimitedSentinel: Int64 = -1

    /// Free-disk-ceiling FALLBACK budget when free space can't be read (NOT the unset default). 2 GB is a
    /// safe middle value. The actual unset default is OFF (see `storedBytes`): this on-disk cache is the
    /// same mechanism that crashed Apple TVs at ~21s into 4K remuxes in 0.2.11, so it ships OFF until it has
    /// been soak-tested on real hardware. The owner opts in to test.
    static let defaultBytes: Int64 = 2 * gib

    /// OFF still needs a tiny forward buffer so playback is not starved. Mirrors the smallest existing
    /// in-memory read-ahead used elsewhere in the player.
    static let offFloorBytes: Int64 = 64 * 1024 * 1024   // 64 MiB

    /// Never let the cache consume more than this fraction of FREE disk, even for UNLIMITED or a huge
    /// literal value. Half of free space leaves ample headroom for the OS, the engine HTTP cache, and
    /// the in-process torrent cache.
    static let freeDiskFraction: Double = 0.5

    /// Hard upper ceiling on a CONSTRAINED device (Apple TV HD). Even with disk (not RAM) backing the
    /// cache, the tiny internal storage + jetsam pressure means a runaway cache-dir is dangerous there,
    /// so cap it tight regardless of what was chosen (or synced from a Mac).
    static let constrainedDeviceCeilingBytes: Int64 = 2 * gib

    // MARK: Persistence

    /// The viewer's stored choice as a raw byte count (or a sentinel). Defaults to OFF (0) when unset:
    /// the on-disk cache is opt-in because this exact mechanism crashed Apple TVs at ~21s into 4K remuxes
    /// in 0.2.11 and has not been re-soak-tested on hardware. Interops with the Settings
    /// `@AppStorage(...) var: Int` binding: UserDefaults boxes both Int and Int64 as NSNumber, so reading
    /// via NSNumber round-trips whichever side wrote it.
    static var storedBytes: Int64 {
        get {
            guard let number = UserDefaults.standard.object(forKey: key) as? NSNumber else {
                return 0   // OFF until the viewer opts in (keeps the proven in-memory read-ahead)
            }
            return number.int64Value
        }
        set { UserDefaults.standard.set(NSNumber(value: newValue), forKey: key) }
    }

    static var isOff: Bool { storedBytes == 0 }
    static var isUnlimited: Bool { storedBytes == unlimitedSentinel }

    // MARK: Cache directory

    /// On-disk cache location: an app Caches subdirectory. The OS may purge Caches under storage
    /// pressure, which is the desired failure mode for a disposable streaming buffer. Created lazily.
    static var cacheDirectoryURL: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return caches.appendingPathComponent("mpv-cache", isDirectory: true)
    }

    /// Ensure the cache directory exists; returns its path for `cache-dir`, or nil on failure.
    static func ensureCacheDirectory() -> String? {
        guard let url = cacheDirectoryURL else { return nil }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        } catch {
            log.error("could not create mpv cache dir: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Free-disk ceiling (the UNLIMITED safety)

    /// Bytes of free space on the volume that backs the Caches directory, or nil if it can't be read.
    static var freeDiskBytes: Int64? {
        guard let url = cacheDirectoryURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        #if !os(tvOS)
        // volumeAvailableCapacityForImportantUsage is unavailable on tvOS; iOS/macOS use it (it accounts
        // for purgeable space). tvOS falls through to the POSIX systemFreeSize below.
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let important = values.volumeAvailableCapacityForImportantUsage {
            return Int64(important)
        }
        #endif
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return nil
    }

    /// The ACTUAL byte budget to hand mpv right now, after every safety clamp:
    ///   - OFF        -> a small floor (playback is never starved, but no big buffer)
    ///   - UNLIMITED  -> freeDisk * freeDiskFraction (NEVER actually unlimited)
    ///   - a value    -> min(value, freeDisk * freeDiskFraction)
    /// plus a hard ceiling on constrained devices. Recomputed per played file so it always reflects
    /// CURRENT free space, never a stale snapshot.
    static func resolvedMaxBytes() -> Int64 {
        let stored = storedBytes
        if stored == 0 { return offFloorBytes }

        // Free-disk ceiling. If free space can't be read, fall back to a conservative fixed cap rather
        // than trusting an unbounded request.
        let freeCeiling: Int64
        if let free = freeDiskBytes, free > 0 {
            freeCeiling = Int64(Double(free) * freeDiskFraction)
        } else {
            freeCeiling = defaultBytes   // unknown free space -> behave like the safe default
        }

        var budget: Int64
        if stored == unlimitedSentinel {
            budget = freeCeiling
        } else {
            budget = min(stored, freeCeiling)
        }

        if PerformanceMode.reduced {
            budget = min(budget, constrainedDeviceCeilingBytes)
        }

        // Never below the floor (so even a tiny free-disk volume keeps playback alive).
        return max(budget, offFloorBytes)
    }

    /// Whether the on-disk cache should be armed at all. OFF keeps mpv on its in-memory buffer.
    /// Also gated by the RemoteConfig fleet kill-switch `features.diskCache`: a remote `false` FORCES the
    /// cache off fleet-wide (an escape hatch if the disk cache regresses on some devices). Baked default is
    /// true, so an absent / null remote field is behaviorally identical to shipping; the user's own Off/On
    /// selection still governs — this only ANDs in the fleet gate.
    static var diskCacheEnabled: Bool {
        !isOff && RemoteConfig.snapshot.isFeatureOn("diskCache", default: true)
    }

    // MARK: Auto-clear

    /// Delete the cache directory's contents. Called on a genuine playback exit and as a launch sweep.
    /// Best-effort and silent on failure: a leftover file is bounded by `resolvedMaxBytes` anyway, and
    /// the OS can purge Caches under pressure. Never throws into the teardown / launch path.
    static func clearCache() {
        guard let url = cacheDirectoryURL else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            // Directory may not exist yet (never played) — nothing to clear.
            return
        }
        var cleared = 0
        for entry in entries {
            if (try? fm.removeItem(at: entry)) != nil { cleared += 1 }
        }
        if cleared > 0 { log.log("cleared \(cleared, privacy: .public) mpv cache entr\(cleared == 1 ? "y" : "ies", privacy: .public)") }
    }

    // MARK: UI helpers

    /// Current on-disk cache usage in bytes (sum of the cache directory's files), or 0 if empty/missing.
    /// Used only to show "current usage" in Settings; cheap enough for a settings screen, not a hot path.
    static var currentUsageBytes: Int64 {
        guard let url = cacheDirectoryURL else { return 0 }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for entry in entries {
            if let values = try? entry.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
                total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return total
    }

    /// The picker choices, in order. `id` is the raw stored value; `label` is the menu text.
    static let pickerOptions: [(id: Int64, label: String)] = [
        (0, "Off"),
        (2 * gib, "2 GB"),
        (5 * gib, "5 GB"),
        (10 * gib, "10 GB"),
        (20 * gib, "20 GB"),
        (unlimitedSentinel, "Unlimited"),
    ]

    /// Human label for a stored value (for the current-selection display / summary text).
    static func label(for bytes: Int64) -> String {
        if bytes == 0 { return "Off" }
        if bytes == unlimitedSentinel { return "Unlimited" }
        let gb = Double(bytes) / Double(gib)
        return gb >= 1 ? "\(Int(gb.rounded())) GB" : "\(bytes / (1024 * 1024)) MB"
    }

    /// "1.4 GB" style formatter for the live usage readout.
    static func humanReadable(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
