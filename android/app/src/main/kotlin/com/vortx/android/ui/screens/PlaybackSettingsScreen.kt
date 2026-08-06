package com.vortx.android.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.vortx.android.model.LanguagePriority
import com.vortx.android.model.TrackPreferences
import com.vortx.android.model.TrackPreferencesStore
import com.vortx.android.model.VideoUpscaling
import com.vortx.android.player.AudioOutputMode
import com.vortx.android.player.AutoAddLibrarySetting
import com.vortx.android.player.DiskCacheSetting
import com.vortx.android.player.PlaybackBehaviorSettings
import com.vortx.android.player.PerformanceMode
import com.vortx.android.player.SubtitleStyle
import com.vortx.android.skip.SkipConfig
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import kotlin.math.roundToInt

/// Settings > Playback: the device-scoped player preferences, the Android port of the Apple
/// `iOSSettingsView` playback/subtitle/track sections (iOSSettingsView.swift:535-545, 1221, 1246-1269,
/// 1353-1380).
///
/// SCOPE, and why it is not the whole Apple section: every control here drives a preference that an engine
/// ACTUALLY reads, verified against the engine call sites rather than assumed from the model existing.
///   - Audio output      -> MpvPlayer.kt:103 (pre-init) + :200 (live). ExoPlayer auto-negotiates, so its
///                          `setAudioOutputMode` is a documented no-op; the row says so rather than lying.
///   - Streaming cache   -> MpvConfig.kt:142 + MpvPlayer.kt:136.
///   - Performance       -> MpvPlayer.kt:134 (PerformanceMode.isReduced).
///   - Subtitle style    -> MpvPlayer.kt:100/:191 AND ExoPlayerEngine.kt:264. The only one live on BOTH.
///   - Audio/subtitle languages + forced policy -> TrackSelector via PlayerScreen.kt:137.
///   - Skip segments     -> SkipTimestampService.kt:55 (the crowd-provider branch), reached from the live
///                          skip read path at PlayerScreen.kt:163.
///   - Auto-add to Library -> StremioXApp.kt's 60s playback tick (LibraryAutoAdd.addIfNeeded `enabled`).
///                          Apple offers this on BOTH its settings surfaces (iOSSettingsView.swift:594,
///                          SourcesTV/SettingsView.swift:92); Android read the key but shipped no control,
///                          so the behaviour was pinned to its default and could not be turned off.
///
/// SkipDBClient (the SUBMIT client) is deliberately NOT driven from here: `submit` needs an imdb id, a
/// segment type and start/end times, which only exist while a title is playing, so its natural entry point
/// is the in-player segment editor (PlayerScreen.kt:163 notes it as a later round), not a settings toggle.
/// The provider picker below configures the READ path it shares, which is the part that IS settings-shaped.
///
/// Settings changes take effect on the NEXT load: every engine reads these at load time. (MpvPlayer's
/// `applySubtitleStyle`/`setAudioOutputMode` exist for the in-player controls, which are a separate surface.)
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlaybackSettingsScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    val appContext = LocalContext.current.applicationContext

    // The store is the source of truth; Compose state seeds from it once and writes through on every
    // change. There is no reactive SharedPreferences stream in this module and none is needed: these are
    // device-scoped values read at player load, so a write-through keeps the UI and the engine in step.
    // The constrained-device flag is injected exactly as PlayerScreen.kt:138 does, so the Anime4K guard
    // and the hardware-aware upscaling default behave identically to the playback path.
    val trackStore = remember {
        TrackPreferencesStore(appContext, PerformanceMode.isConstrainedDevice(appContext))
    }

    var audioMode by remember { mutableStateOf(AudioOutputMode.current(appContext)) }
    var cacheBytes by remember { mutableStateOf(DiskCacheSetting.storedBytes(appContext)) }
    var perfOverride by remember { mutableStateOf(PerformanceMode.currentOverride(appContext)) }
    var subtitleStyle by remember { mutableStateOf(SubtitleStyle.current(appContext)) }
    var trackPrefs by remember { mutableStateOf(trackStore.current) }
    var subtitlesOnlyPreferred by remember { mutableStateOf(trackStore.subtitlesOnlyPreferred) }
    var videoUpscaling by remember { mutableStateOf(trackStore.videoUpscaling) }
    var autoSkip by remember { mutableStateOf(PlaybackBehaviorSettings.autoSkip(appContext)) }
    var autoAddLibrary by remember { mutableStateOf(AutoAddLibrarySetting.isEnabled(appContext)) }

    var skipProvider by remember {
        // SkipConfig.init MUST run before the first read/write here. SkipConfig holds its SharedPreferences
        // lazily and EVERY accessor is null-safe against it (`prefs?.edit()` / `prefs?.getString(...)`), so a
        // setProvider before init would silently write NOTHING and the picker would report a value it never
        // stored -- the same class of lie as the hardcoded rows this screen replaces. SkipTimestampService.init
        // (SkipTimestampService.kt:34) also calls it, but only on the playback path, which a viewer who opens
        // Settings before playing anything has not reached. init is idempotent and network-free.
        SkipConfig.init(appContext)
        mutableStateOf(SkipConfig.provider)
    }

    fun updateSubtitles(next: SubtitleStyle) {
        subtitleStyle = next
        SubtitleStyle.save(appContext, next)
    }

    fun updateTracks(next: TrackPreferences) {
        trackPrefs = next
        trackStore.save(next)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Playback", style = VortXTheme.type.cardTitle) },
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
                title = "Audio output",
                footer = "Applies to the built-in libmpv player. On the ExoPlayer path Android negotiates " +
                    "the channel layout with your TV or receiver itself, so this has no effect there.",
            ) {
                AudioOutputMode.entries.forEach { mode ->
                    OptionRow(
                        label = mode.label,
                        detail = mode.detail,
                        selected = mode == audioMode,
                        onClick = {
                            audioMode = mode
                            AudioOutputMode.setCurrent(appContext, mode)
                        },
                    )
                }
            }

            SettingsSection(
                title = "Subtitle style",
                footer = "Styles the built-in player's subtitles. Pick which subtitle track to show from " +
                    "the player while watching.",
            ) {
                SubtitlePreview(style = subtitleStyle)
                PickerRow(
                    label = "Font",
                    options = SubtitleStyle.fonts,
                    selectedId = subtitleStyle.fontId,
                    onSelect = { updateSubtitles(subtitleStyle.copy(fontId = it)) },
                )
                PickerRow(
                    label = "Size",
                    options = SubtitleStyle.sizes,
                    selectedId = subtitleStyle.sizeId,
                    onSelect = { updateSubtitles(subtitleStyle.copy(sizeId = it)) },
                )
                StepperRow(
                    // Apple renders this as "Fine size  ·  N%" (iOSSettingsView.swift:1367).
                    label = "Fine size  ·  ${(subtitleStyle.sizeScale * 100).roundToInt()}%",
                    canDecrease = subtitleStyle.sizeScale > SubtitleStyle.SIZE_SCALE_RANGE.start,
                    canIncrease = subtitleStyle.sizeScale < SubtitleStyle.SIZE_SCALE_RANGE.endInclusive,
                    // SubtitleStyle.save clamps and rounds, so the stepper cannot walk out of range or
                    // accumulate binary-float drift across taps.
                    onDecrease = {
                        updateSubtitles(subtitleStyle.copy(sizeScale = subtitleStyle.sizeScale - SubtitleStyle.SIZE_SCALE_STEP))
                        subtitleStyle = SubtitleStyle.current(appContext)
                    },
                    onIncrease = {
                        updateSubtitles(subtitleStyle.copy(sizeScale = subtitleStyle.sizeScale + SubtitleStyle.SIZE_SCALE_STEP))
                        subtitleStyle = SubtitleStyle.current(appContext)
                    },
                )
                PickerRow(
                    label = "Color",
                    options = SubtitleStyle.colors,
                    selectedId = subtitleStyle.colorId,
                    onSelect = { updateSubtitles(subtitleStyle.copy(colorId = it)) },
                )
                PickerRow(
                    label = "Brightness",
                    options = SubtitleStyle.brightnessLevels.map { it.id to it.label },
                    selectedId = subtitleStyle.brightnessId,
                    onSelect = { updateSubtitles(subtitleStyle.copy(brightnessId = it)) },
                )
                PickerRow(
                    label = "Background",
                    options = SubtitleStyle.backgrounds,
                    selectedId = subtitleStyle.backgroundId,
                    onSelect = { updateSubtitles(subtitleStyle.copy(backgroundId = it)) },
                )
            }

            SettingsSection(
                title = "Audio & subtitle languages",
                footer = "The player tries every language in order. Add as many as you need, then move " +
                    "them earlier or later to set priority.",
            ) {
                LanguagePriorityEditor(
                    label = "Audio",
                    languages = trackPrefs.audioLanguages,
                    onChange = { updateTracks(trackPrefs.copy(audioLanguages = it)) },
                )
                LanguagePriorityEditor(
                    label = "Subtitle",
                    languages = trackPrefs.subtitleLanguages,
                    onChange = { updateTracks(trackPrefs.copy(subtitleLanguages = it)) },
                )
                ToggleRow(
                    label = "Only preferred external subtitles",
                    detail = "Keep embedded file tracks, but limit add-on subtitles to the languages above.",
                    checked = subtitlesOnlyPreferred,
                    onCheckedChange = {
                        subtitlesOnlyPreferred = it
                        trackStore.subtitlesOnlyPreferred = it
                    },
                )
            }

            SettingsSection(
                title = "Subtitles when you got your audio language",
                footer = "Forced-only shows just the foreign-dialogue captions. This is what most viewers want.",
            ) {
                TrackPreferences.ForcedPolicy.entries.forEach { policy ->
                    OptionRow(
                        label = policy.label,
                        detail = null,
                        selected = policy == trackPrefs.forcedPolicy,
                        onClick = { updateTracks(trackPrefs.copy(forcedPolicy = policy)) },
                    )
                }
            }

            SettingsSection(
                title = "Video quality",
                footer = "Applied by the built-in libmpv player on the next load. Anime4K is not implemented " +
                    "on Android; it requires both packaged shaders and application wiring.",
            ) {
                VideoUpscaling.androidChoices.forEach { preset ->
                    OptionRow(
                        label = preset.label,
                        detail = preset.detail,
                        selected = preset == videoUpscaling,
                        onClick = {
                            videoUpscaling = preset
                            trackStore.videoUpscaling = preset
                        },
                    )
                }
            }

            SettingsSection(
                title = "Skip segments",
                footer = "Which community database to ask for intro and recap timings. VortX's own database " +
                    "is always used and needs no setting; this picks what is asked ON TOP of it.",
            ) {
                skipProviderOptions.forEach { (id, copy) ->
                    val (label, detail) = copy
                    OptionRow(
                        label = label,
                        detail = detail,
                        selected = id == skipProvider,
                        onClick = {
                            skipProvider = id
                            SkipConfig.setProvider(id)
                        },
                    )
                }
                ToggleRow(
                    label = "Skip automatically",
                    detail = "Automatically jump past each detected intro, recap, credits, or preview once.",
                    checked = autoSkip,
                    onCheckedChange = {
                        autoSkip = it
                        PlaybackBehaviorSettings.setAutoSkip(appContext, it)
                    },
                )
            }

            SettingsSection(
                title = "Library",
                footer = "Adds a title to your Library once about a minute of it has played, so the things " +
                    "you actually watch collect themselves. A title you remove by hand stays removed.",
            ) {
                ToggleRow(
                    label = "Auto-add watched to Library",
                    detail = null,
                    checked = autoAddLibrary,
                    onCheckedChange = {
                        autoAddLibrary = it
                        AutoAddLibrarySetting.setEnabled(appContext, it)
                    },
                )
            }

            SettingsSection(
                title = "Streaming cache",
                footer = "Moves the player's forward buffer to disk so a big buffer costs no memory. Any " +
                    "size is still capped against current free space, and the cache is wiped when playback " +
                    "ends. Off by default.",
            ) {
                DiskCacheSetting.pickerOptions.forEach { (bytes, label) ->
                    OptionRow(
                        label = label,
                        detail = null,
                        selected = bytes == cacheBytes,
                        onClick = {
                            cacheBytes = bytes
                            DiskCacheSetting.setStoredBytes(appContext, bytes)
                        },
                    )
                }
            }

            SettingsSection(
                title = "Performance",
                footer = performanceFooter(
                    constrained = PerformanceMode.isConstrainedDevice(appContext),
                    reduced = PerformanceMode.isReduced(appContext),
                ),
            ) {
                PerformanceMode.Override.entries.forEach { option ->
                    OptionRow(
                        label = option.label,
                        detail = null,
                        selected = option == perfOverride,
                        onClick = {
                            perfOverride = option
                            PerformanceMode.setOverride(appContext, option)
                        },
                    )
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------------
// Language priority editor
// ---------------------------------------------------------------------------------------------------

@Composable
private fun LanguagePriorityEditor(
    label: String,
    languages: List<String>,
    onChange: (List<String>) -> Unit,
) {
    val colors = VortXTheme.colors
    val ordered = LanguagePriority.normalized(languages)
    val labels = TrackPreferences.commonLanguages.toMap()
    val available = TrackPreferences.commonLanguages.filterNot { (id, _) -> id in ordered }

    Column(
        modifier = Modifier.padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
    ) {
        Text(label, style = VortXTheme.type.label.copy(color = colors.textSecondary))
        ordered.forEachIndexed { index, language ->
            key(language) {
                val languageLabel = labels[language] ?: language.uppercase()
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(VortXTheme.radius.card))
                        .background(colors.surface2)
                        .padding(VortXTheme.spacing.xs),
                    verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
                ) {
                    Text(
                        "${index + 1}. $languageLabel",
                        style = VortXTheme.type.body.copy(color = colors.textPrimary),
                    )
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
                        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
                    ) {
                        Chip(
                            label = "Earlier",
                            selected = false,
                            enabled = index > 0,
                            modifier = Modifier.semantics {
                                contentDescription = languageActionDescription(
                                    action = LanguagePriorityAction.EARLIER,
                                    languageLabel = languageLabel,
                                )
                            },
                            onClick = { onChange(LanguagePriority.move(ordered, index, -1)) },
                        )
                        Chip(
                            label = "Later",
                            selected = false,
                            enabled = index < ordered.lastIndex,
                            modifier = Modifier.semantics {
                                contentDescription = languageActionDescription(
                                    action = LanguagePriorityAction.LATER,
                                    languageLabel = languageLabel,
                                )
                            },
                            onClick = { onChange(LanguagePriority.move(ordered, index, 1)) },
                        )
                        Chip(
                            label = "Remove",
                            selected = false,
                            enabled = ordered.size > 1,
                            modifier = Modifier.semantics {
                                contentDescription = languageActionDescription(
                                    action = LanguagePriorityAction.REMOVE,
                                    languageLabel = languageLabel,
                                )
                            },
                            accent = colors.danger,
                            accentText = colors.danger,
                            onClick = { onChange(LanguagePriority.remove(ordered, index)) },
                        )
                    }
                }
            }
        }
        if (available.isNotEmpty()) {
            PickerRow(
                label = "Add language",
                options = available,
                selectedId = "",
                onSelect = { onChange(LanguagePriority.add(ordered, it)) },
            )
        }
    }
}

