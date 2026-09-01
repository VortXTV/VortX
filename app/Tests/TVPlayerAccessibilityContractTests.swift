import Foundation

private struct Check {
    var failures = 0

    mutating func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            print("PASS: \(message)")
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }
}

private func section(_ source: String, from start: String, to end: String) -> String? {
    guard let startRange = source.range(of: start) else { return nil }
    let suffix = source[startRange.lowerBound...]
    guard let endRange = suffix.range(of: end) else { return nil }
    return String(suffix[..<endRange.lowerBound])
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let playerURL = root.appendingPathComponent("app/SourcesTV/TVPlayerView.swift")
let player = (try? String(contentsOf: playerURL, encoding: .utf8)) ?? ""
private var check = Check()

let remoteHandling = section(
    player,
    from: "private func handlePress(_ type: UIPress.PressType)",
    to: "private var canEditSkip"
) ?? ""
check.require(
    remoteHandling.contains("case .sourceAudio:      openPanel(.sources, preferredAccessibilityID: \"sources.audio\")"),
    "Back from source audio returns to Sources at the stable Audio parent"
)
check.require(
    remoteHandling.contains("case .upArrow: moveOption(-1)")
        && remoteHandling.contains("case .select: activateOption()"),
    "the raw Siri Remote options path remains intact"
)

let sourceRows = section(player, from: "private func sourceRows()", to: "private func playerSettingsRows()") ?? ""
check.require(
    sourceRows.contains("accessibilityID: \"sources.audio\"")
        && sourceRows.contains("accessibilityID: \"source-audio.auto\"")
        && sourceRows.contains("accessibilityID: \"source-audio.language.\\(lang.id)\""),
    "Sources and source-audio rows publish stable semantic identities"
)
check.require(
    sourceRows.components(separatedBy: "openPanel(.sources, preferredAccessibilityID: \"sources.audio\")").count >= 3,
    "Auto and language choices restore the Audio parent instead of the playing source"
)

check.require(
    player.contains("@Environment(\\.accessibilityReduceMotion) private var accessibilityReduceMotion")
        && player.contains(".transition(accessibilityReduceMotion ? .identity : .move(edge: .trailing))")
        && player.contains("if accessibilityReduceMotion {\n                        proxy.scrollTo(optionRow, anchor: .center)")
        && player.contains(".scaleEffect(accessibilityReduceMotion ? 1.0"),
    "Reduce Motion suppresses panel movement, animated scrolling, and focus scaling"
)

let bridge = section(player, from: "// MARK: - Remote-catcher accessibility bridge", to: "private func timeString") ?? ""
check.require(
    bridge.contains("remoteAccessibilityItems")
        && bridge.contains("controlAccessibilityLabel")
        && bridge.contains("remoteAccessibilityActivate")
        && bridge.contains("remoteAccessibilityAdjust"),
    "the virtual accessibility tree mirrors labels, activation, and adjustable transport state"
)
check.require(
    bridge.contains("if reconnecting { return \"Reconnecting playback\" }")
        && bridge.contains("return \"Loading season \\(pending.meta.season ?? 0), episode \\(pending.meta.episode ?? 0)\""),
    "episode loading and playback recovery publish status announcements"
)

let catcher = section(player, from: "private struct RemoteCatcher", to: "private extension") ?? String(player.suffix(20_000))
check.require(
    catcher.contains("ActionAccessibilityElement: UIAccessibilityElement")
        && catcher.contains("override func accessibilityActivate() -> Bool")
        && catcher.contains("override func accessibilityPerformEscape() -> Bool")
        && catcher.contains("override func accessibilityIncrement()")
        && catcher.contains("UIAccessibility.post(notification: .announcement"),
    "RemoteCatcher exposes activation, escape, adjustment, and edge-triggered announcements"
)
check.require(
    catcher.contains("case .select, .menu, .playPause:")
        && catcher.contains("case .upArrow, .downArrow, .leftArrow, .rightArrow:"),
    "the low-level remote press routing remains present"
)

if check.failures > 0 {
    print("TV player accessibility contract failed: \(check.failures)")
    exit(1)
}
print("TV player accessibility contract passed")
