import Foundation
import AppKit

@main @MainActor
private enum TrickplayLocalReadCancellationTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError(message) }
    }

    static func frame(_ red: UInt8) -> (NSImage, Data) {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        let color = NSColor(deviceRed: Double(red) / 255, green: 0, blue: 0, alpha: 1)
        for y in 0..<2 { for x in 0..<2 { bitmap.setColor(color, atX: x, y: y) } }
        let data = bitmap.representation(using: .png, properties: [:])!
        return (NSImage(data: data)!, data)
    }

    static func value(_ image: NSImage?) -> Int? {
        guard let data = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let color = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return nil }
        // Compare deliberately dark/light fixtures across AppKit color-profile conversion.
        return color.redComponent > 0.5 ? 210 : 40
    }

    static func read(_ cache: LocalTrickplayFrameCache, key: String, time: Double) async -> Int? {
        await withCheckedContinuation { continuation in
            cache.imageAsync(for: key, time: time, lease: TrickplayLocalReadLease()) {
                continuation.resume(returning: value($0))
            }
        }
    }

    static func settles(_ preview: PreviewHarness, to expected: Int) async {
        for _ in 0..<100 {
            if value(preview.image) == expected { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("preview did not replace its placeholder with saved frame \(expected)")
    }

    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let worker = LocalTrickplayDiskWorker(directory: directory)
        let cache = LocalTrickplayFrameCache(diskWorker: worker)
        let disk = TrickplayFrameDiskStore(directory: directory)
        let (recent, recentData) = frame(210)
        let (_, oldData) = frame(40)
        // The downloaded watch left only disk frames; this session has two recent resident captures.
        try disk.write(oldData, mediaKey: "episode-a", bucket: 10)
        cache.store(image: recent, data: recentData, for: "episode-a", time: 600)
        cache.store(image: recent, data: recentData, for: "episode-a", time: 610)
        _ = await read(cache, key: "episode-a", time: 610) // drain both stores
        let preview = PreviewHarness(cache: cache, key: "episode-a")
        preview.show(time: 20)
        expect(value(preview.image) == 210, "warm fallback must remain immediate while disk is read")
        await settles(preview, to: 40)
        expect(value(preview.image) == 40, "exact prior-watch disk frame must replace future memory placeholder")

        try disk.write(oldData, mediaKey: "episode-b", bucket: 300)
        cache.store(image: recent, data: recentData, for: "episode-b", time: 590)
        _ = await read(cache, key: "episode-b", time: 590)
        preview.clear(); preview.localCacheKey = "episode-b"
        preview.show(time: 600)
        expect(value(preview.image) == 210, "earlier memory remains an immediate placeholder")
        await settles(preview, to: 40)
        expect(value(preview.image) == 40, "exact disk frame beats memory inside primary lookback")

        try disk.write(oldData, mediaKey: "nearest", bucket: 505)
        cache.store(image: recent, data: recentData, for: "nearest", time: 1100)
        _ = await read(cache, key: "nearest", time: 1100)
        let nearer = await read(cache, key: "nearest", time: 1000)
        expect(nearer == 40,
               "nearer future disk frame beats farther resident frame")
        try disk.write(oldData, mediaKey: "tie", bucket: 510)
        cache.store(image: recent, data: recentData, for: "tie", time: 980)
        _ = await read(cache, key: "tie", time: 980)
        let primary = await read(cache, key: "tie", time: 1000)
        expect(primary == 210,
               "at-or-before coverage retains priority over a future frame")
        try disk.write(oldData, mediaKey: "future-tie", bucket: 510)
        cache.store(image: recent, data: recentData, for: "future-tie", time: 220)
        _ = await read(cache, key: "future-tie", time: 220)
        let tied = await read(cache, key: "future-tie", time: 620)
        expect(tied == 40,
               "equal-distance nearest disk/resident tie chooses higher future bucket")
        let isolated = await read(cache, key: "another-episode", time: 20)
        expect(isolated == nil,
               "same time in a different episode cannot reuse another episode's images")

        // Park the real serial worker: cancelled requests must not publish after clear or A→B→A.
        let parked = DispatchSemaphore(value: 0), resumed = DispatchSemaphore(value: 0)
        worker.ioQueue.async { parked.signal(); _ = resumed.wait(timeout: .now() + 3) }
        expect(parked.wait(timeout: .now() + 3) == .success, "worker barrier must start")
        var completions = 0
        var previous: TrickplayLocalReadLease?
        for _ in 0..<100 {
            previous?.cancel()
            let lease = TrickplayLocalReadLease(); previous = lease
            cache.imageAsync(for: "episode-a", time: 20, lease: lease) { _ in completions += 1 }
        }
        preview.clear(); preview.localCacheKey = "episode-a"; preview.show(time: 24)
        preview.clear(); preview.localCacheKey = "episode-b"; preview.show(time: 24)
        preview.clear(); preview.localCacheKey = "episode-a" // same key, different request epoch
        resumed.signal()
        _ = await read(cache, key: "episode-a", time: 20)
        expect(completions == 1, "cancelled burst only completes its newest owner")
        expect(preview.image == nil && preview.previewState == .hidden,
               "A→B→A and clear reject stale disk publications")
        let cancelled = TrickplayLocalReadLease(); cancelled.cancel()
        var called = false
        cache.imageAsync(for: "episode-a", time: 20, lease: cancelled) { _ in called = true }
        _ = await read(cache, key: "episode-a", time: 20)
        expect(!called, "already-cancelled read never publishes")
        var scanChecks = 0
        let cancelledScan = disk.nearest(mediaKey: "episode-a", targetBucket: 12, shouldContinue: {
            scanChecks += 1; return scanChecks < 3
        })
        expect(cancelledScan == nil && scanChecks == 3, "disk scan observes cancellation")
        try disk.write(oldData, mediaKey: "disk-tie", bucket: 9)
        try disk.write(recentData, mediaKey: "disk-tie", bucket: 11)
        expect(disk.nearest(mediaKey: "disk-tie", targetBucket: 10)?.bucket == 11,
               "disk-only distance ties choose the higher bucket deterministically")

        var retry = TrickplayCommunityFetchPolicy()
        expect(retry.begin(now: 0), "initial fetch is immediate")
        for tick in 1...1000 { expect(!retry.begin(now: Double(tick)), "in-flight fetch never overlaps") }
        retry.finish(now: 1, succeeded: false)
        expect(!retry.begin(now: 30), "first miss waits thirty seconds")
        expect(retry.begin(now: 31), "first retry starts exactly at its deadline")
        retry.finish(now: 32, succeeded: false)
        expect(!retry.begin(now: 151), "second retry waits two minutes")
        expect(retry.begin(now: 152), "second retry starts at its deadline")
        retry.finish(now: 153, succeeded: false)
        expect(!retry.begin(now: 10_000), "three attempts cap per-key failed requests")
        retry.reset()
        expect(retry.begin(now: 154), "new exact key resets admission")
        retry.finish(now: 155, succeeded: true)
        expect(!retry.begin(now: 20_000), "success stops clock-driven retries")
        expect(!TrickplayFetchClaim.accepts(requestEpoch: 1, requestKey: "a", currentEpoch: 3, currentKey: "a"),
               "stale same-key fetch completion cannot change retry state")
        expect(!TrickplayPreviewReadGate.accepts(requestToken: 1, requestMediaKey: "a", currentToken: 3, currentMediaKey: "a"),
               "stale same-media read cannot publish after A→B→A")
        print("Trickplay actual-cache reuse/cancellation/retry: \(checks) passed")
    }
}
