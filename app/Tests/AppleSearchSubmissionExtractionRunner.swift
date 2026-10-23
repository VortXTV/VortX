import Darwin
import Foundation

@MainActor
final class SearchCoreSpy {
    private(set) var searches: [String] = []
    private(set) var calls: [String] = []
    private(set) var loadRangeEquivalentCount = 0

    func prepareSearch(_ query: String) { calls.append("prepare:\(query)") }
    func suggestSearch(_ query: String) { calls.append("suggest:\(query)") }
    func search(_ query: String) {
        calls.append("search:\(query)")
        searches.append(query)
        loadRangeEquivalentCount += 2
    }
}
@MainActor
final class MacSearchBridge {
    static let shared = MacSearchBridge()
    var pending: String?
}

@MainActor
final class SearchPresentationSpy {
    private var query = ""
    private var suggestionsRefreshScheduled = false
    private(set) var refreshCount = 0
    private(set) var refreshSnapshots: [String] = []
    private var bindingID = "initial-binding"

    func setCurrentBindingForTest(_ binding: String) { bindingID = binding }
    func setCurrentQueryForTest(_ query: String) { self.query = query }
    func scheduleRefreshForTest() { scheduleSuggestionsRefresh() }

    private func refreshSuggestions() {
        refreshCount += 1
        refreshSnapshots.append("\(bindingID)|\(query)")
    }

    /*__SET_QUERY__*/
    /*__SCHEDULE_SUGGESTIONS_REFRESH__*/
}

@MainActor
final class ExtractedSearchSurface {
    let core = SearchCoreSpy()
    let searchPresentation = SearchPresentationSpy()
    var query = ""
    var searchQuery = ""
    var submittedSuggestion: String?
    var searchTask: Task<Void, Never>?
    var searchDebouncePending = false
    var mergeDiscoverSearch = true
    var macInlineSearchFocused = false

    /*__SUBMIT_TOUCH_SEARCH__*/
    /*__SCHEDULE_SEARCH__*/
    /*__SUBMIT_MERGED_SEARCH__*/
    /*__SCHEDULE_MERGED_SEARCH__*/

    func submitTouchSearchForTest(_ value: String) { submitTouchSearch(value) }
    func submitMergedSearchForTest(_ value: String) { submitMergedSearch(value) }

    func receiveDedicatedPending(_ pending: String?) {
        /*__DEDICATED_HANDOFF_BODY__*/
    }

    func dedicatedQueryDidChange(_ value: String) {
        /*__DEDICATED_CHANGE_BODY__*/
    }

    func receiveMergedPending(_ pending: String?) {
        /*__MERGED_HANDOFF_BODY__*/
    }

    func mergedQueryDidChange(_ value: String) {
        /*__MERGED_CHANGE_BODY__*/
    }
}

