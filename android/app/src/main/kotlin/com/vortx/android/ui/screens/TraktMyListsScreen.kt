package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.home.ImportedCatalogs
import com.vortx.android.integrations.ScrobbleService
import com.vortx.android.integrations.TraktAuth
import com.vortx.android.integrations.TraktMyListsController
import com.vortx.android.profile.ProfileStore
import com.vortx.android.ui.components.PrimaryButton
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TraktMyListsScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current.applicationContext
    val imported = remember(context) { ScrobbleService.init(context); ImportedCatalogs.shared(context) }
    val session by TraktAuth.sessionBoundary.collectAsStateWithLifecycle()
    val profile by ProfileStore.shared.activeProfile.collectAsStateWithLifecycle()
    val controller = remember(imported, session, profile) {
        TraktMyListsController(register = imported::register, remove = imported::remove)
    }
    val state by controller.state.collectAsStateWithLifecycle()
    val catalogs by imported.catalogs.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    LaunchedEffect(session, profile) { controller.reconcile(); controller.load() }
    Scaffold(topBar = {
        TopAppBar(title = { Text("My Trakt lists") }, navigationIcon = {
            IconButton(onClick = onBack) { Icon(VortXIcons.back, contentDescription = "Back") }
        })
    }) { insets ->
        Column(modifier.fillMaxSize().padding(insets).padding(VortXTheme.spacing.edge)
            .verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md)) {
            Text("Browse your lists and up to 100 liked lists as Home rows. Adding or removing a row leaves your lists on Trakt unchanged.")
            Text("Private and friends-only rows stay on this device for the current connection and profile. Add them again after reconnecting or restarting VortX.")
            when {
                !TraktAuth.isConfigured -> Text("Trakt is not available in this build.")
                state.owner == null -> Text("Connect Trakt from Integrations to see your lists.")
                else -> {
                    PrimaryButton(text = if (state.loading) "Loading…" else "Refresh lists", enabled = !state.loading,
                        onClick = { scope.launch { controller.load() } })
                    state.message?.let { Text(it) }
                    if (state.loaded && !state.loading && state.lists.isEmpty() && state.message == null)
                        Text("No lists found. Lists you make or like on Trakt will appear here.")
                    for (liked in listOf(false, true)) {
                        val group = state.lists.filter { it.liked == liked }
                        if (group.isNotEmpty()) Text(if (liked) "Lists you liked" else "Your lists", style = VortXTheme.type.cardTitle)
                        for (list in group) SurfaceCard(modifier = Modifier.fillMaxWidth()) {
                            Column(Modifier.padding(VortXTheme.spacing.md), verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                                Text(list.name, style = VortXTheme.type.cardTitle)
                                Text("${list.privacy.replaceFirstChar(Char::uppercase)} · ${list.itemCount} titles" + if (liked) " · by ${list.owner}" else "")
                                val added = catalogs.any { it.id == list.id }
                                val busy = list.id in state.busyIds
                                PrimaryButton(text = if (busy) "Adding…" else if (added) "Remove row" else "Show as a row",
                                    enabled = !busy, onClick = {
                                        state.owner?.let { owner ->
                                            if (added) controller.remove(owner, list) else scope.launch { controller.add(owner, list) }
                                        }
                                    })
                            }
                        }
                    }
                }
            }
        }
    }
}
