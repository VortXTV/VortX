package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
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
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.ui.prefs.TabBarPrefs
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TabBarScreen(
    prefs: TabBarPrefs,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tabs by prefs.state.collectAsStateWithLifecycle()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Tab bar", style = VortXTheme.type.cardTitle) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(VortXIcons.back, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = modifier
                .fillMaxSize()
                .padding(padding)
                .padding(VortXTheme.spacing.edge)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            SettingsSection(
                title = "Visible tabs",
                footer = "Home and Settings always stay. Hiding the current tab returns you to Home.",
            ) {
                ToggleRow("Show Discover tab", null, !tabs.hideDiscover, prefs::setDiscoverVisible)
                ToggleRow(
                    "Show Live TV tab",
                    "Channels from your installed Live TV add-ons.",
                    !tabs.hideLive,
                    prefs::setLiveVisible,
                )
                ToggleRow("Show Library tab", null, !tabs.hideLibrary, prefs::setLibraryVisible)
                ToggleRow("Show Search tab", null, !tabs.hideSearch, prefs::setSearchVisible)
            }
        }
    }
}
