// EngineChangeGate: a screen hears engine changes only while on view, and catches up once.
// Run: scripts/test-engine-observation.sh

import Combine
import Foundation

final class CoreBridge: ObservableObject {
    static let shared = CoreBridge()
    @Published var revision = 0
    @Published var streamsEpoch = 0
    @Published var metaDetails: String?
}

private var failures = 0
private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

@main
enum EngineChangeGateTests {
    static func main() {
        let core = CoreBridge()
        let gate = EngineChangeGate(core: core)
        var heard = 0
        let subscription = gate.objectWillChange.sink { heard += 1 }
        core.revision += 1
        check("an open gate forwards every engine change", heard == 1)
        gate.setOpen(false, announce: true)
        core.revision += 1; core.revision += 1
        check("a closed gate stays silent", heard == 1)
        gate.setOpen(true, announce: true)
        check("reopening after missed changes catches up exactly once", heard == 2)
        gate.setOpen(true, announce: true)
        check("reopening an open gate sends nothing", heard == 2)
        gate.setOpen(false, announce: false)
        gate.setOpen(true, announce: true)
        check("reopening with nothing missed sends nothing", heard == 2)
        gate.setOpen(false, announce: false)
        core.revision += 1
        gate.setOpen(true, announce: false)
        check("a silent reopen (the screen is already re-rendering) sends nothing", heard == 2)
        core.revision += 1
        check("after a silent reopen changes flow again", heard == 3)
        withExtendedLifetime(subscription) {}

        // The player hears only what it draws: no rebuild for the raw per-event revision bump.
        let player = PlayerEngineChanges(core: core)
        var redraws = 0
        let playerSubscription = player.objectWillChange.sink { redraws += 1 }
        core.revision += 1; core.revision += 1; core.revision += 1
        check("the player ignores the per-event revision bump", redraws == 0)
        core.streamsEpoch += 1
        check("the player redraws when streams change", redraws == 1)
        core.metaDetails = "tt0903747"
        check("the player redraws when the loaded title changes", redraws == 2)
        player.followAll(true)
        check("opening a source list catches up once", redraws == 3)
        core.revision += 1
        check("with a source list open every engine change redraws", redraws == 4)
        player.followAll(true)
        check("following again sends nothing", redraws == 4)
        player.followAll(false)
        core.revision += 1
        check("closing the source list stops the per-event redraws", redraws == 4)
        withExtendedLifetime(playerSubscription) {}
        if failures > 0 { print("\n\(failures) check(s) failed"); exit(1) }
        print("\nAll engine gate checks passed")
    }
}
