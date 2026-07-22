import Foundation

// =============================================================================
// player-conformance - acceptance harness for the player rework.
//
// Subcommands:
//   selftest                         Validate the oracle (cohort boundary cases,
//                                     EXTINF integer-ms parsing, fMP4 sync parser,
//                                     server-faithful build/parse round trip).
//   trace <log> [--index N]          Evaluate contract points 1,3,4,6,7 from a
//                                     captured request-trace (real server lines).
//   live  --container <dir>          Full battery over loopback + filesystem while
//         [--port N] [--log <file>]  a plain-remux playback is LIVE. Decides all
//         [--spool <dir>]            seven points; the acceptance gate.
//         [--spool-bound-mib N]
//         [--sample N]
//   spool <dir>                      Print total bytes under <dir> (runner uses it
//                                     for the post-teardown zero check).
//
// Exit code for trace/live is the GATE: 0 only when every point is GREEN/EXEMPT.
// Against current beta it is non-zero (points are RED); it turns 0 when the rework
// is correct. selftest exits 0 only when the oracle's own checks all pass.
// =============================================================================

let useColor = isatty(fileno(stdout)) != 0
func paint(_ s: String, _ code: String) -> String { useColor ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
func colorFor(_ v: Verdict) -> String {
    switch v {
    case .green: return "32"; case .red: return "31"
    case .exempt: return "36"; case .indeterminate: return "33"; case .pending: return "35"
    }
}

func report(_ title: String, _ findings: [Finding]) -> Bool {
    print("")
    print(paint("== \(title) ==", "1"))
    var accept = true
    for p in Point.allCases {
        guard let f = findings.first(where: { $0.point == p }) else { continue }
        if !f.verdict.acceptable { accept = false }
        let tag = paint(f.verdict.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0), colorFor(f.verdict))
        print("[\(tag)] (\(p.rawValue)) \(p.title)")
        for e in f.evidence { print("               - \(e)") }
    }
    print("")
    print(accept ? paint("GATE: PASS (all points GREEN/EXEMPT)", "1;32")
                 : paint("GATE: FAIL (not every point is GREEN/EXEMPT)", "1;31"))
    return accept
}

// MARK: - selftest

func runSelfTest() -> Bool {
    var checks: [(String, Bool)] = []
    func expect(_ name: String, _ cond: Bool) { checks.append((name, cond)) }

    // Cohort boundary cases, built through the REAL server format and measured as
    // integer ms from the resulting EXTINF text.
    func cohort(_ durs: [Double], ended: Bool = false) -> (Int, Int, Bool) {
        let body = Playlist.buildMediaBodyLikeServer(durations: durs, ended: ended)
        let p = Playlist.parseMedia(body)
        return (p.count, p.totalMs, Playlist.cohortReady(count: p.count, totalMs: p.totalMs))
    }
    let a = cohort(Array(repeating: 4.000, count: 5))
    expect("5x4.000s stays CLOSED (count 5<6)", a == (5, 20000, false))
    let b = cohort(Array(repeating: 3.000, count: 6))
    expect("6x3.000s OPENS (6 segs, 18000 ms)", b == (6, 18000, true))
    let c = cohort(Array(repeating: 1.000, count: 15))
    expect("15x1.000s OPENS (15 segs, 15000 ms)", c == (15, 15000, true))
    let d = cohort([2.500, 2.500, 2.500, 2.500, 2.500, 2.499])
    expect("14.999s (6 segs) stays CLOSED (14999<15000, 1 ms)", d == (6, 14999, false))
    let e = cohort([2.500, 2.500, 2.500, 2.500, 2.500, 2.500])
    expect("15.000s (6 segs) OPENS (integer >= 15000)", e == (6, 15000, true))

    // EXTINF text -> integer ms, no float.
    expect("EXTINF 4.000 -> 4000 ms", Playlist.msFromExtinf("#EXTINF:4.000,") == 4000)
    expect("EXTINF 14.999 -> 14999 ms", Playlist.msFromExtinf("#EXTINF:14.999,") == 14999)
    expect("EXTINF 15.000 -> 15000 ms", Playlist.msFromExtinf("#EXTINF:15.000,") == 15000)
    expect("EXTINF 15 -> 15000 ms", Playlist.msFromExtinf("#EXTINF:15,") == 15000)
    expect("EXTINF 1.5 -> 1500 ms", Playlist.msFromExtinf("#EXTINF:1.5,") == 1500)

    // The real DVPlaybackPolicy header is compiled in and used by the builder.
    let body = Playlist.buildMediaBodyLikeServer(durations: [4.0, 4.0, 4.0], ended: true)
    expect("builder emits TARGETDURATION 5", body.contains("#EXT-X-TARGETDURATION:5"))
    expect("builder emits the load-bearing EXT-X-START", body.contains("#EXT-X-START:TIME-OFFSET=0,PRECISE=YES"))
    expect("builder emits EXT-X-MAP init.mp4", body.contains("#EXT-X-MAP:URI=\"init.mp4\""))
    let rp = Playlist.parseMedia(body)
    expect("round-trip recovers 3 segments ids 0..2", rp.segments.map(\.id) == [0, 1, 2])
    expect("round-trip sees ENDLIST", rp.endlist)

    // fMP4 first-sample sync parser.
    expect("synthetic sync segment reads as IDR", FMP4.firstSampleIsSync(FMP4.syntheticSegment(firstSampleSync: true)) == true)
    expect("synthetic non-sync segment reads as non-IDR", FMP4.firstSampleIsSync(FMP4.syntheticSegment(firstSampleSync: false)) == false)

    print(paint("== oracle self-test ==", "1"))
    var ok = true
    for (name, pass) in checks {
        ok = ok && pass
        print("[\(paint(pass ? "PASS" : "FAIL", pass ? "32" : "31"))] \(name)")
    }
    print("")
    print(ok ? paint("SELF-TEST OK (oracle validated)", "1;32") : paint("SELF-TEST FAILED", "1;31"))
    return ok
}

