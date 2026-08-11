// Standalone source/state contract for the reachable AVPlayer Picture in Picture path.
//
// Extract the dependency-free production state machine, then compile this harness:
//
//   sed -n '/^enum AVPlayerPictureInPictureCommand:/,/^\/\/ MARK: - AVPlayer engine/p' \
//     app/Sources/Player/AVPlayerEngine.swift | sed '$d' \
//     > /tmp/avplayer-pip-state.swift && \
//   swiftc -warnings-as-errors /tmp/avplayer-pip-state.swift \
//     app/Tests/AVPlayerPiPContractTests.swift \
//     -o /tmp/avplayer-pip-contract && /tmp/avplayer-pip-contract

import Foundation

private var failures = 0

private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private final class FakePictureInPictureController {
    let identifier: String
    var isPossible: Bool
    var isActive: Bool
    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    init(identifier: String, possible: Bool, active: Bool = false) {
        self.identifier = identifier
        self.isPossible = possible
        self.isActive = active
    }

    func startPictureInPicture() {
        startCalls += 1
    }

    func stopPictureInPicture() {
        stopCalls += 1
    }
}

private struct PictureInPictureOwnershipProjection {
    private(set) var controllerIdentifier: String? = "stable-layer-controller"
    private(set) var controllerGeneration: UInt64 = 17
    private(set) var currentItemIdentifier: String? = "series:s1e10"
    private(set) var observedNilCurrentItem = false

    mutating func apply(
        _ event: AVPlayerPictureInPictureOwnershipEvent,
        replacementItemIdentifier: String? = nil
    ) {
        if event.invalidatesController {
            controllerIdentifier = nil
            controllerGeneration &+= 1
        }
        if event.clearsCurrentItemBeforeAttach {
            currentItemIdentifier = nil
            observedNilCurrentItem = true
        }
        if let replacementItemIdentifier {
            currentItemIdentifier = replacementItemIdentifier
        }
    }
}

private func sourceText(_ relativePath: String) -> String? {
    let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try? String(
        contentsOf: appRoot.appendingPathComponent(relativePath),
        encoding: .utf8)
}

private func section(in source: String, from start: String, to end: String) -> String? {
    guard let lower = source.range(of: start),
          let upper = source.range(of: end, range: lower.upperBound..<source.endIndex) else {
        return nil
    }
    return String(source[lower.lowerBound..<upper.lowerBound])
}

private func containsInOrder(_ source: String, _ fragments: [String]) -> Bool {
    var cursor = source.startIndex
    for fragment in fragments {
        guard let range = source.range(of: fragment, range: cursor..<source.endIndex) else { return false }
        cursor = range.upperBound
    }
    return true
}

private func testUnsupportedDevice() {
    var state = AVPlayerPictureInPictureState()
    let generation = state.attach(supported: false, possible: false, active: false)
    check("unsupported device: PiP is unavailable", !state.isAvailable)
    check("unsupported device: PiP is inactive", !state.isActive)
    check("unsupported device: start is rejected", state.requestStart() == nil)
    check("unsupported device: stale callback is rejected",
          !state.observe(possible: true, active: true, generation: generation))
    check("unsupported device: stale callback cannot activate", !state.isActive)
}

private func testStartFailure() {
    var state = AVPlayerPictureInPictureState()
    let generation = state.attach(supported: true, possible: true, active: false)
    check("start failure: first request is accepted",
          state.requestStart() == .start(generation))
    check("start failure: duplicate request is suppressed", state.requestStart() == nil)
    check("start failure: failure is owned by the current generation",
          state.failStart(generation: generation))
    check("start failure: failed start is not reported active", !state.isActive)
    check("start failure: controller remains available", state.isAvailable)
    check("start failure: retry is possible",
          state.requestStart() == .start(generation))
}

private func testReplacementFence() {
    var state = AVPlayerPictureInPictureState()
    let oldGeneration = state.attach(supported: true, possible: true, active: true)
    let newGeneration = state.attach(supported: true, possible: true, active: false)
    check("replacement: generation advances", oldGeneration != newGeneration)
    check("replacement: old active callback is rejected",
          !state.observe(possible: true, active: true, generation: oldGeneration))
    check("replacement: stale callback cannot revive PiP", !state.isActive)
    check("replacement: current callback is accepted",
          state.observe(possible: true, active: false, generation: newGeneration))
}

private func testRepeatedToggle() {
    var state = AVPlayerPictureInPictureState()
    let generation = state.attach(supported: true, possible: true, active: false)
    check("repeated toggle: start is issued once",
          state.requestStart() == .start(generation) && state.requestStart() == nil)
    check("repeated toggle: active callback settles start",
          state.didStart(possible: true, active: true, generation: generation) && state.isActive)
    check("repeated toggle: stop is issued once",
          state.requestStop() == .stop(generation) && state.requestStop() == nil)
    check("repeated toggle: inactive callback settles stop",
          state.didStop(possible: true, active: false, generation: generation) && !state.isActive)
}

