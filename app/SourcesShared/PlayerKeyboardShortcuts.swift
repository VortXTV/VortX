/// Physical keyboard actions shared by the Apple player surfaces. The player decides which
/// actions the current presentation and source can accept.
enum PlayerKeyboardAction: Equatable {
    case playPause, seekBackward, seekForward, volumeUp, volumeDown
    case mute, subtitles, fullScreen, previousEpisode, nextEpisode, skipSegment, back
    case audioMenu, subtitleMenu, playbackInfo, cycleAspect, slower, faster

    init?(character: String) {
        switch character.lowercased() {
        case " ", "k": self = .playPause
        case "j": self = .seekBackward
        case "l": self = .seekForward
        case "m": self = .mute
        case "c": self = .subtitles
        case "f": self = .fullScreen
        case "p": self = .previousEpisode
        case "n": self = .nextEpisode
        case "s": self = .skipSegment
        case "a": self = .audioMenu
        case "t": self = .subtitleMenu
        case "i": self = .playbackInfo
        case "v": self = .cycleAspect
        case "[": self = .slower
        case "]": self = .faster
        default: return nil
        }
    }

    var repeats: Bool {
        switch self {
        case .seekBackward, .seekForward, .volumeUp, .volumeDown: true
        default: false
        }
    }
}

/// The visible speed presets are already in ascending order. Keep shortcuts on that same scale.
enum PlayerKeyboardSpeed {
    static func next(from current: Double, action: PlayerKeyboardAction, presets: [Double]) -> Double? {
        switch action {
        case .slower: presets.last { $0 < current - 0.01 }
        case .faster: presets.first { $0 > current + 0.01 }
        default: nil
        }
    }
}

/// The native aspect controls use Fit, Fill and Stretch. Zoom is an engine alias for Fill.
enum PlayerKeyboardAspect {
    static func next(after current: String) -> String {
        switch current {
        case "original": "fill"
        case "fill", "zoom": "stretch"
        default: "original"
        }
    }
}
