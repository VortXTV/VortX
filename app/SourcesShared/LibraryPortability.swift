import Foundation

/// Portable export / import of a single profile's library + watch history, so a viewer can carry
/// their saved titles and progress to another device or another profile without the account in the
/// loop. Companion to `SettingsBackup` (which carries preferences); this one carries the watch data.
///
/// The file is a flat, human-inspectable JSON envelope of `Item`s. It is storage-agnostic on
/// purpose: the active-profile read/write that actually honours the per-profile invariant (engine
/// library for the owner, the private overlay for every other profile) lives in `ProfileStore`
/// (`exportActiveLibraryItems` / `importLibraryItems`). This type is pure serialization only, with
/// no UserDefaults / engine dependency, so it stays trivially testable.
enum LibraryPortability {
    static let schema = 1
    static let formatTag = "vortx-library"

    /// One saved title with its watch state. Mirrors the fields both the overlay `WatchEntry` and the
    /// engine `CoreCWItem` can supply, so an export round-trips between profile kinds. `watchedVideoIds`
    /// is populated for overlay profiles (the engine owns per-episode ticks for the owner, so it stays
    /// empty there); a null/zero offset is a saved-but-unwatched title.
    struct Item: Codable, Equatable {
        var metaId: String
        var type: String
        var name: String
        var poster: String?
        var videoId: String?
        var timeOffsetMs: Int
        var durationMs: Int
        var lastWatched: String          // ISO timestamp; orders the rail + drives last-writer-wins merges
        var watchedVideoIds: [String]
    }

    struct Envelope: Codable {
        var format: String
        var schema: Int
        var app: String
        var profile: String
        var createdAt: Date
        var count: Int
        var items: [Item]
    }

    enum RestoreError: LocalizedError {
        case notALibrary

        var errorDescription: String? {
            switch self {
            case .notALibrary: return "This file is not a VortX library export."
            }
        }
    }

    // MARK: Pure serialization (no UserDefaults / engine dependency)

    static func encode(items: [Item], profile: String, now: Date = Date()) throws -> Data {
        let env = Envelope(
            format: formatTag, schema: schema,
            app: (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String) ?? "VortX",
            profile: profile, createdAt: now, count: items.count, items: items
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(env)
    }

    static func decode(from data: Data) throws -> [Item] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let env = try? dec.decode(Envelope.self, from: data), env.format == formatTag else {
            throw RestoreError.notALibrary
        }
        return env.items
    }

    /// Suggested exporter filename (the `.json` extension is appended from the content type).
    static func defaultFilename(profile: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmm"
        let safe = profile.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let tag = safe.isEmpty ? "Library" : safe
        return "VortX-Library-\(tag)-\(df.string(from: Date()))"
    }
}
