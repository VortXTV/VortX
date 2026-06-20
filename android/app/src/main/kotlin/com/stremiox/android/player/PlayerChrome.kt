package com.stremiox.android.player

import android.content.Context
import android.os.Build
import android.view.Display
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.stremiox.android.model.Playable

/// The VortX-specific chrome layered over the PlayerView. The PlayerView's own controller already owns
/// transport (play/pause, seek, fast-forward/rewind) and the scrubber, recolored ember in
/// [PlayerScreen]. This overlay adds only what the built-in controller does not: a back affordance, the
/// source title, and the DV / streaming-server badges. Keeping transport in the battle-tested Media3
/// controller is deliberate (KISS). We do not re-implement a scrubber.
@Composable
fun PlayerChrome(
    playable: Playable,
    dolbyVisionAvailable: Boolean,
    emberAccent: Color,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(modifier = modifier) {
        // Top scrim so the title and back button stay legible over bright video.
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .align(Alignment.TopCenter)
                .background(
                    Brush.verticalGradient(
                        listOf(Color.Black.copy(alpha = 0.55f), Color.Transparent)
                    )
                )
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 8.dp, vertical = 8.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) {
                    Icon(
                        Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "Back",
                        tint = Color.White,
                    )
                }
                Text(
                    text = playable.title,
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 16.sp,
                    maxLines = 1,
                    modifier = Modifier.padding(start = 4.dp),
                )
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.align(Alignment.CenterEnd),
            ) {
                if (playable.viaStreamingServer) {
                    ChromeBadge("SOURCE", emberAccent)
                }
                // DV badge is GATED on the display actually advertising Dolby Vision. ExoPlayer still
                // does its own DV -> HEVC/AVC/AV1 fallback for decoding regardless; this badge is purely
                // about not claiming DV on a panel that cannot present it.
                if (dolbyVisionAvailable) {
                    ChromeBadge("DOLBY VISION", emberAccent)
                }
            }
        }
    }
}

@Composable
private fun ChromeBadge(text: String, accent: Color) {
    Text(
        text = text,
        color = Color.White,
        fontSize = 10.sp,
        fontWeight = FontWeight.Bold,
        modifier = Modifier
            .clip(RoundedCornerShape(4.dp))
            .background(accent.copy(alpha = 0.85f))
            .padding(horizontal = 8.dp, vertical = 3.dp),
    )
}

/// True when the device's default display advertises Dolby Vision in its HDR capabilities. This gates
/// the DV badge only; it does not influence decoding (ExoPlayer's DefaultRenderersFactory handles the
/// codec fallback). Uses the modern Display API on R+ and reports false on older releases where the
/// capability query is unavailable.
fun displaySupportsDolbyVision(context: Context): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
    val display: Display? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        context.display
    } else {
        @Suppress("DEPRECATION")
        (context.getSystemService(Context.WINDOW_SERVICE) as? android.view.WindowManager)?.defaultDisplay
    }
    @Suppress("DEPRECATION")
    val hdr = display?.hdrCapabilities ?: return false
    return hdr.supportedHdrTypes.contains(Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION)
}
