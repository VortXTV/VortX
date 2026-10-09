import Foundation
import Libmpv

/// No loadfile, media, HTTP requests or output devices. The helper is real production source;
/// controller assertions are source-wiring contracts, not a playback or race reproduction.
@main
private struct MPVSeekTransportDiagnosticTests {
    static func main() throws {
        typealias Diagnostic = MPVSeekTransportDiagnostic
        guard let handle = mpv_create() else { fatalError("mpv_create failed") }
        defer { mpv_terminate_destroy(handle) }
        for (key, value) in [("config", "no"), ("terminal", "no"), ("vo", "null"),
                             ("ao", "null"), ("load-scripts", "no"), ("idle", "yes")] {
            precondition(mpv_set_option_string(handle, key, value) >= 0)
        }
        precondition(mpv_initialize(handle) >= 0)
        if let version = mpv_get_property_string(handle, "mpv-version") {
            print("native runtime: \(String(cString: version))")
            mpv_free(version)
        }
        var checks = 0
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }

        let observed = Diagnostic.read(from: handle)
        print("idle actual native observation: \(observed.receipt)")
        expect(observed.seekable == .unavailable, "native seekable exists, idle unavailable")
        expect(observed.partiallySeekable == .unavailable, "native partially-seekable exists, idle unavailable")
        expect(observed.demuxBytePosition == .unavailable, "native stream-pos exists, idle unavailable")
        expect(observed.sourceByteSize == .unavailable, "native file-size exists, idle unavailable")
        expect(Diagnostic.codecProfile(from: handle) == .unavailable,
               "native current-tracks/video/codec-profile exists, no selected video unavailable")

        var native = mpv_node()
        var status = mpv_get_property(handle, "pause", MPV_FORMAT_NODE, &native)
        expect(status >= 0 && Diagnostic.decode(native, status: status, kind: .flag) == .flag(false),
               "actual native false is not unavailable")
        if status >= 0 { mpv_free_node_contents(&native) }
        for number in [Int64(0), 42] {
            var input = mpv_node()
            input.format = MPV_FORMAT_INT64
            input.u.int64 = number
            precondition(mpv_set_property(handle, "user-data/seek-transport-fixture", MPV_FORMAT_NODE, &input) >= 0)
            status = mpv_get_property(handle, "user-data/seek-transport-fixture", MPV_FORMAT_NODE, &native)
            expect(status >= 0 && Diagnostic.decode(native, status: status, kind: .nonnegativeInteger) == .integer(number),
                   "actual native integer \(number) preserved")
            if status >= 0 { mpv_free_node_contents(&native) }
        }
        status = mpv_get_property(handle, "vortx-nonexistent-fixture-property", MPV_FORMAT_NODE, &native)
        expect(status == MPV_ERROR_PROPERTY_NOT_FOUND.rawValue
               && Diagnostic.decode(native, status: status, kind: .flag) == .error(status),
               "actual missing property error distinct from unavailable")

        var node = mpv_node()
        node.format = MPV_FORMAT_INT64
        node.u.int64 = 0
        expect(Diagnostic.decode(node, status: MPV_ERROR_PROPERTY_UNAVAILABLE.rawValue, kind: .nonnegativeInteger) == .unavailable,
               "unavailable ignores zero-initialized output")
        expect(Diagnostic.decode(node, status: MPV_ERROR_PROPERTY_FORMAT.rawValue, kind: .nonnegativeInteger)
               == .error(MPV_ERROR_PROPERTY_FORMAT.rawValue), "native format error preserved")
        node.u.int64 = -1
        expect(Diagnostic.decode(node, status: 0, kind: .nonnegativeInteger) == .malformed, "negative byte offset rejected")
        node.format = MPV_FORMAT_DOUBLE
        node.u.double_ = 42
        expect(Diagnostic.decode(node, status: 0, kind: .nonnegativeInteger) == .malformed, "wrong integer type rejected")
        node.format = MPV_FORMAT_FLAG
        node.u.flag = 2
        expect(Diagnostic.decode(node, status: 0, kind: .flag) == .malformed, "nonboolean flag rejected")
        node.u.flag = 1
        expect(Diagnostic.decode(node, status: 0, kind: .flag) == .flag(true), "true flag preserved")
        expect(Diagnostic.decode(node, status: 0, kind: .codecProfile) == .malformed, "wrong profile type rejected")
        node.format = MPV_FORMAT_STRING
        node.u.string = nil
        expect(Diagnostic.decode(node, status: 0, kind: .codecProfile) == .malformed, "nil profile rejected")
        for profile in ["High", "Main 10", "High 4:4:4 Predictive"] {
            profile.withCString { pointer in
                node.u.string = UnsafeMutablePointer(mutating: pointer)
                expect(Diagnostic.decode(node, status: 0, kind: .codecProfile) == .profile(profile),
                       "codec profile preserves \(profile)")
            }
        }
        for profile in ["", "https://fixture.invalid/fake", "Authorization: fixture", "High\nInjected", "High\"", String(repeating: "A", count: 97)] {
            profile.withCString { pointer in
                node.u.string = UnsafeMutablePointer(mutating: pointer)
                expect(Diagnostic.decode(node, status: 0, kind: .codecProfile) == .malformed,
                       "unsafe or overlong profile rejected (length \(profile.utf8.count))")
            }
        }
        let receipt = Diagnostic(seekable: .flag(false), partiallySeekable: .unavailable,
                                 demuxBytePosition: .integer(0), sourceByteSize: .error(-8)).receipt
        expect(receipt == "seekable=false partialSeekable=unavailable demuxBytePos=0 sourceByteSize=error(-8)",
               "receipt does not relabel demux position as HTTP range or unavailable as zero")

