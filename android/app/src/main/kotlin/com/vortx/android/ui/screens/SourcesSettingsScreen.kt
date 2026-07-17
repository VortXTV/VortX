package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
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
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import com.vortx.android.sources.SourcePreferencesStore
import com.vortx.android.sources.SourcePreset
import com.vortx.android.sources.SourceType
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import java.util.Locale

/// Settings > Sources: the control surface over [SourcePreferencesStore], the store that decides which
/// streams survive filtering and in what order they rank.
///
/// WHY THIS EXISTS: every preference here was already read by [com.vortx.android.engine.StreamRanking] on
/// every source list, but nothing in `ui/` wrote any of them, so the whole ranking layer sat at its
/// defaults with no way for a viewer to reach it.
///
/// SCOPE RULE (the same one PlaybackSettingsScreen applies): a control ships ONLY when a call site actually
/// consumes the value. Verified against the ranker, not assumed from the setter existing:
///   - typeOrder / useAddonOrder        -> StreamRanking.kt:64, :88, :109, :137, :260, :376
///   - excludeTerms / includeTerms      -> StreamRanking.kt:582, :583 (and :580/:581 in regex mode)
///   - preferTerms / avoidBehavior      -> StreamRanking.kt:377, :378
///   - safetyMode                       -> StreamRanking.kt:587 ("balanced" / "strict")
///   - instantOnly                      -> StreamRanking.kt:594
///   - hideDeadTorrents                 -> StreamRanking.kt:595
///   - excludeAV1 / hdrOnly             -> StreamRanking.kt:599, :600
///   - maxResolution / minResolution    -> StreamRanking.kt:604, :605-607
///   - hideUnknownResolution            -> StreamRanking.kt:609
///   - preferredAudioOnly               -> StreamRanking.kt:612
///   - maxFileSizeGB                    -> StreamRanking.kt:613-615
///
/// DELIBERATELY NOT SURFACED, because nothing consumes them (a control over them would write a preference
/// that changes nothing a viewer can observe, which is the defect this whole round removes):
///   - `autoPickBest` (SourcePreferences.kt:226): it rides the snapshot (:347) and the cache tag (:114), but
///     NO call site reads `prefs.autoPickBest` to auto-pick anything. It lands with the source-picker
///     behavior that would honour it.
///   - `defaultSourceSort` (SourcePreferences.kt:274): read by nothing at all in any source set. It lands
///     with the Sources-list sort control that would remember it.
///
/// A change here takes effect on the NEXT source list, with no restart: `EngineStremioRepository` builds a
/// FRESH snapshot off this store and installs it on every load (EngineStremioRepository.kt:550-551), and the
/// order/prefer/avoid setters additionally drop the memoized ranking scores.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SourcesSettingsScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    val appContext = LocalContext.current.applicationContext
    val store = remember { SourcePreferencesStore(appContext) }

    // ONE snapshot of the store drives the whole screen, and every write re-reads it. This is deliberate
    // over ~15 independent state vars: `apply(preset)` mutates six fields at once, and `moveType` rewrites
    // the order, so per-field state would drift out of step with the store the moment a preset is tapped.
    // Re-reading is cheap (SharedPreferences serves an in-memory map, and `apply()` updates that map before
    // it returns), so the screen can never show a value the ranker will not use.
    var ui by remember { mutableStateOf(readPrefs(store)) }
    fun mutate(block: SourcePreferencesStore.() -> Unit) {
        store.block()
        ui = readPrefs(store)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Sources", style = VortXTheme.type.cardTitle) },
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
                title = "Quick setup",
                footer = "A preset rewrites the source order and the quality caps below. Your keyword " +
                    "filters and safety mode are yours and are left alone.",
            ) {
                // Presets are an ACTION, not a stored choice: SourcePreferencesStore has no "current preset"
                // (Apple's `apply(_:)` writes fields and keeps no tag), and after any single edit below the
                // state no longer equals a preset. Rendering them as chips with no selected state says that
                // honestly; a radio group would imply a persistent selection that does not exist.
                SourcePreset.entries.forEach { preset ->
                    OptionRow(
                        label = preset.label,
                        detail = preset.detail,
                        selected = false,
                        onClick = { mutate { apply(preset) } },
                    )
                }
            }

            SettingsSection(
                title = "Source order",
                footer = "Sources are grouped strongest-first in this order. Turn on \"Use add-on order\" to " +
                    "keep whatever order your add-ons return instead.",
            ) {
                ToggleRow(
                    label = "Use add-on order",
                    detail = "Skip VortX ranking and show sources exactly as your add-ons list them.",
                    checked = ui.useAddonOrder,
                    onCheckedChange = { value -> mutate { useAddonOrder = value } },
                )
                // The order list is disabled-looking but still shown when add-on order wins, rather than
                // hidden: a viewer needs to see the order they will get back when they turn the toggle off.
                ui.typeOrder.forEachIndexed { index, type ->
                    ReorderRow(
                        label = type.label,
                        detail = type.detail,
                        position = index + 1,
                        enabled = !ui.useAddonOrder,
                        canMoveUp = index > 0,
                        canMoveDown = index < ui.typeOrder.lastIndex,
                        onUp = { mutate { moveType(index, -1) } },
                        onDown = { mutate { moveType(index, +1) } },
                    )
                }
            }

            SettingsSection(
                title = "Quality",
                footer = "Caps and floors apply only to sources that ADVERTISE a resolution. A source that " +
                    "does not say is kept, unless you hide unlabelled sources below.",
            ) {
                PickerRow(
                    label = "Highest resolution",
                    options = maxResolutionOptions,
                    selectedId = ui.maxResolution.toString(),
                    onSelect = { id -> mutate { maxResolution = id.toInt() } },
                )
                PickerRow(
                    label = "Lowest resolution",
                    options = minResolutionOptions,
                    selectedId = ui.minResolution.toString(),
                    onSelect = { id -> mutate { minResolution = id.toInt() } },
                )
                PickerRow(
                    label = "Largest file",
                    options = fileSizeOptions,
                    selectedId = formatSizeId(ui.maxFileSizeGB),
                    onSelect = { id -> mutate { maxFileSizeGB = id.toDouble() } },
                )
                ToggleRow(
                    label = "HDR only",
                    detail = "Keep only HDR, HDR10+ or Dolby Vision sources.",
                    checked = ui.hdrOnly,
                    onCheckedChange = { value -> mutate { hdrOnly = value } },
                )
                ToggleRow(
                    label = "Hide AV1",
                    detail = "AV1 has no hardware decode on many devices, so it can stutter.",
                    checked = ui.excludeAV1,
                    onCheckedChange = { value -> mutate { excludeAV1 = value } },
                )
                ToggleRow(
                    label = "Hide unlabelled resolutions",
                    detail = "Hide sources that do not advertise a resolution at all.",
                    checked = ui.hideUnknownResolution,
                    onCheckedChange = { value -> mutate { hideUnknownResolution = value } },
                )
            }

            SettingsSection(
                title = "Availability",
                footer = "Instant sources start immediately: a cached debrid file, a direct link, or your " +
                    "own media server.",
            ) {
                ToggleRow(
                    label = "Instant only",
                    detail = "Hide anything that would need to download first.",
                    checked = ui.instantOnly,
                    onCheckedChange = { value -> mutate { instantOnly = value } },
                )
                ToggleRow(
                    label = "Hide dead torrents",
                    detail = "Hide torrents with no seeders.",
                    checked = ui.hideDeadTorrents,
                    onCheckedChange = { value -> mutate { hideDeadTorrents = value } },
                )
                ToggleRow(
                    label = "My audio languages only",
                    detail = "Hide sources that do not carry one of your Playback audio languages.",
                    checked = ui.preferredAudioOnly,
                    onCheckedChange = { value -> mutate { preferredAudioOnly = value } },
                )
            }

            SettingsSection(
                title = "Safety",
                footer = "Filters out obvious junk: mislabelled files, and sizes that cannot really hold " +
                    "the resolution they claim.",
            ) {
                safetyOptions.forEach { (id, copy) ->
                    val (label, detail) = copy
                    OptionRow(
                        label = label,
                        detail = detail,
                        selected = id == ui.safetyMode,
                        onClick = { mutate { safetyMode = id } },
                    )
                }
            }

            SettingsSection(
                title = "Keywords",
                footer = "Comma-separated, and case does not matter. Matching is on the source's whole " +
                    "title line.",
            ) {
                KeywordField(
                    label = "Exclude",
                    placeholder = "cam, ts, hdcam",
                    value = ui.excludeKeywords,
                    onValueChange = { value -> mutate { excludeKeywords = value } },
                )
                KeywordField(
                    label = "Only show if it contains",
                    placeholder = "remux, bluray",
                    value = ui.includeKeywords,
                    onValueChange = { value -> mutate { includeKeywords = value } },
                )
                KeywordField(
                    label = "Prefer",
                    placeholder = "atmos, hdr",
                    value = ui.preferKeywords,
                    onValueChange = { value -> mutate { preferKeywords = value } },
                )
                ToggleRow(
                    label = "Treat these as regular expressions",
                    // Fail-open is worth saying out loud: SourcePreferences.compilePattern returns null on an
                    // invalid pattern, so a typo applies NO filter rather than hiding every source. A viewer
                    // who is told this can tell "my regex is wrong" from "the filter is broken".
                    detail = "An invalid expression is ignored rather than hiding everything.",
                    checked = ui.keywordsAreRegex,
                    onCheckedChange = { value -> mutate { keywordsAreRegex = value } },
                )
            }

            SettingsSection(
                title = "Excluded sources",
                footer = "What happens to a source that matches your Exclude list.",
            ) {
                avoidOptions.forEach { (id, copy) ->
                    val (label, detail) = copy
                    OptionRow(
                        label = label,
                        detail = detail,
                        selected = id == ui.avoidBehavior,
                        onClick = { mutate { avoidBehavior = id } },
                    )
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------------
// Store snapshot
// ---------------------------------------------------------------------------------------------------

/// An immutable read of every preference this screen drives. Mirrors the store field-for-field so a
/// re-read after any write is the single way the UI learns what changed.
private data class SourcesPrefsUi(
    val typeOrder: List<SourceType>,
    val useAddonOrder: Boolean,
    val excludeKeywords: String,
    val includeKeywords: String,
    val preferKeywords: String,
    val keywordsAreRegex: Boolean,
    val avoidBehavior: String,
    val safetyMode: String,
    val instantOnly: Boolean,
    val hideDeadTorrents: Boolean,
    val hdrOnly: Boolean,
    val excludeAV1: Boolean,
    val hideUnknownResolution: Boolean,
    val preferredAudioOnly: Boolean,
    val maxResolution: Int,
    val minResolution: Int,
    val maxFileSizeGB: Double,
)

private fun readPrefs(store: SourcePreferencesStore) = SourcesPrefsUi(
    typeOrder = store.typeOrder,
    useAddonOrder = store.useAddonOrder,
    excludeKeywords = store.excludeKeywords,
    includeKeywords = store.includeKeywords,
    preferKeywords = store.preferKeywords,
    keywordsAreRegex = store.keywordsAreRegex,
    avoidBehavior = store.avoidBehavior,
    safetyMode = store.safetyMode,
    instantOnly = store.instantOnly,
    hideDeadTorrents = store.hideDeadTorrents,
    hdrOnly = store.hdrOnly,
    excludeAV1 = store.excludeAV1,
    hideUnknownResolution = store.hideUnknownResolution,
    preferredAudioOnly = store.preferredAudioOnly,
    maxResolution = store.maxResolution,
    minResolution = store.minResolution,
    maxFileSizeGB = store.maxFileSizeGB,
)

// ---------------------------------------------------------------------------------------------------
// Option tables
// ---------------------------------------------------------------------------------------------------

/// Resolution ids are the ENGINE's internal scale, not the marketing number, and the difference is
/// load-bearing: StreamRanking.explicitResolution (StreamRanking.kt:992) maps the token "2160" to the VALUE
/// 4000, and knownResolution (:1001) maps "4k"/"uhd" to 4000 as well. So 4K is 4000 on this scale, and a
/// "4K" cap that stored 2160 would make `resolution(text) > maxResolution` true for EVERY 4K source and
/// silently hide all of them. 1440 and below are their own numbers. `0` is Apple's "no cap" sentinel
/// (StreamRanking.kt:604 gates on `> 0`), and the Data Saver preset's `maxResolution = 1080`
/// (SourcePreferences.kt:316) confirms the scale.
private val maxResolutionOptions: List<Pair<String, String>> = listOf(
    "0" to "No cap",
    "720" to "720p",
    "1080" to "1080p",
    "1440" to "1440p",
    "4000" to "4K",
)

/// The floor. Same scale as the cap above. StreamRanking.kt:605-607 only rejects a source whose resolution
/// is KNOWN and below the floor, so an unlabelled source still passes (#117).
private val minResolutionOptions: List<Pair<String, String>> = listOf(
    "0" to "No floor",
    "720" to "720p+",
    "1080" to "1080p+",
    "1440" to "1440p+",
    "4000" to "4K",
)

/// Size ids are plain GB doubles; `0` is the no-cap sentinel (StreamRanking.kt:613 gates on `> 0`). The 4 GB
/// and 15 GB entries are the Data Saver and Balanced preset values (SourcePreferences.kt:313-316) so the
/// preset a viewer taps shows up as a selected chip here rather than as an unexplained custom value.
private val fileSizeOptions: List<Pair<String, String>> = listOf(
    "0.0" to "No cap",
    "4.0" to "4 GB",
    "8.0" to "8 GB",
    "15.0" to "15 GB",
    "30.0" to "30 GB",
    "60.0" to "60 GB",
)

/// A stored size is a Float widened to Double (SourcePreferences.kt:261), so an exact `==` against a literal
/// is not reliable; match on the same one-decimal rendering the ids use. A value with no chip (say a 12.5 GB
/// cap synced from another platform) simply selects nothing rather than snapping the viewer's choice to a
/// neighbour.
///
/// [Locale.ROOT] is REQUIRED, not tidiness: the ids above are literals like "4.0", but a default-locale
/// format on a device set to (say) German renders 4.0 as "4,0", which would match no id, so the viewer's own
/// saved cap would show as unselected on every locale that uses a decimal comma.
private fun formatSizeId(gb: Double): String = String.format(Locale.ROOT, "%.1f", gb)

/// Ids are the exact strings StreamRanking.kt:587-590 branches on. Anything else falls to its `else`, which
/// is why "off" is spelled as a real option rather than left implicit.
private val safetyOptions: List<Pair<String, Pair<String, String>>> = listOf(
    "off" to ("Off" to "Show every source."),
    "balanced" to ("Balanced" to "Hide obvious junk: cams, mislabelled files."),
    "strict" to ("Strict" to "Also hide sources whose size cannot hold the resolution they claim."),
)

/// Ids are the exact strings StreamRanking.kt:378/:577 branches on: "rank" demotes, anything else hides.
private val avoidOptions: List<Pair<String, Pair<String, String>>> = listOf(
    "hide" to ("Hide them" to "Excluded sources do not appear at all."),
    "rank" to ("Just rank them lower" to "Excluded sources still appear, at the bottom."),
)

// ---------------------------------------------------------------------------------------------------
// Local building blocks
// ---------------------------------------------------------------------------------------------------

/// One source type in the order list, with its position and up/down affordances. Local to this screen: the
/// shared controls cover pick/toggle/step, and nothing else reorders a list.
@Composable
private fun ReorderRow(
    label: String,
    detail: String,
    position: Int,
    enabled: Boolean,
    canMoveUp: Boolean,
    canMoveDown: Boolean,
    onUp: () -> Unit,
    onDown: () -> Unit,
) {
    val colors = VortXTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "$position",
            style = VortXTheme.type.cardTitle.copy(
                color = if (enabled) colors.accent else colors.textTertiary,
            ),
        )
        Column(modifier = Modifier.fillMaxWidth(0.72f)) {
            Text(
                label,
                style = VortXTheme.type.body.copy(
                    color = if (enabled) colors.textPrimary else colors.textTertiary,
                ),
            )
            Text(detail, style = VortXTheme.type.label.copy(color = colors.textTertiary))
        }
        // contentDescription carries the row's own label, so a screen reader announces "Move Debrid up"
        // rather than four identical "Move up" buttons.
        IconButton(onClick = onUp, enabled = enabled && canMoveUp) {
            Icon(
                VortXIcons.chevronUp,
                contentDescription = "Move $label up",
                tint = if (enabled && canMoveUp) colors.textSecondary else colors.textTertiary,
            )
        }
        IconButton(onClick = onDown, enabled = enabled && canMoveDown) {
            Icon(
                VortXIcons.chevronDown,
                contentDescription = "Move $label down",
                tint = if (enabled && canMoveDown) colors.textSecondary else colors.textTertiary,
            )
        }
    }
}

/// A comma-separated keyword field. Writes through on every keystroke rather than on a Done/blur: there is
/// no commit affordance in this design, so a viewer who types a term and taps Back must still keep it.
/// The value round-trips through the store (which serves it back from its in-memory map), so the field
/// shows exactly what was stored and the caret does not jump.
@Composable
private fun KeywordField(
    label: String,
    placeholder: String,
    value: String,
    onValueChange: (String) -> Unit,
) {
    val colors = VortXTheme.colors
    Column(
        modifier = Modifier.padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
    ) {
        Text(label, style = VortXTheme.type.label.copy(color = colors.textSecondary))
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            placeholder = {
                Text(placeholder, style = VortXTheme.type.label.copy(color = colors.textTertiary))
            },
            // No autocapitalise/autocorrect: these are match terms, not prose, and a capitalised or
            // "corrected" term is a term that silently stops matching.
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
                imeAction = ImeAction.Done,
            ),
        )
    }
}
