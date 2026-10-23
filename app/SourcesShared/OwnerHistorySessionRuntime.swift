import Foundation
import Darwin
import VortxEngine

/// Dedicated opaque-session ABI. An Engine ABI or UInt from VortxNativeRuntime cannot be used
/// here. Every return still requires its documented host validation; no method acknowledges disk.
protocol OwnerHistorySessionABI: Sendable {
    typealias Verify = @Sendable (Data) throws -> Void
    func open(_ snapshot: String, verify: @escaping Verify) -> UInt
    func fork(_ session: UInt, fence: String, verify: @escaping Verify) -> UInt
    func request(_ session: UInt, json: String, now: UInt64, verify: @escaping Verify) -> String?
    func free(_ session: UInt)
}

final class OwnerHistorySessionRuntime: @unchecked Sendable {
    typealias Verify = OwnerHistorySessionABI.Verify
    private let abi: any OwnerHistorySessionABI
    private let lock = NSLock()
    private var handle: UInt
    private var inCall = false
    let identity = UUID()
    static let maximumBytes = 16 * 1024 * 1024

    init(snapshot: Data, abi: any OwnerHistorySessionABI, verify: @escaping Verify) throws {
        let text = try Self.input(snapshot)
        let opened = abi.open(text, verify: verify)
        guard opened != 0 else { throw VortxNativeError.invalidSnapshot }
        self.handle = opened; self.abi = abi
    }
    private init(handle: UInt, abi: any OwnerHistorySessionABI) {
        self.handle = handle; self.abi = abi
    }
    deinit { precondition(close(), "session released during an active native call") }

    @discardableResult func close() -> Bool {
        let retired: UInt? = lock.withLock {
            guard !inCall else { return nil }
            let value = handle; handle = 0; return value
        }
        guard let retired else { return false }
        if retired != 0 { abi.free(retired) }
        return true
    }

    /// Metadata lock is NOT held while C invokes the host verifier. A synchronous verifier
    /// may lock existing provider/session/Bridge/facade authorities in their normal order.
    /// Reentrant/concurrent stateful calls fail busy; free cannot race an active callback.
    private func call<T>(_ operation: (UInt) throws -> T) throws -> T {
        let current = try lock.withLock { () throws -> UInt in
            guard !inCall else { throw VortxNativeRuntime.OwnershipFailure.busy }
            guard handle != 0 else { throw VortxNativeError.closed }
            inCall = true; return handle
        }
        defer { lock.withLock { inCall = false } }
        return try withExtendedLifetime(self) { try operation(current) }
    }
    func fork(fence: Data, verify: @escaping Verify) throws -> OwnerHistorySessionRuntime {
        let json = try Self.input(fence)
        guard fence.count <= 64 * 1024 else { throw VortxNativeError.invalidResponse }
        let candidate = try call { abi.fork($0, fence: json, verify: verify) }
        guard candidate != 0 else { throw VortxNativeError.superseded }
        return .init(handle: candidate, abi: abi)
    }
    func request(_ request: Data, now: UInt64 = 0, verify: @escaping Verify) throws -> Data {
        let input = try Self.input(request)
        guard let response = try call({ abi.request($0, json: input, now: now, verify: verify) }),
              response.utf8.count <= Self.maximumBytes else { throw VortxNativeError.invalidResponse }
        let bytes = Data(response.utf8)
        let fields = try OwnerHistoryExactJSON.Object(bytes)
        guard try fields.text("kind") != "error" else { throw VortxNativeError.invalidResponse }
        return bytes
    }
    private static func input(_ bytes: Data) throws -> String {
        guard bytes.count <= maximumBytes, let value = String(data: bytes, encoding: .utf8),
              !value.utf8.contains(0) else { throw VortxNativeError.invalidSnapshot }
        return value
    }
}

/// The production adapter is present but unavailable until root builds every selected SDK and
/// explicitly enables its existing recovery proposal flag. This is not a capability advertisement.
struct OwnerHistorySessionCABI: OwnerHistorySessionABI {
    private final class Context {
        let verify: Verify
        init(_ verify: @escaping Verify) { self.verify = verify }
    }
    private static let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Int32 = { context, bytes in
        guard let context, let bytes else { return 0 }
        let length = strnlen(bytes, 32 * 1024 * 1024 + 1)
        guard length <= 32 * 1024 * 1024 else { return 0 }
        do {
            try Unmanaged<Context>.fromOpaque(context).takeUnretainedValue().verify(Data(bytes: bytes, count: length))
            return 1
        } catch { return 0 }
    }
    private func withContext<T>(_ verify: @escaping Verify,
                                _ body: (UnsafeMutableRawPointer) -> T) -> T {
        let context = Unmanaged.passRetained(Context(verify))
        defer { context.release() }
        return body(context.toOpaque())
    }
    private func copy(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { vortx_string_free(pointer) }
        let length = strnlen(pointer, OwnerHistorySessionRuntime.maximumBytes + 1)
        guard length <= OwnerHistorySessionRuntime.maximumBytes else { return nil }
        return String(data: Data(bytes: pointer, count: length), encoding: .utf8)
    }
    func open(_ snapshot: String, verify: @escaping Verify) -> UInt {
        withContext(verify) { context in
            vortx_owner_history_session_open(snapshot, Self.callback, context).map { UInt(bitPattern: $0) } ?? 0
        }
    }
    func fork(_ session: UInt, fence: String, verify: @escaping Verify) -> UInt {
        withContext(verify) { context in
            vortx_owner_history_session_fork(OpaquePointer(bitPattern: session), fence, Self.callback, context)
                .map { UInt(bitPattern: $0) } ?? 0
        }
    }
    func request(_ session: UInt, json: String, now: UInt64, verify: @escaping Verify) -> String? {
        withContext(verify) { context in
            copy(vortx_owner_history_session_json(OpaquePointer(bitPattern: session), json, now, Self.callback, context))
        }
    }
    func free(_ session: UInt) { vortx_owner_history_session_free(OpaquePointer(bitPattern: session)) }
}
