// Production-linked regression gate for issue #165.
//
// Run from the repository root:
//
//   xcrun swiftc -parse-as-library \
//     app/SourcesShared/DetailMetaRecoveryPolicy.swift \
//     app/Tests/MetaResolutionFallbackTests.swift \
//     -o /tmp/vortx-meta-recovery-tests && /tmp/vortx-meta-recovery-tests
//
// The state and catalog-ID assertions execute the real helper shipped by the app. The final checks
// read the source files to prove that CoreModels, CoreBridge, and both detail surfaces still consume
// that helper at the required integration points.

import Foundation

@main
enum MetaResolutionFallbackTests {
    private static var failures = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        if condition() {
            print("PASS  \(label)")
        } else {
            failures += 1
            print("FAIL  \(label)")
        }
    }

    private static func source(_ relativePath: String, root: URL) -> String {
        let url = root.appendingPathComponent(relativePath)
        guard let value = try? String(contentsOf: url, encoding: .utf8) else {
            failures += 1
            print("FAIL  could not read \(relativePath)")
            return ""
        }
        return value
    }

    static func main() {
        typealias Policy = DetailMetaRecoveryPolicy

        check(
            Policy.resolution(selectedID: "tmdb:603", requestedID: "tmdb:603", entries: []) == .unresolved,
            "matching selection with no planned request is terminal"
        )
        check(
            Policy.resolution(selectedID: "tmdb:603", requestedID: "tvdb:81189", entries: []) == nil,
            "selection mismatch is not terminal for the new page"
        )
        check(
            Policy.resolution(
                selectedID: "tmdb:603",
                requestedID: "tmdb:603",
                entries: [.notStarted]
            ) == .pending,
            "an entry with no content is pending"
        )
        check(
            Policy.resolution(
                selectedID: "tmdb:603",
                requestedID: "tmdb:603",
                entries: [.failed, .loading]
            ) == .pending,
            "one loading provider keeps a mixed result pending"
        )
        check(
            Policy.resolution(
                selectedID: "tmdb:603",
                requestedID: "tmdb:603",
                entries: [.failed, .failed]
            ) == .unresolved,
            "all failed providers are terminal"
        )
        check(
            Policy.resolution(
                selectedID: "tmdb:603",
                requestedID: "tmdb:603",
                entries: [.failed, .ready]
            ) == .ready,
            "one ready provider wins"
        )
        check(
            Policy.resolution(entries: [.loading]) != Policy.resolution(entries: [.failed]),
            "loading-to-error changes the bridge-visible resolution"
        )

        check(Policy.catalogIDShape("tt0111161") == .imdb("tt0111161"), "IMDb ID passes through")
        check(
            Policy.catalogIDShape("imdb:tt0111161") == .imdb("tt0111161"),
            "embedded IMDb component passes through"
        )
        check(
            Policy.catalogIDShape("tmdb:603") == .tmdb(603, media: nil),
            "untyped TMDB ID parses"
        )
        check(
            Policy.catalogIDShape("tmdb:movie:603") == .tmdb(603, media: .movie),
            "typed TMDB movie ID parses"
        )
        check(
            Policy.catalogIDShape("tmdb:tv:1396") == .tmdb(1396, media: .tv),
            "typed TMDB TV ID parses"
        )
        check(Policy.catalogIDShape("tvdb:81189") == .tvdb(81189), "TVDB ID parses")
        check(
            Policy.catalogIDShape("603") == .tmdb(603, media: nil),
            "legacy bare TMDB number parses"
        )
        check(Policy.catalogIDShape("tt") == .unsupported, "IMDb prefix without digits is rejected")
        check(Policy.catalogIDShape("tmdb::603") == .unsupported, "empty TMDB media is rejected")
        check(
            Policy.catalogIDShape("tmdb:series:603") == .unsupported,
            "unknown TMDB media is rejected"
        )
        check(Policy.catalogIDShape("tvdb:foo:81189") == .unsupported, "malformed TVDB ID is rejected")
        // Kitsu ids get a shape of their own (anime add-ons hand them out constantly, and they used to have
        // no recovery path at all). They are NOT folded onto the bare-number TMDB rule: a Kitsu id and a TMDB
        // id that happen to share a number are unrelated titles.
        check(Policy.catalogIDShape("kitsu:460") == .kitsu(460), "Kitsu ID parses")
        check(Policy.catalogIDShape("KITSU:460") == .kitsu(460), "Kitsu scheme is case-insensitive")
        check(Policy.catalogIDShape("kitsu:460") != .tmdb(460, media: nil), "Kitsu ID is not guessed as TMDB")
        check(Policy.catalogIDShape("kitsu:foo") == .unsupported, "malformed Kitsu ID is rejected")
        check(
            Policy.catalogIDShape("kitsu:460:1:2") == .unsupported,
            "episode-qualified Kitsu ID is not a detail route and stays unsupported"
        )
        check(
            Policy.catalogIDShape("kitsu:tt0069576") == .imdb("tt0069576"),
            "an embedded IMDb component still wins over the Kitsu scheme"
        )
        check(Policy.catalogIDShape("anidb:1078") == .unsupported, "unknown scheme is not guessed")

        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
        let models = source("app/SourcesShared/CoreModels.swift", root: root)
        let bridge = source("app/SourcesShared/CoreBridge.swift", root: root)
        let tv = source("app/SourcesTV/DetailView.swift", root: root)
        let ios = source("app/SourcesiOS/iOSDetailView.swift", root: root)

        check(models.contains("let selected: CoreMetaSelection?"), "CoreModels decodes selected.metaPath")
        check(models.contains("func metaResolution(for requestedID: String)"), "CoreModels exposes scoped resolution")
        check(
            bridge.contains("current.selectedMetaID != next.selectedMetaID")
                && bridge.contains("current.metaResolution != next.metaResolution"),
            "CoreBridge republishes selection and resolution transitions"
        )
        check(
            bridge.contains("canonicalReadyMetaTarget")
                && bridge.contains("return (imdb, readyMeta.type)")
                && tv.contains("requestType: target.type")
                && ios.contains("requestType: target.type"),
            "canonical ready metadata carries its authoritative content type into recovery"
        )
        check(
            tv.contains("pageID: metaRequestID")
                && tv.contains("catalogID: id")
                && tv.contains("metaUnavailablePage")
                && tv.contains("VXProbeRedaction.identityToken"),
            "tvOS wires effective requests while preserving raw catalog source identity"
        )
        check(
            ios.contains("pageID: metaRequestID")
                && ios.contains("SourcePinContext(metaId: id")
                && ios.contains("VXProbeRedaction.identityToken"),
            "iOS and Mac wire effective requests while preserving the existing raw pin context"
        )
        check(
            tv.contains("guard !LiveTypes.contains(type)")
                && ios.contains("guard !LiveTypes.contains(type)"),
            "metadata recovery remains disabled for live types"
        )
        let tmdb = source("app/SourcesShared/TMDBClient.swift", root: root)
        check(
            tmdb.contains("case .kitsu(let kitsuID) = shape")
                && tmdb.contains("kitsuMappedShape(forKitsuID:"),
            "the Kitsu shape is mapped to a TMDB-answerable shape before resolution"
        )
        // Both surfaces must offer a way OUT of a terminal metadata failure. tvOS has had one since the
        // recovery work landed; iOS/Mac used to spin on the skeleton hero forever.
        check(
            tv.contains("metaUnavailablePage") && tv.contains("retryMeta()")
                && ios.contains("metaUnavailableScreen") && ios.contains("retryMeta()"),
            "both detail surfaces render a terminal page with a retry"
        )
        // The one-attempt latch must survive a cancel that happened BEFORE the lookup ran, or an engine
        // republish permanently latches "Details unavailable" with no lookup having ever completed.
        check(
            tv.contains("if !lookupCompleted && Task.isCancelled { metaRecoveryAttempted = false }")
                && ios.contains("if !lookupCompleted && Task.isCancelled { metaRecoveryAttempted = false }"),
            "a pre-network cancel re-arms the recovery attempt on both surfaces"
        )

        if failures == 0 {
            print("PASS  all issue #165 checks")
        } else {
            print("FAIL  \(failures) issue #165 check(s)")
            exit(1)
        }
    }
}
