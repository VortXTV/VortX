// Standalone production-wiring and mutation gate for the debrid credential security contract.
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
//     -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     app/Tests/DebridCredentialCallerGateTests.swift \
//     -o /tmp/debrid-credential-callers && /tmp/debrid-credential-callers
//
// This gate reads the exact production sources. Every named fence also has a focused live-source mutant below;
// a protection is counted only when its mutant makes the associated rule red.

import Foundation

private struct SourceFile: Sendable {
    let path: String
    let text: String

    var code: String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

private struct Rule: Sendable {
    let name: String
    let files: [String]
    let violations: @Sendable ([String: SourceFile]) -> [String]
}

private struct Mutation: Sendable {
    let name: String
    let rule: String
    let path: String
    let find: String
    let replacement: String
}

private func load(root: String, path: String) -> SourceFile? {
    let absolute = root + "/" + path
    guard let text = try? String(contentsOfFile: absolute, encoding: .utf8) else { return nil }
    return SourceFile(path: path, text: text)
}

private func require(_ file: SourceFile, _ needle: String, _ reason: String) -> [String] {
    file.code.contains(needle) ? [] : ["\(file.path): missing \(reason) (`\(needle)`)" ]
}

private func forbid(_ file: SourceFile, _ needle: String, _ reason: String) -> [String] {
    file.code.contains(needle) ? ["\(file.path): \(reason) (`\(needle)`)" ] : []
}

private func section(_ file: SourceFile, start: String, end: String) -> SourceFile? {
    guard let startRange = file.code.range(of: start),
          let endRange = file.code.range(of: end, range: startRange.upperBound..<file.code.endIndex) else {
        return nil
    }
    return SourceFile(path: file.path, text: String(file.code[startRange.lowerBound..<endRange.lowerBound]))
}

private func occurrenceCount(_ needle: String, in text: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return text.components(separatedBy: needle).count - 1
}

private func requireCount(_ file: SourceFile, _ needle: String, _ expected: Int,
                          _ reason: String) -> [String] {
    let count = occurrenceCount(needle, in: file.code)
    return count == expected ? [] : ["\(file.path): \(reason), expected \(expected), found \(count)"]
}

private func requireOrdered(_ file: SourceFile, _ needles: [String], _ reason: String) -> [String] {
    var cursor = file.code.startIndex
    for needle in needles {
        guard let range = file.code.range(of: needle, range: cursor..<file.code.endIndex) else {
            return ["\(file.path): \(reason), missing or out of order (`\(needle)`)" ]
        }
        cursor = range.upperBound
    }
    return []
}

private let statePath = "app/SourcesShared/DebridCredentialState.swift"
private let keysPath = "app/SourcesShared/DebridKeys.swift"
private let resolverPath = "app/SourcesShared/DebridResolver.swift"
private let keychainPath = "app/SourcesShared/Keychain.swift"
private let coreModelsPath = "app/SourcesShared/CoreModels.swift"
private let syncPath = "app/SourcesShared/VortXSyncManager.swift"
private let torBoxSearchPath = "app/SourcesShared/TorBoxSearchSource.swift"

private let monotonicRule = "snapshot publication is monotonic and cold bootstrap is synchronous"
private let ownerRule = "canonical owners and envelope accounts stay disjoint"
private let envelopeRule = "one complete envelope is exact-read before its commit marker"
private let durableMutationRule = "durable mutation commits before replacing mutable state"
private let keysCommitRule = "DebridKeys publishes and syncs only a committed candidate"
private let remoteRule = "remote sync applies one durable envelope with no echo"
private let migrationRule = "global migration is durably claimed and delete-source-first"
private let keychainRule = "Keychain replacement rejects deletion failure and exact-readbacks"
private let coordinatorRule = "coordinator accepts only typed newer snapshots"
private let sendRule = "every authenticated provider request validates at the actual send"
private let resultRule = "coordinator result escape retains pre and post await fences"
private let callerRule = "in-lease cache publication uses the atomic caller mutation seam"
private let apiRule = "every credential-derived coordinator API exposes its exact revision"
private let detachedRule = "detached configured-service reads use the immutable store"
private let authRule = "restore and adopt validate canonical owners before mutation"
private let torBoxSearchRule = "TorBox search carries one revision through both sends and every mutation"
private let syncPayloadRule = "sync payload revision is fenced at actual task resume"

private let rules: [Rule] = [
    Rule(name: monotonicRule, files: [statePath], violations: { files in
        guard let file = files[statePath] else { return ["missing credential state"] }
        return require(
            file,
            "initial: DebridCredentialPersistence.bootstrapSignedOutSnapshot(read: Keychain.string)",
            "synchronous signed-out durable bootstrap"
        ) + require(
            file,
            "guard snapshot.revision > value.revision else {",
            "strictly newer snapshot publication"
        )
    }),
    Rule(name: ownerRule, files: [statePath], violations: { files in
        guard let file = files[statePath] else { return ["missing credential state"] }
        return require(
            file,
            "guard let uuid = UUID(uuidString: raw), uuid.uuidString.lowercased() == raw else { return nil }",
            "exact lowercase UUID round-trip"
        ) + require(file, "case .signedOutDevice: return \"device.local\"", "device namespace")
            + require(
                file,
                "case .account(let uuid): return \"account.\" + uuid.uuidString.lowercased()",
                "account namespace"
            ) + require(file, "let base = \"vortx.debrid.v3.envelope.\" + owner.storageNamespace",
                        "owner-scoped envelope namespace")
    }),
    Rule(name: envelopeRule, files: [statePath], violations: { files in
        guard let file = files[statePath],
              let commit = section(file, start: "static func commit(owner:",
                                   end: "static func encodeCanonical") else {
            return ["missing credential envelope commit"]
        }
        return require(file, "let nextSlot = currentSlot?.other ?? .a", "inactive-slot selection")
            + require(file, "guard winners.count == 1 else { return .quarantined }",
                      "ambiguous-generation quarantine")
            + requireOrdered(commit, [
                "guard io.write(envelopeString, envelopeAccount)",
                "guard io.read(envelopeAccount) == envelopeString",
                "guard io.write(markerString, markerAccount)",
                "guard io.read(markerAccount) == markerString",
                "guard case .committed(let verified) = load(owner: owner, read: io.read), verified == next",
            ], "envelope payload/readback/marker/readback/final-validation order")
    }),
    Rule(name: durableMutationRule, files: [statePath], violations: { files in
        guard let file = files[statePath],
              let local = section(file, start: "static func setKey(", end: "static func applyRemoteKeys("),
              let remote = section(file, start: "static func applyRemoteKeys(",
                                   end: "struct DebridCredentialMigrationClaim") else {
            return ["missing durable mutation helpers"]
        }
        let order = [
            "var candidate = state",
            "guard let snapshot = candidate.",
            "guard persist(snapshot.keys) else { return .persistenceFailed }",
            "state = candidate",
            "return .committed(snapshot)",
        ]
        return requireOrdered(local, order, "local candidate durability order")
            + requireOrdered(remote, order, "remote candidate durability order")
    }),
    Rule(name: keysCommitRule, files: [keysPath], violations: { files in
        guard let file = files[keysPath],
              let local = section(file, start: "func setKey(", end: "func applyRemoteKeys("),
              let remote = section(file, start: "func applyRemoteKeys(", end: "private func publish") else {
            return ["missing DebridKeys mutation functions"]
        }
        return require(local, "DebridCredentialDurableMutation.setKey", "durable local helper")
            + require(local, "case .persistenceFailed:", "local persistence failure branch")
            + requireCount(local, "publish(", 1, "local publication count changed")
            + requireCount(local, "requestSyncSoon()", 1, "local sync scheduling count changed")
            + require(remote, "DebridCredentialDurableMutation.applyRemoteKeys", "durable remote helper")
            + require(remote, "case .persistenceFailed:", "remote persistence failure branch")
            + requireCount(remote, "publish(snapshot)", 1, "remote publication count changed")
            + requireCount(remote, "requestSyncSoon()", 0, "remote apply must not schedule sync")
    }),
    Rule(name: remoteRule, files: [keysPath, syncPath], violations: { files in
        guard let keys = files[keysPath], let sync = files[syncPath],
              let remote = section(keys, start: "func applyRemoteKeys(", end: "private func publish"),
              let syncDown = section(sync, start: "func syncDown(",
                                     end: "func hydrateEngineFromOwnedAddons()") else {
            return ["missing remote apply production files"]
        }
        return require(sync, "debrid.applyRemoteKeys(remoteDebrid)", "one remote envelope apply")
            + forbid(sync, "debrid.setKey(", "remote sync fans out through per-service setKey")
            + forbid(sync, "reload(keys:", "remote sync retains raw resolver reload")
            + require(remote, "DebridCredentialPersistence.commit(owner: currentOwner, keys: keys, io: io).succeeded",
                      "whole-owner envelope commit")
            + forbid(remote, "Keychain.set", "remote apply performs independent service writes")
            + requireOrdered(syncDown, [
                "var debridGenerationApplied = true",
                "guard debrid.applyRemoteKeys(remoteDebrid) else {",
                "debridGenerationApplied = false",
                "guard debridGenerationApplied else { return false }",
            ], "failed debrid envelope prevents remote version/application acknowledgment")
    }),
    Rule(name: migrationRule, files: [statePath, keysPath], violations: { files in
        guard let state = files[statePath], let keys = files[keysPath],
              let migration = section(state, start: "static func migrate(",
                                      end: "return .migrated") else {
            return ["missing migration implementation"]
        }
        return require(state, "vortx.debrid.v3.migration.global.", "durable global claim account")
            + require(migration, "guard read(claimAccount) == encoded else { return .claimReadbackMismatch }",
                      "claim exact readback")
            + requireOrdered(migration, [
                "guard delete(sourceAccount), read(sourceAccount) == nil else { return .deleteFailed }",
                "next[service] = source",
                "guard commitTarget(next) else { return .targetWriteFailedAfterSourceDeletion }",
                "guard targetKeys()[service] == source else { return .targetReadbackMismatch }",
            ], "delete-source-first target commit")
            + require(keys, "claimAccount: DebridCredentialMigration.globalClaimAccount(for: service)",
                      "global migration claim wiring")
            + forbid(keys, "hasConsideredGlobalLegacy", "process-local global migration ownership remains")
            + forbid(migration, "delete(claimAccount)", "durable owner claim is deleted")
    }),
    Rule(name: keychainRule, files: [keychainPath], violations: { files in
        guard let file = files[keychainPath] else { return ["missing Keychain"] }
        return require(file, "let deleteStatus = SecItemDelete(base as CFDictionary)",
                       "captured Keychain deletion result")
            + require(file, "guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {",
                      "failed replacement rejection")
            + require(file, "guard save(store) else { return false }", "macOS persistence failure rejection")
            + require(file, "return load()[account] == value", "macOS exact readback")
            + require(file, "return string(account) == value", "iOS and tvOS exact readback")
    }),
    Rule(name: coordinatorRule, files: [resolverPath], violations: { files in
        guard let file = files[resolverPath] else { return ["missing resolver"] }
        return require(file, "func reload(snapshot: DebridCredentialSnapshot)", "typed reload API")
            + require(file, "guard revisionFence.accept(snapshot) else { return false }",
                      "equal and older snapshot rejection")
            + require(file, "ensureCurrentSnapshot()", "operation-time snapshot catch-up")
            + forbid(file, "reload(keys:", "raw resolver reload remains")
            + forbid(file, "didWarm", "lazy warm retains a second authority flag")
    }),
    Rule(name: sendRule, files: [statePath, resolverPath], violations: { files in
        guard let state = files[statePath], let file = files[resolverPath],
              let issuance = section(state, start: "func authorizeAndIssue(revision:",
                                     end: "func compareAndPublish("),
              let helper = section(file, start: "enum DebridAuthenticatedHTTP",
                                   end: "enum DebridHTTP") else {
            return ["missing authenticated HTTP boundary"]
        }
        return requireOrdered(issuance, [
            "lock.lock()",
            "guard value.revision == revision else { return false }",
            "issue()",
        ], "snapshot lock held through request issuance")
            + requireOrdered(helper, [
                "let task = session.dataTask(with: request)",
                "guard taskBox.install(task) else",
                "guard credentialToken.authorizeAndIssue({ task.resume() }) else",
            ], "suspended task creation and lock-held resume")
            + requireCount(file, "session.data(for:", 0,
                           "async URLSession send bypasses the lock-held issuance seam")
            + requireCount(helper, "session.dataTask(with: request)", 1,
                           "authenticated helper must create exactly one suspended task")
            + requireCount(helper, "task.resume()", 1,
                           "authenticated helper must resume only inside authorization")
            + requireCount(file, "private let credentialToken: DebridCredentialRevisionToken", 5,
                           "every credential-bearing provider must retain one revision token")
            + requireCount(file, "init(apiKey: String, credentialToken: DebridCredentialRevisionToken)", 5,
                           "every credential-bearing provider initializer must require the token")
            + require(file, "DebridHTTP.decode(session, req, credentialToken: credentialToken)",
                      "shared decode path token propagation")
    }),
    Rule(name: resultRule, files: [resolverPath], violations: { files in
        guard let file = files[resolverPath],
              let wrapper = section(file, start: "private func withCurrentCredential",
                                    end: "var hasUsenetResolver: Bool") else {
            return ["missing result escape wrapper"]
        }
        return requireOrdered(wrapper, [
            "guard credentialStore.isCurrent(revision: revision) else { throw DebridError.credentialsChanged }",
            "let result = try await operation()",
            "guard credentialStore.resultIsCurrent(revision: revision) else { throw DebridError.credentialsChanged }",
            "return result",
        ], "coordinator pre and post await result fencing")
    }),
    Rule(name: callerRule, files: [statePath, resolverPath], violations: { files in
        guard let state = files[statePath], let resolver = files[resolverPath],
              let seam = section(state, start: "func compareAndPublish(", end: "func isConfigured("),
              let cache = section(resolver, start: "final class DebridCacheAwareness",
                                  end: "extension TorBoxResolver") else {
            return ["missing in-lease caller publication seam"]
        }
        return require(state,
                       "@MainActor\n    @discardableResult\n    func publish(_ snapshot:",
                       "MainActor-isolated credential publication")
            + require(state,
                      "@MainActor\n    @discardableResult\n    func compareAndPublish(",
                      "MainActor-isolated caller mutation")
            + requireOrdered(seam, [
            "lock.lock()",
            "let matches = value.revision == revision",
            "lock.unlock()",
            "guard matches else { return false }",
            "mutation()",
        ], "unlock-before-callback MainActor comparison and synchronous mutation")
            + require(state,
                      "NotificationCenter.default.post(name: Self.didPublishNotification, object: self)",
                      "post-lock credential revision invalidation signal")
            + requireCount(cache, "compareAndPublish(revision:", 5,
                           "revision adoption plus torrent/usenet pre-send and completion mutations")
            + require(cache, "cacheCheckVersioned", "versioned torrent cache result")
            + require(cache, "usenetCacheCheckVersioned", "versioned usenet cache result")
            + require(cache, "DebridCredentialSnapshotStore.didPublishNotification",
                      "long-lived cache invalidation subscription")
            + requireOrdered(cache, [
                "guard self.credentialRevision != revision else { return }",
                "self.lastQueried.removeAll()",
                "self.lastUsenetQueried.removeAll()",
                "self.cachedHashes.removeAll()",
                "self.cachedUsenetURLs.removeAll()",
            ], "revision change clears both dedupe and visible cache state")
    }),
    Rule(name: apiRule, files: [resolverPath, coreModelsPath], violations: { files in
        guard let resolver = files[resolverPath], let core = files[coreModelsPath] else {
            return ["missing versioned coordinator API files"]
        }
        let coordinatorAPIs = [
            "func cacheCheckVersioned(",
            "func resolveVersioned(",
            "func resolveWithIdsVersioned(",
            "func reresolveVersioned(",
            "func resolveUsenetVersioned(",
            "func usenetCacheCheckVersioned(",
            "func resolvedPlaybackURLVersioned(",
            "func resolvedPlaybackRefVersioned(",
            "func resolveFirstPlayableVersioned(",
            "func cloudLibraryVersioned(",
            "func resolveLibraryItemVersioned(",
        ]
        var violations = coordinatorAPIs.flatMap {
            require(resolver, $0, "version-carrying coordinator result API")
        }
        violations += require(
            core,
            "static func resolvedURLVersioned(",
            "version-carrying continue-watching result API"
        )
        violations += require(
            core,
            "DebridCoordinator.shared.reresolveVersioned(",
            "continue-watching revision propagation"
        )
        violations += require(
            resolver,
            "DebridCoordinator.shared.resolveUsenetVersioned(",
            "usenet high-level revision propagation"
        )
        violations += require(
            resolver,
            "DebridCoordinator.shared.resolveWithIdsVersioned(",
            "torrent high-level revision propagation"
        )
        return violations
    }),
    Rule(name: detachedRule, files: [coreModelsPath], violations: { files in
        guard let file = files[coreModelsPath] else { return ["missing CoreModels"] }
        return require(file, "DebridCredentialSnapshotStore.shared.isConfigured(.torBox)",
                       "immutable configured-service query")
            + forbid(file, "DebridKeys.shared.isConfigured(.torBox)",
                     "detached code reads the main-actor mutable owner")
    }),
    Rule(name: authRule, files: [syncPath], violations: { files in
        guard let file = files[syncPath] else { return ["missing sync manager"] }
        guard let restore = section(file, start: "private func restore()", end: "func signOut()"),
              let adopt = section(file, start: "private func adopt(", end: "enum AuthResult") else {
            return ["missing restore or adopt function"]
        }
        return requireOrdered(restore, [
            "DebridOwnerScope.canonicalAccount(p.account.id)",
            "SourceIndexLifecycleScope.shared.sessionWillMutate()",
        ], "restore owner validation before mutation")
            + requireOrdered(adopt, [
                "DebridOwnerScope.canonicalAccount(accountID)",
                "SourceIndexLifecycleScope.shared.sessionWillMutate()",
            ], "adopt owner validation before mutation")
            + forbid(file, "DebridKeys.shared.bind(owner: p.account.id)", "raw restore owner bind remains")
    }),
    Rule(name: torBoxSearchRule, files: [torBoxSearchPath], violations: { files in
        guard let file = files[torBoxSearchPath],
              let search = section(file, start: "static func streams(",
                                   end: "private static func fetch("),
              let fetch = section(file, start: "private static func fetch(",
                                  end: "private static func stream("),
              let source = section(file, start: "final class TorBoxSearchSource",
                                   end: "nonisolated static func merge(") else {
            return ["missing TorBox search sections"]
        }
        return require(search, "snapshot: DebridCredentialSnapshot", "captured complete credential snapshot")
            + require(search, "async -> DebridVersionedResult<SearchResult>", "versioned combined result")
            + require(search, "revision: snapshot.revision, store: credentialStore", "revision token construction")
            + requireCount(search, "credentialToken: credentialToken", 2,
                           "usenet and torrent legs must each receive the revision token")
            + require(fetch, "DebridAuthenticatedHTTP.data(", "lock-held actual task issuance")
            + forbid(fetch, "session.data(for:", "TorBox search bypasses guarded task resume")
            + forbid(file, "DebridKeys.shared", "TorBox search captures mutable MainActor credentials")
            + require(source, "private var credentialRevision: UInt64?", "revision-scoped contributor state")
            + require(source, "private var inFlightRevision: UInt64?", "revision-scoped in-flight state")
            + requireOrdered(source, [
                "init(credentialStore: DebridCredentialSnapshotStore = .shared)",
                "forName: DebridCredentialSnapshotStore.didPublishNotification",
                "object: credentialStore",
                "Task { @MainActor [weak self] in self?.adoptCurrentCredentialRevision() }",
            ], "live revision publication invalidates the injected store's contributor state")
            + require(source, "credentialStore: requestCredentialStore",
                      "injected credential store reaches both guarded search legs")
            + requireCount(source, "compareAndPublish(revision:", 4,
                           "pre-send, completion, revision adoption, and clear mutations must all use the seam")
            + requireOrdered(source, [
                "let snapshot = credentialStore.load()",
                "guard adoptCredentialRevision(snapshot.revision) else { return }",
                "guard let key = snapshot.keys[.torBox], !key.isEmpty else",
                "credentialStore.compareAndPublish(revision: snapshot.revision)",
            ], "snapshot adoption and pre-send mutation ordering")
            + requireOrdered(source, [
                "guard self.credentialRevision != revision else { return }",
                "self.inFlightKey = nil",
                "self.inFlightRevision = nil",
                "self.cache.removeAll()",
                "self.cooldownUntil = nil",
                "self.shownKey = nil",
                "self.publishedContentID = nil",
                "self.streams = []",
            ], "revision change retires every old contributor-state class")
    }),
    Rule(name: syncPayloadRule, files: [syncPath], violations: { files in
        guard let file = files[syncPath],
              let request = section(file, start: "private func request(",
                                    end: "private func adopt("),
              let push = section(file, start: "private func pushSyncDocAt(",
                                 end: "private func pushDerivedDoc("),
              let derivedPush = section(file, start: "private func pushDerivedDoc(",
                                        end: "private func vortxSummary("),
              let merge = section(file, start: "private func mergeLocalIntoDoc(",
                                  end: "static func currentAddonOrder()") else {
            return ["missing sync payload sections"]
        }
        return require(request, "debridCredentialToken: DebridCredentialRevisionToken? = nil",
                       "optional credential issuance token")
            + requireOrdered(request, [
                "if let debridCredentialToken",
                "DebridAuthenticatedHTTP.data(",
                "credentialToken: debridCredentialToken",
            ], "credential-bearing PUT uses the lock-held task-resume helper")
            + requireOrdered(push, [
                "debridRevision: UInt64",
                "guard DebridCredentialSnapshotStore.shared.isCurrent(revision: debridRevision) else",
                "JSONSerialization.data(withJSONObject: obj)",
                "DebridCredentialRevisionToken(",
                "revision: debridRevision, store: DebridCredentialSnapshotStore.shared",
                "debridCredentialToken: credentialToken",
            ], "derived payload is rejected before crypto and fenced again at actual request issuance")
            + forbid(file, "func pushSyncDoc(_ obj:",
                     "blind sync helper blesses a payload without derivation provenance")
            + require(derivedPush,
                      "doc.object, version: version, debridRevision: doc.debridRevision",
                      "optimistic retries retain each rebuilt payload's exact revision")
            + requireOrdered(merge, [
                "let debridSnapshot = DebridCredentialSnapshotStore.shared.load()",
                "debridSnapshot.keys[.realDebrid]",
                "debridSnapshot.keys[.allDebrid]",
                "debridSnapshot.keys[.premiumize]",
                "debridSnapshot.keys[.torBox]",
                "DerivedSyncDocument(object: doc, debridRevision: debridSnapshot.revision)",
            ], "one snapshot supplies all four encrypted payload keys and its revision")
            + forbid(merge, "DebridKeys.shared", "sync payload captures mutable keys outside its snapshot")
    }),
]

private let mutations: [Mutation] = [
    Mutation(name: "M01 allow equal snapshot publication", rule: monotonicRule, path: statePath,
             find: "guard snapshot.revision > value.revision else {",
             replacement: "guard snapshot.revision >= value.revision else {"),
    Mutation(name: "M02 restore empty cold bootstrap", rule: monotonicRule, path: statePath,
             find: "initial: DebridCredentialPersistence.bootstrapSignedOutSnapshot(read: Keychain.string)",
             replacement: "initial: DebridCredentialSnapshot(owner: .signedOutDevice, revision: 1, keys: [:])"),
    Mutation(name: "M03 map account storage onto the device namespace", rule: ownerRule, path: statePath,
             find: "case .account(let uuid): return \"account.\" + uuid.uuidString.lowercased()",
             replacement: "case .account: return \"device.local\""),
    Mutation(name: "M04 accept noncanonical account spelling", rule: ownerRule, path: statePath,
             find: "guard let uuid = UUID(uuidString: raw), uuid.uuidString.lowercased() == raw else { return nil }",
             replacement: "guard let uuid = UUID(uuidString: raw) else { return nil }"),
    Mutation(name: "M05 overwrite the active envelope slot", rule: envelopeRule, path: statePath,
             find: "let nextSlot = currentSlot?.other ?? .a",
             replacement: "let nextSlot = currentSlot ?? .a"),
    Mutation(name: "M06 remove envelope exact readback", rule: envelopeRule, path: statePath,
             find: "guard io.read(envelopeAccount) == envelopeString else { return .failed(.envelopeReadbackMismatch) }",
             replacement: "_ = io.read(envelopeAccount)"),
    Mutation(name: "M07 remove commit marker exact readback", rule: envelopeRule, path: statePath,
             find: "guard io.read(markerAccount) == markerString else { return .failed(.markerReadbackMismatch) }",
             replacement: "_ = io.read(markerAccount)"),
    Mutation(name: "M08 publish local candidate before persistence", rule: durableMutationRule, path: statePath,
             find: "guard let snapshot = candidate.setKey(value, for: service) else { return .unchanged }\n        guard persist(snapshot.keys) else { return .persistenceFailed }\n        state = candidate",
             replacement: "guard let snapshot = candidate.setKey(value, for: service) else { return .unchanged }\n        state = candidate\n        guard persist(snapshot.keys) else { return .persistenceFailed }"),
    Mutation(name: "M09 publish remote candidate before persistence", rule: durableMutationRule, path: statePath,
             find: "guard let snapshot = candidate.applyRemoteKeys(remote) else { return .unchanged }\n        guard persist(snapshot.keys) else { return .persistenceFailed }\n        state = candidate",
             replacement: "guard let snapshot = candidate.applyRemoteKeys(remote) else { return .unchanged }\n        state = candidate\n        guard persist(snapshot.keys) else { return .persistenceFailed }"),
    Mutation(name: "M10 publish after failed local persistence", rule: keysCommitRule, path: keysPath,
             find: "case .persistenceFailed:\n            persistenceError = \"Could not save debrid credentials. Your previous saved keys are still active.\"\n            return false",
             replacement: "case .persistenceFailed:\n            publish(state.snapshot)\n            return false"),
    Mutation(name: "M11 let remote apply echo a sync", rule: keysCommitRule, path: keysPath,
             find: "case .committed(let snapshot):\n            persistenceError = nil\n            publish(snapshot)\n            return true\n        }\n    }\n\n    private func publish",
             replacement: "case .committed(let snapshot):\n            persistenceError = nil\n            publish(snapshot)\n            Task { @MainActor in VortXSyncManager.shared.requestSyncSoon() }\n            return true\n        }\n    }\n\n    private func publish"),
    Mutation(name: "M12 restore remote per-service setKey fanout", rule: remoteRule, path: syncPath,
             find: "debrid.applyRemoteKeys(remoteDebrid)",
             replacement: "for (service, value) in remoteDebrid { debrid.setKey(value, for: service) }"),
    Mutation(name: "M13 remove durable global claim wiring", rule: migrationRule, path: keysPath,
             find: "claimAccount: DebridCredentialMigration.globalClaimAccount(for: service)",
             replacement: "claimAccount: nil"),
    Mutation(name: "M14 write migration target before deleting source", rule: migrationRule, path: statePath,
             find: "guard delete(sourceAccount), read(sourceAccount) == nil else { return .deleteFailed }\n\n        var next = current\n        next[service] = source\n        guard commitTarget(next) else { return .targetWriteFailedAfterSourceDeletion }",
             replacement: "var next = current\n        next[service] = source\n        guard commitTarget(next) else { return .targetWriteFailedAfterSourceDeletion }\n        guard delete(sourceAccount), read(sourceAccount) == nil else { return .deleteFailed }"),
    Mutation(name: "M15 remove migration claim exact readback", rule: migrationRule, path: statePath,
             find: "guard read(claimAccount) == encoded else { return .claimReadbackMismatch }",
             replacement: "_ = read(claimAccount)"),
    Mutation(name: "M16 ignore Keychain deletion failure", rule: keychainRule, path: keychainPath,
             find: "guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {\n            return false\n        }",
             replacement: "_ = deleteStatus"),
    Mutation(name: "M17 report macOS persistence success without readback", rule: keychainRule, path: keychainPath,
             find: "guard save(store) else { return false }\n            return load()[account] == value",
             replacement: "_ = save(store)\n            return true"),
    Mutation(name: "M18 release publication lock before request issuance", rule: sendRule, path: statePath,
             find: "guard value.revision == revision else { return false }\n        issue()\n        return true\n    }\n\n    /// The required caller-publication seam",
             replacement: "guard value.revision == revision else { return false }\n        return true\n    }\n\n    /// The required caller-publication seam"),
    Mutation(name: "M19 restore a detached pre-send predicate", rule: sendRule, path: resolverPath,
             find: "guard credentialToken.authorizeAndIssue({ task.resume() }) else {\n                    task.cancel()",
             replacement: "guard credentialToken.revision > 0 else {\n                    task.cancel()\n                    resumeGate.run { continuation.resume(throwing: DebridError.credentialsChanged) }\n                    return\n                }\n                task.resume()\n                if false {\n                    task.cancel()"),
    Mutation(name: "M20 bypass guarded send for one provider", rule: sendRule, path: resolverPath,
             find: "static func decode<T: Decodable>(\n        _ session: URLSession,\n        _ req: URLRequest,\n        credentialToken: DebridCredentialRevisionToken\n    ) async throws -> T {\n        let (data, response) = try await DebridAuthenticatedHTTP.data(\n            session, for: req, credentialToken: credentialToken\n        )",
             replacement: "static func decode<T: Decodable>(\n        _ session: URLSession,\n        _ req: URLRequest,\n        credentialToken: DebridCredentialRevisionToken\n    ) async throws -> T {\n        let (data, response) = try await session.data(for: req)"),
    Mutation(name: "M21 remove one provider's durable revision token", rule: sendRule, path: resolverPath,
             find: "actor RealDebridResolver: DebridResolving {\n    nonisolated let service: DebridService = .realDebrid\n    private let apiKey: String\n    private let credentialToken: DebridCredentialRevisionToken",
             replacement: "actor RealDebridResolver: DebridResolving {\n    nonisolated let service: DebridService = .realDebrid\n    private let apiKey: String"),
    Mutation(name: "M22 remove coordinator post-await result fence", rule: resultRule, path: resolverPath,
             find: "guard credentialStore.resultIsCurrent(revision: revision) else { throw DebridError.credentialsChanged }",
             replacement: "_ = revision"),
    Mutation(name: "M23 separate cache check from caller mutation", rule: callerRule, path: resolverPath,
             find: "_ = self.credentialStore.compareAndPublish(revision: result.revision) {",
             replacement: "if DebridCredentialSnapshotStore.shared.isCurrent(revision: result.revision) {"),
    Mutation(name: "M24 remove atomic caller revision comparison", rule: callerRule, path: statePath,
             find: "let matches = value.revision == revision\n        lock.unlock()\n        guard matches else { return false }\n        mutation()",
             replacement: "_ = revision\n        lock.unlock()\n        mutation()"),
    Mutation(name: "M25 allow equal coordinator reload", rule: coordinatorRule, path: resolverPath,
             find: "guard revisionFence.accept(snapshot) else { return false }",
             replacement: "_ = revisionFence.accept(snapshot)"),
    Mutation(name: "M26 restore detached mutable-owner read", rule: detachedRule, path: coreModelsPath,
             find: "DebridCredentialSnapshotStore.shared.isConfigured(.torBox)",
             replacement: "DebridKeys.shared.isConfigured(.torBox)"),
    Mutation(name: "M27 bind restore through a raw owner", rule: authRule, path: syncPath,
             find: "let dk = Data(base64Encoded: p.dataKey),\n              let debridOwner = DebridOwnerScope.canonicalAccount(p.account.id) else { return }",
             replacement: "let dk = Data(base64Encoded: p.dataKey) else { return }\n        let debridOwner = DebridOwnerScope.signedOutDevice"),
    Mutation(name: "M28 strip revision from library item resolution", rule: apiRule, path: resolverPath,
             find: "func resolveLibraryItemVersioned(_ item: DebridLibraryItem)",
             replacement: "func resolveLibraryItemUnchecked(_ item: DebridLibraryItem)"),
    Mutation(name: "M29 strip revision from continue-watching reresolve", rule: apiRule, path: coreModelsPath,
             find: "DebridCoordinator.shared.reresolveVersioned(",
             replacement: "DebridCoordinator.shared.reresolve("),
    Mutation(name: "M30 acknowledge sync after failed remote envelope", rule: remoteRule, path: syncPath,
             find: "guard debrid.applyRemoteKeys(remoteDebrid) else {\n                debridGenerationApplied = false\n                return\n            }",
             replacement: "_ = debrid.applyRemoteKeys(remoteDebrid)"),
    Mutation(name: "M31 hold snapshot lock across observable callback", rule: callerRule, path: statePath,
             find: "lock.lock()\n        let matches = value.revision == revision\n        lock.unlock()\n        guard matches else { return false }\n        mutation()",
             replacement: "lock.lock()\n        defer { lock.unlock() }\n        guard value.revision == revision else { return false }\n        mutation()"),
    Mutation(name: "M32 bypass guarded TorBox search send", rule: torBoxSearchRule, path: torBoxSearchPath,
             find: "DebridAuthenticatedHTTP.data(\n            session, for: req, credentialToken: credentialToken\n        )",
             replacement: "session.data(for: req)"),
    Mutation(name: "M33 drop TorBox torrent-leg revision token", rule: torBoxSearchRule, path: torBoxSearchPath,
             find: "async let torrents = fetch(\n            kind: \"torrents\", imdbId: imdbId, season: season, episode: episode,\n            apiKey: apiKey, credentialToken: credentialToken\n        )",
             replacement: "async let torrents = fetch(\n            kind: \"torrents\", imdbId: imdbId, season: season, episode: episode,\n            apiKey: apiKey\n        )"),
    Mutation(name: "M34 strip TorBox combined-result revision", rule: torBoxSearchRule, path: torBoxSearchPath,
             find: ") async -> DebridVersionedResult<SearchResult> {",
             replacement: ") async -> SearchResult {"),
    Mutation(name: "M35 publish TorBox completion without caller seam", rule: torBoxSearchRule,
             path: torBoxSearchPath,
             find: "_ = self.credentialStore.compareAndPublish(revision: result.revision) {",
             replacement: "if true {"),
    Mutation(name: "M36 retain TorBox cache across credential revision", rule: torBoxSearchRule,
             path: torBoxSearchPath,
             find: "self.cache.removeAll()",
             replacement: "_ = self.cache"),
    Mutation(name: "M37 recapture TorBox key from mutable owner", rule: torBoxSearchRule,
             path: torBoxSearchPath,
             find: "func refresh(imdbId: String?, season: Int? = nil, episode: Int? = nil) {\n        let snapshot = credentialStore.load()",
             replacement: "func refresh(imdbId: String?, season: Int? = nil, episode: Int? = nil) {\n        let snapshot = DebridKeys.shared.snapshot"),
    Mutation(name: "M38 split sync revision check from actual task resume", rule: syncPayloadRule,
             path: syncPath,
             find: "if let debridCredentialToken {\n                response = try await DebridAuthenticatedHTTP.data(\n                    URLSession.shared, for: req, credentialToken: debridCredentialToken\n                )",
             replacement: "if let debridCredentialToken {\n                guard DebridCredentialSnapshotStore.shared.isCurrent(revision: debridCredentialToken.revision) else { return (0, nil) }\n                response = try await URLSession.shared.data(for: req)"),
    Mutation(name: "M39 drop rebuilt sync payload revision", rule: syncPayloadRule, path: syncPath,
             find: "doc.object, version: version, debridRevision: doc.debridRevision",
             replacement: "doc.object, version: version, debridRevision: DebridCredentialSnapshotStore.shared.load().revision"),
    Mutation(name: "M40 mix a second credential snapshot into sync payload", rule: syncPayloadRule,
             path: syncPath,
             find: "if let value = debridSnapshot.keys[.torBox] { keys[\"torBox\"] = value }",
             replacement: "if let value = DebridCredentialSnapshotStore.shared.load().keys[.torBox] { keys[\"torBox\"] = value }"),
    Mutation(name: "M41 retain cache-awareness dedupe across credential revision", rule: callerRule,
             path: resolverPath,
             find: "self.lastQueried.removeAll()",
             replacement: "_ = self.lastQueried"),
    Mutation(name: "M42 suppress live credential invalidation signal", rule: callerRule, path: statePath,
             find: "NotificationCenter.default.post(name: Self.didPublishNotification, object: self)",
             replacement: "_ = Self.didPublishNotification"),
    Mutation(name: "M43 serialize stale sync payload before checking revision", rule: syncPayloadRule,
             path: syncPath,
             find: "guard DebridCredentialSnapshotStore.shared.isCurrent(revision: debridRevision) else {\n            return .error\n        }",
             replacement: "_ = debridRevision"),
    Mutation(name: "M44 restore blind sync payload helper", rule: syncPayloadRule, path: syncPath,
             find: "private struct DerivedSyncDocument {",
             replacement: "func pushSyncDoc(_ obj: [String: Any]) async -> Bool { false }\n\n    private struct DerivedSyncDocument {"),
    Mutation(name: "M45 suppress live TorBox contributor invalidation", rule: torBoxSearchRule,
             path: torBoxSearchPath,
             find: "forName: DebridCredentialSnapshotStore.didPublishNotification,",
             replacement: "forName: Notification.Name(\"mutant.torbox.no-invalidation\"),"),
]

@main
private enum DebridCredentialCallerGateRunner {
    static func main() {
        let root = CommandLine.arguments.dropFirst().first
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().path
        var failures: [String] = []
        var checks = 0

        for rule in rules {
            checks += 1
            var production: [String: SourceFile] = [:]
            for path in rule.files {
                guard let file = load(root: root, path: path) else {
                    failures.append("\(rule.name): missing production file \(path)")
                    continue
                }
                production[path] = file
            }
            let live = rule.violations(production)
            if live.isEmpty {
                print("PASS  \(rule.name)")
            } else {
                failures.append(contentsOf: live.map { "\(rule.name): \($0)" })
                print("FAIL  \(rule.name)")
            }
        }

        for mutation in mutations {
            checks += 1
            guard let rule = rules.first(where: { $0.name == mutation.rule }) else {
                failures.append("\(mutation.name): missing named rule \(mutation.rule)")
                print("FAIL  \(mutation.name)")
                continue
            }
            var mutated: [String: SourceFile] = [:]
            for path in rule.files {
                guard let file = load(root: root, path: path) else {
                    failures.append("\(mutation.name): missing production file \(path)")
                    continue
                }
                mutated[path] = file
            }
            guard let target = mutated[mutation.path] else {
                failures.append("\(mutation.name): target is outside named rule")
                print("FAIL  \(mutation.name)")
                continue
            }
            let matches = occurrenceCount(mutation.find, in: target.text)
            guard matches == 1 else {
                failures.append("\(mutation.name): expected one live mutation target, found \(matches)")
                print("FAIL  \(mutation.name)")
                continue
            }
            mutated[mutation.path] = SourceFile(
                path: target.path,
                text: target.text.replacingOccurrences(of: mutation.find, with: mutation.replacement)
            )
            if rule.violations(mutated).isEmpty {
                failures.append("\(mutation.name): live-source mutation survived")
                print("FAIL  \(mutation.name)")
            } else {
                print("PASS  \(mutation.name)")
            }
        }

        if failures.isEmpty {
            print("ALL PASS (\(checks) checks)")
        } else {
            print("FAILED \(failures.count) finding(s) across \(checks) checks")
            for failure in failures { print(" - \(failure)") }
            exit(1)
        }
    }
}
