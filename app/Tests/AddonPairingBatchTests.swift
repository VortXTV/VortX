// AddonPairingBatchTests: a standalone, runnable verification of the tvOS "Install by QR" auto-install
// decision surface (INS-260722-04 / REQ-260722-44) in app/SourcesShared/AddonPairingView.swift.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md), so,
// exactly like app/Tests/HouseholdCryptoTests.swift and StreamRankingChipsTests.swift, this is a
// self-contained Swift executable that runs directly with the system toolchain:
//
//     swift app/Tests/AddonPairingBatchTests.swift
//
// SCOPE: a standalone script cannot link the SwiftUI app target (CoreBridge, Theme, the whole UI stack come
// with it), so this re-implements ONLY the pure decision logic of AddonPairingView — the row keying, the
// merge dedup + malformed / wrong-session rejection, the auto-install-exactly-once guard, the idempotent
// install outcome, `batchStatus`, `doneState`, and the manual-recovery (focus reachability) invariant. These
// mirrors MUST stay in lockstep with AddonPairingView.swift; if the shipped rules there change, update the
// mirrors below so the properties are still asserted against the real design.

import Foundation

// MARK: - Mirror of AddonPairingView.Row.State + the pure reductions

enum RowState: Equatable {
    case pending, resolving, ready, invalid, installing, installed
    case failed(String)

    // Mirror of Row.State.isInFlight.
    var isInFlight: Bool {
        switch self {
        case .pending, .resolving, .ready, .installing: return true
        case .invalid, .installed, .failed:             return false
        }
    }
    // Mirror of Row.State.isManualActionable — the states that render a FOCUSABLE Install / Retry Button in
    // trailingControl(for:). This is the "Install button focusable + actionable as manual recovery" contract.
    var isManualActionable: Bool {
        switch self {
        case .ready:  return true
        case .failed: return true
        default:      return false
        }
    }
}

enum BatchStatus: Equatable {
    case empty
    case working
    case allInstalled(Int)
    case partial(installed: Int, failed: Int, invalid: Int)
}

// Mirror of AddonPairingView.batchStatus(_:).
func batchStatus(_ states: [RowState]) -> BatchStatus {
    guard !states.isEmpty else { return .empty }
    if states.contains(where: { $0.isInFlight }) { return .working }
    var installed = 0, failed = 0, invalid = 0
    for s in states {
        switch s {
        case .installed: installed += 1
        case .invalid:   invalid += 1
        case .failed:    failed += 1
        default:         break
        }
    }
    if installed == states.count { return .allInstalled(installed) }
    return .partial(installed: installed, failed: failed, invalid: invalid)
}

// Mirror of AddonPairingView.doneState(_:).
func doneState(_ status: BatchStatus) -> (title: String, enabled: Bool) {
    switch status {
    case .working:                        return ("Installing…", false)
    case .empty, .allInstalled, .partial: return ("Done", true)
    }
}

// MARK: - Mirror of the merge / auto-install model

/// A row identified by SESSION + identity (never URL alone), mirroring AddonPairingView.Row.
struct Row: Equatable {
    let sessionToken: String
    let url: String
    let identity: String
    var state: RowState = .pending
    var id: String { sessionToken + "\u{1}" + identity }
}

/// A faithful-but-minimal stand-in for the pairing model: it owns `rows`, the auto-install-once set, and a
/// tiny fake engine (the set of already-installed transport URLs). It mirrors merge / resolve / auto-install
/// / install so the properties can be asserted without SwiftUI or the network.
final class PairingModel {
    private(set) var rows: [Row] = []
    private(set) var autoInstalled: Set<String> = []
    private(set) var installDispatches = 0        // how many times the hardened installer was invoked
    var liveSessionToken: String
    /// The fake "engine": transport URLs already installed. A URL here validates as `alreadyInstalled`.
    var installed: Set<String>
    /// URLs whose manifest fails validation (malformed-manifest / unreachable) — resolve → `.invalid`.
    var invalidManifests: Set<String>

    init(liveSessionToken: String, installed: Set<String> = [], invalidManifests: Set<String> = []) {
        self.liveSessionToken = liveSessionToken
        self.installed = installed
        self.invalidManifests = invalidManifests
    }

    /// Mirror of CoreBridge.normalizedAddonURL: http(s) only, ensure a /manifest.json suffix, else nil.
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

