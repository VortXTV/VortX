import Foundation

// No live transport, storage, credentials, app owner, playback or device is used.
// All JSON decoders/models, native projection and TrailerRequest below are production code.
private enum CustomDecodeFailure: Error { case sentinel }
private struct CustomFailingPayload: Decodable {
    init(from decoder: Decoder) throws { throw CustomDecodeFailure.sentinel }
}

@MainActor @main enum Issue261ResourceFixture {
    static var checks = 0
    static var failures: [String] = []
    static var expectedBaselineFailures: Set<String> = []
    static let baselineMode = CommandLine.arguments.dropFirst().contains("--expect-regression")
    static let decoder = JSONDecoder()
    static let encoder = JSONEncoder()
    static let ytA = "PLl99DlL6b4"
    static let ytB = "xyXX8LXiNJ4"

    static func expect(_ value: Bool, _ label: String, baselineRegression: Bool = false) {
        checks += 1
        if baselineRegression { expectedBaselineFailures.insert(label) }
        if value { print("PASS \(label)") }
        else {
            failures.append(label)
            print("\(baselineMode && baselineRegression ? "EXPECTED BASELINE RED" : "FAIL") \(label)")
        }
    }
    static func target(_ value: Bool, _ label: String) {
        expect(value, label, baselineRegression: true)
    }
    static func json(_ raw: String) throws -> VortxJSON { try decoder.decode(VortxJSON.self, from: Data(raw.utf8)) }
    static func decode<T: Decodable>(_ type: T.Type, _ value: VortxJSON) throws -> T {
        try decoder.decode(type, from: encoder.encode(value))
    }
    static func errored<T: Decodable>(_ value: CoreLoadable<T>?) -> Bool { if case .err? = value { return true }; return false }
    static func loading<T: Decodable>(_ value: CoreLoadable<T>?) -> Bool { if case .loading? = value { return true }; return false }
    static func addon(_ id: String) -> VortxResourceAddon {
        .init(id: id, transportUrl: "https://\(id).fixture.invalid/manifest.json", manifest: nil)
    }
    static func request(_ resource: VortxResourceRequest.Resource, id: String = "tt-fixture") -> VortxResourceRequest {
        .init(resource: resource, type: "movie", id: id)
    }
    static func snapshot(_ path: VortxResourceRequest, groups: [VortxResourceGroup], registry: [VortxResourceAddon]) -> VortxResourceSnapshot {
        .init(ownerID: "controlled-owner", requestID: "controlled-request", generation: 1, request: path,
              groups: groups, sourceURLs: Dictionary(uniqueKeysWithValues: registry.map { ($0.id, $0.transportUrl) }))
    }
    static func entry(_ path: VortxResourceRequest, tag: String, content: VortxJSON? = nil) throws -> VortxJSON {
        var payload = ["type": VortxJSON.string(tag)]
        if let content { payload["content"] = content }
        return .object(["request": .object(["base": .string("https://raw.fixture.invalid/manifest.json"),
                                          "path": try VortxResourceProjection.path(path)]),
                        "content": .object(payload)])
    }
    static func group(_ id: String, key: String, payload: VortxJSON) -> VortxResourceGroup {
        .init(addonId: id, status: .ready, content: .object([key: payload]), error: nil)
    }

