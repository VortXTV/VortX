// Hostile source/compile contract for the shared DownloadManager background-event and HLS recovery seams.
//
// Run from the repository root:
//   swiftc -parse-as-library app/Tests/DownloadManagerCrossPlatformCompileContractTests.swift \
//     -o /tmp/vortx-download-manager-cross-platform-contract && \
//   /tmp/vortx-download-manager-cross-platform-contract
//
// The production file cannot be typechecked standalone because it depends on the full app target. This
// contract checks the real source's platform boundaries, typechecks the exact cross-platform failure shape,
// then extracts and executes the dependency-free barrier/ledger state from the production file.

import Foundation

private struct Contract {
    var failures = 0

    mutating func check(_ name: String, _ condition: Bool) {
        if condition {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)")
        }
    }

    static func sourceURL() -> URL? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent("app/SourcesShared/DownloadManager.swift"),
            cwd.appendingPathComponent("SourcesShared/DownloadManager.swift")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Returns true when the line containing `marker` is lexically inside an active `#if os(iOS)` branch.
    /// This tracks conditional nesting instead of relying on line numbers, so a later edit cannot silently
    /// move a shared declaration across a platform boundary while leaving this test green.
    static func isInsideIOSGuard(marker: String, lines: [Substring]) -> Bool {
        guard let markerIndex = lines.firstIndex(where: { $0.contains(marker) }) else { return false }
        var guards: [Bool] = []
        for line in lines[..<lines.index(after: markerIndex)] {
            let directive = line.trimmingCharacters(in: .whitespaces)
            if directive.hasPrefix("#if ") {
                guards.append(directive == "#if os(iOS)")
            } else if directive.hasPrefix("#elseif ") {
                if !guards.isEmpty { guards[guards.index(before: guards.endIndex)] = directive.contains("os(iOS)") }
            } else if directive == "#else" {
                if !guards.isEmpty { guards[guards.index(before: guards.endIndex)] = false }
            } else if directive == "#endif" {
                _ = guards.popLast()
            }
        }
        return guards.contains(true)
    }

    static func sourceSection(_ source: String, from start: String, through end: String) -> String? {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            return nil
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    static func functionSource(_ source: String, marker: String) -> String? {
        guard let markerRange = source.range(of: marker),
              let openingBrace = source.range(of: "{", range: markerRange.upperBound..<source.endIndex) else {
            return nil
        }
        var depth = 0
        var cursor = openingBrace.lowerBound
        while cursor < source.endIndex {
            if source[cursor] == "{" {
                depth += 1
            } else if source[cursor] == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[markerRange.lowerBound..<source.index(after: cursor)])
                }
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    static func containsInOrder(_ source: String, _ fragments: [String]) -> Bool {
        var cursor = source.startIndex
        for fragment in fragments {
            guard let range = source.range(of: fragment, range: cursor..<source.endIndex) else { return false }
            cursor = range.upperBound
        }
        return true
    }

    static func typechecks(_ source: String, named name: String) -> Bool {
        let path = URL(fileURLWithPath: "/tmp/vortx-download-manager-\(name)-\(UUID().uuidString).swift")
        defer { try? FileManager.default.removeItem(at: path) }
        do {
            try source.write(to: path, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
            process.arguments = [
                "-parse-as-library", "-strict-concurrency=complete", "-warnings-as-errors", "-typecheck", path.path
            ]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let diagnostics = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if !diagnostics.isEmpty { print("  swiftc \(name):\n\(diagnostics)") }
            return process.terminationStatus == 0
        } catch {
            print("  swiftc \(name) could not run: \(error)")
            return false
        }
    }

    static func compilesAndRuns(_ source: String, named name: String) -> Bool {
        let token = UUID().uuidString
        let sourcePath = URL(fileURLWithPath: "/tmp/vortx-download-manager-\(name)-\(token).swift")
        let executablePath = URL(fileURLWithPath: "/tmp/vortx-download-manager-\(name)-\(token)-run")
        defer {
            try? FileManager.default.removeItem(at: sourcePath)
            try? FileManager.default.removeItem(at: executablePath)
        }
        do {
            try source.write(to: sourcePath, atomically: true, encoding: .utf8)
            let compile = Process()
            compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
            compile.arguments = [
                "-parse-as-library", "-strict-concurrency=complete", "-warnings-as-errors",
                sourcePath.path, "-o", executablePath.path
            ]
            let compileOutput = Pipe()
            compile.standardOutput = compileOutput
            compile.standardError = compileOutput
            try compile.run()
            compile.waitUntilExit()
            let compileDiagnostics = String(
                data: compileOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if !compileDiagnostics.isEmpty { print("  swiftc \(name):\n\(compileDiagnostics)") }
            guard compile.terminationStatus == 0 else { return false }

            let run = Process()
            run.executableURL = executablePath
            let runOutput = Pipe()
            run.standardOutput = runOutput
            run.standardError = runOutput
            try run.run()
            run.waitUntilExit()
            let output = String(data: runOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if !output.isEmpty { print("  \(name) output:\n\(output)") }
            return run.terminationStatus == 0
        } catch {
            print("  \(name) could not run: \(error)")
            return false
        }
    }
}

@main
private enum DownloadManagerCrossPlatformCompileContractTests {
    static func main() {
        guard let sourceURL = Contract.sourceURL(),
              let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            fatalError("DownloadManager.swift not found from the current repository root")
        }
        guard let byteSuccessSource = Contract.sourceSection(
            source,
            from: "    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,\n                                didFinishDownloadingTo location: URL) {",
            through: "    /// Error path:") else {
            fatalError("byte success delegate source section not found")
        }
        guard let byteErrorSource = Contract.sourceSection(
            source,
            from: "    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {",
            through: "    #if os(iOS)\n    /// Finalize an HLS asset download.") else {
            fatalError("byte error delegate source section not found")
        }
        guard let hlsCompletionSource = Contract.functionSource(
            source,
            marker: "nonisolated func handleAssetTaskCompletion") else {
            fatalError("HLS completion source not found")
        }
        guard let hlsCancellationSource = Contract.sourceSection(
            hlsCompletionSource,
            from: "if let ns = error as NSError?, ns.code == NSURLErrorCancelled {",
            through: "guard case let .accepted(finishedLocation)") else {
            fatalError("HLS cancellation source not found")
        }
        let hlsCallbackUsesAtomicClaim = hlsCompletionSource.contains(
            "let barrier = self.backgroundEventBarriers.beginWork(for: Self.hlsSessionIdentifier)")
            && !hlsCompletionSource.contains("barrier.beginFinalization()")
        let hlsCancellationUsesAtomicClaim = Contract.containsInOrder(hlsCancellationSource, [
            "let barrier = self.backgroundEventBarriers.beginWork(for: Self.hlsSessionIdentifier)",
            "Task { @MainActor [weak self] in",
            "defer { barrier.completeFinalization().forEach { $0() } }",
            "guard let self else { return }",
            "self.cleanupHLSAsset"
        ])
        guard let registrySource = Contract.sourceSection(
            source,
            from: "final class HLSBackgroundEventBarrierRegistry:",
            through: "enum HLSAssetCleanupPolicy {") else {
            fatalError("background event registry source section not found")
        }
        guard let registryBeginWorkSource = Contract.functionSource(
            registrySource,
            marker: "func beginWork(for identifier: String)") else {
            fatalError("registry begin-work source not found")
        }
        guard let byteBarrierHelperSource = Contract.functionSource(
            source,
            marker: "private nonisolated func beginByteBackgroundEventWork(for session: URLSession)") else {
            fatalError("byte background barrier helper source not found")
        }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var contract = Contract()

        contract.check(
            "background barrier member is shared across Apple targets",
            !Contract.isInsideIOSGuard(marker: "nonisolated let backgroundEventBarriers", lines: lines))
        contract.check(
            "background-event adoption is shared-target safe",
            !Contract.isInsideIOSGuard(marker: "func adoptBackgroundEvents(", lines: lines))
        contract.check(
            "background-event finish callback is shared-target safe",
            !Contract.isInsideIOSGuard(marker: "nonisolated func urlSessionDidFinishEvents(", lines: lines))
        contract.check(
            "reconnection starts as barrier work before getAllTasks",
            source.contains(
                "barrier.beginFinalization()\n        reconnectInFlightDownloads(for: identifier, hasInFlightRecords: true, barrier: barrier)"))
        contract.check(
            "weak-self reconciliation exits always finish the barrier",
            source.components(separatedBy: "defer { Self.finishBackgroundEventWork(barrier) }").count - 1 >= 2)
        contract.check(
            "finish callback can release without a live manager self",
            source.contains("Task { @MainActor in\n            let handlers = barrier.finishEvents()"))
        contract.check(
            "cleanup commits only after a deletion result",
            source.contains("func finishCleanup(taskIdentifier: Int, location: URL, succeeded: Bool)"))
        contract.check(
            "cleanup retries are bounded and visible",
            source.contains("HLSAssetCleanupPolicy.maxAttempts")
                && source.contains("DiagnosticsLog.log(\"downloads\", message)"))
        contract.check(
            "byte finalization claims only the named background session",
            byteBarrierHelperSource.contains("guard session.configuration.identifier == Self.backgroundSessionIdentifier else { return nil }")
                && byteBarrierHelperSource.contains("backgroundEventBarriers.beginWork(for: Self.backgroundSessionIdentifier)")
                && !byteBarrierHelperSource.contains("barrier.beginFinalization()")
                && !Contract.isInsideIOSGuard(marker: "private nonisolated func beginByteBackgroundEventWork", lines: lines))
        contract.check(
            "byte success finalizer begins before its deferred MainActor task",
            Contract.containsInOrder(byteSuccessSource, [
                "let barrier = beginByteBackgroundEventWork(for: session)",
                "Task { @MainActor [weak self] in\n            defer { Self.finishBackgroundEventWork(barrier) }"
            ]))
        contract.check(
            "byte error and cancellation finalizer begins before its deferred MainActor task",
            Contract.containsInOrder(byteErrorSource, [
                "guard let error else { return }\n        let barrier = beginByteBackgroundEventWork(for: session)",
                "Task { @MainActor [weak self] in\n            defer { Self.finishBackgroundEventWork(barrier) }"
            ]))
        contract.check(
            "HLS cancellation claims work before queued cleanup and defers completion before weak self",
            hlsCancellationUsesAtomicClaim)
        contract.check(
            "background adoption starts a new generation after an unadopted drain",
            registryBeginWorkSource.contains("current.beginWork()")
                && registryBeginWorkSource.contains("new.beginWork()")
                && registrySource.contains("func beginAdoption(for identifier: String)")
                && source.contains("hasUnadoptedFinishedEvents")
                && source.contains("pendingFinalizations == 0"))
        // Hostile regression fixture: the old shape has an iOS-only member but unguarded callers. On a
        // non-iOS target it must fail exactly as the shared target did before the correction.
        let brokenShape = """
        import Foundation
        #if os(iOS)
        final class HLSBackgroundEventBarrierRegistry {}
        #endif
        struct DummySession {}
        final class BrokenDownloadManager {
            #if os(iOS)
            let backgroundEventBarriers = HLSBackgroundEventBarrierRegistry()
            #endif
            func adoptBackgroundEvents(for identifier: String, completionHandler: @escaping () -> Void) {
                _ = backgroundEventBarriers
                _ = identifier
                _ = completionHandler
            }
            func urlSessionDidFinishEvents(forBackgroundURLSession session: DummySession) {
                _ = backgroundEventBarriers
                _ = session
            }
        }
        """
        contract.check(
            "iOS-only member with shared callers fails the compiler",
            !Contract.typechecks(brokenShape, named: "broken"))

        // Corrected projection: the registry and both callers are available on every shared target. HLS-only
        // work is still selected by the platform-specific reconnection branch at runtime.
        let correctedShape = """
        import Foundation
        final class HLSBackgroundEventBarrierRegistry {}
        struct DummySession {}
        final class SharedDownloadManager {
            let backgroundEventBarriers = HLSBackgroundEventBarrierRegistry()
            func adoptBackgroundEvents(for identifier: String, completionHandler: @escaping () -> Void) {
                _ = backgroundEventBarriers
                _ = identifier
                _ = completionHandler
            }
            func urlSessionDidFinishEvents(forBackgroundURLSession session: DummySession) {
                _ = backgroundEventBarriers
                _ = session
            }
        }
        """
        contract.check(
            "shared-target projection typechecks",
            Contract.typechecks(correctedShape, named: "corrected"))

        guard let barrierSource = Contract.sourceSection(
            source,
            from: "final class HLSBackgroundEventBarrier:",
            through: "final class HLSBackgroundEventBarrierRegistry:") else {
            fatalError("HLSBackgroundEventBarrier source section not found")
        }
        guard let barrierBeginWorkSource = Contract.functionSource(
            barrierSource,
            marker: "func beginWork()") else {
            fatalError("barrier begin-work source not found")
        }
        contract.check(
            "begin-work increments outstanding finalization atomically",
            barrierBeginWorkSource.contains("pendingFinalizations += 1"))
        guard let stateSource = Contract.sourceSection(
            source,
            from: "enum HLSAssetCleanupPolicy {",
            through: "// END HLS background policy state") else {
            fatalError("HLS cleanup state source section not found")
        }

        let hlsStateHarness = """
        import Foundation

        \(barrierSource)
        \(stateSource)

        private enum HarnessError: Error { case injectedFailure }

        private func fire(_ handlers: [() -> Void]) {
            handlers.forEach { $0() }
        }

        private struct HLSStateChecks {
            var failures = 0

            mutating func check(_ name: String, _ condition: Bool) {
                if condition {
                    print("PASS  \\(name)")
                } else {
                    failures += 1
                    print("FAIL  \\(name)")
                }
            }
        }

        @main
        private enum HLSStateHarness {
            static func main() {
                var checks = HLSStateChecks()
                // Reconnection work begins before the session-drain callback and releases only after the
                // MainActor reconciliation work reports completion.
                let finishBeforeReconnect = HLSBackgroundEventBarrier()
                var releases = 0
                _ = finishBeforeReconnect.addCompletion { releases += 1 }
                finishBeforeReconnect.beginFinalization()
                checks.check(
                    "finish-before-reconnect waits for reconciliation",
                    finishBeforeReconnect.finishEvents().isEmpty && releases == 0)
                fire(finishBeforeReconnect.completeFinalization())
                checks.check("reconciliation releases the adopted completion once", releases == 1)

                // A caller that retains this exact barrier identity can prove finish-before-adoption belongs to
                // the same generation. Registry-level adoption rotates away from an unadopted finished barrier.
                let finishBeforeAdoption = HLSBackgroundEventBarrier()
                var lateReleases = 0
                checks.check(
                    "finish-before-adoption does not release an unadopted barrier",
                    finishBeforeAdoption.finishEvents().isEmpty)
                _ = finishBeforeAdoption.addCompletion { lateReleases += 1 }
                finishBeforeAdoption.beginFinalization()
                fire(finishBeforeAdoption.completeFinalization())
                checks.check("late adoption still receives exactly one completion", lateReleases == 1)

                // `defer`-style weak-self/error exits must close their work item before the finish signal can
                // release UIKit. This models the guard-let-self early return in each reconciliation task.
                let weakExit = HLSBackgroundEventBarrier()
                var weakExitReleases = 0
                _ = weakExit.addCompletion { weakExitReleases += 1 }
                weakExit.beginFinalization()
                func simulateWeakSelfExit() {
                    defer { fire(weakExit.completeFinalization()) }
                    guard false else { return }
                }
                simulateWeakSelfExit()
                fire(weakExit.finishEvents())
                checks.check("weak-self exit closes its barrier work", weakExitReleases == 1)

                // A transient filesystem failure must retry and only the successful deletion commits the
                // ledger claim.
                var attempts = 0
                let retryError = HLSAssetCleanupPolicy.remove(
                    using: {
                        attempts += 1
                        if attempts == 1 { throw HarnessError.injectedFailure }
                    },
                    isAbsent: { false })
                checks.check("cleanup retries once and then succeeds", retryError == nil && attempts == 2)

                let location = URL(fileURLWithPath: "/tmp/hls-recovery-contract-\\(UUID().uuidString)/title.movpkg")
                defer {
                    try? FileManager.default.removeItem(at: location)
                    try? FileManager.default.removeItem(at: location.deletingLastPathComponent())
                }
                let ledger = HLSAssetLifecycleLedger()
                _ = ledger.recordFinishedLocation(taskIdentifier: 7, location: location)
                let firstClaim = ledger.cancel(taskIdentifier: 7)
                checks.check("failed cleanup gets an initial claim", firstClaim == location)
                ledger.finishCleanup(taskIdentifier: 7, location: location, succeeded: false)
                let retryClaim = ledger.recordFinishedLocation(taskIdentifier: 7, location: location)
                checks.check("failed cleanup remains retryable", retryClaim == location)
                ledger.finishCleanup(taskIdentifier: 7, location: location, succeeded: true)
                checks.check(
                    "successful cleanup is committed exactly once",
                    ledger.recordFinishedLocation(taskIdentifier: 7, location: location) == nil)

                var boundedAttempts = 0
                let persistentError = HLSAssetCleanupPolicy.remove(
                    using: {
                        boundedAttempts += 1
                        throw HarnessError.injectedFailure
                    },
                    isAbsent: { false })
                checks.check(
                    "persistent cleanup failure stops at the bound",
                    persistentError != nil && boundedAttempts == HLSAssetCleanupPolicy.maxAttempts)

                if checks.failures > 0 {
                    print("\\n\\(checks.failures) HLS STATE CHECKS FAILED")
                    exit(1)
                }
                print("\\nALL HLS STATE CHECKS PASS")
            }
        }
        """
        contract.check(
            "barrier and cleanup state contract passes",
            Contract.compilesAndRuns(hlsStateHarness, named: "hls-state"))

        let byteFinalizationHarness = """
        import Foundation

        \(barrierSource)
        \(registrySource)

        private func fire(_ handlers: [() -> Void]) {
            handlers.forEach { $0() }
        }

        private struct ByteStateChecks {
            var failures = 0

            mutating func check(_ name: String, _ condition: Bool) {
                if condition {
                    print("PASS  \\(name)")
                } else {
                    failures += 1
                    print("FAIL  \\(name)")
                }
            }
        }

        @main
        private enum ByteFinalizationHarness {
            static func main() {
                var checks = ByteStateChecks()

                // A previous process can receive a finish signal without ever adopting a UIKit handler.
                // That old drain must not mark the later relaunch generation as finished.
                let registry = HLSBackgroundEventBarrierRegistry()
                let prior = registry.barrier(for: "tv.vortx.downloads.background")
                fire(prior.finishEvents())
                let current = registry.beginAdoption(for: "tv.vortx.downloads.background")
                var currentReleases = 0
                var currentPersisted = false
                var currentReleasedBeforePersistence = false
                _ = current.addCompletion {
                    if !currentPersisted { currentReleasedBeforePersistence = true }
                    currentReleases += 1
                }
                current.beginFinalization()
                fire(current.completeFinalization())
                checks.check(
                    "prior unadopted drain cannot release a later generation",
                    prior.generation < current.generation
                        && !current.isReleased
                        && currentReleases == 0)
                currentPersisted = true
                fire(current.finishEvents())
                checks.check(
                    "later generation releases only after its current finish",
                    !currentReleasedBeforePersistence && currentReleases == 1)

                // A real byte cycle can claim and complete without a UIKit handler. Once that cycle also
                // receives its finish signal, a later relaunch must rotate before reconnect completion can
                // consume the old eventsFinished bit.
                let completedWithoutAdoptionRegistry = HLSBackgroundEventBarrierRegistry()
                let completedWithoutAdoption = completedWithoutAdoptionRegistry.beginWork(
                    for: "tv.vortx.downloads.background")
                fire(completedWithoutAdoption.completeFinalization())
                fire(completedWithoutAdoption.finishEvents())
                var relaunchReleases = 0
                var newFinishObserved = false
                var relaunchReleasedBeforeNewFinish = false
                let relaunch = completedWithoutAdoptionRegistry.beginAdoption(
                    for: "tv.vortx.downloads.background")
                _ = relaunch.addCompletion {
                    if !newFinishObserved { relaunchReleasedBeforeNewFinish = true }
                    relaunchReleases += 1
                }
                relaunch.beginFinalization()
                fire(relaunch.completeFinalization())
                checks.check(
                    "completed unadopted byte cycle rotates before relaunch",
                    completedWithoutAdoption.generation < relaunch.generation
                        && relaunchReleases == 0
                        && !relaunchReleasedBeforeNewFinish)
                newFinishObserved = true
                fire(relaunch.finishEvents())
                checks.check(
                    "relaunch completion waits for its new finish",
                    !relaunchReleasedBeforeNewFinish && relaunchReleases == 1)

                // The inverse ordering keeps byte work outstanding: finishEvents may precede the queued
                // adoption, but adoption must bind to this same generation until that work is drained.
                let pendingRegistry = HLSBackgroundEventBarrierRegistry()
                let pendingCallback = pendingRegistry.beginWork(
                    for: "tv.vortx.downloads.background")
                fire(pendingCallback.finishEvents())
                var pendingReleases = 0
                var pendingReleasedBeforeDrain = false
                let pendingAdoption = pendingRegistry.beginAdoption(
                    for: "tv.vortx.downloads.background")
                _ = pendingAdoption.addCompletion {
                    if pendingCallback !== pendingAdoption { pendingReleasedBeforeDrain = true }
                    pendingReleases += 1
                }
                pendingAdoption.beginFinalization()
                fire(pendingAdoption.completeFinalization())
                checks.check(
                    "queued adoption reuses a generation with outstanding callback work",
                    pendingCallback === pendingAdoption
                        && pendingReleases == 0
                        && !pendingReleasedBeforeDrain)
                fire(pendingCallback.completeFinalization())
                checks.check(
                    "queued adoption releases after the outstanding callback drains",
                    pendingReleases == 1)

                // A and B both claim their own outstanding count. A may complete after B returns but before
                // B's deferred MainActor body runs; no shared reservation may be stolen by adoption work.
                let interleavingRegistry = HLSBackgroundEventBarrierRegistry()
                let callbackA = interleavingRegistry.beginWork(
                    for: "tv.vortx.downloads.background")
                let callbackB = interleavingRegistry.beginWork(
                    for: "tv.vortx.downloads.background")
                fire(callbackA.completeFinalization())
                var interleavingReleases = 0
                var callbackBDrained = false
                var interleavingReleasedBeforeB = false
                let interleavingAdoption = interleavingRegistry.beginAdoption(
                    for: "tv.vortx.downloads.background")
                _ = interleavingAdoption.addCompletion {
                    if !callbackBDrained { interleavingReleasedBeforeB = true }
                    interleavingReleases += 1
                }
                interleavingAdoption.beginFinalization()
                fire(interleavingAdoption.finishEvents())
                fire(interleavingAdoption.completeFinalization())
                checks.check(
                    "A/B callback claims remain independently drainable",
                    callbackA === callbackB
                        && interleavingReleases == 0
                        && !interleavingReleasedBeforeB)
                callbackBDrained = true
                fire(callbackB.completeFinalization())
                checks.check(
                    "A/B callback claims release exactly after both drains",
                    interleavingReleases == 1 && !interleavingReleasedBeforeB)

                // HLS finalization owns a distinct session barrier. Completing HLS must release its own
                // adopted handler without consuming the pending byte-finalization work item.
                let exclusionRegistry = HLSBackgroundEventBarrierRegistry()
                let byteBarrier = exclusionRegistry.barrier(for: "tv.vortx.downloads.background")
                let hlsBarrier = exclusionRegistry.barrier(for: "tv.vortx.downloads.hls")
                var byteExclusionReleases = 0
                var hlsReleases = 0
                _ = byteBarrier.addCompletion { byteExclusionReleases += 1 }
                _ = hlsBarrier.addCompletion { hlsReleases += 1 }
                byteBarrier.beginFinalization()
                hlsBarrier.beginFinalization()
                fire(hlsBarrier.completeFinalization())
                fire(hlsBarrier.finishEvents())
                checks.check(
                    "HLS finalization never claims the byte barrier",
                    hlsBarrier !== byteBarrier
                        && hlsReleases == 1
                        && byteExclusionReleases == 0
                        && !byteBarrier.isReleased)
                fire(byteBarrier.finishEvents())
                fire(byteBarrier.completeFinalization())
                checks.check(
                    "byte barrier releases only after its own finish",
                    byteExclusionReleases == 1)

                // Hostile ordering: UIKit's finish signal arrives before the MainActor record persistence.
                // The adopted completion must remain held until the byte finalizer's defer completes.
                let success = HLSBackgroundEventBarrier()
                var persisted = false
                var releases = 0
                var releasedBeforePersistence = false
                _ = success.addCompletion {
                    if !persisted { releasedBeforePersistence = true }
                    releases += 1
                }
                success.beginFinalization()
                checks.check(
                    "byte finish-events waits for record persistence",
                    success.finishEvents().isEmpty && releases == 0 && !persisted)
                persisted = true
                fire(success.completeFinalization())
                checks.check(
                    "byte persistence releases adopted completion once",
                    !releasedBeforePersistence && releases == 1)

                // The error path returns from its MainActor task through the same defer.
                let error = HLSBackgroundEventBarrier()
                var errorReleases = 0
                _ = error.addCompletion { errorReleases += 1 }
                error.beginFinalization()
                func simulateErrorExit() {
                    defer { fire(error.completeFinalization()) }
                    do {
                        throw NSError(domain: "byte-contract", code: 1)
                    } catch {
                        return
                    }
                }
                simulateErrorExit()
                fire(error.finishEvents())
                checks.check("byte error exit completes its barrier work", errorReleases == 1)

                // Cancellation is an early return and must not strand the background launch transaction.
                let cancellation = HLSBackgroundEventBarrier()
                var cancellationReleases = 0
                _ = cancellation.addCompletion { cancellationReleases += 1 }
                cancellation.beginFinalization()
                func simulateCancellationExit() {
                    defer { fire(cancellation.completeFinalization()) }
                    guard false else { return }
                }
                simulateCancellationExit()
                fire(cancellation.finishEvents())
                checks.check(
                    "byte cancellation exit completes its barrier work",
                    cancellationReleases == 1)

                // Duplicate delegate callbacks each own one begin/defer pair. The barrier must wait for both,
                // then invoke UIKit's completion exactly once; an extra completion is harmless underflow.
                let duplicate = HLSBackgroundEventBarrier()
                var duplicateReleases = 0
                _ = duplicate.addCompletion { duplicateReleases += 1 }
                duplicate.beginFinalization()
                duplicate.beginFinalization()
                checks.check(
                    "duplicate byte callbacks cannot release early",
                    duplicate.finishEvents().isEmpty && duplicateReleases == 0)
                func simulateDuplicateCallback() {
                    defer { fire(duplicate.completeFinalization()) }
                    _ = duplicate.isReleased
                }
                simulateDuplicateCallback()
                checks.check(
                    "one duplicate callback does not release the pair",
                    duplicateReleases == 0)
                simulateDuplicateCallback()
                fire(duplicate.completeFinalization())
                checks.check(
                    "duplicate callbacks release exactly once",
                    duplicateReleases == 1)

                if checks.failures > 0 {
                    print("\\n\\(checks.failures) BYTE FINALIZATION CHECKS FAILED")
                    exit(1)
                }
                print("\\nALL BYTE FINALIZATION CHECKS PASS")
            }
        }
        """
        contract.check(
            "byte finalization ordering and callback contract passes",
            Contract.compilesAndRuns(byteFinalizationHarness, named: "byte-finalization"))

        let hlsGenerationHarness = """
        import Foundation

        \(barrierSource)
        \(registrySource)

        private func fire(_ handlers: [() -> Void]) {
            handlers.forEach { $0() }
        }

        private struct HLSGenerationChecks {
            var failures = 0

            mutating func check(_ name: String, _ condition: Bool) {
                if condition {
                    print("PASS  \\(name)")
                } else {
                    failures += 1
                    print("FAIL  \\(name)")
                }
            }
        }

        private final class HLSCompletionProjection {
            static let hlsSessionIdentifier = "tv.vortx.downloads.hls.\\(UUID().uuidString)"
            static let byteSessionIdentifier = "tv.vortx.downloads.background.\\(UUID().uuidString)"
            static let productionHLSCallbackUsesAtomicClaim = \(hlsCallbackUsesAtomicClaim)
            static let productionHLSCancellationUsesAtomicClaim = \(hlsCancellationUsesAtomicClaim)

            let backgroundEventBarriers = HLSBackgroundEventBarrierRegistry()

            func handleAssetTaskCompletion() -> HLSBackgroundEventBarrier {
                if Self.productionHLSCallbackUsesAtomicClaim {
                    return backgroundEventBarriers.beginWork(for: Self.hlsSessionIdentifier)
                }
                let barrier = backgroundEventBarriers.barrier(for: Self.hlsSessionIdentifier)
                barrier.beginFinalization()
                return barrier
            }

            func handleCancellation() -> HLSBackgroundEventBarrier? {
                guard Self.productionHLSCancellationUsesAtomicClaim else { return nil }
                return backgroundEventBarriers.beginWork(for: Self.hlsSessionIdentifier)
            }

            func adoptBackgroundEvents(_ completionHandler: @escaping () -> Void) -> HLSBackgroundEventBarrier {
                let barrier = backgroundEventBarriers.beginAdoption(for: Self.hlsSessionIdentifier)
                guard !barrier.addCompletion(completionHandler) else {
                    completionHandler()
                    return barrier
                }
                barrier.beginFinalization()
                return barrier
            }

            func finishHLS() -> [() -> Void] {
                backgroundEventBarriers.barrier(for: Self.hlsSessionIdentifier).finishEvents()
            }

            func complete(_ barrier: HLSBackgroundEventBarrier) -> [() -> Void] {
                barrier.completeFinalization()
            }

            func finishCancellationTask(
                _ barrier: HLSBackgroundEventBarrier,
                ownerExists: Bool,
                cleanupFinished: inout Bool
            ) {
                defer { fire(complete(barrier)) }
                guard ownerExists else { return }
                cleanupFinished = true
            }
        }

        @main
        private enum HLSGenerationHarness {
            static func main() {
                var checks = HLSGenerationChecks()

                // A completed old HLS drain must rotate before a new callback. Adoption/reconnect completion
                // must not consume the old eventsFinished bit before this cycle's finish callback.
                let staleProjection = HLSCompletionProjection()
                let oldHLS = staleProjection.backgroundEventBarriers.barrier(
                    for: HLSCompletionProjection.hlsSessionIdentifier)
                fire(oldHLS.finishEvents())
                let byteBarrier = staleProjection.backgroundEventBarriers.barrier(
                    for: HLSCompletionProjection.byteSessionIdentifier)
                let callback = staleProjection.handleAssetTaskCompletion()
                var staleReleases = 0
                var currentFinishObserved = false
                var releasedBeforeCurrentFinish = false
                let adopted = staleProjection.adoptBackgroundEvents {
                    if !currentFinishObserved { releasedBeforeCurrentFinish = true }
                    staleReleases += 1
                }
                fire(staleProjection.complete(callback))
                fire(staleProjection.complete(adopted))
                checks.check(
                    "HLS callback atomically rotates a completed stale drain",
                    HLSCompletionProjection.productionHLSCallbackUsesAtomicClaim
                        && oldHLS.generation < callback.generation
                        && callback === adopted
                        && callback !== byteBarrier
                        && staleReleases == 0
                        && !releasedBeforeCurrentFinish)
                currentFinishObserved = true
                fire(staleProjection.finishHLS())
                checks.check(
                    "HLS adopted completion waits for the current finish",
                    !releasedBeforeCurrentFinish && staleReleases == 1)

                // The inverse ordering has a live HLS callback when finishEvents arrives. Queued adoption must
                // reuse that exact generation until the callback's own deferred completion drains.
                let pendingProjection = HLSCompletionProjection()
                let pendingCallback = pendingProjection.handleAssetTaskCompletion()
                fire(pendingProjection.finishHLS())
                var pendingReleases = 0
                var pendingCallbackDrained = false
                var pendingReleasedBeforeDrain = false
                let pendingAdoption = pendingProjection.adoptBackgroundEvents {
                    if !pendingCallbackDrained { pendingReleasedBeforeDrain = true }
                    pendingReleases += 1
                }
                fire(pendingProjection.complete(pendingAdoption))
                checks.check(
                    "HLS callback-before-adoption reuses outstanding generation",
                    pendingCallback === pendingAdoption
                        && pendingReleases == 0
                        && !pendingReleasedBeforeDrain)
                pendingCallbackDrained = true
                fire(pendingProjection.complete(pendingCallback))
                checks.check(
                    "HLS callback-before-adoption releases after drain",
                    pendingReleases == 1 && !pendingReleasedBeforeDrain)

                // A cancellation callback queues its cleanup onto MainActor. finishEvents may race that queue,
                // so the callback must claim work synchronously and release only after cleanup's defer runs.
                let cancellationProjection = HLSCompletionProjection()
                let cancellationWork = cancellationProjection.handleCancellation()
                var cancellationReleases = 0
                var cancellationCleanupFinished = false
                var cancellationReleasedBeforeCleanup = false
                let cancellationAdoption = cancellationProjection.adoptBackgroundEvents {
                    if !cancellationCleanupFinished { cancellationReleasedBeforeCleanup = true }
                    cancellationReleases += 1
                }
                fire(cancellationProjection.finishHLS())
                fire(cancellationProjection.complete(cancellationAdoption))
                checks.check(
                    "HLS cancellation finish-events race remains held before cleanup",
                    HLSCompletionProjection.productionHLSCancellationUsesAtomicClaim
                        && cancellationWork === cancellationAdoption
                        && cancellationReleases == 0
                        && !cancellationReleasedBeforeCleanup)
                cancellationCleanupFinished = true
                if let cancellationWork {
                    fire(cancellationProjection.complete(cancellationWork))
                }
                checks.check(
                    "HLS cancellation releases exactly after cleanup defer",
                    cancellationReleases == 1 && !cancellationReleasedBeforeCleanup)

                let vanishedOwnerProjection = HLSCompletionProjection()
                let vanishedOwnerWork = vanishedOwnerProjection.handleCancellation()
                var vanishedOwnerReleases = 0
                var vanishedOwnerCleanupFinished = false
                let vanishedOwnerAdoption = vanishedOwnerProjection.adoptBackgroundEvents {
                    vanishedOwnerReleases += 1
                }
                fire(vanishedOwnerProjection.finishHLS())
                fire(vanishedOwnerProjection.complete(vanishedOwnerAdoption))
                if let vanishedOwnerWork {
                    vanishedOwnerProjection.finishCancellationTask(
                        vanishedOwnerWork,
                        ownerExists: false,
                        cleanupFinished: &vanishedOwnerCleanupFinished)
                    checks.check(
                        "HLS cancellation defer releases when weak owner is gone",
                        vanishedOwnerReleases == 1 && !vanishedOwnerCleanupFinished)
                } else {
                    checks.check("HLS cancellation with vanished owner claims work", false)
                }

                if checks.failures > 0 {
                    print("\\n\\(checks.failures) HLS GENERATION CHECKS FAILED")
                    exit(1)
                }
                print("\\nALL HLS GENERATION CHECKS PASS")
            }
        }
        """
        contract.check(
            "HLS executable generation trace passes",
            Contract.compilesAndRuns(hlsGenerationHarness, named: "hls-generation"))

        let productionProjectionHarness = """
        import Foundation

        \(barrierSource)
        \(registrySource)

        private final class ProjectionCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0

            func increment() {
                lock.lock(); defer { lock.unlock() }
                value += 1
            }

            var count: Int {
                lock.lock(); defer { lock.unlock() }
                return value
            }
        }

        private final class ProjectionGate: @unchecked Sendable {
            private let lock = NSLock()
            private var open = false
            private var waiters: [CheckedContinuation<Void, Never>] = []

            func signal() {
                lock.lock()
                guard !open else {
                    lock.unlock()
                    return
                }
                open = true
                let waiters = self.waiters
                self.waiters.removeAll()
                lock.unlock()
                waiters.forEach { $0.resume() }
            }

            func wait(registered: (@Sendable () -> Void)? = nil) async {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    if open {
                        lock.unlock()
                        continuation.resume()
                    } else {
                        waiters.append(continuation)
                        lock.unlock()
                        registered?()
                    }
                }
            }

            static func verifiesDuplicateSignals() async -> Bool {
                let gate = ProjectionGate()
                let firstRegistered = ProjectionGate()
                let secondRegistered = ProjectionGate()
                let firstWaiter = Task {
                    await gate.wait { firstRegistered.signal() }
                }
                await firstRegistered.wait()
                let secondWaiter = Task {
                    await gate.wait { secondRegistered.signal() }
                }
                await secondRegistered.wait()
                gate.signal()
                gate.signal()
                await firstWaiter.value
                await secondWaiter.value
                return true
            }
        }

        private struct ProjectionChecks {
            var failures = 0

            mutating func check(_ name: String, _ condition: Bool) {
                if condition {
                    print("PASS  \\(name)")
                } else {
                    failures += 1
                    print("FAIL  \\(name)")
                }
            }
        }

        @MainActor
        private final class ByteDownloadManagerProjection: NSObject, URLSessionDownloadDelegate {
            nonisolated let backgroundSessionIdentifier = "tv.vortx.downloads.background.\\(UUID().uuidString)"
            nonisolated let backgroundEventBarriers = HLSBackgroundEventBarrierRegistry()

            private(set) var finalizerEntered = 0
            private(set) var successPersisted = 0
            private(set) var cancellations = 0
            private(set) var retries = 0
            private(set) var failures = 0
            private(set) var finishObserved = false
            private var finalizerGate = ProjectionGate()
            private var finishGate = ProjectionGate()
            private var resultGate = ProjectionGate()
            private var releaseGate = ProjectionGate()

            private nonisolated static func finishBackgroundEventWork(_ barrier: HLSBackgroundEventBarrier?) {
                barrier?.completeFinalization().forEach { $0() }
            }

            private nonisolated func beginByteBackgroundEventWork(for session: URLSession) -> HLSBackgroundEventBarrier? {
                guard session.configuration.identifier == backgroundSessionIdentifier else { return nil }
                let barrier = backgroundEventBarriers.beginWork(for: backgroundSessionIdentifier)
                return barrier
            }

                func adoptBackgroundEvents(for identifier: String, completionHandler: @escaping () -> Void) {
                    let barrier = backgroundEventBarriers.beginAdoption(for: identifier)
                    guard !barrier.addCompletion(completionHandler) else {
                        completionHandler()
                        return
                    }
                    barrier.beginFinalization()
                    barrier.completeFinalization().forEach { $0() }
                }

                func seedOldUnadoptedDrain() {
                    let old = backgroundEventBarriers.barrier(for: backgroundSessionIdentifier)
                    _ = old.finishEvents()
                }

            func allowFinalization() {
                releaseGate.signal()
            }

            func resetFinalizationGate() {
                finishObserved = false
                finalizerGate = ProjectionGate()
                finishGate = ProjectionGate()
                resultGate = ProjectionGate()
                releaseGate = ProjectionGate()
            }

            func waitForFinalizerAndFinish() async {
                await finalizerGate.wait()
                await finishGate.wait()
            }

            func waitForResult() async {
                await resultGate.wait()
            }

            nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                        didFinishDownloadingTo location: URL) {
                let barrier = beginByteBackgroundEventWork(for: session)
                Task { @MainActor [weak self] in
                    defer { Self.finishBackgroundEventWork(barrier) }
                    guard let self else { return }
                    self.finalizerEntered += 1
                    self.finalizerGate.signal()
                    await self.releaseGate.wait()
                    self.successPersisted += 1
                    self.resultGate.signal()
                }
            }

            nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                guard let error else { return }
                let barrier = beginByteBackgroundEventWork(for: session)
                Task { @MainActor [weak self] in
                    defer { Self.finishBackgroundEventWork(barrier) }
                    guard let self else { return }
                    self.finalizerEntered += 1
                    self.finalizerGate.signal()
                    await self.releaseGate.wait()
                    switch (error as NSError).code {
                    case NSURLErrorCancelled:
                        self.cancellations += 1
                    case 42:
                        self.retries += 1
                    default:
                        self.failures += 1
                    }
                    self.resultGate.signal()
                }
            }

            nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
                guard let identifier = session.configuration.identifier else { return }
                let barrier = backgroundEventBarriers.barrier(for: identifier)
                Task { @MainActor [weak self] in
                    let handlers = barrier.finishEvents()
                    self?.finishObserved = true
                    self?.finishGate.signal()
                    handlers.forEach { $0() }
                }
            }
        }

        @main
        @MainActor
        private enum ProductionProjectionHarness {
            static func main() async {
                var checks = ProjectionChecks()
                checks.check(
                    "projection gate handles duplicate signals with multiple waiters",
                    await ProjectionGate.verifiesDuplicateSignals())
                let manager = ByteDownloadManagerProjection()
                let outputToken = UUID().uuidString
                let byteOutputURL = URL(fileURLWithPath: "/tmp/byte-projection-\\(outputToken).mp4")
                let foregroundOutputURL = URL(fileURLWithPath: "/tmp/foreground-projection-\\(outputToken).mp4")
                defer {
                    try? FileManager.default.removeItem(at: byteOutputURL)
                    try? FileManager.default.removeItem(at: foregroundOutputURL)
                }
                let backgroundSession = URLSession(
                    configuration: URLSessionConfiguration.background(
                        withIdentifier: manager.backgroundSessionIdentifier),
                    delegate: manager,
                    delegateQueue: nil)
                let backgroundTask = backgroundSession.downloadTask(
                    with: URL(string: "https://example.com/byte.mp4")!)

                let successCompletion = ProjectionCounter()
                manager.seedOldUnadoptedDrain()
                manager.urlSession(
                    backgroundSession,
                    downloadTask: backgroundTask,
                    didFinishDownloadingTo: byteOutputURL)
                manager.adoptBackgroundEvents(for: manager.backgroundSessionIdentifier) {
                    successCompletion.increment()
                }
                manager.urlSessionDidFinishEvents(forBackgroundURLSession: backgroundSession)
                await manager.waitForFinalizerAndFinish()
                checks.check(
                    "production projection holds success completion before persistence",
                    successCompletion.count == 0 && manager.successPersisted == 0)
                manager.allowFinalization()
                await manager.waitForResult()
                checks.check(
                    "production projection releases success after persistence",
                    manager.successPersisted == 1 && successCompletion.count == 1)

                manager.resetFinalizationGate()
                let cancellationCompletion = ProjectionCounter()
                manager.seedOldUnadoptedDrain()
                manager.urlSession(
                    backgroundSession,
                    task: backgroundTask,
                    didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
                manager.adoptBackgroundEvents(for: manager.backgroundSessionIdentifier) {
                    cancellationCompletion.increment()
                }
                manager.urlSessionDidFinishEvents(forBackgroundURLSession: backgroundSession)
                await manager.waitForFinalizerAndFinish()
                checks.check(
                    "production projection holds cancellation completion before exit",
                    cancellationCompletion.count == 0 && manager.cancellations == 0)
                manager.allowFinalization()
                await manager.waitForResult()
                checks.check(
                    "production projection releases cancellation after defer",
                    manager.cancellations == 1 && cancellationCompletion.count == 1)

                manager.resetFinalizationGate()
                let retryCompletion = ProjectionCounter()
                manager.seedOldUnadoptedDrain()
                manager.urlSession(
                    backgroundSession,
                    task: backgroundTask,
                    didCompleteWithError: NSError(domain: "projection", code: 42))
                manager.adoptBackgroundEvents(for: manager.backgroundSessionIdentifier) {
                    retryCompletion.increment()
                }
                manager.urlSessionDidFinishEvents(forBackgroundURLSession: backgroundSession)
                await manager.waitForFinalizerAndFinish()
                checks.check(
                    "production projection holds retry completion before policy result",
                    retryCompletion.count == 0 && manager.retries == 0)
                manager.allowFinalization()
                await manager.waitForResult()
                checks.check(
                    "production projection releases retry after defer",
                    manager.retries == 1 && retryCompletion.count == 1)

                manager.resetFinalizationGate()
                let failureCompletion = ProjectionCounter()
                manager.seedOldUnadoptedDrain()
                manager.urlSession(
                    backgroundSession,
                    task: backgroundTask,
                    didCompleteWithError: NSError(domain: "projection", code: 99))
                manager.adoptBackgroundEvents(for: manager.backgroundSessionIdentifier) {
                    failureCompletion.increment()
                }
                manager.urlSessionDidFinishEvents(forBackgroundURLSession: backgroundSession)
                await manager.waitForFinalizerAndFinish()
                checks.check(
                    "production projection holds terminal error completion before result",
                    failureCompletion.count == 0 && manager.failures == 0)
                manager.allowFinalization()
                await manager.waitForResult()
                checks.check(
                    "production projection releases terminal error after defer",
                    manager.failures == 1 && failureCompletion.count == 1)

                manager.resetFinalizationGate()
                let foregroundCompletion = ProjectionCounter()
                manager.adoptBackgroundEvents(for: manager.backgroundSessionIdentifier) {
                    foregroundCompletion.increment()
                }
                let foregroundSession = URLSession(configuration: .default)
                let foregroundTask = foregroundSession.downloadTask(
                    with: URL(string: "https://example.com/foreground.mp4")!)
                manager.urlSession(
                    foregroundSession,
                    downloadTask: foregroundTask,
                    didFinishDownloadingTo: foregroundOutputURL)
                manager.urlSessionDidFinishEvents(forBackgroundURLSession: backgroundSession)
                await manager.waitForFinalizerAndFinish()
                checks.check(
                    "production projection excludes unnamed foreground finalizer from background barrier",
                    foregroundCompletion.count == 1 && manager.successPersisted == 1)
                manager.allowFinalization()
                await manager.waitForResult()
                checks.check("foreground finalizer still completes", manager.successPersisted == 2)

                if checks.failures > 0 {
                    print("\\n\\(checks.failures) PRODUCTION PROJECTION CHECKS FAILED")
                    exit(1)
                }
                print("\\nALL PRODUCTION PROJECTION CHECKS PASS")
            }
        }
        """
        let projectionStressRuns = max(
            1,
            Int(ProcessInfo.processInfo.environment["VORTX_PROJECTION_STRESS_RUNS"] ?? "1") ?? 1)
        if projectionStressRuns == 1 {
            contract.check(
                "typechecked production callback projection passes",
                Contract.compilesAndRuns(productionProjectionHarness, named: "production-projection"))
        } else {
            for stressRun in 1...projectionStressRuns {
                contract.check(
                    "typechecked production callback projection stress run \(stressRun) passes",
                    Contract.compilesAndRuns(
                        productionProjectionHarness,
                        named: "production-projection-stress-\(stressRun)"))
            }
        }

        if contract.failures > 0 {
            print("\n\(contract.failures) CONTRACT CHECKS FAILED")
            exit(1)
        }
        print("\nALL CONTRACT CHECKS PASS")
    }
}
