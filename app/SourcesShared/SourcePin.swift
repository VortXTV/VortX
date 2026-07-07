import Foundation
import Combine

/// A user-pinned source preference.
///
/// Pinning captures a stream's *signature* - the add-on it came from, its resolution, and the add-on's
/// own bingeGroup id when present - rather than its exact URL (which changes per episode and again every
/// time a debrid service re-resolves it). That lets one pin keep preferring the same provider + quality
/// for every episode of a show, while the player's invisible auto-failover can still hop OFF a pinned
/// source the moment it goes dead: a pin is a *preference* expressed as a large ranking bonus, never a
/// hard lock. See `StreamRanking.pinBonus` and `PlayerScreen.hopToNextSource`.
struct SourcePin: Codable, Equatable {
    /// The source group's add-on name (e.g. "Torrentio"). The only field a `global` (provider) pin needs.
    var addon: String
    /// Resolution label as `StreamRanking.qualityLabel` prints it: "4K" / "1080p" / "720p" / "Best".
    var quality: String
    /// Coarse release flavor for the human label only ("Remux" / "BluRay" / "WEB" / ""), not part of the
    /// hard cross-episode match - matching on addon+quality stays robust when a season mixes flavors.
    var flavor: String
    /// The add-on's own same-release id, when it sets one. The strongest cross-episode key there is.
    var bingeGroup: String?

    /// Human label for the menu row + badge, e.g. "Torrentio · 4K · Remux".
    var label: String {
        var parts = [addon, quality]
        if !flavor.isEmpty { parts.append(flavor) }
        return parts.joined(separator: " · ")
    }
}

/// Where a pin applies. `entry` = this one movie or this one show (keyed by the meta id, so every episode
/// of a series shares it); `global` = every title (a plain provider preference).
enum SourcePinScope: String, Codable, CaseIterable { case entry, global }

/// A resolved pin plus the scope it came from, handed to the ranker. Scope changes match strictness:
/// `global` matches on add-on alone; `entry` matches on bingeGroup (exact) or add-on + resolution.
struct ResolvedPin: Equatable {
    let pin: SourcePin
    let scope: SourcePinScope
}

/// The minimal title context a stream list needs to offer pinning: the meta id (the movie or the show)
/// and whether it is a series, which only changes the menu wording ("this show" vs "this movie").
struct SourcePinContext: Equatable {
    let metaId: String
    let isSeries: Bool
    var entryNoun: String { isSeries ? "show" : "movie" }
}

/// Per-profile store of pinned sources, persisted in `UserDefaults` and namespaced by the active profile
/// id (like `LastStreamStore` and the streaming flat keys). Reloaded on a profile switch from `Profiles`,
/// alongside `SourcePreferences.reload()`.
final class SourcePinStore: ObservableObject {
    static let shared = SourcePinStore()

    @Published private(set) var entry: [String: SourcePin] = [:]   // metaId -> pin
    @Published private(set) var global: SourcePin?

    private var loadedProfile: String?

    private init() { reload() }

    private struct Blob: Codable {
        var entry: [String: SourcePin]
        var global: SourcePin?
    }

    private static func key(_ profile: String) -> String { "stremiox.sourcePins.\(profile)" }

    /// The active profile's stable key. `activeID` is a `UUID?`; fall back to a constant so a not-yet-loaded
    /// roster still has a namespace.
    private static var activeProfileKey: String { ProfileStore.shared.activeID?.uuidString ?? "default" }

    /// Re-read the active profile's pins. Called once at init and on every profile switch.
    func reload() {
        let profile = Self.activeProfileKey
        loadedProfile = profile
        guard let data = UserDefaults.standard.data(forKey: Self.key(profile)),
              let blob = try? JSONDecoder().decode(Blob.self, from: data) else {
            entry = [:]; global = nil; return
        }
        entry = blob.entry; global = blob.global
    }

    private func persist() {
        let profile = loadedProfile ?? Self.activeProfileKey
        let blob = Blob(entry: entry, global: global)
        if let data = try? JSONEncoder().encode(blob) {
            UserDefaults.standard.set(data, forKey: Self.key(profile))
        }
        StreamRanking.invalidateCaches()
    }

    // MARK: Build a pin from a chosen stream

    static func makePin(addon: String, stream: CoreStream) -> SourcePin {
        SourcePin(addon: addon,
                  quality: StreamRanking.qualityLabel(stream),
                  flavor: StreamRanking.releaseFlavor(stream),
                  bingeGroup: stream.behaviorHints?.bingeGroup)
    }

    // MARK: Mutations

    func pin(_ stream: CoreStream, addon: String, scope: SourcePinScope, context: SourcePinContext) {
        let p = Self.makePin(addon: addon, stream: stream)
        switch scope {
        case .entry:  entry[context.metaId] = p
        case .global: global = p
        }
        persist()
    }

    func unpin(scope: SourcePinScope, context: SourcePinContext) {
        switch scope {
        case .entry:  entry[context.metaId] = nil
        case .global: global = nil
        }
        persist()
    }

    func clearAll() {
        guard !entry.isEmpty || global != nil else { return }
        entry = [:]; global = nil; persist()
    }

    var pinnedCount: Int { entry.count + (global == nil ? 0 : 1) }

    // MARK: Resolution + matching

    /// The pin that applies to a title, most-specific first: an `entry` pin for this meta id wins over the
    /// `global` one. `nil` when nothing is pinned for this context.
    func effectivePin(_ context: SourcePinContext?) -> ResolvedPin? {
        if let context, let p = entry[context.metaId] { return ResolvedPin(pin: p, scope: .entry) }
        if let g = global { return ResolvedPin(pin: g, scope: .global) }
        return nil
    }

    func entryPin(_ context: SourcePinContext) -> SourcePin? { entry[context.metaId] }

    /// Whether `stream` (from `addon`) matches a resolved pin. Used by both the ranker bonus and the row
    /// badge, so the badge marks exactly the streams the pin would float to the top.
    static func matches(_ stream: CoreStream, addon: String, pin: ResolvedPin) -> Bool {
        let addonEqual = addon.caseInsensitiveCompare(pin.pin.addon) == .orderedSame
        switch pin.scope {
        case .global:
            return addonEqual
        case .entry:
            if let bg = pin.pin.bingeGroup, !bg.isEmpty, stream.behaviorHints?.bingeGroup == bg { return true }
            return addonEqual && StreamRanking.qualityLabel(stream) == pin.pin.quality
        }
    }
}
