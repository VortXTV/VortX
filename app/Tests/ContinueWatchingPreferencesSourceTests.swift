// Compile beside the COMPLETE admitted production source, never an extracted replacement.
// No persistent defaults, standard defaults, profiles, accounts, engine, UI or network.
import Foundation
import Darwin

private enum FixtureFailure: Error {
    case setup(String)
    case assertion(String)
}

private struct Checks {
    var count = 0
    mutating func expect(_ condition: Bool, _ label: String) throws {
        count += 1
        if !condition { throw FixtureFailure.assertion(label) }
    }
}

private struct Row: Equatable, Sendable {
    let tag: Int
    let key: String
    let timestamp: String?
}

@main
private enum ContinueWatchingPreferencesSourceUnit {
    private static let now = Date(timeIntervalSince1970: 1_791_504_000)
    private static let rows = [
        Row(tag: 0, key: "z", timestamp: nil),
        Row(tag: 1, key: "b", timestamp: "2026-10-09T00:00:00Z"),
        Row(tag: 2, key: "a", timestamp: "2026-10-09T00:00:00Z"),
        Row(tag: 3, key: "a", timestamp: "2026-10-09T00:00:00Z"),
        Row(tag: 4, key: "edge", timestamp: "2026-07-11T00:00:00Z"),
        Row(tag: 5, key: "old", timestamp: "2026-07-10T23:59:59Z"),
        Row(tag: 6, key: "future", timestamp: "2026-10-09T00:00:01Z"),
        Row(tag: 7, key: "invalid", timestamp: "not-a-date"),
        Row(tag: 8, key: "fraction", timestamp: "2026-10-09T00:00:00.125Z")
    ]

    // Test-only original comparator/filter oracle. It calls the actual unchanged parser.
    private static func legacyBounded(_ items: [Row], window: ContinueWatchingWindow) -> [Row] {
        let ordered = items.enumerated().sorted { a, b in
            let lhs = ContinueWatchingPreferences.activity(a.element.timestamp)
            let rhs = ContinueWatchingPreferences.activity(b.element.timestamp)
            if lhs != rhs { return (lhs ?? .distantPast) > (rhs ?? .distantPast) }
            let left = a.element.key, right = b.element.key
            return left == right ? a.offset < b.offset : left < right
        }.map(\.element)
        if let cap = window.cap { return Array(ordered.prefix(cap)) }
        let cutoff = now.addingTimeInterval(-90 * 24 * 60 * 60)
        return ordered.filter {
            $0.timestamp.flatMap(ContinueWatchingPreferences.activity).map { $0 >= cutoff && $0 <= now } ?? false
        }
    }

    private static func bounded(_ input: [Row], _ window: ContinueWatchingWindow) -> [Row] {
        ContinueWatchingPreferences.bounded(input, window: window, now: now,
            activity: { $0.timestamp }, identity: { $0.key })
    }

