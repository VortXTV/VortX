import Foundation
import CryptoKit

/// Pure admission and projection for an exported Nuvio/Xperience collection array.
/// Raw safe JSON survives alongside derived DTOs; this type performs no storage or network writes.
enum XperienceCollections {
    static let maximumBytes = 512 * 1024
    static let maximumDepth = 32
    static let maximumNodes = 50_000
    static let maximumCollections = 100
    static let maximumFolders = 1_000
    static let maximumSources = 5_000

    enum Failure: Error, Equatable, LocalizedError {
        case tooLarge, invalidJSON, duplicateMember, unpreservableNumber
        case invalidSchema, duplicateCollection, duplicateFolder, duplicateSource
        case emptyImport, staleRegister, invalidNamespace, unsafeHostValue
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "This collection export exceeds the import limit."
            case .invalidJSON: return "This is not a complete JSON collection export."
            case .duplicateMember: return "The export repeats a JSON field. Nothing was imported."
            case .unpreservableNumber: return "A number in this export cannot be preserved. Nothing was imported."
            case .invalidSchema: return "The collection export has an invalid field or value."
            case .duplicateCollection: return "The export repeats a collection ID. Nothing was imported."
            case .duplicateFolder: return "A collection repeats a folder ID. Nothing was imported."
            case .duplicateSource: return "A folder repeats a catalog source. Nothing was imported."
            case .emptyImport: return "The export contains no collections."
            case .staleRegister: return "This import changed. Open a fresh preview before replacing it."
            case .invalidNamespace: return "The saved import could not be read safely."
            case .unsafeHostValue: return "This export contains data that cannot be saved safely. Nothing was imported."
            }
        }
    }

    enum NoticeKind: Equatable, Sendable {
        case unsupportedViewMode, unsupportedTileShape, unsupportedProvider
        case modernAndLegacySourcesDiffer, animatedArtworkRetained
    }
    struct Notice: Equatable, Sendable {
        let kind: NoticeKind
        let collectionIndex: Int
        let folderIndex: Int?
        let sourceIndex: Int?
    }
    struct Source: Equatable, Sendable {
        let raw: VortxJSON
        let provider: String
        let addonID: String?
        let type: String?
        let catalogID: String?
        let genre: String?
        var isAddon: Bool { provider.lowercased() == "addon" }
        /// Deliberately not a URL. No collection-supplied base URL becomes a transport.
        var semanticIdentity: VortxJSON {
            guard isAddon else { return raw }
            return .array([.string("addon"), addonID.map(VortxJSON.string) ?? .null,
                type.map(VortxJSON.string) ?? .null, catalogID.map(VortxJSON.string) ?? .null,
                genre.map(VortxJSON.string) ?? .null])
        }
    }
    struct Folder: Equatable, Sendable {
        let raw: VortxJSON
        let id: String
        let title: String
        let coverImageURL: String?
        let heroBackdropURL: String?
        let titleLogoURL: String?
        let tileShape: String
        let hideTitle: Bool
        let sources: [Source]
    }
    struct Collection: Equatable, Sendable {
        let raw: VortxJSON
        let id: String
        let title: String
        let backdropImageURL: String?
        let pinToTop: Bool
        let showAllTab: Bool
        let viewMode: String
        let folders: [Folder]
    }
    struct Document: Equatable, Sendable {
        let raw: VortxJSON
        let collections: [Collection]
        let notices: [Notice]
        var fingerprint: String { XperienceCollections.digest(raw) }
    }

    static func parse(_ data: Data) throws -> Document {
        try project(parseCompleteRaw(data))
    }

    /// Complete bounded JSON admission, also used before profile-envelope projection.
    static func parseCompleteRaw(_ data: Data) throws -> VortxJSON {
        var parser = StrictParser(data: data)
        return try parser.parse()
    }

    /// Revalidate a stored value too. No malformed saved child is silently omitted.
    static func project(_ raw: VortxJSON) throws -> Document {
        try validateRawTree(raw)
        guard case .array(let items) = raw else { throw Failure.invalidSchema }
        guard !items.isEmpty else { throw Failure.emptyImport }
        guard items.count <= maximumCollections else { throw Failure.tooLarge }
        var seenCollections = Set<String>(), folderCount = 0, sourceCount = 0
        var collections: [Collection] = [], notices: [Notice] = []
        for (ci, item) in items.enumerated() {
            guard case .object(let fields) = item else { throw Failure.invalidSchema }
            let id = try identity(fields["id"]), collectionTitle = try title(fields["title"])
            guard seenCollections.insert(id).inserted else { throw Failure.duplicateCollection }
            let backdrop = try optionalString(fields["backdropImageUrl"])
            let pin = try boolean(fields["pinToTop"], default: false)
            let all = try boolean(fields["showAllTab"], default: true)
            _ = try boolean(fields["focusGlowEnabled"], default: true, allowNull: true)
            let mode = try optionalString(fields["viewMode"]) ?? "TABBED_GRID"
            if !["TABBED_GRID", "FOLLOW_LAYOUT", "ROWS"].contains(mode.uppercased()) {
                notices.append(.init(kind: .unsupportedViewMode, collectionIndex: ci, folderIndex: nil, sourceIndex: nil))
            }
            guard case .array(let rawFolders) = fields["folders"] else { throw Failure.invalidSchema }
            folderCount += rawFolders.count
            guard folderCount <= maximumFolders else { throw Failure.tooLarge }
            var seenFolders = Set<String>(), folders: [Folder] = []
            for (fi, rawFolder) in rawFolders.enumerated() {
                guard case .object(let f) = rawFolder else { throw Failure.invalidSchema }
                let fid = try identity(f["id"]), name = try title(f["title"])
                guard seenFolders.insert(fid).inserted else { throw Failure.duplicateFolder }
                let cover = try optionalString(f["coverImageUrl"])
                let hero = try optionalString(f["heroBackdropUrl"])
                let logo = try optionalString(f["titleLogoUrl"])
                _ = try optionalString(f["coverEmoji"])
                let gif = try optionalString(f["focusGifUrl"])
                let video = try optionalString(f["heroVideoUrl"])
                let focusVideo = try optionalString(f["focusVideoUrl"])
                let focusWebm = try optionalString(f["focusVideoWebmUrl"])
                _ = try boolean(f["focusGifEnabled"], default: true, allowNull: true)
                let shape = try optionalString(f["tileShape"]) ?? "SQUARE"
                let hide = try boolean(f["hideTitle"], default: false)
                if !["POSTER", "LANDSCAPE", "WIDE", "SQUARE"].contains(shape.uppercased()) {
                    notices.append(.init(kind: .unsupportedTileShape, collectionIndex: ci, folderIndex: fi, sourceIndex: nil))
                }
                if [gif, video, focusVideo, focusWebm].contains(where: { $0?.isEmpty == false }) {
                    notices.append(.init(kind: .animatedArtworkRetained, collectionIndex: ci, folderIndex: fi, sourceIndex: nil))
                }
                let modern = try sourceArray(f["sources"], legacy: false)
                let legacy = try sourceArray(f["catalogSources"], legacy: true)
                if !modern.isEmpty, !legacy.isEmpty,
                   modern.map({ digest($0.semanticIdentity) }) != legacy.map({ digest($0.semanticIdentity) }) {
                    notices.append(.init(kind: .modernAndLegacySourcesDiffer, collectionIndex: ci, folderIndex: fi, sourceIndex: nil))
                }
                let sources = modern.isEmpty ? legacy : modern
                sourceCount += modern.count + legacy.count
                guard sourceCount <= maximumSources else { throw Failure.tooLarge }
                for (si, source) in sources.enumerated() where !source.isAddon {
                    notices.append(.init(kind: .unsupportedProvider, collectionIndex: ci, folderIndex: fi, sourceIndex: si))
                }
                folders.append(.init(raw: rawFolder, id: fid, title: name, coverImageURL: cover,
                    heroBackdropURL: hero, titleLogoURL: logo, tileShape: shape, hideTitle: hide, sources: sources))
            }
            collections.append(.init(raw: item, id: id, title: collectionTitle, backdropImageURL: backdrop,
                pinToTop: pin, showAllTab: all, viewMode: mode, folders: folders))
        }
        return Document(raw: raw, collections: collections, notices: notices)
    }

    private static func sourceArray(_ value: VortxJSON?, legacy: Bool) throws -> [Source] {
        guard let value, value != .null else { return [] }
        guard case .array(let items) = value, items.count <= maximumSources else { throw Failure.invalidSchema }
        var result: [Source] = [], seen = Set<String>()
        for item in items {
            guard case .object(let source) = item else { throw Failure.invalidSchema }
            let provider = legacy ? "addon" : try optionalString(source["provider"]) ?? "addon"
            let addon = try optionalString(source["addonId"])
            let type = try optionalString(source["type"])
            let catalog = try optionalString(source["catalogId"])
            let genre = try optionalString(source["genre"])
            if provider.lowercased() == "addon" {
                _ = try identity(addon.map(VortxJSON.string))
                _ = try identity(type.map(VortxJSON.string))
                _ = try identity(catalog.map(VortxJSON.string))
            }
            let decoded = Source(raw: item, provider: provider, addonID: addon, type: type, catalogID: catalog, genre: genre)
            guard seen.insert(digest(decoded.semanticIdentity)).inserted else { throw Failure.duplicateSource }
            result.append(decoded)
        }
        return result
    }

    private static func identity(_ value: VortxJSON?) throws -> String {
        guard case .string(let string) = value, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              string.utf8.count <= 1024,
              !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.invalidSchema }
        return string
    }
    private static func title(_ value: VortxJSON?) throws -> String {
        guard case .string(let string) = value,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidSchema }
        return string
    }
    private static func optionalString(_ value: VortxJSON?) throws -> String? {
        guard let value, value != .null else { return nil }
        guard case .string(let string) = value else { throw Failure.invalidSchema }
        return string
    }
    private static func boolean(_ value: VortxJSON?, default fallback: Bool, allowNull: Bool = false) throws -> Bool {
        guard let value else { return fallback }
        if allowNull, value == .null { return fallback }
        guard case .bool(let boolean) = value else { throw Failure.invalidSchema }
        return boolean
    }
    static func canonicalData(_ value: VortxJSON) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    /// Stored values bypass the byte parser, so bound their entire tree, including unknown
    /// extensions, before canonical encoding or projection. The cheap byte count is a lower
    /// bound; the final canonical encoding enforces the exact persisted-byte ceiling.
    private static func validateRawTree(_ value: VortxJSON) throws {
        var nodes = 0, minimumBytes = 0
        func admit(_ count: Int) throws {
            guard count >= 0, count <= maximumBytes - minimumBytes else { throw Failure.tooLarge }
            minimumBytes += count
        }
        func walk(_ value: VortxJSON, depth: Int) throws {
            nodes += 1
            guard depth <= maximumDepth, nodes <= maximumNodes else { throw Failure.tooLarge }
            switch value {
            case .object(let fields):
                try admit(2)
                for (index, field) in fields.enumerated() {
                    try admit(index == 0 ? 3 : 4) // quotes, colon, optional separator
                    try admit(field.key.utf8.count)
                    try walk(field.value, depth: depth + 1)
                }
            case .array(let items):
                try admit(2)
                for (index, item) in items.enumerated() {
                    if index > 0 { try admit(1) }
                    try walk(item, depth: depth + 1)
                }
            case .string(let string):
                try admit(2)
                try admit(string.utf8.count)
            case .number(let number):
                guard number.isFinite else { throw Failure.unpreservableNumber }
                try admit(1)
            case .integer, .unsigned: try admit(1)
            case .null: try admit(4)
            case .bool(let flag): try admit(flag ? 4 : 5)
            }
        }
        try walk(value, depth: 0)
        guard try canonicalData(value).count <= maximumBytes else { throw Failure.tooLarge }
    }
    static func digest(_ value: VortxJSON) -> String {
        // Every admitted VortxJSON is finite and encodable; avoid ever fingerprinting an error string.
        guard let data = try? canonicalData(value) else { return "" }
        return digestBytes(data)
    }
    static func digestBytes(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A small complete JSON reader: duplicate members are rejected before dictionary conversion.
    /// Number lexemes must preserve their numeric value when represented and re-encoded by VortxJSON.
    private struct StrictParser {
        let data: Data
        private var bytes: [UInt8] = []
        private var cursor = 0
        private var nodes = 0
        init(data: Data) { self.data = data }
        mutating func parse() throws -> VortxJSON {
            guard !data.isEmpty, data.count <= maximumBytes else { throw Failure.tooLarge }
            guard String(data: data, encoding: .utf8) != nil else { throw Failure.invalidJSON }
            bytes = Array(data)
            let value = try read(depth: 0)
            whitespace()
            guard cursor == bytes.count else { throw Failure.invalidJSON }
            return value
        }
        private mutating func whitespace() {
            while cursor < bytes.count, [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 }
        }
        private mutating func consume(_ byte: UInt8) -> Bool {
            whitespace()
            guard cursor < bytes.count, bytes[cursor] == byte else { return false }
            cursor += 1
            return true
        }
        private mutating func read(depth: Int) throws -> VortxJSON {
            whitespace()
            nodes += 1
            guard depth <= maximumDepth, nodes <= maximumNodes else { throw Failure.tooLarge }
            guard cursor < bytes.count else { throw Failure.invalidJSON }
            switch bytes[cursor] {
            case 123:
                cursor += 1
                var object: [String: VortxJSON] = [:], seen = Set<String>()
                if consume(125) { return .object(object) }
                while true {
                    whitespace()
                    guard cursor < bytes.count, bytes[cursor] == 34 else { throw Failure.invalidJSON }
                    let key = try string()
                    guard seen.insert(key).inserted else { throw Failure.duplicateMember }
                    guard consume(58) else { throw Failure.invalidJSON }
                    object[key] = try read(depth: depth + 1)
                    if consume(125) { return .object(object) }
                    guard consume(44) else { throw Failure.invalidJSON }
                }
            case 91:
                cursor += 1
                var array: [VortxJSON] = []
                if consume(93) { return .array(array) }
                while true {
                    array.append(try read(depth: depth + 1))
                    if consume(93) { return .array(array) }
                    guard consume(44) else { throw Failure.invalidJSON }
                }
            case 34: return .string(try string())
            case 116: try literal(Array("true".utf8)); return .bool(true)
            case 102: try literal(Array("false".utf8)); return .bool(false)
            case 110: try literal(Array("null".utf8)); return .null
            case 45, 48...57:
                let start = cursor
                while cursor < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[cursor]) { cursor += 1 }
                let token = Data(bytes[start..<cursor])
                let before = String(decoding: token, as: UTF8.self)
                let normalizedBefore = try normalizedNumber(before)
                let value: VortxJSON
                do { value = try JSONDecoder().decode(VortxJSON.self, from: token) }
                catch { throw Failure.invalidJSON }
                switch value {
                case .integer, .unsigned: break
                case .number(let number): guard number.isFinite else { throw Failure.unpreservableNumber }
                default: throw Failure.invalidJSON
                }
                guard let after = String(data: try XperienceCollections.canonicalData(value), encoding: .utf8),
                      try normalizedBefore == normalizedNumber(after) else { throw Failure.unpreservableNumber }
                return value
            default: throw Failure.invalidJSON
            }
        }
        private mutating func literal(_ expected: [UInt8]) throws {
            guard cursor + expected.count <= bytes.count,
                  Array(bytes[cursor..<(cursor + expected.count)]) == expected else { throw Failure.invalidJSON }
            cursor += expected.count
        }
        private mutating func string() throws -> String {
            let start = cursor
            guard bytes[cursor] == 34 else { throw Failure.invalidJSON }
            cursor += 1
            while cursor < bytes.count {
                let byte = bytes[cursor]
                cursor += 1
                if byte == 92 {
                    guard cursor < bytes.count else { throw Failure.invalidJSON }
                    cursor += 1
                } else if byte == 34 {
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<cursor])) }
                    catch { throw Failure.invalidJSON }
                } else if byte < 32 { throw Failure.invalidJSON }
            }
            throw Failure.invalidJSON
        }
        private func normalizedNumber(_ input: String) throws -> String {
            var text = input.lowercased()
            let negative = text.hasPrefix("-")
            if negative { text.removeFirst() }
            let exponentParts = text.split(separator: "e", maxSplits: 1, omittingEmptySubsequences: false)
            let parsedExponent: Int? = exponentParts.count == 2 ? Int(exponentParts[1]) : Optional(0)
            guard let exponent = parsedExponent,
                  exponent >= -100_000, exponent <= 100_000 else { throw Failure.unpreservableNumber }
            let decimal = exponentParts[0].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let digits = decimal.map(String.init).joined()
            guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { throw Failure.invalidJSON }
            var power = exponent - (decimal.count == 2 ? decimal[1].count : 0)
            var first = digits.startIndex, end = digits.endIndex
            while first < end, digits[first] == "0" { first = digits.index(after: first) }
            if first == end { return "0" }
            while first < end {
                let last = digits.index(before: end)
                guard digits[last] == "0" else { break }
                end = last; power += 1
            }
            return (negative ? "-" : "") + String(digits[first..<end]) + "e" + String(power)
        }
    }
}