    static func catalogCases() throws {
        let registry = [addon("healthy"), addon("broken")]
        let good = try json(#"{"id":"tt-fixture","type":"movie","name":"Healthy catalog title"}"#)
        let brokenPayloads = [
            #"{"type":"movie","name":"Missing identity"}"#,
            #"{"id":"tt-broken","type":"movie","name":17}"#,
            #"{"id":"tt-broken","type":"movie","name":"Bad optional poster","poster":17}"#
        ]
        for (index, raw) in brokenPayloads.enumerated() {
            let groups = [group("healthy", key: "metas", payload: .array([good])),
                          group("broken", key: "metas", payload: .array([try json(raw)]))]
            let projected = try VortxResourceProjection.board(pages: [snapshot(request(.catalog, id: "popular"), groups: groups, registry: registry)], registry: registry)
            let decoded = try? decode(CoreBoardState.self, projected)
            target(decoded?.catalogs.count == 2, "catalog variant \(index) keeps exact projected rows decodable")
            target(decoded?.catalogs.first?.first?.content?.ready?.first?.id == "tt-fixture", "catalog variant \(index) retains healthy sibling")
            target(errored(decoded?.catalogs.last?.first?.content), "catalog variant \(index) settles malformed Ready as error")
        }
        let rawRows = try [entry(request(.catalog), tag: "Ready", content: .array([good])),
                           entry(request(.catalog), tag: "Ready"), entry(request(.catalog), tag: "Loading"),
                           entry(request(.catalog), tag: "Err")]
        let rawBoard: VortxJSON = .object(["selected": .object([:]), "catalogs": .array(rawRows.map { .array([$0]) })])
        let decoded = try? decode(CoreBoardState.self, rawBoard)
        target(decoded?.catalogs.count == 4, "missing Ready content does not suppress board siblings")
        target(decoded?.catalogs.first?.first?.content?.ready?.count == 1, "missing content retains valid catalog sibling")
        target(errored(decoded?.catalogs.dropFirst().first?.first?.content), "missing catalog Ready content becomes error")
        let controlReady = try decode(CoreCatalogPage.self, rawRows[0])
        let controlLoading = try decode(CoreCatalogPage.self, rawRows[2])
        let controlError = try decode(CoreCatalogPage.self, rawRows[3])
        expect(controlReady.content?.ready?.count == 1, "valid catalog Ready unchanged")
        expect(loading(controlLoading.content), "known catalog Loading unchanged")
        expect(errored(controlError.content), "known catalog Err unchanged")
        let empty = try decode(CoreCatalogPage.self, entry(request(.catalog), tag: "Ready", content: .array([])))
        expect(empty.content?.ready?.isEmpty == true, "successful empty catalog remains Ready")
    }

    static func detailCases() throws {
        let registry = [addon("healthy"), addon("broken")]
        let goodMeta = try json(#"{"id":"tt-fixture","type":"movie","name":"Healthy detail","links":[{"name":"Trailer","category":"Trailer","url":"https://www.youtube.com/watch?v=PLl99DlL6b4"}]}"#)
        let goodStream = try json(#"{"url":"https://media.fixture.invalid/movie.m3u8","name":"Healthy stream","behaviorHints":{"proxyHeaders":{"request":{"Referer":"https://headers.fixture.invalid/"}}}}"#)
        let brokenMetas = [#"{"id":17,"type":"movie","name":"Bad identity"}"#,
                           #"{"id":"tt-fixture","type":"movie","name":"Bad episode coordinates","videos":[{"id":"episode-one","season":"one"}]}"#]
        for (index, raw) in brokenMetas.enumerated() {
            let meta = snapshot(request(.meta), groups: [group("healthy", key: "meta", payload: goodMeta),
                                                       group("broken", key: "meta", payload: try json(raw))], registry: registry)
            let streams = snapshot(request(.stream), groups: [group("healthy", key: "streams", payload: .array([goodStream])),
                                                            group("broken", key: "streams", payload: .array([try json(#"{"url":17}"#)]))], registry: registry)
            let projected = try VortxResourceProjection.metaDetails(meta: meta, streams: streams, expectedStream: request(.stream), registry: registry)
            let decoded = try? decode(CoreMetaDetails.self, projected)
            target(decoded?.metaItems.count == 2 && decoded?.streams.count == 2, "detail variant \(index) decodes exact native projected arrays")
            target(decoded?.meta?.id == "tt-fixture", "detail variant \(index) preserves actual priority-selected healthy meta")
            target(errored(decoded?.metaItems.last?.content), "detail variant \(index) settles bad meta as error")
            target(decoded?.streams.first?.content?.ready?.first?.url == "https://media.fixture.invalid/movie.m3u8", "detail variant \(index) retains healthy stream")
            target(decoded?.streams.first?.content?.ready?.first?.requestHeaders?["Referer"] == "https://headers.fixture.invalid/", "detail variant \(index) retains stream header provenance")
            target(errored(decoded?.streams.last?.content), "detail variant \(index) settles bad stream as error")
            target(decoded?.metaResolution == .ready, "detail variant \(index) resolves with healthy peer")
            target(decoded?.meta.flatMap { TrailerRequest.from(meta: $0) }?.youTubeID == ytA, "detail variant \(index) forwards raw trailer link through production request")
        }
        let metaPath = request(.meta), streamPath = request(.stream)
        let selected: VortxJSON = .object(["metaPath": try VortxResourceProjection.path(metaPath), "streamPath": try VortxResourceProjection.path(streamPath)])
        let raw: VortxJSON = .object(["selected": selected,
            "metaItems": .array(try [entry(metaPath, tag: "Ready", content: goodMeta), entry(metaPath, tag: "Ready"), entry(metaPath, tag: "Loading"), entry(metaPath, tag: "Err")]),
            "streams": .array(try [entry(streamPath, tag: "Ready", content: .array([goodStream])), entry(streamPath, tag: "Ready"), entry(streamPath, tag: "Loading"), entry(streamPath, tag: "Err")])])
        let decoded = try? decode(CoreMetaDetails.self, raw)
        target(decoded?.meta?.id == "tt-fixture", "missing meta/stream Ready content preserves healthy detail")
        target(errored(decoded?.metaItems.dropFirst().first?.content) && errored(decoded?.streams.dropFirst().first?.content), "missing meta/stream content settles each entry as error")
        let loadingMeta = try decode(CoreMetaEntry.self, entry(metaPath, tag: "Loading"))
        let loadingStream = try decode(CoreStreamGroup.self, entry(streamPath, tag: "Loading"))
        let errorMeta = try decode(CoreMetaEntry.self, entry(metaPath, tag: "Err"))
        let errorStream = try decode(CoreStreamGroup.self, entry(streamPath, tag: "Err"))
        expect(loading(loadingMeta.content) && loading(loadingStream.content), "known meta/stream Loading stays pending")
        expect(errored(errorMeta.content) && errored(errorStream.content), "known meta/stream Err stays terminal")
        let badStreams = [VortxJSON.object([:]), .array([.object(["fileIdx": .string("two")])])]
        for (index, content) in badStreams.enumerated() {
            let response = try? decode(CoreStreamGroup.self, entry(streamPath, tag: "Ready", content: content))
            target(errored(response?.content), "stream payload variant \(index) settles bad shape/type")
        }
        let empty = try decode(CoreStreamGroup.self, entry(streamPath, tag: "Ready", content: .array([])))
        expect(empty.content?.ready?.isEmpty == true, "successful empty stream remains Ready")
        do {
            _ = try decode(CoreLoadable<CustomFailingPayload>.self, .object(["type": .string("Ready"), "content": .object([:])]))
            expect(false, "non-DecodingError must propagate")
        } catch CustomDecodeFailure.sentinel { expect(true, "non-DecodingError propagates") }
        catch { expect(false, "non-DecodingError remains exact custom failure") }
        let malformedTags: [(String, VortxJSON)] = [
            ("missing", .object(["content": .array([])])),
            ("null", .object(["type": .null, "content": .array([])])),
            ("non-string", .object(["type": .integer(17), "content": .array([])]))
        ]
        for (label, value) in malformedTags {
            do {
                _ = try decode(CoreLoadable<[CoreMeta]>.self, value)
                expect(false, "\(label) envelope tag remains rejected")
            } catch is DecodingError { expect(true, "\(label) envelope tag remains rejected") }
            catch { expect(false, "\(label) envelope tag emits a decoding failure") }
        }
        let malformedRequests = [
            #"{"request":{"base":"https://fixture.invalid","path":{"resource":"catalog","type":"movie"}},"content":{"type":"Ready","content":[]}}"#,
            #"{"request":{"base":17,"path":{"resource":"catalog","type":"movie","id":"popular"}},"content":{"type":"Ready","content":[]}}"#
        ]
        for (index, raw) in malformedRequests.enumerated() {
            do {
                _ = try decode(CoreCatalogPage.self, json(raw))
                expect(false, "malformed request \(index) remains rejected")
            } catch is DecodingError { expect(true, "malformed request \(index) remains rejected") }
            catch { expect(false, "malformed request \(index) emits a decoding failure") }
        }
    }

    static func trailerCases() throws {
        let cases: [(String, String, String?, Bool)] = [
            ("raw URL-based link", #""links":[{"name":"Trailer","category":"Trailer","url":"https://www.youtube.com/watch?v=PLl99DlL6b4"}]"#, ytA, true),
            ("legacy name-based link", #""links":[{"name":"https://www.youtube.com/watch?v=PLl99DlL6b4","category":"Trailer"}]"#, ytA, false),
            ("URL wins over legacy name", #""links":[{"name":"https://www.youtube.com/watch?v=xyXX8LXiNJ4","category":"Trailer","url":"https://youtu.be/PLl99DlL6b4"}]"#, ytA, true),
            ("later real URL wins over earlier legacy name", #""links":[{"name":"xyXX8LXiNJ4","category":"Trailer"},{"name":"Trailer","category":"Trailer","url":"https://youtu.be/PLl99DlL6b4"}]"#, ytA, true),
            ("invalid first trailer does not hide later link", #""links":[{"name":"Trailer","category":"Trailer","url":"https://example.invalid/no-video"},{"name":"Trailer","category":"trailer","url":"https://youtu.be/PLl99DlL6b4"}]"#, ytA, true),
            ("invalid URL falls back to legacy name", #""links":[{"name":"PLl99DlL6b4","category":"Trailer","url":"https://example.invalid/no-video"}]"#, ytA, false),
            ("ytId stream keeps priority", #""trailerStreams":[{"ytId":"xyXX8LXiNJ4"}],"links":[{"name":"Trailer","category":"Trailer","url":"https://youtu.be/PLl99DlL6b4"}]"#, ytB, false),
            ("empty ytId falls back to URL", #""trailerStreams":[{"ytId":""}],"links":[{"name":"Trailer","category":"Trailer","url":"https://youtu.be/PLl99DlL6b4"}]"#, ytA, true),
            ("wrong category ignored", #""links":[{"name":"Trailer","category":"Website","url":"https://youtu.be/PLl99DlL6b4"}]"#, nil, false),
            ("missing trailer remains nil", #""links":[]"#, nil, false)
        ]
        for (label, fields, expected, baselineRegression) in cases {
            let payload = try json("{\"id\":\"tt-fixture\",\"type\":\"movie\",\"name\":\"Fixture\",\(fields)}")
            let meta = try decode(CoreMetaItem.self, payload)
            expect(meta.trailerYouTubeID == expected, "\(label): production meta trailer id", baselineRegression: baselineRegression)
            let request = TrailerRequest.from(meta: meta)
            expect(request?.youTubeID == expected && (expected != nil || request == nil), "\(label): production TrailerRequest admission", baselineRegression: baselineRegression)
            if let expected {
                expect(request?.playableURL?.absoluteString == "https://trailer.vortx.tv/yt/\(expected)", "\(label): worker URL matches selected id", baselineRegression: baselineRegression)
            }
        }
        let directMeta = try decode(CoreMetaItem.self, json(#"{"id":"tt-fixture","type":"movie","name":"Fixture","trailerStreams":[{"url":"https://media.fixture.invalid/full-trailer.mp4"},{"ytId":"PLl99DlL6b4"}]}"#))
        let direct = TrailerRequest.from(meta: directMeta)
        expect(direct?.youTubeID == ytA && direct?.directURL?.absoluteString == "https://media.fixture.invalid/full-trailer.mp4", "direct stream retains YouTube rescue provenance")
        expect(direct?.playableURL?.absoluteString == "https://media.fixture.invalid/full-trailer.mp4", "direct URL keeps playback priority over YouTube")
        expect(direct?.nativeFullTrailerURL(preferredYouTubeID: ytB, languageCode: "hi")?.absoluteString == "https://media.fixture.invalid/full-trailer.mp4", "language-preferred id cannot replace direct stream")
    }

    static func main() throws {
        try catalogCases()
        try detailCases()
        try trailerCases()
        print("Issue261 production resource/trailer fixture: \(checks) checks, \(failures.count) failures")
        if baselineMode {
            let observed = Set(failures)
            let unexpected = observed.subtracting(expectedBaselineFailures)
            let missing = expectedBaselineFailures.subtracting(observed)
            guard !expectedBaselineFailures.isEmpty, unexpected.isEmpty, missing.isEmpty else {
                print("FAIL baseline acceptance: \(unexpected.count) failed controls, \(missing.count) missing target regressions")
                for label in unexpected.sorted() { print("Unexpected control failure: \(label)") }
                for label in missing.sorted() { print("Missing baseline regression: \(label)") }
                throw NSError(domain: "Issue261BaselineAcceptance", code: 1)
            }
            print("PASS EXPECTED BASELINE REGRESSIONS: \(expectedBaselineFailures.count) exact target failures; \(checks - expectedBaselineFailures.count) unchanged controls passed")
        } else if !failures.isEmpty {
            throw NSError(domain: "Issue261Fixture", code: failures.count)
        }
    }
}

