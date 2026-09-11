import AVFoundation
import CoreMedia
import Foundation

@main
enum AVEmbeddedSubtitleBackgroundTests {
    static func main() throws {
        for (style, alpha) in [("outline", 0.0), ("shaded", 0.5), ("box", 1.0), ("unknown", 0.0)] {
            let attributes = AVEmbeddedSubtitleBackground.attributes(style: style)
            let rule = AVTextStyleRule(textMarkupAttributes: attributes)!
            precondition(rule.textMarkupAttributes[kCMTextMarkupAttribute_BackgroundColorARGB as String]
                as? [Double] == [0, 0, 0, 0], "\(style): default enclosing box must be cleared")
            precondition(rule.textMarkupAttributes[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String]
                as? [Double] == [alpha, 0, 0, 0], "\(style): character background must match preference")
            print("PASS native background \(style)")
        }
        let engine = try String(contentsOfFile: "app/Sources/Player/AVPlayerEngine.swift", encoding: .utf8)
        precondition(engine.contains("var attrs = AVEmbeddedSubtitleBackground.attributes(style: SubtitleStyle.backgroundId)"))
        precondition(engine.contains("applyEmbeddedSubtitleTextStyle()   // P5:"), "replacement media discovery must retain style reapplication")
        print("PASS native rule wiring and existing replacement styling retained")
    }
}
