import Foundation

// Compile alongside the actual production components, actual VortxJSON,
// and XperienceImportPrivacy's native archive dependency.
// No copied model, mock parser, network, account, app or device operation is used here.
@main
@MainActor
enum XperienceCollectionsTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        precondition(value(), name)
    }
    static func rejects(_ expected: XperienceCollections.Failure, _ name: String, _ body: () throws -> Void) {
        checks += 1
        do { try body(); preconditionFailure(name) }
        catch let failure as XperienceCollections.Failure { precondition(failure == expected, name) }
        catch { preconditionFailure(name + ": unexpected error category") }
    }
    static let source = #"{"provider":"addon","addonId":"example.catalogs","type":"movie","catalogId":"genre.example","genre":"None"}"#
    static func fixture(source: String? = nil, extra: String = "") -> Data {
        let catalogSource = source ?? Self.source
        return Data("""
        [{"id":"collection.one","title":"One","pinToTop":true,"viewMode":"TABBED_GRID",
          "folders":[{"id":"folder.one","title":"Folder","tileShape":"LANDSCAPE","hideTitle":true,
          "sources":[\(catalogSource)]}]\(extra)}]
        """.utf8)
    }
    static func changing(_ data: Data, _ from: String, _ to: String) -> Data {
        Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: from, with: to).utf8)
    }
    static func main() throws {
        let document = try XperienceCollections.parse(fixture(extra: #","future":{"unknown":[true,null,9007199254740993]}"#))
        expect(document.collections[0].pinToTop, "pin state retained")
        expect(document.collections[0].folders[0].hideTitle, "hide title retained")
        expect(document.collections[0].folders[0].sources[0].genre == "None", "None is a real source genre")
        expect(document.raw.array?[0]["future"]?["unknown"]?.array?[2] == .integer(9_007_199_254_740_993),
               "unknown integer is not rounded through binary64")
        let encoded = try XperienceCollections.canonicalData(document.raw)
        let roundTrip = try XperienceCollections.parse(encoded)
        expect(roundTrip.raw == document.raw, "all unknown values round trip")

        rejects(.duplicateMember, "escaped duplicate member fails before dictionary conversion") {
            _ = try XperienceCollections.parse(changing(fixture(), #""id":"collection.one""#,
                #""id":"collection.one","i\u0064":"other""#))
        }
        rejects(.duplicateMember, "nested unknown duplicate also fails") {
            _ = try XperienceCollections.parse(fixture(extra: #","future":{"x":1,"x":2}"#))
        }
        rejects(.invalidJSON, "trailing document garbage fails") {
            _ = try XperienceCollections.parse(fixture() + Data("null".utf8))
        }
        rejects(.invalidSchema, "wrong known type does not become a default") {
            _ = try XperienceCollections.parse(changing(fixture(), #""pinToTop":true"#, #""pinToTop":1"#))
        }
        rejects(.emptyImport, "empty array never clears a namespace") {
            _ = try XperienceCollections.parse(Data("[]".utf8))
        }
        rejects(.tooLarge, "bounded parser fails before allocating a large tree") {
            _ = try XperienceCollections.parse(Data(repeating: 32, count: XperienceCollections.maximumBytes + 1))
        }
        for extensionValue in [VortxJSON.string(String(repeating: "x", count: XperienceCollections.maximumBytes + 1)),
                               .array(Array(repeating: .null, count: XperienceCollections.maximumNodes + 1))] {
            guard case .object(var fields) = document.collections[0].raw else { preconditionFailure("fixture shape") }
            fields["future"] = extensionValue
            rejects(.tooLarge, "stored unknown subtree must honor byte and node limits") {
                _ = try XperienceCollections.project(.array([.object(fields)]))
            }
        }
        var nested: VortxJSON = .null
        for _ in 0...XperienceCollections.maximumDepth { nested = .object(["child": nested]) }
        guard case .object(var deepFields) = document.collections[0].raw else { preconditionFailure("fixture shape") }
        deepFields["future"] = nested
        rejects(.tooLarge, "stored unknown subtree must honor depth limit") {
            _ = try XperienceCollections.project(.array([.object(deepFields)]))
        }
        rejects(.unpreservableNumber, "unknown high precision decimal must not be rounded") {
            _ = try XperienceCollections.parse(fixture(extra: #","future":0.123456789012345678901"#))
        }
        rejects(.unpreservableNumber, "huge negative exponent is controlled, not abs(Int.min)") {
            _ = try XperienceCollections.parse(fixture(extra: #","future":0e-9223372036854775808"#))
        }
        let unsigned = try XperienceCollections.parse(fixture(extra: #","future":18446744073709551615"#))
        expect(unsigned.raw.array?[0]["future"] == .unsigned(UInt64.max), "UInt64 maximum remains exact")
        let collection = document.raw.array![0]
        rejects(.duplicateCollection, "duplicate collection IDs fail the whole import") {
            _ = try XperienceCollections.project(.array([collection, collection]))
        }
        guard case .object(var repeatedFolder) = collection,
              case .array(var folders) = repeatedFolder["folders"] else { preconditionFailure("fixture shape") }
        folders.append(folders[0]); repeatedFolder["folders"] = .array(folders)
        rejects(.duplicateFolder, "duplicate folder IDs fail the whole import") {
            _ = try XperienceCollections.project(.array([.object(repeatedFolder)]))
        }
        let legacy = #"{"addonId":"example.catalogs","type":"movie","catalogId":"genre.example","genre":"None"}"#
        let dual = changing(fixture(), #""sources":["# + source + "]", #""sources":["# + source + #"],"catalogSources":["# + legacy + "]")
        let dualDocument = try XperienceCollections.parse(dual)
        expect(dualDocument.collections[0].folders[0].sources.count == 1, "dual source arrays are not concatenated")
        expect(!dualDocument.notices.contains(where: { $0.kind == .modernAndLegacySourcesDiffer }),
               "equivalent legacy and modern semantics do not create a false warning")
        rejects(.duplicateSource, "repeated active source fails instead of double fetching") {
            _ = try XperienceCollections.parse(fixture(source: source + "," + source))
        }
        let futureProvider = try XperienceCollections.parse(fixture(source: #"{"provider":"future","extension":{"keep":true}}"#))
        let unsupported = futureProvider.collections[0].folders[0].sources[0]
        expect(XperienceAddonBinding.resolve(unsupported, installed: []) == .unsupportedProvider,
               "unknown provider is explicit and never coerced to an add-on")
        expect(futureProvider.raw.array?[0]["folders"]?.array?[0]["sources"]?.array?[0]["extension"]?["keep"] == .bool(true),
               "unsupported provider extensions survive")

        let catalogs: [XperienceAddonBinding.Catalog] = [
            .init(type: "movie", id: "genre.example", acceptsGenre: true, requiresGenre: false, supportsSkip: true),
            .init(type: "series", id: "genre.example", acceptsGenre: true, requiresGenre: false, supportsSkip: true)
        ]
        let one = try XperienceAddonBinding.Candidate(manifestID: "example.catalogs",
            transport: "https://ADDON.example/first/manifest.json?tenant=one&mode=full", catalogs: catalogs)
        let two = try XperienceAddonBinding.Candidate(manifestID: "example.catalogs",
            transport: "https://addon.example/second/manifest.json?tenant=two", catalogs: catalogs)
        let selected = document.collections[0].folders[0].sources[0]
        expect(XperienceAddonBinding.resolve(selected, installed: [one]) == .resolved(one), "unique exact binding resolves")
        expect(XperienceAddonBinding.resolve(selected, installed: [one, two]) == .ambiguous([one, two]),
               "same manifest with different configured transports requires user mapping")
        expect(XperienceAddonBinding.resolve(selected, installed: [one, two], mapping: two.mapping) == .resolved(two),
               "explicit mapping resolves the chosen transport")
        expect(XperienceAddonBinding.resolve(selected, installed: [one], mapping: two.mapping) == .mappingUnavailable,
               "removed mapped transport cannot retarget to another instance")
        expect(XperienceAddonBinding.resolve(selected, installed: [one, one]) == .invalidRegistry, "duplicate registry is explicit")
        let wrong = try XperienceAddonBinding.Candidate(manifestID: "other.catalogs", transport: one.canonicalTransport, catalogs: catalogs)
        expect(XperienceAddonBinding.resolve(selected, installed: [wrong]) == .missing, "catalog ID alone cannot bind")

        let url = try XperienceAddonBinding.catalogURL(source: selected, candidate: one, skip: 20)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        expect(components.percentEncodedPath == "/first/catalog/movie/genre.example/genre=None&skip=20.json", "None and skip projected")
        expect(components.percentEncodedQuery == "tenant=one&mode=full", "configured query preserved exactly")
        let configuredPath = try XperienceAddonBinding.Candidate(manifestID: "example.catalogs",
            transport: "https://ADDON.example/config%2Fvalue/%25literal/manifest.json?key=a%2Fb&x=%26", catalogs: catalogs)
        let configuredRequest = try XperienceAddonBinding.catalogURL(source: selected, candidate: configuredPath)
        let configuredParts = URLComponents(url: configuredRequest, resolvingAgainstBaseURL: false)!
        expect(configuredParts.percentEncodedPath == "/config%2Fvalue/%25literal/catalog/movie/genre.example/genre=None.json",
               "installed escaped configuration prefix retains exact route bytes")
        expect(configuredParts.percentEncodedQuery == "key=a%2Fb&x=%26", "escaped query remains exact")
        let unicodeSources = ["caf\u{00e9}", "cafe\u{0301}"].map { catalog in
            #"{"provider":"addon","addonId":"example.catalogs","type":"movie","catalogId":""# + catalog + #"","genre":"None"}"#
        }
        let unicodeDocument = try XperienceCollections.parse(fixture(source: unicodeSources.joined(separator: ",")))
        let unicodeRows = unicodeDocument.collections[0].folders[0].sources
        expect(XperienceAddonBinding.key(for: unicodeRows[0]) != XperienceAddonBinding.key(for: unicodeRows[1]),
               "protocol Unicode byte variants have distinct stable keys")
        let unicodeCandidates = try ["caf\u{00e9}", "cafe\u{0301}"].map { catalog in
            try XperienceAddonBinding.Candidate(manifestID: "example.catalogs", transport: one.canonicalTransport,
                catalogs: [.init(type: "movie", id: catalog, acceptsGenre: true, requiresGenre: false, supportsSkip: false)])
        }
        expect(XperienceAddonBinding.resolve(unicodeRows[0], installed: [unicodeCandidates[0]]) == .resolved(unicodeCandidates[0]),
               "exact Unicode protocol identity resolves")
        expect(XperienceAddonBinding.resolve(unicodeRows[1], installed: [unicodeCandidates[0]]) == .missing,
               "equivalent display Unicode cannot alias a different protocol ID")
        let unicodeURLs = try zip(unicodeRows, unicodeCandidates).map {
            try XperienceAddonBinding.catalogURL(source: $0.0, candidate: $0.1).absoluteString
        }
        expect(unicodeURLs[0] != unicodeURLs[1], "distinct protocol IDs keep distinct encoded routes")
        let unicodeDual = changing(fixture(source: unicodeSources[0]),
            #""sources":["# + unicodeSources[0] + "]", #""sources":["# + unicodeSources[0] + #"],"catalogSources":["# + unicodeSources[1] + "]")
        let unicodeDualDocument = try XperienceCollections.parse(unicodeDual)
        expect(unicodeDualDocument.notices.contains { $0.kind == .modernAndLegacySourcesDiffer },
               "source-array comparison uses the same byte identity as binding")
        let encodedSource = try XperienceCollections.parse(fixture(source:
            #"{"addonId":"example.catalogs","type":"movie","catalogId":"a/b?x#z","genre":"A&B/None"}"#))
            .collections[0].folders[0].sources[0]
        let encodedCandidate = try XperienceAddonBinding.Candidate(manifestID: "example.catalogs", transport: one.canonicalTransport,
            catalogs: [.init(type: "movie", id: "a/b?x#z", acceptsGenre: true, requiresGenre: false, supportsSkip: false)])
        let safe = try XperienceAddonBinding.catalogURL(source: encodedSource, candidate: encodedCandidate)
        expect(safe.absoluteString.contains("a%2Fb%3Fx%23z/genre=A%26B%2FNone.json"), "route components cannot inject slash/query/fragment")
        expect(safe.host == "addon.example", "route data never replaces host")
        do { _ = try XperienceAddonBinding.catalogURL(source: encodedSource, candidate: encodedCandidate, skip: 20)
            preconditionFailure("pagination must be advertised")
        } catch XperienceAddonBinding.Failure.unsupportedPagination { checks += 1 }

        let namespace = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let append = try XperienceImportNamespace.append(document: document, label: "Example import", namespace: namespace)
        expect(append.baselineMatches(nil), "append requires absent register")
        expect(!append.baselineMatches(.null), "existing tombstone/value is not absence")
        let sibling = try XperienceImportNamespace.append(document: document, label: "Other instance")
        expect(sibling.field != append.field, "equal collection IDs stay separate across import namespaces")
        var priorValue = append.value
        guard case .object(var saved) = priorValue else { preconditionFailure("envelope") }
        saved["futureSaved"] = .object(["preserve": .bool(true)])
        priorValue = .object(saved)
        let actor = "00000000-0000-0000-0000-000000000456"
        let prior: VortxJSON = .object(["clock": .integer(3), "actor": .string(actor), "value": priorValue])
        let replacement = try XperienceImportNamespace.replace(document: document, label: "Renamed", namespace: namespace,
            expectedRegister: prior, bindings: [XperienceAddonBinding.key(for: selected): two.mapping])
        expect(replacement.baselineMatches(prior), "full register CAS accepts its preview")
        let concurrent: VortxJSON = .object(["clock": .integer(4), "actor": .string(actor), "value": priorValue])
        expect(!replacement.baselineMatches(concurrent), "new clock rejects stale replacement")
        let exactEdit = XperienceImportNamespace.Edit(namespace: namespace, field: append.field,
            expectedRegister: .string("caf\u{00e9}"), value: append.value)
        expect(!exactEdit.baselineMatches(.string("cafe\u{0301}")),
               "full register comparison does not collapse Unicode byte changes")
        expect(replacement.value["futureSaved"]?["preserve"] == .bool(true), "replacement retains unknown envelope fields")
        expect(replacement.value["collections"] == document.raw, "save retains complete raw document")

        try XperienceImportPrivacy.validate(append)
        guard case .object(var typedDigestEnvelope) = append.value else { preconditionFailure("envelope") }
        let braceLikeDigest = "e9" + String(repeating: "a", count: 62)
        typedDigestEnvelope["fingerprint"] = .string(braceLikeDigest)
        typedDigestEnvelope["bindings"] = .object([XperienceAddonBinding.key(for: selected): .object([
            "manifestID": .string("example.catalogs"),
            "transport": .object(["fingerprint": .string(braceLikeDigest)])
        ])])
        let digestEdit = XperienceImportNamespace.Edit(namespace: namespace, field: append.field,
            expectedRegister: nil, value: .object(typedDigestEnvelope))
        try XperienceImportPrivacy.validate(digestEdit)
        checks += 1 // Generated hashes use the native inspector's typed fingerprint positions.
        let unsafe = try XperienceCollections.parse(fixture(extra: #","future":{"apiKey":"synthetic-value"}"#))
        let unsafeEdit = try XperienceImportNamespace.append(document: unsafe, label: "Unsafe fixture", namespace: namespace)
        rejects(.unsafeHostValue, "native credential policy rejects intact, without deleting a foreign field") {
            try XperienceImportPrivacy.validate(unsafeEdit)
        }
        print("Xperience pure production component checks passed: \(checks)")
    }
}
