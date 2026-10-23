// Actual selected MPV controller methods and terminal dispatch closures are inserted by the runner.
// Native transport/property calls, provenance lookup and unrelated cleanup are controlled fixtures.
/* __PRODUCTION_SETTLEMENT__ */

enum MPVProperty {
    static let pause = "pause", endFileEof = "eof", endFileError = "error"
}
struct PlayerTimePositionEvent: Sendable {
    let seconds: Double
    let loadToken: PlayerLoadToken
    let mpvSeekSettlement: MPVSeekSettlementEvidence?
}
enum PlayerLoadProvenanceState {
    static func accepts(callbackToken: Int?, activeToken: Int?) -> Bool {
        callbackToken != nil && callbackToken == activeToken
    }
}
enum VXProbe { static func event(_ channel: String, _ message: String) {} }
struct NativeProvenance { var activeToken: Int? = 2 }
struct NativeFreshOrigin { func hasFailed(owner: Int) -> Bool { false } }
struct NativeCacheFlight {
    mutating func reset(owner: Int) -> Int? { nil }
    mutating func updateTransportIntent(owner: Int, paused: Bool) {}
}
@MainActor final class NativeDelegate {
    struct Event { let name: String; let data: Any?; let token: Int }
    var events: [Event] = []
    func propertyChange(propertyName: String, data: Any?, loadToken: Int) {
        events.append(Event(name: propertyName, data: data, token: loadToken))
    }
}

@MainActor final class ExtractedMPVController {
    var mpv: Int? = 1
    var loadProvenance = NativeProvenance()
    var activeLoadToken: Int? { loadProvenance.activeToken }
    let loadTokenLock = NSLock()
    var seekSettlement = MPVSeekSettlementPolicy<Int>()
    var seekEOFRecovery = SeekEOFRecoveryPolicy<Int>()
    var seekEOFTerminalPark = SeekEOFTerminalParkPolicy<Int>()
    var seekEOFRecoveryTimeout: DispatchWorkItem?
    var cacheFlushFlight = NativeCacheFlight(), freshOrigin = NativeFreshOrigin()
    let mpvLog = Logger(subsystem: "local.vortx.source-replay", category: "no-native-player")
    let probeChannel = "fixture"
    let playDelegate: NativeDelegate? = NativeDelegate()
    static let seekEOFRecoveryTimeoutSeconds: TimeInterval = 12
    struct SeekEOFReloadSource {
        let url: URL; let headers: [String:String]?; let live: Bool; let audioSidecar: URL?
    }
    var seekEOFReloadSource: SeekEOFReloadSource?
    var flag = false, flags: [Bool] = [], loads = 0
    init() { seekSettlement.reset(owner: 2) }
    func callbackLoadToken() -> Int? { activeLoadToken }
    @discardableResult func setFlag(_ name: String, _ flag: Bool) -> Bool {
        self.flag = flag; flags.append(flag); return true
    }
    func getFlag(_ name: String) -> Bool { flag }
    func finishCacheFlushFlight(_ value: Int?) {}
    func failFreshOriginCorrection(owner: Int, reason: String) {}
    func loadFile(_ url: URL, headers: [String:String]?, live: Bool, audioSidecar: URL?,
                  preservingSeekEOFRecovery: Bool) -> Int {
        loads += 1; return 2
    }
    /* __PRODUCTION_CONTROLLER_METHODS__ */

