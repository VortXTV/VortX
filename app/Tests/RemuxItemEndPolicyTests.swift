// Executable contract for AVPlayer's remux-item end notification.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/remux-item-end-policy-test \
//     app/Sources/Player/VortXRemuxBuffer.swift \
//     app/Sources/Player/AudioLanguagePolicy.swift \
//     app/Sources/Player/MultiAudioPolicy.swift \
//     app/Tests/RemuxItemEndPolicyTests.swift && \
//     /tmp/remux-item-end-policy-test

import Foundation

struct RemoteConfig {
    struct Snapshot { let dvRemuxWindowMiB: Int }
    static let snapshot = Snapshot(dvRemuxWindowMiB: 64)
}

enum DiagnosticsLog {
    static func log(_ tag: String, _ message: String) {}
}

@MainActor private var failures = 0

@MainActor private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func sourceSection(_ source: String?, from start: String, to end: String) -> String? {
    guard let source,
          let startRange = source.range(of: start),
          let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
        return nil
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}

private func containsInOrder(_ source: String?, _ needles: [String]) -> Bool {
    guard let source else { return false }
    var cursor = source.startIndex
    for needle in needles {
        guard let range = source.range(of: needle, range: cursor..<source.endIndex) else { return false }
        cursor = range.upperBound
    }
    return true
}

