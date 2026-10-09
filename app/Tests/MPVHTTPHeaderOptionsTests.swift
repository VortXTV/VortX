import Foundation
import Libmpv

// Isolate unrelated dependencies in the extracted real controller body; these stubs never do I/O.
struct FixtureCacheFlight { func reset() -> Bool { true } }
@MainActor enum YouTubeDirectResolver {
    static func requiredUserAgent(for url: URL) -> String { "fixture-google-agent" }
    static func isManifestURL(_ url: URL) -> Bool { false }
}
@MainActor final class VXTrailerProxy {
    static let shared = VXTrailerProxy()
    var calls = 0
    func proxied(_ url: URL, mime: String) -> URL? { calls += 1; return url }
}
enum TrackPreferences { static let trailerAudioLanguages: [String] = [] }

#if !MPV_HTTP_HEADER_BASELINE
@MainActor enum MPVHTTPHeaderOptions {
    static var rejectedCall: Int?
    static var attempts: [[String]] = []
    static func set(_ fields: [String], on handle: OpaquePointer?) -> Int32 {
        attempts.append(fields)
        if attempts.count == rejectedCall, let handle {
            // A real native setter error, injected at the real controller boundary. The sanitizer
            // already strips NUL; this is NOT a claim that a sanitized NUL header reaches libmpv.
            var invalidFormatValue: Int64 = 1
            let status = mpv_set_property(handle, "http-header-fields", MPV_FORMAT_INT64, &invalidFormatValue)
            precondition(status < 0)
            return status
        }
        return NativeMPVHTTPHeaderOptions.set(fields, on: handle)
    }
}
#endif

