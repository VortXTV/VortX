import Foundation

/// Exact evidence uses canonical JSON bytes, not Swift's Unicode-canonical String/Dictionary
/// equality. Invalid encodings never compare equal, including when BOTH encodings fail.
enum XperienceExactEvidence {
    static func json(_ left: VortxJSON?, _ right: VortxJSON?) -> Bool {
        VortxNativeHostFieldEvidence.json(left, right)
    }
    static func registers(_ left: [String: VortxJSON]?, _ right: [String: VortxJSON]?) -> Bool {
        VortxNativeHostFieldEvidence.registers(left, right)
    }
    /// A facade publication can precede the saving continuation. Recognize ONLY the immutable
    /// pending edit's durable value, with the original field CAS and every other register intact.
    /// This advances observation; it does not synthesize a Save receipt or recapture authority.
    static func acknowledges(_ edit: XperienceImportNamespace.Edit, baseline: [String: VortxJSON],
                             current: [String: VortxJSON]) -> Bool {
        guard json(baseline[edit.field], edit.expectedRegister),
              json(current[edit.field]?["value"], edit.value) else { return false }
        return registers(baseline.filter { $0.key != edit.field }, current.filter { $0.key != edit.field })
    }
    static func registers(_ left: [String: VortxRawHostRegister]?, _ right: [String: VortxRawHostRegister]?) -> Bool {
        switch (left, right) {
        case (nil, nil): return true
        case let (a?, b?):
            return Set(a.keys) == Set(b.keys) && a.allSatisfy { VortxRawHostRegister.same($0.value, b[$0.key]) }
        default: return false
        }
    }
    static func acknowledges(_ edit: XperienceImportNamespace.RawEdit, baseline: [String: VortxRawHostRegister],
                             current: [String: VortxRawHostRegister]) -> Bool {
        let raw = edit.raw
        guard raw.baselineMatches(baseline[edit.field]),
              let accepted = current[edit.field], accepted.canonicalValue == raw.canonicalValue,
              accepted.metadata == (raw.expectedRegister?.metadata ?? Data("{}".utf8)) else { return false }
        return registers(baseline.filter { $0.key != edit.field }, current.filter { $0.key != edit.field })
    }

}

/// One original gesture's lifetime. Revocation holds ONLY this lock and never calls Bridge,
/// facade, observers, publishers or an await. Final commit holds this lock after Bridge admission.
/// If commit enters first, retirement waits and linearizes after that transaction; retirement
/// that completes first prevents checkpoint entry. A later capture creates a DIFFERENT lifetime.
final class XperienceImportLifetime: VortxMutationAuthority, @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.withLock { active } }
    func revoke() { lock.withLock { active = false } }
    func withActive(_ operation: () throws -> Void) throws {
        try lock.withLock {
            guard active else { throw XperiencePersistenceFailure.staleContext }
            try operation()
        }
    }
}

/// Uses exactly the current JSONSerialization document serializer and AES-GCM combined/base64 shape.
/// No key is needed for an exact ciphertext LENGTH: 12 nonce + plaintext + 16 tag, then base64, plus v2.
struct XperienceExportBudget: VortxProspectiveCheckpointValidator, Sendable {
    // Official backup-storage.js MAX_DOCUMENT_BYTES; the official deployment's chunk-write
    // capability is a release authority prerequisite. This is NOT a generic custom-server claim.
    static let officialMaximumSealedBytes = 7 * 1024 * 1024
    private let base: VortxJSON?
    private let rawBase: Data?
    private let maximumSealedBytes: Int
    private let writeV2: Bool

    init(completeAccountDocument: VortxJSON, maximumSealedBytes: Int, writeV2: Bool) throws {
        guard case .object = completeAccountDocument, maximumSealedBytes > 0 else {
            throw XperiencePersistenceFailure.exportBaseUnavailable
        }
        base = completeAccountDocument
        rawBase = nil
        self.maximumSealedBytes = maximumSealedBytes
        self.writeV2 = writeV2
    }

