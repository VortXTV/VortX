// Executable contract for the bounded nonblocking PGS OCR worker.
//
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/pgs-ocr-pipeline \
//     app/Sources/Player/PGSOCRPolicy.swift \
//     app/Tests/PGSOCRPipelineTests.swift && /tmp/pgs-ocr-pipeline

import Foundation

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [Value] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

private func item(token: UInt64,
                  bytes: Int,
                  deadlineAfter: TimeInterval = 1,
                  epoch: UInt64 = 7) -> PGSOCRWorkItem {
    PGSOCRWorkItem(
        token: token,
        epoch: epoch,
        sourceIndex: 9,
        renditionID: 2,
        startSeconds: Double(token),
        durationSeconds: 2,
        deadlineUptime: ProcessInfo.processInfo.systemUptime + deadlineAfter,
        bitmaps: [
            PGSOCRBitmap(
                width: max(1, bytes),
                height: 1,
                indices: Data(repeating: 1, count: bytes),
                paletteBGRA: Data()),
        ])
}

private func waitUntil(_ predicate: () -> Bool,
                       timeout: TimeInterval = 1) -> Bool {
    let end = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < end {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return predicate()
}

private func sourceSlice(_ source: String,
                         from start: String,
                         to end: String) -> String? {
    guard let lower = source.range(of: start),
          let upper = source.range(
              of: end,
              range: lower.upperBound..<source.endIndex) else { return nil }
    return String(source[lower.lowerBound..<upper.lowerBound])
}

private func tokensAppearInOrder(_ source: String,
                                 _ tokens: [String]) -> Bool {
    var cursor = source.startIndex
    for token in tokens {
        guard let range = source.range(
            of: token,
            range: cursor..<source.endIndex) else { return false }
        cursor = range.upperBound
    }
    return true
}

@main
enum PGSOCRPipelineTests {
    static func main() {
        var failures = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS  \(name)")
            } else {
                failures += 1
                print("FAIL  \(name)")
            }
        }

        check("prepare bounds accept the exact rectangle cap",
              PGSOCRPolicy.acceptsPacketRectangleCount(PGSOCRPolicy.maximumBitmapsPerItem))
        check("prepare bounds reject a hostile rectangle count before allocation",
              !PGSOCRPolicy.acceptsPacketRectangleCount(PGSOCRPolicy.maximumBitmapsPerItem + 1))
        check("prepare bounds accept the exact aggregate byte cap",
              PGSOCRPolicy.canAppendBitmap(
                  existingCount: 0,
                  existingBytes: 0,
                  nextBytes: PGSOCRPolicy.maximumBitmapBytesPerItem))
        check("prepare bounds reject aggregate overflow",
              !PGSOCRPolicy.canAppendBitmap(
                  existingCount: 1,
                  existingBytes: PGSOCRPolicy.maximumBitmapBytesPerItem,
                  nextBytes: Int.max))
        check("decoder display offsets determine cue timing",
              PGSOCRPolicy.cueTiming(
                  packetStartSeconds: 10,
                  packetDurationSeconds: 9,
                  displayStartMilliseconds: 250,
                  displayEndMilliseconds: 2_250)?.start == 10.25
                && PGSOCRPolicy.cueTiming(
                    packetStartSeconds: 10,
                    packetDurationSeconds: 9,
                    displayStartMilliseconds: 250,
                    displayEndMilliseconds: 2_250)?.duration == 2)

        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let producerSource = try? String(
            contentsOf: appRoot.appendingPathComponent(
                "Sources/Player/VortXPGSSubtitleOCR.swift"),
            encoding: .utf8)
        let prepareSource = producerSource.flatMap {
            sourceSlice($0, from: "    func prepare(", to: "    func submit(")
        }
        let statefulDecodeOrder = [
            "avcodec_decode_subtitle2",
            "guard worker.canPrepare else",
            "var bitmaps: [PGSOCRBitmap]",
        ]
        check("producer preserves stateful PGS decode before worker backpressure",
              prepareSource.map {
                  tokensAppearInOrder($0, statefulDecodeOrder)
              } == true)
        check("producer ordering contract rejects the pre-decode backpressure mutant",
              !tokensAppearInOrder(
                  "guard worker.canPrepare else\n"
                    + "avcodec_decode_subtitle2\n"
                    + "var bitmaps: [PGSOCRBitmap]",
                  statefulDecodeOrder))

        var queue = PGSOCRQueueState(itemLimit: 3, byteLimit: 10)
        check("queue admits first item", queue.enqueue(item(token: 1, bytes: 4)).accepted)
        check("queue charges an in-flight item", queue.beginNext()?.token == 1)
        check("queue admits to exact item and byte ceilings",
              queue.enqueue(item(token: 2, bytes: 3)).accepted
                && queue.enqueue(item(token: 3, bytes: 3)).accepted
                && queue.snapshot.outstandingItems == 3
                && queue.snapshot.outstandingBytes == 10)
        let replacement = queue.enqueue(item(token: 4, bytes: 5))
        check("queue sheds oldest queued work deterministically",
              replacement.accepted && replacement.droppedTokens == [2, 3])
        check("queue never evicts in-flight work",
              queue.snapshot.inFlightItems == 1
                && queue.snapshot.inFlightBytes == 4
                && queue.snapshot.outstandingBytes == 9)
        check("queue rejects an individually oversized item",
              !queue.enqueue(item(token: 5, bytes: 11)).accepted)

        let recognitionStarted = DispatchSemaphore(value: 0)
        let releaseRecognition = DispatchSemaphore(value: 0)
        let timeoutDelivered = DispatchSemaphore(value: 0)
        let cancellationCalled = LockedFlag()
        let completions = LockedValues<PGSOCRCompletion>()
        let worker = PGSOCRWorker(
            itemLimit: 2,
            byteLimit: 64,
            recognizer: { _, context in
                context.registerCancellation { cancellationCalled.set() }
                recognitionStarted.signal()
                releaseRecognition.wait()
                return .text("late text")
            },
            completion: { completion in
                completions.append(completion)
                timeoutDelivered.signal()
            })
        worker.start()
        let submitStarted = ProcessInfo.processInfo.systemUptime
        let submission = worker.submit(item(token: 10, bytes: 8, deadlineAfter: 0.08))
        check("submit never waits for recognition",
              submission.accepted
                && ProcessInfo.processInfo.systemUptime - submitStarted < 0.05)
        check("recognizer starts on its worker",
              recognitionStarted.wait(timeout: .now() + 1) == .success)
        check("absolute deadline completes while Vision is blocked",
              timeoutDelivered.wait(timeout: .now() + 0.5) == .success
                && completions.snapshot.map(\.outcome) == [.timedOut])
        check("deadline asks the active request to cancel", cancellationCalled.isSet)
        check("timed-out work stays charged until the recognizer returns",
              worker.snapshot.inFlightItems == 1)
        releaseRecognition.signal()
        check("in-flight accounting releases after the recognizer returns",
              waitUntil({ worker.snapshot.inFlightItems == 0 }))
        Thread.sleep(forTimeInterval: 0.05)
        check("late text is suppressed after timeout",
              completions.snapshot.map(\.outcome) == [.timedOut])
        _ = worker.invalidateAndStop()

        let drainStarted = DispatchSemaphore(value: 0)
        let releaseDrain = DispatchSemaphore(value: 0)
        let drainDelivered = DispatchSemaphore(value: 0)
        let drainCompletions = LockedValues<PGSOCRCompletion>()
        let drainWorker = PGSOCRWorker(
            itemLimit: 3,
            byteLimit: 64,
            recognizer: { work, _ in
                if work.token == 40 {
                    drainStarted.signal()
                    releaseDrain.wait()
                }
                return .text("cue \(work.token)")
            },
            completion: {
                drainCompletions.append($0)
                drainDelivered.signal()
            })
        drainWorker.start()
        check("EOF drain admits the in-flight head",
              drainWorker.submit(item(token: 40, bytes: 8, deadlineAfter: 2)).accepted)
        check("EOF drain head starts",
              drainStarted.wait(timeout: .now() + 1) == .success)
        check("EOF drain admits a queued tail",
              drainWorker.submit(item(token: 41, bytes: 8, deadlineAfter: 2)).accepted
                && drainWorker.submit(item(token: 42, bytes: 8, deadlineAfter: 2)).accepted)
        let drainStart = ProcessInfo.processInfo.systemUptime
        drainWorker.finishAdmissionAndDrain()
        check("EOF drain never joins the in-flight recognizer",
              ProcessInfo.processInfo.systemUptime - drainStart < 0.05)
        check("EOF drain closes new admission",
              !drainWorker.submit(item(token: 43, bytes: 8, deadlineAfter: 2)).accepted)
        releaseDrain.signal()
        check("EOF drain delivers the admitted head and full queued tail",
              drainDelivered.wait(timeout: .now() + 1) == .success
                && drainDelivered.wait(timeout: .now() + 1) == .success
                && drainDelivered.wait(timeout: .now() + 1) == .success
                && drainCompletions.snapshot.map(\.token) == [40, 41, 42]
                && drainCompletions.snapshot.map(\.outcome)
                    == [.text("cue 40"), .text("cue 41"), .text("cue 42")])
        check("EOF drain releases all accounting",
              waitUntil({ drainWorker.snapshot.outstandingItems == 0 }))

        let teardownStarted = DispatchSemaphore(value: 0)
        let releaseTeardown = DispatchSemaphore(value: 0)
        let teardownCompletions = LockedValues<PGSOCRCompletion>()
        let teardownWorker = PGSOCRWorker(
            recognizer: { _, _ in
                teardownStarted.signal()
                releaseTeardown.wait()
                return .text("must not escape")
            },
            completion: { teardownCompletions.append($0) })
        teardownWorker.start()
        check("teardown work is admitted",
              teardownWorker.submit(item(token: 20, bytes: 8)).accepted)
        check("teardown recognizer starts",
              teardownStarted.wait(timeout: .now() + 1) == .success)
        let teardownStart = ProcessInfo.processInfo.systemUptime
        _ = teardownWorker.invalidateAndStop()
        check("invalidation never joins a blocked recognizer",
              ProcessInfo.processInfo.systemUptime - teardownStart < 0.05)
        releaseTeardown.signal()
        check("teardown eventually releases accounting",
              waitUntil({ teardownWorker.snapshot.inFlightItems == 0 }))
        check("teardown rejects late completion", teardownCompletions.snapshot.isEmpty)

        let completion = PGSOCRCompletion(
            token: 30,
            epoch: 9,
            sourceIndex: 4,
            renditionID: 0,
            startSeconds: 1,
            durationSeconds: 2,
            outcome: .empty)
        check("active pending completion is accepted",
              PGSOCRCompletionPolicy.accepts(
                  completion,
                  activeEpoch: 9,
                  tokenIsPending: true,
                  generationIsActive: true))
        check("cancelled generation cannot publish a completion",
              !PGSOCRCompletionPolicy.accepts(
                  completion,
                  activeEpoch: 9,
                  tokenIsPending: true,
                  generationIsActive: false))
        check("stale epoch cannot publish a completion",
              !PGSOCRCompletionPolicy.accepts(
                  completion,
                  activeEpoch: 10,
                  tokenIsPending: true,
                  generationIsActive: true))

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
