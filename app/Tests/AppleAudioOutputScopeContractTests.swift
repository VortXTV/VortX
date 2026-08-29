// Standalone source contract for the Apple audio-output setting's truthful scope.
//
// Run from the repository root:
//   xcrun swiftc app/Tests/AppleAudioOutputScopeContractTests.swift \
//     -o .build/apple-audio-output-scope-contract \
//     && .build/apple-audio-output-scope-contract

import Foundation

private let tvScopeCopy = "Auto plays HLS and Dolby Vision through AVPlayer (AirPlay and Picture in Picture), with the full player controls, and uses the built-in libmpv player for torrents, MKV, and anything AVPlayer cannot open. If a stream will not start, choose Always libmpv."
private let iOSScopeCopy = "Auto plays HLS and Dolby Vision through AVPlayer (AirPlay and Picture in Picture) and uses the built-in libmpv player for torrents, MKV, and anything AVPlayer cannot open. If a stream will not start, choose Always libmpv."

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL  \(message)\n".utf8))
    exit(1)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fail(message) }
    print("PASS  \(message)")
}

private func section(in text: String, from start: String, to end: String) -> String {
    guard let lower = text.range(of: start),
          let upper = text.range(of: end, range: lower.upperBound..<text.endIndex) else {
        fail("find \(start) section")
    }
    return String(text[lower.lowerBound..<upper.lowerBound])
}

let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
let app = URL(fileURLWithPath: root).appendingPathComponent("app")
let tvPath = app.appendingPathComponent("SourcesTV/SettingsView.swift")
let iOSPath = app.appendingPathComponent("SourcesiOS/iOSSettingsView.swift")
let controllerPath = app.appendingPathComponent("Sources/Player/MPVMetalViewController.swift")
let catalogPath = app.appendingPathComponent("Resources/Localizable.xcstrings")

guard let tv = try? String(contentsOf: tvPath, encoding: .utf8),
      let iOS = try? String(contentsOf: iOSPath, encoding: .utf8),
      let controller = try? String(contentsOf: controllerPath, encoding: .utf8),
      let catalogData = try? Data(contentsOf: catalogPath),
      let catalog = try? JSONSerialization.jsonObject(with: catalogData) as? [String: Any] else {
    fail("read Apple settings sources")
}

func localizationCount(for key: String) -> Int {
    let strings = catalog["strings"] as? [String: Any]
    let entry = strings?[key] as? [String: Any]
    return (entry?["localizations"] as? [String: Any])?.count ?? 0
}

let audioOutputLocalizationCount = localizationCount(for: "Audio output")
require(audioOutputLocalizationCount > 0,
        "Audio output has catalog localizations")
require(localizationCount(for: tvScopeCopy) == audioOutputLocalizationCount,
        "tvOS scope copy reuses a fully localized catalog key")
require(localizationCount(for: iOSScopeCopy) == audioOutputLocalizationCount,
        "iOS scope copy reuses a fully localized catalog key")

let tvPlayback = section(
    in: tv,
    from: "private var playbackSection: some View {",
    to: "choiceRow(String(localized: \"Video upscaling\")"
)
require(tv.contains("@AppStorage(AudioOutputMode.key) private var audioOutput"),
        "tvOS preserves the saved global audio-output binding")
require(tvPlayback.contains("choiceRow(String(localized: \"Audio output\")"),
        "tvOS reuses the translated Audio output label")
require(tvPlayback.contains("selection: $audioOutput"),
        "tvOS scope copy does not replace the selectable setting")
require(tvPlayback.contains(".accessibilityHint(String(localized: \"\(tvScopeCopy)\"))"),
        "tvOS exposes localized player-routing scope in an accessibility hint")
require(tvPlayback.contains("Text(String(localized: \"\(tvScopeCopy)\"))"),
        "tvOS visibly explains the player-routing scope from the catalog")
let tvChoiceRow = section(
    in: tv,
    from: "private func choiceRow(_ label: String, _ options: [(id: String, label: String)]",
    to: "/// Numeric variant of `choiceRow`"
)
require(tvChoiceRow.contains(".focusSection()"),
        "tvOS audio-output row retains choiceRow focus ownership")

let iOSPlayback = section(
    in: iOS,
    from: "@ViewBuilder private var playbackSection: some View {",
    to: "@ViewBuilder private var advancedSection: some View {"
)
require(iOS.contains("@AppStorage(AudioOutputMode.key) private var audioOutput"),
        "iOS preserves the saved global audio-output binding")
require(iOSPlayback.contains("Picker(\"Audio output\", selection: $audioOutput)"),
        "iOS reuses the translated Audio output label")
require(iOSPlayback.contains(".accessibilityHint(String(localized: \"\(iOSScopeCopy)\"))"),
        "iOS exposes localized player-routing scope in an accessibility hint")
require(iOSPlayback.contains("Text(String(localized: \"\(iOSScopeCopy)\"))"),
        "iOS visibly explains the player-routing scope from the catalog")
require(iOSPlayback.contains("Text(AudioOutputMode(rawValue: audioOutput)?.detail ?? \"\")"),
        "iOS keeps the selected mode detail")

let macInitialization = section(
    in: controller,
    from: "#elseif os(macOS)\n        // Desktop mpv's CoreAudio output",
    to: "        #endif\n\n        // Video upscaling"
)
require(macInitialization.contains("AudioOutputMode.current == .stereo"),
        "macOS consumes the persisted Stereo choice before libmpv initialization")
require(macInitialization.contains("mpv_set_option_string(mpv, \"audio-channels\", \"stereo\")"),
        "macOS initialization applies only the safe Stereo channel policy")
require(!macInitialization.contains("audio-spdif"),
        "macOS initialization makes no app-side SPDIF request")
let macRuntime = section(
    in: controller,
    from: "#elseif os(macOS)\n        // macOS CoreAudio owns normal route negotiation.",
    to: "        #else\n        setString(\"audio-channels\", channelPolicy)"
)
require(macRuntime.contains("setString(\"audio-channels\", mode == .stereo ? \"stereo\" : \"auto-safe\")"),
        "macOS live changes preserve Stereo and return other choices to safe automatic routing")

print("PASS  Apple audio-output scope contract")
