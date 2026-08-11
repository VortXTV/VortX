// Standalone executable contract for the caller side of next-episode prepared-remux adoption.
//
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/prepared-remux-caller-wiring \
//     app/Sources/Player/VortXPreparedRemuxPolicy.swift \
//     app/Tests/PreparedRemuxCallerWiringTests.swift && /tmp/prepared-remux-caller-wiring

import Foundation

@main
struct PreparedRemuxCallerWiringTests {
    nonisolated(unsafe) private static var passed = 0
    nonisolated(unsafe) private static var failed = 0

    static func main() {
        eligibleLocalDolbyVisionUsesDolbyVisionMode()
        eligibleLocalPlainMKVUsesPlainMode()
        rawTorrentNeverStartsLocalRemuxPreparation()
        externalEngineNeverStartsLocalRemuxPreparation()
        nonAVPlayerPlaybackNeverStartsLocalRemuxPreparation()
        exactOwnerIsRequiredAtAdmission()
        earlySkipWithoutAReadyHandleColdLoadsOnce()
        eligibleRemuxUsesOneTransportWarmPath()
        productionWiringCarriesAndConsumesTheExactHandle()

        print("")
        print(failed == 0 ? "ALL PASS (\(passed) checks)" : "FAILURES: \(failed) of \(passed + failed) checks")
        exit(failed == 0 ? 0 : 1)
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passed += 1
            print("PASS  \(message)")
        } else {
            failed += 1
            print("FAIL  \(message)")
        }
    }

    private static func eligibleLocalDolbyVisionUsesDolbyVisionMode() {
        expect(
            VortXPreparedRemuxCallerPolicy.mode(
                avPlayerActive: true,
                mountIsOnDevice: true,
                rawTorrent: false,
                dolbyVision: true,
                dolbyVisionRemuxEligible: true,
                plainRemuxEligible: false
            ) == .dolbyVision,
            "a local AVPlayer Dolby Vision remux source prepares the Dolby Vision transport"
        )
    }

    private static func eligibleLocalPlainMKVUsesPlainMode() {
        expect(
            VortXPreparedRemuxCallerPolicy.mode(
                avPlayerActive: true,
                mountIsOnDevice: true,
                rawTorrent: false,
                dolbyVision: false,
                dolbyVisionRemuxEligible: false,
                plainRemuxEligible: true
            ) == .plain,
            "a local AVPlayer plain-MKV source prepares the plain remux transport"
        )
    }

    private static func rawTorrentNeverStartsLocalRemuxPreparation() {
        expect(
            VortXPreparedRemuxCallerPolicy.mode(
                avPlayerActive: true,
                mountIsOnDevice: true,
                rawTorrent: true,
                dolbyVision: true,
                dolbyVisionRemuxEligible: true,
                plainRemuxEligible: false
            ) == nil,
            "a raw torrent retains its single tracker-aware create lane and never starts a local remux preload"
        )
    }

    private static func externalEngineNeverStartsLocalRemuxPreparation() {
        expect(
            VortXPreparedRemuxCallerPolicy.mode(
                avPlayerActive: true,
                mountIsOnDevice: false,
                rawTorrent: false,
                dolbyVision: true,
                dolbyVisionRemuxEligible: true,
                plainRemuxEligible: false
            ) == nil,
            "external Mac-engine mode skips the on-device prepared-remux producer"
        )
    }

    private static func nonAVPlayerPlaybackNeverStartsLocalRemuxPreparation() {
        expect(
            VortXPreparedRemuxCallerPolicy.mode(
                avPlayerActive: false,
                mountIsOnDevice: true,
                rawTorrent: false,
                dolbyVision: true,
                dolbyVisionRemuxEligible: true,
                plainRemuxEligible: false
            ) == nil,
            "libmpv playback does not spend the one producer slot on an AVPlayer-only transport"
        )
    }

    private static func exactOwnerIsRequiredAtAdmission() {
        let actual = VortXPreparedRemuxOwnerIdentity(
            mediaID: "tt123:1:2", generation: 9, sourceSignature: "4k/dv/addon"
        )
        expect(
            VortXPreparedRemuxCallerPolicy.admission(
                actualOwner: actual,
                expectedOwner: actual,
                avPlayerActive: true,
                mountIsOnDevice: true
            ) == .configure,
            "the exact episode, generation and source signature may configure the next AVPlayer load"
        )
        for mismatch in [
            VortXPreparedRemuxOwnerIdentity(mediaID: "tt123:1:3", generation: 9, sourceSignature: "4k/dv/addon"),
            VortXPreparedRemuxOwnerIdentity(mediaID: "tt123:1:2", generation: 10, sourceSignature: "4k/dv/addon"),
            VortXPreparedRemuxOwnerIdentity(mediaID: "tt123:1:2", generation: 9, sourceSignature: "1080p/other")
        ] {
            expect(
                VortXPreparedRemuxCallerPolicy.admission(
                    actualOwner: actual,
                    expectedOwner: mismatch,
                    avPlayerActive: true,
                    mountIsOnDevice: true
                ) == .abandonAndColdLoad,
                "a wrong episode, generation or source signature abandons once and cold-loads"
            )
        }
    }

    private static func earlySkipWithoutAReadyHandleColdLoadsOnce() {
        expect(
            VortXPreparedRemuxCallerPolicy.loadPath(
                hasPreparedHandle: false,
                admission: .abandonAndColdLoad
            ) == .coldLoad,
            "an early skip before readiness issues one cold load"
        )
    }

    private static func eligibleRemuxUsesOneTransportWarmPath() {
        expect(
            VortXPreparedRemuxCallerPolicy.transportWarmPath(
                preparedMode: .dolbyVision
            ) == .preparedRemux,
            "an eligible remux uses its startup cohort instead of a redundant prefix GET"
        )
        expect(
            VortXPreparedRemuxCallerPolicy.transportWarmPath(
                preparedMode: nil
            ) == .prefixRange,
            "an ordinary direct or raw-torrent source keeps the bounded prefix warm-up"
        )
    }

    private static func productionWiringCarriesAndConsumesTheExactHandle() {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let playerScreen = read(root.appendingPathComponent("app/Sources/PlayerScreen.swift"))
        let iosDetail = read(root.appendingPathComponent("app/SourcesiOS/iOSDetailView.swift"))
        let tvPlayer = read(root.appendingPathComponent("app/SourcesTV/TVPlayerView.swift"))

        expect(playerScreen.contains("var preparedRemux: VortXPreparedRemuxAttachment?"),
               "PlayerEpisodeStream carries the ready transport across the retained episode boundary")
        expect(iosDetail.contains("AVPlayerEngineController.prepareRemuxTransport"),
               "iOS and macOS prepare the transport after source resolution")
        expect(tvPlayer.contains("AVPlayerEngineController.prepareRemuxTransport"),
               "tvOS prepares the transport after source resolution")
        expect(playerScreen.contains("configurePreparedRemuxForNextLoad"),
               "iOS and macOS configure the exact handle immediately before AVPlayer loadFile")
        expect(tvPlayer.contains("configurePreparedRemuxForNextLoad"),
               "tvOS configures the exact handle immediately before AVPlayer loadFile")
        expect(iosDetail.contains("rawTorrent: requiresTorrentPreparation"),
               "iOS and macOS explicitly fence raw torrents from prepared remux")
        expect(tvPlayer.contains("rawTorrent: requiresTorrentPreparation"),
               "tvOS explicitly fences raw torrents from prepared remux")
        expect(
            iosDetail.contains("VortXPreparedRemuxCallerPolicy.transportWarmPath(")
                && appearsBefore(
                    "let preparedMode = VortXPreparedRemuxCallerPolicy.mode(",
                    "BoundedRangeWarmup.fetch(mediaRequest",
                    in: iosDetail
                ),
            "iOS and macOS choose prepared remux versus prefix range before issuing transport work"
        )
        expect(
            tvPlayer.contains("VortXPreparedRemuxCallerPolicy.transportWarmPath(")
                && appearsBefore(
                    "let preparedMode = VortXPreparedRemuxCallerPolicy.mode(",
                    "BoundedRangeWarmup.fetch(request)",
                    in: tvPlayer
                ),
            "tvOS chooses prepared remux versus prefix range before issuing transport work"
        )
        expect(
            playerScreen.contains("let admissionPreparedRemux = retainedPreparedEpisode?.preparedRemux")
                && playerScreen.contains("if !admissionCommandIssued {")
                && playerScreen.contains("episode admission task ended before prepared-remux issue"),
            "iOS and macOS same-URL, stale and rejected commands retire the taken handle in the admission defer"
        )
        expect(
            tvPlayer.contains("discardPreparedEpisode(pre, reason: \"episode admission rejected duplicate media\")")
                && tvPlayer.contains("discardPreparedEpisode(pre, reason: \"player rejected prepared episode command\")"),
            "tvOS same-URL and rejected commands discard the retained prepared handle"
        )
        expect(
            tvPlayer.contains("PreparedTorrentAdmissionPolicy.shouldIssuePlaybackCreate")
                && tvPlayer.contains("leaseAdopted: preparedTorrentAdopted"),
            "tvOS suppresses a duplicate playback create after adopting the tracker-aware torrent lease"
        )
    }

    private static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func appearsBefore(_ first: String, _ second: String, in text: String) -> Bool {
        guard let firstRange = text.range(of: first),
              let secondRange = text.range(of: second) else { return false }
        return firstRange.lowerBound < secondRange.lowerBound
    }
}
