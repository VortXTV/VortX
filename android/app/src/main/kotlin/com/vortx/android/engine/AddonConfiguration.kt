package com.vortx.android.engine

import java.net.URI

/// Add-on configuration-page detection, the Kotlin port of Apple `isAddonConfigurationPageURL`
/// (`AddonPairingReducer.swift:44`) and `CoreBridge.addonNeedsConfigurationMessage`.
///
/// A pasted `/configure` PAGE is NOT an installable manifest: a configurable add-on (Torrentio, debrid
/// configs, ...) mints a per-user manifest only after you sign in on that page and enter your debrid key.
/// Normalizing a `/configure` link to `/configure/manifest.json` fetches a valid-shaped but DEAD default
/// from the add-on SDK router, so the install "succeeds" yet returns no sources on every title (the
/// owner-reported Lumio / AllDebrid case, fixed Apple-side in Beta 17). Guide the user to finish
/// configuration and paste the personalized link instead of installing a dead copy.
object AddonConfiguration {
    /// Shown when a pasted link is a configuration page rather than an installable manifest (Apple
    /// `CoreBridge.addonNeedsConfigurationMessage`, byte-for-byte). The user must finish setup on the
    /// add-on's own page and paste the personalized manifest link it then mints.
    const val NEEDS_CONFIGURATION_MESSAGE: String =
        "This add-on needs to be set up first. Open its configuration page in a browser, sign in and " +
            "enter your debrid key, then copy the personalized add-on link it gives you (it ends in " +
            "/manifest.json, not /configure) and paste that here."

    /// True when [raw] is an add-on's `/configure` web page rather than an installable manifest. Tests the
    /// PATH only (a query/fragment is never part of an add-on identity), and also catches a hand-appended
    /// `/configure/manifest.json`, which the same SDK router treats as the identical dead config token.
    /// Mirrors Apple `isAddonConfigurationPageURL` exactly; a legitimate per-user manifest is
    /// `/<profileId>/manifest.json`, whose peeled last segment is the profile id, never the literal
    /// "configure", so this stays zero-regression for real add-ons.
    fun isConfigurationPageUrl(raw: String): Boolean {
        val trimmed = raw.trim()
        val uri = runCatching { URI(trimmed) }.getOrNull() ?: return false
        val scheme = uri.scheme?.lowercase() ?: return false
        if (scheme != "http" && scheme != "https") return false
        if (uri.host.isNullOrEmpty()) return false
        // Non-empty segments so a trailing or doubled slash cannot hide the meaningful last one.
        val segments = (uri.path ?: "").split('/').filter { it.isNotEmpty() }.toMutableList()
        // A configure page with a manually appended manifest suffix is the SAME dead token; peel it and
        // test the segment before it.
        if (segments.lastOrNull()?.lowercase() == "manifest.json") segments.removeAt(segments.lastIndex)
        return segments.lastOrNull()?.lowercase() == "configure"
    }
}
