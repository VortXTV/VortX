// Standalone executable for the Apple Search submission/coalescing source contract.
//
// This is the lightweight model/source-contract suite. It is not the production extraction
// gate. Run scripts/test-apple-search-submission.sh for the mechanically extracted closures
// and methods from app/SourcesiOS/iOSRootView.swift.
//
//   mkdir -p app/build && xcrun swiftc -parse-as-library -o app/build/apple-search-submission-model \
//     app/Tests/AppleSearchSubmissionContractTests.swift && \
//     app/build/apple-search-submission-model
//
// The CoreSpy flow below is an inert model of the production query-change, suggestion-submit,
// empty-query, and top-bar handoff closures. It deliberately models the engine's `search` as one
// Load + LoadRange-equivalent pair, so the regression is observable without CoreBridge, SwiftUI,
// the native engine, or a device. The legacy handoff is kept only as a RED proof: it mutates the
// bound query, submits immediately, then lets the ordinary onChange debounce submit again.

import Foundation

private enum CoreCall: Equatable {
    case prepare(String)
    case suggest(String)
    case search(String)
}

private final class CoreSpy {
    private(set) var calls: [CoreCall] = []
    private(set) var loadRangeEquivalentCount = 0

    func prepareSearch(_ query: String) { calls.append(.prepare(query)) }
    func suggestSearch(_ query: String) { calls.append(.suggest(query)) }
    func search(_ query: String) {
        calls.append(.search(query))
        loadRangeEquivalentCount += 2
    }

    var searches: [String] {
        calls.compactMap { call in
            guard case let .search(query) = call else { return nil }
            return query
        }
    }

    func reset() {
        calls.removeAll()
        loadRangeEquivalentCount = 0
    }
}

/// Mirrors both Apple surfaces' state and closures. `surface` only selects the production method name
/// represented by the delayed path; the handoff/suggestion behavior is intentionally shared by both.
private final class SearchSubmissionCoreSpy {
    enum Surface { case dedicatedSearch, mergedDiscover }

    let core = CoreSpy()
    let surface: Surface
    private(set) var query = ""
    private(set) var submittedSuggestion: String?
    private var delayedSearch: (() -> Void)?

    init(_ surface: Surface) { self.surface = surface }

    /// Exact ordinary `.onChange` shape from iOSSearchView, with the merged Discover branch's
    /// `mergeDiscoverSearch` gate represented by the surface itself.
    private func queryDidChange(_ value: String) {
        query = value
        let alreadySubmitted = submittedSuggestion == value
        submittedSuggestion = nil
        if alreadySubmitted { return }
        if surface == .dedicatedSearch { scheduleSearch(value) }
        else { scheduleMergedSearch(value) }
    }

    func type(_ value: String) {
        guard value != query else { return }
        queryDidChange(value)
    }

    /// The ordinary debounced dedicated Search closure.
    private func scheduleSearch(_ value: String) {
        delayedSearch = nil
        let q = value.trimmingCharacters(in: .whitespaces)
        core.prepareSearch(q)
        core.suggestSearch(q)
        guard !q.isEmpty else { core.search(""); return }
        delayedSearch = { [weak self] in
            guard let self else { return }
            self.core.search(q)
        }
    }

    /// The ordinary debounced merged Discover closure.
    private func scheduleMergedSearch(_ value: String) {
        delayedSearch = nil
        let q = value.trimmingCharacters(in: .whitespaces)
        core.prepareSearch(q)
        core.suggestSearch(q)
        guard !q.isEmpty else { core.search(""); return }
        delayedSearch = { [weak self] in
            guard let self else { return }
            self.core.search(q)
        }
    }