@MainActor @main
enum RemuxItemEndPolicyTests {
    static func main() {
        var deferred = VortXPlaybackEndNotificationPolicy.DeferredTerminal()
        deferred.reset(generation: 7)
        var deferredEOFLatch = VortXPlaybackTerminalLatch(generation: 7)
        check(
            "paused genuine non-remux EOF is delivered exactly once only after an explicit later Play",
            deferred.capture(.eof, generation: 7)
                && !deferredEOFLatch.hasEmitted
                && deferred.consume(generation: 7) == .eof
                && deferredEOFLatch.claim(generation: 7)
                && !deferredEOFLatch.claim(generation: 7)
                && deferred.consume(generation: 7) == nil)
        deferred.reset(generation: 8)
        check(
            "paused clean producer EOF is deferred exactly once",
            deferred.capture(.eof, generation: 8)
                && deferred.consume(generation: 8) == .eof
                && deferred.consume(generation: 8) == nil)
        deferred.reset(generation: 9)
        check(
            "temporary remux-tail failure is retained as an error and never becomes EOF",
            VortXRemuxItemEndPolicy.classify(
                isRemux: true,
                producerEnded: false,
                producerFailureReason: nil) == .remuxFailure(VortXRemuxItemEndPolicy.prematureEndReason)
                && deferred.capture(.error(VortXRemuxItemEndPolicy.prematureEndReason), generation: 9)
                && deferred.consume(generation: 9) == .error(VortXRemuxItemEndPolicy.prematureEndReason))
        deferred.reset(generation: 10)
        check(
            "generation reset cannot replay an old deferred terminal",
            deferred.capture(.error("real failure"), generation: 10)
                && { deferred.reset(generation: 11); return deferred.consume(generation: 10) == nil }())
        deferred.reset(generation: 12)
        check(
            "a real deferred failure remains an error when explicitly consumed",
            deferred.capture(.error("real failure"), generation: 12)
                && deferred.consume(generation: 12) == .error("real failure"))

        check(
            "raw AVPlayer end remains content EOF",
            VortXRemuxItemEndPolicy.classify(
                isRemux: false,
                producerEnded: false,
                producerFailureReason: "ignored") == .contentEOF)

        let completedLegacyProducer = VortXRemuxItemEndPolicy.producerEnded(
            indexedHLS: false,
            indexedEnd: false,
            streamFinished: true,
            streamFailureReason: nil)
        check(
            "a clean legacy progressive completion remains content EOF",
            completedLegacyProducer
                && VortXRemuxItemEndPolicy.classify(
                    isRemux: true,
                    producerEnded: completedLegacyProducer,
                    producerFailureReason: nil) == .contentEOF)

        let prematureLegacyProducer = VortXRemuxItemEndPolicy.producerEnded(
            indexedHLS: false,
            indexedEnd: false,
            streamFinished: false,
            streamFailureReason: nil)
        check(
            "a premature legacy progressive item end becomes a typed playback failure",
            !prematureLegacyProducer
                && VortXRemuxItemEndPolicy.classify(
                    isRemux: true,
                    producerEnded: prematureLegacyProducer,
                    producerFailureReason: nil) == .remuxFailure(
                    VortXRemuxItemEndPolicy.prematureEndReason))

        check(
            "a failed legacy producer cannot masquerade as clean completion",
            !VortXRemuxItemEndPolicy.producerEnded(
                indexedHLS: false,
                indexedEnd: false,
                streamFinished: true,
                streamFailureReason: "read failed"))

        check(
            "indexed HLS trusts only its terminal index receipt",
            VortXRemuxItemEndPolicy.producerEnded(
                indexedHLS: true,
                indexedEnd: true,
                streamFinished: false,
                streamFailureReason: nil)
                && !VortXRemuxItemEndPolicy.producerEnded(
                    indexedHLS: true,
                    indexedEnd: false,
                    streamFinished: true,
                    streamFailureReason: nil))

        check(
            "the producer's concrete failure reason wins",
            VortXRemuxItemEndPolicy.classify(
                isRemux: true,
                producerEnded: false,
                producerFailureReason: "HLS spool admission failed") == .remuxFailure(
                    "HLS spool admission failed"))
        check(
            "a concrete remux failure outranks a contradictory ended receipt",
            VortXRemuxItemEndPolicy.classify(
                isRemux: true,
                producerEnded: true,
                producerFailureReason: "trailer write failed") == .remuxFailure(
                    "trailer write failed"))

        var duplicateEOF = VortXPlaybackTerminalLatch(generation: 7)
        check(
            "terminal latch: duplicate EOF emits exactly once for one item generation",
            duplicateEOF.claim(generation: 7)
                && !duplicateEOF.claim(generation: 7))
        var eofThenError = VortXPlaybackTerminalLatch(generation: 8)
        check(
            "terminal latch: EOF followed by error stays one terminal event",
            eofThenError.claim(generation: 8)
                && !eofThenError.claim(generation: 8))
        var errorThenEOF = VortXPlaybackTerminalLatch(generation: 9)
        check(
            "terminal latch: error followed by EOF stays one terminal event",
            errorThenEOF.claim(generation: 9)
                && !errorThenEOF.claim(generation: 9))
        var generationMismatch = VortXPlaybackTerminalLatch(generation: 30)
        check(
            "terminal latch: a mismatched generation is rejected without consuming the current event",
            !generationMismatch.claim(generation: 29)
                && !generationMismatch.hasEmitted
                && generationMismatch.claim(generation: 30))
        generationMismatch.reset(generation: 31)
        check(
            "terminal latch: reset rejects the stale generation without consuming the fresh event",
            !generationMismatch.claim(generation: 30)
                && !generationMismatch.hasEmitted
                && generationMismatch.claim(generation: 31))
        errorThenEOF.reset(generation: 10)
        check(
            "terminal latch: a fresh exact item generation owns a fresh terminal event",
            errorThenEOF.claim(generation: 10))

        var replacement = RemuxAudioReplacementPolicy.State(
            rollbackSourceIndex: 2,
            targetSourceIndex: 5,
            sourceSeconds: 90,
            generation: 20)
        var replacementTerminal = VortXPlaybackTerminalLatch(generation: 20)
        check(
            "item-end recovery: accepted replacement rollback emits no terminal event",
            replacement.failureAction(generation: 20)
                == .remountRollback(sourceIndex: 2, sourceSeconds: 90)
                && !replacementTerminal.hasEmitted)
        replacement.bind(to: 21)
        replacementTerminal.reset(generation: 21)
        check(
            "item-end recovery: rollback failure emits one error with no terminal loop",
            replacement.failureAction(generation: 21) == .noFurtherRetry
                && replacementTerminal.claim(generation: 21)
                && !replacementTerminal.claim(generation: 21))

        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let engine = try? String(
            contentsOf: appRoot.appendingPathComponent("Sources/Player/AVPlayerEngine.swift"),
            encoding: .utf8)
        let server = try? String(
            contentsOf: appRoot.appendingPathComponent("Sources/Player/VortXRemuxHLSServer.swift"),
            encoding: .utf8)
        let stream = try? String(
            contentsOf: appRoot.appendingPathComponent("Sources/Player/VortXMKVRemuxStream.swift"),
            encoding: .utf8)
        let endHandler = sourceSection(
            engine,
            from: "@objc private func didPlayToEnd",
            to: "@objc private func failedToEnd")
        check(
            "wiring: paused item-end evidence is classified then deferred before terminal-latch claim",
            containsInOrder(endHandler, [
                "VortXRemuxItemEndPolicy.classify(",
                "if !playbackRequested {",
                "deferredTerminal.capture(terminal, generation: itemGeneration)",
            ]) && endHandler?.contains("terminalLatch.claim(generation: itemGeneration)") == false)
        check(
            "wiring: explicit Play consumes a deferred terminal before asking AVPlayer to run again",
            containsInOrder(engine, [
                "func play() {",
                "deferredTerminal.consume(generation: itemGeneration)",
                "deliverTerminal(deferred, loadToken: loadToken, generation: itemGeneration)",
                "player.rate = requestedRate",
            ]))
        check(
            "wiring: nonterminal local remux EOF is one fatal error and never ordinary EOF",
            server?.contains("stream.hlsSnapshot().ended") == true
                && containsInOrder(endHandler, [
                    "VortXRemuxItemEndPolicy.classify(",
                    "case .remuxFailure(let reason):",
                    "guard !fatalErrorEmitted, !terminalLatch.hasEmitted else { return }",
                    "fatalErrorEmitted = true",
                    "emit(MPVProperty.endFileError, reason",
                ]))
        check(
            "wiring: the legacy progressive remux loader contributes its producer-ended receipt",
            engine?.contains("else if let loader = remuxLoader") == true
                && engine?.contains("let progress = loader.mountProgress") == true
                && stream?.contains("VortXRemuxItemEndPolicy.producerEnded(") == true)
        check(
            "wiring: remote and legacy failed progress become typed item-end failures",
            engine?.components(separatedBy:
                "progress.failed ? VortXRemuxItemEndPolicy.producerFailedReason : nil").count == 3)
        check(
            "wiring: item-end audio rollback runs before immediate terminal delivery",
            containsInOrder(endHandler, [
                "recoverAudioReplacementIfNeeded(",
                "terminal = .error(reason)",
                "deliverTerminal(terminal, loadToken: loadToken, generation: itemGeneration)",
            ]))
        check(
            "wiring: deferred and immediate EOF/error delivery share the exact-generation terminal latch",
            engine?.contains("private func deliverTerminal(") == true
                && engine?.contains("terminalLatch.claim(generation: generation)") == true
                && engine?.contains("case .eof:") == true
                && engine?.contains("case .error(let reason):") == true
                && engine?.components(separatedBy:
                    "deferredTerminal.reset(generation: itemGeneration)").count == 4)

        print("")
        if failures == 0 {
            print("ALL PASS")
            exit(0)
        }
        print("\(failures) FAILED")
        exit(1)
    }
}
