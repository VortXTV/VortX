package com.vortx.android.ui.theme

import android.os.Build
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

/// VortX "liquid glass" for Android: the warm-dark translucent material that is VortX's ELEVATION
/// LANGUAGE across the app's chrome, ported from the Apple app's `GlassStyle.swift` (`VortXGlass`).
/// It is a warm translucent fill over the content behind it, a 1px lit top-edge highlight, and a soft
/// drop shadow, so every raised chrome surface (nav/top bars, chips, rows, primary actions, panels,
/// fields, toasts, badges) reads as one system instead of a run of unrelated fills.
///
/// PLATFORM NOTE (blur): Apple's material blurs the live backdrop behind the surface. Stable Jetpack
/// Compose has no first-class backdrop blur without an extra dependency (Haze) or a captured backdrop,
/// and [androidx.compose.ui.draw.blur] blurs a node's OWN content (which would smear the chrome's text),
/// so it is deliberately NOT used over chrome here. On Android the frosted, see-through quality is
/// carried by the translucent warm fill (the color behind bleeds through) plus the lit top edge and the
/// soft shadow. The API-31 gate ([rememberGlassOpaque]) still governs the look exactly as the spec asks:
/// on Android 12+ (and no reduce-transparency) the surface is TRANSLUCENT glass; on API 26 to 30, or when
/// the accessibility reduce-transparency proxy is set, it stands down to an OPAQUE warm surface so the
/// chrome stays legible, mirroring Apple's Reduce-Transparency fallback.
///
/// Still deliberately NOT for scrolling poster art, backdrops, cast headshots, or episode thumbnails:
/// those keep their solid fills / images so their legibility contract holds. Glass is chrome only.
object VortXGlass {

    /// The warm near-black glass fill (Apple mockups: `rgba(20,17,16,~.5)`, that is `#141110`). A FIXED
    /// sRGB color, NOT the user-themeable [VortXColors.canvas], so the glass reads warm even under the
    /// OLED true-black chrome setting: a stable identity surface rather than the app background.
    val fillColor = Color(0xFF141110)

    /// The warm-dark translucent glass fill at a given [alpha].
    fun fill(alpha: Float): Color = fillColor.copy(alpha = alpha)

    // Default fill alphas per surface, matching the Apple presets (bar ~.55, pill/field ~.5).
    const val barFillAlpha = 0.55f
    const val pillFillAlpha = 0.50f
    /// Inline scroll-column cards / rows: the same warm fill a touch lighter than a floating pill, since
    /// these sit ON the canvas rather than floating high over content.
    const val cardFillAlpha = 0.50f
    /// The focused / selected state of a glass row: a small alpha lift over [cardFillAlpha] so the row
    /// brightens under focus the way the old opaque surface1 to surface2 step did.
    const val rowFocusFillAlpha = 0.64f
    /// Large modal / side-panel glass: HIGH alpha so text stays legible even when the panel floats over
    /// bright, moving video (a hero backdrop or the player), where a thin fill would wash out.
    const val panelFillAlpha = 0.74f
    /// On-poster / on-video badges: higher alpha than a pill so the badge holds its own against saturated
    /// artwork or a hot video frame underneath.
    const val badgeFillAlpha = 0.72f
    /// Text-entry field glass: tuned higher than a pill so typed text keeps contrast over the fill.
    const val fieldFillAlpha = 0.62f
    /// The accent tint alpha for the PROMINENT (primary-action) glass: kept in the GLASS range (not near
    /// opaque) so the button reads as tinted ember GLASS while the onAccent label still clears contrast.
    /// Under the opaque fallback the tint is forced to 1.0 so the CTA stays a solid, maximally legible slab.
    const val prominentTintAlpha = 0.66f
    /// The selected-chip ember tint alpha, composited OVER the warm glass fill.
    const val chipSelectedAlpha = 0.20f

    /// The interior "lit frost" sheen composited over the warm fill on the translucent path only: a soft
    /// white top-down gradient that fades out by the vertical midpoint, giving the surface a lit, liquid
    /// quality without any blur. Skipped on the opaque fallback (the solid surface needs no sheen).
    val sheen: Brush = Brush.verticalGradient(
        0f to Color.White.copy(alpha = 0.06f),
        0.5f to Color.Transparent,
    )

    /// The 1px edge treatment: a bright top highlight fading into a faint warm hairline toward the bottom
    /// (Apple: `inset 0 1px 0 rgba(255,255,255,~.12)` over a `1px solid rgba(242,236,226,~.14)` border).
    /// One gradient stroke reads as both, so a single bordered brush gives the lit top edge.
    fun highlightBrush(top: Float = 0.14f): Brush = Brush.verticalGradient(
        0f to Color.White.copy(alpha = top),
        1f to Color(0.949f, 0.925f, 0.886f, top * 0.42f),
    )