    /// The typed owner-history route retains the authenticated account as exact JSON
    /// slices. This sizing witness is additional to Session's full raw candidate budget;
    /// it cannot turn disposable presentation values back into a source checkpoint.
    init(completeAccountPlaintext: Data, maximumSealedBytes: Int, writeV2: Bool) throws {
        guard maximumSealedBytes > 0 else { throw XperiencePersistenceFailure.exportBaseUnavailable }
        _ = try OwnerHistoryExactJSON.Object(completeAccountPlaintext)
        base = nil; rawBase = completeAccountPlaintext
        self.maximumSealedBytes = maximumSealedBytes; self.writeV2 = writeV2
    }

    func projected(native: VortxJSON, host: VortxJSON, profileEditResults: VortxJSON) throws -> VortxJSON {
        guard case .object(var complete)? = base else { throw XperiencePersistenceFailure.exportBaseUnavailable }
        // Preserve ALL other top-level siblings, including provider credentials and legacy carriers.
        complete["nativeSync"] = native
        complete["nativeHostPreferences"] = host
        complete["profileEditResults"] = profileEditResults
        return .object(complete)
    }
    func validate(native: VortxJSON, host: VortxJSON, profileEditResults: VortxJSON) throws {
        let plaintext: Data
        if let rawBase {
            // Only the owned disposable projection supplied by typed Session is overlaid.
            // Its excluded history and every unknown native/account slice stay untouched.
            var complete = try OwnerHistoryExactJSON.Object(rawBase)
            var nativeBase = try OwnerHistoryExactJSON.Object(complete.required("nativeSync"))
            let projection = try OwnerHistoryExactJSON.Object(JSONEncoder().encode(native))
            let owned: Set<String> = ["schemaVersion", "scope", "ownerProfileId", "profiles", "addons",
                "libraries", "watches", "legacyImport", "accountSlots", "websiteAddonReceipts", "legacyProfileEditReceipts"]
            guard Set(projection.fields.keys).isSubset(of: owned) else {
                throw XperiencePersistenceFailure.exportBaseUnavailable
            }
            for (key, value) in projection.fields { nativeBase.set(key, value) }
            complete.set("nativeSync", try nativeBase.encoded())
            complete.set("nativeHostPreferences", try JSONEncoder().encode(host))
            complete.set("profileEditResults", try JSONEncoder().encode(profileEditResults))
            plaintext = try complete.encoded()
        } else {
            let full = try projected(native: native, host: host, profileEditResults: profileEditResults)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(full))
            plaintext = try JSONSerialization.data(withJSONObject: object)
        }
        guard try Self.sealedByteCount(plaintextCount: plaintext.count, writeV2: writeV2) <= maximumSealedBytes else {
            throw XperiencePersistenceFailure.exportTooLarge
        }
    }
    /// Size the exact prospective raw host carrier against the original complete account.
    /// A typed base remains the existing compatibility contract; only rawBase is original
    /// raw account authority. Neither path turns the host presentation DTO into saved data.
    func validateRawHost(native: VortxJSON, host: Data, profileEditResults: VortxJSON) throws {
        var complete: OwnerHistoryExactJSON.Object
        if let rawBase { complete = try OwnerHistoryExactJSON.Object(rawBase) }
        else if let base { complete = try OwnerHistoryExactJSON.Object(JSONEncoder().encode(base)) }
        else { throw XperiencePersistenceFailure.exportBaseUnavailable }
        if rawBase != nil {
            var nativeBase = try OwnerHistoryExactJSON.Object(complete.required("nativeSync"))
            let projection = try OwnerHistoryExactJSON.Object(JSONEncoder().encode(native))
            let owned: Set<String> = ["schemaVersion", "scope", "ownerProfileId", "profiles", "addons",
                "libraries", "watches", "legacyImport", "accountSlots", "websiteAddonReceipts", "legacyProfileEditReceipts"]
            guard Set(projection.fields.keys).isSubset(of: owned) else { throw XperiencePersistenceFailure.exportBaseUnavailable }
            for (key, value) in projection.fields { nativeBase.set(key, value) }
            complete.set("nativeSync", try nativeBase.encoded())
        } else { complete.set("nativeSync", try JSONEncoder().encode(native)) }
        _ = try OwnerHistoryExactJSON.Object(host)
        complete.set("nativeHostPreferences", host)
        complete.set("profileEditResults", try JSONEncoder().encode(profileEditResults))
        let plaintext = try complete.encoded()
        guard try Self.sealedByteCount(plaintextCount: plaintext.count, writeV2: writeV2) <= maximumSealedBytes else {
            throw XperiencePersistenceFailure.exportTooLarge
        }
    }
    // A constant synthetic budget has no live authority. The production Bridge accepts only
    // XperiencePreparedExport, whose witness remains locked through the durable checkpoint.
    func withActive(_ operation: () throws -> Void) throws { try operation() }
    static func sealedByteCount(plaintextCount: Int, writeV2: Bool) throws -> Int {
        guard plaintextCount >= 0, plaintextCount <= Int.max - 30 else { throw XperiencePersistenceFailure.exportTooLarge }
        let combined = plaintextCount + 28
        guard (combined + 2) / 3 <= (Int.max - 3) / 4 else { throw XperiencePersistenceFailure.exportTooLarge }
        return 4 * ((combined + 2) / 3) + (writeV2 ? VortXSyncCrypto.docV2Prefix.utf8.count : 0)
    }
}

