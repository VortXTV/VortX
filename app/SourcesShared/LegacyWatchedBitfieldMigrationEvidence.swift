import Foundation
import CryptoKit

/// Evidence required to turn one legacy series bitmap into bare watched episode IDs.
///
/// This is deliberately a standalone preparation step. It neither changes import material nor
/// manufactures a watch clock: an importer must still merge `watchedVideoIDs` with `ma`/`ua`,
/// where the existing explicit clocked marks win. The caller supplies its already-captured,
/// authenticated document and uses the injected fetcher for exactly one original-addon meta call.
enum LegacyWatchedBitfieldMigrationEvidence {
    private static let legacyOwnerProfileID = UUID(uuidString: "00000000-0000-0000-0000-00000000A11C")!
    enum Failure: Error, Equatable {
        case malformed(String)
        case admissionRevoked
    }

    struct Scope: Equatable, Sendable {
        let accountID: String
        let profileID: UUID
        /// Resolved from the captured authenticated roster, never an implicit fixed owner.
        let ownerProfileID: UUID
        /// Required only for an independently authenticated own-account source.
        let verifiedStreamingUID: String?

        init(accountID: String, profileID: UUID, verifiedStreamingUID: String? = nil, ownerProfileID: UUID) throws {
            func validIdentity(_ value: String) -> Bool {
                !value.isEmpty && value.utf8.count <= 256 && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                    && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            }
            guard validIdentity(accountID), verifiedStreamingUID.map(validIdentity) ?? true else { throw Failure.malformed("Missing account scope") }
            self.accountID = accountID
            self.profileID = profileID
            self.ownerProfileID = ownerProfileID
            self.verifiedStreamingUID = verifiedStreamingUID
        }
    }

    /// An exact JSON-pointer-shaped locator. It is intentionally typed instead of accepting an
    /// arbitrary pointer, so a title cannot borrow another profile's bitmap.
    enum SourceRowLocator: Equatable, Sendable {
        case authenticatedOwnerLibrary(index: Int)
        case authenticatedLegacyRootLibrary(index: Int)
        case authenticatedProfileLibrary(index: Int)
        case authenticatedOwnerHistory(sourceProfileID: String, index: Int)
        case ownAccountLibraryResponse(index: Int)
        case ownAccountProfileLibrary(index: Int)
        case ownAccountOwnerHistory(index: Int)

        var pointer: String {
            switch self {
            case .authenticatedOwnerLibrary(let index): return "/vortx/library/\(index)"
            case .authenticatedLegacyRootLibrary(let index): return "/library/\(index)"
            case .authenticatedProfileLibrary(let index): return "/vortx/byProfile/<captured-profile>/library/\(index)"
            case .authenticatedOwnerHistory(let sourceProfileID, let index): return "/vortx/byProfile/\(sourceProfileID)/ownerHistory/\(index)"
            case .ownAccountLibraryResponse(let index): return "/libraryResponseBase64/result/\(index)"
            case .ownAccountProfileLibrary(let index): return "/profileOverlayBase64/vortx/byProfile/<captured-profile>/library/\(index)"
            case .ownAccountOwnerHistory(let index): return "/profileOverlayBase64/vortx/byProfile/<captured-profile>/ownerHistory/\(index)"
            }
        }

        var isOwnAccount: Bool {
            switch self {
            case .ownAccountLibraryResponse, .ownAccountProfileLibrary, .ownAccountOwnerHistory: return true
            default: return false
            }
        }
    }

    /// The raw manifest body is retained only as an identity witness. The source document must
    /// contain the same descriptor; a current registry/cache cannot substitute for it.
    struct AuthorizedAddon: Equatable, Sendable {
        let transportURL: String
        let manifest: Data

        init(transportURL: String, manifest: Data) throws {
            guard let url = URL(string: transportURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false, url.user == nil, url.password == nil, url.fragment == nil,
                  !manifest.isEmpty, manifest.count <= StrictJSON.maximumDocumentBytes else {
                throw Failure.malformed("Invalid original add-on descriptor")
            }
            let object = try strictObject(StrictJSON.value(manifest))
            guard case .string = object.value("id"), case .string = object.value("name") else {
                throw Failure.malformed("Original add-on manifest is incomplete")
            }
            self.transportURL = transportURL
            self.manifest = manifest
        }

        var manifestSHA256: String { sha256(manifest) }
    }

