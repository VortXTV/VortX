import Foundation
import Libmpv

// Only unrelated dependencies are isolated. The runner extracts the actual default declaration,
// native setup setter, complete header-admission body and provenance-admission call from the controller.
struct FixtureCacheFlight { func reset() -> Bool { true } }
@MainActor enum YouTubeDirectResolver {
    static func requiredUserAgent(for url: URL) -> String { "FixtureTrailerAgent" }
    static func isManifestURL(_ url: URL) -> Bool { false }
}
@MainActor final class VXTrailerProxy {
    static let shared = VXTrailerProxy()
    func proxied(_ url: URL, mime: String) -> URL? { nil }
}
enum TrackPreferences { static let trailerAudioLanguages: [String] = [] }
@MainActor enum MPVHTTPHeaderOptions {
    static var reject = false
    static func set(_ fields: [String], on handle: OpaquePointer?) -> Int32 {
        if reject, let handle {
            var invalid: Int64 = 1
            // A real negative native return, not a claim that the sanitizer permits NUL.
            return mpv_set_property(handle, "http-header-fields", MPV_FORMAT_INT64, &invalid)
        }
        return NativeMPVHTTPHeaderOptions.set(fields, on: handle)
    }
}

@main
private struct MPVUserAgentIsolationTests {
    @MainActor static func main() {
        var checks = 0
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        for (label, missingHeaders) in [("nil", nil as [String: String]?), ("empty", [:]),
                                         ("empty-ua", ["User-Agent": ""])] {
            guard let handle = mpv_create() else { fatalError("mpv_create failed") }
            let application = ExtractedMPVUserAgentApplication(mpv: handle)
            for (key, value) in [("config", "no"), ("terminal", "no"), ("vo", "null"),
                                 ("ao", "null"), ("load-scripts", "no"), ("idle", "yes")] {
                precondition(mpv_set_option_string(handle, key, value) >= 0)
            }
            application.configureNativeUserAgent()
            precondition(mpv_initialize(handle) >= 0)
            let setupDefault = application.getString("user-agent")
            expect(setupDefault?.contains("AppleWebKit/605.1.15") == true, "\(label): actual setup Safari policy retained")
            let custom = "FixtureFirstAgent/1.0"
            let old = application.apply(["User-Agent": custom, "Referer": "https://fixture.invalid/first",
                                         "X-Fixture": "first,field"])
            expect(application.getString("user-agent") == custom, "\(label): first custom UA honored")
            expect(application.loadProvenance.callbackToken(requiresLoadedFile: true) == old,
                   "\(label): accepted first source owns callbacks")

            application.loggedHardwareDecoderNegotiation = true
            application.appliedDynamicRange = 7
            application.secondarySubtitleID = 42
            let cacheResets = application.cacheResets
            MPVHTTPHeaderOptions.reject = true
            let refused = application.apply(["User-Agent": "FixtureRefusedAgent", "X-Fixture": "rejected"])
            MPVHTTPHeaderOptions.reject = false
            expect(application.lastStatus < 0 && refused != old
                   && application.loadProvenance.callbackToken(requiresLoadedFile: true) == old,
                   "\(label): native header rejection leaves old owner, new token unadmitted")
            expect(application.getString("user-agent") == custom
                   && application.getString("referrer") == "https://fixture.invalid/first"
                   && readFields(handle) == ["X-Fixture: first,field"],
                   "\(label): rejection preserves native UA referrer and full headers")
            expect(application.loggedHardwareDecoderNegotiation && application.appliedDynamicRange == 7
                   && application.secondarySubtitleID == 42 && application.cacheResets == cacheResets,
                   "\(label): rejection preserves decoder HDR subtitle and cache bookkeeping")

            let next = application.apply(missingHeaders)
            expect(application.getString("user-agent") == setupDefault,
                   "\(label): first custom then omitted UA restores setup default")
            expect(application.getString("referrer") == "" && readFields(handle) == [],
                   "\(label): omitted source clears old referrer and header list")
            expect(application.loadProvenance.callbackToken(requiresLoadedFile: true) == next && next != old,
                   "\(label): accepted replacement owns callbacks")
            _ = application.apply(["User-Agent": "FixtureSecondAgent/2.0"])
            expect(application.getString("user-agent") == "FixtureSecondAgent/2.0",
                   "\(label): subsequent custom UA honored")
            _ = application.apply(nil)
            expect(application.getString("user-agent") == setupDefault,
                   "\(label): later default is not permanently poisoned")
            mpv_terminate_destroy(handle)
        }
        guard let handle = mpv_create() else { fatalError("mpv_create failed") }
        let trailer = ExtractedMPVUserAgentApplication(mpv: handle)
        for (key, value) in [("config", "no"), ("terminal", "no"), ("vo", "null"),
                             ("ao", "null"), ("load-scripts", "no"), ("idle", "yes")] {
            precondition(mpv_set_option_string(handle, key, value) >= 0)
        }
        trailer.configureNativeUserAgent()
        precondition(mpv_initialize(handle) >= 0)
        let setupDefault = trailer.getString("user-agent")
        _ = trailer.apply(["X-Fixture": "must-clear"], url: URL(string: "https://video.googlevideo.invalid/fixture")!)
        expect(trailer.getString("user-agent") == "FixtureTrailerAgent" && readFields(handle) == [],
               "first trailer uses final forced UA and empty header list")
        _ = trailer.apply(nil)
        expect(trailer.getString("user-agent") == setupDefault, "first trailer then ordinary source restores setup default")
        mpv_terminate_destroy(handle)
        print("\(checks - failures)/\(checks) PASS; failures=\(failures)")
        if failures != 0 { exit(1) }
    }

    static func readFields(_ handle: OpaquePointer) -> [String]? {
        var node = mpv_node()
        guard mpv_get_property(handle, "http-header-fields", MPV_FORMAT_NODE, &node) >= 0 else { return nil }
        defer { mpv_free_node_contents(&node) }
        guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list else { return nil }
        return (0..<Int(list.pointee.num)).map { String(cString: list.pointee.values[$0].u.string) }
    }
}
