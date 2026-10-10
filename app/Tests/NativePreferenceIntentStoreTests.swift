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
    init(_ intent: NativePreferenceIntentStore.Intent) {
        id = intent.id; authority = intent.authority; group = intent.group; base = intent.base
        desired = intent.desired; supersededIDs = intent.supersededIDs; supersededReceipts = intent.supersededReceipts
        acceptedBases = intent.acceptedBases
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
        check(repeatCapture == first, "same desired value capture is idempotent")
        check(repeatCapture.projectionStamps == ["audioLang": 1.0], "idempotent capture preserves original projection stamps")

        let second = try reopened.prepare(authority: authority, group: .playback,
            base: snapshot(desiredA, 4), desired: desiredB, projectionStamps: ["audioLang": 3.0])
        check(second.id != first.id && second.supersededIDs == [first.id], "new group intent replaces old intent with bounded lineage")
        check(second.projectionStamps == ["audioLang": 3.0], "superseding intent captures only its supplied dirty stamps")
        let forgedPredecessor = NativePreferenceIntentStore.Intent(id: first.id, authority: first.authority, group: first.group,
            base: first.base, desired: playback("unrelated"), supersededIDs: first.supersededIDs,
            supersededReceipts: first.supersededReceipts, acceptedBases: first.acceptedBases,
            projectionStamps: first.projectionStamps)
        check(!(try reopened.acknowledge(forgedPredecessor, current: snapshot(playback("unrelated"), 5))),
              "forged predecessor receipt cannot add an accepted base")
        check(try reopened.pending().first?.acceptedBases.isEmpty == true, "forged predecessor leaves accepted bases unchanged")
        check(try reopened.acknowledge(first, current: snapshot(desiredA, 5)), "accepted predecessor ACK is recognized")
        let updated = try reopened.pending().first!
        check(updated.id == second.id && updated.desired == desiredB && updated.acceptedBases == [snapshot(desiredA, 5)],
              "old ACK records accepted base without erasing newer intent")
        check(NativePreferenceIntentStore.decision(updated, current: snapshot(desiredA, 5), authority: authority) == .apply,
              "accepted predecessor snapshot safely enables replay")
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
        for index in 1...16 {
            lineageIntent = try lineageStore.prepare(authority: authority, group: .playback,
                base: snapshot(lineageIntent.desired, Int64(index)), desired: playback(String(index)))
        }
        check(lineageIntent.supersededIDs.count == NativePreferenceIntentStore.maximumLineage,
              "supersession history remains within its bound")
        let lastLineageIntent = lineageIntent
        check(throws: { _ = try lineageStore.prepare(authority: authority, group: .playback,
            base: snapshot(lineageIntent.desired, 17), desired: playback("17")) }, "lineage overflow fails closed")
        check(try lineageStore.pending() == [lastLineageIntent], "lineage overflow preserves the existing journal")

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
        check(sameDesiredCapture == unresolved && sameDesiredCapture.requiresResolution,
              "same desired capture cannot rebase or clear resolution conflict")
        let resolvedByNewEdit = try reopenedResolution.prepare(authority: authority, group: .playback,
            base: base, desired: desiredB, requiresResolution: false)
        check(resolvedByNewEdit.id != unresolved.id && resolvedByNewEdit.supersededIDs == [unresolved.id]
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
        check(try reopenedCommitted.pending().first?.acceptedBases == [nativeCommitSnapshot],
              "native commit witness survives reopening")
        check(try reopenedCommitted.acknowledge(committedIntent, current: nativeCommitSnapshot),
              "cloud ACK clears the exact committed intent")
        check(try reopenedCommitted.pending().isEmpty, "cloud ACK removes the encrypted intent")

        let saturatedStore = NativePreferenceIntentStore(directoryURL: root.appendingPathComponent("saturated", isDirectory: true), key: key, namespace: "account-fixture")
        let saturatedIntent = try saturatedStore.prepare(authority: authority, group: .playback, base: base, desired: desiredA)
        for revision in 1...NativePreferenceIntentStore.maximumAcceptedBases {
            _ = try saturatedStore.recordCommitted(saturatedIntent, current: snapshot(desiredA, Int64(100 + revision)))
        }
        let terminalSnapshot = snapshot(desiredA, 100 + Int64(NativePreferenceIntentStore.maximumAcceptedBases))
        check(try saturatedStore.pending().first?.acceptedBases.count == NativePreferenceIntentStore.maximumAcceptedBases,
              "accepted-base capacity reaches its bound")
        check(try saturatedStore.authorizesAcknowledgement(saturatedIntent, current: terminalSnapshot),
              "read-only cloud-ACK preflight succeeds at accepted-base saturation")
        check(!(try saturatedStore.authorizesAcknowledgement(saturatedIntent, current: snapshot(desiredB, 116))),
              "read-only cloud-ACK preflight rejects an unrelated value")
        check(try saturatedStore.acknowledge(saturatedIntent, current: terminalSnapshot),
              "valid terminal cloud ACK succeeds at accepted-base saturation")
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
              && committedSuccessorStore.pending().first?.acceptedBases == [snapshot(desiredA, 24)],
              "superseded native commit advances successor base without clearing it")

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
        let legacyBytes = try JSONEncoder().encode(LegacyIntentDocument(schemaVersion: 1, intents: [LegacyStoredIntent(legacyIntent)]))
        let legacyBox = try AES.GCM.seal(legacyBytes, using: SymmetricKey(data: key),
            authenticating: Data("vortx-native-preference-intents|schema=1|namespace=account-fixture".utf8))
        let legacyFile = legacyDirectory.appendingPathComponent("preference-intents-\(sha256Hex("account-fixture")).bin")
        try legacyBox.combined!.write(to: legacyFile)
        let legacyStore = NativePreferenceIntentStore(directoryURL: legacyDirectory, key: key, namespace: "account-fixture")
        check(try legacyStore.quarantined().isEmpty
              && legacyStore.pending().first?.projectionStamps == [:]
              && legacyStore.pending().first?.requiresResolution == false,
              "schema-one journal without quarantine, stamps, or resolution remains readable")

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
        print("PASS bounded journal failure leaves existing entries intact")
    }
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