    struct MetadataRequest: Equatable, Sendable {
        let scope: Scope
        let addon: AuthorizedAddon
        let type: String
        let metaID: String
    }

    struct MetadataResponse: Equatable, Sendable {
        let request: MetadataRequest
        /// Exact, token-free, unprojected response bytes for later host archival.
        let raw: Data
    }

    typealias MetadataFetcher = @Sendable (MetadataRequest) async throws -> MetadataResponse

    struct Evidence: Equatable, Sendable {
        let scope: Scope
        let rowLocator: SourceRowLocator
        let metaID: String
        let watchedBitfield: String
        let addon: AuthorizedAddon
        let source: Data
        let sourceSHA256: String
        let metadata: Data
        let metadataSHA256: String
        let inventory: [LegacyWatchedBitfieldEpisode]
        /// Bare facts only. Existing `ma` / `ua` merge code owns final watch truth and clocks.
        let watchedVideoIDs: [String]
    }

    static func capture(scope: Scope, source: Data, rowLocator: SourceRowLocator,
                        addon: AuthorizedAddon, isCurrent: @escaping @Sendable () -> Bool,
                        fetch: MetadataFetcher) async throws -> Evidence {
        guard isCurrent() else { throw Failure.admissionRevoked }
        let (sourceTree, row) = try checkedSource(scope: scope, source: source, rowLocator: rowLocator)
        try requireOriginalAddon(sourceTree, locator: rowLocator, expected: addon)

        let request = MetadataRequest(scope: scope, addon: addon, type: "series", metaID: row.metaID)
        let response = try await fetch(request)
        guard isCurrent() else { throw Failure.admissionRevoked }
        guard sameRequest(response.request, request) else { throw Failure.malformed("Metadata response belongs to another request") }
        return try replay(scope: scope, source: source, rowLocator: rowLocator, addon: addon, metadata: response.raw, isCurrent: isCurrent)
    }

    /// Replays the same strict validator over exact archived bytes. No stored decoded IDs, clocks,
    /// projected inventory or caller-constructed Evidence can bypass source/descriptor validation.
    static func replay(scope: Scope, source: Data, rowLocator: SourceRowLocator, addon: AuthorizedAddon,
                       metadata: Data, isCurrent: @escaping @Sendable () -> Bool) throws -> Evidence {
        guard isCurrent() else { throw Failure.admissionRevoked }
        let (sourceTree, row) = try checkedSource(scope: scope, source: source, rowLocator: rowLocator)
        try requireOriginalAddon(sourceTree, locator: rowLocator, expected: addon)
        let inventory = try inventory(metadata, requestedID: row.metaID)
        let watched = try LegacyWatchedBitfieldDecoder.decode(serialized: row.watchedBitfield, inventory: inventory)
        guard isCurrent() else { throw Failure.admissionRevoked }
        return Evidence(scope: scope, rowLocator: rowLocator, metaID: row.metaID, watchedBitfield: row.watchedBitfield,
                        addon: addon, source: source, sourceSHA256: sha256(source), metadata: metadata,
                        metadataSHA256: sha256(metadata), inventory: inventory, watchedVideoIDs: watched)
    }

    /// Pending evidence still proves which original bitmap was left unresolved, even when no
    /// original add-on can supply metadata. It grants no decoded watch facts.
    static func validateSource(scope: Scope, source: Data, rowLocator: SourceRowLocator) throws {
        _ = try checkedSource(scope: scope, source: source, rowLocator: rowLocator)
    }

    private static func checkedSource(scope: Scope, source: Data, rowLocator: SourceRowLocator) throws -> (StrictJSON.Value, SourceRow) {
        let sourceTree = try StrictJSON.value(source)
        if rowLocator.isOwnAccount {
            guard scope.verifiedStreamingUID != nil, scope.profileID != scope.ownerProfileID else { throw Failure.malformed("Own source requires verified secondary streaming identity") }
            try requireOwnEnvelope(sourceTree)
        } else {
            guard scope.verifiedStreamingUID == nil else { throw Failure.malformed("Shared source cannot claim an own identity") }
        }
        let row = try sourceRow(sourceTree, scope: scope, locator: rowLocator)
        guard row.type == "series", !row.metaID.isEmpty, !row.watchedBitfield.isEmpty else { throw Failure.malformed("Source row is not a watched series") }
        return (sourceTree, row)
    }