private func testItemReplacementLifetime() {
    var active = PictureInPictureOwnershipProjection()
    active.apply(
        .itemReplacement(isActive: true, isTransitioning: false),
        replacementItemIdentifier: "series:s2e1")
    check("item replacement: active PiP retains its controller",
          active.controllerIdentifier == "stable-layer-controller")
    check("item replacement: active PiP retains its controller generation",
          active.controllerGeneration == 17)
    check("item replacement: active PiP never observes a nil current item",
          !active.observedNilCurrentItem && active.currentItemIdentifier == "series:s2e1")

    var transitioning = PictureInPictureOwnershipProjection()
    transitioning.apply(
        .itemReplacement(isActive: false, isTransitioning: true),
        replacementItemIdentifier: "source:replacement")
    check("item replacement: transitioning PiP retains its controller and non-nil item",
          transitioning.controllerIdentifier == "stable-layer-controller"
            && transitioning.controllerGeneration == 17
            && !transitioning.observedNilCurrentItem
            && transitioning.currentItemIdentifier == "source:replacement")

    var inactive = PictureInPictureOwnershipProjection()
    inactive.apply(
        .itemReplacement(isActive: false, isTransitioning: false),
        replacementItemIdentifier: "inactive:replacement")
    check("item replacement: inactive PiP retains controller identity across early item retirement",
          inactive.controllerIdentifier == "stable-layer-controller"
            && inactive.controllerGeneration == 17
            && inactive.observedNilCurrentItem
            && inactive.currentItemIdentifier == "inactive:replacement")

    var stopped = PictureInPictureOwnershipProjection()
    stopped.apply(.engineStop)
    check("engine stop: PiP controller is invalidated",
          stopped.controllerIdentifier == nil && stopped.controllerGeneration == 18)

    var replacedLayer = PictureInPictureOwnershipProjection()
    replacedLayer.apply(.layerReplacement)
    check("layer replacement: PiP controller is invalidated",
          replacedLayer.controllerIdentifier == nil && replacedLayer.controllerGeneration == 18)
}

private func testHostileFakeTrace() {
    var state = AVPlayerPictureInPictureState()
    let firstController = FakePictureInPictureController(identifier: "first", possible: true)
    let firstGeneration = state.attach(
        supported: true,
        possible: firstController.isPossible,
        active: firstController.isActive)

    check("hostile trace: start is accepted",
          state.requestStart() == .start(firstGeneration))
    firstController.startPictureInPicture()
    check("hostile trace: fake start is called once", firstController.startCalls == 1)

    firstController.isPossible = false
    check("hostile trace: transient impossible observation is accepted",
          state.observe(
            possible: firstController.isPossible,
            active: firstController.isActive,
            generation: firstGeneration))
    check("hostile trace: impossible observation preserves starting",
          state.isTransitioning && state.transition == .starting)
    check("hostile trace: second start tap is rejected",
          state.requestStart() == nil && firstController.startCalls == 1)

    firstController.isActive = true
    check("hostile trace: didStart settles current start",
          state.didStart(
            possible: firstController.isPossible,
            active: firstController.isActive,
            generation: firstGeneration)
            && state.isActive
            && !state.isTransitioning)

    check("hostile trace: stop is accepted",
          state.requestStop() == .stop(firstGeneration))
    firstController.stopPictureInPicture()
    check("hostile trace: fake stop is called once", firstController.stopCalls == 1)
    firstController.isPossible = true
    check("hostile trace: possible change preserves stopping",
          state.observe(
            possible: firstController.isPossible,
            active: firstController.isActive,
            generation: firstGeneration)
            && state.isTransitioning
            && state.transition == .stopping)
    check("hostile trace: second stop tap is rejected",
          state.requestStop() == nil && firstController.stopCalls == 1)

    firstController.isActive = false
    check("hostile trace: didStop settles current stop",
          state.didStop(
            possible: firstController.isPossible,
            active: firstController.isActive,
            generation: firstGeneration)
            && !state.isActive
            && !state.isTransitioning)

    let replacementController = FakePictureInPictureController(identifier: "replacement", possible: true)
    let replacementGeneration = state.attach(
        supported: true,
        possible: replacementController.isPossible,
        active: replacementController.isActive)
    check("hostile trace: replacement is a new fake controller",
          replacementController.identifier != firstController.identifier)
    check("hostile trace: replacement advances generation", replacementGeneration != firstGeneration)
    check("hostile trace: replacement start is accepted",
          state.requestStart() == .start(replacementGeneration))
    replacementController.startPictureInPicture()
    check("hostile trace: stale didStop cannot settle replacement",
          !state.didStop(
            possible: false,
            active: false,
            generation: firstGeneration)
            && state.isTransitioning
            && state.transition == .starting)
    check("hostile trace: stale didFail cannot settle replacement",
          !state.failStart(generation: firstGeneration) && state.isTransitioning)
    replacementController.isActive = true
    check("hostile trace: current didStart settles replacement",
          state.didStart(
            possible: replacementController.isPossible,
            active: replacementController.isActive,
            generation: replacementGeneration)
            && state.isActive
            && !state.isTransitioning)
}

