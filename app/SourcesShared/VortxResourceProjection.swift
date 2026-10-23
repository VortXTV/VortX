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