    /// Soft drop-shadow presets under a raised element, expressed as [VortXElevationSpec] so they ride the
    /// app's existing [Modifier.vortxShadow] path. Elevations approximate the Apple blur radii; the black
    /// alpha matches each Apple preset. Colored tinting only renders on API 31+ (a framework limit, see
    /// [VortXElevation]); every surface still reads lifted below that.
    object Shadow {
        val bar = VortXElevationSpec(elevation = 20.dp, color = Color.Black.copy(alpha = 0.50f))
        val pill = VortXElevationSpec(elevation = 14.dp, color = Color.Black.copy(alpha = 0.45f))
        val disc = VortXElevationSpec(elevation = 5.dp, color = Color.Black.copy(alpha = 0.26f))
        val card = VortXElevationSpec(elevation = 9.dp, color = Color.Black.copy(alpha = 0.28f))
        val panel = VortXElevationSpec(elevation = 26.dp, color = Color.Black.copy(alpha = 0.55f))
        val toast = VortXElevationSpec(elevation = 16.dp, color = Color.Black.copy(alpha = 0.40f))
        /// Near-zero shadow for surfaces that must NOT float or that get their lift elsewhere (chips).
        val flat = VortXElevationSpec(elevation = 0.dp, color = Color.Transparent)
    }
}

/// The Android reduce-transparency signal. Android has no first-class "reduce transparency" toggle like
/// iOS, so the closest PUBLIC accessibility preference is used as the proxy: "High contrast text", which
/// the users who most need maximal chrome legibility enable. When set, glass stands down to an opaque warm
/// surface. Read once via [remember]; a runtime toggle takes effect on the next recomposition.
///
/// TODO(a11y): adopt a first-class reduce-transparency signal if Android exposes one, or surface an in-app
/// "reduce transparency" toggle, and OR it in here. Until then this is the honest available proxy.
@Composable
fun rememberReduceTransparency(): Boolean {
    val context = LocalContext.current
    return remember {
        Settings.Secure.getInt(context.contentResolver, HIGH_TEXT_CONTRAST_ENABLED, 0) == 1
    }
}

/// The `Settings.Secure` key for the accessibility "High contrast text" preference. It is a stable
/// platform key (currently `@hide` as a typed constant) read via its string name with a safe 0 default,
/// so an absent key simply reads "off" rather than throwing.
private const val HIGH_TEXT_CONTRAST_ENABLED = "high_text_contrast_enabled"

/// The single gate every glass preset shares: the surface renders OPAQUE (a solid warm fallback) when the
/// device is below Android 12 (API 31, where the translucent-glass era begins) OR when the reduce-
/// transparency proxy is set, and TRANSLUCENT glass otherwise. This is the Android analogue of Apple's
/// one OS-gate-plus-Reduce-Transparency fallback, so the upgrade and the fallback are identical across
/// every preset instead of re-derived per modifier.
@Composable
fun rememberGlassOpaque(): Boolean =
    Build.VERSION.SDK_INT < Build.VERSION_CODES.S || rememberReduceTransparency()

/// Apply the VortX glass material in [shape]: a soft drop [shadow], the warm translucent fill (or the
/// opaque warm fallback per [rememberGlassOpaque]), an optional interior sheen, an optional [activeFill]
/// selection tint composited above the fill but below the content, and the 1px lit top edge. [fillAlpha] /
/// [highlight] / [shadow] tune it per surface (defaults suit a floating bar or pill).
@Composable
fun Modifier.vortxGlass(
    shape: Shape,
    fillAlpha: Float = VortXGlass.barFillAlpha,
    highlight: Float = 0.14f,
    shadow: VortXElevationSpec = VortXGlass.Shadow.bar,
    activeFill: Color? = null,
): Modifier {
    val opaque = rememberGlassOpaque()
    val surface1 = VortXTheme.colors.surface1
    // Translucent path uses the fixed warm fill; the opaque fallback uses the themeable warm surface1
    // (matching Apple's Reduce-Transparency branch, which fills with `surface1`).
    val fillColor = if (opaque) surface1 else VortXGlass.fill(fillAlpha)
    return this
        .vortxShadow(shadow, shape)
        .clip(shape)
        .background(fillColor, shape)
        .then(if (!opaque) Modifier.background(VortXGlass.sheen, shape) else Modifier)
        // The selection tint sits ABOVE the warm fill and sheen but still inside the background subtree, so
        // it stays below the content. Rendered in both modes so the cue survives the opaque fallback too.
        .then(if (activeFill != null) Modifier.background(activeFill, shape) else Modifier)
        .border(1.dp, VortXGlass.highlightBrush(highlight), shape)
}

