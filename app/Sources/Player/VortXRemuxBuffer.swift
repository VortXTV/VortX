import Foundation

/// One published fMP4 media segment. `id` is absolute for the session and never changes when older bytes leave
/// the resident window. Keeping this outside the FFmpeg-owning stream lets the real storage/request contract run
/// in the standalone regression harness.
struct VortXHLSSegment: Equatable, Sendable {
    let id: Int
    let byteOffset: Int
    let byteLength: Int
    let start: Double
    let duration: Double

    init(id: Int, byteOffset: Int, byteLength: Int, start: Double = 0, duration: Double) {
        self.id = id
        self.byteOffset = byteOffset
        self.byteLength = byteLength
        self.start = start
        self.duration = duration
    }

    var end: Double { start + duration }
}

/// One immutable view of the media bytes the server can advertise right now. Video is the only Beta 7 consumer;
/// future subtitle renditions must consume this same absolute-id window rather than manufacturing array offsets.
struct VortXHLSWindow: Equatable, Sendable {
    let segments: [VortXHLSSegment]

    var mediaSequence: Int { segments.first?.id ?? 0 }

    func segment(id: Int) -> VortXHLSSegment? {
        segments.first { $0.id == id }
    }
}

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
///   sequentially from offset 0, and the HLS server only advertises CLOSED segments whose bytes remain in its
///   sliding resident window. Once bytes fall below the re-read floor, their segment URIs disappear before the
///   bytes are evicted. We therefore drop bytes that
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
    private var nextReadLeaseID = 0
    private var activeReadRanges: [Int: Range<Int>] = [:]

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
    private let windowFloorBytes: Int

    // --- F3 two-stage producer lead (ONE-LINE REVERT: delete `engineReady` + `markEngineReady` and set the
    // ceiling in `append` back to `windowFloorBytes + producerLeadFull`). The producer-lead budget is the slack
    // the remux thread may run ahead of the reader before `append` blocks; without it a stream-copy that muxes
    // as fast as the debrid link delivers races to the full remuxed size whenever AVPlayer throttles, jetsaming
    // the memory-constrained Apple TV. Resident RAM is bounded to (floor + lead). We run a REDUCED lead until
    // the engine reports first-frame readiness, so the pre-first-frame window cannot stack the full 64 MiB lead
    // into the shared jetsam budget at the exact moment mpv may be re-opening the same 4K stream on a demote;
    // once ready, the full lead restores steady-state headroom. The 16 MiB reduced lead is not itself the
    // operative bound against the 32 MiB open-segment cap: it is added on top of windowFloorBytes (at least
    // 64 MiB), so the pre-ready CEILING stays at least 80 MiB published, comfortably above the 32 MiB
    // open-segment cap plus init, and the publish pipeline cannot stall. ---
    private static let producerLeadPreReady = 16 * 1024 * 1024   // F3: reduced lead before first-frame readiness
    private static let producerLeadFull      = 64 * 1024 * 1024   // F3: full lead once the engine is ready
    /// Set once via `markEngineReady()` when AVPlayerEngine reports readyToPlay/first frame; guarded by
    /// `condition`. Selects the producer lead in `append` (reduced before, full after).
    private var engineReady = false

    /// Bytes currently held in `storage` (delivered floor plus producer lead). Caller holds the lock.
    private var residentCount: Int { storage.count }

    /// Production uses the fleet-clamped MiB floor. The explicit byte floor exists so the production buffer's
    /// eviction contract can be executed quickly by the standalone regression harness.
    init(windowFloorBytes: Int? = nil) {
        self.windowFloorBytes = max(1, windowFloorBytes
            ?? max(Self.windowFloorMinMiB, RemoteConfig.snapshot.dvRemuxWindowMiB) * 1024 * 1024)
    }

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
        // F3 two-stage lead: reduced until the engine reports readiness, then full.
        let ceiling = windowFloorBytes + (engineReady ? Self.producerLeadFull : Self.producerLeadPreReady)
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

    /// Nonblocking append for an OPTIONAL producer that must never stall the primary remux thread. The caller
    /// supplies its own finite resident cap; crossing it returns false without appending or changing buffer
    /// status, so that caller can fail and tear down only its optional lane. The primary `append` path above is
    /// deliberately unchanged and retains its existing backpressure contract.
    func appendIfWithinResidentLimit(_ bytes: UnsafePointer<UInt8>, count: Int, limit: Int) -> Bool {
        guard count > 0 else { return true }
        condition.lock()
        defer { condition.unlock() }
        guard !isFinished,
              limit >= 0,
              residentCount <= limit,
              count <= limit - residentCount else { return false }
        storage.append(bytes, count: count)
        producedCount += count
        condition.signal()
        return true
    }

    /// Advance an explicit retention floor without reading or copying the discarded payload. This is used by
    /// optional renditions whose bytes may never be requested: their floor follows the first absolute segment
    /// still resident in the primary window, while retaining the documented re-read floor behind it. Active
    /// response leases clamp the trim further so a playlist reload cannot evict bytes beneath an open segment
    /// response. The offset must identify an already-produced resident byte.
    @discardableResult
    func discardPrefix(before absoluteOffset: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard absoluteOffset >= storageBase, absoluteOffset <= producedCount else { return false }
        let floorStart = absoluteOffset > windowFloorBytes
            ? absoluteOffset - windowFloorBytes : storageBase
        discardPrefixLocked(before: max(storageBase, floorStart))
        return true
    }

    /// Drop a prefix whose replacement backing has already committed to the session spool. Unlike the normal
    /// reader-driven trim, this does not retain the in-memory re-read floor: durable request leases now own that
    /// responsibility. Active buffer leases still clamp the drop, so an overlapping staging/read operation can
    /// never lose bytes beneath itself.
    @discardableResult
    func discardDurablyBackedPrefix(before absoluteOffset: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard absoluteOffset >= storageBase, absoluteOffset <= producedCount else { return false }
        discardPrefixLocked(before: absoluteOffset)
        return true
    }

    /// F3: mark that the playback engine has reached first-frame readiness, so `append` switches from the
    /// reduced pre-ready producer lead to the full lead. Thread-safe; called from the AVPlayerEngine readyToPlay
    /// path via the remux server/loader. Signals so a producer parked on the lower ceiling wakes and may run on.
    func markEngineReady() {
        condition.lock()
        if !engineReady {
            engineReady = true
            condition.signal()
        }
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

    /// Lifetime token for one advertised resource response. The buffer stores only the protected range, not
    /// the token, so dropping the final reference on completion, cancellation or error deterministically
    /// releases the lease without a buffer/token retain cycle.
    final class ReadLease: @unchecked Sendable {
        private weak var owner: VortXRemuxBuffer?
        private let id: Int

        fileprivate init(owner: VortXRemuxBuffer, id: Int) {
            self.owner = owner
            self.id = id
        }

        deinit { owner?.releaseReadLease(id: id) }
    }

    /// Protect a complete resident resource before its first byte is read. nil means the range is malformed or
    /// no longer wholly resident, so the server can return a clean 404 before committing response headers.
    func beginReadLease(offset: Int, length: Int) -> ReadLease? {
        guard offset >= 0, length > 0 else { return nil }
        let (end, overflow) = offset.addingReportingOverflow(length)
        guard !overflow else { return nil }
        condition.lock()
        guard offset >= storageBase, end <= producedCount else {
            condition.unlock()
            return nil
        }
        let id = nextReadLeaseID
        nextReadLeaseID &+= 1
        activeReadRanges[id] = offset..<end
        condition.unlock()
        return ReadLease(owner: self, id: id)
    }

    private func releaseReadLease(id: Int) {
        condition.lock()
        activeReadRanges.removeValue(forKey: id)
        condition.signal()
        condition.unlock()
    }

    /// Snapshot of stream state without blocking. Used by the HLS server's poll loops to detect a remux
    /// failure, and by the loader to answer a content-information request / decide whether a data request
    /// can be served immediately.
    func status() -> (produced: Int, finished: Bool, failure: String?) {
        condition.lock(); defer { condition.unlock() }
        return (producedCount, isFinished, failureMessage)
    }

    /// Absolute byte interval resident at this instant. Used for diagnostics and the executable window contract.
    var residentByteRange: Range<Int> {
        condition.lock(); defer { condition.unlock() }
        return storageBase..<producedCount
    }

    /// Freeze the published segment list to ranges wholly resident in this buffer. A segment is either present in
    /// full or omitted; partial ranges can never leak into a playlist. The returned ids remain absolute, so removing
    /// a prefix advances MEDIA-SEQUENCE without renumbering requests.
    func residentWindow(segments: [VortXHLSSegment]) -> VortXHLSWindow {
        condition.lock(); defer { condition.unlock() }
        let resident = storageBase..<producedCount
        let readable = segments.filter { segment in
            guard segment.byteOffset >= resident.lowerBound, segment.byteLength > 0 else { return false }
            let (end, overflow) = segment.byteOffset.addingReportingOverflow(segment.byteLength)
            return !overflow && end <= resident.upperBound
        }
        return VortXHLSWindow(segments: readable)
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

    /// Copy one bounded, already-produced resident chunk without advancing the reader or eviction floor. A
    /// multi-chunk caller must hold `beginReadLease` for the complete source range until its final chunk has
    /// been durably consumed, otherwise another reader could evict the range between snapshots.
    func snapshotChunk(offset: Int, length: Int) -> Data? {
        guard offset >= 0, length > 0 else { return nil }
        let (end, overflow) = offset.addingReportingOverflow(length)
        guard !overflow else { return nil }
        condition.lock(); defer { condition.unlock() }
        guard offset >= storageBase, end <= producedCount else { return nil }
        let local = offset - storageBase
        let lower = storage.startIndex + local
        let upper = lower + length
        guard lower >= storage.startIndex, upper <= storage.endIndex else { return nil }
        return storage.subdata(in: lower..<upper)
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
        // The two startup playlists and their first segment fetches race one another. Until AVPlayer reports
        // readyToPlay, retain the initial bytes so every URI in that first immutable window remains readable.
        guard engineReady else { return }
        let keepFrom = max(storageBase, readHead - windowFloorBytes)
        discardPrefixLocked(before: keepFrom)
    }

    /// Caller holds `condition`. `Data.removeFirst` advances the logical start without copying on the normal
    /// trim path; occasional compaction releases the old backing allocation after one full floor has moved.
    private func discardPrefixLocked(before keepFrom: Int) {
        let leasedFloor = activeReadRanges.values.map(\.lowerBound).min()
        let protectedKeepFrom = min(keepFrom, leasedFloor ?? keepFrom)
        let dropCount = protectedKeepFrom - storageBase
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

/// Session-global durable backing for closed HLS media. A process launch owns one UUID directory and each
/// playback owns one child UUID directory, so stale prior-launch roots can be scavenged once without touching a
/// live sibling. The 512 MiB production ceiling is admission only: protected resources are never evicted to make
/// room. Playlist deadlines and open-handle leases decide when an individual resource may be reclaimed.
final class VortXHLSSessionSpool: @unchecked Sendable {

    static let defaultCapacityBytes = 512 * 1024 * 1024
    static let defaultChunkBytes = 512 * 1024

    enum ResourceKey: Hashable, Sendable {
        case video(segmentID: Int)
        case audio(renditionID: Int, segmentID: Int)
        case subtitle(renditionID: Int, segmentID: Int)

        fileprivate var fileName: String {
            switch self {
            case .video(let segmentID):
                return "video-\(segmentID).m4s"
            case .audio(let renditionID, let segmentID):
                return "audio-\(renditionID)-\(segmentID).m4s"
            case .subtitle(let renditionID, let segmentID):
                return "subtitle-\(renditionID)-\(segmentID).vtt"
            }
        }
    }

    struct SpillResource: @unchecked Sendable {
        fileprivate enum Payload: @unchecked Sendable {
            case buffer(VortXRemuxBuffer, offset: Int, length: Int)
            case data(Data)
        }

        let key: ResourceKey
        let durationMilliseconds: Int
        fileprivate let payload: Payload

        fileprivate var length: Int {
            switch payload {
            case .buffer(_, _, let length): return length
            case .data(let data): return data.count
            }
        }

        init(key: ResourceKey, buffer: VortXRemuxBuffer,
             offset: Int, length: Int, durationMilliseconds: Int) {
            self.key = key
            self.durationMilliseconds = durationMilliseconds
            self.payload = .buffer(buffer, offset: offset, length: length)
        }

        init(key: ResourceKey, data: Data, durationMilliseconds: Int) {
            self.key = key
            self.durationMilliseconds = durationMilliseconds
            self.payload = .data(data)
        }
    }

    enum FailureInjection: Equatable, Sendable {
        case write(afterBytes: Int)
        case diskFull(afterBytes: Int)
        case rename(afterSuccessfulMoves: Int)
        case sizeMismatch
    }

    struct Accounting: Equatable, Sendable {
        fileprivate(set) var finalBytes = 0
        fileprivate(set) var temporaryBytes = 0
        fileprivate(set) var reservedBytes = 0
        fileprivate(set) var auxiliaryBytes = 0
        fileprivate(set) var peakTemporaryBytes = 0
        fileprivate(set) var peakReservedBytes = 0
        fileprivate(set) var peakChunkBytes = 0

        /// Temporary bytes are a materialized subset of their reservation, so counting both would double-charge
        /// one write. Admission is committed final + non-file auxiliary + the full outstanding reservation.
        var admittedBytes: Int { finalBytes + auxiliaryBytes + reservedBytes }
    }

    struct PlaylistGeneration: Equatable, Sendable {
        let playlistID: String
        let generation: Int
        let resourceKeys: [ResourceKey]
        let renderedDurationMilliseconds: Int
        let distributedAt: TimeInterval
    }

    final class ResourceLease: @unchecked Sendable {
        let length: Int
        private weak var owner: VortXHLSSessionSpool?
        private let key: ResourceKey
        private let handle: FileHandle
        private let lock = NSLock()
        private var closed = false
        private var remaining: Int

        fileprivate init(owner: VortXHLSSessionSpool, key: ResourceKey,
                         handle: FileHandle, length: Int) {
            self.owner = owner
            self.key = key
            self.handle = handle
            self.length = length
            self.remaining = length
        }

        func read(maxLength: Int) throws -> Data {
            guard maxLength > 0 else { return Data() }
            lock.lock(); defer { lock.unlock() }
            guard !closed, remaining > 0 else { return Data() }
            let amount = min(maxLength, remaining)
            let data = try handle.read(upToCount: amount) ?? Data()
            guard data.count <= remaining else { throw SpoolError.invalidRead }
            remaining -= data.count
            return data
        }

        func close(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            lock.lock()
            guard !closed else { lock.unlock(); return }
            closed = true
            lock.unlock()
            try? handle.close()
            owner?.releaseResourceLease(key: key, now: now)
        }

        deinit { close() }
    }

    private enum SpoolError: Error {
        case invalidSource
        case injectedWrite
        case injectedDiskFull
        case injectedRename
        case invalidRead
        case invalidLength
    }

    private struct Entry {
        let url: URL
        let length: Int
        let segmentDurationMilliseconds: Int
        var containingPlaylists: Set<String> = []
        var longestPlaylistDurationMilliseconds = 0
        var retentionDeadline: TimeInterval?
        var leaseCount = 0
    }

    private struct PlaylistState {
        var generation = 0
        var currentKeys: Set<ResourceKey> = []
    }

    private final class LaunchRegistry: @unchecked Sendable {
        private struct Launch {
            let directory: URL
            var sessions: Set<String>
            var didScavenge: Bool
        }

        private let lock = NSLock()
        private var launches: [String: Launch] = [:]

        func join(parent: URL, sessionName: String,
                  requestScavenge: Bool) -> (launch: URL, shouldScavenge: Bool) {
            let parentKey = parent.standardizedFileURL.path
            lock.lock(); defer { lock.unlock() }
            var launch = launches[parentKey] ?? Launch(
                directory: parent.appendingPathComponent("launch-\(UUID().uuidString)", isDirectory: true),
                sessions: [],
                didScavenge: false)
            launch.sessions.insert(sessionName)
            let shouldScavenge = requestScavenge && !launch.didScavenge
            if shouldScavenge { launch.didScavenge = true }
            launches[parentKey] = launch
            return (launch.directory, shouldScavenge)
        }

        func leave(parent: URL, sessionName: String) {
            let parentKey = parent.standardizedFileURL.path
            lock.lock(); defer { lock.unlock() }
            guard var launch = launches[parentKey] else { return }
            launch.sessions.remove(sessionName)
            launches[parentKey] = launch
        }
    }

    private static let launchRegistry = LaunchRegistry()

    let sessionDirectory: URL
    private let parentDirectory: URL
    private let sessionName: String
    private let capacityBytes: Int
    private let chunkSize: Int
    private let failureInjection: FailureInjection?
    private let lock = NSLock()
    private var entries: [ResourceKey: Entry] = [:]
    private var pendingKeys: Set<ResourceKey> = []
    private var reservations: [UUID: Int] = [:]
    private var playlists: [String: PlaylistState] = [:]
    private var currentAccounting = Accounting()
    private var totalActiveLeases = 0
    private var invalidated = false
    private var listenerRetired = false
    private var producerEnded = false
    private var cleanupClaimed = false
    private var registryJoined = true
    private var fileOperationProbe: ((VortXHLSSessionSpool) -> Void)?

    init?(parentDirectory: URL,
          sessionID: UUID = UUID(),
          capacityBytes: Int = VortXHLSSessionSpool.defaultCapacityBytes,
          chunkSize: Int = VortXHLSSessionSpool.defaultChunkBytes,
          failureInjection: FailureInjection? = nil,
          scavengeStaleSessions: Bool = true) {
        guard capacityBytes > 0, chunkSize > 0 else { return nil }
        self.parentDirectory = parentDirectory
        self.capacityBytes = capacityBytes
        self.chunkSize = chunkSize
        self.failureInjection = failureInjection
        self.sessionName = "session-\(sessionID.uuidString)"
        let joined = Self.launchRegistry.join(
            parent: parentDirectory,
            sessionName: self.sessionName,
            requestScavenge: scavengeStaleSessions)
        self.sessionDirectory = joined.launch.appendingPathComponent(self.sessionName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: sessionDirectory, withIntermediateDirectories: true)
        } catch {
            Self.launchRegistry.leave(parent: parentDirectory, sessionName: self.sessionName)
            registryJoined = false
            return nil
        }
        if joined.shouldScavenge {
            Self.scavengePriorLaunches(parent: parentDirectory, keeping: joined.launch)
        }
    }

    static func makeDefault() -> VortXHLSSessionSpool? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return VortXHLSSessionSpool(
            parentDirectory: caches.appendingPathComponent("VortXHLS", isDirectory: true))
    }

    deinit {
        if registryJoined {
            Self.launchRegistry.leave(parent: parentDirectory, sessionName: sessionName)
        }
    }

    var accounting: Accounting {
        lock.lock(); defer { lock.unlock() }
        return currentAccounting
    }

    var activeLeaseCount: Int {
        lock.lock(); defer { lock.unlock() }
        return totalActiveLeases
    }

    var fileNamesOnDisk: [String] {
        (try? FileManager.default.contentsOfDirectory(
            at: sessionDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]).map(\.lastPathComponent).sorted()) ?? []
    }

    func contains(_ key: ResourceKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[key] != nil
    }

    func retentionDeadline(for key: ResourceKey) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return entries[key]?.retentionDeadline
    }

    func playlistGenerationCount(playlistID: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return playlists[playlistID]?.generation ?? 0
    }

    /// Test seam proving filesystem work never runs while the session-state lock is held. The callback is
    /// copied under the lock and invoked only after unlock, so it may safely re-enter coordinator reads.
    func installFileOperationProbe(_ probe: @escaping (VortXHLSSessionSpool) -> Void) {
        lock.lock()
        fileOperationProbe = probe
        lock.unlock()
    }

    /// Reserve the whole cohort before any file exists, lease every buffer source range, stream bounded chunks
    /// into `.part`, verify exact sizes, rename every member, then register the cohort together. Filesystem work
    /// runs outside the coordinator and buffer locks; registration is the only visibility edge.
    func spill(_ resources: [SpillResource]) -> Bool {
        guard validate(resources: resources) != nil else { return false }

        // A closed segment can legitimately be shared by multiple variant playlists. Treat the same key,
        // duration and bytes as an idempotent publication, but reject a conflicting reuse of an absolute key.
        var resourcesToStage: [SpillResource] = []
        for resource in resources {
            switch existingMetadata(for: resource.key) {
            case .none:
                resourcesToStage.append(resource)
            case .some(let metadata):
                guard metadata.length == resource.length,
                      metadata.durationMilliseconds == resource.durationMilliseconds,
                      let lease = openResource(resource.key, now: 0) else { return false }
                let matches = payload(resource, exactlyMatches: lease)
                lease.close(now: 0)
                guard matches else { return false }
            }
        }
        guard !resourcesToStage.isEmpty else { return true }
        guard let total = validate(resources: resourcesToStage) else { return false }
        let reservationID = UUID()
        guard reserve(id: reservationID, resources: resourcesToStage, bytes: total) else { return false }

        var sourceLeases: [VortXRemuxBuffer.ReadLease] = []
        for resource in resourcesToStage {
            if case .buffer(let buffer, let offset, let length) = resource.payload {
                guard let lease = buffer.beginReadLease(offset: offset, length: length) else {
                    releaseReservation(
                        id: reservationID,
                        keys: resourcesToStage.map(\.key),
                        temporaryBytes: 0)
                    return false
                }
                sourceLeases.append(lease)
            }
        }

        struct Staged {
            let resource: SpillResource
            let partURL: URL
            let finalURL: URL
        }
        let operationID = UUID().uuidString
        let staged = resourcesToStage.map { resource in
            let final = sessionDirectory.appendingPathComponent(resource.key.fileName)
            return Staged(
                resource: resource,
                partURL: sessionDirectory.appendingPathComponent(
                    "\(resource.key.fileName).\(operationID).part"),
                finalURL: final)
        }
        var materializedBytes = 0
        var successfulMoves = 0
        do {
            for item in staged {
                notifyFileOperation()
                guard FileManager.default.createFile(atPath: item.partURL.path, contents: nil) else {
                    throw SpoolError.invalidSource
                }
                notifyFileOperation()
                let handle = try FileHandle(forWritingTo: item.partURL)
                do {
                    var localOffset = 0
                    while localOffset < item.resource.length {
                        let count = min(chunkSize, item.resource.length - localOffset)
                        guard let chunk = chunk(
                            for: item.resource, localOffset: localOffset, length: count) else {
                            throw SpoolError.invalidSource
                        }
                        notifyFileOperation()
                        let written = try writeWithInjectedFailure(
                            chunk, to: handle, operationBytes: materializedBytes)
                        materializedBytes += written
                        noteTemporaryWrite(written, chunkBytes: chunk.count)
                        if written != chunk.count {
                            switch failureInjection {
                            case .diskFull: throw SpoolError.injectedDiskFull
                            default: throw SpoolError.injectedWrite
                            }
                        }
                        localOffset += written
                    }
                    try handle.synchronize()
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
                if failureInjection == .sizeMismatch {
                    notifyFileOperation()
                    let mismatchHandle = try FileHandle(forWritingTo: item.partURL)
                    try mismatchHandle.truncate(atOffset: UInt64(item.resource.length - 1))
                    try mismatchHandle.close()
                }
                notifyFileOperation()
                let values = try item.partURL.resourceValues(forKeys: [.fileSizeKey])
                guard values.fileSize == item.resource.length else { throw SpoolError.invalidLength }
            }
            for item in staged {
                if case .rename(let allowedMoves) = failureInjection,
                   successfulMoves >= max(0, allowedMoves) {
                    throw SpoolError.injectedRename
                }
                guard !FileManager.default.fileExists(atPath: item.finalURL.path) else {
                    throw SpoolError.injectedRename
                }
                notifyFileOperation()
                try FileManager.default.moveItem(at: item.partURL, to: item.finalURL)
                successfulMoves += 1
            }
            guard commit(
                id: reservationID,
                resources: staged.map { ($0.resource, $0.finalURL) },
                bytes: total,
                temporaryBytes: materializedBytes) else {
                throw SpoolError.invalidSource
            }
            withExtendedLifetime(sourceLeases) {}
            return true
        } catch {
            for item in staged {
                notifyFileOperation()
                try? FileManager.default.removeItem(at: item.partURL)
                notifyFileOperation()
                try? FileManager.default.removeItem(at: item.finalURL)
            }
            releaseReservation(
                id: reservationID,
                keys: resourcesToStage.map(\.key),
                temporaryBytes: materializedBytes)
            withExtendedLifetime(sourceLeases) {}
            return false
        }
    }

    /// Non-file resident state (currently subtitle cue storage) participates in the same admission ceiling.
    @discardableResult
    func setAuxiliaryBytes(_ bytes: Int) -> Bool {
        guard bytes >= 0 else { return false }
        lock.lock(); defer { lock.unlock() }
        guard !invalidated else { return false }
        let withoutOld = currentAccounting.admittedBytes - currentAccounting.auxiliaryBytes
        guard withoutOld <= capacityBytes, bytes <= capacityBytes - withoutOld else { return false }
        currentAccounting.auxiliaryBytes = bytes
        return true
    }

    @discardableResult
    func recordPlaylistGeneration(playlistID: String,
                                  resourceKeys: [ResourceKey],
                                  now: TimeInterval) -> PlaylistGeneration? {
        guard !playlistID.isEmpty, now.isFinite, now >= 0,
              Set(resourceKeys).count == resourceKeys.count else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard !invalidated else { return nil }
        var duration = 0
        for key in resourceKeys {
            guard let entry = entries[key] else { return nil }
            let (sum, overflow) = duration.addingReportingOverflow(entry.segmentDurationMilliseconds)
            guard !overflow else { return nil }
            duration = sum
        }
        var state = playlists[playlistID] ?? PlaylistState()
        let nextKeys = Set(resourceKeys)
        let removed = state.currentKeys.subtracting(nextKeys)
        let (nextGeneration, generationOverflow) = state.generation.addingReportingOverflow(1)
        guard !generationOverflow else { return nil }
        state.generation = nextGeneration
        state.currentKeys = nextKeys

        var updatedEntries = entries
        for key in nextKeys {
            guard var entry = updatedEntries[key] else { continue }
            entry.containingPlaylists.insert(playlistID)
            entry.longestPlaylistDurationMilliseconds = max(
                entry.longestPlaylistDurationMilliseconds, duration)
            entry.retentionDeadline = nil
            updatedEntries[key] = entry
        }
        for key in removed {
            guard var entry = updatedEntries[key] else { continue }
            entry.containingPlaylists.remove(playlistID)
            if entry.containingPlaylists.isEmpty {
                let (milliseconds, overflow) = entry.segmentDurationMilliseconds
                    .addingReportingOverflow(entry.longestPlaylistDurationMilliseconds)
                guard !overflow else { return nil }
                let interval = Double(milliseconds) / 1_000
                let deadline = now + interval
                guard interval.isFinite, deadline.isFinite else { return nil }
                entry.retentionDeadline = deadline
            }
            updatedEntries[key] = entry
        }
        entries = updatedEntries
        playlists[playlistID] = state
        let receipt = PlaylistGeneration(
            playlistID: playlistID,
            generation: state.generation,
            resourceKeys: resourceKeys,
            renderedDurationMilliseconds: duration,
            distributedAt: now)
        return receipt
    }

    /// Claim the resource under the coordinator, then open its handle outside that lock. The claim pins the
    /// file against expiry while the potentially blocking open runs; nil is returned before a caller can send 200.
    func openResource(_ key: ResourceKey, now: TimeInterval) -> ResourceLease? {
        guard now.isFinite, now >= 0 else { return nil }
        var url: URL?
        var length = 0
        var expiredURL: URL?
        lock.lock()
        if !invalidated, var entry = entries[key] {
            if let deadline = entry.retentionDeadline, now > deadline {
                if entry.leaseCount == 0, entry.containingPlaylists.isEmpty {
                    entries.removeValue(forKey: key)
                    currentAccounting.finalBytes -= entry.length
                    expiredURL = entry.url
                }
            } else {
                entry.leaseCount += 1
                totalActiveLeases += 1
                entries[key] = entry
                url = entry.url
                length = entry.length
            }
        }
        lock.unlock()
        if let expiredURL { try? FileManager.default.removeItem(at: expiredURL) }
        guard let url else { return nil }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            return ResourceLease(owner: self, key: key, handle: handle, length: length)
        } catch {
            releaseResourceLease(key: key, now: now)
            return nil
        }
    }

    func collectExpired(now: TimeInterval) {
        guard now.isFinite, now >= 0 else { return }
        var urls: [URL] = []
        lock.lock()
        for (key, entry) in entries {
            if let deadline = entry.retentionDeadline,
               now > deadline,
               entry.leaseCount == 0,
               entry.containingPlaylists.isEmpty {
                entries.removeValue(forKey: key)
                currentAccounting.finalBytes -= entry.length
                urls.append(entry.url)
            }
        }
        lock.unlock()
        urls.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    func producerDidReachEOF() {
        lock.lock(); producerEnded = true; lock.unlock()
    }

    func invalidateSession() {
        let cleanup: URL?
        lock.lock()
        invalidated = true
        cleanup = claimCleanupIfReadyLocked()
        lock.unlock()
        if let cleanup { performCleanup(cleanup) }
    }

    func listenerDidRetire() {
        let cleanup: URL?
        lock.lock()
        listenerRetired = true
        cleanup = claimCleanupIfReadyLocked()
        lock.unlock()
        if let cleanup { performCleanup(cleanup) }
    }

    private func validate(resources: [SpillResource]) -> Int? {
        guard !resources.isEmpty, Set(resources.map(\.key)).count == resources.count else { return nil }
        var total = 0
        for resource in resources {
            guard resource.length > 0, resource.durationMilliseconds > 0 else { return nil }
            switch resource.payload {
            case .buffer(_, let offset, let length):
                guard offset >= 0, length > 0 else { return nil }
                let (_, overflow) = offset.addingReportingOverflow(length)
                guard !overflow else { return nil }
            case .data:
                break
            }
            let (sum, overflow) = total.addingReportingOverflow(resource.length)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    private func existingMetadata(for key: ResourceKey)
        -> (length: Int, durationMilliseconds: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated, !pendingKeys.contains(key), let entry = entries[key] else { return nil }
        return (entry.length, entry.segmentDurationMilliseconds)
    }

    /// Compare a duplicate publication against its durable backing without materializing the full payload.
    /// The complete source range and destination file both stay leased for the bounded comparison.
    private func payload(_ resource: SpillResource, exactlyMatches lease: ResourceLease) -> Bool {
        guard lease.length == resource.length else { return false }
        var sourceLease: VortXRemuxBuffer.ReadLease?
        if case .buffer(let buffer, let offset, let length) = resource.payload {
            guard let held = buffer.beginReadLease(offset: offset, length: length) else { return false }
            sourceLease = held
        }
        defer { withExtendedLifetime(sourceLease) {} }
        var localOffset = 0
        do {
            while localOffset < resource.length {
                let count = min(chunkSize, resource.length - localOffset)
                guard let proposed = chunk(
                    for: resource, localOffset: localOffset, length: count) else { return false }
                notifyFileOperation()
                let existing = try lease.read(maxLength: count)
                guard existing.count == count, existing == proposed else { return false }
                localOffset += count
            }
            return true
        } catch {
            return false
        }
    }

    private func notifyFileOperation() {
        let probe: ((VortXHLSSessionSpool) -> Void)?
        lock.lock()
        probe = fileOperationProbe
        lock.unlock()
        probe?(self)
    }

    private func reserve(id: UUID, resources: [SpillResource], bytes: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let keys = Set(resources.map(\.key))
        guard !invalidated,
              keys.isDisjoint(with: pendingKeys),
              keys.allSatisfy({ entries[$0] == nil }),
              currentAccounting.admittedBytes <= capacityBytes,
              bytes <= capacityBytes - currentAccounting.admittedBytes else { return false }
        reservations[id] = bytes
        pendingKeys.formUnion(keys)
        currentAccounting.reservedBytes += bytes
        currentAccounting.peakReservedBytes = max(
            currentAccounting.peakReservedBytes, currentAccounting.reservedBytes)
        return true
    }

    private func chunk(for resource: SpillResource, localOffset: Int, length: Int) -> Data? {
        switch resource.payload {
        case .buffer(let buffer, let offset, _):
            let (absolute, overflow) = offset.addingReportingOverflow(localOffset)
            guard !overflow else { return nil }
            return buffer.snapshotChunk(offset: absolute, length: length)
        case .data(let data):
            guard localOffset >= 0, length > 0,
                  localOffset <= data.count, length <= data.count - localOffset else { return nil }
            return data.subdata(in: localOffset..<(localOffset + length))
        }
    }

    private func writeWithInjectedFailure(_ data: Data, to handle: FileHandle,
                                          operationBytes: Int) throws -> Int {
        let limit: Int?
        switch failureInjection {
        case .write(let afterBytes), .diskFull(let afterBytes): limit = max(0, afterBytes)
        default: limit = nil
        }
        guard let limit else {
            try handle.write(contentsOf: data)
            return data.count
        }
        let allowed = max(0, limit - operationBytes)
        let amount = min(allowed, data.count)
        if amount > 0 { try handle.write(contentsOf: data.prefix(amount)) }
        return amount
    }

    private func noteTemporaryWrite(_ bytes: Int, chunkBytes: Int) {
        lock.lock()
        currentAccounting.temporaryBytes += bytes
        currentAccounting.peakTemporaryBytes = max(
            currentAccounting.peakTemporaryBytes, currentAccounting.temporaryBytes)
        currentAccounting.peakChunkBytes = max(currentAccounting.peakChunkBytes, chunkBytes)
        lock.unlock()
    }

    private func commit(id: UUID,
                        resources: [(SpillResource, URL)],
                        bytes: Int,
                        temporaryBytes: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated, reservations[id] == bytes,
              resources.allSatisfy({ entries[$0.0.key] == nil }) else { return false }
        for (resource, url) in resources {
            entries[resource.key] = Entry(
                url: url,
                length: resource.length,
                segmentDurationMilliseconds: resource.durationMilliseconds)
        }
        reservations.removeValue(forKey: id)
        pendingKeys.subtract(resources.map { $0.0.key })
        currentAccounting.reservedBytes -= bytes
        currentAccounting.temporaryBytes -= temporaryBytes
        currentAccounting.finalBytes += bytes
        return true
    }

    private func releaseReservation(id: UUID, keys: [ResourceKey], temporaryBytes: Int) {
        let cleanup: URL?
        lock.lock()
        if let bytes = reservations.removeValue(forKey: id) {
            currentAccounting.reservedBytes -= bytes
        }
        pendingKeys.subtract(keys)
        currentAccounting.temporaryBytes = max(
            0, currentAccounting.temporaryBytes - temporaryBytes)
        cleanup = claimCleanupIfReadyLocked()
        lock.unlock()
        if let cleanup { performCleanup(cleanup) }
    }

    private func releaseResourceLease(key: ResourceKey, now: TimeInterval) {
        var expiredURL: URL?
        let cleanup: URL?
        lock.lock()
        if var entry = entries[key], entry.leaseCount > 0 {
            entry.leaseCount -= 1
            totalActiveLeases -= 1
            if let deadline = entry.retentionDeadline,
               now > deadline,
               entry.leaseCount == 0,
               entry.containingPlaylists.isEmpty {
                entries.removeValue(forKey: key)
                currentAccounting.finalBytes -= entry.length
                expiredURL = entry.url
            } else {
                entries[key] = entry
            }
        }
        cleanup = claimCleanupIfReadyLocked()
        lock.unlock()
        if let expiredURL { try? FileManager.default.removeItem(at: expiredURL) }
        if let cleanup { performCleanup(cleanup) }
    }

    private func claimCleanupIfReadyLocked() -> URL? {
        guard invalidated, listenerRetired, totalActiveLeases == 0,
              reservations.isEmpty, !cleanupClaimed else { return nil }
        cleanupClaimed = true
        return sessionDirectory
    }

    private func performCleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
        lock.lock()
        let shouldLeave = registryJoined
        registryJoined = false
        lock.unlock()
        if shouldLeave {
            Self.launchRegistry.leave(parent: parentDirectory, sessionName: sessionName)
        }
    }

    private static func scavengePriorLaunches(parent: URL, keeping launch: URL) {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let keepPath = launch.standardizedFileURL.path
        for child in children where child.standardizedFileURL.path != keepPath {
            try? FileManager.default.removeItem(at: child)
        }
    }
}

/// Bounded, callback-driven response pump over one already-open spool lease. The handle is acquired before this
/// object exists and remains owned until the first terminal edge, so no expiry or teardown can undercut a 200.
final class VortXSpoolResponsePump: @unchecked Sendable {
    enum Terminal: Equatable, Sendable {
        case complete
        case cancelled
        case sendError
        case readError
    }

    typealias Send = (Data, @escaping (Bool) -> Void) -> Void

    private let lease: VortXHLSSessionSpool.ResourceLease
    private let chunkSize: Int
    private var firstChunk: Data?
    private var remaining: Int
    private var started = false
    private var terminated = false

    init?(lease: VortXHLSSessionSpool.ResourceLease, chunkSize: Int) {
        guard chunkSize > 0 else { return nil }
        do {
            let first = try lease.read(maxLength: min(chunkSize, lease.length))
            guard !first.isEmpty else { lease.close(); return nil }
            self.lease = lease
            self.chunkSize = chunkSize
            self.firstChunk = first
            self.remaining = lease.length - first.count
        } catch {
            lease.close()
            return nil
        }
    }

    func start(header: Data,
               cancelled: @escaping () -> Bool,
               send: @escaping Send,
               terminal: @escaping (Terminal) -> Void) {
        guard !started, !terminated else { return }
        started = true
        guard !cancelled() else { finish(.cancelled, terminal: terminal); return }
        send(header) { [self] succeeded in
            guard succeeded else { finish(.sendError, terminal: terminal); return }
            sendNext(cancelled: cancelled, send: send, terminal: terminal)
        }
    }

    private func sendNext(cancelled: @escaping () -> Bool,
                          send: @escaping Send,
                          terminal: @escaping (Terminal) -> Void) {
        guard !terminated else { return }
        guard !cancelled() else { finish(.cancelled, terminal: terminal); return }
        let data: Data
        if let firstChunk {
            data = firstChunk
            self.firstChunk = nil
        } else if remaining > 0 {
            do {
                data = try lease.read(maxLength: min(chunkSize, remaining))
            } catch {
                finish(.readError, terminal: terminal)
                return
            }
            guard !data.isEmpty else { finish(.readError, terminal: terminal); return }
            remaining -= data.count
        } else {
            finish(.complete, terminal: terminal)
            return
        }
        send(data) { [self] succeeded in
            guard succeeded else { finish(.sendError, terminal: terminal); return }
            sendNext(cancelled: cancelled, send: send, terminal: terminal)
        }
    }

    private func finish(_ outcome: Terminal, terminal: (Terminal) -> Void) {
        guard !terminated else { return }
        terminated = true
        firstChunk = nil
        lease.close()
        terminal(outcome)
    }
}

/// Dependency-free segment response state machine shared by the video and alternate-audio HLS routes.
/// It owns the buffer lease from the clean pre-header residency probe through every asynchronous send callback,
/// and releases it on the first terminal edge. Only one bounded chunk is read at a time.
final class VortXSegmentResponsePump: @unchecked Sendable {

    enum Terminal: Equatable, Sendable {
        case complete
        case cancelled
        case sendError
        case readError
    }

    typealias Send = (Data, @escaping (Bool) -> Void) -> Void

    private let source: VortXRemuxBuffer
    private let chunkSize: Int
    private var nextOffset: Int
    private var remaining: Int
    private var firstChunk: Data?
    private var lease: VortXRemuxBuffer.ReadLease?
    private var started = false
    private var terminated = false

    /// Acquires the full resource lease and probes at most one chunk before headers are committed. nil is the
    /// clean 404 path: the range is no longer wholly resident, cancellation already won, or the first read failed.
    init?(source: VortXRemuxBuffer,
          offset: Int,
          length: Int,
          chunkSize: Int,
          cancelled: @escaping () -> Bool) {
        guard chunkSize > 0,
              let lease = source.beginReadLease(offset: offset, length: length) else { return nil }
        let first = source.read(
            offset: offset,
            length: min(chunkSize, length),
            cancelled: cancelled)
        guard first.failure == nil, !first.data.isEmpty else { return nil }
        self.source = source
        self.chunkSize = chunkSize
        self.nextOffset = offset + first.data.count
        self.remaining = length - first.data.count
        self.firstChunk = first.data
        self.lease = lease
    }

    /// Sends headers, the probed first chunk and each subsequent bounded chunk in strict callback order.
    /// `send` reports only success/failure, keeping Network.framework out of this executable seam.
    func start(header: Data,
               cancelled: @escaping () -> Bool,
               send: @escaping Send,
               terminal: @escaping (Terminal) -> Void) {
        guard !started, !terminated else { return }
        started = true
        guard !cancelled() else {
            finish(.cancelled, terminal: terminal)
            return
        }
        send(header) { [self] succeeded in
            guard succeeded else {
                finish(.sendError, terminal: terminal)
                return
            }
            sendNext(cancelled: cancelled, send: send, terminal: terminal)
        }
    }

    private func sendNext(cancelled: @escaping () -> Bool,
                          send: @escaping Send,
                          terminal: @escaping (Terminal) -> Void) {
        guard !terminated else { return }
        guard !cancelled() else {
            finish(.cancelled, terminal: terminal)
            return
        }

        let data: Data
        if let firstChunk {
            data = firstChunk
            self.firstChunk = nil
        } else if remaining > 0 {
            let chunk = source.read(
                offset: nextOffset,
                length: min(chunkSize, remaining),
                cancelled: cancelled)
            guard chunk.failure == nil, !chunk.data.isEmpty else {
                finish(cancelled() ? .cancelled : .readError, terminal: terminal)
                return
            }
            data = chunk.data
            nextOffset += data.count
            remaining -= data.count
        } else {
            finish(.complete, terminal: terminal)
            return
        }

        send(data) { [self] succeeded in
            guard succeeded else {
                finish(.sendError, terminal: terminal)
                return
            }
            sendNext(cancelled: cancelled, send: send, terminal: terminal)
        }
    }

    private func finish(_ outcome: Terminal,
                        terminal: (Terminal) -> Void) {
        guard !terminated else { return }
        terminated = true
        firstChunk = nil
        lease = nil
        terminal(outcome)
    }
}
