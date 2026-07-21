// Standalone executable for the REAL diagnostic-log sink scrubber and the ONE durable-line formatter.
// VortX has no Xcode unit-test bundle, so this compiles the production VXProbeRedaction.swift with no stubs
// at all:
//
//   xcrun swiftc -o /tmp/vxprobe-redaction-test \
//     app/SourcesShared/VXProbeRedaction.swift \
//     app/Tests/VXProbeRedactionTests.swift && /tmp/vxprobe-redaction-test
//
// (run from the repo root; the command above is executed verbatim as part of every verification pass.)
//
// SCOPE, stated the way the code states it. This covers the SINK, and the sink is permanently best-effort:
// an adversarial pass over the previous revision walked identifiers through it SEVEN different ways, which
// is the evidence for the claim rather than a rhetorical hedge. Those seven have a case each below. The
// typed-field contract at the producers is the real protection; what is proven here is that the net under it
// has the holes closed that we know about, and the two limits it cannot close are asserted rather than
// glossed (a shapeless free-text title, and the correlation-not-anonymity property of the placeholder).
//
// A HANG IS NOT A RED TEST, so this binary arms a watchdog thread before it does anything else: if the whole
// suite has not finished within `watchdogSeconds` the process exits NON-ZERO. Two cases here deliberately
// feed 200 KB of adversarial input to code whose earlier revision stalled on exactly that.

import Foundation
import CryptoKit

nonisolated(unsafe) var failures = 0

func expect(_ condition: Bool, _ what: String) {
    if condition {
        print("PASS  \(what)")
    } else {
        failures += 1
        print("FAIL  \(what)")
    }
}

/// Wall-clock ceiling for the WHOLE suite. Generous next to the ~1s the suite actually takes, so it fires
/// only on a genuine stall, and a stall is precisely what an unbounded regex quantifier produces.
let watchdogSeconds = 60.0

func armWatchdog() {
    let thread = Thread {
        Thread.sleep(forTimeInterval: watchdogSeconds)
        FileHandle.standardError.write(Data("\nFAIL  watchdog: suite exceeded \(watchdogSeconds)s (a stall is a FAILURE, not a slow pass)\n".utf8))
        exit(2)
    }
    thread.stackSize = 512 * 1024
    thread.start()
}

/// The unkeyed placeholder a salt-free `token` would produce. Used to prove the salt is actually mixed in.
func unsaltedToken(_ tag: String, _ value: String) -> String {
    var hasher = SHA256()
    hasher.update(data: Data(value.utf8))
    let hex = hasher.finalize().prefix(3).map { String(format: "%02x", $0) }.joined()
    return "<\(tag):\(hex)>"
}