    private struct SourceRow { let metaID: String; let type: String; let watchedBitfield: String }

    private static func sourceRow(_ root: StrictJSON.Value, scope: Scope, locator: SourceRowLocator) throws -> SourceRow {
        let rootObject = try strictObject(root)
        switch locator {
        case .authenticatedOwnerLibrary(let index):
            guard index >= 0, scope.profileID == scope.ownerProfileID else { throw Failure.malformed("Owner source requires owner scope") }
            let vortx = try strictObject(strictValue(rootObject, "vortx"))
            let rows = try strictArray(strictValue(vortx, "library"))
            return try sharedRow(rows, index: index)
        case .authenticatedLegacyRootLibrary(let index):
            guard index >= 0, scope.profileID == scope.ownerProfileID else { throw Failure.malformed("Owner source requires owner scope") }
            return try sharedRow(try strictArray(strictValue(rootObject, "library")), index: index)
        case .authenticatedProfileLibrary(let index):
            guard index >= 0 else { throw Failure.malformed("Invalid source row index") }
            let vortx = try strictObject(strictValue(rootObject, "vortx"))
            let profiles = try strictObject(strictValue(vortx, "byProfile"))
            let bucket = try profileBucket(profiles, id: scope.profileID)
            return try sharedRow(try strictArray(strictValue(bucket, "library")), index: index)
        case .authenticatedOwnerHistory(let sourceProfileID, let index):
            guard index >= 0, scope.profileID == scope.ownerProfileID, let id = UUID(uuidString: sourceProfileID),
                  id == scope.ownerProfileID || id == legacyOwnerProfileID else { throw Failure.malformed("History source requires resolved owner scope") }
            let vortx = try strictObject(strictValue(rootObject, "vortx"))
            let profiles = try strictObject(strictValue(vortx, "byProfile"))
            let bucket = try profileBucket(profiles, id: id, exactKey: sourceProfileID)
            return try sharedRow(try strictArray(strictValue(bucket, "ownerHistory")), index: index)
        case .ownAccountLibraryResponse(let index):
            guard index >= 0, scope.verifiedStreamingUID != nil else { throw Failure.malformed("Own source requires verified streaming identity") }
            let envelope = try strictObject(try StrictJSON.value(try strictEnvelopeBytes(rootObject, "libraryResponseBase64")))
            let rows = try strictArray(strictValue(envelope, "result"))
            guard let row = rows[safe: index] else { throw Failure.malformed("Source row is absent") }
            let rowObject = try strictObject(row)
            let state = try strictObject(strictValue(rowObject, "state"))
            return SourceRow(metaID: try strictString(rowObject.value("_id")), type: try strictString(rowObject.value("type")), watchedBitfield: try strictString(state.value("watched")))
        case .ownAccountProfileLibrary(let index), .ownAccountOwnerHistory(let index):
            guard index >= 0 else { throw Failure.malformed("Invalid source row index") }
            let overlay = try strictObject(try StrictJSON.value(try strictEnvelopeBytes(rootObject, "profileOverlayBase64")))
            let vortx = try strictObject(strictValue(overlay, "vortx"))
            let profiles = try strictObject(strictValue(vortx, "byProfile"))
            guard profiles.members.count == 1 else { throw Failure.malformed("Own overlay must contain exactly its profile") }
            let bucket = try profileBucket(profiles, id: scope.profileID, exactKey: scope.profileID.uuidString)
            let carrier: String
            if case .ownAccountOwnerHistory = locator { carrier = "ownerHistory" } else { carrier = "library" }
            return try sharedRow(try strictArray(strictValue(bucket, carrier)), index: index)
        }
    }

    private static func profileBucket(_ profiles: StrictJSON.Object, id: UUID, exactKey: String? = nil) throws -> StrictJSON.Object {
        var seen = Set<UUID>()
        var selected: StrictJSON.Value?
        for member in profiles.members {
            guard let profile = UUID(uuidString: member.key), seen.insert(profile).inserted else { throw Failure.malformed("Ambiguous profile source identity") }
            if profile == id {
                guard exactKey == nil || exactUTF8(member.key, exactKey!) else { throw Failure.malformed("Source profile locator mismatch") }
                selected = member.value
            }
        }
        return try strictObject(selected)
    }

