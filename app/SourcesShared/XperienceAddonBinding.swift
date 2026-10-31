import Foundation

/// Pure source matching and URL projection. DNS/redirect checks belong to AddonURLGuard at fetch time.
enum XperienceAddonBinding {
    struct Catalog: Equatable, Sendable {
        let type: String
        let id: String
        let acceptsGenre: Bool
        let requiresGenre: Bool
        let supportsSkip: Bool
    }
    struct Mapping: Codable, Equatable, Sendable {
        struct Transport: Codable, Equatable, Sendable { let fingerprint: String }
        let manifestID: String
        let transport: Transport
        var transportDigest: String { transport.fingerprint }
        init(manifestID: String, transportDigest: String) {
            self.manifestID = manifestID
            self.transport = .init(fingerprint: transportDigest)
        }
    }
    struct Candidate: Equatable, Sendable {
        let manifestID: String
        /// Portable identity bytes, not a request endpoint. Unicode host spelling is opaque, not IDNA.
        /// Keep internal; never include in user errors or logs.
        let canonicalTransport: String
        /// Original installed descriptor remains the only request authority, independently of identity.
        fileprivate let configuredTransport: String
        let catalogs: [Catalog]
        let transportDigest: String

        init(manifestID: String, transport: String, catalogs: [Catalog]) throws {
            guard !manifestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidRegistry }
            let normalized = try XperienceAddonBinding.transportIdentity(transport)
            var seen = Set<String>()
            for catalog in catalogs {
                let key = XperienceCollections.digest(.array([.string(catalog.type), .string(catalog.id)]))
                guard !catalog.type.isEmpty, !catalog.id.isEmpty, seen.insert(key).inserted else { throw Failure.invalidRegistry }
            }
            self.manifestID = manifestID
            self.canonicalTransport = normalized
            self.configuredTransport = transport
            self.catalogs = catalogs
            self.transportDigest = XperienceCollections.digestBytes(Data(normalized.utf8))
        }
        var mapping: Mapping { .init(manifestID: manifestID, transportDigest: transportDigest) }
        var safeHost: String { URLComponents(string: configuredTransport)?.host ?? "" }
    }
    enum Resolution: Equatable, Sendable {
        case resolved(Candidate)
        case missing
        case ambiguous([Candidate])
        case mappingUnavailable
        case unsupportedProvider
        case unsupportedGenreConfiguration
        case invalidRegistry
    }
    enum Failure: Error, Equatable { case invalidRegistry, unavailableSource, invalidPath, unsupportedPagination }

    /// Configured-source identity, deliberately independent of platform URL repair/IDNA.
    /// ASCII scheme/host letters fold; valid escapes retain spelling; raw path/query UTF8 is escaped.
    /// Host Unicode and percent spellings remain opaque and distinct. This grants no fetch permission.
    private static func transportIdentity(_ raw: String) throws -> String {
        guard !raw.isEmpty,
              !raw.unicodeScalars.contains(where: { $0.value <= 32 || (127...159).contains($0.value) }) else { throw Failure.invalidRegistry }
        let outputCapacity = try transportIdentityCapacity(utf8Count: raw.utf8.count)
        let bytes = Array(raw.utf8)
        guard !bytes.contains(35), let colon = bytes.firstIndex(of: 58),
              colon + 2 < bytes.count, bytes[colon + 1] == 47, bytes[colon + 2] == 47 else { throw Failure.invalidRegistry }
        let scheme = folded(Array(bytes[..<colon]))
        guard scheme == Array("https".utf8) || scheme == Array("http".utf8),
              let slash = bytes[(colon + 3)...].firstIndex(of: 47) else { throw Failure.invalidRegistry }
        let authority = Array(bytes[(colon + 3)..<slash])
        guard !authority.isEmpty, !authority.contains(64) else { throw Failure.invalidRegistry }
        let question = bytes[slash...].firstIndex(of: 63) ?? bytes.count
        let path = Array(bytes[slash..<question])
        guard folded(path).suffix(14).elementsEqual("/manifest.json".utf8) else { throw Failure.invalidRegistry }
        let host: [UInt8]
        let port: [UInt8]?
        if authority.first == 91 {
            guard let close = authority.firstIndex(of: 93) else { throw Failure.invalidRegistry }
            host = Array(authority[...close])
            if close + 1 == authority.count { port = nil }
            else {
                guard authority[close + 1] == 58 else { throw Failure.invalidRegistry }
                port = Array(authority.dropFirst(close + 2))
            }
            try requireIPv6(Array(host.dropFirst().dropLast()))
        } else if let split = authority.firstIndex(of: 58) {
            host = Array(authority[..<split]); port = Array(authority.dropFirst(split + 1))
        } else { host = authority; port = nil }
        guard !host.isEmpty else { throw Failure.invalidRegistry }
        let normalizedHost: [UInt8]
        if host.first == 91 {
            // A scoped interface identifier can be case-sensitive; only the address is folded.
            let zone = host.firstIndex(of: 37) ?? host.count
            normalizedHost = folded(Array(host[..<zone])) + Array(host[zone...])
        }
        else { normalizedHost = try opaqueHost(host) }
        var normalized: [UInt8] = []
        normalized.reserveCapacity(outputCapacity)
        normalized += scheme + Array("://".utf8) + normalizedHost
        if let port, !port.isEmpty {
            var number = 0
            for digit in port {
                guard (48...57).contains(digit) else { throw Failure.invalidRegistry }
                number = number * 10 + Int(digit - 48)
                guard number <= 65535 else { throw Failure.invalidRegistry }
            }
            guard number > 0 else { throw Failure.invalidRegistry }
            normalized += Array((":" + String(number)).utf8)
        }
        normalized += try escapedComponent(path, query: false)
        if question < bytes.count {
            normalized.append(63)
            normalized += try escapedComponent(Array(bytes.dropFirst(question + 1)), query: true)
        }
        guard normalized.count <= outputCapacity else { throw Failure.invalidRegistry }
        return String(decoding: normalized, as: UTF8.self)
    }
    /// Common Int32 output-count representation, not a URL-policy or available-memory budget.
    /// Every original byte emits at most three identity bytes; no allocation occurs in this helper.
    static func transportIdentityCapacity(utf8Count: Int) throws -> Int {
        guard utf8Count >= 0, utf8Count <= Int(Int32.max) / 3 else { throw Failure.invalidRegistry }
        return utf8Count * 3
    }
    private static func folded(_ bytes: [UInt8]) -> [UInt8] { bytes.map { (65...90).contains($0) ? $0 + 32 : $0 } }
    private static func hex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) }
    private static let nameASCII = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=".utf8)
    private static let pathASCII = nameASCII.union(":@/".utf8)
    private static func opaqueHost(_ bytes: [UInt8]) throws -> [UInt8] {
        let text = String(decoding: bytes, as: UTF8.self)
        guard !text.unicodeScalars.contains(where: {
            let value = $0.value
            return value == 160 || value == 5760 || (8192...8202).contains(value) ||
                value == 8232 || value == 8233 || value == 8239 || value == 8287 || value == 12288
        }) else { throw Failure.invalidRegistry }
        var result: [UInt8] = []; var index = 0
        result.reserveCapacity(bytes.count)
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 37 {
                guard index + 2 < bytes.count, hex(bytes[index + 1]), hex(bytes[index + 2]) else { throw Failure.invalidRegistry }
                result += bytes[index...(index + 2)]; index += 3
            } else {
                guard byte >= 128 || nameASCII.contains(byte) else { throw Failure.invalidRegistry }
                result.append((65...90).contains(byte) ? byte + 32 : byte); index += 1
            }
        }
        return result
    }
    private static func escapedComponent(_ bytes: [UInt8], query: Bool) throws -> [UInt8] {
        let digits = Array("0123456789ABCDEF".utf8)
        var result: [UInt8] = []; var index = 0
        result.reserveCapacity(try transportIdentityCapacity(utf8Count: bytes.count))
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 37 {
                guard index + 2 < bytes.count, hex(bytes[index + 1]), hex(bytes[index + 2]) else { throw Failure.invalidRegistry }
                result += bytes[index...(index + 2)]; index += 3
            } else if byte >= 128 {
                result += [37, digits[Int(byte >> 4)], digits[Int(byte & 15)]]; index += 1
            } else {
                guard pathASCII.contains(byte) || (query && byte == 63) else { throw Failure.invalidRegistry }
                result.append(byte); index += 1
            }
        }
        return result
    }
    private static func requireIPv6(_ bytes: [UInt8]) throws {
        let percent = bytes.firstIndex(of: 37) ?? bytes.count
        if percent < bytes.count {
            guard percent + 3 < bytes.count, bytes[percent + 1] == 50, bytes[percent + 2] == 53,
                  bytes.dropFirst(percent + 3).allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || "-._~".utf8.contains($0) }) else { throw Failure.invalidRegistry }
        }
        let address = String(decoding: bytes[..<percent], as: UTF8.self)
        guard address.utf8.allSatisfy({ hex($0) || $0 == 58 || $0 == 46 }), address.contains(":"),
              !address.contains(":::"), address.components(separatedBy: "::").count <= 2,
              (!address.hasPrefix(":") || address.hasPrefix("::")),
              (!address.hasSuffix(":") || address.hasSuffix("::")) else { throw Failure.invalidRegistry }
        var groups = address.split(separator: ":", omittingEmptySubsequences: true)
        var units = groups.count
        if let last = groups.last, last.contains(".") {
            let octets = last.split(separator: ".", omittingEmptySubsequences: false)
            guard address.hasSuffix(String(last)), octets.count == 4, octets.allSatisfy({ part in
                (1...3).contains(part.utf8.count) && part.utf8.allSatisfy({ (48...57).contains($0) }) && (Int(part) ?? 256) <= 255
            }) else { throw Failure.invalidRegistry }
            groups.removeLast(); units += 1
        }
        guard groups.allSatisfy({ (1...4).contains($0.utf8.count) && $0.utf8.allSatisfy(hex) }),
              address.contains("::") ? units < 8 : (units == 8 && !address.hasPrefix(":") && !address.hasSuffix(":")) else { throw Failure.invalidRegistry }
    }

    static func key(for source: XperienceCollections.Source) -> String {
        XperienceCollections.digest(source.semanticIdentity)
    }
    /// Add-on protocol IDs and route values are byte identities, not localized display text.
    private static func exact(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }

    static func resolve(_ source: XperienceCollections.Source, installed: [Candidate], mapping: Mapping? = nil) -> Resolution {
        guard source.isAddon else { return .unsupportedProvider }
        guard let addon = source.addonID, let type = source.type, let id = source.catalogID else { return .missing }
        let matching = installed.filter { exact($0.manifestID, addon) && $0.catalogs.contains { exact($0.type, type) && exact($0.id, id) } }
        guard !matching.isEmpty else { return mapping == nil ? .missing : .mappingUnavailable }
        // Registry duplicates are not a reason to choose a first instance.
        guard Set(matching.map(\.transportDigest)).count == matching.count else { return .invalidRegistry }
        let chosen: Candidate
        if let mapping {
            guard exact(mapping.manifestID, addon),
                  let exact = matching.first(where: { $0.transportDigest == mapping.transportDigest }) else { return .mappingUnavailable }
            chosen = exact // first is safe here: uniqueness was checked, and this is an exact digest.
        } else {
            guard matching.count == 1 else { return .ambiguous(matching) }
            chosen = matching[0]
        }
        guard let catalog = chosen.catalogs.first(where: { exact($0.type, type) && exact($0.id, id) }),
              (source.genre == nil || catalog.acceptsGenre),
              (!catalog.requiresGenre || source.genre != nil) else { return .unsupportedGenreConfiguration }
        return .resolved(chosen)
    }

    /// Preserve configured query and original exact type/id/genre while encoding each resource component.
    /// A resulting URL still MUST pass AddonURLGuard's public-address and per-redirect policy.
    static func catalogURL(source: XperienceCollections.Source, candidate: Candidate, skip: Int? = nil) throws -> URL {
        guard case .resolved = resolve(source, installed: [candidate], mapping: candidate.mapping),
              let type = source.type, let id = source.catalogID,
              let catalog = candidate.catalogs.first(where: { exact($0.type, type) && exact($0.id, id) }),
              var components = URLComponents(string: candidate.configuredTransport),
              components.percentEncodedPath.lowercased().hasSuffix("/manifest.json") else { throw Failure.unavailableSource }
        if let skip, skip < 0 || !catalog.supportsSkip { throw Failure.unsupportedPagination }
        var path = String(components.percentEncodedPath.dropLast("manifest.json".count))
        path += "catalog/" + (try segment(type)) + "/" + (try segment(id))
        var extras: [String] = []
        if let genre = source.genre { extras.append("genre=" + (try segment(genre, permitEmpty: true))) }
        if let skip { extras.append("skip=" + String(skip)) }
        if !extras.isEmpty { path += "/" + extras.joined(separator: "&") }
        components.percentEncodedPath = path + ".json"
        guard let url = components.url else { throw Failure.invalidPath }
        return url
    }
    private static func segment(_ raw: String, permitEmpty: Bool = false) throws -> String {
        guard (permitEmpty || !raw.isEmpty), raw != ".", raw != "..",
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.invalidPath }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed) else { throw Failure.invalidPath }
        return encoded
    }
}

