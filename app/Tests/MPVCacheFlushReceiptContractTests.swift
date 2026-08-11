// MPVCacheFlushReceiptContractTests: standalone source contract for the bounded receipt that identifies
// intentional internal cache-flush seeks in exported Apple diagnostics.
//
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     app/Tests/MPVCacheFlushReceiptContractTests.swift \
//     -o /tmp/mpv-cache-flush-receipt-contract-tests \
//     && /tmp/mpv-cache-flush-receipt-contract-tests

import Foundation

@main
@MainActor
private enum MPVCacheFlushReceiptContractTests {
    private static var failures = 0

    private static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS: \(name)")
        } else {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    private static func section(
        _ source: String,
        from start: String,
        to end: String
    ) -> String? {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            return nil
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private static func ordered(_ needles: [String], in source: String) -> Bool {
        var cursor = source.startIndex
        for needle in needles {
            guard let range = source.range(of: needle, range: cursor..<source.endIndex) else {
                return false
            }
            cursor = range.upperBound
        }
        return true
    }

    private static func replacingFirst(
        _ needle: String,
        with replacement: String,
        in source: String
    ) -> String {
        guard let range = source.range(of: needle) else { return source }
        return source.replacingCharacters(in: range, with: replacement)
    }

    private static func hasFiniteReasons(_ source: String, policy: String) -> Bool {
        return policy.contains("enum CacheFlushReason: String, Equatable")
            && policy.contains("case pausedCacheClamp = \"paused-cache-clamp\"")
            && policy.contains("case memoryWarning = \"memory-warning\"")
            && policy.contains("case proactiveMemoryPressure = \"proactive-memory-pressure\"")
            && source.contains("reason: CacheFlushReason")
    }

    private static func hasReceiptBeforeCommands(_ source: String) -> Bool {
        guard let flush = section(
            source,
            from: "private func flushDemuxerCachePreservingPosition(reason: CacheFlushReason)",
            to: "    /// System memory warning"
        ), let begin = section(
            source,
            from: "private func beginCacheFlushReceipt",
            to: "    private func cacheFlushCommandErrorReceipt"
        ) else {
            return false
        }
        return ordered(
            [
                "let bufferedAheadReceipt",
                "let pausedForCacheReceipt",
                "DiagnosticsLog.log(",
                "internal-cache-flush-begin",
                "bufferedAhead=",
                "pausedForCache=",
                "loadToken=",
            ],
            in: begin
        )
            && ordered(
                [
                    "beginCacheFlushReceipt(flight)",
                    "\"drop-buffers\"",
                    "let seekResult: Int32 = {",
                    "\"seek\"",
                    "flight.targetArgument",
                    "\"absolute+exact\"",
                ],
                in: flush
            )
    }

    private static func everyProductionCallSiteHasStaticReason(_ source: String) -> Bool {
        guard let pausedClamp = section(
            source,
            from: "private func applyPausedCacheClamp(reason: String = \"long pause\")",
            to: "    /// Free the demuxer cache"
        ), let memoryWarning = section(
            source,
            from: "private func shedForMemoryPressure()",
            to: "    #if os(tvOS)"
        ), let proactivePressure = section(
            source,
            from: "private func evaluateProactiveMemoryPressure()",
            to: "    #endif\n    #endif\n\n    private func updateCapturePipeline"
        ) else {
            return false
        }
        return pausedClamp.contains("flushDemuxerCachePreservingPosition(reason: .pausedCacheClamp)")
            && memoryWarning.contains("flushDemuxerCachePreservingPosition(reason: .memoryWarning)")
            && proactivePressure.contains(
                "flushDemuxerCachePreservingPosition(reason: .proactiveMemoryPressure)"
            )
    }

    private static func hasExplicitReceiptSelf(_ source: String) -> Bool {
        guard let pausedClamp = section(
            source,
            from: "private func applyPausedCacheClamp(reason: String = \"long pause\")",
            to: "    /// Free the demuxer cache"
        ) else {
            return false
        }
        return pausedClamp.contains("self.cacheFlushDispositionReceipt(flushDisposition)")
    }

    private static func cacheFlushSource(_ source: String) -> String? {
        section(
            source,
            from: "private func flushDemuxerCachePreservingPosition(reason: CacheFlushReason)",
            to: "    /// System memory warning"
        )
    }

    private static func memoryWarningSource(_ source: String) -> String? {
        section(
            source,
            from: "private func shedForMemoryPressure()",
            to: "    #if os(tvOS)"
        )
    }

    private static func lifecycleSource(_ source: String) -> String? {
        section(
            source,
            from: "func invalidateLoadToken()",
            to: "    private func callbackLoadToken"
        )
    }

    private static func stopSource(_ source: String) -> String? {
        section(
            source,
            from: "func stop()",
            to: "    deinit"
        )
    }

    private static func loadFileSource(_ source: String) -> String? {
        section(
            source,
            from: "func loadFile(",
            to: "    /// Decode only the command result map"
        )
    }

    private static func eventLoopSource(_ source: String) -> String? {
        section(
            source,
            from: "func readEvents()",
            to: "    /// log once."
        )
    }

    private static func hasSingleFlightAdmissionContract(_ source: String) -> Bool {
        guard let flush = cacheFlushSource(source) else { return false }
        return ordered(
            [
                "guard mpv != nil else { return .skipped }",
                "guard var owner = callbackLoadToken(requiresLoadedFile: true) else { return .skipped }",
                "if cacheFlushFlight.current?.owner == owner",
                "cacheFlushFlight.admit(owner: owner)",
                "guard cacheFlushFlight.admit(owner: owner) == .started else { return .coalesced }",
                "getFlag(MPVProperty.seekable)",
                "let pos = getDouble(MPVProperty.timePos)",
                "guard pos.isFinite, pos > 0 else { return .skipped }",
                "let targetArgument = String(format: \"%.3f\", pos)",
                "callbackLoadToken(requiresLoadedFile: true)",
                "let flight = cacheFlushFlight.install(",
                "beginCacheFlushReceipt(flight)",
                "DispatchQueue.main.asyncAfter",
                "deadline: .now() + Self.cacheFlushTimeoutSeconds",
                "flight.phase == .dropping",
                "let dropResult: Int32",
                "\"drop-buffers\"",
                "cacheFlushFlight.markDropSucceeded(",
                "flight.phase == .seeking",
                "let currentOwner = callbackLoadToken(requiresLoadedFile: true)",
                "currentOwner == flight.owner",
                "let seekResult: Int32 = {",
                "\"seek\"",
                "flight.targetArgument",
                "\"absolute+exact\"",
                "if seekResult >= 0",
                "cacheFlushFlight.markSeekCommandAccepted(id: flight.id, owner: flight.owner)",
            ],
            in: flush
        )
            && !flush.contains("mpv_command_async")
            && !flush.contains("beginSeekRequest")
            && !flush.contains("getDouble(MPVProperty.timePos)), \"absolute+exact\"")
            && flush.components(separatedBy: "currentOwner == flight.owner").count >= 3
    }

    private static func hasSynchronousSettleWindowContract(
        _ source: String,
        policy: String
    ) -> Bool {
        guard let flush = cacheFlushSource(source),
              let events = eventLoopSource(source) else { return false }
        return hasSingleFlightAdmissionContract(source)
            && ordered(
                [
                    "let seekResult: Int32 = {",
                    "if seekResult >= 0",
                    "cacheFlushFlight.markSeekCommandAccepted(id: flight.id, owner: flight.owner)",
                    "} else if cacheFlushFlight.seekCommandError(id: flight.id, owner: flight.owner)",
                ],
                in: flush
            )
            && !flush.contains("cacheFlushFlight.settle(")
            && !source.contains("mpv_command_async")
            && !source.contains("MPV_EVENT_COMMAND_REPLY")
            && !source.contains("playbackRestart")
            && !source.contains("beginSeekRequest")
            && !source.contains("awaitingSeekReply")
            && !source.contains("awaitingRestart")
            && !source.contains("markSeek(id:")
            && !events.contains("case MPV_EVENT_SEEK:")
            && !events.contains("case MPV_EVENT_PLAYBACK_RESTART:")
            && source.contains("handleCacheFlushTimeout(id: nextFlightID, owner: owner)")
            && source.contains("cacheFlushFlight.settle(id: id, owner: owner)")
            && policy.contains("case settling")
            && policy.contains("case commandAccepted = \"command-accepted\"")
            && policy.contains("mutating func markSeekCommandAccepted(id: UInt64, owner: Owner)")
            && policy.contains("mutating func settle(id: UInt64, owner: Owner)")
            && policy.contains("flight.phase == .settling")
            && policy.contains(
                "let result: CacheFlushFlight<Owner>.Result =\n            flight.result == .seekCommandError ? .seekCommandError : .commandAccepted"
            )
            && !policy.contains("case completed")
            && !policy.contains("case awaitingSeekReply")
            && !policy.contains("case awaitingRestart")
    }

    private static func hasFiniteReceiptContract(_ source: String) -> Bool {
        guard let begin = section(
            source,
            from: "private func beginCacheFlushReceipt",
            to: "    private func cacheFlushCommandErrorReceipt"
        ), let end = section(
            source,
            from: "private func finishCacheFlushFlight",
            to: "    /// mpv's stock User-Agent"
        ), let error = section(
            source,
            from: "private func cacheFlushCommandErrorReceipt",
            to: "    private func cacheFlushDispositionReceipt"
        ) else { return false }
        let receiptSource = begin + end + error
        return receiptSource.contains("internal-cache-flush-begin")
            && receiptSource.contains("internal-cache-flush-end")
            && receiptSource.contains("flightId=")
            && receiptSource.contains("coalesced=")
            && receiptSource.contains("elapsed=")
            && receiptSource.contains("outcome=")
            && receiptSource.contains("loadToken=")
            && !receiptSource.contains("completed")
            && !receiptSource.contains("restarted")
            && !receiptSource.contains("seek-completed")
            && !receiptSource.contains("url=")
            && !receiptSource.contains("path=")
            && !receiptSource.contains("headers=")
            && !receiptSource.contains("query=")
    }

    private static func hasPolicyOutsideGateContract(_ source: String) -> Bool {
        guard let warning = memoryWarningSource(source) else { return false }
        return ordered(
            [
                "let currentCapBytes = currentReadAheadBudgetBytes",
                "let availableBytes = UInt64(os_proc_available_memory())",
                "let cacheFillBytes = diagnosticInt(\"demuxer-cache-state/fw-bytes\") ?? Int.max",
                "let deferFlush = VortXCacheShedPolicy.shouldDeferFlushOnWarning(",
                "setString(\"demuxer-max-back-bytes\", \"8MiB\")",
                "flushDisposition = flushDemuxerCachePreservingPosition(reason: .memoryWarning)",
            ],
            in: warning
        )
    }

    private static func hasLifecycleResetContract(_ source: String) -> Bool {
        guard let lifecycle = lifecycleSource(source),
              let stop = stopSource(source),
              let load = loadFileSource(source),
              let events = eventLoopSource(source) else { return false }
        return ordered(
            [
                "cacheFlushFlight.reset()",
                "loadProvenance.invalidate()",
            ],
            in: lifecycle
        )
            && ordered(["invalidateLoadToken()", "guard let handle = mpv else { return }", "mpv = nil"], in: stop)
            && ordered(
                [
                    "loadTokenLock.unlock()",
                    "if commandResult >= 0 {",
                    "cacheFlushFlight.reset()",
                    "} else {",
                ],
                in: load
            )
            && load.contains("Rejected replace: preserve the previous source's cache lifecycle")
            && events.contains("case MPV_EVENT_END_FILE:")
            && events.contains("cacheFlushFlight.reset(owner: loadToken)")
            && events.contains("MPV_END_FILE_REASON_REDIRECT")
    }

    private static func hasAcceptedReplacementReceiptContract(_ source: String) -> Bool {
        guard let load = loadFileSource(source),
              let finish = section(
                source,
                from: "private func finishCacheFlushFlight",
                to: "    /// mpv's stock User-Agent"
              ), let falseBranch = section(
                finish,
                from: "} else {",
                to: "        }"
              ) else { return false }
        return ordered(
            [
                "loadTokenLock.unlock()",
                "if commandResult >= 0 {",
                "finishCacheFlushFlight(cacheFlushFlight.reset(), sampleLiveState: false)",
                "mpv_set_property_string(mpv, \"demuxer-max-bytes\", appliedCap)",
                "activeReadAheadCap = appliedCap",
                "baselineReadAheadCap = appliedCap",
            ],
            in: load
        )
            && ordered(
                [
                    "if sampleLiveState {",
                    "cacheFlushSampleReceipt(\"demuxer-cache-duration\")",
                    "diagnosticFlag(\"paused-for-cache\")",
                    "} else {",
                    "bufferedAheadReceipt = \"unknown\"",
                    "pausedForCacheReceipt = \"unknown\"",
                ],
                in: finish
            )
            && finish.contains("sampleLiveState: Bool = true")
            && !falseBranch.contains("diagnosticDouble(")
            && !falseBranch.contains("diagnosticFlag(")
    }

    private static func hasNoMisleadingFlushText(_ source: String) -> Bool {
        !source.contains("at/above pressure bar")
            && !source.contains("+ buffers dropped")
            && !source.contains("= \"buffers dropped\"")
    }

    static func main() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controllerURL = appRoot.appendingPathComponent("Sources/Player/MPVMetalViewController.swift")
        let policyURL = appRoot.appendingPathComponent("Sources/Player/CacheShedPolicy.swift")
        let controller = try String(contentsOf: controllerURL, encoding: .utf8)
        let policy = try String(contentsOf: policyURL, encoding: .utf8)

        check("finite reasons name every internal cache-flush source", hasFiniteReasons(controller, policy: policy))
        check("receipt records cache state before drop-buffers and exact seek", hasReceiptBeforeCommands(controller))
        check("each production cache-flush caller supplies a static reason",
              everyProductionCallSiteHasStaticReason(controller))
        check("paused cache diagnostics qualify the receipt helper with self",
              hasExplicitReceiptSelf(controller))
        check("single-flight admission is ordered and provenance-gated",
              hasSingleFlightAdmissionContract(controller))
        check("synchronous cache seek uses an event-independent 15-second settle window",
              hasSynchronousSettleWindowContract(controller, policy: policy))
        check("correction pass 2 binds the settle latch to truthful old-source receipts",
              hasSynchronousSettleWindowContract(controller, policy: policy)
                && hasAcceptedReplacementReceiptContract(controller))
        check("flight diagnostics are bounded and opaque",
              hasFiniteReceiptContract(controller))
        check("headroom/cache policy and seek-back cap remain outside the flight gate",
              hasPolicyOutsideGateContract(controller))
        check("load, invalidation, stop, EOF/error, and redirect lifecycle resets are exact",
              hasLifecycleResetContract(controller))
        check("accepted replacements finish old receipts before new-source bookkeeping",
              hasAcceptedReplacementReceiptContract(controller))
        check("misleading cap-held and unconditional dropped-buffer text is absent",
              hasNoMisleadingFlushText(controller))

        let missingLogMutant = replacingFirst(
            "beginCacheFlushReceipt(flight)",
            with: "// receipt removed",
            in: controller
        )
        check("hostile: missing receipt fails the command-order contract",
              !hasReceiptBeforeCommands(missingLogMutant))

        let missingReasonMutant = replacingFirst(
            "flushDemuxerCachePreservingPosition(reason: .memoryWarning)",
            with: "flushDemuxerCachePreservingPosition()",
            in: controller
        )
        check("hostile: missing memory-warning reason fails the call-site contract",
              !everyProductionCallSiteHasStaticReason(missingReasonMutant))

        let missingReceiptSelfMutant = replacingFirst(
            "self.cacheFlushDispositionReceipt(flushDisposition)",
            with: "cacheFlushDispositionReceipt(flushDisposition)",
            in: controller
        )
        check("hostile: removing receipt self qualification fails the closure contract",
              !hasExplicitReceiptSelf(missingReceiptSelfMutant))

        let missingActiveCheckMutant = replacingFirst(
            "guard mpv != nil else { return .skipped }",
            with: "// active check removed",
            in: controller
        )
        check("hostile: removing the active check fails admission ordering",
              !hasSingleFlightAdmissionContract(missingActiveCheckMutant))

        let repeatedTargetReadMutant = replacingFirst(
            "args: [flight.targetArgument, \"absolute+exact\"]",
            with: "args: [String(format: \"%.3f\", getDouble(MPVProperty.timePos)), \"absolute+exact\"]",
            in: controller
        )
        check("hostile: resampling time-pos for seek fails stored-target ordering",
              !hasSingleFlightAdmissionContract(repeatedTargetReadMutant))

        let timeoutAfterDropMutant = replacingFirst(
            "DispatchQueue.main.asyncAfter(\n            deadline: .now() + Self.cacheFlushTimeoutSeconds,",
            with: "// timeout installed too late",
            in: controller
        )
        check("hostile: installing timeout after drop fails timeout-before-command ordering",
              !hasSingleFlightAdmissionContract(timeoutAfterDropMutant))

        let unconditionalDropMutant = replacingFirst(
            "guard cacheFlushFlight.admit(owner: owner) == .started else { return .coalesced }",
            with: "guard true else { return .coalesced }",
            in: controller
        )
        check("hostile: unconditional drop path fails single-flight admission contract",
              !hasSingleFlightAdmissionContract(unconditionalDropMutant))

        let postDropOwnerMutant = replacingFirst(
            "currentOwner == flight.owner",
            with: "true",
            in: controller
        )
        check("hostile: synchronous seek requires the exact post-drop owner",
              !hasSingleFlightAdmissionContract(postDropOwnerMutant))

        let asyncSeekMutant = replacingFirst(
            "let seekResult: Int32 = {",
            with: "let seekResult = mpv_command_async(mpv, flight.id, &cargs)",
            in: controller
        )
        check("hostile: cache seek cannot use an asynchronous command fence",
              !hasSynchronousSettleWindowContract(asyncSeekMutant, policy: policy))

        let markSeekMutant = replacingFirst(
            "cacheFlushFlight.markSeekCommandAccepted(id: flight.id, owner: flight.owner)",
            with: "cacheFlushFlight.markSeek(id: flight.id, owner: flight.owner)",
            in: controller
        )
        check("hostile: generic markSeek cannot become the cache completion edge",
              !hasSynchronousSettleWindowContract(markSeekMutant, policy: policy))

        let immediateSettleMutant = replacingFirst(
            "cacheFlushFlight.markSeekCommandAccepted(id: flight.id, owner: flight.owner)",
            with: "cacheFlushFlight.markSeekCommandAccepted(id: flight.id, owner: flight.owner)\n            _ = cacheFlushFlight.settle(id: flight.id, owner: flight.owner)",
            in: controller
        )
        check("hostile: successful seek cannot settle before the 15-second window",
              !hasSynchronousSettleWindowContract(immediateSettleMutant, policy: policy))

        let ignoredErrorMutant = replacingFirst(
            "} else if cacheFlushFlight.seekCommandError(id: flight.id, owner: flight.owner) {",
            with: "} else if false, cacheFlushFlight.seekCommandError(id: flight.id, owner: flight.owner) {",
            in: controller
        )
        check("hostile: synchronous seek errors must latch for the settle window",
              !hasSynchronousSettleWindowContract(ignoredErrorMutant, policy: policy))

        let reintroducedEventMutant = replacingFirst(
            "case MPV_EVENT_START_FILE:",
            with: "case MPV_EVENT_PLAYBACK_RESTART:\n                    _ = self.cacheFlushFlight.settle(id: 1, owner: loadToken)\n                case MPV_EVENT_START_FILE:",
            in: controller
        )
        check("hostile: playback events cannot mutate the cache flight",
              !hasSynchronousSettleWindowContract(reintroducedEventMutant, policy: policy))

        let timeoutOwnerMutant = replacingFirst(
            "handleCacheFlushTimeout(id: nextFlightID, owner: owner)",
            with: "handleCacheFlushTimeout(id: 0, owner: owner)",
            in: controller
        )
        check("hostile: settle deadline captures the exact flight id and owner",
              !hasSynchronousSettleWindowContract(timeoutOwnerMutant, policy: policy))

        let timeoutCurrentLookupMutant = replacingFirst(
            "handleCacheFlushTimeout(id: nextFlightID, owner: owner)",
            with: "handleCacheFlushTimeout(id: cacheFlushFlight.current!.id, owner: owner)",
            in: controller
        )
        check("hostile: settle deadline cannot look up a current replacement id",
              !hasSynchronousSettleWindowContract(timeoutCurrentLookupMutant, policy: policy))

        let overwrittenSeekErrorMutant = replacingFirst(
            "let result: CacheFlushFlight<Owner>.Result =\n            flight.result == .seekCommandError ? .seekCommandError : .commandAccepted",
            with: "let result: CacheFlushFlight<Owner>.Result = .commandAccepted",
            in: policy
        )
        check("hostile: settle deadline must preserve a latched seek error",
              !hasSynchronousSettleWindowContract(controller, policy: overwrittenSeekErrorMutant))

        let commandAcceptedSpellingMutant = replacingFirst(
            "case commandAccepted = \"command-accepted\"",
            with: "case commandAccepted = \"completed\"",
            in: policy
        )
        check("hostile: settle receipts must use command-accepted spelling",
              !hasSynchronousSettleWindowContract(controller, policy: commandAcceptedSpellingMutant))

        let missingInvalidationResetMutant = replacingFirst(
            "finishCacheFlushFlight(cacheFlushFlight.reset())",
            with: "// invalidation reset removed",
            in: controller
        )
        check("hostile: invalidation resets the flight before provenance invalidation",
              !hasLifecycleResetContract(missingInvalidationResetMutant))

        let stopBeforeNilMutant = replacingFirst(
            "        invalidateLoadToken()",
            with: "        // invalidation removed",
            in: controller
        )
        check("hostile: stop must invalidate before niling mpv",
              !hasLifecycleResetContract(stopBeforeNilMutant))

        let missingTerminalResetMutant = replacingFirst(
            "self.finishCacheFlushFlight(self.cacheFlushFlight.reset(owner: loadToken))",
            with: "// terminal reset removed",
            in: controller
        )
        check("hostile: EOF/error terminal callbacks reset only their exact token",
              !hasLifecycleResetContract(missingTerminalResetMutant))

        let missingBackBufferPolicyMutant = replacingFirst(
            "setString(\"demuxer-max-back-bytes\", \"8MiB\")",
            with: "// backbuffer policy removed",
            in: controller
        )
        check("hostile: warning cap/backbuffer policy must remain before the flight gate",
              !hasPolicyOutsideGateContract(missingBackBufferPolicyMutant))

        let rejectedReplacementResetMutant = replacingFirst(
            "finishCacheFlushFlight(cacheFlushFlight.reset(), sampleLiveState: false)",
            with: "if true {",
            in: controller
        )
        check("hostile: rejected loadfile cannot reset the current flight",
              !hasLifecycleResetContract(rejectedReplacementResetMutant))

        let redirectResetMutant = replacingFirst(
            "if ef.reason == MPV_END_FILE_REASON_REDIRECT {",
            with: "if true {\n                            cacheFlushFlight.reset(owner: loadToken)",
            in: controller
        )
        check("hostile: redirects must retain the current flight provenance",
              !hasLifecycleResetContract(redirectResetMutant))

        let replacementResetAfterCapMutant = replacingFirst(
            "finishCacheFlushFlight(cacheFlushFlight.reset(), sampleLiveState: false)\n            mpv_set_property_string(mpv, \"demuxer-max-bytes\", appliedCap)",
            with: "mpv_set_property_string(mpv, \"demuxer-max-bytes\", appliedCap)\n            finishCacheFlushFlight(cacheFlushFlight.reset(), sampleLiveState: false)",
            in: controller
        )
        check("hostile: accepted replacement finishes the old receipt before cap bookkeeping",
              !hasAcceptedReplacementReceiptContract(replacementResetAfterCapMutant))

        let replacementLiveSampleMutant = replacingFirst(
            "sampleLiveState: false",
            with: "sampleLiveState: true",
            in: controller
        )
        check("hostile: accepted replacement cannot sample live state for the old receipt",
              !hasAcceptedReplacementReceiptContract(replacementLiveSampleMutant))

        let unknownReceiptMutant = replacingFirst(
            "bufferedAheadReceipt = \"unknown\"",
            with: "bufferedAheadReceipt = cacheFlushSampleReceipt(\"demuxer-cache-duration\")",
            in: controller
        )
        check("hostile: non-live old-flight receipt must emit literal unknown samples",
              !hasAcceptedReplacementReceiptContract(unknownReceiptMutant))

        let textMutant = controller + " at/above pressure bar + buffers dropped"
        check("hostile: misleading pressure-bar/drop text fails the diagnostics contract",
              !hasNoMisleadingFlushText(textMutant))

        guard failures == 0 else {
            print("MPVCacheFlushReceiptContractTests: \(failures) FAILED")
            exit(1)
        }
        print("MPVCacheFlushReceiptContractTests: ALL PASS")
    }
}