struct XperienceSavedNamespace: Equatable, Sendable, Identifiable {
    let namespace: UUID
    let field: String
    let label: String
    let document: XperienceCollections.Document
    let bindings: [String: XperienceAddonBinding.Mapping]
    fileprivate let register: VortxJSON
    fileprivate var rawRegister: VortxRawHostRegister? = nil
    var id: String { field }

    static func read(field: String, register: VortxJSON) throws -> Self {
        let prefix = "xperience.import."
        guard field.hasPrefix(prefix), let id = UUID(uuidString: String(field.dropFirst(prefix.count))),
              XperienceImportNamespace.field(id) == field,
              case .object(let envelope) = register["value"] else { throw XperiencePersistenceFailure.invalidSavedImport }
        guard envelope["schemaVersion"] == .integer(1) else { throw XperiencePersistenceFailure.unsupportedSavedFormat }
        guard envelope["importID"] == .string(id.uuidString.lowercased()),
              case .string(let label) = envelope["label"], !label.isEmpty, label.utf8.count <= 256,
              let raw = envelope["collections"],
              case .object(let rawBindings) = envelope["bindings"] else { throw XperiencePersistenceFailure.invalidSavedImport }
        let document = try XperienceCollections.project(raw)
        guard envelope["fingerprint"] == .string(document.fingerprint) else { throw XperiencePersistenceFailure.invalidSavedImport }
        let sourceKeys = Set(document.collections.flatMap(\.folders).flatMap(\.sources).filter(\.isAddon).map(XperienceAddonBinding.key))
        var bindings: [String: XperienceAddonBinding.Mapping] = [:]
        for (key, rawMapping) in rawBindings {
            guard sourceKeys.contains(key), case .object(let fields) = rawMapping,
                  Set(fields.keys) == ["manifestID", "transport"],
                  case .string(let manifest) = fields["manifestID"], !manifest.isEmpty,
                  case .object(let transport) = fields["transport"], Set(transport.keys) == ["fingerprint"],
                  case .string(let fingerprint) = transport["fingerprint"],
                  fingerprint.count == 64, fingerprint.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                // Never rewrite a mapping whose unknown extension we do not understand.
                throw XperiencePersistenceFailure.unsupportedSavedFormat
            }
            bindings[key] = .init(manifestID: manifest, transportDigest: fingerprint)
        }
        return .init(namespace: id, field: field, label: label, document: document, bindings: bindings, register: register)
    }

    /// Disposable DTO projection after retaining full original raw observation. Collections
    /// are independently admitted from their exact source bytes under the existing lossless
    /// parser; unknown envelope/register siblings never enter an encoded presentation path.
    static func read(field: String, register: VortxRawHostRegister) throws -> Self {
        guard register.canonical != nil else { throw XperienceCollections.Failure.tooLarge }
        let object = try OwnerHistoryExactJSON.Object(register.bytes)
        let clock = try JSONDecoder().decode(UInt64.self, from: object.required("clock"))
        guard clock <= VortxRawHostRegister.maximumClock,
              UUID(uuidString: try object.text("actor"))?.uuidString.lowercased() == (try object.text("actor")) else {
            throw XperiencePersistenceFailure.invalidSavedImport
        }
        let value = try OwnerHistoryExactJSON.Object(register.value)
        guard try JSONDecoder().decode(Int.self, from: value.required("schemaVersion")) == 1 else {
            throw XperiencePersistenceFailure.unsupportedSavedFormat
        }
        let document = try XperienceCollections.parse(value.required("collections"))
        var saved = try read(field: field, register: JSONDecoder().decode(VortxJSON.self, from: register.bytes))
        guard saved.document.fingerprint == document.fingerprint else { throw XperiencePersistenceFailure.invalidSavedImport }
        saved.rawRegister = register; return saved
    }
    static func readAll(_ registers: [String: VortxRawHostRegister]) throws -> [Self] {
        try registers.keys.sorted().compactMap { field in
            guard let register = registers[field] else { return nil }
            // Absence and a complete tombstone remain different original observations.
            if register.value == Data("null".utf8) { return nil }
            return try read(field: field, register: register)
        }
    }

    static func readAll(_ registers: [String: VortxJSON]) throws -> [Self] {
        // Namespace order is deterministic and unaffected by a replacement register clock.
        // Collection/folder/source order and pinToTop remain exactly the JSON array order.
        try registers.keys.sorted().compactMap { field in
            guard let register = registers[field], register["value"] != .null else { return nil }
            return try read(field: field, register: register)
        }
    }

    func replacement(document: XperienceCollections.Document, label: String,
                     bindings: [String: XperienceAddonBinding.Mapping]) throws -> XperienceImportNamespace.Edit {
        try XperienceImportNamespace.replace(document: document, label: label, namespace: namespace,
            expectedRegister: register, bindings: bindings)
    }
    func rawReplacement(document: XperienceCollections.Document, label: String,
                        bindings: [String: XperienceAddonBinding.Mapping]) throws -> XperienceImportNamespace.RawEdit {
        guard let rawRegister else { throw XperiencePersistenceFailure.invalidSavedImport }
        return try XperienceImportNamespace.replaceRaw(document: document, label: label, namespace: namespace,
            expectedRegister: rawRegister, bindings: bindings)
    }

}

