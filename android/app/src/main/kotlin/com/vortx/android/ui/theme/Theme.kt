package com.vortx.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/// StremioX is a media app used on a couch in a dim room at night, so the UI is dark by intent, not
/// by default. Neutrals are tinted toward the StremioX violet brand hue (no pure black or white),
/// with a single vivid accent that carries focus and selection.
private val Accent = Color(0xFF7B5BFF)        // electric violet, the brand accent
private val AccentDim = Color(0xFF2A2140)      // accent at low chroma for selected backgrounds
private val Background = Color(0xFF0E0B14)      // near-black, violet-tinted
private val Surface = Color(0xFF16121F)
private val SurfaceVariant = Color(0xFF211B30)
private val OnAccent = Color(0xFFF6F4FF)
private val OnBackground = Color(0xFFECE9F2)    // tinted off-white, never #FFF
private val OnSurfaceVariant = Color(0xFF9A93AD)

private val StremioXDarkColors = darkColorScheme(
    primary = Accent,
    onPrimary = OnAccent,
    primaryContainer = AccentDim,
    onPrimaryContainer = OnBackground,
    background = Background,
    onBackground = OnBackground,
    surface = Surface,
    onSurface = OnBackground,
    surfaceVariant = SurfaceVariant,
    onSurfaceVariant = OnSurfaceVariant,
)

/// Hierarchy through scale and weight contrast (>1.25 ratio between steps), not a flat scale.
private val StremioXType = Typography(
    headlineLarge = TextStyle(fontWeight = FontWeight.Bold, fontSize = 34.sp, letterSpacing = (-0.5).sp),
    titleLarge = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 22.sp),
    titleMedium = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 17.sp),
    bodyMedium = TextStyle(fontWeight = FontWeight.Normal, fontSize = 15.sp),
    labelLarge = TextStyle(fontWeight = FontWeight.Medium, fontSize = 13.sp, letterSpacing = 0.3.sp),
    labelSmall = TextStyle(fontWeight = FontWeight.Medium, fontSize = 11.sp, letterSpacing = 0.5.sp),
)

@Composable
fun StremioXTheme(content: @Composable () -> Unit) {
    // The app commits to dark; isSystemInDarkTheme is read so a future light scheme can slot in here.
    @Suppress("UNUSED_VARIABLE") val systemDark = isSystemInDarkTheme()
    MaterialTheme(
        colorScheme = StremioXDarkColors,
        typography = StremioXType,
        content = content,
    )
}
