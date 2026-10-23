import Foundation
import CryptoKit

/// Exercises the actual production parser/binder/persistence components, not a model copy.
@main enum XperienceNativePersistenceTests {
    enum Failure: Error { case assertion(String) }
    static func check(_ value: Bool, _ message: String) throws { if !value { throw Failure.assertion(message) } }
    static func reject(_ expected: XperiencePersistenceFailure, _ operation: () throws -> Void) throws {
        do { try operation(); throw Failure.assertion("expected controlled rejection") }
        catch let value as XperiencePersistenceFailure { try check(value == expected, "wrong controlled error") }
    }
    final class Owner: VortxMutationAuthority, @unchecked Sendable {
        private let lock = NSRecursiveLock()
        private var active = true
        func revoke() { lock.withLock { active = false } }
        func withActive(_ operation: () throws -> Void) throws {
            try lock.withLock { guard active else { throw VortxNativeError.superseded }; try operation() }
        }
    }
    static func document(padding: Int = 0) throws -> XperienceCollections.Document {
        try XperienceCollections.project(.array([.object([
            "id": .string("collection"), "title": .string("Synthetic collection"), "pinToTop": .bool(true),
            "futureExtension": .object(["padding": .string(String(repeating: "x", count: padding))]),
            "folders": .array([.object(["id": .string("folder"), "title": .string("Synthetic folder"),
                "tileShape": .string("SQUARE"), "sources": .array([.object(["provider": .string("addon"),
                    "addonId": .string("synthetic.addon"), "type": .string("movie"),
                    "catalogId": .string("synthetic/catalog"), "genre": .string("None")])])])])
        ])]))
    }
    static func run() throws {
        // Exact ciphertext length compared against the actual existing sealing implementation.
        for count in [0, 1, 2, 3, 63, 1_500, 65_535] {
            let plaintext = Data(repeating: 0x78, count: count)
            for v2 in [false, true] {
                let sealed = VortXSyncCrypto.sealDocument(dataKey: Data(repeating: 7, count: 32),
                    plaintext: plaintext, accountId: "synthetic-account", version: 1, writeV2: v2)!
                try check(try XperienceExportBudget.sealedByteCount(plaintextCount: count, writeV2: v2) == sealed.utf8.count,
                    "budget does not match actual encrypted transport length")
            }
        }
        let untouched: VortxJSON = .object(["legacySibling": .array([.string("preserve")]),
            "nativeProviderCredentials": .object(["schemaVersion": .integer(1), "futureProvider": .string("retain")]),
            "nativeSync": .object(["prior": .bool(true)]), "nativeHostPreferences": .object(["prior": .bool(true)])])
        let budget = try XperienceExportBudget(completeAccountDocument: untouched,
            maximumSealedBytes: XperienceExportBudget.officialMaximumSealedBytes, writeV2: true)
        let projected = try budget.projected(native: .object(["candidate": .bool(true)]),
            host: .object(["fields": .array([])]), profileEditResults: .object(["conflicts": .array([])]))
        try check(projected["legacySibling"] == untouched["legacySibling"] &&
            projected["nativeProviderCredentials"] == untouched["nativeProviderCredentials"], "complete siblings were stripped")
        let tooSmall = try XperienceExportBudget(completeAccountDocument: untouched, maximumSealedBytes: 1, writeV2: true)
        try reject(.exportTooLarge) { try tooSmall.validate(native: .object([:]), host: .object([:]), profileEditResults: .object([:])) }
        // A small new import is rejected when the OTHER preserved siblings fill the complete export.
        let crowded = try XperienceExportBudget(completeAccountDocument: .object([
            "largeLegacySibling": .string(String(repeating: "x", count: 6 * 1024 * 1024))]),
            maximumSealedBytes: XperienceExportBudget.officialMaximumSealedBytes, writeV2: true)
        try reject(.exportTooLarge) { try crowded.validate(native: .object([:]), host: .object([:]), profileEditResults: .object([:])) }

        // A typed source-bearing account never becomes a generic JSON DTO for sizing.
        // Preserved native/legacy siblings count even though the additional validator
        // receives only the small disposable projection of changed owned fields.
        let rawAccount = Data(#"{"nativeSync":{"schemaVersion":6,"ownerHistory":{"opaque":18446744073709551615,"negativeZero":-0.0},"future":9007199254740993},"legacy":{"keep":-0},"nativeOwnerHistorySources":{"keep":"original"}}"#.utf8)
        let rawBudget = try XperienceExportBudget(completeAccountPlaintext: rawAccount,
            maximumSealedBytes: XperienceExportBudget.officialMaximumSealedBytes, writeV2: true)
        try rawBudget.validate(native: .object(["schemaVersion": .integer(6)]), host: .object([:]), profileEditResults: .object([:]))
        try reject(.exportBaseUnavailable) { _ = try rawBudget.projected(native: .object([:]), host: .object([:]), profileEditResults: .object([:])) }
        try reject(.exportBaseUnavailable) { try rawBudget.validate(native: .object(["ownerHistory": .object([:])]), host: .object([:]), profileEditResults: .object([:])) }
        let rawCrowded = try XperienceExportBudget(completeAccountPlaintext:
            Data((#"{"nativeSync":{"schemaVersion":6,"ownerHistory":{"keep":""# + String(repeating: "x", count: 2048) + #""}},"legacy":18446744073709551615}"#).utf8),
            maximumSealedBytes: 1024, writeV2: true)
        try reject(.exportTooLarge) { try rawCrowded.validate(native: .object(["schemaVersion": .integer(6)]), host: .object([:]), profileEditResults: .object([:])) }

        let raw = try document()
        let source = raw.collections[0].folders[0].sources[0]
        let mapping = XperienceAddonBinding.Mapping(manifestID: "synthetic.addon", transportDigest: String(repeating: "a", count: 64))
        let edit = try XperienceImportNamespace.append(document: raw, label: "Synthetic",
            bindings: [XperienceAddonBinding.key(for: source): mapping])
        try XperienceImportPrivacy.validate(edit)
        let register: VortxJSON = .object(["clock": .integer(1),
            "actor": .string("30000000-0000-0000-0000-000000000071"), "value": edit.value])
        let saved = try XperienceSavedNamespace.read(field: edit.field, register: register)
        try check(saved.bindings[XperienceAddonBinding.key(for: source)] == mapping, "initial append lost exact mapping")
        let replace = try saved.replacement(document: raw, label: "Renamed", bindings: saved.bindings)
        try check(replace.expectedRegister == register && replace.value["collections"] == raw.raw, "replace lost raw/CAS")
        try check(raw.collections[0].pinToTop && source.genre == "None", "pin or literal None was normalized")
        var futureEnvelope = try edit.value.decode([String: VortxJSON].self)
        futureEnvelope["futureSafeField"] = .object(["keep": .bool(true)])
        let futureRegister: VortxJSON = .object(["clock": .integer(2),
            "actor": register["actor"]!, "value": .object(futureEnvelope)])
        let futureSaved = try XperienceSavedNamespace.read(field: edit.field, register: futureRegister)
        let futureReplace = try futureSaved.replacement(document: raw, label: "Still safe", bindings: saved.bindings)
        try check(futureReplace.value["futureSafeField"] == futureEnvelope["futureSafeField"], "unknown envelope field lost")
        futureEnvelope["schemaVersion"] = .integer(2)
        try reject(.unsupportedSavedFormat) {
            _ = try XperienceSavedNamespace.readAll([edit.field: .object(["clock": .integer(3),
                "actor": register["actor"]!, "value": .object(futureEnvelope)])])
        }

        let installed = VortxResourceAddon(id: "opaque-instance", transportUrl: "https://addon.example/manifest.json",
            manifest: .object(["id": .string("synthetic.addon"), "catalogs": .array([
                .object(["type": .string("movie"), "id": .string("search"),
                    "extra": .array([.object(["name": .string("search"), "isRequired": .bool(true)])])]),
                .object(["type": .string("movie"), "id": .string("legacy-search"),
                    "extraRequired": .array([.string("search")])]),
                .object(["type": .string("movie"), "id": .string("synthetic/catalog"),
                    "extraRequired": .array([.string("genre")])])
            ])]))
        let streamOnly = VortxResourceAddon(id: "streams", transportUrl: "https://streams.addon.example/manifest.json",
            manifest: .object(["id": .string("synthetic.streams"), "resources": .array([.string("stream")])]))
        let candidates = try XperienceInstalledCatalogs.candidates([installed, streamOnly])
        try check(candidates.count == 1 && candidates[0].catalogs.count == 1, "unrelated search-only catalog poisoned registry")
        try check(candidates[0].catalogs[0].requiresGenre && candidates[0].catalogs[0].acceptsGenre,
            "legacy required genre was lost")
        guard case .resolved = XperienceAddonBinding.resolve(source, installed: candidates) else {
            throw Failure.assertion("usable catalog did not resolve")
        }

        // Feature policy stays outside the native core and uses only immutable inputs.
        try XperienceNativeHostFieldAdmission.validate(edit, fields: [:])
        try reject(.alreadyImported) {
            try XperienceNativeHostFieldAdmission.validate(edit, fields: [edit.field: register])
        }
        try check(VortxNativeHostFieldEvidence.json(edit.nativeEdit.value, edit.value)
            && edit.nativeEdit.field == edit.field, "feature-to-native conversion changed one-field evidence")

        // Negative control: Swift deliberately treats canonically equivalent strings as equal.
        // Neither exact register evidence nor a secure journal byte witness may do so.
        let nfc = "\u{00e9}", nfd = "e\u{0301}"
        try check(nfc == nfd && Data(nfc.utf8) != Data(nfd.utf8), "Unicode adversarial fixture is not byte-distinct")
        let nfcRegister: VortxJSON = .object(["clock": .integer(9),
            "actor": .string("30000000-0000-0000-0000-000000000071"),
            "value": .object(["label": .string(nfc), "future": .array([.string("keep")])])])
        let nfdRegister: VortxJSON = .object(["clock": .integer(9),
            "actor": .string("30000000-0000-0000-0000-000000000071"),
            "value": .object(["label": .string(nfd), "future": .array([.string("keep")])])])
        try check(nfcRegister == nfdRegister, "structural-equality negative control must expose the old bug")
        let field = "xperience.import.10000000-0000-0000-0000-000000000071", profile = "synthetic-profile"
        let actualNFD: VortxJSON = .object(["profiles": .object([profile: .object(["fields": .object([field: nfdRegister])])])])
        let exactCAS = VortxHostFieldCAS(profileID: profile, field: field, register: nfcRegister)
        try check(!exactCAS.matches(actualNFD), "actual Session CAS accepted NFC/NFD byte-distinct full register")
        try check(!XperienceExactEvidence.registers([field: nfcRegister], [field: nfdRegister]),
            "store observation missed NFC/NFD byte-distinct register")
        try check(!XperienceExactEvidence.json(.object(["scope": .string("synthetic"), "value": .string(nfc)]),
            .object(["scope": .string("synthetic"), "value": .string(nfd)])), "prepared provider proof normalized Unicode")
        try check(!XperienceExactEvidence.json(.number(.nan), .number(.nan)), "two unencodable values compared equal")
        try check(XperienceExactEvidence.json(nil, nil) && !XperienceExactEvidence.json(nil, .null),
            "register absence and tombstone were conflated")
        let originalLifetime = XperienceImportLifetime()
        try check(originalLifetime.isActive, "fresh original lifetime unavailable")
        originalLifetime.revoke()
        try check(!originalLifetime.isActive, "retirement did not synchronously clear lifetime")
        try reject(.staleContext) { try originalLifetime.withActive { throw Failure.assertion("retired lifetime entered sink") } }
        let laterLifetime = XperienceImportLifetime()
        var laterEntries = 0
        try laterLifetime.withActive { laterEntries += 1 }
        try reject(.staleContext) { try originalLifetime.withActive { laterEntries += 1 } }
        try check(laterEntries == 1, "a new gesture revived the original lifetime")

        // This store's own durable publication may beat its Save continuation. Only that ONE
        // pending exact value may advance observation; unrelated or byte-distinct changes retire it.
        let pendingEdit = try XperienceImportNamespace.append(document: raw, label: nfc, bindings: [:])
        let pendingReceipt: VortxJSON = .object(["clock": .integer(10), "actor": register["actor"]!, "value": pendingEdit.value])
        try check(XperienceExactEvidence.acknowledges(pendingEdit, baseline: [:], current: [pendingEdit.field: pendingReceipt]),
            "own durable acknowledgement was not recognized")
        var byteDistinctPendingValue = try pendingEdit.value.decode([String: VortxJSON].self)
        byteDistinctPendingValue["label"] = .string(nfd)
        let wrongReceipt: VortxJSON = .object(["clock": .integer(10), "actor": register["actor"]!, "value": .object(byteDistinctPendingValue)])
        try check(!XperienceExactEvidence.acknowledges(pendingEdit, baseline: [:], current: [pendingEdit.field: wrongReceipt]),
            "Unicode-canonical equivalent foreign publication was accepted as own acknowledgement")
        let peerField = "xperience.import.10000000-0000-0000-0000-000000000074"
        try check(!XperienceExactEvidence.acknowledges(pendingEdit,
            baseline: [peerField: nfcRegister], current: [peerField: nfdRegister, pendingEdit.field: pendingReceipt]),
            "unrelated byte-distinct register change was hidden by own acknowledgement")
        try check(!XperienceExactEvidence.acknowledges(pendingEdit, baseline: [pendingEdit.field: pendingReceipt],
            current: [pendingEdit.field: pendingReceipt]), "own acknowledgement bypassed the original field baseline")

        // The production observation witness retires same-profile later complete bases.
        let observation = XperienceExportObservationFence()
        let generation = observation.capture()
        var observations = 0
        try observation.withCurrent(generation) { observations += 1 }
        observation.observe()
        try reject(.exportBaseUnavailable) { try observation.withCurrent(generation) { observations += 1 } }
        try check(observations == 1, "later complete backup did not retire old witness")
        // Exact provider-byte CAS via an injected reader; no Keychain/account operation in this test.
        final class ProviderBytes: @unchecked Sendable {
            private let lock = NSLock()
            private var value = "synthetic-provider-one"
            func read() -> CredentialDurableReadResult { lock.withLock { .value(value) } }
            func change() { VortxNativeProviderCredentials.withStoreLock { lock.withLock { value = "synthetic-provider-two" } } }
        }
        let provider = ProviderBytes(), currentObservation = observation.capture()
        let witness = XperienceExportWitnessAuthority(observation: observation, generation: currentObservation,
            providerSlot: "synthetic-only", providerBytes: "synthetic-provider-one", providerRead: { _ in provider.read() })
        var witnessCommits = 0
        try witness.withActive { witnessCommits += 1 }
        provider.change()
        try reject(.exportBaseUnavailable) { try witness.withActive { witnessCommits += 1 } }
        try check(witnessCommits == 1, "new secure provider bytes did not retire witness")

        final class UnicodeProviderBytes: @unchecked Sendable {
            private let lock = NSLock()
            private var bytes: String
            init(_ bytes: String) { self.bytes = bytes }
            func read() -> CredentialDurableReadResult { lock.withLock { .value(bytes) } }
            func replace(_ next: String) {
                VortxNativeProviderCredentials.withStoreLock { lock.withLock { bytes = next } }
            }
        }
        let nfcJournal = "{\"value\":\"" + nfc + "\"}", nfdJournal = "{\"value\":\"" + nfd + "\"}"
        try check(nfcJournal == nfdJournal && Data(nfcJournal.utf8) != Data(nfdJournal.utf8),
            "secure journal fixture did not expose String canonical equivalence")
        let unicodeProvider = UnicodeProviderBytes(nfcJournal)
        let unicodeWitness = XperienceExportWitnessAuthority(observation: observation, generation: observation.capture(),
            providerSlot: "synthetic-unicode-only", providerBytes: nfcJournal, providerRead: { _ in unicodeProvider.read() })
        var unicodeCommits = 0
        try unicodeWitness.withActive { unicodeCommits += 1 }
        unicodeProvider.replace(nfdJournal)
        try reject(.exportBaseUnavailable) { try unicodeWitness.withActive { unicodeCommits += 1 } }
        try check(unicodeCommits == 1, "byte-distinct canonically equivalent secure journal passed its witness")

        let owner = Owner(), cancelled = VortxNativeHostFieldCommitLatch(source: Owner())
        cancelled.cancel()
        do { try cancelled.withActive { throw Failure.assertion("cancelled latch entered sink") }; throw Failure.assertion("cancelled latch accepted") }
        catch VortxNativeHostFieldMutationError.cancelled {}
        let latch = VortxNativeHostFieldCommitLatch(source: owner)
        var committed = 0
        try latch.withActive { committed += 1 }
        owner.revoke()
        do { try latch.withActive { committed += 1 }; throw Failure.assertion("revoked owner entered sink") }
        catch VortxNativeError.superseded {}
        try check(committed == 1, "owner invalidation checkpoint count")
        print("PASS actual Xperience budget, namespace, candidates and authority components")
    }
    static func main() {
        do { try run() } catch { print("FAIL Xperience native persistence components"); exit(1) }
    }
}
