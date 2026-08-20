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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import com.vortx.android.ui.prefs.HomeDiscoverPreferences
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme

/// Settings > Home & Discover (SET-3, Apple `iOSSettingsView.swift:1640-1672`). Content toggles + the
/// collections refresh cadence, each persisted on Apple's EXACT key via [HomeDiscoverPreferences]. The two
/// Collections-hub-on-Home keys and the cadence are read live by
/// [com.vortx.android.home.CollectionsHubModel]; the rest persist + sync on the same key and take effect
/// once their consumer is ported (see [HomeDiscoverPreferences]).
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeDiscoverSettingsScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current.applicationContext
    val prefs = remember { HomeDiscoverPreferences(context) }

    var showCuratedRails by remember { mutableStateOf(prefs.showCuratedRails) }
    var showHubHome by remember { mutableStateOf(prefs.showCollectionsHubHome) }
    var showHubDiscover by remember { mutableStateOf(prefs.showCollectionsHubDiscover) }
    var refreshCadence by remember { mutableStateOf(prefs.refreshCadence) }
    var mergeDiscoverSearch by remember { mutableStateOf(prefs.mergeDiscoverSearch) }
    var regionPreference by remember { mutableStateOf(prefs.regionPreference) }
    var showFinancials by remember { mutableStateOf(prefs.showFinancials) }
    var spoilerSafe by remember { mutableStateOf(prefs.spoilerSafe) }
    var hidePosterLabels by remember { mutableStateOf(prefs.hidePosterLabels) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Home & Discover", style = VortXTheme.type.cardTitle) },
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
                title = "Home",
                footer = "Editorial rows are built-in and show even with no add-ons. Collections needs a TMDB key.",
            ) {
                ToggleRow(
                    label = "Show editorial Home rows",
                    detail = null,
                    checked = showCuratedRails,
                    onCheckedChange = {
                        showCuratedRails = it
                        prefs.showCuratedRails = it
                    },
                )
                ToggleRow(
                    label = "Collections on Home",
                    detail = null,
                    checked = showHubHome,
                    onCheckedChange = {
                        showHubHome = it
                        prefs.showCollectionsHubHome = it
                    },
                )
            }

            SettingsSection(
                title = "Discover",
                footer = "Combine Discover and Search into one surface with a search field above the browse.",
            ) {
                ToggleRow(
                    label = "Collections on Discover",
                    detail = null,
                    checked = showHubDiscover,
                    onCheckedChange = {
                        showHubDiscover = it
                        prefs.showCollectionsHubDiscover = it
                    },
                )
                ToggleRow(
                    label = "Combine Discover & Search",
                    detail = null,
                    checked = mergeDiscoverSearch,
                    onCheckedChange = {
                        mergeDiscoverSearch = it
                        prefs.mergeDiscoverSearch = it
                    },
                )
            }

            SettingsSection(
                title = "Region",
                footer = "Browse another market's streaming services and catalogs in Collections. Auto uses " +
                    "your device region.",
            ) {
                PickerRow(
                    label = "Discover region",
                    options = regionOptions,
                    selectedId = regionPreference,
                    onSelect = {
                        regionPreference = it
                        prefs.regionPreference = it
                    },
                )
            }

            SettingsSection(
                title = "Collections",
                footer = "How often the Collections hub refreshes its tiles.",
            ) {
                PickerRow(
                    label = "Refresh collections",
                    options = refreshCadenceOptions,
                    selectedId = refreshCadence,
                    onSelect = {
                        refreshCadence = it
                        prefs.refreshCadence = it
                    },
                )
            }

            SettingsSection(
                title = "Detail pages",
                footer = "Spoiler-safe mode veils an unwatched episode's art and synopsis. Hide poster labels " +
                    "removes titles under every poster.",
            ) {
                ToggleRow(
                    label = "Budget & box office",
                    detail = null,
                    checked = showFinancials,
                    onCheckedChange = {
                        showFinancials = it
                        prefs.showFinancials = it
                    },
                )
                ToggleRow(
                    label = "Spoiler-safe mode",
                    detail = null,
                    checked = spoilerSafe,
                    onCheckedChange = {
                        spoilerSafe = it
                        prefs.setSpoilerSafe(it)
                    },
                )
                ToggleRow(
                    label = "Hide poster labels",
                    detail = null,
                    checked = hidePosterLabels,
                    onCheckedChange = {
                        hidePosterLabels = it
                        prefs.hidePosterLabels = it
                    },
                )
            }
        }
    }
}

/// Apple's refresh-cadence raw values (iOSSettingsView.swift:1668-1670): id = stored value, label = display.
private val refreshCadenceOptions: List<Pair<String, String>> = listOf(
    "daily" to "Daily",
    "twiceDaily" to "Twice daily",
    "fourTimesDaily" to "4x daily",
)

/// Region override options: id = the stored uppercase code ("" = Auto/device region), label = display name.
/// A common-markets shortlist rather than every ISO country, so the wrap-chip picker stays one-handed.
private val regionOptions: List<Pair<String, String>> = listOf(
    "" to "Auto",
    "US" to "United States",
    "GB" to "United Kingdom",
    "CA" to "Canada",
    "AU" to "Australia",
    "IN" to "India",
    "DE" to "Germany",
    "FR" to "France",
    "ES" to "Spain",
    "IT" to "Italy",
    "BR" to "Brazil",
    "MX" to "Mexico",
    "JP" to "Japan",
    "KR" to "South Korea",
    "NL" to "Netherlands",
)
