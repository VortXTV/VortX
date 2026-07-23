// AddonPairingReducerTests: a standalone, runnable verification of the tvOS "Install by QR" auto-install
// contract (INS-260722-04) that tests the SHIPPED reducer directly - no mirror.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md), so,
// like app/Tests/HouseholdCryptoTests.swift and QRJoinerFlowTests.swift, this runs with the system toolchain.
// UNLIKE those (which re-implement production logic in a mirror), this COMPILES THE REAL REDUCER FILE and asserts
// against it, so the "auto-install on ready, install exactly once, fail honestly" rules are proven on the exact
// code the app ships - a regression to "still needs a manual tap" would fail this, not slip past a stale copy.
// Because it links a SECOND source file (the real reducer), it is built with swiftc, not run in `swift` immediate
// mode (which compiles only the first file); `-parse-as-library` + `@main` lets the entry point live here:
//
//     swiftc -parse-as-library app/SourcesShared/AddonPairingReducer.swift app/Tests/AddonPairingReducerTests.swift -o /tmp/AddonPairingReducerTests && /tmp/AddonPairingReducerTests
//
// The reducer is pure and Foundation-only precisely so this is possible: the view (AddonPairingView) performs
// the I/O for the reducer's effects, but every DECISION under test lives in AddonPairingReducer, compiled above.

import Foundation

// MARK: - A tiny synchronous host that performs the reducer's effects against a fake engine

/// Executes AddonPairingReducer effects the way AddonPairingView does, but against an in-memory "engine" and
/// synchronously (no network, no Tasks), so one `.delivered` drives the whole resolve → auto-install → done
/// chain to a terminal state in a single call. It records the two things the contract turns on: how many times
/// the hardened installer was DISPATCHED, and whether any MANUAL install event was ever sent.
final class Host {
    var state = AddonPairingReducer.State()

    /// Fake engine: transport identities already installed (an install of one is an idempotent no-op success).
    var installedTransport: Set<String> = []
    /// Raw URLs whose manifest fails validation → resolve `.invalid` (never installs, never a success).
    var invalidURLs: Set<String> = []
    /// Raw URLs whose install fails while NOT already present → `.failed` (manual Retry).
    var installFailURLs: Set<String> = []
    /// identity → resolved add-on name.
    var manifestNames: [String: String] = [:]

    private(set) var installEffectCount = 0     // times `.install` was performed (the "exactly once" metric)
    private(set) var manualInstallDispatched = false

    /// Equivalent of CoreBridge.normalizedAddonURL (the closure the view injects): http(s) only, ensure a
    /// /manifest.json suffix, else nil. This is the reducer's INJECTED input mapper, not the logic under test.
    func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        var s = url.absoluteString
        if !s.lowercased().hasSuffix("manifest.json") {
            if !s.hasSuffix("/") { s += "/" }
            s += "manifest.json"
        }
        return s
    }

    func dispatch(_ event: AddonPairingReducer.Event) {
        if case .manualInstall = event { manualInstallDispatched = true }
        let effects = AddonPairingReducer.reduce(&state, event, normalize: normalize)
        for effect in effects { perform(effect) }
    }

    private func perform(_ effect: AddonPairingReducer.Effect) {
        switch effect {
        case let .resolve(rowId, url):
            let identity = normalize(url) ?? url
            if invalidURLs.contains(url) || invalidURLs.contains(identity) {
                dispatch(.resolved(rowId: rowId, outcome: .invalid))
            } else if installedTransport.contains(identity) {
                dispatch(.resolved(rowId: rowId, outcome: .alreadyInstalled(name: manifestNames[identity] ?? "Add-on")))
            } else {
                dispatch(.resolved(rowId: rowId, outcome: .ready(name: manifestNames[identity] ?? "Add-on")))
            }
        case let .install(rowId, url):
            installEffectCount += 1
            let identity = normalize(url) ?? url
            if installFailURLs.contains(url), !installedTransport.contains(identity) {
                dispatch(.installFinished(rowId: rowId, outcome: .failed("network error")))
            } else {
                installedTransport.insert(identity)   // engine now holds it (idempotent success)
                dispatch(.installFinished(rowId: rowId, outcome: .installed))
            }
        }
    }

    var batch: AddonPairingReducer.BatchStatus { AddonPairingReducer.batchStatus(state.rows.map(\.state)) }
    var done: (title: String, enabled: Bool) { AddonPairingReducer.doneState(batch) }
}

