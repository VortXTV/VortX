import Foundation

/// Titles watched or started on the active profile, for the Library: every title watched stays
/// in the Library until the viewer removes it. Pure: built from the native playback projection.
enum VortxNativePreviouslyWatched {
    struct Title: Equatable, Sendable {
        let id: String
        let type: String
        let name: VortxJSON
        let poster: VortxJSON
        /// Seconds, the native clock unit; the latest watch or progress for any part of the title.
        let lastWatched: UInt64
    }

    /// The engine's own type for a watched or started title, which keys its Library removal record.
    static func type(of id: String, playback: VortxJSON?) -> String? {
        for row in (playback?["continueWatching"]?.array ?? []) + (playback?["history"]?.array ?? []) {
            if case .string(id)? = row["metaId"], case .string(let type)? = row["type"], !type.isEmpty { return type }
        }
        return nil
    }

    /// Every title in Continue Watching or the watch history, once, newest first. Titles in `excluding`
    /// are left out (the Library lists them already), and so is a title whose Library removal (seconds)
    /// is at or after its last watch: the viewer removed it, and only watching it again brings it back.
    static func titles(playback: VortxJSON?, excluding: Set<String>,
                       removedAt: (_ type: String, _ id: String) -> UInt64?) -> [Title] {
        var latest: [String: Title] = [:]
        for row in (playback?["continueWatching"]?.array ?? []) + (playback?["history"]?.array ?? []) {
            guard case .string(let id)? = row["metaId"], !id.isEmpty, !excluding.contains(id),
                  case .string(let type)? = row["type"], !type.isEmpty else { continue }
            let at = (try? row["updatedAt"]?.decode(UInt64.self)) ?? 0
            if let prior = latest[id], prior.lastWatched >= at { continue }
            latest[id] = Title(id: id, type: type, name: row["name"] ?? .string(id), poster: row["poster"] ?? .null, lastWatched: at)
        }
        return latest.values.filter { title in
            guard let removed = removedAt(title.type, title.id), removed > 0 else { return true }
            return removed < title.lastWatched
        }.sorted { $0.lastWatched == $1.lastWatched ? $0.id < $1.id : $0.lastWatched > $1.lastWatched }
    }
}
