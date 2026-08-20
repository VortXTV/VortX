package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.vortx.android.model.TrackPreferencesStore
import com.vortx.android.profile.ProfileStore
import com.vortx.android.sources.SourcePreferencesStore
import com.vortx.android.sources.SourcePreviewModel
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.theme.VortXTheme

/// Smart Source Selection panel: the Android port of Apple `app/SourcesShared/SourceFilterChipsView.swift`.
/// One self-contained block that presents each source criterion as a VISIBLE 3-state chip (Prefer / Only /
/// Avoid), the Avoid-behavior chips, the auto-pick toggle, and a LIVE PREVIEW of what the current chips would
/// surface. It binds through the SAME [SourcePreferencesStore] keys the granular controls below it write, so
/// there is no migration and no new per-criterion state; a chip and its detailed control (where one remains)
/// stay in step because both round-trip through the store.
///
/// Chip -> existing key mapping (verified against [com.vortx.android.engine.StreamRanking]):
///   - Cached = Only ([SourcePreferencesStore.instantOnly]), HDR / DV = Only ([hdrOnly]),
///     My audio = Only ([preferredAudioOnly]), Stated quality = Only ([hideUnknownResolution]).
///   - Dead swarms = Avoid ([hideDeadTorrents]), AV1 = Avoid ([excludeAV1]).
/// CAM / TS and other fake-quality junk stay HARD-hidden by the Safety filter regardless of any chip, which
/// the footnote states plainly. The Prefer / Only / Avoid keyword LANES live in the dedicated "Keywords"
/// section below (the same `preferKeywords` / `includeKeywords` / `excludeKeywords` keys), so they are not
/// duplicated here.
@Composable
internal fun SmartSourceSelectionSection(
    ui: SourcesPrefsUi,
    store: SourcePreferencesStore,
    onMutate: (SourcePreferencesStore.() -> Unit) -> Unit,
) {
    val colors = VortXTheme.colors
    val context = LocalContext.current.applicationContext

    // The live preview reuses the EXACT rank path StreamRanking uses. Its snapshotProvider reads the store at
    // recompute time, so a chip write (which happens BEFORE preview.refresh() below) is reflected. Audio
    // languages + isKids ride the snapshot exactly as DetailViewModel builds it, so the "My audio" chip and a
    // Kids guard preview like the real list.
    val trackPrefs = remember { TrackPreferencesStore(context) }
    val preview = remember {
        SourcePreviewModel(
            snapshotProvider = {
                store.snapshot(
                    audioLanguages = trackPrefs.current.audioLanguages,
                    isKids = ProfileStore.sharedOrNull()?.activeIsKids == true,
                )
            },
        )
    }
    DisposableEffect(Unit) { onDispose { preview.close() } }
    val rows by preview.rows.collectAsState()
    val hiddenCount by preview.hiddenCount.collectAsState()

    // Every chip write goes through the parent's `mutate` (store write + screen re-read) and then nudges the
    // preview to recompute off the new store state.
    fun mutateAndPreview(block: SourcePreferencesStore.() -> Unit) {
        onMutate(block)
        preview.refresh()
    }

    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        Text(
            if (ui.safetyMode == "off") {
                "Tap a chip to require or avoid a kind of source. CAM and fake-quality sources always rank " +
                    "last; turn on the Safety filter below to hide them entirely."
            } else {
                "Tap a chip to require or avoid a kind of source. CAM and fake-quality sources stay hidden by " +
                    "the Safety filter."
            },
            style = VortXTheme.type.label.copy(color = colors.textSecondary),
            modifier = Modifier.padding(horizontal = VortXTheme.spacing.xs),
        )

        // Criterion chips: the boolean prefs shown as visible Only / Avoid chips.
        FlowRow(
            modifier = Modifier.padding(horizontal = VortXTheme.spacing.xs),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            CriterionChip(ChipKind.ONLY, "Cached", ui.instantOnly) {
                mutateAndPreview { instantOnly = !instantOnly }
            }
            CriterionChip(ChipKind.ONLY, "HDR / DV", ui.hdrOnly) {
                mutateAndPreview { hdrOnly = !hdrOnly }
            }
            CriterionChip(ChipKind.ONLY, "My audio", ui.preferredAudioOnly) {
                mutateAndPreview { preferredAudioOnly = !preferredAudioOnly }
            }
            CriterionChip(ChipKind.ONLY, "Stated quality", ui.hideUnknownResolution) {
                mutateAndPreview { hideUnknownResolution = !hideUnknownResolution }
            }
            CriterionChip(ChipKind.AVOID, "Dead swarms", ui.hideDeadTorrents) {
                mutateAndPreview { hideDeadTorrents = !hideDeadTorrents }
            }
            CriterionChip(ChipKind.AVOID, "AV1", ui.excludeAV1) {
                mutateAndPreview { excludeAV1 = !excludeAV1 }
            }
        }

        // Avoid behavior: two chips instead of a segmented picker (matching Apple's shared surfaces).
        Text(
            "WHEN I AVOID A SOURCE",
            style = VortXTheme.type.eyebrow.copy(color = colors.textSecondary),
            modifier = Modifier.padding(horizontal = VortXTheme.spacing.xs),
        )
        FlowRow(
            modifier = Modifier.padding(horizontal = VortXTheme.spacing.xs),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            Chip(
                label = "Hide it",
                selected = ui.avoidBehavior != "rank",
                onClick = { mutateAndPreview { avoidBehavior = "hide" } },
            )
            Chip(
                label = "Rank it down",
                selected = ui.avoidBehavior == "rank",
                onClick = { mutateAndPreview { avoidBehavior = "rank" } },
            )
        }
        Text(
            avoidBehaviorCaption(rankMode = ui.avoidBehavior == "rank", safetyOn = ui.safetyMode != "off"),
            style = VortXTheme.type.label.copy(color = colors.textTertiary),
            modifier = Modifier.padding(horizontal = VortXTheme.spacing.xs),
        )

        // Auto-pick: a plain toggle (Apple renders it as a Toggle, not a chip). Same wording as Apple.
        ToggleRow(
            label = "Auto-pick my best source",
            detail = "Play the top-ranked source straight away instead of opening the source list. Back out " +
                "of the player any time to see the full source list.",
            checked = ui.autoPickBest,
            onCheckedChange = { mutateAndPreview { autoPickBest = it } },
        )

        // Live preview panel.
        PreviewPanel(rows = rows, hiddenCount = hiddenCount)
    }
}

