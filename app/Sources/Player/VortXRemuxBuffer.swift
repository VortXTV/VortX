import Foundation

/// A thread-safe, forward-only growing byte buffer for the DV-for-MKV streaming remux (Phase 1). The remux
/// thread (`VortXMKVRemuxStream`) appends muxed fragmented-MP4 bytes as they are produced; the resource
/// loader (`VortXRemuxResourceLoader`) reads byte ranges out of it to feed AVPlayer.
///
/// Design notes:
/// - APPEND-ONLY at the head. Bytes are only ever added at the end; nothing already produced is rewritten. This
///   matches a forward-only stream-copy remux, where the muxer writes fMP4 fragments in order.
/// - BOUNDED SLIDING WINDOW at the tail. Because the resource loader advertises NO byte-range access
///   (`isByteRangeAccessSupported = false`), AVPlayer streams the asset strictly sequentially from offset 0 via
///   one open-ended request, so once a byte has been read it is never re-requested. We therefore drop bytes that
///   sit well below the reader's low-water mark, keeping only a small re-read floor plus a bounded producer
///   lead (the producer BLOCKS in `append` once resident bytes hit floor + lead, so a slow/paused reader can
///   never let it run away). This caps RAM at roughly (floor + producer lead) instead of the whole
///   movie, which on a feature-length 4K DV MKV would be many GB and jetsam the app on the memory-constrained
///   Apple TV. `storageBase` is the absolute offset of `storage[0]`; a reader's absolute offset maps to
///   `absolute - storageBase`. The window floor is a RemoteConfig dial (`dvRemuxWindowMiB`) so it can be tuned
///   or widened from the fleet like the other jetsam knobs, and a seek Phase-2 that needs byte-range access can
///   raise it.
/// - Thread-safety is a single `NSCondition`: producers append + signal, consumers wait for enough bytes or
///   for end-of-stream. All shared mutable state (`storage`, `storageBase`, `isFinished`, `failureMessage`,
///   `producedCount`) is touched only while the condition's lock is held.
///
/// This type carries NO libav or AVFoundation types, so it compiles on every target and is trivial to reason
/// about in isolation.
final class VortXRemuxBuffer: @unchecked Sendable {

    private let condition = NSCondition()
    /// The retained tail of the produced stream. `storage[0]` corresponds to absolute offset `storageBase`.
    private var storage = Data()
    /// Absolute offset of the first byte still held in `storage`. Bytes below this have been delivered and evicted.
    private var storageBase = 0
    private var isFinished = false
    private var failureMessage: String?

    /// Total bytes produced so far across the whole session (monotonic; NOT storage.count once eviction starts).
    private(set) var producedCount: Int = 0

    /// The re-read floor: how many already-delivered bytes to keep behind the reader's low-water mark before
    /// evicting. Kept small (a fragment or two) so a benign re-read at the current position still succeeds while
    /// RAM stays flat. Sourced from RemoteConfig so the fleet can widen it (e.g. for a future seek lane) without
    /// an app update; clamped to a sane floor here so a bad remote value can never make the window degenerate.
    private static var windowFloorBytes: Int {
        let mib = max(4, RemoteConfig.snapshot.dvRemuxWindowMiB)   // never below 4 MiB
        return mib * 1024 * 1024
    }

    /// Producer-lead budget on top of the re-read floor. This is the slack the remux thread is allowed to run
    /// ahead of the reader before `append` blocks. Without it the producer (a stream-copy that muxes as fast as
    /// the debrid link delivers) would race to the full remuxed size whenever AVPlayer throttles or the user
    /// pauses, and jetsam the memory-constrained Apple TV. Resident RAM is thus bounded to (floor + this).
    private static let producerLeadBytes = 64 * 1024 * 1024

    /// Bytes currently held in `storage` (delivered floor plus producer lead). Caller holds the lock.
    private var residentCount: Int { storage.count }

    // MARK: Producer side (remux thread)

    /// Append newly-muxed bytes and wake any waiting readers. Called from the remux thread's AVIO write
    /// callback. `bytes`/`count` point at libav-owned memory valid only for the call, so we copy immediately.
    ///
    /// Blocks (back-pressure) while resident bytes exceed (floor + producer lead), so a slow/paused reader can
    /// never let `storage` grow toward the whole-movie size. `finish`/`fail`/`cancel` broadcast, so a producer
    /// parked here wakes and returns without appending once the stream is torn down.
    func append(_ bytes: UnsafePointer<UInt8>, count: Int) {
        guard count > 0 else { return }
        condition.lock()
        let ceiling = Self.windowFloorBytes + Self.producerLeadBytes
        while residentCount >= ceiling && !isFinished {
            condition.wait(until: Date().addingTimeInterval(0.25))
        }
        if isFinished {           // finished/failed/cancelled while parked: drop these bytes, unblock teardown.
            condition.unlock()
            return
        }
        storage.append(bytes, count: count)
        producedCount += count
        condition.signal()
        condition.unlock()
    }

