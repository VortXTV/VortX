package com.vortx.android.ui.tv

import androidx.compose.ui.unit.dp

/// 10-foot layout constants for the TV surface. A television is viewed from across a room, so the phone's
/// arm's-length spacing (VortXSpacing.edge = 20dp, 124dp poster cards) reads too tight and too small; these
/// are the deliberately larger TV values the plan calls for computing per-surface rather than overloading
/// the shared 8pt tokens (see VortXSpacing.edge's own doc). Kept in one place so the Home rows, the Detail
/// page, and the focus cards stay on one rhythm.
object TvDimens {
    /// Screen-edge inset (overscan-safe margin). TVs historically overscan; 48dp keeps content clear of the
    /// bezel on sets that still crop the signal, and reads as an intentional 10-foot margin on those that do
    /// not.
    val edge = 48.dp

    /// Poster card width. ~150dp lands roughly seven cards across a 1080p row with the gap below, the density
    /// a browse wall wants at 10 feet (the phone's 124dp would waste the width).
    val posterWidth = 150.dp

    /// Gap between cards in a row.
    val cardGap = 20.dp

    /// Gap between stacked rows.
    val rowGap = 28.dp

    /// Focused-card scale. Slightly punchier than the phone poster's 1.03 press scale because focus (not
    /// touch) is the only selection signal on TV, so the focused tile must read unambiguously from the couch.
    const val focusScale = 1.08f

    /// Focus ring width drawn around the focused tile (accent-bright border on focus).
    val focusBorder = 3.dp

    /// Width of the left navigation rail (Home / Discover / Library / Search / Settings). Wide enough for
    /// the longest label ("Discover") beside its glyph at 10-foot legibility, without eating the browse
    /// wall to its right.
    val railWidth = 232.dp
}
