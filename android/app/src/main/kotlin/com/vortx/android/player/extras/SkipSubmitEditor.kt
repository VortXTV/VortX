package com.vortx.android.player.extras

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.vortx.android.player.formatTime
import com.vortx.android.skip.SkipDBClient
import kotlinx.coroutines.launch

/**
 * The in-player "contribute a skip time" editor, the Android analogue of Apple `SkipDBSubmitView`. Captures
 * a segment kind and its start/end (seeded from the playhead, nudged by buttons since the modal cannot scrub)
 * and submits through [SkipDBClient.submit], the same DUAL/triple-submit path Apple uses (authoritative
 * skip.vortx.tv plus the best-effort community + custom legs), then invalidates the cache so the next fetch
 * sees the contribution. Self-contained (its own dark panel) so it stays out of the chrome's internals.
 *
 * The caller gates visibility with [SkipEditPolicy.canEdit]; this view assumes a submittable title.
 */
@Composable
fun SkipSubmitEditor(
    imdbId: String,
    season: Int?,
    episode: Int?,
    currentPositionMs: Long,
    durationMs: Long,
    emberAccent: Color,
    onDismiss: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val upper = if (durationMs > 0L) durationMs else Long.MAX_VALUE

    var kind by remember { mutableStateOf(SkipKind.INTRO) }
    var startMs by remember { mutableStateOf(currentPositionMs.coerceIn(0L, upper)) }
    var endMs by remember { mutableStateOf((currentPositionMs + DEFAULT_SPAN_MS).coerceIn(0L, upper)) }
    var submitting by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }
    var done by remember { mutableStateOf(false) }

    fun nudge(target: Boolean, deltaMs: Long) {
        if (target) startMs = (startMs + deltaMs).coerceIn(0L, upper)
        else endMs = (endMs + deltaMs).coerceIn(0L, upper)
    }

    val valid = endMs > startMs && !submitting

    fun submit() {
        errorText = null
        submitting = true
        scope.launch {
            val durationMsInt = SkipEditPolicy.submissionDurationMs(durationMs / 1000.0, null)
            val result = runCatching {
                SkipDBClient.submit(
                    SkipDBClient.SubmitRequest(
                        imdbId = imdbId,
                        season = season,
                        episode = episode,
                        segmentType = kind.wire,
                        startMs = startMs.toInt(),
                        endMs = endMs.toInt(),
                        durationMs = durationMsInt,
                    ),
                )
                SkipDBClient.invalidateCache(imdbId, season, episode, durationMs / 1000.0)
            }
            submitting = false
            result.onSuccess { done = true }.onFailure { errorText = it.message ?: "Submission failed." }
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.5f))
            .clickable(onClick = onDismiss),
    ) {
        Column(
            modifier = Modifier
                .align(Alignment.Center)
                .fillMaxWidth(0.92f)
                .clip(RoundedCornerShape(16.dp))
                .background(Color(0xFF15171B))
                .padding(20.dp)
                // Swallow taps so a click inside the panel does not dismiss via the scrim.
                .clickable(enabled = false, onClick = {}),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("Contribute a skip time", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 17.sp)

            if (done) {
                Text("Thanks. Your skip time was submitted.", color = Color.White, fontSize = 14.sp)
                PanelButton("Done", emberAccent, filled = true) { onDismiss() }
                return@Column
            }

            // Segment kind picker.
            Text("Segment", color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                SkipKind.entries.forEach { candidate ->
                    val selected = kind == candidate
                    Text(
                        text = candidate.label,
                        color = if (selected) Color.Black else Color.White,
                        fontSize = 13.sp,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .background(if (selected) emberAccent else Color.White.copy(alpha = 0.10f))
                            .clickable { kind = candidate }
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                    )
                }
            }

            TimeRow("Start", startMs, emberAccent, onNudge = { nudge(true, it) }, onNow = { startMs = currentPositionMs.coerceIn(0L, upper) })
            TimeRow("End", endMs, emberAccent, onNudge = { nudge(false, it) }, onNow = { endMs = currentPositionMs.coerceIn(0L, upper) })

            errorText?.let { Text(it, color = Color(0xFFE0803F), fontSize = 13.sp) }
            if (endMs <= startMs) {
                Text("End must be after start.", color = Color(0xFFE0803F), fontSize = 12.sp)
            }

            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                PanelButton("Cancel", emberAccent, filled = false, modifier = Modifier) { onDismiss() }
                PanelButton(if (submitting) "Submitting..." else "Submit", emberAccent, filled = true, enabled = valid) { submit() }
            }
        }
    }
}

/** Segment kinds offered by the editor. [wire] is the skip service's `segment_type` (credits -> outro). */
private enum class SkipKind(val label: String, val wire: String) {
    INTRO("Intro", "intro"),
    RECAP("Recap", "recap"),
    CREDITS("Credits", "outro"),
    PREVIEW("Preview", "preview"),
}

@Composable
private fun TimeRow(label: String, valueMs: Long, accent: Color, onNudge: (Long) -> Unit, onNow: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp, modifier = Modifier.weight(1f))
            Text(formatTime(valueMs), color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            NudgeChip("-30s", accent) { onNudge(-30_000L) }
            NudgeChip("-5s", accent) { onNudge(-5_000L) }
            NudgeChip("Now", accent) { onNow() }
            NudgeChip("+5s", accent) { onNudge(5_000L) }
            NudgeChip("+30s", accent) { onNudge(30_000L) }
        }
    }
}

@Composable
private fun NudgeChip(label: String, accent: Color, onClick: () -> Unit) {
    Text(
        text = label,
        color = Color.White,
        fontSize = 12.sp,
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(Color.White.copy(alpha = 0.10f))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp),
    )
}

@Composable
private fun PanelButton(
    label: String,
    accent: Color,
    filled: Boolean,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Text(
        text = label,
        color = if (filled) Color.Black else Color.White,
        fontWeight = FontWeight.SemiBold,
        fontSize = 14.sp,
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(if (filled) accent.copy(alpha = if (enabled) 1f else 0.4f) else Color.White.copy(alpha = 0.12f))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 10.dp),
    )
}

private const val DEFAULT_SPAN_MS = 90_000L
