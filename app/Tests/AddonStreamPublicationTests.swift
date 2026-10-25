import Foundation
import Combine
import os

// No app, account, Keychain, provider requests, stream start or native engine is used. The
// production resource projection and complete CoreModels decode native-shaped in-memory fixtures.
// Actual CoreBridge predicates/assembly and complete Models remain unchanged.
// Current lane: exact immutable frame owner, explicit RAM composition glue; not native pipeline admission.
// Historical lane: the predecessor Published acceptance fragment and its negative controls.
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

    static func metadataWire() -> [String: VortxJSON] {
        let path: VortxJSON = .object(["resource": .string("meta"), "type": .string("series"), "id": .string("synthetic-title")])
        let stream: VortxJSON = .object(["resource": .string("stream"), "type": .string("series"), "id": .string("synthetic-title:1:1")])
        let primary: VortxJSON = .object([
            "request": .object(["base": .string(base), "path": path]),
            "content": .object(["type": .string("Ready"), "content": .object([
                "id": .string("synthetic-title"), "type": .string("series"), "name": .string("Synthetic primary")])])])
        let secondary: VortxJSON = .object([
            "request": .object(["base": .string("https://secondary.invalid/manifest.json"), "path": path]),
            "content": .object(["type": .string("Loading")])])
        return ["selected": .object(["metaPath": path, "streamPath": stream]),
            "metaItems": .array([primary, secondary]), "streams": .array([]), "metaStreams": .array([])]
    }
    static func fields(_ value: VortxJSON) -> [String: VortxJSON] {
        guard case .object(let result) = value else { preconditionFailure("malformed synthetic fixture") }
        return result
    }
    static func replaceMetaRow(_ original: [String: VortxJSON], index: Int,
                               changes: [String: VortxJSON]) -> [String: VortxJSON] {
        var root = original, rows = root["metaItems"]!.array!
        var row = fields(rows[index])
        for (key, value) in changes { row[key] = value }
        rows[index] = .object(row); root["metaItems"] = .array(rows)
        return root
    }
    static func decoded(_ root: [String: VortxJSON]) throws -> CoreMetaDetails {
        try VortxJSON.object(root).decode(CoreMetaDetails.self)
    }
    static func libraryItemWire() -> VortxJSON {
        .object(["_id": .string("synthetic-title"), "type": .string("series"),
            "name": .string("Synthetic library"), "poster": .string("https://poster.invalid/old"),
            "removed": .bool(false), "temp": .bool(false), "previouslyWatched": .bool(false),
            "state": .object(["timeOffset": .integer(5), "duration": .integer(100),
                "video_id": .string("synthetic-title:1:1"), "lastWatched": .string("2026-10-24"),
                "flaggedWatched": .integer(0), "timesWatched": .integer(0)])])
    }
    static func libraryEventCases() throws {
        var root = metadataWire()
        root["libraryItem"] = libraryItemWire()
        root["watchedVideoIds"] = .array([.string("a"), .string("b")])
        let old = try decoded(root)
        func accepts(_ label: String, _ nextRoot: [String: VortxJSON]) throws {
            let next = try decoded(nextRoot), probe = AddonPublicationProbe()
            probe.accept(old)
            let publications = probe.metadataPublications, epoch = probe.streamsEpoch
            probe.acceptLibrary(next)
            check(probe.metadataPublications == publications + 1, "library event \(label) publishes full overlay")
            check(probe.metaDetails?.libraryItem == next.libraryItem
                  && probe.metaDetails?.watchedIds == next.watchedIds, "library event \(label) adopts exact library/watch values")
            check(probe.streamsEpoch == epoch, "library event \(label) does not rebuild sources")
            probe.acceptLibrary(next)
            check(probe.metadataPublications == publications + 1, "library event \(label) repeat quiet")
        }
        for (field, value) in [("type", VortxJSON.string("movie")), ("name", .string("Replacement name")),
                               ("poster", .string("https://poster.invalid/new")), ("removed", .bool(true)),
                               ("temp", .bool(true)), ("previouslyWatched", .bool(true))] {
            var changed = root, item = fields(root["libraryItem"]!)
            item[field] = value; changed["libraryItem"] = .object(item)
            try accepts(field, changed)
        }
        for (field, value) in [("timeOffset", VortxJSON.integer(6)), ("duration", .integer(101)),
                               ("video_id", .string("synthetic-title:1:2")), ("lastWatched", .string("2026-10-25")),
                               ("flaggedWatched", .integer(1)), ("timesWatched", .integer(1))] {
            var changed = root, item = fields(root["libraryItem"]!), state = fields(item["state"]!)
            state[field] = value; item["state"] = .object(state); changed["libraryItem"] = .object(item)
            try accepts("state \(field)", changed)
        }
        var removed = root; removed.removeValue(forKey: "libraryItem")
        try accepts("removed library row", removed)
        var watched = root; watched["watchedVideoIds"] = .array([.string("a"), .string("c")])
        try accepts("same-count watched replacement", watched)
        var empty = root; empty.removeValue(forKey: "watchedVideoIds")
        try accepts("cleared watched membership", empty)

        // Current provider/source values can advance after the worker captured an older library
        // snapshot for the same request. Only its library fields may be merged into current UI.
        var currentRoot = root
        currentRoot = replaceMetaRow(currentRoot, index: 1,
            changes: ["retainedWhileLoading": .object(["type": .string("Ready"), "content": .object([
                "id": .string("synthetic-title"), "type": .string("series"), "name": .string("Newer retained")])])])
        let sources = try details([["url": .string("https://media.invalid/newest")]])
        let current = CoreMetaDetails(selected: old.selected, metaItems: try decoded(currentRoot).metaItems,
            streams: sources.streams, metaStreams: sources.metaStreams,
            libraryItem: old.libraryItem, watchedVideoIds: old.watchedVideoIds)
        let probe = AddonPublicationProbe(); probe.accept(current)
        let epoch = probe.streamsEpoch
        probe.acceptLibrary(try decoded(watched))
        check(probe.metaDetails?.metaItems == current.metaItems && probe.metaDetails?.streams == current.streams
              && probe.metaDetails?.metaStreams == current.metaStreams && probe.metaDetails?.selected == current.selected,
              "library overlay preserves newer provider/retained/stream/selection values")
        check(probe.streamsEpoch == epoch && probe.metaDetails?.watchedIds == Set(["a", "c"]),
              "older library carrier changes watched overlay without source-epoch churn")
        let accepted = probe.metaDetails, count = probe.metadataPublications
        probe.acceptLibrary(nil)
        var unloaded = watched; unloaded.removeValue(forKey: "selected")
        probe.acceptLibrary(try decoded(unloaded))
        check(probe.metaDetails == accepted && probe.metadataPublications == count,
              "missing/null/unloaded library snapshot cannot erase detail")
        for pathKey in ["metaPath", "streamPath"] {
            for field in ["resource", "type", "id"] {
                var changed = watched, selected = fields(root["selected"]!), path = fields(selected[pathKey]!)
                path[field] = .string("replacement")
                selected[pathKey] = .object(path); changed["selected"] = .object(selected)
                probe.acceptLibrary(try decoded(changed))
                check(probe.metaDetails == accepted && probe.metadataPublications == count,
                      "library event rejects replaced \(pathKey).\(field)")
            }
        }
        var reordered = watched; reordered["watchedVideoIds"] = .array([.string("c"), .string("a"), .string("a")])
        probe.acceptLibrary(try decoded(reordered))
        check(probe.metadataPublications == count, "library watched order/duplicate-only carrier stays quiet")
        let closed = AddonPublicationProbe(); closed.acceptLibrary(old)
        check(closed.metaDetails == nil && closed.metadataPublications == 0, "library event cannot reopen closed detail")
        var noSelection = root; noSelection.removeValue(forKey: "selected")
        let idle = AddonPublicationProbe(); idle.accept(try decoded(noSelection))
        let idleCount = idle.metadataPublications
        idle.acceptLibrary(try decoded(unloaded))
        check(idle.metadataPublications == idleCount, "matching absent selection is not detail ownership")
    }

    static func errorSidecarCases() throws {
        // These exercise the extracted actual projection/getter/admission branches. Native
        // callback, account and request-generation guards remain source contracts, not RAM mocks.
        func wire(_ content: VortxJSON, id: String = "synthetic-title:1:1",
                  provider: String = "https://provider.invalid/synthetic-config/manifest.json") -> [String: VortxJSON] {
            var root = metadataWire()
            root["streams"] = .array([.object([
                "request": .object(["base": .string(provider), "path": .object([
                    "resource": .string("stream"), "type": .string("series"), "id": .string(id)])]),
                "content": content])])
            return root
        }
        func err(_ code: String, _ status: VortxJSON? = nil) -> VortxJSON {
            var payload: [String: VortxJSON] = ["code": .string(code)]
            payload["status"] = status
            return .object(["type": .string("Err"), "content": .object(payload)])
        }
        let probe = AddonPublicationProbe()
        probe.names = [base: "Synthetic A"]
        func accept(_ root: [String: VortxJSON]) throws {
            try probe.acceptData(JSONEncoder().encode(VortxJSON.object(root)))
        }
        let timeout = wire(err("timeout")), rateLimited = wire(err("http", .integer(429)))
        check(try decoded(timeout) == decoded(rateLimited), "error payload-only wire change is typed-equivalent")
        try accept(timeout)
        check(probe.streamAddonStates().first?.error == "Add-on request timed out. Try again.", "accepted timeout is visible")
        let publications = probe.metadataPublications, epoch = probe.streamsEpoch
        let statusCount = probe.statusPublications, indexerStarts = probe.indexerStarts
        try accept(rateLimited)
        check(probe.streamAddonStates().first?.error == "Add-on rate limited (HTTP 429). Try again later.", "HTTP 429 replaces cached timeout")
        check(probe.statusPublications == statusCount + 1, "error-only change publishes one status value")
        check(probe.metadataPublications == publications && probe.streamsEpoch == epoch && probe.indexerStarts == indexerStarts,
              "error-only change leaves typed metadata, sources and indexer untouched")
        try accept(rateLimited)
        check(probe.statusPublications == statusCount + 1, "identical status receipt stays quiet")
        try accept(wire(err("http", .integer(503))))
        check(probe.streamAddonStates().first?.error == "Add-on returned HTTP 503.", "HTTP status-only transition updates presentation")
        try accept(wire(err("empty_resource")))
        check(probe.streamAddonStates().first?.error == nil && probe.streamAddonStates().first?.loading == false,
              "empty-resource error clears prior failure without looking pending")
        check(probe.metadataPublications == publications && probe.streamsEpoch == epoch,
              "error-to-empty message change is not a source rebuild")
        try accept(wire(err("unknown-one")))
        let unknownCount = probe.statusPublications
        var unknown = wire(err("unknown-two")); unknown["unused"] = .string("ignored")
        try accept(unknown)
        check(probe.statusPublications == unknownCount && probe.streamAddonStates().first?.error == "Add-on request could not be completed. Try again.",
              "equivalent normalized unknown errors and unknown fields stay quiet")
        try accept(wire(err("http")))
        let invalidStatusCount = probe.statusPublications
        for invalid in [VortxJSON.bool(true), .number(429.5), .integer(99), .integer(600)] {
            try accept(wire(err("http", invalid)))
            check(probe.statusPublications == invalidStatusCount && probe.streamAddonStates().first?.error == "Add-on returned an HTTP error.",
                  "invalid HTTP status cannot become an HTTP code")
        }
        try accept(wire(.object(["type": .string("Err"), "content": .string("Synthetic legacy error")])))
        check(probe.streamAddonStates().first?.error == "Synthetic legacy error", "legacy bare error rendering is retained")
        try accept(wire(.object(["type": .string("Err"), "content": .object([
            "type": .string("Env"), "content": .object(["type": .string("Fetch"), "content": .string("synthetic failure")])])])))
        check(probe.streamAddonStates().first?.error == "Env: Fetch: synthetic failure", "legacy tagged error rendering is retained")
        try accept(wire(.object(["type": .string("Err"), "content": .object(["type": .string("EmptyContent")])])))
        check(probe.streamAddonStates().first?.error == nil, "legacy EmptyContent remains non-error")

        try accept(wire(.object(["type": .string("UnknownState")])))
        check(probe.streamAddonStates().first?.loading == true, "unknown raw state keeps existing pending presentation")
        try accept(wire(.object(["type": .string("Ready"), "content": .array([.object(["url": .integer(42)])]) ])))
        check(probe.streamAddonStates().first?.error == "Unreadable add-on response" && probe.streamAddonStates().first?.loading == false,
              "malformed Ready is terminal rather than a false successful empty result")
        try accept(wire(.object(["type": .string("Ready"), "content": .array([])])))
        check(probe.streamAddonStates().first?.ready == 0 && probe.streamAddonStates().first?.error == nil,
              "valid empty Ready is not an error")
        let ready: VortxJSON = .object(["type": .string("Ready"), "content": .array([.object([
            "url": .string("https://media.invalid/status"), "behaviorHints": .object(["videoSize": .integer(42)])])])])
        try accept(wire(ready))
        check(probe.streamAddonStates().first?.ready == 1, "Ready count comes from the same-buffer typed row")
        let readyCount = probe.statusPublications, readyEpoch = probe.streamsEpoch
        let stringReady: VortxJSON = .object(["type": .string("Ready"), "content": .array([.object([
            "url": .string("https://media.invalid/status"), "behaviorHints": .object(["videoSize": .string("42")])])])])
        try accept(wire(stringReady))
        check(probe.statusPublications == readyCount && probe.streamsEpoch == readyEpoch,
              "decoder-equivalent stream values do not churn the sidecar")
        probe.names = [base: "Renamed A"]
        check(probe.streamAddonStates().first?.name == "Renamed A" && probe.statusPublications == readyCount,
              "current add-on names are not trapped in an epoch cache")

        var multiple = timeout
        let other = wire(err("network"), id: "synthetic-title:1:2", provider: "https://second.invalid/manifest.json")
        let rows = timeout["streams"]!.array! + other["streams"]!.array!
        multiple["streams"] = .array(rows)
        try accept(multiple)
        check(probe.streamAddonStates().map(\.base) == [base, "https://second.invalid/manifest.json"], "status rows preserve provider order")
        check(probe.streamAddonStates(forStreamId: "synthetic-title:1:1").count == 1
              && probe.streamAddonStates(forStreamId: "synthetic-title:1:2").first?.base == "https://second.invalid/manifest.json"
              && probe.streamAddonStates(forStreamId: "synthetic-title:1:3").isEmpty, "status filtering uses the exact row episode ID")
        multiple["streams"] = .array(Array(rows.reversed()))
        try accept(multiple)
        check(probe.streamAddonStates().first?.base == "https://second.invalid/manifest.json", "provider reorder replaces ordered status projection")
        var embeddedOnly = multiple
        embeddedOnly["metaStreams"] = embeddedOnly["streams"]; embeddedOnly["streams"] = .array([])
        try accept(embeddedOnly)
        check(probe.streamAddonStates().isEmpty, "status scope remains stream-resource rows, not embedded sources")
        for field in ["base", "resource", "type", "id"] {
            try accept(timeout)
            let previous = probe.statusPublications
            var changed = timeout, row = fields(timeout["streams"]!.array!.first!), request = fields(row["request"]!)
            if field == "base" { request[field] = .string("replacement") }
            else {
                var requestPath = fields(request["path"]!); requestPath[field] = .string("replacement")
                request["path"] = .object(requestPath)
            }
            row["request"] = .object(request); changed["streams"] = .array([.object(row)])
            try accept(changed)
            check(probe.statusPublications == previous + 1, "status projection retains exact request \(field)")
        }

        try accept(timeout)
        let beforeFailure = probe.streamAddonStates(), beforeFailureCount = probe.statusPublications
        do {
            try probe.acceptData(Data("{".utf8))
            check(false, "invalid receipt must throw before admission")
        } catch {
            check(probe.streamAddonStates() == beforeFailure && probe.statusPublications == beforeFailureCount,
                  "failed decode preserves the admitted metadata/status pair")
        }
        var routeB = timeout, selected = fields(timeout["selected"]!), path = fields(selected["metaPath"]!)
        path["id"] = .string("replacement-title"); selected["metaPath"] = .object(path); routeB["selected"] = .object(selected)
        probe.accept(try decoded(routeB))
        check(probe.streamAddonStates().isEmpty, "accepted A sidecar is not paired with different current route B")
        probe.accept(nil)
        probe.accept(try decoded(timeout))
        check(probe.streamAddonStates().isEmpty, "explicit nil clear retires old sidecar before same-route reopen")
        try accept(timeout)
        check(probe.streamAddonStates().first?.error == "Add-on request timed out. Try again.", "fresh same-route receipt installs its own status")
        try probe.acceptData(Data("null".utf8))
        check(probe.metaDetails == nil && probe.streamAddonStates().isEmpty, "valid null unload clears metadata and sidecar")
        let unloadedCount = probe.statusPublications
        try probe.acceptData(Data("null".utf8))
        check(probe.statusPublications == unloadedCount, "repeated unloaded receipt stays quiet")
    }

    static func errorSidecarReentryCases() throws {
        // A real ObservableObject uses exact current guarded frame (or historical Published
        // declarations). Every reentry is a one-shot synchronous Combine callback, never a queue hop.
        func bytes(_ code: String, status: Int64? = nil, name: String? = nil) throws -> Data {
            var root = metadataWire()
            var failure: [String: VortxJSON] = ["code": .string(code)]
            if let status { failure["status"] = .integer(status) }
            root["streams"] = .array([.object([
                "request": .object(["base": .string(base), "path": .object([
                    "resource": .string("stream"), "type": .string("series"), "id": .string("synthetic-title:1:1")])]),
                "content": .object(["type": .string("Err"), "content": .object(failure)])])])
            if let name {
                var rows = root["metaItems"]!.array!, row = fields(rows[0]), content = fields(row["content"]!)
                var meta = fields(content["content"]!); meta["name"] = .string(name)
                content["content"] = .object(meta); row["content"] = .object(content); rows[0] = .object(row)
                root["metaItems"] = .array(rows)
            }
            return try JSONEncoder().encode(VortxJSON.object(root))
        }
        let old = try bytes("timeout"), rateLimited = try bytes("http", status: 429)
        let newer = try bytes("http", status: 503)
        let oldDetails = try JSONDecoder().decode(CoreMetaDetails.self, from: old)
        let rateMessage = "Add-on rate limited (HTTP 429). Try again later."
        let newerMessage = "Add-on returned HTTP 503."
        do {
            let probe = AddonPublicationProbe(); try probe.acceptData(old)
            let publications = probe.metadataPublications, epoch = probe.streamsEpoch
            var wakes = 0
            let subscription = probe.objectWillChange.sink { _ in wakes += 1 }
            try probe.acceptData(rateLimited)
            subscription.cancel()
            check(wakes == 1 && probe.streamAddonStates().first?.error == rateMessage,
                  "real Combine status signal wakes once for typed-equivalent timeout to HTTP 429")
            check(probe.metadataPublications == publications && probe.streamsEpoch == epoch,
                  "real status-only observable wake does not republish typed err or rebuild sources")
        }
        do {
            let probe = AddonPublicationProbe(); try probe.acceptData(old)
            var fired = false
            let subscription = probe.objectWillChange.sink { _ in
                guard !fired else { return }; fired = true
                probe.accept(nil)
                probe.accept(oldDetails)
            }
            try probe.acceptData(rateLimited)
            subscription.cancel()
            check(fired && probe.metaDetails?.selected == oldDetails.selected && probe.streamAddonStates().isEmpty,
                  "status willSet nil-clear and synchronous same-route reopen cannot revive retired payload")
            try probe.acceptData(newer)
            check(probe.streamAddonStates().first?.error == newerMessage, "fresh receipt after reentrant clear installs its own status")
        }
        do {
            let probe = AddonPublicationProbe(); try probe.acceptData(old)
            var fired = false
            let subscription = probe.objectWillChange.sink { _ in
                guard !fired else { return }; fired = true
                probe.accept(nil)
            }
            try probe.acceptData(rateLimited)
            subscription.cancel()
            probe.accept(oldDetails)
            check(fired && probe.streamAddonStates().isEmpty, "status willSet clear also stays retired on a later same-route reopen")
        }
        do {
            let probe = AddonPublicationProbe(); try probe.acceptData(old)
            var fired = false, nestedFailed = false
            let subscription = probe.objectWillChange.sink { _ in
                guard !fired else { return }; fired = true
                do { try probe.acceptData(newer) } catch { nestedFailed = true }
            }
            try probe.acceptData(rateLimited)
            subscription.cancel()
            check(fired && !nestedFailed && probe.streamAddonStates().first?.error == newerMessage,
                  "nested newer nonnil status admission wins over outer status willSet")
        }
        do {
            let probe = AddonPublicationProbe()
            probe.accept(oldDetails) // Metadata exists, but no status payload has ever been stored.
            var fired = false
            let subscription = probe.objectWillChange.sink { _ in
                guard !fired else { return }; fired = true
                probe.accept(nil); probe.accept(oldDetails)
            }
            try probe.acceptData(rateLimited)
            subscription.cancel()
            check(fired && probe.streamAddonStates().isEmpty,
                  "nil clear retires an in-flight first status even when the prior payload was nil")
            try probe.acceptData(newer)
            check(probe.streamAddonStates().first?.error == newerMessage,
                  "a fresh status can commit after the first in-flight publication was retired")
        }
        do {
            let probe = AddonPublicationProbe(); try probe.acceptData(old)
            var fired = false, nestedFailed = false
            let subscription = probe.objectWillChange.sink { _ in
                guard !fired else { return }; fired = true
                do { try probe.acceptData(newer) } catch { nestedFailed = true }
            }
            try probe.acceptData(bytes("http", status: 429, name: "Outer metadata carrier"))
            subscription.cancel()
            check(fired && !nestedFailed && probe.streamAddonStates().first?.error == newerMessage,
                  "original admission token spans typed metadata willSet as well as the status signal")
            // This intentionally says nothing about the outer typed setter's own writeback; that
            // broader receipt/actor join is separate. Only the status payload commit is fenced here.
        }
#if !VORTX_GUARDED_METADATA_PRESENTATION
        do {
            let probe = AddonPublicationProbe(); try probe.acceptData(old)
            var fired = false
            let subscription = probe.objectWillChange.sink { _ in
                guard !fired else { return }; fired = true
                probe.accept(nil); probe.accept(oldDetails)
            }
            try probe.acceptDataWithoutPostFence(rateLimited)
            subscription.cancel()
            check(fired && probe.streamAddonStates().first?.error == rateMessage,
                  "negative control: removing only post-signal original fence reproduces same-route resurrection")
        }
        do {
            let probe = AddonPublicationProbe(); try probe.acceptData(old)
            var fired = false, nestedFailed = false
            let subscription = probe.objectWillChange.sink { _ in
                guard !fired else { return }; fired = true
                do { try probe.acceptData(newer) } catch { nestedFailed = true }
            }
            try probe.acceptDataWithoutPostFence(rateLimited)
            subscription.cancel()
            check(fired && !nestedFailed && probe.streamAddonStates().first?.error == rateMessage,
                  "negative control: missing post-signal fence overwrites newer nested status")
        }
#endif
    }

    static func metadataValueTransferCases() async throws {
        // This exercises the immutable decoded graph that moves from a worker callback to the
        // actor-owned publication branch. The detached task receives production values, not
        // fixture mirrors, and mutates only local copy-on-write carriers.
        let metadata = try details([original], embedded: true)
        var libraryRoot = metadataWire()
        libraryRoot["libraryItem"] = libraryItemWire()
        let withLibrary = try decoded(libraryRoot)
        let originalEntryCount = metadata.metaItems.count
        let originalWatched = withLibrary.watchedVideoIds
        let transferred = await Task.detached(priority: nil) {
            var entries = metadata.metaItems
            entries.removeLast()
            var library = withLibrary.libraryItem
            library?.removed = true
            var watched = withLibrary.watchedVideoIds ?? []
            watched.append("worker-watch")
            let changed = CoreMetaDetails(
                selected: metadata.selected,
                metaItems: entries,
                streams: metadata.streams,
                metaStreams: metadata.metaStreams,
                libraryItem: library,
                watchedVideoIds: watched)
            return (changed, library, CoreLoadable<[CoreMeta]>.ready([]))
        }.value
        let loadableReadyAndEmpty: Bool
        switch transferred.2 {
        case .ready(let values): loadableReadyAndEmpty = values.isEmpty
        case .loading, .err: loadableReadyAndEmpty = false
        }
        check(metadata.metaItems.count == originalEntryCount
              && withLibrary.libraryItem?.removed == false
              && withLibrary.watchedVideoIds == originalWatched,
              "decoded metadata and library values stay unchanged after detached worker copy")
        check(transferred.0.metaItems.count == originalEntryCount - 1
              && transferred.0.libraryItem?.removed == true
              && transferred.0.watchedIds == Set(["worker-watch"])
              && loadableReadyAndEmpty,
              "decoded metadata graph and conditional loadable transfer as Sendable values")
    }

    static func metadataReplacement(_ label: String, old: CoreMetaDetails,
                                    next: CoreMetaDetails, sourceChange: Bool = false) {
        let probe = AddonPublicationProbe(); probe.accept(old)
        let epoch = probe.streamsEpoch, publications = probe.metadataPublications
        check(probe.needs(next), "\(label) whole decoded value republishes")
        check(probe.streamsChange(next) == sourceChange, "\(label) independent source-epoch policy")
        probe.accept(next)
        check(probe.metadataPublications == publications + 1, "\(label) actual accepted branch stores once")
        check(probe.streamsEpoch == epoch + (sourceChange ? 1 : 0), "\(label) actual source epoch")
        probe.accept(next)
        check(probe.metadataPublications == publications + 1, "\(label) identical repeat remains quiet")
    }
    static func metadataValueCases() throws {
        let root = metadataWire(), old = try decoded(root)
        check(Set(Mirror(reflecting: old).children.compactMap { $0.label })
            == Set(["selected", "metaItems", "streams", "metaStreams", "libraryItem", "watchedVideoIds"]),
            "metadata equality schema covers all six stored fields; new fields require gate review")
        let terminal = replaceMetaRow(root, index: 1,
            changes: ["content": .object(["type": .string("Err"), "content": .object(["code": .string("timeout")])])])
        metadataReplacement("nonwinning provider Loading to Err", old: old, next: try decoded(terminal))
        let ready = replaceMetaRow(root, index: 1,
            changes: ["content": .object(["type": .string("Ready"), "content": .object([
                "id": .string("synthetic-title"), "type": .string("series"), "name": .string("Synthetic secondary")])])])
        metadataReplacement("nonwinning provider Ready", old: old, next: try decoded(ready))
        let row = root["metaItems"]!.array![1]
        var request = fields(row["request"]!); request["base"] = .string("https://replacement.invalid/manifest.json")
        metadataReplacement("nonwinning provider request", old: old,
            next: try decoded(replaceMetaRow(root, index: 1, changes: ["request": .object(request)])))
        let retainedA: VortxJSON = .object(["type": .string("Ready"), "content": .object([
            "id": .string("synthetic-title"), "type": .string("series"), "name": .string("Retained A")])])
        let retainedB: VortxJSON = .object(["type": .string("Ready"), "content": .object([
            "id": .string("synthetic-title"), "type": .string("series"), "name": .string("Retained B")])])
        let prior = try decoded(replaceMetaRow(root, index: 1, changes: ["retainedWhileLoading": retainedA]))
        let next = try decoded(replaceMetaRow(root, index: 1, changes: ["retainedWhileLoading": retainedB]))
        metadataReplacement("nonwinning retained metadata", old: prior, next: next)
        var ordered = root
        ordered["metaItems"] = .array(Array(root["metaItems"]!.array!.reversed()))
        metadataReplacement("provider row order", old: old, next: try decoded(ordered))

        // Full selected route identity must change the source epoch even before
        // any group request exists to expose a type/resource/episode mismatch.
        for pathKey in ["metaPath", "streamPath"] {
            for field in ["resource", "type", "id"] {
                var changed = root, selected = fields(root["selected"]!)
                var path = fields(selected[pathKey]!)
                path[field] = .string("synthetic-replacement")
                selected[pathKey] = .object(path); changed["selected"] = .object(selected)
                metadataReplacement("selected \(pathKey).\(field) empty groups", old: old,
                    next: try decoded(changed), sourceChange: true)
            }
        }
        var library = root
        library["libraryItem"] = libraryItemWire()
        let libraryOld = try decoded(library)
        for (field, value) in [("type", VortxJSON.string("movie")), ("name", .string("Replacement name")),
                               ("poster", .string("https://poster.invalid/new")), ("removed", .bool(true)),
                               ("temp", .bool(true)), ("previouslyWatched", .bool(true))] {
            var changed = library, item = fields(library["libraryItem"]!)
            item[field] = value; changed["libraryItem"] = .object(item)
            metadataReplacement("library \(field)", old: libraryOld, next: try decoded(changed))
        }
        for (field, value) in [("timeOffset", VortxJSON.integer(6)), ("duration", .integer(101)),
                               ("video_id", .string("synthetic-title:1:2")), ("lastWatched", .string("2026-10-25")),
                               ("flaggedWatched", .integer(1)), ("timesWatched", .integer(1))] {
            var changed = library, item = fields(library["libraryItem"]!), state = fields(item["state"]!)
            state[field] = value; item["state"] = .object(state); changed["libraryItem"] = .object(item)
            metadataReplacement("library state \(field)", old: libraryOld, next: try decoded(changed))
        }
        var watched = root, reordered = root, changedWatched = root
        watched["watchedVideoIds"] = .array([.string("a"), .string("b")])
        reordered["watchedVideoIds"] = .array([.string("b"), .string("a"), .string("a")])
        changedWatched["watchedVideoIds"] = .array([.string("a"), .string("c")])
        let watchedOld = try decoded(watched), membershipProbe = AddonPublicationProbe()
        membershipProbe.accept(watchedOld); let membershipCount = membershipProbe.metadataPublications
        membershipProbe.accept(try decoded(reordered))
        check(membershipProbe.metadataPublications == membershipCount, "watched order and duplicate equivalence stays quiet")
        metadataReplacement("same-count watched membership", old: watchedOld, next: try decoded(changedWatched))
        var empty = root; empty["watchedVideoIds"] = .array([]); empty.removeValue(forKey: "metaStreams")
        check(old == (try decoded(empty)), "nil/empty watched and effective embedded-stream equivalence")

        // No raw-to-Double canonicalization, serialization cache, or unknown-field
        // rebuild is added by the production change. Native raw evidence stays raw.
        let extensionValue: VortxJSON = .object(["sequence": .unsigned(UInt64.max),
            "nested": .array([.null, .bool(true), .string("opaque-synthetic")])])
        var unknown = root; unknown["providerFuture"] = extensionValue
        let retainedRaw = VortxJSON.object(unknown), decodedUnknown = try retainedRaw.decode(CoreMetaDetails.self)
        check(retainedRaw["providerFuture"] == extensionValue, "raw unknown UInt64-max extension retained independently")
        check(old == decodedUnknown, "unknown-only raw change remains truly decoded-equivalent")
        let exact = Int64(9_007_199_254_740_993)
        let numeric = try details([["url": .string("https://media.invalid/precise"),
            "behaviorHints": .object(["videoSize": .integer(exact)])]])
        let string = try details([["url": .string("https://media.invalid/precise"),
            "behaviorHints": .object(["videoSize": .string(String(exact))])]])
        let adjacent = try details([["url": .string("https://media.invalid/precise"),
            "behaviorHints": .object(["videoSize": .integer(exact + 1)])]])
        check(numeric.allStreamGroups.first?.content?.ready?.first?.behaviorHints?.videoSize == exact,
            "decoded Int64 byte count above Double-exact range preserves precision")
        check(numeric == string, "exact numeric/string byte count remains decoded-equivalent")
        metadataReplacement("adjacent large Int64 byte count", old: numeric, next: adjacent, sourceChange: true)
    }

    static func finiteLargeValueCases() throws {
        let values: [[String: VortxJSON]] = (0..<3_000).map { index in
            ["url": .string("https://media.invalid/finite/\(index)"), "name": .string("Synthetic \(index)")]
        }
        let first = try details(values), equal = try details(values)
        var replacement = values; replacement[2_999]["url"] = .string("https://media.invalid/finite/tail-new")
        let tail = try details(replacement), probe = AddonPublicationProbe()
        probe.accept(first); let count = probe.metadataPublications, epoch = probe.streamsEpoch
        probe.accept(equal)
        check(probe.metadataPublications == count && probe.streamsEpoch == epoch, "3000-row functional equal receipt is quiet")
        probe.accept(tail)
        check(probe.metadataPublications == count + 1 && probe.streamsEpoch == epoch + 1,
            "3000-row functional tail replacement publishes once")
        check(probe.groups().first?.streams.count == 3_000, "3000-row functional projection retains all rows")
    }

    static func dateParserCases() {
        // Legacy instances stay local to the oracle; worker checks use only actual Sendable parsers.
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let inputs = ["2026-10-24T12:34:56Z", "2026-10-24T12:34:56.123Z",
            "2026-10-24T12:34:56.123456Z", "2026-10-24T12:34:56.123456789Z",
            "2026-10-24T12:34:56+05:30", "2026-10-24T12:34:56+0530",
            "2026-10-24T12:34:56-04:00", "2026-10-24T12:34:56.999+05:30",
            "", "not-a-date", "2026", "2026-10-24", "2026-99-24T12:34:56Z",
            "2026-10-24T99:00:00Z", "2026-10-24T12:34:56Z trailing"]
        let expected = inputs.map { raw in
            (plain.date(from: raw) ?? fractional.date(from: raw))?.timeIntervalSince1970
        }
        for (index, raw) in inputs.enumerated() {
            let date = (ISO8601DateFormatter.epg.date(from: raw)
                ?? ISO8601DateFormatter.epgFractional.date(from: raw))?.timeIntervalSince1970
            let reverse = (ISO8601DateFormatter.epgFractional.date(from: raw)
                ?? ISO8601DateFormatter.epg.date(from: raw))?.timeIntervalSince1970
            let same = date == expected[index]
            check(same && date == reverse, "ISO parser legacy date/acceptance parity case \(index)")
        }
        let failures = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            var missed = 0
            for (index, raw) in inputs.enumerated() {
                let date = (ISO8601DateFormatter.epg.date(from: raw)
                    ?? ISO8601DateFormatter.epgFractional.date(from: raw))?.timeIntervalSince1970
                let same = date == expected[index]
                if !same { missed += 1 }
            }
            failures.withLock { [missed] in $0 += missed }
        }
        check(failures.withLock { $0 } == 0, "shared actual ISO parser values support bounded worker reads")
    }

    static func finiteResumeTimecodeCases() {
        for value in [-1.0, 0, 0.99, Double.nan, .infinity, -.infinity,
                      Double(Int.max), Double.greatestFiniteMagnitude] {
            check(resumeTimecode(value) == nil, "nonpositive/nonfinite/out-of-Int duration rejected")
        }
        for (value, expected) in [(1.0, "0:01"), (59.99, "0:59"), (60, "1:00"),
                                  (3_600, "1:00:00"), (7_730_941_132_800, "2147483648:00:00")] {
            check(resumeTimecode(value) == expected, "resume timecode finite formatting \(expected)")
        }
        check(resumeTimecode(Double(Int.max).nextDown) != nil, "largest representable Double below Int bound formats safely")
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
        print(String(format: "TIMING actual predicates/value acceptance streams=%d iterations=%d optimization=none equal_total_ms=%.3f equal_mean_ms=%.3f tail_total_ms=%.3f tail_mean_ms=%.3f",
            count, iterations, Double(equalElapsed) / 1_000_000, Double(equalElapsed) / Double(iterations) / 1_000_000,
            Double(tailElapsed) / 1_000_000, Double(tailElapsed) / Double(iterations) / 1_000_000))
    }

    static func sourceOriginChecks() throws {
        let a = "https://provider.invalid/config/manifest.json?quality=4k&account=A"
        let b = "https://provider.invalid/config/manifest.json?quality=4k&account=B"
        let row: [String: Any] = ["url": "https://media.invalid/shared", "name": "same release",
            "behaviorHints": ["proxyHeaders": ["request": ["X-Synthetic": "same"]]]]
        let selected = try JSONDecoder().decode(CoreStream.self, from: JSONSerialization.data(withJSONObject: row))
        let groups = [CoreStreamSourceGroup(id: a, addon: "4k", streams: [selected]),
                      CoreStreamSourceGroup(id: b, addon: "4k", streams: [selected])]
        let clicked = SourceOrigin(id: b, addon: "4k")
        check(SourceOrigin.current(for: selected, clicked: clicked, groups: groups) == clicked,
              "two identical full stream records retain the explicitly clicked second configuration")
        check(clicked.engineBase == b, "source origin preserves complete configured path and query")
        check(SourceOrigin.current(for: selected, clicked: nil, groups: groups) == nil,
              "legacy inference refuses identical records across different configured instances")
        check(SourceOrigin.current(for: selected, clicked: nil, groups: [groups[1]]) == clicked,
              "legacy inference is allowed for a unique complete-record group")
        check(SourceOrigin.current(for: selected, clicked: .init(id: a + "-missing", addon: "4k"), groups: groups) == nil,
              "an explicit missing configured identity cannot fall back by label")
        check(SourceOrigin.current(for: selected, clicked: .init(id: b, addon: "different"), groups: groups) == nil,
              "a stale mismatching label cannot become current source-origin proof")
        check(SourceOrigin.current(for: selected, clicked: clicked, groups: [groups[1], groups[1]]) == nil,
              "duplicate configured group IDs fail closed")
        let synthetic = SourceOrigin(id: "vortx.singularity.sources", addon: "Singularity")
        check(SourceOrigin.current(for: selected, clicked: synthetic,
            groups: [.init(id: synthetic.id, addon: synthetic.addon, streams: [selected])]) == synthetic
              && synthetic.engineBase == nil, "valid synthetic origins remain distinct from missing/invalid origins")
        var differentHeaders = row
        differentHeaders["behaviorHints"] = ["proxyHeaders": ["request": ["X-Synthetic": "other"]]]
        let other = try JSONDecoder().decode(CoreStream.self, from: JSONSerialization.data(withJSONObject: differentHeaders))
        check(SourceOrigin.current(for: selected, clicked: clicked,
            groups: [.init(id: b, addon: "4k", streams: [other])]) == nil,
              "matching URL alone cannot satisfy full selected-record attribution")
        func group(_ base: String, _ rows: [[String: Any]]) -> [String: Any] {
            ["request": ["base": base, "path": ["resource": "stream", "type": "movie", "id": "synthetic-title"]],
             "content": ["type": "Ready", "content": rows]]
        }
        let meta: [String: Any] = ["request": ["base": a,
            "path": ["resource": "meta", "type": "movie", "id": "synthetic-title"]],
            "content": ["type": "Ready", "content": ["id": "synthetic-title", "type": "movie", "name": "Synthetic"]]]
        let object: [String: Any] = ["metaItems": [meta], "streams": [group(a, [row]), group(b, [row])]]
        let probe = try SourceOriginBindingProbe(object)
        check(probe.loadEnginePlayer(for: selected, sourceGroupID: b),
              "the actual production movie attribution method dispatches the clicked second instance")
        let action = probe.dispatched.last?["args"] as? [String: Any]
        let selection = action?["args"] as? [String: Any]
        let request = selection?["streamRequest"] as? [String: Any]
        check(request?["base"] as? String == b, "the dispatched source request binds B rather than first-equal A")
        let missing = try SourceOriginBindingProbe(object)
        check(!missing.loadEnginePlayer(for: selected, sourceGroupID: b + "-missing") && missing.dispatched.isEmpty,
              "missing explicit movie origin does not dispatch or borrow another ready instance")
        let mismatch = try SourceOriginBindingProbe(["metaItems": [meta],
            "streams": [group(a, [row]), group(b, [differentHeaders])]])
        check(!mismatch.loadEnginePlayer(for: selected, sourceGroupID: b) && mismatch.dispatched.isEmpty,
              "full-record mismatch at clicked B never falls back to matching A")
        let embedded = try SourceOriginBindingProbe(["metaItems": [meta], "metaStreams": [group(b, [row])],
            "streams": [group(a, [row])]])
        check(embedded.loadEnginePlayer(for: selected, sourceGroupID: b),
              "an explicitly clicked meta-embedded source retains its actual instance attribution")
        let local = try SourceOriginBindingProbe(object)
        check(!local.loadEnginePlayer(for: selected, sourceGroupID: synthetic.id) && local.dispatched.isEmpty,
              "a valid synthetic selection cannot masquerade as another ready network add-on")
    }

    static func main() async throws {
        try sourceOriginChecks()
        let statusProbe = AddonPublicationProbe()
        let currentRequest: [String: Any] = ["base": base,
            "path": ["resource": "stream", "type": "series", "id": "synthetic-title:1:2"]]
        let goodGroup: [String: Any] = ["request": currentRequest,
            "content": ["type": "Ready", "content": [["url": "https://media.invalid/current"]]]]
        check(statusProbe.readyCount(goodGroup) == 1, "current typed stream response has the exact ready count")
        let badGroup: [String: Any] = ["request": currentRequest,
            "content": ["type": "Ready", "content": [["url": 42]]]]
        check(statusProbe.readyCount(badGroup) == nil, "unreadable Ready stream is terminal rather than falsely reported ready")
        let missingGroup: [String: Any] = ["request": currentRequest, "content": ["type": "Ready"]]
        check(statusProbe.readyCount(missingGroup) == nil, "missing Ready stream payload is not reported as a successful empty response")
        let emptyGroup: [String: Any] = ["request": currentRequest, "content": ["type": "Ready", "content": []]]
        check(statusProbe.readyCount(emptyGroup) == 0, "valid successful empty response remains non-error")
        check(statusProbe.readyCount(["request": ["base": base], "content": ["type": "Ready", "content": []]]) == nil,
              "malformed current request remains failed rather than borrowing a previous episode")
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
        try metadataValueCases()
        try libraryEventCases()
        try errorSidecarCases()
        try errorSidecarReentryCases()
#if VORTX_GUARDED_METADATA_PRESENTATION
        try AddonPublicationProbe.runGuardedMetadataCases(old: old, next: changedMetadata, check: check)
#endif
        try await metadataValueTransferCases()
        try finiteLargeValueCases()
        finiteResumeTimecodeCases()
        dateParserCases()
        if ProcessInfo.processInfo.environment["VORTX_ADDON_PUBLICATION_BENCHMARK"] == "1" {
            try timing()
        } else {
            print("SKIP timing benchmark (explicit --benchmark opt-in); finite 3000-row correctness covered")
        }
        print("\(checks) checks, \(failures) failures; synthetic values only; provider health unproven")
        if failures != 0 { exit(1) }
    }
}
