import Foundation

// N1: returning the noncopyable inout capability as a Copyable generic result must reject.
func cannotReturnCapability(_ runtime: VortxNativeRuntime) throws {
    _ = try runtime.withReservation { capability -> VortxNativeRuntime.Reservation in
        return capability
    }
}