    // These wrappers execute the exact dispatch closures extracted from readEvents. The real raw
    // dequeue and libmpv event decoding are not present; only their immutable captured inputs are.
    func enqueueRawEOF(owner loadToken: Int, evidence rawTerminalSeekEvidence: MPVSeekSettlementEvidence?) {
        let rawTerminalOwner: Int? = loadToken
        /* __PRODUCTION_RAW_EOF__ */
    }
    func enqueueRawError(owner loadToken: Int, evidence rawTerminalSeekEvidence: MPVSeekSettlementEvidence?) {
        let rawTerminalOwner: Int? = loadToken, msg = "fixture native reopen error"
        /* __PRODUCTION_RAW_ERROR__ */
    }
    // This is the real accepted-command guard and fresh-load reset/park-release block from loadFile,
    // not a reproduction of its policy. The rest of the large loadFile admission is not compiled here.
    func finishLoadAdmission(commandResult: Int32, preservingSeekEOFRecovery: Bool) {
        /* __PRODUCTION_LOAD_ADMISSION__ */
    }
    func terminalEvidence() -> MPVSeekSettlementEvidence {
        seekSettlement.evidence(owner: 2, seeking: nil, eofReached: nil)
    }
    func newExplicitSeek() {
        let lease = seekSettlement.beginIssue(owner: 2, seeking: false)!
        seekSettlement.completeIssue(lease, accepted: true)
        _ = seekEOFRecovery.supersedeForNewExplicitSeek()
        seekEOFRecovery.begin(owner: 2, target: 600, wasPaused: false, duration: 2608,
                              origin: .viewer, now: ProcessInfo.processInfo.systemUptime)
    }
    func spent(restored: Bool = true) -> SeekEOFRecoveryExhaustion {
        let now = ProcessInfo.processInfo.systemUptime
        seekEOFRecovery.begin(owner: 2, target: 2497.479, wasPaused: false, duration: 2608,
                              origin: .viewer, now: now)
        _ = seekEOFRecovery.observeSeek(owner: 2)
        seekEOFRecovery.observePosition(owner: 2, position: 2497.495, now: now)
        _ = seekEOFRecovery.consumeEOFForReload(owner: 2)
        _ = seekEOFRecovery.adoptReload(owner: 2)
        if restored {
            _ = seekEOFRecovery.beginReloadSeek(owner: 2)
            _ = seekEOFRecovery.observeSeek(owner: 2)
            _ = seekEOFRecovery.completeReloadAtPosition(owner: 2, position: 2497.495)
        }
        return seekEOFRecovery.exhaustion(owner: 2, reason: "fixture consumed reopen")!
    }
}

