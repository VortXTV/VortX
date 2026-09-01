// Executable regression contract for the tvOS series episode-list Up boundary.
//
//   swiftc -parse-as-library \
//     app/SourcesTV/TVDetailEpisodeListFocusPolicy.swift \
//     app/Tests/TVDetailEpisodeListFocusContractTests.swift \
//     -o /tmp/tv-detail-episode-list-focus-contract \
//     && /tmp/tv-detail-episode-list-focus-contract <repository-root>
//
// This runs the same production boundary predicate DetailView uses. The SwiftUI integration remains
// deliberately narrow: only the first episode row receives a move-command handler.

import SwiftUI

private var failures = 0

private func expect(_ condition: Bool, _ message: String) {
    if condition {
        print("PASS  \(message)")
    } else {
        failures += 1
        print("FAIL  \(message)")
    }
}

@main
private struct TVDetailEpisodeListFocusContractTests {
    static func main() {
        expect(TVDetailEpisodeListFocusPolicy.rowOwnsUpEscape(at: 0),
               "first episode row owns the Up escape")

        for index in 1...12 {
            expect(!TVDetailEpisodeListFocusPolicy.rowOwnsUpEscape(at: index),
                   "episode row \(index) keeps native Up navigation")
        }

        expect(TVDetailEpisodeListFocusPolicy.destination(for: .up, fromEpisodeIndex: 0, episodeCount: 12) == .hero,
               "first episode forwards Up to the detail hero")
        expect(TVDetailEpisodeListFocusPolicy.destination(for: .down, fromEpisodeIndex: 0, episodeCount: 12) == .episode(1),
               "first episode explicitly focuses the second episode on Down")
        expect(TVDetailEpisodeListFocusPolicy.destination(for: .down, fromEpisodeIndex: 0, episodeCount: 1) == .native,
               "a one-episode list has no invented Down destination")
        for direction in [MoveCommandDirection.down, .left, .right] {
            if direction != .down {
                expect(TVDetailEpisodeListFocusPolicy.destination(for: direction, fromEpisodeIndex: 0, episodeCount: 12) == .native,
                       "first episode keeps \(String(describing: direction)) native")
            }
        }
        for index in 1...12 {
            expect(TVDetailEpisodeListFocusPolicy.destination(for: .up, fromEpisodeIndex: index, episodeCount: 13) == .native,
                   "episode row \(index) keeps native Up navigation")
        }

        // A season can grow while its rows are lazily realized. The index boundary stays at the first
        // position, so the existing stable CoreVideo.id focus identity for a deeper episode is unaffected.
        let focusedEpisodeID = "episode-10"
        let beforeGrowth = ["episode-1", "episode-2", focusedEpisodeID]
        let afterGrowth = beforeGrowth + (3...24).map { "episode-\($0)" }
        expect(beforeGrowth.contains(focusedEpisodeID) && afterGrowth.contains(focusedEpisodeID),
               "list growth preserves the existing episode focus identity")
        expect(!TVDetailEpisodeListFocusPolicy.rowOwnsUpEscape(at: 9),
               "episode 10 remains a native previous-row focus target after growth")

        let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
        let detailViewPath = root + "/app/SourcesTV/DetailView.swift"
        guard let detailView = try? String(contentsOfFile: detailViewPath, encoding: .utf8) else {
            print("FAIL  could not read \(detailViewPath)")
            exit(2)
        }

        expect(detailView.contains("ForEach(Array(episodes.enumerated()), id: \\.element.id)"),
               "episode rows retain their stable CoreVideo ids while exposing the row index")
        expect(detailView.contains("episodeRow(v).focused($focusedEpisode, equals: v.id).id(v.id)"),
               "episode row focus and scroll identities remain CoreVideo.id")
        expect(detailView.contains("TVDetailEpisodeListFocusPolicy.rowOwnsUpEscape(at: index)"),
               "SwiftUI asks the production boundary policy at each episode row")
        expect(detailView.contains("TVDetailEpisodeListFocusPolicy.destination("),
               "first-row directional routing is decided by the production policy")
        expect(detailView.contains("focusedEpisode = episodes[targetIndex].id"),
               "first-row Down targets the second row through its stable CoreVideo id")
        expect(detailView.contains("onEpisodeMove: { direction in"),
               "series detail supplies the optional hero-focus bridge")
        expect(!detailView.contains(".id(\"detailContent\")\n                            .onMoveCommand"),
               "the episode panel no longer intercepts every Up command at its parent")

        exit(failures == 0 ? 0 : 1)
    }
}