/// Only installed manifest descriptors become candidates. Collection JSON cannot nominate a host.
enum XperienceInstalledCatalogs {
    /// A captured projection, not an endpoint/owner capability. Rejections stay private to
    /// THIS registry observation; no URL/config/error string is exposed or persisted.
    struct Snapshot: Sendable {
        let candidates: [XperienceAddonBinding.Candidate]
        private let originalOrdinals: [Int]
        private let rejectedIDs: Set<Data>
        private let rejectedConfiguredIdentities: [Data: Set<String>]
        // Typed compatibility for exhaustive, already-admitted candidate inputs (including
        // existing pure mapper fixtures). Real installed capture always calls project below.
        init(admittedCandidates: [XperienceAddonBinding.Candidate]) {
            candidates = admittedCandidates; originalOrdinals = Array(admittedCandidates.indices)
            rejectedIDs = []; rejectedConfiguredIdentities = [:]
        }
        fileprivate init(candidates: [XperienceAddonBinding.Candidate], originalOrdinals: [Int], rejectedIDs: Set<Data>,
                         rejectedConfiguredIdentities: [Data: Set<String>]) {
            precondition(candidates.count == originalOrdinals.count)
            self.candidates = candidates; self.originalOrdinals = originalOrdinals; self.rejectedIDs = rejectedIDs
            self.rejectedConfiguredIdentities = rejectedConfiguredIdentities
        }
        static let empty = Snapshot(admittedCandidates: [])
        func displayOrdinal(at admittedIndex: Int) -> Int { originalOrdinals[admittedIndex] + 1 }
        func hasRejectedDescriptor(for source: XperienceCollections.Source) -> Bool {
            guard source.isAddon, let id = source.addonID else { return false }
            return rejectedIDs.contains(Data(id.utf8))
        }
        func resolve(_ source: XperienceCollections.Source,
                     mapping: XperienceAddonBinding.Mapping? = nil) -> XperienceAddonBinding.Resolution {
            let result = XperienceAddonBinding.resolve(source, installed: candidates, mapping: mapping)
            if mapping == nil, hasRejectedDescriptor(for: source) { return .invalidRegistry }
            if case .resolved(let candidate) = result,
               rejectedConfiguredIdentities[Data(candidate.manifestID.utf8)]?.contains(candidate.transportDigest) == true {
                // A mapping cannot distinguish an invalid configuration with the SAME admitted
                // identity. Never use it as permission to pick a surviving same-name instance.
                return .invalidRegistry
            }
            return result
        }
        func mappingMatches(_ mapping: XperienceAddonBinding.Mapping?, candidate: XperienceAddonBinding.Candidate) -> Bool {
            guard let mapping else { return false }
            return Data(mapping.manifestID.utf8) == Data(candidate.manifestID.utf8)
                && mapping.transportDigest == candidate.transportDigest
        }
    }
    private struct IdentityBudget {
        // Reuse the existing native/source JSON bound, not a new small manifest-ID quota.
        // Rejected observations retain at most the identity bytes admitted by this capture.
        var remaining = OwnerHistoryExactJSON.maximumBytes
        mutating func admit(_ identity: String) throws {
            let count = identity.utf8.count
            guard count < remaining else { throw XperiencePersistenceFailure.invalidRegistry }
            remaining -= count + 1
        }
    }
    static func project(_ registry: [VortxResourceAddon]) throws -> Snapshot {
        var output: [XperienceAddonBinding.Candidate] = []
        var originalOrdinals: [Int] = []
        var rejectedIDs = Set<Data>(), rejectedConfiguredIdentities: [Data: Set<String>] = [:]
        var budget = IdentityBudget()
        for (originalIndex, addon) in registry.enumerated() {
            try Task.checkCancellation()
            // An absent/invalid/unbounded identity cannot be attributed and rejects the
            // whole capture. Swift String equality is NEVER an identity key here.
            guard let manifest = addon.manifest, case .object = manifest,
                  case .string(let id) = manifest["id"],
                  id.unicodeScalars.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
                throw XperiencePersistenceFailure.invalidRegistry
            }
            try budget.admit(id)
            // A known catalog-omitted manifest advertises no endpoint. Preserve that old
            // behavior; it must not taint a valid same-ID catalog sibling as malformed.
            guard manifest["catalogs"] != nil else { continue }
            var admittedTransport: XperienceAddonBinding.Candidate?
            do {
                admittedTransport = try .init(manifestID: id, transport: addon.transportUrl, catalogs: [])
                let catalogs = try projectedCatalogs(manifest)
                output.append(try .init(manifestID: id, transport: addon.transportUrl, catalogs: catalogs))
                originalOrdinals.append(originalIndex)
            } catch XperiencePersistenceFailure.invalidRegistry {
                rejectedIDs.insert(Data(id.utf8))
                if let digest = admittedTransport?.transportDigest {
                    rejectedConfiguredIdentities[Data(id.utf8), default: []].insert(digest)
                }
            } catch XperienceAddonBinding.Failure.invalidRegistry {
                rejectedIDs.insert(Data(id.utf8))
                if let digest = admittedTransport?.transportDigest {
                    rejectedConfiguredIdentities[Data(id.utf8), default: []].insert(digest)
                }
            }
            // Other failures, including cancellation, are not descriptor faults.
        }
        return .init(candidates: output, originalOrdinals: originalOrdinals, rejectedIDs: rejectedIDs,
            rejectedConfiguredIdentities: rejectedConfiguredIdentities)
    }
    private static func projectedCatalogs(_ manifest: VortxJSON) throws -> [XperienceAddonBinding.Catalog] {
        guard let catalogs = manifest["catalogs"]?.array else { throw XperiencePersistenceFailure.invalidRegistry }
        return try catalogs.compactMap { catalog -> XperienceAddonBinding.Catalog? in
            try Task.checkCancellation()
            guard case .object = catalog, case .string(let type) = catalog["type"], case .string(let id) = catalog["id"],
                  !type.isEmpty, !id.isEmpty else { throw XperiencePersistenceFailure.invalidRegistry }
            let extras: [VortxJSON]
            if let value = catalog["extra"] {
                guard let array = value.array else { throw XperiencePersistenceFailure.invalidRegistry }; extras = array
            } else { extras = [] }
            var supported = Set<String>(), required = Set<String>()
            for extra in extras {
                guard case .object = extra, case .string(let name) = extra["name"], !name.isEmpty else {
                    throw XperiencePersistenceFailure.invalidRegistry
                }
                supported.insert(name)
                if let value = extra["isRequired"] {
                    guard case .bool(let needed) = value else { throw XperiencePersistenceFailure.invalidRegistry }
                    if needed { required.insert(name) }
                }
            }
            for (key, isRequired) in [("extraSupported", false), ("extraRequired", true)] {
                if let value = catalog[key] {
                    guard let array = value.array else { throw XperiencePersistenceFailure.invalidRegistry }
                    for entry in array {
                        guard case .string(let name) = entry, !name.isEmpty else { throw XperiencePersistenceFailure.invalidRegistry }
                        if isRequired { required.insert(name) } else { supported.insert(name) }
                    }
                }
            }
            guard required.subtracting(["genre"]).isEmpty else { return nil }
            return .init(type: type, id: id, acceptsGenre: supported.contains("genre") || required.contains("genre"),
                requiresGenre: required.contains("genre"), supportsSkip: supported.contains("skip"))
        }
    }
}

