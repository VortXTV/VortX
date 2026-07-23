// Executable harness for the Install-by-QR add-on pairing lifecycle.
//
//   xcrun swiftc -o /tmp/addon-pairing-reducer-test \
//     app/SourcesShared/AddonPairingReducer.swift \
//     app/Tests/AddonPairingReducerTests.swift && /tmp/addon-pairing-reducer-test
//
// This suite CALLS the production reducer (`AddonPairingReducer`) and its shared pure helpers
// (`canonicalAddonIdentity`, `safeRevision`) — the exact value type + functions `AddonPairingView`,
// `CoreBridge`, and `AddonPairingClient` drive — not a re-implemented mirror state machine. The mirror-test
// anti-pattern was the prior blocker: a test that re-encodes the lifecycle proves its own copy, never the
// shipping code. Here the install / close / drain / ack decisions under test ARE the shipping decisions, because
// the view holds no lifecycle logic of its own.
//
// THE CENTRAL PROPERTY (C1, the CEO's #1 requirement): a validated delivery AUTO-INSTALLS on arrival — no second
// tap. `resolved(.ready)` EMITS the install effect itself. The on-screen Install button is recovery only. The
// prior 42/42 suite codified the REJECTED second-tap design (`closeDrainsThenReleasesOnce` blessed token release
// after Done + `.ready` with no install; `addThenDoneNotLost` manually called `install(...)`), so those tests are
// REWRITTEN here, not merely extended: `autoInstallAddThenDoneEndsInstalled` performs a real phone add + immediate
// Done and NEVER calls `install(...)` manually, and asserts the add-on ends INSTALLED.
//
// The bar is that each property turns RED when broken, including semantic breaks that leave the source intact:
//   - close-while-auto-installing is asserted BOTH ways (in-flight blocks release; the CONFIRMED install drains
//     and releases exactly once), so moving the drain check or dropping auto-install catches a reordering that
//     changes no strings;
//   - a stale install result and a duplicate delivery are asserted to be dropped, so deleting the attempt / id
//     guards fails loudly;
//   - already-installed and confirmed-not-dispatched are distinct outcomes, so collapsing them fails;
//   - a hostile revision and a query/fragment-bearing URL are exercised against the real shared helpers.

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

// Does the effect list contain ANY ack (regardless of status/attempt)?
func hasAnyAck(_ effects: [AddonPairingEffect]) -> Bool {
    effects.contains { if case .ack = $0 { return true }; return false }
}

@main
enum AddonPairingReducerTests {
    static func main() { run() }

    static func run() {
        retryableClassification()
        duplicateDeliveryExactlyOnce()
        alreadyInstalledIsSuccess()
        resolvedReadyAutoInstalls()              // C1
        autoInstallAddThenDoneEndsInstalled()    // C1 (rewritten add-then-Done, NO manual install)
        closeDrainsThenReleasesOnce()            // rewritten: auto-install keeps the session in flight
        rosterTransitionOnCanonicalIdentity()    // roster transition proof (resolve->install->installed)
        confirmedNotJustDispatched()
        staleInstallResultIgnored()
        transientFailureRetryable()
        terminalFailureAcksFailed()
        terminalPreviewRejectionAcksFailed()     // H1
        crossSessionDuplicateAcksInstalled()     // H7 (already-installed)
        pendingDuplicateAckedOnConfirm()         // H7 (same-window, flushed on confirm)
        ackCarriesInstallAttempt()               // H3
        unknownDeliveryRejected()
        retryReResolvesWhenNeverValidated()
        canonicalIdentityRule()                  // H4 (shared helper)
        safeRevisionNoCrash()                    // H11 (shared helper)

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
        // The canonical row is still resolving (not installed), so the new-id duplicate is stashed silently.
        let dupId = r.ingest([d])
        let dupCanon = r.ingest([AddonDelivery(id: "d2", canonicalURL: d.canonicalURL, rawURL: d.rawURL, token: "tok-A")])
        check("ingest: duplicate id is ignored", dupId.isEmpty)
        check("ingest: duplicate canonical (new id, not-yet-installed) emits nothing", dupCanon.isEmpty)
        check("ingest: still exactly one row", r.rows.count == 1)
    }

