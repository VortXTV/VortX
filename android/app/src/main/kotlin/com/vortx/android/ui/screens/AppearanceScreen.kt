package com.vortx.android.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.prefs.AppLanguage
import com.vortx.android.ui.prefs.AppearancePrefs
import com.vortx.android.ui.theme.VortXAccents
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppearanceScreen(
    prefs: AppearancePrefs,
    onCustomizeHome: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val appearance by prefs.state.collectAsStateWithLifecycle()
    val percent = (appearance.textScale * 100).roundToInt()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Appearance", style = VortXTheme.type.cardTitle) },
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
                title = "Accent",
                footer = "Changes apply immediately to selection, focus, progress, and primary actions.",
            ) {
                FlowRow(
                    modifier = Modifier.padding(VortXTheme.spacing.sm),
                    horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
                    verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
                ) {
                    VortXAccents.curated.forEach { accent ->
                        Chip(
                            label = accent.label,
                            selected = appearance.accentId == accent.id,
                            onClick = { prefs.setAccent(accent.id) },
                            modifier = Modifier.heightIn(min = 48.dp),
                            accent = accent.base,
                            accentText = accent.bright,
                        )
                    }
                }
            }

            SettingsSection(
                title = "Background",
                footer = "OLED Black uses true black for the canvas and neutral dark surfaces.",
            ) {
                ToggleRow(
                    label = "OLED Black",
                    detail = null,
                    checked = appearance.oled,
                    onCheckedChange = prefs::setOled,
                )
            }

            SettingsSection(
                title = "Text size",
                footer = "Scales app text from 80 to 140 percent while preserving the device accessibility setting.",
            ) {
                FlowRow(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(VortXTheme.spacing.sm),
                    horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                    verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
                ) {
                    OutlinedButton(
                        enabled = appearance.textScale > AppearancePrefs.TEXT_SCALE_MIN,
                        onClick = {
                            prefs.setTextScale(
                                appearance.textScale - AppearancePrefs.TEXT_SCALE_STEP,
                            )
                        },
                        modifier = Modifier
                            .heightIn(min = 48.dp)
                            .semantics {
                                contentDescription = "Smaller, decrease app text size"
                            },
                        colors = ButtonDefaults.outlinedButtonColors(
                            contentColor = VortXTheme.colors.accent,
                        ),
                    ) {
                        Text("Smaller")
                    }
                    Text(
                        text = "$percent%",
                        style = VortXTheme.type.cardTitle,
                        modifier = Modifier
                            .heightIn(min = 48.dp)
                            .padding(vertical = VortXTheme.spacing.sm)
                            .semantics {
                                contentDescription = "Text size"
                                stateDescription = "$percent percent"
                                liveRegion = LiveRegionMode.Polite
                            },
                    )
                    OutlinedButton(
                        enabled = appearance.textScale < AppearancePrefs.TEXT_SCALE_MAX,
                        onClick = {
                            prefs.setTextScale(
                                appearance.textScale + AppearancePrefs.TEXT_SCALE_STEP,
                            )
                        },
                        modifier = Modifier
                            .heightIn(min = 48.dp)
                            .semantics {
                                contentDescription = "Larger, increase app text size"
                            },
                        colors = ButtonDefaults.outlinedButtonColors(
                            contentColor = VortXTheme.colors.accent,
                        ),
                    ) {
                        Text("Larger")
                    }
                }
            }

            LanguageSection()

            SettingsSection(
                title = "Home",
                footer = "Continue Watching stays first. Every other Home row can be reordered or hidden.",
            ) {
                OutlinedButton(
                    onClick = onCustomizeHome,
                    modifier = Modifier.fillMaxWidth().padding(VortXTheme.spacing.sm),
                ) {
                    Icon(VortXIcons.listBullet, contentDescription = null)
                    Text(
                        "Customize Home",
                        modifier = Modifier.padding(start = VortXTheme.spacing.sm),
                    )
                }
            }
        }
    }
}

/// App-language override (SET-6, Apple `AppLanguage` / iOSSettingsView.swift:510). One row showing the
/// current pick that opens a scrollable dialog of the curated autonym roster plus "System default". The
/// choice persists on the exact key `stremiox.languageOverride` and, on Android 13+, re-localizes the app
/// via the framework per-app locale; on older OSes it is stored for cross-device sync (see [AppLanguage]).
@Composable
private fun LanguageSection() {
    val context = LocalContext.current
    var dialogOpen by remember { mutableStateOf(false) }
    var code by remember { mutableStateOf(AppLanguage.current(context)) }

    val currentLabel = code?.let { AppLanguage.name(it) } ?: "System default"
    val footer = if (AppLanguage.canApply) {
        "Pin the app to a language instead of following your device. Takes effect as you return to the app."
    } else {
        "Pin the app to a language. On this Android version the choice is saved and syncs to your other " +
            "devices; the running app keeps the system language."
    }

    SettingsSection(title = "Language", footer = footer) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { dialogOpen = true }
                .padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text("App language", style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary))
            Text(currentLabel, style = VortXTheme.type.label.copy(color = VortXTheme.colors.accent))
        }
    }

    if (dialogOpen) {
        AlertDialog(
            onDismissRequest = { dialogOpen = false },
            confirmButton = {
                TextButton(onClick = { dialogOpen = false }) { Text("Close") }
            },
            title = { Text("App language", style = VortXTheme.type.cardTitle) },
            text = {
                LazyColumn(modifier = Modifier.heightIn(max = 420.dp)) {
                    item {
                        OptionRow(
                            label = "System default",
                            detail = null,
                            selected = code == null,
                            onClick = {
                                AppLanguage.set(context, null)
                                code = null
                                dialogOpen = false
                            },
                        )
                    }
                    items(AppLanguage.supported) { (languageCode, name) ->
                        OptionRow(
                            label = name,
                            detail = null,
                            selected = code == languageCode,
                            onClick = {
                                AppLanguage.set(context, languageCode)
                                code = languageCode
                                dialogOpen = false
                            },
                        )
                    }
                }
            },
        )
    }
}
