package com.vortx.android.player

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.HighQuality
import androidx.compose.material.icons.filled.BrightnessHigh
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.vortx.android.ui.theme.vortxGlassProminent

/** Same existing badge row/padding/tint, no independent polling or focus/input behavior. */
@Composable
internal fun PlaybackMetadataPillView(pill: PlaybackMetadataPill, accent: Color) {
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier.vortxGlassProminent(shape = RoundedCornerShape(6.dp), tint = accent)
            .padding(horizontal = 8.dp, vertical = 3.dp)
            .clearAndSetSemantics { contentDescription = pill.accessibilityLabel }) {
        Icon(when (pill.id) {
            "quality" -> Icons.Filled.HighQuality
            "range" -> Icons.Filled.BrightnessHigh
            else -> Icons.Filled.VolumeUp
        }, contentDescription = null, tint = Color.White, modifier = Modifier.size(12.dp))
        Text(pill.text, color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Bold, maxLines = 1)
    }
}
