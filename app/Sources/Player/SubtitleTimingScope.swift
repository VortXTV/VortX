import Foundation

/// Stable device-local identity for one title or episode and one authoritative release description.
///
/// This value is deliberately smaller than the community subtitle fingerprint. It does not know about
/// engines, URLs, persistence, or lifecycle. Callers must supply an actual content identity and release
/// description; unknown or empty inputs fail closed so timing can never leak across an unscoped load.
struct SubtitleTimingScope: Hashable, Sendable {
    let contentKey: String
    let releaseFingerprint: String

    init?(contentKey: String?, releaseFingerprint: String?) {
        guard let contentKey = Self.trimmed(contentKey),
              let releaseFingerprint = Self.trimmed(releaseFingerprint),
              !Self.isUnknown(contentKey),
              !Self.isUnknown(releaseFingerprint) else {
            return nil
        }
        self.contentKey = contentKey
        self.releaseFingerprint = releaseFingerprint
    }

    /// Deterministic composite key for the v2 device-local store.
    var storageKey: String {
        "\(contentKey)|\(releaseFingerprint)"
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isUnknown(_ value: String) -> Bool {
        value.caseInsensitiveCompare("unknown") == .orderedSame
    }
}
