import Foundation

/// Covers the COMPLETE thumbnail operation, including its Core Image/JPEG consumer.
/// MPV's Vulkan finish does not drain the app's independent MPS/CI command queues.
/// No callback or GPU operation runs under this condition lock.
final class MPVPiPCaptureGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var closed = false
    private var generation: UInt64 = 0
    private var inFlight = 0

    func enter() -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !closed else { return false }
        inFlight += 1
        return true
    }

    func leave() {
        condition.lock()
        precondition(inFlight > 0)
        inFlight -= 1
        condition.broadcast()
        condition.unlock()
    }

    func seal() -> UInt64 {
        condition.lock(); defer { condition.unlock() }
        closed = true
        generation &+= 1
        condition.broadcast()
        return generation
    }

    func waitUntilDrained(_ receipt: UInt64, before deadline: Date) -> Bool {
        condition.lock(); defer { condition.unlock() }
        while closed && generation == receipt && inFlight > 0 {
            if !condition.wait(until: deadline) { break }
        }
        return closed && generation == receipt && inFlight == 0
    }

    /// Foreground owner only. Reopening revokes an old waiter, even if closed again.
    func reopen() {
        condition.lock()
        closed = false
        generation &+= 1
        condition.broadcast()
        condition.unlock()
    }
}
