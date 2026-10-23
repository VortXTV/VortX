import Foundation

@MainActor
private final class PreparationFixture {
    var owner = 1, profile = 1, generation = 1
    var target: Int?
    var captures = 0, preparations = 0
    var suspended: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    func prepare() async {
        preparations += 1
        await withCheckedContinuation {
            suspended = $0
            started?.resume(); started = nil
        }
    }
    func waitForStart() async {
        if suspended != nil { return }
        await withCheckedContinuation { started = $0 }
    }
}

@main
enum NativeProfileActionPreparationTests {
    @MainActor static func main() async throws {
        let selected = UUID(), later = UUID()
        var deferred = NativeProfileActionPreparation.DeferredSelection<Int>()
        deferred.request(selected, owner: 1)
        precondition(deferred.take(owner: 1, preparing: true, ready: false, profileExists: { _ in true }) == nil)
        precondition(deferred.profileID == selected)
        precondition(deferred.take(owner: 1, preparing: true, ready: true, profileExists: { _ in true }) == nil)
        precondition(deferred.take(owner: 1, preparing: false, ready: true, profileExists: { $0 == selected }) == selected)
        precondition(deferred.take(owner: 1, preparing: false, ready: true, profileExists: { _ in true }) == nil, "Open exactly once")
        for outcome in ["account-changed", "deleted", "failed", "cancelled", "later-choice"] {
            deferred.request(selected, owner: 1, preparing: true)
            if outcome == "cancelled" { deferred.cancel() }
            if outcome == "later-choice" { deferred.request(later, owner: 1, preparing: true) }
            let opened = deferred.take(owner: outcome == "account-changed" ? 2 : 1, preparing: false,
                                       ready: outcome != "failed", profileExists: { _ in outcome != "deleted" })
            precondition(opened == (outcome == "later-choice" ? later : nil), outcome)
            precondition(deferred.profileID == nil)
        }
        deferred.request(selected, owner: 1)
        precondition(deferred.take(owner: 1, preparing: false, ready: true, profileExists: { _ in true }) == nil,
                     "A terminal failure in a ready session must not automatically retry")
        deferred.request(selected, owner: 1)
        deferred.observePreparation(true) // Migration can begin after an action was admitted.
        precondition(deferred.take(owner: 1, preparing: false, ready: true, profileExists: { _ in true }) == selected)
        deferred.request(selected, owner: 1, preparing: true, accountRestorePreparing: true)
        precondition(deferred.waitedForAccountRestore)
        deferred.cancel()
        precondition(!deferred.waitedForAccountRestore)
        deferred.request(selected, owner: 1, preparing: true)
        precondition(!deferred.waitedForAccountRestore, "A manual retry under an old failed status is distinct from a failed queued restore")
        deferred.observePreparation(true, accountRestorePreparing: true)
        precondition(deferred.waitedForAccountRestore)
        deferred.cancel()
        // A cached owner/secondary and a newly entered profile all need the same mount admission.
        for kind in ["open-owner", "open-secondary", "save-new"] {
            for outcome in ["ready", "unavailable", "owner-changed", "profile-changed", "generation-changed", "cancelled"] {
                let f = PreparationFixture()
                let owner = f.owner, profile = f.profile, generation = f.generation
                let task = Task { @MainActor in
                    await NativeProfileActionPreparation.target(isCurrent: {
                        f.owner == owner && f.profile == profile && f.generation == generation
                    }, capture: { f.captures += 1; return f.target }, prepare: { await f.prepare() })
                }
                await f.waitForStart()
                precondition(f.captures == 1 && f.preparations == 1)
                if outcome != "unavailable" { f.target = 260 }
                if outcome == "owner-changed" { f.owner += 1 }
                if outcome == "profile-changed" { f.profile += 1 }
                if outcome == "generation-changed" { f.generation += 1 }
                if outcome == "cancelled" { task.cancel() }
                f.suspended?.resume(); f.suspended = nil
                let result = await task.value
                precondition(result == (outcome == "ready" ? 260 : nil), "\(kind): \(outcome)")
                precondition(f.captures == (outcome == "ready" || outcome == "unavailable" ? 2 : 1))
            }
        }
        let f = PreparationFixture(); f.target = 260
        let fast = await NativeProfileActionPreparation.target(isCurrent: { true },
            capture: { f.captures += 1; return f.target }, prepare: { await f.prepare() })
        precondition(fast == 260 && f.captures == 1 && f.preparations == 0)
        let cancelled = Task { @MainActor in
            await NativeProfileActionPreparation.target(isCurrent: { true },
                capture: { f.captures += 1; return f.target }, prepare: { await f.prepare() })
        }
        cancelled.cancel()
        let rejected = await cancelled.value
        precondition(rejected == nil && f.captures == 1 && f.preparations == 0)
        let bridge = try String(contentsOfFile: "app/SourcesShared/CoreBridge.swift", encoding: .utf8)
        let admission = bridge.components(separatedBy: "func prepareNativeProfileActionTarget")[1]
            .components(separatedBy: "var nativeProfileRecoveryMessage")[0]
        precondition(admission.contains("CredentialScopeRegistry.shared.isCurrent(admission.credential)"))
        precondition(admission.contains("ProfileStore.shared.activeID == admission.profileID"))
        precondition(admission.contains("guard case .native(nil) = admission.target else { return }"))
        precondition(admission.contains("await facade.settleNativeMutations()"))
        precondition(admission.contains("restoreNativeCheckpoint(credentialCapture: admission.credential, userInitiated: true)"))
        let picker = try String(contentsOfFile: "app/SourcesShared/ProfilesView.swift", encoding: .utf8)
        let resume = picker.components(separatedBy: "private func resumeDeferredSelection()")[1]
            .components(separatedBy: "private func commit(")[0]
        precondition(resume.contains("core.hasCertifiedNativeSession(capture: capture, profileID: store.activeID)"))
        precondition(resume.contains("pick(profile)"), "Deferred open rechecks the fresh roster PIN through pick")
        precondition(picker.contains("if profilesArePreparing { return nil }"), "In-progress restore must not display terminal error")
        guard let startupStart = bridge.range(of: "    func start() {"),
              let startupEnd = bridge.range(of: "    private func seedInitialState()", range: startupStart.upperBound..<bridge.endIndex) else {
            preconditionFailure("CoreBridge startup extraction boundary changed")
        }
        let startup = String(bridge[startupStart.lowerBound..<startupEnd.lowerBound])
        precondition(startup.contains("await VortXSyncManager.shared.hydrateEngineFromOwnedAddons()"))
        precondition(!startup.contains("restoreNativeCheckpoint()"), "Delayed startup must retain a certified resident session")
        let sync = try String(contentsOfFile: "app/SourcesShared/VortXSyncManager.swift", encoding: .utf8)
        let beforeRestore = sync.components(separatedBy: "func restoreNativeCheckpoint(")[1]
            .components(separatedBy: "if let pending = nativeCheckpointTask")[0]
        precondition(beforeRestore.contains("guard isSignedIn, isCurrent(capture), case .account = capture.scope else"))
        precondition(beforeRestore.contains("restore result=not_started reason=account_not_ready"))
        precondition(!beforeRestore.contains("VortxNativeSession("))
        precondition(!beforeRestore.contains("installNativeSession("))
        print("PASS profile readiness: 18 delayed mount cases, acknowledged fast path, cancellation, original owner/profile and authenticated mount fences, no stale-target upgrade")
    }
}
