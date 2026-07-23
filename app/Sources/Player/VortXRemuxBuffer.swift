import Foundation
#if canImport(Darwin)
import Darwin
#endif

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

    /// Exact live allocation proof for the resident byte store. `capacityBytes` is either the explicit extent
    /// of a successfully-created anonymous mapping or the measured size of the tiny heap allocation, never a
    /// logical count or helper-call telemetry. `generation` changes with backing ownership.
    struct ResidentBackingSnapshot: Equatable, Sendable {
        let generation: Int
        let capacityBytes: Int
        let logicalBytes: Int
    }

    fileprivate struct ResidentBackingTransition: Equatable, Sendable {
        let oldCapacityBytes: Int
        let newCapacityBytes: Int
        let remainingLogicalBytes: Int
    }

    private final class ResidentAllocation {
        private enum Kind { case heap, mapping }

        let pointer: UnsafeMutableRawPointer
        let capacity: Int
        private let kind: Kind

        init?(capacity: Int) {
            guard capacity > 0 else { return nil }
            if capacity < ResidentStorage.pageBytes {
                guard let pointer = malloc(capacity) else { return nil }
                guard malloc_size(pointer) == capacity else {
                    free(pointer)
                    return nil
                }
                self.pointer = pointer
                self.capacity = capacity
                kind = .heap
            } else {
                guard capacity % ResidentStorage.pageBytes == 0,
                      let pointer = mmap(
                          nil, capacity, PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANON, -1, 0),
                      pointer != MAP_FAILED else { return nil }
                self.pointer = pointer
                self.capacity = capacity
                kind = .mapping
            }
        }

        deinit {
            switch kind {
            case .heap: free(pointer)
            case .mapping: munmap(pointer, capacity)
            }
        }
    }

    /// One contiguous allocation is required because the fMP4 parser consumes a borrowed `Data` view. Capacity
    /// production-scale growth is rounded to an explicit anonymous-mapping extent, admitted before allocation,
    /// and performed while the old allocation remains charged as transient overlap. The tiny inline allocation
    /// is accepted only when `malloc_size` exactly matches its admitted extent. No Swift `Data` owns backing.
    private struct ResidentStorage {
        private var allocation: ResidentAllocation?
        private(set) var start = 0
        private(set) var count = 0
        private(set) var generation = 0

        var capacity: Int { allocation?.capacity ?? 0 }
        var isEmpty: Bool { count == 0 }
        static let tinyHeapMaximumBytes = 16
        static let pageBytes = Int(getpagesize())

        static func exactAllocationSize(minimum: Int) -> Int? {
            guard minimum > 0 else { return 0 }
            if minimum <= tinyHeapMaximumBytes {
                let good = malloc_good_size(minimum)
                return good >= minimum && good < pageBytes ? good : nil
            }
            guard pageBytes > 0 else { return nil }
            let (padded, overflow) = minimum.addingReportingOverflow(pageBytes - 1)
            guard !overflow else { return nil }
            return padded / pageBytes * pageBytes
        }

        func projectedCapacity(adding additional: Int) -> Int? {
            guard additional >= 0 else { return nil }
            let (logicalRequired, logicalOverflow) = count.addingReportingOverflow(additional)
            guard !logicalOverflow else { return nil }
            if logicalRequired == 0 { return 0 }
            if start <= capacity, logicalRequired <= capacity - start { return capacity }
            if logicalRequired <= capacity { return capacity }
            let doubled: Int
            if capacity > 0, capacity <= Int.max / 2 {
                doubled = capacity * 2
            } else {
                doubled = logicalRequired
            }
            return Self.exactAllocationSize(minimum: max(logicalRequired, doubled))
        }

        mutating func append(_ bytes: UnsafePointer<UInt8>, count additional: Int,
                             admittedCapacity: Int? = nil) -> Bool {
            guard additional > 0,
                  let projected = projectedCapacity(adding: additional),
                  admittedCapacity == nil || admittedCapacity == projected else { return false }
            let (logicalRequired, overflow) = count.addingReportingOverflow(additional)
            guard !overflow else { return false }

            if let allocation, start <= allocation.capacity,
               logicalRequired <= allocation.capacity - start {
                allocation.pointer.advanced(by: start + count).copyMemory(
                    from: bytes, byteCount: additional)
                count = logicalRequired
                return true
            }
            if let allocation, logicalRequired <= allocation.capacity {
                memmove(allocation.pointer, allocation.pointer.advanced(by: start), count)
                start = 0
                allocation.pointer.advanced(by: count).copyMemory(
                    from: bytes, byteCount: additional)
                count = logicalRequired
                return true
            }
            guard let next = ResidentAllocation(capacity: projected),
                  next.capacity == projected else { return false }
            if let allocation, count > 0 {
                next.pointer.copyMemory(
                    from: allocation.pointer.advanced(by: start), byteCount: count)
            }
            next.pointer.advanced(by: count).copyMemory(from: bytes, byteCount: additional)
            allocation = next
            start = 0
            count = logicalRequired
            generation &+= 1
            return true
        }

        mutating func removeFirst(_ amount: Int) -> Bool {
            guard amount >= 0, amount <= count else { return false }
            start += amount
            count -= amount
            if count == 0 { releaseAll() }
            return true
        }

        func projectedCapacity(afterDropping amount: Int) -> Int? {
            guard amount >= 0, amount <= count else { return nil }
            return Self.exactAllocationSize(minimum: count - amount)
        }

        mutating func compact(afterDropping amount: Int,
                              admittedCapacity: Int) -> Bool {
            guard amount >= 0, amount <= count,
                  let projected = projectedCapacity(afterDropping: amount),
                  projected == admittedCapacity else { return false }
            let remaining = count - amount
            guard remaining > 0 else {
                releaseAll()
                return admittedCapacity == 0
            }
            guard let allocation,
                  let next = ResidentAllocation(capacity: projected),
                  next.capacity == projected else { return false }
            next.pointer.copyMemory(
                from: allocation.pointer.advanced(by: start + amount), byteCount: remaining)
            self.allocation = next
            start = 0
            count = remaining
            generation &+= 1
            return true
        }

        mutating func compactInPlaceIfUseful(threshold: Int) {
            guard start >= threshold, count > 0,
                  let projected = Self.exactAllocationSize(minimum: count),
                  projected < capacity,
                  let allocation,
                  let next = ResidentAllocation(capacity: projected),
                  next.capacity == projected else { return }
            next.pointer.copyMemory(
                from: allocation.pointer.advanced(by: start), byteCount: count)
            self.allocation = next
            start = 0
            generation &+= 1
        }

        mutating func releaseAll() {
            allocation = nil
            start = 0
            count = 0
            generation &+= 1
        }

        func copyData(localOffset: Int, length: Int) -> Data? {
            guard localOffset >= 0, length >= 0,
                  localOffset <= count, length <= count - localOffset else { return nil }
            guard length > 0 else { return Data() }
            guard let allocation else { return nil }
            return Data(
                bytes: allocation.pointer.advanced(by: start + localOffset),
                count: length)
        }

        func withBorrowedData<T>(localOffset: Int, length: Int,
                                 operation: (Data) -> T) -> T? {
            guard localOffset >= 0, length > 0,
                  localOffset <= count, length <= count - localOffset,
                  let allocation else { return nil }
            let borrowed = Data(
                bytesNoCopy: allocation.pointer.advanced(by: start + localOffset),
                count: length,
                deallocator: .none)
            let result = operation(borrowed)
            withExtendedLifetime(allocation) {}
            return result
        }

        mutating func overwrite(localOffset: Int, data: Data) -> Bool {
            guard localOffset >= 0, localOffset <= count,
                  data.count <= count - localOffset,
                  let allocation else { return false }
            data.withUnsafeBytes { source in
                guard let base = source.baseAddress else { return }
                allocation.pointer.advanced(by: start + localOffset).copyMemory(
                    from: base, byteCount: source.count)
            }
            return true
        }
    }

    private let condition = NSCondition()
    /// The retained tail of the produced stream. `storage[storage.startIndex]` corresponds to absolute offset
    /// `storageBase`. The index base is NOT always 0: `evictBelow`'s `Data.removeFirst` advances an internal
    /// start offset, so reads and eviction must work relative to `storage.startIndex`, never a bare 0.
    private var storage = ResidentStorage()
    /// Absolute offset of the first byte still held in `storage`. Bytes below this have been delivered and evicted.
    private var storageBase = 0
    private var isFinished = false
    private var failureMessage: String?
    private var nextReadLeaseID = 0
    private var activeReadRanges: [Int: Range<Int>] = [:]
    /// nil on the progressive rollback path. The HLS session spool owns this object; the buffer keeps only a
    /// weak route to it so teardown cannot form buffer -> stage -> buffer ownership.
    private weak var openStage: VortXHLSSessionSpool.OpenStage?

    /// Total bytes produced so far across the whole session (monotonic; NOT storage.count once eviction starts).
    private(set) var producedCount: Int = 0

    /// Design minimum for the in-memory re-read window, in MiB. This is not a segment-size limit: legal GOPs
    /// may exceed the retired 32 MiB threshold. Active read leases independently prevent eviction beneath an
    /// open response, while this floor keeps ordinary near-frontier re-reads from churning. The shipped
    /// RemoteConfig default (`dvRemuxWindowMiB` = 64) is exactly this value, so the clamp is a fleet no-op today
    /// and only protects against a pathological smaller remote value.
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
    // once ready, the full lead restores steady-state headroom. The 16 MiB reduced lead is added on top of
    // windowFloorBytes (at least 64 MiB), so the pre-ready resident ceiling stays at least 80 MiB. This is a
    // capacity control only. With the obsolete 32 MiB open-segment limit retired, it does not prove that an
    // arbitrarily large in-progress fragment cannot stall; that requires separate spill/staging work. ---
    private static let producerLeadPreReady = 16 * 1024 * 1024   // F3: reduced lead before first-frame readiness
    private static let producerLeadFull      = 64 * 1024 * 1024   // F3: full lead once the engine is ready
    private let producerLeadPreReadyBytes: Int
    private let producerLeadFullBytes: Int
    /// Set once via `markEngineReady()` when AVPlayerEngine reports readyToPlay/first frame; guarded by
    /// `condition`. Selects the producer lead in `append` (reduced before, full after).
    private var engineReady = false

    /// Bytes currently held in `storage` (delivered floor plus producer lead). Caller holds the lock.
    private var residentCount: Int { storage.count }

    /// Caller holds `condition`. The optional capacity was admitted by the open-stage coordinator before this
    /// allocation can overlap the old backing.
    private func appendResidentLocked(_ bytes: UnsafePointer<UInt8>, count: Int,
                                      admittedCapacity: Int? = nil) -> Bool {
        storage.append(bytes, count: count, admittedCapacity: admittedCapacity)
    }

    /// Production uses the fleet-clamped MiB floor. The explicit byte floor exists so the production buffer's
    /// eviction contract can be executed quickly by the standalone regression harness.
    init(windowFloorBytes: Int? = nil, producerLeadBytes: Int? = nil) {
        self.windowFloorBytes = max(1, windowFloorBytes
            ?? max(Self.windowFloorMinMiB, RemoteConfig.snapshot.dvRemuxWindowMiB) * 1024 * 1024)
        self.producerLeadPreReadyBytes = max(1, producerLeadBytes ?? Self.producerLeadPreReady)
        self.producerLeadFullBytes = max(1, producerLeadBytes ?? Self.producerLeadFull)
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
        let stage = openStage
        if let stage, stage.routesForwardAppends {
            condition.unlock()
            append(bytes, count: count, through: stage)
            return
        }
        // F3 two-stage lead: reduced until the engine reports readiness, then full.
        let ceiling = windowFloorBytes
            + (engineReady ? producerLeadFullBytes : producerLeadPreReadyBytes)
        while residentCount >= ceiling && !isFinished {
            condition.wait(until: Date().addingTimeInterval(0.25))
        }
        if isFinished {           // finished/failed/cancelled while parked: drop these bytes, unblock teardown.
            condition.unlock()
            return
        }
        guard appendResidentLocked(bytes, count: count) else {
            failureMessage = "remux buffer resident allocation failed"
            isFinished = true
            condition.broadcast()
            condition.unlock()
            return
        }
        producedCount += count
        condition.signal()
        condition.unlock()
    }

    /// How long the stage-append producer may PARK on a full session spool before the mount is declared dead.
    /// Retention deadlines are seconds-to-a-minute (segment + longest-playlist duration), so a healthy playing
    /// session reclaims space well inside this bound; only a genuinely wedged spool exhausts it.
    private static let stageBackpressureLimitSeconds: TimeInterval = 120

    /// HLS-only append path. Stage admission and any filesystem write happen with the buffer condition unlocked;
    /// the producer then advances the buffer head. A memory stage materializes the bytes in RAM. An active stage
    /// is durable first and advances an already-empty resident frontier without copying those bytes into `Data`.
    ///
    /// A FULL session spool is BACKPRESSURE, not death (build 189 field lesson): the 512 MiB ceiling is
    /// admission-only and expired-retention reclamation frees space as playback advances, so a producer that
    /// out-runs the budget must PARK and retry exactly like the legacy resident-ceiling path above - failing
    /// here killed every healthy UHD DV play ~25s in ("remux failed" 404s -> AVPlayer endFileError -> HDR10
    /// demote). A stage that dies for a real reason fails the buffer through `poisonAndFail`, which ends the
    /// retry loop with the honest first failure preserved.
    private func append(_ bytes: UnsafePointer<UInt8>, count: Int,
                        through stage: VortXHLSSessionSpool.OpenStage) {
        let parkDeadline = Date().addingTimeInterval(Self.stageBackpressureLimitSeconds)
        var forwardReceipt: VortXHLSSessionSpool.OpenStage.ForwardReceipt?
        var head = 0
        var nextHead = 0
        while true {
            condition.lock()
            guard !isFinished else { condition.unlock(); return }
            head = producedCount
            let resident = residentCount
            let residentBackingBefore = storage.capacity
            let residentBackingAfter = storage.projectedCapacity(adding: count)
            let ceiling = windowFloorBytes
                + (engineReady ? producerLeadFullBytes : producerLeadPreReadyBytes)
            condition.unlock()
            let (projectedResident, residentOverflow) = resident.addingReportingOverflow(count)
            let (nextHeadValue, headOverflow) = head.addingReportingOverflow(count)
            guard !residentOverflow, !headOverflow, let residentBackingAfter else {
                fail("HLS mutable open-stage resident arithmetic overflow")
                return
            }
            nextHead = nextHeadValue

            if let receipt = stage.acceptForward(
                bytes, count: count, at: head, projectedResidentBytes: projectedResident,
                activationThresholdBytes: ceiling,
                residentBackingCapacityBefore: residentBackingBefore,
                residentBackingCapacityAfter: residentBackingAfter) {
                forwardReceipt = receipt
                break
            }
            // nil admission with a healthy buffer = the spool is at capacity (or a transient state race).
            // Sweep expired retention entries, park briefly, retry. A real stage death fails the buffer and
            // the guard at the top of the loop returns on the next pass.
            if Date() >= parkDeadline {
                fail("HLS session spool stayed full for \(Int(Self.stageBackpressureLimitSeconds))s (backpressure limit)")
                return
            }
            stage.reclaimExpiredForBackpressure()
            condition.lock()
            if !isFinished {
                condition.wait(until: Date().addingTimeInterval(0.25))
            }
            let finished = isFinished
            condition.unlock()
            if finished { return }
        }
        guard let forwardReceipt else { return }
        defer { stage.completeForward(forwardReceipt) }

        condition.lock()
        guard !isFinished, producedCount == head,
              forwardReceipt.endOffset == nextHead else {
            condition.unlock()
            stage.requestAbort()
            return
        }
        if forwardReceipt.isDurable {
            // Activation exact-reclaims the prior resident range before it releases its transient reservation.
            // Therefore every later active append must begin at an empty resident frontier. Advancing both
            // absolute counters preserves storage == [storageBase, producedCount) without allocating a second
            // copy that ordinary sub-floor eviction could retain in `Data` backing.
            guard storageBase == head, storage.isEmpty else {
                condition.unlock()
                stage.requestAbort()
                fail("HLS mutable open-stage durable frontier retained unexpected RAM backing")
                return
            }
            storageBase = nextHead
        } else {
            guard let admittedCapacity = forwardReceipt.residentBackingCapacity,
                  appendResidentLocked(bytes, count: count, admittedCapacity: admittedCapacity) else {
                condition.unlock()
                stage.requestAbort()
                fail("HLS mutable open-stage RAM materialization failed")
                return
            }
        }
        producedCount = nextHead
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
        guard appendResidentLocked(bytes, count: count) else { return false }
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

    /// Reclaims an exact durable prefix and compacts the remaining bytes before returning. Unlike the ordinary
    /// sliding-window trim, this never advances partially beneath an active lease. Open-stage accounting keeps
    /// the duplicate-copy charge until this method confirms that the old backing allocation is no longer owned.
    fileprivate func projectedBackingCapacityAfterReclaim(before absoluteOffset: Int) -> Int? {
        condition.lock(); defer { condition.unlock() }
        guard absoluteOffset >= storageBase, absoluteOffset <= producedCount else { return nil }
        return storage.projectedCapacity(afterDropping: absoluteOffset - storageBase)
    }

    fileprivate func reclaimDurablyBackedPrefix(
        before absoluteOffset: Int,
        admittedCapacity: Int
    ) -> ResidentBackingTransition? {
        condition.lock()
        defer { condition.unlock() }
        guard absoluteOffset >= storageBase, absoluteOffset <= producedCount else { return nil }
        if let leasedFloor = activeReadRanges.values.map(\.lowerBound).min(),
           leasedFloor < absoluteOffset { return nil }
        let dropCount = absoluteOffset - storageBase
        let oldCapacity = storage.capacity
        guard storage.compact(afterDropping: dropCount, admittedCapacity: admittedCapacity) else {
            return nil
        }
        storageBase = absoluteOffset
        condition.signal()
        return ResidentBackingTransition(
            oldCapacityBytes: oldCapacity,
            newCapacityBytes: storage.capacity,
            remainingLogicalBytes: storage.count)
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
        let patch = Data(bytes: bytes, count: count)
        condition.lock()
        let stage = openStage
        if let stage, stage.isArmed {
            condition.unlock()
            return overwriteStaged(at: offset, data: patch, stage: stage)
        }
        let result = overwriteResidentLocked(at: offset, data: patch)
        condition.unlock()
        return result
    }

    /// After init publication, only the mutable open range is authoritative. Closed-prefix trailer patches are
    /// best effort; a straddling patch is split so failure below the stage base cannot hide failure in the open
    /// suffix. Active-stage bytes are patched durably first, then any overlapping RAM copy is brought in sync.
    private func overwriteStaged(at offset: Int, data patch: Data,
                                 stage: VortXHLSSessionSpool.OpenStage) -> Bool {
        let range = stage.mutableRange
        let (end, overflow) = offset.addingReportingOverflow(patch.count)
        guard !overflow else { return false }
        guard end <= range.upperBound else {
            fail("HLS mutable open-stage backpatch extended beyond the produced head")
            return false
        }
        let mutableStart = max(offset, range.lowerBound)
        let closedEnd = min(end, range.lowerBound)

        if offset < closedEnd {
            bestEffortOverwriteResident(
                at: offset,
                data: patch.subdata(in: 0..<(closedEnd - offset)))
        }
        guard mutableStart < end else { return true }
        let localStart = mutableStart - offset
        let mutableData = patch.subdata(in: localStart..<(localStart + end - mutableStart))
        switch stage.overwriteMutable(at: mutableStart, data: mutableData) {
        case .memory:
            guard overwriteResident(at: mutableStart, data: mutableData) else {
                fail("HLS mutable open-stage RAM backpatch missed its resident range")
                return false
            }
        case .active:
            bestEffortOverwriteResident(at: mutableStart, data: mutableData)
        case .failed:
            fail("HLS mutable open-stage durable backpatch failed")
            return false
        }
        return true
    }

    private func overwriteResident(at offset: Int, data: Data) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return overwriteResidentLocked(at: offset, data: data)
    }

    /// Caller holds `condition`, binding the stage route decision and the resident mutation to one producer edge.
    private func overwriteResidentLocked(at offset: Int, data: Data) -> Bool {
        let (end, overflow) = offset.addingReportingOverflow(data.count)
        // Must lie fully within the resident, already-produced window. storage always spans exactly
        // [storageBase, producedCount) (eviction only drops BELOW storageBase, appends only grow the top), so
        // this bound alone guarantees the byte range is present.
        guard !overflow, offset >= storageBase, end <= producedCount else { return false }
        // `withUnsafeMutableBytes` exposes the LOGICAL content 0-based (it hides `storage.startIndex`), so the
        // byte at absolute `offset` maps to local index `offset - storageBase`, never a bare `startIndex` add.
        let local = offset - storageBase
        return storage.overwrite(localOffset: local, data: data)
    }

    private func bestEffortOverwriteResident(at offset: Int, data: Data) {
        guard !data.isEmpty else { return }
        condition.lock()
        let (dataEnd, overflow) = offset.addingReportingOverflow(data.count)
        guard !overflow else { condition.unlock(); return }
        let patchStart = max(offset, storageBase)
        let patchEnd = min(dataEnd, producedCount)
        if patchStart < patchEnd {
            let sourceStart = patchStart - offset
            let local = patchStart - storageBase
            let overlap = data.subdata(in: sourceStart..<(sourceStart + patchEnd - patchStart))
            _ = storage.overwrite(localOffset: local, data: overlap)
        }
        condition.unlock()
    }

    fileprivate func attachOpenStage(_ stage: VortXHLSSessionSpool.OpenStage) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard openStage == nil else { return openStage === stage }
        openStage = stage
        return true
    }

    fileprivate func stageActivationSnapshot()
        -> (produced: Int, resident: Int, backing: Int, threshold: Int, failed: Bool) {
        condition.lock(); defer { condition.unlock() }
        return (
            producedCount,
            residentCount,
            storage.capacity,
            windowFloorBytes + (engineReady ? producerLeadFullBytes : producerLeadPreReadyBytes),
            isFinished)
    }

    /// Holds the producer boundary while an arming stage charges and adopts every byte appended since its first
    /// snapshot. The closure performs accounting/state transitions only; filesystem work remains outside.
    fileprivate func withStageActivationBarrier<T>(
        _ operation: ((produced: Int, resident: Int, backing: Int,
                       threshold: Int, failed: Bool)) -> T
    ) -> T {
        condition.lock(); defer { condition.unlock() }
        return operation((
            producedCount,
            residentCount,
            storage.capacity,
            windowFloorBytes + (engineReady ? producerLeadFullBytes : producerLeadPreReadyBytes),
            isFinished))
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
        let isFirstFailure = failureMessage == nil
        if isFirstFailure { failureMessage = message }
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
        storage.releaseAll()
        storageBase = producedCount
        condition.broadcast()
        condition.unlock()
        // Beta 7 field lesson (build 189, diag 7/8): every remux death demoted the play with NO reason in the
        // diagnostics export, because many fail() call sites are silent. Log the FIRST failure reason here, at
        // the one funnel every death passes through. "cancelled" is ordinary teardown and stays quiet.
        if isFirstFailure, message != "cancelled" {
            DiagnosticsLog.log("dv", "remux buffer FAILED: \(message)")
        }
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

    /// Exact live allocation state, including allocator capacity retained behind an empty logical range.
    var residentBackingSnapshot: ResidentBackingSnapshot {
        condition.lock(); defer { condition.unlock() }
        return ResidentBackingSnapshot(
            generation: storage.generation,
            capacityBytes: storage.capacity,
            logicalBytes: storage.count)
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
        return storage.copyData(localOffset: 0, length: length)
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
        return storage.copyData(localOffset: local, length: length)
    }

    /// Borrow one resident range without allocating a second payload. The buffer lock keeps the allocation
    /// stable for the nonescaping operation; the open-stage claim independently blocks producer mutation.
    fileprivate func withResidentBytes(offset: Int, length: Int,
                                       operation: (Data) -> Void) -> Bool {
        guard offset >= 0, length > 0 else { return false }
        let (end, overflow) = offset.addingReportingOverflow(length)
        guard !overflow else { return false }
        condition.lock(); defer { condition.unlock() }
        guard offset >= storageBase, end <= producedCount else { return false }
        let local = offset - storageBase
        guard storage.withBorrowedData(
            localOffset: local, length: length,
            operation: { bytes in operation(bytes) }) != nil else { return false }
        return true
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
                let localStart = offset - storageBase
                let available = storage.count - localStart
                let take = min(length, available)
                guard let slice = storage.copyData(localOffset: localStart, length: take) else {
                    // Unreachable given the window invariant, but fail soft (drives the AVPlayer -> libmpv
                    // fallback) instead of trapping and taking the whole app down, as the old code did.
                    return ReadResult(data: Data(), atEnd: true, failure: "remux buffer range out of bounds")
                }
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

    /// Caller holds `condition`. Logical prefix removal keeps the allocation until one full floor is reclaimable,
    /// then moves the retained suffix into a smaller measured allocation.
    private func discardPrefixLocked(before keepFrom: Int) {
        let leasedFloor = activeReadRanges.values.map(\.lowerBound).min()
        let protectedKeepFrom = min(keepFrom, leasedFloor ?? keepFrom)
        let dropCount = protectedKeepFrom - storageBase
        guard dropCount > 0, dropCount <= storage.count else { return }
        guard storage.removeFirst(dropCount) else { return }
        storageBase += dropCount
        storage.compactInPlaceIfUseful(threshold: windowFloorBytes)
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
        case openStageForwardWrite(afterBytes: Int, rollbackFails: Bool)
        case openStageFstat
        case openStageMMap
        case openStageCancelBeforeRegistry
        case openStageCancelAfterRegistry
        case openStageCreatePermission
        case openStageMovePermission
        case openStageMovePermissionCleanupRemoveOnce
        case openStageActivationCleanupRemoveOnce
        case cleanupRemove(failures: Int)
    }

    struct Accounting: Equatable, Sendable {
        fileprivate(set) var finalBytes = 0
        fileprivate(set) var temporaryBytes = 0
        fileprivate(set) var reservedBytes = 0
        fileprivate(set) var auxiliaryBytes = 0
        fileprivate(set) var openBytes = 0
        /// Logical open bytes currently represented by the resident allocation. These bytes are already part
        /// of `openBytes`, so physical accounting subtracts them once before adding actual allocator capacity.
        fileprivate(set) var residentLogicalBytes = 0
        /// Actual live allocator extent: measured by `malloc_size` for the tiny heap case, or the explicit
        /// page-rounded length of the successfully-created anonymous mapping.
        fileprivate(set) var residentBackingBytes = 0
        fileprivate(set) var transientCopyBytes = 0
        fileprivate(set) var quarantinedBytes = 0
        fileprivate(set) var peakTemporaryBytes = 0
        fileprivate(set) var peakReservedBytes = 0
        fileprivate(set) var peakChunkBytes = 0
        fileprivate(set) var peakTransientCopyBytes = 0

        /// Temporary bytes are a materialized subset of their reservation, so counting both would double-charge
        /// one write. Admission is committed final + non-file auxiliary + open + reserved + quarantined bytes.
        /// Public totals saturate only for diagnostics; every admission path below uses the checked variants and
        /// therefore rejects arithmetic overflow instead of mistaking it for free capacity.
        var admittedBytes: Int { checkedAdmittedBytes() ?? Int.max }
        var physicalBytes: Int { checkedPhysicalBytes() ?? Int.max }
        var residentBackingOverheadBytes: Int {
            guard residentBackingBytes >= residentLogicalBytes else { return Int.max }
            return residentBackingBytes - residentLogicalBytes
        }

        fileprivate func checkedPhysicalBytes(
            replacingAuxiliaryWith replacement: Int? = nil
        ) -> Int? {
            guard let admitted = checkedAdmittedBytes(
                replacingAuxiliaryWith: replacement),
                  residentLogicalBytes >= 0,
                  residentBackingBytes >= residentLogicalBytes,
                  openBytes >= residentLogicalBytes,
                  let total = Self.checkedSum([
                      admitted,
                      transientCopyBytes,
                      residentBackingBytes - residentLogicalBytes,
                  ]) else { return nil }
            return total
        }

        private func checkedAdmittedBytes(
            replacingAuxiliaryWith replacement: Int? = nil
        ) -> Int? {
            Self.checkedSum([
                finalBytes,
                replacement ?? auxiliaryBytes,
                openBytes,
                reservedBytes,
                quarantinedBytes,
            ])
        }

        private static func checkedSum(_ values: [Int]) -> Int? {
            var total = 0
            for value in values {
                guard value >= 0 else { return nil }
                let (next, overflow) = total.addingReportingOverflow(value)
                guard !overflow else { return nil }
                total = next
            }
            return total
        }
    }

    fileprivate struct OpenStageArmReceipt: Sendable {
        let id: UUID
        let initialOpenBytes: Int
        let priorAuxiliaryBytes: Int
        let auxiliaryGenerationBefore: Int
        let auxiliaryGenerationAfter: Int
        let priorResidentLogicalBytes: Int
        let priorResidentBackingBytes: Int
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

    /// One mutable, session-owned backing for the currently open primary-video range. It is attached only to
    /// the HLS buffer. The sole nested lock order is producer condition -> state lock during routing/adoption;
    /// no path takes that pair in reverse. The state lock never spans spool, filesystem, parser, or callback work.
    final class OpenStage: @unchecked Sendable {
        enum Storage: Equatable, Sendable {
            case dormant
            case arming
            case memory
            case activating
            case active
            case promoting
            case poisoned
        }

        struct Snapshot: Equatable, Sendable {
            let storage: Storage
            let baseOffset: Int
            let logicalEndOffset: Int
            let durableEndOffset: Int
            let fileURL: URL?
            let abortRequested: Bool
            let activeClaimReads: Int
        }

        enum OverwriteResult { case memory, active, failed }

        fileprivate struct ArmPreparation: Sendable {
            let tokenID: UUID
            var accountingReceipt: OpenStageArmReceipt
            let baseOffset: Int
            let initialEndOffset: Int

            var auxiliaryGeneration: Int {
                accountingReceipt.auxiliaryGenerationAfter
            }
        }

        fileprivate struct ForwardReceipt: Sendable {
            let id: UUID
            let endOffset: Int
            let isDurable: Bool
            let residentBackingCapacity: Int?
        }

        final class OpenClaim: @unchecked Sendable {
            let baseOffset: Int
            let logicalEndOffset: Int
            fileprivate let id: UUID
            private weak var stage: OpenStage?
            private let lock = NSLock()
            private enum State { case available, inUse, consumed, released }
            private var state: State = .available
            private var releasePending = false

            fileprivate init(stage: OpenStage, id: UUID, base: Int, end: Int) {
                self.stage = stage
                self.id = id
                self.baseOffset = base
                self.logicalEndOffset = end
            }

            /// The operation is nonescaping by default and completes before an active mmap is unmapped. Callers
            /// that retain parsed bytes must copy them inside the closure.
            func withBytes(_ operation: (Data) -> Void) -> Bool {
                lock.lock()
                guard case .available = state else { lock.unlock(); return false }
                state = .inUse
                lock.unlock()
                let result = stage?.withClaimBytes(self, operation: operation) ?? false
                finishUse()
                return result
            }

            func release() {
                lock.lock()
                let releaseNow: Bool
                switch state {
                case .available:
                    state = .released
                    releaseNow = true
                case .inUse:
                    releasePending = true
                    releaseNow = false
                case .consumed, .released:
                    releaseNow = false
                }
                lock.unlock()
                if releaseNow { stage?.releaseClaim(id: id) }
            }

            fileprivate func consume() -> Bool {
                lock.lock(); defer { lock.unlock() }
                guard case .available = state else { return false }
                state = .consumed
                return true
            }

            private func finishUse() {
                lock.lock()
                guard case .inUse = state else { lock.unlock(); return }
                let releaseNow = releasePending
                state = releaseNow ? .released : .available
                releasePending = false
                lock.unlock()
                if releaseNow { stage?.releaseClaim(id: id) }
            }

            deinit { release() }
        }

        private weak var owner: VortXHLSSessionSpool?
        fileprivate weak var buffer: VortXRemuxBuffer?
        private let lock = NSCondition()
        private var storage: Storage = .dormant
        private var baseOffset = 0
        private var logicalEndOffset = 0
        private var durableEndOffset = 0
        private var fileURL: URL?
        private var abortRequested = false
        private var activeClaimID: UUID?
        private var activeClaimReads = 0
        private var closeTokenID: UUID?
        private var armTokenID: UUID?
        private var forwardCommitID: UUID?

        fileprivate init(owner: VortXHLSSessionSpool, buffer: VortXRemuxBuffer) {
            self.owner = owner
            self.buffer = buffer
        }

        var snapshot: Snapshot {
            lock.lock(); defer { lock.unlock() }
            return Snapshot(
                storage: storage,
                baseOffset: baseOffset,
                logicalEndOffset: logicalEndOffset,
                durableEndOffset: durableEndOffset,
                fileURL: fileURL,
                abortRequested: abortRequested,
                activeClaimReads: activeClaimReads)
        }

        var routesForwardAppends: Bool {
            lock.lock(); defer { lock.unlock() }
            return (storage == .arming || storage == .memory || storage == .activating
                || storage == .active || storage == .promoting)
                && !abortRequested
        }

        var isArmed: Bool { routesForwardAppends }

        var mutableRange: Range<Int> {
            lock.lock(); defer { lock.unlock() }
            return baseOffset..<logicalEndOffset
        }

        func arm(base: Int, auxiliaryBytes: Int? = nil) -> Bool {
            guard let preparation = prepareArm(
                base: base,
                auxiliaryBytes: auxiliaryBytes,
                expectedAuxiliaryGeneration: nil) else { return false }
            return finishArm(preparation, restoreAuxiliaryOnFailure: true)
        }

        /// Claims the one-shot arming transition before touching coordinator accounting. This phase performs
        /// only lock-protected snapshots and checked accounting; the filesystem-capable activation is deferred
        /// to `finishArm`, so an external auxiliary transaction can publish its matching generation first.
        fileprivate func prepareArm(base: Int,
                                    auxiliaryBytes: Int?,
                                    expectedAuxiliaryGeneration: Int?) -> ArmPreparation? {
            guard base >= 0, let owner, let buffer else { return nil }
            let tokenID = UUID()
            lock.lock()
            guard storage == .dormant, armTokenID == nil, !abortRequested else {
                lock.unlock()
                return nil
            }
            storage = .arming
            armTokenID = tokenID
            lock.unlock()

            let state = buffer.stageActivationSnapshot()
            guard !state.failed, base <= state.produced else {
                abandonArm(tokenID)
                return nil
            }
            let initialOpen = state.produced - base
            guard let accountingReceipt = owner.armOpenStageAtomically(
                initialOpenBytes: initialOpen,
                residentBackingBytes: state.backing,
                auxiliaryBytes: auxiliaryBytes,
                expectedAuxiliaryGeneration: expectedAuxiliaryGeneration) else {
                abandonArm(tokenID)
                return nil
            }
            lock.lock()
            let valid = storage == .arming && armTokenID == tokenID && !abortRequested
            lock.unlock()
            guard valid else {
                owner.rollbackOpenStageArm(accountingReceipt, restoreAuxiliary: true)
                abandonArm(tokenID)
                return nil
            }
            return ArmPreparation(
                tokenID: tokenID,
                accountingReceipt: accountingReceipt,
                baseOffset: base,
                initialEndOffset: state.produced)
        }

        /// Reconciles every byte that reached the RAM buffer while `.arming` under the buffer's producer
        /// barrier, then switches future appends to the stage before any filesystem activation begins.
        fileprivate func finishArm(_ original: ArmPreparation,
                                   restoreAuxiliaryOnFailure: Bool) -> Bool {
            guard let owner, let buffer else { return false }
            var preparation = original
            let reconciled = buffer.withStageActivationBarrier { state -> Bool in
                guard !state.failed,
                      state.produced >= preparation.initialEndOffset,
                      preparation.baseOffset <= state.produced else { return false }
                let additionalOpen = state.produced - preparation.initialEndOffset
                if additionalOpen > 0 {
                    guard let extended = owner.extendOpenStageArm(
                        preparation.accountingReceipt,
                        additionalBytes: additionalOpen,
                        residentBackingBytes: state.backing) else { return false }
                    preparation.accountingReceipt = extended
                } else if !owner.refreshOpenStageArmBacking(
                    preparation.accountingReceipt,
                    residentBackingBytes: state.backing) {
                    return false
                }
                lock.lock()
                guard storage == .arming, armTokenID == preparation.tokenID,
                      !abortRequested else {
                    lock.unlock()
                    return false
                }
                storage = .memory
                baseOffset = preparation.baseOffset
                logicalEndOffset = state.produced
                durableEndOffset = preparation.baseOffset
                lock.broadcast()
                lock.unlock()
                return true
            }
            guard reconciled else {
                owner.rollbackOpenStageArm(
                    preparation.accountingReceipt,
                    restoreAuxiliary: restoreAuxiliaryOnFailure)
                abandonArm(preparation.tokenID)
                return false
            }

            let pressure = buffer.stageActivationSnapshot()
            if pressure.resident >= pressure.threshold, !activateFromMemory() {
                poisonAndFail("HLS mutable open-stage activation failed during adoption")
                owner.rollbackOpenStageArm(
                    preparation.accountingReceipt,
                    restoreAuxiliary: restoreAuxiliaryOnFailure)
                clearArmToken(preparation.tokenID)
                return false
            }
            owner.completeOpenStageArm(preparation.accountingReceipt)
            clearArmToken(preparation.tokenID)
            return true
        }

        private func abandonArm(_ tokenID: UUID) {
            lock.lock()
            if armTokenID == tokenID {
                storage = abortRequested ? .poisoned : .dormant
                armTokenID = nil
                lock.broadcast()
            }
            lock.unlock()
        }

        private func clearArmToken(_ tokenID: UUID) {
            lock.lock()
            if armTokenID == tokenID { armTokenID = nil }
            lock.broadcast()
            lock.unlock()
        }

        fileprivate func acceptForward(_ bytes: UnsafePointer<UInt8>, count: Int, at offset: Int,
                                       projectedResidentBytes: Int,
                                       activationThresholdBytes: Int,
                                       residentBackingCapacityBefore: Int,
                                       residentBackingCapacityAfter: Int) -> ForwardReceipt? {
            guard count > 0, let owner else { return nil }
            let reservationID = UUID()
            lock.lock()
            while (storage == .arming || storage == .activating) && !abortRequested { lock.wait() }
            let needsActivation = storage == .memory
                && projectedResidentBytes >= activationThresholdBytes
            let intendsResidentStorage = storage == .memory && !needsActivation
            let valid = storage != .dormant && storage != .poisoned
                && !abortRequested && activeClaimID == nil && forwardCommitID == nil
                && offset == logicalEndOffset
            lock.unlock()
            guard valid,
                  owner.reserveOpenGrowth(
                      id: reservationID,
                      logicalBytes: count,
                      residentBackingCapacityBefore: intendsResidentStorage
                          ? residentBackingCapacityBefore : nil,
                      residentBackingCapacityAfter: intendsResidentStorage
                          ? residentBackingCapacityAfter : nil) else { return nil }
            lock.lock()
            let reservedStateStillValid = !abortRequested && activeClaimID == nil
                && forwardCommitID == nil && offset == logicalEndOffset
                && (storage == .memory || storage == .active)
            if reservedStateStillValid { forwardCommitID = reservationID }
            lock.unlock()
            guard reservedStateStillValid else {
                owner.releaseOpenGrowth(id: reservationID)
                return nil
            }
            if needsActivation, !activateFromMemory() {
                poisonAndFail("HLS mutable open-stage backfill failed")
                clearForwardCommit(reservationID)
                owner.releaseOpenGrowth(id: reservationID)
                return nil
            }

            lock.lock()
            let currentStorage = storage
            let url = fileURL
            let oldDurableEnd = durableEndOffset
            let stillValid = !abortRequested && activeClaimID == nil
                && forwardCommitID == reservationID
                && offset == logicalEndOffset
            lock.unlock()
            guard stillValid else {
                clearForwardCommit(reservationID)
                owner.releaseOpenGrowth(id: reservationID)
                return nil
            }

            if currentStorage == .active {
                let transientID = UUID()
                guard let url,
                      owner.reserveTransientCopy(id: transientID, bytes: count) else {
                    clearForwardCommit(reservationID)
                    owner.releaseOpenGrowth(id: reservationID)
                    return nil
                }
                // Growth admission owns the eventual durable bytes. The transient receipt owns the payload
                // copy while it overlaps the file write. The helper's local `Data` lifetime ends before this
                // scope releases that receipt or transfers growth admission into durable open ownership.
                let wrote = writeForwardBytes(
                    bytes, count: count, to: url, absoluteOffset: offset,
                    oldDurableEnd: oldDurableEnd,
                    growthReservationID: reservationID)
                owner.releaseTransientCopy(id: transientID)
                guard wrote else {
                    clearForwardCommit(reservationID)
                    owner.releaseOpenGrowth(id: reservationID)
                    return nil
                }
            } else if currentStorage != .memory {
                clearForwardCommit(reservationID)
                owner.releaseOpenGrowth(id: reservationID)
                return nil
            }

            lock.lock()
            let (nextEnd, endOverflow) = logicalEndOffset.addingReportingOverflow(count)
            guard !abortRequested, storage == currentStorage,
                  forwardCommitID == reservationID, logicalEndOffset == offset else {
                lock.unlock()
                clearForwardCommit(reservationID)
                owner.releaseOpenGrowth(id: reservationID)
                return nil
            }
            guard !endOverflow else {
                lock.unlock()
                poisonAndFail("HLS mutable open-stage offset overflow")
                clearForwardCommit(reservationID)
                owner.releaseOpenGrowth(id: reservationID)
                return nil
            }
            logicalEndOffset = nextEnd
            if storage == .active { durableEndOffset = logicalEndOffset }
            lock.unlock()
            guard owner.commitOpenGrowth(id: reservationID, bytes: count) else {
                poisonAndFail("HLS mutable open-stage accounting commit failed")
                clearForwardCommit(reservationID)
                return nil
            }
            return ForwardReceipt(
                id: reservationID,
                endOffset: nextEnd,
                isDurable: currentStorage == .active,
                residentBackingCapacity: currentStorage == .memory
                    ? residentBackingCapacityAfter : nil)
        }

        fileprivate func completeForward(_ receipt: ForwardReceipt) {
            owner?.completeOpenGrowth(id: receipt.id)
            clearForwardCommit(receipt.id)
        }

        private func clearForwardCommit(_ id: UUID) {
            lock.lock()
            if forwardCommitID == id {
                forwardCommitID = nil
                lock.broadcast()
            }
            lock.unlock()
        }

        /// Backpressure recovery sweep: a producer parked on a full spool collects expired retention entries
        /// itself, so reclamation does not depend on client playlist traffic arriving while it is parked.
        fileprivate func reclaimExpiredForBackpressure() {
            owner?.collectExpired(now: ProcessInfo.processInfo.systemUptime)
        }

        fileprivate func requestAbort() {
            lock.lock()
            abortRequested = true
            lock.broadcast()
            lock.unlock()
        }

        fileprivate func overwriteMutable(at offset: Int, data: Data) -> OverwriteResult {
            guard !data.isEmpty else { return .memory }
            lock.lock()
            let (end, overflow) = offset.addingReportingOverflow(data.count)
            let currentStorage = storage
            let url = fileURL
            let valid = !abortRequested && activeClaimID == nil
                && !overflow && offset >= baseOffset && end <= logicalEndOffset
            lock.unlock()
            guard valid else { return .failed }
            if currentStorage == .memory { return .memory }
            guard currentStorage == .active, let url, let owner,
                  owner.beginStageOperation() else { return .failed }
            defer { owner.endStageOperation() }
            do {
                owner.notifyFileOperation()
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(offset - snapshot.baseOffset))
                try handle.write(contentsOf: data)
                try handle.synchronize()
                return .active
            } catch {
                poisonAndFail("HLS mutable open-stage backpatch write failed")
                return .failed
            }
        }

        func claim() -> OpenClaim? {
            lock.lock(); defer { lock.unlock() }
            guard !abortRequested, storage == .memory || storage == .active,
                  activeClaimID == nil, forwardCommitID == nil,
                  logicalEndOffset > baseOffset else { return nil }
            let id = UUID()
            activeClaimID = id
            return OpenClaim(
                stage: self, id: id, base: baseOffset, end: logicalEndOffset)
        }

        func closePrefix(_ claim: OpenClaim,
                         endOffset: Int,
                         key: ResourceKey,
                         durationMilliseconds: Int,
                         additionalResources: [SpillResource]) -> Bool {
            // Acquire the weak owner before consuming the one-shot claim. If teardown already released the
            // spool, the caller can still release this claim and clear activeClaimID instead of stranding it.
            guard let owner, claim.consume() else { return false }
            let result = owner.closeOpenStagePrefix(
                stage: self,
                claimID: claim.id,
                claimedBase: claim.baseOffset,
                claimedEnd: claim.logicalEndOffset,
                endOffset: endOffset,
                key: key,
                durationMilliseconds: durationMilliseconds,
                additionalResources: additionalResources)
            if !result {
                releaseClaim(id: claim.id)
                buffer?.fail("HLS mutable open-stage close failed")
            }
            return result
        }

        fileprivate func releaseClaim(id: UUID) {
            lock.lock()
            if activeClaimID == id { activeClaimID = nil }
            lock.unlock()
        }

        private func withClaimBytes(_ claim: OpenClaim,
                                    operation: (Data) -> Void) -> Bool {
            guard owner != nil, let buffer else { return false }
            lock.lock()
            let valid = activeClaimID == claim.id
                && baseOffset == claim.baseOffset && logicalEndOffset == claim.logicalEndOffset
                && !abortRequested && activeClaimReads == 0
            let currentStorage = storage
            let url = fileURL
            let length = claim.logicalEndOffset - claim.baseOffset
            if valid && length > 0 { activeClaimReads += 1 }
            lock.unlock()
            guard valid, length > 0 else { return false }
            defer { finishClaimRead() }
            if currentStorage == .memory {
                let pressure = buffer.stageActivationSnapshot()
                guard length < pressure.threshold,
                      buffer.withResidentBytes(
                          offset: claim.baseOffset,
                          length: length,
                          operation: operation) else {
                    poisonAndFail("HLS mutable open-stage RAM claim exceeded its activation bound")
                    return false
                }
                return true
            }
            guard currentStorage == .active, let url else { return false }
            return withMappedPrefix(url: url, length: length, operation: operation)
        }

        private func finishClaimRead() {
            lock.lock()
            if activeClaimReads > 0 { activeClaimReads -= 1 }
            lock.unlock()
        }

        /// Explicit nonescaping mapping. The Data owns munmap and is destroyed before this method returns, so
        /// append, truncate, or rename cannot overlap a live mapping from a parser claim.
        private func withMappedPrefix(url: URL, length: Int,
                                      operation: (Data) -> Void) -> Bool {
            guard let owner, owner.beginStageOperation() else { return false }
            defer { owner.endStageOperation() }
            var descriptor: Int32 = -1
            do {
                owner.notifyFileOperation()
                descriptor = Darwin.open(url.path, O_RDONLY)
                guard descriptor >= 0 else { throw SpoolError.invalidSource }
                defer { Darwin.close(descriptor) }
                if owner.failureInjection == .openStageFstat { throw SpoolError.injectedFstat }
                var info = stat()
                guard fstat(descriptor, &info) == 0,
                      info.st_size >= 0,
                      UInt64(info.st_size) >= UInt64(length) else { throw SpoolError.invalidLength }
                if owner.failureInjection == .openStageMMap { throw SpoolError.injectedMMap }
                guard let address = mmap(nil, length, PROT_READ, MAP_PRIVATE, descriptor, 0),
                      address != MAP_FAILED else { throw SpoolError.injectedMMap }
                do {
                    let mapped = Data(bytesNoCopy: address, count: length, deallocator: .unmap)
                    operation(mapped)
                    withExtendedLifetime(mapped) {}
                }
                return true
            } catch {
                if descriptor >= 0 { /* defer closes it */ }
                poisonAndFail("HLS mutable open-stage mmap/fstat failed")
                return false
            }
        }

        private func activateFromMemory() -> Bool {
            guard let owner, let buffer, owner.beginStageOperation() else { return false }
            defer { owner.endStageOperation() }
            lock.lock()
            while storage == .activating && !abortRequested { lock.wait() }
            guard storage == .memory, activeClaimID == nil, !abortRequested else {
                let alreadyActive = storage == .active
                lock.unlock()
                return alreadyActive
            }
            storage = .activating
            let base = baseOffset
            let end = logicalEndOffset
            lock.unlock()

            let length = end - base
            let reservationID = UUID()
            guard owner.reserveTransientCopy(id: reservationID, bytes: length) else {
                restoreOrPoisonAfterActivationFailure()
                return false
            }
            let partURL = owner.sessionDirectory.appendingPathComponent(
                "open-\(UUID().uuidString).part")
            let finalURL = owner.sessionDirectory.appendingPathComponent(
                "open-\(UUID().uuidString).stage")
            var cleanupReceipts: [URL] = []
            var lease: VortXRemuxBuffer.ReadLease?
            if length > 0 {
                lease = buffer.beginReadLease(offset: base, length: length)
                guard lease != nil else {
                    owner.releaseTransientCopy(id: reservationID)
                    restoreOrPoisonAfterActivationFailure()
                    return false
                }
            }
            do {
                cleanupReceipts.append(partURL)
                owner.notifyFileOperation()
                guard FileManager.default.createFile(
                    atPath: partURL.path, contents: nil,
                    attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
                    throw SpoolError.invalidSource
                }
                try VortXHLSSessionSpool.ensureOwnerOnlyFile(partURL)
                let handle = try FileHandle(forWritingTo: partURL)
                do {
                    var copied = 0
                    while copied < length {
                        let count = min(owner.chunkSize, length - copied)
                        guard let chunk = buffer.snapshotChunk(offset: base + copied, length: count) else {
                            throw SpoolError.invalidSource
                        }
                        owner.notifyFileOperation()
                        try handle.write(contentsOf: chunk)
                        copied += chunk.count
                    }
                    try handle.synchronize()
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
                let values = try partURL.resourceValues(forKeys: [.fileSizeKey])
                guard values.fileSize == length else { throw SpoolError.invalidLength }
                cleanupReceipts.append(finalURL)
                owner.notifyFileOperation()
                try FileManager.default.moveItem(at: partURL, to: finalURL)
                try VortXHLSSessionSpool.ensureOwnerOnlyFile(finalURL)
                if owner.failureInjection == .openStageActivationCleanupRemoveOnce {
                    throw SpoolError.injectedPermissions
                }
                lock.lock()
                guard storage == .activating, !abortRequested,
                      baseOffset == base, logicalEndOffset == end else {
                    lock.unlock()
                    throw SpoolError.invalidSource
                }
                storage = .active
                durableEndOffset = end
                fileURL = finalURL
                lock.broadcast()
                lock.unlock()
                lease = nil
                guard let transition = buffer.reclaimDurablyBackedPrefix(
                    before: end,
                    admittedCapacity: 0),
                      owner.commitResidentBackingTransition(
                          transition,
                          residentLogicalBytes: 0,
                          releasingTransientID: reservationID) else {
                    poisonAndFail("HLS mutable open-stage activation could not reclaim RAM backing")
                    owner.invalidateSession()
                    return false
                }
                return true
            } catch {
                lease = nil
                let cleanupComplete = owner.removeCloseArtifacts(cleanupReceipts)
                if cleanupComplete {
                    owner.releaseTransientCopy(id: reservationID)
                } else {
                    owner.quarantineOpenClose(
                        stage: self,
                        id: reservationID,
                        keys: [],
                        receipts: cleanupReceipts)
                }
                restoreOrPoisonAfterActivationFailure()
                return false
            }
        }

        private func restoreOrPoisonAfterActivationFailure() {
            lock.lock()
            storage = abortRequested ? .poisoned : .memory
            lock.broadcast()
            lock.unlock()
        }

        private func writeForward(_ data: Data, to url: URL,
                                  absoluteOffset: Int, oldDurableEnd: Int,
                                  growthReservationID: UUID) -> Bool {
            guard let owner, owner.beginStageOperation() else { return false }
            defer { owner.endStageOperation() }
            let relative = oldDurableEnd - snapshot.baseOffset
            guard relative >= 0 else { return false }
            do {
                owner.notifyFileOperation()
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(relative))
                let written = try owner.writeOpenStageForward(data, to: handle)
                guard written == data.count else {
                    let rollbackFails: Bool
                    if case .openStageForwardWrite(_, let injected) = owner.failureInjection {
                        rollbackFails = injected
                    } else {
                        rollbackFails = false
                    }
                    if rollbackFails {
                        owner.quarantineFailedOpenForward(
                            id: growthReservationID,
                            url: url,
                            oldDurableBytes: relative)
                        lock.lock()
                        storage = .poisoned
                        abortRequested = true
                        lock.broadcast()
                        lock.unlock()
                    } else {
                        try handle.truncate(atOffset: UInt64(relative))
                        try handle.synchronize()
                    }
                    buffer?.fail("HLS mutable open-stage partial write")
                    return false
                }
                try handle.synchronize()
                return true
            } catch {
                owner.quarantineFailedOpenForward(
                    id: growthReservationID,
                    url: url,
                    oldDurableBytes: relative)
                lock.lock()
                storage = .poisoned
                abortRequested = true
                lock.broadcast()
                lock.unlock()
                buffer?.fail("HLS mutable open-stage forward write failed")
                return false
            }
        }

        /// The caller owns a transient-copy receipt for this entire helper. Its nonescaping local payload is
        /// destroyed on return, before the caller releases that receipt and commits durable open ownership.
        private func writeForwardBytes(_ bytes: UnsafePointer<UInt8>, count: Int,
                                       to url: URL, absoluteOffset: Int,
                                       oldDurableEnd: Int,
                                       growthReservationID: UUID) -> Bool {
            let payload = Data(bytes: bytes, count: count)
            return writeForward(
                payload, to: url, absoluteOffset: absoluteOffset,
                oldDurableEnd: oldDurableEnd,
                growthReservationID: growthReservationID)
        }

        fileprivate func poisonAndFail(_ reason: String) {
            lock.lock()
            storage = .poisoned
            lock.broadcast()
            lock.unlock()
            buffer?.fail(reason)
        }

        fileprivate func closeSnapshot(claimID: UUID, base: Int, end: Int)
            -> (storage: Storage, url: URL?)? {
            lock.lock(); defer { lock.unlock() }
            guard activeClaimID == claimID, baseOffset == base,
                  logicalEndOffset == end, !abortRequested,
                  activeClaimReads == 0,
                  storage == .memory || storage == .active else { return nil }
            return (storage, fileURL)
        }

        fileprivate struct CloseToken {
            let id: UUID
            let claimID: UUID
            let oldStorage: Storage
            let oldBase: Int
            let newBase: Int
            let oldEnd: Int
            let nextStorage: Storage
            let nextURL: URL?
        }

        fileprivate func prepareClosedPrefix(claimID: UUID, oldBase: Int,
                                              newBase: Int, oldEnd: Int,
                                              nextStorage: Storage,
                                              nextURL: URL?) -> CloseToken? {
            lock.lock(); defer { lock.unlock() }
            guard activeClaimID == claimID, baseOffset == oldBase,
                  logicalEndOffset == oldEnd, newBase > oldBase, newBase <= oldEnd,
                  storage == .memory || storage == .active,
                  activeClaimReads == 0, closeTokenID == nil else { return nil }
            let token = CloseToken(
                id: UUID(), claimID: claimID, oldStorage: storage,
                oldBase: oldBase, newBase: newBase, oldEnd: oldEnd,
                nextStorage: nextStorage, nextURL: nextURL)
            closeTokenID = token.id
            storage = .promoting
            return token
        }

        /// This is the only post-registry gate. Cancellation is orthogonal to `.promoting`, so it must be
        /// rechecked while the stage lock still protects the token and exact parser claim. A mismatch poisons
        /// the stage and makes the caller invalidate the session; committed files remain owned by cleanup and
        /// are never rolled back after becoming visible in the registry.
        fileprivate func finalizeClosedPrefix(_ token: CloseToken) -> Bool {
            lock.lock()
            guard storage == .promoting, closeTokenID == token.id,
                  activeClaimID == token.claimID, !abortRequested else {
                storage = .poisoned
                activeClaimID = nil
                closeTokenID = nil
                lock.unlock()
                buffer?.fail("HLS mutable open-stage post-registry finalization was aborted")
                return false
            }
            baseOffset = token.newBase
            durableEndOffset = token.nextStorage == .active ? token.oldEnd : token.newBase
            storage = token.nextStorage
            fileURL = token.nextURL
            activeClaimID = nil
            closeTokenID = nil
            lock.unlock()
            return true
        }

        fileprivate func rollbackClosedPrefix(_ token: CloseToken, filesMutated: Bool) {
            lock.lock()
            guard storage == .promoting, closeTokenID == token.id else {
                lock.unlock()
                return
            }
            storage = filesMutated || abortRequested ? .poisoned : token.oldStorage
            closeTokenID = nil
            activeClaimID = nil
            lock.unlock()
        }
    }

    private enum SpoolError: Error {
        case invalidSource
        case injectedWrite
        case injectedDiskFull
        case injectedRename
        case invalidRead
        case invalidLength
        case invalidPermissions
        case injectedFstat
        case injectedMMap
        case injectedPermissions
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

        func sessionCount(parent: URL) -> Int {
            let parentKey = parent.standardizedFileURL.path
            lock.lock(); defer { lock.unlock() }
            return launches[parentKey]?.sessions.count ?? 0
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
    private struct OpenGrowthReservation {
        let logicalBytes: Int
        let physicalBytes: Int
        let residentBackingCapacity: Int?
        let resizeTransientBytes: Int
    }
    private var openGrowthReservations: [UUID: OpenGrowthReservation] = [:]
    private var transientCopyReservations: [UUID: Int] = [:]
    private var playlists: [String: PlaylistState] = [:]
    private var currentAccounting = Accounting()
    private var totalActiveLeases = 0
    private var invalidated = false
    private var listenerRetired = false
    private var producerEnded = false
    private var activeStageOperations = 0
    private var cleanupClaimed = false
    private var registryJoined = true
    private var mutableOpenStage: OpenStage?
    private var cleanupRemovalFailuresRemaining = 0
    private var closeArtifactRemovalFailuresRemaining = 0
    private var quarantinedArtifacts: Set<URL> = []
    private var auxiliaryGeneration = 0
    private var openStageArmReceipt: OpenStageArmReceipt?
    private var fileOperationProbe: ((VortXHLSSessionSpool) -> Void)?
    private var openStageArmAccountingProbe: ((VortXHLSSessionSpool) -> Void)?

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
        if case .cleanupRemove(let failures) = failureInjection {
            self.cleanupRemovalFailuresRemaining = max(0, failures)
        }
        if failureInjection == .openStageMovePermissionCleanupRemoveOnce
            || failureInjection == .openStageActivationCleanupRemoveOnce {
            self.closeArtifactRemovalFailuresRemaining = 1
        }
        self.sessionName = "session-\(sessionID.uuidString)"
        let joined = Self.launchRegistry.join(
            parent: parentDirectory,
            sessionName: self.sessionName,
            requestScavenge: scavengeStaleSessions)
        self.sessionDirectory = joined.launch.appendingPathComponent(self.sessionName, isDirectory: true)
        do {
            try Self.ensureOwnerOnlyDirectory(parentDirectory)
            try Self.ensureOwnerOnlyDirectory(joined.launch)
            try Self.ensureOwnerOnlyDirectory(sessionDirectory)
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
        var removed = !FileManager.default.fileExists(atPath: sessionDirectory.path)
        if !removed, invalidated {
            do {
                try FileManager.default.removeItem(at: sessionDirectory)
                removed = true
            } catch {
                removed = false
            }
        }
        // A normal owner disappearance must leave the in-process registry even though its orphan directory is
        // intentionally left for the next-launch scavenger. An invalidated cleanup that truly failed keeps its
        // registry membership, so another live session cannot scavenge a directory whose ownership is unclear.
        if registryJoined, !invalidated || removed {
            Self.launchRegistry.leave(parent: parentDirectory, sessionName: sessionName)
        }
    }

    static func registeredSessionCount(parentDirectory: URL) -> Int {
        launchRegistry.sessionCount(parent: parentDirectory)
    }

    var accounting: Accounting {
        lock.lock(); defer { lock.unlock() }
        return currentAccounting
    }

    var activeLeaseCount: Int {
        lock.lock(); defer { lock.unlock() }
        return totalActiveLeases
    }

    var activeOpenStageOperationCount: Int {
        lock.lock(); defer { lock.unlock() }
        return activeStageOperations
    }

    var fileNamesOnDisk: [String] {
        (try? FileManager.default.contentsOfDirectory(
            at: sessionDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]).map(\.lastPathComponent).sorted()) ?? []
    }

    var quarantinedFileNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return quarantinedArtifacts.map(\.lastPathComponent).sorted()
    }

    fileprivate var auxiliaryAccountingGeneration: Int {
        lock.lock(); defer { lock.unlock() }
        return auxiliaryGeneration
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

    /// Test seam for proving a rejected repeated arm never reaches coordinator accounting. Like the filesystem
    /// probe, it is copied under the coordinator lock and invoked only after unlock.
    func installOpenStageArmAccountingProbe(
        _ probe: @escaping (VortXHLSSessionSpool) -> Void
    ) {
        lock.lock()
        openStageArmAccountingProbe = probe
        lock.unlock()
    }

    /// Creates exactly one mutable stage for this session and attaches it to the supplied HLS buffer. The
    /// coordinator retains the stage; the buffer's reference is weak. A second attachment is rejected.
    func attachOpenStage(to buffer: VortXRemuxBuffer) -> OpenStage? {
        lock.lock()
        guard !invalidated, mutableOpenStage == nil else {
            lock.unlock()
            return nil
        }
        let stage = OpenStage(owner: self, buffer: buffer)
        mutableOpenStage = stage
        lock.unlock()
        guard buffer.attachOpenStage(stage) else {
            lock.lock()
            if mutableOpenStage === stage { mutableOpenStage = nil }
            lock.unlock()
            return nil
        }
        return stage
    }

    /// Arm-time admission is one coordinator transaction. The stage has already claimed its one-shot `.arming`
    /// state before entering here, and every physical component participates in checked admission.
    fileprivate func armOpenStageAtomically(initialOpenBytes: Int,
                                             residentBackingBytes: Int,
                                             auxiliaryBytes: Int?,
                                             expectedAuxiliaryGeneration: Int?)
        -> OpenStageArmReceipt? {
        guard initialOpenBytes >= 0, residentBackingBytes >= initialOpenBytes else { return nil }
        let probe: ((VortXHLSSessionSpool) -> Void)?
        let receipt: OpenStageArmReceipt
        lock.lock()
        guard !invalidated, openStageArmReceipt == nil,
              expectedAuxiliaryGeneration == nil
                  || expectedAuxiliaryGeneration == auxiliaryGeneration else {
            lock.unlock()
            return nil
        }
        let nextAuxiliary = auxiliaryBytes ?? currentAccounting.auxiliaryBytes
        var projected = currentAccounting
        let (nextOpen, openOverflow) = projected.openBytes.addingReportingOverflow(initialOpenBytes)
        guard nextAuxiliary >= 0, !openOverflow,
              projected.residentLogicalBytes == 0,
              projected.residentBackingBytes == 0 else {
            lock.unlock()
            return nil
        }
        projected.auxiliaryBytes = nextAuxiliary
        projected.openBytes = nextOpen
        projected.residentLogicalBytes = initialOpenBytes
        projected.residentBackingBytes = residentBackingBytes
        guard let physical = projected.checkedPhysicalBytes(), physical <= capacityBytes else {
            lock.unlock()
            return nil
        }
        let nextGeneration: Int
        if auxiliaryBytes != nil {
            let (incremented, overflow) = auxiliaryGeneration.addingReportingOverflow(1)
            guard !overflow else { lock.unlock(); return nil }
            nextGeneration = incremented
        } else {
            nextGeneration = auxiliaryGeneration
        }
        let priorAuxiliary = currentAccounting.auxiliaryBytes
        receipt = OpenStageArmReceipt(
            id: UUID(),
            initialOpenBytes: initialOpenBytes,
            priorAuxiliaryBytes: priorAuxiliary,
            auxiliaryGenerationBefore: auxiliaryGeneration,
            auxiliaryGenerationAfter: nextGeneration,
            priorResidentLogicalBytes: currentAccounting.residentLogicalBytes,
            priorResidentBackingBytes: currentAccounting.residentBackingBytes)
        currentAccounting = projected
        auxiliaryGeneration = nextGeneration
        openStageArmReceipt = receipt
        probe = openStageArmAccountingProbe
        lock.unlock()
        probe?(self)
        return receipt
    }

    /// Extends the same pending arm receipt for RAM bytes that raced its first buffer snapshot. The buffer holds
    /// its producer barrier while this executes, so switching `.arming -> .memory` closes the routing gap.
    fileprivate func extendOpenStageArm(_ receipt: OpenStageArmReceipt,
                                        additionalBytes: Int,
                                        residentBackingBytes: Int) -> OpenStageArmReceipt? {
        guard additionalBytes >= 0, residentBackingBytes >= 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard !invalidated,
              let stored = openStageArmReceipt,
              stored.id == receipt.id else { return nil }
        let (totalOpen, overflow) = stored.initialOpenBytes.addingReportingOverflow(additionalBytes)
        guard !overflow else { return nil }
        var projected = currentAccounting
        let (nextOpen, openOverflow) = projected.openBytes.addingReportingOverflow(additionalBytes)
        let (nextResident, residentOverflow) = projected.residentLogicalBytes
            .addingReportingOverflow(additionalBytes)
        guard !openOverflow, !residentOverflow,
              residentBackingBytes >= nextResident else { return nil }
        projected.openBytes = nextOpen
        projected.residentLogicalBytes = nextResident
        projected.residentBackingBytes = residentBackingBytes
        guard let physical = projected.checkedPhysicalBytes(), physical <= capacityBytes else { return nil }
        let updated = OpenStageArmReceipt(
            id: stored.id,
            initialOpenBytes: totalOpen,
            priorAuxiliaryBytes: stored.priorAuxiliaryBytes,
            auxiliaryGenerationBefore: stored.auxiliaryGenerationBefore,
            auxiliaryGenerationAfter: stored.auxiliaryGenerationAfter,
            priorResidentLogicalBytes: stored.priorResidentLogicalBytes,
            priorResidentBackingBytes: stored.priorResidentBackingBytes)
        currentAccounting = projected
        openStageArmReceipt = updated
        return updated
    }

    fileprivate func refreshOpenStageArmBacking(
        _ receipt: OpenStageArmReceipt,
        residentBackingBytes: Int
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated, openStageArmReceipt?.id == receipt.id,
              residentBackingBytes >= currentAccounting.residentLogicalBytes else { return false }
        var projected = currentAccounting
        projected.residentBackingBytes = residentBackingBytes
        guard let physical = projected.checkedPhysicalBytes(), physical <= capacityBytes else { return false }
        currentAccounting = projected
        return true
    }

    fileprivate func rollbackOpenStageArm(_ receipt: OpenStageArmReceipt,
                                          restoreAuxiliary: Bool) {
        lock.lock()
        if let stored = openStageArmReceipt, stored.id == receipt.id {
            currentAccounting.openBytes = max(
                0, currentAccounting.openBytes - stored.initialOpenBytes)
            currentAccounting.residentLogicalBytes = stored.priorResidentLogicalBytes
            currentAccounting.residentBackingBytes = stored.priorResidentBackingBytes
            if restoreAuxiliary,
               auxiliaryGeneration == stored.auxiliaryGenerationAfter {
                let (nextGeneration, overflow) = auxiliaryGeneration.addingReportingOverflow(1)
                if !overflow {
                    currentAccounting.auxiliaryBytes = stored.priorAuxiliaryBytes
                    auxiliaryGeneration = nextGeneration
                }
            }
            openStageArmReceipt = nil
        }
        lock.unlock()
    }

    fileprivate func completeOpenStageArm(_ receipt: OpenStageArmReceipt) {
        lock.lock()
        if openStageArmReceipt?.id == receipt.id {
            openStageArmReceipt = nil
        }
        lock.unlock()
    }

    fileprivate func reserveOpenGrowth(id: UUID,
                                       logicalBytes: Int,
                                       residentBackingCapacityBefore: Int?,
                                       residentBackingCapacityAfter: Int?) -> Bool {
        guard logicalBytes > 0,
              (residentBackingCapacityBefore == nil) == (residentBackingCapacityAfter == nil) else {
            return false
        }
        let physicalBytes: Int
        let resizeTransientBytes: Int
        if let before = residentBackingCapacityBefore,
           let after = residentBackingCapacityAfter {
            guard before >= 0, after >= before else { return false }
            physicalBytes = after - before
            resizeTransientBytes = after > before ? before : 0
        } else {
            physicalBytes = logicalBytes
            resizeTransientBytes = 0
        }
        lock.lock(); defer { lock.unlock() }
        guard let physical = currentAccounting.checkedPhysicalBytes(),
              !invalidated, reservations[id] == nil,
              openGrowthReservations[id] == nil,
              transientCopyReservations[id] == nil,
              physical <= capacityBytes,
              physicalBytes <= capacityBytes - physical,
              resizeTransientBytes <= capacityBytes - physical - physicalBytes else { return false }
        reservations[id] = physicalBytes
        openGrowthReservations[id] = OpenGrowthReservation(
            logicalBytes: logicalBytes,
            physicalBytes: physicalBytes,
            residentBackingCapacity: residentBackingCapacityAfter,
            resizeTransientBytes: resizeTransientBytes)
        transientCopyReservations[id] = resizeTransientBytes
        currentAccounting.reservedBytes += physicalBytes
        currentAccounting.transientCopyBytes += resizeTransientBytes
        currentAccounting.peakReservedBytes = max(
            currentAccounting.peakReservedBytes, currentAccounting.reservedBytes)
        currentAccounting.peakTransientCopyBytes = max(
            currentAccounting.peakTransientCopyBytes, currentAccounting.transientCopyBytes)
        return true
    }

    fileprivate func commitOpenGrowth(id: UUID, bytes: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let reservation = openGrowthReservations[id],
              reservation.logicalBytes == bytes,
              reservations[id] == reservation.physicalBytes else { return false }
        reservations.removeValue(forKey: id)
        currentAccounting.reservedBytes -= reservation.physicalBytes
        currentAccounting.openBytes += bytes
        if let capacity = reservation.residentBackingCapacity {
            currentAccounting.residentLogicalBytes += bytes
            currentAccounting.residentBackingBytes = capacity
        }
        return true
    }

    fileprivate func completeOpenGrowth(id: UUID) {
        let cleanup: URL?
        lock.lock()
        openGrowthReservations.removeValue(forKey: id)
        if let bytes = transientCopyReservations.removeValue(forKey: id) {
            currentAccounting.transientCopyBytes -= bytes
        }
        cleanup = claimCleanupIfReadyLocked()
        lock.unlock()
        if let cleanup { performCleanup(cleanup) }
    }

    fileprivate func releaseOpenGrowth(id: UUID) {
        let cleanup: URL?
        lock.lock()
        if let bytes = reservations.removeValue(forKey: id) {
            currentAccounting.reservedBytes -= bytes
        }
        openGrowthReservations.removeValue(forKey: id)
        if let bytes = transientCopyReservations.removeValue(forKey: id) {
            currentAccounting.transientCopyBytes -= bytes
        }
        cleanup = claimCleanupIfReadyLocked()
        lock.unlock()
        if let cleanup { performCleanup(cleanup) }
    }

    /// A failed rollback may leave bytes appended to the live stage file. Resolve their exact surviving length,
    /// transfer it from the growth reservation into quarantine, and permanently close admission before the
    /// caller releases any transient payload copy.
    fileprivate func quarantineFailedOpenForward(id: UUID,
                                                 url: URL,
                                                 oldDurableBytes: Int) {
        let observedValues = try? url.resourceValues(forKeys: [.fileSizeKey])
        let cleanup: URL?
        lock.lock()
        let reservedLogicalBytes = openGrowthReservations[id]?.logicalBytes ?? 0
        let surviving = observedValues?.fileSize.map {
            max(0, $0 - max(0, oldDurableBytes))
        } ?? reservedLogicalBytes
        if let reserved = reservations.removeValue(forKey: id) {
            currentAccounting.reservedBytes -= reserved
        }
        openGrowthReservations.removeValue(forKey: id)
        if let resize = transientCopyReservations.removeValue(forKey: id) {
            currentAccounting.transientCopyBytes -= resize
        }
        let (nextQuarantine, overflow) = currentAccounting.quarantinedBytes
            .addingReportingOverflow(surviving)
        currentAccounting.quarantinedBytes = overflow ? Int.max : nextQuarantine
        if FileManager.default.fileExists(atPath: url.path) {
            quarantinedArtifacts.insert(url)
        }
        invalidated = true
        cleanup = claimCleanupIfReadyLocked()
        lock.unlock()
        if let cleanup { performCleanup(cleanup) }
    }

    /// Reserves physical headroom for a copy that duplicates bytes already counted in admitted ownership.
    /// The reservation remains live until the caller proves that the source backing has been reclaimed.
    fileprivate func reserveTransientCopy(id: UUID, bytes: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let physical = currentAccounting.checkedPhysicalBytes(),
              !invalidated, reservations[id] == nil,
              transientCopyReservations[id] == nil,
              bytes >= 0, physical <= capacityBytes,
              bytes <= capacityBytes - physical else { return false }
        transientCopyReservations[id] = bytes
        currentAccounting.transientCopyBytes += bytes
        currentAccounting.peakTransientCopyBytes = max(
            currentAccounting.peakTransientCopyBytes, currentAccounting.transientCopyBytes)
        return true
    }

    fileprivate func releaseTransientCopy(id: UUID) {
        let cleanup: URL?
        lock.lock()
        if let bytes = transientCopyReservations.removeValue(forKey: id) {
            currentAccounting.transientCopyBytes -= bytes
        }
        cleanup = claimCleanupIfReadyLocked()
        lock.unlock()
        if let cleanup { performCleanup(cleanup) }
    }

    fileprivate func commitResidentBackingTransition(
        _ transition: VortXRemuxBuffer.ResidentBackingTransition,
        residentLogicalBytes: Int,
        releasingTransientID: UUID?
    ) -> Bool {
        let cleanup: URL?
        lock.lock()
        guard !invalidated,
              currentAccounting.residentBackingBytes == transition.oldCapacityBytes,
              residentLogicalBytes == transition.remainingLogicalBytes,
              residentLogicalBytes >= 0,
              residentLogicalBytes <= currentAccounting.openBytes else {
            lock.unlock()
            return false
        }
        var nextAccounting = currentAccounting
        nextAccounting.residentBackingBytes = transition.newCapacityBytes
        nextAccounting.residentLogicalBytes = residentLogicalBytes
        var releasedTransientID: UUID?
        if let id = releasingTransientID,
           let bytes = transientCopyReservations[id] {
            nextAccounting.transientCopyBytes -= bytes
            releasedTransientID = id
        }
        guard nextAccounting.checkedPhysicalBytes() != nil else {
            lock.unlock()
            return false
        }
        if let releasedTransientID {
            transientCopyReservations.removeValue(forKey: releasedTransientID)
        }
        currentAccounting = nextAccounting
        cleanup = claimCleanupIfReadyLocked()
        lock.unlock()
        if let cleanup { performCleanup(cleanup) }
        return true
    }

    fileprivate func beginStageOperation() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated, !cleanupClaimed else { return false }
        activeStageOperations += 1
        return true
    }

    fileprivate func endStageOperation() {
        let cleanup: URL?
        lock.lock()
        activeStageOperations = max(0, activeStageOperations - 1)
        cleanup = claimCleanupIfReadyLocked()
        lock.unlock()
        if let cleanup { performCleanup(cleanup) }
    }

    fileprivate func writeOpenStageForward(_ data: Data, to handle: FileHandle) throws -> Int {
        guard case .openStageForwardWrite(let afterBytes, _) = failureInjection else {
            try handle.write(contentsOf: data)
            return data.count
        }
        let amount = min(max(0, afterBytes), data.count)
        if amount > 0 { try handle.write(contentsOf: data.prefix(amount)) }
        return amount
    }

    /// Transactionally promotes an exact parser claim. The RAM path streams only P under a lease. The active
    /// path copies only S, then truncates/renames the original P. Neither path advances the stage until every
    /// cohort file and the coordinator registry are committed.
    fileprivate func closeOpenStagePrefix(
        stage: OpenStage,
        claimID: UUID,
        claimedBase: Int,
        claimedEnd: Int,
        endOffset: Int,
        key: ResourceKey,
        durationMilliseconds: Int,
        additionalResources: [SpillResource]
    ) -> Bool {
        guard durationMilliseconds > 0,
              endOffset > claimedBase, endOffset <= claimedEnd,
              let buffer = stage.buffer,
              let stageState = stage.closeSnapshot(
                  claimID: claimID, base: claimedBase, end: claimedEnd) else { return false }
        let prefixBytes = endOffset - claimedBase
        let suffixBytes = claimedEnd - endOffset
        let additionalBytes = validate(resources: additionalResources) ?? (additionalResources.isEmpty ? 0 : -1)
        guard additionalBytes >= 0 else { return false }
        let keys = [key] + additionalResources.map(\.key)
        guard Set(keys).count == keys.count else { return false }
        let reservationID = UUID()
        let reclaimedBackingCapacity = stageState.storage == .memory
            ? buffer.projectedBackingCapacityAfterReclaim(before: endOffset) : nil
        guard stageState.storage != .memory || reclaimedBackingCapacity != nil else { return false }
        let transientBytes: Int
        if stageState.storage == .active {
            transientBytes = suffixBytes
        } else {
            let (combined, overflow) = prefixBytes.addingReportingOverflow(
                reclaimedBackingCapacity ?? 0)
            guard !overflow else { return false }
            transientBytes = combined
        }
        guard reserveOpenClose(
            id: reservationID, keys: keys,
            uncoveredBytes: additionalBytes, transientBytes: transientBytes) else { return false }

        var sourceLeases: [VortXRemuxBuffer.ReadLease] = []
        if stageState.storage == .memory {
            guard let lease = buffer.beginReadLease(offset: claimedBase, length: prefixBytes) else {
                releaseOpenClose(
                    id: reservationID, keys: keys)
                return false
            }
            sourceLeases.append(lease)
        }
        for resource in additionalResources {
            if case .buffer(let source, let offset, let length) = resource.payload {
                guard let lease = source.beginReadLease(offset: offset, length: length) else {
                    releaseOpenClose(
                        id: reservationID, keys: keys)
                    return false
                }
                sourceLeases.append(lease)
            }
        }

        guard beginStageOperation() else {
            releaseOpenClose(id: reservationID, keys: keys)
            return false
        }
        defer { endStageOperation() }

        struct CloseFile {
            let resource: SpillResource?
            let part: URL
            let final: URL
            let length: Int
        }
        let operation = UUID().uuidString
        let videoFinal = sessionDirectory.appendingPathComponent(key.fileName)
        let videoPart = sessionDirectory.appendingPathComponent("\(key.fileName).\(operation).part")
        let otherFiles = additionalResources.map { resource in
            CloseFile(
                resource: resource,
                part: sessionDirectory.appendingPathComponent(
                    "\(resource.key.fileName).\(operation).part"),
                final: sessionDirectory.appendingPathComponent(resource.key.fileName),
                length: resource.length)
        }
        let suffixPart = sessionDirectory.appendingPathComponent("open-\(operation).part")
        let suffixFinal = sessionDirectory.appendingPathComponent("open-\(operation).stage")
        var createdURLs: [URL] = []
        var finalURLs: [URL] = []
        var movedCount = 0
        var stageFilesMutated = false
        var closeToken: OpenStage.CloseToken?
        do {
            if stageState.storage == .memory {
                try createOwnerOnlyFile(videoPart, cleanupReceipts: &createdURLs)
                let handle = try FileHandle(forWritingTo: videoPart)
                do {
                    var copied = 0
                    while copied < prefixBytes {
                        let count = min(chunkSize, prefixBytes - copied)
                        guard let chunk = buffer.snapshotChunk(
                            offset: claimedBase + copied, length: count) else {
                            throw SpoolError.invalidSource
                        }
                        notifyFileOperation()
                        try handle.write(contentsOf: chunk)
                        copied += chunk.count
                    }
                    try handle.synchronize()
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
                try requireFileSize(videoPart, prefixBytes)
            } else {
                guard let activeURL = stageState.url else { throw SpoolError.invalidSource }
                if suffixBytes > 0 {
                    try createOwnerOnlyFile(suffixPart, cleanupReceipts: &createdURLs)
                    let source = try FileHandle(forReadingFrom: activeURL)
                    let destination = try FileHandle(forWritingTo: suffixPart)
                    do {
                        try source.seek(toOffset: UInt64(prefixBytes))
                        var copied = 0
                        while copied < suffixBytes {
                            notifyFileOperation()
                            let part = try source.read(upToCount: min(chunkSize, suffixBytes - copied)) ?? Data()
                            guard !part.isEmpty else { throw SpoolError.invalidSource }
                            try destination.write(contentsOf: part)
                            copied += part.count
                        }
                        try destination.synchronize()
                        try source.close()
                        try destination.close()
                    } catch {
                        try? source.close()
                        try? destination.close()
                        throw error
                    }
                    try requireFileSize(suffixPart, suffixBytes)
                }
            }

            for file in otherFiles {
                try createOwnerOnlyFile(file.part, cleanupReceipts: &createdURLs)
                guard let resource = file.resource else { throw SpoolError.invalidSource }
                let handle = try FileHandle(forWritingTo: file.part)
                do {
                    var copied = 0
                    while copied < file.length {
                        let count = min(chunkSize, file.length - copied)
                        guard let bytes = chunk(for: resource, localOffset: copied, length: count) else {
                            throw SpoolError.invalidSource
                        }
                        notifyFileOperation()
                        try handle.write(contentsOf: bytes)
                        copied += bytes.count
                    }
                    try handle.synchronize()
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
                try requireFileSize(file.part, file.length)
            }

            if stageState.storage == .active {
                guard let activeURL = stageState.url else { throw SpoolError.invalidSource }
                notifyFileOperation()
                let handle = try FileHandle(forWritingTo: activeURL)
                try handle.truncate(atOffset: UInt64(prefixBytes))
                try handle.synchronize()
                try handle.close()
                try requireFileSize(activeURL, prefixBytes)
                stageFilesMutated = true
                try moveForClose(
                    activeURL, to: videoFinal,
                    successfulMoves: &movedCount,
                    cleanupReceipts: &finalURLs)
            } else {
                try moveForClose(
                    videoPart, to: videoFinal,
                    successfulMoves: &movedCount,
                    cleanupReceipts: &finalURLs)
            }

            var nextStageURL: URL?
            if stageState.storage == .active, suffixBytes > 0 {
                try moveForClose(
                    suffixPart, to: suffixFinal,
                    successfulMoves: &movedCount,
                    cleanupReceipts: &finalURLs)
                nextStageURL = suffixFinal
            }
            for file in otherFiles {
                try moveForClose(
                    file.part, to: file.final,
                    successfulMoves: &movedCount,
                    cleanupReceipts: &finalURLs)
            }

            let registered: [(ResourceKey, URL, Int, Int)] = [
                (key, videoFinal, prefixBytes, durationMilliseconds),
            ] + zip(additionalResources, otherFiles).map { resource, file in
                (resource.key, file.final, resource.length, resource.durationMilliseconds)
            }
            let nextStorage: OpenStage.Storage = stageState.storage == .active && suffixBytes > 0
                ? .active : .memory
            guard let prepared = stage.prepareClosedPrefix(
                claimID: claimID, oldBase: claimedBase, newBase: endOffset,
                oldEnd: claimedEnd, nextStorage: nextStorage, nextURL: nextStageURL) else {
                throw SpoolError.invalidSource
            }
            closeToken = prepared
            if failureInjection == .openStageCancelBeforeRegistry {
                invalidateSession()
            }
            guard commitOpenClose(
                id: reservationID,
                registered: registered,
                prefixBytes: prefixBytes,
                uncoveredBytes: additionalBytes,
                transientBytes: transientBytes,
                residentLogicalBytes: stageState.storage == .memory ? suffixBytes : nil) else {
                throw SpoolError.invalidSource
            }
            if failureInjection == .openStageCancelAfterRegistry {
                invalidateSession()
            }
            guard stage.finalizeClosedPrefix(prepared) else {
                // Registry publication already committed. Ownership now belongs to invalidation cleanup; do
                // not delete files or rewrite accounting through the pre-commit rollback path.
                closeToken = nil
                sourceLeases.removeAll()
                releaseOpenClose(id: reservationID, keys: [])
                invalidateSession()
                return false
            }
            closeToken = nil
            sourceLeases.removeAll()
            if stageState.storage == .memory {
                guard let admittedCapacity = reclaimedBackingCapacity,
                      let transition = buffer.reclaimDurablyBackedPrefix(
                          before: endOffset,
                          admittedCapacity: admittedCapacity),
                      commitResidentBackingTransition(
                          transition,
                          residentLogicalBytes: suffixBytes,
                          releasingTransientID: reservationID) else {
                    stage.poisonAndFail("HLS open-stage promotion could not reclaim RAM backing")
                    invalidateSession()
                    releaseOpenClose(id: reservationID, keys: [])
                    return false
                }
            }
            releaseOpenClose(id: reservationID, keys: [])
            return true
        } catch {
            let cleanupComplete = removeCloseArtifacts(createdURLs + finalURLs)
            if cleanupComplete {
                releaseOpenClose(id: reservationID, keys: keys)
            } else {
                quarantineOpenClose(
                    stage: stage,
                    id: reservationID,
                    keys: keys,
                    receipts: createdURLs + finalURLs)
            }
            if let closeToken {
                stage.rollbackClosedPrefix(closeToken, filesMutated: stageFilesMutated)
            } else if stageState.storage == .active {
                stage.poisonAndFail("HLS open-stage promotion failed")
            }
            withExtendedLifetime(sourceLeases) {}
            return false
        }
    }

    private func reserveOpenClose(id: UUID, keys: [ResourceKey],
                                  uncoveredBytes: Int, transientBytes: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let keySet = Set(keys)
        guard let physical = currentAccounting.checkedPhysicalBytes(),
              !invalidated, reservations[id] == nil,
              transientCopyReservations[id] == nil,
              keySet.isDisjoint(with: pendingKeys),
              keySet.allSatisfy({ entries[$0] == nil }),
              uncoveredBytes >= 0, transientBytes >= 0,
              physical <= capacityBytes,
              uncoveredBytes <= capacityBytes - physical,
              transientBytes <= capacityBytes - physical - uncoveredBytes else { return false }
        reservations[id] = uncoveredBytes
        transientCopyReservations[id] = transientBytes
        pendingKeys.formUnion(keySet)
        currentAccounting.reservedBytes += uncoveredBytes
        currentAccounting.transientCopyBytes += transientBytes
        currentAccounting.peakReservedBytes = max(
            currentAccounting.peakReservedBytes, currentAccounting.reservedBytes)
        currentAccounting.peakTransientCopyBytes = max(
            currentAccounting.peakTransientCopyBytes, currentAccounting.transientCopyBytes)
        return true
    }

    private func commitOpenClose(id: UUID,
                                 registered: [(ResourceKey, URL, Int, Int)],
                                 prefixBytes: Int,
                                 uncoveredBytes: Int,
                                 transientBytes: Int,
                                 residentLogicalBytes: Int?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let postCommitTransientBytes: Int
        if residentLogicalBytes != nil {
            guard transientBytes >= prefixBytes else { return false }
            postCommitTransientBytes = transientBytes - prefixBytes
        } else {
            postCommitTransientBytes = transientBytes
        }
        guard !invalidated, reservations[id] == uncoveredBytes,
              transientCopyReservations[id] == transientBytes,
              currentAccounting.openBytes >= prefixBytes,
              residentLogicalBytes == nil
                  || (residentLogicalBytes! >= 0
                      && residentLogicalBytes! <= currentAccounting.openBytes - prefixBytes),
              registered.allSatisfy({ entries[$0.0] == nil }) else { return false }
        for (key, url, length, duration) in registered {
            entries[key] = Entry(
                url: url, length: length,
                segmentDurationMilliseconds: duration)
        }
        reservations.removeValue(forKey: id)
        pendingKeys.subtract(registered.map { $0.0 })
        currentAccounting.reservedBytes -= uncoveredBytes
        currentAccounting.openBytes -= prefixBytes
        transientCopyReservations[id] = postCommitTransientBytes
        currentAccounting.transientCopyBytes -= transientBytes - postCommitTransientBytes
        if let residentLogicalBytes {
            currentAccounting.residentLogicalBytes = residentLogicalBytes
        }
        currentAccounting.finalBytes += registered.reduce(0) { $0 + $1.2 }
        return true
    }

    private func releaseOpenClose(id: UUID, keys: [ResourceKey]) {
        let cleanup: URL?
        lock.lock()
        if let bytes = reservations.removeValue(forKey: id) {
            currentAccounting.reservedBytes -= bytes
        }
        if let bytes = transientCopyReservations.removeValue(forKey: id) {
            currentAccounting.transientCopyBytes -= bytes
        }
        pendingKeys.subtract(keys)
        cleanup = claimCleanupIfReadyLocked()
        lock.unlock()
        if let cleanup { performCleanup(cleanup) }
    }

    /// Attempts every post-effect receipt. A failed first removal never short-circuits later receipts, and a
    /// path counts as removed only after the filesystem confirms it no longer exists.
    private func removeCloseArtifacts(_ urls: [URL]) -> Bool {
        var allRemoved = true
        var attempted: Set<URL> = []
        for url in urls where attempted.insert(url).inserted {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let injectFailure: Bool
            lock.lock()
            injectFailure = closeArtifactRemovalFailuresRemaining > 0
            if injectFailure { closeArtifactRemovalFailuresRemaining -= 1 }
            lock.unlock()
            if !injectFailure {
                notifyFileOperation()
                try? FileManager.default.removeItem(at: url)
            }
            if FileManager.default.fileExists(atPath: url.path) { allRemoved = false }
        }
        return allRemoved
    }

    /// Converts a failed close rollback into session-owned quarantine. Reservation and transient charges move
    /// rather than disappear, later admissions fail through invalidation, and only confirmed directory removal
    /// clears the quarantine accounting and retained receipts.
    private func quarantineOpenClose(stage: OpenStage,
                                     id: UUID,
                                     keys: [ResourceKey],
                                     receipts: [URL]) {
        stage.requestAbort()
        let surviving = Set(receipts.filter {
            FileManager.default.fileExists(atPath: $0.path)
        })
        let cleanup: URL?
        lock.lock()
        let reserved = reservations.removeValue(forKey: id) ?? 0
        currentAccounting.reservedBytes = max(0, currentAccounting.reservedBytes - reserved)
        let retainedTransient = transientCopyReservations.removeValue(forKey: id) ?? 0
        currentAccounting.transientCopyBytes -= retainedTransient
        let (quarantineCharge, chargeOverflow) = reserved.addingReportingOverflow(retainedTransient)
        let (nextQuarantine, quarantineOverflow) = currentAccounting.quarantinedBytes
            .addingReportingOverflow(chargeOverflow ? Int.max : quarantineCharge)
        currentAccounting.quarantinedBytes = quarantineOverflow ? Int.max : nextQuarantine
        pendingKeys.subtract(keys)
        quarantinedArtifacts.formUnion(surviving)
        invalidated = true
        cleanup = claimCleanupIfReadyLocked()
        lock.unlock()
        if let cleanup { performCleanup(cleanup) }
    }

    private func createOwnerOnlyFile(_ url: URL,
                                     cleanupReceipts: inout [URL]) throws {
        notifyFileOperation()
        guard FileManager.default.createFile(
            atPath: url.path, contents: nil,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
            throw SpoolError.invalidSource
        }
        cleanupReceipts.append(url)
        if failureInjection == .openStageCreatePermission {
            throw SpoolError.injectedPermissions
        }
        try Self.ensureOwnerOnlyFile(url)
    }

    private func requireFileSize(_ url: URL, _ expected: Int) throws {
        notifyFileOperation()
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard values.fileSize == expected else { throw SpoolError.invalidLength }
    }

    private func moveForClose(_ source: URL, to destination: URL,
                              successfulMoves: inout Int,
                              cleanupReceipts: inout [URL]) throws {
        if case .rename(let allowedMoves) = failureInjection,
           successfulMoves >= max(0, allowedMoves) {
            throw SpoolError.injectedRename
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SpoolError.injectedRename
        }
        notifyFileOperation()
        try FileManager.default.moveItem(at: source, to: destination)
        cleanupReceipts.append(destination)
        if failureInjection == .openStageMovePermission
            || failureInjection == .openStageMovePermissionCleanupRemoveOnce {
            throw SpoolError.injectedPermissions
        }
        try Self.ensureOwnerOnlyFile(destination)
        successfulMoves += 1
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
                guard FileManager.default.createFile(
                    atPath: item.partURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
                    throw SpoolError.invalidSource
                }
                try Self.ensureOwnerOnlyFile(item.partURL)
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
                try Self.ensureOwnerOnlyFile(item.finalURL)
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
        setAuxiliaryBytesChecked(bytes, expectedGeneration: nil) != nil
    }

    /// Versioned compare-and-set used by the three-component auxiliary ledger. A stale writer cannot overwrite
    /// a newer primary/audio/subtitle total even when its arithmetic was valid when first computed.
    fileprivate func setAuxiliaryBytes(_ bytes: Int,
                                       expectedGeneration: Int) -> Int? {
        setAuxiliaryBytesChecked(bytes, expectedGeneration: expectedGeneration)
    }

    private func setAuxiliaryBytesChecked(_ bytes: Int,
                                          expectedGeneration: Int?) -> Int? {
        guard bytes >= 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard !invalidated,
              expectedGeneration == nil || expectedGeneration == auxiliaryGeneration,
              let withoutOld = currentAccounting.checkedPhysicalBytes(
                  replacingAuxiliaryWith: 0),
              withoutOld <= capacityBytes,
              bytes <= capacityBytes - withoutOld else { return nil }
        let (nextGeneration, overflow) = auxiliaryGeneration.addingReportingOverflow(1)
        guard !overflow else { return nil }
        currentAccounting.auxiliaryBytes = bytes
        auxiliaryGeneration = nextGeneration
        return nextGeneration
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

    func producerDidReachEOF() { producerDidTerminate() }

    func producerDidTerminate() {
        let cleanup: URL?
        lock.lock()
        producerEnded = true
        cleanup = claimCleanupIfReadyLocked()
        lock.unlock()
        if let cleanup { performCleanup(cleanup) }
    }

    func invalidateSession() {
        lock.lock()
        let stage = mutableOpenStage
        lock.unlock()
        stage?.requestAbort()
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
        guard let physical = currentAccounting.checkedPhysicalBytes(),
              !invalidated,
              keys.isDisjoint(with: pendingKeys),
              keys.allSatisfy({ entries[$0] == nil }),
              physical <= capacityBytes,
              bytes <= capacityBytes - physical else { return false }
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
        guard invalidated, producerEnded, listenerRetired,
              totalActiveLeases == 0, reservations.isEmpty,
              transientCopyReservations.isEmpty,
              activeStageOperations == 0, !cleanupClaimed else { return nil }
        cleanupClaimed = true
        return sessionDirectory
    }

    private func performCleanup(_ directory: URL) {
        let injectFailure: Bool
        lock.lock()
        injectFailure = cleanupRemovalFailuresRemaining > 0
        if injectFailure { cleanupRemovalFailuresRemaining -= 1 }
        lock.unlock()
        var removed = false
        if !injectFailure {
            do {
                try FileManager.default.removeItem(at: directory)
                removed = true
            } catch {
                removed = !FileManager.default.fileExists(atPath: directory.path)
            }
        }
        lock.lock()
        if !removed { cleanupClaimed = false }
        let shouldLeave = removed && registryJoined
        if removed {
            registryJoined = false
            entries.removeAll()
            playlists.removeAll()
            pendingKeys.removeAll()
            reservations.removeAll()
            transientCopyReservations.removeAll()
            openStageArmReceipt = nil
            mutableOpenStage = nil
            quarantinedArtifacts.removeAll()
            currentAccounting.finalBytes = 0
            currentAccounting.temporaryBytes = 0
            currentAccounting.reservedBytes = 0
            currentAccounting.auxiliaryBytes = 0
            currentAccounting.openBytes = 0
            currentAccounting.transientCopyBytes = 0
            currentAccounting.quarantinedBytes = 0
        }
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

    private static func ensureOwnerOnlyDirectory(_ url: URL) throws {
        let permissions = NSNumber(value: 0o700)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: permissions])
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions], ofItemAtPath: url.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let actual = attributes[.posixPermissions] as? NSNumber,
              actual.intValue & 0o777 == 0o700 else {
            throw SpoolError.invalidPermissions
        }
    }

    private static func ensureOwnerOnlyFile(_ url: URL) throws {
        let permissions = NSNumber(value: 0o600)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions], ofItemAtPath: url.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let actual = attributes[.posixPermissions] as? NSNumber,
              actual.intValue & 0o777 == 0o600 else {
            throw SpoolError.invalidPermissions
        }
    }
}

/// One versioned owner for the three non-file HLS components. Coordinator compare-and-set and local component
/// publication happen under this short lock; mutable-stage filesystem activation always happens after unlock.
final class VortXHLSAuxiliaryAccounting: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let primaryInitBytes: Int
        let alternateAudioInitBytes: Int
        let subtitleBytes: Int
        let generation: Int
    }

    private weak var spool: VortXHLSSessionSpool?
    private let lock = NSLock()
    private var primaryInitBytes = 0
    private var alternateAudioInitBytes = 0
    private var subtitleBytes = 0
    private var generation: Int

    init(spool: VortXHLSSessionSpool) {
        self.spool = spool
        self.generation = spool.auxiliaryAccountingGeneration
    }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            primaryInitBytes: primaryInitBytes,
            alternateAudioInitBytes: alternateAudioInitBytes,
            subtitleBytes: subtitleBytes,
            generation: generation)
    }

    @discardableResult
    func update(primaryInit: Int? = nil,
                alternateAudioInit: Int? = nil,
                subtitles: Int? = nil) -> Bool {
        guard let spool else { return false }
        lock.lock(); defer { lock.unlock() }
        let nextPrimary = primaryInit ?? primaryInitBytes
        let nextAudio = alternateAudioInit ?? alternateAudioInitBytes
        let nextSubtitles = subtitles ?? subtitleBytes
        guard nextPrimary >= 0, nextAudio >= 0, nextSubtitles >= 0 else { return false }
        let (initTotal, initOverflow) = nextPrimary.addingReportingOverflow(nextAudio)
        let (total, totalOverflow) = initTotal.addingReportingOverflow(nextSubtitles)
        guard !initOverflow, !totalOverflow,
              let nextGeneration = spool.setAuxiliaryBytes(
                  total, expectedGeneration: generation) else { return false }
        primaryInitBytes = nextPrimary
        alternateAudioInitBytes = nextAudio
        subtitleBytes = nextSubtitles
        generation = nextGeneration
        return true
    }

    @discardableResult
    func omitAlternateAudioInitOnTimeout() -> Bool {
        update(alternateAudioInit: 0)
    }

    /// The coordinator charge and all three local components are published as one version while the lock is
    /// held. `finishArm` then reconciles racing RAM appends and performs any filesystem activation after unlock.
    @discardableResult
    func armPrimary(stage: VortXHLSSessionSpool.OpenStage,
                    base: Int,
                    primaryInitBytes nextPrimary: Int) -> Bool {
        guard nextPrimary >= 0 else { return false }
        lock.lock()
        let priorPrimary = primaryInitBytes
        let (initTotal, initOverflow) = nextPrimary.addingReportingOverflow(
            alternateAudioInitBytes)
        let (total, totalOverflow) = initTotal.addingReportingOverflow(subtitleBytes)
        guard !initOverflow, !totalOverflow,
              let preparation = stage.prepareArm(
                  base: base,
                  auxiliaryBytes: total,
                  expectedAuxiliaryGeneration: generation) else {
            lock.unlock()
            return false
        }
        primaryInitBytes = nextPrimary
        generation = preparation.auxiliaryGeneration
        lock.unlock()

        guard stage.finishArm(preparation, restoreAuxiliaryOnFailure: false) else {
            // The stage has already removed its open-byte receipt. A fresh versioned reduction preserves any
            // audio/subtitle update that won while filesystem activation was in flight.
            _ = update(primaryInit: priorPrimary)
            return false
        }
        return true
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
