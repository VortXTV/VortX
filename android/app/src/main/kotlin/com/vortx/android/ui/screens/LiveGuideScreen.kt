package com.vortx.android.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.vortx.android.iptv.LiveGuideChannel
import com.vortx.android.iptv.LiveGuideLoader
import com.vortx.android.iptv.LiveGuidePolicy
import com.vortx.android.iptv.LiveGuideProgramme
import com.vortx.android.iptv.LiveGuideSegment
import com.vortx.android.iptv.LiveGuideWindow
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.delay

private val CHANNEL_WIDTH = 104.dp
private val ROW_HEIGHT = 64.dp
private const val HOURS = 2
private const val PAGE_HALF_HOURS = 2

/**
 * Live > TV guide on phone and tablet (Apple `iOSLiveGuideView`): every live channel down the side, a paged
 * two-hour window of programmes across, a line at the current time. Rows load their channel's schedule when
 * they scroll into view. Tapping any programme opens the channel.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LiveGuideScreen(channels: List<LiveGuideChannel>, onOpen: (LiveGuideChannel) -> Unit, onBack: () -> Unit) {
    BackHandler { onBack() }
    val scope = rememberCoroutineScope()
    val loader = remember { LiveGuideLoader(scope) }
    val schedules by loader.schedules.collectAsStateWithLifecycle()
    var window by remember { mutableStateOf(LiveGuidePolicy.window(System.currentTimeMillis(), HOURS)) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(60_000); now = System.currentTimeMillis() } }
    val timeFormat = remember { DateFormat.getTimeInstance(DateFormat.SHORT) }

    Column(modifier = Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("TV guide", style = VortXTheme.type.screenTitle) },
            navigationIcon = { IconButton(onClick = onBack) { Icon(VortXIcons.back, "Back") } },
        )
        Row(modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge), horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
            Chip("Earlier", selected = false, onClick = { window = LiveGuidePolicy.shifted(window, -PAGE_HALF_HOURS) })
            Chip("Now", selected = now in window, onClick = { window = LiveGuidePolicy.window(System.currentTimeMillis(), HOURS) })
            Chip("Later", selected = false, onClick = { window = LiveGuidePolicy.shifted(window, PAGE_HALF_HOURS) })
        }
        if (channels.isEmpty()) {
            Text("No live channels yet. Add an IPTV playlist or a live TV add-on and its channels appear here.",
                style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
                modifier = Modifier.padding(VortXTheme.spacing.edge))
            return@Column
        }
        BoxWithConstraints(modifier = Modifier.fillMaxSize().padding(horizontal = VortXTheme.spacing.sm)) {
            val trackWidth = (maxWidth - CHANNEL_WIDTH).coerceAtLeast(1.dp)
            val dpPerMinute = trackWidth.value / (HOURS * 60)
            Column {
                Row(modifier = Modifier.padding(vertical = VortXTheme.spacing.xs)) {
                    Spacer(Modifier.width(CHANNEL_WIDTH))
                    LiveGuidePolicy.marks(window).forEach { mark ->
                        Text(timeFormat.format(Date(mark)), style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                            modifier = Modifier.width((30 * dpPerMinute).dp), maxLines = 1)
                    }
                }
                Box {
                    LazyColumn(contentPadding = PaddingValues(bottom = VortXTheme.spacing.xl), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        items(channels, key = { "${it.type}|${it.id}" }) { channel ->
                            LaunchedEffect(channel.id) { loader.request(channel) }
                            GuideRow(channel, schedules[channel.id], window, dpPerMinute, trackWidth, now, timeFormat) { onOpen(channel) }
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
private fun GuideRow(
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
            modifier = Modifier.width(CHANNEL_WIDTH).padding(end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            AsyncImage(model = channel.logo, contentDescription = null, modifier = Modifier.size(28.dp))
            Text(channel.name, style = VortXTheme.type.label, maxLines = 2)
        }
        Box(modifier = Modifier.width(trackWidth).height(ROW_HEIGHT), contentAlignment = Alignment.CenterStart) {
            when (schedule) {
                is LiveGuideLoader.Schedule.Loaded -> {
                    val segments = LiveGuidePolicy.segments(LiveGuidePolicy.cells(schedule.programmes, window, dpPerMinute))
                    if (segments.isEmpty()) GuideCell("Nothing scheduled · Watch live", null, trackWidth, false, onOpen)
                    else Row {
                        segments.forEach { segment ->
                            when (segment) {
                                is LiveGuideSegment.Gap -> Spacer(Modifier.width(segment.width.dp))
                                is LiveGuideSegment.Cell -> GuideCell(segment.cell.programme.title, range(segment.cell.programme, timeFormat),
                                    segment.cell.width.dp, segment.cell.programme.isOn(now), onOpen)
                            }
                        }
                    }
                }
                LiveGuideLoader.Schedule.Unavailable -> GuideCell("No guide · Watch live", null, trackWidth, false, onOpen)
                LiveGuideLoader.Schedule.Loading, null ->
                    Text("Loading…", style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary),
                        modifier = Modifier.padding(horizontal = VortXTheme.spacing.xs))
            }
        }
    }
}

@Composable
private fun GuideCell(title: String, detail: String?, width: Dp, onAir: Boolean, onClick: () -> Unit) {
    val colors = VortXTheme.colors
    Column(
        modifier = Modifier
            .width(width)
            .height(ROW_HEIGHT)
            .padding(horizontal = 1.dp, vertical = 2.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(if (onAir) colors.accent.copy(alpha = 0.24f) else colors.surface1)
            .clickable(onClick = onClick)
            .padding(horizontal = 6.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Text(title, style = VortXTheme.type.label, maxLines = 1)
        detail?.let { Text(it, style = VortXTheme.type.label.copy(color = colors.textSecondary), maxLines = 1) }
    }
}

private fun range(programme: LiveGuideProgramme, format: DateFormat): String =
    "${format.format(Date(programme.startMs))} – ${format.format(Date(programme.endMs))}"