    /// Mirror of AddonPairingView.merge(incoming:sessionToken:) — binds to the live session, dedups by
    /// (session, identity), rejects malformed URLs in place as `.invalid`, then resolves the rest.
    func merge(incoming: [String], sessionToken: String) {
        guard sessionToken == liveSessionToken else { return }   // wrong-session → nothing happens
        let known = Set(rows.map(\.id))
        var toResolve: [String] = []
        for url in incoming {
            let normalized = normalize(url)
            let identity = normalized ?? url
            let rowId = sessionToken + "\u{1}" + identity
            guard !known.contains(rowId) else { continue }        // duplicate delivery → no second row
            if normalized == nil {
                rows.append(Row(sessionToken: sessionToken, url: url, identity: identity, state: .invalid))
            } else {
                rows.append(Row(sessionToken: sessionToken, url: url, identity: identity, state: .pending))
                toResolve.append(rowId)
            }
        }
        for rowId in toResolve { resolve(rowId: rowId) }
    }

    /// Mirror of resolve(rowId:) + autoInstallIfEligible: validate, mark installed/ready/invalid, then
    /// auto-install a valid, not-yet-installed, live-session row exactly once.
    func resolve(rowId: String) {
        guard let idx = rows.firstIndex(where: { $0.id == rowId }) else { return }
        let identity = rows[idx].identity
        if invalidManifests.contains(rows[idx].url) || invalidManifests.contains(identity) {
            rows[idx].state = .invalid
            return
        }
        rows[idx].state = installed.contains(identity) ? .installed : .ready
        autoInstallIfEligible(rowId: rowId)
    }

    func autoInstallIfEligible(rowId: String) {
        guard let row = rows.first(where: { $0.id == rowId }) else { return }
        guard row.sessionToken == liveSessionToken else { return }   // wrong-session → never installs
        guard row.state == .ready else { return }
        guard !autoInstalled.contains(rowId) else { return }         // exactly once
        install(rowId: rowId)
    }

    /// Mirror of install(rowId:): the hardened, idempotent installer. Marks the once-guard BEFORE dispatch,
    /// treats an already-present add-on as success (idempotent), else installs.
    func install(rowId: String) {
        guard let idx = rows.firstIndex(where: { $0.id == rowId }) else { return }
        autoInstalled.insert(rowId)
        let identity = rows[idx].identity
        installDispatches += 1
        // installAddon idempotency: a URL already present is a no-op success.
        installed.insert(identity)
        rows[idx].state = .installed
    }

    func installActionable() {
        for row in rows where row.state.isManualActionable { install(rowId: row.id) }
    }

    /// Test-only: seed a row in an arbitrary state (e.g. `.failed`) to exercise manual recovery directly.
    func seed(_ row: Row) { rows.append(row) }

    var batch: BatchStatus { batchStatus(rows.map(\.state)) }
}

// MARK: - Tiny assertion harness

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("  ok   \(name)") }
    else { failures += 1; print("  FAIL \(name)") }
}

print("AddonPairingBatchTests")

// 1. AUTO-INSTALL + IDEMPOTENCY: a valid submission installs exactly once; a duplicate delivery in the same
//    session does NOT create a second row or a second install.
do {
    let m = PairingModel(liveSessionToken: "S1")
    m.merge(incoming: ["https://good.example/manifest.json"], sessionToken: "S1")
    check(m.rows.count == 1, "idempotency: one submission → one row")
    check(m.rows[0].state == .installed, "idempotency: valid submission auto-installs")
    check(m.installDispatches == 1, "idempotency: installed exactly once")
    // Relay re-delivers the same URL on the next poll (very common — the list is cumulative).
    m.merge(incoming: ["https://good.example/manifest.json"], sessionToken: "S1")
    check(m.rows.count == 1, "idempotency: duplicate delivery adds no second row")
    check(m.installDispatches == 1, "idempotency: duplicate delivery does not re-install")
}

// 2. WRONG-SESSION rejection: a submission carrying a token other than the live one is refused with NO
//    partial state (no row, no install).
do {
    let m = PairingModel(liveSessionToken: "S1")
    m.merge(incoming: ["https://good.example/manifest.json"], sessionToken: "S-OTHER")
    check(m.rows.isEmpty, "wrong-session: no row created")
    check(m.installDispatches == 0, "wrong-session: nothing installed")
}

