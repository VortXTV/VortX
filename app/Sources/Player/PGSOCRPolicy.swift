import Foundation

enum PGSOCRPolicy {
    static let overrideKey = "vortx.pgsSubtitleOCR"
    static let maximumOutstandingItems = 8
    static let maximumOutstandingBytes = 32 << 20
    static let maximumBitmapsPerItem = 64
    static let maximumBitmapBytesPerItem = 8 << 20
    static let recognitionDeadlineSeconds: TimeInterval = 0.6
    static let maximumBitmapPixels = 16 << 20
    static let maximumBitmapEdge = 8_192

    /// The production path is safe to default on because Vision never runs on the remux producer, admission
    /// is bounded, and an explicit false remains a fleet escape hatch.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: overrideKey) != nil else { return true }
        return defaults.bool(forKey: overrideKey)
    }

    static func acceptsPacketRectangleCount(_ count: Int) -> Bool {
        count > 0 && count <= maximumBitmapsPerItem
    }

    static func canAppendBitmap(existingCount: Int,
                                existingBytes: Int,
                                nextBytes: Int) -> Bool {
        guard existingCount >= 0,
              existingCount < maximumBitmapsPerItem,
              existingBytes >= 0,
              existingBytes <= maximumBitmapBytesPerItem,
              nextBytes > 0 else { return false }
        let (total, overflow) = existingBytes.addingReportingOverflow(nextBytes)
        return !overflow && total <= maximumBitmapBytesPerItem
    }

    static func cueTiming(packetStartSeconds: Double,
                          packetDurationSeconds: Double,
                          displayStartMilliseconds: UInt32,
                          displayEndMilliseconds: UInt32) -> (start: Double, duration: Double)? {
        guard packetStartSeconds.isFinite, packetStartSeconds >= 0 else { return nil }
        let displayStart = Double(displayStartMilliseconds) / 1_000
        let start = packetStartSeconds + displayStart
        guard start.isFinite else { return nil }

        let duration: Double
        if displayEndMilliseconds > displayStartMilliseconds {
            duration = Double(displayEndMilliseconds - displayStartMilliseconds) / 1_000
        } else {
            duration = packetDurationSeconds
        }
        guard duration.isFinite else { return nil }
        return (start, duration)
    }
}

struct PGSOCRBitmap: Equatable, Sendable {
    let width: Int
    let height: Int
    let indices: Data
    let paletteBGRA: Data

    var byteCount: Int {
        let (sum, overflow) = indices.count.addingReportingOverflow(paletteBGRA.count)
        return overflow ? Int.max : sum
    }
}

struct PGSOCRWorkItem: Equatable, Sendable {
    let token: UInt64
    let epoch: UInt64
    let sourceIndex: Int
    let renditionID: Int
    let startSeconds: Double
    let durationSeconds: Double
    let deadlineUptime: TimeInterval
    let bitmaps: [PGSOCRBitmap]

    var byteCount: Int {
        bitmaps.reduce(into: 0) { total, bitmap in
            let (next, overflow) = total.addingReportingOverflow(bitmap.byteCount)
            total = overflow ? Int.max : next
        }
    }
}

enum PGSOCRRecognizerResult: Equatable, Sendable {
    case text(String)
    case empty
    case failed
}

enum PGSOCRCompletionOutcome: Equatable, Sendable {
    case text(String)
    case empty
    case failed
    case timedOut
}

struct PGSOCRCompletion: Equatable, Sendable {
    let token: UInt64
    let epoch: UInt64
    let sourceIndex: Int
    let renditionID: Int
    let startSeconds: Double
    let durationSeconds: Double
    let outcome: PGSOCRCompletionOutcome
}

enum PGSOCRCompletionPolicy {
    static func accepts(_ completion: PGSOCRCompletion,
                        activeEpoch: UInt64,
                        tokenIsPending: Bool,
                        generationIsActive: Bool) -> Bool {
        generationIsActive && completion.epoch == activeEpoch && tokenIsPending
    }
}

