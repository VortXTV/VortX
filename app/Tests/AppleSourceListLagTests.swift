import Foundation

// The runner inserts the actual production display methods and all three consumer
// expressions. Only state, source values and parsing counters are fixture collaborators.
private struct CoreStream {
    let id: String
    let token: String
    let size: Double
    let seeders: Int
}
private struct CoreStreamSourceGroup {
    let id: String
    let addon: String
    let streams: [CoreStream]
}
@MainActor private enum StreamRanking {
    static var sizeReads: [String: Int] = [:]
    static var seederReads: [String: Int] = [:]
    static func sizeForSort(_ stream: CoreStream) -> Double {
        sizeReads[stream.token, default: 0] += 1
        return stream.size
    }
    static func seedersForSort(_ stream: CoreStream) -> Int {
        seederReads[stream.token, default: 0] += 1
        return stream.seeders
    }
    static func reset() { sizeReads = [:]; seederReads = [:] }
}

// PRODUCTION_ROWS
@MainActor private struct ProductionSourceList {
    var groups: [CoreStreamSourceGroup]
    var sourceFilter: String?
    var collapsed: Set<String> = []
    var renderLimit = 100
    var sortMode: SourceSort = .best
    // PRODUCTION_METHODS
    func plan() -> (groups: [WindowedGroup], shown: Int, expandable: Int) { windowedPlan }
}

private final class CoreBridge {
    struct StreamAddonState: Equatable {
        let name: String
        let ready: Int
        let loading: Bool
        let error: String?
    }
    var reads = 0
    var requestedIDs: [String?] = []
    let states: [StreamAddonState] = [
        .init(name: "ready", ready: 140, loading: false, error: nil),
        .init(name: "empty", ready: 0, loading: false, error: nil),
        .init(name: "failed", ready: 0, loading: false, error: "controlled failure"),
    ]
    func streamAddonStates(forStreamId id: String? = nil) -> [StreamAddonState] {
        reads += 1
        requestedIDs.append(id)
        return states
    }
}
private struct FixtureSettlement { var isSettled = false }
private struct FixtureVideo { let id: String }
private final class ProductionDiagnosticConsumers {
    let core = CoreBridge()
    var sourceList = FixtureSettlement()
    let shownVideo = FixtureVideo(id: "synthetic-episode")
    // PRODUCTION_CONSUMERS
}

