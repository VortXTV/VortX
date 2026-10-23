import Foundation
import XCTest

/// Calls the production admission/capability implementation through real XCTest discovery.
/// Synthetic context/source authorities only; no Session, native ABI, disk, peer or ACK claim.
final class VortxNativeFIFOAdmissionTests: XCTestCase {
    private final class Source: VortxMutationAuthority, @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        private var throwAfter = false
        func revoke() { lock.withLock { active = false } }
        func failAfterOperation() { lock.withLock { throwAfter = true } }
        func withActive(_ operation: () throws -> Void) throws {
            try lock.withLock {
                guard active else { throw VortxNativeError.superseded }
                try operation()
                if throwAfter { throw VortxNativeError.superseded }
            }
        }
    }
    private final class Fixture: @unchecked Sendable {
        let lock = NSRecursiveLock()
        let source = Source()
        let fifo: VortxNativeFIFOAdmission
        private var acknowledgedIdentity = UUID()
        init() { fifo = VortxNativeFIFOAdmission(lock: lock) }
        func capture() throws -> VortxNativeFIFOAdmission.ReadCapability {
            let expected = lock.withLock { acknowledgedIdentity }
            return try fifo.capture(source: source) { [self] in
                guard acknowledgedIdentity == expected else { throw VortxNativeError.superseded }
            }
        }
        func changeAcknowledgedIdentity() { lock.withLock { acknowledgedIdentity = UUID() } }
        func consume(_ read: VortxNativeFIFOAdmission.ReadCapability) throws -> VortxNativeFIFOAdmission.Member {
            var member: VortxNativeFIFOAdmission.Member?
            try fifo.admit(read) { member = $0 }
            return try XCTUnwrap(member)
        }
    }

    func testPrecedingIntentRetiresReadEvenAfterItSettles() throws {
        let f = Fixture(), read = try f.capture()
        let earlier = try f.fifo.admit()
        var installs = 0
        XCTAssertThrowsError(try f.fifo.admit(read) { _ in installs += 1 })
        try earlier.begin(); earlier.finish()
        XCTAssertThrowsError(try f.fifo.admit(read) { _ in installs += 1 })
        XCTAssertEqual(installs, 0)
        XCTAssertNoThrow(try f.capture())
    }

    func testBusyQueueCannotCaptureAReplacementRead() throws {
        let f = Fixture(), member = try f.fifo.admit()
        XCTAssertThrowsError(try f.capture())
        try member.begin()
        XCTAssertThrowsError(try f.capture())
        member.finish()
        XCTAssertNoThrow(try f.capture())
    }

    func testOneOriginalReadTransitionsToOnlyItsRunningMember() throws {
        let f = Fixture(), read = try f.capture()
        let queue = read.queueAuthority
        let member = try f.consume(read)
        XCTAssertTrue(try f.fifo.capturedAuthority(for: member) === read)
        XCTAssertThrowsError(try read.withActive {})
        XCTAssertThrowsError(try queue.withActive {})
        XCTAssertThrowsError(try f.fifo.admit(read) { _ in XCTFail("second installation") })
        try member.begin()
        XCTAssertNoThrow(try read.withActive {})
        XCTAssertNoThrow(try queue.withActive {})
        XCTAssertThrowsError(try member.begin())
        member.finish()
        XCTAssertThrowsError(try read.withActive {})
        XCTAssertThrowsError(try queue.withActive {})
        XCTAssertThrowsError(try f.fifo.admit(read) { _ in XCTFail("reuse after finish") })
    }

    func testLaterEnqueuesDoNotRevokeTheEarlierRunningSource() throws {
        let f = Fixture(), read = try f.capture()
        let sourceMember = try f.consume(read)
        let laterProfileIntent = try f.fifo.admit()
        let stillLater = try f.fifo.admit()
        try sourceMember.begin()
        XCTAssertNoThrow(try read.withActive {})
        XCTAssertThrowsError(try laterProfileIntent.begin())
        // Later intent admission is not an acknowledged identity change.
        XCTAssertNoThrow(try read.queueAuthority.withActive {})
        sourceMember.finish()
        try laterProfileIntent.begin(); laterProfileIntent.finish()
        try stillLater.begin(); stillLater.finish()
        XCTAssertNoThrow(try f.capture())
    }

    func testTwoCapturesCannotBothBeAdmittedFromTheSameHead() throws {
        let f = Fixture(), first = try f.capture(), second = try f.capture()
        let member = try f.consume(first)
        XCTAssertThrowsError(try f.fifo.admit(second) { _ in XCTFail("competing read installed") })
        try member.begin(); member.finish()
        XCTAssertThrowsError(try f.fifo.admit(second) { _ in XCTFail("stale read revived") })
    }

    func testOrdinaryMembersRetainFIFOOrderWithoutLatestWins() throws {
        let f = Fixture(), first = try f.fifo.admit(), second = try f.fifo.admit(), third = try f.fifo.admit()
        XCTAssertThrowsError(try second.begin())
        try first.begin(); first.finish()
        try second.begin(); second.finish()
        try third.begin(); third.finish()
        // Duplicate settlement cannot remove a different member.
        first.finish()
        XCTAssertNoThrow(try f.capture())
    }

    func testCancellationBeforeAdmissionInstallsNothing() throws {
        let f = Fixture(), read = try f.capture(); read.cancel()
        var installs = 0
        XCTAssertThrowsError(try f.fifo.admit(read) { _ in installs += 1 })
        XCTAssertEqual(installs, 0)
        XCTAssertNoThrow(try f.capture())
    }

    func testQueuedCancellationPreservesLaterIntent() throws {
        let f = Fixture(), read = try f.capture(), member = try f.consume(read)
        let later = try f.fifo.admit()
        read.cancel()
        XCTAssertThrowsError(try member.begin())
        member.finish()
        try later.begin(); later.finish()
        XCTAssertNoThrow(try f.capture())
    }

    func testRunningCancellationAndActualIdentityChangeRetireAuthority() throws {
        let f = Fixture(), read = try f.capture(), member = try f.consume(read)
        try member.begin(); read.cancel()
        XCTAssertThrowsError(try read.withActive {})
        member.finish()
        let nextRead = try f.capture(), next = try f.consume(nextRead)
        try next.begin(); f.changeAcknowledgedIdentity()
        XCTAssertThrowsError(try nextRead.withActive {})
        XCTAssertThrowsError(try nextRead.queueAuthority.withActive {})
        next.finish()
    }

    func testOriginalSourceIsNotReplacedByAValidQueue() throws {
        let f = Fixture(), read = try f.capture(), member = try f.consume(read)
        try member.begin(); f.source.revoke()
        XCTAssertNoThrow(try read.queueAuthority.withActive {})
        XCTAssertThrowsError(try read.withActive {})
        member.finish()
        XCTAssertThrowsError(try f.capture())
    }

    func testRevokedSourceRejectsBeforeInstallation() throws {
        let f = Fixture(), read = try f.capture(); f.source.revoke()
        var installs = 0
        XCTAssertThrowsError(try f.fifo.admit(read) { _ in installs += 1 })
        XCTAssertEqual(installs, 0)
    }

    func testCloseAndUncertaintyNeverReactivateAnAdmittedRead() throws {
        for uncertain in [false, true] {
            let f = Fixture(), read = try f.capture(), member = try f.consume(read)
            try member.begin()
            if uncertain { f.fifo.markUncertain() } else { f.fifo.close() }
            XCTAssertThrowsError(try read.withActive {})
            XCTAssertThrowsError(try f.fifo.admit())
            member.finish()
            XCTAssertThrowsError(try f.capture())
        }
    }

    func testWrongQueueCannotConsumeOrScheduleAnotherQueuesCapability() throws {
        let first = Fixture(), second = Fixture(), read = try first.capture()
        XCTAssertThrowsError(try second.fifo.admit(read) { _ in XCTFail("cross-queue install") })
        let member = try first.consume(read)
        XCTAssertThrowsError(try second.fifo.capturedAuthority(for: member))
        try member.begin(); member.finish()
    }

    func testPostInstallationAuthorityFailureDoesNotCreateSecondCompletionOwner() throws {
        let f = Fixture(), read = try f.capture()
        f.source.failAfterOperation()
        var installs = 0
        var member: VortxNativeFIFOAdmission.Member?
        XCTAssertNoThrow(try f.fifo.admit(read) { installs += 1; member = $0 })
        XCTAssertEqual(installs, 1)
        let queued = try XCTUnwrap(member)
        XCTAssertThrowsError(try queued.begin())
        queued.finish()
        XCTAssertThrowsError(try f.fifo.admit(read) { _ in XCTFail("retry after post-install failure") })
    }
}
