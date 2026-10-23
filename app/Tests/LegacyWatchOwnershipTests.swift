import Foundation

enum LegacyWatchOwnershipTests {
    struct Owner: Equatable, Sendable { let account: String; let generation: UInt64 }
    @MainActor private final class CurrentState {
        var owner: Owner
        var session: UUID
        var profile: UUID
        var slot = "primary"
        var token: String? = "token-A"
        var usesEngineHistory = false
        var sends = 0
        init(owner: Owner, session: UUID, profile: UUID) {
            self.owner = owner; self.session = session; self.profile = profile
        }
    }
    @MainActor static func run(root: URL) async throws {
        func check(_ value: Bool, _ message: String) { precondition(value, message) }
        let profile = UUID(), otherProfile = UUID(), owner = Owner(account: "A", generation: 7)
        let session = LegacyWatchOwnership.session()
        let captured = LegacyWatchOwnership.Capture(owner: owner, session: session, profileID: profile, slot: "primary", token: "token-A")
        let snapshot = Data("exact retained watch snapshot".utf8)
        let state = CurrentState(owner: owner, session: session, profile: profile)
        let current: @MainActor () -> Bool = {
            captured.matches(owner: state.owner, session: state.session, profileID: state.profile,
                usesEngineHistory: state.usesEngineHistory, slot: state.slot, token: state.token)
        }
        @MainActor func rejected() async throws {
            do {
                _ = try await LegacyWatchOwnership.perform(isCurrent: current) { state.sends += 1; return "sent" }
                preconditionFailure("Retired snapshot acquired transport authority")
            } catch is CancellationError {}
        }
        check(current(), "unchanged owner/epoch/profile/slot/token positive control")
        state.token = "token-B"; try await rejected(); state.token = "token-A"
        state.owner = Owner(account: "B", generation: 8); try await rejected(); state.owner = owner
        state.owner = Owner(account: "A", generation: 9); try await rejected(); state.owner = owner
        state.profile = otherProfile; try await rejected(); state.profile = profile
        state.slot = "another-slot"; try await rejected(); state.slot = "primary"
        state.token = nil; try await rejected(); state.token = "token-A"
        state.usesEngineHistory = true; try await rejected(); state.usesEngineHistory = false
        LegacyWatchOwnership.invalidateSession(); LegacyWatchOwnership.invalidateSession()
        state.session = LegacyWatchOwnership.session(); try await rejected(); state.session = session
        check(state.sends == 0 && snapshot == Data("exact retained watch snapshot".utf8), "rejected/ABA work never sends or consumes retained data")
        let accepted = try await LegacyWatchOwnership.perform(isCurrent: current) { state.sends += 1; return "accepted" }
        check(accepted == "accepted" && state.sends == 1, "unchanged transport is allowed once")
        var published = false
        do {
            _ = try await LegacyWatchOwnership.perform(isCurrent: current) { state.sends += 1; state.session = UUID(); return "late" }
            published = true
        } catch is CancellationError {}
        check(!published && state.sends == 2, "in-flight result cannot acknowledge or publish for a later session")
        let cancellation = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await LegacyWatchOwnership.perform(isCurrent: { true }) { () -> Int in preconditionFailure("Cancelled work invoked transport") }
                preconditionFailure("Cancelled work was accepted")
            } catch is CancellationError {}
        }
        try await cancellation.value
        let exact = LegacyWatchOwnership.Capture(owner: owner, session: session, profileID: profile, slot: "primary", token: "é")
        check(!exact.matches(owner: owner, session: session, profileID: profile, usesEngineHistory: false, slot: "primary", token: "e\u{301}"), "credential matching is exact UTF8, not Unicode equivalence")
        for failed in [nil, Data("{".utf8), Data("{\"result\":{}}".utf8), Data("{\"result\":[{}]}".utf8), Data("{\"result\":[],\"error\":\"failure\"}".utf8)] as [Data?] {
            let inspection = LegacyProfileRecoveryPolicy.inspection(failed)
            check(!inspection.inspectionSucceeded, "failed/malformed listing remains unknown, never clean")
            check(LegacyProfileRecoveryPolicy.notice(after: inspection, previous: LegacyProfileRecoveryPolicy.recoveryNotice) == LegacyProfileRecoveryPolicy.recoveryNotice, "failed listing preserves previous recovery warning")
        }
        let clean = LegacyProfileRecoveryPolicy.inspection(Data("{\"result\":[]}".utf8))
        check(clean.inspectionSucceeded && !clean.requiresSafeRepair, "successful empty listing is a clean positive control")
        check(LegacyProfileRecoveryPolicy.notice(after: clean, previous: LegacyProfileRecoveryPolicy.recoveryNotice) == nil, "only a successful clean scan clears its recovery warning")
        check(LegacyProfileRecoveryPolicy.notice(after: clean, previous: LegacyProfileRecoveryPolicy.mirrorNotice) == LegacyProfileRecoveryPolicy.mirrorNotice, "clean inspection cannot clear unrelated mirror capacity warning")
        let profiles = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/Profiles.swift"), encoding: .utf8)
        let start = profiles.range(of: "private func schedulePushWatch()")!.lowerBound
        let end = profiles.range(of: "private func loadWatchCache()", range: start..<profiles.endIndex)!.lowerBound
        let scheduling = String(profiles[start..<end])
        check(scheduling.range(of: "let capturedKey =")!.lowerBound < scheduling.range(of: "Task.sleep")!.lowerBound, "actual caller captures credential before debounce")
        check(scheduling.contains("authKey: capturedKey, isCurrent: isCurrent") && scheduling.components(separatedBy: "guard isCurrent()").count == 3, "actual caller sends captured token and fences transport plus result")
        check(scheduling.contains("CredentialScopeRegistry.shared.capture()") && scheduling.contains("LegacyWatchOwnership.session()"), "actual caller binds account generation and streaming session epoch")
        check(scheduling.contains("Keychain.confirmedString(slot)") && scheduling.contains("Keychain.confirmedString(currentSlot)"), "missing or uncertain durable credentials cannot authorize a mirror write")
        check(profiles.contains("CredentialScopeRegistry.shared.isCurrent(inspectionOwner)") && profiles.contains("LegacyWatchOwnership.session() == inspectionSession"), "late recovery inspection also cannot publish across owner/session ABA")
        let lifecycleParts = profiles.components(separatedBy: "// BEGIN legacy-watch lifecycle projection")
        check(lifecycleParts.count == 2, "actual lifecycle projection has one entry marker")
        let lifecycleTail = lifecycleParts[1].components(separatedBy: "// END legacy-watch lifecycle projection.")
        check(lifecycleTail.count == 2, "actual lifecycle projection has one exit marker")
        let lifecycle = lifecycleTail[0]
        check(lifecycle.contains("let retiresSession = activeID != newValue")
            && lifecycle.contains("!= Self.legacyWatchBinding(in: newValue, activeID: activeID)"),
              "profile selection and same-ID roster binding changes compare identity before publication")
        for stack in ["legacyRosterMutationRetirements", "legacySelectionMutationRetirements"] {
            check(lifecycle.contains(stack + ".append(retiresSession)") && lifecycle.contains(stack + ".removeLast()"),
                  "nested profile publication retains each setter entry decision in its own LIFO stack")
        }
        check(lifecycle.components(separatedBy: "LegacyWatchOwnership.beginProfileMutation(retire: retiresSession)").count == 3
            && lifecycle.components(separatedBy: "LegacyWatchOwnership.endProfileMutation()").count == 3,
              "every roster and selection assignment brackets publication, including nonmaterial setters")
        let auth = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/StremioAccount.swift"), encoding: .utf8)
        for boundary in ["private static func storeAuthKey(_ value: String?, account: String) {", "private func beginAuthOperation() -> AuthOperationContext {", "func reloadForActiveProfile(preservingSignInError message: String? = nil) {", "func signOut() {"] {
            check(auth.contains(boundary + "\n        LegacyWatchOwnership.invalidateSession()"), "actual credential lifecycle advances epoch: \(boundary)")
        }
        let sync = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/ProfileSync.swift"), encoding: .utf8)
        check(sync.contains("return try await LegacyWatchOwnership.perform(isCurrent: isCurrent)"), "actual watch transport uses pre/post admission")
        check(sync.contains("LegacyProfileRecoveryPolicy.inspection(try? await post"), "actual inspection distinguishes unavailable from clean")
        print("Legacy watch ownership: account/token/profile/slot/epoch/ABA/cancellation fences, post-response rejection, immutable snapshot and failed/malformed inspection notice preservation passed")
    }
}
