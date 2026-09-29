import Foundation

@main enum BatchMetaSlotPolicyTests {
    static func main() throws {
        let episode = MetaLoadTarget(metaID: "series-a", streamID: "episode-a1")
        let foreign = MetaLoadTarget(metaID: "series-b", streamID: "episode-b1")
        func policy() -> BatchMetaSlotPolicy {
            .init(expected: episode, now: 0, settlementWindow: 20)
        }
        var late = policy()
        precondition(late.update(requestedTarget: episode, registered: true, now: 18) == .wait)
        precondition(late.update(requestedTarget: foreign, registered: false, now: 19) == .reassert)
        precondition(late.settlementStartedAt == 19)
        precondition(late.update(requestedTarget: episode, registered: true, now: 20) == .wait,
                     "A must get a bounded settlement opportunity after B preempted the late request")
        // A ready group can now queue within the restarted window; it was not falsely skipped at t=20.
        precondition(20 - late.settlementStartedAt < late.settlementWindow)

        var empty = policy()
        for now in stride(from: 2.5, to: 20.0, by: 2.5) {
            precondition(empty.update(requestedTarget: episode, registered: false, now: now) == .reassert)
            precondition(empty.settlementStartedAt == 0, "registration retries cannot extend an empty source")
        }
        precondition(empty.update(requestedTarget: episode, registered: false, now: 20) == .deadline)

        var early = policy()
        precondition(early.update(requestedTarget: foreign, registered: false, now: 0.5) == .reassert)
        precondition(early.update(requestedTarget: episode, registered: true, now: 3) == .wait)
        precondition(early.update(requestedTarget: episode, registered: true, now: 20.5) == .deadline)
        var repeated = policy()
        for now in stride(from: 1.0, to: 60.0, by: 1.0) {
            precondition(repeated.update(requestedTarget: foreign, registered: false, now: now) == .reassert)
        }
        precondition(repeated.update(requestedTarget: foreign, registered: false, now: 60) == .deadline,
                     "repeated navigation must not cause unbounded batch work")
        var throttled = policy()
        precondition(throttled.update(requestedTarget: foreign, registered: false, now: 0.1) == .wait)
        precondition(throttled.update(requestedTarget: nil, registered: false, now: 0.25) == .reassert)
        precondition(episode != MetaLoadTarget(metaID: "series-a", streamID: "episode-a2"))
        precondition(episode != MetaLoadTarget(metaID: "series-b", streamID: "episode-a1"))

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let coordinator = try String(contentsOf: root.appendingPathComponent("SourcesiOS/iOSBatchDownloadCoordinator.swift"), encoding: .utf8)
        let bridge = try String(contentsOf: root.appendingPathComponent("SourcesShared/CoreBridge.swift"), encoding: .utf8)
        precondition(coordinator.contains("core.currentMetaLoadTarget == expected")
                     && coordinator.contains("selected?.metaPath.id == expected.metaID")
                     && coordinator.contains("selected?.streamPath?.id == expected.streamID"))
        precondition(coordinator.contains("if action == .deadline { break }") && coordinator.contains("if action == .reassert"))
        precondition(bridge.contains("requestedMetaLoadTarget = MetaLoadTarget(metaID: id, streamID: streamID)"))
        print("PASS late/early shared-slot recovery, empty deadline, repeated-preemption cap, exact identities and production wiring")
    }
}
