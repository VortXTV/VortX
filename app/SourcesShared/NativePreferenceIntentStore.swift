import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

/// Encrypted, bounded local journal for native preference edits awaiting authenticated sync.
/// Callers serialize read-modify-write operations on their owning actor (currently MainActor).
struct NativePreferenceIntentStore {
    enum Group: String, Codable, CaseIterable, Sendable { case playback, discovery, theme }
    struct Authority: Codable, Equatable, Sendable {
        let account: String
        let ownerProfileID: String
        let profileID: String
        let profileBinding: VortxJSON
    }
    struct Snapshot: Codable, Equatable, Sendable {
        let value: VortxJSON
        let revision: VortxJSON
    }
    struct QuarantinedProjection: Codable, Equatable, Sendable {
        let key: String
        let stamp: Double
        let value: VortxJSON
    }
    struct SupersededReceipt: Codable, Equatable, Sendable {
        let id: UUID
        let digest: Data
    }
    struct Intent: Codable, Equatable, Sendable {
        let id: UUID
        let authority: Authority
        let group: Group
        let base: Snapshot
        let desired: VortxJSON
        let supersededIDs: [UUID]
        let supersededReceipts: [SupersededReceipt]
        let projectionStamps: [String: Double]
        let requiresResolution: Bool
        var acceptedBases: [Snapshot]

        private enum CodingKeys: String, CodingKey {
            case id, authority, group, base, desired, supersededIDs, supersededReceipts, projectionStamps, requiresResolution, acceptedBases
        }
        init(id: UUID, authority: Authority, group: Group, base: Snapshot, desired: VortxJSON,
             supersededIDs: [UUID], supersededReceipts: [SupersededReceipt], acceptedBases: [Snapshot],
             projectionStamps: [String: Double] = [:], requiresResolution: Bool = false) {
            self.id = id; self.authority = authority; self.group = group; self.base = base; self.desired = desired
            self.supersededIDs = supersededIDs; self.supersededReceipts = supersededReceipts
            self.projectionStamps = projectionStamps; self.requiresResolution = requiresResolution; self.acceptedBases = acceptedBases
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            authority = try container.decode(Authority.self, forKey: .authority)
            group = try container.decode(Group.self, forKey: .group)
            base = try container.decode(Snapshot.self, forKey: .base)
            desired = try container.decode(VortxJSON.self, forKey: .desired)
            supersededIDs = try container.decode([UUID].self, forKey: .supersededIDs)
            supersededReceipts = try container.decode([SupersededReceipt].self, forKey: .supersededReceipts)
            projectionStamps = try container.decodeIfPresent([String: Double].self, forKey: .projectionStamps) ?? [:]
            requiresResolution = try container.decodeIfPresent(Bool.self, forKey: .requiresResolution) ?? false
            acceptedBases = try container.decode([Snapshot].self, forKey: .acceptedBases)
        }
    }
    enum Decision: Equatable, Sendable { case apply, alreadyApplied, conflict }
    enum StoreError: Error, Sendable { case invalid, unreadable, tooLarge, conflict, persistence }

    static let schemaVersion = 1
    static let maximumFileBytes = 512 * 1_024
    static let maximumRecordBytes = 16 * 1_024
    static let maximumRecords = 192
    static let maximumLineage = 16
    static let maximumAcceptedBases = 16

    private struct Document: Codable {
        let schemaVersion: Int
        var intents: [Intent]
        var quarantined: [QuarantinedProjection]

        private enum CodingKeys: String, CodingKey { case schemaVersion, intents, quarantined }
        init(schemaVersion: Int, intents: [Intent], quarantined: [QuarantinedProjection] = []) {
            self.schemaVersion = schemaVersion
            self.intents = intents
            self.quarantined = quarantined
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            intents = try container.decode([Intent].self, forKey: .intents)
            quarantined = try container.decodeIfPresent([QuarantinedProjection].self, forKey: .quarantined) ?? []
        }
    }
    /// Fields that identify the submitted mutation. acceptedBases is mutable local ACK metadata,
    /// so it is deliberately excluded from predecessor receipt authentication.
    private struct ReceiptPayload: Codable, Equatable {
        let id: UUID
        let authority: Authority
        let group: Group
        let base: Snapshot
        let desired: VortxJSON
        let supersededIDs: [UUID]
        let supersededReceipts: [SupersededReceipt]
        let projectionStamps: [String: Double]
        let requiresResolution: Bool
        init(_ intent: Intent) {
            id = intent.id; authority = intent.authority; group = intent.group; base = intent.base
            desired = intent.desired; supersededIDs = intent.supersededIDs; supersededReceipts = intent.supersededReceipts
            projectionStamps = intent.projectionStamps
            requiresResolution = intent.requiresResolution
        }
    }