internal enum class LanguagePriorityAction {
    EARLIER,
    LATER,
    REMOVE,
}

internal fun languageActionDescription(
    action: LanguagePriorityAction,
    languageLabel: String,
): String = when (action) {
    LanguagePriorityAction.EARLIER -> "Move $languageLabel earlier"
    LanguagePriorityAction.LATER -> "Move $languageLabel later"
    LanguagePriorityAction.REMOVE -> "Remove $languageLabel"
}

/// The crowd skip-database choices. The ids are the EXACT strings [SkipConfig.provider] stores and
/// [com.vortx.android.skip.SkipTimestampService] branches on (SkipTimestampService.kt:55-62), so a pick here
/// selects a leg that genuinely runs. "both" is first because it is the stored default.
///
/// Note "theintrodb" is [SkipTimestampService]'s `else` branch, so any unknown/legacy stored value also lands
/// there; selecting it explicitly writes the canonical id.
private val skipProviderOptions: List<Pair<String, Pair<String, String>>> = listOf(
    "both" to ("Both" to "Ask both databases. The widest coverage, and the default."),
    "theintrodb" to ("TheIntroDB" to "Ask TheIntroDB only."),
    "skipdb" to ("SkipDB" to "Ask SkipDB only."),
)

private fun performanceFooter(constrained: Boolean, reduced: Boolean): String {
    val device = if (constrained) "This device is memory-constrained" else "This device is not memory-constrained"
    val effective = if (reduced) "reduced" else "full"
    return "$device, so Auto runs the $effective path. Reduced keeps the buffer tight so a weak device " +
        "stays responsive while decoding."
}

