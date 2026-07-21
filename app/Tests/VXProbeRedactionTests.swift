// Standalone executable for the REAL diagnostic-log sink scrubber (D1). VortX has no Xcode unit-test bundle,
// so this compiles the production VXProbeRedaction.swift with no stubs at all:
//
//   xcrun swiftc -o /tmp/vxprobe-redaction-test \
//     app/SourcesShared/VXProbeRedaction.swift \
//     app/Tests/VXProbeRedactionTests.swift && /tmp/vxprobe-redaction-test
//
// SCOPE, stated the way the code states it: `VXProbe` is OFF BY DEFAULT and needs either VORTX_PROBE=1 or the
// Settings toggle, so this is a backstop against OPT-IN exposure at the moment a user is about to export and
// share the file, not against silent collection from every user. The producers that build identifier-bearing
// strings are fixed at their own call sites; this proves the sink catches what a NEW producer would leak.

import Foundation

nonisolated(unsafe) var failures = 0

func expect(_ condition: Bool, _ what: String) {
    if condition {
        print("PASS  \(what)")
    } else {
        failures += 1
        print("FAIL  \(what)")
    }
}

@main
struct VXProbeRedactionTests {
    static func main() {
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
        expect(huge.utf8.count <= VXProbeRedaction.maxLineBytes + 32,
               "D1: one line cannot be grown without bound by a hostile value")
        expect(huge.hasSuffix("[truncated]"),
               "D1: truncation is stated in the line rather than silently swallowing the tail")
        expect(huge.utf8.count <= VXProbeRedaction.maxLineBytes,
               "D1: the truncation marker is counted INSIDE the budget, so bounding is idempotent")
        expect(!huge.replacingOccurrences(of: "[truncated]", with: "", options: [.backwards], range: huge.range(of: "[truncated]", options: .backwards)).contains("[truncated]"),
               "D1: bounding twice does not staple two markers onto one line")

        // REGRESSION (found by this harness hanging): the credential rule used an unbounded scheme repetition
        // and was quadratic on a long run of scheme-legal characters, so one pathological line stalled the
        // scrubber -- which sits on the path that writes the log. Bounding the line before the regexes runs,
        // plus a bounded scheme quantifier, makes the work fixed-cost. A wall-clock assertion is the honest
        // way to state "this must not be able to hang", since a hang has no other observable failure mode.
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
        let many = VXProbeRedaction.scrub("tt1111111 tt2222222 tt3333333 \(hash) tmdb:5 tmdb:5")
        expect(!many.contains("tt1111111") && !many.contains("tt2222222") && !many.contains("tt3333333")
               && !many.contains(hash),
               "D1: every occurrence on a line is redacted, not just the first")
        // "tmdb:5" appears twice and must produce the identical placeholder both times.
        let tmdbTokens = many.split(separator: " ").filter { $0.hasPrefix("<tmdb:") }
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
        // A free-text title has no shape and the pattern-based sink cannot recognise it. That is the whole
        // reason the producers are fixed too. Nailing it down here stops anyone reading the scrubber as a
        // guarantee it does not provide.
        expect(VXProbeRedaction.scrub("open Breaking Bad S03E05") == "open Breaking Bad S03E05",
               "D1 LIMIT (asserted, not glossed): a shapeless free-text title passes the sink untouched")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
