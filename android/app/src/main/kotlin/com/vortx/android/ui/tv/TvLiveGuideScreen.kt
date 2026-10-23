package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import coil3.compose.AsyncImage
import com.vortx.android.iptv.LiveGuideChannel
import com.vortx.android.iptv.LiveGuideLoader
import com.vortx.android.iptv.LiveGuidePolicy
import com.vortx.android.iptv.LiveGuideProgramme
import com.vortx.android.iptv.LiveGuideSegment
import com.vortx.android.iptv.LiveGuideWindow
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.delay

private val CHANNEL_WIDTH = 260.dp
private val ROW_HEIGHT = 96.dp
private const val HOURS = 3
private const val PAGE_HALF_HOURS = 3

/**
 * Live > TV guide on Android TV (Apple `TVLiveGuideView`): every live channel down the side, a paged three-hour
 * window of programmes across, a line at the current time. Rows load their channel's schedule when they scroll
 * into view. Choosing any programme opens the channel.
 */
@Composable
internal fun TvLiveGuideScreen(channels: List<LiveGuideChannel>, onOpen: (LiveGuideChannel) -> Unit, onBack: () -> Unit) {
    BackHandler { onBack() }
    val scope = rememberCoroutineScope()
    val loader = remember { LiveGuideLoader(scope) }
    val schedules by loader.schedules.collectAsStateWithLifecycle()
    var window by remember { mutableStateOf(LiveGuidePolicy.window(System.currentTimeMillis(), HOURS)) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(60_000); now = System.currentTimeMillis() } }
    val timeFormat = remember { DateFormat.getTimeInstance(DateFormat.SHORT) }

    Column(modifier = Modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
        TvLibraryRouteHeader("TV guide", onBack = onBack)
        Row(
            modifier = Modifier.padding(horizontal = TvDimens.edge),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TvFilterChip("Earlier", selected = false, onClick = { window = LiveGuidePolicy.shifted(window, -PAGE_HALF_HOURS) },
                leadingIcon = Icons.AutoMirrored.Filled.KeyboardArrowLeft)
            TvFilterChip("Now", selected = now in window, onClick = { window = LiveGuidePolicy.window(System.currentTimeMillis(), HOURS) })
            TvFilterChip("Later", selected = false, onClick = { window = LiveGuidePolicy.shifted(window, PAGE_HALF_HOURS) },
                leadingIcon = Icons.AutoMirrored.Filled.KeyboardArrowRight)
        }
        if (channels.isEmpty()) {
            Text("No live channels yet. Add an IPTV playlist or a live TV add-on and its channels appear here.",
                style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
                modifier = Modifier.padding(TvDimens.edge))
            return@Column
        }
        BoxWithConstraints(modifier = Modifier.fillMaxSize().padding(horizontal = TvDimens.edge)) {
            val trackWidth = (maxWidth - CHANNEL_WIDTH).coerceAtLeast(1.dp)
            val dpPerMinute = trackWidth.value / (HOURS * 60)
            Column {
                Row(modifier = Modifier.padding(vertical = VortXTheme.spacing.xs)) {
                    Spacer(Modifier.width(CHANNEL_WIDTH))
                    LiveGuidePolicy.marks(window).forEach { mark ->
                        Text(timeFormat.format(Date(mark)), style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                            modifier = Modifier.width((30 * dpPerMinute).dp))
                    }
                }
                Box {
                    LazyColumn(
                        contentPadding = PaddingValues(bottom = TvDimens.edge),
                        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
                    ) {
                        items(channels, key = { "${it.type}|${it.id}" }) { channel ->
                            LaunchedEffect(channel.id) { loader.request(channel) }
                            TvGuideRow(channel, schedules[channel.id], window, dpPerMinute, trackWidth, now, timeFormat) { onOpen(channel) }
                        }
                    }
                    if (now in window) {
                        val x = CHANNEL_WIDTH + ((now - window.startMs) / 60_000f * dpPerMinute).dp
                        Box(Modifier.offset(x = x).width(2.dp).fillMaxHeight().background(VortXTheme.colors.accent))
                    }
                }
            }
        }
    }
}

@Composable
private fun TvGuideRow(
    channel: LiveGuideChannel,
    schedule: LiveGuideLoader.Schedule?,
    window: LiveGuideWindow,
    dpPerMinute: Float,
    trackWidth: Dp,
    now: Long,
    timeFormat: DateFormat,
    onOpen: () -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Row(
            modifier = Modifier.width(CHANNEL_WIDTH).padding(end = VortXTheme.spacing.xs),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
        ) {
            AsyncImage(model = channel.logo, contentDescription = null, modifier = Modifier.size(48.dp))
            Text(channel.name, style = VortXTheme.type.label, maxLines = 2)
        }
        Box(modifier = Modifier.width(trackWidth).height(ROW_HEIGHT), contentAlignment = Alignment.CenterStart) {
            when (schedule) {
                is LiveGuideLoader.Schedule.Loaded -> {
                    val segments = LiveGuidePolicy.segments(LiveGuidePolicy.cells(schedule.programmes, window, dpPerMinute))
                    if (segments.isEmpty()) {
                        TvGuideCell("Nothing scheduled in this window · Watch live", null, trackWidth, onAir = false, onClick = onOpen)
                    } else Row {
                        segments.forEach { segment ->
                            when (segment) {
                                is LiveGuideSegment.Gap -> Spacer(Modifier.width(segment.width.dp))
                                is LiveGuideSegment.Cell -> TvGuideCell(
                                    segment.cell.programme.title, range(segment.cell.programme, timeFormat),
                                    segment.cell.width.dp, onAir = segment.cell.programme.isOn(now), onClick = onOpen,
                                )
                            }
                        }
                    }
                }
                LiveGuideLoader.Schedule.Unavailable ->
                    TvGuideCell("No guide for this channel · Watch live", null, trackWidth, onAir = false, onClick = onOpen)
                LiveGuideLoader.Schedule.Loading, null ->
                    Text("Loading guide…", style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary),
                        modifier = Modifier.padding(horizontal = VortXTheme.spacing.sm))
            }
        }
    }
}

@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvGuideCell(title: String, detail: String?, width: Dp, onAir: Boolean, onClick: () -> Unit) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        modifier = Modifier.width(width).height(ROW_HEIGHT).padding(horizontal = 2.dp, vertical = 3.dp),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (onAir) colors.accent.copy(alpha = 0.24f) else colors.surface1,
            contentColor = colors.textPrimary,
            focusedContainerColor = colors.surface3,
            focusedContentColor = colors.textPrimary,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(BorderStroke(TvDimens.focusBorder, colors.accentBright), shape = VortXShapes.control),
        ),
    ) {
        Column(modifier = Modifier.padding(horizontal = VortXTheme.spacing.xs, vertical = 4.dp), verticalArrangement = Arrangement.Center) {
            Text(title, style = VortXTheme.type.label, maxLines = 1)
            detail?.let { Text(it, style = VortXTheme.type.label.copy(color = colors.textSecondary), maxLines = 1) }
        }
    }
}

private fun range(programme: LiveGuideProgramme, format: DateFormat): String =
    "${format.format(Date(programme.startMs))} – ${format.format(Date(programme.endMs))}"