    // ---- Already-installed = success, not error ----------------------------------------------------

    static func alreadyInstalledIsSuccess() {
        var r = AddonPairingReducer()
        let d = delivery("d1", raw: "a.example.com/addon")
        _ = r.ingest([d])
        let effects = r.resolved(id: "d1", outcome: .alreadyInstalled(name: "Already"))
        check("resolve already-installed -> row installed", state(r, "d1") == .installed)
        // No local install ran, so the ack carries attempt 0.
        check("resolve already-installed -> acks installed (attempt 0)", effects.contains(.ack(d, .installed, attempt: 0)))
    }

    // ---- C1: a validated delivery AUTO-INSTALLS on arrival (no tap) --------------------------------

    static func resolvedReadyAutoInstalls() {
        var r = AddonPairingReducer()
        let d = delivery("d1", raw: "a.example.com/addon")
        _ = r.ingest([d])
        // The ONLY event is resolution finishing; NO install(...) is called by the test.
        let auto = r.resolved(id: "d1", outcome: .ready(name: "Ready"))
        check("resolved(.ready) auto-emits the install effect (no manual tap)", auto == [.install(d, attempt: 1)])
        check("auto-install -> installing", state(r, "d1") == .installing)
        check("auto-install keeps the session in flight (outliving)", r.isInFlight(token: "tok-A"))
    }

    // ---- C1: real phone add + immediate Done, NEVER calling install() manually ---------------------

    static func autoInstallAddThenDoneEndsInstalled() {
        var r = AddonPairingReducer()
        let d = delivery("d1", raw: "a.example.com/addon")
        // Phone adds a URL...
        _ = r.ingest([d])
        // ...it validates and AUTO-INSTALLS (the test never taps Install)...
        let auto = r.resolved(id: "d1", outcome: .ready(name: "Ready"))
        check("add -> auto-install fires with no manual install()", auto == [.install(d, attempt: 1)])
        // ...and in the SAME window the phone taps Done.
        let onClose = r.closeSeen(token: "tok-A")
        check("Done while auto-installing does NOT release the token", onClose.isEmpty)
        check("Done while auto-installing keeps the token in flight", r.isInFlight(token: "tok-A"))
        check("Done does not drop the auto-installing row", r.rows.count == 1 && state(r, "d1") == .installing)
        // The auto-install confirms AFTER Done; it must land, ack, and drain the closed session.
        let onDone = r.installed(id: "d1", attempt: 1, outcome: .installed)
        check("ADD-ON ENDS INSTALLED with zero manual install() calls", state(r, "d1") == .installed)
        check("post-Done confirm -> acks installed (attempt 1)", onDone.contains(.ack(d, .installed, attempt: 1)))
        check("post-Done confirm -> releases the drained token", onDone.contains(.releaseToken("tok-A")))
        check("token now reported released", r.isReleased("tok-A"))
    }

    // ---- Close drains, then releases exactly once (auto-install semantics) -------------------------

