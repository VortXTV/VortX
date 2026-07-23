// QRJoinerFlowTests: a standalone, runnable verification of the VortX-account QR sign-in JOINER's
// decision logic (the loop that drove issue #153: an Apple TV stuck forever on "waiting").
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md),
// so this is written as a self-contained Swift executable that runs directly with the system toolchain:
//
//     swift app/Tests/QRJoinerFlowTests.swift
//
// It MIRRORS two pure pieces of production logic (no crypto, no network), which is why they were split
// out of the SwiftUI view / sync manager in the first place:
//
//   1. VortXSyncManager.qrPollDisposition(status:hasApproval:)  maps HTTP status to a coarse disposition.
//   2. QrJoinerReducer.onResult(_:codeAge:)                     maps a poll result to a UI action.
//
// The mirrors below MUST stay byte-identical to:
//   - app/SourcesShared/VortXSyncManager.swift  (QrJoinResult, QrPollDisposition, qrPollDisposition)
//   - app/SourcesShared/VortXAccountJoinerView.swift (QrJoinerReducer)
// If the production logic drifts, update these mirrors and the expectations together.

import Foundation

// MARK: - Mirror of VortXSyncManager's poll classification

enum QrJoinResult: Equatable { case pending, transportError, expired, failed, signedIn(email: String) }

enum QrPollDisposition: Equatable { case ready, pending, expired, retriableError }

func qrPollDisposition(status: Int, hasApproval: Bool) -> QrPollDisposition {
    if status == 404 || status == 410 { return .expired }
    if status == 0 || status == 429 || status >= 500 { return .retriableError }
    if status == 200 && hasApproval { return .ready }
    return .pending
}

// MARK: - Mirror of QrJoinerReducer (VortXAccountJoinerView.swift)

struct QrJoinerReducer {
    private(set) var consecutiveErrors = 0
    let errorNoticeThreshold: Int
    let codeMaxAge: TimeInterval

    init(errorNoticeThreshold: Int = 4, codeMaxAge: TimeInterval = 240) {
        self.errorNoticeThreshold = errorNoticeThreshold
        self.codeMaxAge = codeMaxAge
    }

    enum Action: Equatable {
        case keepWaiting(reachTrouble: Bool)
        case remint
        case signedIn(email: String)
        case failed
    }

    mutating func onResult(_ result: QrJoinResult, codeAge: TimeInterval) -> Action {
        switch result {
        case .signedIn(let email):
            return .signedIn(email: email)
        case .failed:
            return .failed
        case .expired:
            consecutiveErrors = 0
            return .remint
        case .transportError:
            consecutiveErrors += 1
            return .keepWaiting(reachTrouble: consecutiveErrors >= errorNoticeThreshold)
        case .pending:
            consecutiveErrors = 0
            if codeAge >= codeMaxAge { return .remint }
            return .keepWaiting(reachTrouble: false)
        }
    }
}

// MARK: - Harness

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if condition { print("  PASS  \(name)") } else { failures += 1; print("  FAIL  \(name)") }
}

// MARK: - Tests: qrPollDisposition (HTTP status -> disposition)

print("qrPollDisposition:")
// Expiry: the relay says the pairing is gone.
check(qrPollDisposition(status: 404, hasApproval: false) == .expired, "404 -> expired")
check(qrPollDisposition(status: 410, hasApproval: false) == .expired, "410 -> expired")
// Retriable transport/relay trouble: the field-report path where a stuck relay used to read as "pending".
check(qrPollDisposition(status: 0,   hasApproval: false) == .retriableError, "0 (offline/DNS/TLS/timeout) -> retriableError")
check(qrPollDisposition(status: 429, hasApproval: false) == .retriableError, "429 (rate limit) -> retriableError")
check(qrPollDisposition(status: 500, hasApproval: false) == .retriableError, "500 -> retriableError")
check(qrPollDisposition(status: 502, hasApproval: false) == .retriableError, "502 -> retriableError")
check(qrPollDisposition(status: 503, hasApproval: true)  == .retriableError, "503 outranks a body -> retriableError")
// Ready: an approval is present on a 200.
check(qrPollDisposition(status: 200, hasApproval: true)  == .ready,   "200 + approval -> ready")
// Pending: reachable but nothing to do yet, or an unexpected-but-benign status.
check(qrPollDisposition(status: 200, hasApproval: false) == .pending, "200 without approval -> pending")
check(qrPollDisposition(status: 202, hasApproval: false) == .pending, "202 -> pending")
check(qrPollDisposition(status: 401, hasApproval: false) == .pending, "401 -> pending (keep polling, not retriable-surfaced)")
check(qrPollDisposition(status: 404, hasApproval: true)  == .expired, "404 outranks a body -> expired")

