import Foundation
#if canImport(VortxEngine) && VORTX_ENGINE_RESOURCE_HOST
import VortxEngine
#endif

/// Lossless JSON at the addon boundary: preserve headers, subtitle options, binge hints and
/// provider extensions instead of rebuilding a reduced stream from a ranking decision.
indirect enum VortxJSON: Codable, Equatable, Sendable {
    case object([String: VortxJSON]), array([VortxJSON]), string(String), integer(Int64), unsigned(UInt64), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: VortxJSON].self) { self = .object(v) }
        else if let v = try? c.decode([VortxJSON].self) { self = .array(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(UInt64.self) { self = .unsigned(v) }
        else { self = .number(try c.decode(Double.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .unsigned(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> VortxJSON? {
        guard case .object(let v) = self else { return nil }; return v[key]
    }
    var array: [VortxJSON]? { guard case .array(let v) = self else { return nil }; return v }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
}

struct VortxResourceRequest: Codable, Equatable, Sendable {
    enum Resource: String, Codable, Sendable { case catalog, meta, stream, subtitles, manifest, addonCatalog = "addon_catalog" }
    let resource: Resource
    let type: String
    let id: String
    var extra: [[String]] = []
}

struct VortxResourceAddon: Codable, Sendable {
    let id: String
    let transportUrl: String
    let manifest: VortxJSON?
}

struct VortxResourceGroup: Decodable, Sendable {
    enum Status: String, Decodable, Sendable { case ready, error, timeout, cancelled }
    /// Only controlled categories and a bounded HTTP status cross into presentation/diagnostics.
    /// Never retain a transport's arbitrary error description: it may contain configured URLs.
    struct Failure: Error, Decodable, Sendable {
        let code: String
        let status: Int?
        private static let codes: Set<String> = ["invalid_request", "invalid_source", "unsupported_resource",
            "network", "http", "timeout", "cancelled", "body_too_large", "malformed", "unavailable",
            "invalid_response", "empty_resource", "native_resource_failed", "native_catalog_failed",
            "closed", "invalid_snapshot", "superseded", "checkpoint_uncertain"]
        init(code: String, status: Int? = nil) {
            self.code = Self.codes.contains(code) ? code : "native_resource_failed"
            self.status = self.code == "http" ? status.flatMap { (100...599).contains($0) ? $0 : nil } : nil
        }
        private enum CodingKeys: String, CodingKey { case code, status }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(code: try values.decode(String.self, forKey: .code),
                      status: try? values.decode(Int.self, forKey: .status))
        }
        static func from(_ error: Error) -> Self {
            if error is CancellationError { return .init(code: "cancelled") }
            if error is DecodingError { return .init(code: "invalid_response") }
            if error is VortxNativeError { return .init(code: VortxNativeError.diagnosticCode(error)) }
            return .init(code: "native_resource_failed")
        }
        var userMessage: String {
            switch code {
            case "http":
                if let status { return status == 429 ? "Add-on rate limited (HTTP 429). Try again later." : "Add-on returned HTTP \(status)." }
                return "Add-on returned an HTTP error."
            case "network": return "Add-on network request failed."
            case "timeout": return "Add-on request timed out. Try again."
            case "malformed", "invalid_response": return "Could not read the add-on response."
            case "invalid_request", "invalid_source": return "Add-on configuration could not be used."
            case "unsupported_resource", "empty_resource": return "No results for this request."
            case "body_too_large": return "Add-on response exceeded the size limit."
            case "cancelled", "closed", "superseded": return "Add-on request was cancelled."
            default: return "Add-on request could not be completed. Try again."
            }
        }
    }
    let addonId: String
    let status: Status
    let content: VortxJSON?
    let error: Failure?

    static func failed(addonId: String, failure: Failure) -> Self {
        let status: Status = failure.code == "timeout" ? .timeout :
            ["cancelled", "closed", "superseded"].contains(failure.code) ? .cancelled : .error
        return .init(addonId: addonId, status: status, content: nil, error: failure)
    }

    /// A request-local ordinal identifies a source without logging its URL, manifest, name or ID.
    /// Call only after the consumer's ticket/epoch and bridge acceptance checks, once per leg.
    func terminalDiagnostic(requestID: UUID, request: VortxResourceRequest, sourceOrdinal: Int) -> String {
        let prefix = "request=\(requestID.uuidString) resource=\(request.resource.rawValue) source=\(sourceOrdinal)"
        if status == .ready {
            guard let items = try? items(for: request.resource) else { return "\(prefix) result=error code=invalid_response" }
            let count = items.count
            return "\(prefix) result=\(count == 0 ? "empty" : "ready") items=\(count)"
        }
        let failure = error ?? .init(code: status.rawValue)
        return "\(prefix) result=error code=\(failure.code)" + (failure.status.map { " status=\($0)" } ?? "")
    }

    /// All results remain grouped under the exact registry identity. No cross-addon de-duplication,
    /// sorting, dropped subtitle tracks, or substitution of metadata from an unrelated request.
    func items(for resource: VortxResourceRequest.Resource) throws -> [VortxJSON] {
        guard status == .ready else { return [] }
        guard case .object = content else { throw VortxNativeError.invalidResponse }
        if resource == .manifest { return [content!] }
        if resource == .meta {
            guard let meta = content?["meta"] else { throw VortxNativeError.invalidResponse }
            if meta == .null { return [] }
            guard case .object = meta else { throw VortxNativeError.invalidResponse }
            return [meta]
        }
        let key: String
        switch resource {
        case .catalog: key = "metas"
        case .stream: key = "streams"
        case .subtitles: key = "subtitles"
        case .addonCatalog: key = "addons"
        case .meta: key = "meta"
        case .manifest: key = ""
        }
        guard let items = content?[key]?.array else { throw VortxNativeError.invalidResponse }
        guard items.allSatisfy({ if case .object = $0 { return true }; return false })
        else { throw VortxNativeError.invalidResponse }
        return items
    }
}

struct VortxResourceSnapshot: Sendable {
    let ownerID: String
    let requestID: String
    let generation: UInt64
    let request: VortxResourceRequest
    let groups: [VortxResourceGroup]
    /// Original registry identity, retained in memory only. A later configuration may reuse an addon
    /// ID with a different transport; it must not relabel an earlier response as that new source.
    let sourceURLs: [String: String]
}

/// Bounds retained normalized result content across singleton calls. This intentionally does
/// not claim to measure consumed wire bytes (the ABI does not return that receipt).
struct VortxResourceContentBudget {
    private(set) var usedBytes = 0
    private let limit = 33_554_432
    mutating func claim(_ content: VortxJSON) throws -> Bool {
        let bytes = try JSONEncoder().encode(content).count
        guard bytes <= limit - usedBytes else { return false }
        usedBytes += bytes; return true
    }
}

protocol VortxResourceCancellation: AnyObject, Sendable { func cancel() }
protocol VortxResourceTransport: Sendable {
    func makeCancellation() throws -> any VortxResourceCancellation
    /// Blocking, bounded native I/O; always called on a worker queue. The cancellation object and
    /// transport remain strongly owned until this returns, even after cancellation or close.
    func load(_ requestJSON: String, cancellation: any VortxResourceCancellation) throws -> String
}

/// One instance per consumer/screen. A new load or explicit owner invalidation cancels its previous
/// operation and revokes publication even if the transport ignores cancellation. No disk persistence.
final class VortxResourceBridge: @unchecked Sendable {
    private struct Lease: Equatable { let owner: String; let id: String; let generation: UInt64 }
    private struct WireRequest: Encodable {
        let requestId: String; let generation: UInt64; let request: VortxResourceRequest
        let addons: [VortxResourceAddon]; let budgetMs: UInt64; let maxResponseBytes: UInt64
        let maxTotalResponseBytes: UInt64
    }
    private struct WireResult: Decodable {
        let kind: String; let requestId: String; let generation: UInt64
        let request: VortxResourceRequest; let groups: [VortxResourceGroup]; let cancelled: Bool
    }
    private let transport: any VortxResourceTransport
    private let lock = NSLock()
    private let workers = DispatchQueue(label: "tv.vortx.native-resources", qos: .userInitiated, attributes: .concurrent)
    private var sequence: UInt64 = 0
    private var current: Lease?
    private var cancellation: (any VortxResourceCancellation)?

    init(transport: any VortxResourceTransport) { self.transport = transport }
    deinit { invalidate() }

    func invalidate() {
        lock.lock()
        current = nil
        let previous = cancellation; cancellation = nil
        lock.unlock()
        previous?.cancel()
    }

    func accepts(_ snapshot: VortxResourceSnapshot) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current == Lease(owner: snapshot.ownerID, id: snapshot.requestID, generation: snapshot.generation)
    }

    private func begin(owner: String, token: any VortxResourceCancellation) throws -> Lease {
        lock.lock()
        guard sequence < UInt64.max else { lock.unlock(); throw VortxNativeError.unavailable }
        sequence += 1
        let lease = Lease(owner: owner, id: UUID().uuidString, generation: sequence)
        let previous = cancellation
        current = lease; cancellation = token
        lock.unlock()
        previous?.cancel()
        return lease
    }

    private func cancel(_ lease: Lease, token: any VortxResourceCancellation) {
        lock.lock()
        if current == lease { current = nil; cancellation = nil }
        lock.unlock()
        token.cancel()
    }

    func load(ownerID: String, request: VortxResourceRequest, addons: [VortxResourceAddon],
              budgetMs: UInt64 = 5000, maxResponseBytes: UInt64 = 8_388_608,
              maxTotalResponseBytes: UInt64 = 33_554_432) async throws -> VortxResourceSnapshot {
        guard !ownerID.isEmpty, Set(addons.map(\.id)).count == addons.count,
              addons.allSatisfy({ !$0.id.isEmpty }), request.extra.allSatisfy({ $0.count == 2 }),
              (1...60_000).contains(budgetMs), (1...33_554_432).contains(maxResponseBytes),
              (1...67_108_864).contains(maxTotalResponseBytes)
        else { throw VortxNativeError.invalidResponse }
        let token = try transport.makeCancellation()
        let lease = try begin(owner: ownerID, token: token)
        let wire = WireRequest(requestId: lease.id, generation: lease.generation, request: request,
                               addons: addons, budgetMs: budgetMs, maxResponseBytes: maxResponseBytes,
                               maxTotalResponseBytes: maxTotalResponseBytes)
        let json = String(decoding: try JSONEncoder().encode(wire), as: UTF8.self)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                workers.async { [self] in
                    do {
                        let output = try transport.load(json, cancellation: token)
                        let result = try JSONDecoder().decode(WireResult.self, from: Data(output.utf8))
                        guard result.kind == "resource_result", result.requestId == lease.id,
                              result.generation == lease.generation, result.request == request,
                              Set(result.groups.map(\.addonId)).count == result.groups.count,
                              result.groups.allSatisfy({ group in addons.contains { $0.id == group.addonId } })
                        else { throw VortxNativeError.invalidResponse }
                        guard !result.cancelled else { throw CancellationError() }
                        let groups = result.groups.map { group -> VortxResourceGroup in
                            do { _ = try group.items(for: request.resource); return group }
                            catch {
                                // The envelope above still owns request/source identity. A malformed
                                // payload belongs to this addon only; do not discard valid peers.
                                NSLog("[VortXNative] resource=%@ result=partial_error category=invalid_response", request.resource.rawValue)
                                return .init(addonId: group.addonId, status: .error, content: nil, error: .init(code: "invalid_response"))
                            }
                        }
                        let snapshot = VortxResourceSnapshot(ownerID: ownerID, requestID: lease.id,
                            generation: lease.generation, request: request, groups: groups,
                            sourceURLs: Dictionary(uniqueKeysWithValues: addons.map { ($0.id, $0.transportUrl) }))
                        guard accepts(snapshot) else { throw VortxNativeError.superseded }
                        continuation.resume(returning: snapshot)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { [self] in cancel(lease, token: token) }
    }
}

#if canImport(VortxEngine) && VORTX_ENGINE_RESOURCE_HOST
/// Artifact-gated live transport. No shared mutable kernel handle participates in network calls.
final class VortxCResourceTransport: VortxResourceTransport, @unchecked Sendable {
    private let host: UnsafeMutableRawPointer
    init() throws {
        guard vortx_resource_host_abi_version() == 1 else { throw VortxNativeError.unavailable }
        guard let host = vortx_resource_host_new() else { throw VortxNativeError.unavailable }
        self.host = host
    }
    deinit { vortx_resource_host_free(host) }
    func makeCancellation() throws -> any VortxResourceCancellation { try Token() }
    func load(_ requestJSON: String, cancellation: any VortxResourceCancellation) throws -> String {
        guard let token = cancellation as? Token,
              let out = vortx_resource_host_load_json(host, requestJSON, token.handle)
        else { throw VortxNativeError.unavailable }
        defer { vortx_string_free(out) }
        return String(cString: out)
    }
    private final class Token: VortxResourceCancellation, @unchecked Sendable {
        let handle: UnsafeMutableRawPointer
        init() throws {
            guard let value = vortx_cancel_new() else { throw VortxNativeError.unavailable }
            handle = value
        }
        deinit { vortx_cancel_free(handle) }
        func cancel() { vortx_cancel_cancel(handle) }
    }
}
#endif
