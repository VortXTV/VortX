package com.vortx.android.ui.screens

/// Spoiler-safe veil decision for one episode on the detail list (DET spoiler-safe mode), the Android port
/// of Apple `iOSDetailView.spoilerVeiled`. When spoiler-safe mode is on, an UNWATCHED, not-yet-revealed
/// episode's artwork is blurred, its overview is withheld behind "Tap to reveal", and a veiled row's first
/// tap REVEALS it (a session-only reveal) rather than navigating.
///
/// READ-ONLY against watched state: it only reads [isWatched] (from the engine's per-profile watched
/// bitfield) and the caller's session-local [revealed] set; it never writes a watched tick, so revealing an
/// episode can never mark it watched and the per-profile watch invariant is honoured.
internal fun spoilerVeiled(spoilerSafe: Boolean, isWatched: Boolean, revealed: Boolean): Boolean =
    spoilerSafe && !isWatched && !revealed
