import Foundation

enum PGSOCRPolicy {
    static let overrideKey = "vortx.pgsSubtitleOCR"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: overrideKey) != nil else { return false }
        return defaults.bool(forKey: overrideKey)
    }
}
