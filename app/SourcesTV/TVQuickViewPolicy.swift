import Foundation
import Combine

/// Only ordinary catalog selection may interpose a preview. Resume, history, local downloads,
/// protected profile selection and credential-private rows retain their original action owner.
enum TVQuickViewPolicy {
    static func presents(enabled: Bool, catalog: Bool, hasDirectPlay: Bool = false,
                         hasResume: Bool = false, privateIntent: Bool = false,
                         ownerCurrent: Bool = true) -> Bool {
        enabled && catalog && !hasDirectPlay && !hasResume && !privateIntent && ownerCurrent
    }
}

/// Explicit Watch can be admitted once. A retired request stays retired across an owner ABA or
/// another SwiftUI task invocation; settled empty sources are a real unavailable outcome.
struct TVQuickViewWatchState: Equatable {
    enum Decision: Equatable { case waiting, play, unavailable, retired }
    private(set) var started = false
    private(set) var finished = false

    mutating func begin(enabled: Bool) -> Bool {
        guard enabled, !started, !finished else { return false }
        started = true
        return true
    }

    mutating func decide(ownerCurrent: Bool, cancelled: Bool, playbackPresent: Bool,
                         settled: Bool, hasBest: Bool) -> Decision {
        guard started, !finished else { return .retired }
        guard ownerCurrent, !cancelled, !playbackPresent else { retire(); return .retired }
        guard settled else { return .waiting }
        finished = true
        return hasBest ? .play : .unavailable
    }

    mutating func retire() { finished = true }
}

/// Structured Quick Watch work carries its scope through the existing async resolver's fallback.
/// Ordinary source picks leave this nil and retain their existing admission contract.
enum TVQuickViewWatchTask {
    @TaskLocal static var scope: CinemaQuickWatchScope?
}

/// Detail owns this lifetime above its loading/metadata branches. Replacing a source-list child
/// cannot recreate a consumed or canceled explicit Watch request.
@MainActor
final class TVQuickViewWatchOwner: ObservableObject {
    private(set) var state = TVQuickViewWatchState()
    private(set) var generation = 0
    func begin(enabled: Bool) -> Bool { state.begin(enabled: enabled) }
    func decide(ownerCurrent: Bool, cancelled: Bool, playbackPresent: Bool,
                settled: Bool, hasBest: Bool) -> TVQuickViewWatchState.Decision {
        state.decide(ownerCurrent: ownerCurrent, cancelled: cancelled, playbackPresent: playbackPresent,
                     settled: settled, hasBest: hasBest)
    }
    func retire() { state.retire(); generation &+= 1 }
}

enum TVDiscoverSearchPolicy {
    static func showsSeparateSearch(merged: Bool, hideSearch: Bool) -> Bool {
        !merged && !hideSearch
    }

    /// Match touch Apple: merging the selected Search tab moves to visible Discover, else Home.
    static func selectionAfterMerge(_ selection: Int, merged: Bool, hideDiscover: Bool) -> Int {
        selection == 4 && merged ? (hideDiscover ? 0 : 1) : selection
    }

    static func hasQuery(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    static func acceptsResults(query: String, submittedQuery: String, debouncePending: Bool,
                               capturedProfile: UUID?, currentProfile: UUID?,
                               capturedAccountBoundary: UInt64?, currentAccountBoundary: UInt64) -> Bool {
        hasQuery(query) && !debouncePending
            && submittedQuery == query.trimmingCharacters(in: .whitespacesAndNewlines)
            && capturedProfile != nil && capturedProfile == currentProfile
            && capturedAccountBoundary == currentAccountBoundary
    }
}
