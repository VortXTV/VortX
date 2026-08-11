// Executable retained-tail proof for producer handoff.
//
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/prepared-remux-spool-survival \
//     app/Sources/Player/VortXPreparedRemuxPolicy.swift \
//     app/Sources/Player/VortXRemuxBuffer.swift \
//     app/Tests/PreparedRemuxSpoolSurvivalTests.swift && /tmp/prepared-remux-spool-survival

import Foundation

struct RemoteConfig {
    struct Snapshot { let dvRemuxWindowMiB: Int }
    static let snapshot = Snapshot(dvRemuxWindowMiB: 64)
}

enum DiagnosticsLog {
    static func log(_ tag: String, _ message: String) {}
}

@main
struct PreparedRemuxSpoolSurvivalTests {
    private final class StartCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Int] = [:]

        func increment(_ key: String) {
            lock.lock()
            values[key, default: 0] += 1
            lock.unlock()
        }

        func value(_ key: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return values[key, default: 0]
        }
    }

    static func main() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vortx-prepared-handoff-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let source = VortXRemuxBuffer(windowFloorBytes: 1)
        let expected = Array(0..<16).map(UInt8.init)
        expected.withUnsafeBufferPointer { bytes in
            if let base = bytes.baseAddress { source.append(base, count: bytes.count) }
        }
        guard let spool = VortXHLSSessionSpool(
            parentDirectory: root,
            capacityBytes: 64,
            chunkSize: 4,
            scavengeStaleSessions: false) else {
            fail("current playback spool is creatable")
        }
        let key = VortXHLSSessionSpool.ResourceKey.video(segmentID: 40)
        guard spool.spill([.init(
            key: key,
            buffer: source,
            offset: 0,
            length: expected.count,
            durationMilliseconds: 4_000
        )]) else {
            fail("current playback tail is durably staged")
        }

        let coordinator = VortXRemuxProducerCoordinator()
        let starts = StartCounter()
        let current = coordinator.submit(
            purpose: .playback,
            start: { _ in starts.increment("current") },
            preempt: {},
            reject: {})
        let next = coordinator.submit(
            purpose: .preparation,
            start: { _ in starts.increment("next") },
            preempt: {},
            reject: {})
        expect(starts.value("current") == 1 && starts.value("next") == 0,
               "next preparation remains queued while current playback produces")

        spool.producerDidTerminate()
        current.producerDidUnwind()
        expect(starts.value("next") == 1,
               "real current-producer unwind starts next preparation exactly once")

        let lease = spool.openResource(key, now: 1)
        let retained = try? lease?.read(maxLength: expected.count)
        expect(retained == Data(expected)
                && FileManager.default.fileExists(atPath: spool.sessionDirectory.path),
               "current listener can still read its retained credits tail after next preparation starts")

        lease?.close(now: 1)
        spool.invalidateSession()
        spool.listenerDidRetire()
        next.producerDidUnwind()
        expect(!FileManager.default.fileExists(atPath: spool.sessionDirectory.path),
               "retained tail cleans only after current listener retirement")
        expect(VortXHLSConsumptionWindowPolicy.ordinarySessionCapacityBytes == 1024 * 1024 * 1024,
               "prepared and current ordinary spools retain the existing one-GiB hard capacity")
        print("ALL PASS (5 checks)")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fail(message) }
        print("PASS  \(message)")
    }

    private static func fail(_ message: String) -> Never {
        print("FAIL  \(message)")
        exit(1)
    }
}
