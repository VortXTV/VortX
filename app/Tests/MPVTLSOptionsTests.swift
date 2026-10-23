import Foundation

// Only native API boundaries are inert. The runner embeds both complete, unmodified actual controller
// methods in ExtractedMPVTLSController; no policy/application/retirement algorithm is copied here.
@MainActor
enum MPVTLSNativeBoundary {
    static var rejectedName: String?
    static var calls: [MPVTLSOptions.Option] = []
    static var retired: [OpaquePointer?] = []

    static func reset(rejecting name: String? = nil) {
        rejectedName = name
        calls = []
        retired = []
    }

    static func set(_ handle: OpaquePointer?, _ name: String, _ value: String) -> Int32 {
        precondition(handle != nil, "controller must not pass a retired handle")
        calls.append(.init(name: name, value: value))
        return name == rejectedName ? -5 : 0
    }
}

@MainActor
@discardableResult
func mpv_set_option_string(_ handle: OpaquePointer?, _ name: String, _ value: String) -> Int32 {
    MPVTLSNativeBoundary.set(handle, name, value)
}

@MainActor
@discardableResult
func mpv_set_property_string(_ handle: OpaquePointer?, _ name: String, _ value: String) -> Int32 {
    MPVTLSNativeBoundary.set(handle, name, value)
}

@MainActor
func mpv_terminate_destroy(_ handle: OpaquePointer?) {
    MPVTLSNativeBoundary.retired.append(handle)
}

@main
enum MPVTLSOptionsTests {
    static func ordered(_ needles: [String], in source: String) -> Bool {
        var tail = source[...]
        for needle in needles {
            guard let range = tail.range(of: needle) else { return false }
            tail = tail[range.upperBound...]
        }
        return true
    }

    static func setupWiring(_ source: String) -> Bool {
        guard let start = source.range(of: "    func setupMpv() {"),
              let end = source.range(of: "        mpv_observe_property(mpv, 0, MPVProperty.videoParamsSigPeak",
                                     range: start.upperBound..<source.endIndex) else { return false }
        return ordered([
            "for (key, value) in PlaybackSettings.parsedCustomMpvOptions",
            "guard MPVTLSOptions.allowsCustomOption(key, value: value) else {",
            "continue", "let err = mpv_set_option_string(mpv, key, value)",
            "guard applyRequiredTLSPolicy() else { return }",
            "if startMuted {", "let initializationStatus = mpv_initialize(mpv)",
            "guard initializationStatus >= 0 else",
        ], in: String(source[start.lowerBound..<end.lowerBound]))
    }

