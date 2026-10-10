import Foundation
import CryptoKit

private func snapshot(_ value: VortxJSON, _ revision: Int64) -> NativePreferenceIntentStore.Snapshot {
    .init(value: value, revision: .integer(revision))
}
private func playback(_ audio: String) -> VortxJSON {
    .object(["playback": .object(["audioLang": .string(audio)]), "addonPreferences": .null])
}
private struct LegacyIntentDocument: Codable {
    let schemaVersion: Int
    let intents: [LegacyStoredIntent]
}
private struct LegacyStoredIntent: Codable {
    let id: UUID
    let authority: NativePreferenceIntentStore.Authority
    let group: NativePreferenceIntentStore.Group
    let base: NativePreferenceIntentStore.Snapshot
    let desired: VortxJSON
    let supersededIDs: [UUID]
    let supersededReceipts: [NativePreferenceIntentStore.SupersededReceipt]
    let acceptedBases: [NativePreferenceIntentStore.Snapshot]
    init(_ intent: NativePreferenceIntentStore.Intent, acceptedBases: [NativePreferenceIntentStore.Snapshot]? = nil) {
        id = intent.id; authority = intent.authority; group = intent.group; base = intent.base
        desired = intent.desired; supersededIDs = intent.supersededIDs; supersededReceipts = intent.supersededReceipts
        self.acceptedBases = acceptedBases ?? intent.acceptedBases
    }
}
private struct FullIntentDocument: Codable {
    let schemaVersion: Int
    let intents: [NativePreferenceIntentStore.Intent]
}
private struct LegacyReceiptPayload: Encodable {
    let id: UUID
    let authority: NativePreferenceIntentStore.Authority
    let group: NativePreferenceIntentStore.Group
    let base: NativePreferenceIntentStore.Snapshot
    let desired: VortxJSON
    let supersededIDs: [UUID]
    let supersededReceipts: [NativePreferenceIntentStore.SupersededReceipt]
    let projectionStamps: [String: Double]
    let requiresResolution: Bool
    init(_ intent: NativePreferenceIntentStore.Intent) {
        id = intent.id; authority = intent.authority; group = intent.group; base = intent.base; desired = intent.desired
        supersededIDs = intent.supersededIDs; supersededReceipts = intent.supersededReceipts
        projectionStamps = intent.projectionStamps; requiresResolution = intent.requiresResolution
    }
}

@main private enum NativePreferenceIntentStoreTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let key = Data(repeating: 0x5a, count: 32)
        let authority = NativePreferenceIntentStore.Authority(account: "account-fixture",
            ownerProfileID: "00000000-0000-4000-8000-000000000001",
            profileID: "00000000-0000-4000-8000-000000000002",
            profileBinding: .object(["account": .string("account-fixture"), "revision": .integer(3)]))
        let base = snapshot(playback("en"), 3)
        let desiredA = playback("hi")
        let desiredB = playback("fr")
        let store = NativePreferenceIntentStore(directoryURL: root, key: key, namespace: "account-fixture")

        check(try store.pending().isEmpty, "new journal starts empty")
        let beforeCommit = NativePreferenceIntentStore(directoryURL: root, key: key, namespace: "account-fixture")
        check(try beforeCommit.pending().isEmpty, "uncommitted intent is absent after reopening")
        let first = try store.prepare(authority: authority, group: .playback, base: base, desired: desiredA,
            projectionStamps: ["audioLang": 1.0])
        let reopened = NativePreferenceIntentStore(directoryURL: root, key: key, namespace: "account-fixture")
        check(try reopened.pending() == [first], "atomic committed intent survives reopening")
        let forgedActive = NativePreferenceIntentStore.Intent(id: first.id, authority: first.authority, group: first.group,
            base: first.base, desired: desiredB, supersededIDs: first.supersededIDs,
            supersededReceipts: first.supersededReceipts, acceptedBases: first.acceptedBases,
            projectionStamps: first.projectionStamps)
        check(!(try reopened.acknowledge(forgedActive, current: snapshot(desiredB, 5))), "altered same-ID ACK cannot delete active intent")
        check(try reopened.pending() == [first], "altered same-ID ACK preserves the active record")
        let repeatCapture = try reopened.prepare(authority: authority, group: .playback,
            base: snapshot(playback("different-stale-base"), 99), desired: desiredA, projectionStamps: ["audioLang": 2.0])
        check(repeatCapture.id != first.id && repeatCapture.base == first.base,
              "same desired value with a new stamp gets a fresh receipt without rebasing onto a stale peer")
        check(repeatCapture.projectionStamps == ["audioLang": 2.0], "recapture retains the new stamp for exact acknowledgement")

        let second = try reopened.prepare(authority: authority, group: .playback,
            base: snapshot(desiredA, 4), desired: desiredB, projectionStamps: ["audioLang": 3.0])
        check(second.id != first.id && second.supersededIDs.isEmpty && second.generationAuthentication?.count == 32,
              "new group intent replaces old generation without growing historical lineage")
        check(second.projectionStamps == ["audioLang": 3.0], "superseding intent captures only its supplied dirty stamps")
        let forgedPredecessor = NativePreferenceIntentStore.Intent(id: first.id, authority: first.authority, group: first.group,
            base: first.base, desired: playback("unrelated"), supersededIDs: first.supersededIDs,
            supersededReceipts: first.supersededReceipts, acceptedBases: first.acceptedBases,
            projectionStamps: first.projectionStamps, generationAuthentication: first.generationAuthentication)
        check(!(try reopened.acknowledge(forgedPredecessor, current: snapshot(playback("unrelated"), 5))),
              "forged predecessor receipt cannot add an accepted base")
        check(!(try reopened.recordCommitted(forgedPredecessor, current: snapshot(playback("unrelated"), 5))),
              "retired signed native completion rejects altered payload carrying the original authentication")
        check(try reopened.pending() == [second], "forged retired signed completion preserves the newest pending generation")
        check(try reopened.pending().first?.acceptedBases.isEmpty == true, "forged predecessor leaves accepted bases unchanged")
        check(!(try reopened.acknowledge(first, current: snapshot(desiredA, 5))), "retired cloud ACK cannot acknowledge the new generation")
        let updated = try reopened.pending().first!
        check(updated.id == second.id && updated.desired == desiredB && updated.acceptedBases.isEmpty,
              "old ACK leaves newer intent and exact base unchanged")
        check(NativePreferenceIntentStore.decision(updated, current: snapshot(desiredA, 4), authority: authority) == .apply,
              "quiescent captured snapshot safely enables replay")
        check(NativePreferenceIntentStore.decision(updated, current: snapshot(desiredA, 5), authority: authority) == .conflict,
              "unrecognized later revision cannot acquire predecessor replay authority")
        check(NativePreferenceIntentStore.decision(updated, current: snapshot(desiredB, 6), authority: authority) == .alreadyApplied,
              "desired value is recognized as already applied")
        check(NativePreferenceIntentStore.decision(updated, current: snapshot(playback("es"), 6), authority: authority) == .conflict,
              "stale peer change conflicts instead of last-write-wins")
        let otherAuthority = NativePreferenceIntentStore.Authority(account: "other-account",
            ownerProfileID: authority.ownerProfileID, profileID: authority.profileID, profileBinding: authority.profileBinding)
        check(NativePreferenceIntentStore.decision(updated, current: snapshot(desiredA, 5), authority: otherAuthority) == .conflict,
              "authority mismatch conflicts")
        check(!(try reopened.acknowledge(second, current: snapshot(desiredA, 5))), "ACK with a different value is rejected")

        let lineageStore = NativePreferenceIntentStore(directoryURL: root.appendingPathComponent("lineage", isDirectory: true), key: key, namespace: "account-fixture")
        var lineageIntent = try lineageStore.prepare(authority: authority, group: .playback, base: base, desired: playback("0"))
        for index in 1...64 {
            lineageIntent = try lineageStore.prepare(authority: authority, group: .playback,
                base: snapshot(lineageIntent.desired, Int64(index)), desired: playback(String(index)))
            check(try lineageStore.recordCommitted(lineageIntent, current: snapshot(lineageIntent.desired, Int64(index + 1))),
                  "offline generation \(index) records durable native completion")
            let coldStore = NativePreferenceIntentStore(directoryURL: root.appendingPathComponent("lineage", isDirectory: true), key: key, namespace: "account-fixture")
            check(try coldStore.pending() == [lineageIntent], "offline generation \(index) survives reopening pending cloud ACK")
        }
        check(lineageIntent.supersededIDs.isEmpty && lineageIntent.acceptedBases.isEmpty,
              "64 offline edits require constant journal history")

        let rebindStore = NativePreferenceIntentStore(directoryURL: root.appendingPathComponent("rebind", isDirectory: true), key: key, namespace: "account-fixture")
        let oldBindingIntent = try rebindStore.prepare(authority: authority, group: .playback, base: base, desired: desiredA)
        let reboundAuthority = NativePreferenceIntentStore.Authority(account: authority.account,
            ownerProfileID: authority.ownerProfileID, profileID: authority.profileID,
            profileBinding: .object(["account": .string(authority.account), "revision": .integer(4)]))
        let newBindingIntent = try rebindStore.prepare(authority: reboundAuthority, group: .playback,
            base: base, desired: desiredB)
        check(try rebindStore.pending() == [oldBindingIntent, newBindingIntent],
              "new profile binding admits a separate intent and preserves the old binding")
        check(NativePreferenceIntentStore.decision(oldBindingIntent, current: base, authority: reboundAuthority) == .conflict,
              "old binding intent cannot be applied under a rebound authority")
        check(NativePreferenceIntentStore.decision(newBindingIntent, current: base, authority: reboundAuthority) == .apply,
              "new binding intent applies under the exact rebound authority")

        let resolutionDirectory = root.appendingPathComponent("resolution", isDirectory: true)
        let resolutionStore = NativePreferenceIntentStore(directoryURL: resolutionDirectory, key: key, namespace: "account-fixture")
        let unresolved = try resolutionStore.prepare(authority: authority, group: .playback, base: base,
            desired: desiredA, projectionStamps: ["audioLang": 4], requiresResolution: true)
        check(NativePreferenceIntentStore.decision(unresolved, current: base, authority: authority) == .conflict,
              "stale published-group intent requires explicit resolution")
        check(NativePreferenceIntentStore.decision(unresolved, current: snapshot(desiredA, 25), authority: authority) == .alreadyApplied,
              "already-desired value is accepted before resolution conflict")
        let reopenedResolution = NativePreferenceIntentStore(directoryURL: resolutionDirectory, key: key, namespace: "account-fixture")
        check(try reopenedResolution.pending().first?.requiresResolution == true,
              "resolution requirement survives reopening")
        let sameDesiredCapture = try reopenedResolution.prepare(authority: authority, group: .playback,
            base: snapshot(desiredB, 26), desired: desiredA, projectionStamps: ["audioLang": 5], requiresResolution: false)
        check(sameDesiredCapture.base == unresolved.base && sameDesiredCapture.requiresResolution && sameDesiredCapture.projectionStamps == ["audioLang": 5],
              "same desired capture retains refreshed stamps without rebasing or clearing resolution conflict")
        let resolvedByNewEdit = try reopenedResolution.prepare(authority: authority, group: .playback,
            base: base, desired: desiredB, requiresResolution: false)
        check(resolvedByNewEdit.id != unresolved.id && resolvedByNewEdit.supersededIDs.isEmpty
              && !resolvedByNewEdit.requiresResolution,
              "different explicit desired value supersedes the unresolved draft")
        let alteredResolutionReceipt = NativePreferenceIntentStore.Intent(id: unresolved.id, authority: unresolved.authority,
            group: unresolved.group, base: unresolved.base, desired: unresolved.desired,
            supersededIDs: unresolved.supersededIDs, supersededReceipts: unresolved.supersededReceipts,
            acceptedBases: unresolved.acceptedBases, projectionStamps: unresolved.projectionStamps,
            requiresResolution: false)
        check(!(try reopenedResolution.authorizesAcknowledgement(alteredResolutionReceipt, current: snapshot(desiredA, 25))),
              "tampered resolution flag invalidates the authenticated receipt")

        let committedDir = root.appendingPathComponent("native-commit", isDirectory: true)
        let committedStore = NativePreferenceIntentStore(directoryURL: committedDir, key: key, namespace: "account-fixture")
        let committedIntent = try committedStore.prepare(authority: authority, group: .playback, base: base, desired: desiredA)
        let forgedCommitted = NativePreferenceIntentStore.Intent(id: committedIntent.id, authority: committedIntent.authority,
            group: committedIntent.group, base: committedIntent.base, desired: desiredB,
            supersededIDs: committedIntent.supersededIDs, supersededReceipts: committedIntent.supersededReceipts,
            acceptedBases: committedIntent.acceptedBases, projectionStamps: committedIntent.projectionStamps)
        check(!(try committedStore.recordCommitted(forgedCommitted, current: snapshot(desiredB, 21))),
              "tampered native commit receipt is rejected")
        check(try committedStore.pending() == [committedIntent], "tampered native commit receipt retains witness")
        let nativeCommitSnapshot = snapshot(desiredA, 22)
        check(try committedStore.recordCommitted(committedIntent, current: nativeCommitSnapshot),
              "native durable commit is recorded")
        check(try committedStore.pending().count == 1, "native commit does not clear cloud authority")
        let reopenedCommitted = NativePreferenceIntentStore(directoryURL: committedDir, key: key, namespace: "account-fixture")
        check(try reopenedCommitted.pending().first == committedIntent,
              "native commit preserves exact pending cloud authority without repeated snapshots")
        check(try reopenedCommitted.acknowledge(committedIntent, current: nativeCommitSnapshot),
              "cloud ACK clears the exact committed intent")
        check(try reopenedCommitted.pending().isEmpty, "cloud ACK removes the encrypted intent")

        let saturatedStore = NativePreferenceIntentStore(directoryURL: root.appendingPathComponent("saturated", isDirectory: true), key: key, namespace: "account-fixture")
        let saturatedIntent = try saturatedStore.prepare(authority: authority, group: .playback, base: base, desired: desiredA)
        for revision in 1...64 {
            _ = try saturatedStore.recordCommitted(saturatedIntent, current: snapshot(desiredA, Int64(100 + revision)))
        }
        let terminalSnapshot = snapshot(desiredA, 164)
        check(try saturatedStore.pending().first?.acceptedBases.isEmpty == true,
              "same desired value at 64 revisions does not exhaust accepted-base capacity")
        check(try saturatedStore.authorizesAcknowledgement(saturatedIntent, current: terminalSnapshot),
              "read-only cloud-ACK preflight succeeds after repeated native receipts")
        check(!(try saturatedStore.authorizesAcknowledgement(saturatedIntent, current: snapshot(desiredB, 116))),
              "read-only cloud-ACK preflight rejects an unrelated value")
        check(try saturatedStore.acknowledge(saturatedIntent, current: terminalSnapshot),
              "valid terminal cloud ACK succeeds after repeated native receipts")
        check(try saturatedStore.pending().isEmpty, "saturated cloud ACK clears the intent")

        let stampsStore = NativePreferenceIntentStore(directoryURL: root.appendingPathComponent("stamps", isDirectory: true), key: key, namespace: "account-fixture")
        let stampedIntent = try stampsStore.prepare(authority: authority, group: .playback, base: base, desired: desiredA,
            projectionStamps: ["audioLang": 2.5])
        let alteredStampReceipt = NativePreferenceIntentStore.Intent(id: stampedIntent.id, authority: stampedIntent.authority,
            group: stampedIntent.group, base: stampedIntent.base, desired: stampedIntent.desired,
            supersededIDs: stampedIntent.supersededIDs, supersededReceipts: stampedIntent.supersededReceipts,
            acceptedBases: stampedIntent.acceptedBases, projectionStamps: ["audioLang": 3.5])
        check(!(try stampsStore.recordCommitted(alteredStampReceipt, current: snapshot(desiredA, 31))),
              "tampered projection stamp invalidates the authenticated receipt")
        check(try stampsStore.pending() == [stampedIntent], "tampered projection stamp preserves intent")

        let committedSuccessorStore = NativePreferenceIntentStore(directoryURL: root.appendingPathComponent("native-commit-successor", isDirectory: true), key: key, namespace: "account-fixture")
        let committedPredecessor = try committedSuccessorStore.prepare(authority: authority, group: .playback, base: base, desired: desiredA)
        let committedSuccessor = try committedSuccessorStore.prepare(authority: authority, group: .playback,
            base: snapshot(desiredA, 23), desired: desiredB)
        check(try committedSuccessorStore.recordCommitted(committedPredecessor, current: snapshot(desiredA, 24)),
              "native commit for superseded intent is recognized")
        check(try committedSuccessorStore.pending().first?.id == committedSuccessor.id
              && committedSuccessorStore.pending().first?.acceptedBases.isEmpty == true,
              "retired native completion leaves successor exact base and pending cloud authority intact")

        let quarantineDir = root.appendingPathComponent("quarantine", isDirectory: true)
        let quarantineStore = NativePreferenceIntentStore(directoryURL: quarantineDir, key: key, namespace: "account-fixture")
        let originalProjection = NativePreferenceIntentStore.QuarantinedProjection(key: "audioLang", stamp: 12.5,
            value: .string("hi"))
        try quarantineStore.quarantine([originalProjection])
        let reopenedQuarantine = NativePreferenceIntentStore(directoryURL: quarantineDir, key: key, namespace: "account-fixture")
        check(try reopenedQuarantine.quarantined() == [originalProjection], "quarantined raw projection survives reopening")
        try reopenedQuarantine.quarantine([originalProjection])
        check(try reopenedQuarantine.quarantined() == [originalProjection], "exact quarantined tuple is idempotent")
        let conflictingProjection = NativePreferenceIntentStore.QuarantinedProjection(key: "audioLang", stamp: 12.5,
            value: .string("fr"))
        check(throws: { try reopenedQuarantine.quarantine([conflictingProjection]) },
              "same key and stamp with a different value conflicts")
        check(try reopenedQuarantine.quarantined() == [originalProjection], "quarantine conflict preserves first value")
        let oversizedProjection = NativePreferenceIntentStore.QuarantinedProjection(key: "audioLang", stamp: 13,
            value: .string(String(repeating: "x", count: 20_000)))
        check(throws: { try reopenedQuarantine.quarantine([oversizedProjection]) }, "oversized quarantine entry is rejected")
        check(try reopenedQuarantine.quarantined() == [originalProjection], "quarantine bound failure preserves prior value")
        let batchConflictStore = NativePreferenceIntentStore(directoryURL: root.appendingPathComponent("quarantine-batch", isDirectory: true), key: key, namespace: "account-fixture")
        let batchConflict = NativePreferenceIntentStore.QuarantinedProjection(key: "audioLang", stamp: 12.5, value: .string("de"))
        check(throws: { try batchConflictStore.quarantine([originalProjection, batchConflict]) },
              "conflicting values in one quarantine batch are rejected")
        check(try batchConflictStore.quarantined().isEmpty, "conflicting quarantine batch writes nothing")

        let legacyDirectory = root.appendingPathComponent("legacy-document", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacySourceStore = NativePreferenceIntentStore(directoryURL: root.appendingPathComponent("legacy-source", isDirectory: true), key: key, namespace: "account-fixture")
        let legacyIntent = try legacySourceStore.prepare(authority: authority, group: .playback, base: base,
            desired: desiredA, projectionStamps: ["audioLang": 9.0])
        let legacyAccepted = snapshot(playback("legacy-committed"), 50)
        let legacyBytes = try JSONEncoder().encode(LegacyIntentDocument(schemaVersion: 1,
            intents: [LegacyStoredIntent(legacyIntent, acceptedBases: [legacyAccepted])]))
        let legacyBox = try AES.GCM.seal(legacyBytes, using: SymmetricKey(data: key),
            authenticating: Data("vortx-native-preference-intents|schema=1|namespace=account-fixture".utf8))
        let legacyFile = legacyDirectory.appendingPathComponent("preference-intents-\(sha256Hex("account-fixture")).bin")
        try legacyBox.combined!.write(to: legacyFile)
        let legacyStore = NativePreferenceIntentStore(directoryURL: legacyDirectory, key: key, namespace: "account-fixture")
        check(try legacyStore.quarantined().isEmpty
              && legacyStore.pending().first?.projectionStamps == [:]
              && legacyStore.pending().first?.requiresResolution == false,
              "schema-one journal without quarantine, stamps, or resolution remains readable")
        let migratedLegacy = try legacyStore.pending().first!
        check(migratedLegacy.generationAuthentication == nil && migratedLegacy.acceptedBases == [legacyAccepted]
              && NativePreferenceIntentStore.decision(migratedLegacy, current: legacyAccepted, authority: authority) == .apply,
              "legacy authenticated exact accepted snapshot remains replayable before replacement")
        let migratedGate = NativePreferenceIntentStore.AdmissionGate()
        var migratedGeneration = try migratedGate.withJournal(read: { try legacyStore.pending() }) {
            try legacyStore.prepare(authority: authority, group: .playback, base: legacyAccepted, desired: desiredB,
                                    projectionStamps: ["audioLang": 10])
        }
        check(migratedGeneration.supersededIDs == [migratedLegacy.id] && migratedGeneration.acceptedBases.isEmpty,
              "legacy retirement retains only its authenticated active completion bridge")
        for index in 0..<40 {
            migratedGeneration = try migratedGate.withJournal(read: { try legacyStore.pending() }) {
                try legacyStore.prepare(authority: authority, group: .playback,
                    base: snapshot(migratedGeneration.desired, Int64(51 + index)), desired: playback("migrated-\(index)"))
            }
        }
        check(migratedGeneration.supersededIDs == [migratedLegacy.id] && migratedGeneration.acceptedBases.isEmpty,
              "40 post-migration generations retain a constant single legacy bridge")
        check(try legacyStore.recordCommitted(migratedLegacy, current: snapshot(migratedGeneration.desired, 100)),
              "delayed authenticated legacy native completion is a no-op after replacement")
        check(!(try legacyStore.authorizesAcknowledgement(migratedLegacy, current: snapshot(migratedLegacy.desired, 99))),
              "legacy bridge cannot acknowledge new cloud generation or stamps")
        check(try NativePreferenceIntentStore(directoryURL: legacyDirectory, key: key, namespace: authority.account).pending() == [migratedGeneration],
              "migrated generation and bridge survive another cold reopen")

        try fullLegacyMigrationTests(root: root, key: key, authority: authority)

        let optionalPlayback = NativePreferenceIntentStore(directoryURL: root.appendingPathComponent("optional-playback", isDirectory: true), key: key, namespace: "account-fixture")
        let absentGroups = VortxJSON.object(["playback": .null, "addonPreferences": .object([:])])
        check(try optionalPlayback.prepare(authority: authority, group: .playback, base: base, desired: absentGroups).desired == absentGroups,
              "playback group accepts exact nullable optional fields")
        let incompletePlayback = VortxJSON.object(["playback": .object([:])])
        check(throws: { _ = try optionalPlayback.prepare(authority: authority, group: .playback, base: base, desired: incompletePlayback) },
              "playback group requires both exact fields")

        let oldNamespace = root.appendingPathComponent("namespace", isDirectory: true)
        let namespaceStore = NativePreferenceIntentStore(directoryURL: oldNamespace, key: key, namespace: "ns-one")
        let namespaceAuthority = NativePreferenceIntentStore.Authority(account: "ns-one", ownerProfileID: authority.ownerProfileID,
            profileID: authority.profileID, profileBinding: .object(["account": .string("ns-one"), "revision": .integer(3)]))
        _ = try namespaceStore.prepare(authority: namespaceAuthority, group: .playback, base: base, desired: desiredA)
        let files = try FileManager.default.contentsOfDirectory(at: oldNamespace, includingPropertiesForKeys: nil)
        let misplaced = oldNamespace.appendingPathComponent("preference-intents-" +
            sha256Hex("ns-two") + ".bin")
        try FileManager.default.moveItem(at: files[0], to: misplaced)
        let wrongNamespace = NativePreferenceIntentStore(directoryURL: oldNamespace, key: key, namespace: "ns-two")
        check(throws: { _ = try wrongNamespace.pending() }, "namespace AAD mismatch fails closed")
        let wrongKey = NativePreferenceIntentStore(directoryURL: root, key: Data(repeating: 0x33, count: 32), namespace: "account-fixture")
        check(throws: { _ = try wrongKey.pending() }, "wrong key fails closed")

        let tamperDir = root.appendingPathComponent("tamper", isDirectory: true)
        let tamperStore = NativePreferenceIntentStore(directoryURL: tamperDir, key: key, namespace: "account-fixture")
        _ = try tamperStore.prepare(authority: authority, group: .playback, base: base, desired: desiredA)
        let tamperURL = try FileManager.default.contentsOfDirectory(at: tamperDir, includingPropertiesForKeys: nil)[0]
        let original = try Data(contentsOf: tamperURL)
        var altered = original; altered[altered.startIndex] ^= 1
        try altered.write(to: tamperURL)
        check(throws: { _ = try tamperStore.pending() }, "modified ciphertext fails authentication")
        check(try Data(contentsOf: tamperURL) == altered, "unreadable journal bytes are preserved")

        let failurePath = root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: failurePath)
        let failing = NativePreferenceIntentStore(directoryURL: failurePath, key: key, namespace: "account-fixture")
        check(throws: { _ = try failing.prepare(authority: authority, group: .playback, base: base, desired: desiredA) },
              "failed persistence does not report success")

        let bounded = NativePreferenceIntentStore(directoryURL: root.appendingPathComponent("bounded", isDirectory: true), key: key, namespace: "account-fixture")
        check(throws: { _ = try bounded.prepare(authority: authority, group: .theme, base: base,
            desired: .object(["accentID": .string("x"), "oled": .bool(false), "textScale": .number(.nan)])) },
              "invalid non-finite theme value rejected")
        let oversized = VortxJSON.object(["playback": .object(["blob": .string(String(repeating: "x", count: 20_000))])])
        check(throws: { _ = try bounded.prepare(authority: authority, group: .playback, base: base, desired: oversized) },
              "oversized record rejected before persistence")
        let secretBearing = VortxJSON.object(["playback": .object(["apiToken": .string("fixture")])])
        check(throws: { _ = try bounded.prepare(authority: authority, group: .playback, base: base, desired: secretBearing) },
              "credential-bearing preference data rejected")
        check(throws: { _ = try bounded.prepare(authority: authority, group: .playback, base: base, desired: desiredA,
            projectionStamps: ["accessToken": 1]) }, "sensitive projection stamp key rejected")
        check(throws: { _ = try bounded.prepare(authority: authority, group: .playback, base: base, desired: desiredA,
            projectionStamps: ["audioLang": .nan]) }, "non-finite projection stamp rejected")
        let tooManyStamps = Dictionary(uniqueKeysWithValues: (0..<97).map { ("setting-\($0)", Double($0)) })
        check(throws: { _ = try bounded.prepare(authority: authority, group: .playback, base: base, desired: desiredA,
            projectionStamps: tooManyStamps) }, "projection stamp count is bounded")
        let invalidKey = NativePreferenceIntentStore(directoryURL: root, key: Data(repeating: 1, count: 16), namespace: "account-fixture")
        check(throws: { _ = try invalidKey.pending() }, "non-256-bit key rejected")
        check(try bounded.pending().isEmpty, "bound failure leaves journal unchanged")
        try generationLifecycleTests(root: root, key: key, authority: authority)
        print("PASS bounded journal failure leaves existing entries intact")
    }
}

