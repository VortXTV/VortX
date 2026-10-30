import Foundation
import CoreFoundation
import CryptoKit

/// Exercises actual native Session+Facade, the supplied ABI and encrypted checkpoint store.
/// Takes a caller-provided disposable directory. Never opens an account, app, device or network.
private final class XperienceCountingCheckpointStore: VortxCheckpointStore, @unchecked Sendable {
    let backing: VortxEncryptedCheckpointStore
    private let lock = NSLock()
    private var writes = 0
    private var failAfterNextDurableCommit = false
    private var postWriteFailures = 0
    enum InjectedFailure: Error { case afterDurableCommit }
    init(_ backing: VortxEncryptedCheckpointStore) { self.backing = backing }
    var count: Int { lock.withLock { writes } }
    var injectedFailureCount: Int { lock.withLock { postWriteFailures } }
    func armPostWriteFailure() { lock.withLock { failAfterNextDurableCommit = true } }
    private func didDurablyCommit() throws {
        let fail = lock.withLock { () -> Bool in
            writes += 1
            guard failAfterNextDurableCommit else { return false }
            failAfterNextDurableCommit = false; postWriteFailures += 1; return true
        }
        // The REAL encrypted backing has completed its write/readback before this injected error.
        if fail { throw InjectedFailure.afterDurableCommit }
    }
    func read(scope: VortxAccountScope) throws -> String? { try backing.read(scope: scope) }
    func readHostPreferences(scope: VortxAccountScope) throws -> Data? { try backing.readHostPreferences(scope: scope) }
    func readLegacyMaterial(scope: VortxAccountScope) throws -> Data? { try backing.readLegacyMaterial(scope: scope) }
    func readLegacyProfileEdits(scope: VortxAccountScope) throws -> VortxJSON? { try backing.readLegacyProfileEdits(scope: scope) }
    func commit(_ snapshot: String, scope: VortxAccountScope) throws {
        try backing.commit(snapshot, scope: scope); try didDurablyCommit()
    }
    func commit(_ snapshot: String, scope: VortxAccountScope, hostPreferences: Data) throws {
        try backing.commit(snapshot, scope: scope, hostPreferences: hostPreferences); try didDurablyCommit()
    }
}
private final class XperiencePublicationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var publications = 0
    var count: Int { lock.withLock { publications } }
    func record() { lock.withLock { publications += 1 } }
}
private final class XperienceTestGateAuthority: VortxMutationAuthority, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lifetime: XperienceImportLifetime?
    init(lifetime: XperienceImportLifetime? = nil) { self.lifetime = lifetime }
    func withActive(_ operation: () throws -> Void) throws {
        entered.signal()
        guard release.wait(timeout: .now() + 5) == .success else { throw VortxNativeError.superseded }
        if let lifetime { try lifetime.withActive(operation) } else { try operation() }
    }
}
private struct XperienceTestOwnerAuthority: VortxMutationAuthority {
    func withActive(_ operation: () throws -> Void) throws { try operation() }
}
private final class XperienceSourceNotificationTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var hostChanges = 0
    private var notes = 0
    var hostChangeCount: Int { lock.withLock { hostChanges } }
    var noteCount: Int { lock.withLock { notes } }
    func event(_ event: VortxNativeCoreFacade.SourceEvent) {
        if case .changed(let fields, _) = event.kind, fields.contains("native_host_preferences") {
            lock.withLock { hostChanges += 1 }
        }
    }
    func note() { lock.withLock { notes += 1 } }
}
@main @MainActor enum XperienceNativeCheckpointTests {
    enum Failure: Error { case assertion(String) }
    static func check(_ value: Bool, _ message: String) throws { if !value { throw Failure.assertion(message) } }
    static func register(_ facade: VortxNativeCoreFacade, profile: String, field: String) throws -> VortxJSON? {
        guard let data = facade.stateData("native_host_preferences") else { throw Failure.assertion("host unavailable") }
        return try JSONDecoder().decode(VortxJSON.self, from: data)["profiles"]?[profile]?["fields"]?[field]
    }
    static func raw(_ value: VortxJSON) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    static func document(_ padding: Int = 0) throws -> XperienceCollections.Document {
        try XperienceCollections.project(.array([.object(["id": .string("collection"), "title": .string("Synthetic"),
            "future": .string(String(repeating: "x", count: padding)),
            "folders": .array([.object(["id": .string("folder"), "title": .string("Folder"), "sources": .array([])])])])]))
    }
    /// New assertions use the REAL raw producer, encrypted store, facade and Session bodies.
    /// No register serializer/comparator miniature is substituted. Inputs remain a few KiB.
    static func rawRetention(_ directory: URL) async throws {
        let owner = "10000000-0000-0000-0000-000000000091"
        let actor = "30000000-0000-0000-0000-000000000091"
        let scope = VortxAccountScope(account: "synthetic.xperience-raw-retention", ownerProfileID: owner)
        let backing = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(size: .bits256))
        let store = XperienceCountingCheckpointStore(backing)
        let initial = try VortxNativeSession(scope: scope, ownerName: "Synthetic", abi: VortxCABI(),
            store: store, transport: VortxCResourceTransport(), allowNewAccount: true, hostActor: actor)
        let snapshot = try await initial.stateJSON()
        let initialHost = try await initial.hostPreferencesPublication().rawDocument
        await initial.close()
        let edit = try XperienceImportNamespace.appendRaw(document: document(), label: "Original", bindings: [:])
        let exact = Data("340282366920938463463374607431768211455".utf8)
        var envelope = try OwnerHistoryExactJSON.Object(edit.raw.value)
        envelope.set("futureExact", exact)
        envelope.set("futureDecimal", Data("9007199254740993.0".utf8))
        var register = try OwnerHistoryExactJSON.Object(Data("{}".utf8))
        register.set("clock", Data("7".utf8)); register.set("actor", try OwnerHistoryExactJSON.string(actor))
        register.set("value", try envelope.encoded()); register.set("futureRegister", exact)
        let originalRegister = try register.encoded()
        let futureField = "xperience.import.10000000-0000-0000-0000-000000000092"
        let deletedField = "xperience.import.10000000-0000-0000-0000-000000000093"
        let future = Data((#"{"clock":8,"actor":""# + actor + #"","value":{"schemaVersion":2,"future":340282366920938463463374607431768211455},"extension":9007199254740993.0}"#).utf8)
        let tombstone = Data((#"{"clock":9,"actor":""# + actor + #"","value":null,"future":18446744073709551616}"#).utf8)
        var fields = try OwnerHistoryExactJSON.Object(Data("{}".utf8))
        fields.set(edit.field, originalRegister); fields.set(futureField, future); fields.set(deletedField, tombstone)
        var wrapper = try OwnerHistoryExactJSON.Object(Data("{}".utf8))
        wrapper.set("fields", try fields.encoded()); wrapper.set("futureWrapper", exact)
        var profiles = try OwnerHistoryExactJSON.Object(Data("{}".utf8)); profiles.set(owner, try wrapper.encoded())
        var carrier = try OwnerHistoryExactJSON.Object(initialHost)
        carrier.set("profiles", try profiles.encoded()); carrier.set("futureDocument", exact)
        var sealed = try OwnerHistoryExactJSON.Object(Data("{}".utf8))
        sealed.set("actor", try OwnerHistoryExactJSON.string(actor)); sealed.set("counter", Data("9".utf8))
        sealed.set("document", try carrier.encoded()); sealed.set("futureLocal", exact)
        // This is an explicit SYNTHETIC original encrypted fixture, before reopening the
        // actual producer. No live account/source/SDK bytes are invented from a DTO.
        try backing.commit(snapshot, scope: scope, hostPreferences: sealed.encoded())
        let session = try VortxNativeSession(scope: scope, ownerName: "Synthetic", abi: VortxCABI(),
            store: store, transport: VortxCResourceTransport(), hostActor: actor)
        let facade = try await VortxNativeCoreFacade.create(session: session, registry: session.resourceRegistry(), changed: { _ in })
        guard let binding = facade.watchlistBinding, let registry = facade.registryBinding,
              let observed = facade.capturedHostProfileSnapshot(expected: binding, registry: registry),
              let original = observed.rawRegisters[edit.field] else { throw Failure.assertion("raw original unavailable") }
        try check(original.bytes == originalRegister, "original register was reconstructed after DTO decoding")
        let whitespace = try VortxRawHostRegister.prepared(Data(" \n".utf8) + original.bytes + Data(" \n".utf8))
        try check(VortxRawHostRegister.same(original, whitespace), "raw observation treated whitespace as successor content")
        var precision = try OwnerHistoryExactJSON.Object(original.bytes)
        precision.set("futureRegister", Data("340282366920938463463374607431768211454".utf8))
        try check(!VortxRawHostRegister.same(original, try VortxRawHostRegister.prepared(precision.encoded())),
            "raw CAS rounded exact integers in unknown metadata")
        do {
            _ = try VortxRawHostRegister.prepared(Data(#"{"clock":1,"clock":2,"value":null}"#.utf8))
            throw Failure.assertion("duplicate register key accepted")
        } catch OwnerHistoryExactJSON.Failure.malformed {}
        var deep = Data("0".utf8)
        for _ in 0..<129 { deep = Data("[".utf8) + deep + Data("]".utf8) }
        do {
            var tooDeep = try OwnerHistoryExactJSON.Object(Data("{}".utf8)); tooDeep.set("value", deep)
            _ = try VortxRawHostRegister.prepared(tooDeep.encoded())
            throw Failure.assertion("raw register bypassed depth bound")
        } catch OwnerHistoryExactJSON.Failure.excessive {}
        try check(!VortxRawHostRegister.same(nil, observed.rawRegisters[deletedField]), "raw absence and tombstone were conflated")
        do {
            _ = try XperienceSavedNamespace.read(field: futureField, register: observed.rawRegisters[futureField]!)
            throw Failure.assertion("future format was rewritten as a supported namespace")
        } catch XperiencePersistenceFailure.unsupportedSavedFormat {}
        let saved = try XperienceSavedNamespace.read(field: edit.field, register: original)
        let replacement = try saved.rawReplacement(document: document(), label: "Renamed", bindings: [:])
        let replacementValue = try OwnerHistoryExactJSON.Object(replacement.raw.value)
        try check(replacementValue["futureExact"] == exact && replacementValue["futureDecimal"] == Data("9007199254740993.0".utf8),
            "raw replacement changed an unknown exact value")
        let budget = try XperienceExportBudget(completeAccountPlaintext: Data(#"{"nativeSync":{},"legacy":{"exact":340282366920938463463374607431768211455}}"#.utf8),
            maximumSealedBytes: XperienceExportBudget.officialMaximumSealedBytes, writeV2: true)
        let accepted = try await facade.setCapturedRawHostProfileField(replacement.nativeEdit, expected: binding, registry: registry,
            sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: budget)
        let acceptedObject = try OwnerHistoryExactJSON.Object(accepted.bytes)
        try check(acceptedObject["futureRegister"] == exact, "complete register metadata was erased")
        guard let durable = try store.readHostPreferences(scope: scope) else { throw Failure.assertion("raw checkpoint absent") }
        let local = try OwnerHistoryExactJSON.Object(durable)
        let durableDocument = try OwnerHistoryExactJSON.Object(local.required("document"))
        let durableProfiles = try OwnerHistoryExactJSON.Object(durableDocument.required("profiles"))
        let durableWrapper = try OwnerHistoryExactJSON.Object(durableProfiles.required(owner))
        let durableFields = try OwnerHistoryExactJSON.Object(durableWrapper.required("fields"))
        try check(local["futureLocal"] == exact && durableDocument["futureDocument"] == exact && durableWrapper["futureWrapper"] == exact,
            "producer-to-checkpoint path erased unknown siblings")
        try check(durableFields[futureField] == future && durableFields[deletedField] == tombstone,
            "unknown format or tombstone was pruned by replacement")
        let durableValue = try OwnerHistoryExactJSON.Object(OwnerHistoryExactJSON.Object(durableFields.required(edit.field)).required("value"))
        try check(durableValue["futureExact"] == exact && durableValue["futureDecimal"] == Data("9007199254740993.0".utf8),
            "raw future integer/decimal changed in encrypted checkpoint")
        let count = store.count
        do {
            _ = try await facade.setCapturedRawHostProfileField(replacement.nativeEdit, expected: binding, registry: registry,
                sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: budget)
            throw Failure.assertion("raw stale original CAS accepted")
        } catch VortxNativeHostFieldMutationError.staleRegister {}
        try check(store.count == count && store.readHostPreferences(scope: scope) == durable, "raw CAS rejection changed durable bytes")
        // Equal clock+actor/value with changed unknown register metadata is still a
        // different full observation, and actual merge must reject its contradiction.
        var contradictory = try OwnerHistoryExactJSON.Object(accepted.bytes)
        contradictory.set("futureRegister", Data("340282366920938463463374607431768211454".utf8))
        var remoteFields = try OwnerHistoryExactJSON.Object(Data("{}".utf8)); remoteFields.set(edit.field, try contradictory.encoded())
        var remoteWrapper = try OwnerHistoryExactJSON.Object(Data("{}".utf8)); remoteWrapper.set("fields", try remoteFields.encoded())
        var remoteProfiles = try OwnerHistoryExactJSON.Object(Data("{}".utf8)); remoteProfiles.set(owner, try remoteWrapper.encoded())
        var remote = try OwnerHistoryExactJSON.Object(durableDocument.encoded()); remote.set("profiles", try remoteProfiles.encoded())
        do {
            _ = try await session.dispatch([], now: 1001, hostRemoteRaw: remote.encoded())
            throw Failure.assertion("same-clock/actor raw contradiction merged")
        } catch VortxNativeError.invalidSnapshot {}
        try check(store.count == count && store.readHostPreferences(scope: scope) == durable, "contradictory merge wrote")
        do {
            _ = try await session.dispatch([], now: 1001,
                hostEdits: [.init(profileID: owner, fields: [edit.field: replacement.value], rawFields: [edit.field: replacement.raw.value])],
                hostFieldCAS: .init(profileID: owner, field: edit.field, register: replacement.expectedRegister, raw: replacement.raw),
                checkpointValidator: budget)
            throw Failure.assertion("actual Session before-edit raw CAS accepted the old observation")
        } catch VortxNativeHostFieldMutationError.staleRegister {}
        try check(store.count == count && store.readHostPreferences(scope: scope) == durable, "raw Session stale CAS wrote")
        let cancel = try XperienceImportNamespace.appendRaw(document: Self.document(), label: "Raw cancellation", bindings: [:])
        let gate = XperienceTestGateAuthority()
        let cancelled = Task {
            try await facade.setCapturedRawHostProfileField(cancel.nativeEdit, expected: binding, registry: registry,
                sourceAuthority: gate, checkpointValidator: budget)
        }
        let entered = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: gate.entered.wait(timeout: .now() + 5) == .success) }
        }
        try check(entered, "raw final authority not reached")
        cancelled.cancel(); gate.release.signal()
        do { _ = try await cancelled.value; throw Failure.assertion("raw cancellation reached durability") }
        catch VortxNativeHostFieldMutationError.cancelled {}
        try check(store.count == count && store.readHostPreferences(scope: scope) == durable, "raw cancelled checkpoint changed bytes")
        // Existing typed unrelated edits must materialize against the retained raw baseline.
        _ = try await session.dispatch([], now: 1002, hostEdits: [.init(profileID: owner, fields: ["avatar": .string("synthetic")])])
        let unrelated = try OwnerHistoryExactJSON.Object(store.readHostPreferences(scope: scope)!)
        let unrelatedDocument = try OwnerHistoryExactJSON.Object(unrelated.required("document"))
        let unrelatedProfiles = try OwnerHistoryExactJSON.Object(unrelatedDocument.required("profiles"))
        let unrelatedFields = try OwnerHistoryExactJSON.Object(OwnerHistoryExactJSON.Object(unrelatedProfiles.required(owner)).required("fields"))
        try check(unrelatedFields[edit.field] == accepted.bytes && unrelatedFields[futureField] == future && unrelatedFields[deletedField] == tombstone,
            "unrelated typed edit rewrote raw registers")
        // The generic exporter uses the exact production projection, retaining complete
        // unknown account/native siblings without sending provider/account data to host.
        let account = try OwnerHistoryAccountExport(completeAccountPlaintext:
            Data(#"{"legacy":{"exact":340282366920938463463374607431768211455},"nativeSync":{"futureNative":9007199254740993.0},"providerSibling":{"keep":18446744073709551616}}"#.utf8))
        let exported = try account.projectingGenericHost(native: .object(["schemaVersion": .integer(1)]),
            host: unrelatedDocument.encoded(), profileEditResults: .object([:]))
        try check(exported.raw("legacy") == account.raw("legacy") && exported.raw("providerSibling") == account.raw("providerSibling") &&
            exported.raw("nativeHostPreferences") == unrelatedDocument.encoded(), "generic exporter lost original raw siblings/host")
        let exportedNative = try OwnerHistoryExactJSON.Object(exported.raw("nativeSync")!)
        try check(exportedNative["futureNative"] == Data("9007199254740993.0".utf8), "generic native sibling changed")
        let tiny = try XperienceExportBudget(completeAccountPlaintext: exported.encoded(), maximumSealedBytes: 32, writeV2: true)
        do {
            try tiny.validateRawHost(native: .object(["schemaVersion": .integer(1)]), host: unrelatedDocument.encoded(), profileEditResults: .object([:]))
            throw Failure.assertion("exact raw export budget ignored retained siblings")
        } catch XperiencePersistenceFailure.exportTooLarge {}
        await facade.shutdown()
    }
    /// Real encrypted Session -> actual Facade -> complete literal production CoreBridge
    /// callback/lifetime/mailbox -> actual Store subscription. Fixture context and downstream
    /// metadata receiver are collaborators only; no manually posted notification is used.
    static func rawPublicationNotifications(_ directory: URL) async throws {
        let owner = "10000000-0000-0000-0000-000000000094"
        let actor = "30000000-0000-0000-0000-000000000094"
        let scope = VortxAccountScope(account: "synthetic.xperience-raw-notifications", ownerProfileID: owner)
        let backing = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(size: .bits256))
        let counted = XperienceCountingCheckpointStore(backing)
        let initial = try VortxNativeSession(scope: scope, ownerName: "Synthetic", abi: VortxCABI(),
            store: counted, transport: VortxCResourceTransport(), allowNewAccount: true, hostActor: actor)
        let snapshot = try await initial.stateJSON()
        await initial.close()
        let first = try XperienceImportNamespace.appendRaw(document: document(), label: "First", bindings: [:])
        var otherCollections = try document().raw.array!
        var otherCollection = try otherCollections[0].decode([String: VortxJSON].self)
        otherCollection["id"] = .string("other-notification-collection"); otherCollections[0] = .object(otherCollection)
        let second = try XperienceImportNamespace.appendRaw(document: XperienceCollections.project(.array(otherCollections)),
            label: "Other register", bindings: [:])
        var source = try VortxNativeHostPreferences(scope: scope, actor: actor)
        try source.editRaw(profileID: owner, field: first.field, value: first.raw.value, scope: scope)
        try source.editRaw(profileID: owner, field: second.field, value: second.raw.value, scope: scope)
        var local = try OwnerHistoryExactJSON.Object(source.encoded())
        var host = try OwnerHistoryExactJSON.Object(local.required("document"))
        var profiles = try OwnerHistoryExactJSON.Object(host.required("profiles"))
        var profile = try OwnerHistoryExactJSON.Object(profiles.required(owner))
        var fields = try OwnerHistoryExactJSON.Object(profile.required("fields"))
        var other = try OwnerHistoryExactJSON.Object(fields.required(second.field))
        other.set("futureRegister", Data("340282366920938463463374607431768211455".utf8))
        fields.set(second.field, try other.encoded()); profile.set("fields", try fields.encoded())
        profiles.set(owner, try profile.encoded()); host.set("profiles", try profiles.encoded())
        local.set("document", try host.encoded())
        try backing.commit(snapshot, scope: scope, hostPreferences: local.encoded())
        let session = try VortxNativeSession(scope: scope, ownerName: "Synthetic", abi: VortxCABI(),
            store: counted, transport: VortxCResourceTransport(), hostActor: actor)
        let core = CoreBridge(), trace = XperienceSourceNotificationTrace()
        let callback = core.makeNotificationSourceCallbackForFixture()
        let note = NotificationCenter.default.addObserver(forName: CoreBridge.xperienceContextChangedNote,
            object: nil, queue: nil) { _ in trace.note() }
        defer { NotificationCenter.default.removeObserver(note) }
        let facade = try await VortxNativeCoreFacade.create(session: session, registry: session.resourceRegistry(),
            sourceEvent: { event in trace.event(event); callback(event) }, changed: { _ in })
        try core.installOriginalForFixture(facade)
        let store = XperienceCollectionsStore(core: core)
        let lease = try store.capture()
        guard let binding = facade.watchlistBinding, let registry = facade.registryBinding,
              let original = facade.capturedHostProfileSnapshot(expected: binding, registry: registry) else {
            throw Failure.assertion("notification original source unavailable")
        }
        let typed = try await session.hostPreferencesDocument()
        let previousValues: [String: VortxJSON] = ["native_host_preferences": typed]
        let originalRaw = [owner: original.rawRegisters]
        // Complete register metadata at equal clock+actor is rejected by mergeRaw. Do not
        // waive that rule to manufacture a supposedly accepted runtime event. Instead test
        // the EXACT production changed-field decision with typed-equal acknowledged evidence.
        var metadataOnly = try OwnerHistoryExactJSON.Object(original.rawRegisters[second.field]!.bytes)
        metadataOnly.set("futureRegister", Data("340282366920938463463374607431768211454".utf8))
        var metadataRaw = original.rawRegisters
        metadataRaw[second.field] = try VortxRawHostRegister.prepared(metadataOnly.encoded())
        let actualDecision = VortxNativeCoreFacade.acknowledgedChangedFields(previous: previousValues,
            acknowledged: previousValues, previousRaw: originalRaw, acknowledgedRaw: [owner: metadataRaw])
        try check(actualDecision == ["native_host_preferences"], "actual publication decision hid typed-equal other-register metadata")
        let a = original.rawRegisters[second.field]!, b = metadataRaw[second.field]!
        let opaqueA = VortxRawHostRegister(bytes: a.bytes, canonical: nil, value: a.value, canonicalValue: nil, metadata: nil)
        let opaqueB = VortxRawHostRegister(bytes: b.bytes, canonical: nil, value: b.value, canonicalValue: nil, metadata: nil)
        var noCacheA = original.rawRegisters, noCacheB = original.rawRegisters
        noCacheA[second.field] = opaqueA; noCacheB[second.field] = opaqueB
        try check(VortxNativeCoreFacade.acknowledgedChangedFields(previous: previousValues, acknowledged: previousValues,
            previousRaw: [owner: noCacheA], acknowledgedRaw: [owner: noCacheB]) == ["native_host_preferences"],
            "two absent canonical caches hid different raw observations")
        var whitespaceRaw = original.rawRegisters
        whitespaceRaw[second.field] = try VortxRawHostRegister.prepared(Data(" \n".utf8) + a.bytes + Data(" \n".utf8))
        try check(VortxNativeCoreFacade.acknowledgedChangedFields(previous: previousValues, acknowledged: previousValues,
            previousRaw: originalRaw, acknowledgedRaw: [owner: whitespaceRaw]).isEmpty,
            "successful semantic raw caches lost intended whitespace conflation")
        // Real Session accepted no-content merge: source canonical equality keeps the
        // original full register. Neither facade nor actual callback should fabricate a hint.
        var whitespaceFields = fields; whitespaceFields.set(second.field, whitespaceRaw[second.field]!.bytes)
        var whitespaceProfile = profile; whitespaceProfile.set("fields", try whitespaceFields.encoded())
        var whitespaceProfiles = profiles; whitespaceProfiles.set(owner, try whitespaceProfile.encoded())
        var whitespaceHost = host; whitespaceHost.set("profiles", try whitespaceProfiles.encoded())
        _ = try await facade.mergeAccountDocumentReceipt(nil, hostRemote: nil, legacyMaterial: nil,
            hostRemoteRaw: whitespaceHost.encoded())
        await facade.settled()
        try check(trace.hostChangeCount == 0 && trace.noteCount == 0 && store.isCurrent(lease) && core.captureCount == 1,
            "real unchanged raw merge emitted a context hint or recaptured ownership")
        // Accepted LWW update changes the OTHER register's unknown metadata and advances
        // its real clock. The real pipeline must deliver a note to the original Store.
        // This integration case is separate from the typed-equal source decision above.
        metadataOnly.set("clock", Data("3".utf8))
        var nextFields = fields; nextFields.set(second.field, try metadataOnly.encoded())
        var nextProfile = profile; nextProfile.set("fields", try nextFields.encoded())
        var nextProfiles = profiles; nextProfiles.set(owner, try nextProfile.encoded())
        var nextHost = host; nextHost.set("profiles", try nextProfiles.encoded())
        let nextHostBytes = try nextHost.encoded()
        try await core.observeRealMutationForFixture {
            _ = try await facade.mergeAccountDocumentReceipt(nil, hostRemote: nil, legacyMaterial: nil,
                hostRemoteRaw: nextHostBytes)
        }
        await facade.settled()
        try check(trace.hostChangeCount == 1 && trace.noteCount == 1,
            "actual Session/Facade/CoreBridge callback did not deliver the real host hint")
        try check(!store.isCurrent(lease) && core.captureCount == 1 && facade.watchlistBinding == binding,
            "other-register metadata notification failed to retire the original view or recaptured a successor")
        guard let acknowledged = facade.capturedHostProfileSnapshot(expected: binding, registry: registry) else {
            throw Failure.assertion("original notification source retired unexpectedly")
        }
        try check(VortxRawHostRegister.same(acknowledged.rawRegisters[first.field], original.rawRegisters[first.field]),
            "other-register notification changed the originally rendered field")
        let rawOther = try OwnerHistoryExactJSON.Object(acknowledged.rawRegisters[second.field]!.bytes)
        try check(rawOther["futureRegister"] == Data("340282366920938463463374607431768211454".utf8),
            "real notification path changed or lost unknown raw register metadata")
        await facade.shutdown()
    }
    static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.assertion("disposable directory required") }
        try await rawRetention(URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("raw-register-retention"))
        try await rawPublicationNotifications(URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("raw-notification"))
        let owner = "10000000-0000-0000-0000-000000000071"
        let scope = VortxAccountScope(account: "synthetic.xperience-checkpoint", ownerProfileID: owner)
        let backing = try VortxEncryptedCheckpointStore(directory: URL(fileURLWithPath: CommandLine.arguments[1]),
            key: SymmetricKey(size: .bits256))
        let store = XperienceCountingCheckpointStore(backing)
        let session = try VortxNativeSession(scope: scope, ownerName: "Synthetic", abi: VortxCABI(),
            store: store, transport: VortxCResourceTransport(), allowNewAccount: true)
        let facade = try await VortxNativeCoreFacade.create(session: session, registry: session.resourceRegistry(), changed: { _ in })
        guard let binding = facade.watchlistBinding, let registry = facade.registryBinding else { throw Failure.assertion("native context unavailable") }
        let initialState = try store.read(scope: scope), initialHost = try store.readHostPreferences(scope: scope)
        let edit = try XperienceImportNamespace.append(document: document(), label: "Initial", bindings: [:])
        let rejected = try XperienceExportBudget(completeAccountDocument: .object(["preserved": .string("old")]),
            maximumSealedBytes: 1, writeV2: true)
        let before = store.count
        do {
            _ = try await facade.setCapturedHostProfileField(edit.nativeEdit, expected: binding, registry: registry,
                sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: rejected)
            throw Failure.assertion("oversize full export committed")
        } catch XperiencePersistenceFailure.exportTooLarge {}
        try check(store.count == before && store.read(scope: scope) == initialState &&
            store.readHostPreferences(scope: scope) == initialHost, "budget failure altered durable checkpoint")
        try check(facade.isAvailable, "preflight failure incorrectly poisoned checkpoint certainty")
        let accepted = try XperienceExportBudget(completeAccountDocument: .object(["preserved": .string("old")]),
            maximumSealedBytes: XperienceExportBudget.officialMaximumSealedBytes, writeV2: true)
        let receipt = try await facade.setCapturedHostProfileField(edit.nativeEdit, expected: binding, registry: registry,
            sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: accepted)
        try check(receipt["value"] == edit.value && store.count == before + 1, "durable receipt missing")
        let saved = try XperienceSavedNamespace.read(field: edit.field, register: receipt)
        let replacement = try saved.replacement(document: document(), label: "Replacement", bindings: [:])
        _ = try await facade.setCapturedHostProfileField(replacement.nativeEdit, expected: binding, registry: registry,
            sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: accepted)
        let countAfterReplace = store.count
        do {
            _ = try await facade.setCapturedHostProfileField(replacement.nativeEdit, expected: binding, registry: registry,
                sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: accepted)
            throw Failure.assertion("stale complete register accepted")
        } catch VortxNativeHostFieldMutationError.staleRegister {}
        try check(store.count == countAfterReplace, "stale CAS wrote checkpoint")

        // The session checks its ACTUAL candidate host too, not only the facade cache.
        do {
            _ = try await session.dispatch([], now: 1000,
                hostEdits: [.init(profileID: owner, fields: [edit.field: edit.value])],
                hostFieldCAS: .init(profileID: owner, field: edit.field, register: receipt), checkpointValidator: accepted)
            throw Failure.assertion("stale actual-session CAS accepted")
        } catch VortxNativeHostFieldMutationError.staleRegister {}
        try check(store.count == countAfterReplace, "actual-session CAS wrote checkpoint")

        // Actual Session's before-edit CAS must reject Unicode-canonical-equivalent evidence.
        // Same clock, actor, keys and structure; ONLY the UTF8 form of the label differs.
        let unicodeScope = VortxAccountScope(account: "synthetic.xperience-unicode-register-cas",
            ownerProfileID: "10000000-0000-0000-0000-000000000074")
        let unicodeKey = SymmetricKey(size: .bits256)
        let unicodeBacking = try VortxEncryptedCheckpointStore(
            directory: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("unicode-register-cas"),
            key: unicodeKey)
        let unicodeStore = XperienceCountingCheckpointStore(unicodeBacking)
        let unicodeSession = try VortxNativeSession(scope: unicodeScope, ownerName: "Synthetic", abi: VortxCABI(),
            store: unicodeStore, transport: VortxCResourceTransport(), allowNewAccount: true)
        let unicodeField = "xperience.import.10000000-0000-0000-0000-000000000073"
        let nfc = "\u{00e9}", nfd = "e\u{0301}"
        _ = try await unicodeSession.dispatch([], now: 1000,
            hostEdits: [.init(profileID: unicodeScope.ownerProfileID, fields: [unicodeField: .object(["label": .string(nfd)])])])
        let unicodeHost = try await unicodeSession.hostPreferencesDocument()
        guard let actualUnicodeRegister = unicodeHost["profiles"]?[unicodeScope.ownerProfileID]?["fields"]?[unicodeField] else {
            throw Failure.assertion("Unicode candidate register missing")
        }
        var exactExpected = try actualUnicodeRegister.decode([String: VortxJSON].self)
        exactExpected["value"] = .object(["label": .string(nfc)])
        let expectedNFC = VortxJSON.object(exactExpected)
        try check(expectedNFC == actualUnicodeRegister &&
            !XperienceExactEvidence.json(expectedNFC, actualUnicodeRegister), "actual Unicode fixture lost its negative control")
        let unicodeBefore = unicodeStore.count, unicodeBytesBefore = try unicodeStore.readHostPreferences(scope: unicodeScope)
        do {
            _ = try await unicodeSession.dispatch([], now: 1001,
                hostEdits: [.init(profileID: unicodeScope.ownerProfileID, fields: [unicodeField: .object(["label": .string("must-not-commit")])])],
                hostFieldCAS: .init(profileID: unicodeScope.ownerProfileID, field: unicodeField, register: expectedNFC))
            throw Failure.assertion("actual Session CAS accepted byte-distinct NFC evidence")
        } catch VortxNativeHostFieldMutationError.staleRegister {}
        try check(unicodeStore.count == unicodeBefore && unicodeStore.readHostPreferences(scope: unicodeScope) == unicodeBytesBefore,
            "Unicode CAS rejection modified actual encrypted checkpoint")
        await unicodeSession.close()

        // 14 individually valid near-limit imports must NOT bypass whole encrypted document budget.
        // Different IDs avoid the separate identical-import check.
        var hitBudget = false
        for index in 0..<14 {
            var doc = try document(500_000).raw.array!
            var entry = try doc[0].decode([String: VortxJSON].self)
            entry["id"] = .string("large-\(index)"); doc[0] = .object(entry)
            let large = try XperienceImportNamespace.append(document: XperienceCollections.project(.array(doc)),
                label: "Large synthetic", bindings: [:])
            let oldState = try store.read(scope: scope), oldHost = try store.readHostPreferences(scope: scope), oldCount = store.count
            do {
                _ = try await facade.setCapturedHostProfileField(large.nativeEdit, expected: binding, registry: registry,
                    sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: accepted)
            } catch XperiencePersistenceFailure.exportTooLarge {
                hitBudget = true
                try check(store.count == oldCount && store.read(scope: scope) == oldState &&
                    store.readHostPreferences(scope: scope) == oldHost, "aggregate failure pruned or modified checkpoint")
                break
            }
        }
        try check(hitBudget && facade.isAvailable, "aggregate growth did not reject safely")
        try check(try register(facade, profile: owner, field: edit.field)?["value"]?["label"] == .string("Replacement"),
            "existing namespace disappeared during aggregate rejection")
        // Actual A->B->A native selection retires the full profile generation, not just its ID.
        func dispatch(_ action: VortxJSON) async throws {
            try check(facade.dispatch(data: JSONEncoder().encode(VortxJSON.object(["action": .string("Vortx"), "args": action])),
                field: "native_state"), "profile fixture dispatch not admitted")
            await facade.settled()
        }
        let child = "10000000-0000-0000-0000-000000000072"
        try await dispatch(.object(["type": .string("add_profile"), "id": .string(child), "name": .string("Synthetic child")]))
        guard let beforeABA = facade.watchlistBinding, let registryBeforeABA = facade.registryBinding else {
            throw Failure.assertion("ABA fixture binding unavailable")
        }
        try await dispatch(.object(["type": .string("switch_profile"), "id": .string(child)]))
        try await dispatch(.object(["type": .string("switch_profile"), "id": .string(owner)]))
        try check(facade.watchlistBinding?.profileID == beforeABA.profileID &&
            facade.watchlistBinding?.accountGeneration == beforeABA.accountGeneration &&
            facade.watchlistBinding?.profileGeneration != beforeABA.profileGeneration, "native selection ABA not retired")
        let freshEdit = try XperienceImportNamespace.append(document: document(), label: "Stale ABA", bindings: [:])
        let beforeStale = store.count
        do {
            _ = try await facade.setCapturedHostProfileField(freshEdit.nativeEdit, expected: beforeABA, registry: registryBeforeABA,
                sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: accepted)
            throw Failure.assertion("ABA context accepted")
        } catch VortxNativeError.superseded {}
        try check(store.count == beforeStale, "ABA rejection wrote checkpoint")
        let currentBinding = facade.watchlistBinding!, currentRegistry = facade.registryBinding!
        try await facade.rebindRegistry([], expected: currentRegistry)
        try check(facade.capturedHostProfileSnapshot(expected: currentBinding, registry: currentRegistry) == nil,
            "same-descriptor registry ABA accepted old mapping context")
        guard let reboundBinding = facade.watchlistBinding, let reboundRegistry = facade.registryBinding else {
            throw Failure.assertion("rebound context unavailable")
        }
        try check(facade.capturedHostProfileSnapshot(expected: reboundBinding, registry: reboundRegistry) == nil,
            "missing acknowledged host carrier was misrepresented as an empty profile")
        let beforeUnknownHost = store.count
        do {
            _ = try await facade.setCapturedHostProfileField(freshEdit.nativeEdit, expected: reboundBinding, registry: reboundRegistry,
                sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: accepted)
            throw Failure.assertion("missing acknowledged host carrier admitted a mutation")
        } catch VortxNativeError.invalidSnapshot {}
        try check(store.count == beforeUnknownHost, "unknown host carrier reached durable sink")
        // Republish through the REAL native FIFO, not a synthesized/host-injected cache.
        try await dispatch(.object(["type": .string("get_state")]))
        guard let restoredBinding = facade.watchlistBinding, let restoredRegistry = facade.registryBinding,
              let restored = facade.capturedHostProfileSnapshot(expected: restoredBinding, registry: restoredRegistry) else {
            throw Failure.assertion("real get_state did not restore acknowledged host carrier")
        }
        try check(restored.registers[edit.field]?["value"]?["label"] == .string("Replacement"),
            "rebind/get_state lost existing saved namespace")

        // Cancel AFTER FIFO admission but BEFORE final checkpoint authority enters the latch.
        let gate = XperienceTestGateAuthority()
        let cancellationEdit = try XperienceImportNamespace.append(document: document(), label: "Cancelled", bindings: [:])
        // Use a changed fingerprint so duplicate-import admission is not the rejection reason.
        var cancelRaw = try document().raw.array!, cancelObject = try cancelRaw[0].decode([String: VortxJSON].self)
        cancelObject["id"] = .string("cancel-before-checkpoint"); cancelRaw[0] = .object(cancelObject)
        let cancelEdit = try XperienceImportNamespace.append(document: XperienceCollections.project(.array(cancelRaw)),
            label: "Cancelled", bindings: [:])
        _ = cancellationEdit // prove an unsubmitted draft has no effect
        let cancelBinding = facade.watchlistBinding!, cancelRegistry = facade.registryBinding!, countBeforeCancel = store.count
        let pending = Task {
            try await facade.setCapturedHostProfileField(cancelEdit.nativeEdit, expected: cancelBinding, registry: cancelRegistry,
                sourceAuthority: gate, checkpointValidator: accepted)
        }
        let entered = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: gate.entered.wait(timeout: .now() + 5) == .success) }
        }
        try check(entered, "final checkpoint authority not reached")
        pending.cancel(); gate.release.signal()
        do { _ = try await pending.value; throw Failure.assertion("cancelled final checkpoint committed") }
        catch VortxNativeHostFieldMutationError.cancelled {}
        try check(store.count == countBeforeCancel && (try register(facade, profile: owner, field: cancelEdit.field)) == nil,
            "cancelled transaction reached durable sink")
        // Retiring the STORE/GESTURE lifetime after FIFO admission must also revoke the worker,
        // even when account/profile/registry are unchanged and the task itself was never canceled.
        var retiredRaw = try document().raw.array!, retiredObject = try retiredRaw[0].decode([String: VortxJSON].self)
        retiredObject["id"] = .string("retired-original-gesture"); retiredRaw[0] = .object(retiredObject)
        let retiredEdit = try XperienceImportNamespace.append(document: XperienceCollections.project(.array(retiredRaw)),
            label: "Retired original gesture", bindings: [:])
        let capturedLifetime = XperienceImportLifetime(), retirementGate = XperienceTestGateAuthority(lifetime: capturedLifetime)
        let retirementBinding = facade.watchlistBinding!, retirementRegistry = facade.registryBinding!, beforeRetirement = store.count
        let queuedOriginal = Task {
            try await facade.setCapturedHostProfileField(retiredEdit.nativeEdit, expected: retirementBinding, registry: retirementRegistry,
                sourceAuthority: retirementGate, checkpointValidator: accepted)
        }
        let originalEntered = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: retirementGate.entered.wait(timeout: .now() + 5) == .success) }
        }
        try check(originalEntered, "queued original lifetime did not reach final authority")
        capturedLifetime.revoke() // the exact primitive called by Store.invalidate/superseding capture
        let unrelatedNewGestureLifetime = XperienceImportLifetime()
        try check(unrelatedNewGestureLifetime.isActive, "new gesture fixture unavailable")
        retirementGate.release.signal()
        do { _ = try await queuedOriginal.value; throw Failure.assertion("retired original gesture committed") }
        catch XperiencePersistenceFailure.staleContext {}
        try check(store.count == beforeRetirement && (try register(facade, profile: owner, field: retiredEdit.field)) == nil,
            "presentation retirement left a live worker checkpoint authority")
        await facade.shutdown()

        // A REAL encrypted checkpoint may reach disk before a storage/readback error is reported.
        // This isolated synthetic account must stay write-blocked and un-published until reopen.
        let faultScope = VortxAccountScope(account: "synthetic.xperience-post-write-failure",
            ownerProfileID: "10000000-0000-0000-0000-000000000075")
        let faultKey = SymmetricKey(size: .bits256)
        let faultBacking = try VortxEncryptedCheckpointStore(
            directory: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("post-write-failure"),
            key: faultKey)
        let faultStore = XperienceCountingCheckpointStore(faultBacking)
        let faultSession = try VortxNativeSession(scope: faultScope, ownerName: "Synthetic", abi: VortxCABI(),
            store: faultStore, transport: VortxCResourceTransport(), allowNewAccount: true)
        let publications = XperiencePublicationCounter()
        let faultFacade = try await VortxNativeCoreFacade.create(session: faultSession, registry: faultSession.resourceRegistry(),
            changed: { _ in publications.record() })
        guard let faultBinding = faultFacade.watchlistBinding, let faultRegistry = faultFacade.registryBinding,
              let projectedBefore = faultFacade.stateData("native_host_preferences"),
              let stateBefore = faultFacade.stateData("native_state") else { throw Failure.assertion("fault fixture unavailable") }
        let faultEdit = try XperienceImportNamespace.append(document: document(), label: "Durable but not acknowledged", bindings: [:])
        let beforeFault = faultStore.count, beforePublications = publications.count
        faultStore.armPostWriteFailure()
        do {
            _ = try await faultFacade.setCapturedHostProfileField(faultEdit.nativeEdit, expected: faultBinding, registry: faultRegistry,
                sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: accepted)
            throw Failure.assertion("post-write failure returned a successful receipt")
        } catch VortxNativeError.checkpointUncertain {}
        guard let diskHostBytes = try faultStore.readHostPreferences(scope: faultScope),
              let projectedAfter = faultFacade.stateData("native_host_preferences"),
              let stateAfter = faultFacade.stateData("native_state") else { throw Failure.assertion("fault readback unavailable") }
        let diskHost = try JSONDecoder().decode(VortxJSON.self, from: diskHostBytes)
        try check(faultStore.injectedFailureCount == 1 && faultStore.count == beforeFault + 1 &&
            VortxNativeHostFieldEvidence.json(diskHost["document"]?["profiles"]?[faultScope.ownerProfileID]?["fields"]?[faultEdit.field]?["value"], faultEdit.value),
            "injected error did not follow an actual durable encrypted write/readback")
        try check(faultFacade.requiresCheckpointReopen && !faultFacade.isAvailable &&
            faultFacade.lastFailure == "checkpoint_uncertain_reopen_required", "uncertain checkpoint was not fenced")
        try check(publications.count == beforePublications &&
            VortxNativeHostFieldEvidence.json(try JSONDecoder().decode(VortxJSON.self, from: projectedBefore),
                try JSONDecoder().decode(VortxJSON.self, from: projectedAfter)) &&
            VortxNativeHostFieldEvidence.json(try JSONDecoder().decode(VortxJSON.self, from: stateBefore),
                try JSONDecoder().decode(VortxJSON.self, from: stateAfter)),
            "uncertain checkpoint published an unacknowledged new projection")
        let afterFault = faultStore.count
        do {
            _ = try await faultSession.dispatch([], now: 2000,
                hostEdits: [.init(profileID: faultScope.ownerProfileID, fields: ["synthetic.afterFault": .bool(true)])])
            throw Failure.assertion("session admitted mutation before checkpoint reopen")
        } catch VortxNativeError.checkpointUncertain {}
        do {
            _ = try await faultFacade.setCapturedHostProfileField(faultEdit.nativeEdit, expected: faultBinding, registry: faultRegistry,
                sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: accepted)
            throw Failure.assertion("facade admitted mutation before checkpoint reopen")
        } catch VortxNativeError.superseded {}
        try check(faultStore.count == afterFault && publications.count == beforePublications,
            "blocked post-failure mutation reached durable sink/publication")
        await faultFacade.shutdown() // release the real scope-account writer before reopening
        let reopenedSession = try VortxNativeSession(scope: faultScope, ownerName: "Synthetic", abi: VortxCABI(),
            store: faultStore, transport: VortxCResourceTransport())
        let reopenedFacade = try await VortxNativeCoreFacade.create(session: reopenedSession, registry: reopenedSession.resourceRegistry(),
            changed: { _ in })
        guard let reopenedBinding = reopenedFacade.watchlistBinding, let reopenedRegistry = reopenedFacade.registryBinding,
              let reopenedRegister = try register(reopenedFacade, profile: faultScope.ownerProfileID, field: faultEdit.field) else {
            throw Failure.assertion("authenticated reopen did not recover durable uncertain checkpoint")
        }
        try check(reopenedFacade.isAvailable && !reopenedFacade.requiresCheckpointReopen &&
            VortxNativeHostFieldEvidence.json(reopenedRegister["value"], faultEdit.value), "reopen did not certify durable value")
        let recovered = try XperienceSavedNamespace.read(field: faultEdit.field, register: reopenedRegister)
        let afterReopenEdit = try recovered.replacement(document: document(), label: "Reopened acknowledged", bindings: [:])
        let countAfterReopen = faultStore.count
        let afterReopenReceipt = try await reopenedFacade.setCapturedHostProfileField(afterReopenEdit.nativeEdit,
            expected: reopenedBinding, registry: reopenedRegistry, sourceAuthority: XperienceTestOwnerAuthority(), checkpointValidator: accepted)
        try check(faultStore.count == countAfterReopen + 1 &&
            VortxNativeHostFieldEvidence.json(afterReopenReceipt["value"], afterReopenEdit.value),
            "validated reopen did not permit a subsequent acknowledged mutation")
        await reopenedFacade.shutdown()
        print("PASS actual native CAS/budget/ABA/registry/unknown-carrier/cancellation/lifetime/preflight/postwrite-reopen")
    }
    static func main() {
        // The actual Store uses receive(on: RunLoop.main); keep that Foundation delivery
        // boundary live while the existing real native checkpoint cases await their work.
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL Xperience native checkpoint components"); exit(1) }
        }
        CFRunLoopRun()
    }
}
