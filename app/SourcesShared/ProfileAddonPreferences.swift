import Foundation

/// Profile presentation choices only. Account installation membership and deletion receipts never
/// enter this value. Missing overrides follow the account owner's current choices, including future
/// changes. An explicitly empty disabled list means all installed add-ons are visible.
struct ProfileAddonPreferences: Codable, Equatable {
    var disabledAddonURLsOverride: [String]? = nil
    var rankingOverride: ProfileAddonRanking? = nil
}

struct ProfileAddonRanking: Codable, Equatable {
    /// nil is used only by migrated source-ranking preferences that never had a personal add-on order.
    /// It continues following the account order until the viewer explicitly customizes the order.
    var addonOrder: [String]? = nil
    var sourceTypeOrder: [String]
    var useAddonOrder: Bool
}

/// Foundation-only policy shared by the live profile projection and deterministic contract tests.
enum ProfileAddonPreferencesPolicy {
    /// URL paths, queries and fragments may contain case-sensitive configuration. Normalize only the
    /// URL's scheme/host and surrounding whitespace, never the configured path or its credentials.
    static func identity(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URLComponents(string: trimmed), url.scheme != nil, url.host != nil else {
            return trimmed
        }
        url.scheme = url.scheme?.lowercased()
        url.host = url.host?.lowercased()
        return url.string ?? trimmed
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map(identity).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func disabled(override: [String]?, inherited: [String]) -> [String] {
        unique(override ?? inherited)
    }

    /// Unlisted new installations remain present and stable after the explicitly ranked entries.
    static func sorted<T>(_ items: [T], order: [String], key: (T) -> String) -> [T] {
        let rank = Dictionary(unique(order).enumerated().map { ($0.element, $0.offset) },
                              uniquingKeysWith: { first, _ in first })
        return items.enumerated().sorted { lhs, rhs in
            let a = rank[identity(key(lhs.element))] ?? Int.max
            let b = rank[identity(key(rhs.element))] ?? Int.max
            return a == b ? lhs.offset < rhs.offset : a < b
        }.map(\.element)
    }

    /// Legacy records have no durable Follow Main marker. Explicit ranking fields are therefore
    /// personal choices even when equal to Main; comparing values would change their mode after a
    /// later Main edit. Only absent fields inherit, while new carriers retain their nil overrides.
    static func migrated(legacyDisabled: [String]?, legacyTypes: [String]?, legacyUseOrder: Bool?,
                         inheritedRanking: ProfileAddonRanking) -> ProfileAddonPreferences {
        let types = legacyTypes ?? inheritedRanking.sourceTypeOrder
        let useOrder = legacyUseOrder ?? inheritedRanking.useAddonOrder
        let customized = legacyTypes != nil || legacyUseOrder != nil
        return ProfileAddonPreferences(
            disabledAddonURLsOverride: legacyDisabled.map(unique),
            rankingOverride: customized ? ProfileAddonRanking(
                sourceTypeOrder: types, useAddonOrder: useOrder) : nil)
    }
}