    /// Immediate dedicated Search submission, including suggestion selection and the explicit empty
    /// submit path. This is the same cancellation + suggest + search sequence used by production.
    private func submitTouchSearch(_ submittedQuery: String? = nil) {
        let value = (submittedQuery ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        delayedSearch = nil
        core.suggestSearch(value)
        core.search(value)
    }

    /// Immediate merged Discover submission, including explicit field submit and top-bar handoff.
    private func submitMergedSearch(_ submittedQuery: String? = nil) {
        let value = (submittedQuery ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        delayedSearch = nil
        core.suggestSearch(value)
        core.search(value)
    }

    /// Corrected `MacSearchBridge.$pending` closure. SwiftUI delivers onChange only when the bound
    /// value actually changes; the stamp therefore exists only for that real mutation and is consumed
    /// by the onChange callback below. A same-query repeat directly submits with no residual stamp.
    func receiveTopBar(_ pending: String) {
        delayedSearch = nil
        let q = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = query != q
        if changed {
            submittedSuggestion = q
            query = q
        } else {
            submittedSuggestion = nil
        }
        if surface == .dedicatedSearch { submitTouchSearch(q) }
        else { submitMergedSearch(q) }
        if changed { queryDidChange(query) }
    }

    /// Original broken handoff, retained to prove the regression before the corrected flow.
    func receiveTopBarLegacy(_ pending: String) {
        delayedSearch = nil
        let q = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        query = q
        if surface == .dedicatedSearch {
            core.suggestSearch(q)
            core.search(q)
        } else {
            core.suggestSearch(q)
            core.search(q)
        }
        // The state mutation above is followed by the ordinary onChange callback.
        queryDidChange(query)
    }

    func selectSuggestion(_ title: String) {
        submittedSuggestion = title == query ? nil : title
        query = title
        if surface == .dedicatedSearch { submitTouchSearch(title) }
        else { submitMergedSearch(title) }
        if submittedSuggestion != nil { queryDidChange(query) }
    }

    func flushDebounce() {
        let pending = delayedSearch
        delayedSearch = nil
        pending?()
    }
}

private final class SuggestionsRefreshSpy {
    private var refreshScheduled = false
    private var queued: [() -> Void] = []
    var binding = "initial-core"
    var query = "initial-query"
    private(set) var refreshCount = 0
    private(set) var refreshedSnapshots: [(binding: String, query: String)] = []

    /// Inert model of AppleSearchPresentation.scheduleSuggestionsRefresh. The queued closure reads
    /// `binding` and `query` at execution time, matching production's current-owner/current-query rule.
    func scheduleSuggestionsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        queued.append { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshSuggestions()
        }
    }

    private func refreshSuggestions() {
        refreshCount += 1
        refreshedSnapshots.append((binding, query))
    }

    func drainRunLoop() {
        while !queued.isEmpty { queued.removeFirst()() }
    }
}

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { print("PASS  \(name)") }
    else { failures += 1; print("FAIL  \(name)") }
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func source(_ relativePath: String) -> String {
    let url = repositoryRoot.appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func slice(_ text: String, from start: String, to end: String) -> String {
    guard let lower = text.range(of: start),
          let upper = text.range(of: end, range: lower.upperBound..<text.endIndex) else { return "" }
    return String(text[lower.lowerBound..<upper.lowerBound])
}

private func containsInOrder(_ text: String, _ needles: [String]) -> Bool {
    var cursor = text.startIndex
    for needle in needles {
        guard let match = text.range(of: needle, range: cursor..<text.endIndex) else { return false }
        cursor = match.upperBound
    }
    return true
}

@main
enum AppleSearchSubmissionContractTests {
    static func main() {
        // MARK: RED proof and corrected GREEN flow for both surfaces

        for surface in [SearchSubmissionCoreSpy.Surface.dedicatedSearch,
                        SearchSubmissionCoreSpy.Surface.mergedDiscover] {
            let label = surface == .dedicatedSearch ? "Search" : "merged Discover"
            let legacy = SearchSubmissionCoreSpy(surface)
            legacy.receiveTopBarLegacy("Dune")
            legacy.flushDebounce()
            expect(legacy.core.searches == ["Dune", "Dune"],
                   "RED " + label + ": legacy handoff submits twice")
            expect(legacy.core.loadRangeEquivalentCount == 4,
                   "RED " + label + ": legacy handoff duplicates Load+LoadRange")

            let flow = SearchSubmissionCoreSpy(surface)
            flow.receiveTopBar("Dune")
            flow.flushDebounce()
            expect(flow.core.searches == ["Dune"],
                   "GREEN " + label + ": changed top-bar handoff submits exactly once")
            expect(flow.core.loadRangeEquivalentCount == 2,
                   "GREEN " + label + ": changed handoff has one Load+LoadRange")

            flow.receiveTopBar("Dune")
            flow.flushDebounce()
            expect(flow.core.searches == ["Dune", "Dune"],
                   "GREEN " + label + ": same-query repeat still submits exactly once")
            expect(flow.submittedSuggestion == nil,
                   "GREEN " + label + ": same-query repeat leaves no onChange stamp")

            flow.type("Dune ")
            flow.flushDebounce()
            expect(flow.core.searches.last == "Dune",
                   "GREEN " + label + ": normal typing remains debounced after same-query handoff")
            expect(flow.core.searches.count == 3,
                   "GREEN " + label + ": normal typing adds one search, not a duplicate")

            flow.selectSuggestion("Dune 2")
            flow.flushDebounce()
            expect(flow.core.searches.last == "Dune 2" && flow.core.searches.count == 4,
                   "GREEN " + label + ": suggestion selection submits once")

            flow.type("")
            flow.flushDebounce()
            expect(flow.core.searches.last == "" && flow.core.searches.count == 5,
                   "GREEN " + label + ": empty input submits once and clears the engine")

            flow.type("A")
            flow.type("AB")
            flow.flushDebounce()
            expect(flow.core.searches.last == "AB" && flow.core.searches.count == 6,
                   "GREEN " + label + ": rapid A-to-B cancels the stale debounce")
            expect(flow.core.searches.filter { $0 == "A" }.isEmpty,
                   "GREEN " + label + ": rapid A-to-B never searches stale A")
        }

        // MARK: one run-loop refresh for a publication burst, current owner/query preserved

        let refresh = SuggestionsRefreshSpy()
        refresh.scheduleSuggestionsRefresh() // results
        refresh.scheduleSuggestionsRefresh() // suggestions
        refresh.scheduleSuggestionsRefresh() // Continue Watching
        refresh.scheduleSuggestionsRefresh() // board
        refresh.binding = "new-core"
        refresh.query = "new-query"
        refresh.drainRunLoop()
        expect(refresh.refreshCount == 1, "GREEN presentation: a burst coalesces to one refresh")
        expect(refresh.refreshedSnapshots.first?.binding == "new-core"
            && refresh.refreshedSnapshots.first?.query == "new-query",
               "GREEN presentation: the coalesced refresh uses current binding/query")
        refresh.scheduleSuggestionsRefresh()
        refresh.drainRunLoop()
        expect(refresh.refreshCount == 2, "GREEN presentation: a later run-loop gets a fresh refresh")

        // MARK: production source contract

        let root = source("SourcesiOS/iOSRootView.swift")
        let search = slice(root, from: "struct iOSSearchView: View {", to: "struct iOSDiscoverView: View {")
        let discover = slice(root, from: "struct iOSDiscoverView: View {", to: "// MARK: Advanced filters")
        let presentation = slice(root, from: "final class AppleSearchPresentation: ObservableObject {", to: "/// Search across every installed add-on")
        let searchHandoff = slice(search, from: ".onReceive(MacSearchBridge.shared.$pending)", to: "#endif")
        let searchQueryChange = slice(search, from: ".onChange(of: query) { value in", to: "#if os(iOS)")
        let discoverHandoff = slice(discover, from: ".onReceive(MacSearchBridge.shared.$pending)", to: "#endif")
        let discoverQueryChange = slice(discover, from: ".onChange(of: searchQuery) { value in", to: ".onChange(of: mergeDiscoverSearch)")
        expect(!search.isEmpty && !discover.isEmpty && !presentation.isEmpty,
               "source: Search, merged Discover, and presentation anchors are readable")
        expect(containsInOrder(searchHandoff, [
            "if query != q", "submittedSuggestion = q", "query = q", "submittedSuggestion = nil", "submitTouchSearch(q)"
        ]) && !searchHandoff.contains("core.search(q)"),
               "source: dedicated handoff stamps only changed values then uses one submit path")
        expect(containsInOrder(discoverHandoff, [
            "if searchQuery != q", "submittedSuggestion = q", "searchQuery = q", "submittedSuggestion = nil", "submitMergedSearch(q)"
        ]) && !discoverHandoff.contains("core.search(q)"),
               "source: merged handoff stamps only changed values then uses one submit path")
        expect(containsInOrder(searchQueryChange, [
            "let alreadySubmitted = submittedSuggestion == value",
            "submittedSuggestion = nil",
            "if alreadySubmitted { return }",
            "scheduleSearch(value)"
        ]), "source: dedicated onChange consumes only its actual-value handoff stamp")
        expect(containsInOrder(discoverQueryChange, [
            "let alreadySubmitted = submittedSuggestion == value",
            "submittedSuggestion = nil",
            "if mergeDiscoverSearch, !alreadySubmitted { scheduleMergedSearch(value) }"
        ]), "source: merged onChange consumes only its actual-value handoff stamp")
        expect(presentation.contains("private var suggestionsRefreshScheduled = false")
            && presentation.contains("guard !suggestionsRefreshScheduled else { return }")
            && presentation.contains("self.suggestionsRefreshScheduled = false"),
               "source: presentation refresh is one-shot per run-loop and re-arms afterward")
        expect(source("SourcesShared/CoreBridge.swift").contains("final class CoreSearchPublicationFence"),
               "scope: current search publication fence remains owned by CoreBridge")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
