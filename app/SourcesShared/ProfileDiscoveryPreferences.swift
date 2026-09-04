import Foundation

/// The discovery/catalog state that belongs to one VortX profile. It is deliberately a
/// Foundation-only value so the profile roster can sync it and the executable contract can run the
/// same capture/apply implementation without SwiftUI or the player targets.
///
/// nil fields are wire-compatible with pre-feature and partially upgraded rosters. On a real
/// profile switch they resolve to the documented flat-key defaults; during a background sync fold
/// they leave the current live value intact until that viewer is explicitly selected.
struct ProfileDiscoveryPreferences: Codable, Equatable {
    var hiddenCatalogs: [String]? = nil
    var catalogOrder: [String]? = nil
    var hiddenHubCategories: [String]? = nil
    /// nil marker means a legacy/partial roster never captured this field. true means the
    /// accompanying optional is authoritative, including nil as an intentional clear.
    var regionOverrideCaptured: Bool? = nil
    var regionOverride: String? = nil
    /// Encoded DiscoverFilters payload. Keeping the transport as opaque Codable data means a
    /// newer filter schema can follow a profile without this persistence boundary needing UI types.
    var filtersCaptured: Bool? = nil
    var filtersData: Data? = nil
    var selectedProviders: [Int]? = nil
    var providerOrder: [Int]? = nil
    /// Tab visibility is deliberately captured as a group: false is a meaningful choice, so the
    /// marker distinguishes an explicit visible tab from a pre-feature roster that has no opinion.
    var tabVisibilityCaptured: Bool? = nil
    var hideLiveTab: Bool? = nil
    var hideDiscoverTab: Bool? = nil
    var hideLibraryTab: Bool? = nil
    var hideSearchTab: Bool? = nil
}

/// The one persistence bridge for profile-owned catalog and Discover values. Existing UI and
/// off-main callers keep reading their legacy flat keys, but ProfileStore captures and reapplies
/// them through this value on every profile transition.
enum ProfileDiscoveryPreferencesStore {
    enum Key {
        static let hiddenCatalogs = "stremiox.catalog.hidden"
        static let catalogOrder = "stremiox.catalog.order"
        static let hiddenHubCategories = "vortx.discover.hiddenCategories"
        static let regionOverride = "vortx.discover.regionPreference"
        static let filters = "vortx.discover.filters"
        static let selectedProviders = "vortx.collections.selectedProviders"
        static let providerOrder = "vortx.collections.providerOrder"
        static let hideLiveTab = TabBarPrefs.hideLive
        static let hideDiscoverTab = TabBarPrefs.hideDiscover
        static let hideLibraryTab = TabBarPrefs.hideLibrary
        static let hideSearchTab = TabBarPrefs.hideSearch
    }

    /// The legacy keys are a projection of whichever profile is active on THIS device. They remain
    /// part of user-created backup files for compatibility with pre-profile builds, but must not be
    /// copied through account sync as independent settings: the synced profile roster is their sole
    /// cross-device authority, and a peer may have a different viewer selected.
    static let activeProjectionKeys: Set<String> = [
        Key.hiddenCatalogs,
        Key.catalogOrder,
        Key.hiddenHubCategories,
        Key.regionOverride,
        Key.filters,
        Key.selectedProviders,
        Key.providerOrder,
        Key.hideLiveTab,
        Key.hideDiscoverTab,
        Key.hideLibraryTab,
        Key.hideSearchTab,
    ]

    static func capture(from defaults: UserDefaults = .standard) -> ProfileDiscoveryPreferences {
        ProfileDiscoveryPreferences(
            hiddenCatalogs: defaults.stringArray(forKey: Key.hiddenCatalogs) ?? [],
            catalogOrder: defaults.stringArray(forKey: Key.catalogOrder) ?? [],
            hiddenHubCategories: defaults.stringArray(forKey: Key.hiddenHubCategories) ?? [],
            regionOverrideCaptured: true,
            regionOverride: regionOverride(from: defaults),
            filtersCaptured: true,
            filtersData: defaults.data(forKey: Key.filters),
            selectedProviders: selectedProviders(from: defaults),
            providerOrder: defaults.array(forKey: Key.providerOrder) as? [Int] ?? [],
            tabVisibilityCaptured: true,
            hideLiveTab: defaults.bool(forKey: Key.hideLiveTab),
            hideDiscoverTab: defaults.bool(forKey: Key.hideDiscoverTab),
            hideLibraryTab: defaults.bool(forKey: Key.hideLibraryTab),
            hideSearchTab: defaults.bool(forKey: Key.hideSearchTab))
    }