    private let directoryURL: URL
    private let key: SymmetricKey
    private let keyByteCount: Int
    private let namespace: String
    private let fileURL: URL

    init(directoryURL: URL, key: Data, namespace: String) {
        self.directoryURL = directoryURL
        self.key = SymmetricKey(data: key)
        self.keyByteCount = key.count
        self.namespace = namespace
        let digest = SHA256.hash(data: Data(namespace.utf8)).map { String(format: "%02x", $0) }.joined()
        self.fileURL = directoryURL.appendingPathComponent("preference-intents-\(digest).bin", isDirectory: false)
    }

    func prepare(authority: Authority, group: Group, base: Snapshot, desired: VortxJSON,
                 projectionStamps: [String: Double] = [:], requiresResolution: Bool = false) throws -> Intent {
        try validate(authority: authority)
        try validate(snapshot: base)
        try Self.validate(desired: desired, group: group)
        try Self.validate(projectionStamps: projectionStamps)
        var document = try readDocument()
        if let existing = document.intents.last(where: { $0.authority == authority && $0.group == group && $0.desired == desired }) {
            return existing
        }
        let previous = document.intents.last(where: { $0.authority == authority && $0.group == group })
        let lineage = ([previous?.id].compactMap { $0 } + (previous?.supersededIDs ?? []))
        guard lineage.count <= Self.maximumLineage else { throw StoreError.tooLarge }
        let receipts = (previous.map { [SupersededReceipt(id: $0.id, digest: receiptDigest($0))] } ?? []) + (previous?.supersededReceipts ?? [])
        guard receipts.count <= Self.maximumLineage,
              receipts.map(\.id) == lineage else { throw StoreError.unreadable }
        let intent = Intent(id: UUID(), authority: authority, group: group, base: base, desired: desired,
                            supersededIDs: lineage, supersededReceipts: receipts, acceptedBases: previous?.acceptedBases ?? [],
                            projectionStamps: projectionStamps, requiresResolution: requiresResolution)
        document.intents.removeAll { $0.authority == authority && $0.group == group }
        guard document.intents.count + document.quarantined.count < Self.maximumRecords else { throw StoreError.tooLarge }
        document.intents.append(intent)
        try writeDocument(document)
        return intent
    }

    func pending() throws -> [Intent] { try readDocument().intents }

    /// Retains unmounted legacy projection evidence verbatim. These values are never interpreted
    /// as intent or replay authority; the admission caller supplies only its own whitelist.
    func quarantine(_ values: [QuarantinedProjection]) throws {
        guard values.count <= Self.maximumRecords else { throw StoreError.tooLarge }
        for value in values { try Self.validate(quarantined: value) }
        var document = try readDocument()
        var additions: [QuarantinedProjection] = []
        for value in values {
            if let existing = (document.quarantined + additions).first(where: { $0.key == value.key && $0.stamp == value.stamp }) {
                guard existing.value == value.value else { throw StoreError.conflict }
                continue
            }
            additions.append(value)
        }
        guard document.intents.count + document.quarantined.count + additions.count <= Self.maximumRecords else { throw StoreError.tooLarge }
        guard !additions.isEmpty else { return }
        document.quarantined.append(contentsOf: additions)
        try writeDocument(document)
    }

    func quarantined() throws -> [QuarantinedProjection] { try readDocument().quarantined }

    /// Read-only cloud-ACK preflight. This deliberately does not consume accepted-base capacity.
    func authorizesAcknowledgement(_ sent: Intent, current: Snapshot) throws -> Bool {
        try validate(authority: sent.authority)
        try Self.validate(desired: sent.desired, group: sent.group)
        try Self.validate(projectionStamps: sent.projectionStamps)
        try validate(snapshot: current)
        guard current.value == sent.desired else { return false }
        let document = try readDocument()
        return try matchingIndex(for: sent, in: document) != nil
    }