/// The PROMINENT variant for a primary action (Play / Resume): the same API-31 gate plus opaque fallback,
/// tinted with a GLASS-range [tint] over a warm frost base so the button reads as tinted ember GLASS
/// rather than a flat slab, while the onAccent label stays legible over it. Under the opaque fallback the
/// tint is forced to 1.0 so the CTA falls back to a solid, maximally legible ember surface (never a neutral
/// chip). No drop shadow of its own: the calling button style owns the glow.
@Composable
fun Modifier.vortxGlassProminent(
    shape: Shape,
    tint: Color = VortXTheme.colors.accent,
    highlight: Float = 0.18f,
): Modifier {
    val opaque = rememberGlassOpaque()
    return this
        .clip(shape)
        // Warm frost base under the ember tint on the translucent path, so the tint reads as glass rather
        // than a near-flat ember. Skipped on the opaque fallback (the solid tint carries the whole fill).
        .then(if (!opaque) Modifier.background(VortXGlass.fill(0.30f), shape) else Modifier)
        .background(tint.copy(alpha = if (opaque) 1f else VortXGlass.prominentTintAlpha), shape)
        .border(1.dp, VortXGlass.highlightBrush(highlight), shape)
}

/// The ONE chip path: the neutral glass base plus a parameterized ember tint. Idle = glass pill; [selected]
/// = glass pill + the [tint] ember composited above the warm fill but below the label (accent by default;
/// a destructive tint is supported). No drop shadow: chips sit inline, and their press scale / ring ride
/// on top from the [com.vortx.android.ui.components.Chip] call site.
@Composable
fun Modifier.vortxGlassChip(
    selected: Boolean,
    tint: Color = VortXTheme.colors.accent,
): Modifier = vortxGlass(
    shape = VortXShapes.chip,
    fillAlpha = VortXGlass.pillFillAlpha,
    shadow = VortXGlass.Shadow.flat,
    activeFill = if (selected) tint.copy(alpha = VortXGlass.chipSelectedAlpha) else null,
)

/// A list-row / stream-row glass fill. [focused] lifts the fill alpha so the row brightens on focus the
/// way the old surface1 to surface2 step did. Keeps a soft card shadow so the row still reads lifted (the
/// Android rows have no separate focus-lift owner, unlike the Apple `RowFocusStyle`).
@Composable
fun Modifier.vortxGlassRow(focused: Boolean = false): Modifier = vortxGlass(
    shape = VortXShapes.card,
    fillAlpha = if (focused) VortXGlass.rowFocusFillAlpha else VortXGlass.cardFillAlpha,
    shadow = VortXGlass.Shadow.card,
)

/// A text-entry field glass, tuned ([VortXGlass.fieldFillAlpha]) so typed text keeps contrast over the fill.
@Composable
fun Modifier.vortxGlassField(shape: Shape = VortXShapes.control): Modifier =
    vortxGlass(shape = shape, fillAlpha = VortXGlass.fieldFillAlpha, shadow = VortXGlass.Shadow.pill)

/// A high-alpha large modal / side-panel glass that stays legible over bright, moving video.
@Composable
fun Modifier.vortxGlassPanel(shape: Shape): Modifier =
    vortxGlass(shape = shape, fillAlpha = VortXGlass.panelFillAlpha, shadow = VortXGlass.Shadow.panel)

/// A compact, non-interactive notice (toast) glass: legible fill plus a soft toast shadow.
@Composable
fun Modifier.vortxGlassToast(shape: Shape): Modifier =
    vortxGlass(shape = shape, fillAlpha = VortXGlass.fieldFillAlpha, shadow = VortXGlass.Shadow.toast)

/// A full-width, edge-flush strip (the native top / bottom bars): the shared warm fill with a TOP-only 1px
/// lit line (no side or bottom border), so the strip reads as flush chrome rather than a floating card.
/// Follows the same API-31 gate: translucent glass on Android 12+, opaque warm surface1 otherwise.
@Composable
fun Modifier.vortxGlassStrip(fillAlpha: Float = VortXGlass.barFillAlpha): Modifier {
    val opaque = rememberGlassOpaque()
    val surface1 = VortXTheme.colors.surface1
    val fill = if (opaque) surface1 else VortXGlass.fill(fillAlpha)
    return this.drawBehind {
        drawRect(color = fill)
        // The 1px lit top edge, drawn flush along the top so the strip stays edge-to-edge chrome.
        drawRect(color = Color.White.copy(alpha = 0.12f), size = Size(size.width, 1.dp.toPx()))
    }
}
