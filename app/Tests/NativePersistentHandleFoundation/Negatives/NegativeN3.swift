import Foundation

// N3: a Task cannot outlive or asynchronously consume the inout scoped capability.
func cannotSendCapability(_ runtime: VortxNativeRuntime) throws {
    _ = try runtime.withReservation { capability in
        Task { _ = try capability.stateJSON() }
    }
}