/// Keeps secure provider bytes private and in memory. Exact bytes are compared, not a public
/// hash/revision, under the SAME existing provider store lock that guards every native write.
final class XperienceExportWitnessAuthority: VortxMutationAuthority, @unchecked Sendable {
    private let observation: XperienceExportObservationFence
    private let generation: UUID
    private let providerSlot: String
    private let providerBytes: Data
    private let providerRead: @Sendable (String) -> CredentialDurableReadResult
    init(observation: XperienceExportObservationFence, generation: UUID, providerSlot: String, providerBytes: String,
         providerRead: @escaping @Sendable (String) -> CredentialDurableReadResult = { Keychain.confirmedString($0) }) {
        self.observation = observation; self.generation = generation
        self.providerSlot = providerSlot; self.providerBytes = Data(providerBytes.utf8); self.providerRead = providerRead
    }
    func withActive(_ operation: () throws -> Void) throws {
        try observation.withCurrent(generation) {
            try VortxNativeProviderCredentials.withStoreLock {
                guard case .value(let current) = providerRead(providerSlot), Data(current.utf8) == providerBytes else {
                    throw XperiencePersistenceFailure.exportBaseUnavailable
                }
                try operation()
            }
        }
    }
}

/// Only this prepared form crosses the CoreBridge production save adapter. The pure budget
/// remains separately testable; live saving additionally requires the full base/provider witness.
struct XperiencePreparedExport: VortxProspectiveCheckpointValidator, Sendable {
    let budget: XperienceExportBudget
    let authority: any VortxMutationAuthority
    func validate(native: VortxJSON, host: VortxJSON, profileEditResults: VortxJSON) throws {
        try budget.validate(native: native, host: host, profileEditResults: profileEditResults)
    }
    func validateRawHost(native: VortxJSON, host: Data, profileEditResults: VortxJSON) throws {
        try budget.validateRawHost(native: native, host: host, profileEditResults: profileEditResults)
    }
    func withActive(_ operation: () throws -> Void) throws { try authority.withActive(operation) }
}

