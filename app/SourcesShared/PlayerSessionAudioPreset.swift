import Foundation

/// One controller-owned audio filter, never a saved preference or a replacement for user custom `af`.
/// Recipes are admitted by libmpv at runtime; an accepted command is not an audible/device receipt.
enum PlayerSessionAudioPreset: String, CaseIterable, Sendable {
    case normal, dialogue, night

    var label: String {
        switch self {
        case .normal: "Normal"
        case .dialogue: "Dialogue"
        case .night: "Night"
        }
    }

    var detail: String {
        switch self {
        case .normal: "No added VortX processing"
        case .dialogue: "Speech-range emphasis, not voice isolation"
        case .night: "Reduces loud peaks without raising quiet audio"
        }
    }

    /// No channel mixing, volume/mute write, or manual audio-delay adjustment.
    var filter: String? {
        switch self {
        case .normal: nil
        case .dialogue:
            "lavfi=[equalizer=f=1800:t=q:w=1:g=3,alimiter=limit=0.95:level=0]"
        case .night:
            "lavfi=[acompressor=threshold=0.125:ratio=4:attack=20:release=250:makeup=1]"
        }
    }
}

/// Main-actor-owned by the concrete MPV controller. Pure command policy is independently testable.
/// The native adapter snapshots the complete typed `af` node before a mutation and restores that
/// exact node on rejection; it never rebuilds custom filters from a lossy string representation.
struct PlayerSessionAudioPresetState: Sendable {
    static let filterLabel = "@vortx-session-audio-preset"
    static let avPlayerUnavailable = "Audio presets aren't available on the Dolby Vision player"
    static let unknownState = "Audio processing state is unavailable. Close and reopen the player."

    /// A checkmark means native command acceptance, not measured/audible effect. nil is unknown after
    /// a failed rollback; do not claim either the requested or previous preset then.
    private(set) var selected: PlayerSessionAudioPreset? = .normal
    private(set) var message: String?

    @discardableResult
    mutating func refuse(_ reason: String) -> Bool {
        message = reason
        return false
    }

    @discardableResult
    mutating func apply(
        _ requested: PlayerSessionAudioPreset,
        unavailableReason: String?,
        command: ([String]) -> Int32,
        restore: () -> Int32
    ) -> Bool {
        if requested != .normal, let unavailableReason {
            return refuse(unavailableReason)
        }
        if selected == requested {
            message = nil
            return true
        }
        let previous = selected
        // Do not remove an absent own label on the first selection. Never use af set/clr, which
        // would discard custom filters; Normal removes only the label this controller owns.
        if selected != .normal, command(["remove", Self.filterLabel]) < 0 {
            return rejected(previous: previous, restore: restore)
        }
        if let filter = requested.filter,
           command(["add", "\(Self.filterLabel):\(filter)"]) < 0 {
            return rejected(previous: previous, restore: restore)
        }
        selected = requested
        message = nil
        return true
    }

    private mutating func rejected(
        previous: PlayerSessionAudioPreset?,
        restore: () -> Int32
    ) -> Bool {
        if restore() >= 0 {
            selected = previous
            message = previous == nil ? Self.unknownState
                : "This preset isn't supported by the current audio path. Previous processing restored."
        } else {
            selected = nil
            message = Self.unknownState
        }
        return false
    }
}
