package com.vortx.android.iptv

/// The user-facing data model for the Live TV (IPTV) feature. Kotlin port of the Apple
/// `app/SourcesShared/IPTVPlaylistStore.swift` value types (`IPTVKind` / `IPTVPlaylist` / `IPTVCredentials`)
/// plus the converter's `Registration`. These live in the NEW `iptv` package and are shared by
/// [IPTVConverterClient], [IPTVPlaylistStore], and [com.vortx.android.ui.screens.IPTVSettingsScreen].
///
/// The metadata / credential split mirrors Apple exactly: [IPTVPlaylist] is the non-secret, syncable record
/// kept in plain SharedPreferences (the Apple UserDefaults key `vortx.iptv.playlists`), while
/// [IPTVCredentials] is the credential-bearing half kept ONLY in the encrypted
/// [com.vortx.android.integrations.SecureTokenStore] (the Apple Keychain account `vortx.iptv.cred.<slug>`),
/// so a settings backup never carries the secret and it never leaves the device except to the worker.

/// Which kind of source a playlist was added from. [wire] is the persisted + synced token (matches the
/// Apple `IPTVKind.rawValue`), so it must stay stable across versions and platforms; [label] is display copy.
enum class IPTVKind(val wire: String, val label: String) {
    M3U("m3u", "M3U playlist"),
    XTREAM("xtream", "Xtream login"),
    ;

    companion object {
        /// The kind for a persisted / synced [wire] token, or null for an unknown value (a forward-compat
        /// guard so a newer kind synced from another platform is skipped rather than crashing the decode).
        fun fromWire(value: String?): IPTVKind? = entries.firstOrNull { it.wire == value }
    }
}

/// The non-secret, syncable metadata for one installed IPTV playlist. [id] is the opaque worker slug (also
/// the `/c/<slug>/` path capability). Mirrors the Apple `IPTVPlaylist` struct; [createdAtMillis] is carried
/// as epoch MILLIS (the unit the Apple sync blob's `createdAt` uses) rather than a Date, so the local record
/// and the cross-device blob share one representation.
data class IPTVPlaylist(
    val id: String,
    val name: String,
    val kind: IPTVKind,
    val transportUrl: String,
    val createdAtMillis: Long,
)

/// The credential-bearing fields for one playlist, kept in the encrypted store only. Optional throughout: an
/// M3U playlist has only [m3uUrl] (+ optional [xmltvUrl]); an Xtream login has [xtreamHost] / [xtreamUser] /
/// [xtreamPass] (+ optional [xmltvUrl]). Retained after registration so a future refresh can re-register
/// without re-prompting. Mirrors the Apple `IPTVCredentials`.
data class IPTVCredentials(
    val m3uUrl: String? = null,
    val xtreamHost: String? = null,
    val xtreamUser: String? = null,
    val xtreamPass: String? = null,
    val xmltvUrl: String? = null,
)

/// A successful converter registration: the worker slug and the manifest URL to install as a normal add-on.
/// Mirrors the Apple `IPTVConverterClient.Registration`.
data class IPTVRegistration(
    val slug: String,
    val manifestUrl: String,
)
