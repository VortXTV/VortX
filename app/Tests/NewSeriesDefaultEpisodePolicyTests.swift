import Foundation

/// Independent issue #244 fixtures. Compile the production default-selection and exact-CW-target
/// policies beside this file; this test never starts a player, signs in, or fetches provider data.
@main
private enum NewSeriesDefaultEpisodePolicyTests {
    private struct Episode: Equatable {
        let id: String
        let season: Int?
    }

    nonisolated(unsafe) private static var checks = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else {
            fputs("FAIL: \(label)\n", stderr)
            exit(1)
        }
        checks += 1
    }

    private static func firstUnwatched(_ episodes: [Episode], watched: Set<String> = []) -> Episode? {
        EpisodeDefaultSelectionPolicy.firstUnwatched(
            in: episodes, season: { $0.season }, isWatched: { watched.contains($0.id) }
        )
    }

    private static func fallback(_ episodes: [Episode]) -> Episode? {
        EpisodeDefaultSelectionPolicy.fallback(in: episodes, season: { $0.season })
    }

    static func main() throws {
        let special = Episode(id: "show:0:1", season: 0)
        let first = Episode(id: "show:1:1", season: 1)
        let second = Episode(id: "show:1:2", season: 1)
        let nextSeason = Episode(id: "show:2:1", season: 2)
        let ordered = [special, first, second, nextSeason]

        expect(firstUnwatched(ordered) == first,
               "fresh title selects S1E1 even when S0E1 sorts first")
        expect(fallback(ordered) == first,
               "fresh-title fallback selects the first regular episode")
        expect(firstUnwatched(ordered, watched: [first.id]) == second,
               "ordinary progress selects the next unwatched regular episode")
        expect(firstUnwatched(ordered, watched: [first.id, second.id]) == nextSeason,
               "ordinary progress crosses a season boundary without selecting specials")
        expect(firstUnwatched(ordered, watched: [first.id, second.id, nextSeason.id]) == nil,
               "unwatched specials cannot override a fully watched regular inventory")
        expect(fallback(ordered) == first,
               "rewatch fallback starts the regular inventory")
        expect(firstUnwatched([special]) == special && fallback([special]) == special,
               "a specials-only inventory remains playable")
        expect(firstUnwatched([special], watched: [special.id]) == nil,
               "watched specials-only inventory uses fallback rather than claiming unwatched")
        expect(firstUnwatched([]) == nil && fallback([]) == nil,
               "empty metadata cannot manufacture an episode")

        let unnumbered = Episode(id: "custom-episode", season: nil)
        expect(firstUnwatched([special, unnumbered]) == unnumbered,
               "missing season metadata stays playable as ordinary provider content")
        expect(fallback([special, unnumbered]) == unnumbered,
               "fallback preserves provider content without a season coordinate")

        // Default-selection is deliberately subordinate to the real existing CW identity policy.
        // A resume/manual navigation hint to a special must not be redirected to the ordinary inventory.
        let ids = ordered.map(\.id)
        let explicitSpecial = DetailEpisodeTargetPolicy.preferred(
            orderedIDs: ids, initialVideoID: special.id, initialResumeSeconds: 0,
            newerPlaybackID: nil, localWatched: [], watched: []
        )
        expect(explicitSpecial == .init(videoID: special.id, isResume: false),
               "an exact zero-offset special navigation hint remains authoritative")
        let resumedSpecial = DetailEpisodeTargetPolicy.preferred(
            orderedIDs: ids, initialVideoID: special.id, initialResumeSeconds: 120,
            newerPlaybackID: nil, localWatched: [], watched: []
        )
        expect(resumedSpecial == .init(videoID: special.id, isResume: true),
               "an exact special resume hint retains its position")
        let newerSpecial = DetailEpisodeTargetPolicy.preferred(
            orderedIDs: ids, initialVideoID: first.id, initialResumeSeconds: 120,
            newerPlaybackID: special.id, localWatched: [], watched: []
        )
        expect(newerSpecial == .init(videoID: special.id, isResume: true),
               "newly confirmed local special playback outranks an older ordinary hint")

        if CommandLine.arguments.count > 1 {
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            for path in ["app/SourcesTV/DetailView.swift", "app/SourcesiOS/iOSDetailView.swift"] {
                let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                expect(source.contains("EpisodeDefaultSelectionPolicy.firstUnwatched("),
                       "\(path) wires the production first-unwatched policy")
                expect(source.contains("EpisodeDefaultSelectionPolicy.fallback("),
                       "\(path) wires the production fallback policy")
                expect(source.contains("DetailEpisodeTargetPolicy.preferred("),
                       "\(path) retains the exact CW target policy")
                expect(source.contains("if newerPlaybackVideoID != nil || validInitialVideoID != nil { return nil }"),
                       "\(path) cannot substitute a default for an absent exact CW target")
            }
        }

        print("NewSeriesDefaultEpisodePolicyTests: \(checks) checks passed")
    }
}
