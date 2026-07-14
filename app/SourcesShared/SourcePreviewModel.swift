import Foundation
import Combine

/// Live preview for Smart Source Selection (Lane A). Given the viewer's current chip state, it shows which
/// sources the ranker would surface (top 5) and how many the current filters would hide, so the Settings
/// panel can answer "what would these chips actually do?" without opening a title.
///
/// It reuses the EXACT off-main rank path `SourceListModel` uses: capture an immutable
/// `SourcePreferences.Snapshot` on the main actor (the chips write the live singleton via the documented
/// direct-singleton binding, so the snapshot already reflects the draft chip state), then run
/// `StreamRanking.rankedGroups` / `best` inside `SourcePreferences.$readingOverride.withValue(snapshot)` on a
/// detached task so the ranker never reads the mutable singleton across threads. Keystrokes are debounced so
/// typing into the Prefer / Avoid fields does not thrash the rank.
@MainActor
final class SourcePreviewModel: ObservableObject {

    /// One preview row: the parsed quality label, the pick reason badges, and whether it is the auto-pick.
    struct Row: Identifiable, Equatable {
        let id: String
        let qualityLabel: String
        let reason: String?
        let isBest: Bool
    }

    /// The top-N surfaced sources, best first.
    @Published private(set) var rows: [Row] = []
    /// How many sources the current chips would HIDE from the sample set (drops, not demotions).
    @Published private(set) var hiddenCount: Int = 0
    /// The size of the sample set the preview is computed over, so the UI can say "5 of 12 shown".
    @Published private(set) var sampleCount: Int = 0

    private let topN = 5
    private static let debounceMs = 250

    /// The sample stream set the preview ranks. Defaults to a small bundled fixture; a caller may feed the
    /// last opened detail's loaded groups instead for a title-accurate preview.
    private var sampleGroups: [CoreStreamSourceGroup]
    private var debounce: DispatchWorkItem?
    private var generation = 0

    init(sampleGroups: [CoreStreamSourceGroup]? = nil) {
        self.sampleGroups = sampleGroups ?? Self.fixtureGroups
        refresh()
    }

    /// Swap in a real sample set (e.g. the last detail's loaded groups) and recompute. Passing an empty set
    /// restores the bundled fixture, so the preview is never blank.
    func update(sampleGroups groups: [CoreStreamSourceGroup]) {
        self.sampleGroups = groups.isEmpty ? Self.fixtureGroups : groups
        refresh()
    }

    /// Recompute after a chip change, debounced so a burst of keystrokes coalesces into one rank.
    func refresh() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recompute() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.debounceMs), execute: work)
    }

    private func recompute() {
        generation += 1
        let gen = generation
        // Capture the frozen prefs snapshot ON THE MAIN ACTOR (same contract as SourceListModel), so the
        // detached rank cannot race the singleton the chips are mutating.
        let snapshot = SourcePreferences.shared.snapshot()
        let groups = sampleGroups
        let inputCount = groups.reduce(0) { $0 + $1.streams.count }
        let want = topN
        Task.detached(priority: .userInitiated) { [weak self] in
            let (rows, keptCount): ([Row], Int) = SourcePreferences.$readingOverride.withValue(snapshot) {
                let ranked = StreamRanking.rankedGroups(groups)
                let best = StreamRanking.best(ranked)
                let bestID = best?.id
                let flat = ranked.flatMap { $0.streams }
                    .filter { $0.playableURL != nil && !$0.isYouTubeTrailer }
                let kept = flat.count
                let top = flat.prefix(want).map { s in
                    Row(id: s.id,
                        qualityLabel: StreamRanking.watchLabel(s),
                        reason: StreamRanking.pickReason(s),
                        isBest: s.id == bestID)
                }
                return (top, kept)
            }
            await MainActor.run {
                guard let self, gen == self.generation else { return }
                self.rows = rows
                self.sampleCount = inputCount
                // Hidden = sample inputs that did NOT survive the filters (drops). Demoted-but-visible
                // sources in "rank" mode are still kept, so they are NOT counted here.
                self.hiddenCount = max(0, inputCount - keptCount)
            }
        }
    }

    // MARK: - Bundled fixture

    /// A small, representative sample used when no real groups are supplied: a cached 4K remux, a 1080p
    /// WEB-DL, an HEVC 4K, a CAM (always safety-hidden), and a 720p, enough to make Prefer / Avoid / Only /
    /// resolution chips visibly change the ordering and the hidden count in the preview.
    static let fixtureGroups: [CoreStreamSourceGroup] = {
        let samples: [(String, [String: Any])] = [
            ("4K Remux Cached", ["name": "Movie 2023 2160p BluRay REMUX HDR DV Atmos [RD+] 💾 54.3 GB",
                                 "url": "https://cdn.example.com/a.mkv",
                                 "infoHash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]),
            ("1080p WEB-DL",    ["name": "Movie 2023 1080p WEB-DL H.264 DDP5.1 💾 6.2 GB",
                                 "url": "https://cdn.example.com/b.mp4"]),
            ("4K HEVC",         ["name": "Movie 2023 2160p WEB-DL HEVC HDR10 💾 18.4 GB",
                                 "url": "https://cdn.example.com/c.mkv"]),
            ("CAM",             ["name": "Movie 2023 HDCAM x264 💾 1.8 GB",
                                 "url": "https://cdn.example.com/d.mp4"]),
            ("720p",            ["name": "Movie 2023 720p WEBRip x264 💾 2.1 GB",
                                 "url": "https://cdn.example.com/e.mp4"]),
        ]
        let decoder = JSONDecoder()
        var groups: [CoreStreamSourceGroup] = []
        for (i, entry) in samples.enumerated() {
            guard let data = try? JSONSerialization.data(withJSONObject: entry.1),
                  let stream = try? decoder.decode(CoreStream.self, from: data) else { continue }
            groups.append(CoreStreamSourceGroup(id: "fixture-\(i)", addon: entry.0, streams: [stream]))
        }
        return groups
    }()
}