private final class AdmissionProbe: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Bool?
    func set(_ value: Bool) { lock.lock(); result = value; lock.unlock(); finished.signal() }
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return result }
}

private func generationLifecycleTests(root: URL, key: Data, authority: NativePreferenceIntentStore.Authority) throws {
    typealias Store = NativePreferenceIntentStore
    let directory = root.appendingPathComponent("generation-lifecycle", isDirectory: true)
    let store = Store(directoryURL: directory, key: key, namespace: authority.account)
    let gate = Store.AdmissionGate()
    func fullPlayback(_ audio: String) -> VortxJSON {
        .object(["playback": .object(["audioLang": .string(audio), "subtitleLang": .string("en"),
            "forcedPolicy": .string("forced"), "subFont": .string("system"), "subSize": .string("medium"),
            "subColor": .string("white"), "subBackground": .string("none"), "subSizeScale": .integer(1),
            "sourceTypeOrder": .array([.string("debrid"), .string("torrent")]), "useAddonOrder": .bool(false),
            "safetyMode": .string("balanced"), "instantOnly": .bool(false)]),
            "addonPreferences": .object(["disabledAddonURLsOverride": .array((0..<12).map {
                .string("https://addon-\($0).example.invalid/catalog/manifest.json")
            })])])
    }
    func fullSnapshot(_ audio: String, _ clock: Int64) -> Store.Snapshot {
        let value = fullPlayback(audio)
        return .init(value: value, revision: .object(["playback": .object([
            "clock": .integer(clock), "actor": .string("00000000-0000-4000-8000-000000000090"), "value": value["playback"]!]),
            "addonPreferences": .object(["clock": .integer(clock), "actor": .string("00000000-0000-4000-8000-000000000090"), "value": value["addonPreferences"]!])]))
    }
    check(try JSONEncoder().encode(fullSnapshot("en", 1)).count >= 1_509, "capacity fixture includes full register values and exceeds reported snapshot size")
    var current = fullSnapshot("en", 1)
    var sent: [Store.Intent] = []
    for index in 0..<64 {
        let intent = try gate.withJournal(read: { try store.pending() }) {
            try store.prepare(authority: authority, group: .playback, base: current,
                desired: fullPlayback("language-\(index)"), projectionStamps: ["audioLang": Double(index + 1)])
        }
        check(gate.admits([intent]) { Store.decision(intent, current: current, authority: authority) == .apply },
              "full-size offline edit \(index) is admitted under its exact active generation")
        current = fullSnapshot("language-\(index)", Int64(index + 2))
        check(try store.recordCommitted(intent, current: current), "full-size offline edit \(index) commits")
        let reopened = Store(directoryURL: directory, key: key, namespace: authority.account)
        check(try reopened.pending() == [intent] && JSONEncoder().encode(intent).count < Store.maximumRecordBytes,
              "full-size offline edit \(index) reopens under the original unchanged byte cap")
        sent.append(intent)
    }
    let latest = sent.last!
    for retired in sent.dropLast() {
        check(!gate.admits([retired]) { true }, "retired local generation cannot admit")
        check(try store.recordCommitted(retired, current: current), "authenticated delayed native completion is a no-op")
        check(!(try store.authorizesAcknowledgement(retired, current: .init(value: retired.desired, revision: .integer(999)))),
              "retired cloud receipt cannot clear a successor's stamps")
        check(!(try store.acknowledge(retired, current: .init(value: retired.desired, revision: .integer(999)))),
              "retired cloud ACK cannot remove newest pending intent")
    }
    check(try store.pending() == [latest], "delayed native and cloud completions preserve latest desired and stamps")
    var injectedProof = latest
    let peer = fullSnapshot("peer", 1_000)
    injectedProof.acceptedBases = [peer]
    check(!gate.admits([injectedProof]) { true }, "signed immutable receipt cannot smuggle unauthenticated replay metadata")
    check(Store.decision(injectedProof, current: peer, authority: authority) == .conflict,
          "signed generation never derives replay authority from accepted-base metadata")
    let coldGate = Store.AdmissionGate()
    check(!coldGate.admits([latest]) { true }, "cold gate starts closed")
    try coldGate.withJournal(read: { try store.pending() }) {}
    check(coldGate.admits([latest]) { true }, "cold gate reloads authenticated pending receipt")

    let stamps = try gate.withJournal(read: { try store.pending() }) {
        try store.prepare(authority: authority, group: .playback, base: current, desired: latest.desired,
                          projectionStamps: ["audioLang": 100, "subtitleLang": 200])
    }
    check(stamps.id != latest.id && stamps.projectionStamps == ["audioLang": 100, "subtitleLang": 200],
          "same desired recapture durably owns refreshed dirty stamps")
    let replaced = try gate.withJournal(read: { try store.pending() }) {
        try store.prepare(authority: authority, group: .playback, base: current, desired: fullPlayback("next"), projectionStamps: ["audioLang": 101])
    }
    check(replaced.projectionStamps == ["audioLang": 101, "subtitleLang": 200], "generation rollover preserves untouched pending stamps")
    check(!(try store.authorizesAcknowledgement(stamps, current: current)), "old upload cannot acknowledge carried unchanged stamp")

    let probe = AdmissionProbe()
    _ = try gate.withJournal(read: { try store.pending() }) {
        DispatchQueue.global().async {
            probe.started.signal()
            probe.set(gate.admits([replaced]) { true })
        }
        check(probe.started.wait(timeout: .now() + 2) == .success, "older admission task starts during successor preparation")
        check(probe.finished.wait(timeout: .now() + 0.02) == .timedOut, "contending old admission does not complete while preparation holds the gate")
        return try store.prepare(authority: authority, group: .playback, base: current, desired: fullPlayback("successor"))
    }
    check(probe.finished.wait(timeout: .now() + 2) == .success && probe.value == false,
          "task queued during journal replacement is retired before its admission")
    for phase in [Store.WritePhase.beforeReplace, .afterReplace] {
        let failing = Store(directoryURL: directory, key: key, namespace: authority.account, writeBarrier: { observed in
            switch (phase, observed) {
            case (.beforeReplace, .beforeReplace), (.afterReplace, .afterReplace): throw Store.StoreError.persistence
            default: break
            }
        })
        let before = try store.pending().first!
        check(throws: {
            _ = try gate.withJournal(read: { try store.pending() }) {
                try failing.prepare(authority: authority, group: .playback, base: current,
                    desired: fullPlayback("failure-\(phase)"), projectionStamps: ["audioLang": 300])
            }
        }, "injected journal write failure is reported")
        let after = try store.pending().first!
        switch phase {
        case .beforeReplace:
            check(after == before && gate.admits([before]) { true }, "pre-replace failure preserves prior durable generation and admission")
        case .afterReplace:
            check(after.id != before.id && !gate.admits([before]) { true } && gate.admits([after]) { true },
                  "post-replace failure refreshes durable successor before releasing old admissions")
            check(after.projectionStamps["subtitleLang"] == 200, "after-effect failure preserves carried pending stamps")
        }
    }
    let pending = try store.pending().first!
    check(gate.admits([pending]) { true }, "current durable receipt is live before unreadable refresh")
    check(throws: {
        try gate.withJournal(read: { throw Store.StoreError.unreadable }) {}
    }, "unreadable refresh is reported")
    check(!gate.admits([pending]) { true }, "uncertain refresh invalidates the previously live receipt cache")
    try gate.withJournal(read: { try store.pending() }) {}
    check(gate.admits([pending]) { true }, "authenticated refresh restores the exact active receipt before cloud ACK")
    try gate.withJournal(read: { try store.pending() }) {
        check(try store.acknowledge(pending, current: .init(value: pending.desired, revision: .integer(2_000))),
              "actual latest cloud receipt clears exact active generation")
    }
    check(try store.pending().isEmpty && !gate.admits([pending]) { true }, "cloud removal also revokes cached admission")
}

