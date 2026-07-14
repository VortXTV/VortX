package com.vortx.android.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.dp

/// Corner radii (DESIGN-SYSTEM.md §2 "Radius"). [pill] is a large value rather than 50% so a pill
/// shape stays a stable capsule at any height, matching CSS's `border-radius: 999px` idiom.
object VortXRadius {
    val card = 16.dp
    val chip = 12.dp
    val control = 14.dp
    val pill = 999.dp
}

object VortXShapes {
    val card = RoundedCornerShape(VortXRadius.card)
    val chip = RoundedCornerShape(VortXRadius.chip)
    val control = RoundedCornerShape(VortXRadius.control)
    val pill = RoundedCornerShape(VortXRadius.pill)
}
