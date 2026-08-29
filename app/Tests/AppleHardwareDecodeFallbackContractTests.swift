// Focused behavior + wiring contract for vortx-diag 9's silent VideoToolbox fallback.
//
// RUN:
//   sed -n '/^enum MPVHardwareDecodePolicy {/,/^\/\/ warning: metal API validation/p' \
//     app/Sources/Player/MPVMetalViewController.swift | sed '$d' \
//     > /tmp/vortx-hwdec-policy.swift && \
//   xcrun swiftc /tmp/vortx-hwdec-policy.swift \
//     app/Tests/AppleHardwareDecodeFallbackContractTests.swift \
//     -o /tmp/vortx-hwdec-tests && /tmp/vortx-hwdec-tests

import Foundation

nonisolated(unsafe) private var failures = 0

private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() { print("PASS  \(name)") }
    else { failures += 1; print("FAIL  \(name)") }
}

private func section(_ source: String, from start: String, to end: String) -> String? {
    guard let lower = source.range(of: start),
          let upper = source.range(of: end, range: lower.upperBound..<source.endIndex) else {
        return nil
    }
    return String(source[lower.lowerBound..<upper.lowerBound])
}

@main
private enum AppleHardwareDecodeFallbackContractTests {
static func main() throws {
check("default decoder request is exact VideoToolbox",
      MPVHardwareDecodePolicy.requestedDecoder(arguments: ["VortX"]) == "videotoolbox")
check("diagnostic software override remains explicit user control",
      MPVHardwareDecodePolicy.requestedDecoder(
        arguments: ["VortX", "-stremiox-hwdec", "no"]) == "no")
check("requested VideoToolbox plus active no is a silent software fallback",
      MPVHardwareDecodePolicy.isSoftwareFallback(requested: "videotoolbox", active: "no"))
check("explicit Software is not mislabeled as a fallback",
      !MPVHardwareDecodePolicy.isSoftwareFallback(requested: "no", active: "no"))
check("active VideoToolbox is not mislabeled as a fallback",
      !MPVHardwareDecodePolicy.isSoftwareFallback(
        requested: "videotoolbox", active: "videotoolbox"))

let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let app = tests.deletingLastPathComponent()
let controller = try String(
    contentsOf: app.appendingPathComponent("Sources/Player/MPVMetalViewController.swift"),
    encoding: .utf8)
let playerScreen = try String(
    contentsOf: app.appendingPathComponent("Sources/PlayerScreen.swift"), encoding: .utf8)
let tvPlayerView = try String(
    contentsOf: app.appendingPathComponent("SourcesTV/TVPlayerView.swift"), encoding: .utf8)

let setup = section(
    controller,
    from: "let hwdec = MPVHardwareDecodePolicy.requestedDecoder(",
    to: "checkError(mpv_set_option_string(mpv, \"video-rotate\"") ?? ""
check("setup applies the policy result directly to mpv",
      setup.contains("mpv_set_option_string(mpv, \"hwdec\", hwdec)"))
check("setup synchronizes the settings selection with an explicit Software launch override",
      setup.contains("hardwareDecoding = hwdec != \"no\""))

let runtimeSwitch = section(
    controller, from: "func setHardwareDecoding(_ on: Bool)",
    to: "/// Player-settings detail") ?? ""
check("runtime control still offers exact VideoToolbox and Software requests",
      runtimeSwitch.contains("on ? MPVHardwareDecodePolicy.videoToolbox : \"no\"")
        && runtimeSwitch.contains("setString(\"hwdec\", requestedHardwareDecoder)"))

let receipt = section(
    controller, from: "private func recordHardwareDecoderNegotiation(active: String?)",
    to: "/// Switch the audio output policy") ?? ""
check("negotiation telemetry records requested, active, fallback, codec, and dimensions",
      receipt.contains("hwdec negotiation requested=")
        && receipt.contains(#"active=\(active)"#)
        && receipt.contains(#"fallback=\(fallback)"#)
        && receipt.contains(#"codec=\(codec)"#)
        && receipt.contains(#"video=\(width)x\(height)"#))
check("negotiation telemetry is one-shot until a load or explicit decoder change",
      receipt.contains("guard !loggedHardwareDecoderNegotiation")
        && controller.contains("loggedHardwareDecoderNegotiation = false"))

check("Playback Info names a silent VideoToolbox fallback as software",
      controller.contains("software (VideoToolbox unavailable)"))
check("Decoder settings preserve Hardware intent while exposing software activity",
      playerScreen.contains("hardwareDecoderSettingDetail")
        && tvPlayerView.contains("hardwareDecoderSettingDetail")
        && tvPlayerView.contains("OptionRow(label: \"Hardware\", detail: hardwareDetail")
        && controller.contains("VideoToolbox requested, software active"))

if failures > 0 {
    print("AppleHardwareDecodeFallbackContractTests: \(failures) FAILED")
    exit(1)
}
print("AppleHardwareDecodeFallbackContractTests: ALL PASS")
}
}