@MainActor func drainControllerCallbacks() async {
    // Two terminal hops plus a final marker, without sleeps or native event-loop activity.
    for _ in 0..<3 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor func runControllerExtractionReplays(_ check: (Bool, String) -> Void) async {
    let rawEOF = ExtractedMPVController()
    rawEOF.enqueueRawEOF(owner: 2, evidence: rawEOF.terminalEvidence())
    rawEOF.newExplicitSeek()
    await drainControllerCallbacks()
    check(rawEOF.playDelegate!.events.isEmpty && rawEOF.loads == 0,
          "actual first raw EOF dispatch rejects old generation after same-source new seek")

    let secondEOF = ExtractedMPVController(); _ = secondEOF.spent()
    secondEOF.emitEndFileEOF(loadToken: 2, seekEvidence: secondEOF.terminalEvidence())
    secondEOF.newExplicitSeek()
    await drainControllerCallbacks()
    check(secondEOF.playDelegate!.events.isEmpty,
          "actual second EOF dispatch rejects captured spent context across newer seek")

    let delivered = ExtractedMPVController(); _ = delivered.spent()
    delivered.enqueueRawEOF(owner: 2, evidence: delivered.terminalEvidence())
    await drainControllerCallbacks()
    check(delivered.playDelegate!.events.count == 1
            && delivered.playDelegate!.events.first?.data is SeekEOFRecoveryExhaustion,
          "actual current two-hop EOF delivery retains consumed-reopen context")

    let staleError = ExtractedMPVController(); _ = staleError.spent(restored: false)
    staleError.enqueueRawError(owner: 2, evidence: staleError.terminalEvidence())
    staleError.newExplicitSeek()
    await drainControllerCallbacks()
    check(staleError.playDelegate!.events.isEmpty && staleError.flags.isEmpty,
          "actual raw reopen error dispatch cannot fail newer same-file seek")

    let currentError = ExtractedMPVController(); _ = currentError.spent(restored: false)
    currentError.enqueueRawError(owner: 2, evidence: currentError.terminalEvidence())
    await drainControllerCallbacks()
    check(currentError.playDelegate!.events.count == 1
            && currentError.playDelegate!.events.first?.data is SeekEOFRecoveryExhaustion,
          "actual native in-flight reopen error uses typed consumed-attempt failure")
    check(currentError.flags == [false] && currentError.seekEOFRecovery.current == nil,
          "actual failure restores latest transport intent then retires reload bookkeeping")

    let restoredError = ExtractedMPVController(); _ = restoredError.spent()
    restoredError.enqueueRawError(owner: 2, evidence: restoredError.terminalEvidence())
    await drainControllerCallbacks()
    check(restoredError.playDelegate!.events.count == 1
            && restoredError.playDelegate!.events.first?.data is SeekEOFRecoveryExhaustion
            && restoredError.seekEOFRecovery.current == nil,
          "actual native error after restored landing retains spent recovery instead of outer retry")
    let ordinaryError = ExtractedMPVController()
    ordinaryError.enqueueRawError(owner: 2, evidence: ordinaryError.terminalEvidence())
    await drainControllerCallbacks()
    check(ordinaryError.playDelegate!.events.count == 1
            && ordinaryError.playDelegate!.events.first?.data as? String == "fixture native reopen error",
          "actual ordinary native error without spent receipt retains generic recovery behavior")

    let queuedTimeout = ExtractedMPVController(); _ = queuedTimeout.spent(restored: false)
    queuedTimeout.failSeekEOFRecovery(loadToken: 2, reason: "fixture timeout")
    queuedTimeout.newExplicitSeek()
    await drainControllerCallbacks()
    check(queuedTimeout.playDelegate!.events.isEmpty,
          "actual queued typed timeout emit cannot cross explicit seek generation")

    let parked = ExtractedMPVController(); let receipt = parked.spent()
    parked.parkAfterExhaustedSeekEOF(receipt)
    check(parked.flags == [true] && parked.flag && parked.requestedPauseIntent == false,
          "actual terminal park sends native pause while exposing prior playing intent")
    parked.pause(); parked.play(); parked.togglePause()
    check(parked.flags == [true] && parked.requestedPauseIntent == true,
          "actual parked Play/Pause/Toggle update intent without native unpause")
    parked.finishLoadAdmission(commandResult: -1, preservingSeekEOFRecovery: false)
    check(parked.seekEOFTerminalPark.owner == 2 && parked.flags == [true],
          "actual rejected-load admission guard retains park and avoids transport writes")
    parked.play()
    parked.finishLoadAdmission(commandResult: 0, preservingSeekEOFRecovery: true)
    check(parked.seekEOFTerminalPark.owner == 2 && parked.flags == [true],
          "actual internal automatic restore admission cannot release terminal park")
    parked.finishLoadAdmission(commandResult: 0, preservingSeekEOFRecovery: false)
    check(parked.seekEOFTerminalPark.owner == nil && parked.flags == [true, false]
            && parked.seekEOFRecovery.exhaustion(owner: 2, reason: "old") == nil,
          "actual accepted fresh admission resets budget and releases latest user transport intent")

    let stalePark = ExtractedMPVController(); let oldReceipt = stalePark.spent()
    stalePark.newExplicitSeek(); stalePark.parkAfterExhaustedSeekEOF(oldReceipt)
    check(stalePark.flags.isEmpty && stalePark.seekEOFTerminalPark.owner == nil,
          "actual park cannot borrow retired same-source receipt")
    let stopped = ExtractedMPVController(); stopped.mpv = nil
    stopped.emitEndFileEOF(loadToken: 2, seekEvidence: stopped.terminalEvidence())
    await drainControllerCallbacks()
    check(stopped.playDelegate!.events.isEmpty, "actual queued EOF drops after native core teardown")
}
