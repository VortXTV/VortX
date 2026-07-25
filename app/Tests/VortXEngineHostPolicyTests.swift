// Executable harness for the EXTERNAL ENGINE MODE routing/auth/failover decisions.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/vortx-engine-host-policy-test \
//     app/SourcesShared/VortXEngineHostPolicy.swift \
//     app/Tests/VortXEngineHostPolicyTests.swift && /tmp/vortx-engine-host-policy-test
//
// This suite CALLS the production decisions (the RemuxResumePolicyTests pattern). VortXEngineHostPolicy is pure
// Foundation with no other dependencies, so it compiles standalone with no stubs required.
//
// The single property that matters more than any other, per the source's own TOP INVARIANT comment: **with
// external mode off (no capability), every decision must reduce to today's shipping behaviour exactly** —
// method-blind, Range-blind, path-exact, and it must NEVER reject a request that today's server would have
// answered. Section 1 below (`defaultOff*`) pins that equivalence; everything after it is the strict HTTP layer
// that only ever activates for a LAN-hosted session with a real capability.
//
// A genuine bug was found in `normalizeHost` while writing this suite (see the "BUG" comment in section 4): the
// unbracketed `host:port` split is dead code, so a typed port is silently ignored in favour of the default. The
// source was left untouched per instructions; the tests below assert the ACTUAL behaviour and are annotated with
// what the doc comment / an unbracketed caller would reasonably have expected instead.

import Foundation

@MainActor var failures = 0
@MainActor func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

/// `(host:port)?` is a tuple type, which cannot conform to `Equatable`, so `Optional<(String, Int)>` has no `==`
/// overload (proven by direct compilation before writing this suite). This local comparator is the tuple
/// counterpart to `RemuxResumePolicyTests.near` for floating point: a tiny helper standing in for an operator
/// the standard library does not provide here.
func hostsEqual(_ a: (host: String, port: Int)?, _ b: (host: String, port: Int)?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (l?, r?): return l.host == r.host && l.port == r.port
    default: return false
    }
}

@MainActor @main
enum VortXEngineHostPolicyTests {
    static func main() { run() }
}

