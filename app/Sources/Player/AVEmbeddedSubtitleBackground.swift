import CoreMedia
import Foundation

/// WebVTT has two independent backgrounds. Clear the enclosing text box explicitly, then apply
/// the user's choice behind the characters. Setting both to translucent black would compound
/// their alpha; leaving the enclosing box unspecified lets AVFoundation keep its default box.
enum AVEmbeddedSubtitleBackground {
    static func attributes(style: String) -> [String: Any] {
        let alpha: Double
        switch style {
        case "shaded": alpha = 0.5
        case "box": alpha = 1
        default: alpha = 0
        }
        return [
            kCMTextMarkupAttribute_BackgroundColorARGB as String: [0.0, 0, 0, 0],
            kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String: [alpha, 0, 0, 0]
        ]
    }
}
