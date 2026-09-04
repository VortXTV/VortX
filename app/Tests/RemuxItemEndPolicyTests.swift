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
            "a healthy producer's temporary published tail is recoverable and never fabricated as EOF",
            VortXRemuxItemEndPolicy.classify(
                isRemux: true,
                producerEnded: false,
                producerFailureReason: nil) == .recoverablePublishedTail)
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
        deferred.reset(generation: 13)
        check(
            "paused status failures defer one exact-generation error without claiming a terminal",
            deferred.capture(.error("producer failed"), generation: 13)
                && !deferred.capture(.error("duplicate"), generation: 13)
                && deferred.consume(generation: 13) == .error("producer failed")
                && deferred.consume(generation: 13) == nil)
        deferred.reset(generation: 14)
        check(
            "paused status failure receipts cannot cross an item-generation replacement",
            deferred.capture(.error("old item failed"), generation: 14)
                && { deferred.reset(generation: 15); return deferred.consume(generation: 14) == nil }())

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
            "a premature legacy progressive item end remains recoverable while its producer is active",
            !prematureLegacyProducer
                && VortXRemuxItemEndPolicy.classify(
                    isRemux: true,
                    producerEnded: prematureLegacyProducer,
                    producerFailureReason: nil) == .recoverablePublishedTail)

        check(
            "same-source replacement carries intent only from an active playable nonterminal item",
            PlaybackIntentPolicy.carriesIntentForOwnedRecovery(
                recoveryTokenMatchesActiveLoad: true,
                sameRequestMetadata: true,
                hasCurrentItem: true,
                hasProducedPlayback: true,
                fatalErrorEmitted: false,
                terminalClaimed: false)
                && !PlaybackIntentPolicy.carriesIntentForOwnedRecovery(
                    recoveryTokenMatchesActiveLoad: false,
                    sameRequestMetadata: true,
                    hasCurrentItem: true,
                    hasProducedPlayback: true,
                    fatalErrorEmitted: false,
                    terminalClaimed: false)
                && !PlaybackIntentPolicy.carriesIntentForOwnedRecovery(
                    recoveryTokenMatchesActiveLoad: true,
                    sameRequestMetadata: false,
                    hasCurrentItem: true,
                    hasProducedPlayback: true,
                    fatalErrorEmitted: true,
                    terminalClaimed: false))

        check(
            "paused published tail is reclassified from active to clean EOF on Play",
            VortXRemuxItemEndPolicy.classify(
                isRemux: true,
                producerEnded: false,
                producerFailureReason: nil) == .recoverablePublishedTail
                && VortXRemuxItemEndPolicy.classify(
                    isRemux: true,
                    producerEnded: true,
                    producerFailureReason: nil) == .contentEOF)
        check(
            "paused published tail is reclassified from active to exact producer failure on Play",
            VortXRemuxItemEndPolicy.classify(
                isRemux: true,
                producerEnded: false,
                producerFailureReason: nil) == .recoverablePublishedTail
                && VortXRemuxItemEndPolicy.classify(
                    isRemux: true,
                    producerEnded: false,
                    producerFailureReason: "socket read failed") == .remuxFailure("socket read failed"))

        var replacementIntent = PlaybackIntentPolicy.Intent(
            sourceSeconds: 232.375,
            playbackRequested: false,
            requestedRate: 1.25,
            audioSelectionKnown: true,
            audioSourceIndex: 7,
            nativeAudioIndex: nil,
            subtitle: .embedded(sourceIndex: 19))
        replacementIntent.bind(generation: 42, mountIdentity: 3)
        check(
            "stall replacement carries exact playhead pause audio ID and subtitle ID",
            replacementIntent.consume(generation: 42, mountIdentity: 3) == .init(
                sourceSeconds: 232.375,
                playbackRequested: false,
                requestedRate: 1.25,
                audioSelectionKnown: true,
                audioSourceIndex: 7,
                nativeAudioIndex: nil,
                subtitle: .embedded(sourceIndex: 19)))

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
        let iosSurface = try? String(
            contentsOf: appRoot.appendingPathComponent("Sources/PlayerScreen.swift"),
            encoding: .utf8)
        let tvSurface = try? String(
            contentsOf: appRoot.appendingPathComponent("SourcesTV/TVPlayerView.swift"),
            encoding: .utf8)
        let endHandler = sourceSection(
            engine,
            from: "@objc private func didPlayToEnd",
            to: "@objc private func failedToEnd")
        check(
            "wiring: paused item-end evidence is classified then deferred before terminal-latch claim",
            containsInOrder(endHandler, [
                "currentRemuxItemEndDecision()",
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
            "wiring: explicit Play during recovery updates intent but cannot start before restoration",
            containsInOrder(engine, [
                "func play() {",
                "refreshPendingIntentTransport()",
                "if pendingPlaybackIntent != nil {",
                "play -> deferred until recovery restoration",
                "return",
                "player.rate = requestedRate",
            ]))
        check(
            "wiring: healthy remux tail replaces only the item and concrete failure remains terminal",
            server?.contains("stream.hlsSnapshot().ended") == true
                && containsInOrder(endHandler, [
                    "currentRemuxItemEndDecision()",
                    "case .recoverablePublishedTail:",
                    "retryFreshItemOnHealthyMount(",
                    "case .remuxFailure(let reason):",
                    "guard !fatalErrorEmitted, !terminalLatch.hasEmitted else { return }",
                ])
                && engine?.contains("return VortXRemuxItemEndPolicy.classify(") == true
                && engine?.contains("emit(MPVProperty.endFileError, reason") == true)
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
        let tailRecovery = sourceSection(
            engine,
            from: "private func retryFreshItemOnHealthyMount",
            to: "private func refreshPendingIntentTransport")
        let loadFile = sourceSection(
            engine,
            from: "func loadFile(_ url: URL",
            to: "private func attachPreparedItem")
        check(
            "wiring: surface same-source replacement captures intent before teardown and keeps exact resume origin",
            containsInOrder(loadFile, [
                "PlaybackIntentPolicy.carriesIntentForOwnedRecovery(",
                "pendingPlaybackIntent = capturePlaybackIntent(from: item)",
                "pendingPlaybackIntent?.updateSourceSeconds(configured)",
                "retryFreshItemOnHealthyMount(",
                "return existingToken",
                "teardownRemux()",
                "disableExternalSubtitle(discardingCues: !isIntentRemount)",
            ]))
        check(
            "wiring: both Apple stall surfaces pass the active AVPlayer recovery token explicitly",
            containsInOrder(iosSurface, [
                "private func recoverFromStall()",
                "let recoveryToken = coordinator.player is AVPlayerEngineController",
                "reusing: recoveryToken, resumeOrigin: resume",
            ])
                && containsInOrder(tvSurface, [
                    "private func reloadAtPlayhead()",
                    "let recoveryToken = coordinator.player is AVPlayerEngineController",
                    "reusing: recoveryToken, resumeOrigin: currentTime",
                ]))
        let readyHandler = sourceSection(
            engine,
            from: "private func handleStatus(_ item: AVPlayerItem",
            to: "@objc private func didPlayToEnd")
        let statusFailure = sourceSection(
            engine,
            from: "case .failed:",
            to: "default:")
        check(
            "wiring: recovery ready cannot apply transport before async selection restoration",
            containsInOrder(readyHandler, [
                "loadSelectionGroups()",
                "if pendingPlaybackIntent == nil {",
                "applyCommittedTransport()",
                "readyToPlay deferred transport until recovery selection and playhead restoration",
            ])
                && containsInOrder(engine, [
                    "private func loadSelectionGroups()",
                    "switch restore.subtitle",
                    "applyCommittedTransport()",
                ]))
        check(
            "wiring: same-mount tail recovery captures selection intent and restores it before transport",
            containsInOrder(tailRecovery, [
                "pendingPlaybackIntent = capturePlaybackIntent(from: currentItem)",
                "let freshItem = AVPlayerItem(asset: AVURLAsset(url: playlistURL))",
                "pendingPlaybackIntent?.bind(",
                "player.replaceCurrentItem(with: freshItem)",
            ])
                && containsInOrder(engine, [
                    "private func loadSelectionGroups()",
                    "let restore = replacementReady",
                    "item.select(option, in: group)",
                    "switch restore.subtitle",
                    "applyCommittedTransport()",
                ]))
        check(
            "wiring: paused published-tail recovery waits for explicit Play",
            containsInOrder(endHandler, [
                "case .recoverablePublishedTail:",
                "if !playbackRequested {",
                "deferredPublishedTailRecoveryGeneration = itemGeneration",
                "return",
                "retryFreshItemOnHealthyMount(",
            ])
                && containsInOrder(engine, [
                    "func play() {",
                    "deferredPublishedTailRecoveryGeneration == itemGeneration",
                    "retryFreshItemOnHealthyMount(",
                ])
                && containsInOrder(engine, [
                    "func play() {",
                    "deferredTerminal.consume(generation: itemGeneration)",
                    "deferredPublishedTailRecoveryGeneration == itemGeneration",
                    "currentRemuxItemEndDecision()",
                ]))
        check(
            "wiring: deferred and immediate EOF/error delivery share the exact-generation terminal latch",
            engine?.contains("private func deliverTerminal(") == true
                && engine?.contains("terminalLatch.claim(generation: generation)") == true
                && engine?.contains("case .eof:") == true
                && engine?.contains("case .error(let reason):") == true
                && engine?.components(separatedBy:
                    "deferredTerminal.reset(generation: itemGeneration)").count == 5)
        check(
            "wiring: a paused AVPlayer status failure defers before every retry or demotion path",
            containsInOrder(statusFailure, [
                "if !playbackRequested {",
                "switch currentRemuxItemEndDecision()",
                "case .recoverablePublishedTail:",
                "deferredPublishedTailRecoveryGeneration != itemGeneration",
                "deferredPublishedTailRecoveryGeneration = itemGeneration",
                "case .remuxFailure(let reason):",
                "deferredTerminal.capture(.error(reason), generation: itemGeneration)",
                "case .contentEOF:",
                "deferredTerminal.capture(.error(reason), generation: itemGeneration)",
                "return",
                "if shouldRetryViaPlainRemux",
            ]))
        check(
            "wiring: paused healthy status tail keeps the existing one-shot Play recovery generation fence",
            containsInOrder(statusFailure, [
                "case .recoverablePublishedTail:",
                "guard deferredPublishedTailRecoveryGeneration != itemGeneration else { return }",
                "deferredPublishedTailRecoveryGeneration = itemGeneration",
            ])
                && containsInOrder(engine, [
                    "func play() {",
                    "deferredPublishedTailRecoveryGeneration == itemGeneration",
                    "retryFreshItemOnHealthyMount(",
                ]))

        print("")
        if failures == 0 {
            print("ALL PASS")
            exit(0)
        }
        print("\(failures) FAILED")
        exit(1)
    }
}
