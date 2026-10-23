import Foundation
import XCTest

@MainActor final class CurationDefaultsClientTests: XCTestCase {
    private static let wire = Data("""
    {"schemaVersion":1,"revision":"fixture.1","collections":[{"id":"vortx.fixture","name":"Fixture","revision":"fixture.1","base":{"folders":[{"id":"folder","name":"Folder","sources":[{"id":"source","type":"curated","collectionID":"curated.acclaimed"}]}]}}]}
    """.utf8)
    private func scope() -> CurationDefaultsRequestScope {
        .init(endpoint: CurationDefaultsClient.endpoint(catalogs: RemoteConfig.snapshot.catalogsEndpoint)!,
              lifecycle: SourceIndexLifecycleClock.snapshot(), isSignedIn: true)
    }
    func testActualClientSignsAndUsesBoundedInjectedTransport() async throws {
        // The standalone executable must have no production key configuration.
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "VortXEdgeSecret"))
        DefaultsFixture.reset(body: Self.wire)
        let feed = try await CurationDefaultsClient.load(scope())
        XCTAssertEqual(feed.collections.map(\.id), ["vortx.fixture"])
        let calls = DefaultsFixture.state.read().requests
        XCTAssertEqual(calls.count, 1)
        let request = try XCTUnwrap(calls.first)
        XCTAssertEqual(request.url?.absoluteString, "https://catalogs.vortx.tv/curation/v1/defaults")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-vx-moat"), "fixture-only-moat")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-VX-Kid"), "k1")
        XCTAssertNotNil(Int(request.value(forHTTPHeaderField: "X-VX-Ts") ?? ""))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-VX-Sig")?.count, 64)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }
    func testActualClientRejectsWholeEnvelopeAndDoesNotTruncate() async throws {
        let raw = try JSONDecoder().decode(VortxJSON.self, from: Self.wire)
        let valid = try XCTUnwrap(raw["collections"]?.array?.first)
        let invalid = VortxJSON.object(["id": .string("vortx.invalid"), "name": .string("Invalid"),
            "revision": .string("1"), "base": .object(["folders": .string("not-an-array")])])
        for entries in [[valid, invalid], [valid, valid], Array(repeating: valid, count: 9)] {
            let data = try JSONEncoder().encode(VortxJSON.object([
                "schemaVersion": .integer(1), "revision": .string("1"), "collections": .array(entries)]))
            DefaultsFixture.reset(body: data)
            do { _ = try await CurationDefaultsClient.load(scope()); XCTFail("Whole invalid envelope accepted") }
            catch { XCTAssertEqual(error as? CurationDefaultsFailure, .invalidDocument) }
        }
    }
    func testActualClientMapsHTTPAndTransportFailures() async {
        for status in [401, 403, 404, 500] {
            DefaultsFixture.reset(body: Self.wire, status: status)
            do { _ = try await CurationDefaultsClient.load(scope()); XCTFail("HTTP failure accepted") }
            catch { XCTAssertEqual(error as? CurationDefaultsFailure, .http(status)) }
        }
        DefaultsFixture.reset(behavior: .failure)
        do { _ = try await CurationDefaultsClient.load(scope()); XCTFail("Transport failure accepted") }
        catch { XCTAssertEqual(error as? CurationDefaultsFailure, .transport) }
    }
    func testActualTransportEnforcesStreamingCapAndRedirectRejection() async {
        DefaultsFixture.reset(body: Data(repeating: 32, count: CurationDefaultsFeed.maximumBytes + 1))
        do { _ = try await CurationDefaultsClient.load(scope()); XCTFail("Over-cap response accepted") }
        catch { XCTAssertEqual(error as? CurationDefaultsFailure, .transport) }
        DefaultsFixture.reset(body: Self.wire, status: 302)
        do { _ = try await CurationDefaultsClient.load(scope()); XCTFail("Redirect status accepted") }
        catch { XCTAssertEqual(error as? CurationDefaultsFailure, .transport) }
    }
    func testStaleBeforeStampAndDuringStampNeverSends() async {
        DefaultsFixture.reset(body: Self.wire)
        let stale = scope(); _ = SourceIndexLifecycleClock.closeSource()
        do { _ = try await CurationDefaultsClient.load(stale); XCTFail("Stale scope accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(DefaultsFixture.state.read().requests.isEmpty)
        DefaultsFixture.reset(body: Self.wire, retireDuringStamp: true)
        do { _ = try await CurationDefaultsClient.load(scope()); XCTFail("Stamp-retired scope accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(DefaultsFixture.state.read().requests.isEmpty)
    }
    func testStaleAfterResponseCannotPublish() async {
        DefaultsFixture.reset(body: Self.wire, retireDuringResponse: true)
        do { _ = try await CurationDefaultsClient.load(scope()); XCTFail("Response-retired scope accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(DefaultsFixture.state.read().requests.count, 1)
    }
    func testActualTransportCallerCancellation() async {
        DefaultsFixture.reset(behavior: .suspend)
        let requested = scope(), entered = DefaultsFixture.state.read().entered
        let task = Task { try await CurationDefaultsClient.load(requested) }
        await entered.wait()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(DefaultsFixture.state.read().requests.count, 1)
    }
}
