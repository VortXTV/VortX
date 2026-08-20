package com.vortx.android.player

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.vortx.android.ui.theme.vortxGlassPanel
import com.vortx.android.ui.theme.vortxGlassProminent

/**
 * The "Still watching?" idle / binge guard, the Android port of Apple's PlayerScreen.swift
 * `maybePromptStillWatching` / `presentStillWatching` / `continueStillWatching` / `stopStillWatching`.
 *
 * This file holds the PURE decision ([StillWatchingPolicy]) plus the overlay ([StillWatchingOverlay]);
 * the host ([com.vortx.android.player.PlayerScreen]) owns the idle deadline, the interaction re-arm, and
 * the pause/resume, exactly as Apple's PlayerScreen owns `idleDeadline` / `noteInteraction`.
 */
object StillWatchingPolicy {

    /**
     * Whether the timed idle prompt should fire on this poll tick. Mirrors Apple `maybePromptStillWatching`:
     * only when enabled, actually playing, not already prompting, and past the idle deadline; a paused /
     * buffering / errored / already-prompting session is never interrupted (each is re-checked next tick).
     */
    fun shouldPromptOnIdle(
        enabled: Boolean,
        alreadyPrompting: Boolean,
        hasStartedPlaying: Boolean,
        isPaused: Boolean,
        isBuffering: Boolean,
        hasError: Boolean,
        nowMs: Long,
        idleDeadlineMs: Long,
    ): Boolean {
        if (!enabled || alreadyPrompting) return false
        if (!hasStartedPlaying || isPaused || isBuffering || hasError) return false
        return nowMs >= idleDeadlineMs
    }

    /**
     * Whether a binge boundary (an auto-advance about to happen) should raise the prompt instead of rolling
     * straight on. Mirrors Apple's boundary check `consecutiveAutoAdvances >= max(1, afterEpisodes)`.
     */
    fun shouldPromptOnBinge(enabled: Boolean, consecutiveAutoAdvances: Int, afterEpisodes: Int): Boolean {
        if (!enabled) return false
        return consecutiveAutoAdvances >= maxOf(1, afterEpisodes)
    }
}

/**
 * The "Still watching?" modal: a dark scrim + warm-glass card with a Stop and a Continue action, matching
 * Apple's `stillWatchingOverlay` (title, idle subtitle, Stop = leave, Continue = resume). Drawn over the
 * chrome by the host while the prompt is up.
 */
@Composable
fun StillWatchingOverlay(
    emberAccent: Color,
    onContinue: () -> Unit,
    onStop: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.55f)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .widthIn(max = 420.dp)
                .padding(horizontal = 32.dp)
                .vortxGlassPanel(RoundedCornerShape(22.dp))
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                text = "Still watching?",
                color = Color.White,
                fontWeight = FontWeight.Bold,
                fontSize = 22.sp,
            )
            Text(
                text = "Playback paused after a long stretch with no activity.",
                color = Color.White.copy(alpha = 0.7f),
                fontSize = 14.sp,
                textAlign = TextAlign.Center,
            )
            Row(
                modifier = Modifier.padding(top = 14.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "Stop",
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 15.sp,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .background(Color.White.copy(alpha = 0.18f), RoundedCornerShape(999.dp))
                        .clickable(onClick = onStop)
                        .padding(horizontal = 22.dp, vertical = 12.dp),
                )
                Row(
                    modifier = Modifier
                        .vortxGlassProminent(shape = RoundedCornerShape(999.dp), tint = emberAccent)
                        .clickable(onClick = onContinue)
                        .padding(horizontal = 22.dp, vertical = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = Icons.Filled.PlayArrow,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.padding(0.dp),
                    )
                    Text(
                        text = "Continue",
                        color = Color.White,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 15.sp,
                    )
                }
            }
        }
    }
}
