package com.vortx.android.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.vortx.android.R
import com.vortx.android.foryou.ForYouText
import com.vortx.android.foryou.SmartCollection
import com.vortx.android.model.Catalog
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.components.PosterRail
import com.vortx.android.ui.foryou.SmartCollectionEditor
import com.vortx.android.ui.foryou.phoneForYouChip
import com.vortx.android.ui.foryou.rememberSmartCollectionsState
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme

/** Which collection the builder is open on: [collection] null is a new one. */
private data class Editing(val collection: SmartCollection?)

/**
 * Library > Smart collections on phone and tablet (Apple `iOSSmartCollectionsView`): every collection as a
 * Home-style rail of its titles, pinned to Home or not, with Edit, plus New collection.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SmartCollectionsScreen(onBack: () -> Unit, onItem: (MetaItem) -> Unit, modifier: Modifier = Modifier) {
    val text = ForYouText(LocalContext.current)
    val state = rememberSmartCollectionsState()
    var editing by remember { mutableStateOf<Editing?>(null) }
    editing?.let { open ->
        BackHandler { editing = null }
        SmartCollectionEditor(
            existing = open.collection, watched = state.watched, chip = phoneForYouChip, edge = VortXTheme.spacing.edge,
            onFinish = { editing = null },
        ) { items, _ ->
            if (items.isNotEmpty()) PosterRail(catalog = Catalog("smartCollection.preview", "", items), onItem = {})
        }
        return
    }
    Column(modifier = modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(stringResource(R.string.smart_collections_title), style = VortXTheme.type.screenTitle) },
            navigationIcon = { IconButton(onClick = onBack) { Icon(VortXIcons.back, "Back") } },
        )
        LazyColumn(
            contentPadding = PaddingValues(bottom = VortXTheme.spacing.xl),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
        ) {
            item {
                Column(modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge), verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                    Text(stringResource(R.string.smart_collections_intro), style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary))
                    Chip(label = stringResource(R.string.smart_collections_new), selected = false, onClick = { editing = Editing(null) },
                        leadingIcon = Icons.Filled.Add)
                    when {
                        !state.store.ready -> Note(stringResource(R.string.smart_collections_not_ready))
                        state.store.collections.isEmpty() -> Note(stringResource(R.string.smart_collections_empty))
                    }
                }
            }
            items(state.store.collections, key = { it.id }) { collection ->
                val items = state.visible(collection)
                Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
                    Row(modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                        Chip(label = stringResource(R.string.smart_collections_edit), selected = false,
                            onClick = { editing = Editing(collection) }, leadingIcon = Icons.Filled.Tune)
                        if (collection.home) Text(stringResource(R.string.smart_collections_on_home).uppercase(),
                            style = VortXTheme.type.eyebrow.copy(color = VortXTheme.colors.accentBright))
                    }
                    if (items.isEmpty()) {
                        Column(modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge)) {
                            Text(text.summary(collection.rules).uppercase(), style = VortXTheme.type.eyebrow)
                            Text(collection.name, style = VortXTheme.type.sectionTitle)
                            Note(stringResource(if (collection.id in state.loading) R.string.smart_collections_finding else R.string.smart_collections_no_match))
                        }
                    } else {
                        PosterRail(catalog = Catalog("smartCollection.${collection.id}", collection.name, items), onItem = onItem,
                            eyebrow = text.summary(collection.rules))
                    }
                }
            }
        }
    }
}

@Composable
private fun Note(text: String) {
    Text(text, style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary))
}