    /// Mark the stream complete (the remux loop wrote its trailer). Readers waiting past the end return the
    /// bytes they can and then see EOF instead of blocking forever.
    func finish() {
        condition.lock()
        isFinished = true
        condition.broadcast()
        condition.unlock()
    }

    /// Mark the stream failed (the remux threw). Readers unblock and can surface the failure to AVPlayer so
    /// the chrome's AVPlayer -> libmpv fallback fires instead of hanging.
    func fail(_ message: String) {
        condition.lock()
        if failureMessage == nil { failureMessage = message }
        isFinished = true
        condition.broadcast()
        condition.unlock()
    }

    // MARK: Consumer side (resource loader queue)

    struct ReadResult {
        var data: Data          // bytes actually available for the requested range (may be shorter than asked)
        var atEnd: Bool         // true when no more bytes will ever arrive past data
        var failure: String?    // non-nil if the remux failed OR the range fell below the evicted window
    }

    /// Snapshot of stream state without blocking. Used by the loader to answer a content-information request
    /// and to decide whether a data request can be served immediately.
    func status() -> (produced: Int, finished: Bool, failure: String?) {
        condition.lock(); defer { condition.unlock() }
        return (producedCount, isFinished, failureMessage)
    }

    /// Read up to `length` bytes starting at absolute `offset`, BLOCKING until either enough bytes are
    /// produced, the stream ends, or it fails. `cancelled` lets a torn-down request bail out of the wait.
    ///
    /// Returns the largest contiguous slice available at `offset` (bounded by `length`). A short read at EOF
    /// is normal (the tail fragment). An empty result with `atEnd` true means the offset is at/after the end.
    /// A request for an offset that has already been EVICTED below the window returns a failure (which drives
    /// the AVPlayer -> libmpv fallback); this cannot happen under the forward-only, no-byte-range delivery
    /// contract, so it is purely a safety net.
    func read(offset: Int, length: Int, cancelled: @escaping () -> Bool) -> ReadResult {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let failureMessage {
                return ReadResult(data: Data(), atEnd: true, failure: failureMessage)
            }
            if cancelled() {
                // Treat a cancelled wait as a soft end so the caller stops; it will not deliver these bytes.
                return ReadResult(data: Data(), atEnd: true, failure: nil)
            }
            if offset < storageBase {
                // The requested range was already delivered and evicted from the window. Under the forward-only
                // contract AVPlayer never asks for this; if it somehow does, fail so the chrome falls back to libmpv.
                return ReadResult(data: Data(), atEnd: true, failure: "range evicted below streaming window")
            }
            if offset < producedCount {
                let localStart = offset - storageBase
                let available = storage.count - localStart
                let take = min(length, available)
                let slice = storage.subdata(in: localStart..<(localStart + take))
                // atEnd only if we've handed back everything up to a finished stream's end.
                let end = isFinished && (offset + take >= producedCount)
                // The reader has consumed up to (offset + take); drop the delivered tail below the floor.
                evictBelow(offset + take)
                return ReadResult(data: slice, atEnd: end, failure: nil)
            }
            // offset is at or beyond what we've produced.
            if isFinished {
                return ReadResult(data: Data(), atEnd: true, failure: nil)
            }
            // Wait for more bytes (or finish/fail). A bounded wait lets us re-check `cancelled` periodically.
            condition.wait(until: Date().addingTimeInterval(0.25))
        }
    }

    /// Drop already-delivered bytes so only a `windowFloorBytes` re-read floor remains behind `readHead`.
    /// Caller holds the lock. Keeps `storageBase` and `storage` consistent (storage[0] == absolute storageBase).
    private func evictBelow(_ readHead: Int) {
        let keepFrom = max(storageBase, readHead - Self.windowFloorBytes)
        let dropCount = keepFrom - storageBase
        guard dropCount > 0, dropCount <= storage.count else { return }
        storage.removeFirst(dropCount)
        storageBase += dropCount
        // Resident bytes dropped: wake a producer parked on the high-water mark in `append`.
        condition.signal()
    }
}
