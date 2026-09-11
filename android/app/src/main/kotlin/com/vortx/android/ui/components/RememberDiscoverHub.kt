package com.vortx.android.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.vortx.android.home.CollectionsHubModel
import com.vortx.android.home.CollectionsHubSurface
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/** Phone and TV own independent Discover instances; closing one never clears the Home hub. */
@Composable
internal fun rememberDiscoverHub(): CollectionsHubModel {
    val context = LocalContext.current.applicationContext
    val model = remember(context) { CollectionsHubModel(context, surface = CollectionsHubSurface.DISCOVER) }
    LaunchedEffect(model) {
        model.refreshRequests().collectLatest {
            coroutineScope {
                launch { model.load() }
                launch { model.loadArtwork() }
            }
        }
    }
    DisposableEffect(model) { onDispose { model.close() } }
    return model
}