@main
private struct MPVHTTPHeaderOptionsTests {
    @MainActor
    static func main() {
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
        var failures = 0
        var checks = 0
        func expect(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        func readFields() -> [String]? {
            var node = mpv_node()
            guard mpv_get_property(handle, "http-header-fields", MPV_FORMAT_NODE, &node) >= 0 else { return nil }
            defer { mpv_free_node_contents(&node) }
            guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list,
                  list.pointee.num >= 0 else { return nil }
            return (0..<Int(list.pointee.num)).map { index in
                let value = list.pointee.values[index]
                precondition(value.format == MPV_FORMAT_STRING)
                return String(cString: value.u.string)
            }
        }
        // This application body is extracted from the actual controller by the runner, not copied here.
        var application = ExtractedMPVHTTPHeaderApplication(mpv: handle)
        let headers = [
            "Accept": "video/*, */*;q=0.5",
            "Authorization": "FixtureSignature key=\"fake,only\",signature=\"not-a-secret\"",
            "Cookie": "fixture=one,two; quoted=\"three,four\"",
            "X-Path": #"prefix\,middle\\suffix: tail"#,
            "X-Empty": "",
            "Range": "bytes=0-1023",
            "Connection": "close",
            "X-Injected": "bad\r\nRange: bytes=0-0",
            "Referer": "https://fixture.invalid/ref",
            "User-Agent": "Fixture, Browser"
        ]
        let expected = [
            "Accept: video/*, */*;q=0.5",
            "Authorization: FixtureSignature key=\"fake,only\",signature=\"not-a-secret\"",
            "Cookie: fixture=one,two; quoted=\"three,four\"",
            "X-Empty: ",
            #"X-Path: prefix\,middle\\suffix: tail"#
        ]
        expect(application.apply(headers) >= 0, "controller header admission")
        expect(readFields() == expected, "exact ordered comma quote backslash colon and empty values")
        expect(!(readFields() ?? []).contains(where: { $0.hasPrefix("Range:") || $0.hasPrefix("Connection:") || $0.hasPrefix("X-Injected:") }),
               "transport and CRLF sanitization retained")
        expect(application.apply(["X-New": "replacement,only"]) >= 0, "replacement admitted")
        expect(readFields() == ["X-New: replacement,only"], "replacement excludes previous source fields")
        expect(application.apply(nil) >= 0 && readFields() == [], "nil new-source headers clear old fields")
        expect(application.apply([:]) >= 0 && readFields() == [], "empty new-source headers stay empty")
        #if !MPV_HTTP_HEADER_BASELINE
        let reversedFields = Array(expected.reversed())
        expect(MPVHTTPHeaderOptions.set(reversedFields, on: handle) >= 0
               && readFields() == reversedFields, "native helper preserves supplied field order")
        expect(MPVHTTPHeaderOptions.set([], on: handle) >= 0 && readFields() == [], "explicit trailer clear uses empty native array")
        expect(MPVHTTPHeaderOptions.set(["X: before\0after"], on: handle) == MPV_ERROR_INVALID_PARAMETER.rawValue
               && readFields() == [], "embedded NUL rejected without partial mutation")
        expect(MPVHTTPHeaderOptions.set([], on: nil) == MPV_ERROR_UNINITIALIZED.rawValue,
               "missing native handle is an error not success")
        var retiredApplication = ExtractedMPVHTTPHeaderApplication(mpv: nil)
        expect(retiredApplication.apply(["X-Fake": "value"]) < 0, "controller rejects failed header application before load admission")

        func nativeString(_ name: String) -> String? {
            guard let pointer = mpv_get_property_string(handle, name) else { return nil }
            defer { mpv_free(pointer) }
            return String(cString: pointer)
        }
        let oldFields = ["X-Old: preserve,whole"]
        let googleURL = URL(string: "https://video.googlevideo.invalid/fixture")!
        let ordinaryURL = URL(string: "https://fixture.invalid/fixture")!
        for (name, url, sidecar) in [("ordinary", ordinaryURL, nil as URL?),
                                     ("google-video", googleURL, nil),
                                     ("google-sidecar", ordinaryURL, googleURL)] {
            precondition(NativeMPVHTTPHeaderOptions.set(oldFields, on: handle) >= 0)
            precondition(mpv_set_property_string(handle, "user-agent", "old-agent") >= 0)
            precondition(mpv_set_property_string(handle, "referrer", "https://old.invalid/ref") >= 0)
            MPVHTTPHeaderOptions.attempts = []
            MPVHTTPHeaderOptions.rejectedCall = 1
            VXTrailerProxy.shared.calls = 0
            var rejected = ExtractedMPVHTTPHeaderApplication(mpv: handle)
            expect(rejected.apply(headers, url: url, audioSidecar: sidecar) < 0, "\(name) native failure rejects controller admission")
            expect(nativeString("user-agent") == "old-agent" && nativeString("referrer") == "https://old.invalid/ref",
                   "\(name) rejection preserves actual old UA and referrer")
            expect(readFields() == oldFields, "\(name) rejection preserves actual old fields")
            expect(rejected.loggedHardwareDecoderNegotiation && rejected.appliedDynamicRange == 7
                   && rejected.secondarySubtitleID == 42 && rejected.cacheResets == 0,
                   "\(name) rejection preserves decoder receipt HDR subtitle and cache state")
            expect(VXTrailerProxy.shared.calls == 0, "\(name) rejection starts no trailer proxy")
            if name != "ordinary" {
                expect(MPVHTTPHeaderOptions.attempts == [[]], "\(name) final empty choice is the only attempted header array")
            }
        }
        // A fault armed on a second call must never fire: trailer setup has one final header choice.
        MPVHTTPHeaderOptions.attempts = []
        MPVHTTPHeaderOptions.rejectedCall = 2
        var trailer = ExtractedMPVHTTPHeaderApplication(mpv: handle)
        expect(trailer.apply(headers, url: googleURL) >= 0, "trailer has no fallible second clear")
        expect(MPVHTTPHeaderOptions.attempts == [[]] && readFields() == [], "trailer applies its final empty array exactly once")
        expect(nativeString("user-agent") == "fixture-google-agent" && nativeString("referrer") == "",
               "accepted trailer uses final client UA and empty referrer")
        expect(!trailer.loggedHardwareDecoderNegotiation && trailer.appliedDynamicRange == nil
               && trailer.secondarySubtitleID == -1 && trailer.cacheResets == 1,
               "accepted choice retains existing per-load state reset behavior")
        MPVHTTPHeaderOptions.rejectedCall = nil
        #endif
        print("HTTP header native property fixture: \(failures == 0 ? "PASS" : "FAIL") (\(checks) checks, \(failures) failures); no source loaded")
        if failures > 0 { exit(1) }
    }
}