    private static func choices(_ checks: inout Checks) throws {
        guard let defaults = UserDefaults(suiteName: "tv.vortx.fixture.cwpreferences." + UUID().uuidString) else {
            throw FixtureFailure.setup("unique defaults suite unavailable")
        }
        let sourceKey = ContinueWatchingPreferences.sourceKey, windowKey = ContinueWatchingPreferences.windowKey
        let domain = UserDefaults.argumentDomain
        let prior = defaults.volatileDomain(forName: domain)
        defer { defaults.setVolatileDomain(prior, forName: domain) }
        func install(_ source: String?, _ window: String?) throws {
            var arguments = prior
            if let source { arguments[sourceKey] = source } else { arguments.removeValue(forKey: sourceKey) }
            if let window { arguments[windowKey] = window } else { arguments.removeValue(forKey: windowKey) }
            defaults.setVolatileDomain(arguments, forName: domain)
            guard defaults.string(forKey: sourceKey) == source, defaults.string(forKey: windowKey) == window else {
                throw FixtureFailure.setup("volatile defaults lookup did not match the requested inputs")
            }
        }
        try install("local", "20")
        try checks.expect(ContinueWatchingPreferences.current(defaults) == .init(source: .local, window: .twenty), "isolated current values")
        let originalEpoch = ContinueWatchingPreferences.selectionEpoch
        var callbacks = 0
        let same = ContinueWatchingPreferences.writeUserChoice("local", forKey: sourceKey, defaults: defaults) { callbacks += 1 }
        try checks.expect(!same && callbacks == 0 && ContinueWatchingPreferences.selectionEpoch == originalEpoch, "same source is no-op")
        let invalid = ContinueWatchingPreferences.writeUserChoice("trakt", forKey: "fixture.invalid-key", defaults: defaults) { callbacks += 1 }
        try checks.expect(!invalid && callbacks == 0 && ContinueWatchingPreferences.selectionEpoch == originalEpoch, "invalid key is no-op")
        try install(nil, nil) // Missing-key assumptions are SETUP-checked, not inferred from a unique name.
        let defaultSource = ContinueWatchingPreferences.writeUserChoice("local", forKey: sourceKey, defaults: defaults) { callbacks += 1 }
        try checks.expect(!defaultSource && callbacks == 0 && ContinueWatchingPreferences.selectionEpoch == originalEpoch, "missing source fallback is no-op")
        let defaultWindow = ContinueWatchingPreferences.writeUserChoice("20", forKey: windowKey, defaults: defaults) { callbacks += 1 }
        try checks.expect(!defaultWindow && callbacks == 0 && ContinueWatchingPreferences.selectionEpoch == originalEpoch, "missing window fallback is no-op")
        try install("unsupported", "999")
        let unsupported = ContinueWatchingPreferences.current(defaults)
        try checks.expect(!unsupported.isSupported && unsupported.source == .local && unsupported.window == .twenty, "unsupported source remains unavailable")
        try install("local", "20")
        let before = ContinueWatchingPreferences.selectionEpoch
        var observedBeforeCallbackRetirement = false
        let changed = ContinueWatchingPreferences.writeUserChoice("trakt", forKey: sourceKey, defaults: defaults) {
            callbacks += 1
            observedBeforeCallbackRetirement = ContinueWatchingPreferences.selectionEpoch == before &+ 1
            ContinueWatchingPreferences.retireSelection() // Must be legal outside the production lock.
        }
        try checks.expect(changed, "changed source accepted")
        try checks.expect(callbacks == 1 && observedBeforeCallbackRetirement, "exactly-once callback observes prior retirement")
        try checks.expect(ContinueWatchingPreferences.selectionEpoch == before &+ 2, "callback may reenter retirement")
        try checks.expect(defaults.string(forKey: sourceKey) == "local", "production delegates writes to its callback")
        let windowEpoch = ContinueWatchingPreferences.selectionEpoch
        let changedWindow = ContinueWatchingPreferences.writeUserChoice("40", forKey: windowKey, defaults: defaults) { callbacks += 1 }
        try checks.expect(changedWindow && callbacks == 2 && ContinueWatchingPreferences.selectionEpoch == windowEpoch &+ 1, "changed window retires and calls once")
    }

    private static func decoratedKeys(_ checks: inout Checks) throws {
        print("start group=decorated-keys")
        let many = (0..<120).reversed().map {
            Row(tag: 100 + $0, key: String(1000 + ($0 % 17)), timestamp: rows[$0 % rows.count].timestamp)
        }
        let corpora: [(String, [Row])] = [
            ("empty", []), ("singleton", [rows[1]]), ("mixed9", rows), ("rows120", many)
        ]
        for (name, input) in corpora {
            for window in ContinueWatchingWindow.allCases {
                // Observational counters never affect the stable value returned by either key closure.
                var activityCalls = 0, identityCalls = 0
                let actual = ContinueWatchingPreferences.bounded(input, window: window, now: now,
                    activity: { row in activityCalls += 1; return row.timestamp },
                    identity: { row in identityCalls += 1; return row.key })
                let label = "corpus=\(name) window=\(window.rawValue)"
                print("keys \(label) rows=\(input.count) activity=\(activityCalls) identity=\(identityCalls)")
                try checks.expect(activityCalls == input.count, "one activity key per row \(label)")
                try checks.expect(identityCalls == input.count, "one identity key per row \(label)")
                try checks.expect(actual == legacyBounded(input, window: window), "complete original output \(label)")
            }
        }
        print("pass group=decorated-keys")
    }

