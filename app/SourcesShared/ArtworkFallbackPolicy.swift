import Foundation

enum ArtworkFallbackPolicy {
    static func candidates(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let value else { return nil }
            let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: candidate),
                  let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
                  let host = url.host, !host.isEmpty,
                  seen.insert(candidate).inserted else { return nil }
            return candidate
        }
    }

    @MainActor
    static func firstAvailable<Result>(
        _ candidates: [String], load: (String) async -> Result?
    ) async -> Result? {
        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            let result = await load(candidate)
            guard !Task.isCancelled else { return nil }
            if let result { return result }
        }
        return nil
    }
}
