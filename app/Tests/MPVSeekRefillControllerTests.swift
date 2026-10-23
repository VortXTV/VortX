import Foundation

// No media, libmpv, network, device, or real timer. The controller methods are extracted unchanged.
private typealias PlayerLoadToken = Int
private enum MPVProperty {
    static let pause = "pause"
    static let timePos = "time-pos"
    static let duration = "duration"
    static let pausedForCache = "paused-for-cache"
}
private final class DispatchWorkItem {
    let work: () -> Void
    init(block: @escaping () -> Void) { work = block }
    func cancel() {}
    func perform() { work() } // Intentionally deliver canceled work to exercise generation fencing.
}
private extension Double { static func now() -> Double { 0 } }
private final class DispatchQueue {
    static let main = DispatchQueue()
    var scheduled: [DispatchWorkItem] = []
    func async(execute: () -> Void) { execute() }
    func asyncAfter(deadline: Double, execute work: DispatchWorkItem) { scheduled.append(work) }
    func tick() {
        let pending = scheduled
        scheduled = []
        pending.forEach { $0.perform() }
    }
}
private struct LogMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    enum Privacy { case `public` }
    struct StringInterpolation: StringInterpolationProtocol {
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ text: String) {}
        mutating func appendInterpolation<T>(_ value: T) {}
        mutating func appendInterpolation<T>(_ value: T, privacy: Privacy) {}
    }
    init(stringLiteral value: String) {}
    init(stringInterpolation: StringInterpolation) {}
}
private struct Log { func log(_ message: LogMessage) {} }
private struct EOFRecovery {
    enum Origin { case viewer }
    mutating func begin(owner: Int, target: Double, wasPaused: Bool, duration: Double,
                        origin: Origin, now: TimeInterval) {}
}
private final class Controller {
    var mpv: Int? = 1
    var startMuted = false
    var cachePauseWaitSeconds = 6.0
    var userSeekedSinceRampSample = false
    let queue = DispatchQueue.main
    let loadTokenLock = NSLock()
    var seekSettlement = MPVSeekSettlementPolicy<Int>()
    var seekEOFRecovery = EOFRecovery()
    var owner: Int? = 1
    var activeLoadToken: Int? { owner }
    var paused = false
    var buffering: Bool? = true
    var cache: Double? = 60
    var position = 100.0
    var seeking: Bool? = false
    var acceptCommands = true
    var commands: [String] = []
    var options: [String: String] = [:]
    let mpvLog = Log()
    init() { seekSettlement.reset(owner: 1) }
    func callbackLoadToken(requiresLoadedFile: Bool) -> Int? { owner }
    func getFlag(_ name: String) -> Bool { paused }
    func getDouble(_ name: String) -> Double {
        name == MPVProperty.timePos ? position : name == MPVProperty.duration ? 1_000 : cache ?? 0
    }
    func diagnosticDouble(_ name: String) -> Double? { cache }
    func diagnosticFlag(_ name: String) -> Bool? {
        name == MPVProperty.pausedForCache ? buffering : name == "seeking" ? seeking : false
    }
    func setString(_ name: String, _ value: String) { options[name] = value }
    func cancelCacheReanchorForExplicitSeek() {
        cancelSeekRefillWatchdog()
        lastOutOfWindowSeekTarget = nil
        releaseSeekCacheHoldIfArmed()
    }
    func supersedeSeekEOFRecoveryForExplicitSeek() {}
    func command(_ name: String, args: [String], returnValueCallback: ((Int32) -> Void)? = nil) {
        commands.append(args.joined(separator: " "))
        let generation = owner.flatMap { seekSettlement.beginIssue(owner: $0, seeking: seeking) }
        if let generation { seekSettlement.completeIssue(generation, accepted: acceptCommands) }
        returnValueCallback?(acceptCommands ? 0 : -1)
    }
    func observedSeek() {
        if let owner { seekSettlement.observeSeek(owner: owner) }
        seeking = true
    }
    func replaceSource() {
        owner = 2
        seekSettlement.reset(owner: 2)
        releaseSeekCacheHoldIfArmed()
    }
    var retryCount: Int { max(0, commands.count - 1) }
    var holdArmed: Bool { seekCacheHoldArmed }
    func deliverBufferingEnd(command: UInt64?, observed: Bool = true) {
        releaseSeekCacheHoldAfterBuffering(owner: 1, commandGeneration: command, seekObserved: observed)
    }

    // EXTRACTED_CONTROLLER_METHODS
}

