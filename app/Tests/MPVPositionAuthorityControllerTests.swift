import Foundation

// EXTRACTED_MODELS

private final class DispatchQueue {
    static let main = DispatchQueue()
    var work: [() -> Void] = []
    func async(execute: @escaping () -> Void) { work.append(execute) }
    func drain() {
        let pending = work
        work = []
        pending.forEach { $0() }
    }
}
private final class Delegate {
    var events: [PlayerTimePositionEvent] = []
    func propertyChange(propertyName: String, data: Any?, loadToken: PlayerLoadToken) {
        if let event = data as? PlayerTimePositionEvent { events.append(event) }
    }
}
private final class Controller {
    var mpv: Int? = 1
    var activeLoadToken: PlayerLoadToken? = PlayerLoadToken()
    let loadTokenLock = NSLock()
    var seekSettlement = MPVSeekSettlementPolicy<PlayerLoadToken>()
    var playDelegate: Delegate? = Delegate()
    init() { seekSettlement.reset(owner: activeLoadToken) }
    func callbackLoadToken() -> PlayerLoadToken? { activeLoadToken }
    func issue(seeking: Bool, accepted: Bool = true) {
        let lease = seekSettlement.beginIssue(owner: activeLoadToken!, seeking: seeking)!
        seekSettlement.completeIssue(lease, accepted: accepted)
    }
    func nativeSeek() { seekSettlement.observeSeek(owner: activeLoadToken!) }
    func nativeRestart(seeking: Bool? = false, eof: Bool? = false) {
        seekSettlement.observeRestart(owner: activeLoadToken!, seeking: seeking, eofReached: eof)
    }
    func queuePosition(_ seconds: Double, seeking: Bool? = false, eof: Bool? = false) {
        let owner = activeLoadToken!
        let evidence = seekSettlement.evidence(owner: owner, seeking: seeking, eofReached: eof)
        emit("time-pos", PlayerTimePositionEvent(seconds: seconds, loadToken: owner, mpvSeekSettlement: evidence),
             loadToken: owner)
    }
    func strictAuthority(_ evidence: MPVSeekSettlementEvidence) -> Bool {
        acceptsCurrentSeekEvent(evidence, owner: activeLoadToken!)
            || acceptsSettledPosition(evidence, owner: activeLoadToken!)
    }
    func replaceSource() {
        activeLoadToken = PlayerLoadToken()
        seekSettlement.reset(owner: activeLoadToken)
    }
    var last: PlayerTimePositionEvent? { playDelegate?.events.last }

    // EXTRACTED_CONTROLLER_METHODS
}

@main private enum MPVPositionAuthorityControllerTests {
    static var failures: [String] = []
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { failures.append(message) }
    }
    static func fresh(_ action: (Controller) -> Void) {
        DispatchQueue.main.work = []
        action(Controller())
        DispatchQueue.main.work = []
    }
    static func main() {
        // Policy admission is command-type agnostic: every relative or absolute call uses beginIssue.
        for commands in [["relative", "relative"], ["relative", "relative", "relative", "relative", "relative"],
                         ["absolute", "relative", "absolute", "relative"]] {
            fresh { c in
                for index in commands.indices { c.issue(seeking: index > 0) }
                c.nativeSeek(); c.nativeRestart()
                c.queuePosition(321.25)
                DispatchQueue.main.drain()
                check(c.last?.seconds == 321.25 && c.last?.positionSettled == true,
                      "\(commands.joined(separator: "+")): native settled position survives actual emit")
                check(c.last?.transportSettled == false && c.last?.mpvSeekSettlement?.attributed == false,
                      "ambiguous physical landing must not invent command attribution")
                check(c.last.map { !c.strictAuthority($0.mpvSeekSettlement!) } == true,
                      "resume/start/EOF/recovery admission remains attribution-gated")
            }
        }
        fresh { c in
            c.issue(seeking: false); c.issue(seeking: true)
            c.nativeSeek(); c.nativeRestart()
            c.queuePosition(50)
            c.issue(seeking: false) // Main delivery arrives after the newer accepted command.
            DispatchQueue.main.drain()
            check(c.last?.positionSettled == false && c.last?.transportSettled == false,
                  "queued older-generation position loses authority after a new seek")
            c.nativeRestart() // A stale restart cannot settle a command before its SEEK boundary.
            c.queuePosition(100)
            DispatchQueue.main.drain()
            check(c.last?.positionSettled == false, "old restart before latest SEEK cannot prove a position")
            c.nativeSeek(); c.nativeRestart(); c.queuePosition(100)
            DispatchQueue.main.drain()
            check(c.last?.positionSettled == true && c.last?.transportSettled == true,
                  "a subsequent unambiguous native landing keeps full authority")
        }
        fresh { c in
            c.issue(seeking: false); c.issue(seeking: true)
            c.nativeSeek(); c.nativeRestart(); c.queuePosition(40)
            c.issue(seeking: false, accepted: false)
            DispatchQueue.main.drain()
            check(c.last?.positionSettled == true && c.last?.transportSettled == false,
                  "rejected newer command preserves the accepted physical landing")
        }
        fresh { c in
            c.issue(seeking: false); c.issue(seeking: true)
            c.nativeSeek(); c.nativeRestart(); c.queuePosition(40)
            c.nativeSeek() // Native refresh changes transport generation without a new app command.
            DispatchQueue.main.drain()
            check(c.last?.positionSettled == false, "native refresh retires a queued older physical position")
            c.queuePosition(42); DispatchQueue.main.drain()
            check(c.last?.positionSettled == false, "latest native SEEK still needs its non-EOF restart")
            c.nativeRestart(); c.queuePosition(42); DispatchQueue.main.drain()
            check(c.last?.positionSettled == true && c.last?.transportSettled == false,
                  "latest native restart restores physical position without inventing attribution")
        }
        fresh { c in
            c.issue(seeking: false); c.issue(seeking: true)
            c.nativeSeek(); c.nativeRestart(); c.queuePosition(40)
            c.replaceSource(); DispatchQueue.main.drain()
            check(c.playDelegate?.events.isEmpty == true, "source replacement rejects old queued position")
        }
        fresh { c in
            c.issue(seeking: false); c.issue(seeking: true)
            c.nativeSeek(); c.nativeRestart(); c.queuePosition(40)
            c.mpv = nil; DispatchQueue.main.drain()
            check(c.playDelegate?.events.isEmpty == true, "stop rejects queued position")
        }
        fresh { c in
            c.issue(seeking: false); c.issue(seeking: true)
            c.nativeSeek(); c.nativeRestart()
            // Paused/audio-only native restart can prove the same parked position without clock advance.
            for _ in 0..<3 { c.queuePosition(40); DispatchQueue.main.drain() }
            check(c.playDelegate?.events.allSatisfy { $0.positionSettled && !$0.transportSettled } == true,
                  "paused physical samples need no advancing clock or attribution")
        }
        for state: (Bool?, Bool?) in [(true, false), (nil, false), (false, true), (false, nil)] {
            fresh { c in
                c.issue(seeking: false); c.issue(seeking: true)
                c.nativeSeek(); c.nativeRestart(seeking: state.0, eof: state.1)
                c.queuePosition(321.25, seeking: state.0, eof: state.1)
                DispatchQueue.main.drain()
                check(c.last?.positionSettled == false && c.last?.transportSettled == false,
                      "seeking/EOF/unknown native state cannot prove target-shaped timestamps")
            }
        }
        if failures.isEmpty { print("PASS: production MPV emit position authority and strict attribution regressions") }
        else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
    }
}
