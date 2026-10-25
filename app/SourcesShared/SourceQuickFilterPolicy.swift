import Foundation

/// A display-only projection of already admitted/ranked sources. Reported tags are not measured
/// playback properties; missing range tags never imply SDR, and missing cache proof never means uncached.
enum SourceQuickFilterPolicy {
    enum Range: String, CaseIterable, Sendable { case dv = "DV", hdr10Plus = "HDR10+", hdr10 = "HDR10", hdr = "HDR", unknown = "Unknown" }
    enum Codec: String, CaseIterable, Sendable { case hevc = "HEVC", av1 = "AV1", h264 = "H.264", unknown = "Unknown" }
    struct Selection: Equatable, Sendable {
        var confirmedCacheOnly = false
        var range: Range?
        var codec: Codec?
        var isActive: Bool { confirmedCacheOnly || range != nil || codec != nil }
    }
    struct Row: Identifiable, Equatable, Sendable {
        let id: UUID
        let addon: String
        let groupID: String
        let stream: CoreStream
        fileprivate let ranges: Set<Range>
        fileprivate let codecs: Set<Codec>
        fileprivate let cacheHash: String?
        fileprivate let cacheURLs: [String]
    }
    struct Group: Identifiable, Equatable, Sendable {
        let group: CoreStreamSourceGroup
        let rows: [Row]
        var id: String { group.id }
    }
    /// Equality uses the complete actual record, not CoreStream.id (which omits transport hints).
    /// Hash every stored field to keep duplicate-ID buckets bounded; equality still resolves collisions.
    private struct RecordKey: Hashable, Sendable {
        let groupID: String
        let addon: String
        let stream: CoreStream
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.groupID == rhs.groupID && lhs.addon == rhs.addon && lhs.stream == rhs.stream
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(groupID); hasher.combine(addon)
            hasher.combine(stream.url); hasher.combine(stream.ytId); hasher.combine(stream.infoHash)
            hasher.combine(stream.fileIdx); hasher.combine(stream.sources); hasher.combine(stream.externalUrl)
            hasher.combine(stream.name); hasher.combine(stream.description); hasher.combine(stream.nzbUrl)
            hasher.combine(stream.nzbUrls); hasher.combine(stream.servers); hasher.combine(stream.fileMustInclude)
            hasher.combine(stream.vortxProvider)
            let hints = stream.behaviorHints
            hasher.combine(hints != nil); hasher.combine(hints?.notWebReady); hasher.combine(hints?.bingeGroup)
            hasher.combine(hints?.filename); hasher.combine(hints?.videoHash); hasher.combine(hints?.videoSize)
            hasher.combine(hints?.proxyHeaders != nil)
            let headers = hints?.proxyHeaders?.request
            hasher.combine(headers != nil)
            for key in headers?.keys.sorted() ?? [] { hasher.combine(key); hasher.combine(headers?[key]) }
        }
    }
    struct Index: Sendable {
        let groups: [Group]
        static let empty = Index(groups: [], reportedTags: { _ in [] })

        /// Called once in SourceListModel's existing detached rebuild, never from a View body.
        /// Reuse IDs by full record before filtering/sorting, including across changed ranking order.
        init(groups: [CoreStreamSourceGroup], previous: Index? = nil, reportedTags: (CoreStream) -> [String]) {
            var priorIDs: [RecordKey: [UUID]] = [:]
            for group in previous?.groups ?? [] {
                for row in group.rows {
                    priorIDs[RecordKey(groupID: group.id, addon: row.addon, stream: row.stream), default: []].append(row.id)
                }
            }
            var used: [RecordKey: Int] = [:]
            self.groups = groups.map { group in
                let rows = group.streams.map { stream in
                    let key = RecordKey(groupID: group.id, addon: group.addon, stream: stream)
                    let occurrence = used[key, default: 0]
                    used[key] = occurrence + 1
                    let previous = priorIDs[key] ?? []
                    let id = occurrence < previous.count ? previous[occurrence] : UUID()
                    let tags = Set(reportedTags(stream))
                    var ranges = Set(Range.allCases.filter { $0 != .unknown && tags.contains($0.rawValue) })
                    var codecs = Set(Codec.allCases.filter { $0 != .unknown && tags.contains($0.rawValue) })
                    if ranges.isEmpty { ranges.insert(.unknown) }
                    if codecs.isEmpty { codecs.insert(.unknown) }
                    return Row(id: id,
                        addon: group.addon, groupID: group.id, stream: stream, ranges: ranges, codecs: codecs,
                        cacheHash: stream.isUsenet ? nil : stream.infoHash?.lowercased(),
                        cacheURLs: stream.isUsenet ? stream.usenetURLs : [])
                }
                return Group(group: group, rows: rows)
            }
        }

        func project(_ selection: Selection, cachedHashes: Set<String>, cachedUsenetURLs: Set<String>) -> [Group] {
            guard selection.isActive else { return groups }
            return groups.compactMap { group in
                let rows = group.rows.filter { row in
                    let confirmed = row.cacheHash.map(cachedHashes.contains) == true
                        || row.cacheURLs.contains(where: cachedUsenetURLs.contains)
                    return (!selection.confirmedCacheOnly || confirmed)
                        && (selection.range.map(row.ranges.contains) ?? true)
                        && (selection.codec.map(row.codecs.contains) ?? true)
                }
                guard !rows.isEmpty else { return nil }
                return Group(group: .init(id: group.group.id, addon: group.group.addon, streams: rows.map(\.stream)), rows: rows)
            }
        }
    }
    /// The actual model's display lifecycle, independent of ranking/registry availability. Cache
    /// validity can hide an active Confirmed facet, but never the unchanged All-source projection.
    struct Session: Sendable {
        private(set) var index = Index.empty
        private(set) var selection = Selection()
        private(set) var groups: [Group] = []
        mutating func install(_ index: Index, resetSelection: Bool, cachedHashes: Set<String>, cachedUsenetURLs: Set<String>) {
            self.index = index
            if resetSelection { selection = .init() }
            refresh(cachedHashes: cachedHashes, cachedUsenetURLs: cachedUsenetURLs)
        }
        mutating func select(_ selection: Selection, cachedHashes: Set<String>, cachedUsenetURLs: Set<String>) {
            self.selection = selection
            refresh(cachedHashes: cachedHashes, cachedUsenetURLs: cachedUsenetURLs)
        }
        mutating func refresh(cachedHashes: Set<String>, cachedUsenetURLs: Set<String>) {
            groups = index.project(selection, cachedHashes: cachedHashes, cachedUsenetURLs: cachedUsenetURLs)
        }
        mutating func invalidate() { self = Session() }
        func displayed(scopeIsCurrent: Bool, cacheIsCurrent: Bool) -> [Group] {
            guard scopeIsCurrent, !selection.confirmedCacheOnly || cacheIsCurrent else { return [] }
            return groups
        }
    }
}
