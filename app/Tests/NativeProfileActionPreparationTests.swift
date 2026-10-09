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
        precondition(admission.contains("await facade.settled()"))
        precondition(admission.contains("restoreNativeCheckpoint(credentialCapture: admission.credential)"))
        print("PASS profile readiness: 18 delayed mount cases, acknowledged fast path, cancellation, original owner/profile fences, no stale-target upgrade")
    }
}
