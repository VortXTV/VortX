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
        /// Configured private transport. Keep internal; never include in user errors or logs.
        let canonicalTransport: String
        let catalogs: [Catalog]
        let transportDigest: String

        init(manifestID: String, transport: String, catalogs: [Catalog]) throws {
            guard !manifestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  var original = URLComponents(string: transport),
                  original.user == nil, original.password == nil,
                  original.fragment == nil,
                  ["http", "https"].contains(original.scheme?.lowercased() ?? ""),
                  original.host?.isEmpty == false,
                  original.percentEncodedPath.lowercased().hasSuffix("/manifest.json") else { throw Failure.invalidRegistry }
            if let port = original.port, !(1...65535).contains(port) { throw Failure.invalidRegistry }
            // URLComponents.path is decoded. Never round-trip it: an installed configuration
            // containing %2F is not the same resource as a literal path separator.
            original.scheme = original.scheme?.lowercased()
            original.host = original.host?.lowercased()
            guard let normalized = original.string else { throw Failure.invalidRegistry }
            var seen = Set<String>()
            for catalog in catalogs {
                let key = XperienceCollections.digest(.array([.string(catalog.type), .string(catalog.id)]))
                guard !catalog.type.isEmpty, !catalog.id.isEmpty, seen.insert(key).inserted else { throw Failure.invalidRegistry }
            }
            self.manifestID = manifestID
            self.canonicalTransport = normalized
            self.catalogs = catalogs
            self.transportDigest = XperienceCollections.digestBytes(Data(normalized.utf8))
        }
        var mapping: Mapping { .init(manifestID: manifestID, transportDigest: transportDigest) }
        var safeHost: String { URLComponents(string: canonicalTransport)?.host ?? "" }
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
              var components = URLComponents(string: candidate.canonicalTransport),
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
