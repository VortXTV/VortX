import Foundation

@main
enum MPVInitializationFailureTests {
    static func main() {
        var state = MPVInitializationFailureState<Int>()
        precondition(state.admit(1) == nil)
        state.fail("creation failed")
        precondition(state.activeToken == nil)
        precondition(state.admit(2) == "creation failed")
        precondition(state.accepts(2))
        precondition(state.admit(3) == "creation failed")
        precondition(!state.accepts(2) && state.accepts(3))
        state.invalidateLoad()
        precondition(!state.accepts(3))
        precondition(state.admit(4) == "creation failed")
        state.stop()
        precondition(!state.accepts(4))
        precondition(state.admit(5) == nil && state.activeToken == nil)
        state.fail("initialization failed")
        precondition(state.admit(6) == "initialization failed")
        let controller = try! String(contentsOfFile: "app/Sources/Player/MPVMetalViewController.swift", encoding: .utf8)
        precondition(!controller.contains("exit(1)"))
        precondition(controller.contains("guard initializationStatus >= 0 else"))
        precondition(controller.contains("initializationFailure.accepts(issuedToken)"))
        precondition(controller.contains("initializationFailure.invalidateLoad()"))
        precondition(controller.contains("initializationFailure.stop()"))
        print("MPV initialization failure: 16 checks passed")
    }
}
