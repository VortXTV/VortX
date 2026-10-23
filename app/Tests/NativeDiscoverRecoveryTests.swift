import Foundation
import CryptoKit

// Test-only ABI and in-memory store are extracted unchanged from VortxNativeSessionTests.
// The real facade, session, resource bridge/projection and CoreDiscover decoder are compiled.
// SESSION_FIXTURES
// DISCOVER_MODELS

struct CoreMeta: Decodable { let id: String }

private final class DiscoverRecoveryTransport: VortxResourceTransport, @unchecked Sendable {
    enum Response { case throwing, failed, ready(String), empty, heldFailure }
    final class Token: VortxResourceCancellation, @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.withLock { value = true } }
        var cancelled: Bool { lock.withLock { value } }
    }
    private let lock = NSLock()
    private var responses: [Response] = []
    private var requests: [VortxResourceRequest] = []
    private var held: Token?
    private var didFinishHeld = false
    let release = DispatchSemaphore(value: 0)
    func queue(_ response: Response) { lock.withLock { responses.append(response) } }
    var lastRequest: VortxResourceRequest? { lock.withLock { requests.last } }
    var heldStarted: Bool { lock.withLock { held != nil } }
    var heldCancelled: Bool { lock.withLock { held?.cancelled == true } }
    var heldFinished: Bool { lock.withLock { didFinishHeld } }
    func makeCancellation() throws -> any VortxResourceCancellation { Token() }
    func load(_ requestJSON: String, cancellation: any VortxResourceCancellation) throws -> String {
        let input = try JSONDecoder().decode(VortxJSON.self, from: Data(requestJSON.utf8))
        let request = try input["request"]!.decode(VortxResourceRequest.self)
        let response: Response = lock.withLock {
            requests.append(request)
            precondition(!responses.isEmpty, "Unexpected provider request")
            return responses.removeFirst()
        }
        let group: VortxJSON
        switch response {
        case .throwing: throw VortxNativeError.unavailable
        case .heldFailure:
            lock.withLock { held = cancellation as? Token }
            precondition(release.wait(timeout: .now() + 10) == .success)
            lock.withLock { didFinishHeld = true }
            throw VortxNativeError.unavailable // Deliberately ignores cancellation.
        case .failed:
            group = .object(["addonId": input["addons"]!.array![0]["id"]!, "status": .string("error"),
                "error": .object(["code": .string("network")])])
        case .ready(let id):
            group = .object(["addonId": input["addons"]!.array![0]["id"]!, "status": .string("ready"),
                "content": .object(["metas": .array([.object(["id": .string(id), "type": .string("movie"), "name": .string(id)])])])])
        case .empty:
            group = .object(["addonId": input["addons"]!.array![0]["id"]!, "status": .string("ready"),
                "content": .object(["metas": .array([])])])
        }
        return String(decoding: try JSONEncoder().encode(VortxJSON.object([
            "kind": .string("resource_result"), "requestId": input["requestId"]!, "generation": input["generation"]!,
            "request": input["request"]!, "groups": .array([group]), "cancelled": .bool(false)])), as: UTF8.self)
    }
}