// ---------------------------------------------------------------------------------------------------
// Building blocks
// ---------------------------------------------------------------------------------------------------
//
// SettingsSection / OptionRow / PickerRow / StepperRow now live in SettingsControls.kt so the Sources
// screen renders from the SAME controls rather than a look-alike set. Only the subtitle preview below is
// still local: it is specific to this screen and has no second caller.

/// A live sample rendered from the SAME computed properties the ExoPlayer path uses, so the preview cannot
/// drift from playback: [SubtitleStyle.foregroundColorArgb], [SubtitleStyle.backgroundColorArgb] and
/// [SubtitleStyle.exoTextSizeFraction] (a fraction of the view height, which is exactly how ExoPlayer's
/// `setFractionalTextSize` sizes captions). Sizing the preview box the same way means the percentage the
/// stepper reports is the percentage the viewer sees.
///
/// The Modern look is the thin-outline + soft-shadow treatment, not a font face: this port deliberately
/// does not select a face (see the divergence note on SubtitleStyle), so the preview must not imply one.
@Composable
private fun SubtitlePreview(style: SubtitleStyle) {
    val colors = VortXTheme.colors
    val previewHeight = 96.dp
    val density = LocalDensity.current
    val textSize = with(density) { (previewHeight.toPx() * style.exoTextSizeFraction).toSp() }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = VortXTheme.spacing.sm)
            .height(previewHeight)
            .clip(RoundedCornerShape(VortXTheme.radius.card))
            // A neutral stand-in for video, so the outline/shaded/box treatments are all legible against
            // something. Not the app canvas: subtitles never sit on the app background in practice.
            .background(colors.surface1),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            "The quick brown fox",
            textAlign = TextAlign.Center,
            style = VortXTheme.type.body.copy(
                color = Color(style.foregroundColorArgb),
                fontSize = textSize,
                fontWeight = if (style.isModern) FontWeight.Medium else FontWeight.Bold,
                shadow = androidx.compose.ui.graphics.Shadow(
                    color = Color.Black,
                    offset = androidx.compose.ui.geometry.Offset(0f, 2f),
                    blurRadius = if (style.isModern) 6f else 3f,
                ),
            ),
            modifier = Modifier
                .background(Color(style.backgroundColorArgb))
                .padding(horizontal = VortXTheme.spacing.xs),
        )
    }
}