/// Which state a criterion chip represents, for its overline badge.
internal enum class ChipKind { ONLY, AVOID }

/// One labelled criterion chip: a small overline mode badge (ONLY / AVOID) over the shared [Chip], filled
/// when engaged. Mirrors Apple's `chip(_:kind:isOn:toggle:)` overline + glass pill.
@Composable
private fun CriterionChip(kind: ChipKind, name: String, isOn: Boolean, onToggle: () -> Unit) {
    val colors = VortXTheme.colors
    val badge = if (kind == ChipKind.ONLY) "ONLY" else "AVOID"
    val badgeColor = if (kind == ChipKind.ONLY) colors.accent else colors.textSecondary
    Column(horizontalAlignment = Alignment.Start) {
        Text(
            badge,
            style = VortXTheme.type.eyebrow.copy(color = badgeColor, fontWeight = FontWeight.SemiBold),
            modifier = Modifier.padding(start = VortXTheme.spacing.xs, bottom = 2.dp),
        )
        Chip(
            label = name,
            selected = isOn,
            onClick = onToggle,
            stateDescription = if (isOn) "$badge $name on" else "$badge $name off",
        )
    }
}

/// The live preview: a titled area listing the top surfaced sources and a shown/hidden count, so the panel
/// answers "what would these chips actually do?" without opening a title. Mirrors Apple's `previewPanel`.
@Composable
private fun PreviewPanel(rows: List<SourcePreviewModel.Row>, hiddenCount: Int) {
    val colors = VortXTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = VortXTheme.spacing.xs),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("PREVIEW", style = VortXTheme.type.eyebrow.copy(color = colors.textSecondary))
            Text(
                if (hiddenCount > 0) "${rows.size} shown · $hiddenCount hidden" else "${rows.size} shown",
                style = VortXTheme.type.eyebrow.copy(color = colors.textTertiary),
            )
        }
        if (rows.isEmpty()) {
            Text(
                "No sources would show with these settings.",
                style = VortXTheme.type.label.copy(color = colors.textSecondary),
                modifier = Modifier.padding(horizontal = VortXTheme.spacing.xs),
            )
        } else {
            rows.forEach { row ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = VortXTheme.spacing.xs),
                    horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        if (row.isBest) "★" else "•",
                        style = VortXTheme.type.label.copy(
                            color = if (row.isBest) colors.accent else colors.textTertiary,
                            fontWeight = if (row.isBest) FontWeight.Bold else FontWeight.Normal,
                        ),
                    )
                    Column(modifier = Modifier.fillMaxWidth()) {
                        Text(
                            row.qualityLabel,
                            style = VortXTheme.type.label.copy(color = colors.textPrimary),
                        )
                        row.reason?.let { reason ->
                            Text(reason, style = VortXTheme.type.eyebrow.copy(color = colors.textTertiary))
                        }
                    }
                }
            }
        }
        Text(
            "A sample of what the current chips would surface. Your real list uses the sources each title " +
                "actually returns.",
            style = VortXTheme.type.eyebrow.copy(color = colors.textTertiary),
            modifier = Modifier.padding(horizontal = VortXTheme.spacing.xs),
        )
    }
}

/// The Avoid-behavior caption, honest about BOTH the chosen behavior AND whether the Safety filter is on (it
/// defaults to off, so CAM / fake-quality sources are not hidden until the viewer turns it on; they only rank
/// last). Mirrors Apple's `avoidBehaviorCaption`.
private fun avoidBehaviorCaption(rankMode: Boolean, safetyOn: Boolean): String = when {
    rankMode && safetyOn ->
        "Avoided sources stay in the list but sink to the bottom. CAM and fake-quality sources are hidden by " +
            "the Safety filter."
    rankMode && !safetyOn ->
        "Avoided sources stay in the list but sink to the bottom. CAM and fake-quality sources also rank " +
            "last; turn on the Safety filter to hide them."
    !rankMode && safetyOn ->
        "Avoided sources are hidden from the list. CAM and fake-quality sources are hidden by the Safety " +
            "filter."
    else ->
        "Avoided sources are hidden from the list. CAM and fake-quality sources rank last; turn on the " +
            "Safety filter to hide them too."
}
