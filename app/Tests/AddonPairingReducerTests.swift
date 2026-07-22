// Executable harness for the Install-by-QR add-on pairing lifecycle.
//
//   xcrun swiftc -o /tmp/addon-pairing-reducer-test \
//     app/SourcesShared/AddonPairingReducer.swift \
//     app/Tests/AddonPairingReducerTests.swift && /tmp/addon-pairing-reducer-test
//
// This suite CALLS the production reducer (`AddonPairingReducer`), the exact value type `AddonPairingView` drives,
// not a re-implemented mirror state machine. The mirror-test anti-pattern was the prior blocker: a test that
// re-encodes the lifecycle proves its own copy, never the shipping code. Here the install / close / drain / ack
// decisions under test ARE the shipping decisions, because the view holds no lifecycle logic of its own.
//
// The bar is that each property turns RED when broken, including semantic breaks that leave the source intact:
//   - close-while-installing is asserted BOTH ways (in-flight blocks release; drained releases exactly once), so
//     moving the drain check catches a reordering that changes no strings;
//   - a stale install result and a duplicate delivery are asserted to be dropped, so deleting the attempt / id
//     guards fails loudly;
//   - already-installed and confirmed-not-dispatched are distinct outcomes, so collapsing them fails.

import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

// A delivery on session token `t` with a canonical URL derived from `raw`.
func delivery(_ id: String, raw: String, token: String = "tok-A") -> AddonDelivery {
    AddonDelivery(id: id, canonicalURL: "https://\(raw)/manifest.json", rawURL: "https://\(raw)", token: token)
}

// Find a row's state by delivery id.
func state(_ r: AddonPairingReducer, _ id: String) -> AddonRowState? {
    r.rows.first(where: { $0.delivery.id == id })?.state
}

@main
enum AddonPairingReducerTests {
    static func main() { run() }

