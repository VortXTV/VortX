package com.vortx.android.ui.theme

import androidx.compose.ui.unit.dp

/// The 8pt spacing scale (DESIGN-SYSTEM.md §2 "Spacing (8pt)"). Rhythm rule: section-to-section gaps
/// use [xl], readable-column block gaps use [lg], in-card gaps use [sm] — never one value everywhere.
object VortXSpacing {
    val xs = 8.dp
    val sm = 12.dp
    val md = 20.dp
    val lg = 32.dp
    val xl = 48.dp
    val xxl = 72.dp

    /// `edge = clamp(20px,5vw,60px)` on the web. Android has no viewport-width unit; phone screens sit
    /// close to the 20px floor at arm's length, so [edge] pins to that floor as a fixed token. Screens
    /// that want the web's width-responsive upper end (tablet/foldable) should compute it themselves
    /// from `LocalConfiguration` rather than overload this constant.
    val edge = 20.dp
}