@main private enum MPVSeekRefillControllerTests {
    static var failures: [String] = []
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { failures.append(message) }
    }
    static func fresh(_ action: (Controller) -> Void) {
        DispatchQueue.main.scheduled = []
        action(Controller())
        DispatchQueue.main.scheduled = []
    }
    static func main() {
        fresh { c in
            c.seek(to: 500)
            c.observedSeek(); c.cache = 3
            DispatchQueue.main.tick()
            check(c.retryCount == 0, "healthy cold refill 60s before seek -> 3s after seek must not restart")
            c.cache = 4
            DispatchQueue.main.tick()
            check(c.retryCount == 0, "growing refill must retain its articles")
        }
        fresh { c in
            c.seek(by: 500)
            c.observedSeek(); c.cache = 3
            DispatchQueue.main.tick()
            check(c.retryCount == 0, "relative cold seek must not compare against the previous buffer")
        }
        fresh { c in
            c.acceptCommands = false
            c.seek(to: 500)
            DispatchQueue.main.tick()
            check(c.commands.count == 1 && !c.holdArmed, "rejected seek must not arm a destructive watchdog")
        }
        fresh { c in
            c.seek(to: 500)
            for _ in 0..<4 { DispatchQueue.main.tick() }
            check(c.retryCount == 0, "command admission without a native SEEK cannot authorize a retry")
        }
        fresh { c in
            c.seek(to: 500); c.observedSeek(); c.cache = 0
            DispatchQueue.main.tick()
            check(c.retryCount == 0, "first post-seek sample establishes the new baseline")
            DispatchQueue.main.tick()
            check(c.retryCount == 1, "two unchanged cold samples admit one retry")
            c.observedSeek(); c.cache = 0.5
            DispatchQueue.main.tick()
            check(c.retryCount == 1, "accepted retry resets the baseline before asynchronous cache reset")
            DispatchQueue.main.tick()
            check(c.retryCount == 2, "second proven wedge receives the final bounded retry")
            c.observedSeek(); c.cache = 0
            for _ in 0..<4 { DispatchQueue.main.tick() }
            check(c.retryCount == 2, "a real persistent wedge never exceeds two retries")
        }
        fresh { c in
            c.seek(to: 500); c.observedSeek(); c.cache = 1
            DispatchQueue.main.tick()
            c.paused = true; DispatchQueue.main.tick()
            c.paused = false; DispatchQueue.main.tick()
            check(c.retryCount == 0, "resume must establish a fresh observation window")
        }
        for invalid: Double? in [nil, .nan, .infinity, -1] {
            fresh { c in
                c.seek(to: 500); c.observedSeek(); c.cache = invalid
                for _ in 0..<3 { DispatchQueue.main.tick() }
                check(c.retryCount == 0, "missing/nonfinite/negative cache is not proof of a wedge")
            }
        }
        fresh { c in
            c.seek(to: 500); c.observedSeek(); c.replaceSource()
            for _ in 0..<3 { DispatchQueue.main.tick() }
            check(c.retryCount == 0, "new source retires pending work")
        }
        fresh { c in
            c.seek(to: 500); c.observedSeek()
            c.owner = 2; c.seekSettlement.reset(owner: 2)
            for _ in 0..<3 { DispatchQueue.main.tick() }
            check(c.retryCount == 0 && !c.holdArmed, "source mismatch alone retires owned work")
        }
        fresh { c in
            c.seek(to: 500); c.observedSeek()
            c.command("seek", args: ["200", "absolute"])
            for _ in 0..<3 { DispatchQueue.main.tick() }
            check(c.commands.count == 2 && !c.holdArmed, "new accepted command alone retires prior work")
        }
        fresh { c in
            c.seek(to: 500); c.observedSeek(); c.cache = 0
            DispatchQueue.main.tick(); c.acceptCommands = false
            DispatchQueue.main.tick(); DispatchQueue.main.tick()
            check(c.retryCount == 1 && !c.holdArmed, "rejected retry releases hold without rearming")
        }
        fresh { c in
            c.seek(to: 500); c.observedSeek(); c.cache = 3
            DispatchQueue.main.tick(); c.cache = 1
            DispatchQueue.main.tick()
            check(c.retryCount == 0, "cache reset cannot be mistaken for a wedge")
            c.buffering = nil; DispatchQueue.main.tick()
            c.buffering = true; DispatchQueue.main.tick()
            check(c.retryCount == 0, "unknown buffering discards previous baseline")
        }
        fresh { c in
            c.seek(to: 500)
            let first = c.seekSettlement.lastAcceptedCommandGeneration
            c.buffering = false
            c.deliverBufferingEnd(command: first)
            check(c.holdArmed, "pre-SEEK buffering-end cannot release accepted seek hold")
            c.observedSeek()
            c.deliverBufferingEnd(command: first, observed: false)
            check(c.holdArmed, "delayed pre-SEEK edge stays stale after native SEEK arrives")
            c.seek(to: 700); c.observedSeek()
            c.deliverBufferingEnd(command: first)
            check(c.holdArmed, "old same-source buffering-end cannot release the latest hold")
            c.deliverBufferingEnd(command: c.seekSettlement.lastAcceptedCommandGeneration)
            check(!c.holdArmed, "owned post-SEEK buffering-end releases the hold")
        }
        fresh { c in
            c.seek(to: 500); c.observedSeek()
            c.seek(to: 200); c.observedSeek(); c.cache = 1
            DispatchQueue.main.tick()
            check(c.commands.count == 2, "new seek rejects canceled work and its stale destination")
        }
        if failures.isEmpty { print("PASS: extracted MPV seek/refill controller regression cases") }
        else {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
    }
}