@MainActor
@main
enum AppleSearchSubmissionExtractionRunner {
    private static func fail(_ message: String) -> Never {
        print("FAIL \(message)")
        exit(1)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fail(message) }
    }

    private static func settleDebounce() async {
        try? await Task.sleep(for: .milliseconds(450))
        await Task.yield()
    }

    private static func settleMainQueue() async {
        try? await Task.sleep(for: .milliseconds(30))
        await Task.yield()
    }

    private static func deliverDedicated(_ surface: ExtractedSearchSurface, _ value: String) {
        let previous = surface.query
        surface.receiveDedicatedPending(value)
        if surface.query != previous { surface.dedicatedQueryDidChange(surface.query) }
    }

    private static func deliverMerged(_ surface: ExtractedSearchSurface, _ value: String) {
        let previous = surface.searchQuery
        surface.receiveMergedPending(value)
        if surface.searchQuery != previous { surface.mergedQueryDidChange(surface.searchQuery) }
    }

    private static func runDedicatedTests(baseline: Bool) async {
        let surface = ExtractedSearchSurface()
        deliverDedicated(surface, "Foundation")
        await settleDebounce()
        let firstHandoffCount = surface.core.searches.count
        let expectedFirstHandoff = baseline ? 2 : 1
        require(firstHandoffCount == expectedFirstHandoff,
                "dedicated one-handoff expected \(expectedFirstHandoff), got \(firstHandoffCount)")
        require(surface.core.loadRangeEquivalentCount == expectedFirstHandoff * 2,
                "dedicated one-handoff Load + LoadRange equivalent count changed")
        print(baseline ? "BASELINE RED dedicated one-handoff searches=\(firstHandoffCount)" :
              "GREEN dedicated one-handoff searches=\(firstHandoffCount)")

        deliverDedicated(surface, "Foundation")
        require(surface.submittedSuggestion == nil,
                "dedicated same-query handoff left a stale submittedSuggestion stamp")
        await settleDebounce()
        require(surface.core.searches.count == expectedFirstHandoff + 1,
                "dedicated same-query repeat did not add exactly one search")
        require(surface.core.loadRangeEquivalentCount == (expectedFirstHandoff + 1) * 2,
                "dedicated same-query repeat Load + LoadRange equivalent count changed")
        print("\(baseline ? "BASELINE RED" : "GREEN") dedicated same-query repeat searches=\(surface.core.searches.count)")

        let searchesBeforeFollowUp = surface.core.searches.count
        surface.dedicatedQueryDidChange("Foundation-follow-up")
        await settleDebounce()
        require(surface.core.searches.count == searchesBeforeFollowUp + 1,
                "dedicated same-query follow-up did not add exactly one search")
        require(surface.core.searches.last == "Foundation-follow-up",
                "dedicated same-query follow-up searched the wrong value")
        print("\(baseline ? "BASELINE RED" : "GREEN") dedicated same-query follow-up searches=\(surface.core.searches.count)")

        let typed = ExtractedSearchSurface()
        typed.dedicatedQueryDidChange("ab")
        await settleDebounce()
        require(typed.core.searches == ["ab"], "dedicated ordinary change did not debounce once")
        print("\(baseline ? "BASELINE RED" : "GREEN") dedicated ordinary change searches=1")

        let rapid = ExtractedSearchSurface()
        rapid.dedicatedQueryDidChange("a")
        rapid.dedicatedQueryDidChange("ab")
        await settleDebounce()
        require(rapid.core.searches == ["ab"], "dedicated rapid A-to-B was not cancelled")
        print("\(baseline ? "BASELINE RED" : "GREEN") dedicated rapid A-to-B searches=[ab]")

        let empty = ExtractedSearchSurface()
        empty.dedicatedQueryDidChange("")
        await settleDebounce()
        require(empty.core.searches == [""], "dedicated empty query did not search exactly once")
        print("\(baseline ? "BASELINE RED" : "GREEN") dedicated empty searches=1")

        let ignoredPending = ExtractedSearchSurface()
        ignoredPending.receiveDedicatedPending(nil)
        ignoredPending.receiveDedicatedPending("")
        require(ignoredPending.core.searches.isEmpty, "dedicated nil/empty handoff was not ignored")
        print("\(baseline ? "BASELINE RED" : "GREEN") dedicated nil-empty handoff searches=0")

        let suggestion = ExtractedSearchSurface()
        suggestion.submittedSuggestion = "Foundation"
        suggestion.query = "Foundation"
        suggestion.submitTouchSearchForTest("Foundation")
        suggestion.dedicatedQueryDidChange("Foundation")
        await settleDebounce()
        require(suggestion.core.searches == ["Foundation"], "dedicated suggestion submitted twice")
        print("\(baseline ? "BASELINE RED" : "GREEN") dedicated suggestion searches=1")
        surface.searchTask?.cancel()
        typed.searchTask?.cancel()
        rapid.searchTask?.cancel()
        empty.searchTask?.cancel()
        suggestion.searchTask?.cancel()
    }

    private static func runMergedTests(baseline: Bool) async {
        let surface = ExtractedSearchSurface()
        deliverMerged(surface, "Foundation")
        await settleDebounce()
        let firstHandoffCount = surface.core.searches.count
        let expectedFirstHandoff = baseline ? 2 : 1
        require(firstHandoffCount == expectedFirstHandoff,
                "merged one-handoff expected \(expectedFirstHandoff), got \(firstHandoffCount)")
        require(surface.core.loadRangeEquivalentCount == expectedFirstHandoff * 2,
                "merged one-handoff Load + LoadRange equivalent count changed")
        print(baseline ? "BASELINE RED merged one-handoff searches=\(firstHandoffCount)" :
              "GREEN merged one-handoff searches=\(firstHandoffCount)")

        deliverMerged(surface, "Foundation")
        require(surface.submittedSuggestion == nil,
                "merged same-query handoff left a stale submittedSuggestion stamp")
        await settleDebounce()
        require(surface.core.searches.count == expectedFirstHandoff + 1,
                "merged same-query repeat did not add exactly one search")
        require(surface.core.loadRangeEquivalentCount == (expectedFirstHandoff + 1) * 2,
                "merged same-query repeat Load + LoadRange equivalent count changed")
        print("\(baseline ? "BASELINE RED" : "GREEN") merged same-query repeat searches=\(surface.core.searches.count)")

        let searchesBeforeFollowUp = surface.core.searches.count
        surface.mergedQueryDidChange("Foundation-follow-up")
        await settleDebounce()
        require(surface.core.searches.count == searchesBeforeFollowUp + 1,
                "merged same-query follow-up did not add exactly one search")
        require(surface.core.searches.last == "Foundation-follow-up",
                "merged same-query follow-up searched the wrong value")
        print("\(baseline ? "BASELINE RED" : "GREEN") merged same-query follow-up searches=\(surface.core.searches.count)")

        let typed = ExtractedSearchSurface()
        typed.mergedQueryDidChange("ab")
        await settleDebounce()
        require(typed.core.searches == ["ab"], "merged ordinary change did not debounce once")
        print("\(baseline ? "BASELINE RED" : "GREEN") merged ordinary change searches=1")

        let rapid = ExtractedSearchSurface()
        rapid.mergedQueryDidChange("a")
        rapid.mergedQueryDidChange("ab")
        await settleDebounce()
        require(rapid.core.searches == ["ab"], "merged rapid A-to-B was not cancelled")
        print("\(baseline ? "BASELINE RED" : "GREEN") merged rapid A-to-B searches=[ab]")

        let empty = ExtractedSearchSurface()
        empty.mergedQueryDidChange("")
        await settleDebounce()
        require(empty.core.searches == [""], "merged empty query did not search exactly once")
        print("\(baseline ? "BASELINE RED" : "GREEN") merged empty searches=1")

        let ignoredPending = ExtractedSearchSurface()
        ignoredPending.receiveMergedPending(nil)
        ignoredPending.receiveMergedPending("")
        require(ignoredPending.core.searches.isEmpty, "merged nil/empty handoff was not ignored")
        print("\(baseline ? "BASELINE RED" : "GREEN") merged nil-empty handoff searches=0")

        let suggestion = ExtractedSearchSurface()
        suggestion.submittedSuggestion = "Foundation"
        suggestion.searchQuery = "Foundation"
        suggestion.submitMergedSearchForTest("Foundation")
        suggestion.mergedQueryDidChange("Foundation")
        await settleDebounce()
        let expectedSuggestionSearches = baseline ? ["Foundation", "Foundation"] : ["Foundation"]
        require(suggestion.core.searches == expectedSuggestionSearches, "merged suggestion submission count changed")
        print("\(baseline ? "BASELINE RED" : "GREEN") merged suggestion searches=\(suggestion.core.searches.count)")
        surface.searchTask?.cancel()
        typed.searchTask?.cancel()
        rapid.searchTask?.cancel()
        empty.searchTask?.cancel()
        suggestion.searchTask?.cancel()
    }

    private static func runPresentationTests(baseline: Bool) async {
        let presentation = SearchPresentationSpy()
        presentation.scheduleRefreshForTest()
        presentation.scheduleRefreshForTest()
        presentation.scheduleRefreshForTest()
        presentation.scheduleRefreshForTest()
        presentation.setCurrentBindingForTest("current-binding")
        presentation.setCurrentQueryForTest("current-query")
        await settleMainQueue()
        let expectedBurst = baseline ? 4 : 1
        require(presentation.refreshCount == expectedBurst,
                "suggestion refresh burst expected \(expectedBurst), got \(presentation.refreshCount)")
        require(presentation.refreshSnapshots.last == "current-binding|current-query",
                "suggestion refresh used stale binding/query")
        print(baseline ? "BASELINE RED burst refreshes=\(presentation.refreshCount) current-binding=current-query" :
              "GREEN burst refreshes=\(presentation.refreshCount) current-binding=current-query")

        presentation.scheduleRefreshForTest()
        await settleMainQueue()
        require(presentation.refreshCount == expectedBurst + 1,
                "suggestion refresh did not schedule a later independent burst")
    }

    static func main() async {
        let baseline = CommandLine.arguments.contains("--baseline")
        await runDedicatedTests(baseline: baseline)
        await runMergedTests(baseline: baseline)
        await runPresentationTests(baseline: baseline)
        print(baseline ? "BASELINE RED extraction exercised legacy duplicate paths" :
              "PASS actual-source Apple Search extraction")
    }
}
