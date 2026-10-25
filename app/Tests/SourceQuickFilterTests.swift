import Foundation

@main
enum SourceQuickFilterTests {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func stream(_ fields: [String: Any]) -> CoreStream {
        try! JSONDecoder().decode(CoreStream.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    static func main() {
        let unlabelled = stream(["url": "https://example.invalid/plain", "name": "Unknown"])
        let advertisedCache = stream(["url": "https://example.invalid/cached", "name": "Cached ⚡"])
        let first = stream(["infoHash": "ABC", "name": "same", "behaviorHints": ["filename": "DV HEVC"]])
        let second = stream(["infoHash": "ABC", "name": "same", "behaviorHints": ["filename": "HDR10 H.264"]])
        let usenet = stream(["nzbUrl": "https://example.invalid/a.nzb", "name": "USENET",
                             "behaviorHints": ["filename": "HDR10+ AV1"]])
        let invalid = stream(["nzbUrl": "https://user:secret@example.invalid/a.nzb", "name": "Invalid descriptor"])
        let rows = [unlabelled, advertisedCache, first, second, usenet, invalid]
        let groups = [CoreStreamSourceGroup(id: "one", addon: "One", streams: rows),
                      CoreStreamSourceGroup(id: "two", addon: "Two", streams: [first])]
        let original = groups
        // The existing parser is source-contracted, not mirrored here. These are explicit reported-tag
        // inputs to the actual new index/mapping/projection implementation.
        var tagCalls = 0
        let index = SourceQuickFilterPolicy.Index(groups: groups) { stream in
            tagCalls += 1
            return stream.behaviorHints?.filename?.components(separatedBy: " ") ?? []
        }
        expect(tagCalls == 7, "tag facts built once per input occurrence")
        let all = index.project(.init(), cachedHashes: [], cachedUsenetURLs: [])
        expect(all.map(\.group) == original, "inactive filter preserves complete groups and order")
        expect(all[0].rows.allSatisfy { $0.groupID == "one" } && all[1].rows.allSatisfy { $0.groupID == "two" },
               "flattenable production rows retain the exact configured group identity")
        let sameName = SourceQuickFilterPolicy.Index(groups: [
            .init(id: "configured-a", addon: "AIOStreams", streams: [first]),
            .init(id: "configured-b", addon: "AIOStreams", streams: [first])
        ], reportedTags: { _ in [] })
        expect(sameName.groups.map { $0.rows[0].groupID } == ["configured-a", "configured-b"]
                   && sameName.groups[0].rows[0].id != sameName.groups[1].rows[0].id,
               "identical rows and names in two configurations retain distinct origins and row identities")
        expect(Set(all.flatMap(\.rows).map(\.id)).count == 7, "duplicate IDs are unique across occurrences and add-ons")
        expect(first.id == second.id, "fixture exercises actual duplicate stream identity")
        let secondID = all[0].rows[3].id
        let hdr = index.project(.init(range: .hdr10), cachedHashes: [], cachedUsenetURLs: [])
        expect(hdr.count == 1 && hdr[0].rows.count == 1 && hdr[0].rows[0].stream == second, "range selects exact original record")
        expect(hdr[0].rows[0].id == secondID, "filtering earlier duplicate does not retarget the retained row")
        let reversed = SourceQuickFilterPolicy.Index(groups: [
            .init(id: "one", addon: "One", streams: [second, first, unlabelled, advertisedCache, usenet, invalid]), groups[1]
        ], previous: index, reportedTags: { $0.behaviorHints?.filename?.components(separatedBy: " ") ?? [] })
        expect(reversed.groups[0].rows[0].id == secondID && reversed.groups[0].rows[1].id == all[0].rows[2].id,
               "rank reversal preserves full-record identities despite identical legacy IDs")
        expect(reversed.groups[1].rows[0].id == all[1].rows[0].id,
               "same stream in another add-on keeps its own row identity")
        let fileOne = stream(["infoHash": "ABC", "name": "same", "fileIdx": 1,
                              "behaviorHints": ["proxyHeaders": ["request": ["X-Test": "one"]]]])
        let fileTwo = stream(["infoHash": "ABC", "name": "same", "fileIdx": 2,
                              "behaviorHints": ["proxyHeaders": ["request": ["X-Test": "two"]]]])
        expect(fileOne.id == fileTwo.id, "fixture covers transport-distinct legacy duplicate IDs")
        let transports = SourceQuickFilterPolicy.Index(groups: [.init(id: "files", addon: "Files", streams: [fileOne, fileTwo, fileOne])], reportedTags: { _ in [] })
        let swapped = SourceQuickFilterPolicy.Index(groups: [.init(id: "files", addon: "Files", streams: [fileTwo, fileOne, fileOne])], previous: transports, reportedTags: { _ in [] })
        expect(swapped.groups[0].rows[0].id == transports.groups[0].rows[1].id &&
               swapped.groups[0].rows[1].id == transports.groups[0].rows[0].id &&
               swapped.groups[0].rows[2].id == transports.groups[0].rows[2].id,
               "file/header variants and truly identical occurrences preserve distinct stable IDs")
        let duplicateCount = 2_048
        let identicalGroup = CoreStreamSourceGroup(id: "identical", addon: "Identical", streams: Array(repeating: first, count: duplicateCount))
        var duplicateTagCalls = 0
        let identical = SourceQuickFilterPolicy.Index(groups: [identicalGroup]) { _ in duplicateTagCalls += 1; return [] }
        let identicalRebuild = SourceQuickFilterPolicy.Index(groups: [identicalGroup], previous: identical) { _ in duplicateTagCalls += 1; return [] }
        expect(duplicateTagCalls == duplicateCount * 2 && identicalRebuild.groups[0].rows.map(\.id) == identical.groups[0].rows.map(\.id),
               "large identical bucket reuses every ID with one fact extraction per row per rebuild")
        expect(Set(identicalRebuild.groups[0].rows.map(\.id)).count == duplicateCount, "identical records still have distinct row IDs")
        let unknown = index.project(.init(range: .unknown, codec: .unknown), cachedHashes: [], cachedUsenetURLs: [])
        expect(unknown[0].group.streams == [unlabelled, advertisedCache, invalid], "unknown remains explicitly reachable")
        expect(index.project(.init(confirmedCacheOnly: true), cachedHashes: [], cachedUsenetURLs: []).isEmpty,
               "addon cache text and direct URL are not confirmation")
        let confirmed = index.project(.init(confirmedCacheOnly: true), cachedHashes: ["abc"],
                                      cachedUsenetURLs: ["https://example.invalid/a.nzb"])
        expect(confirmed[0].group.streams == [first, second, usenet] && confirmed[1].group.streams == [first],
               "confirmed normalized hash and validated NZB matches preserve order and groups")
        expect(index.project(.init(confirmedCacheOnly: true), cachedHashes: [],
                             cachedUsenetURLs: ["https://user:secret@example.invalid/a.nzb"]).isEmpty,
               "unsafe NZB descriptor is never cache proof")
        let intersection = index.project(.init(confirmedCacheOnly: true, range: .hdr10Plus, codec: .av1),
                                         cachedHashes: [], cachedUsenetURLs: ["https://example.invalid/a.nzb"])
        expect(intersection.first?.group.streams == [usenet], "facets intersect")
        expect(index.project(.init(range: .dv, codec: .av1), cachedHashes: [], cachedUsenetURLs: []).isEmpty,
               "incompatible facets yield an explicit empty projection")
        expect(index.project(.init(), cachedHashes: [], cachedUsenetURLs: []).map(\.group) == original,
               "reset restores every source without changing saved fields or rank")
        expect(groups == original && tagCalls == 7, "projection does not mutate inputs or reparse reported tags")
        let layered = SourceQuickFilterPolicy.Index(groups: [groups[1]], reportedTags: { _ in ["DV", "HDR10", "HEVC"] })
        expect(!layered.project(.init(range: .dv), cachedHashes: [], cachedUsenetURLs: []).isEmpty &&
               !layered.project(.init(range: .hdr10), cachedHashes: [], cachedUsenetURLs: []).isEmpty,
               "layered reported formats remain additive")
        // Exercise the SAME Session used by SourceListModel. No fabricated bridge/registry exists:
        // a registry-only rebind leaves output identity/signature unchanged and runs no install.
        var session = SourceQuickFilterPolicy.Session()
        session.install(index, resetSelection: true, cachedHashes: ["abc"], cachedUsenetURLs: [])
        expect(session.displayed(scopeIsCurrent: true, cacheIsCurrent: false) == all,
               "All remains available without any navigation receipt or current cache evidence")
        expect(session.displayed(scopeIsCurrent: true, cacheIsCurrent: false) == all,
               "unchanged-signature registry-only rebind requires no rebuild or recapture for All")
        session.select(.init(confirmedCacheOnly: true), cachedHashes: ["abc"], cachedUsenetURLs: [])
        expect(!session.displayed(scopeIsCurrent: true, cacheIsCurrent: true).isEmpty,
               "current successful cache facts populate Confirmed")
        expect(session.displayed(scopeIsCurrent: true, cacheIsCurrent: false).isEmpty,
               "credential change without publication or rebuild immediately hides old Confirmed proof")
        session.refresh(cachedHashes: [], cachedUsenetURLs: [])
        expect(session.displayed(scopeIsCurrent: true, cacheIsCurrent: true).isEmpty,
               "queued old cache publication read with current empty snapshot cannot restore proof")
        session.select(.init(), cachedHashes: [], cachedUsenetURLs: [])
        expect(session.displayed(scopeIsCurrent: true, cacheIsCurrent: false) == all,
               "Reset after credential invalidation restores All, not a blank list")
        expect(session.displayed(scopeIsCurrent: false, cacheIsCurrent: true).isEmpty,
               "changed source output identity cannot expose the old projection")
        session.select(.init(range: .dv), cachedHashes: [], cachedUsenetURLs: [])
        session.install(reversed, resetSelection: false, cachedHashes: [], cachedUsenetURLs: [])
        expect(session.selection.range == .dv && session.groups[0].rows[0].id == all[0].rows[2].id,
               "same-scope rank rebuild preserves selection and logical row identity")
        session.install(index, resetSelection: true, cachedHashes: [], cachedUsenetURLs: [])
        expect(!session.selection.isActive && session.groups == all, "new source/profile/cache scope resets filters")
        session.invalidate()
        session.refresh(cachedHashes: ["abc"], cachedUsenetURLs: [])
        expect(session.displayed(scopeIsCurrent: true, cacheIsCurrent: true).isEmpty,
               "late cache event after source retirement cannot resurrect rows")
        expect(!TVDetailSourceColumnFocusPolicy.filterBarOwnsUpEscape(groupsCount: 1), "legacy single-group focus unchanged")
        expect(TVDetailSourceColumnFocusPolicy.filterBarOwnsUpEscape(groupsCount: 1, hasQuickFilters: true),
               "quick filters own the single-group top boundary")
        expect(!TVDetailSourceColumnFocusPolicy.sourceRowOwnsUpEscape(at: 0, groupsCount: 1, hasQuickFilters: true),
               "first source row reaches its filter bar with native Up")
        expect(!TVDetailSourceColumnFocusPolicy.sourceRowOwnsUpEscape(at: 3, groupsCount: 2, hasQuickFilters: true),
               "deeper source rows retain native Up")
        print("Source quick-filter production policy and focus tests PASS")
    }
}
