package com.vortx.android.model

/// One add-on in the official Stremio community collection (Apple `AddonStoreView.StoreAddon`). Carries
/// only the fields the store shows; the manifest holds far more (resources, catalogs, version) that the
/// store ignores. [transportUrl] is the stable identity, so the health store (keyed by transport URL) and
/// the installed-set both line up against it.
data class StoreAddon(
    val transportUrl: String,
    val name: String,
    val summary: String,
    val logo: String?,
    val types: List<String>,
)