// MARK: - Entry point (swiftc @main, so the real reducer above links into this same binary)

@main
enum AddonPairingReducerTests {
    static var failures = 0
    static func check(_ cond: Bool, _ name: String) {
        if cond { print("  ok   \(name)") }
        else { failures += 1; print("  FAIL \(name)") }
    }

    static func main() {
        print("AddonPairingReducerTests")

        let good = "https://good.example/manifest.json"

// 1. THE CORE CONTRACT: a delivered add-on AUTO-INSTALLS and Done seals the session, with NO manual install
//    event ever dispatched. This is the exact defect the revert cited ("still needed a manual Install tap").
do {
    let h = Host()
    h.manifestNames["https://good.example/manifest.json"] = "Good"
    h.dispatch(.delivered(urls: [good], sessionToken: "S1", liveToken: "S1"))
    check(h.state.rows.count == 1, "auto: one delivery → one row")
    check(h.state.rows[0].state == .installed, "auto: a delivered add-on installs itself (no manual tap)")
    check(h.installEffectCount == 1, "auto: installed exactly once")
    check(h.manualInstallDispatched == false, "auto: NO manual install event was dispatched - it was automatic")
    check(h.done.enabled && h.done.title == "Done", "auto: Done is enabled + 'Done' once the batch is terminal")
    if case .allInstalled(1) = h.batch { check(true, "auto: batch reports allInstalled(1)") }
    else { check(false, "auto: batch should be allInstalled(1)") }
}

// 2. IDEMPOTENT per delivery id: a re-poll re-delivering the SAME url in the same session adds no second row
//    and dispatches no second install.
do {
    let h = Host()
    h.manifestNames["https://good.example/manifest.json"] = "Good"
    h.dispatch(.delivered(urls: [good], sessionToken: "S1", liveToken: "S1"))
    check(h.installEffectCount == 1, "idempotency: first delivery installs once")
    h.dispatch(.delivered(urls: [good], sessionToken: "S1", liveToken: "S1"))   // relay re-delivers (cumulative list)
    check(h.state.rows.count == 1, "idempotency: duplicate delivery adds no second row")
    check(h.installEffectCount == 1, "idempotency: duplicate delivery does not re-install")
}

// 3. ALREADY-INSTALLED is an idempotent success that does NOT install again.
do {
    let h = Host()
    let identity = h.normalize(good)!
    h.installedTransport = [identity]
    h.manifestNames[identity] = "Good"
    h.dispatch(.delivered(urls: [good], sessionToken: "S1", liveToken: "S1"))
    check(h.state.rows[0].state == .installed, "already-installed: resolves straight to installed")
    check(h.installEffectCount == 0, "already-installed: never dispatches an install")
}

// 4. WRONG-SESSION: a delivery whose token is not the live one is refused - no row, no install.
do {
    let h = Host()
    h.dispatch(.delivered(urls: [good], sessionToken: "S-OTHER", liveToken: "S1"))
    check(h.state.rows.isEmpty, "wrong-session: no row created")
    check(h.installEffectCount == 0, "wrong-session: nothing installed")
}

// 5. ROTATION PRUNE: a non-terminal row bound to a now-dead session is dropped on rotation; a terminal row
//    (installed history) is kept. Driven straight through the real reducer.
do {
    var st = AddonPairingReducer.State()
    st.rows = [
        AddonPairingReducer.Row(sessionToken: "S1", url: "https://x/manifest.json", identity: "https://x/manifest.json", name: nil, state: .resolving),
        AddonPairingReducer.Row(sessionToken: "S1", url: good, identity: good, name: "Good", state: .installed),
    ]
    _ = AddonPairingReducer.reduce(&st, .sessionRotated(liveToken: "S2"), normalize: { _ in nil })
    check(st.rows.count == 1, "rotation: the in-flight stale row is pruned")
    check(st.rows[0].state == .installed, "rotation: the terminal row is kept as history")
}

// 6. FAILURE → RECOVERY: an engine install failure lands `.failed` (manual-actionable), and a manual Retry
//    re-dispatches the installer and succeeds. Failure is surfaced honestly, never swallowed as success.
do {
    let flaky = "https://flaky.example/manifest.json"
    let h = Host()
    h.installFailURLs = [flaky]
    h.manifestNames[h.normalize(flaky)!] = "Flaky"
    h.dispatch(.delivered(urls: [flaky], sessionToken: "S1", liveToken: "S1"))
    check(h.state.rows[0].state == .failed("network error"), "failure: a failed install lands .failed with the message")
    check(h.state.rows[0].state.isManualActionable, "failure: a failed row is manual-actionable (focusable Retry)")
    check(h.installEffectCount == 1, "failure: the auto-install was attempted once")
    if case .partial(let i, let f, let inv) = h.batch { check(i == 0 && f == 1 && inv == 0, "failure: batch is partial (1 failed), NOT allInstalled") }
    else { check(false, "failure: batch should be partial") }
    // User taps Retry; the transient failure has cleared.
    h.installFailURLs = []
    h.dispatch(.manualInstall(rowId: h.state.rows[0].id))
    check(h.manualInstallDispatched, "recovery: the manual Retry was a deliberate manual event")
    check(h.state.rows[0].state == .installed, "recovery: manual Retry installs the previously-failed add-on")
    check(h.installEffectCount == 2, "recovery: the installer ran again for the manual Retry")
}

// 7. MALFORMED: a non-http(s) URL is rejected in place as `.invalid`, never resolves, never installs, and an
//    invalid-only batch is NEVER allInstalled.
do {
    let h = Host()
    h.dispatch(.delivered(urls: ["ftp://nope/manifest.json", "not a url", "javascript:alert(1)"], sessionToken: "S1", liveToken: "S1"))
    check(h.state.rows.count == 3, "malformed: rows created for visibility")
    check(h.state.rows.allSatisfy { $0.state == .invalid }, "malformed: all rejected as .invalid")
    check(h.installEffectCount == 0, "malformed: nothing installed")
    if case .allInstalled = h.batch { check(false, "malformed: invalid-only batch must NOT be allInstalled") }
    else { check(true, "malformed: invalid-only batch is NOT allInstalled") }
}

// 8. batchStatus + doneState pure reductions (the Done-never-silently-exits-a-pending-submission rule).
do {
    check(AddonPairingReducer.batchStatus([]) == .empty, "batch: empty")
    check(AddonPairingReducer.batchStatus([.resolving, .installed]) == .working, "batch: any in-flight → working")
    check(AddonPairingReducer.batchStatus([.installed, .installed]) == .allInstalled(2), "batch: all installed → allInstalled")
    check(AddonPairingReducer.batchStatus([.installed, .invalid]) == .partial(installed: 1, failed: 0, invalid: 1),
          "batch: installed + invalid → partial (invalid is non-success)")
    check(AddonPairingReducer.doneState(.working).enabled == false, "done: disabled while working (no silent exit)")
    check(AddonPairingReducer.doneState(.working).title == "Installing…", "done: labels 'Installing…' while working")
    check(AddonPairingReducer.doneState(.allInstalled(2)).enabled, "done: enabled once all installed")
    check(AddonPairingReducer.doneState(.partial(installed: 1, failed: 1, invalid: 0)).enabled, "done: enabled on a terminal partial")
    check(AddonPairingReducer.doneState(.empty).enabled, "done: enabled when nothing submitted yet")
}

        print("")
        if failures == 0 {
            print("ALL TESTS PASSED")
            exit(0)
        } else {
            print("FAIL: \(failures) assertion(s) failed")
            exit(1)
        }
    }
}
