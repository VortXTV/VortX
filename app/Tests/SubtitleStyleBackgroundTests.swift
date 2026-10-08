import Foundation

@main
enum SubtitleStyleBackgroundTests {
    @MainActor static func main() throws {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            if condition { print("PASS  \(name)") }
            else { failures += 1; print("FAIL  \(name)") }
        }
        for font in ["modern", "classic"] {
            var properties: [String: String] = [:]
            // Reuse one simulated player: all three modes must fully replace the preceding mode.
            for background in ["shaded", "box", "outline", "box", "unknown"] {
                let options = SubtitleStyle.mpvBackgroundOptions(background: background, font: font)
                for (name, value) in options { properties[name] = value }
                let boxed = background == "shaded" || background == "box"
                check("\(font) \(background) selects the actual box or outline renderer",
                      properties["sub-border-style"] == (boxed ? "background-box" : "outline-and-shadow"))
                let alpha = background == "box" ? "#FF000000"
                    : boxed || font == "modern" ? "#80000000" : "#00000000"
                check("\(font) \(background) applies its opacity and resets box padding or shadow offset",
                      properties["sub-back-color"] == alpha
                        && properties["sub-shadow-offset"] == (boxed || font == "modern" ? "2" : "0"))
                check("\(font) \(background) never writes the aliased shadow color a second time",
                      Set(options.map(\.0)).count == options.count
                        && !options.contains { $0.0 == "sub-shadow-color" })
            }
        }
        let options = SubtitleStyle.mpvOptions
        let actual = Dictionary(uniqueKeysWithValues: options)
        let expected = SubtitleStyle.mpvBackgroundOptions(
            background: SubtitleStyle.backgroundId, font: SubtitleStyle.fontId)
        check("complete production style uses the same background mapping without alias conflicts",
              expected.allSatisfy { actual[$0.0] == $0.1 }
                && !options.contains { $0.0 == "sub-shadow-color" })
        let enginePath = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Player/MPVMetalViewController.swift")
        let engine = try String(contentsOf: enginePath, encoding: .utf8)
        check("initial mount and live settings both consume the complete style",
              engine.components(separatedBy: "for (name, value) in SubtitleStyle.mpvOptions").count == 3)
        print("===== FAILURES: \(failures) =====")
        exit(failures == 0 ? 0 : 1)
    }
}
