import Foundation

// No app, account, Keychain, provider requests, stream start or native engine is used. The
// production resource projection and complete CoreModels decode native-shaped in-memory fixtures.
// The actual CoreBridge predicates, accepted-publication branch and assembly are extracted unchanged.
@main @MainActor private enum AddonStreamPublicationTests {
    static var checks = 0
    static var failures = 0
    static func check(_ value: Bool, _ label: String) {
        checks += 1
        if !value { failures += 1 }
        print("\(value ? "PASS" : "FAIL") \(label)")
    }
    static let base = "https://provider.invalid/synthetic-config/manifest.json"
    static let original: [String: VortxJSON] = ["url": .string("https://media.invalid/old"), "name": .string("Synthetic source")]

    static func details(_ items: [[String: VortxJSON]], base: String = "https://provider.invalid/synthetic-config/manifest.json",
                        pathID: String = "synthetic-title:1:1", type: String = "series",
                        embedded: Bool = false, status: VortxResourceGroup.Status = .ready,
                        hostState: String? = nil, metadataName: String = "Synthetic title") throws -> CoreMetaDetails {
        let metaRequest = VortxResourceRequest(resource: .meta, type: type, id: "synthetic-title")
        let streamRequest = VortxResourceRequest(resource: .stream, type: type, id: pathID)
        let registry = [VortxResourceAddon(id: "synthetic-addon", transportUrl: base, manifest: nil)]
        var metadata: [String: VortxJSON] = ["id": .string("synthetic-title"), "type": .string(type), "name": .string(metadataName)]
        if embedded {
            metadata["videos"] = .array([.object(["id": .string(pathID), "title": .string("Synthetic episode"), "streams": .array(items.map(VortxJSON.object))])])
        }
        let meta = VortxResourceSnapshot(ownerID: "synthetic-owner", requestID: "synthetic-meta", generation: 1,
            request: metaRequest, groups: [.init(addonId: "synthetic-addon", status: .ready,
                content: .object(["meta": .object(metadata)]), error: nil)], sourceURLs: ["synthetic-addon": base])
        let stream = VortxResourceSnapshot(ownerID: "synthetic-owner", requestID: "synthetic-stream", generation: 1,
            request: streamRequest, groups: embedded ? [] : [.init(addonId: "synthetic-addon", status: status,
                content: status == .ready ? .object(["streams": .array(items.map(VortxJSON.object))]) : nil,
                error: status == .ready ? nil : .init(code: "timeout"))], sourceURLs: ["synthetic-addon": base])
        let projected = try VortxResourceProjection.metaDetails(meta: meta, streams: stream,
            expectedStream: streamRequest, registry: registry)
        // Loading/missing content is host-owned initial state, not a terminal native response.
        if let hostState, case .object(var root) = projected,
           case .object(var row) = root["streams"]?.array?.first {
            row["content"] = hostState == "missing" ? nil : .object(["type": .string(hostState)])
            root["streams"] = .array([.object(row)])
            return try VortxJSON.object(root).decode(CoreMetaDetails.self)
        }
        return try projected.decode(CoreMetaDetails.self)
    }

    static func replacement(_ label: String, old: CoreMetaDetails, next: CoreMetaDetails) {
        let probe = AddonPublicationProbe()
        probe.names = [base: "Synthetic A", "https://replacement.invalid/manifest.json": "Synthetic B"]
        probe.accept(old)
        let before = probe.streamsEpoch
        check(probe.needs(next), "\(label) republishes")
        check(probe.streamsChange(next), "\(label) changes source epoch")
        probe.accept(next)
        let expected = AddonPublicationProbe(); expected.names = probe.names; expected.accept(next)
        check(probe.streamsEpoch == before + 1 && probe.groups() == expected.groups(), "\(label) accepted rows contain replacement")
        let after = probe.streamsEpoch
        probe.accept(next)
        check(probe.streamsEpoch == after, "\(label) identical repeat stays quiet")
    }

    static func timing() throws {
        let count = 3_000, iterations = 100
        let values: [[String: VortxJSON]] = (0..<count).map { index in
            ["url": .string("https://media.invalid/synthetic/\(index)"), "name": .string("Synthetic \(index)"),
             "description": .string("Synthetic description"), "fileIdx": .integer(Int64(index)),
             "behaviorHints": .object(["bingeGroup": .string("synthetic-group"), "filename": .string("synthetic.mkv"),
                 "proxyHeaders": .object(["request": .object(["Referer": .string("https://referrer.invalid/synthetic")])])])]
        }
        let first = try details(values), equal = try details(values)
        var changed = values
        changed[count - 1]["url"] = .string("https://media.invalid/synthetic/tail-replacement")
        let tail = try details(changed)
        let probe = AddonPublicationProbe(); probe.accept(first)
        let initialEpoch = probe.streamsEpoch
        let equalStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { probe.accept(equal) }
        let equalElapsed = DispatchTime.now().uptimeNanoseconds - equalStart
        check(probe.streamsEpoch == initialEpoch, "3000 separately decoded equal streams do not republish")
        let tailStart = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations { probe.accept(index.isMultiple(of: 2) ? tail : first) }
        let tailElapsed = DispatchTime.now().uptimeNanoseconds - tailStart
        check(probe.streamsEpoch == initialEpoch + iterations, "3000-stream tail changes all publish through both actual comparisons")
        check(probe.groups().first?.streams.count == count, "3000-stream timing keeps every row")
        print(String(format: "TIMING actual accepted branch streams=%d iterations=%d optimization=none equal_total_ms=%.3f equal_mean_ms=%.3f tail_total_ms=%.3f tail_mean_ms=%.3f",
            count, iterations, Double(equalElapsed) / 1_000_000, Double(equalElapsed) / Double(iterations) / 1_000_000,
            Double(tailElapsed) / 1_000_000, Double(tailElapsed) / Double(iterations) / 1_000_000))
    }

