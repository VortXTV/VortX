import Foundation

/// The four source categories the ranking system recognises.
enum SourceType: String, CaseIterable, Codable {
    case debrid  = "debrid"
    case usenet  = "usenet"
    case torrent = "torrent"
    case direct  = "direct"

    var label: String {
        switch self {
        case .debrid:  return "Debrid"
        case .usenet:  return "Usenet"
        case .torrent: return "Torrent"
        case .direct:  return "Direct"
        }
    }

    var detail: String {
        switch self {
        case .debrid:  return "Real-Debrid, AllDebrid, Premiumize, TorBox, Debrid-Link"
        case .usenet:  return "NZB / Usenet sources"
        case .torrent: return "BitTorrent info-hash streams"
        case .direct:  return "Plain HTTP/HTTPS streams from add-ons"
        }
    }
}

/// Persisted source-ranking preferences.
/// Observed by SettingsView and read by StreamRanking at score time.
final class SourcePreferences: ObservableObject {
    static let shared = SourcePreferences()

    private static let orderKey      = "stremiox.streaming.sourceTypeOrder"
    private static let addonOrderKey = "stremiox.streaming.useAddonOrder"

    // Max possible quality score is ~13,800 (4K + cached + remux + HDR + atmos + file-size cap).
    // A 15,000-point tier gap means the preferred type ALWAYS beats a lower type regardless of quality.
    private static let tierWeights = [45_000, 30_000, 15_000, 0]

    @Published var typeOrder: [SourceType] {
        didSet {
            UserDefaults.standard.set(
                typeOrder.map(\.rawValue).joined(separator: ","),
                forKey: Self.orderKey
            )
            StreamRanking.invalidateCaches()   // memoized scores embed the tier weights
        }
    }

    @Published var useAddonOrder: Bool {
        didSet { UserDefaults.standard.set(useAddonOrder, forKey: Self.addonOrderKey) }
    }

    private init() {
        typeOrder     = Self.readOrder()
        useAddonOrder = UserDefaults.standard.bool(forKey: Self.addonOrderKey)
    }

    private static func readOrder() -> [SourceType] {
        let saved = UserDefaults.standard.string(forKey: orderKey) ?? ""
        var order = saved.split(separator: ",").compactMap { SourceType(rawValue: String($0)) }
        for t in SourceType.allCases where !order.contains(t) { order.append(t) }
        return order
    }

    /// Re-read both keys from UserDefaults into the published props. The singleton reads them only
    /// at init, so a profile switch (which rewrites the flat keys) must call this to take effect
    /// live. The didSet observers re-persist the same values (a no-op write) and invalidate the
    /// ranking cache, which is exactly what a source-preference change needs. Call on the main
    /// thread (same contract as the rest of the profile/theme switch path).
    func reload() {
        let order = Self.readOrder()
        if typeOrder != order { typeOrder = order }
        let addon = UserDefaults.standard.bool(forKey: Self.addonOrderKey)
        if useAddonOrder != addon { useAddonOrder = addon }
    }

    /// Dominant-tier score added to a stream so its source type is the primary sort key.
    func tierWeight(for type: SourceType) -> Int {
        let idx = typeOrder.firstIndex(of: type) ?? (typeOrder.count - 1)
        return idx < Self.tierWeights.count ? Self.tierWeights[idx] : 0
    }

    /// Move the type at `index` one step toward the top (direction = -1) or bottom (+1).
    func moveType(at index: Int, direction: Int) {
        let target = index + direction
        guard target >= 0, target < typeOrder.count else { return }
        typeOrder.swapAt(index, target)
    }
}
