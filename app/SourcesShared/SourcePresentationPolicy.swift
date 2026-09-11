import Foundation

/// Preserve add-on-authored line breaks, emoji and labels. Parsed labels are an explicit compact mode.
enum SourcePresentationPolicy {
    static func text(name: String?, description: String?, filename: String?) -> [String] {
        let authored = [name, description].compactMap { value -> String? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        if !authored.isEmpty { return authored }
        guard let filename, !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [filename]
    }

    static func mobileHeroHeight(width: CGFloat, viewport: CGFloat) -> CGFloat {
        guard viewport.isFinite, width.isFinite, viewport > 0, width > 0 else { return 420 }
        // Phone portrait takes the cinematic band requested by the viewer; tablet/landscape keeps
        // room for the source controls. The entire page scrolls, so Dynamic Type never clips actions.
        let phonePortrait = width < 600 && viewport > width
        return max(360, viewport * (phonePortrait ? 0.78 : 0.60))
    }
}
