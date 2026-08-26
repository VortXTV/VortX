// Dependency-free executable contract for the pure download scheduler and source classifier seams.
//
// Run from the repository root:
//   swiftc -parse-as-library app/Tests/DownloadSchedulerSafetyContractTests.swift \
//     -o /tmp/vortx-download-scheduler-contract && /tmp/vortx-download-scheduler-contract

import Foundation

private struct Checks {
    var failures = 0

    mutating func check(_ name: String, _ condition: Bool) {
        if condition {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)")
        }
    }
}

private enum ContractSupport {
    static func sourceURL() -> URL? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return [
            cwd.appendingPathComponent("app/SourcesShared/DownloadManager.swift"),
            cwd.appendingPathComponent("SourcesShared/DownloadManager.swift")
        ].first { FileManager.default.fileExists(atPath: $0.path) }
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
            if source[cursor] == "{" { depth += 1 }
            if source[cursor] == "}" {
                depth -= 1
                if depth == 0 { return String(source[markerRange.lowerBound...cursor]) }
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    static func compilesAndRuns(_ source: String) -> Bool {
        let token = UUID().uuidString
        let swift = URL(fileURLWithPath: "/tmp/vortx-download-scheduler-\(token).swift")
        let executable = URL(fileURLWithPath: "/tmp/vortx-download-scheduler-\(token)")
        defer {
            try? FileManager.default.removeItem(at: swift)
            try? FileManager.default.removeItem(at: executable)
        }
        do {
            try source.write(to: swift, atomically: true, encoding: .utf8)
            let compile = Process()
            compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
            compile.arguments = [
                "-parse-as-library", "-strict-concurrency=complete", "-warnings-as-errors",
                swift.path, "-o", executable.path
            ]
            let compilePipe = Pipe()
            compile.standardOutput = compilePipe
            compile.standardError = compilePipe
            try compile.run()
            compile.waitUntilExit()
            let compileOutput = String(
                data: compilePipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if !compileOutput.isEmpty { print("  swiftc seam:\n\(compileOutput)") }
            guard compile.terminationStatus == 0 else { return false }

            let run = Process()
            run.executableURL = executable
            let runPipe = Pipe()
            run.standardOutput = runPipe
            run.standardError = runPipe
            try run.run()
            run.waitUntilExit()
            let runOutput = String(data: runPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if !runOutput.isEmpty { print(runOutput, terminator: "") }
            return run.terminationStatus == 0
        } catch {
            print("  contract could not run: \(error)")
            return false
        }
    }
}

@main
private enum DownloadSchedulerSafetyContractTests {
    static func main() {
        guard let sourceURL = ContractSupport.sourceURL(),
              let source = try? String(contentsOf: sourceURL, encoding: .utf8),
              let seam = ContractSupport.sourceSection(
                source,
                from: "enum DownloadStartDisposition:",
                through: "/// The file-writing core") else {
            fatalError("DownloadManager scheduler seam not found")
        }

        var checks = Checks()
        let fillSource = ContractSupport.functionSource(source, marker: "private func fillAvailableSlots()") ?? ""
        let selfHealSource = ContractSupport.sourceSection(
            source,
            from: "case .selfHealRestart:",
            through: "case .hardFail:") ?? ""
        let activeWeightSource = ContractSupport.functionSource(
            source, marker: "private var activeWeight: Int") ?? ""
        let downloadSource = ContractSupport.functionSource(source, marker: "func download(") ?? ""
        let resumeSource = ContractSupport.functionSource(source, marker: "func resume(id: UUID)") ?? ""
        let reconnectSource = ContractSupport.functionSource(
            source, marker: "private func reconnectInFlightDownloads(") ?? ""
        let finishReconciliationSource = ContractSupport.functionSource(
            source, marker: "private func finishReconciliationCallback(") ?? ""
        checks.check(
            "production drain uses coordinator reentrancy guard",
            fillSource.contains("guard schedulerCoordinator.beginDrain() else { return }")
                && fillSource.contains("if schedulerCoordinator.finishDrain()")
                && fillSource.contains("fillAvailableSlots()")
                && fillSource.contains("DownloadSchedulerCoordinator.drain"))
        checks.check(
            "production reconciliation claims every selected callback",
            reconnectSource.contains(
                "schedulerCoordinator.beginReconciliation(callbackCount: sessions.count)"))
        checks.check(
            "only the final reconciliation callback refills slots",
            finishReconciliationSource.contains("Self.finishBackgroundEventWork(barrier)")
                && finishReconciliationSource.contains(
                    "schedulerCoordinator.completeReconciliationCallback()")
                && finishReconciliationSource.contains("fillAvailableSlots()"))
        checks.check(
            "every async reconciliation callback defers its claim release",
            source.components(separatedBy: "defer { finishReconciliationCallback(barrier: barrier) }").count - 1 >= 2)
        checks.check(
            "recursive queue starter is removed",
            !source.contains("private func startNextQueued()"))
        checks.check(
            "self-heal requeues before the scheduler drains",
            selfHealSource.range(of: "prependToQueueOrder(id)")?.lowerBound ?? selfHealSource.endIndex
                < selfHealSource.range(of: "fillAvailableSlots()")?.lowerBound ?? selfHealSource.startIndex)
        checks.check(
            "self-heal never starts a task directly",
            !selfHealSource.contains("startTask("))
        checks.check(
            "initial and resume paths only request scheduler draining",
            downloadSource.contains("fillAvailableSlots()")
                && resumeSource.contains("fillAvailableSlots()")
                && !downloadSource.contains("task.resume()")
                && !resumeSource.contains("task.resume()"))
        checks.check(
            "HLS marker survives relaunch",
            source.contains("record.localFilename.hasSuffix(\".movpkg\")"))
        checks.check(
            "suspended HLS is excluded from active weight",
            activeWeightSource.contains("state == .downloading"))
        checks.check(
            "HLS lifecycle callbacks refill aggregate slots",
            source.components(separatedBy: "self.fillAvailableSlots()").count - 1 >= 3)

        let harness = """
        import Foundation

        \(seam)

        private struct HarnessChecks {
            var failures = 0
            mutating func check(_ name: String, _ condition: Bool) {
                if condition { print("PASS  \\(name)") }
                else { failures += 1; print("FAIL  \\(name)") }
            }
        }

        private final class ReentrantDrainHarness {
            var coordinator = DownloadSchedulerCoordinator()
            var queued = ["A-byte"]
            var started: [String] = []
            var reentrantAttempts = 0
            var coalescedPasses = 0
            var maximumActiveWeight = 0
            let limit = 2

            func fill() {
                guard coordinator.beginDrain() else {
                    reentrantAttempts += 1
                    return
                }
                defer {
                    if coordinator.finishDrain() {
                        coalescedPasses += 1
                        fill()
                    }
                }
                var projectedWeight = started.count
                let snapshot = queued
                DownloadSchedulerCoordinator.drain(
                    limit: limit,
                    activeWeight: &projectedWeight,
                    queued: snapshot,
                    transport: { $0.hasSuffix("hls") ? .hls : .byte },
                    start: { item in
                        queued.removeAll { $0 == item }
                        if item == "A-byte" {
                            queued.append("B-hls")
                            fill()
                        }
                        started.append(item)
                        maximumActiveWeight = max(maximumActiveWeight, started.count)
                        return .started
                    })
            }
        }

        @main
        private enum SchedulerHarness {
            static func main() {
                var checks = HarnessChecks()

                var active = 0
                var started: [String] = []
                let forward = DownloadSchedulerCoordinator.drain(
                    limit: 1,
                    activeWeight: &active,
                    queued: ["rejected-head", "valid-second"],
                    transport: { _ in .byte },
                    start: { item in
                        if item == "rejected-head" { return .rejected }
                        started.append(item)
                        return .started
                    })
                checks.check(
                    "rejected head permits forward progress",
                    forward == [.rejected, .started] && started == ["valid-second"] && active == 1)

                active = 0
                started = []
                _ = DownloadSchedulerCoordinator.drain(
                    limit: 1,
                    activeWeight: &active,
                    queued: ["self-heal", "ordinary"],
                    transport: { _ in .byte },
                    start: { item in started.append(item); return .started })
                checks.check(
                    "self-heal admission respects the cap",
                    active == 1 && started == ["self-heal"])

                active = 0
                started = []
                let transports: [DownloadSchedulerCoordinator.Transport] = [.hls, .byte, .hls]
                _ = DownloadSchedulerCoordinator.drain(
                    limit: 2,
                    activeWeight: &active,
                    queued: Array(transports.indices),
                    transport: { transports[$0] },
                    start: { item in started.append(String(item)); return .started })
                checks.check(
                    "mixed HLS and byte work shares one cap",
                    active == 2 && started == ["0", "1"])

                let reentrant = ReentrantDrainHarness()
                reentrant.fill()
                checks.check(
                    "synchronous reentrant queue insertion coalesces after release",
                    reentrant.reentrantAttempts == 1
                        && reentrant.coalescedPasses == 1
                        && reentrant.started == ["A-byte", "B-hls"]
                        && reentrant.maximumActiveWeight == 2
                        && reentrant.queued.isEmpty
                        && !reentrant.coordinator.drainRequested
                        && reentrant.coordinator.admissionAllowed)

                var reconnect = DownloadSchedulerCoordinator()
                reconnect.beginReconciliation(callbackCount: 2)
                active = 0
                started = []
                let admittedBeforeCallbacks = reconnect.beginDrain()
                let firstCompletedLast = reconnect.completeReconciliationCallback()
                let admittedAfterFirst = reconnect.beginDrain()
                active = 1
                let secondCompletedLast = reconnect.completeReconciliationCallback()
                let admittedAfterSecond = reconnect.beginDrain()
                let afterSecond = DownloadSchedulerCoordinator.drain(
                    limit: 2,
                    activeWeight: &active,
                    queued: ["queued-byte", "queued-hls"],
                    transport: { $0.hasSuffix("hls") ? .hls : .byte },
                    start: { item in started.append(item); return .started })
                let reconnectRequestedAnotherPass = reconnect.finishDrain()
                checks.check(
                    "delayed reconnect gates until all callbacks adopt active work",
                    !admittedBeforeCallbacks
                        && !admittedAfterFirst
                        && !firstCompletedLast
                        && secondCompletedLast
                        && admittedAfterSecond
                        && !reconnectRequestedAnotherPass
                        && afterSecond == [.started]
                        && started == ["queued-byte"]
                        && active == 2)

                var overlapping = DownloadSchedulerCoordinator()
                overlapping.beginReconciliation(callbackCount: 1)
                overlapping.beginReconciliation(callbackCount: 2)
                let overlapFirst = overlapping.completeReconciliationCallback()
                let overlapSecond = overlapping.completeReconciliationCallback()
                let overlapThird = overlapping.completeReconciliationCallback()
                checks.check(
                    "overlapping reconnect claims open admission only once at zero",
                    !overlapFirst && !overlapSecond && overlapThird && overlapping.admissionAllowed)

                var current = "paused"
                let stale = current
                current = "queued"
                let returned = DownloadSchedulerCoordinator.postMutationValue(stale) { current }
                checks.check("paused duplicate returns post-mutation state", returned == "queued")

                let extensionless = URL(string: "https://cdn.example.test/signed/manifest?token=.m3u8")!
                let explicitPath = URL(string: "https://cdn.example.test/master.m3u8?token=abc")!
                checks.check(
                    "unknown extensionless source follows byte behavior",
                    DownloadSourceClassifier.classify(url: extensionless, hintedFilename: nil) == .byte)
                checks.check(
                    "exact URL path extension classifies HLS",
                    DownloadSourceClassifier.classify(url: explicitPath, hintedFilename: nil) == .hls)
                checks.check(
                    "explicit filename hint classifies extensionless HLS",
                    DownloadSourceClassifier.classify(
                        url: extensionless, hintedFilename: "episode-master.m3u8") == .hls)

                if checks.failures > 0 { exit(1) }
                print("ALL SCHEDULER SAFETY CHECKS PASS")
            }
        }
        """
        checks.check("extracted scheduler and classifier seam passes", ContractSupport.compilesAndRuns(harness))

        if checks.failures > 0 {
            print("\n\(checks.failures) DOWNLOAD SCHEDULER CONTRACT CHECKS FAILED")
            exit(1)
        }
        print("\nALL DOWNLOAD SCHEDULER CONTRACT CHECKS PASS")
    }
}
