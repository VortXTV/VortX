import Foundation

// Compile with SourcesShared/AppleCWSeasonRolloverPolicy.swift; execute from the repository root.
@main
private enum DetailEpisodeTargetPolicyTests {
    nonisolated(unsafe) private static var checks = 0
    private static func expect(_ result: Bool, _ label: String) {
        precondition(result, label)
        checks += 1
    }

    static func main() throws {
        typealias Policy = DetailEpisodeTargetPolicy
        let episodes = ["fg:0:1", "fg:6:1", "fg:6:2", "fg:6:3", "fg:6:4"]
        func target(_ initial: String?, _ position: Double? = 900, newer: String? = nil,
                    local: Set<String> = [], watched: Set<String> = []) -> Policy.Target? {
            Policy.preferred(orderedIDs: episodes, initialVideoID: initial, initialResumeSeconds: position,
                             newerPlaybackID: newer, localWatched: local, watched: watched)
        }
        expect(target("fg:6:2") == .init(videoID: "fg:6:2", isResume: true),
               "S6E2 CW fallback retains position instead of unwatched S0E1")
        expect(target("fg:6:2", 0) == .init(videoID: "fg:6:2", isResume: false),
               "zero-offset next episode is still the exact CW target")
        expect(target("fg:6:2", nil) == .init(videoID: "fg:6:2", isResume: false),
               "missing offset does not erase an exact episode")
        expect(target("fg:0:1", 0) == .init(videoID: "fg:0:1", isResume: false),
               "explicitly selected specials remain supported")
        expect(target("not-present") == nil && target(nil) == nil,
               "missing inventory identity leaves ordinary detail selection untouched")
        expect(target("fg:6:2", .nan)?.isResume == false,
               "invalid offset cannot claim a resume")
        expect(target("fg:6:2", newer: "fg:6:3") == .init(videoID: "fg:6:3", isResume: true),
               "newer successful playback supersedes the immutable initial CW target")
        expect(target("fg:6:2", newer: "fg:6:3", watched: ["fg:6:3"])
               == .init(videoID: "fg:6:3", isResume: true),
               "Trakt-only watched mirror cannot veto local in-progress playback")
        expect(target("fg:6:2", newer: "fg:6:3", local: ["fg:6:3"], watched: ["fg:6:3"])
               == .init(videoID: "fg:6:4", isResume: false),
               "finished current episode advances forward, never back to unwatched specials")
        expect(target("fg:6:2", newer: "fg:6:4", local: ["fg:6:4"], watched: ["fg:6:4"])
               == .init(videoID: "fg:6:4", isResume: false),
               "final visible episode does not wrap back to S0")
        let opened = Date(timeIntervalSince1970: 1_000)
        for seconds in [999.0, 1_000.0] {
            expect(Policy.newerPlaybackID(videoID: "fg:1:1", savedAt: Date(timeIntervalSince1970: seconds),
                                          openedAt: opened) == nil,
                   "older/equal local stream receipt cannot defeat incoming cross-device CW")
        }
        expect(Policy.newerPlaybackID(videoID: "fg:6:3", savedAt: Date(timeIntervalSince1970: 1_001),
                                      openedAt: opened) == "fg:6:3", "later first-frame receipt wins")
        expect(Policy.newerPlaybackID(videoID: "", savedAt: nil, openedAt: opened) == nil,
               "absent receipt cannot retire navigation hint")
        let root = FileManager.default.currentDirectoryPath
        for path in ["app/SourcesTV/DetailView.swift", "app/SourcesiOS/iOSDetailView.swift"] {
            let source = try String(contentsOfFile: root + "/" + path, encoding: .utf8)
            expect(source.contains("DetailEpisodeTargetPolicy.preferred(")
                   && source.contains("profileID: profiles.activeID")
                   && source.contains("openedAt: resumeHintOpenedAt"),
                   "production detail uses current-profile, visit-scoped playback receipt: \(path)")
            expect(source.contains("newerPlaybackVideoID ?? validInitialVideoID"),
                   "season selector follows the same preferred identity as hero: \(path)")
            expect(source.contains("if newerPlaybackVideoID != nil || validInitialVideoID != nil { return nil }"),
                   "partial metadata cannot redirect an unresolved CW episode to S0: \(path)")
            expect(source.contains("guard saved.timeOffsetMs > 0, saved.videoId == video.id else { return nil }"),
                   "resume offset is fenced to selected episode: \(path)")
        }
        print("DetailEpisodeTargetPolicyTests: \(checks) checks passed")
    }
}
