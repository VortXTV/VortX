import XCTest
import Foundation

// Actual defaults model/feed tests with injected lifecycle, clock and loader seams.
// Run with scripts/test-curation-defaults.sh; no account, device or network is used.
@MainActor
final class CurationDefaultsTests: XCTestCase {
    private static let wire = """
    {
      "schemaVersion": 1,
      "revision": "2026-10-20.1",
      "collections": [{
        "id": "vortx.editorial",
        "name": "VortX Collections",
        "revision": "2026-10-20.1",
        "base": {
          "pinned": false,
          "presentation": {"layout":"tabs","tileShape":"landscape","showAll":true,"hideTitle":false},
          "folders": [
            {"id":"acclaimed","name":"Critically Acclaimed","presentation":{"layout":"grid","tileShape":"poster","showAll":true,"hideTitle":false},"sources":[{"id":"curated.acclaimed","type":"curated","collectionID":"curated.acclaimed"}]},
            {"id":"hidden-gems","name":"Hidden Gems","presentation":{"layout":"grid","tileShape":"poster","showAll":true,"hideTitle":false},"sources":[{"id":"curated.hidden-gems","type":"curated","collectionID":"curated.hidden-gems"}]},
            {"id":"modern-classics","name":"Modern Classics","presentation":{"layout":"grid","tileShape":"poster","showAll":true,"hideTitle":false},"sources":[{"id":"curated.modern-classics","type":"curated","collectionID":"curated.modern-classics"}]},
            {"id":"award-winners","name":"Award Winners","presentation":{"layout":"grid","tileShape":"poster","showAll":true,"hideTitle":false},"sources":[{"id":"curated.award-winners","type":"curated","collectionID":"curated.award-winners"}]}
          ]
        }
      }]
    }
    """

    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func read() -> Value { lock.lock(); defer { lock.unlock() }; return value }
        func write(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
        func update(_ body: (inout Value) -> Void) {
            lock.lock(); body(&value); lock.unlock()
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func write(_ value: Date) { lock.lock(); self.value = value; lock.unlock() }
    }

    @MainActor
    private final class ScopeBox {
        var value: CurationDefaultsRequestScope?
        init(_ value: CurationDefaultsRequestScope?) { self.value = value }
    }

    private actor ContinuationGate {
        private var entered = false
        private var released = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func enterAndWait() async {
            entered = true
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if released { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiters.append($0) }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func data(_ text: String = CurationDefaultsTests.wire) -> Data { Data(text.utf8) }

    private func replacing(_ old: String, with new: String,
                           in text: String = CurationDefaultsTests.wire) -> Data {
        data(text.replacingOccurrences(of: old, with: new))
    }

    private func replacing(_ old: String, _ new: String,
                           text: String = CurationDefaultsTests.wire) -> Data {
        replacing(old, with: new, in: text)
    }

    private func feed(_ text: String = CurationDefaultsTests.wire) throws -> CurationDefaultsFeed {
        try CurationDefaultsFeed(data: data(text))
    }

    private func fallback(_ name: String = "Local fallback") -> [CurationCollection] {
        [CurationCollection(id: "fallback", name: name, home: false, pinned: false,
                            folders: [], presentation: .init(), artwork: .init())]
    }

    private func scope(_ source: UInt64, session: UInt64 = 1, consent: UInt64 = 1,
                       signedIn: Bool = true) -> CurationDefaultsRequestScope {
        .init(endpoint: URL(string: "https://catalogs.vortx.tv/curation/v1/defaults")!,
              lifecycle: .init(sourceGeneration: source, sessionGeneration: session,
                               consentGeneration: consent), isSignedIn: signedIn)
    }

    private func makeModel(
        scopeBox: ScopeBox,
        clock: Clock,
        fallback: [CurationCollection],
        loader: @escaping CurationDefaultsModel.Loader
    ) -> CurationDefaultsModel {
        CurationDefaultsModel(loader: loader,
            scopeProvider: { scopeBox.value },
            fallback: { fallback },
            now: { clock.read() })
    }

    func testValidEnvelopeProjectsExactPublicFolders() throws {
        let feed = try feed()
        XCTAssertEqual(feed.revision, "2026-10-20.1")
        XCTAssertEqual(feed.collections.map(\.id), ["vortx.editorial"])
        let collection = try XCTUnwrap(feed.collections.first)
        XCTAssertEqual(collection.name, "VortX Collections")
        XCTAssertFalse(collection.pinned)
        XCTAssertEqual(collection.presentation.layout, .tabs)
        XCTAssertEqual(collection.presentation.tileShape, .landscape)
        XCTAssertEqual(collection.folders.map(\.id), ["acclaimed", "hidden-gems", "modern-classics", "award-winners"])
        XCTAssertEqual(collection.folders.flatMap(\.sources).map(\.id), [
            "curated.acclaimed", "curated.hidden-gems", "curated.modern-classics", "curated.award-winners"
        ])
    }

    func testDecoderRejectsDuplicateAndUnsafePublicWire() {
        let duplicateEnvelope = replacing("\"schemaVersion\": 1,", with: "\"schemaVersion\": 1,\"schemaVersion\": 1,")
        XCTAssertThrowsError(try CurationDefaultsFeed(data: duplicateEnvelope))
        XCTAssertThrowsError(try CurationDefaultsFeed(data: replacing("\"schemaVersion\": 1", with: "\"schemaVersion\": 2")))
        XCTAssertThrowsError(try CurationDefaultsFeed(data: replacing(
            "\"id\":\"curated.acclaimed\",\"type\":\"curated\",\"collectionID\":\"curated.acclaimed\"",
            "\"id\":\"curated.acclaimed\",\"type\":\"legacyRules\",\"collectionID\":\"legacy\""
        )))
        XCTAssertThrowsError(try CurationDefaultsFeed(data: replacing(
            "\"id\":\"curated.acclaimed\",\"type\":\"curated\",\"collectionID\":\"curated.acclaimed\"",
            "\"id\":\"duplicate\",\"type\":\"curated\",\"collectionID\":\"curated.acclaimed\"},{\"id\":\"duplicate\",\"type\":\"curated\",\"collectionID\":\"curated.acclaimed\""
        )))
        let oversized = replacing("\"revision\": \"2026-10-20.1\"",
            "\"revision\": \"2026-10-20.1\",\"oversized\":\"\(String(repeating: "x", count: 17_000))\"")
        XCTAssertGreaterThan(oversized.count, CurationDefaultsFeed.maximumBytes)
        XCTAssertThrowsError(try CurationDefaultsFeed(data: oversized))
    }

    func testUnknownEnvelopeEntryAndBaseFieldsRemainRaw() throws {
        let unknownEnvelope = replacing("\"schemaVersion\": 1,",
            "\"schemaVersion\": 1,\"unknownEnvelope\":{\"keep\":true},")
        let unknownEntry = replacing("\"name\": \"VortX Collections\",",
            "\"name\": \"VortX Collections\",\"unknownEntry\":{\"keep\":true},", text: String(decoding: unknownEnvelope, as: UTF8.self))
        let unknownBase = replacing("\"pinned\": false,",
            "\"unknownBase\":{\"keep\":true},\"pinned\": false,", text: String(decoding: unknownEntry, as: UTF8.self))
        let feed = try CurationDefaultsFeed(data: unknownBase)
        XCTAssertEqual(feed.raw["unknownEnvelope"], .object(["keep": .bool(true)]))
        XCTAssertEqual(feed.raw["collections"]?.array?.first?["unknownEntry"], .object(["keep": .bool(true)]))
        XCTAssertEqual(feed.raw["collections"]?.array?.first?["base"]?["unknownBase"], .object(["keep": .bool(true)]))
    }

    func testEndpointRequiresFixedHTTPSCatalogsOriginAndOwnPath() {
        let valid = CurationDefaultsClient.endpoint(catalogs: URL(string: "https://catalogs.vortx.tv/other")!)
        XCTAssertEqual(valid, URL(string: "https://catalogs.vortx.tv/curation/v1/defaults"))
        XCTAssertEqual(
            CurationDefaultsClient.endpoint(catalogs: URL(string: "HTTPS://CATALOGS.VORTX.TV:443/3")!),
            URL(string: "https://catalogs.vortx.tv/curation/v1/defaults")
        )
        let explicitDefaultPort = CurationDefaultsClient.endpoint(catalogs: URL(string: "https://catalogs.vortx.tv:443/other")!)
        XCTAssertEqual(explicitDefaultPort?.scheme, "https")
        XCTAssertEqual(explicitDefaultPort?.host, "catalogs.vortx.tv")
        XCTAssertEqual(explicitDefaultPort?.path, "/curation/v1/defaults")
        for raw in [
            "http://catalogs.vortx.tv/other",
            "https://evil.example/other",
            "https://user:pass@catalogs.vortx.tv/other",
            "https://catalogs.vortx.tv:8443/other",
            "https://catalogs.vortx.tv/other?custom=1",
            "https://catalogs.vortx.tv/other#fragment"
        ] {
            XCTAssertNil(CurationDefaultsClient.endpoint(catalogs: URL(string: raw)!))
        }
    }

    func testHealthySameScopeFlightSurvivesPreCancelledJoiner() async throws {
        let scope = scope(1), scopeBox = ScopeBox(scope), clock = Clock(Self.epoch)
        let gate = ContinuationGate(), calls = Locked(0), local = fallback()
        let expected = try feed()
        let model = makeModel(scopeBox: scopeBox, clock: clock, fallback: local) { _ in
            calls.update { $0 += 1 }
            await gate.enterAndWait()
            return expected
        }
        let healthy = Task { @MainActor in await model.loadIfNeeded() }
        await gate.waitUntilEntered()
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await model.loadIfNeeded()
        }
        await cancelled.value
        XCTAssertEqual(calls.read(), 1)
        XCTAssertEqual(model.currentCollections(), local)
        await gate.release()
        await healthy.value
        XCTAssertEqual(model.currentCollections(), expected.collections)
        XCTAssertEqual(calls.read(), 1)
    }

    func testLateAScopeCannotPublishAcrossBAndBackToA() async throws {
        let scopeA = scope(10), scopeB = scope(11), scopeBox = ScopeBox(scopeA), clock = Clock(Self.epoch)
        let oldAGate = ContinuationGate(), calls = Locked(0), local = fallback()
        let oldA = try feed(Self.wire.replacingOccurrences(of: "VortX Collections", with: "Old A"))
        let newA = try feed(Self.wire.replacingOccurrences(of: "VortX Collections", with: "New A"))
        let b = try feed(Self.wire.replacingOccurrences(of: "VortX Collections", with: "B"))
        let model = makeModel(scopeBox: scopeBox, clock: clock, fallback: local) { requested in
            calls.update { $0 += 1 }
            let call = calls.read()
            if call == 1 {
                await oldAGate.enterAndWait()
                return oldA
            }
            if requested == scopeB { return b }
            return newA
        }
        let lateA = Task { @MainActor in await model.loadIfNeeded() }
        await oldAGate.waitUntilEntered()
        scopeBox.value = scopeB
        await model.loadIfNeeded()
        XCTAssertEqual(model.currentCollections(), b.collections)
        scopeBox.value = scopeA
        await model.loadIfNeeded()
        XCTAssertEqual(model.currentCollections(), newA.collections)
        await oldAGate.release()
        await lateA.value
        XCTAssertEqual(model.currentCollections(), newA.collections)
        XCTAssertEqual(calls.read(), 3)
    }

    func testStopCancelsNonCooperatingResultWithoutPublishing() async throws {
        let scopeBox = ScopeBox(scope(20)), clock = Clock(Self.epoch), gate = ContinuationGate()
        let calls = Locked(0), local = fallback(), expected = try feed()
        let model = makeModel(scopeBox: scopeBox, clock: clock, fallback: local) { _ in
            calls.update { $0 += 1 }
            await gate.enterAndWait()
            return expected
        }
        let task = Task { @MainActor in await model.loadIfNeeded() }
        await gate.waitUntilEntered()
        model.stop()
        XCTAssertEqual(model.currentCollections(), local)
        await gate.release()
        await task.value
        XCTAssertEqual(model.currentCollections(), local)
        XCTAssertEqual(calls.read(), 1)
    }

    func testFreshCacheAvoidsFetchAndTransientStaleRetainsLastGood() async throws {
        let scopeBox = ScopeBox(scope(30)), clock = Clock(Self.epoch), calls = Locked(0)
        let expected = try feed(), local = fallback()
        let model = makeModel(scopeBox: scopeBox, clock: clock, fallback: local) { _ in
            calls.update { $0 += 1 }
            if calls.read() == 1 { return expected }
            throw CurationDefaultsFailure.transport
        }
        await model.loadIfNeeded()
        clock.write(Self.epoch.addingTimeInterval(100))
        await model.loadIfNeeded()
        XCTAssertEqual(calls.read(), 1)
        XCTAssertEqual(model.currentCollections(), expected.collections)
        clock.write(Self.epoch.addingTimeInterval(4_000))
        await model.loadIfNeeded()
        XCTAssertEqual(calls.read(), 2)
        XCTAssertEqual(model.currentCollections(), expected.collections)
    }

    func testRetryWindowSuppressesRepeatAndHTTPAuthFailuresClearLastGood() async throws {
        let expected = try feed(), local = fallback()
        let scopeBox = ScopeBox(scope(40)), clock = Clock(Self.epoch), calls = Locked(0)
        let model = makeModel(scopeBox: scopeBox, clock: clock, fallback: local) { _ in
            calls.update { $0 += 1 }
            if calls.read() == 1 { return expected }
            throw CurationDefaultsFailure.transport
        }
        await model.loadIfNeeded()
        clock.write(Self.epoch.addingTimeInterval(4_000))
        await model.loadIfNeeded()
        clock.write(Self.epoch.addingTimeInterval(4_299))
        await model.loadIfNeeded()
        XCTAssertEqual(calls.read(), 2)
        XCTAssertEqual(model.currentCollections(), expected.collections)

        for (offset, code) in [(50, 401), (100, 403), (150, 404)] {
            let codeScope = ScopeBox(scope(UInt64(40 + offset)))
            let codeClock = Clock(Self.epoch)
            let codeCalls = Locked(0)
            let codeModel = makeModel(scopeBox: codeScope, clock: codeClock, fallback: local) { _ in
                codeCalls.update { $0 += 1 }
                if codeCalls.read() == 1 { return expected }
                throw CurationDefaultsFailure.http(code)
            }
            await codeModel.loadIfNeeded()
            XCTAssertEqual(codeModel.currentCollections(), expected.collections)
            codeClock.write(Self.epoch.addingTimeInterval(4_000))
            await codeModel.loadIfNeeded()
            XCTAssertEqual(codeCalls.read(), 2)
            XCTAssertEqual(codeModel.currentCollections(), local)
        }
    }

    func testMaximumStaleAgeAndClockRollbackUseFallback() async throws {
        let expected = try feed(), local = fallback()
        let scopeBox = ScopeBox(scope(60)), clock = Clock(Self.epoch), calls = Locked(0)
        let model = makeModel(scopeBox: scopeBox, clock: clock, fallback: local) { _ in
            calls.update { $0 += 1 }
            return expected
        }
        await model.loadIfNeeded()
        clock.write(Self.epoch.addingTimeInterval(-1))
        XCTAssertEqual(model.currentCollections(), local)
        clock.write(Self.epoch.addingTimeInterval(86_400))
        XCTAssertEqual(model.currentCollections(), local)
        XCTAssertEqual(calls.read(), 1)
    }
}
