package com.vortx.android.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.home.HomeRail
import com.vortx.android.home.HomeRailPreferences
import com.vortx.android.home.HomeRailSurface
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CustomizeHomeScreen(
    preferences: HomeRailPreferences,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler(onBack = onBack)
    val layout by preferences.state.collectAsStateWithLifecycle()
    val rails = remember(layout) { preferences.ordered(HomeRailSurface.PHONE) }
    val order = remember(rails) { rails.toMutableStateList() }
    var draggingKey by remember { mutableStateOf<String?>(null) }
    var dragOffset by remember { mutableStateOf(0f) }
    val rowHeightPx = with(LocalDensity.current) { (ROW_HEIGHT_DP + ROW_GAP_DP).dp.toPx() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Customize Home", style = VortXTheme.type.cardTitle) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(VortXIcons.back, contentDescription = "Back")
                    }
                },
                actions = {
                    TextButton(onClick = preferences::reset) { Text("Reset") }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = VortXTheme.spacing.edge, vertical = VortXTheme.spacing.md),
            verticalArrangement = Arrangement.spacedBy(ROW_GAP_DP.dp),
        ) {
            Text(
                "Drag rows into your preferred order or turn them off. Continue Watching always stays first.",
                style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
                modifier = Modifier.padding(bottom = VortXTheme.spacing.sm),
            )
            PinnedContinueWatchingRow()
            order.forEach { rail ->
                key(rail.key) {
                    val dragging = draggingKey == rail.key
                    val shown = rail !in layout.hidden
                    SurfaceCard(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(ROW_HEIGHT_DP.dp)
                            .zIndex(if (dragging) 1f else 0f)
                            .graphicsLayer { translationY = if (dragging) dragOffset else 0f },
                    ) {
                        Row(
                            modifier = Modifier.fillMaxSize().padding(horizontal = VortXTheme.spacing.md),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
                        ) {
                            Text(rail.title, style = VortXTheme.type.cardTitle, modifier = Modifier.weight(1f))
                            Switch(
                                checked = shown,
                                onCheckedChange = { preferences.setHidden(rail, hidden = !it) },
                                modifier = Modifier.semantics {
                                    contentDescription = if (shown) "Hide ${rail.title}" else "Show ${rail.title}"
                                },
                            )
                            Icon(
                                imageVector = Icons.Filled.DragHandle,
                                contentDescription = "Reorder ${rail.title}",
                                tint = VortXTheme.colors.textTertiary,
                                modifier = Modifier.pointerInput(rail.key) {
                                    detectDragGestures(
                                        onDragStart = {
                                            draggingKey = rail.key
                                            dragOffset = 0f
                                        },
                                        onDrag = { change, amount ->
                                            change.consume()
                                            dragOffset += amount.y
                                            val from = order.indexOfFirst { it.key == rail.key }
                                            if (from < 0) return@detectDragGestures
                                            val target = (from + (dragOffset / rowHeightPx).roundToInt())
                                                .coerceIn(0, order.lastIndex)
                                            if (target != from) {
                                                order.add(target, order.removeAt(from))
                                                dragOffset -= (target - from) * rowHeightPx
                                            }
                                        },
                                        onDragEnd = {
                                            draggingKey = null
                                            dragOffset = 0f
                                            preferences.setOrder(order.toList())
                                        },
                                        onDragCancel = {
                                            draggingKey = null
                                            dragOffset = 0f
                                            order.clear()
                                            order.addAll(preferences.ordered(HomeRailSurface.PHONE))
                                        },
                                    )
                                },
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PinnedContinueWatchingRow() {
    SurfaceCard(modifier = Modifier.fillMaxWidth().height(ROW_HEIGHT_DP.dp)) {
        Row(
            modifier = Modifier.fillMaxSize().padding(horizontal = VortXTheme.spacing.md),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text("Continue Watching", style = VortXTheme.type.cardTitle, modifier = Modifier.weight(1f))
            Text("Always first", style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary))
        }
    }
}

private const val ROW_HEIGHT_DP = 68
private const val ROW_GAP_DP = 10
