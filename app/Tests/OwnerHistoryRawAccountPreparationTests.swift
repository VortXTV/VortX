import Foundation

/// UNRUN pure regression proposal. Real parser/Capture/provider/host/account projection; tiny
/// synthetic input snapshots are NOT native-accepted Session, HTTP, Keychain or authority proof.
@main enum OwnerHistoryRawAccountPreparationTests {
    typealias Exact = OwnerHistoryExactJSON
    typealias Subject = OwnerHistoryRawAccountPreparation
    static let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let actor = "00000000-0000-0000-0000-000000000002"
    static let scope = VortxAccountScope(account: "synthetic.raw-account", ownerProfileID: owner.uuidString)
    static func check(_ value: Bool, line: UInt = #line) { precondition(value, "raw account fixture line \(line)") }
    static func rejects(_ operation: () throws -> Void, line: UInt = #line) {
        var rejected = false
        do { try operation() } catch { rejected = true }
        check(rejected, line: line)
    }

    static func main() async throws {
        let native = Data(#"{"scope":"synthetic.raw-account","ownerProfileId":"\#(owner.uuidString)","future":[-0.0,9007199254740993,1e999],"tombstone":{"value":null,"clock":1}}"#.utf8)
        let snapshot = Data(#"{"activeProfileId":"\#(owner.uuidString)","nativeSync":\#(String(decoding: native, as: UTF8.self)),"roster":{"profiles":{"\#(owner.uuidString)":{"owner":true,"deleted":false,"account":{"kind":"local_only"}}}}}"#.utf8)
        let source = try VortxNativeOwnerHistorySource.Capture(scope: scope, profileID: owner,
            verifiedUID: "synthetic-owner", snapshotData: snapshot)
        let host = try VortxNativeHostPreferences(scope: scope, actor: actor).encoded()
        let hostProjection = try OwnerHistoryAccountExport.hostProjection(host, scope: scope)
        var provider = try VortxNativeProviderCredentials(scope: scope.account, actor: actor)
        try provider.edit(["tmdb": .string("fixture-local")])
        let unknown = Data(#"{"big":9007199254740993,"overflow":1e999,"negativeZero":-0.0,"deleted":null,"order":[3,1,2]}"#.utf8)
        var root = try Exact.Object(Data("{}".utf8))
        root.set("nativeSync", native)
        root.set("nativeHostPreferences", hostProjection.document)
        root.set("profileEditResults", hostProjection.profileEditResults)
        root.set("unknownPeer", unknown)
        root.set("legacyCarrier", unknown)
        root.set("apiKeys", Data(#"{"unknownProvider":\#(String(decoding: unknown, as: UTF8.self)),"metadata":{"unknownMetadata":\#(String(decoding: unknown, as: UTF8.self))}}"#.utf8))
        func reconcile(_ candidate: Exact.Object, state: VortxNativeProviderCredentials? = nil,
                       local: Data? = nil) throws -> OwnerHistoryAccountExport {
            try Subject.reconcile(plaintext: candidate.encoded(), source: source, snapshotData: snapshot,
                hostPreferencesData: host, ownerHistoryLocalData: local, readOwnerUID: "synthetic-owner", provider: state ?? provider)
        }
        let projected = try reconcile(root)
        check(projected.raw("nativeSync") == native)
        check(projected.raw("unknownPeer") == unknown && projected.raw("legacyCarrier") == unknown)
        let projectedKeys = try Exact.Object(projected.raw("apiKeys")!)
        let projectedMetadata = try Exact.Object(projectedKeys.required("metadata"))
        check(try projectedKeys.text("tmdb") == "fixture-local" && projectedMetadata.text("tmdb") == "fixture-local")
        check(projectedKeys["unknownProvider"] == unknown && projectedMetadata["unknownMetadata"] == unknown)
        _ = try projected.validatedPlaintext(writeV2: false)
        _ = try projected.validatedPlaintext(writeV2: true)

        var changed = root
        var changedNative = try Exact.Object(native); changedNative.set("futurePeer", unknown)
        changed.set("nativeSync", try changedNative.encoded())
        rejects { _ = try reconcile(changed) }
        changed = root; changed.remove("nativeHostPreferences")
        rejects { _ = try reconcile(changed) }
        changed = root; changed.set("profileEditResults", unknown)
        rejects { _ = try reconcile(changed) }
        changed = root; changed.set(OwnerHistoryAccountExport.archiveKey, Data("{}".utf8))
        rejects { _ = try reconcile(changed) } // no absent-local fallback over a peer carrier

        // Use the actual journal's empty encoding, not a hand-written algorithm or fake receipt.
        let journal = try VortxNativeOwnerHistoryJournal(scope: scope.account, ownerProfileID: owner).encoded()
        var local = try Exact.Object(Data("{}".utf8))
        local.set("kind", try Exact.string("vortx.owner-history.local/1"))
        local.set("journalBase64", try Exact.string(journal.base64EncodedString()))
        local.set("pending", Data("{}".utf8))
        let localBytes = try local.encoded()
        let carrier = try OwnerHistoryAccountExport.sourceCarrier(local: localBytes, scope: scope, readOwnerUID: "synthetic-owner")
        changed = root; changed.set(OwnerHistoryAccountExport.archiveKey, carrier)
        check(try reconcile(changed, local: localBytes).raw(OwnerHistoryAccountExport.archiveKey) == carrier)
        rejects { _ = try reconcile(root, local: localBytes) }

        // Peer event/legacy alias consistency and secure local hydration requirement are real.
        var remote = provider
        try remote.edit(["tmdb": .string("fixture-peer")])
        changed = root
        changed.set("nativeProviderCredentials", try JSONEncoder().encode(remote.local.document))
        changed.set("apiKeys", Data(#"{"tmdb":"fixture-peer","metadata":{"tmdb":"fixture-peer"}}"#.utf8))
        rejects { _ = try reconcile(changed) }
        let joinedPeer = try Subject.projectingPeerProvider(account: .init(completeAccountPlaintext: changed.encoded()), provider: provider)
        let peerDocument = try JSONDecoder().decode(VortxNativeProviderCredentials.Document.self,
            from: joinedPeer.raw("nativeProviderCredentials")!)
        check(peerDocument.fields["tmdb"]?.value == .string("fixture-peer"))
        check(provider.local.document.fields["tmdb"]?.value == .string("fixture-local"))
        check(joinedPeer.raw("unknownPeer") == unknown && joinedPeer.raw("legacyCarrier") == unknown)
        // A peer projection is not credential persistence/ACK. Contradictory aliases
        // and prepared local writes remain rejected by the same real provider policy.
        var contradictoryPeer = changed
        contradictoryPeer.set("apiKeys", Data(#"{"tmdb":"wrong","metadata":{"tmdb":"fixture-peer"}}"#.utf8))
        rejects { _ = try Subject.projectingPeerProvider(account: .init(completeAccountPlaintext: contradictoryPeer.encoded()), provider: provider) }
        changed = root
        changed.set("nativeProviderCredentials", try JSONEncoder().encode(provider.local.document))
        changed.set("apiKeys", Data(#"{"tmdb":null,"metadata":{"tmdb":"fixture-local"}}"#.utf8))
        rejects { _ = try reconcile(changed) }
        var prepared = provider
        _ = try prepared.prepare(["tmdb": .string("fixture-uncommitted")])
        rejects { _ = try reconcile(root, state: prepared) }

        // A dominating real local clear removes ONLY registered aliases, never unknown data.
        var cleared = provider; try cleared.edit(["tmdb": .null])
        changed = root
        changed.set("nativeProviderCredentials", try JSONEncoder().encode(provider.local.document))
        var aliases = try Exact.Object(root.required("apiKeys"))
        var metadata = try Exact.Object(aliases.required("metadata"))
        aliases.set("tmdb", try Exact.string("fixture-local")); metadata.set("tmdb", try Exact.string("fixture-local"))
        aliases.set("metadata", try metadata.encoded()); changed.set("apiKeys", try aliases.encoded())
        let clearKeys = try Exact.Object(reconcile(changed, state: cleared).raw("apiKeys")!)
        let clearMetadata = try Exact.Object(clearKeys.required("metadata"))
        check(clearKeys["tmdb"] == nil && clearMetadata["tmdb"] == nil)
        check(clearKeys["unknownProvider"] == unknown && clearMetadata["unknownMetadata"] == unknown)
        let clearProvider = try JSONDecoder().decode(VortxNativeProviderCredentials.Document.self,
            from: reconcile(changed, state: cleared).raw("nativeProviderCredentials")!)
        check(clearProvider.fields["tmdb"]?.value == .null)
        var badProvider = try Exact.Object(JSONEncoder().encode(provider.local.document))
        var badFields = try Exact.Object(badProvider.required("fields"))
        var badRegister = try Exact.Object(badFields.required("tmdb"))
        badRegister.set("unknownRegisterExtension", unknown)
        badFields.set("tmdb", try badRegister.encoded()); badProvider.set("fields", try badFields.encoded())
        changed.set("nativeProviderCredentials", try badProvider.encoded())
        rejects { _ = try reconcile(changed) } // reject unknown closed-schema fields, never drop them

        for version in ["0", "1", "9007199254740991"] {
            let envelope = try Subject.envelope(Data(#"{"document":"synthetic-ciphertext","version":\#(version)}"#.utf8))
            check(envelope.version == Int(version) && envelope.document == "synthetic-ciphertext")
        }
        for bad in [#"{"document":"x","version":true}"#, #"{"document":"x","version":-0.0}"#,
                    #"{"document":"x","version":1e0}"#, #"{"document":"x","version":9007199254740992}"#,
                    #"{"document":"x","version":1,"version":2}"#, #"{"document":"x","version":1,"future":0}"#,
                    #"{"document":"","version":1}"#] {
            rejects { _ = try Subject.envelope(Data(bad.utf8)) }
        }
        var excessive = root
        excessive.set("unknownLarge", try Exact.string(String(repeating: "x", count: 6 * 1024 * 1024)))
        let fullExcessive = try reconcile(excessive)
        rejects { _ = try fullExcessive.validatedPlaintext(writeV2: false) }
        rejects { _ = try fullExcessive.validatedPlaintext(writeV2: true) }
        // The ACK view belongs to the exact sent raw candidate, not the current UI or a
        // Foundation decode of source-bearing history. No secure store or native ACK here.
        let sent = Data(#"{"nativeSync":{"scope":"synthetic.raw-account","ownerProfileId":"\#(owner.uuidString)","ownerHistory":{"future":1e999,"wide":9007199254740993},"profiles":{"\#(owner.uuidString)":{"profile":{"id":"\#(owner.uuidString)","accent":"red"},"fieldClocks":{"accent":7,"deleted":2,"unknown":1e999},"future":-0}},"accountSlots":{"\#(owner.uuidString)":{"activeBinding":{"account":{"kind":"local_only"},"revision":0,"transactionId":null},"slots":{"sensitiveSourceBaseline":1e999},"sourceBaseline":-0}}},"nativeHostPreferences":{"profiles":{}},"unknown":1e999}"#.utf8)
        let ack = try Exact.Object(await OwnerHistoryRawAccountPreparationWorker.shared.nativePreferenceAckProjection(sent))
        check(Set(ack.fields.keys) == ["nativeSync", "nativeHostPreferences"])
        let ackNative = try Exact.Object(ack.required("nativeSync"))
        check(Set(ackNative.fields.keys) == ["scope", "ownerProfileId", "profiles", "accountSlots"])
        let ackProfile = try Exact.Object(Exact.Object(ackNative.required("profiles")).required(owner.uuidString))
        check(Set(ackProfile.fields.keys) == ["profile", "fieldClocks"])
        check(try Exact.Object(ackProfile.required("profile")).text("accent") == "red")
        let ackClocks = try Exact.Object(ackProfile.required("fieldClocks"))
        check(Set(ackClocks.fields.keys) == ["accent", "deleted"])
        let ackSlot = try Exact.Object(Exact.Object(ackNative.required("accountSlots")).required(owner.uuidString))
        check(Set(ackSlot.fields.keys) == ["activeBinding"])
        check(try ack.required("nativeHostPreferences") == Exact.Object(sent).required("nativeHostPreferences"))
        let later = Data(String(decoding: sent, as: UTF8.self).replacingOccurrences(of: "red", with: "blue").utf8)
        let laterAck = try Exact.Object(await OwnerHistoryRawAccountPreparationWorker.shared.nativePreferenceAckProjection(later))
        check(try ack.encoded() != laterAck.encoded())
        check(try Exact.Object(ackProfile.required("profile")).text("accent") == "red")
        print("PASS raw account projection retains unknowns/numeric tokens/tombstones, rejects peer/provider drift, and sizes the full account")
    }
}