/// Feature-to-core conversion keeps the generic Session/Facade contracts free of parser types.
extension XperienceImportNamespace.Edit {
    var nativeEdit: VortxNativeHostFieldEdit {
        .init(field: field, expectedRegister: expectedRegister, value: value)
    }
}

/// Pure Sendable admission: captured immutable edit + supplied fields only. No MainActor access,
/// Bridge/facade lookup, lock acquisition, transport, credential read or other side effect.
enum XperienceNativeHostFieldAdmission {
    static func validate(_ edit: XperienceImportNamespace.Edit, fields: [String: VortxJSON]) throws {
        guard edit.expectedRegister == nil, let fingerprint = edit.value["fingerprint"] else { return }
        if fields.contains(where: { $0.key.hasPrefix("xperience.import.")
            && VortxNativeHostFieldEvidence.json($0.value["value"]?["fingerprint"], fingerprint) }) {
            throw XperiencePersistenceFailure.alreadyImported
        }
    }
}

// Production raw namespace adapter. The existing pure typed Namespace/Candidate module is
// unchanged; a typed caller is never upgraded into original raw observation authority.
extension XperienceImportNamespace {
    struct RawEdit: Equatable, Sendable {
        let presentation: Edit
        let raw: VortxRawHostFieldEdit
        var namespace: UUID { presentation.namespace }
        var field: String { presentation.field }
        var expectedRegister: VortxJSON? { presentation.expectedRegister }
        var value: VortxJSON { presentation.value }
        var nativeEdit: VortxNativeHostFieldEdit {
            .init(field: field, expectedRegister: expectedRegister, value: value, raw: raw)
        }
    }
    static func appendRaw(document: XperienceCollections.Document, label: String, namespace: UUID = UUID(),
                          bindings: [String: XperienceAddonBinding.Mapping] = [:]) throws -> RawEdit {
        let owned = try append(document: document, label: label, namespace: namespace, bindings: bindings)
        let bytes = try XperienceCollections.canonicalData(owned.value)
        guard let canonical = try VortxRawHostRegister.boundedCanonical(bytes) else { throw XperienceCollections.Failure.tooLarge }
        return .init(presentation: owned, raw: .init(expectedRegister: nil, value: bytes, canonicalValue: canonical))
    }
    static func replaceRaw(document: XperienceCollections.Document, label: String, namespace: UUID,
                           expectedRegister: VortxRawHostRegister,
                           bindings: [String: XperienceAddonBinding.Mapping]) throws -> RawEdit {
        guard expectedRegister.canonical != nil else { throw XperienceCollections.Failure.tooLarge }
        let register = try OwnerHistoryExactJSON.Object(expectedRegister.bytes)
        let clock = try JSONDecoder().decode(UInt64.self, from: register.required("clock"))
        let actor = try register.text("actor")
        var value = try OwnerHistoryExactJSON.Object(register.required("value"))
        guard clock <= VortxRawHostRegister.maximumClock, UUID(uuidString: actor)?.uuidString.lowercased() == actor,
              try JSONDecoder().decode(Int.self, from: value.required("schemaVersion")) == 1,
              try value.text("importID") == namespace.uuidString.lowercased() else { throw XperienceCollections.Failure.invalidNamespace }
        // Reuse the real owned-field admission. Only those six members are replaced; no
        // future register/envelope member is decoded and then used as saved source data.
        let owned = try append(document: document, label: label, namespace: namespace, bindings: bindings)
        let replacement = try OwnerHistoryExactJSON.Object(XperienceCollections.canonicalData(owned.value))
        for key in ["schemaVersion", "importID", "label", "fingerprint", "collections", "bindings"] {
            value.set(key, try replacement.required(key))
        }
        let bytes = try value.encoded()
        guard bytes.count <= XperienceCollections.maximumBytes,
              let canonical = try VortxRawHostRegister.boundedCanonical(bytes) else { throw XperienceCollections.Failure.tooLarge }
        let presentation = Edit(namespace: namespace, field: field(namespace),
            expectedRegister: try JSONDecoder().decode(VortxJSON.self, from: expectedRegister.bytes),
            value: try JSONDecoder().decode(VortxJSON.self, from: bytes))
        return .init(presentation: presentation,
            raw: .init(expectedRegister: expectedRegister, value: bytes, canonicalValue: canonical))
    }
}
extension XperienceNativeHostFieldAdmission {
    static func validate(_ edit: XperienceImportNamespace.RawEdit, fields: [String: VortxJSON]) throws {
        try validate(edit.presentation, fields: fields)
    }
}