    static func closeDrainsThenReleasesOnce() {
        var r = AddonPairingReducer()
        let d = delivery("d1", raw: "a.example.com/addon", token: "tok-B")
        _ = r.ingest([d])
        // Still resolving (in flight): close must not release.
        let early = r.closeSeen(token: "tok-B")
        check("close while resolving does not release", early.isEmpty && r.isReleased("tok-B") == false)
        // Resolution finishing now AUTO-INSTALLS -> the row is .installing, i.e. STILL in flight, so the closed
        // session is STILL not released (this is the exact assertion the old suite got backwards: it blessed a
        // release here with no install).
        let onResolve = r.resolved(id: "d1", outcome: .ready(name: "Ready"))
        check("resolve auto-installs -> installing, not ready", state(r, "d1") == .installing)
        check("closed session with an auto-install in flight is NOT released",
              onResolve.contains(.releaseToken("tok-B")) == false && r.isReleased("tok-B") == false)
        // Only the CONFIRMED install drains + releases, exactly once.
        let onConfirm = r.installed(id: "d1", attempt: 1, outcome: .installed)
        check("confirmed install releases the drained token", onConfirm.contains(.releaseToken("tok-B")))
        check("released token reported released", r.isReleased("tok-B"))
        let again = r.closeSeen(token: "tok-B")
        check("release is emitted exactly once", again.contains(.releaseToken("tok-B")) == false)
    }

    // ---- Roster transition proof: resolve -> install -> installed on the canonical identity ---------

    static func rosterTransitionOnCanonicalIdentity() {
        var r = AddonPairingReducer()
        let d = AddonDelivery(id: "d1",
                              canonicalURL: "https://a.example.com/addon/manifest.json?token=AbC",
                              rawURL: "https://a.example.com/addon?token=AbC",
                              token: "tok-A")
        // resolving
        _ = r.ingest([d])
        check("transition[0]: resolving", state(r, "d1") == .resolving)
        // installing (auto), carrying the SAME canonical identity
        let auto = r.resolved(id: "d1", outcome: .ready(name: "Ready"))
        check("transition[1]: installing", state(r, "d1") == .installing)
        check("install effect carries the canonical identity",
              auto == [.install(d, attempt: 1)] && r.rows.first?.delivery.canonicalURL == d.canonicalURL)
        // installed, and the ack targets the same canonical identity's delivery
        let done = r.installed(id: "d1", attempt: 1, outcome: .installed)
        check("transition[2]: installed", state(r, "d1") == .installed)
        check("ack targets the same delivery/canonical identity", done.contains(.ack(d, .installed, attempt: 1)))
    }

    // ---- Confirmed, not merely dispatched ----------------------------------------------------------

    static func confirmedNotJustDispatched() {
        var r = AddonPairingReducer()
        let d = delivery("d1", raw: "a.example.com/addon")
        _ = r.ingest([d])
        _ = r.resolved(id: "d1", outcome: .ready(name: "Ready"))   // auto-install -> installing, attempt 1
        check("auto-install -> installing (NOT installed)", state(r, "d1") == .installing)
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
        _ = r.resolved(id: "d1", outcome: .ready(name: "Ready"))   // auto-install -> attempt 1, installing
        // A late failure from a PRIOR attempt (attempt 0) must not touch the row mid-install.
        let ignored = r.installed(id: "d1", attempt: 0, outcome: .failed(retryable: false, message: "stale"))
        check("stale attempt result is ignored", ignored.isEmpty && state(r, "d1") == .installing)
        // The current attempt's result applies exactly once; a duplicate of it is then dropped.
        _ = r.installed(id: "d1", attempt: 1, outcome: .installed)
        let dupe = r.installed(id: "d1", attempt: 1, outcome: .installed)
        check("duplicate confirmed result is dropped (exactly once)", dupe.isEmpty && state(r, "d1") == .installed)
    }

    // ---- Transient failure is retryable and NOT acked failed ---------------------------------------

    static func transientFailureRetryable() {
        var r = AddonPairingReducer()
        let d = delivery("d1", raw: "a.example.com/addon")
        _ = r.ingest([d])
        _ = r.resolved(id: "d1", outcome: .ready(name: "Ready"))   // auto-install -> attempt 1
        let effects = r.installed(id: "d1", attempt: 1, outcome: .failed(retryable: true, message: "blip"))
        check("transient install failure -> failed(retryable:true)", state(r, "d1") == .failed(retryable: true, message: "blip"))
        check("transient failure is NOT acked failed (still pending)", hasAnyAck(effects) == false)
        // Retry re-installs a row that already validated, at the next attempt.
        let retried = r.retry(id: "d1")
        check("retry a validated retryable-failed row -> installs at attempt 2", retried == [.install(d, attempt: 2)])
        check("retry -> installing again", state(r, "d1") == .installing)
    }