    @MainActor
    static func main() throws {
        var checks = 0
        func expect(_ accepted: Bool, _ label: String) {
            checks += 1
            precondition(accepted, label)
        }
        var expected = [
            MPVTLSOptions.Option(name: "config", value: "no"),
            .init(name: "load-scripts", value: "no"),
            .init(name: "resume-playback", value: "no"),
            .init(name: "tls-verify", value: "yes"),
            .init(name: "stream-lavf-o", value: "tls_verify=1,reconnect=1,reconnect_streamed=1,reconnect_delay_max=7,multiple_requests=1"),
            .init(name: "demuxer-lavf-o", value: "tls_verify=1"),
            .init(name: "demuxer-lavf-propagate-opts", value: "yes"),
        ]
        #if os(macOS)
        expected.append(.init(name: "ytdl", value: "no"))
        #endif
        expect(MPVTLSOptions.initializationOptions == expected, "exact required system-verifier policy")

        for name in [
            "tls-verify", "no-tls-verify", "TLS-VERIFY", "no-no-tls-verify", "tls-ca-file",
            "tls-cert-file", "tls-key-file", "config", "no-config", "config-dir", "include",
            "include-append", "profile-append", "profile-restore", "no-profile", "scripts",
            "scripts-append", "scripts-clr", "script", "script-opts", "script-opts-add",
            "load-scripts", "no-load-scripts", "use-filedir-conf", "resume-playback",
            "watch-later-directory", "watch-later-options", "reset-on-next-file", "input-conf",
            "input-file", "input-ipc-server", "input-ipc-client", "input-commands",
            "stream-lavf-o", "stream-lavf-o-append", "stream-lavf-o-clr",
            "demuxer-lavf-o", "demuxer-lavf-o-add", "demuxer-lavf-propagate-opts",
            "ytdl", "no-ytdl", "ytdl-raw-options", "ytdl-format", "o", "of", "ofopts",
            "ofopts-append", "ovc", "ovcopts", "oac", "oacopts",
            "--tls-verify", "options/tls-verify", "tls_verify", "tls-verify\0ignored", "", "-",
        ] {
            expect(!MPVTLSOptions.allowsCustomOption(name, value: "fixture"), "reserved option: \(name)")
        }
        for value in ["unsafe-file-profile", "gpu-hq,unsafe", "gpu-hq,fast", "", "GPU-HQ"] {
            expect(!MPVTLSOptions.allowsCustomOption("profile", value: value), "profile loader rejected")
        }
        for value in ["gpu-hq", "fast"] {
            expect(MPVTLSOptions.allowsCustomOption("profile", value: value), "existing built-in rendering profile retained")
        }
        for (name, value) in [
            ("scale", "ewa_lanczossharp"), ("video-sync", "display-resample"),
            ("hwdec", "videotoolbox"), ("audio-channels", "stereo"), ("audio-delay", "0.25"),
            ("glsl-shaders", "/fixture/a.glsl:/fixture/b.glsl"), ("vf", "format=yuv420p"),
            ("af", "lavfi=[volume=0.8]"), ("network-timeout", "30"),
            ("user-agent", "Fixture UA"), ("http-header-fields", "X-Fixture: one"),
            ("http-proxy", "http://proxy.invalid:8080"), ("cache-secs", "120"),
            ("deband", "yes"), ("no-deband", "yes"),
        ] {
            expect(MPVTLSOptions.allowsCustomOption(name, value: value), "ordinary override retained: \(name)")
        }
        expect(!MPVTLSOptions.allowsCustomOption("user-agent", value: "safe\0hidden"), "C-string truncation rejected")

        let handle = OpaquePointer(bitPattern: 0x17)!
        MPVTLSNativeBoundary.reset()
        let accepted = ExtractedMPVTLSController(handle: handle)
        expect(accepted.applyTLS(), "actual owning TLS method accepts complete policy")
        expect(MPVTLSNativeBoundary.calls == expected, "actual owning method applies exact ordered options")
        expect(accepted.mpv == handle && MPVTLSNativeBoundary.retired.isEmpty, "success retains handle")
        expect(accepted.initializationFailure.message == nil && accepted.errors.isEmpty, "success reports no failure")

        for (index, option) in expected.enumerated() {
            MPVTLSNativeBoundary.reset(rejecting: option.name)
            let rejected = ExtractedMPVTLSController(handle: handle)
            expect(!rejected.applyTLS(), "actual owning method refuses rejected mandatory option")
            expect(rejected.mpv == nil && MPVTLSNativeBoundary.retired == [handle], "exact handle retired once")
            expect(rejected.errors == [-5], "negative native status retained")
            expect(MPVTLSNativeBoundary.calls == Array(expected.prefix(index + 1)), "no later options after rejection")
            expect(rejected.initializationFailure.message != nil, "existing controlled failure receipt installed")
            expect(rejected.initializationFailure.admit(9) != nil && rejected.initializationFailure.accepts(9),
                   "next requested load owns existing failure receipt")
        }
        MPVTLSNativeBoundary.reset()
        let missing = ExtractedMPVTLSController(handle: nil)
        expect(!missing.applyTLS() && MPVTLSNativeBoundary.calls.isEmpty && MPVTLSNativeBoundary.retired.isEmpty,
               "missing handle never reaches native API")

        let modes = ExtractedMPVTLSController(handle: handle)
        MPVTLSNativeBoundary.reset()
        modes.configure(false)
        expect(MPVTLSNativeBoundary.calls.isEmpty, "unchanged initial VOD uses mandatory initialization policy")
        for live in [true, false, true] {
            MPVTLSNativeBoundary.reset()
            modes.configure(live)
            expect(MPVTLSNativeBoundary.calls == [
                .init(name: "demuxer-readahead-secs", value: live ? "18" : "300"),
                .init(name: "demuxer-max-back-bytes", value: live ? "8MiB" : "64MiB"),
                .init(name: "demuxer-lavf-o", value: live ? "tls_verify=1,live_start_index=-3" : "tls_verify=1"),
                .init(name: "stream-lavf-o", value: live
                      ? "tls_verify=1,reconnect=1,reconnect_streamed=0,reconnect_delay_max=1"
                      : "tls_verify=1,reconnect=1,reconnect_streamed=1,reconnect_delay_max=7,multiple_requests=1"),
            ], "actual mode rewrite retains TLS and existing live/VOD behavior")
            expect(modes.configuredLiveMode == live, "actual mode bookkeeping retained")
        }
        MPVTLSNativeBoundary.reset(rejecting: "demuxer-lavf-o")
        modes.configure(false)
        expect(modes.errors == [-5], "mode rewrite records native setter error")
        expect(MPVTLSNativeBoundary.calls.filter { $0.name.contains("lavf-o") }.allSatisfy { $0.value.hasPrefix("tls_verify=1") },
               "even a rejected mode rewrite never requests weaker TLS")
        MPVTLSNativeBoundary.reset()
        missing.configure(true)
        expect(MPVTLSNativeBoundary.calls.isEmpty, "retired mode update never reaches native API")

        let root = CommandLine.arguments.dropFirst().first ?? "."
        let source = try String(contentsOfFile: root + "/app/Sources/Player/MPVMetalViewController.swift", encoding: .utf8)
        expect(setupWiring(source), "actual setup gates custom options and fails before initialize")
        expect(!setupWiring(source.replacingOccurrences(of: "guard applyRequiredTLSPolicy() else { return }", with: "")),
               "missing mandatory setup call is not a false green")
        expect(!setupWiring(source.replacingOccurrences(of: "guard MPVTLSOptions.allowsCustomOption(key, value: value) else {", with: "if false {")),
               "missing custom admission gate is not a false green")
        expect(!setupWiring(source.replacingOccurrences(of: "guard applyRequiredTLSPolicy() else { return }", with: "if !applyRequiredTLSPolicy() {}")),
               "ignored mandatory rejection is not a false green")
        print("Apple mpv TLS policy: \(checks) checks; actual extracted controller methods, inert native API only; no playback/TLS handshake/OS-distrust proof")
    }
}