private func fullLegacyMigrationTests(root: URL, key: Data, authority: NativePreferenceIntentStore.Authority) throws {
    typealias Store = NativePreferenceIntentStore
    let directory = root.appendingPathComponent("full-legacy-migration", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("preference-intents-\(sha256Hex(authority.account)).bin")
    let predecessor = Store.Intent(id: UUID(), authority: authority, group: .playback, base: snapshot(playback("en"), 1),
        desired: playback("hi"), supersededIDs: [], supersededReceipts: [], acceptedBases: [], projectionStamps: ["audioLang": 40])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let predecessorDigest = Data(HMAC<SHA256>.authenticationCode(for: try encoder.encode(LegacyReceiptPayload(predecessor)),
                                                                using: SymmetricKey(data: key)))
    let legacy = Store.Intent(id: UUID(), authority: authority, group: .playback, base: snapshot(playback("en"), 1),
        desired: playback("fr"), supersededIDs: [predecessor.id], supersededReceipts: [.init(id: predecessor.id, digest: predecessorDigest)],
        acceptedBases: [snapshot(playback("hi"), 2)], projectionStamps: ["audioLang": 41, "subtitleLang": 42], requiresResolution: true)
    let originalBytes = try AES.GCM.seal(encoder.encode(FullIntentDocument(schemaVersion: 1, intents: [legacy])), using: SymmetricKey(data: key),
        authenticating: Data("vortx-native-preference-intents|schema=1|namespace=\(authority.account)".utf8)).combined!
    try originalBytes.write(to: file)
    let store = Store(directoryURL: directory, key: key, namespace: authority.account)
    check(try store.pending() == [legacy], "full schema-one fixture retains stamps, resolution, exact accepted base, and predecessor receipt")
    check(try store.recordCommitted(predecessor, current: snapshot(predecessor.desired, 3)),
          "existing schema-one predecessor HMAC remains authenticated after loading")
    let updatedLegacy = try store.pending().first!
    check(updatedLegacy.acceptedBases == legacy.acceptedBases + [snapshot(predecessor.desired, 3)]
          && updatedLegacy.projectionStamps == legacy.projectionStamps && updatedLegacy.requiresResolution,
          "legacy predecessor completion preserves pending stamps and resolution")
    let theme = VortxJSON.object(["accentID": .string("violet"), "oled": .bool(false), "textScale": .integer(1)])
    let themeGeneration = try store.prepare(authority: authority, group: .theme, base: .init(value: theme, revision: .integer(1)), desired: theme)
    let cold = Store(directoryURL: directory, key: key, namespace: authority.account)
    check(try cold.pending() == [updatedLegacy, themeGeneration], "schema two cold-opens a mixed legacy and signed-generation document")
    let successor = try store.prepare(authority: authority, group: .playback, base: snapshot(playback("peer"), 4),
        desired: playback("de"), projectionStamps: ["audioLang": 43])
    check(successor.projectionStamps == ["audioLang": 43, "subtitleLang": 42] && !successor.requiresResolution
          && successor.supersededIDs == [updatedLegacy.id], "explicit migrated edit retains all pending stamps with only the active legacy completion bridge")
    let ancestorAcknowledged = try store.acknowledge(predecessor, current: snapshot(predecessor.desired, 3))
    let legacyAcknowledged = try store.acknowledge(updatedLegacy, current: snapshot(updatedLegacy.desired, 4))
    check(!ancestorAcknowledged && !legacyAcknowledged,
          "both old legacy ancestor and active cloud ACKs are retired by migration")
    check(try cold.pending() == [themeGeneration, successor], "mixed migration cold restart preserves newest desired and untouched group")

    // A valid encrypted container is insufficient: malformed signed generation metadata must
    // also fail authentication, and neither a read nor failed preparation may replace it.
    var malformed = successor
    malformed.generationAuthentication = Data(repeating: 0, count: 32)
    let malformedBytes = try AES.GCM.seal(encoder.encode(FullIntentDocument(schemaVersion: 2, intents: [malformed])), using: SymmetricKey(data: key),
        authenticating: Data("vortx-native-preference-intents|schema=2|namespace=\(authority.account)".utf8)).combined!
    try malformedBytes.write(to: file)
    check(throws: { _ = try cold.pending() }, "cold authenticated-container read rejects malformed generation authentication")
    check(throws: { _ = try cold.prepare(authority: authority, group: .playback, base: legacy.base, desired: playback("it")) },
          "malformed generation cannot be silently replaced by a new edit")
    check(try Data(contentsOf: file) == malformedBytes, "malformed generation bytes remain intact for recovery")
}

private func check(_ passed: Bool, _ label: String) {
    print("\(passed ? "PASS" : "FAIL") \(label)")
    if !passed { exit(1) }
}
private func check(throws body: () throws -> Void, _ label: String) {
    do { try body(); print("FAIL \(label)"); exit(1) }
    catch { print("PASS \(label)") }
}
private func sha256Hex(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}