struct PGSOCRSubmission: Equatable, Sendable {
    let accepted: Bool
    let droppedTokens: [UInt64]
}

struct PGSOCRQueueSnapshot: Equatable, Sendable {
    let queuedItems: Int
    let queuedBytes: Int
    let inFlightItems: Int
    let inFlightBytes: Int

    var outstandingItems: Int { queuedItems + inFlightItems }
    var outstandingBytes: Int { queuedBytes + inFlightBytes }
}

/// Pure accounting for the bounded worker. The current in-flight item remains charged after timeout until
/// the recognizer actually returns, so a Vision request that ignores cancellation cannot hide memory use.
struct PGSOCRQueueState: Sendable {
    private let itemLimit: Int
    private let byteLimit: Int
    private var queued: [PGSOCRWorkItem] = []
    private var queuedBytes = 0
    private var inFlight: PGSOCRWorkItem?

    init(itemLimit: Int = PGSOCRPolicy.maximumOutstandingItems,
         byteLimit: Int = PGSOCRPolicy.maximumOutstandingBytes) {
        self.itemLimit = max(0, itemLimit)
        self.byteLimit = max(0, byteLimit)
    }

    var snapshot: PGSOCRQueueSnapshot {
        PGSOCRQueueSnapshot(
            queuedItems: queued.count,
            queuedBytes: queuedBytes,
            inFlightItems: inFlight == nil ? 0 : 1,
            inFlightBytes: inFlight?.byteCount ?? 0)
    }

    mutating func enqueue(_ item: PGSOCRWorkItem) -> PGSOCRSubmission {
        var dropped: [UInt64] = []
        guard itemLimit > 0,
              item.byteCount >= 0,
              item.byteCount <= byteLimit else {
            return PGSOCRSubmission(accepted: false, droppedTokens: [])
        }
        while !queued.isEmpty && !canFit(item) {
            let oldest = queued.removeFirst()
            queuedBytes -= oldest.byteCount
            dropped.append(oldest.token)
        }
        guard canFit(item) else {
            return PGSOCRSubmission(accepted: false, droppedTokens: dropped)
        }
        queued.append(item)
        queuedBytes += item.byteCount
        return PGSOCRSubmission(accepted: true, droppedTokens: dropped)
    }

    mutating func beginNext() -> PGSOCRWorkItem? {
        guard inFlight == nil, !queued.isEmpty else { return nil }
        let item = queued.removeFirst()
        queuedBytes -= item.byteCount
        inFlight = item
        return item
    }

    @discardableResult
    mutating func completeInFlight(token: UInt64) -> Bool {
        guard inFlight?.token == token else { return false }
        inFlight = nil
        return true
    }

    mutating func removeAllQueued() -> [UInt64] {
        let tokens = queued.map(\.token)
        queued.removeAll(keepingCapacity: false)
        queuedBytes = 0
        return tokens
    }

    mutating func removeQueued(token: UInt64) -> PGSOCRWorkItem? {
        guard let index = queued.firstIndex(where: { $0.token == token }) else { return nil }
        let item = queued.remove(at: index)
        queuedBytes -= item.byteCount
        return item
    }

    func item(token: UInt64) -> PGSOCRWorkItem? {
        if inFlight?.token == token { return inFlight }
        return queued.first(where: { $0.token == token })
    }

    var inFlightItem: PGSOCRWorkItem? { inFlight }

    func canPrepare(maximumItemBytes: Int) -> Bool {
        guard maximumItemBytes > 0, maximumItemBytes <= byteLimit else { return false }
        let current = snapshot
        guard current.outstandingItems < itemLimit else { return false }
        let (nextBytes, overflow) = current.outstandingBytes.addingReportingOverflow(maximumItemBytes)
        return !overflow && nextBytes <= byteLimit
    }

