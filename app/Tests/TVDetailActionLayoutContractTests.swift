// Executable contract for the tvOS detail action rows and focus topology.
//
//   swiftc app/SourcesTV/TVDetailActionFocusPolicy.swift \
//     app/Tests/TVDetailActionLayoutContractTests.swift \
//     -o /tmp/tv-detail-action-layout-contract \
//     && /tmp/tv-detail-action-layout-contract <repository-root>
//
// The reducer is production code and Foundation-only, so these scenarios exercise the same focus decisions
// that SwiftUI uses without requiring a simulator or connected device. Layout checks remain intentionally
// narrow; they guard the two-row/intrinsic-width view seam rather than pretending source text is navigation.

import Foundation

private var passed = 0
private var failed = 0

private func expect(_ condition: Bool, _ message: String) {
    if condition {
        passed += 1
        print("PASS  \(message)")
    } else {
        failed += 1
        print("FAIL  \(message)")
    }
}

private func state(isLive: Bool = false,
                   hasTrailer: Bool = false,
                   best: TVDetailBestState = .absent,
                   download: TVDetailDownloadState = .none) -> TVDetailActionState {
    TVDetailActionState(isLive: isLive, hasTrailer: hasTrailer, best: best, download: download)
}

private func expectStableSecondary(_ snapshot: TVDetailActionState, _ name: String) {
    let rows = TVDetailActionFocusPolicy.rows(for: snapshot)
    expect(rows.showsSecondary, "\(name): title-action row remains mounted")
    expect(rows.showsLibrary, "\(name): Library remains visible")
    expect(rows.secondaryAnchor == .secondary, "\(name): Library owns the stable secondary focus seat")
    expect(TVDetailActionFocusPolicy.destination(from: .lower, direction: .up, state: snapshot) == .secondary,
           "\(name): lower content returns to the stable secondary row")
}

@main
private struct TVDetailActionLayoutContract {
    static func main() {
// A source refresh may add, settle, or remove the best candidate. None of those transitions may remove the
// Library anchor or alter the Up graph.
let sourceStates: [(String, TVDetailActionState, Bool)] = [
    ("best absent", state(best: .absent), false),
    ("best settling", state(best: .settling), true),
    ("best ready", state(best: .ready), true),
    ("best removed after refresh", state(best: .absent), false),
    ("trailer absent", state(hasTrailer: false, best: .ready), true),
    ("trailer present", state(hasTrailer: true, best: .ready), true),
]

for (name, snapshot, expectsDownload) in sourceStates {
    let rows = TVDetailActionFocusPolicy.rows(for: snapshot)
    expectStableSecondary(snapshot, name)
    expect(rows.showsDownload == expectsDownload, "\(name): download eligibility follows a present best source")
}

// The download's presentation state is intentionally orthogonal to the focus topology. This is especially
// important when its button swaps from Download to Downloading to Downloaded while the user is on the row.
for (name, download) in [
    ("download none", TVDetailDownloadState.none),
    ("download in progress", TVDetailDownloadState.inProgress),
    ("download done", TVDetailDownloadState.done),
] {
    let snapshot = state(best: .ready, download: download)
    let rows = TVDetailActionFocusPolicy.rows(for: snapshot)
    expectStableSecondary(snapshot, name)
    expect(rows.showsDownload, "\(name): an eligible VOD download remains visible")
}

let live = state(isLive: true, hasTrailer: false, best: .ready, download: .unavailable)
expectStableSecondary(live, "live source ready")
expect(!TVDetailActionFocusPolicy.rows(for: live).showsDownload,
       "live source ready: download is correctly suppressed without removing title actions")

// Explicit before/after scenarios replace the old conditional-row source assertions. The visual neighbours
// change, but a focused secondary region remains valid through each transition.
let refreshTransitions: [(String, TVDetailActionState, TVDetailActionState)] = [
    ("secondary appears conceptually", state(isLive: true, best: .absent, download: .unavailable), state(isLive: true, best: .ready, download: .unavailable)),
    ("secondary survives best removal", state(hasTrailer: true, best: .ready), state(hasTrailer: true, best: .absent)),
    ("secondary survives trailer removal", state(hasTrailer: true, best: .settling), state(hasTrailer: false, best: .settling)),
]
for (name, before, after) in refreshTransitions {
    let beforeRows = TVDetailActionFocusPolicy.rows(for: before)
    let afterRows = TVDetailActionFocusPolicy.rows(for: after)
    expect(beforeRows.showsSecondary && afterRows.showsSecondary,
           "\(name): secondary row never disappears")
    expect(beforeRows.secondaryAnchor == afterRows.secondaryAnchor,
           "\(name): focus anchor remains Library across the transition")
}

let directionalState = state(hasTrailer: true, best: .ready, download: .inProgress)
let directions: [(String, DetailFocusRegion, TVDetailFocusDirection, DetailFocusRegion?)] = [
    ("secondary Up", .secondary, .up, .primary),
    ("primary Up", .primary, .up, .top),
    ("lower Up", .lower, .up, .secondary),
    ("top Up", .top, .up, .shell),
    ("shell Up", .shell, .up, nil),
    ("secondary Down", .secondary, .down, nil),
    ("secondary Left", .secondary, .left, nil),
    ("secondary Right", .secondary, .right, nil),
]
for (name, origin, direction, destination) in directions {
    expect(TVDetailActionFocusPolicy.destination(from: origin, direction: direction, state: directionalState) == destination,
           "directional route: \(name)")
}

// Keep the source-level part of this harness restricted to view construction facts that a pure reducer cannot
// observe. These are layout/accessibility guarantees, not a second navigation implementation.
let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
let path = root + "/app/SourcesTV/DetailView.swift"
guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
    print("FAIL  could not read \(path)")
    exit(2)
}

expect(source.contains("private struct TVDetailActionRow"), "two-row view helper is present")
expect(source.contains("ScrollView(.horizontal, showsIndicators: false)"), "action rows scroll horizontally")
expect(source.contains(".fixedSize(horizontal: true, vertical: false)"), "action labels preserve intrinsic widths")
expect(source.contains(".scrollClipDisabled()"), "focused action effects remain unclipped")
expect(source.contains("focusSecondary(LibraryChip())"), "Library is installed as the source-row focus anchor")
expect(source.contains("TVDetailActionFocusPolicy.rows(for: actionState)"), "SwiftUI reads the production row policy")
expect(!source.contains("hasSecondaryRow"), "legacy conditional secondary-row state is removed")
expect(!source.contains("DetailFocusEscapePolicy"), "legacy source-only focus policy is removed")

if failed == 0 {
    print("PASS  tvOS detail action and focus contract (\(passed) checks)")
    exit(0)
} else {
    print("FAIL  tvOS detail action and focus contract (\(failed) failed, \(passed) passed)")
    exit(1)
}
    }
}