    // ---- Terminal install failure acks failed (truthful phone Done) --------------------------------

    static func terminalFailureAcksFailed() {
        var r = AddonPairingReducer()
        let d = delivery("d1", raw: "a.example.com/addon")
        _ = r.ingest([d])
        _ = r.resolved(id: "d1", outcome: .ready(name: "Ready"))   // auto-install -> attempt 1
        let effects = r.installed(id: "d1", attempt: 1, outcome: .failed(retryable: false, message: "bad manifest"))
        check("terminal install failure -> failed(retryable:false)", state(r, "d1") == .failed(retryable: false, message: "bad manifest"))
        check("terminal install failure acks failed (attempt 1)", effects.contains(.ack(d, .failed, attempt: 1)))
        // A terminal-failed row has no retry.
        check("retry on a terminal-failed row is a no-op", r.retry(id: "d1").isEmpty)
    }

    // ---- H1: a TERMINAL preview rejection acks failed (never leaves the worker/web pending) --------

    static func terminalPreviewRejectionAcksFailed() {
        var r = AddonPairingReducer()
        let d = delivery("d1", raw: "a.example.com/addon", token: "tok-C")
        _ = r.ingest([d])
        // A terminal (non-retryable) rejection during resolve: private address / bad scheme / bad manifest.
        let effects = r.resolved(id: "d1", outcome: .rejected(retryable: false, message: "private address"))
        check("terminal preview rejection -> failed(retryable:false)", state(r, "d1") == .failed(retryable: false, message: "private address"))
        check("terminal preview rejection ACKS failed (H1)", effects.contains(.ack(d, .failed, attempt: 0)))
        // And a session closed on that terminal row can now drain (nothing in flight, ack sent).
        let onClose = r.closeSeen(token: "tok-C")
        check("closed session with a terminal-preview row releases", onClose.contains(.releaseToken("tok-C")))
        // A RETRYABLE preview rejection, by contrast, is NOT acked (genuinely still pending).
        var r2 = AddonPairingReducer()
        let d2 = delivery("d2", raw: "b.example.com/addon")
        _ = r2.ingest([d2])
        let retryableEffects = r2.resolved(id: "d2", outcome: .rejected(retryable: true, message: "blip"))
        check("retryable preview rejection is NOT acked", hasAnyAck(retryableEffects) == false)
    }

    // ---- H7: a NEW delivery for an already-installed canonical URL gets an already-installed ack ----

    static func crossSessionDuplicateAcksInstalled() {
        var r = AddonPairingReducer()
        let d1 = delivery("d1", raw: "a.example.com/addon", token: "tok-A")
        _ = r.ingest([d1])
        _ = r.resolved(id: "d1", outcome: .ready(name: "Ready"))
        _ = r.installed(id: "d1", attempt: 1, outcome: .installed)   // now confirmed installed
        // A DIFFERENT delivery id on a DIFFERENT token, same canonical URL (a fresh session re-delivering it).
        let d2 = AddonDelivery(id: "d2", canonicalURL: d1.canonicalURL, rawURL: d1.rawURL, token: "tok-Z")
        let effects = r.ingest([d2])
        check("cross-session duplicate does NOT add a second row", r.rows.count == 1)
        check("cross-session duplicate sends an already-installed ack for the NEW delivery (H7)",
              effects.contains(.ack(d2, .installed, attempt: 0)))
        // Idempotent: the same duplicate arriving again does not re-ack.
        let again = r.ingest([d2])
        check("cross-session duplicate ack is exactly once", again.isEmpty)
    }