    /// Acknowledges only a value confirmed in the current authenticated snapshot. A stale ACK
    /// can add a recognized committed predecessor to a newer intent, but cannot erase it.
    func acknowledge(_ sent: Intent, current: Snapshot) throws -> Bool {
        try validate(authority: sent.authority)
        try Self.validate(desired: sent.desired, group: sent.group)
        try Self.validate(projectionStamps: sent.projectionStamps)
        try validate(snapshot: current)
        guard current.value == sent.desired else { return false }
        var document = try readDocument()
        guard let index = try matchingIndex(for: sent, in: document) else { return false }
        if document.intents[index].id == sent.id {
            document.intents.remove(at: index)
        } else {
            _ = try appendAcceptedBase(current, to: index, in: &document)
        }
        try writeDocument(document)
        return true
    }

    /// Records a native durable commit while retaining its encrypted intent as the cloud-sync
    /// authority. Only a later authenticated cloud ACK may clear an exact active intent.
    func recordCommitted(_ sent: Intent, current: Snapshot) throws -> Bool {
        try validate(authority: sent.authority)
        try Self.validate(desired: sent.desired, group: sent.group)
        try Self.validate(projectionStamps: sent.projectionStamps)
        try validate(snapshot: current)
        guard current.value == sent.desired else { return false }
        var document = try readDocument()
        guard let index = try matchingIndex(for: sent, in: document) else { return false }
        if try appendAcceptedBase(current, to: index, in: &document) { try writeDocument(document) }
        return true
    }

    private func matchingIndex(for sent: Intent, in document: Document) throws -> Int? {
        guard let index = document.intents.firstIndex(where: {
            $0.authority == sent.authority && $0.group == sent.group && ($0.id == sent.id || $0.supersededIDs.contains(sent.id))
        }) else { return nil }
        let active = document.intents[index]
        if active.id == sent.id {
            guard ReceiptPayload(active) == ReceiptPayload(sent) else { return nil }
        } else {
            guard let receipt = active.supersededReceipts.first(where: { $0.id == sent.id }),
                  HMAC<SHA256>.isValidAuthenticationCode(receipt.digest, authenticating: try receiptMessage(sent), using: key) else { return nil }
        }
        return index
    }

    private func appendAcceptedBase(_ current: Snapshot, to index: Int, in document: inout Document) throws -> Bool {
        var active = document.intents[index]
        guard !active.acceptedBases.contains(current) else { return false }
        guard active.acceptedBases.count < Self.maximumAcceptedBases else { throw StoreError.tooLarge }
        active.acceptedBases.append(current)
        document.intents[index] = active
        return true
    }

    static func decision(_ intent: Intent, current: Snapshot, authority: Authority) -> Decision {
        guard intent.authority == authority else { return .conflict }
        if current.value == intent.desired { return .alreadyApplied }
        if intent.requiresResolution { return .conflict }
        if current == intent.base || intent.acceptedBases.contains(current) { return .apply }
        return .conflict
    }

    private func validate(authority: Authority) throws {
        guard !namespace.isEmpty, namespace.utf8.count <= 512,
              !authority.account.isEmpty, authority.account == namespace, authority.account.utf8.count <= 256,
              !authority.account.contains("@"),
              authority.account.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              Self.isUUID(authority.ownerProfileID), Self.isUUID(authority.profileID),
              case .object = authority.profileBinding,
              try Self.encodedSize(authority.profileBinding) <= Self.maximumRecordBytes,
              Self.containsSensitiveKey(authority.profileBinding) == false else { throw StoreError.invalid }
    }

    private func validate(snapshot: Snapshot) throws {
        guard try Self.encodedSize(snapshot.value) <= Self.maximumRecordBytes,
              try Self.encodedSize(snapshot.revision) <= Self.maximumRecordBytes else { throw StoreError.tooLarge }
        guard !Self.containsSensitiveKey(snapshot.value), !Self.containsSensitiveKey(snapshot.revision) else { throw StoreError.invalid }
    }

