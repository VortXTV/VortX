// Executable harness for the terminal-failure ownership contract (REQ-260721-78, option A).
//
//   xcrun swiftc -o /tmp/terminal-load-failure-contract-test \
//     app/Sources/Player/TerminalLoadFailurePolicy.swift \
//     app/Tests/TerminalLoadFailureContractTests.swift && /tmp/terminal-load-failure-contract-test
//
// The property under test: once the surface publishes a TERMINAL load failure, a late
// display-criteria / attach completion minted by the failed load must be INERT: no display mode
// apply, no item attach, no playback start, no state resurrection. The surfaces themselves pull in
// SwiftUI and AVFoundation and cannot compile here, so the ordering decision every terminal branch
// routes through lives in the Foundation-only TerminalLoadFailurePolicy, and this suite executes it
// against a model of the engine's token gate (mint on load, invalidate on stop, deferred work
// checks ownership before acting), which is exactly the machinery AVPlayerEngineController.stop()
// drives (invalidateLoadToken + itemGeneration advance + pre-attach cancellation).
//
// The bar is mutation survival: dropping the retire step, or publishing before retiring, must turn
// this suite RED.

import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

/// A minimal model of the native engine's ownership gate: load() mints a ticket (the load token /
/// item generation), stop() retires the mount and advances the generation, and the delayed
/// display-criteria completion applies only while its mint still owns the engine (mirrors the
/// owns(_:loadToken:) guard on AVPlayerEngine's pre-attach path).
final class TokenGatedEngine {
    private(set) var generation = 0
    private(set) var stopped = false
    private(set) var displayModeApplied = false
    private(set) var itemAttached = false
    private(set) var playbackStarted = false

    func load() -> Int {
        stopped = false
        generation += 1
        return generation
    }

    func stop() {
        stopped = true
        generation += 1
    }

    /// The delayed preferredDisplayCriteria completion for the load that minted `ticket`.
    func fireLateDisplayCriteriaCompletion(ticket: Int) {
        guard !stopped, ticket == generation else { return }
        displayModeApplied = true
        itemAttached = true
        playbackStarted = true
    }
}

/// A minimal model of the surface: the terminal flag behind the error overlay.
final class SurfaceModel {
    private(set) var loadFailed = false
    func publishOverlay() { loadFailed = true }
}

// Compiling several files together means only a `main.swift` may carry top-level expressions, so
// the run body is a function invoked from `@main`, matching the other standalone suites here.
@main
enum TerminalLoadFailureContractTests {
    static func main() { run() }
}

func run() {

// MARK: - Scoping: which mounted engine gets retired

check("scope: the native (AVFoundation) engine is retired before publishing",
      TerminalLoadFailurePolicy.shouldRetireBeforePublish(engineIsNative: true))
check("scope: libmpv is NOT retired (its stop() destroys the core and would kill the overlay's Retry)",
      !TerminalLoadFailurePolicy.shouldRetireBeforePublish(engineIsNative: false))

// MARK: - Ordering: retire and publish both run, exactly once, retire strictly first

var order: [String] = []
TerminalLoadFailurePolicy.presentTerminal(
    retire: { order.append("retire") },
    publish: { order.append("publish") })
check("order: retire runs, publish runs, retire strictly first", order == ["retire", "publish"])

// MARK: - The property: a late completion after the terminal publication is inert

do {
    let engine = TokenGatedEngine()
    let surface = SurfaceModel()
    let ticket = engine.load()   // the failed native-HLS DV load minted this ticket

    // The surface goes terminal through the one legal ordering.
    TerminalLoadFailurePolicy.presentTerminal(
        retire: { engine.stop() },
        publish: { surface.publishOverlay() })

    // The delayed display-criteria completion for the dead load lands late.
    engine.fireLateDisplayCriteriaCompletion(ticket: ticket)

    check("inert: no display mode apply behind the terminal overlay", !engine.displayModeApplied)
    check("inert: no item attach behind the terminal overlay", !engine.itemAttached)
    check("inert: no playback start behind the terminal overlay", !engine.playbackStarted)
    check("inert: the overlay stays terminal (no state resurrection)", surface.loadFailed)
}

// MARK: - The nasty timing: the completion lands DURING the publication turn

// If the ordering were publish-then-retire, a completion firing in the same turn as the publication
// would still own the engine and would apply. Retire-first makes even that landing inert.
do {
    let engine = TokenGatedEngine()
    let surface = SurfaceModel()
    let ticket = engine.load()
    TerminalLoadFailurePolicy.presentTerminal(
        retire: { engine.stop() },
        publish: {
            surface.publishOverlay()
            engine.fireLateDisplayCriteriaCompletion(ticket: ticket)   // lands mid-publication
        })
    check("mid-publication completion is inert (retire already happened)",
          !engine.displayModeApplied && !engine.itemAttached && !engine.playbackStarted)
}

// MARK: - Idempotency: a double terminal presentation cannot trap or resurrect

do {
    let engine = TokenGatedEngine()
    let surface = SurfaceModel()
    let ticket = engine.load()
    TerminalLoadFailurePolicy.presentTerminal(
        retire: { engine.stop() }, publish: { surface.publishOverlay() })
    // A dismissal or a second terminal branch double-fires the presentation.
    TerminalLoadFailurePolicy.presentTerminal(
        retire: { engine.stop() }, publish: { surface.publishOverlay() })
    engine.fireLateDisplayCriteriaCompletion(ticket: ticket)
    check("idempotent: double presentation, late completion still inert, overlay still terminal",
          !engine.playbackStarted && surface.loadFailed)
}

// MARK: - Retry stays alive: a FRESH load after the terminal overlay still works

do {
    let engine = TokenGatedEngine()
    let surface = SurfaceModel()
    let staleTicket = engine.load()
    TerminalLoadFailurePolicy.presentTerminal(
        retire: { engine.stop() }, publish: { surface.publishOverlay() })
    let freshTicket = engine.load()   // the overlay's Retry re-loads
    engine.fireLateDisplayCriteriaCompletion(ticket: staleTicket)
    check("retry: the stale completion still cannot act on the fresh mount", !engine.playbackStarted)
    engine.fireLateDisplayCriteriaCompletion(ticket: freshTicket)
    check("retry: the fresh mount's own completion DOES act", engine.playbackStarted)
}

// MARK: - Result

print("")
if failures == 0 { print("ALL PASS"); exit(0) } else { print("\(failures) FAILED"); exit(1) }
}