    static func run() {
        retryableClassification()
        duplicateDeliveryExactlyOnce()
        alreadyInstalledIsSuccess()
        confirmedNotJustDispatched()
        staleInstallResultIgnored()
        addThenDoneNotLost()
        closeDrainsThenReleasesOnce()
        transientFailureRetryable()
        terminalFailureAcksFailed()
        unknownDeliveryRejected()
        retryReResolvesWhenNeverValidated()

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    // ---- Retryable classification (the transient-vs-terminal rule) ---------------------------------

    static func retryableClassification() {
        check("classify: unresolvable is retryable", addonFetchIsRetryable(.unresolvable) == true)
        check("classify: private address is terminal", addonFetchIsRetryable(.privateAddress) == false)
        check("classify: invalid scheme is terminal", addonFetchIsRetryable(.invalidScheme) == false)
        check("classify: redirect loop is terminal", addonFetchIsRetryable(.tooManyRedirects) == false)
    }

    // ---- Duplicate delivery -> exactly one row, one resolve ----------------------------------------

    static func duplicateDeliveryExactlyOnce() {
        var r = AddonPairingReducer()
        let d = delivery("d1", raw: "a.example.com/addon")
        let first = r.ingest([d])
        check("ingest: new delivery emits exactly one resolve", first == [.resolve(d)])
        // Same id again, and a different id that canonicalizes identically: neither adds a row or re-resolves.
        let dupId = r.ingest([d])
        let dupCanon = r.ingest([AddonDelivery(id: "d2", canonicalURL: d.canonicalURL, rawURL: d.rawURL, token: "tok-A")])
        check("ingest: duplicate id is ignored", dupId.isEmpty)
        check("ingest: duplicate canonical (new id) is ignored", dupCanon.isEmpty)
        check("ingest: still exactly one row", r.rows.count == 1)
    }

    // ---- Already-installed = success, not error ----------------------------------------------------

    static func alreadyInstalledIsSuccess() {
        var r = AddonPairingReducer()
        let d = delivery("d1", raw: "a.example.com/addon")
        _ = r.ingest([d])
        let effects = r.resolved(id: "d1", outcome: .alreadyInstalled(name: "Already"))
        check("resolve already-installed -> row installed", state(r, "d1") == .installed)
        check("resolve already-installed -> acks installed", effects.contains(.ack(d, .installed)))
    }

    // ---- Confirmed, not merely dispatched ----------------------------------------------------------

    static func confirmedNotJustDispatched() {
        var r = AddonPairingReducer()
        let d = delivery("d1", raw: "a.example.com/addon")
        _ = r.ingest([d])
        _ = r.resolved(id: "d1", outcome: .ready(name: "Ready"))
        let started = r.install(id: "d1")
        check("install tap -> installing (NOT installed)", state(r, "d1") == .installing)
        check("install tap -> emits install effect at attempt 1", started == [.install(d, attempt: 1)])
        check("dispatched install is still in flight (blocks release)", r.isInFlight(token: "tok-A"))
        // Only a CONFIRMED result marks installed.
        _ = r.installed(id: "d1", attempt: 1, outcome: .installed)
        check("confirmed result -> installed", state(r, "d1") == .installed)
        check("after confirm, nothing in flight", r.isInFlight(token: "tok-A") == false)
    }

    // ---- A stale install result (superseded attempt) is dropped ------------------------------------

    static func staleInstallResultIgnored() {
        var r = AddonPairingReducer()
        let d = delivery("d1", raw: "a.example.com/addon")
        _ = r.ingest([d])
        _ = r.resolved(id: "d1", outcome: .ready(name: "Ready"))
        _ = r.install(id: "d1")                              // attempt 1
        // A late failure from a PRIOR attempt (attempt 0) must not touch the row mid-install.
        let ignored = r.installed(id: "d1", attempt: 0, outcome: .failed(retryable: false, message: "stale"))
        check("stale attempt result is ignored", ignored.isEmpty && state(r, "d1") == .installing)
        // The current attempt's result applies exactly once; a duplicate of it is then dropped.
        _ = r.installed(id: "d1", attempt: 1, outcome: .installed)
        let dupe = r.installed(id: "d1", attempt: 1, outcome: .installed)
        check("duplicate confirmed result is dropped (exactly once)", dupe.isEmpty && state(r, "d1") == .installed)
    }

    // ---- Add-then-Done: an install started just before Done completes and is not lost --------------

    static func addThenDoneNotLost() {
        var r = AddonPairingReducer()
        let d = delivery("d1", raw: "a.example.com/addon")
        _ = r.ingest([d])
        _ = r.resolved(id: "d1", outcome: .ready(name: "Ready"))
        _ = r.install(id: "d1")                              // user taps Install...
        // ...and in the SAME poll window the phone tapped Done (closed == true).
        let onClose = r.closeSeen(token: "tok-A")
        check("close while installing does NOT release the token", onClose.isEmpty)
        check("close while installing keeps the token in flight", r.isInFlight(token: "tok-A"))
        check("close does not drop the installing row", r.rows.count == 1 && state(r, "d1") == .installing)
        // The install confirms AFTER Done; it must land and then the session drains + acks.
        let onDone = r.installed(id: "d1", attempt: 1, outcome: .installed)
        check("post-close confirm -> installed", state(r, "d1") == .installed)
        check("post-close confirm -> acks installed", onDone.contains(.ack(d, .installed)))
        check("post-close confirm -> releases the drained token", onDone.contains(.releaseToken("tok-A")))
        check("token now reported released", r.isReleased("tok-A"))
    }

    // ---- Close drains, then releases exactly once --------------------------------------------------

    static func closeDrainsThenReleasesOnce() {
        var r = AddonPairingReducer()
        let d = delivery("d1", raw: "a.example.com/addon", token: "tok-B")
        _ = r.ingest([d])
        // Still resolving (in flight): close must not release.
        let early = r.closeSeen(token: "tok-B")
        check("close while resolving does not release", early.isEmpty && r.isReleased("tok-B") == false)
        // Resolve completes to a ready row (no install started): now nothing is in flight -> release once.
        let onResolve = r.resolved(id: "d1", outcome: .ready(name: "Ready"))
        check("resolve finishing a closed session releases it", onResolve.contains(.releaseToken("tok-B")))
        check("released token reported released", r.isReleased("tok-B"))
        // A later close event for the same token does not release again.
        let again = r.closeSeen(token: "tok-B")
        check("release is emitted exactly once", again.contains(.releaseToken("tok-B")) == false)
    }

    // ---- Transient failure is retryable and NOT acked failed ---------------------------------------

    static func transientFailureRetryable() {
        var r = AddonPairingReducer()
        let d = delivery("d1", raw: "a.example.com/addon")
        _ = r.ingest([d])
        _ = r.resolved(id: "d1", outcome: .ready(name: "Ready"))
        _ = r.install(id: "d1")
        let effects = r.installed(id: "d1", attempt: 1, outcome: .failed(retryable: true, message: "blip"))
        check("transient install failure -> failed(retryable:true)", state(r, "d1") == .failed(retryable: true, message: "blip"))
        check("transient failure is NOT acked failed (still pending)", effects.contains(where: { if case .ack = $0 { return true }; return false }) == false)
        // Retry re-installs a row that already validated.
        let retried = r.retry(id: "d1")
        check("retry a validated retryable-failed row -> installs at attempt 2", retried == [.install(d, attempt: 2)])
        check("retry -> installing again", state(r, "d1") == .installing)
    }

    // ---- Terminal failure acks failed (truthful phone Done) ----------------------------------------

    static func terminalFailureAcksFailed() {
        var r = AddonPairingReducer()
        let d = delivery("d1", raw: "a.example.com/addon")
        _ = r.ingest([d])
        _ = r.resolved(id: "d1", outcome: .ready(name: "Ready"))
        _ = r.install(id: "d1")
        let effects = r.installed(id: "d1", attempt: 1, outcome: .failed(retryable: false, message: "bad manifest"))
        check("terminal install failure -> failed(retryable:false)", state(r, "d1") == .failed(retryable: false, message: "bad manifest"))
        check("terminal failure acks failed", effects.contains(.ack(d, .failed)))
        // A terminal-failed row has no retry.
        check("retry on a terminal-failed row is a no-op", r.retry(id: "d1").isEmpty)
    }

    // ---- Unknown delivery / wrong session is rejected ----------------------------------------------

    static func unknownDeliveryRejected() {
        var r = AddonPairingReducer()
        // No rows ingested: every action for an unknown id is a no-op (the "wrong / expired session" analog).
        check("resolve unknown id -> no effect", r.resolved(id: "ghost", outcome: .ready(name: "x")).isEmpty)
        check("install unknown id -> no effect", r.install(id: "ghost").isEmpty)
        check("installed unknown id -> no effect", r.installed(id: "ghost", attempt: 1, outcome: .installed).isEmpty)
        check("retry unknown id -> no effect", r.retry(id: "ghost").isEmpty)
        check("no phantom rows were created", r.rows.isEmpty)
    }

    // ---- Retry re-resolves when the failure happened before validation -----------------------------

    static func retryReResolvesWhenNeverValidated() {
        var r = AddonPairingReducer()
        let d = delivery("d1", raw: "a.example.com/addon")
        _ = r.ingest([d])
        // A transient failure during RESOLVE (no name yet).
        _ = r.resolved(id: "d1", outcome: .rejected(retryable: true, message: "blip"))
        check("resolve blip -> failed(retryable:true)", state(r, "d1") == .failed(retryable: true, message: "blip"))
        let retried = r.retry(id: "d1")
        check("retry a never-validated row -> re-resolves (not install)", retried == [.resolve(d)])
        check("retry -> resolving again", state(r, "d1") == .resolving)
    }
}
