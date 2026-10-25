import Foundation

/// Source-wiring coverage complements, never replaces, genuine capability/provider behavioral tests.
/// Run from the repository root only after composing12 +12b. No credentials/network/native calls.
@main
struct TraktWorkerCapabilityContractTests {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        func section(_ text: String, _ start: String, _ end: String) -> String {
            guard let lower = text.range(of: start),
                  let upper = text.range(of: end, range: lower.upperBound..<text.endIndex) else {
                preconditionFailure("missing source boundary: \(start) / \(end)")
            }
            return String(text[lower.lowerBound..<upper.lowerBound])
        }
        var checks = 0
        func check(_ result: Bool, _ label: String) {
            precondition(result, label)
            checks += 1
        }
        let shadow = try source("app/SourcesShared/TraktPlaybackShadow.swift")
        let producer = try source("app/SourcesShared/TraktHomeNextEpisodeProducer.swift")
        let simkl = try source("app/SourcesShared/SIMKLContinueWatchingShadow.swift")
        let home = try source("app/SourcesShared/HomeContinueWatchingSelection.swift")
        let ui = try source("app/SourcesiOS/iOSRootView.swift")
        let core = try source("app/SourcesShared/CoreBridge.swift")
        let refresh = section(shadow, "    private func refreshIfStale(context:", "    /// Force a pull")
        let finish = section(shadow, "    private func finishRefresh(", "    private func activitySnapshot(")
        let commit = section(shadow, "    private func commitPlayback(", "    /// Gate on")
        let pull = section(shadow, "    private func pullPlayback(", "    /// Fold one")
        let dataNotice = section(shadow, "    private static func postChanged(context:", "\n}")
        for (name, body) in [("refresh", refresh), ("finish", finish), ("commit", commit),
                             ("pull", pull), ("data notification", dataNotice)] {
            check(!body.contains("CoreBridge.shared") && !body.contains("core: .shared")
                && !body.contains("captureNativePlaybackReadCapability"), "no worker recapture: " + name)
            check(body.contains("owner:"), "explicit original capability: " + name)
        }
        check(refresh.contains("refreshIfStale(context: context, owner: owner, sessionID: sessionID)"),
              "auth reset recursion preserves original provider session and native capability")
        check(!refresh.contains("self.refreshIfStale()"), "stale worker cannot admit replacement owner")
        check(finish.contains("generationMatches && context.isCurrent(owner: owner)")
            && finish.contains("if state.refreshingGeneration == gen"), "stale completion releases only matching throttle flight")
        check(finish.contains("storage.withLock { state in")
            && commit.contains("return storage.withLock { state in")
            && refresh.contains("let admission: RefreshAdmission = storage.withLock { state in"),
              "refresh admission, release and durable publication share checked cache state")
        check(commit.contains("context.isCurrent(owner: owner), Self.saveCache(")
            && commit.contains("context.isCurrent(owner: owner), TraktPlaybackSnapshotPolicy.canCommit(")
            && commit.contains("_ = Self.resetCache()"), "save-before-memory and post-save rejection remain wired")
        check(pull.contains("guard allLegsSucceeded else { return }")
            && pull.contains("Self.postChanged(context: context, owner: owner)"), "whole provider result and original notice retained")
        check(!producer.contains("intent.isCurrent()") && !producer.contains("intent.isCurrent(core: core)"),
              "next-episode worker/offer never uses default current Bridge")
        check(producer.contains("private struct Owner: Hashable, Sendable")
            && producer.contains("lhs.intent == rhs.intent")
            && producer.contains("hasher.combine(intent)"), "existing Intent cache key equivalence preserved")
        check(producer.contains("owner.intent.isCurrent(owner: owner.capability)")
            && producer.contains("await consumer.refresh(owner: original, session: session, native: lease)"),
              "inventory, owner and consumer share original capability")
        let request = section(producer, "    func requestRefresh(", "    func offers(")
        let beforeTask = section(request, "    func requestRefresh(", "        Task(priority:")
        check(beforeTask.contains("captureNativePlaybackReadCapability(target)")
            && beforeTask.contains("captureNativeExternalCWRead(target: target)"),
              "both native admissions precede provider task")
        let afterTask = request.components(separatedBy: "        Task(priority:").last ?? ""
        check(!afterTask.contains("core.") && afterTask.contains("original.capability"), "Task does not retain mixed Bridge")
        check(producer.contains("intent.isCurrent(owner: owner), intent.traktSessionID == sessionID"),
              "later offer validation retains original read capability")
        check(!simkl.contains("core: .shared") && !simkl.contains("CoreBridge.shared"), "SIMKL worker/cache never looks up Bridge")
        check(simkl.contains("defer { self.finishRefresh(context: expected, session: expectedSession, generation: captured) }")
            && simkl.contains("generation &+= 1\n        running = true"), "SIMKL attempt-specific deferred release")
        check(simkl.contains("generation == captured, context == expected, session == expectedSession")
            && simkl.contains("expected.isCurrent(owner: owner)"), "SIMKL commit retains cache/provider/native fences")
        check(home.contains("@MainActor\n        func isCurrent(core: CoreBridge = .shared)")
            && home.contains("@MainActor\n    static func captureContext(core: CoreBridge = .shared)"),
              "UI singleton defaults explicitly owner-isolated")
        check(home.contains("let providerOwner = context.nativeTarget.flatMap")
            && home.contains("owner: owner, paused: selection.items"), "one presentation read capability flows through offers")
        check(home.contains("struct Context: Hashable, Sendable")
            && home.contains("struct Intent: Hashable, Sendable")
            && !home.contains("let owner: CoreBridge.NativePlaybackReadCapability"), "capability not embedded into Context/Intent identity")
        check(ui.contains("@MainActor\n    func isCurrent(traktSessionID currentSessionID:"), "plain iOS provenance wrapper is an explicit UI caller")
        check(core.contains("struct NativePlaybackReadCapability: Sendable")
            && core.contains("func captureNativePlaybackReadCapability(_ target:"), "actual prerequisite is present")
        print("PASS \(checks) provider capability source-wiring checks; no runtime/native proof claimed")
    }
}
