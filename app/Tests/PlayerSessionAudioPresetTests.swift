import Foundation

@main enum PlayerSessionAudioPresetTests {
    @MainActor static func main() {
        typealias Preset = PlayerSessionAudioPreset
        typealias State = PlayerSessionAudioPresetState
        let label = State.filterLabel
        var state = State()
        var commands: [[String]] = []
        var restores = 0
        func accepted(_ args: [String]) -> Int32 { commands.append(args); return 0 }
        func restore() -> Int32 { restores += 1; return 0 }

        precondition(state.selected == .normal)
        precondition(state.apply(.normal, unavailableReason: "bitstream", command: accepted, restore: restore))
        precondition(commands.isEmpty && restores == 0, "Normal starts without mutating custom filters")
        precondition(!state.apply(.dialogue, unavailableReason: "bitstream", command: accepted, restore: restore))
        precondition(state.selected == .normal && commands.isEmpty && restores == 0)
        precondition(!state.apply(.night, unavailableReason: "property unavailable", command: accepted, restore: restore))
        precondition(state.message == "property unavailable")

        precondition(state.apply(.dialogue, unavailableReason: nil, command: accepted, restore: restore))
        precondition(commands == [["add", "\(label):\(Preset.dialogue.filter!)"]])
        precondition(state.selected == .dialogue && state.message == nil && restores == 0)
        commands = []
        precondition(state.apply(.dialogue, unavailableReason: nil, command: accepted, restore: restore))
        precondition(commands.isEmpty, "same choice never stacks DSP")
        precondition(state.apply(.night, unavailableReason: nil, command: accepted, restore: restore))
        precondition(commands == [["remove", label], ["add", "\(label):\(Preset.night.filter!)"]])
        precondition(state.selected == .night)
        commands = []
        precondition(state.apply(.normal, unavailableReason: "bitstream", command: accepted, restore: restore))
        precondition(commands == [["remove", label]] && state.selected == .normal, "Normal can clear own DSP before bitstream")
        precondition(restores == 0)

        commands = []
        precondition(!state.apply(.dialogue, unavailableReason: nil, command: {
            commands.append($0); return -1
        }, restore: restore))
        precondition(state.selected == .normal && restores == 1, "native rejection never claims requested preset")
        precondition(commands.count == 1 && commands[0][0] == "add")
        precondition(state.apply(.night, unavailableReason: nil, command: accepted, restore: restore))
        commands = []
        precondition(!state.apply(.dialogue, unavailableReason: nil, command: {
            commands.append($0); return $0[0] == "remove" ? 0 : -2
        }, restore: restore))
        precondition(state.selected == .night && restores == 2, "exact native snapshot restored after failed replacement")
        precondition(commands.map { $0[0] } == ["remove", "add"])
        commands = []
        precondition(!state.apply(.normal, unavailableReason: nil, command: {
            commands.append($0); return -3
        }, restore: restore))
        precondition(commands == [["remove", label]] && state.selected == .night && restores == 3)
        commands = []
        precondition(!state.apply(.dialogue, unavailableReason: nil, command: {
            commands.append($0); return -4
        }, restore: { -5 }))
        precondition(state.selected == nil && state.message == State.unknownState,
                     "failed rollback must not claim previous/Normal processing")
        commands = []
        precondition(!state.apply(.night, unavailableReason: State.unknownState, command: accepted, restore: restore))
        precondition(commands.isEmpty && state.selected == nil)
        precondition(state.apply(.normal, unavailableReason: nil, command: accepted, restore: restore))
        precondition(commands == [["remove", label]] && state.selected == .normal && state.message == nil)
        let fresh = State()
        precondition(fresh.selected == .normal && fresh.message == nil, "new controller/session inherits no prior preset")
        precondition(Preset.normal.filter == nil)
        for preset in [Preset.dialogue, .night] {
            let filter = preset.filter!
            precondition(filter.hasPrefix("lavfi=[") && filter.hasSuffix("]"))
            precondition(!filter.contains("volume=") && !filter.contains("pan=") && !filter.contains("adelay="))
        }
        // These methods are extracted verbatim from the real MPV controller by the runner.
        let engine = AudioPresetControllerFixture()
        engine.spdif = nil
        precondition(!engine.setSessionAudioPreset(.dialogue) && engine.calls.isEmpty,
                     "unknown passthrough property fails closed before a native mutation")
        engine.spdif = "ac3,dts"
        precondition(!engine.setSessionAudioPreset(.night) && engine.calls.isEmpty)
        engine.spdif = ""
        engine.loaded = false
        precondition(!engine.setSessionAudioPreset(.night) && engine.calls.isEmpty)
        engine.loaded = true
        engine.startMuted = true
        precondition(!engine.setSessionAudioPreset(.dialogue) && engine.calls.isEmpty, "decorative previews never process audio")
        engine.startMuted = false
        MPVPlaybackProfileOption.allowsSnapshot = false
        precondition(!engine.setSessionAudioPreset(.night) && engine.calls.isEmpty)
        MPVPlaybackProfileOption.allowsSnapshot = true
        engine.statuses = [0]
        precondition(engine.setSessionAudioPreset(.dialogue))
        precondition(engine.sessionAudioPreset.selected == .dialogue)
        precondition(engine.calls == [["add", "\(label):\(Preset.dialogue.filter!)"]])
        engine.calls = []
        engine.statuses = [0, -1]
        MPVPlaybackProfileOption.restoreStatus = 0
        let restoresBefore = MPVPlaybackProfileOption.restoreCount
        precondition(!engine.setSessionAudioPreset(.night))
        precondition(engine.sessionAudioPreset.selected == .dialogue)
        precondition(MPVPlaybackProfileOption.restoreCount == restoresBefore + 1)
        precondition(MPVPlaybackProfileOption.names.allSatisfy { $0 == "af" })
        engine.calls = []
        engine.statuses = [-1]
        MPVPlaybackProfileOption.restoreStatus = -2
        precondition(!engine.setSessionAudioPreset(.normal))
        precondition(engine.sessionAudioPreset.selected == nil)
        precondition(engine.sessionAudioPresetUnavailableReason(for: .night) == State.unknownState)
        engine.calls = []
        engine.mpv = nil
        precondition(!engine.setSessionAudioPreset(.night) && engine.calls.isEmpty)
        print("PASS actual session audio policy: fail-closed availability, native acceptance, no stacking, own-label Normal, exact rollback/unknown state, fresh session")
    }
}
