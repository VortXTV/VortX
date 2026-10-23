// Synthetic profile-export contract tests. All endpoints and keys are test material.
// Run with scripts/test-xperience-export-contracts.sh; no account or credential is provisioned.
import Combine
import Foundation

@main @MainActor enum XperienceExportConnectorTests {
    enum Failure: Error { case assertion(String) }
    static var checks = 0

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.assertion(message) }
        checks += 1
        print("PASS \(message)")
    }

    nonisolated private static let profileID = "11111111-1111-4111-8111-111111111111"
    nonisolated private static let collectionID = "22222222-2222-4222-8222-222222222222"
    private static let sourceID = "33333333-3333-4333-8333-333333333333"
    // Deliberately recognisable test material, never a real key.
    nonisolated private static let exampleKey = "synthetic-example-key"

    static func endpoint(_ id: String = profileID, key: String = exampleKey) throws -> XperienceExportEndpoint {
        try XperienceExportEndpoint("https://xperience-app.com/profile-export/\(id).json?key=\(key)")
    }

    static func requireFailure<T: Error & Equatable>(_ expected: T,
                                                      _ operation: () throws -> Void,
                                                      _ message: String) throws {
        do {
            try operation()
            throw Failure.assertion("expected rejection: \(message)")
        } catch let error as T {
            try require(error == expected, message)
        }
    }

    static func requireAsyncFailure(_ operation: () async throws -> Void,
                                    _ message: String,
                                    accepts: (Error) -> Bool) async throws {
        do {
            try await operation()
            throw Failure.assertion("expected async rejection: \(message)")
        } catch let error as Failure {
            throw error
        } catch {
            try require(accepts(error), message)
        }
    }

    // MARK: URL and credential boundaries

    static func endpointAdmission() throws {
        _ = try endpoint()
        let invalid = [
            "https://xperience-app.com/manifest/\(profileID)/manifest.json?key=\(exampleKey)",
            "https://127.0.0.1/profile-export/\(profileID).json?key=\(exampleKey)",
            "https://xperience-app.com/profile-export/\(profileID).json?key=\(exampleKey)&extra=1",
            "https://xperience-app.com/profile-export/\(profileID).json?key=\(exampleKey)&%65xtra=1",
            "https://xperience-app.com/profile-export/\(profileID).json?key=\(exampleKey)#fragment",
            "http://xperience-app.com/profile-export/\(profileID).json?key=\(exampleKey)",
            "https://xperience-app.com/profile-export/11111111-1111-4111-8111-11111111111A.json?key=\(exampleKey)",
            "https://xperience-app.com/profile-export/%2F\(profileID).json?key=\(exampleKey)",
            "https://xperience-app.com/profile-export/\(profileID).json"
        ]
        for text in invalid {
            try requireFailure(XperienceExportFailure.invalidURL, { _ = try XperienceExportEndpoint(text) },
                               "rejects non-official/private/extra-query/encoded-separator URL \(text)")
        }
        for opaqueValue in ["synthetic%26extra=1", "synthetic/extra"] {
            _ = try XperienceExportEndpoint(
                "https://xperience-app.com/profile-export/\(profileID).json?key=\(opaqueValue)")
        }
        try require(true, "single opaque export-key values may contain encoded separators")
        let value = try endpoint()
        try require(value.description == "<Xperience profile export>",
                     "endpoint description does not echo the export key")
        try require(value.debugDescription == value.description,
                     "endpoint debug description is equally redacted")
        try require(!value.description.contains(exampleKey),
                     "endpoint debug output contains no synthetic key")
    }

    final class CredentialBackend: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: CredentialDurableReadResult] = [:]
        var failReads = false
        var uncertifiedMarker = false
        var writes = 0
        private var armFinalReadFailure = false
        private var armAfterWrite = false
        private var failNextRead = false

        /// Arms a fault after the next successful write certification: the vault's internal
        /// readback still succeeds, while the controller's final receipt read fails.
        func failFinalReadAfterWriteCertification() {
            lock.lock(); defer { lock.unlock() }
            armFinalReadFailure = true
        }

        func store() -> XperienceExportCredentialStore {
            XperienceExportCredentialStore(
                read: { [self] slot in
                    self.lock.lock(); defer { self.lock.unlock() }
                    if self.failReads || self.uncertifiedMarker || self.failNextRead {
                        self.failNextRead = false
                        return .failure
                    }
                    let result = self.values[slot] ?? .missing
                    if self.armAfterWrite {
                        // This read is the certified readback inside vault.save. Fault only the
                        // following controller receipt read.
                        self.armAfterWrite = false
                        self.failNextRead = true
                    }
                    return result
                },
                write: { [self] value, slot in
                    self.lock.lock(); defer { self.lock.unlock() }
                    self.writes += 1
                    if self.failReads { return .failure }
                    if let value { self.values[slot] = .value(value) }
                    else { self.values.removeValue(forKey: slot) }
                    // A newly certified explicit reconnect write clears the uncertain marker;
                    // no prior/unknown URL is ever promoted into the value slot.
                    self.uncertifiedMarker = false
                    if self.armFinalReadFailure {
                        self.armFinalReadFailure = false
                        self.armAfterWrite = true
                    }
                    return .success
                })
        }

        func rawValue(for slot: String) -> CredentialDurableReadResult? {
            lock.lock(); defer { lock.unlock() }
            return values[slot]
        }
    }

    static func ownerScopedCredentials() throws {
        let backend = CredentialBackend()
        let authority = CredentialScopeRegistry(initialScope: .signedOutDevice)
        let vault = XperienceExportCredentialVault(store: backend.store(), authority: authority)
        let owner = authority.capture()
        let profile = UUID(uuidString: profileID)!
        let collection = UUID(uuidString: collectionID)!
        let source = UUID(uuidString: sourceID)!
        let record = XperienceExportCredentialVault.Record(endpoint: try endpoint(),
                                                            sourceID: source.uuidString.lowercased(),
                                                            sessionID: UUID())
        let slot = XperienceExportCredentialVault.slot(owner: owner, profileID: profile,
                                                       collectionID: collection.uuidString.lowercased())
        try vault.save(record, replacing: nil, owner: owner, profileID: profile,
                       collectionID: collection.uuidString.lowercased())
        let readBack = try vault.read(owner: owner, profileID: profile,
                                      collectionID: collection.uuidString.lowercased())
        try require(readBack == record,
                     "credential vault returns the exact certified owner/profile/collection record")
        if case .value(let raw)? = backend.rawValue(for: slot) {
            try require(raw.contains(exampleKey),
                         "synthetic URL is present only in the injected durable fixture")
            try require(!record.debugDescription.contains(exampleKey),
                         "credential record debug output redacts the URL key")
        } else {
            throw Failure.assertion("credential fixture did not receive a durable value")
        }

        backend.failReads = true
        try requireFailure(XperienceExportFailure.credentialUnavailable, {
            try vault.save(record, replacing: record, owner: owner, profileID: profile,
                           collectionID: collection.uuidString.lowercased())
        }, "certified credential readback failure is not treated as success")
        backend.failReads = false
        try requireFailure(XperienceExportFailure.staleContext, {
            try vault.save(record, replacing: nil, owner: owner, profileID: profile,
                           collectionID: collection.uuidString.lowercased())
        }, "credential CAS rejects an unexpected prior record")
        try require(backend.writes == 1,
                    "failed credential certification does not publish another durable value")
    }

    static func explicitRepairTickets() throws {
        let authority = CredentialScopeRegistry(initialScope: .signedOutDevice)
        let backend = CredentialBackend()
        backend.uncertifiedMarker = true
        let vault = XperienceExportCredentialVault(store: backend.store(), authority: authority)
        let owner = authority.capture()
        let profile = UUID(uuidString: profileID)!
        let collection = UUID(uuidString: collectionID)!
        let slot = XperienceExportCredentialVault.slot(owner: owner, profileID: profile,
                                                       collectionID: collection.uuidString.lowercased())
        try require(backend.rawValue(for: slot) == nil,
                    "uncertified marker has no recoverable URL value")
        let repair = try vault.prepareRepair(owner: owner, profileID: profile,
                                             collectionID: collection.uuidString.lowercased())
        let repairMatches = try vault.matches(nil, owner: owner, profileID: profile,
                                              collectionID: collection.uuidString.lowercased(), repair: repair)
        try require(repairMatches, "repair ticket matches only the same uncertain owner slot")
        let record = XperienceExportCredentialVault.Record(endpoint: try endpoint(),
                                                            sourceID: sourceID, sessionID: UUID())
        try vault.save(record, replacing: nil, owner: owner, profileID: profile,
                       collectionID: collection.uuidString.lowercased(), repair: repair)
        let repaired = try vault.read(owner: owner, profileID: profile,
                                      collectionID: collection.uuidString.lowercased())
        try require(repaired == record && backend.uncertifiedMarker == false,
                    "explicit repair clears the uncertified marker only after new write/readback")
        if case .value(let raw)? = backend.rawValue(for: slot) {
            try require(raw.contains(exampleKey), "repair stores only the newly entered synthetic URL")
        } else {
            throw Failure.assertion("certified repair did not publish its value")
        }

        let secondBackend = CredentialBackend()
        secondBackend.uncertifiedMarker = true
        let firstVault = XperienceExportCredentialVault(store: secondBackend.store(), authority: authority)
        let secondVault = XperienceExportCredentialVault(store: secondBackend.store(), authority: authority)
        let firstTicket = try firstVault.prepareRepair(owner: owner, profileID: profile,
                                                       collectionID: collection.uuidString.lowercased())
        try requireFailure(XperienceExportFailure.credentialUnavailable, {
            try secondVault.save(record, replacing: nil, owner: owner, profileID: profile,
                                 collectionID: collection.uuidString.lowercased())
        }, "a failed mutation attempt remains uncertified but advances the shared slot epoch")
        try requireFailure(XperienceExportFailure.staleContext, {
            _ = try firstVault.matches(nil, owner: owner, profileID: profile,
                                       collectionID: collection.uuidString.lowercased(), repair: firstTicket)
        }, "a second vault mutation invalidates the first repair ticket")

        let (linkedCollection, linkedSession) = try sessionFixture(linked: true)
        let routeFixture = ExportStoreFixture(session: linkedSession)
        let routeBackend = CredentialBackend(); routeBackend.uncertifiedMarker = true
        let routeVault = XperienceExportCredentialVault(store: routeBackend.store(), authority: authority)
        let routeController = XperienceCurationExportController(
            store: routeFixture, vault: routeVault, authority: authority,
            transport: { _ in Data() })
        try requireFailure(XperienceExportFailure.credentialUnavailable, {
            _ = try routeController.beginLink(linkedCollection)
        }, "ordinary Link cannot capture an uncertified repair ticket")
        routeFixture.current = true
        try requireFailure(XperienceExportFailure.credentialUnavailable, {
            _ = try routeController.beginRefresh(linkedCollection)
        }, "ordinary Refresh cannot capture an uncertified repair ticket")
        routeFixture.current = true
        _ = try routeController.beginReconnect(linkedCollection)
        try require(routeController.phase == .idle,
                    "explicit Reconnect is the only controller path that captures repair")
    }

    // MARK: Whole-envelope admission

    static func collectionValue(_ id: String = collectionID, folderCount: Int = 0) -> VortxJSON {
        let folders = (0..<folderCount).map { index in
            VortxJSON.object([
                "id": .string("folder-\(index)"), "title": .string("Folder \(index)"),
                "catalogSources": .array([])
            ])
        }
        return .object([
            "id": .string(id), "title": .string("Synthetic collection"),
            "viewMode": .string("TABBED_GRID"), "folders": .array(folders)
        ])
    }

    static func envelope(_ collections: VortxJSON,
                         version: VortxJSON = .integer(1),
                         configExtras: [String: VortxJSON] = [:]) -> VortxJSON {
        var config = configExtras
        config["collections"] = collections
        return .object([
            "exportType": .string("xperienceProfile"), "exportVersion": version,
            "name": .string("Synthetic profile"), "config": .object(config),
            "ignoredEnvelopeExtension": .object(["privatePrompt": .string("never persist")])
        ])
    }

    static func data(_ value: VortxJSON) throws -> Data {
        try XperienceCollections.canonicalData(value)
    }

    static func envelopeAdmission() throws {
        let parsed = try XperienceProfileExportAdmission.parse(
            data(envelope(.array([collectionValue()]),
                          configExtras: ["unknownFutureConfig": .string("retained only as untrusted input")]))
        )
        try require(parsed.name == "Synthetic profile" && parsed.collections.collections.count == 1,
                     "whole profile envelope admits only the documented export projection")
        try require(parsed.untrustedConfig["unknownFutureConfig"] == .string("retained only as untrusted input"),
                     "unknown config fields remain preview-only raw input")

        try requireFailure(XperienceProfileExportAdmission.Failure.unsupportedVersion, {
            _ = try XperienceProfileExportAdmission.parse(data(envelope(.array([collectionValue()]),
                                                                        version: .integer(99))))
        }, "future export version is rejected before projection")

        let duplicate = Data("{\"exportType\":\"xperienceProfile\",\"exportVersion\":1,\"name\":\"Synthetic\",\"config\":{\"collections\":[],\"collections\":[]}}".utf8)
        do {
            _ = try XperienceProfileExportAdmission.parse(duplicate)
            throw Failure.assertion("duplicate ignored/config member was admitted")
        } catch let failure as XperienceCollections.Failure {
            try require(failure == .duplicateMember,
                        "duplicate member in ignored envelope/config data is rejected")
        }

        let oversize = Data(repeating: 0x20, count: XperienceCollections.maximumBytes + 1)
        do {
            _ = try XperienceProfileExportAdmission.parse(oversize)
            throw Failure.assertion("oversize profile was admitted")
        } catch let failure as XperienceCollections.Failure {
            try require(failure == .tooLarge, "advertised/whole-envelope byte bound rejects oversize input")
        }
    }

    // MARK: Pure source matching and curation preservation

    static func candidate(transport: String = "https://addon.example/manifest.json") throws -> XperienceAddonBinding.Candidate {
        try XperienceAddonBinding.Candidate(
            manifestID: "addon.example",
            transport: transport,
            catalogs: [.init(type: "movie", id: "catalog", acceptsGenre: true,
                             requiresGenre: false, supportsSkip: true)])
    }

    static func mappedProjection(sourceProvider: String = "addon") throws
        -> XperienceProfileExportAdmission.Projection {
        let source: VortxJSON = .object([
            "provider": .string(sourceProvider), "addonId": .string("addon.example"),
            "type": .string("movie"), "catalogId": .string("catalog")
        ])
        let folder: VortxJSON = .object([
            "id": .string("upstream-folder"), "title": .string("Upstream folder"),
            "tileShape": .string("POSTER"), "sources": .array([source])
        ])
        let collection: VortxJSON = .object([
            "id": .string(collectionID), "title": .string("Mapped collection"),
            "viewMode": .string("TABBED_GRID"), "folders": .array([folder])
        ])
        return try XperienceProfileExportAdmission.parse(data(envelope(.array([collection]))) )
    }

    static func mappedCollectionValue() -> VortxJSON {
        let source: VortxJSON = .object([
            "provider": .string("addon"), "addonId": .string("addon.example"),
            "type": .string("movie"), "catalogId": .string("catalog")
        ])
        let folder: VortxJSON = .object([
            "id": .string("upstream-folder"), "title": .string("Upstream folder"),
            "tileShape": .string("POSTER"), "sources": .array([source])
        ])
        return .object([
            "id": .string(collectionID), "title": .string("Mapped collection"),
            "viewMode": .string("TABBED_GRID"), "folders": .array([folder])
        ])
    }

    static func legacyDocument() throws -> CurationDocument {
        let legacyID = "44444444-4444-4444-8444-444444444444"
        let collection = SmartCollection(id: legacyID, name: "Legacy rules",
                                         rules: SmartCollectionRules(), home: true, createdAt: 1)
        let legacyValue: VortxJSON = .object([
            "id": .string(legacyID), "name": .string("Legacy rules"),
            "home": .bool(true), "createdAt": .number(1),
            "rules": .object(["type": .string("all")])
        ])
        let initial = try CurationDocument.make(for: collection, legacyValue: legacyValue)
        // This tombstone represents an owner edit made before a rich refresh.
        return try initial.removingFolder("rules")
    }

    static func unknownRichDocument() throws -> CurationDocument {
        let legacyID = "44444444-4444-4444-8444-444444444444"
        let collection = SmartCollection(id: legacyID, name: "Legacy rules",
                                         rules: SmartCollectionRules(), home: true, createdAt: 1)
        let legacyValue: VortxJSON = .object([
            "id": .string(legacyID), "name": .string("Legacy rules"),
            "home": .bool(true), "createdAt": .number(1),
            "rules": .object(["type": .string("all")])
        ])
        let initial = try CurationDocument.make(for: collection, legacyValue: legacyValue)
        let source: VortxJSON = .object([
            "provider": .string("addon"), "addonId": .string("addon.example"),
            "type": .string("movie"), "catalogId": .string("catalog")
        ])
        let parsedSource = try XperienceCollections.project(.array([.object([
            "id": .string(collectionID), "title": .string("Mapped collection"),
            "folders": .array([.object([
                "id": .string("upstream-folder"), "title": .string("Upstream folder"),
                "catalogSources": .array([source])
            ])])
        ])])).collections[0].folders[0].sources[0]
        let sourceKey = XperienceAddonBinding.key(for: parsedSource)
        guard case .object(var fields) = initial.raw,
              case .object(var base) = fields["base"],
              var folders = base["folders"]?.array else { throw Failure.assertion("bad document fixture") }
        let oldFolder: VortxJSON = .object([
            "id": .string("upstream-folder"), "name": .string("Old upstream name"),
            "xperienceSourceID": .string(sourceID),
            "sources": .array([.object([
                "id": .string(sourceKey), "type": .string("addonCatalog"),
                "manifestID": .string("addon.example"), "mediaType": .string("movie"),
                "catalogID": .string("catalog"), "futureSourceLeaf": .string("keep")
            ])]),
            "presentation": .object(["layout": .string("tabs"), "futureFolderLeaf": .string("keep")]),
            "artwork": .object(["futureArtworkLeaf": .string("keep")]),
            "futureFolderLeaf": .string("keep")
        ])
        folders.append(oldFolder)
        base["folders"] = .array(folders)
        base["futureBaseLeaf"] = .string("keep")
        base["presentation"] = .object(["futurePresentationLeaf": .string("keep")])
        base["artwork"] = .object([
            "cover": .string("https://art.example/base-cover.jpg"),
            "logo": .string("https://art.example/base-logo.png"),
            "futureBaseArtworkLeaf": .string("keep")
        ])
        fields["base"] = .object(base)
        let rich = try CurationDocument(raw: .object(fields))
        return try rich.attaching(base: rich.raw["base"]!, provider: XperienceCurationExportMapper.provider,
                                  sourceID: sourceID, revision: "old-revision", upstreamCollectionID: collectionID)
    }

    static func mapperBoundaries() throws {
        let projection = try mappedProjection()
        let current = try legacyDocument()
        let linked = try XperienceCurationExportMapper.map(
            projection, upstreamCollectionID: collectionID, sourceID: sourceID,
            into: current, installed: [try candidate()])
        try require(linked.raw["overrides"]?["removedFolderIDs"]?.array?.contains(.string("rules")) == true,
                    "mapper preserves legacy local folder tombstones")
        try require(linked.raw["base"]?["folders"]?.array?.contains(where: {
            $0["xperienceSourceID"] == .string(sourceID)
        }) == true, "mapper adds only the selected Xperience upstream slice")

        try requireFailure(XperienceExportFailure.unsupportedSource, {
            _ = try XperienceCurationExportMapper.map(try mappedProjection(sourceProvider: "foreign"),
                                                       upstreamCollectionID: collectionID, sourceID: sourceID,
                                                       into: current, installed: [try candidate()])
        }, "unsupported provider is not coerced into an addon source")
        try requireFailure(XperienceExportFailure.unsupportedSource, {
            _ = try XperienceCurationExportMapper.map(projection,
                                                       upstreamCollectionID: collectionID, sourceID: sourceID,
                                                       into: current, installed: [])
        }, "missing installed addon binding rejects the complete selection")
        try requireFailure(XperienceExportFailure.unsupportedSource, {
            let second = try candidate(transport: "https://other.example/manifest.json")
            _ = try XperienceCurationExportMapper.map(projection,
                                                       upstreamCollectionID: collectionID, sourceID: sourceID,
                                                       into: current, installed: [try candidate(), second])
        }, "ambiguous installed addon binding rejects instead of choosing first")

        let unknown = try unknownRichDocument()
        let refreshed = try XperienceCurationExportMapper.map(projection,
                                                               upstreamCollectionID: collectionID,
                                                               sourceID: sourceID, into: unknown,
                                                               installed: [try candidate()])
        try require(refreshed.raw["base"]?["futureBaseLeaf"] == .string("keep") &&
                    refreshed.raw["base"]?["presentation"]?["futurePresentationLeaf"] == .string("keep") &&
                    refreshed.raw["base"]?["artwork"]?["futureBaseArtworkLeaf"] == .string("keep") &&
                    refreshed.raw["base"]?["artwork"]?["cover"] == .string("https://art.example/base-cover.jpg") &&
                    refreshed.raw["base"]?["artwork"]?["logo"] == .string("https://art.example/base-logo.png"),
                    "refresh preserves unknown base/presentation/artwork and native cover/logo leaves")
        try require(refreshed.raw["base"]?["folders"]?.array?.contains(where: {
            $0["futureFolderLeaf"] == .string("keep") &&
            $0["presentation"]?["futureFolderLeaf"] == .string("keep") &&
            $0["sources"]?.array?.first?["futureSourceLeaf"] == .string("keep")
        }) == true, "refresh merges unknown folder and source leaves")

        let missing = try XperienceProfileExportAdmission.parse(data(envelope(
            .array([collectionValue("99999999-9999-4999-8999-999999999999")]))))
        try requireFailure(XperienceExportFailure.missingCollection, {
            _ = try XperienceCurationExportMapper.map(missing,
                                                       upstreamCollectionID: collectionID, sourceID: sourceID,
                                                       into: current, installed: [try candidate()])
        }, "selected upstream collection ID must exist in the admitted profile")
    }

    // MARK: HTTP redirect and byte-bound fixtures

    final class ExportURLProtocol: URLProtocol {
        enum Mode: Equatable { case redirect, fixedLengthTooLarge, chunkedTooLarge }
        static let lock = NSLock()
        static var mode: Mode = .redirect
        static var requests = 0
        static var body = Data()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock(); Self.requests += 1; let mode = Self.mode; let body = Self.body; Self.lock.unlock()
            guard let url = request.url else { client?.urlProtocolDidFinishLoading(self); return }
            let status = mode == .redirect ? 302 : 200
            var headers = ["Content-Type": "application/json"]
            if mode == .fixedLengthTooLarge {
                headers["Content-Length"] = String(XperienceCollections.maximumBytes + 1)
            }
            if mode == .redirect { headers["Location"] = url.absoluteString + "&redirected=1" }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: headers)!
            if mode == .redirect {
                // Exercise URLSession's redirect delegate path; DenyRedirects must answer nil and
                // no second URLProtocol instance may be created for the Location target.
                let redirected = URLRequest(url: URL(string: headers["Location"]!)!)
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
        static func configure(_ next: Mode, body nextBody: Data) {
            lock.withLock { requests = 0; mode = next; body = nextBody }
        }
        static func requestCount() -> Int { lock.withLock { requests } }
    }

    static func httpBoundaries() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExportURLProtocol.self]
        ExportURLProtocol.configure(.redirect, body: Data())
        do {
            _ = try await XperienceExportHTTP.load(try endpoint(), configuration: configuration,
                                                    addressCheck: { _ in true })
            throw Failure.assertion("redirect response was accepted")
        } catch let failure as XperienceExportFailure {
            try require(failure == .invalidResponse || failure == .unavailable,
                        "302 is rejected without following Location")
        }
        let redirectCount = ExportURLProtocol.requestCount()
        try require(redirectCount == 1, "302 fixture receives exactly one request; no second target request")

        ExportURLProtocol.configure(.fixedLengthTooLarge, body: Data([0x7B]))
        do {
            _ = try await XperienceExportHTTP.load(try endpoint(), configuration: configuration,
                                                    addressCheck: { _ in true })
            throw Failure.assertion("advertised oversized response was accepted")
        } catch let failure as XperienceExportFailure {
            try require(failure == .tooLarge, "advertised Content-Length is bounded before body admission")
        }

        ExportURLProtocol.configure(.chunkedTooLarge, body: Data(repeating: 0x20, count: XperienceCollections.maximumBytes + 1))
        do {
            _ = try await XperienceExportHTTP.load(try endpoint(), configuration: configuration,
                                                    addressCheck: { _ in true })
            throw Failure.assertion("chunked oversized response was accepted")
        } catch let failure as XperienceExportFailure {
            try require(failure == .tooLarge, "chunked response is bounded by streamed byte count")
        }
    }

    // MARK: Controller gesture, reconnect and CAS fixtures

    @MainActor final class ExportStoreFixture: XperienceCurationExportStore {
        let session: CurationEditSession
        var current = true
        var contextCurrent = true
        var saveError: Error?
        var saved: CurationDocument?
        var saves = 0
        var retirements = 0
        var invalidateContextAfterSave = false
        var afterSave: (() -> Void)?
        let installed: [XperienceAddonBinding.Candidate]

        init(session: CurationEditSession, installed: [XperienceAddonBinding.Candidate] = []) {
            self.session = session; self.installed = installed
        }
        func captureXperienceExportEdit(_ collection: SmartCollection) throws -> CurationEditSession { session }
        func xperienceExportEditIsCurrent(_ session: CurationEditSession) -> Bool { current }
        func xperienceExportContextIsCurrent(_ session: CurationEditSession) -> Bool { contextCurrent }
        func xperienceExportCandidates(_ session: CurationEditSession) throws -> [XperienceAddonBinding.Candidate] {
            installed
        }
        func saveXperienceExport(_ document: CurationDocument, session: CurationEditSession) async throws {
            saves += 1
            if let saveError { throw saveError }
            saved = document
            if invalidateContextAfterSave { contextCurrent = false }
            afterSave?()
        }
        func retireXperienceExportEdit(_ session: CurationEditSession) { retirements += 1; current = false }
    }

    /// A deterministic in-flight transport gate. It signals only after the injected transport
    /// starts, so the context publisher invalidates a real suspended fetch rather than a task that
    /// has not begun executing yet.
    final class TransportGate: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var released: Data?
        private var releaseWaiters: [CheckedContinuation<Data, Never>] = []

        func markStarted() {
            lock.lock()
            started = true
            let waiters = startWaiters; startWaiters.removeAll()
            lock.unlock()
            waiters.forEach { $0.resume() }
        }

        func waitUntilStarted() async {
            if lock.withLock({ started }) { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if started {
                    lock.unlock(); continuation.resume()
                } else {
                    startWaiters.append(continuation); lock.unlock()
                }
            }
        }

        func release(_ data: Data) {
            lock.lock()
            if releaseWaiters.isEmpty { released = data; lock.unlock(); return }
            let waiters = releaseWaiters; releaseWaiters.removeAll(); lock.unlock()
            waiters.forEach { $0.resume(returning: data) }
        }

        func waitForRelease() async -> Data {
            let ready: Data? = lock.withLock {
                defer { released = nil }
                return released
            }
            if let ready { return ready }
            return await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                lock.lock()
                if let released {
                    self.released = nil; lock.unlock(); continuation.resume(returning: released)
                } else {
                    releaseWaiters.append(continuation); lock.unlock()
                }
            }
        }
    }

    final class TransportProbe: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        let payload: Data
        init(payload: Data) { self.payload = payload }
        func load() -> Data {
            lock.lock(); calls += 1; lock.unlock()
            return payload
        }
        func callCount() -> Int {
            lock.lock(); defer { lock.unlock() }
            return calls
        }
    }

    static func sessionFrom(_ baseline: CurationEditSession,
                            document: CurationDocument) -> CurationEditSession {
        #if VORTX_NATIVE_DATA_ENGINE
        return CurationEditSession(profileID: baseline.profileID, collection: baseline.collection,
                                   document: document, legacyRegister: baseline.legacyRegister,
                                   companionRegister: document.raw, target: nil)
        #else
        return CurationEditSession(profileID: baseline.profileID, collection: baseline.collection,
                                   document: document, legacyRegister: baseline.legacyRegister,
                                   companionRegister: document.raw)
        #endif
    }

    static func sessionFixture(linked: Bool = false) throws -> (SmartCollection, CurationEditSession) {
        let id = "55555555-5555-4555-8555-555555555555"
        let profile = UUID(uuidString: profileID)!
        let collection = SmartCollection(id: id, name: "Controller fixture",
                                         rules: SmartCollectionRules(), home: true, createdAt: 1)
        let legacy: VortxJSON = .object([
            "id": .string(id), "name": .string(collection.name), "home": .bool(true),
            "createdAt": .number(1), "rules": .object(["type": .string("all")])
        ])
        var document = try CurationDocument.make(for: collection, legacyValue: legacy)
        if linked {
            document = try document.attaching(base: document.raw["base"]!,
                                              provider: XperienceCurationExportMapper.provider,
                                              sourceID: sourceID, revision: "last-good-revision",
                                              upstreamCollectionID: collectionID)
        }
        #if VORTX_NATIVE_DATA_ENGINE
        let session = CurationEditSession(profileID: profile, collection: collection, document: document,
                                          legacyRegister: legacy, companionRegister: document.raw, target: nil)
        #else
        let session = CurationEditSession(profileID: profile, collection: collection, document: document,
                                          legacyRegister: legacy, companionRegister: document.raw)
        #endif
        return (collection, session)
    }

    static func controllerGestureAndReconnect() async throws {
        let (collection, session) = try sessionFixture()
        let fixture = ExportStoreFixture(session: session)
        let context = PassthroughSubject<Void, Never>()
        let authority = CredentialScopeRegistry(initialScope: .signedOutDevice)
        let gestureBackend = CredentialBackend()
        let vault = XperienceExportCredentialVault(store: gestureBackend.store(), authority: authority)
        let gate = TransportGate()
        let payload = try data(envelope(.array([collectionValue(), collectionValue("other")])) )
        let controller = XperienceCurationExportController(
            store: fixture, vault: vault, authority: authority,
            contextChanges: context.eraseToAnyPublisher(),
            transport: { _ in
                gate.markStarted()
                return await gate.waitForRelease()
            })
        let ticket = try controller.beginLink(collection)
        let pending = Task { try await controller.previewURL(
            "https://xperience-app.com/profile-export/\(profileID).json?key=\(exampleKey)", ticket: ticket) }
        await gate.waitUntilStarted()
        context.send(()) // profile/account publisher invalidates the original gesture during the suspended fetch.
        gate.release(payload)
        do {
            _ = try await pending.value
            throw Failure.assertion("cancelled profile preview returned selections")
        } catch is CancellationError {
            checks += 1
        } catch let error as XperienceExportFailure {
            try require(error == .staleContext, "profile ABA rejects the late preview with stale context")
        } catch {
            throw error
        }
        try require(fixture.retirements == 1,
                    "profile ABA/context publication retires the captured edit and late transport")
        try require(controller.phase == .idle,
                     "late preview does not install selections after the original gesture is cancelled")

        let (linkedCollection, linkedSession) = try sessionFixture(linked: true)
        let reconnectFixture = ExportStoreFixture(session: linkedSession)
        let reconnectAuthority = CredentialScopeRegistry(initialScope: .signedOutDevice)
        let reconnectBackend = CredentialBackend()
        let reconnectVault = XperienceExportCredentialVault(store: reconnectBackend.store(),
                                                             authority: reconnectAuthority)
        let reconnect = XperienceCurationExportController(
            store: reconnectFixture, vault: reconnectVault, authority: reconnectAuthority,
            transport: { _ in payload })
        let reconnectTicket = try reconnect.beginReconnect(linkedCollection)
        let selections = try await reconnect.previewURL(
            "https://xperience-app.com/profile-export/\(profileID).json?key=\(exampleKey)",
            ticket: reconnectTicket)
        try require(selections.map(\.id) == [collectionID],
                    "reconnect-device preview retains the shared upstream collection selection")
    }

    static func controllerCASAndSyncDistinction() async throws {
        let (collection, session) = try sessionFixture()
        let fixture = ExportStoreFixture(session: session, installed: [try candidate()])
        fixture.saveError = CurationFailure.staleRevision
        let mappedPayload = try data(envelope(.array([mappedCollectionValue()])))
        let backend = CredentialBackend()
        let authority = CredentialScopeRegistry(initialScope: .signedOutDevice)
        let vault = XperienceExportCredentialVault(store: backend.store(), authority: authority)
        let controller = XperienceCurationExportController(
            store: fixture, vault: vault, authority: authority,
            transport: { _ in
                try await Task.sleep(nanoseconds: 1)
                return mappedPayload
            })
        let ticket = try controller.beginLink(collection)
        _ = try await controller.previewURL(
            "https://xperience-app.com/profile-export/\(profileID).json?key=\(exampleKey)", ticket: ticket)
        do {
            try await controller.selectAndSave(upstreamCollectionID: collectionID, ticket: ticket)
            throw Failure.assertion("native CAS failure was not surfaced")
        } catch let error as XperienceExportFailure {
            try require(error == .staleRevision || error == .unsafeContent,
                        "native CAS failure is controlled and does not look like a successful sync")
        }
        try require(fixture.saved == nil && fixture.saves == 1,
                    "native save failure leaves the last-good document unchanged")
        try require(backend.writes == 0,
                    "failed native CAS leaves the prior private URL credential unchanged")

        let (postACKCollection, postACKSession) = try sessionFixture()
        let postACKFixture = ExportStoreFixture(session: postACKSession, installed: [try candidate()])
        postACKFixture.invalidateContextAfterSave = true // same owner, changed install/registry witness.
        let postACKBackend = CredentialBackend()
        let postACKAuthority = CredentialScopeRegistry(initialScope: .signedOutDevice)
        let postACKVault = XperienceExportCredentialVault(store: postACKBackend.store(), authority: postACKAuthority)
        let postACKController = XperienceCurationExportController(
            store: postACKFixture, vault: postACKVault, authority: postACKAuthority,
            transport: { _ in mappedPayload })
        let postACKTicket = try postACKController.beginLink(postACKCollection)
        _ = try await postACKController.previewURL(
            "https://xperience-app.com/profile-export/\(profileID).json?key=\(exampleKey)",
            ticket: postACKTicket)
        do {
            try await postACKController.selectAndSave(upstreamCollectionID: collectionID, ticket: postACKTicket)
            throw Failure.assertion("post-ACK context replacement was reported as saved")
        } catch let error as XperienceExportFailure {
            try require(error == .staleContext,
                        "same-owner install/registry replacement after native ACK rejects .saved")
        }
        try require(postACKFixture.saved != nil && postACKController.phase == .failed,
                    "post-ACK context loss retains native result but never reports a saved connector")

        let (credentialFailureCollection, credentialFailureSession) = try sessionFixture()
        let credentialFailureFixture = ExportStoreFixture(session: credentialFailureSession,
                                                           installed: [try candidate()])
        let credentialFailureBackend = CredentialBackend()
        credentialFailureFixture.afterSave = { credentialFailureBackend.failReads = true }
        let credentialFailureAuthority = CredentialScopeRegistry(initialScope: .signedOutDevice)
        let credentialFailureVault = XperienceExportCredentialVault(
            store: credentialFailureBackend.store(), authority: credentialFailureAuthority)
        let credentialFailureController = XperienceCurationExportController(
            store: credentialFailureFixture, vault: credentialFailureVault,
            authority: credentialFailureAuthority,
            transport: { _ in mappedPayload })
        let credentialFailureTicket = try credentialFailureController.beginLink(credentialFailureCollection)
        _ = try await credentialFailureController.previewURL(
            "https://xperience-app.com/profile-export/\(profileID).json?key=\(exampleKey)",
            ticket: credentialFailureTicket)
        do {
            try await credentialFailureController.selectAndSave(
                upstreamCollectionID: collectionID, ticket: credentialFailureTicket)
            throw Failure.assertion("post-ACK credential failure was reported as a normal save")
        } catch let error as XperienceExportFailure {
            try require(error == .savedNeedsConnection,
                        "post-ACK secure-store failure reports the explicit reconnect-needed outcome")
        }
        try require(credentialFailureFixture.saved != nil &&
                    credentialFailureController.phase == .savedNeedsConnection,
                    "acknowledged native definition remains saved while URL reconnect is required")
        try require(credentialFailureController.message?.localizedCaseInsensitiveContains("reconnect") == true,
                    "reconnect-needed UI message does not claim account sync or a complete link")

        let (finalReadCollection, finalReadSession) = try sessionFixture()
        let finalReadFixture = ExportStoreFixture(session: finalReadSession, installed: [try candidate()])
        let finalReadBackend = CredentialBackend()
        finalReadFixture.afterSave = { finalReadBackend.failFinalReadAfterWriteCertification() }
        let finalReadAuthority = CredentialScopeRegistry(initialScope: .signedOutDevice)
        let finalReadVault = XperienceExportCredentialVault(store: finalReadBackend.store(),
                                                             authority: finalReadAuthority)
        let finalReadController = XperienceCurationExportController(
            store: finalReadFixture, vault: finalReadVault, authority: finalReadAuthority,
            transport: { _ in mappedPayload })
        let finalReadTicket = try finalReadController.beginLink(finalReadCollection)
        _ = try await finalReadController.previewURL(
            "https://xperience-app.com/profile-export/\(profileID).json?key=\(exampleKey)",
            ticket: finalReadTicket)
        do {
            try await finalReadController.selectAndSave(
                upstreamCollectionID: collectionID, ticket: finalReadTicket)
            throw Failure.assertion("final certified receipt read fault was reported as a normal save")
        } catch let error as XperienceExportFailure {
            try require(error == .savedNeedsConnection,
                        "final receipt read failure after successful write certification reports reconnect-needed")
        }
        try require(finalReadBackend.writes == 1 && finalReadFixture.saved != nil &&
                    finalReadController.phase == .savedNeedsConnection,
                    "final receipt fault retains the acknowledged definition and never fabricates saved")
    }

    static func successfulLinkAndExplicitRefresh() async throws {
        let (collection, baselineSession) = try sessionFixture()
        let linkFixture = ExportStoreFixture(session: baselineSession, installed: [try candidate()])
        let backend = CredentialBackend()
        let authority = CredentialScopeRegistry(initialScope: .signedOutDevice)
        let vault = XperienceExportCredentialVault(store: backend.store(), authority: authority)
        let payload = try data(envelope(.array([mappedCollectionValue()])))
        let linkProbe = TransportProbe(payload: payload)
        let linkController = XperienceCurationExportController(
            store: linkFixture, vault: vault, authority: authority,
            transport: { _ in linkProbe.load() })
        let linkTicket = try linkController.beginLink(collection)
        _ = try await linkController.previewURL(
            "https://xperience-app.com/profile-export/\(profileID).json?key=\(exampleKey)",
            ticket: linkTicket)
        try await linkController.selectAndSave(upstreamCollectionID: collectionID, ticket: linkTicket)
        try require(linkController.phase == .saved &&
                    linkController.message?.contains("Linked from Xperience") == true &&
                    linkController.message?.contains("account sync runs separately") == true,
                    "successful link reports local save separately from account sync")
        guard let saved = linkFixture.saved else { throw Failure.assertion("link fixture did not retain saved document") }

        // A new gesture/session reads the saved common document, but the same owner-scoped vault
        // carries the private URL. Refresh is an explicit user action, never an implicit poll.
        let refreshSession = sessionFrom(baselineSession, document: saved)
        let refreshFixture = ExportStoreFixture(session: refreshSession, installed: [try candidate()])
        let refreshProbe = TransportProbe(payload: payload)
        let refreshController = XperienceCurationExportController(
            store: refreshFixture, vault: vault, authority: authority,
            transport: { _ in refreshProbe.load() })
        let refreshTicket = try refreshController.beginRefresh(collection)
        try require(refreshProbe.callCount() == 0 && refreshController.phase == .idle,
                    "beginRefresh captures authority without fetching until Refresh now")
        try await refreshController.refreshNow(ticket: refreshTicket)
        try require(refreshProbe.callCount() == 1 && refreshController.phase == .saved &&
                    refreshController.message?.contains("Refreshed from Xperience") == true &&
                    refreshController.message?.contains("account sync runs separately") == true,
                    "explicit Refresh now reports refreshed local content separately from account sync")
    }

    static func main() async throws {
        try endpointAdmission()
        try ownerScopedCredentials()
        try explicitRepairTickets()
        try envelopeAdmission()
        try XperienceMapperWireEqualityTests.run()
        try mapperBoundaries()
        try await httpBoundaries()
        try await controllerGestureAndReconnect()
        try await controllerCASAndSyncDistinction()
        try await successfulLinkAndExplicitRefresh()
        print("PASS authored Xperience export contract checks: \(checks)")
    }
}