    private static func requireOwnEnvelope(_ source: StrictJSON.Value) throws {
        let object = try strictObject(source)
        let keys = object.members.map(\.keyBytes)
        let expected = ["schemaVersion", "libraryResponseBase64", "addonsResponseBase64", "profileOverlayBase64"].map { Data($0.utf8) }
        guard keys.count == expected.count, Set(keys) == Set(expected),
              case .number(let version) = try strictValue(object, "schemaVersion"), version == "1" || version == "2" else {
            throw Failure.malformed("Malformed own-account source envelope")
        }
        _ = try strictEnvelopeBytes(object, "libraryResponseBase64")
        _ = try strictEnvelopeBytes(object, "addonsResponseBase64")
        _ = try strictEnvelopeBytes(object, "profileOverlayBase64")
    }

    private static func sharedRow(_ rows: [StrictJSON.Value], index: Int) throws -> SourceRow {
        guard let raw = rows[safe: index] else { throw Failure.malformed("Source row is absent") }
        let row = try strictObject(raw)
        return SourceRow(metaID: try strictString(row.value("id")), type: try strictString(row.value("type")), watchedBitfield: try strictString(row.value("watched")))
    }

    private static func requireOriginalAddon(_ root: StrictJSON.Value, locator: SourceRowLocator,
                                             expected: AuthorizedAddon) throws {
        let expectedManifest = try StrictJSON.value(expected.manifest)
        let matches = try sourceDescriptors(root, locator: locator).filter { raw in
            let descriptor = try strictObject(raw)
            guard exactUTF8(try strictString(descriptor.value("transportUrl")), expected.transportURL) else { return false }
            return descriptor.value("manifest") == expectedManifest
        }
        guard matches.count == 1 else { throw Failure.malformed("Original add-on descriptor is absent or ambiguous") }
    }

    /// Preserve all scalar spelling from the strict tree, including manifest numeric lexemes.
    /// Foundation's dictionary projection is never a replacement descriptor identity witness.
    static func originalAddons(source: Data, rowLocator: SourceRowLocator) throws -> [AuthorizedAddon] {
        let root = try StrictJSON.value(source)
        if rowLocator.isOwnAccount { try requireOwnEnvelope(root) }
        return try sourceDescriptors(root, locator: rowLocator).map { raw in
            let descriptor = try strictObject(raw)
            let manifest = try strictValue(descriptor, "manifest")
            return try AuthorizedAddon(transportURL: strictString(descriptor.value("transportUrl")), manifest: StrictJSON.serialize(manifest))
        }
    }

    private static func sourceDescriptors(_ root: StrictJSON.Value, locator: SourceRowLocator) throws -> [StrictJSON.Value] {
        let rootObject = try strictObject(root)
        let descriptors: [StrictJSON.Value]
        if locator.isOwnAccount {
            let envelope = try StrictJSON.value(try strictEnvelopeBytes(rootObject, "addonsResponseBase64"))
            let result = try strictObject(strictValue(try strictObject(envelope), "result"))
            descriptors = try strictArray(strictValue(result, "addons"))
        } else {
            // Add-on descriptors are account-global original-registry evidence. Profile library
            // rows do not get to supply or override an add-on descriptor from their own bucket.
            let vortxDescriptors: [StrictJSON.Value]
            if let rawVortx = rootObject.value("vortx") {
                // A present `vortx` member is still structural evidence and must be well-formed.
                vortxDescriptors = try optionalStrictArray(strictObject(rawVortx).value("addons"))
            } else {
                // The pre-vortx authenticated root form has its registry alongside `library`.
                vortxDescriptors = []
            }
            descriptors = vortxDescriptors + (try optionalStrictArray(rootObject.value("addons")))
        }
        return descriptors
    }

    private static func inventory(_ raw: Data, requestedID: String) throws -> [LegacyWatchedBitfieldEpisode] {
        let root = try strictObject(try StrictJSON.value(raw))
        let meta = try strictObject(strictValue(root, "meta"))
        guard exactUTF8(try strictString(meta.value("id")), requestedID), exactUTF8(try strictString(meta.value("type")), "series") else {
            throw Failure.malformed("Metadata identity mismatch")
        }
        let videos = try strictArray(strictValue(meta, "videos"))
        guard !videos.isEmpty, videos.count <= 10_000 else { throw Failure.malformed("Metadata has no complete episode inventory") }
        let unsorted = try videos.map { rawVideo in
            let video = try strictObject(rawVideo)
            return LegacyWatchedBitfieldEpisode(id: try strictString(video.value("id")), season: try strictInt(video.value("season")),
                                                episode: try strictInt(video.value("episode")), releasedMs: try strictReleased(video.value("released")))
        }
        return unsorted.sorted(by: legacyOrder)
    }

