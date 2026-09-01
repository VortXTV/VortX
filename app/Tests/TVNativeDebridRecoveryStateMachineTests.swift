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
        check("a failed native-debrid mount begins one fresh-link transaction", state.beginFreshLink())
        check("the transaction is visibly in flight", state.freshLinkInFlight)
        check("an engine switch joins the in-flight refresh instead of replacing the stale mount", state.joinEngineSwitch(false))
        check("fresh-link completion consumes the joined engine exactly once", state.finishFreshLink() == false)
        check("completion closes the in-flight transaction", !state.freshLinkInFlight)
        check("the completed source cannot start a second fresh-link request", !state.beginFreshLink())

        state.reset()
        check("a new source or episode owns a new fresh-link transaction", state.beginFreshLink(requestedEngine: true))
        check("the initial engine request survives until fresh-link completion", state.finishFreshLink() == true)

        if failures > 0 { exit(1) }
    }
}
