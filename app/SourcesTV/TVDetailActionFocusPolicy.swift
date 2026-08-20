import Foundation

/// Visible regions in the detail-page focus graph. `shell` documents the native handoff; it is never a
/// hidden SwiftUI focus target.
enum DetailFocusRegion: Hashable {
    case top
    case primary
    case secondary
    case lower
    case shell
}

/// Foundation-only representation of the directional command that this policy owns. SwiftUI translates its
/// `MoveCommandDirection` into this type at the view boundary, keeping the reducer directly executable in
/// the contract harness without a tvOS runtime.
enum TVDetailFocusDirection: Equatable {
    case up
    case down
    case left
    case right
}

/// A ranked source can be absent, still settling, or ready to play. The focus topology deliberately does not
/// change between these states: the primary status/action and the secondary Library anchor remain mounted.
enum TVDetailBestState: Equatable {
    case absent
    case settling
    case ready
}

/// Download presentation is independent from focus ownership. It is carried through the policy so callers and
/// contract tests prove that a download state change cannot displace the secondary anchor.
enum TVDetailDownloadState: Equatable {
    case unavailable
    case none
    case inProgress
    case done
}

struct TVDetailActionState: Equatable {
    let isLive: Bool
    let hasTrailer: Bool
    let best: TVDetailBestState
    let download: TVDetailDownloadState
}

struct TVDetailActionRows: Equatable {
    /// The title-action row is permanent. Library is the first visible item and therefore a stable focus seat.
    let showsSecondary: Bool
    let secondaryAnchor: DetailFocusRegion
    let showsLibrary: Bool
    let showsTrailer: Bool
    let showsDownload: Bool
}

/// The detail action-row topology. Dynamic source results may add/remove Trailer and Download neighbours, but
/// never remove the Library anchor or the secondary row itself. That makes an in-flight source refresh safe
/// for Siri Remote focus.
enum TVDetailActionFocusPolicy {
    /// Detail heroes always expose title actions, independent of source loading. This is used by the page-owned
    /// rows whose state does not depend on a stream result.
    static let persistentTitleActions = TVDetailActionState(
        isLive: false,
        hasTrailer: false,
        best: .absent,
        download: .unavailable
    )

    static func rows(for state: TVDetailActionState) -> TVDetailActionRows {
        TVDetailActionRows(
            showsSecondary: true,
            secondaryAnchor: .secondary,
            showsLibrary: true,
            showsTrailer: state.hasTrailer,
            showsDownload: !state.isLive && state.best != .absent
        )
    }

    /// Returns only destinations that SwiftUI owns. `.shell` intentionally has no local focus assignment;
    /// when the visible top target receives another Up command, tvOS returns focus to its native tab/menu.
    static func destination(from region: DetailFocusRegion,
                            direction: TVDetailFocusDirection,
                            state: TVDetailActionState) -> DetailFocusRegion? {
        guard direction == .up else { return nil }
        switch region {
        case .secondary:
            return .primary
        case .primary:
            return .top
        case .lower:
            return rows(for: state).showsSecondary ? .secondary : .primary
        case .top:
            return .shell
        case .shell:
            return nil
        }
    }
}
