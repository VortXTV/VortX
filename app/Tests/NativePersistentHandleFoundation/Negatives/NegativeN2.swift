import Foundation

// N2: capturing the inout capability in an escaping closure must reject.
func cannotEscapeCapability(_ runtime: VortxNativeRuntime) throws {
    func acceptEscaping(_ callback: @escaping () throws -> String) {}
    try runtime.withReservation { capability in
        acceptEscaping { try capability.stateJSON() }
    }
}