@main @MainActor private enum AppleSourceListLagTests {
    static var checks = 0
    static var failures = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL \(message)") }
    }
    static func streams(_ prefix: String, count: Int) -> [CoreStream] {
        (0..<count).map { index in
            CoreStream(id: "row-\(index / 2)", token: "\(prefix)-\(index)",
                       size: Double(index % 7), seeders: index % 9 - 1)
        }
    }
    static func expected(_ streams: [CoreStream], mode: ProductionSourceList.SourceSort) -> [String] {
        switch mode {
        case .best: return streams.map(\.token)
        case .size:
            return streams.enumerated().sorted {
                $0.element.size == $1.element.size ? $0.offset < $1.offset : $0.element.size > $1.element.size
            }.map { $0.element.token }
        case .seeders:
            return streams.enumerated().sorted {
                $0.element.seeders == $1.element.seeders ? $0.offset < $1.offset : $0.element.seeders > $1.element.seeders
            }.map { $0.element.token }
        }
    }
    static func diagnosticChecks() {
        let consumers = ProductionDiagnosticConsumers()
        let paths: [(String, (Bool) -> [CoreBridge.StreamAddonState], String?)] = [
            ("movie", consumers.movieStates, nil),
            ("live", consumers.liveStates, nil),
            ("episode", consumers.episodeStates, "synthetic-episode"),
        ]
        for (name, read, expectedID) in paths {
            for suspended in [false, true] {
                for settled in [false, true] {
                    consumers.sourceList.isSettled = settled
                    consumers.core.reads = 0
                    consumers.core.requestedIDs = []
                    let states = read(suspended)
                    let allowed = !suspended && settled
                    check(consumers.core.reads == (allowed ? 1 : 0), "\(name) diagnostic acquisition gate suspended=\(suspended) settled=\(settled)")
                    check(states == (allowed ? consumers.core.states : []), "\(name) preserves settled ready/empty/error diagnostics")
                    if allowed { check(consumers.core.requestedIDs == [expectedID], "\(name) preserves exact source request scope") }
                }
            }
        }
    }
    static func displayChecks() {
        let first = streams("first", count: 140)
        let later = streams("later", count: 1_600)
        let groups = [
            CoreStreamSourceGroup(id: "base-one", addon: "One", streams: first),
            CoreStreamSourceGroup(id: "base-two", addon: "Two", streams: later),
            CoreStreamSourceGroup(id: "base-three", addon: "Three", streams: streams("third", count: 300)),
        ]
        for mode in ProductionSourceList.SourceSort.allCases {
            var list = ProductionSourceList(groups: groups, sortMode: mode)
            StreamRanking.reset()
            let plan = list.plan()
            check(plan.shown == 100 && plan.expandable == 2_040, "\(mode) row and expandable budgets")
            check(plan.groups.map(\.id) == ["One", "Two", "Three"], "\(mode) keeps budget-exhausted headers")
            check(plan.groups.map { $0.group.id } == groups.map(\.id), "\(mode) preserves transport identities")
            // Under All every add-on shows its top rows: an equal share each, the remainder to the first.
            check(plan.groups.map(\.rows.count) == [34, 33, 33], "\(mode) shares the window across add-ons")
            check(zip(plan.groups, [first, later, streams("third", count: 300)]).allSatisfy { group, source in
                group.rows.map { $0.stream.token } == Array(expected(source, mode: mode).prefix(group.rows.count))
            }, "\(mode) descending order and stable ties")
            check(plan.groups.allSatisfy { Set($0.rows.map(\.id)).count == $0.rows.count }, "\(mode) repeated content IDs retain distinct row suffixes")
            let reads = mode == .size ? StreamRanking.sizeReads : StreamRanking.seederReads
            check(mode == .best ? reads.isEmpty : reads.count == 2_040 && reads.values.allSatisfy { $0 == 1 }, "\(mode) comparator keys parsed once per stream")

            list.renderLimit = 2
            StreamRanking.reset()
            let tight = list.plan()
            let tightReads = mode == .size ? StreamRanking.sizeReads : StreamRanking.seederReads
            check(tight.groups.map(\.rows.count) == [1, 1, 0] && tightReads.keys.allSatisfy { !$0.hasPrefix("third-") },
                  "\(mode) no parsing after exhausted budget")

            list.renderLimit = 0
            StreamRanking.reset()
            let zero = list.plan()
            check(zero.shown == 0 && zero.groups.count == 3 && zero.expandable == 2_040, "\(mode) zero budget keeps headers and total")
            check(StreamRanking.sizeReads.isEmpty && StreamRanking.seederReads.isEmpty, "\(mode) zero budget performs no parsing")

            list.renderLimit = 100
            list.collapsed = ["One"]
            StreamRanking.reset()
            let collapsed = list.plan()
            check(collapsed.groups[0].rows.isEmpty && collapsed.shown == 100 && collapsed.expandable == 1_900, "\(mode) collapsed header spends no rows")
            check(collapsed.groups[1].rows.map { $0.stream.token } == Array(expected(later, mode: mode).prefix(50))
                  && collapsed.groups[2].rows.count == 50, "\(mode) expanded groups share the window")

            list.sourceFilter = "Three"
            let filtered = list.plan()
            check(filtered.groups.map(\.id) == ["Three"] && filtered.shown == 100 && filtered.expandable == 300, "\(mode) addon filter preserves counts")
            list.renderLimit = 200
            check(list.plan().shown == 200, "\(mode) show-more grows the same group window")
        }
    }
    static func main() {
        diagnosticChecks()
        displayChecks()
        print("Apple source-list lag checks=\(checks) failures=\(failures); operation counts only, no frame-time claim")
        exit(failures == 0 ? 0 : 1)
    }
}
