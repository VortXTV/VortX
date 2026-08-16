// Executable harness for the pre-scan first-packet-read-failure classification.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/remux-first-packet-failure-policy-test \
//     app/Sources/Player/RemuxFirstPacketFailurePolicy.swift \
//     app/Tests/RemuxFirstPacketFailurePolicyTests.swift && \
//     /tmp/remux-first-packet-failure-policy-test
//
// Pure policy harness (root-cause report section 3): no FFmpeg, no AVFoundation, no VortXRemuxBuffer. It only
// checks that a raw (rc, avioEOF, avioError, isCancelled) tuple lands on the classification the recovery
// policy table requires, and that the message-prefix round-trip (the ONLY channel the classification actually
// crosses module boundaries through today) survives.

import Foundation

@MainActor private var failures = 0

@MainActor private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

@main
@MainActor
enum RemuxFirstPacketFailurePolicyTests {
    static func main() {
        eofWinsOverAnyOtherSignal()
        avioFeofAloneIsEOFEvenWithoutTheEOFReturnCode()
        timeoutClassifiesAsTimeout()
        nonZeroAvioErrorClassifiesAsIOError()
        unrecognizedNegativeRcFallsBackToIOError()
        cancellationWinsOverEveryOtherSignal()
        onlyEOFIsSourceTerminal()
        onlyCancelledIsCancellation()
        onlyTimeoutAndIOErrorRetry()
        prefixesRoundTripAndNeverCollide()
        cancelledMessageCarriesNoZeroPacketPrefix()

        print("===== FAILURES: \(failures) =====")
        exit(failures == 0 ? 0 : 1)
    }

    static func eofWinsOverAnyOtherSignal() {
        let c = RemuxFirstPacketFailure.classify(
            readResult: -541_478_725, avioEOF: false, avioError: 0, isCancelled: false)
        check("AVERROR_EOF rc alone classifies emptyEOF", c == .emptyEOF)
    }

    static func avioFeofAloneIsEOFEvenWithoutTheEOFReturnCode() {
        // A short/truncated read can return a different negative rc while avio_feof is already true; the feof
        // bit is the more authoritative EOF signal and must still win.
        let c = RemuxFirstPacketFailure.classify(
            readResult: -5, avioEOF: true, avioError: 0, isCancelled: false)
        check("avio_feof=true classifies emptyEOF regardless of rc", c == .emptyEOF)
    }

    static func timeoutClassifiesAsTimeout() {
        let c = RemuxFirstPacketFailure.classify(
            readResult: -60, avioEOF: false, avioError: 0, isCancelled: false)
        check("AVERROR(ETIMEDOUT) rc classifies timeout", c == .timeout(code: -60))
    }

    static func nonZeroAvioErrorClassifiesAsIOError() {
        let c = RemuxFirstPacketFailure.classify(
            readResult: -5, avioEOF: false, avioError: -103, isCancelled: false)
        check("non-zero pb.error classifies ioError with the AVIO error code", c == .ioError(code: -103))
    }

    static func unrecognizedNegativeRcFallsBackToIOError() {
        let c = RemuxFirstPacketFailure.classify(
            readResult: -5, avioEOF: false, avioError: 0, isCancelled: false)
        check("unclassified negative rc still fails closed as ioError, never silently dropped",
              c == .ioError(code: -5))
    }

    static func cancellationWinsOverEveryOtherSignal() {
        let c = RemuxFirstPacketFailure.classify(
            readResult: -541_478_725, avioEOF: true, avioError: -103, isCancelled: true)
        check("isCancelled overrides EOF/avioError signals", c == .cancelled(code: -541_478_725))
    }

    static func onlyEOFIsSourceTerminal() {
        check("emptyEOF is source-terminal", RemuxFirstPacketFailure.emptyEOF.isSourceTerminal)
        check("timeout is NOT source-terminal", !RemuxFirstPacketFailure.timeout(code: -60).isSourceTerminal)
        check("ioError is NOT source-terminal", !RemuxFirstPacketFailure.ioError(code: -5).isSourceTerminal)
        check("cancelled is NOT source-terminal", !RemuxFirstPacketFailure.cancelled(code: -1).isSourceTerminal)
    }

    static func onlyCancelledIsCancellation() {
        check("cancelled is a cancellation", RemuxFirstPacketFailure.cancelled(code: -1).isCancellation)
        check("emptyEOF is not a cancellation", !RemuxFirstPacketFailure.emptyEOF.isCancellation)
        check("timeout is not a cancellation", !RemuxFirstPacketFailure.timeout(code: -60).isCancellation)
        check("ioError is not a cancellation", !RemuxFirstPacketFailure.ioError(code: -5).isCancellation)
    }

    static func onlyTimeoutAndIOErrorRetry() {
        check("timeout deserves one bounded retry", RemuxFirstPacketFailure.timeout(code: -60).deservesOneBoundedRetry)
        check("ioError deserves one bounded retry", RemuxFirstPacketFailure.ioError(code: -5).deservesOneBoundedRetry)
        check("emptyEOF never retries (would only re-create the wasted-time symptom)",
              !RemuxFirstPacketFailure.emptyEOF.deservesOneBoundedRetry)
        check("cancelled never retries", !RemuxFirstPacketFailure.cancelled(code: -1).deservesOneBoundedRetry)
        check("retry bound is exactly one bounded reopen, not the mid-stream loop's 4",
              RemuxFirstPacketFailure.maxPreScanReadRetries == 1)
    }

    static func prefixesRoundTripAndNeverCollide() {
        let terminalMsg = RemuxFirstPacketFailure.emptyEOF.failureMessage(isResume: false, evidence: "scanned=0/240")
        let transientMsg = RemuxFirstPacketFailure.timeout(code: -60)
            .failureMessage(isResume: true, evidence: "scanned=3/240")
        check("emptyEOF message is recognized as terminal",
              RemuxFirstPacketFailure.isTerminalZeroPacket(terminalMsg))
        check("emptyEOF message is NOT recognized as transient",
              !RemuxFirstPacketFailure.isTransientZeroPacket(terminalMsg))
        check("timeout message is recognized as transient",
              RemuxFirstPacketFailure.isTransientZeroPacket(transientMsg))
        check("timeout message is NOT recognized as terminal",
              !RemuxFirstPacketFailure.isTerminalZeroPacket(transientMsg))
        check("resume wording is preserved in the message", transientMsg.contains("resume input"))
        check("fresh wording is preserved in the message", terminalMsg.contains("fresh input"))
    }

    static func cancelledMessageCarriesNoZeroPacketPrefix() {
        // cancel() already publishes buffer.fail("cancelled") itself; the pre-scan must never publish a
        // SECOND, source-blaming message over it. Confirm the cancelled message at least never claims to be a
        // terminal (source-penalizing) zero-packet failure even if some future caller published it anyway.
        let msg = RemuxFirstPacketFailure.cancelled(code: -1_414_092_869).failureMessage(isResume: false, evidence: "-")
        check("cancelled message is never classified as a terminal zero-packet failure",
              !RemuxFirstPacketFailure.isTerminalZeroPacket(msg))
        check("cancelled message is never classified as a transient zero-packet failure",
              !RemuxFirstPacketFailure.isTransientZeroPacket(msg))
    }
}
