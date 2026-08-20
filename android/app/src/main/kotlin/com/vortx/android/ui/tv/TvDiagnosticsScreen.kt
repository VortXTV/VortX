package com.vortx.android.ui.tv

import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import com.vortx.android.BuildConfig
import com.vortx.android.player.MpvEngineFactory
import com.vortx.android.player.PerformanceMode
import com.vortx.android.profile.ProfileStore
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

/// The 10-foot Diagnostics surface: a read-only snapshot of what a support-facing tester needs to read off a
/// TV from the couch. It is the Android TV analogue of the "About" info rows in Apple
/// `app/SourcesTV/SettingsView.swift` (Version / Player / Server) plus the device facts. It writes NOTHING and
/// owns no preference key, so it can never disagree with the app or move a setting; every row is a live read of
/// [BuildConfig], [android.os.Build], the active profile, the resolved performance tier, and which player
/// engine is bundled. Each row is a focusable tv-Surface only so the D-pad can move down the list and scroll
/// it, exactly like the settings rows; selecting a row does nothing.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
internal fun TvDiagnosticsScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    BackHandler { onBack() }
    val appContext = LocalContext.current.applicationContext
    val backFocus = remember { FocusRequester() }

    val rows = remember(appContext) {
        val activeProfile = ProfileStore.sharedOrNull()?.active
        val performance = PerformanceMode.currentOverride(appContext)
        listOf(
            "App version" to BuildConfig.VERSION_NAME,
            "Build" to BuildConfig.VERSION_CODE.toString(),
            "Edition" to BuildConfig.FLAVOR + if (BuildConfig.DEBUG) " (debug)" else "",
            "Package" to BuildConfig.APPLICATION_ID,
            "Player engine" to if (MpvEngineFactory.isBundled) "libmpv (bundled)" else "external",
            "Performance mode" to (performance.label),
            "Constrained device" to if (PerformanceMode.isConstrainedDevice(appContext)) "yes" else "no",
            "Device" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "Android" to "${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
            "Active profile" to (activeProfile?.name ?: "Default"),
        )
    }

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(TvDimens.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        item { TvBackupBackButton(onClick = onBack, focusRequester = backFocus) }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
                Text("Diagnostics", style = VortXTheme.type.sectionTitle)
                Text(
                    "A read-only snapshot of this TV and build. Nothing here changes a setting.",
                    style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
                )
            }
        }
        rows.forEach { (label, value) ->
            item { TvDiagnosticRow(label = label, value = value) }
        }
    }

    LaunchedEffect(Unit) {
        runCatching { backFocus.requestFocus() }
    }
}

/// One read-only diagnostic row: a label with its live value, on a focusable tv-Surface so the D-pad can walk
/// and scroll the list. Selecting it is a no-op; the focus ring is the only affordance.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvDiagnosticRow(label: String, value: String) {
    val colors = VortXTheme.colors
    Surface(
        onClick = {},
        modifier = Modifier.fillMaxWidth(),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = colors.surface1,
            contentColor = colors.textPrimary,
            focusedContainerColor = colors.surface3,
            focusedContentColor = colors.textPrimary,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, colors.accentBright),
                shape = VortXShapes.control,
            ),
        ),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = label,
                style = VortXTheme.type.body.copy(fontWeight = FontWeight.SemiBold),
                modifier = Modifier.width(260.dp),
            )
            Spacer(Modifier.width(VortXTheme.spacing.md))
            Text(
                text = value,
                style = VortXTheme.type.body.copy(color = colors.textSecondary),
            )
        }
    }
}