// MARK: - Tests: QrJoinerReducer (poll result -> UI action)

print("\nQrJoinerReducer.onResult:")

// Success and hard-fail pass straight through.
do {
    var r = QrJoinerReducer()
    check(r.onResult(.signedIn(email: "a@b.co"), codeAge: 1) == .signedIn(email: "a@b.co"), "signedIn -> signedIn(email)")
    check(r.onResult(.failed, codeAge: 1) == .failed, "failed -> failed")
    check(r.onResult(.expired, codeAge: 1) == .remint, "expired -> remint")
}

// A single pending is a plain keep-waiting with no trouble surfaced.
do {
    var r = QrJoinerReducer()
    check(r.onResult(.pending, codeAge: 1) == .keepWaiting(reachTrouble: false), "one pending -> keepWaiting(no trouble)")
}

// Transport errors must NOT surface trouble immediately (a blip is tolerated), but DO once they recur.
do {
    var r = QrJoinerReducer(errorNoticeThreshold: 4, codeMaxAge: 240)
    check(r.onResult(.transportError, codeAge: 1) == .keepWaiting(reachTrouble: false), "error 1 -> keepWaiting(no trouble)")
    check(r.onResult(.transportError, codeAge: 1) == .keepWaiting(reachTrouble: false), "error 2 -> keepWaiting(no trouble)")
    check(r.onResult(.transportError, codeAge: 1) == .keepWaiting(reachTrouble: false), "error 3 -> keepWaiting(no trouble)")
    check(r.onResult(.transportError, codeAge: 1) == .keepWaiting(reachTrouble: true),  "error 4 (threshold) -> keepWaiting(trouble)")
    check(r.onResult(.transportError, codeAge: 1) == .keepWaiting(reachTrouble: true),  "error 5 -> keepWaiting(trouble) stays")
}

// Reaching the relay again (a pending) clears the trouble streak, so a transient outage self-heals.
do {
    var r = QrJoinerReducer(errorNoticeThreshold: 2, codeMaxAge: 240)
    _ = r.onResult(.transportError, codeAge: 1)
    check(r.onResult(.transportError, codeAge: 1) == .keepWaiting(reachTrouble: true), "two errors -> trouble surfaced")
    check(r.onResult(.pending, codeAge: 1) == .keepWaiting(reachTrouble: false), "a pending clears the trouble streak")
    check(r.onResult(.transportError, codeAge: 1) == .keepWaiting(reachTrouble: false), "streak reset: next error is 1, no trouble")
}

// Stale-code backstop: a pending past codeMaxAge re-mints even though the relay never reported expiry.
do {
    var r = QrJoinerReducer(errorNoticeThreshold: 4, codeMaxAge: 240)
    check(r.onResult(.pending, codeAge: 239) == .keepWaiting(reachTrouble: false), "pending just under max age -> keepWaiting")
    check(r.onResult(.pending, codeAge: 240) == .remint, "pending at max age -> remint (never a silently rotting code)")
    check(r.onResult(.pending, codeAge: 999) == .remint, "pending well past max age -> remint")
}

print("")
if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failures) TEST(S) FAILED")
    exit(1)
}