    private static func legacyOrder(_ lhs: LegacyWatchedBitfieldEpisode, _ rhs: LegacyWatchedBitfieldEpisode) -> Bool {
        if lhs.season != rhs.season { return lhs.season < rhs.season }
        if lhs.episode != rhs.episode { return lhs.episode < rhs.episode }
        switch (lhs.releasedMs, rhs.releasedMs) {
        case (nil, .some): return true
        case (.some, nil): return false
        case let (.some(left), .some(right)): return left < right
        case (nil, nil): return false
        }
    }

    private static func strictObject(_ value: StrictJSON.Value?) throws -> StrictJSON.Object {
        guard let value, case .object(let object) = value else { throw Failure.malformed("Malformed JSON object") }
        return object
    }
    private static func strictArray(_ value: StrictJSON.Value?) throws -> [StrictJSON.Value] {
        guard let value, case .array(let array) = value else { throw Failure.malformed("Malformed JSON array") }
        return array
    }
    private static func optionalStrictArray(_ value: StrictJSON.Value?) throws -> [StrictJSON.Value] {
        guard let value else { return [] }
        return try strictArray(value)
    }
    private static func strictString(_ value: StrictJSON.Value?) throws -> String {
        guard let value, case .string(let string) = value, !string.isEmpty else { throw Failure.malformed("Missing string") }
        return string
    }
    private static func strictValue(_ object: StrictJSON.Object, _ key: String) throws -> StrictJSON.Value {
        guard let value = object.value(key) else { throw Failure.malformed("Missing JSON value \(key)") }
        return value
    }
    private static func strictInt(_ value: StrictJSON.Value?) throws -> Int {
        guard let value, case .number(let raw) = value,
              raw.range(of: "^(0|[1-9][0-9]{0,9})$", options: .regularExpression) != nil,
              let number = Int64(raw), number <= Int64(Int32.max) else { throw Failure.malformed("Malformed episode coordinate") }
        return Int(number)
    }
    private static func strictReleased(_ value: StrictJSON.Value?) throws -> Int64? {
        guard let value else { return nil }
        if case .null = value { return nil }
        guard case .string(let text) = value, !text.isEmpty else { throw Failure.malformed("Malformed episode release value") }
        return try released(text)
    }

    private static func released(_ text: String) throws -> Int64 {
        let bytes = Array(text.utf8)
        guard bytes.count >= 20, bytes[4] == 45, bytes[7] == 45, bytes[10] == 84, bytes[13] == 58, bytes[16] == 58 else {
            throw Failure.malformed("Malformed episode release value")
        }
        func digits(_ start: Int, _ count: Int) throws -> Int64 {
            guard start + count <= bytes.count, bytes[start..<(start + count)].allSatisfy({ (48...57).contains($0) }) else { throw Failure.malformed("Malformed episode release value") }
            return bytes[start..<(start + count)].reduce(0) { $0 * 10 + Int64($1 - 48) }
        }
        let year = try digits(0, 4), month = try digits(5, 2), day = try digits(8, 2)
        let hour = try digits(11, 2), minute = try digits(14, 2), second = try digits(17, 2)
        guard year >= 1, month >= 1, month <= 12, day >= 1, day <= daysInMonth(year: year, month: month), hour < 24, minute < 60, second < 60 else {
            throw Failure.malformed("Malformed episode release value")
        }
        var cursor = 19; var milliseconds: Int64 = 0
        if cursor < bytes.count, bytes[cursor] == 46 {
            cursor += 1; let fractionStart = cursor
            while cursor < bytes.count, (48...57).contains(bytes[cursor]) { cursor += 1 }
            let count = cursor - fractionStart
            guard (1...3).contains(count) else { throw Failure.malformed("Episode release has non-millisecond precision") }
            milliseconds = try digits(fractionStart, count) * (count == 1 ? 100 : count == 2 ? 10 : 1)
        }
        let offsetMinutes: Int64
        if cursor + 1 == bytes.count, bytes[cursor] == 90 { offsetMinutes = 0 }
        else {
            guard cursor + 6 == bytes.count, (bytes[cursor] == 43 || bytes[cursor] == 45), bytes[cursor + 3] == 58 else { throw Failure.malformed("Malformed episode release value") }
            let hours = try digits(cursor + 1, 2), minutes = try digits(cursor + 4, 2)
            guard hours <= 23, minutes < 60 else { throw Failure.malformed("Malformed episode release value") }
            offsetMinutes = (bytes[cursor] == 43 ? 1 : -1) * (hours * 60 + minutes)
        }
        let days = daysSinceEpoch(year: year, month: month, day: day)
        return try checkedAdd(try checkedAdd(days * 86_400_000 + hour * 3_600_000 + minute * 60_000 + second * 1_000, milliseconds), -offsetMinutes * 60_000)
    }

