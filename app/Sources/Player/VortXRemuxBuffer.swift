import Foundation

/// A thread-safe, forward-only growing byte buffer for the DV-for-MKV streaming remux (Phase 1). The remux
/// thread (`VortXMKVRemuxStream`) appends muxed fragmented-MP4 bytes as they are produced; the local HLS
/// server (`VortXRemuxHLSServer`, the default delivery) reads closed-segment byte ranges out of it, and the
/// legacy progressive loader (`VortXRemuxResourceLoader`, the rollback path) reads it sequentially.
///
/// Design notes:
/// - APPEND-ONLY at the head, with ONE narrow exception. Bytes are almost always added only at the end, matching
///   a forward-only stream-copy remux that writes fMP4 fragments in order. The exception is `overwrite(at:)`: the
///   mov muxer (movenc) writes every box with a 32-bit size PLACEHOLDER and later seeks back to patch it once the
///   box length is known. When a box (chiefly the init `moov`) outgrows the muxer's AVIO buffer, that backpatch
///   cannot be done in the muxer's own unflushed buffer and must rewrite bytes already stored here. `overwrite`
///   patches those already-produced bytes in place; it never grows the stream and never advances `producedCount`.
///   It is only ever used to correct box-size fields the muxer already emitted, so a reader that has not yet been
///   handed those bytes (the init segment is not served until it is fully indexed) always sees the corrected value.
/// - BOUNDED SLIDING WINDOW at the tail. Both deliveries consume the stream front-to-back: the legacy loader
///   advertises NO byte-range access (`isByteRangeAccessSupported = false`) so AVPlayer streams strictly
///   sequentially from offset 0, and the HLS server only serves CLOSED segments of an append-only EVENT
///   playlist, so once a byte has been read it is essentially never re-requested. We therefore drop bytes that
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
    /// The retained tail of the produced stream. `storage[storage.startIndex]` corresponds to absolute offset
    /// `storageBase`. The index base is NOT always 0: `evictBelow`'s `Data.removeFirst` advances an internal
    /// start offset, so reads and eviction must work relative to `storage.startIndex`, never a bare 0.
    private var storage = Data()
    /// Absolute offset of the first byte still held in `storage`. Bytes below this have been delivered and evicted.
    private var storageBase = 0
    private var isFinished = false
    private var failureMessage: String?

    /// Total bytes produced so far across the whole session (monotonic; NOT storage.count once eviction starts).
    private(set) var producedCount: Int = 0

    /// Design minimum for the re-read window, in MiB: two full HLS segments' worth, i.e. 2 x
    /// VortXMKVRemuxStream.hlsMaxSegmentBytes (2 x 32 MiB = 64). Keep in lockstep with that constant. This is the
    /// worst-case concurrent two-segment read skew, so any floor below it can evict a range that is still being
    /// served on an open connection: the reader's next request then falls below `storageBase`, the HLS
    /// connection is cut, and AVPlayer demotes Dolby Vision to HDR10. The shipped RemoteConfig default
    /// (`dvRemuxWindowMiB` = 64) is exactly this value, so this constant is a fleet no-op today; it exists only
    /// so a pathological remote value can never starve the window below the two-segment minimum.
    private static let windowFloorMinMiB = 64

    /// The re-read floor (bytes): how many already-delivered bytes to keep behind the reader's low-water mark
    /// before evicting. Kept small (a fragment or two) so a benign re-read at the current position still
    /// succeeds while RAM stays flat. Captured ONCE at buffer creation, NOT read per fragment: reading it live
    /// took `RemoteConfig.snapshot`'s process-wide lock and copied the whole config struct on the DV hot path
    /// (append per fMP4 fragment, evict per read), contending with the RemoteConfig refresh writer. A mid-play
    /// fleet dial change only ever took effect on the NEXT playback anyway, so capturing at init changes nothing
    /// observable. Floored at the two-segment design minimum so a bad remote value can never degenerate the
    /// window.
    private let windowFloorBytes: Int = max(VortXRemuxBuffer.windowFloorMinMiB, RemoteConfig.snapshot.dvRemuxWindowMiB) * 1024 * 1024

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
        let ceiling = windowFloorBytes + Self.producerLeadBytes
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

    /// Patch `count` already-stored bytes at absolute `offset` in place (the muxer's box-size backpatch). Used
    /// ONLY by the remux thread's seekable custom AVIO: movenc seeks back to a box's start and rewrites its
    /// 32-bit size once the box length is known, which for a box larger than the muxer's AVIO buffer targets
    /// bytes that have already been flushed into `storage`. Returns true iff the WHOLE `[offset, offset+count)`
    /// range is still resident (at/above `storageBase`, at/below `producedCount`) and was patched; false if any
    /// of it was already evicted below the sliding window, in which case the caller drops the patch, which
    /// reproduces the pre-seek behaviour exactly (movenc ignored the failed seek and the bytes were never
    /// written). NEVER appends and NEVER changes `producedCount`: a backpatch only corrects bytes already
    /// produced. Nothing is served until the init segment is indexed, so every backpatch that matters (the moov
    /// and its children, all patched before the init is published) is still fully resident when it lands.
    func overwrite(at offset: Int, bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        guard count > 0 else { return true }
        condition.lock()
        defer { condition.unlock() }
        // Must lie fully within the resident, already-produced window. storage always spans exactly
        // [storageBase, producedCount) (eviction only drops BELOW storageBase, appends only grow the top), so
        // this bound alone guarantees the byte range is present.
        guard offset >= storageBase, offset + count <= producedCount else { return false }
        // `withUnsafeMutableBytes` exposes the LOGICAL content 0-based (it hides `storage.startIndex`), so the
        // byte at absolute `offset` maps to local index `offset - storageBase`, never a bare `startIndex` add.
        let local = offset - storageBase
        storage.withUnsafeMutableBytes { raw in
            // local + count <= raw.count is guaranteed by the bound above (raw.count == producedCount - storageBase).
            raw.baseAddress!.advanced(by: local).copyMemory(from: bytes, byteCount: count)
        }
        return true
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
        // F2: release the resident window (up to floor + producer lead, ~128 MiB) at the DEMOTE EDGE, not at
        // remux-thread exit. On a stalled-CDN demote the remux thread can linger 10-20s in a blocked read
        // while mpv re-opens the same 4K stream; freeing here returns that RAM to the shared jetsam budget
        // immediately so the two lanes never stack a second copy. Advancing storageBase to producedCount keeps
        // every read path consistent WITHOUT touching the freed bytes: read() checks failureMessage FIRST and
        // returns the failure before indexing storage, and any offset below the new storageBase also returns
        // the failure; append()/overwrite() are gated by isFinished / the [storageBase, producedCount) bound
        // and bail. producedCount is left intact so status()/snapshotPrefix() math stays correct. Idempotent:
        // a second fail() (e.g. cancel() after a real failure) just re-clears an already-empty buffer.
        storage = Data()
        storageBase = producedCount
        condition.broadcast()
        condition.unlock()
    }

    // MARK: Consumer side (resource loader queue)

    struct ReadResult {
        var data: Data          // bytes actually available for the requested range (may be shorter than asked)
        var atEnd: Bool         // true when no more bytes will ever arrive past data
        var failure: String?    // non-nil if the remux failed OR the range fell below the evicted window
    }

    /// Snapshot of stream state without blocking. Used by the HLS server's poll loops to detect a remux
    /// failure, and by the loader to answer a content-information request / decide whether a data request
    /// can be served immediately.
    func status() -> (produced: Int, finished: Bool, failure: String?) {
        condition.lock(); defer { condition.unlock() }
        return (producedCount, isFinished, failureMessage)
    }

    /// Copy the first `length` produced bytes, or nil if they are not (or no longer) fully resident from absolute
    /// offset 0. Used ONCE to publish the HLS init segment (ftyp+moov) after the muxer has backpatched the moov
    /// size: at that moment nothing has been served yet, so nothing below offset 0 has been evicted and the whole
    /// init (any size, no fixed-buffer ceiling) is guaranteed present. Non-blocking; the caller treats nil as a
    /// fail-soft abort of the init scan (the start-watchdog then demotes to libmpv like any other dead mount).
    func snapshotPrefix(length: Int) -> Data? {
        guard length > 0 else { return nil }
        condition.lock(); defer { condition.unlock() }
        guard storageBase == 0, producedCount >= length, storage.count >= length else { return nil }
        let lo = storage.startIndex
        return storage.subdata(in: lo..<(lo + length))
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
                // `storage` is indexed relative to its own `startIndex`, NOT 0. `evictBelow`'s
                // `Data.removeFirst` advances an internal start offset rather than memmoving, so after the
                // first eviction `storage.startIndex` is non-zero. Map the 0-based logical position onto the
                // real Data index base before slicing. (Slicing at a bare 0-based `localStart` is exactly what
                // trapped `subdata(in:)` out of bounds once eviction began.)
                let base = storage.startIndex
                let localStart = offset - storageBase
                let available = storage.count - localStart
                let take = min(length, available)
                let lo = base + localStart
                let hi = lo + take
                guard lo >= storage.startIndex, hi <= storage.endIndex, lo <= hi else {
                    // Unreachable given the window invariant, but fail soft (drives the AVPlayer -> libmpv
                    // fallback) instead of trapping and taking the whole app down, as the old code did.
                    return ReadResult(data: Data(), atEnd: true, failure: "remux buffer range out of bounds")
                }
                let slice = storage.subdata(in: lo..<hi)
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
        let keepFrom = max(storageBase, readHead - windowFloorBytes)
        let dropCount = keepFrom - storageBase
        guard dropCount > 0, dropCount <= storage.count else { return }
        storage.removeFirst(dropCount)
        storageBase += dropCount
        // `Data.removeFirst` advances an internal start offset instead of memmoving, so the evicted bytes
        // stay resident in the backing allocation and `storage.startIndex` climbs. Left unbounded that would
        // defeat the whole sliding window: RAM would grow with playback and jetsam the memory-constrained
        // Apple TV this class exists to protect. Once the reclaimable prefix reaches the floor, compact:
        // `subdata` copies the retained window into a fresh 0-based buffer and frees the old backing.
        // Amortized ~1x (one window-sized copy per window-sized advance) and it keeps `startIndex` bounded.
        if storage.startIndex >= windowFloorBytes {
            storage = storage.subdata(in: storage.startIndex..<storage.endIndex)
        }
        // Resident bytes dropped: wake a producer parked on the high-water mark in `append`.
        condition.signal()
    }
}
