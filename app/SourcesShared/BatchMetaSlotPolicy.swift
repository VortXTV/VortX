import Foundation

/// A requested metadata slot is distinct from a published/settled payload.
struct MetaLoadTarget: Equatable, Sendable {
    let metaID: String
    let streamID: String?
}

/// A foreground title can preempt the batch's shared slot. Give the exact episode a fresh bounded
/// settlement window after proven preemption, but never extend a genuinely empty request indefinitely.
struct BatchMetaSlotPolicy {
    enum Action: Equatable { case wait, reassert, deadline }
    let expected: MetaLoadTarget
    let startedAt: TimeInterval
    let settlementWindow: TimeInterval
    let maximumDuration: TimeInterval
    private(set) var settlementStartedAt: TimeInterval
    private var lastAssertAt: TimeInterval

    init(expected: MetaLoadTarget, now: TimeInterval, settlementWindow: TimeInterval,
         maximumDuration: TimeInterval = 60) {
        self.expected = expected
        self.startedAt = now
        self.settlementWindow = settlementWindow
        self.maximumDuration = maximumDuration
        self.settlementStartedAt = now
        self.lastAssertAt = now
    }

    mutating func update(requestedTarget: MetaLoadTarget?, registered: Bool, now: TimeInterval) -> Action {
        if now - startedAt >= maximumDuration { return .deadline }
        if requestedTarget != expected {
            // No 2.5-second delay when another navigation has actually taken ownership.
            guard now - lastAssertAt >= 0.25 else { return .wait }
            settlementStartedAt = now
            lastAssertAt = now
            return .reassert
        }
        if now - settlementStartedAt >= settlementWindow { return .deadline }
        if !registered, now - lastAssertAt >= 2.5 {
            lastAssertAt = now
            return .reassert // registration retry does NOT reset the settlement deadline
        }
        return .wait
    }
}
