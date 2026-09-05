import Foundation

@main
enum AppleRemuxRecoveryPolicyTests {
    static func main() {
        var failures = 0
        func check(_ name: String, _ value: Bool) {
            if value { print("PASS  \(name)") }
            else { failures += 1; print("FAIL  \(name)") }
        }

        check("terminal dead input hops immediately",
              AppleRemuxRecoveryPolicy.terminalDecision(
                failed: true, inputProvablyDead: true,
                ownerCurrent: true, hasStartedPlaying: false) == .hopSource)
        check("terminal mux failure demotes same source",
              AppleRemuxRecoveryPolicy.terminalDecision(
                failed: true, inputProvablyDead: false,
                ownerCurrent: true, hasStartedPlaying: false) == .demoteEngine)
        check("failed receipt never waits for stall budget",
              AppleRemuxRecoveryPolicy.terminalDecision(
                failed: true, inputProvablyDead: false,
                ownerCurrent: true, hasStartedPlaying: false) != .cancel)
        check("nonterminal progress remains watchdog-owned",
              AppleRemuxRecoveryPolicy.terminalDecision(
                failed: false, inputProvablyDead: false,
                ownerCurrent: true, hasStartedPlaying: false) == .cancel)
        check("stale watchdog cannot recover a replacement",
              AppleRemuxRecoveryPolicy.terminalDecision(
                failed: true, inputProvablyDead: true,
                ownerCurrent: false, hasStartedPlaying: false) == .cancel)
        check("late failure after first frame cannot touch playback",
              AppleRemuxRecoveryPolicy.terminalDecision(
                failed: true, inputProvablyDead: true,
                ownerCurrent: true, hasStartedPlaying: true) == .cancel)

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