@main private enum NativeDiscoverRecoveryTests {
    private static func check(_ result: @autoclosure () throws -> Bool, _ label: String) rethrows {
        let passed = try result()
        precondition(passed, label)
        print("PASS \(label)")
    }
    private static func eventually(_ predicate: @Sendable () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Controlled request did not reach expected gate")
    }
    private static let registry: [VortxResourceAddon] = [.init(id: "fixture", transportUrl: "https://fixture.invalid/manifest.json",
        manifest: .object(["catalogs": .array(["popular", "other"].map { id in .object([
            "id": .string(id), "type": .string("movie"), "name": .string(id), "extra": .array([
                .object(["name": .string("genre"), "options": .array([.string("Drama")])]), .object(["name": .string("skip")])])]) })]))]
    private static func make(_ transport: DiscoverRecoveryTransport, registry: [VortxResourceAddon] = registry) async throws -> VortxNativeCoreFacade {
        let session = try VortxNativeSession(scope: .init(account: "discover-fixture", ownerProfileID: "owner"), ownerName: "Owner",
            abi: SessionABI(), store: SessionStore(), transport: transport, allowNewAccount: true)
        return try await VortxNativeCoreFacade.create(session: session, registry: registry, changed: { _ in })
    }
    private static func request(id: String = "popular", extra: [[String]] = []) -> CoreRequest {
        .init(base: registry[0].transportUrl, path: .init(resource: "catalog", type: "movie", id: id, extra: extra))
    }
    private static func load(_ facade: VortxNativeCoreFacade, _ request: CoreRequest? = nil) throws {
        let args: VortxJSON = try request.map { .object(["request": try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode($0))]) } ?? .null
        let action: VortxJSON = .object(["action": .string("Load"), "args": .object(["model": .string("CatalogWithFilters"), "args": args])])
        try check(facade.dispatch(data: try JSONEncoder().encode(action), field: "discover"), "Discover request admitted")
    }
    private static func snapshot(_ facade: VortxNativeCoreFacade) throws -> CoreDiscover {
        try JSONDecoder().decode(CoreDiscover.self, from: facade.stateData("discover")!)
    }
    static func main() async throws {
        let transport = DiscoverRecoveryTransport(), facade = try await make(transport)
        let genre = request(extra: [["genre", "Drama"]])
        transport.queue(.throwing)
        try load(facade, genre)
        await facade.settled()
        let failed = try snapshot(facade)
        check(failed.hasFailedPage && !failed.isLoadingPage && failed.items.isEmpty, "thrown first page settles as decodable failure")
        check(failed.retryRequest == genre, "failure preserves exact selected genre request")
        check(failed.selectable.catalogs.first?.selected == true && failed.selectable.extra.first?.options.last?.selected == true,
              "failure preserves catalog and genre controls")
        transport.queue(.ready("first"))
        try load(facade, failed.retryRequest)
        await facade.settled()
        let recovered = try snapshot(facade)
        check(recovered.items.map(\.id) == ["first"] && !recovered.hasFailedPage && !recovered.isLoadingPage && recovered.retryRequest == nil,
              "exact Retry reaches success and clears terminal error")
        check(transport.lastRequest?.extra == [["genre", "Drama"]], "retry transport receives original genre")

        transport.queue(.failed)
        try load(facade, genre)
        await facade.settled()
        let refresh = try snapshot(facade)
        check(refresh.items.map(\.id) == ["first"] && refresh.hasFailedPage && !refresh.isLoadingPage,
              "returned Err retains last good catalog on refresh")
        transport.queue(.throwing)
        try load(facade, refresh.retryRequest)
        await facade.settled()
        try check(try snapshot(facade).items.map(\.id) == ["first"], "thrown refresh retains last good catalog")
        transport.queue(.ready("recovered"))
        try load(facade, try snapshot(facade).retryRequest)
        await facade.settled()

        transport.queue(.throwing)
        check(facade.dispatch(data: Data(#"{"action":"CatalogWithFilters","args":{"action":"LoadNextPage"}}"#.utf8), field: "discover"), "page admitted")
        await facade.settled()
        let pageError = try snapshot(facade)
        check(pageError.items.map(\.id) == ["recovered"] && pageError.hasFailedPage && !pageError.isLoadingPage, "failed next page settles without discarding first page")
        check(pageError.retryRequest?.path.extra == [["genre", "Drama"], ["skip", "1"]], "page retry preserves exact offset and genre")
        transport.queue(.ready("page-two"))
        try load(facade, pageError.retryRequest)
        await facade.settled()
        let paged = try snapshot(facade)
        check(paged.items.map(\.id) == ["recovered", "page-two"] && !paged.hasFailedPage, "retry replaces failed page and preserves preceding page")

        transport.queue(.heldFailure)
        try load(facade, genre)
        try await eventually { transport.heldStarted }
        transport.queue(.ready("other-selection"))
        try load(facade, request(id: "other"))
        await facade.settled()
        check(transport.heldCancelled, "superseding selection cancels old transport")
        transport.release.signal()
        try await eventually { transport.heldFinished }
        try await Task.sleep(nanoseconds: 30_000_000)
        try check(try snapshot(facade).items.map(\.id) == ["other-selection"] && !snapshot(facade).hasFailedPage,
              "late failed response cannot replace newer selection")
        transport.queue(.empty)
        try load(facade, request(id: "other"))
        await facade.settled()
        let empty = try snapshot(facade)
        check(empty.items.isEmpty && !empty.isLoadingPage && !empty.hasFailedPage, "successful empty page settles as empty")
        await facade.shutdown()

        let contextTransport = DiscoverRecoveryTransport(), context = try await make(contextTransport)
        contextTransport.queue(.heldFailure)
        try load(context)
        try await eventually { contextTransport.heldStarted }
        check(context.dispatch(data: Data(#"{"action":"Vortx","args":{"type":"switch_profile","id":"kid"}}"#.utf8), field: nil), "profile transition admitted")
        await context.settleNativeMutations()
        check(context.stateData("discover") == nil && contextTransport.heldCancelled, "profile change invalidates Discover and cancels old request")
        contextTransport.release.signal()
        try await eventually { contextTransport.heldFinished }
        await context.settled()
        check(context.stateData("discover") == nil, "late failed old-profile response cannot restore old Discover")
        await context.shutdown()

        let noCatalogs = try await make(DiscoverRecoveryTransport(), registry: [])
        try load(noCatalogs)
        let noCatalog = try snapshot(noCatalogs)
        check(noCatalog.items.isEmpty && !noCatalog.isLoadingPage && noCatalog.selectable.catalogs.isEmpty,
              "no installed catalogs settles as decodable empty state")
        await noCatalogs.shutdown()
        print("PASS native Discover failure/retry production-source regression")
    }
}