/// One proposed edit to one native profile field. The CoreBridge/facade adapter must additionally
/// hold the original captured account/profile/session authority through FIFO admission and checkpoint.
enum XperienceImportNamespace {
    struct Edit: Equatable, Sendable {
        let namespace: UUID
        let field: String
        let expectedRegister: VortxJSON?
        let value: VortxJSON
        func baselineMatches(_ currentRegister: VortxJSON?) -> Bool {
            switch (currentRegister, expectedRegister) {
            case (nil, nil): return true
            case (.some(let current), .some(let expected)):
                guard let currentBytes = try? XperienceCollections.canonicalData(current),
                      let expectedBytes = try? XperienceCollections.canonicalData(expected) else { return false }
                return currentBytes == expectedBytes
            default: return false
            }
        }
    }
    static func field(_ namespace: UUID) -> String { "xperience.import." + namespace.uuidString.lowercased() }

    static func append(document: XperienceCollections.Document, label: String, namespace: UUID = UUID(),
                       bindings: [String: XperienceAddonBinding.Mapping] = [:]) throws -> Edit {
        let value = try envelope(document: document, label: label, namespace: namespace, previous: nil, bindings: bindings)
        return .init(namespace: namespace, field: field(namespace), expectedRegister: nil, value: value)
    }
    static func replace(document: XperienceCollections.Document, label: String, namespace: UUID,
                        expectedRegister: VortxJSON, bindings: [String: XperienceAddonBinding.Mapping]) throws -> Edit {
        guard case .object(let register) = expectedRegister,
              Set(register.keys) == ["clock", "actor", "value"],
              validClock(register["clock"]),
              case .string(let actor) = register["actor"],
              UUID(uuidString: actor)?.uuidString.lowercased() == actor,
              case .object(let old) = register["value"],
              old["schemaVersion"] == .integer(1), old["importID"] == .string(namespace.uuidString.lowercased()) else {
            throw XperienceCollections.Failure.invalidNamespace
        }
        let value = try envelope(document: document, label: label, namespace: namespace, previous: old, bindings: bindings)
        return .init(namespace: namespace, field: field(namespace), expectedRegister: expectedRegister, value: value)
    }

