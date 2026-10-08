/// Ordinary automatic selection must not start a new show in Season 0. Explicit episode targets,
/// saved resumes, and manual season choices are resolved by the caller before this fallback policy.
enum EpisodeDefaultSelectionPolicy {
    static func firstUnwatched<Element>(in ordered: [Element], season: (Element) -> Int?,
                                         isWatched: (Element) -> Bool) -> Element? {
        let ordinary = ordered.filter { season($0) != 0 }
        // If ordinary episodes exist, completing them never silently starts an unwatched special.
        return (ordinary.isEmpty ? ordered : ordinary).first { !isWatched($0) }
    }

    static func fallback<Element>(in ordered: [Element], season: (Element) -> Int?) -> Element? {
        ordered.first { season($0) != 0 } ?? ordered.first
    }
}