    private static func validate(desired: VortxJSON, group: Group) throws {
        guard try encodedSize(desired) <= maximumRecordBytes else { throw StoreError.tooLarge }
        guard !containsSensitiveKey(desired) else { throw StoreError.invalid }
        switch group {
        case .playback:
            guard case .object(let values) = desired,
                  Set(values.keys) == ["playback", "addonPreferences"],
                  values.values.allSatisfy({ if case .object = $0 { return true }; if case .null = $0 { return true }; return false })
            else { throw StoreError.invalid }
        case .discovery:
            if desired == .null { return }
            guard case .object = desired else { throw StoreError.invalid }
        case .theme:
            guard case .object(let values) = desired, Set(values.keys) == ["accentID", "oled", "textScale"],
                  case .string(let accentID)? = values["accentID"], !accentID.isEmpty, accentID.utf8.count <= 128,
                  case .bool? = values["oled"], Self.finiteNumber(values["textScale"]) else { throw StoreError.invalid }
        }
    }

    private static func validate(quarantined value: QuarantinedProjection) throws {
        let normalizedKey = value.key.lowercased().filter { $0.isLetter || $0.isNumber }
        let sensitive = ["token", "email", "password", "credential", "secret", "authorization", "apikey"]
        guard !value.key.isEmpty, value.key.utf8.count <= 256,
              value.key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              !sensitive.contains(where: normalizedKey.contains), value.stamp.isFinite,
              !containsSensitiveKey(value.value) else { throw StoreError.invalid }
        guard try encodedSize(value) <= maximumRecordBytes else { throw StoreError.tooLarge }
    }

    private static func validate(projectionStamps: [String: Double]) throws {
        let sensitive = ["token", "email", "password", "credential", "secret", "authorization", "apikey"]
        guard projectionStamps.count <= 96 else { throw StoreError.tooLarge }
        for (key, stamp) in projectionStamps {
            let normalizedKey = key.lowercased().filter { $0.isLetter || $0.isNumber }
            guard !key.isEmpty, key.utf8.count <= 256,
                  key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  !sensitive.contains(where: normalizedKey.contains), stamp.isFinite else { throw StoreError.invalid }
        }
        guard try encodedSize(projectionStamps) <= maximumRecordBytes else { throw StoreError.tooLarge }
    }

    private static func finiteNumber(_ value: VortxJSON?) -> Bool {
        switch value { case .number(let n)?: return n.isFinite; case .integer?, .unsigned?: return true; default: return false }
    }

    private static func isUUID(_ value: String) -> Bool {
        guard let parsed = UUID(uuidString: value) else { return false }
        return parsed.uuidString.caseInsensitiveCompare(value) == .orderedSame
    }

    private static func containsSensitiveKey(_ value: VortxJSON) -> Bool {
        switch value {
        case .object(let members):
            return members.contains { key, child in
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                return ["token", "email", "password", "credential", "secret", "authorization", "apikey"].contains(where: normalized.contains)
                    || containsSensitiveKey(child)
            }
        case .array(let values): return values.contains(where: containsSensitiveKey)
        default: return false
        }
    }

    private static func encodedSize<T: Encodable>(_ value: T) throws -> Int { try JSONEncoder().encode(value).count }

