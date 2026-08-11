// Time-scaled executable proof for the production preparation gate and producer coordinator.
//
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/prepared-remux-producer-park \
//     app/Sources/Player/VortXPreparedRemuxPolicy.swift \
//     app/Tests/PreparedRemuxProducerParkTests.swift && /tmp/prepared-remux-producer-park

import Foundation

private final class BoundedSegmentProducer: @unchecked Sendable {
    let gate = VortXRemuxPreparationGate()
    private let lock = NSLock()
    private let capacityBytes: Int
    private let bytesPerSegment: Int
    private let segmentTarget: Int
    private var cancelled = false
    private var producedBytes = 0
    private var failed = false
    private var startCount = 0
    private var terminalCount = 0
    let terminal = DispatchSemaphore(value: 0)

    init(capacityBytes: Int, bytesPerSegment: Int = 16, segmentTarget: Int) {
        self.capacityBytes = capacityBytes
        self.bytesPerSegment = bytesPerSegment
        self.segmentTarget = segmentTarget
    }

    func start(ticket: VortXRemuxProducerTicket) {
        lock.lock()
        startCount += 1
        lock.unlock()
        let thread = Thread { [self, ticket] in
            defer {
                lock.lock()
                terminalCount += 1
                lock.unlock()
                ticket.producerDidUnwind()
                terminal.signal()
            }
            for _ in 0..<segmentTarget {
                lock.lock()
                if cancelled {
                    lock.unlock()
                    return
                }
                if producedBytes > capacityBytes - bytesPerSegment {
                    failed = true
                    lock.unlock()
                    return
                }
                producedBytes += bytesPerSegment
                lock.unlock()
                if gate.waitAtClosedSegmentBoundary() == .cancelled { return }
            }
        }
        thread.name = "prepared-remux-park-test"
        thread.start()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        gate.cancel()
    }

    var snapshot: (bytes: Int, failed: Bool, starts: Int, terminals: Int) {
        lock.lock(); defer { lock.unlock() }
        return (producedBytes, failed, startCount, terminalCount)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

@main
struct PreparedRemuxProducerParkTests {
    nonisolated(unsafe) private static var passed = 0
    nonisolated(unsafe) private static var failed = 0

    static func main() {
        adoptionResumesTheSameParkedProducer()
        preemptionWakesThenYieldsExactlyOnce()
        productionWiringUsesTheBoundaryGate()
        print("")
        print(failed == 0 ? "ALL PASS (\(passed) checks)" : "FAILURES: \(failed)")
        exit(failed == 0 ? 0 : 1)
    }

    private static func adoptionResumesTheSameParkedProducer() {
        let coordinator = VortXRemuxProducerCoordinator()
        let producer = BoundedSegmentProducer(capacityBytes: 64, segmentTarget: 4)
        expect(producer.gate.requestParkAfterBoundary(),
               "startup readiness requests a boundary park")
        let ticket = coordinator.submit(
            purpose: .preparation,
            start: { producer.start(ticket: $0) },
            preempt: { producer.cancel() },
            reject: { producer.cancel() })
        expect(producer.gate.waitUntilParked(timeoutSeconds: 1),
               "the production gate parks at the next closed-segment boundary")
        let parked = producer.snapshot
        Thread.sleep(forTimeInterval: 0.15)
        let stillParked = producer.snapshot
        expect(parked.bytes == 16
                && stillParked.bytes == parked.bytes
                && !stillParked.failed
                && stillParked.terminals == 0,
               "bytes stop growing without capacity failure while the ticket stays parked")

        producer.gate.resume()
        expect(producer.terminal.wait(timeout: .now() + 1) == .success,
               "exact adoption wakes the parked producer")
        let completed = producer.snapshot
        expect(completed.bytes == 64
                && !completed.failed
                && completed.starts == 1
                && completed.terminals == 1,
               "adoption resumes the same producer without a second start")
        ticket.producerDidUnwind()
        expect(producer.snapshot.terminals == 1,
               "a duplicate terminal receipt cannot unwind the producer twice")
    }

    private static func preemptionWakesThenYieldsExactlyOnce() {
        let coordinator = VortXRemuxProducerCoordinator()
        let producer = BoundedSegmentProducer(capacityBytes: 32, segmentTarget: 8)
        let playbackStarts = Counter()
        _ = producer.gate.requestParkAfterBoundary()
        let preparation = coordinator.submit(
            purpose: .preparation,
            start: { producer.start(ticket: $0) },
            preempt: { producer.cancel() },
            reject: { producer.cancel() })
        expect(producer.gate.waitUntilParked(timeoutSeconds: 1),
               "preemption fixture owns one parked preparation producer")
        let playback = coordinator.submit(
            purpose: .playback,
            start: { _ in playbackStarts.increment() },
            preempt: {},
            reject: {})
        expect(producer.terminal.wait(timeout: .now() + 1) == .success,
               "preemption cancellation wakes the parked producer to unwind")
        let stopped = producer.snapshot
        expect(stopped.bytes == 16
                && !stopped.failed
                && stopped.terminals == 1
                && playbackStarts.count == 1,
               "real parked-producer unwind yields once to waiting playback")
        preparation.producerDidUnwind()
        expect(playbackStarts.count == 1,
               "duplicate preparation unwind cannot start playback twice")
        playback.producerDidUnwind()
    }

    private static func productionWiringUsesTheBoundaryGate() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let stream = try? String(
            contentsOf: root.appendingPathComponent("Sources/Player/VortXMKVRemuxStream.swift"),
            encoding: .utf8)
        let server = try? String(
            contentsOf: root.appendingPathComponent("Sources/Player/VortXRemuxHLSServer.swift"),
            encoding: .utf8)
        expect(stream?.contains("preparationGate.waitAtClosedSegmentBoundary()") == true,
               "the remux thread enters the gate only from closed-segment publication")
        expect(containsInOrder([
            "guard armMountDeadline()",
            "stream.resumePreparationProducer()",
            "prepared-remux phase=adopted",
        ], in: server),
        "adoption arms the mount deadline before resuming the same producer")
        expect(containsInOrder([
            "func cancel()",
            "cancelledFlag.set()",
            "preparationGate.cancel()",
            "private func run()",
            "notifyProducerDidUnwind()",
        ], in: stream),
        "cancellation wakes the gate but terminal ownership stays at run unwind")
    }

    private static func containsInOrder(_ needles: [String], in source: String?) -> Bool {
        guard let source else { return false }
        var cursor = source.startIndex
        for needle in needles {
            guard let range = source.range(of: needle, range: cursor..<source.endIndex) else {
                return false
            }
            cursor = range.upperBound
        }
        return true
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passed += 1
            print("PASS  \(message)")
        } else {
            failed += 1
            print("FAIL  \(message)")
        }
    }
}
