package com.vortx.android.ui.tv

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.util.lerp
import coil3.compose.AsyncImage
import com.vortx.android.config.RemoteConfig
import com.vortx.android.config.RemoteConfigDefaults
import com.vortx.android.model.MetaItem
import com.vortx.android.model.TrackPreferencesStore
import com.vortx.android.ui.theme.VortXMotion
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.rememberReducedMotion

/// The TV Home cinematic "living backdrop" hero -- the Android parity twin of Apple
/// `SourcesTV/SharedUI.swift`'s `BrowseHeroBackdrop` plus the #44 ambient in-hero trailer. It is the
/// single presentation change over the focus-first Home: the focused catalog item fills the band with its
/// full-bleed backdrop, a metadata overlay (clearlogo or title, year, rating, genre, synopsis) reads on the
/// lower-left band, the art + text CROSS-FADE together as focus moves between tiles, and the band is AMBIENT
/// -- a slow Ken Burns pan/zoom on the still art, upgraded to a muted looping trailer once one is readily
/// available (via the existing [rememberHeroTrailerPlayable] -> [TrailerCoordinator] path).
///
/// PARITY + ISOLATION:
///   * Non-focusable, hit-testing-free (like Apple's hero): the rails below own D-pad focus, so pressing up
///     from the top row still lands on the tab bar. No focusable buttons live in the band (Apple's Home hero
///     deliberately carries none, so it never competes with the rails for focus).
///   * Crossfade animates ALPHA only (compositor-friendly), Ken Burns animates scale/translation only -- no
///     layout animation, matching DESIGN-SYSTEM.md.
///   * Ambient motion is gated on the Apple-parity "Autoplay trailers" setting
///     ([TrackPreferencesStore.autoplayTrailers], key `stremiox.autoplayTrailers`), the RemoteConfig fleet
///     kill-switch (`features.trailers`, Apple ANDs the same in HomeView/FeaturedHeroView), AND the Android
///     reduced-motion signal ([rememberReducedMotion]): reduced motion pins a still frame, no pan, no clip.
///   * TV-only: this replaces the flat [com.vortx.android.ui.tv] Home hero and never touches the phone Home
///     ([com.vortx.android.ui.screens.HomeScreen]).
///
/// STOP conditions are handled by composition: the Home subtree leaves composition when the viewer opens a
/// title (Detail covers Home), starts playback (Player covers all), or switches tabs -- each tears down the
/// ambient player, so no extra "player active" plumbing is needed.
@Composable
internal fun TvAmbientHero(item: MetaItem?, modifier: Modifier = Modifier) {
    val colors = VortXTheme.colors
    val context = LocalContext.current
    val reducedMotion = rememberReducedMotion()
    val autoplayTrailers = rememberAutoplayTrailers(context.applicationContext)

    // A crossfade for both the backdrop and the overlay, keyed on the focused item so art and text swap in
    // lockstep. Instant under reduced motion; the standard hero cross-fade otherwise.
    val heroSpec: FiniteAnimationSpec<Float> =
        if (reducedMotion) snap() else tween(VortXMotion.HERO_MS, easing = VortXMotion.easing)

    Box(modifier = modifier.background(colors.canvas).clipToBounds()) {
        // 1) Backdrop layer: the still art (with Ken Burns) plus the base legibility scrims, crossfaded.
        Crossfade(targetState = item, animationSpec = heroSpec, label = "tvHeroBackdrop") { current ->
            TvHeroBackdropLayer(current, reducedMotion)
        }

        // 2) Ambient trailer: a muted looping clip fades in OVER the still backdrop once focus settles and a
        //    trailer is readily available; otherwise this stays absent and the Ken Burns above is the ambient.
        // Fleet kill-switch (Apple ANDs `features.trailers` in HomeView/FeaturedHeroView): a remote false
        // stops ambient trailers across the fleet; baked-true default => unreachable config == shipping.
        val trailersFleetOn = RemoteConfig.isFeatureOn("trailers", RemoteConfigDefaults.FEATURE_TRAILERS)
        val trailer = rememberHeroTrailerPlayable(item, enabled = autoplayTrailers && !reducedMotion && trailersFleetOn)
        if (trailer != null) {
            TvHeroAmbientTrailer(
                playable = trailer,
                reducedMotion = reducedMotion,
                modifier = Modifier.fillMaxSize(),
            )
        }

        // 3) Metadata overlay: logo/title, year, rating, genre, synopsis on the lower-left band, crossfaded
        //    in lockstep with the backdrop so it always reads over whichever layer (still or clip) is behind.
        Crossfade(targetState = item, animationSpec = heroSpec, label = "tvHeroOverlay") { current ->
            if (current != null) TvHeroOverlay(current)
        }
    }
}

/**
 * Observe the exact shared preference used by Settings instead of taking a one-time snapshot in `remember`.
 * This keeps an already-composed Home hero in sync when the viewer changes the setting and returns to TV
 * Home, without changing trailer focus, reduced-motion, or player ownership semantics.
 */