    private func receiptMessage(_ intent: Intent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ReceiptPayload(intent))
    }

    private func receiptDigest(_ intent: Intent) -> Data {
        // Intents created by this store are already bounded and Codable; a failure here indicates
        // an invalid in-memory value, so return an impossible digest that cannot authenticate.
        guard let message = try? receiptMessage(intent) else { return Data() }
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    private func groupOwnerIdentity(_ authority: Authority, group: Group) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(authority)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return "\(digest)|\(group.rawValue)"
    }

    private var authenticatedData: Data { Data("vortx-native-preference-intents|schema=1|namespace=\(namespace)".utf8) }

    private func readDocument() throws -> Document {
        try validateNamespaceAndKey()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Document(schemaVersion: Self.schemaVersion, intents: []) }
        do {
            let bytes = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            guard bytes.count <= Self.maximumFileBytes, let box = try? AES.GCM.SealedBox(combined: bytes),
                  let plaintext = try? AES.GCM.open(box, using: key, authenticating: authenticatedData),
                  plaintext.count <= Self.maximumFileBytes else { throw StoreError.unreadable }
            let document = try JSONDecoder().decode(Document.self, from: plaintext)
            try validate(document: document)
            return document
        } catch { throw StoreError.unreadable }
    }

    private func validate(document: Document) throws {
        guard document.schemaVersion == Self.schemaVersion,
              document.intents.count + document.quarantined.count <= Self.maximumRecords else { throw StoreError.unreadable }
        var identities = Set<String>()
        var groupOwners = Set<String>()
        for intent in document.intents {
            try validate(authority: intent.authority)
            try validate(snapshot: intent.base)
            try Self.validate(desired: intent.desired, group: intent.group)
            try Self.validate(projectionStamps: intent.projectionStamps)
            guard intent.supersededIDs.count <= Self.maximumLineage,
                  intent.supersededReceipts.count == intent.supersededIDs.count,
                  intent.supersededReceipts.map(\.id) == intent.supersededIDs,
                  intent.supersededReceipts.allSatisfy({ $0.digest.count == 32 }),
                  intent.acceptedBases.count <= Self.maximumAcceptedBases,
                  !intent.supersededIDs.contains(intent.id),
                  Set(intent.supersededIDs).count == intent.supersededIDs.count,
                  intent.acceptedBases.allSatisfy({ (try? Self.encodedSize($0)) != nil }) else { throw StoreError.unreadable }
            for snapshot in intent.acceptedBases { try validate(snapshot: snapshot) }
            let owner = try groupOwnerIdentity(intent.authority, group: intent.group)
            guard groupOwners.insert(owner).inserted, identities.insert(intent.id.uuidString).inserted else { throw StoreError.unreadable }
            guard try Self.encodedSize(intent) <= Self.maximumRecordBytes else { throw StoreError.unreadable }
        }
        var quarantinedKeys: [QuarantinedProjection] = []
        for value in document.quarantined {
            try Self.validate(quarantined: value)
            guard !quarantinedKeys.contains(where: { $0.key == value.key && $0.stamp == value.stamp }) else { throw StoreError.unreadable }
            quarantinedKeys.append(value)
        }
    }

    private func writeDocument(_ document: Document) throws {
        do {
            try validateNamespaceAndKey()
            try validate(document: document)
            let plaintext = try JSONEncoder().encode(document)
            guard plaintext.count <= Self.maximumFileBytes else { throw StoreError.tooLarge }
            let box = try AES.GCM.seal(plaintext, using: key, authenticating: authenticatedData)
            guard let bytes = box.combined, bytes.count <= Self.maximumFileBytes else { throw StoreError.tooLarge }
            let manager = FileManager.default
            try manager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try manager.setAttributes(Self.protectedDirectoryAttributes, ofItemAtPath: directoryURL.path)
            let temporaryURL = directoryURL.appendingPathComponent(".intent-\(UUID().uuidString).tmp")
            guard manager.createFile(atPath: temporaryURL.path, contents: nil, attributes: Self.protectedFileAttributes) else { throw StoreError.persistence }
            do {
                let handle = try FileHandle(forWritingTo: temporaryURL)
                try handle.write(contentsOf: bytes)
                try handle.synchronize()
                try handle.close()
                try manager.setAttributes(Self.protectedFileAttributes, ofItemAtPath: temporaryURL.path)
                guard rename(temporaryURL.path, fileURL.path) == 0 else { throw StoreError.persistence }
                #if canImport(Darwin)
                let directoryFD = directoryURL.path.withCString { Darwin.open($0, O_RDONLY) }
                guard directoryFD >= 0 else { throw StoreError.persistence }
                let syncResult = Darwin.fsync(directoryFD)
                let closeResult = Darwin.close(directoryFD)
                guard syncResult == 0, closeResult == 0 else { throw StoreError.persistence }
                #endif
                let readback = try readDocument()
                guard readback.schemaVersion == document.schemaVersion,
                      readback.intents == document.intents,
                      readback.quarantined == document.quarantined else { throw StoreError.persistence }
            } catch {
                try? manager.removeItem(at: temporaryURL)
                throw error
            }
        } catch { throw error is StoreError ? error : StoreError.persistence }
    }

    private static var protectedFileAttributes: [FileAttributeKey: Any] {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS) || os(tvOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        return attributes
    }

    private static var protectedDirectoryAttributes: [FileAttributeKey: Any] {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS) || os(tvOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        return attributes
    }

    private func validateNamespaceAndKey() throws {
        guard !namespace.isEmpty, namespace.utf8.count <= 512, keyByteCount == 32 else { throw StoreError.invalid }
    }
}