private func testSourceContracts() {
    guard let engine = sourceText("Sources/Player/AVPlayerEngine.swift"),
          let player = sourceText("Sources/PlayerScreen.swift") else {
        check("source contracts: governed sources are readable", false)
        return
    }

    check("engine source: unsupported devices fail closed",
          engine.contains("AVPictureInPictureController.isPictureInPictureSupported()"))
    check("engine source: automatic inline PiP is enabled",
          engine.contains("canStartPictureInPictureAutomaticallyFromInline = true"))
    check("engine source: background playback policy is explicit",
          engine.contains("audiovisualBackgroundPlaybackPolicy"))
    check("engine source: start action is exposed",
          engine.contains("func startPictureInPicture()"))
    check("engine source: stop action is exposed",
          engine.contains("func stopPictureInPicture()"))
    check("engine source: failed starts are fenced",
          engine.contains("failedToStartPictureInPictureWithError"))
    check("engine source: KVO observation does not settle transitions",
          engine.contains("mutating func observe(")
            && engine.contains("mutating func didStart(")
            && engine.contains("mutating func didStop("))
    check("engine source: transition state is published",
          engine.contains("pictureInPictureTransition")
            && engine.contains("isPictureInPictureTransitioning"))
    check("engine source: replacement callbacks compare controller identity",
          engine.contains("pipController === pictureInPictureController"))
    check("engine source: stale callbacks compare generation",
          engine.contains("generation: generation"))
    let loadFile = section(
        in: engine,
        from: "func loadFile(_ url: URL",
        to: "private func pendingLoadIsCurrent") ?? ""
    check("engine source: item replacement does not reset the PiP controller",
          loadFile.contains("AVPlayerPictureInPictureOwnershipEvent.itemReplacement")
            && !loadFile.contains("resetPictureInPictureController"))
    check("engine source: active PiP replacement avoids the nil-currentItem gap",
          containsInOrder(loadFile, [
            "if pictureInPictureReplacement.clearsCurrentItemBeforeAttach {",
            "player.replaceCurrentItem(with: nil)",
            "}"
          ]))
    let stop = section(in: engine, from: "func stop()", to: "func setOrientation") ?? ""
    check("engine source: engine stop still resets the PiP controller",
          stop.contains("resetPictureInPictureController(for: .engineStop)"))
    let layerAttachment = section(
        in: engine,
        from: "func attachLayer(_ layer: AVPlayerLayer)",
        to: "private func installPictureInPictureController") ?? ""
    check("engine source: physical layer replacement still resets the PiP controller",
          layerAttachment.contains("previousLayer !== layer")
            && layerAttachment.contains("resetPictureInPictureController(for: .layerReplacement)"))
    let resetController = section(
        in: engine,
        from: "private func resetPictureInPictureController(",
        to: "private func publishPictureInPictureState") ?? ""
    check("engine source: reset helper accepts only an invalidating ownership event",
          resetController.contains("event.invalidatesController"))
    check("engine source: AirPlay remains enabled",
          engine.contains("player.allowsExternalPlayback = true"))

    let topBar = section(in: player, from: "private var topBar: some View", to: "private var volumeControl") ?? ""
    check("transport source: PiP control belongs to the AVPlayer top bar",
          topBar.contains("AVPlayerPictureInPictureButton"))
    check("transport source: PiP control is gated by truthful support",
          player.contains("controller.isPictureInPicturePossible")
            && player.contains("controller.isPictureInPictureActive")
            && player.contains("controller.isPictureInPictureTransitioning"))
    check("transport source: transition button is disabled",
          player.contains(".disabled(controller.isPictureInPictureTransitioning)"))
    check("transport source: starting transition has an accessibility label",
          player.contains("Starting Picture in Picture"))
    check("transport source: stopping transition has an accessibility label",
          player.contains("Stopping Picture in Picture"))
    check("transport source: active state has an exit accessibility label",
          player.contains("Exit Picture in Picture"))
    check("transport source: inactive state has an enter accessibility label",
          player.contains("Enter Picture in Picture"))
    check("transport source: AirPlay control remains present",
          topBar.contains("AirPlayRoutePickerButton()"))
}

@main
private enum AVPlayerPiPContractTests {
    static func main() {
        testUnsupportedDevice()
        testStartFailure()
        testReplacementFence()
        testRepeatedToggle()
        testItemReplacementLifetime()
        testHostileFakeTrace()
        testSourceContracts()

        print("")
        if failures == 0 {
            print("ALL PASS")
        } else {
            print("\(failures) FAILED")
            exit(1)
        }
    }
}