    private static func daysInMonth(year: Int64, month: Int64) -> Int64 {
        switch month { case 2: return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28; case 4, 6, 9, 11: return 30; default: return 31 }
    }
    /// Proleptic Gregorian civil date to days since 1970-01-01, entirely in integral arithmetic.
    private static func daysSinceEpoch(year: Int64, month: Int64, day: Int64) -> Int64 {
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        return era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719_468
    }
    private static func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw Failure.malformed("Episode release is out of range") }
        return result
    }

    private static func envelopeBytes(_ root: [String: Any], _ key: String) throws -> Data {
        guard let encoded = root[key] as? String, let bytes = Data(base64Encoded: encoded),
              bytes.base64EncodedString() == encoded else { throw Failure.malformed("Malformed own-account source envelope") }
        try StrictJSON.validate(bytes)
        return bytes
    }
    private static func strictEnvelopeBytes(_ root: StrictJSON.Object, _ key: String) throws -> Data {
        let encoded = try strictString(root.value(key))
        guard let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded else {
            throw Failure.malformed("Malformed own-account source envelope")
        }
        try StrictJSON.validate(bytes)
        return bytes
    }
    private static func object(_ value: Any) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw Failure.malformed("Malformed JSON object") }
        return value
    }
    private static func object(_ dictionary: [String: Any], _ key: String) throws -> [String: Any] {
        guard let value = dictionary[key] else { throw Failure.malformed("Missing object \(key)") }
        return try object(value)
    }
    private static func array(_ object: [String: Any], _ key: String) throws -> [Any]? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        guard let array = value as? [Any] else { throw Failure.malformed("Malformed JSON array") }
        return array
    }
    private static func requiredArray(_ object: [String: Any], _ key: String) throws -> [Any] {
        guard let value = try array(object, key) else { throw Failure.malformed("Missing array \(key)") }
        return value
    }
    private static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else { throw Failure.malformed("Missing string \(key)") }
        return value
    }
    private static func exactInt(_ object: [String: Any], _ key: String) throws -> Int {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue <= Double(Int.max) else { throw Failure.malformed("Malformed episode \(key)") }
        return number.intValue
    }
    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func exactUTF8(_ lhs: String, _ rhs: String) -> Bool { Data(lhs.utf8) == Data(rhs.utf8) }
    private static func sameRequest(_ lhs: MetadataRequest, _ rhs: MetadataRequest) -> Bool {
        lhs.scope.profileID == rhs.scope.profileID && exactUTF8(lhs.scope.accountID, rhs.scope.accountID) &&
            lhs.scope.ownerProfileID == rhs.scope.ownerProfileID &&
            optionalUTF8(lhs.scope.verifiedStreamingUID, rhs.scope.verifiedStreamingUID) &&
            exactUTF8(lhs.addon.transportURL, rhs.addon.transportURL) && lhs.addon.manifest == rhs.addon.manifest &&
            exactUTF8(lhs.type, rhs.type) && exactUTF8(lhs.metaID, rhs.metaID)
    }
    private static func optionalUTF8(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) { case (nil, nil): return true; case let (.some(left), .some(right)): return exactUTF8(left, right); default: return false }
    }
}

