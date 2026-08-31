// Run from repository root:
// xcrun swiftc -warnings-as-errors -o /tmp/playback-mutation-owner \
//   app/SourcesShared/PlaybackMutationOwnershipPolicy.swift \
//   app/Tests/PlaybackMutationOwnershipPolicyTests.swift && /tmp/playback-mutation-owner

import Foundation

private typealias Policy = PlaybackMutationOwnershipPolicy
private var failures = 0

private struct CacheEntry: Codable, Equatable { let value: Int }

private func check(_ condition: Bool, _ name: String) {
    if condition { print("PASS  \(name)") }
    else { failures += 1; print("FAIL  \(name)") }
}

@main
private struct PlaybackMutationOwnershipPolicyTests {
    static func main() {
        let owner = UUID()
        let overlay = UUID()
        let replacement = UUID()
        let account = "stremiox.auth"
        let ownerContext = Policy.Context(activeProfileID: owner, activeUsesEngineHistory: true,
                                          activeKeychainAccount: account, activeUID: "owner-uid",
                                          extantOverlayProfileIDs: [overlay])
        let overlayContext = Policy.Context(activeProfileID: overlay, activeUsesEngineHistory: false,
                                            activeKeychainAccount: account, activeUID: "owner-uid",
                                            extantOverlayProfileIDs: [overlay])
        let replacementContext = Policy.Context(activeProfileID: replacement, activeUsesEngineHistory: false,
                                                activeKeychainAccount: account, activeUID: "owner-uid",
                                                extantOverlayProfileIDs: [overlay, replacement])
        let ownerTarget = Policy.Target.engine(profileID: owner, keychainAccount: account, uid: "owner-uid")
        let overlayTarget = Policy.Target.overlay(profileID: overlay)
        let settledOwner = Policy.SettledAccountBinding(profileID: owner, keychainAccount: account,
                                                        credentialFingerprint: "fp", uid: "owner-uid", generation: 1)
        let staleEngineAForSelectedB = Policy.SettledAccountBinding(profileID: replacement,
                                                                      keychainAccount: account,
                                                                      credentialFingerprint: "fp-b", uid: "owner-uid", generation: 2)
        let restoredProof = Policy.AuthenticatedAccountProof(profileID: owner, keychainAccount: account,
                                                             credentialFingerprint: "fp", uid: "owner-uid", generation: 1)
        let rotatedBinding = Policy.SettledAccountBinding(profileID: owner, keychainAccount: account,
                                                          credentialFingerprint: "rotated", uid: "owner-uid", generation: 2)

        check(Policy.allows(ownerTarget, in: ownerContext), "owner callback writes while its account remains active")
        check(!Policy.allows(ownerTarget, in: overlayContext), "owner to overlay switch rejects account callback")
        check(Policy.allows(overlayTarget, in: ownerContext), "overlay to owner callback retains captured overlay target")
        check(Policy.allows(overlayTarget, in: replacementContext), "forced active replacement cannot redirect overlay callback")
        check(!Policy.allows(overlayTarget, in: .init(activeProfileID: owner, activeUsesEngineHistory: true,
                                                       activeKeychainAccount: account, activeUID: "owner-uid",
                                                       extantOverlayProfileIDs: [])),
              "removed overlay rejects stale callback")
        check(!Policy.allows(Policy.Target.engine(profileID: owner, keychainAccount: account, uid: "old"),
                             in: ownerContext), "account uid replacement rejects async engine completion")
        check(!Policy.allows(Policy.Target.engine(profileID: owner, keychainAccount: account, uid: nil),
                             in: ownerContext), "unhydrated launch identity is not a wildcard")
        check(Policy.allowsAccountMutation(ownerTarget, in: ownerContext),
              "owner target may dispatch an account mutation")
        check(!Policy.allowsAccountMutation(overlayTarget, in: ownerContext),
              "overlay target may never dispatch an account mutation")
        check(Policy.settle(restoredProof, activeProfileID: owner, activeUsesEngineHistory: true,
                            activeKeychainAccount: account, activeCredentialFingerprint: "fp",
                            engineUID: "owner-uid") == settledOwner,
              "restored logged-in engine requires and accepts independently authenticated token identity")
        check(Policy.settle(restoredProof, activeProfileID: owner, activeUsesEngineHistory: true,
                            activeKeychainAccount: account, activeCredentialFingerprint: "fp",
                            engineUID: "owner-uid") != nil,
              "same-UID reauthentication settles from authenticated proof rather than uid change")
        let selectedBProof = Policy.AuthenticatedAccountProof(profileID: replacement, keychainAccount: account,
                                                              credentialFingerprint: "fp-b", uid: "b-uid", generation: 2)
        check(Policy.settle(selectedBProof, activeProfileID: replacement, activeUsesEngineHistory: true,
                            activeKeychainAccount: account, activeCredentialFingerprint: "fp-b",
                            engineUID: "owner-uid") == nil,
              "selected B remains unresolved while engine ctx still reports A")
        check(!Policy.bindingIsCurrent(settledOwner, current: rotatedBinding),
              "same-slot token rotation invalidates a suspended resolver binding")
        check(!Policy.allowsResolverDispatch(target: nil, binding: nil),
              "default resolver caller fails closed without a settled credential binding")
        check(Policy.allowsResolverDispatch(target: ownerTarget, binding: settledOwner),
              "resolver dispatch requires the captured target and settled credential binding")
        check(Policy.blocksEnginePublication(hasPendingBinding: true, credentialRejected: false),
              "pending B proof suppresses resident A publishing and hydration")
        check(Policy.blocksEnginePublication(hasPendingBinding: true, credentialRejected: true),
              "rejected B blocks both launch and repair timers from indirect retry")
        check(Policy.blocksEnginePublication(hasPendingBinding: false, credentialRejected: false,
                                             signedOutRepairPending: true),
              "pending explicit logout blocks stale resident publication until signed-out control receipt")
        check(!Policy.blocksEnginePublication(hasPendingBinding: false, credentialRejected: false),
              "settled or signed-out engine may publish normally")
        check(!Policy.allowsRepairHydration(engineSignedIn: true, hasSettledBinding: false),
              "14-second repair cannot hydrate selected B into an unverified resident A session")
        check(Policy.allowsRepairHydration(engineSignedIn: true, hasSettledBinding: true),
              "signed-in repair requires the exact settled binding")
        check(Policy.allowsRepairHydration(engineSignedIn: false, hasSettledBinding: false),
              "signed-out local recovery remains available")
        check(!Policy.mayPublish(capturedGeneration: 1, currentGeneration: 2, blocked: false),
              "captured A async publication is dropped after B binding begins or settles")
        check(!Policy.mayPublish(capturedGeneration: 2, currentGeneration: 2, blocked: true),
              "rejected generation cannot publish through delayed jobs")
        check(Policy.mayPublish(capturedGeneration: 3, currentGeneration: 3, blocked: false),
              "logout or no-token generation reset releases signed-out local publication")
        check(Policy.allowsLocalOnlyRecovery(engineSignedIn: false, engineUID: nil, switchInFlight: false,
                                             hasPendingBinding: false, authMigration: false,
                                             activeProfileIsOwner: true, activeUsesEngineHistory: true,
                                             credentialCurrent: true),
              "Stremio-less owner recovery accepts a current VortX credential capture")
        for blockedLocal in [
            Policy.allowsLocalOnlyRecovery(engineSignedIn: true, engineUID: nil, switchInFlight: false, hasPendingBinding: false, authMigration: false, activeProfileIsOwner: true, activeUsesEngineHistory: true, credentialCurrent: true),
            Policy.allowsLocalOnlyRecovery(engineSignedIn: false, engineUID: "uid", switchInFlight: false, hasPendingBinding: false, authMigration: false, activeProfileIsOwner: true, activeUsesEngineHistory: true, credentialCurrent: true),
            Policy.allowsLocalOnlyRecovery(engineSignedIn: false, engineUID: nil, switchInFlight: true, hasPendingBinding: false, authMigration: false, activeProfileIsOwner: true, activeUsesEngineHistory: true, credentialCurrent: true),
            Policy.allowsLocalOnlyRecovery(engineSignedIn: false, engineUID: nil, switchInFlight: false, hasPendingBinding: true, authMigration: false, activeProfileIsOwner: true, activeUsesEngineHistory: true, credentialCurrent: true),
            Policy.allowsLocalOnlyRecovery(engineSignedIn: false, engineUID: nil, switchInFlight: false, hasPendingBinding: false, authMigration: true, activeProfileIsOwner: true, activeUsesEngineHistory: true, credentialCurrent: true),
            Policy.allowsLocalOnlyRecovery(engineSignedIn: false, engineUID: nil, switchInFlight: false, hasPendingBinding: false, authMigration: false, activeProfileIsOwner: false, activeUsesEngineHistory: true, credentialCurrent: true),
            Policy.allowsLocalOnlyRecovery(engineSignedIn: false, engineUID: nil, switchInFlight: false, hasPendingBinding: false, authMigration: false, activeProfileIsOwner: true, activeUsesEngineHistory: true, credentialCurrent: false),
        ] {
            check(!blockedLocal, "local recovery fails closed when session, auth, profile, or capture changes")
        }
        check(Policy.allowsQueuedAccountReplay(profileID: owner, account: account, credentialFingerprint: "fp",
                                                binding: settledOwner),
              "queued owner add replays only in its original account context")
        check(!Policy.allowsQueuedAccountReplay(profileID: owner, account: account, credentialFingerprint: "fp",
                                                 binding: nil),
              "signed-out owner intent cannot replay without a settled binding")
        check(!Policy.allowsQueuedAccountReplay(profileID: owner, account: account, credentialFingerprint: "fp",
                                                 binding: staleEngineAForSelectedB),
              "selected B with stale engine uid A cannot manufacture a B replay target")
        check(!Policy.allowsQueuedAccountReplay(profileID: owner, account: account, credentialFingerprint: "old-fp",
                                                 binding: settledOwner),
              "queued owner add rejects a replaced credential")
        check(Policy.overlayEntries(from: nil, as: CacheEntry.self).isEmpty,
              "first inactive-overlay callback starts from an empty cache")
        let encoded = try! JSONEncoder().encode(["tt1": CacheEntry(value: 1)])
        check(Policy.overlayEntries(from: encoded, as: CacheEntry.self) == ["tt1": CacheEntry(value: 1)],
              "inactive-overlay callback preserves existing persisted cache")
        check(Policy.overlayEntries(from: Data("bad".utf8), as: CacheEntry.self).isEmpty,
              "malformed inactive-overlay cache fails closed to empty")
        if failures > 0 { exit(1) }
    }
}
