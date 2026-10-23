import SwiftUI
@MainActor final class Clock {
    var now = Date(timeIntervalSince1970: 100)
    var uptime: Double = 100
    var pending: [CheckedContinuation<Void, Never>] = []
    var sleepCalls = 0
    func sleep(for duration: Duration) async throws {
        sleepCalls += 1
        await withCheckedContinuation { pending.append($0) }
    }
    func advance(_ seconds: Double) { now += seconds; uptime += seconds }
    func tick(_ seconds: Double) { advance(seconds); let all = pending; pending = []; all.forEach { $0.resume() } }
}
@MainActor final class Subject {
    // __PRODUCTION_CLOCK_HOLDER__
    let controlsHideClock=ControlsHideClock()
    let clock = Clock()
    var controlsVisible = true, hasStartedPlaying = false, isPaused = false, scrubbing = false
    var editingVolume = false, touchOptionsVisible = false, skipEditActive = false, isLocked = false
    var loadFailed = false, playbackExited = false, showExternalChooser = false, showShare = false
    var externalLinkDead = false, subtitleLoadFailed = false, stillWatchingPrompt = false
    var panel: Int?, grabbedFrame: Int?
    var hideTask: Task<Void,Never>?
    var interactions = 0
    func noteInteraction() { interactions += 1 }
    // __PRODUCTION_CONTROL_METHODS__
    func setHold(_ index: Int,_ value: Bool) {
        switch index {
        case 0: scrubbing=value
        case 1: panel=value ? 1 : nil
        case 2: touchOptionsVisible=value
        case 3: skipEditActive=value
        case 4: editingVolume=value
        case 5: showExternalChooser=value
        case 6: showShare=value
        case 7: grabbedFrame=value ? 1 : nil
        case 8: externalLinkDead=value
        case 9: subtitleLoadFailed=value
        case 10: stillWatchingPrompt=value
        default: hasStartedPlaying = !value
        }
    }

func change(_ mutation: ()->Void) { let prior=controlsAutoHideEligible; mutation(); if prior != controlsAutoHideEligible { refreshControlsAutoHide() } }
}

@main struct Tests {
    @MainActor static func main() async {
        var failures=0,checks=0
        func check(_ value: Bool,_ label: String) { checks+=1; if !value { failures+=1 }; print("\(value ? "PASS" : "FAIL") \(label)") }
        func drain() async { for _ in 0..<20 { await Task.yield() } }
        func tick(_ s: Subject,_ seconds: Double=4) async { await drain(); s.clock.tick(seconds); await drain() }
        let cold=Subject(); cold.scheduleHide(); await tick(cold)
        check(cold.controlsVisible,"pre-first-frame escape controls stay visible")
        cold.change { cold.hasStartedPlaying=true }; await tick(cold)
        check(!cold.controlsVisible,"cold first frame re-arms expired initial timer")
        let remote=Subject(); remote.hasStartedPlaying=true; remote.scheduleHide()
        remote.change { remote.isPaused=true }; await tick(remote)
        check(remote.controlsVisible,"paused controls stay visible")
        let beforeResume=remote.interactions; remote.change { remote.isPaused=false }; await tick(remote)
        check(!remote.controlsVisible,"remote resume re-arms controls without a click")
        check(remote.interactions==beforeResume,"engine lifecycle does not fabricate viewer presence")
        let hidden=Subject(); hidden.hasStartedPlaying=true; hidden.scheduleHide(); await tick(hidden)
        hidden.change { hidden.isPaused=true }; hidden.change { hidden.isPaused=false }; await tick(hidden)
        check(!hidden.controlsVisible,"eligibility transitions do not reveal a deliberately hidden bar")
        for hold in 0..<12 {
            let s=Subject(); s.hasStartedPlaying=true; s.scheduleHide()
            s.change { s.setHold(hold,true) }; await tick(s)
            check(s.controlsVisible,"hold \(hold) keeps visible controls")
            s.change { s.setHold(hold,false) }; await tick(s)
            check(!s.controlsVisible,"hold \(hold) removal starts a fresh deadline")
        }
        let moves=Subject(); moves.hasStartedPlaying=true; moves.scheduleHide(); await drain()
        moves.clock.advance(3)
        for _ in 0..<100 { moves.scheduleHide() }
        await drain(); check(moves.clock.sleepCalls==1,"100 mouse moves share one sleeper")
        await tick(moves,1); check(moves.controlsVisible,"movement extends inactivity deadline")
        await tick(moves,3); check(!moves.controlsVisible,"stationary mouse allows auto-hide")
        let pointer=Subject(); pointer.hasStartedPlaying=true; pointer.scheduleHide(); await drain()
        for _ in 0..<100 { pointer.macPointerMoved() }; await drain()
        check(pointer.clock.sleepCalls==1 && pointer.interactions<=2,"pointer burst avoids task and idle-state churn")
        let stale=Subject(); stale.hasStartedPlaying=true; stale.scheduleHide(); await drain()
        stale.change { stale.isPaused=true }; stale.change { stale.isPaused=false }; await drain()
        await tick(stale,2); check(stale.controlsVisible,"cancelled timer cannot hide new deadline")
        await tick(stale,2); check(!stale.controlsVisible,"new deadline survives cancelled predecessor")
        let locked=Subject(); locked.hasStartedPlaying=true; locked.isLocked=true; locked.controlsVisible=false
        locked.scheduleHide(); await tick(locked); check(!locked.controlsVisible,"pointer cannot reveal locked chrome")
        let backwards=Subject(); backwards.hasStartedPlaying=true; backwards.scheduleHide(); await drain()
        backwards.clock.now -= 3_600
        await tick(backwards)
        check(!backwards.controlsVisible,"backward wall-clock change cannot delay inactivity hide")
        let forward=Subject(); forward.hasStartedPlaying=true; forward.scheduleHide(); await drain()
        forward.clock.advance(3); forward.macPointerMoved()
        forward.clock.now += 3_600
        await tick(forward,1)
        check(forward.controlsVisible,"forward wall-clock change cannot hide before inactivity deadline")
        await tick(forward,3)
        check(!forward.controlsVisible,"monotonic inactivity deadline still expires")
        let presence=Subject(); presence.hasStartedPlaying=true; presence.macPointerMoved(); await drain()
        let oldPresence=presence.interactions
        presence.clock.now -= 3_600; presence.clock.advance(1); presence.macPointerMoved()
        check(presence.interactions==oldPresence+1,"backward wall clock cannot suppress sampled pointer presence")
        print("CONTROLS_CHECKS=\(checks) FAILURES=\(failures)")
        if failures>0 { exit(1) }
    }
}
