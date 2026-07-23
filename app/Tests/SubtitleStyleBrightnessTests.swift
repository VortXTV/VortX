// Executable harness for the subtitle brightness / grey-preset math (#155).
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/subtitle-style-brightness-test \
//     app/Sources/Player/SubtitleStyle.swift \
//     app/Tests/SubtitleStyleBrightnessTests.swift && /tmp/subtitle-style-brightness-test
//
// SubtitleStyle is Foundation-only, so this suite compiles it directly and asserts on the PRODUCTION math:
// `dimmedHex` (the one chokepoint both engines read through `colorHex`), the brightness-level table, the new
// grey preset, and the end-to-end `colorHex` for preset x brightness. The bar is mutation survival, not a pass
// count: the identity no-op, the clamps, and each channel are asserted so a flipped clamp or a dropped channel
// turns a case RED.

import Foundation

@MainActor var failures = 0
@MainActor func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

@main
enum SubtitleStyleBrightnessTests {
@MainActor static func main() {
// MARK: dimmedHex, the pure per-channel multiply

// Default (100%) is the identity no-op: an existing viewer's white subtitles are byte-for-byte unchanged.
check("white x 1.0 is identity", SubtitleStyle.dimmedHex("#FFFFFF", factor: 1.0) == "#FFFFFF")
check("white x 0.8", SubtitleStyle.dimmedHex("#FFFFFF", factor: 0.80) == "#CCCCCC")   // 255*0.8 = 204 = 0xCC
check("white x 0.6", SubtitleStyle.dimmedHex("#FFFFFF", factor: 0.60) == "#999999")   // 255*0.6 = 153 = 0x99
check("white x 0.4", SubtitleStyle.dimmedHex("#FFFFFF", factor: 0.40) == "#666666")   // 255*0.4 = 102 = 0x66

// Grey preset (#B3B3B3 = 179) dims proportionally; 179*0.6 = 107.4 -> rounds to 107 = 0x6B.
check("grey x 1.0 is identity", SubtitleStyle.dimmedHex("#B3B3B3", factor: 1.0) == "#B3B3B3")
check("grey x 0.6 rounds", SubtitleStyle.dimmedHex("#B3B3B3", factor: 0.60) == "#6B6B6B")

// Hue is preserved: yellow keeps its zero blue channel while red+green dim together (not a luminance-to-grey).
check("yellow x 0.8 preserves hue", SubtitleStyle.dimmedHex("#FFFF00", factor: 0.80) == "#CCCC00")

// Clamping: a factor above 1 cannot brighten past the preset (clamped to 1.0 -> identity); a negative factor
// floors at black rather than wrapping. Both guard against a corrupt stored level.
check("factor > 1 clamps to identity", SubtitleStyle.dimmedHex("#FFFFFF", factor: 1.5) == "#FFFFFF")
check("factor < 0 clamps to black", SubtitleStyle.dimmedHex("#FFFFFF", factor: -0.5) == "#000000")
check("factor 0 is black", SubtitleStyle.dimmedHex("#FFFFFF", factor: 0.0) == "#000000")

// Malformed input is returned unchanged so a caller never renders an empty colour.
check("short hex returned unchanged", SubtitleStyle.dimmedHex("#FFF", factor: 0.6) == "#FFF")
check("non-hex returned unchanged", SubtitleStyle.dimmedHex("#GGGGGG", factor: 0.6) == "#GGGGGG")
// A hex without the leading '#' still dims (the renderers strip '#' the same way).
check("hex without hash still dims", SubtitleStyle.dimmedHex("FFFFFF", factor: 0.60) == "#999999")

// MARK: level table + grey preset

check("four brightness levels", SubtitleStyle.brightnessLevels.count == 4)
check("first level is the 100% default",
      SubtitleStyle.brightnessLevels.first?.id == SubtitleStyle.defaultBrightness
        && SubtitleStyle.brightnessLevels.first?.factor == 1.0)
check("levels descend to 40%",
      SubtitleStyle.brightnessLevels.map { $0.factor } == [1.0, 0.80, 0.60, 0.40])
check("grey preset present at ~70% white",
      SubtitleStyle.colors.contains { $0.id == "grey" && $0.hex == "#B3B3B3" })

// MARK: colorHex end-to-end (preset x brightness through UserDefaults, the way the engines read it)

UserDefaults.standard.set("white", forKey: SubtitleStyle.Key.color)
UserDefaults.standard.removeObject(forKey: SubtitleStyle.Key.brightness)
check("default colorHex is undimmed white", SubtitleStyle.colorHex == "#FFFFFF")
check("default brightnessFactor is 1.0", SubtitleStyle.brightnessFactor == 1.0)

UserDefaults.standard.set("60", forKey: SubtitleStyle.Key.brightness)
check("white at 60% colorHex", SubtitleStyle.colorHex == "#999999")

UserDefaults.standard.set("grey", forKey: SubtitleStyle.Key.color)
check("grey at 60% colorHex", SubtitleStyle.colorHex == "#6B6B6B")

UserDefaults.standard.set("nonsense", forKey: SubtitleStyle.Key.brightness)
check("unknown level falls back to full brightness (grey undimmed)", SubtitleStyle.colorHex == "#B3B3B3")

if failures == 0 { print("\nALL PASS") } else { print("\n\(failures) FAILURE(S)"); exit(1) }
}
}
