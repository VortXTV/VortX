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
                                                        credentialFingerprint: "fp", uid: "owner-uid")
        let staleEngineAForSelectedB = Policy.SettledAccountBinding(profileID: replacement,
                                                                      keychainAccount: account,
                                                                      credentialFingerprint: "fp-b", uid: "owner-uid")

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