    /// Apply one profile's snapshot to the legacy keys. `resetUnset` is true only for an actual
    /// viewer switch, so a new profile starts clean while an old/partial roster received by sync
    /// cannot erase whatever the currently visible profile is using.
    static func apply(_ prefs: ProfileDiscoveryPreferences?, resetUnset: Bool,
                      to defaults: UserDefaults = .standard) {
        applyStrings(prefs?.hiddenCatalogs, key: Key.hiddenCatalogs, resetUnset: resetUnset, to: defaults)
        applyStrings(prefs?.catalogOrder, key: Key.catalogOrder, resetUnset: resetUnset, to: defaults)
        applyStrings(prefs?.hiddenHubCategories, key: Key.hiddenHubCategories, resetUnset: resetUnset, to: defaults)
        if prefs?.regionOverrideCaptured == true || prefs?.regionOverride != nil {
            if let region = prefs?.regionOverride, !region.isEmpty {
                defaults.set(region.uppercased(), forKey: Key.regionOverride)
            } else {
                defaults.removeObject(forKey: Key.regionOverride)
            }
        } else if resetUnset {
            defaults.removeObject(forKey: Key.regionOverride)
        }
        if prefs?.filtersCaptured == true || prefs?.filtersData != nil {
            if let filtersData = prefs?.filtersData {
                defaults.set(filtersData, forKey: Key.filters)
            } else {
                defaults.removeObject(forKey: Key.filters)
            }
        } else if resetUnset {
            defaults.removeObject(forKey: Key.filters)
        }
        if let selectedProviders = prefs?.selectedProviders {
            defaults.set(selectedProviders.map(String.init).joined(separator: ","), forKey: Key.selectedProviders)
        } else if resetUnset {
            defaults.removeObject(forKey: Key.selectedProviders)
        }
        if let providerOrder = prefs?.providerOrder {
            defaults.set(providerOrder, forKey: Key.providerOrder)
        } else if resetUnset {
            defaults.removeObject(forKey: Key.providerOrder)
        }
        applyTabVisibility(prefs, resetUnset: resetUnset, to: defaults)
    }

    static func hiddenCatalogs(from defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: Key.hiddenCatalogs) ?? []
    }
    static func setHiddenCatalogs(_ keys: [String], in defaults: UserDefaults = .standard) {
        defaults.set(keys, forKey: Key.hiddenCatalogs)
    }
    static func catalogOrder(from defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: Key.catalogOrder) ?? []
    }
    static func setCatalogOrder(_ keys: [String], in defaults: UserDefaults = .standard) {
        defaults.set(keys, forKey: Key.catalogOrder)
    }
    static func hiddenHubCategories(from defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: Key.hiddenHubCategories) ?? []
    }
    static func setHiddenHubCategories(_ keys: [String], in defaults: UserDefaults = .standard) {
        defaults.set(keys, forKey: Key.hiddenHubCategories)
    }
    static func regionOverride(from defaults: UserDefaults = .standard) -> String? {
        let raw = (defaults.string(forKey: Key.regionOverride) ?? "").trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? nil : raw.uppercased()
    }
    static func setRegionOverride(_ code: String?, in defaults: UserDefaults = .standard) {
        if let code, !code.isEmpty { defaults.set(code.uppercased(), forKey: Key.regionOverride) }
        else { defaults.removeObject(forKey: Key.regionOverride) }
    }
    static func filtersData(from defaults: UserDefaults = .standard) -> Data? {
        defaults.data(forKey: Key.filters)
    }
    static func setFiltersData(_ data: Data?, in defaults: UserDefaults = .standard) {
        if let data { defaults.set(data, forKey: Key.filters) }
        else { defaults.removeObject(forKey: Key.filters) }
    }
    static func selectedProviders(from defaults: UserDefaults = .standard) -> [Int] {
        (defaults.string(forKey: Key.selectedProviders) ?? "").split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
    }
    static func setSelectedProviders(_ ids: [Int], in defaults: UserDefaults = .standard) {
        defaults.set(ids.map(String.init).joined(separator: ","), forKey: Key.selectedProviders)
    }
    static func providerOrder(from defaults: UserDefaults = .standard) -> [Int] {
        defaults.array(forKey: Key.providerOrder) as? [Int] ?? []
    }
    static func setProviderOrder(_ ids: [Int], in defaults: UserDefaults = .standard) {
        defaults.set(ids, forKey: Key.providerOrder)
    }

    private static func applyStrings(_ value: [String]?, key: String, resetUnset: Bool,
                                     to defaults: UserDefaults) {
        if let value { defaults.set(value, forKey: key) }
        else if resetUnset { defaults.removeObject(forKey: key) }
    }

    private static func applyTabVisibility(_ prefs: ProfileDiscoveryPreferences?, resetUnset: Bool,
                                           to defaults: UserDefaults) {
        let captured = prefs?.tabVisibilityCaptured == true
        let values: [(Bool?, String)] = [
            (prefs?.hideLiveTab, Key.hideLiveTab),
            (prefs?.hideDiscoverTab, Key.hideDiscoverTab),
            (prefs?.hideLibraryTab, Key.hideLibraryTab),
            (prefs?.hideSearchTab, Key.hideSearchTab),
        ]
        for (value, key) in values {
            if captured || value != nil {
                defaults.set(value ?? false, forKey: key)
            } else if resetUnset {
                // Legacy and newly created profiles have no tab snapshot. A real switch must make
                // each tab visible rather than inheriting the prior profile's hidden state.
                defaults.set(false, forKey: key)
            }
        }
    }
}