private enum StrictJSON {
    static let maximumDocumentBytes = 2 * 1024 * 1024
    struct Member: Equatable {
        let key: String; let keyBytes: Data; let value: Value
        static func == (lhs: Member, rhs: Member) -> Bool { lhs.keyBytes == rhs.keyBytes && lhs.value == rhs.value }
    }
    struct Object: Equatable {
        let members: [Member]
        func value(_ key: String) -> Value? { members.first { $0.keyBytes == Data(key.utf8) }?.value }
        static func == (lhs: Object, rhs: Object) -> Bool {
            guard lhs.members.count == rhs.members.count else { return false }
            // Parser construction rejects duplicate byte keys. Indexing remains byte-keyed so
            // canonical-equivalent Swift strings cannot be treated as the same JSON member.
            var rhsByKey: [Data: Value] = [:]
            for member in rhs.members {
                guard rhsByKey.updateValue(member.value, forKey: member.keyBytes) == nil else { return false }
            }
            return lhs.members.allSatisfy { member in rhsByKey[member.keyBytes] == member.value }
        }
    }
    indirect enum Value: Equatable {
        case object(Object), array([Value]), string(String), number(String), bool(Bool), null
        static func == (lhs: Value, rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case let (.object(left), .object(right)): return left == right
            case let (.array(left), .array(right)): return left.count == right.count && zip(left, right).allSatisfy { $0 == $1 }
            case let (.string(left), .string(right)), let (.number(left), .number(right)): return Data(left.utf8) == Data(right.utf8)
            case let (.bool(left), .bool(right)): return left == right
            case (.null, .null): return true
            default: return false
            }
        }
    }

    static func validate(_ data: Data) throws {
        _ = try value(data)
    }

    static func serialize(_ value: Value) throws -> Data {
        switch value {
        case .object(let object):
            var data = Data("{".utf8)
            for (index, member) in object.members.enumerated() {
                if index > 0 { data.append(44) }
                data.append(try serialize(.string(member.key))); data.append(58)
                data.append(try serialize(member.value))
            }
            data.append(125); return data
        case .array(let values):
            var data = Data("[".utf8)
            for (index, value) in values.enumerated() {
                if index > 0 { data.append(44) }; data.append(try serialize(value))
            }
            data.append(93); return data
        case .string(let text): return try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        case .number(let text): return Data(text.utf8)
        case .bool(let value): return Data((value ? "true" : "false").utf8)
        case .null: return Data("null".utf8)
        }
    }

    static func value(_ data: Data) throws -> Value {
        guard !data.isEmpty, data.count <= maximumDocumentBytes, String(data: data, encoding: .utf8) != nil else {
            throw LegacyWatchedBitfieldMigrationEvidence.Failure.malformed("JSON source is not bounded UTF-8")
        }
        var parser = Parser(Array(data)); let value = try parser.value(depth: 0); parser.whitespace()
        guard parser.atEnd else { throw LegacyWatchedBitfieldMigrationEvidence.Failure.malformed("Trailing JSON data") }
        guard parser.credentialKeys.isEmpty else { throw LegacyWatchedBitfieldMigrationEvidence.Failure.malformed("Raw source is credential-bearing") }
        return value
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard case .object = try value(data) else { throw LegacyWatchedBitfieldMigrationEvidence.Failure.malformed("JSON root is not an object") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LegacyWatchedBitfieldMigrationEvidence.Failure.malformed("JSON root is not an object")
        }
        return object
    }

    private struct Parser {
        let bytes: [UInt8]; var index = 0; var credentialKeys = Set<String>()
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        var atEnd: Bool { index == bytes.count }
        mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func value(depth: Int) throws -> Value {
            guard depth <= 64 else { throw failure("JSON exceeds nesting limit") }; whitespace()
            guard index < bytes.count else { throw failure("Truncated JSON") }
            switch bytes[index] {
            case 123: return try object(depth: depth + 1)
            case 91: return try array(depth: depth + 1)
            case 34: return .string(try string())
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            case 45, 48...57: return .number(try number())
            default: throw failure("Malformed JSON token")
            }
        }
        mutating func object(depth: Int) throws -> Value {
            index += 1; whitespace(); var keys = Set<Data>(); var values: [Member] = []
            if take(125) { return .object(Object(members: values)) }
            while true {
                whitespace(); guard index < bytes.count, bytes[index] == 34 else { throw failure("Object key is missing") }
                let key = try string(); let keyBytes = Data(key.utf8); guard keys.insert(keyBytes).inserted else { throw failure("Duplicate JSON key") }
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                if ["auth", "authkey", "password", "apikey", "apikeys", "authorization", "bearer", "datakey", "token", "accesstoken", "refreshtoken", "authtoken", "clientsecret", "credentials"].contains(normalized)
                    || normalized.contains("secret") || normalized.contains("credential") { credentialKeys.insert(normalized) }
                whitespace(); guard take(58) else { throw failure("Object colon is missing") }
                values.append(Member(key: key, keyBytes: keyBytes, value: try value(depth: depth))); whitespace()
                if take(125) { return .object(Object(members: values)) }; guard take(44) else { throw failure("Object separator is missing") }
            }
        }
        mutating func array(depth: Int) throws -> Value {
            index += 1; whitespace(); var values: [Value] = []; if take(93) { return .array(values) }
            while true { values.append(try value(depth: depth)); whitespace(); if take(93) { return .array(values) }; guard take(44) else { throw failure("Array separator is missing") } }
        }
        mutating func string() throws -> String {
            guard take(34) else { throw failure("String is missing") }; var scalar = String.UnicodeScalarView()
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { return String(scalar) }
                guard byte >= 32 else { throw failure("Control byte in JSON string") }
                if byte != 92 {
                    let start = index - 1; while index < bytes.count, bytes[index] >= 128 { index += 1 }
                    guard let text = String(bytes: bytes[start..<index], encoding: .utf8) else { throw failure("Invalid UTF-8 string") }
                    scalar.append(contentsOf: text.unicodeScalars); continue
                }
                guard index < bytes.count else { throw failure("Truncated JSON escape") }; let escaped = bytes[index]; index += 1
                switch escaped {
                case 34, 92, 47: scalar.append(UnicodeScalar(escaped))
                case 98: scalar.append("\u{08}")
                case 102: scalar.append("\u{0c}")
                case 110: scalar.append("\n")
                case 114: scalar.append("\r")
                case 116: scalar.append("\t")
                case 117:
                    let first = try hex16(); var code = first
                    if (0xD800...0xDBFF).contains(first) {
                        guard take(92), take(117) else { throw failure("Unpaired JSON surrogate") }
                        let second = try hex16(); guard (0xDC00...0xDFFF).contains(second) else { throw failure("Unpaired JSON surrogate") }
                        code = 0x10000 + (first - 0xD800) * 0x400 + second - 0xDC00
                    } else if (0xDC00...0xDFFF).contains(first) { throw failure("Unpaired JSON surrogate") }
                    guard let value = UnicodeScalar(code) else { throw failure("Invalid JSON scalar") }; scalar.append(value)
                default: throw failure("Invalid JSON escape")
                }
            }
            throw failure("Unterminated JSON string")
        }
        mutating func number() throws -> String {
            let start = index; _ = take(45)
            guard index < bytes.count else { throw failure("Malformed JSON number") }
            if take(48) { guard index == bytes.count || !(48...57).contains(bytes[index]) else { throw failure("Leading zero JSON number") } }
            else { guard digit() else { throw failure("Malformed JSON number") }; while digit() {} }
            if take(46) { guard digit() else { throw failure("Malformed JSON number") }; while digit() {} }
            if take(101) || take(69) { _ = take(43) || take(45); guard digit() else { throw failure("Malformed JSON number") }; while digit() {} }
            guard index - start <= 64 else { throw failure("Lossy JSON number") }
            return String(bytes: bytes[start..<index], encoding: .ascii)!
        }
        mutating func literal(_ text: String) throws { for byte in text.utf8 { guard take(byte) else { throw failure("Malformed JSON literal") } } }
        mutating func hex16() throws -> UInt32 { guard index + 4 <= bytes.count else { throw failure("Truncated JSON escape") }; var value: UInt32 = 0; for _ in 0..<4 { let byte = bytes[index]; index += 1; let nibble: UInt32; switch byte { case 48...57: nibble = UInt32(byte - 48); case 65...70: nibble = UInt32(byte - 55); case 97...102: nibble = UInt32(byte - 87); default: throw failure("Invalid JSON hex") }; value = value * 16 + nibble }; return value }
        mutating func digit() -> Bool { guard index < bytes.count, (48...57).contains(bytes[index]) else { return false }; index += 1; return true }
        mutating func take(_ expected: UInt8) -> Bool { guard index < bytes.count, bytes[index] == expected else { return false }; index += 1; return true }
        func failure(_ message: String) -> LegacyWatchedBitfieldMigrationEvidence.Failure { .malformed(message) }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
private extension Collection { subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil } }
