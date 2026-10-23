import Foundation

/// Derived facts about an automatically picked next episode, for diagnosing a wrong episode or language.
/// Only numbers, flags and language codes are logged: never a title, release name, file name or URL.
enum BingePickDiagnostics {
    static func describe(_ stream: CoreStream, resolvedURL: URL, season: Int?, episode: Int?,
                         desiredAudio: String?, chosenBingeGroup: String?) -> String {
        let releaseText = StreamRanking.signature(stream).lowercased()
        let fileName = (resolvedURL.lastPathComponent.removingPercentEncoding ?? resolvedURL.lastPathComponent).lowercased()
        let foreign = desiredAudio.map { StreamRanking.continuityLanguageMismatch(stream, desired: $0) }
        let sameRelease = chosenBingeGroup.map { stream.behaviorHints?.bingeGroup == $0 }
        let seasonText = season.map(String.init) ?? "?"
        let episodeText = episode.map(String.init) ?? "?"
        let foreignText = foreign.map(String.init) ?? "-"
        let releaseMatchText = sameRelease.map(String.init) ?? "-"
        let parts: [String] = [
            "target=S\(seasonText)E\(episodeText)",
            "res=\(StreamRanking.resolutionRank(stream))",
            "episodeInRelease=\(mention(of: episode, in: releaseText))",
            "episodeInFile=\(mention(of: episode, in: fileName))",
            "audio=\(desiredAudio ?? "-")",
            "foreignAudioClaim=\(foreignText)",
            "sameRelease=\(releaseMatchText)",
        ]
        return parts.joined(separator: " ")
    }

    /// `match` when the text names the target episode, `other` when it names only different episodes,
    /// `none` when it names no episode (a season pack or an unnumbered file).
    static func mention(of episode: Int?, in text: String) -> String {
        guard let episode else { return "untargeted" }
        let named = episodeNumbers(in: text)
        if named.isEmpty { return "none" }
        return named.contains(episode) ? "match" : "other"
    }

    /// Episode numbers written as `S01E53` / `E053` / `Ep 53` / `Episode 53`, or anime-style ` - 053`.
    static func episodeNumbers(in text: String) -> Set<Int> {
        let patterns = [#"(?<![a-z])e(?:p|pisode)?[ ._]?0*(\d{1,4})(?!\d)"#, #"(?:^|\s)-\s0*(\d{1,4})(?!\d)"#]
        var numbers = Set<Int>()
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                if let r = Range(match.range(at: 1), in: text), let value = Int(text[r]) { numbers.insert(value) }
            }
        }
        return numbers
    }
}