    private func canFit(_ item: PGSOCRWorkItem) -> Bool {
        let current = snapshot
        guard current.outstandingItems < itemLimit else { return false }
        let (nextBytes, overflow) = current.outstandingBytes.addingReportingOverflow(item.byteCount)
        return !overflow && nextBytes <= byteLimit
    }
}

final class PGSOCRRecognitionContext: @unchecked Sendable {
    let deadlineUptime: TimeInterval

    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?
    private var timedOut = false
    private var cancelled = false

    init(deadlineUptime: TimeInterval) {
        self.deadlineUptime = deadlineUptime
    }

    var shouldStop: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut || cancelled
    }

    var didTimeOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }

    func registerCancellation(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        let cancelNow = timedOut || cancelled
        if !cancelNow { cancellation = action }
        lock.unlock()
        if cancelNow { action() }
    }

    func clearCancellation() {
        lock.lock()
        cancellation = nil
        lock.unlock()
    }

    func markTimedOut() {
        lock.lock()
        guard !timedOut else { lock.unlock(); return }
        timedOut = true
        let action = cancellation
        lock.unlock()
        action?()
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let action = cancellation
        lock.unlock()
        action?()
    }
}

/// One serial OCR worker with bounded admission, absolute deadlines, and nonblocking invalidation.
final class PGSOCRWorker: @unchecked Sendable {
    typealias Recognizer =
        @Sendable (PGSOCRWorkItem, PGSOCRRecognitionContext) -> PGSOCRRecognizerResult
    typealias CompletionHandler = @Sendable (PGSOCRCompletion) -> Void

    private static let deadlineQueue = DispatchQueue(label: "vortx.pgs-ocr.deadline")

    private let condition = NSCondition()
    private var queue: PGSOCRQueueState
    private var admissionOpen = true
    private var drainRequested = false
    private var invalidated = false
    private var currentContext: PGSOCRRecognitionContext?
    private var deadlineItems: [UInt64: DispatchWorkItem] = [:]
    private var timeoutDelivered: Set<UInt64> = []
    private var thread: Thread?
    private let recognizer: Recognizer
    private let completion: CompletionHandler
    private let preparationReservationBytes: Int

    init(itemLimit: Int = PGSOCRPolicy.maximumOutstandingItems,
         byteLimit: Int = PGSOCRPolicy.maximumOutstandingBytes,
         preparationReservationBytes: Int = PGSOCRPolicy.maximumBitmapBytesPerItem,
         recognizer: @escaping Recognizer,
         completion: @escaping CompletionHandler) {
        queue = PGSOCRQueueState(itemLimit: itemLimit, byteLimit: byteLimit)
        self.preparationReservationBytes = max(0, min(preparationReservationBytes, byteLimit))
        self.recognizer = recognizer
        self.completion = completion
    }

    func start() {
        condition.lock()
        guard thread == nil, !invalidated else { condition.unlock(); return }
        let worker = Thread { self.run() }
        worker.name = "vortx.pgs-ocr"
        worker.stackSize = 1 << 20
        worker.qualityOfService = .utility
        thread = worker
        condition.unlock()
        worker.start()
    }

    func submit(_ item: PGSOCRWorkItem) -> PGSOCRSubmission {
        condition.lock()
        let now = ProcessInfo.processInfo.systemUptime
        guard admissionOpen, !invalidated, item.deadlineUptime > now else {
            condition.unlock()
            return PGSOCRSubmission(accepted: false, droppedTokens: [])
        }
        let result = queue.enqueue(item)
        for token in result.droppedTokens {
            deadlineItems.removeValue(forKey: token)?.cancel()
        }
        if result.accepted {
            let timeout = DispatchWorkItem { [weak self] in
                self?.expire(token: item.token)
            }
            deadlineItems[item.token] = timeout
            Self.deadlineQueue.asyncAfter(
                deadline: .now() + max(0, item.deadlineUptime - now),
                execute: timeout)
            condition.signal()
        }
        condition.unlock()
        return result
    }

