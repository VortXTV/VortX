import Foundation

/// A disposable projection of the current admitted Library. It never loads metadata, caches facts
/// across owners or writes an account. Type remains part of every identity, even when ids collide.
enum LibraryGenreFilter {
    struct Key: Hashable, Sendable { let id: String; let type: String }
    struct Entry: Sendable { let key: Key; let genres: [String]? }
    struct Choice: Hashable, Identifiable, Sendable {
        let id: String
        let name: String
        private init(id: String, name: String) { self.id = id; self.name = name }
        static let all = Choice(id: "all", name: "")
        static let unknown = Choice(id: "unknown", name: "")
        static func genre(_ name: String) -> Choice { Choice(id: "genre:" + LibraryGenreFilter.canonical(name), name: name) }
        static func == (a: Choice, b: Choice) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        var label: String {
            switch id {
            case "all": return String(localized: "All genres")
            case "unknown": return String(localized: "Unknown genre")
            default: return name
            }
        }
    }
    static func canonical(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
    struct Projection: Sendable {
        let choices: [Choice]
        private let keys: Set<Key>
        private let facts: [Key: Set<String>]
        init(_ entries: [Entry], selected: Choice) {
            var keys = Set<Key>(), facts: [Key: Set<String>] = [:], names: [String: Choice] = [:]
            for entry in entries where keys.insert(entry.key).inserted {
                let genres = LibraryGenreFacts.normalized(entry.genres) ?? []
                facts[entry.key] = Set(genres.map(LibraryGenreFilter.canonical))
                for name in genres {
                    let choice = Choice.genre(name)
                    if names[choice.id] == nil { names[choice.id] = choice }
                }
            }
            // A selected genre stays a visible, stably identified control when its last row leaves.
            // The empty result remains explicit and All is always available; focus cannot jump to
            // another genre merely because metadata inserted a chip before this one.
            if selected.id.hasPrefix("genre:"), names[selected.id] == nil { names[selected.id] = selected }
            self.keys = keys; self.facts = facts
            choices = [.all, .unknown] + names.values.sorted { $0.id < $1.id }
        }
        func matches(_ key: Key, selected: Choice) -> Bool {
            guard keys.contains(key) else { return false }
            switch selected.id {
            case "all": return true
            case "unknown": return facts[key, default: []].isEmpty
            default: return facts[key, default: []].contains(String(selected.id.dropFirst("genre:".count)))
            }
        }
        func filter<T>(_ items: [T], selected: Choice, key: (T) -> Key) -> [T] {
            items.filter { matches(key($0), selected: selected) }
        }
    }
}