@MainActor func run() {

typealias P = VortXEngineHostPolicy

// MARK: - 1. Default-off equivalence (THE most important group)
//
// Every case here passes `capability: nil`, which is the shape of every session today: no engine host
// configured, loopback only. `route` must reduce to the shipping parse — method-blind, Range-blind, path-exact —
// for every one of these, and the malformed-request-line case must still fail exactly as it does today (a 400,
// not a new rejection shape).

check("default-off: a normal GET routes to legacy with the exact path",
      P.route(header: "GET /master.m3u8 HTTP/1.1", capability: nil) == .legacy(path: "/master.m3u8"))

check("default-off: a query string is stripped from the legacy path",
      P.route(header: "GET /seg7.m4s?x=1 HTTP/1.1", capability: nil) == .legacy(path: "/seg7.m4s"))

// The byte-identical promise in one assertion: an utterly unrecognised method must still be served, never
// rejected, because today's server has never once looked at the method.
check("default-off: an unusual method still routes to legacy, never rejected",
      P.route(header: "WOMBAT /master.m3u8 HTTP/1.1", capability: nil) == .legacy(path: "/master.m3u8"))

// Range-blind: a Range header must not change the outcome or be surfaced anywhere in a legacy route.
check("default-off: a Range header is present but ignored",
      P.route(header: "GET /master.m3u8 HTTP/1.1\r\nRange: bytes=0-99", capability: nil)
        == .legacy(path: "/master.m3u8"))

// The one case a loopback session DOES reject today: a request line that does not even have a path.
check("default-off: fewer than 2 space-separated parts on the request line is 400",
      P.route(header: "GET", capability: nil) == .reject(status: "400 Bad Request"))

check("default-off: bindHost with no capability is loopback",
      P.bindHost(capability: nil) == .loopback)

// A weak credential must never open the LAN. Each of these is well-formed enough to *look* like a real
// capability at a glance but fails `isWellFormedCapability`, so both the bind and the route must degrade to
// exactly the loopback/legacy behaviour above rather than half-authenticating.
let weakCapabilities: [(String, String)] = [
    ("malformed (contains a non-hex character)", String(repeating: "g", count: 32)),
    ("short (31 chars)", String(repeating: "a", count: 31)),
    ("uppercase hex (32 chars)", String(repeating: "A", count: 32)),
]
for (label, weak) in weakCapabilities {
    check("default-off: bindHost with a \(label) capability is loopback",
          P.bindHost(capability: weak) == .loopback)
    check("default-off: route with a \(label) capability still routes to legacy",
          P.route(header: "GET /master.m3u8 HTTP/1.1", capability: weak) == .legacy(path: "/master.m3u8"))
}

// MARK: - 2. Capability auth

let capA = P.makeCapability()
let capB = P.makeCapability()

check("capability: makeCapability produces 32 lowercase hex characters",
      capA.count == 32 && capA.allSatisfy { $0.isHexDigit && !$0.isUppercase })
check("capability: two mints differ",
      capA != capB)

check("capability: a minted capability is well-formed",
      P.isWellFormedCapability(capA))
check("capability: an empty string is not well-formed",
      !P.isWellFormedCapability(""))
check("capability: 31 characters is not well-formed",
      !P.isWellFormedCapability(String(repeating: "a", count: 31)))
check("capability: 33 characters is not well-formed",
      !P.isWellFormedCapability(String(repeating: "a", count: 33)))
check("capability: uppercase hex is not well-formed",
      !P.isWellFormedCapability(String(repeating: "A", count: 32)))
check("capability: a non-hex character is not well-formed",
      !P.isWellFormedCapability(String(repeating: "g", count: 32)))

check("capability: bindHost is allInterfaces only for a well-formed capability",
      P.bindHost(capability: capA) == .allInterfaces)

// The authenticated happy path: the capability prefix is stripped so the resource switch sees the same path it
// always has. Checked for both methods the guarded lane accepts.
let goodPath = "/r/\(capA)/seg3.m4s"
check("capability: a correctly prefixed GET routes to guarded with the prefix stripped",
      P.route(header: "GET \(goodPath) HTTP/1.1", capability: capA)
        == .guarded(method: .get, path: "/seg3.m4s", range: nil))
check("capability: a correctly prefixed HEAD routes to guarded with the prefix stripped",
      P.route(header: "HEAD \(goodPath) HTTP/1.1", capability: capA)
        == .guarded(method: .head, path: "/seg3.m4s", range: nil))

// Silent close, no body, for every way a peer can fail to present the right credential. `status: nil` is the
// contract: an unauthorised LAN peer learns nothing beyond "a TCP port is open".
check("capability: a wrong capability in the path is a silent reject",
      P.route(header: "GET /r/wrongcapabilityvaluenotevenhex/seg3.m4s HTTP/1.1", capability: capA)
        == .reject(status: nil))
check("capability: a missing prefix is a silent reject",
      P.route(header: "GET /seg3.m4s HTTP/1.1", capability: capA) == .reject(status: nil))
check("capability: a truncated prefix is a silent reject",
      P.route(header: "GET /r/\(capA.dropLast(5))/seg3.m4s HTTP/1.1", capability: capA) == .reject(status: nil))
check("capability: a prefix belonging to a different (well-formed) session is a silent reject",
      P.route(header: "GET /r/\(capB)/seg3.m4s HTTP/1.1", capability: capA) == .reject(status: nil))

// Defensive traversal rejection, even though the resource switch never touches a filesystem.
check("capability: a resource containing .. after the prefix is a silent reject",
      P.route(header: "GET /r/\(capA)/../etc/passwd HTTP/1.1", capability: capA) == .reject(status: nil))
check("capability: a resource containing // after the prefix is a silent reject",
      P.route(header: "GET /r/\(capA)//seg3.m4s HTTP/1.1", capability: capA) == .reject(status: nil))

check("capability: a method that is not GET/HEAD is 405",
      P.route(header: "DELETE \(goodPath) HTTP/1.1", capability: capA)
        == .reject(status: "405 Method Not Allowed"))

let overLongPath = "/r/\(capA)/" + String(repeating: "a", count: 3000)
let overLongLine = "GET \(overLongPath) HTTP/1.1"
check("capability: an over-long request line is rejected before it is even measured",
      overLongLine.utf8.count > P.maxRequestLineBytes
        && P.route(header: overLongLine, capability: capA) == .reject(status: "400 Bad Request"))

// MARK: - 3. Range parsing and resolution

check("range: bytes=0-99 parses to fromTo",
      P.parseRangeValue("bytes=0-99") == .fromTo(0, 99))
check("range: bytes=100- parses to from",
      P.parseRangeValue("bytes=100-") == .from(100))
check("range: bytes=-50 parses to suffix",
      P.parseRangeValue("bytes=-50") == .suffix(50))
check("range: bytes=abc has no dash and is rejected",
      P.parseRangeValue("bytes=abc") == nil)
check("range: a value with no bytes= prefix is rejected",
      P.parseRangeValue("100-200") == nil)
check("range: a multi-range value is deliberately unsupported",
      P.parseRangeValue("bytes=0-9,20-29") == nil)
check("range: an inverted range (end before start) is rejected",
      P.parseRangeValue("bytes=200-100") == nil)

// Case-insensitive header discovery, and nil when the header is simply absent.
check("range: a lowercase range: header is found",
      P.parseRange(header: ["GET / HTTP/1.1", "range: bytes=0-9"]) == .fromTo(0, 9))
check("range: a title-case Range: header is found",
      P.parseRange(header: ["GET / HTTP/1.1", "Range: bytes=0-9"]) == .fromTo(0, 9))
check("range: an uppercase RANGE: header is found",
      P.parseRange(header: ["GET / HTTP/1.1", "RANGE: bytes=0-9"]) == .fromTo(0, 9))
check("range: no Range header at all returns nil",
      P.parseRange(header: ["GET / HTTP/1.1"]) == nil)

// resolve() against a known resource length.
check("range: fromTo(0,99) on length 1000 is 0...99",
      P.resolve(.fromTo(0, 99), length: 1000) == 0...99)
check("range: fromTo(0,5000) on length 1000 clamps to 0...999",
      P.resolve(.fromTo(0, 5000), length: 1000) == 0...999)
check("range: from(990) on length 1000 is 990...999",
      P.resolve(.from(990), length: 1000) == 990...999)
check("range: from(1000) on length 1000 is unsatisfiable",
      P.resolve(.from(1000), length: 1000) == nil)
check("range: suffix(50) on length 1000 is 950...999",
      P.resolve(.suffix(50), length: 1000) == 950...999)
check("range: suffix(5000) on length 1000 clamps to the whole resource",
      P.resolve(.suffix(5000), length: 1000) == 0...999)
check("range: any spec on a zero-length resource is unsatisfiable",
      P.resolve(.fromTo(0, 10), length: 0) == nil)

// A guarded route must carry the parsed range through unchanged, so the connection handler can resolve it
// against the resource it is about to serve.
check("range: a guarded route carries the parsed Range through",
      P.route(header: "GET \(goodPath) HTTP/1.1\r\nRange: bytes=0-99", capability: capA)
        == .guarded(method: .get, path: "/seg3.m4s", range: .fromTo(0, 99)))

// MARK: - 4. Host normalization
//
// BUG FOUND (documented, not fixed — source left untouched per instructions): the unbracketed "single colon is
// host:port" branch is dead code. It is guarded by `!text.dropFirst().contains(":")`, which drops exactly one
// CHARACTER from the front of the whole host string, not everything up to and including the colon. For any
// realistic "host:port" string the colon still appears after dropping one character, so the condition is false
// and the branch never runs — the port is silently left at `defaultControlPort` and the full "host:port" text is
// kept as the host verbatim. Only the bracketed IPv6 form (`[fe80::1]:9000`) actually splits a custom port,
// because that path does not go through the broken condition at all.
//
// Practical impact: a user typing `192.168.1.33:9000` into the engine host field gets silently routed to port
// 11471 (the default) against host string `"192.168.1.33:9000"` instead of port 9000 against `"192.168.1.33"`.
// The malformed-port guards (`host:notaport`, `host:0`, `host:70000`) are unreachable for the same reason: since
// the split never happens, `Int(...)` parsing of the port half never runs, so these strings pass through as a
// "valid" (wrong) host with the default port instead of being rejected as the code intends.
//
// The assertions below pin the ACTUAL shipped behaviour (verified by direct compilation against the real
// function before writing this suite), each annotated with what a reader of the doc comment would otherwise
// expect.

check("host: a bare IP normalizes with the default port",
      hostsEqual(P.normalizeHost("192.168.1.33"), (host: "192.168.1.33", port: 11471)))
// BUG: expected (host: "192.168.1.33", port: 9000) per the doc comment; the port is dropped and swallowed into
// the (unsplit) host string instead. See the BUG note above.
check("host: BUG - an unbracketed host:port does NOT split out the port",
      hostsEqual(P.normalizeHost("192.168.1.33:9000"), (host: "192.168.1.33:9000", port: 11471)))
// BUG: same root cause once the scheme and trailing slash are correctly stripped.
check("host: BUG - a scheme+port URL strips scheme/slash but still keeps host:port fused",
      hostsEqual(P.normalizeHost("http://192.168.1.33:9000/"), (host: "192.168.1.33:9000", port: 11471)))
check("host: surrounding whitespace is trimmed",
      hostsEqual(P.normalizeHost("  mac.local  "), (host: "mac.local", port: 11471)))
check("host: a bracketed IPv6 literal with a port splits correctly",
      hostsEqual(P.normalizeHost("[fe80::1]:9000"), (host: "fe80::1", port: 9000)))
check("host: a bracketed IPv6 literal with no port uses the default",
      hostsEqual(P.normalizeHost("[fe80::1]"), (host: "fe80::1", port: 11471)))
// This one happens to match the doc comment's stated intent ("not mangled"), but only as a side effect of the
// same dead branch above, not because of deliberate multi-colon detection.
check("host: a bare (unbracketed) IPv6 literal is kept whole, not mangled",
      hostsEqual(P.normalizeHost("fe80::1:2:3"), (host: "fe80::1:2:3", port: 11471)))
check("host: nil input normalizes to nil",
      P.normalizeHost(nil) == nil)
check("host: empty input normalizes to nil",
      P.normalizeHost("") == nil)
check("host: whitespace-only input normalizes to nil",
      P.normalizeHost("   ") == nil)
// BUG: expected nil (an unparseable port should be refused); actual is a "valid" tuple because the port half is
// never even reached, per the BUG note above.
check("host: BUG - an unparseable port string is NOT rejected, it passes through as the whole host",
      hostsEqual(P.normalizeHost("host:notaport"), (host: "host:notaport", port: 11471)))
// BUG: expected nil (`port > 0` should refuse 0); actual is the same pass-through.
check("host: BUG - a zero port is NOT rejected, it passes through as the whole host",
      hostsEqual(P.normalizeHost("host:0"), (host: "host:0", port: 11471)))
// BUG: expected nil (`port <= 65535` should refuse an out-of-range port); actual is the same pass-through.
check("host: BUG - an out-of-range port is NOT rejected, it passes through as the whole host",
      hostsEqual(P.normalizeHost("host:70000"), (host: "host:70000", port: 11471)))

// MARK: - 5. Mount plan (the default-off gate)
//
// All three of userEnabled, killSwitchOn, and a valid host must hold, or the client stays on-device. Each is
// tested false individually against the other two true, plus the all-true case.

check("mountplan: userEnabled false alone forces onDevice",
      P.mountPlan(userEnabled: false, killSwitchOn: true, host: "192.168.1.33") == .onDevice)
check("mountplan: killSwitchOn false alone forces onDevice",
      P.mountPlan(userEnabled: true, killSwitchOn: false, host: "192.168.1.33") == .onDevice)
check("mountplan: an unusable host alone forces onDevice",
      P.mountPlan(userEnabled: true, killSwitchOn: true, host: nil) == .onDevice)
check("mountplan: all three true yields an external mount",
      P.mountPlan(userEnabled: true, killSwitchOn: true, host: "192.168.1.33")
        == .external(host: "192.168.1.33", port: P.defaultControlPort))

// MARK: - 6. Failover

// The host's own diagnosis is authoritative and final: one unhealthy report fails over immediately, even at
// zero accumulated control-plane failures.
check("failover: hostReportsHealthy == false fails over immediately, even at 0 failures",
      P.failover(consecutiveControlFailures: 0, hostReportsHealthy: false) == .failOverToDevice)

// A nil report (request did not complete) is ambiguous, so it is counted against the threshold rather than
// trusted immediately.
check("failover: a nil report below the threshold keeps the remote mount",
      P.failover(consecutiveControlFailures: P.controlFailureThreshold - 1, hostReportsHealthy: nil)
        == .keepRemote)
check("failover: a nil report exactly at the threshold fails over",
      P.failover(consecutiveControlFailures: P.controlFailureThreshold, hostReportsHealthy: nil)
        == .failOverToDevice)
check("failover: a nil report above the threshold fails over",
      P.failover(consecutiveControlFailures: P.controlFailureThreshold + 5, hostReportsHealthy: nil)
        == .failOverToDevice)

// A healthy report with zero accumulated failures is the ordinary steady state.
check("failover: a healthy report with no accumulated failures keeps the remote mount",
      P.failover(consecutiveControlFailures: 0, hostReportsHealthy: true) == .keepRemote)

// The documented behaviour, matched precisely rather than invented: `failover` does NOT itself reset the
// failure counter on a healthy report. "Fail-open on true" (per the source's own doc comment) is a property of
// the CALLER's contract — the caller resets its counter to 0 on a successful report before the next call. If a
// caller passes `hostReportsHealthy: true` while the counter is still at or above the threshold (i.e. it has not
// yet honoured that contract), the function still fails over, because the second guard alone is sufficient.
check("failover: a healthy report does NOT itself override an already-high failure count",
      P.failover(consecutiveControlFailures: 999, hostReportsHealthy: true) == .failOverToDevice)

// MARK: - 7. mountPath

check("mountpath: a bare resource name is mounted under /r/<capability>/",
      P.mountPath(capability: capA, resource: "master.m3u8") == "/r/\(capA)/master.m3u8")
check("mountpath: a leading-slash resource name mounts identically",
      P.mountPath(capability: capA, resource: "/master.m3u8") == "/r/\(capA)/master.m3u8")
check("mountpath: round-trips through route back to the bare resource path",
      P.route(header: "GET \(P.mountPath(capability: capA, resource: "master.m3u8")) HTTP/1.1", capability: capA)
        == .guarded(method: .get, path: "/master.m3u8", range: nil))

// MARK: - 8. Forward buffer

check("buffer: local (loopback) origin uses the shipping 30s value",
      P.forwardBufferSeconds(remote: false) == 30)
check("buffer: a remote origin buffers more than local",
      P.forwardBufferSeconds(remote: true) > P.forwardBufferSeconds(remote: false))

// MARK: - Result

print("")
if failures == 0 { print("ALL PASS"); exit(0) } else { print("\(failures) FAILED"); exit(1) }
}