    private static func validClock(_ value: VortxJSON?) -> Bool {
        switch value {
        case .integer(let clock): return (0...9_007_199_254_740_991).contains(clock)
        case .unsigned(let clock): return clock <= 9_007_199_254_740_991
        default: return false
        }
    }

    private static func envelope(document: XperienceCollections.Document, label: String, namespace: UUID,
                                 previous: [String: VortxJSON]?, bindings: [String: XperienceAddonBinding.Mapping]) throws -> VortxJSON {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.utf8.count <= 256 else {
            throw XperienceCollections.Failure.invalidSchema
        }
        let revalidated = try XperienceCollections.project(document.raw)
        let supportedKeys = Set(revalidated.collections.flatMap(\.folders).flatMap(\.sources)
            .filter(\.isAddon).map { XperienceAddonBinding.key(for: $0) })
        guard bindings.keys.allSatisfy({ supportedKeys.contains($0) }) else { throw XperienceCollections.Failure.invalidSchema }
        var stored = previous ?? [:]
        stored["schemaVersion"] = .integer(1)
        stored["importID"] = .string(namespace.uuidString.lowercased())
        stored["label"] = .string(label)
        stored["fingerprint"] = .string(revalidated.fingerprint)
        stored["collections"] = revalidated.raw
        stored["bindings"] = .object(bindings.mapValues {
            .object(["manifestID": .string($0.manifestID), "transport": .object(["fingerprint": .string($0.transportDigest)])])
        })
        return .object(stored)
    }
}
