import Foundation

@main enum ChosenReleaseContinuityTests {
    static func main() throws {
        typealias P = ChosenReleaseContinuityPolicy
        precondition(P.priority(addon: "AIOStreams", bingeGroup: "release-A", preferredAddon: "aiostreams", preferredBingeGroup: "release-A") == 3)
        precondition(P.priority(addon: "AIOStreams", bingeGroup: "release-B", preferredAddon: "AIOStreams", preferredBingeGroup: "release-A") == 2)
        precondition(P.priority(addon: "Other", bingeGroup: "release-A", preferredAddon: "AIOStreams", preferredBingeGroup: "release-A") == 0, "opaque IDs cannot collide across known add-ons")
        precondition(P.priority(addon: "Other", bingeGroup: "release-a", preferredAddon: nil, preferredBingeGroup: "release-A") == 0, "opaque group IDs are case-sensitive")
        precondition(P.priority(addon: "AIOStreams", bingeGroup: "release-A", preferredAddon: "AIOStreams", preferredBingeGroup: "release-A", unhealthy: true) == 0)
        precondition(P.precedes(pinned: false, priority: 3, rank: 1, offset: 3,
                               otherPinned: false, otherPriority: 0, otherRank: 100_000, otherOffset: 0), "chosen release must not lose to generic cache/quality score")
        precondition(!P.precedes(pinned: false, priority: 3, rank: 1, offset: 0,
                                otherPinned: true, otherPriority: 0, otherRank: 1, otherOffset: 1), "explicit pin stays authoritative")
        precondition(P.precedes(pinned: false, priority: 0, rank: 2, offset: 1,
                               otherPinned: false, otherPriority: 0, otherRank: 1, otherOffset: 0), "missing release uses generic ranking")
        precondition(P.precedes(pinned: false, priority: 0, rank: 1, offset: 0,
                               otherPinned: false, otherPriority: 0, otherRank: 1, otherOffset: 1), "ties preserve original order")
        let paths = ["app/SourcesTV/TVPlayerView.swift", "app/SourcesiOS/iOSDetailView.swift", "app/SourcesiOS/iOSBatchDownloadCoordinator.swift", "app/SourcesiOS/iOSRootView.swift"]
        for path in paths {
            let source = try String(contentsOfFile: path, encoding: .utf8)
            let minimum = path.contains("BatchDownload") ? 2 : 3
            precondition(source.components(separatedBy: "preserveChosenRelease: true").count >= minimum,
                         "both advance/preload or winner/fallback paths must preserve choice: \(path)")
        }
        let detail = try String(contentsOfFile: "app/SourcesiOS/iOSDetailView.swift", encoding: .utf8)
        precondition(detail.contains("playWithAddon:") && detail.contains("downloadWithAddon:"))
        precondition(detail.contains("sourceAddon: sourceAddon") && detail.contains("initialSourceAddon: launch.sourceAddon"))
        let playPath = detail.components(separatedBy: "struct iOSEpisodeStreams:").last!
            .components(separatedBy: "private func play(").last!
            .components(separatedBy: "private func downloadStream").first!
        precondition(!playPath.contains("SeriesSourceSticky.record(seriesKey: meta.id, addon: sourceAddon"),
                     "launch cannot persist a source before accepted playback")
        let batch = try String(contentsOfFile: paths[2], encoding: .utf8)
        precondition(batch.contains("sticky: job.sticky"))
        precondition(batch.contains("let downloadCandidates = candidates.filter { job.downloadOwner.allows($0) }"),
                     "batch candidates must retain the captured download owner")
        precondition(batch.contains("iOSResolveRankedEpisodeCandidate(\n            downloadCandidates, episode: ep"),
                     "the selected index must belong to the owner-filtered candidate list")
        precondition(batch.contains("downloadCandidates.dropFirst(selected.index + 1)"),
                     "transfer retry must use that same list and not resurrect earlier resolution failures")
        print("PASS production release priority/comparator, provenance wiring, binge/preload/CW/batch fallback opt-in")
    }
}
