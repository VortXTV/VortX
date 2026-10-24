import Foundation

/// Native resource results projected into the existing CoreModels/EngineState read wire. This is
/// host presentation state only; no Stremio runtime is involved. Account/library state is deliberately
/// supplied by its separate owner, rather than invented by catalog or metadata requests.
enum VortxResourceProjection {
    private static func validate(_ snapshot: VortxResourceSnapshot, registry: [VortxResourceAddon]) throws {
        guard Set(registry.map(\.id)).count == registry.count,
              snapshot.groups.allSatisfy({ group in
                  registry.first(where: { $0.id == group.addonId })?.transportUrl == snapshot.sourceURLs[group.addonId]
              }) else { throw VortxNativeError.invalidResponse }
    }
    static func entry(_ group: VortxResourceGroup, request: VortxResourceRequest,
                      registry: [VortxResourceAddon]) throws -> VortxJSON {
        guard let addon = registry.first(where: { $0.id == group.addonId }) else { throw VortxNativeError.invalidResponse }
        let payload: VortxJSON
        if group.status == .ready {
            let items = try group.items(for: request.resource)
            if request.resource == .meta, items.isEmpty {
                payload = .object(["type": .string("Err"), "content": .object(["code": .string("empty_resource")])])
            } else {
                let value = request.resource == .meta || request.resource == .manifest ? items.first ?? .null : .array(items)
                payload = .object(["type": .string("Ready"), "content": value])
            }
        } else {
            let failure = group.error ?? .init(code: group.status.rawValue)
            var receipt: [String: VortxJSON] = ["code": .string(failure.code)]
            if let status = failure.status { receipt["status"] = .integer(Int64(status)) }
            payload = .object(["type": .string("Err"), "content": .object(receipt)])
        }
        return .object(["request": .object(["base": .string(addon.transportUrl), "path": try path(request)]), "content": payload])
    }

    static func path(_ request: VortxResourceRequest) throws -> VortxJSON {
        try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(request))
    }

    /// Pages append within the exact addon/type/catalog identity; the caller supplies accepted,
    /// ordered page snapshots. Different account owners can never be combined into one board.
    static func board(pages: [VortxResourceSnapshot], registry: [VortxResourceAddon]) throws -> VortxJSON {
        var rows: [[VortxJSON]] = []
        var keys: [[String]] = []
        var seenPages = Set<String>()
        for page in pages {
            try validate(page, registry: registry)
            guard page.request.resource == .catalog, page.ownerID == pages.first?.ownerID else { throw VortxNativeError.invalidResponse }
            for group in page.groups {
                let key = [group.addonId, page.request.type, page.request.id]
                // Exact page identity includes all extras (search/genre/skip), not just the title ID.
                let pageKey = String(decoding: try JSONEncoder().encode(key + [String(decoding: JSONEncoder().encode(page.request.extra), as: UTF8.self)]), as: UTF8.self)
                guard seenPages.insert(pageKey).inserted else { throw VortxNativeError.invalidResponse }
                let value = try entry(group, request: page.request, registry: registry)
                if let index = keys.firstIndex(of: key) { rows[index].append(value) }
                else { keys.append(key); rows.append([value]) }
            }
        }
        return .object(["selected": pages.isEmpty ? .null : .object([:]), "catalogs": .array(rows.map(VortxJSON.array))])
    }

    static func metaDetails(meta: VortxResourceSnapshot, streams: VortxResourceSnapshot?,
                            expectedStream: VortxResourceRequest?, registry: [VortxResourceAddon]) throws -> VortxJSON {
        guard meta.request.resource == .meta else { throw VortxNativeError.invalidResponse }
        try validate(meta, registry: registry)
        if let streams {
            try validate(streams, registry: registry)
            guard streams.ownerID == meta.ownerID, streams.request == expectedStream,
                  streams.request.resource == .stream, streams.request.type == meta.request.type
            else { throw VortxNativeError.invalidResponse }
        }
        var embedded: [VortxJSON] = []
        for group in meta.groups where group.status == .ready {
            guard let value = try group.items(for: .meta).first else { continue }
            let target = expectedStream ?? VortxResourceRequest(resource: .stream, type: meta.request.type, id: meta.request.id)
            let video = value["videos"]?.array?.first { $0["id"] == .string(target.id) }
            let items = video?["streams"]?.array ?? (target.id == meta.request.id ? value["streams"]?.array : nil)
            if let items {
                let source = VortxResourceGroup(addonId: group.addonId, status: .ready, content: .object(["streams": .array(items)]), error: nil)
                embedded.append(try entry(source, request: target, registry: registry))
            }
        }
        return .object([
            "selected": .object(["metaPath": try path(meta.request), "streamPath": try expectedStream.map(path) ?? .null]),
            "metaItems": .array(try meta.groups.map { try entry($0, request: meta.request, registry: registry) }),
            "streams": .array(try streams.map { snapshot in try snapshot.groups.map { try entry($0, request: snapshot.request, registry: registry) } } ?? []),
            "metaStreams": .array(embedded),
        ])
    }

    static func subtitles(_ snapshot: VortxResourceSnapshot, registry: [VortxResourceAddon]) throws -> VortxJSON {
        guard snapshot.request.resource == .subtitles else { throw VortxNativeError.invalidResponse }
        try validate(snapshot, registry: registry)
        return .array(try snapshot.groups.map { try entry($0, request: snapshot.request, registry: registry) })
    }
}

/// One admitted detail request may retain its preceding metadata while that same resource loads.
/// Only presentation metadata is carried; streams and embedded stream groups stay with the new load.
enum VortxMetaLoadingProjection {
    static func retainingReadyMetadata(previous: VortxJSON?, incoming: VortxJSON,
                                       ownerIsCurrent: Bool) -> VortxJSON {
        guard ownerIsCurrent, let previous,
              previous["nativeError"] == nil, incoming["nativeError"] == nil,
              let metaPath = incoming["selected"]?["metaPath"],
              metaPath["resource"] == .string("meta"),
              case .string(let id) = metaPath["id"], !id.isEmpty,
              case .string(let type) = metaPath["type"], !type.isEmpty,
              previous["selected"]?["metaPath"] == metaPath,
              let priorRows = previous["metaItems"]?.array,
              let incomingRows = incoming["metaItems"]?.array,
              case .object(var fields) = incoming else { return incoming }
        fields["metaItems"] = .array(incomingRows.map { row in
            guard row["content"]?["type"] == .string("Loading"),
                  let request = row["request"], request["path"] == metaPath,
                  case .string(let base) = request["base"], !base.isEmpty,
                  case .object(var fields) = row else { return row }
            // Duplicate provider receipts are ambiguous; never choose one by incidental order.
            let matching = priorRows.filter { $0["request"] == request }
            guard matching.count == 1 else { return row }
            let prior = matching[0], retained: VortxJSON?
            switch prior["content"]?["type"] {
            case .string("Ready"): retained = prior["content"]
            case .string("Loading"): retained = prior["retainedWhileLoading"]
            default: retained = nil
            }
            guard retained?["type"] == .string("Ready"),
                  retained?["content"]?["id"] == .string(id),
                  retained?["content"]?["type"] == .string(type) else { return row }
            // Actual content remains Loading for every freshness/terminal consumer. Only the
            // display accessor reads this raw envelope; fresh Ready/Err rows replace it normally.
            fields["retainedWhileLoading"] = retained
            return .object(fields)
        })
        return .object(fields)
    }
}