@Composable
private fun rememberAutoplayTrailers(context: android.content.Context): Boolean {
    val appContext = context.applicationContext
    val preferences = remember(appContext) {
        appContext.getSharedPreferences(TrackPreferencesStore.PREFS_FILE, android.content.Context.MODE_PRIVATE)
    }
    var enabled by remember(preferences) {
        mutableStateOf(preferences.getBoolean(TrackPreferencesStore.KEY_AUTOPLAY_TRAILERS, true))
    }
    DisposableEffect(preferences) {
        val listener = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == TrackPreferencesStore.KEY_AUTOPLAY_TRAILERS) {
                enabled = preferences.getBoolean(TrackPreferencesStore.KEY_AUTOPLAY_TRAILERS, true)
            }
        }
        preferences.registerOnSharedPreferenceChangeListener(listener)
        onDispose { preferences.unregisterOnSharedPreferenceChangeListener(listener) }
    }
    return enabled
}

/// The still-art layer: the focused item's backdrop at full bleed under a slow Ken Burns transform, with a
/// left fade (text legibility) and a bottom fade to canvas (so the rows sit on solid). Mirrors Apple
/// `FullBleedBackdrop` + the browse-page scrims.
@Composable
private fun TvHeroBackdropLayer(item: MetaItem?, reducedMotion: Boolean) {
    val colors = VortXTheme.colors
    Box(Modifier.fillMaxSize()) {
        val kenBurns = kenBurnsTransform(reducedMotion)
        TvBackdrop(
            url = item?.background ?: item?.poster,
            seed = item?.id ?: "vortx",
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer {
                    scaleX = kenBurns.scale
                    scaleY = kenBurns.scale
                    translationX = kenBurns.translateX
                },
        )
        Box(
            Modifier
                .fillMaxSize()
                .background(Brush.horizontalGradient(0f to colors.canvas, 0.6f to Color.Transparent)),
        )
        Box(
            Modifier
                .fillMaxSize()
                .background(Brush.verticalGradient(0.35f to Color.Transparent, 1f to colors.canvas)),
        )
    }
}

/// The metadata overlay: the clearlogo (in place of the title, matching Apple's hero) or an eyebrow + serif
/// title, then a "year · ★ rating · genre" meta line and a short synopsis. Pinned bottom-left within the band.
@Composable
private fun TvHeroOverlay(item: MetaItem) {
    val colors = VortXTheme.colors
    Box(Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .align(Alignment.BottomStart)
                .fillMaxWidth(0.6f)
                .padding(start = TvDimens.edge, end = TvDimens.edge, bottom = TvDimens.edge),
        ) {
            val logo = item.logo
            if (!logo.isNullOrBlank()) {
                // The clearlogo IS the title in image form; expose the name for accessibility, not the art.
                AsyncImage(
                    model = logo,
                    contentDescription = item.name,
                    contentScale = ContentScale.Fit,
                    alignment = Alignment.BottomStart,
                    modifier = Modifier.heightIn(max = 132.dp).widthIn(max = 420.dp),
                )
            } else {
                Text(text = item.type.label.uppercase(), style = VortXTheme.type.eyebrow)
                Text(
                    text = item.name,
                    style = VortXTheme.type.hero,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = VortXTheme.spacing.xs),
                )
            }
            val meta = listOfNotNull(
                item.caption ?: item.year,
                item.imdbRating?.let { "★ $it" },
                item.genres.firstOrNull(),
            ).joinToString("   ·   ")
            if (meta.isNotBlank()) {
                Text(
                    text = meta,
                    style = VortXTheme.type.label.copy(color = colors.textSecondary),
                    modifier = Modifier.padding(top = VortXTheme.spacing.sm),
                )
            }
            item.description?.takeIf { it.isNotBlank() }?.let {
                Text(
                    text = it,
                    style = VortXTheme.type.body.copy(color = colors.textSecondary),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = VortXTheme.spacing.sm),
                )
            }
        }
    }
}

/// A slow, continuously-oscillating zoom + drift for the still backdrop (the ambient fallback when no trailer
/// plays). Pinned to a still frame under reduced motion. Restarts per focused item because it lives inside the
/// backdrop crossfade content, so each item pans from rest.
private data class KenBurns(val scale: Float, val translateX: Float)

@Composable
private fun kenBurnsTransform(reducedMotion: Boolean): KenBurns {
    if (reducedMotion) return KenBurns(scale = 1f, translateX = 0f)
    val transition = rememberInfiniteTransition(label = "tvHeroKenBurns")
    val progress by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = HERO_KEN_BURNS_MS, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "tvHeroKenBurnsProgress",
    )
    return KenBurns(
        scale = lerp(1f, HERO_KEN_BURNS_MAX_SCALE, progress),
        translateX = lerp(0f, HERO_KEN_BURNS_MAX_DRIFT_PX, progress),
    )
}

/// Full Ken Burns sweep duration (one direction), long enough that the motion reads as ambient, not busy.
private const val HERO_KEN_BURNS_MS = 20_000

/// Peak zoom for the Ken Burns pan; small so the art never softens noticeably.
private const val HERO_KEN_BURNS_MAX_SCALE = 1.06f

/// Peak horizontal drift (px) paired with the zoom so the pan has direction, not just a breathing zoom.
private const val HERO_KEN_BURNS_MAX_DRIFT_PX = 24f
