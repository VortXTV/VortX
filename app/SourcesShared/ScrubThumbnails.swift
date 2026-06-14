import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
typealias ScrubImage = NSImage
#elseif canImport(UIKit)
typealias ScrubImage = UIImage
#endif

/// Provides scrub-preview thumbnails from locally captured frames.
/// When no server storyboard is available the player captures a frame every ~10 s of playback
/// and stores it via `recordCapturedFrameData`. During scrubbing `show(time:)` serves the
/// nearest stored frame so the user gets a preview even without a network trickplay service.
@MainActor
final class ScrubThumbnailsStore: ObservableObject {
    @Published private(set) var image: ScrubImage?

    private var localCacheKey: String?
    private static let localFrameCache = LocalTrickplayFrameCache()

    func configure(localCacheKey: String?) {
        guard self.localCacheKey != localCacheKey else { return }
        self.localCacheKey = localCacheKey
        image = nil
    }

    /// Shows the stored frame nearest to `time`. Call while the user is scrubbing.
    func show(time: Double) {
        guard let key = localCacheKey,
              let local = Self.localFrameCache.image(for: key, time: time) else {
            image = nil
            return
        }
        image = local
    }

    func clear() {
        image = nil
    }

    /// Stores a captured frame for future scrub previews.
    func recordCapturedFrameData(_ data: Data, at time: Double) {
        guard let key = localCacheKey, !key.isEmpty else { return }
        guard let decoded = ScrubImage(data: data) else {
            NSLog("[trickplay] dropping frame at %.0fs: JPEG decode failed", time)
            return
        }
        #if canImport(AppKit)
        if let cgImage = decoded.cgImage(forProposedRect: nil, context: nil, hints: nil),
           Self.isBlackImage(cgImage) {
            return
        }
        #endif
        Self.localFrameCache.store(image: decoded, data: data, for: key, time: time)
    }

    /// Samples five points; considers the frame black (unrendered) if four or more are near-black.
    #if canImport(AppKit)
    private static func isBlackImage(_ cgImage: CGImage) -> Bool {
        guard cgImage.width > 0, cgImage.height > 0 else { return true }
        let w = cgImage.width, h = cgImage.height
        guard let data = cgImage.dataProvider?.data else { return false }
        let bytes = CFDataGetBytePtr(data)
        let bpr = cgImage.bytesPerRow
        let len = CFDataGetLength(data)
        let points = [(w/4, h/4), (3*w/4, h/4), (w/2, h/2), (w/4, 3*h/4), (3*w/4, 3*h/4)]
        let blackCount = points.filter { x, y in
            let off = y * bpr + x * 4
            guard off + 3 < len else { return false }
            return (bytes?[off] ?? 0) < 30 && (bytes?[off+1] ?? 0) < 30 && (bytes?[off+2] ?? 0) < 30
        }.count
        return blackCount >= 4
    }
    #endif
}

// MARK: - Local frame cache

private final class LocalTrickplayFrameCache {
    private let bucketSeconds: Double = 2
    private let maxLookbackBuckets = 180        // ~6 min back at 2 s per bucket
    private let ttl: TimeInterval = 48 * 3600
    private let maxDiskBytes: Int64 = 256 * 1024 * 1024
    private let ioQueue = DispatchQueue(label: "com.stremiox.trickplay.localcache", qos: .utility)
    private var memory: [String: [Int: ScrubImage]] = [:]
    private var lastPrune = Date.distantPast

    private lazy var cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("trickplay-local", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        ioQueue.async { _ = self.cacheDirectory }
    }

    func hasFrames(for key: String?) -> Bool {
        guard let key, !key.isEmpty else { return false }
        return ioQueue.sync {
            if let buckets = memory[key], !buckets.isEmpty { return true }
            let prefix = filePrefix(for: key) + "-"
            let files = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
            return files.contains { $0.lastPathComponent.hasPrefix(prefix) }
        }
    }

    func store(image: ScrubImage, data: Data, for key: String, time: Double) {
        let bucket = bucketFor(time)
        ioQueue.async {
            self.memory[key, default: [:]][bucket] = image
            try? data.write(to: self.fileURL(for: key, bucket: bucket), options: .atomic)
            self.pruneIfNeeded()
        }
    }

    func image(for key: String, time: Double) -> ScrubImage? {
        let target = bucketFor(time)
        return ioQueue.sync {
            let minBucket = max(0, target - maxLookbackBuckets)
            for bucket in stride(from: target, through: minBucket, by: -1) {
                if let cached = memory[key]?[bucket] { return cached }
                let url = fileURL(for: key, bucket: bucket)
                guard let data = try? Data(contentsOf: url),
                      let decoded = ScrubImage(data: data) else { continue }
                memory[key, default: [:]][bucket] = decoded
                return decoded
            }
            return nil
        }
    }

    private func bucketFor(_ time: Double) -> Int { Int(max(0, floor(time / bucketSeconds))) }

    private func fileURL(for key: String, bucket: Int) -> URL {
        cacheDirectory.appendingPathComponent("\(filePrefix(for: key))-\(bucket).jpg")
    }

    private func filePrefix(for key: String) -> String {
        Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private func pruneIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastPrune) > 600 else { return }
        lastPrune = now
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }
        var retained: [(url: URL, date: Date, size: Int64)] = []
        var total: Int64 = 0
        for file in files {
            guard let vals = try? file.resourceValues(forKeys: Set(keys)),
                  vals.isRegularFile == true else { continue }
            let modified = vals.contentModificationDate ?? .distantPast
            let size = Int64(vals.fileSize ?? 0)
            if now.timeIntervalSince(modified) > ttl { try? FileManager.default.removeItem(at: file); continue }
            total += size
            retained.append((file, modified, size))
        }
        if total > maxDiskBytes {
            for item in retained.sorted(by: { $0.date < $1.date }) {
                if total <= maxDiskBytes { break }
                try? FileManager.default.removeItem(at: item.url)
                total -= item.size
            }
        }
    }

}
