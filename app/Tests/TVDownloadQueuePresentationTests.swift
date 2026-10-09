import Foundation

// Offline dependencies only. The runner compiles real DownloadModels, DownloadGroup, the new pure
// presentation policy and the actual manager's capacity/order/reorder/drain methods. Transfer startup,
// index persistence and defaults are inert fixtures, not production download/backend acceptance.
struct PlaybackMeta {
    let libraryId: String; let videoId: String; let type: String; let name: String; let poster: String?
    let season: Int?; let episode: Int?
}
typealias UserDefaults = QueueFixtureDefaults
final class QueueFixtureDefaults {
    static let standard = QueueFixtureDefaults()
    var values: [String: Any] = [:]
    func set(_ value: Any, forKey key: String) { values[key] = value }
}
@MainActor final class QueueFixtureStore {
    var records: [DownloadRecord] = []
    func record(id: UUID) -> DownloadRecord? { records.first { $0.id == id } }
    func update(id: UUID, _ mutation: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        mutation(&records[index])
    }
}

@main
enum TVDownloadQueuePresentationTests {
    static var checks = 0
    static var failures: [String] = []
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { failures.append(message) }
    }
    static func record(_ suffix: Int, state: DownloadState = .queued, show: Bool = false) -> DownloadRecord {
        DownloadRecord(id: UUID(uuidString: String(format: "11111111-1111-4111-8111-%012d", suffix))!,
            contentId: show ? "show" : "movie-\(suffix)", videoId: show ? "show:2:\(suffix)" : "movie-\(suffix)",
            type: show ? "series" : "movie", name: show ? "Show" : "Movie \(suffix)", poster: nil,
            season: show ? 2 : nil, episode: show ? suffix : nil, sourceName: nil, qualityText: nil,
            isTorrent: false, headers: nil, remoteURL: "https://fixture.invalid/\(suffix).mp4",
            localFilename: "\(suffix).mp4", state: state, addedAt: Date(timeIntervalSince1970: Double(suffix)))
    }

    @MainActor static func main() throws {
        let a = record(1), b = record(2), c = record(3)
        let first = TVDownloadQueuePresentationPolicy.priority(for: a.id, orderedIDs: [a.id, b.id, c.id])!
        let middle = TVDownloadQueuePresentationPolicy.priority(for: b.id, orderedIDs: [a.id, b.id, c.id])!
        let last = TVDownloadQueuePresentationPolicy.priority(for: c.id, orderedIDs: [a.id, b.id, c.id])!
        require(first.position == 1 && first.count == 3 && !first.canMoveEarlier && first.canMoveLater,
                "first priority uses actual ordinal and disables Earlier")
        require(middle.position == 2 && middle.canMoveEarlier && middle.canMoveLater,
                "middle priority enables both directions")
        require(last.position == 3 && last.canMoveEarlier && !last.canMoveLater,
                "last priority disables Later")
        let single = TVDownloadQueuePresentationPolicy.priority(for: a.id, orderedIDs: [a.id])!
        require(!single.canMoveEarlier && !single.canMoveLater, "single queued item cannot move")
        require(TVDownloadQueuePresentationPolicy.priority(for: a.id, orderedIDs: []) == nil,
                "empty or missing queue has no invented position")
        require(TVDownloadQueuePresentationPolicy.priority(for: a.id, orderedIDs: [a.id, a.id]) == nil,
                "ambiguous identity has no misleading position")
        let lower = TVDownloadQueuePresentationPolicy.Capacity(maximum: 1, allowedRange: FixtureDownloadManager.concurrencyRange)
        let upper = TVDownloadQueuePresentationPolicy.Capacity(maximum: 5, allowedRange: FixtureDownloadManager.concurrencyRange)
        let center = TVDownloadQueuePresentationPolicy.Capacity(maximum: 3, allowedRange: FixtureDownloadManager.concurrencyRange)
        require(!lower.canDecrease && lower.canIncrease, "lower manager bound disables Fewer")
        require(upper.canDecrease && !upper.canIncrease, "upper manager bound disables More")
        require(center.canDecrease && center.canIncrease, "interior capacity enables both controls")

        let showQueued = record(4, show: true), showPaused = record(5, state: .paused, show: true)
        let showFinished = record(6, state: .completed, show: true), failed = record(7, state: .failed)
        let groups = [DownloadGroup(id: "series:show", title: "Show", poster: "real-poster", type: "series",
                                   records: [showQueued, showPaused, showFinished]),
                      DownloadGroup(id: "movie:1", title: "Queued movie", poster: nil, type: "movie", records: [a]),
                      DownloadGroup(id: "movie:7", title: "Failed", poster: nil, type: "movie", records: [failed])]
        let remaining = TVDownloadQueuePresentationPolicy.groupsExcludingQueued(groups)
        require(remaining.count == 2 && remaining[0].records.map(\.id) == [showPaused.id, showFinished.id],
                "queued rows are excluded once without changing remaining episode order")
        require(remaining[0].id == groups[0].id && remaining[0].title == groups[0].title
                && remaining[0].poster == groups[0].poster && remaining[0].type == groups[0].type && remaining[0].count == 2,
                "remaining folder identity, metadata and count reflect its real records")
        require(remaining[1].records == [failed] && remaining.flatMap(\.records).allSatisfy { $0.state != .queued },
                "nonqueued states survive and no queued fullrow is duplicated")

        let manager = FixtureDownloadManager()
        manager.store.records = [c, b, a, failed]
        manager.queueOrder = [failed.id, b.id, UUID()]
        require(manager.orderedQueuedRecords().map(\.id) == [b.id, a.id, c.id],
                "actual manager order filters nonqueued/stale ids then uses explicit rank and oldest-first fallback")
        manager.moveQueuedEarlier(id: a.id)
        require(manager.orderedQueuedRecords().map(\.id) == [a.id, b.id, c.id]
                && (QueueFixtureDefaults.standard.values[FixtureDownloadManager.queueOrderDefaultsKey] as? [String]) == [a.id, b.id, c.id].map(\.uuidString),
                "actual Earlier method reorders and persists the same live priority")
        manager.moveQueuedLater(id: a.id)
        require(manager.orderedQueuedRecords().map(\.id) == [b.id, a.id, c.id], "actual Later reverses the one-position move")
        let edgeOrder = manager.queueOrder
        manager.moveQueuedEarlier(id: b.id); manager.moveQueuedLater(id: c.id)
        require(manager.queueOrder == edgeOrder, "actual first/last actions safely no-op")
        manager.store.update(id: a.id) { $0.state = .downloading }
        manager.moveQueuedEarlier(id: a.id)
        require(manager.queueOrder == edgeOrder, "item starting between render and tap cannot be reprioritized")
        manager.store.update(id: b.id) { $0.state = .paused }
        manager.moveQueuedLater(id: b.id); manager.moveQueuedEarlier(id: UUID())
        require(manager.queueOrder == edgeOrder, "paused or missing item actions safely no-op")

        let capacity = FixtureDownloadManager()
        let activeOne = record(8, state: .downloading), activeTwo = record(9, state: .downloading)
        capacity.store.records = [activeOne, activeTwo, c, b, a]
        capacity.queueOrder = [b.id, a.id, c.id]
        capacity.activeWeight = 2
        capacity.setMaxConcurrentDownloads(1)
        require(capacity.maxConcurrentDownloads == 1 && capacity.activeWeight == 2 && capacity.startedIDs.isEmpty
                && capacity.store.records.filter { $0.state == .downloading }.map(\.id) == [activeOne.id, activeTwo.id],
                "actual setter and drain lower capacity without stopping active transfers or starting queued work")
        capacity.setMaxConcurrentDownloads(0)
        require(capacity.maxConcurrentDownloads == 1 && capacity.startedIDs.isEmpty, "actual setter clamps the lower edge and unchanged cap is inert")
        capacity.setMaxConcurrentDownloads(3)
        require(capacity.startedIDs == [b.id] && capacity.activeWeight == 3
                && capacity.orderedQueuedRecords().map(\.id) == [a.id, c.id],
                "actual setter and drain fill only the newly available slot in real manager order")
        capacity.setMaxConcurrentDownloads(100)
        require(capacity.maxConcurrentDownloads == 5 && capacity.startedIDs == [b.id, a.id, c.id],
                "actual setter clamps upper edge and actual admission keeps the queue's priority")

        let view = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let callsites = [
            "@ObservedObject private var manager = DownloadManager.shared",
            "let queued = manager.orderedQueuedRecords()",
            "groupsExcludingQueued(store.groupedDownloads())",
            "priority(for: record.id, orderedIDs: orderedIDs)",
            "disabled: !capacity.canDecrease", "disabled: !capacity.canIncrease",
            "manager.setMaxConcurrentDownloads(manager.maxConcurrentDownloads - 1)",
            "manager.setMaxConcurrentDownloads(manager.maxConcurrentDownloads + 1)",
            "disabled: !priority.canMoveEarlier", "disabled: !priority.canMoveLater",
            "manager.moveQueuedEarlier(id: record.id)", "manager.moveQueuedLater(id: record.id)",
            "manager.pause(id: record.id)", "manager.resume(id: record.id)", "manager.cancel(id: record.id)",
            "store.fileExists(for: record)", "store.fileURL(for: record)", "torrent: false)",
            ".disabled(disabled)", ".vortxCinemaCard()", ".focusSection()"
        ]
        for callsite in callsites { require(view.contains(callsite), "actual TV callsite/flag retained: \(callsite)") }
        require(!view.contains("private let manager") && !view.contains("ForEach(store.groupedDownloads())"),
                "TV does not ignore manager publications or duplicate queued rows in the grouped list")
        if !failures.isEmpty { failures.forEach { print("FAIL: \($0)") }; exit(1) }
        print("PASS: \(checks) offline TV queue policy, actual manager methods and source-wiring checks")
    }
}