    // ---- H7: a duplicate that arrives BEFORE the canonical row confirms is acked on confirm --------

    static func pendingDuplicateAckedOnConfirm() {
        var r = AddonPairingReducer()
        let d1 = delivery("d1", raw: "a.example.com/addon", token: "tok-A")
        _ = r.ingest([d1])
        _ = r.resolved(id: "d1", outcome: .ready(name: "Ready"))   // installing (not yet confirmed)
        // A duplicate delivery (new id/token) arrives while d1 is still installing: stashed, not acked yet.
        let d2 = AddonDelivery(id: "d2", canonicalURL: d1.canonicalURL, rawURL: d1.rawURL, token: "tok-Z")
        let onIngest = r.ingest([d2])
        check("duplicate arriving mid-install is not acked yet", hasAnyAck(onIngest) == false && r.rows.count == 1)
        // When d1 confirms installed, the stashed duplicate is acked installed.
        let onConfirm = r.installed(id: "d1", attempt: 1, outcome: .installed)
        check("stashed duplicate is acked installed on confirm (H7)", onConfirm.contains(.ack(d2, .installed, attempt: 0)))
    }

    // ---- H3: the confirmed ack carries the install attempt authority -------------------------------

    static func ackCarriesInstallAttempt() {
        var r = AddonPairingReducer()
        let d = delivery("d1", raw: "a.example.com/addon")
        _ = r.ingest([d])
        _ = r.resolved(id: "d1", outcome: .ready(name: "Ready"))              // attempt 1
        _ = r.installed(id: "d1", attempt: 1, outcome: .failed(retryable: true, message: "blip"))
        _ = r.retry(id: "d1")                                                 // attempt 2
        let effects = r.installed(id: "d1", attempt: 2, outcome: .installed)
        check("ack carries the WINNING attempt (2), not the failed one", effects.contains(.ack(d, .installed, attempt: 2)))
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

    // ---- H4: the ONE shared canonical identity rule (query/fragment-safe, no double manifest) -------

    static func canonicalIdentityRule() {
        check("canonical: query-bearing manifest is NOT double-suffixed",
              canonicalAddonIdentity("https://a.example.com/manifest.json?token=AbC")
                == "https://a.example.com/manifest.json?token=AbC")
        check("canonical: a ?next=manifest.json decoy is treated as a non-manifest path",
              canonicalAddonIdentity("https://a.example.com/addon?next=manifest.json")
                == "https://a.example.com/addon/manifest.json?next=manifest.json")
        check("canonical: fragment is dropped and host lowercased",
              canonicalAddonIdentity("https://A.Example.com/manifest.json#frag")
                == "https://a.example.com/manifest.json")
        check("canonical: bare host gets /manifest.json",
              canonicalAddonIdentity("https://a.example.com") == "https://a.example.com/manifest.json")
        check("canonical: non-http(s) scheme rejected", canonicalAddonIdentity("ftp://a.example.com/x") == nil)
        check("canonical: schemeless string rejected", canonicalAddonIdentity("notaurl") == nil)
    }

    // ---- H11: a hostile remote revision never crashes (no Int(nan)/Int(1e30) trap) ------------------

    static func safeRevisionNoCrash() {
        check("safeRevision(nil) == 0", safeRevision(nil) == 0)
        check("safeRevision(NaN) == 0", safeRevision(Double.nan) == 0)
        check("safeRevision(+inf) == 0", safeRevision(Double.infinity) == 0)
        check("safeRevision(-inf) == 0", safeRevision(-Double.infinity) == 0)
        check("safeRevision(negative) == 0", safeRevision(-5) == 0)
        check("safeRevision(normal) == value", safeRevision(3.0) == 3)
        check("safeRevision(1e30) clamps to Int.max", safeRevision(1e30) == Int.max)
        check("safeRevision(Double(Int.max)) clamps (no overflow trap)", safeRevision(Double(Int.max)) == Int.max)
    }
}
