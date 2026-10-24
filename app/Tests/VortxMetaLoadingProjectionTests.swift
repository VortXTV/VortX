import Foundation

enum VortxMetaLoadingProjectionTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func replacing(_ value: VortxJSON, _ key: String, _ replacement: VortxJSON) -> VortxJSON {
        guard case .object(var fields) = value else { fatalError("object fixture required") }
        fields[key] = replacement; return .object(fields)
    }
    static func run() {
        let metaPath: VortxJSON = .object(["resource": .string("meta"), "type": .string("series"),
            "id": .string("title"), "extra": .array([])])
        func request(_ base: String, path: VortxJSON? = nil) -> VortxJSON {
            .object(["base": .string(base), "path": path ?? metaPath])
        }
        func row(_ base: String, _ content: VortxJSON, path: VortxJSON? = nil) -> VortxJSON {
            .object(["request": request(base, path: path), "content": content,
                     "rowExtension": .string("new-row-extension")])
        }
        let metadata: VortxJSON = .object(["id": .string("title"), "type": .string("series"),
            "name": .string("Title"), "videos": .array([.object(["id": .string("episode-two"),
                "season": .integer(1), "episode": .integer(2), "providerExtension": .unsigned(UInt64.max)])]),
            "unknownProviderObject": .object(["nested": .array([.null, .bool(true), .integer(7)])])])
        let ready: VortxJSON = .object(["type": .string("Ready"), "content": metadata,
                                     "contentExtension": .string("unchanged")])
        let loading: VortxJSON = .object(["type": .string("Loading")])
        let error: VortxJSON = .object(["type": .string("Err"), "content": .object(["code": .string("network")])])
        func projection(_ rows: [VortxJSON], episode: String, meta: VortxJSON? = nil,
                        streams: [VortxJSON] = []) -> VortxJSON {
            .object(["selected": .object(["metaPath": meta ?? metaPath, "streamPath": .object([
                "resource": .string("stream"), "type": .string("series"), "id": .string(episode), "extra": .array([])])]),
                "metaItems": .array(rows), "streams": .array(streams), "metaStreams": .array([]),
                "projectionExtension": .string("new-projection-extension")])
        }
        let oldStream: VortxJSON = .object(["old": .string("episode-one-source")])
        let old = replacing(projection([row("addon-a", ready), row("addon-b", error)],
            episode: "episode-one", streams: [oldStream]), "metaStreams", .array([oldStream]))
        let newStreamPath = replacing(replacing(metaPath, "resource", .string("stream")), "id", .string("episode-two"))
        let pendingStream = row("addon-a", loading, path: newStreamPath)
        let initial = projection([row("addon-a", loading), row("addon-b", loading)],
            episode: "episode-two", streams: [pendingStream])
        func carry(_ next: VortxJSON, previous: VortxJSON? = nil, current: Bool = true) -> VortxJSON {
            VortxMetaLoadingProjection.retainingReadyMetadata(previous: previous ?? old, incoming: next, ownerIsCurrent: current)
        }
        let carried = carry(initial)
        expect(carried["metaItems"]?.array?.first?["retainedWhileLoading"] == ready, "same resource retains exact Ready JSON for display")
        expect(carried["metaItems"]?.array?.first?["content"] == loading, "raw current request remains Loading")
        expect(carried["metaItems"]?.array?.last?["content"] == loading, "old Error never retained")
        expect(carried["selected"] == initial["selected"], "new episode owns selection")
        expect(carried["streams"] == initial["streams"] && carried["metaStreams"] == initial["metaStreams"], "no old stream source survives")
        expect(carried["projectionExtension"] == initial["projectionExtension"] &&
            carried["metaItems"]?.array?.first?["rowExtension"] == .string("new-row-extension"), "incoming unknown fields preserved")
        expect(carry(initial) == carried, "session initial Loading update also carries")
        expect(carry(initial, previous: carried) == carried, "consecutive same-owner episode request keeps display without claiming readiness")
        let streamReady = replacing(pendingStream, "content", .object(["type": .string("Ready"),
            "content": .array([.object(["url": .string("https://synthetic.invalid/new-episode")])])]))
        let partial = replacing(initial, "streams", .array([streamReady]))
        expect(carry(partial)["metaItems"] == carried["metaItems"] && carry(partial)["streams"] == partial["streams"],
            "stream-first onUpdate keeps metadata while publishing only new streams")
        let fresh = replacing(ready, "content", replacing(metadata, "name", .string("Changed title")))
        let displayed = try! carried.decode(CoreMetaDetails.self)
        expect(displayed.meta?.id == "title" && displayed.meta?.videos?.first?.id == "episode-two", "actual detail model retains display metadata")
        expect(displayed.appleCWTerminalFullMeta(for: "title") == nil && displayed.metaResolution(for: "title") == .pending,
            "display metadata never certifies a current terminal response")
        let streamsFirst = try! carry(partial).decode(CoreMetaDetails.self)
        expect(streamsFirst.appleCWTerminalFullMeta(for: "title", streamID: "episode-two") == nil,
            "fresh stream response cannot promote retained display metadata to terminal")
        let freshProjection = replacing(initial, "metaItems", .array([row("addon-a", fresh), row("addon-b", error)]))
        let refreshed = try! carry(freshProjection).decode(CoreMetaDetails.self)
        expect(refreshed.meta?.name == "Changed title" && refreshed.appleCWTerminalFullMeta(for: "title")?.name == "Changed title"
            && refreshed.metaResolution(for: "title") == .ready, "fresh terminal metadata replaces display envelope and resolves")
        expect(refreshed.appleCWTerminalFullMeta(for: "title", streamID: "episode-two") == nil, "requested streams still need their own terminal response")
        for content in [error, .null, .object(["type": .string("Unknown")])] {
            let staleEnvelope = replacing(row("addon-a", content), "retainedWhileLoading", ready)
            let rejectedDisplay = try! projection([staleEnvelope], episode: "episode-two").decode(CoreMetaDetails.self)
            expect(rejectedDisplay.meta == nil, "actual non-Loading content cannot borrow display fallback")
            expect(carry(initial, previous: projection([staleEnvelope], episode: "episode-one")) == initial,
                "next request cannot revive fallback from an old terminal/missing/unknown row")
        }
        for content in [fresh, error, .null, .object(["type": .string("Unknown")])] {
            let next = replacing(initial, "metaItems", .array([row("addon-a", content)]))
            expect(carry(next) == next, "terminal/replacement/malformed metadata is authoritative")
        }
        expect(carry(initial, current: false) == initial, "changed owner cannot retain metadata")
        for boundary in ["account", "profile-generation", "registry", "profile-id", "closed", "registry-invalid"] {
            let owner = MetaProjectionOwnerFixture()
            let project = owner.capture(previous: old, profile: "profile-a")
            expect(project(initial) == carried, "actual production closure initially carries")
            owner.pendingProfileTransitions = 1
            expect(project(initial) == carried, "queued sync alone does not change acknowledged owner")
            switch boundary {
            case "account": owner.accountEpoch = UUID()
            case "profile-generation": owner.watchlistProfileGeneration = UUID()
            case "registry": owner.registryGeneration = UUID()
            case "profile-id": owner.values["native_state"] = .object(["activeProfileId": .string("profile-b")])
            case "closed": owner.closed = true
            default: owner.resourceRegistryValid = false
            }
            expect(project(initial) == initial, "actual owner closure rejects " + boundary)
        }
        let aba = MetaProjectionOwnerFixture()
        let oldOwnerProject = aba.capture(previous: old, profile: "profile-a")
        aba.watchlistProfileGeneration = UUID()
        aba.values["native_state"] = .object(["activeProfileId": .string("profile-b")])
        aba.watchlistProfileGeneration = UUID()
        aba.values["native_state"] = .object(["activeProfileId": .string("profile-a")])
        expect(oldOwnerProject(initial) == initial, "profile A-B-A cannot resurrect captured owner")
        expect(VortxMetaLoadingProjection.retainingReadyMetadata(previous: nil, incoming: initial, ownerIsCurrent: true) == initial
            && carry(.null) == .null, "nil is never globally ignored")
        let failure: VortxJSON = .object(["nativeError": .string("native_operation_failed")])
        expect(carry(failure) == failure, "enqueue failure clears retained metadata")
        expect(carry(replacing(initial, "nativeError", .string("failed"))) == replacing(initial, "nativeError", .string("failed")),
            "error projection with residual fields cannot carry")
        for path in [replacing(metaPath, "id", .string("foreign")), replacing(metaPath, "type", .string("movie")),
                     replacing(metaPath, "resource", .string("stream")),
                     replacing(metaPath, "extra", .array([.array([.string("lang"), .string("fr")])]))] {
            let next = projection([row("addon-a", loading, path: path)], episode: "episode-two", meta: path)
            expect(carry(next) == next, "full selected path must match")
            let mismatched = replacing(initial, "metaItems", .array([row("addon-a", loading, path: path)]))
            expect(carry(mismatched) == mismatched, "row path must match exact selection")
        }
        for rows in [[row("addon-removed", loading)], [], [row("", loading)]] {
            let next = replacing(initial, "metaItems", .array(rows))
            expect(carry(next) == next, "absent/replaced/empty addon base cannot carry")
        }
        for badMeta in [replacing(metadata, "id", .string("foreign")), replacing(metadata, "type", .string("movie")), .null] {
            let prior = replacing(old, "metaItems", .array([row("addon-a", replacing(ready, "content", badMeta))]))
            expect(carry(initial, previous: prior) == initial, "foreign Ready payload cannot carry")
        }
        let duplicated = replacing(old, "metaItems", .array([row("addon-a", ready), row("addon-a", ready)]))
        expect(carry(initial, previous: duplicated) == initial, "ambiguous duplicate Ready source cannot carry")
        let mixedDuplicate = replacing(old, "metaItems", .array([row("addon-a", ready), row("addon-a", error)]))
        expect(carry(initial, previous: mixedDuplicate) == initial, "duplicate resource cannot hide an error behind Ready")
        let errored = replacing(initial, "metaItems", .array([row("addon-a", error), row("addon-b", error)]))
        expect(carry(initial, previous: errored) == initial, "later request cannot resurrect cleared Ready metadata")
        let noSelection = replacing(initial, "selected", .null)
        expect(carry(noSelection) == noSelection, "unload remains empty")
        print("VortxMetaLoadingProjection PASS: same-resource transition, every partial, owner/error/foreign fences and raw JSON preservation")
    }
}