// 3. EXPIRED / rotated session: rows bound to a dead session never auto-install after rotation, and the URL
//    keying is per-session so the same URL in the NEW session is a fresh, installable row.
do {
    let m = PairingModel(liveSessionToken: "S1")
    m.merge(incoming: ["https://good.example/manifest.json"], sessionToken: "S1")   // installs under S1
    check(m.installDispatches == 1, "rotation: first session installs")
    // Session rotates; S1 is now stale. A delivery still tagged S1 must be refused.
    m.liveSessionToken = "S2"
    m.merge(incoming: ["https://good.example/manifest.json"], sessionToken: "S1")
    check(m.installDispatches == 1, "rotation: a stale-session delivery does not install")
    // Same URL, now under the LIVE session S2 → distinct (session,identity) row. Already installed in the
    // engine, so it resolves idempotently to .installed WITHOUT a second dispatch.
    m.merge(incoming: ["https://good.example/manifest.json"], sessionToken: "S2")
    check(m.rows.contains { $0.sessionToken == "S2" }, "rotation: new session creates a distinct row (session+identity keying)")
    check(m.installDispatches == 1, "rotation: already-installed add-on is not re-installed in the new session")
    check(m.rows.first { $0.sessionToken == "S2" }?.state == .installed, "rotation: new-session row resolves idempotently to installed")
}

// 4. MALFORMED rejection: a non-http(s) URL is rejected in place as .invalid, never resolves, never installs.
do {
    let m = PairingModel(liveSessionToken: "S1")
    m.merge(incoming: ["ftp://nope/manifest.json", "not a url", "javascript:alert(1)"], sessionToken: "S1")
    check(m.rows.count == 3, "malformed: rows created for visibility")
    check(m.rows.allSatisfy { $0.state == .invalid }, "malformed: all rejected as .invalid")
    check(m.installDispatches == 0, "malformed: nothing installed")
}

// 5. INVALID-NOT-SUCCESS: a batch of only invalid manifests must NOT report allInstalled.
do {
    let m = PairingModel(liveSessionToken: "S1", invalidManifests: ["https://bad.example/manifest.json"])
    m.merge(incoming: ["https://bad.example/manifest.json"], sessionToken: "S1")
    check(m.rows.count == 1 && m.rows[0].state == .invalid, "invalid: manifest that fails validation → .invalid")
    if case .allInstalled = m.batch { check(false, "invalid-only batch must NOT be allInstalled") }
    else { check(true, "invalid-only batch is NOT allInstalled") }
    check(m.installDispatches == 0, "invalid: nothing installed")
}

// 6. batchStatus reductions.
do {
    check(batchStatus([]) == .empty, "batch: empty")
    check(batchStatus([.resolving, .installed]) == .working, "batch: any in-flight → working")
    check(batchStatus([.installed, .installed]) == .allInstalled(2), "batch: all installed → allInstalled")
    check(batchStatus([.installed, .invalid]) == .partial(installed: 1, failed: 0, invalid: 1),
          "batch: installed + invalid → partial (invalid is non-success)")
    check(batchStatus([.installed, .failed("x")]) == .partial(installed: 1, failed: 1, invalid: 0),
          "batch: installed + failed → partial (failed is non-success)")
}

// 7. DONE reflects state, never silently exits a pending submission.
do {
    check(doneState(.working).enabled == false, "done: disabled while working (no silent exit of a pending submission)")
    check(doneState(.working).title == "Installing…", "done: labels 'Installing…' while working")
    check(doneState(.allInstalled(2)).enabled, "done: enabled once all installed")
    check(doneState(.partial(installed: 1, failed: 1, invalid: 0)).enabled, "done: enabled on a terminal partial (failures visible, session persists)")
    check(doneState(.empty).enabled, "done: enabled when nothing submitted yet")
}

// 8. INSTALL FOCUS REACHABILITY (manual recovery): a failed row is manual-actionable (renders a focusable
//    Retry Button), and installActionable() recovers it; a mid-flight row is NOT actionable (shows progress).
do {
    let m = PairingModel(liveSessionToken: "S1", invalidManifests: ["https://bad.example/manifest.json"])
    // Force a row into a failed state to exercise manual recovery.
    m.seed(Row(sessionToken: "S1", url: "https://retry.example/manifest.json",
               identity: "https://retry.example/manifest.json", state: .failed("network error")))
    check(m.rows[0].state.isManualActionable, "focus: a failed row is manual-actionable (focusable Retry)")
    check(RowState.ready.isManualActionable, "focus: a ready row is manual-actionable (focusable Install)")
    check(!RowState.installing.isManualActionable, "focus: an installing row is not actionable (shows progress)")
    check(!RowState.installed.isManualActionable, "focus: an installed row is not actionable")
    m.installActionable()   // the "Install all" recovery path
    check(m.rows[0].state == .installed, "focus: manual recovery installs the failed row")
    check(m.installDispatches == 1, "focus: manual recovery dispatched the installer once")
}

print("")
if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("FAIL: \(failures) assertion(s) failed")
    exit(1)
}
