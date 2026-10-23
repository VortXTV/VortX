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
}

/// Only installed manifest descriptors become candidates. Collection JSON cannot nominate a host.
enum XperienceInstalledCatalogs {
    static func candidates(_ registry: [VortxResourceAddon]) throws -> [XperienceAddonBinding.Candidate] {
        var output: [XperienceAddonBinding.Candidate] = []
        for addon in registry {
            guard let manifest = addon.manifest, case .string(let id) = manifest["id"], !id.isEmpty else {
                throw XperiencePersistenceFailure.invalidRegistry
            }
            // Stremio stream/subtitle-only manifests may omit catalogs. They nominate no collection
            // endpoint. A PRESENT malformed catalogs value is still a registry error.
            guard let rawCatalogs = manifest["catalogs"] else { continue }
            guard let catalogs = rawCatalogs.array else { throw XperiencePersistenceFailure.invalidRegistry }
            let projected = try catalogs.compactMap { catalog -> XperienceAddonBinding.Catalog? in
                guard case .string(let type) = catalog["type"], case .string(let id) = catalog["id"],
                      !type.isEmpty, !id.isEmpty else { throw XperiencePersistenceFailure.invalidRegistry }
                let extras = catalog["extra"]?.array ?? []
                let supported = Set(extras.compactMap { $0["name"].flatMap { try? $0.decode(String.self) } }
                    + (catalog["extraSupported"]?.array ?? []).compactMap { try? $0.decode(String.self) })
                let legacyRequired: [String]
                if let value = catalog["extraRequired"] {
                    guard let array = value.array else { throw XperiencePersistenceFailure.invalidRegistry }
                    legacyRequired = try array.map {
                        guard case .string(let name) = $0, !name.isEmpty else { throw XperiencePersistenceFailure.invalidRegistry }
                        return name
                    }
                } else { legacyRequired = [] }
                let required = Set(extras.filter { $0["isRequired"] == .bool(true) }
                    .compactMap { $0["name"].flatMap { try? $0.decode(String.self) } } + legacyRequired)
                // Search-only and other unsupported-extra catalogs are not collection endpoints.
                // Exclude only this endpoint: a referenced source resolves as missing/unavailable,
                // while its raw JSON stays saved and unrelated usable catalogs remain importable.
                guard required.subtracting(["genre"]).isEmpty else { return nil }
                return .init(type: type, id: id, acceptsGenre: supported.contains("genre") || required.contains("genre"),
                    requiresGenre: required.contains("genre"), supportsSkip: supported.contains("skip"))
            }
            output.append(try .init(manifestID: id, transport: addon.transportUrl, catalogs: projected))
        }
        return output
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
