package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Tune
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.tv.material3.Text
import com.vortx.android.R
import com.vortx.android.foryou.ForYouText
import com.vortx.android.foryou.SmartCollection
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.foryou.SmartCollectionEditor
import com.vortx.android.ui.foryou.rememberSmartCollectionsState
import com.vortx.android.ui.theme.VortXTheme

private data class TvEditing(val collection: SmartCollection?)

/**
 * Library > Smart collections on TV (Apple `TVSmartCollectionsView`): every collection as a row of the
 * same cinema cards Home uses, pinned to Home or not, with Edit, plus New collection.
 */
@Composable
internal fun TvSmartCollectionsScreen(onBack: () -> Unit, onItem: (MetaItem) -> Unit) {
    val text = ForYouText(LocalContext.current)
    val state = rememberSmartCollectionsState()
    var editing by remember { mutableStateOf<TvEditing?>(null) }
    editing?.let { open ->
        BackHandler { editing = null }
        Box(modifier = Modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
            SmartCollectionEditor(
                existing = open.collection, watched = state.watched, chip = tvForYouChip, edge = TvDimens.edge,
                onFinish = { editing = null },
            ) { items, _ -> if (items.isNotEmpty()) TvCardRow(items, onItem = {}) }
        }
        return
    }
    Column(modifier = Modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
        TvLibraryRouteHeader(stringResource(R.string.smart_collections_title), onBack)
        LazyColumn(
            contentPadding = PaddingValues(bottom = TvDimens.edge),
            verticalArrangement = Arrangement.spacedBy(TvDimens.rowGap),
        ) {
            item {
                Column(modifier = Modifier.padding(horizontal = TvDimens.edge), verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                    Text(stringResource(R.string.smart_collections_intro), style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary))
                    TvFilterChip(label = stringResource(R.string.smart_collections_new), selected = false,
                        onClick = { editing = TvEditing(null) }, leadingIcon = Icons.Filled.Add)
                    when {
                        !state.store.ready -> TvNote(stringResource(R.string.smart_collections_not_ready))
                        state.store.collections.isEmpty() -> TvNote(stringResource(R.string.smart_collections_empty))
                    }
                }
            }
            items(state.store.collections, key = { it.id }) { collection ->
                val items = state.visible(collection)
                Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                    Row(modifier = Modifier.padding(horizontal = TvDimens.edge), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(text.summary(collection.rules).uppercase(), style = VortXTheme.type.eyebrow)
                            Text(collection.name, style = VortXTheme.type.sectionTitle)
                        }
                        if (collection.home) Text(stringResource(R.string.smart_collections_on_home).uppercase(),
                            style = VortXTheme.type.eyebrow.copy(color = VortXTheme.colors.accentBright))
                        TvFilterChip(label = stringResource(R.string.smart_collections_edit), selected = false,
                            onClick = { editing = TvEditing(collection) }, leadingIcon = Icons.Filled.Tune)
                    }
                    if (items.isEmpty()) {
                        Box(modifier = Modifier.padding(horizontal = TvDimens.edge)) {
                            TvNote(stringResource(if (collection.id in state.loading) R.string.smart_collections_finding else R.string.smart_collections_no_match))
                        }
                    } else TvCardRow(items, onItem)
                }
            }
        }
    }
}

@Composable
private fun TvCardRow(items: List<MetaItem>, onItem: (MetaItem) -> Unit) {
    LazyRow(contentPadding = PaddingValues(horizontal = TvDimens.edge), horizontalArrangement = Arrangement.spacedBy(TvDimens.cardGap)) {
        items(items, key = { "${it.type.name}|${it.id}" }) { item -> TvCinemaCard(item = item, onClick = { onItem(item) }) }
    }
}

@Composable
private fun TvNote(text: String) {
    Text(text, style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary))
}
