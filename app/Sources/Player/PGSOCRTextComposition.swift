import Foundation

/// Keeps one bitmap-subtitle composition readable when Vision reports the same text from overlapping PGS
/// rectangles. The input order is visual reading order, so only exact normalized repeats are removed.
enum PGSOCRTextComposition {
    static func normalizedLines(_ candidates: [String]) -> [String] {
        var seen: Set<String> = []
        return candidates.compactMap { candidate in
            let line = candidate
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            guard !line.isEmpty, seen.insert(line).inserted else { return nil }
            return line
        }
    }
}