@main
struct VXProbeRedactionTests {
    static func main() {
        armWatchdog()

        let hash = "bbe3eb70b55e5ffc0e4eb30fbf33c2ca92fad49e"
        let passkey = "0123456789abcdef0123456789abcdef01234567"

        // ---- Catalog identities: these ARE viewing history ----
        let episode = VXProbeRedaction.scrub("lang fetch key=tt0903747:3:5 seen=4")
        expect(!episode.contains("tt0903747") && !episode.contains("0903747"),
               "D1: an imdb catalog id never survives to the written line")
        expect(episode.contains(":3:5"),
               "D1: the episode coordinates DO survive, because they are the triage value and do not name the title")
        expect(episode.contains("seen=4"),
               "D1: everything that is not an identifier is left completely alone")

        let tmdb = VXProbeRedaction.scrub("refresh id=tmdb:94997 s=3 e=6")
        expect(!tmdb.contains("94997"), "D1: a tmdb catalog id never survives either")

        // ---- Correlation is preserved WITHIN one run: the same id yields the same placeholder ----
        expect(VXProbeRedaction.scrub("a tt0903747") == VXProbeRedaction.scrub("a tt0903747"),
               "D1: one identifier maps to one stable placeholder, so lines about one title still correlate")
        expect(VXProbeRedaction.scrub("tt0903747") != VXProbeRedaction.scrub("tt1375666"),
               "D1: two different identifiers map to two different placeholders, so triage is not flattened")

        // ---- 40-hex tokens: infohashes AND private tracker passkeys share this shape ----
        let hexes = VXProbeRedaction.scrub("hash \(hash) tracker https://tr.example/\(passkey)/announce")
        expect(!hexes.contains(hash) && !hexes.contains(passkey),
               "D1: every 40-hex run is redacted, which covers a private tracker passkey as well as an infohash")

        // ---- URL-embedded credentials ----
        let creds = VXProbeRedaction.scrub("open https://user:hunter2@host.example/file.mkv?token=SECRET-abc123&q=1")
        expect(!creds.contains("hunter2") && !creds.contains("user:hunter2"),
               "D1: URL userinfo is redacted")
        expect(!creds.contains("SECRET-abc123"),
               "D1: a credential-bearing query value is redacted")
        expect(creds.contains("host.example") && creds.contains("q=1"),
               "D1: the host and the non-sensitive query survive, so the line is still worth reading")

        // ---- Line length is capped ----
        let huge = VXProbeRedaction.scrub(String(repeating: "z", count: 200_000))
        expect(huge.utf8.count <= VXProbeRedaction.maxLineBytes,
               "D1: one line cannot be grown without bound by a hostile value")
        expect(huge.hasSuffix("[truncated]"),
               "D1: truncation is stated in the line rather than silently swallowing the tail")
        expect(!huge.replacingOccurrences(of: "[truncated]", with: "", options: [.backwards], range: huge.range(of: "[truncated]", options: .backwards)).contains("[truncated]"),
               "D1: bounding twice does not staple two markers onto one line")

        // REGRESSION (found by this harness hanging): the credential rule used an unbounded scheme repetition
        // and was quadratic on a long run of scheme-legal characters, so one pathological line stalled the
        // scrubber -- which sits on the path that writes the log. Bounding the line before the regexes runs,
        // plus a bounded scheme quantifier, makes the work fixed-cost.
        let started = Date()
        for _ in 0..<20 {
            _ = VXProbeRedaction.scrub(String(repeating: "z", count: 200_000))
            _ = VXProbeRedaction.scrub(String(repeating: "a", count: 100_000) + "://x@y")
        }
        expect(Date().timeIntervalSince(started) < 5,
               "D1: a pathological 200 KB line is bounded work, not a stall on the logging path")

        expect(VXProbeRedaction.scrub("short line") == "short line",
               "D1: a line under the cap is returned byte-identical, so the common path costs nothing")

        // ---- Multi-occurrence and adjacency: the replacement walk must not corrupt later matches ----
        let many = VXProbeRedaction.scrub("tt1111111 tt2222222 tt3333333 \(hash) tmdb:5555555 tmdb:5555555")
        expect(!many.contains("tt1111111") && !many.contains("tt2222222") && !many.contains("tt3333333")
               && !many.contains(hash),
               "D1: every occurrence on a line is redacted, not just the first")
        let tmdbTokens = many.split(separator: " ").filter { $0.hasPrefix("<id:") }
        expect(tmdbTokens.count == 2 && tmdbTokens[0] == tmdbTokens[1],
               "D1: repeated occurrences of one identifier stay correlated with each other")

        // ---- The producer-side spelling yields the same placeholder ----
        expect(VXProbeRedaction.identityToken("tt0903747") == VXProbeRedaction.token("id", "tt0903747"),
               "D2: a producer that redacts at the call site gets the same stable placeholder")
        expect(VXProbeRedaction.identityToken(nil) == "-" && VXProbeRedaction.identityToken("") == "-",
               "D2: an absent identity is a plain dash, not a hash of the empty string")
        expect(!VXProbeRedaction.identityToken("Breaking Bad").contains("Breaking"),
               "D2: the producer-side helper also covers values with NO identifier shape, which the sink cannot see")

        // ---- Honest limit, asserted rather than merely claimed ----
        expect(VXProbeRedaction.scrub("open Breaking Bad S03E05") == "open Breaking Bad S03E05",
               "D1 LIMIT (asserted, not glossed): a shapeless free-text title passes the sink untouched")

        sinkGaps(hash: hash)
        truncationLeak()
        producerBounding()
        durableLineContract()
        mutationSurvivors()

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - A. The seven sink gaps, one case each

    /// Each of these was VERIFIED to walk an identifier through the previous revision. They are written as
    /// the reader's question ("does the value come back out?") rather than as a claim about the rule text.
    static func sinkGaps(hash: String) {
        // GAP 1: the rule demanded seven digits while our own producers accept six.
        // SourceIndexContract.canonicalContentID is tt[0-9]{6,10}; CommunityTrickplay.ttPrefix is ^tt\d{6,}.
        let six = VXProbeRedaction.scrub("resume key=tt123456:1:2")
        expect(!six.contains("123456"),
               "A1: a SIX-digit tt id is redacted, because our own producers mint six-digit ids")

        // GAP 2: the hex rule matched EXACTLY 40, so near-miss lengths failed open instead of degrading.
        let hex41 = hash + "a"
        let hex64 = "f5cf9f2f2b0b2e3a0c8a6ad3ff6d2f6df20bd25f4e7b6ea9dbd1a9e6b7f3c1d2"
        let near = VXProbeRedaction.scrub("v1=\(hex41) v2=\(hex64)")
        expect(!near.contains(hex41) && !near.contains(hash),
               "A2a: a 41-hex run is redacted, so an off-by-one length DEGRADES instead of failing open")
        expect(!near.contains(hex64),
               "A2b: a 64-hex BitTorrent v2 infohash is redacted, not just the v1 40-hex shape")

        // GAP 3: the credential list omitted auth_token (Real-Debrid's actual spelling) and had no rule at
        // all for an Authorization header.
        let rd = VXProbeRedaction.scrub("GET https://api.example/torrents?auth_token=RD-9f8e7d6c5b&limit=10")
        expect(!rd.contains("RD-9f8e7d6c5b"),
               "A3a: auth_token is redacted, and by matching credential words ANYWHERE in the parameter name")
        expect(rd.contains("limit=10"), "A3a: a non-credential parameter is still readable")
        let bearer = VXProbeRedaction.scrub("hdr Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.QQQQQQQQ")
        expect(!bearer.contains("eyJhbGciOiJIUzI1NiJ9"),
               "A3b: Authorization: Bearer <jwt> is redacted, which had no rule at all")
        // Isolates the header rule from the bearer rule and the JWT rule: an opaque non-bearer credential in
        // an Authorization header matches neither of those, so only the header rule can catch it. Without
        // this case, deleting the header rule left the suite green.
        let opaque = VXProbeRedaction.scrub("hdr Authorization: Token 9f8e7d6c5b4a3928")
        expect(!opaque.contains("9f8e7d6c5b4a3928"),
               "A3c: an Authorization header carrying an opaque non-bearer credential is redacted too")

        // GAP 4: a newline in a record forged a SECOND log line with an attacker-chosen timestamp.
        let forged = VXProbeRedaction.scrub("ok\n2026-07-21 00:00:00.000 [engine] all clear")
        expect(!forged.contains("\n") && !forged.contains("\r"),
               "A4a: a newline inside a value cannot survive into the written line")
        expect(forged.contains("\\n"),
               "A4b: it is escaped visibly rather than dropped, so the forgery attempt is still readable")
        let cr = VXProbeRedaction.scrub("a\rb\u{2028}c\u{0085}d\u{0007}e")
        expect(!cr.contains("\r") && !cr.contains("\u{2028}") && !cr.contains("\u{0085}") && !cr.contains("\u{0007}"),
               "A4c: CR, U+2028, U+0085 and a raw C0 control are all neutralised, not only LF")

        // GAP 5: unicode evasion was total.
        let evasions: [(String, String)] = [
            ("zero-width space", "tt\u{200B}0903747"),
            ("zero-width joiner", "tt\u{200D}0903747"),
            ("combining mark", "tt0\u{0301}903747"),
            ("fullwidth digits", "\u{FF54}\u{FF54}\u{FF10}\u{FF19}\u{FF10}\u{FF13}\u{FF17}\u{FF14}\u{FF17}"),
            ("cyrillic homoglyphs", "\u{0442}\u{0442}0903747"),
            ("RTL override", "tt\u{202E}0903747")
        ]
        for (name, value) in evasions {
            let out = VXProbeRedaction.scrub("play id=\(value)")
            expect(!out.contains("0903747") && !out.contains("903747"),
                   "A5: unicode evasion via \(name) does not carry an id through the sink")
        }

        // GAP 6: `\btt` required a non-word character before the id, so an underscore hid it.
        let glued = VXProbeRedaction.scrub("cache id_tt0903747 hit")
        expect(!glued.contains("0903747"),
               "A6: an id preceded by a word character (id_tt0903747) is still redacted")

        // GAP 7: the tmdb rule bounded the digit run at 10 and so failed ENTIRELY on 11 digits.
        let long = VXProbeRedaction.scrub("meta tmdb:123456789012 done")
        expect(!long.contains("123456789012"),
               "A7: an 11+ digit tmdb id is redacted, rather than the bound making the whole rule miss")
    }

    // MARK: - The truncation leak

    /// bound -> redact -> bound cannot be made safe by ordering alone: at one padding, 22 of 40 hex
    /// characters survived the cut. The fix is that truncation retreats to a token boundary, so a value that
    /// straddles the cap is removed WHOLE. Swept across every padding so no single lucky offset can pass.
    static func truncationLeak() {
        let hash = "bbe3eb70b55e5ffc0e4eb30fbf33c2ca92fad49e"
        var leaked: String?
        for padding in 900...1100 {
            let line = String(repeating: "p", count: padding) + " infohash=" + hash + " tail"
            let out = VXProbeRedaction.scrub(line)
            // Any surviving run of 8+ hex characters is a searchable fragment of the real hash.
            for length in stride(from: hash.count, through: 8, by: -1) {
                let prefix = String(hash.prefix(length))
                if out.contains(prefix) { leaked = "padding=\(padding) kept \(length) of \(hash.count) hex chars"; break }
            }
            if leaked != nil { break }
        }
        expect(leaked == nil,
               "A8: no prefix of a straddling 40-hex value survives at ANY padding around the cap (\(leaked ?? "none"))")
    }

    // MARK: - F. Bound BEFORE tokenizing

    /// `token` used to build Data(value.utf8) over the COMPLETE raw value, and `identityToken` hands it
    /// arbitrary producer strings, so unbounded allocation came back at the PRODUCER even with `scrub`
    /// bounded. Testing `scrub` alone never touched this path, which is why it survived.
    static func producerBounding() {
        let started = Date()
        var last = ""
        for _ in 0..<50 { last = VXProbeRedaction.identityToken(String(repeating: "q", count: 200_000)) }
        expect(Date().timeIntervalSince(started) < 5,
               "F: identityToken on a 200 KB producer value is bounded work, not an unbounded copy per call")
        expect(last.hasPrefix("<id:") && last.count <= 12,
               "F: a huge producer value still collapses to one short placeholder")
        expect(VXProbeRedaction.token("id", String(repeating: "q", count: 600))
               == VXProbeRedaction.token("id", String(repeating: "q", count: 700)),
               "F LIMIT (asserted, not glossed): two values sharing their first maxTokenInputBytes collapse to one placeholder")
    }

    // MARK: - C/D. The COMPLETE durable line

    static func durableLineContract() {
        let stamp = "2026-07-21 12:00:00.000"

        let plain = VXProbeRedaction.durableLine(timestamp: stamp, category: "dv", message: "route ok")
        expect(plain == "\(stamp) [dv] route ok\n",
               "C1: the ordinary line is formed exactly as before, with one trailing newline")

        // The CATEGORY is scrubbed too. DiagnosticsLog takes a free-form String category from 152 call
        // sites, so an unguarded category meant there was no chokepoint at all.
        let cat = VXProbeRedaction.durableLine(timestamp: stamp, category: "tt0903747", message: "x")
        expect(!cat.contains("0903747"), "C2: the category is scrubbed, not only the message")
        let forgedCat = VXProbeRedaction.durableLine(timestamp: stamp, category: "a]\nfake [b", message: "x")
        expect(forgedCat.filter { $0 == "\n" }.count == 1,
               "C3: a newline in the CATEGORY cannot forge a second line either")

        // The cap covers the COMPLETE line. The old constant capped the message and then had a timestamp,
        // brackets and a category appended after the fact, so the written line exceeded its own limit.
        let longLine = VXProbeRedaction.durableLine(timestamp: stamp,
                                                    category: String(repeating: "c", count: 400),
                                                    message: String(repeating: "m ", count: 5000))
        expect(longLine.utf8.count <= VXProbeRedaction.maxLineBytes,
               "C4: the COMPLETE line including timestamp, category and newline is <= maxLineBytes (got \(longLine.utf8.count))")
        expect(longLine.filter { $0 == "\n" }.count == 1,
               "C4: and it still terminates with exactly one newline")

        let stampForged = VXProbeRedaction.durableLine(timestamp: "2026-07-21\n[boom]", category: "c", message: "m")
        expect(stampForged.filter { $0 == "\n" }.count == 1,
               "C5: the timestamp field is guarded as well, because an unguarded parameter is not a chokepoint")
    }

    // MARK: - H. The two mutation survivors

    static func mutationSurvivors() {
        // N18: deleting the salt from `token` left the whole suite green. The mutant is NOT equivalent: it
        // turns every placeholder into a plain unkeyed SHA-256 prefix, and the id space (every tt id ever
        // minted) is small enough to enumerate exhaustively, so the placeholders become reversible. The
        // check is that a real token does NOT equal the unsalted digest of the same value. Each value has a
        // 2^-24 chance of colliding by luck; over eight values that is ~5e-7, which is stated rather than
        // ignored.
        let values = ["tt0903747", "tt1375666", "tmdb:94997", "kitsu:1", "a", "", "0123456789abcdef", "x y z"]
        var salted = 0
        for value in values where VXProbeRedaction.token("id", value) != unsaltedToken("id", value) { salted += 1 }
        expect(salted == values.count,
               "H-N18: the placeholder is SALTED (an unsalted SHA-256 prefix is enumerable over the whole id space)")

        // N16: the bounded scheme quantifier `{0,15}` was unasserted, and could not be asserted through
        // `scrub` because `scrub` bounds the line to 1 KiB first, which hides the quadratic cost. Driving
        // `redactAll` directly is the only place the bound is observable.
        //
        // The input has NO "://" in it, and that detail is the whole test. A scheme-legal run that ENDS in a
        // match short-circuits: the engine finds it on the first start position and never backtracks, so a
        // trailing "://user:pw@host/" makes the unbounded pattern look fast and the case prove nothing (it
        // did, and the mutant survived until this was corrected). It is the run that never matches which
        // costs a full re-scan per start position: measured on this machine, an unbounded quantifier takes
        // over 30s on 50 KB and the bounded one takes 0.035s. With `*` this call does not return in any
        // useful time; the suite watchdog turns that stall into a FAILURE rather than a hang.
        let started = Date()
        _ = VXProbeRedaction.redactAll(String(repeating: "a", count: 200_000))
        let elapsed = Date().timeIntervalSince(started)
        expect(elapsed < 10,
               "H-N16: redactAll on an UNBOUNDED 200 KB scheme-legal run returns in \(String(format: "%.2f", elapsed))s, proving the scheme quantifier is bounded")

        // ...and it still redacts, so the bound was not bought by breaking the rule.
        expect(!VXProbeRedaction.redactAll("open ftp://user:hunter2@host/f").contains("hunter2"),
               "H-N16: the bounded rule still redacts ordinary URL userinfo")
    }
}