    static func main() throws {
        let old = try details([original])
        let changes: [(String, String, VortxJSON)] = [
            ("same-count URL", "url", .string("https://media.invalid/refreshed")),
            ("same-count torrent selector", "fileIdx", .integer(7)),
            ("same-count torrent hash", "infoHash", .string(String(repeating: "b", count: 40))),
            ("same-count tracker sources", "sources", .array([.string("tracker:synthetic")])),
            ("same-count external URL", "externalUrl", .string("https://external.invalid/new")),
            ("same-count YouTube selector", "ytId", .string("synthetic-new")),
            ("same-count NZB", "nzbUrl", .string("https://nzb.invalid/new.nzb")),
            ("same-count NZB mirrors", "nzbUrls", .array([.string("https://nzb.invalid/mirror.nzb")])),
            ("same-count NNTP hints", "servers", .array([.string("nntps://synthetic.invalid")])),
            ("same-count file matcher", "fileMustInclude", .string("episode-2")),
            ("same-count name", "name", .string("Updated source")),
            ("same-count description", "description", .string("Updated description")),
            ("same-count provenance", "vortxProvider", .string("synthetic-provider")),
            ("same-count required headers", "behaviorHints", .object(["proxyHeaders": .object(["request": .object(["Referer": .string("https://referrer.invalid/new")])])])),
            ("same-count binge hints", "behaviorHints", .object(["bingeGroup": .string("updated"), "filename": .string("episode.mkv"), "notWebReady": .bool(true)])),
            ("same-count video identity", "behaviorHints", .object(["videoHash": .string("synthetic-hash"), "videoSize": .integer(42)]))
        ]
        for (label, field, value) in changes {
            var changed = original; changed[field] = value
            replacement(label, old: old, next: try details([changed]))
        }
        replacement("same-count provider", old: old, next: try details([original], base: "https://replacement.invalid/manifest.json"))
        replacement("episode request", old: old, next: try details([original], pathID: "synthetic-title:1:2"))
        replacement("resource type", old: old, next: try details([original], type: "movie"))
        let second: [String: VortxJSON] = ["url": .string("https://media.invalid/second")]
        replacement("same-count stream order", old: try details([original, second]), next: try details([second, original]))
        var changed = original; changed["url"] = .string("https://media.invalid/new-embedded")
        replacement("embedded streams", old: try details([original], embedded: true), next: try details([changed], embedded: true))
        replacement("ready to error", old: old, next: try details([], status: .timeout))
        replacement("error to ready", old: try details([], status: .timeout), next: old)
        replacement("ready to empty", old: old, next: try details([]))
        replacement("loading to error", old: try details([], hostState: "Loading"), next: try details([], status: .timeout))
        replacement("loading to ready", old: try details([], hostState: "Loading"), next: old)
        replacement("missing to loading", old: try details([], hostState: "missing"), next: try details([], hostState: "Loading"))

        let probe = AddonPublicationProbe(); probe.accept(old)
        let identical = try details([original])
        check(!probe.needs(identical) && !probe.streamsChange(identical), "decoded identical native-shaped result stays quiet")
        check(probe.groups(streamID: "synthetic-title:1:2").isEmpty, "exact-episode assembly excludes previous episode")
        let oldEpoch = probe.streamsEpoch; probe.accept(nil)
        check(probe.groups().isEmpty && probe.streamsEpoch == oldEpoch + 1, "unload clears sources")
        probe.accept(old)
        check(probe.groups().count == 1 && probe.streamsEpoch == oldEpoch + 2, "same-value reload after unload republishes")
        let changedMetadata = try details([original], metadataName: "New metadata")
        let sourceEpoch = probe.streamsEpoch
        check(probe.needs(changedMetadata) && !probe.streamsChange(changedMetadata), "metadata-only update does not change source epoch")
        probe.accept(changedMetadata)
        check(probe.streamsEpoch == sourceEpoch && probe.metaDetails?.meta?.name == "New metadata", "metadata-only update still publishes")
        let numeric = try details([["url": .string("https://media.invalid/size"), "behaviorHints": .object(["videoSize": .integer(42)])]])
        let stringNumeric = try details([["url": .string("https://media.invalid/size"), "behaviorHints": .object(["videoSize": .string("42")])]])
        probe.accept(numeric)
        check(!probe.needs(stringNumeric) && !probe.streamsChange(stringNumeric), "decoder-equivalent byte counts stay quiet")
        try timing()
        print("\(checks) checks, \(failures) failures; synthetic values only; provider health unproven")
        if failures != 0 { exit(1) }
    }
}