    private static func run() async throws {
        var checks = Checks()
        print("start group=values")
        try checks.expect(ContinueWatchingPreferences.sourceKey == "vortx.home.continueWatching.source" && ContinueWatchingPreferences.windowKey == "vortx.home.continueWatching.window", "legacy keys")
        try checks.expect(ContinueWatchingPreferences.changedNote.rawValue == "vortx.home.continueWatching.preferenceChanged", "notification identity")
        try checks.expect(ContinueWatchingService.allCases.map(\.rawValue) == ["local", "trakt", "simkl"], "service order")
        try checks.expect(ContinueWatchingService.allCases.map(\.isPrivate) == [false, true, true], "private services")
        try checks.expect(ContinueWatchingWindow.allCases.map(\.cap) == [nil, 20, 40, 60, 80, 100], "window caps")
        try checks.expect(ContinueWatchingPreferences.value(source: nil, window: nil) == .init(source: .local, window: .twenty), "missing value defaults")
        let bad = ContinueWatchingPreferences.value(source: "invalid", window: "invalid")
        try checks.expect(!bad.isSupported && bad.source == .local && bad.window == .twenty, "unknown values")
        try checks.expect(ContinueWatchingPreferences.value(source: "simkl", window: "last90Days") == .init(source: .simkl, window: .last90Days), "supported values")
        print("pass group=values")

        print("start group=epoch")
        let captured = ContinueWatchingPreferences.selectionEpoch
        try checks.expect(ContinueWatchingPreferences.selectionEpoch == captured, "read does not retire")
        ContinueWatchingPreferences.retireSelection()
        try checks.expect(ContinueWatchingPreferences.selectionEpoch == captured &+ 1, "one retirement")
        ContinueWatchingPreferences.retireSelection()
        try checks.expect(ContinueWatchingPreferences.selectionEpoch == captured &+ 2 && ContinueWatchingPreferences.selectionEpoch != captured, "two transitions reject captured epoch")
        print("pass group=epoch")

        print("start group=choices")
        try choices(&checks)
        print("pass group=choices")

        print("start group=dates")
        try checks.expect(ContinueWatchingPreferences.activity(nil) == nil, "nil activity")
        try checks.expect(ContinueWatchingPreferences.activity("not-a-date") == nil, "invalid activity")
        try checks.expect(ContinueWatchingPreferences.activity("2026-10-09T00:00:00Z") == now, "plain date")
        try checks.expect(ContinueWatchingPreferences.activity("2026-10-09T00:00:00.125Z") == now.addingTimeInterval(0.125), "fractional date")
        try checks.expect(ContinueWatchingPreferences.activity("2026-10-09T01:00:00+01:00") == now, "offset-equivalent date")
        print("pass group=dates")

        print("start group=windows")
        try checks.expect(bounded([], .twenty).isEmpty, "empty input")
        try checks.expect(bounded([rows[0]], .last90Days).isEmpty, "unknown singleton excluded from dated window")
        try checks.expect(bounded(rows, .twenty).map(\.tag) == [6, 8, 2, 3, 1, 4, 5, 7, 0], "exact date identity and input-offset order")
        try checks.expect(bounded(rows, .last90Days).map(\.tag) == [2, 3, 1, 4], "inclusive boundary excludes old future fractional-future and unknown")
        try checks.expect(bounded([rows[3], rows[2]], .twenty).map(\.tag) == [3, 2], "equal keys retain input offset")
        let many = (0..<120).reversed().map { Row(tag: $0, key: String(1000 + $0), timestamp: nil) }
        for window in ContinueWatchingWindow.allCases where window.cap != nil {
            let result = bounded(many, window)
            try checks.expect(result.map(\.tag) == Array(0..<window.cap!), "complete cap \(window.rawValue)")
        }
        print("pass group=windows")

        print("start group=legacy-oracle")
        let ancient = [Row(tag: 20, key: "early", timestamp: "0001-01-01T00:00:00Z"),
                       Row(tag: 21, key: "nil", timestamp: nil),
                       Row(tag: 22, key: "offset", timestamp: "2026-10-09T01:00:00+01:00")]
        for (index, input) in [rows, Array(rows.reversed()), ancient].enumerated() {
            for window in ContinueWatchingWindow.allCases {
                try checks.expect(bounded(input, window) == legacyBounded(input, window: window), "legacy comparator and filter equality corpus=\(index) window=\(window.rawValue)")
            }
        }
        print("pass group=legacy-oracle")

        print("start group=concurrent-epoch")
        let initial = ContinueWatchingPreferences.selectionEpoch
        let outcome = await withTaskGroup(of: Bool.self, returning: (Int, Bool).self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<64 {
                        let before = ContinueWatchingPreferences.selectionEpoch
                        ContinueWatchingPreferences.retireSelection()
                        let delta = ContinueWatchingPreferences.selectionEpoch &- before
                        if delta == 0 || delta > 512 { return false }
                    }
                    return true
                }
            }
            var finished = 0, valid = true
            for await result in group { finished += 1; valid = result && valid }
            return (finished, valid)
        }
        try checks.expect(outcome.0 == 8, "all eight workers joined")
        try checks.expect(outcome.1, "worker reads observe bounded retirement progress")
        try checks.expect(ContinueWatchingPreferences.selectionEpoch == initial &+ 512, "exact final concurrent retirement count")
        print("pass group=concurrent-epoch")
        guard checks.count == 58 else { throw FixtureFailure.setup("assertion accounting changed: \(checks.count)") }
        print("ContinueWatchingPreferences Swift6 production source unit: 7/7 groups, 58 assertions passed")
        try decoratedKeys(&checks)
        guard checks.count == 130 else { throw FixtureFailure.setup("v2 assertion accounting changed: \(checks.count)") }
        print("ContinueWatchingPreferences Swift6 production source unit: 8/8 groups, 130 assertions passed")
    }

    static func main() async {
        do { try await run() }
        catch FixtureFailure.setup(let message) { print("SETUP: \(message)"); exit(2) }
        catch FixtureFailure.assertion(let message) { print("FAIL: \(message)"); exit(1) }
        catch { print("SETUP: unexpected fixture error \(error)"); exit(2) }
    }
}
