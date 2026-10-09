import Foundation
#if canImport(VortxEngine) && VORTX_ENGINE_STATE_BRIDGE
import VortxEngine
#endif

/// The native store ABI, kept separate from the shipping Stremio screen facade. Snapshots belong
/// to the explicit account/profile owner passed by the caller. This layer never reads credentials,
/// writes preferences, migrates legacy storage, or chooses an engine on the user's behalf.
protocol VortxRuntimeABI: Sendable {
    func create(ownerID: String, ownerName: String) -> UInt
    func hydrate(_ snapshot: String) -> UInt
    func dispatch(_ handle: UInt, action: String, now: UInt64) -> String?
    func resolve(_ handle: UInt, request: String) -> String?
    func state(_ handle: UInt) -> String?
    func delta(_ handle: UInt) -> String?
    func free(_ handle: UInt)
}

enum VortxNativeError: Error, Equatable {
    case unavailable, closed, invalidSnapshot, invalidResponse, superseded, checkpointUncertain

    static func diagnosticCode(_ error: Error?) -> String {
        guard let error else { return "not_dispatched" }
        switch error as? Self {
        case .unavailable: return "unavailable"
        case .closed: return "closed"
        case .invalidSnapshot: return "invalid_snapshot"
        case .invalidResponse: return "invalid_response"
        case .superseded: return "superseded"
        case .checkpointUncertain: return "checkpoint_uncertain"
        case nil: return "restore_or_storage_failed"
        }
    }
}

/// Every handle call, replacement and teardown uses the same lock. A failed cold load leaves
/// the previous runtime intact; callers must not interpret that failure as an empty account.
final class VortxNativeRuntime: @unchecked Sendable {
    private let abi: any VortxRuntimeABI
    private let lock = NSLock()
    private var handle: UInt

    init(abi: any VortxRuntimeABI, ownerID: String, ownerName: String) throws {
        self.abi = abi
        handle = abi.create(ownerID: ownerID, ownerName: ownerName)
        guard handle != 0 else { throw VortxNativeError.unavailable }
    }

    init(abi: any VortxRuntimeABI, snapshot: String) throws {
        self.abi = abi
        handle = abi.hydrate(snapshot)
        guard handle != 0 else { throw VortxNativeError.invalidSnapshot }
    }

    deinit { close() }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard handle != 0 else { return }
        let retired = handle
        handle = 0
        abi.free(retired)
    }

    func replaceFromSnapshot(_ snapshot: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard handle != 0 else { throw VortxNativeError.closed }
        let replacement = abi.hydrate(snapshot)
        guard replacement != 0 else { throw VortxNativeError.invalidSnapshot }
        let retired = handle
        handle = replacement
        abi.free(retired)
    }

    func dispatch(_ action: String, now: UInt64) throws -> String {
        try call { abi.dispatch($0, action: action, now: now) }
    }
    func resolve(_ request: String) throws -> String { try call { abi.resolve($0, request: request) } }
    func stateJSON() throws -> String { try call { abi.state($0) } }
    /// Drains the kernel's dirty set. The persistence owner must durably apply the returned delta
    /// before requesting another; this API does not claim an acknowledgement/retry protocol.
    func takeDeltaJSON() throws -> String { try call { abi.delta($0) } }

    private func call(_ operation: (UInt) -> String?) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard handle != 0 else { throw VortxNativeError.closed }
        guard let result = operation(handle) else { throw VortxNativeError.unavailable }
        return result
    }
}

// Deliberate artifact gate: old frameworks contain no public hydration declaration. Enable only
// after the header/export audit passes for every linked slice. Mac/Lite are not newly linked here.
#if canImport(VortxEngine) && VORTX_ENGINE_STATE_BRIDGE
struct VortxCABI: VortxRuntimeABI {
    private func copy(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { vortx_string_free(pointer) }
        return String(cString: pointer)
    }
    func create(ownerID: String, ownerName: String) -> UInt {
        guard let p = vortx_init_runtime(ownerID, ownerName) else { return 0 }
        return UInt(bitPattern: p)
    }
    func hydrate(_ snapshot: String) -> UInt {
        guard let p = vortx_init_from_state_json(snapshot) else { return 0 }
        return UInt(bitPattern: p)
    }
    func dispatch(_ handle: UInt, action: String, now: UInt64) -> String? {
        copy(vortx_dispatch_json(OpaquePointer(bitPattern: handle), action, now))
    }
    func resolve(_ handle: UInt, request: String) -> String? {
        copy(vortx_resolve_json(OpaquePointer(bitPattern: handle), request))
    }
    func state(_ handle: UInt) -> String? { copy(vortx_get_state_json(OpaquePointer(bitPattern: handle))) }
    func delta(_ handle: UInt) -> String? { copy(vortx_get_state_delta_json(OpaquePointer(bitPattern: handle))) }
    func free(_ handle: UInt) { vortx_engine_free(OpaquePointer(bitPattern: handle)) }
}
#endif
