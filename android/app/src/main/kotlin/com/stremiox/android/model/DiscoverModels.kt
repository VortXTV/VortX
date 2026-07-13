package com.stremiox.android.model

/// S04 (Discover/Library/Add-ons breadth) domain models. These mirror the engine's `Selectable`
/// shapes for `CatalogWithFilters` (Discover) and `LibraryWithFilters` (Library): stremio-core hands
/// back a `request` object alongside every selectable option, which the client is expected to echo
/// straight back (unmodified) to pivot the selection — mirrors Apple `CoreSelectableType`/
/// `CoreSelectableCatalog`/`CoreSelectableExtraOption`'s `request: CoreRequest` fields and
/// `CoreBridge.selectDiscover`/`selectLibrary`. [requestJson] is the exact engine JSON for that option's
/// `request`, kept as an opaque string (never reconstructed field-by-field) so a re-dispatch is
/// byte-for-byte what the engine itself produced — the same contract [EngineActions.loadDiscoverSelect]
/// / [EngineActions.loadLibrarySelect] rely on.

/// One Discover type chip (Movie/Series/Channel/TV/...), engine-driven — NOT the static [MediaType]
/// enum, so an add-on that declares an unusual type still gets a real, working chip.
data class DiscoverTypeOption(val label: String, val selected: Boolean, val requestJson: String)

/// One Discover catalog chip (e.g. "Cinemeta · Popular"), scoped to the currently selected type.
data class DiscoverCatalogOption(val label: String, val selected: Boolean, val requestJson: String)

/// One Discover genre chip, only present when the selected catalog declares a "genre" extra.
data class DiscoverGenreOption(val label: String, val selected: Boolean, val requestJson: String)

/// The full pivot state of one Discover load: every chip row the screen renders, plus whether another
/// page is available (mirrors Apple's `discoverHasNextPage`, simplified to the engine's own cursor).
data class DiscoverFilters(
    val types: List<DiscoverTypeOption> = emptyList(),
    val catalogs: List<DiscoverCatalogOption> = emptyList(),
    val genres: List<DiscoverGenreOption> = emptyList(),
    val hasNextPage: Boolean = false,
)

/// One Library type chip (All/Movie/Series/...).
data class LibraryTypeOption(val label: String, val selected: Boolean, val requestJson: String)

/// One Library sort chip (Recent/A–Z/Most watched/...).
data class LibrarySortOption(val label: String, val selected: Boolean, val requestJson: String)

data class LibraryFilters(
    val types: List<LibraryTypeOption> = emptyList(),
    val sorts: List<LibrarySortOption> = emptyList(),
)

/// One Discover load: the selected catalog's items (already flattened to one row, see
/// [com.stremiox.android.engine.EngineState.parseCatalogWithFilters]) alongside the pivot chips to
/// render around it. Bundled into one result so a type/catalog/genre switch is a SINGLE engine
/// round-trip (one `getState` parse), not two.
data class DiscoverResult(
    val items: List<MetaItem> = emptyList(),
    val filters: DiscoverFilters = DiscoverFilters(),
)

/// One Library load: the filtered/sorted items alongside the pivot chips, same one-round-trip
/// rationale as [DiscoverResult].
data class LibraryResult(
    val items: List<MetaItem> = emptyList(),
    val filters: LibraryFilters = LibraryFilters(),
)

/// One installed add-on, parsed from `ctx.profile.addons` (mirrors Apple `CoreDescriptor`).
/// [rawDescriptorJson] is the engine's own serialized entry for this add-on, echoed back verbatim on
/// [com.stremiox.android.data.CatalogRepository.removeAddon] — `UninstallAddon` takes a full
/// `Descriptor`, so we must hand back exactly what the engine gave us, not a reconstruction.
data class InstalledAddon(
    val transportUrl: String,
    val name: String,
    val logo: String? = null,
    val description: String? = null,
    val isOfficial: Boolean = false,
    val isProtected: Boolean = false,
    val providesStreams: Boolean = false,
    val rawDescriptorJson: String,
) {
    /// The transport URL's host, for a short, stable second line under the name (mirrors Apple
    /// `CoreDescriptor.host`).
    val host: String
        get() = runCatching { java.net.URI(transportUrl).host ?: transportUrl }.getOrDefault(transportUrl)
}
