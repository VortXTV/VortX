// Executable state-machine contract for an in-flight native-debrid refresh and a user engine switch.
//
// Run from repository root:
//   sed -n '/^\/\/ BEGIN native-debrid recovery switch state machine$/,/^\/\/ END native-debrid recovery switch state machine$/p' \
//     app/SourcesTV/TVPlayerView.swift | sed '1d;$d' > /tmp/tv-native-debrid-recovery-state.swift && \
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     /tmp/tv-native-debrid-recovery-state.swift \
//     app/Tests/TVNativeDebridRecoveryStateMachineTests.swift \
//     -o /tmp/tv-native-debrid-recovery-state-test && /tmp/tv-native-debrid-recovery-state-test

import Foundation

@main @MainActor
private enum TVNativeDebridRecoveryStateMachineTests {
    private static var failures = 0

    private static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)")
        }
    }

    static func main() {
        var state = TVNativeDebridRecoveryStateMachine.State()
        guard let firstRecovery = state.beginFreshLink() else {
            check("a failed native-debrid mount begins one fresh-link transaction", false)
            return finish()
        }
        check("a failed native-debrid mount begins one fresh-link transaction", true)
        check("the transaction is visibly in flight", state.freshLinkInFlight)
        check("an engine switch joins the in-flight refresh instead of replacing the stale mount", state.joinEngineSwitch(false))
        check("fresh-link completion consumes the joined engine exactly once", state.finishFreshLink(ownedBy: firstRecovery)?.requestedEngine == false)
        check("completion closes the in-flight transaction", !state.freshLinkInFlight)
        check("the completed source cannot start a second fresh-link request", state.beginFreshLink() == nil)

        state.reset()
        guard let requestedEngineRecovery = state.beginFreshLink(requestedEngine: true) else {
            check("a new source or episode owns a new fresh-link transaction", false)
            return finish()
        }
        check("a new source or episode owns a new fresh-link transaction", true)
        check("the initial engine request survives until fresh-link completion", state.finishFreshLink(ownedBy: requestedEngineRecovery)?.requestedEngine == true)

        state.reset()
        guard let cancelledRecovery = state.beginFreshLink() else {
            check("a cancelled refresh begins", false)
            return finish()
        }
        check("a cancelled refresh begins", true)
        check("a late first-frame cancellation retires only its recovery", state.retireFreshLink(ownedBy: cancelledRecovery))
        check("cancellation releases the in-flight gate", !state.freshLinkInFlight)
        guard let replacementRecovery = state.beginFreshLink() else {
            check("a cancelled refresh permits a second recovery", false)
            return finish()
        }
        check("a cancelled refresh permits a second recovery", true)
        check("a stale cancelled completion cannot finish the replacement", state.finishFreshLink(ownedBy: cancelledRecovery) == nil)
        check("the replacement remains joinable after stale cancellation", state.joinEngineSwitch(false))
        check("the replacement fresh result mounts the joined engine", state.finishFreshLink(ownedBy: replacementRecovery)?.requestedEngine == false)

        finish()
    }

    private static func finish() {
        if failures > 0 { exit(1) }
    }
}