    /// Close producer admission while preserving every item already admitted. The worker drains the in-flight
    /// item and queued tail through their existing absolute deadlines, then exits without blocking the caller.
    func finishAdmissionAndDrain() {
        condition.lock()
        guard !invalidated else { condition.unlock(); return }
        admissionOpen = false
        drainRequested = true
        condition.broadcast()
        condition.unlock()
    }

    /// Stop admission and cancel active work without joining the worker thread.
    func invalidateAndStop() -> [UInt64] {
        condition.lock()
        admissionOpen = false
        drainRequested = false
        invalidated = true
        let dropped = queue.removeAllQueued()
        for timeout in deadlineItems.values { timeout.cancel() }
        deadlineItems.removeAll(keepingCapacity: false)
        let context = currentContext
        condition.broadcast()
        condition.unlock()
        context?.cancel()
        return dropped
    }

    var snapshot: PGSOCRQueueSnapshot {
        condition.lock(); defer { condition.unlock() }
        return queue.snapshot
    }

    var canPrepare: Bool {
        condition.lock(); defer { condition.unlock() }
        return admissionOpen
            && !invalidated
            && queue.canPrepare(maximumItemBytes: preparationReservationBytes)
    }

    private func run() {
        while true {
            condition.lock()
            while !invalidated && !drainRequested && queue.snapshot.queuedItems == 0 {
                condition.wait()
            }
            guard let item = queue.beginNext() else {
                let shouldExit = invalidated || drainRequested
                if shouldExit { thread = nil }
                condition.unlock()
                if shouldExit { return }
                continue
            }
            let context = PGSOCRRecognitionContext(deadlineUptime: item.deadlineUptime)
            currentContext = context
            condition.unlock()

            // Vision and CoreGraphics create Objective-C temporaries. Drain them per cue so a long remux
            // cannot retain an entire title's recognition graph until the worker thread exits.
            let result = autoreleasepool {
                recognizer(item, context)
            }
            let returnedAt = ProcessInfo.processInfo.systemUptime

            condition.lock()
            let completed = queue.completeInFlight(token: item.token)
            if currentContext === context { currentContext = nil }
            deadlineItems.removeValue(forKey: item.token)?.cancel()
            let deadlineAlreadyDelivered = timeoutDelivered.remove(item.token) != nil
            let expiredOnReturn = returnedAt >= item.deadlineUptime || context.didTimeOut
            let deliverTimeout = completed && !invalidated && expiredOnReturn && !deadlineAlreadyDelivered
            let deliver = completed && !invalidated && !expiredOnReturn
                && !context.shouldStop && !deadlineAlreadyDelivered
            condition.unlock()

            if deliverTimeout {
                completion(Self.completion(item: item, outcome: .timedOut))
            } else if deliver {
                let outcome: PGSOCRCompletionOutcome
                switch result {
                case .text(let text): outcome = .text(text)
                case .empty: outcome = .empty
                case .failed: outcome = .failed
                }
                completion(Self.completion(item: item, outcome: outcome))
            }
        }
    }

    private func expire(token: UInt64) {
        condition.lock()
        guard !invalidated, let item = queue.item(token: token) else {
            condition.unlock()
            return
        }
        deadlineItems.removeValue(forKey: token)
        if queue.inFlightItem?.token == token {
            timeoutDelivered.insert(token)
            let context = currentContext
            condition.unlock()
            context?.markTimedOut()
        } else {
            _ = queue.removeQueued(token: token)
            condition.unlock()
        }
        completion(Self.completion(item: item, outcome: .timedOut))
    }

    private static func completion(item: PGSOCRWorkItem,
                                   outcome: PGSOCRCompletionOutcome) -> PGSOCRCompletion {
        PGSOCRCompletion(
            token: item.token,
            epoch: item.epoch,
            sourceIndex: item.sourceIndex,
            renditionID: item.renditionID,
            startSeconds: item.startSeconds,
            durationSeconds: item.durationSeconds,
            outcome: outcome)
    }
}