        let nativeFailures = failures
        let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        func section(_ start: String, _ end: String) -> String {
            guard let first = source.range(of: start),
                  let last = source.range(of: end, range: first.upperBound..<source.endIndex) else { return "" }
            return String(source[first.lowerBound..<last.lowerBound])
        }
        func ordered(_ source: String, _ tokens: [String]) -> Bool {
            var remaining = source[...]
            for token in tokens {
                guard let range = remaining.range(of: token) else { return false }
                remaining = remaining[range.upperBound...]
            }
            return true
        }
        let pending = section("private func scheduleNativeSeekWitness(", "private var seekEOFReloadSource")
        expect(ordered(pending, ["self.loadTokenLock.lock()", "callbackToken(requiresLoadedFile: true) == owner",
                                 "self.seekSettlement.accepts(evidence, owner: owner)", "let snapshot =",
                                 "let transport = MPVSeekTransportDiagnostic.read(from: handle)",
                                 "self.loadTokenLock.unlock()", "\\(transport.receipt)"]),
               "controller pending diagnostic captures transport under existing source-command fence")
        expect(pending.components(separatedBy: "for delay in [2.0, 6.0, 11.0]").count == 2,
               "controller retains exactly one existing pending schedule")
        let deadline = section("func failedResumeSeekTarget(", "func ")
        expect(ordered(deadline, ["loadTokenLock.lock()", "let snapshot =", "let transport = MPVSeekTransportDiagnostic.read(from: handle)",
                                  "seekSettlement.evidenceForLatestCommand(", "loadTokenLock.unlock()",
                                  "seek-native deadline", "\\(transport.receipt)"]),
               "controller deadline transport uses existing ticket admission and lock")
        let dequeue = section("func readEvents()", "if event?.pointee.event_id == MPV_EVENT_NONE")
        expect(ordered(dequeue, ["self.loadTokenLock.lock()", "mpv_wait_event(handle, 0)", "let rawSeekOwner =",
                                 "let rawSeekEvidence =", "let nativeSeekTransport =", "MPVSeekTransportDiagnostic.read(from: handle)",
                                 "self.loadTokenLock.unlock()", "let transport = nativeSeekTransport", "\\(transport.receipt)"]),
               "controller event transport captured beside immutable dequeue ownership")
        let decoder = section("private func recordHardwareDecoderNegotiation", "/// Switch the audio output policy")
        expect(ordered(decoder, ["loadTokenLock.lock()", "let owner = loadProvenance.callbackToken(requiresLoadedFile: true)",
                                 "let active = getString(\"hwdec-current\")", "MPVSeekTransportDiagnostic.codecProfile(from: handle)",
                                 "hwdec negotiation load=\\(owner.hashValue)", "codecProfile=\\(codecProfile.receipt)"]),
               "controller decoder profile and actual mode read under same source fence")
        print("\(checks - failures)/\(checks) PASS; native/pure failures=\(nativeFailures); controller-wiring failures=\(failures - nativeFailures)")
        if failures != 0 { exit(1) }
    }
}
