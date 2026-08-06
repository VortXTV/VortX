package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.ui.components.Chip
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