// MARK: - arg helpers

func value(_ flag: String, _ args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// MARK: - dispatch

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "selftest"

switch cmd {
case "selftest":
    exit(runSelfTest() ? 0 : 1)

case "trace":
    guard let path = args.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
        FileHandle.standardError.write(Data("usage: trace <log> [--index N]\n".utf8)); exit(2)
    }
    let idx = Int(value("--index", args) ?? "0") ?? 0
    guard let s = Trace.session(inFileAt: path, index: idx) else {
        FileHandle.standardError.write(Data("no plain-remux HLS session #\(idx) in \(path)\n".utf8)); exit(2)
    }
    let accept = report("trace channel: \(path) (session #\(idx), port \(s.port.map(String.init) ?? "?"))", Trace.findings(s))
    exit(accept ? 0 : 1)

case "live":
    let container = value("--container", args)
    var logPath = value("--log", args)
    if logPath == nil, let c = container { logPath = c + "/Library/Caches/diagnostics.log" }
    guard let logPath else {
        FileHandle.standardError.write(Data("usage: live --container <appDataDir> [--port N] [--log <file>] [--spool <dir>]\n".utf8)); exit(2)
    }
    guard let s = Trace.session(inFileAt: logPath) else {
        FileHandle.standardError.write(Data("no live plain-remux session in \(logPath) (is a plain MKV playing?)\n".utf8)); exit(2)
    }
    guard let port = Int(value("--port", args) ?? "") ?? s.port else {
        FileHandle.standardError.write(Data("could not determine loopback port (pass --port N)\n".utf8)); exit(2)
    }
    let spool = value("--spool", args)
    let bound = Int(value("--spool-bound-mib", args) ?? "") ?? (Contract.windowFloorMiB * 2)
    let sample = Int(value("--sample", args) ?? "") ?? 12
    let accept = report("live channel: 127.0.0.1:\(port) (log \(logPath))",
                        Live.findings(port: port, trace: s, spoolPath: spool, spoolBoundMiB: bound, segmentSampleCap: sample))
    exit(accept ? 0 : 1)

case "spool":
    guard let dir = args.dropFirst().first else {
        FileHandle.standardError.write(Data("usage: spool <dir>\n".utf8)); exit(2)
    }
    if let b = Live.directoryBytes(dir) { print("\(b)"); exit(0) }
    FileHandle.standardError.write(Data("no directory at \(dir)\n".utf8)); exit(2)

default:
    FileHandle.standardError.write(Data("unknown command \(cmd); use selftest | trace | live | spool\n".utf8))
    exit(2)
}
