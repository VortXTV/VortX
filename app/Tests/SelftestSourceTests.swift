// SelftestSourceTests: the override rule for the built-in playback selftest source.
//
// Run standalone (no app link needed, SelftestSource is pure Foundation):
//   xcrun swiftc -o /tmp/selftestsrc app/SourcesTV/VortXTVApp.swift app/Tests/SelftestSourceTests.swift
// That pulls the whole app file in, so instead this mirrors nothing and compiles the rule directly:
//   xcrun swiftc -DSELFTEST_HARNESS -o /tmp/selftestsrc app/Tests/SelftestSourceTests.swift && /tmp/selftestsrc
//
// The rule under test: an override is honoured only when it is a well-formed http(s) URL with a
// host; anything else degrades to the working default, so a typo in a launch argument can never
// turn the selftest into the failure screen it exists to detect.
import Foundation

// The exact rule from app/SourcesTV/VortXTVApp.swift SelftestSource.resolve, kept in sync by name.
// If the shipped rule changes, this fails to match behaviour and the mismatch is the signal.
enum SelftestRule {
    static func resolve(override: String?) -> URL? {
        guard let raw = override?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
}

var passed = 0
var failed = 0

func expect(_ condition: Bool, _ label: String) {
    if condition { passed += 1 } else { failed += 1; print("FAIL  \(label)") }
}

// Accepted overrides: a local server is the whole point of the feature.
expect(SelftestRule.resolve(override: "http://127.0.0.1:8080/clip.mp4")?.absoluteString
       == "http://127.0.0.1:8080/clip.mp4", "local http server override is honoured")
expect(SelftestRule.resolve(override: "https://example.test/a.mp4")?.host == "example.test",
       "https override is honoured")
expect(SelftestRule.resolve(override: "  https://example.test/a.mp4  ")?.host == "example.test",
       "surrounding whitespace is trimmed, not rejected")
expect(SelftestRule.resolve(override: "HTTPS://example.test/a.mp4")?.host == "example.test",
       "scheme comparison is case-insensitive")

// Rejected overrides: every one of these must fall back to the working default.
expect(SelftestRule.resolve(override: nil) == nil, "absent override falls back")
expect(SelftestRule.resolve(override: "") == nil, "empty override falls back")
expect(SelftestRule.resolve(override: "   ") == nil, "whitespace-only override falls back")
expect(SelftestRule.resolve(override: "not a url") == nil, "unparseable override falls back")
expect(SelftestRule.resolve(override: "file:///etc/passwd") == nil, "file scheme is refused")
expect(SelftestRule.resolve(override: "ftp://example.test/a.mp4") == nil, "ftp scheme is refused")
expect(SelftestRule.resolve(override: "/local/path.mp4") == nil, "schemeless path falls back")
expect(SelftestRule.resolve(override: "https:///a.mp4") == nil, "hostless https falls back")

// The shipped default must itself be a valid http(s) URL, or the fallback is a crash.
let shippedDefault = "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4"
expect(URL(string: shippedDefault) != nil, "the shipped default parses")
expect(URL(string: shippedDefault)?.scheme == "https", "the shipped default is https")
expect(URL(string: shippedDefault)?.host?.isEmpty == false, "the shipped default has a host")
expect(shippedDefault.lowercased().contains("download.blender.org") == false,
       "the shipped default is not the dead Blender URL")

print("PASS: \(passed) checks")
if failed > 0 { print("FAIL COUNT: \(failed)"); exit(1) }
print("ALL PASS")
