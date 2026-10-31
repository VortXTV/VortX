import Foundation

// Only descriptor/hint dependencies for the real SubtitleAddons.swift are stubbed. AddonSubtitle itself,
// AddonPairingProtocol, SubtitleRequestMetadata, AddonURLGuard, and SubtitleFileBudget are production source.
struct CoreStreamBehaviorHints {
    let filename: String?
    let videoHash: String?
    let videoSize: Int64?
}
struct FixtureManifest { let name: String; let resources: [FixtureResource] }
struct FixtureResource { let name: String }
struct CoreDescriptor {
    let baseUrl: String
    let manifest: FixtureManifest
    let providesSubtitles: Bool
}
struct AddonDescriptor {
    let baseUrl: String
    let manifest: FixtureManifest
}
enum AddonTombstones {
    static func normalize(_ value: String) -> String { value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
}
