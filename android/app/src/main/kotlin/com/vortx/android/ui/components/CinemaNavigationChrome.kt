package com.vortx.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.vortx.android.ui.prefs.TabSlot
import com.vortx.android.ui.cinemaCompactNavigation
import com.vortx.android.ui.theme.VortXGlass
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.vortxGlass

internal data class CinemaNavigationItem(val slot: TabSlot, val label: String, val icon: ImageVector)

/** Pure presentation: no account, native session, provider, store, or second navigation owner. */
@Composable
internal fun CinemaTopNavigation(
    items: List<CinemaNavigationItem>, selected: TabSlot, onSelect: (TabSlot) -> Unit,
    onProfiles: () -> Unit, modifier: Modifier = Modifier,
) {
    Row(modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.widthIn(max = 1200.dp), horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Wordmark()
            Row(Modifier.weight(1f, fill = false).vortxGlass(RoundedCornerShape(32.dp),
                shadow = VortXGlass.Shadow.flat).horizontalScroll(rememberScrollState())
                .selectableGroup().padding(6.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                items.forEach { item ->
                    CinemaNavigationButton(item, item.slot == selected, compact = false,
                        onClick = { onSelect(item.slot) })
                }
            }
            IconButton(onClick = onProfiles) { Icon(VortXIcons.profiles, "Switch or manage profiles") }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CinemaBottomNavigation(
    items: List<CinemaNavigationItem>, selected: TabSlot, onSelect: (TabSlot) -> Unit,
    onProfiles: () -> Unit, modifier: Modifier = Modifier,
) {
    val plan = cinemaCompactNavigation(items.map { it.slot })
    val primary = plan.primary.mapNotNull { slot -> items.firstOrNull { it.slot == slot } }
    val overflow = plan.overflow.mapNotNull { slot -> items.firstOrNull { it.slot == slot } }
    var moreOpen by rememberSaveable { mutableStateOf(false) }
    Box(modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center) {
        Row(Modifier.widthIn(max = 600.dp).fillMaxWidth()
            .vortxGlass(RoundedCornerShape(30.dp), shadow = VortXGlass.Shadow.flat)
            .selectableGroup().padding(6.dp), verticalAlignment = Alignment.CenterVertically) {
            primary.forEach { item ->
                CinemaNavigationButton(item, item.slot == selected, compact = true,
                    onClick = { onSelect(item.slot) }, modifier = Modifier.weight(1f))
            }
            if (overflow.isNotEmpty()) {
                CinemaNavigationButton(CinemaNavigationItem(TabSlot.SETTINGS, "More", VortXIcons.moreHoriz),
                    selected = selected in plan.overflow, compact = true,
                    onClick = { moreOpen = true }, modifier = Modifier.weight(1f))
            }
        }
    }
    if (moreOpen && overflow.isNotEmpty()) {
        ModalBottomSheet(onDismissRequest = { moreOpen = false }, containerColor = VortXTheme.colors.surface1) {
            Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).selectableGroup()
                .padding(horizontal = 20.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("More", style = VortXTheme.type.screenTitle)
                overflow.forEach { item ->
                    CinemaNavigationButton(item, item.slot == selected, compact = false,
                        onClick = { moreOpen = false; onSelect(item.slot) }, modifier = Modifier.fillMaxWidth())
                }
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
                    .selectable(selected = false, role = Role.Button,
                        onClick = { moreOpen = false; onProfiles() }).padding(12.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(VortXIcons.profiles, null)
                    Text("Switch or manage profiles", style = VortXTheme.type.label)
                }
            }
        }
    }
}

@Composable
private fun CinemaNavigationButton(
    item: CinemaNavigationItem, selected: Boolean, compact: Boolean,
    onClick: () -> Unit, modifier: Modifier = Modifier,
) {
    val colors = VortXTheme.colors
    val tint = if (selected) colors.accent else colors.textSecondary
    val frame = modifier.clip(RoundedCornerShape(24.dp))
        .then(if (selected) Modifier.background(colors.accentSoft) else Modifier)
        .selectable(selected = selected, role = Role.Tab, onClick = onClick)
        .heightIn(min = if (compact) 60.dp else 48.dp)
        .padding(horizontal = if (compact) 3.dp else 14.dp, vertical = 8.dp)
    if (compact) {
        Column(frame, horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Icon(item.icon, null, tint = tint, modifier = Modifier.size(24.dp))
            Text(item.label, color = tint, style = VortXTheme.type.label,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    } else {
        Row(frame, horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(item.icon, null, tint = tint, modifier = Modifier.size(22.dp))
            Text(item.label, color = tint, style = VortXTheme.type.label, maxLines = 1)
        }
    }
}
