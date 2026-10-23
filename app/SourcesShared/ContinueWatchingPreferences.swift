import Foundation
import os

enum ContinueWatchingService: String, Codable, CaseIterable, Sendable {
    case local, trakt, simkl
    var label: String { switch self { case .local: "Local / VortX"; case .trakt: "Trakt"; case .simkl: "SIMKL" } }
    var isPrivate: Bool { self != .local }
}

enum ContinueWatchingWindow: String, Codable, CaseIterable, Sendable {
    case last90Days, twenty = "20", forty = "40", sixty = "60", eighty = "80", hundred = "100"
    var label: String { self == .last90Days ? "Last 90 days" : "Last \(rawValue) items" }
    var cap: Int? { Int(rawValue) }
}

/// These flat keys are only the active profile projection, never a separate account setting.
enum ContinueWatchingPreferences {
    static let sourceKey = "vortx.home.continueWatching.source"
    static let windowKey = "vortx.home.continueWatching.window"
    static let changedNote = Notification.Name("vortx.home.continueWatching.preferenceChanged")
    private static let epoch = OSAllocatedUnfairLock(initialState: UInt64(0))
    static var selectionEpoch: UInt64 { epoch.withLock { $0 } }
    static func retireSelection() { epoch.withLock { $0 &+= 1 } }
    /// The Picker setter retires old work before its one projection write, even if SwiftUI
    /// coalesces A → B → A into no onChange callback. A same-value setter is a no-op.
    @discardableResult
    static func writeUserChoice(_ value: String, forKey key: String, defaults: UserDefaults = .standard,
                                write: () -> Void) -> Bool {
        guard key == sourceKey || key == windowKey else { return false }
        let fallback = key == sourceKey ? "local" : "20"
        guard (defaults.string(forKey: key) ?? fallback) != value else { return false }
        retireSelection()
        write()
        return true
    }
    struct Value: Hashable, Sendable {
        let source: ContinueWatchingService
        let window: ContinueWatchingWindow
        var isSupported = true
    }
    static func current(_ defaults: UserDefaults = .standard) -> Value {
        value(source: defaults.string(forKey: sourceKey), window: defaults.string(forKey: windowKey))
    }
    static func value(source: String?, window: String?) -> Value {
        Value(source: ContinueWatchingService(rawValue: source ?? "") ?? .local,
              window: ContinueWatchingWindow(rawValue: window ?? "") ?? .twenty,
              isSupported: source == nil || ContinueWatchingService(rawValue: source!) != nil)
    }
    static func activity(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
    /// Unknown activity sorts last for a cap and is excluded from a dated window. Never stamp "now".
    /// Key closures must be stable and side-effect-free for this call; each row is decorated once.
    static func bounded<T>(_ items: [T], window: ContinueWatchingWindow, now: Date,
                           activity: (T) -> String?, identity: (T) -> String) -> [T] {
        let decorated = items.enumerated().map { entry in
            (offset: entry.offset, element: entry.element,
             date: Self.activity(activity(entry.element)), key: identity(entry.element))
        }
        let ordered = decorated.sorted { a, b in
            let lhs = a.date, rhs = b.date
            if lhs != rhs { return (lhs ?? .distantPast) > (rhs ?? .distantPast) }
            let left = a.key, right = b.key
            return left == right ? a.offset < b.offset : left < right
        }
        if let cap = window.cap { return ordered.prefix(cap).map(\.element) }
        let cutoff = now.addingTimeInterval(-90 * 24 * 60 * 60)
        return ordered.filter { $0.date.map { $0 >= cutoff && $0 <= now } ?? false }.map(\.element)
    }
}
