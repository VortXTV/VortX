package com.vortx.android.player

import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.view.Display
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.Audiotrack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Forward10
import androidx.compose.material.icons.filled.HighQuality
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PictureInPictureAlt
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay10
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Subtitles
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.vortx.android.R
import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.Episode
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamSource
import com.vortx.android.ui.theme.VortXGlass
import com.vortx.android.ui.theme.vortxGlass
import com.vortx.android.ui.theme.vortxGlassPanel
import com.vortx.android.ui.theme.vortxGlassProminent
import kotlin.math.roundToInt

/// The VortX-specific chrome layered over whichever [PlayerEngine] is live. It is fully engine-agnostic:
/// it renders the [PlayerState] snapshot and calls back through the transport + track lambdas, never
/// touching the engine directly. The same overlay drives libmpv and ExoPlayer identically, which is the
/// whole point of the [PlayerEngine] seam.
///
/// Controls (matching the Apple player's set as far as the Android engine supports it): back, source
/// title, DV / source badges, a top-right cluster (audio track, subtitle track, playback speed, aspect /
/// zoom), and a bottom play/pause + scrubber row. When the engine reports an error, an overlay offers a
/// return-to-sources fallback instead of a dead black frame.
@Composable
fun PlayerChrome(
    playable: Playable,
    state: PlayerState,
    dolbyVisionAvailable: Boolean,
    emberAccent: Color,
    speed: Float,
    scaleMode: VideoScaleMode,
    chapters: List<PlayerChapter>,
    subtitleDelayAvailable: Boolean,
    subtitleDelaySeconds: Double,
    onAdjustSubtitleDelay: (Double) -> Unit,
    subtitleStyle: SubtitleStyle,
    onChangeSubtitleStyle: (SubtitleStyle) -> Unit,
    audioDelayAvailable: Boolean,
    audioDelaySeconds: Double,
    audioOutputModeAvailable: Boolean,
    audioOutputMode: AudioOutputMode,
    onAdjustAudioDelay: (Double) -> Unit,
    onSelectAudioOutputMode: (AudioOutputMode) -> Unit,
    /// Whether the top scrim + control cluster and the bottom transport bar are drawn. The selection
    /// sheets and the error overlay are NOT gated on it: a sheet the viewer opened must survive an
    /// auto-hide tick, and an error must always be visible. The host owns the show/hide/auto-hide
    /// policy; defaults to always-visible so the chrome stays usable in isolation.
    controlsVisible: Boolean = true,
    /// Reported for chrome-internal continuous interactions (scrubber drags, sheet opens) so the host
    /// can re-arm its auto-hide timer. No-op by default.
    onInteraction: () -> Unit = {},
    onBack: () -> Unit,
    onTogglePause: () -> Unit,
    onSeek: (Long) -> Unit,
    /// Relative seek in milliseconds (negative = back): the +/-10s transport buttons drive this, and the
    /// host also wires the double-tap gesture to the same engine seam. See [PlayerEngine.seekBy].
    onSeekBy: (Long) -> Unit,
    onSelectAudio: (Int) -> Unit,
    onSelectSubtitle: (Int?) -> Unit,
    onSetSpeed: (Float) -> Unit,
    /// Pick the video scale mode (Fit / Fill / Stretch) from the aspect sheet. Replaces the old two-state
    /// toggle so the third (Stretch) mode is reachable. See [VideoScaleMode].
    onSelectScaleMode: (VideoScaleMode) -> Unit,
    onErrorRetry: () -> Unit,
    /// Player Lock: engages the host's touch-lock (controls hidden, taps/gestures ignored until the
    /// unlock affordance is used). Null hides the lock control entirely, keeping the chrome usable
    /// in isolation and on hosts that opt out (the TV shell, where D-pad focus makes a touch-lock
    /// meaningless).
    onLock: (() -> Unit)? = null,
    /// Picture-in-Picture: shrinks the player into the system PiP window (the host wires it to
    /// [PlayerScreen]'s PiP handle). Null hides the control entirely: devices/hosts without PiP
    /// support (no system feature, an activity that does not declare it) never show a dead button.
    onEnterPip: (() -> Unit)? = null,
    /// External subtitles offered by the installed subtitle add-ons for THIS title (the Apple
    /// `SubtitleAddons` union, fetched by the host once per load). Listed in the subtitle sheet
    /// under the file's embedded tracks; picking one mounts + selects it on the live engine via
    /// [onSelectAddonSubtitle]. Empty (the default) leaves the sheet exactly as before.
    addonSubtitles: List<AddonSubtitle> = emptyList(),
    onSelectAddonSubtitle: (AddonSubtitle) -> Unit = {},
    /// Community scrub preview: the thumbnail for a playback time (seconds), or null when this title has
    /// no community sheet (the common case for a title nobody has contributed yet, and always so while
    /// offline). MUST be cheap and synchronous -- it is called for every drag frame -- which is exactly
    /// what [com.vortx.android.trickplay.TrickplaySession.previewAt] guarantees: an in-memory crop of an
    /// already-downloaded sprite. Defaults to no preview so the chrome stays usable in isolation.
    scrubPreview: (Double) -> Bitmap? = { null },
    /// Successful in-place switches increment this even when the replacement resolves to the same URL, closing
    /// the old sheet and resetting chrome state with the engine-owned session.
    playbackSessionRevision: Long = 0L,
    sourceOptions: List<StreamSource> = emptyList(),
    qualityOptions: List<Pair<String, StreamSource>> = emptyList(),
    /// Current-season episodes for the in-player EPISODES sheet (series only). Empty hides the control
    /// (movies, trailers, ad-hoc links). Picking one switches in place via [onSwitchEpisode].
    episodeOptions: List<Episode> = emptyList(),
    currentSource: StreamSource? = null,
    sourceSwitching: Boolean = false,
    sourceSwitchError: String? = null,
    onSwitchSource: (StreamSource) -> Unit = {},
    onSwitchEpisode: (Episode) -> Unit = {},
    /// Secondary (dual) subtitle state. [secondarySubtitleAvailable] is mpv-only, so the control is hidden
    /// on the Dolby Vision (ExoPlayer) engine and when fewer than two subtitle tracks exist. When a second
    /// subtitle is active both the primary and secondary tracks read as selected, so the primary sheet
    /// keys its checkmarks off [primarySubtitleId] instead of the per-track flag.
    secondarySubtitleAvailable: Boolean = false,
    primarySubtitleId: Int = -1,
    secondarySubtitleId: Int = -1,
    onSelectSecondarySubtitle: (Int?) -> Unit = {},
    /// Sleep timer state and control. [sleepEndOfEpisodeAvailable] gates the End of episode row (series
    /// only). Off = (null, false); a timed pause = (minutes, false); End of episode = (null, true).
    sleepSelectionMinutes: Int? = null,
    sleepAtEpisodeEnd: Boolean = false,
    sleepEndOfEpisodeAvailable: Boolean = false,
    onSetSleepTimer: (minutes: Int?, atEpisodeEnd: Boolean) -> Unit = { _, _ -> },
    /// In-player engine switch (mpv <-> ExoPlayer). Hidden for torrents / trailers where the switch is not
    /// valid. [enginePreference] is the current tri-state policy; [liveEngineLabel] names the engine live now.
    engineSwitchAvailable: Boolean = false,
    enginePreference: PlayerEngineRouter.Override = PlayerEngineRouter.Override.AUTO,
    liveEngineLabel: String = "",
    onSelectEnginePreference: (PlayerEngineRouter.Override) -> Unit = {},
    /// Live playback stats for the Playback Info sheet, re-read on each recomposition so the overlay stays
    /// current while open. Empty when the engine exposes nothing.
    playbackInfo: () -> List<Pair<String, String>> = { emptyList() },
    /// Hardware / software decode toggle (mpv-only; hidden on the Dolby Vision player). Software is the
    /// escape hatch for green / garbled frames; Hardware (mediacodec) stays the default.
    hardwareDecodingAvailable: Boolean = false,
    hardwareDecoding: Boolean = true,
    onSetHardwareDecoding: (Boolean) -> Unit = {},
    modifier: Modifier = Modifier,
) {
    // Which selection sheet (if any) is open. Local to the chrome; the engine never sees it.
    var openSheet by remember(playable.url, playbackSessionRevision) { mutableStateOf(ControlSheet.NONE) }
    val sourceChoices = remember(sourceOptions, currentSource) { playerSourceChoices(sourceOptions, currentSource) }
    val qualityChoices = remember(qualityOptions, currentSource) { playerQualityChoices(qualityOptions, currentSource) }
    val episodeChoices = remember(episodeOptions, playable.mediaRef) {
        playerEpisodeChoices(episodeOptions, playable.mediaRef)
    }
    val sourcesTitle = stringResource(R.string.player_sources)
    val sourcesDescription = stringResource(R.string.player_sources_action_description)
    val qualityTitle = stringResource(R.string.player_quality)
    val qualityDescription = stringResource(R.string.player_quality_action_description)
    val switchingSource = stringResource(R.string.player_switching_source)
    val switchFailed = stringResource(R.string.player_source_switch_failed)
    val chaptersTitle = stringResource(R.string.player_chapters)
    val chaptersDescription = stringResource(R.string.player_chapters_action_description)
    val subtitleSettingsTitle = stringResource(R.string.player_subtitle_settings)
    val subtitleSettingsCopy = SubtitleSettingsCopy(
        unavailable = stringResource(R.string.player_subtitle_sync_unavailable),
        sync = stringResource(R.string.player_subtitle_sync),
        earlierHalf = stringResource(R.string.player_subtitle_earlier_half),
        laterHalf = stringResource(R.string.player_subtitle_later_half),
        earlierFine = stringResource(R.string.player_subtitle_earlier_fine),
        laterFine = stringResource(R.string.player_subtitle_later_fine),
        reset = stringResource(R.string.player_subtitle_reset_sync),
        style = stringResource(R.string.player_subtitle_style),
        size = stringResource(R.string.player_subtitle_size),
        smaller = stringResource(R.string.player_subtitle_smaller),
        larger = stringResource(R.string.player_subtitle_larger),
        color = stringResource(R.string.player_subtitle_color),
        brightness = stringResource(R.string.player_subtitle_brightness),
        background = stringResource(R.string.player_subtitle_background),
    )

    Box(modifier = modifier) {
        // Top scrim so the title, back button, and controls stay legible over bright video.
        // Gated (with the transport bar below) on [controlsVisible]: this pair is what auto-hides.
        if (controlsVisible) Column(
            modifier = Modifier
                .fillMaxWidth()
                .align(Alignment.TopCenter)
                .background(
                    Brush.verticalGradient(
                        listOf(Color.Black.copy(alpha = 0.55f), Color.Transparent)
                    )
                )
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 8.dp, vertical = 8.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) {
                    Icon(
                        Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "Back",
                        tint = Color.White,
                    )
                }
                Text(
                    text = playable.title,
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 16.sp,
                    maxLines = 1,
                    modifier = Modifier
                        .weight(1f)
                        .padding(start = 4.dp),
                )
                // Control cluster: source/quality switching, audio/output, subtitles, speed, and aspect.
                // Opening a sheet counts as interaction so the host's auto-hide timer re-arms.
                if (sourceChoices.size > 1) {
                    ChromeIcon(Icons.Filled.Tune, sourcesDescription) { onInteraction(); openSheet = ControlSheet.SOURCES }
                }
                if (qualityChoices.size > 1) {
                    ChromeIcon(Icons.Filled.HighQuality, qualityDescription) { onInteraction(); openSheet = ControlSheet.QUALITY }
                }
                // In-player episode picker (series only): the season's episodes, current one highlighted.
                if (episodeChoices.size > 1) {
                    ChromeIcon(Icons.AutoMirrored.Filled.List, "Episodes") { onInteraction(); openSheet = ControlSheet.EPISODES }
                }
                ChromeIcon(Icons.Filled.Audiotrack, "Audio and output settings") { onInteraction(); openSheet = ControlSheet.AUDIO }
                ChromeIcon(Icons.Filled.Subtitles, "Subtitles") { onInteraction(); openSheet = ControlSheet.SUBTITLE }
                ChromeIcon(Icons.Filled.Speed, "Playback speed") { onInteraction(); openSheet = ControlSheet.SPEED }
                if (chapters.isNotEmpty()) {
                    ChromeIcon(Icons.AutoMirrored.Filled.List, chaptersDescription) { onInteraction(); openSheet = ControlSheet.CHAPTERS }
                }
                // Aspect ratio: opens the Fit / Fill / Stretch sheet. Ember-tinted when not on the default Fit.
                ChromeIcon(
                    Icons.Filled.AspectRatio,
                    "Aspect ratio",
                    tint = if (scaleMode != VideoScaleMode.FIT) emberAccent else Color.White,
                ) { onInteraction(); openSheet = ControlSheet.VIDEO }
                // Player settings overflow: sleep timer, decoder, playback info, and the engine switch.
                ChromeIcon(Icons.Filled.Settings, "Player settings") { onInteraction(); openSheet = ControlSheet.PLAYER_SETTINGS }
                // Picture-in-Picture, before the lock so the lock stays the cluster's last (and
                // therefore most protected-from-fat-finger) position.
                onEnterPip?.let { pip ->
                    ChromeIcon(Icons.Filled.PictureInPictureAlt, "Picture in picture") { pip() }
                }
                // Player Lock: hides the chrome and freezes touch input so nothing mid-film seeks or
                // pauses by accident; the host draws the unlock affordance while locked.
                onLock?.let { lock ->
                    ChromeIcon(Icons.Filled.Lock, "Lock player controls") { lock() }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(start = 8.dp, top = 2.dp)) {
                if (playable.viaStreamingServer) ChromeBadge("SOURCE", emberAccent)
                // DV badge is GATED on the display actually advertising Dolby Vision. The ExoPlayer engine
                // still does its own DV codec fallback regardless; this badge is purely about not claiming
                // DV on a panel that cannot present it.
                if (dolbyVisionAvailable) ChromeBadge("DOLBY VISION", emberAccent)
                if (speed != 1.0f) ChromeBadge("${trimSpeed(speed)}x", emberAccent)
            }
        }

        // Bottom transport: play/pause + scrubber, driven entirely by [state] (engine-agnostic).
        if (controlsVisible) TransportBar(
            state = state,
            emberAccent = emberAccent,
            onTogglePause = onTogglePause,
            onSeek = onSeek,
            onSeekBy = onSeekBy,
            onInteraction = onInteraction,
            scrubPreview = scrubPreview,
            modifier = Modifier
                .fillMaxWidth()
                .align(Alignment.BottomCenter),
        )

        // Selection sheets (audio / subtitle / speed) as a bottom overlay panel.
        when (openSheet) {
            ControlSheet.SOURCES -> ControlSelectionSheet(
                title = sourcesTitle,
                options = buildList {
                    if (sourceSwitching) {
                        add(SheetOption(switchingSource, false, enabled = false, isStatus = true))
                    } else if (sourceSwitchError != null) {
                        add(
                            SheetOption(
                                switchFailed,
                                false,
                                enabled = false,
                                isStatus = true,
                            ),
                        )
                    }
                    sourceChoices.forEach { choice ->
                        add(
                            SheetOption(
                                label = choice.label,
                                selected = choice.selected,
                                detail = choice.detail,
                                enabled = !sourceSwitching,
                                isChoice = true,
                                dismissOnPick = false,
                                onPick = { onSwitchSource(choice.source) },
                            ),
                        )
                    }
                },
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.QUALITY -> ControlSelectionSheet(
                title = qualityTitle,
                options = buildList {
                    if (sourceSwitching) {
                        add(SheetOption(switchingSource, false, enabled = false, isStatus = true))
                    } else if (sourceSwitchError != null) {
                        add(
                            SheetOption(
                                switchFailed,
                                false,
                                enabled = false,
                                isStatus = true,
                            ),
                        )
                    }
                    qualityChoices.forEach { choice ->
                        add(
                            SheetOption(
                                label = choice.label,
                                selected = choice.selected,
                                detail = choice.detail,
                                enabled = !sourceSwitching,
                                isChoice = true,
                                dismissOnPick = false,
                                onPick = { onSwitchSource(choice.source) },
                            ),
                        )
                    }
                },
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.EPISODES -> ControlSelectionSheet(
                title = "Episodes",
                options = buildList {
                    if (sourceSwitching) {
                        add(SheetOption("Switching episode...", false, enabled = false, isStatus = true))
                    } else if (sourceSwitchError != null) {
                        add(SheetOption("Episode switch failed", false, enabled = false, isStatus = true))
                    }
                    episodeChoices.forEach { choice ->
                        add(
                            SheetOption(
                                label = choice.label,
                                selected = choice.selected,
                                enabled = !sourceSwitching,
                                isChoice = true,
                                dismissOnPick = false,
                                onPick = { onSwitchEpisode(choice.episode) },
                            ),
                        )
                    }
                },
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.VIDEO -> ControlSelectionSheet(
                title = "Aspect Ratio",
                options = VIDEO_SCALE_MODES.map { (mode, label, detail) ->
                    SheetOption(
                        label = label,
                        detail = detail,
                        selected = scaleMode == mode,
                        isChoice = true,
                        dismissOnPick = false,
                        onPick = { onSelectScaleMode(mode) },
                    )
                },
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.AUDIO -> ControlSelectionSheet(
                title = "Audio",
                options = buildList {
                    state.audioTracks.forEach { track ->
                        add(
                            SheetOption(
                                label = trackLabel(track.title, track.lang),
                                selected = track.selected,
                                isChoice = true,
                                onPick = { onSelectAudio(track.id) },
                            ),
                        )
                    }
                    add(
                        SheetOption(
                            label = "Audio Settings",
                            selected = false,
                            onPick = { openSheet = ControlSheet.AUDIO_SETTINGS },
                            detail = "›",
                            dismissOnPick = false,
                        ),
                    )
                },
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.SUBTITLE -> ControlSelectionSheet(
                title = "Subtitles",
                options = buildList {
                    // When a second subtitle is active, mpv flags BOTH the primary and secondary tracks
                    // `selected`, so the per-track flag can no longer identify the primary: key the primary
                    // checkmarks off the engine's explicit primary id instead. With no second subtitle (the
                    // ordinary case, and always on the Dolby Vision engine) this stays false and the rows
                    // fall back to the `selected` flag exactly as before.
                    val dualActive = secondarySubtitleAvailable && secondarySubtitleId >= 0
                    add(
                        SheetOption(
                            label = "Off",
                            selected = if (dualActive) primarySubtitleId < 0 else state.subtitleTracks.none { it.selected },
                            isChoice = true,
                            onPick = { onSelectSubtitle(null) },
                        ),
                    )
                    state.subtitleTracks.forEach { track ->
                        add(
                            SheetOption(
                                label = trackLabel(track.title, track.lang),
                                selected = if (dualActive) track.id == primarySubtitleId else track.selected,
                                isChoice = true,
                                onPick = { onSelectSubtitle(track.id) },
                            ),
                        )
                    }
                    // Add-on subtitles, after the embedded tracks (Apple lists them the same way):
                    // picking one mounts it on the live engine, after which it also appears above as
                    // a regular (selected) track.
                    addonSubtitles.forEach { sub ->
                        add(
                            SheetOption(
                                label = "${sub.lang} · ${sub.addonName}",
                                selected = false,
                                isChoice = true,
                                onPick = { onSelectAddonSubtitle(sub) },
                            ),
                        )
                    }
                    // Second subtitle (dual tracks for language study): mpv-only, and only when there are at
                    // least two tracks to pick a second from. Hidden on the Dolby Vision engine, where
                    // playback degrades to the single primary subtitle.
                    if (secondarySubtitleAvailable && state.subtitleTracks.size >= 2) {
                        add(
                            SheetOption(
                                label = secondSubtitleLabel(state.subtitleTracks, secondarySubtitleId),
                                selected = false,
                                onPick = { openSheet = ControlSheet.SECOND_SUBTITLE },
                                detail = "›",
                                dismissOnPick = false,
                            ),
                        )
                    }
                    add(
                        SheetOption(
                            label = subtitleSettingsTitle,
                            selected = false,
                            onPick = { openSheet = ControlSheet.SUBTITLE_SETTINGS },
                            detail = "›",
                            dismissOnPick = false,
                        ),
                    )
                },
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.SECOND_SUBTITLE -> ControlSelectionSheet(
                title = "Second Subtitle",
                options = buildList {
                    add(
                        SheetOption(
                            label = "Off",
                            selected = secondarySubtitleId < 0,
                            isChoice = true,
                            onPick = { onSelectSecondarySubtitle(null) },
                        ),
                    )
                    // mpv refuses to show one track as both primary and secondary, so exclude the primary.
                    state.subtitleTracks
                        .filter { primarySubtitleId < 0 || it.id != primarySubtitleId }
                        .forEach { track ->
                            add(
                                SheetOption(
                                    label = trackLabel(track.title, track.lang),
                                    selected = track.id == secondarySubtitleId,
                                    isChoice = true,
                                    onPick = { onSelectSecondarySubtitle(track.id) },
                                ),
                            )
                        }
                },
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.SUBTITLE_SETTINGS -> ControlSelectionSheet(
                title = subtitleSettingsTitle,
                options = subtitleSettingsOptions(
                    available = subtitleDelayAvailable,
                    delaySeconds = subtitleDelaySeconds,
                    onAdjust = onAdjustSubtitleDelay,
                    style = subtitleStyle,
                    onChangeStyle = onChangeSubtitleStyle,
                    copy = subtitleSettingsCopy,
                ),
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.AUDIO_SETTINGS -> ControlSelectionSheet(
                title = "Audio Settings",
                options = audioSyncOptions(
                    available = audioDelayAvailable,
                    delaySeconds = audioDelaySeconds,
                    outputAvailable = audioOutputModeAvailable,
                    outputMode = audioOutputMode,
                    onAdjust = onAdjustAudioDelay,
                    onSelectOutput = onSelectAudioOutputMode,
                ),
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.SPEED -> ControlSelectionSheet(
                title = "Playback speed",
                options = SPEED_PRESETS.map { preset ->
                    SheetOption(
                        label = if (preset == 1.0f) "Normal" else "${trimSpeed(preset)}x",
                        selected = preset == speed,
                        isChoice = true,
                        onPick = { onSetSpeed(preset) },
                    )
                },
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.CHAPTERS -> ControlSelectionSheet(
                title = chaptersTitle,
                options = chapterOptions(chapters, state.positionMs, onSeek),
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.PLAYER_SETTINGS -> ControlSelectionSheet(
                title = "Player Settings",
                options = buildList {
                    add(
                        SheetOption(
                            label = "Sleep Timer",
                            selected = false,
                            detail = sleepStatusDetail(sleepSelectionMinutes, sleepAtEpisodeEnd),
                            onPick = { openSheet = ControlSheet.SLEEP },
                            dismissOnPick = false,
                        ),
                    )
                    // Decoder toggle is mpv-only: the Dolby Vision player always decodes in hardware, so the
                    // rows are hidden there rather than shown as dead controls.
                    if (hardwareDecodingAvailable) {
                        add(SheetOption("Decoder", false, enabled = false, isHeader = true))
                        add(
                            SheetOption(
                                label = "Hardware",
                                selected = hardwareDecoding,
                                detail = "recommended",
                                isChoice = true,
                                dismissOnPick = false,
                                onPick = { onSetHardwareDecoding(true) },
                            ),
                        )
                        add(
                            SheetOption(
                                label = "Software",
                                selected = !hardwareDecoding,
                                detail = "rescues green or garbled frames",
                                isChoice = true,
                                dismissOnPick = false,
                                onPick = { onSetHardwareDecoding(false) },
                            ),
                        )
                    }
                    add(
                        SheetOption(
                            label = "Playback Info",
                            selected = false,
                            detail = "›",
                            onPick = { openSheet = ControlSheet.INFO },
                            dismissOnPick = false,
                        ),
                    )
                    if (engineSwitchAvailable) {
                        add(
                            SheetOption(
                                label = "Player Engine",
                                selected = false,
                                detail = liveEngineLabel.ifBlank { "›" },
                                onPick = { openSheet = ControlSheet.ENGINE },
                                dismissOnPick = false,
                            ),
                        )
                    }
                },
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.SLEEP -> ControlSelectionSheet(
                title = "Sleep Timer",
                options = buildList {
                    add(
                        SheetOption(
                            label = "Off",
                            selected = sleepSelectionMinutes == null && !sleepAtEpisodeEnd,
                            isChoice = true,
                            dismissOnPick = false,
                            onPick = { onSetSleepTimer(null, false) },
                        ),
                    )
                    SLEEP_TIMER_MINUTES.forEach { minutes ->
                        add(
                            SheetOption(
                                label = "$minutes minutes",
                                selected = sleepSelectionMinutes == minutes && !sleepAtEpisodeEnd,
                                isChoice = true,
                                dismissOnPick = false,
                                onPick = { onSetSleepTimer(minutes, false) },
                            ),
                        )
                    }
                    // Only meaningful for a series episode: it stops the auto-advance at the end of this one.
                    if (sleepEndOfEpisodeAvailable) {
                        add(
                            SheetOption(
                                label = "End of episode",
                                selected = sleepAtEpisodeEnd,
                                isChoice = true,
                                dismissOnPick = false,
                                onPick = { onSetSleepTimer(null, true) },
                            ),
                        )
                    }
                },
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.INFO -> ControlSelectionSheet(
                title = "Playback Info",
                options = playbackInfoOptions(playable, currentSource, playbackInfo()),
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.ENGINE -> ControlSelectionSheet(
                title = "Player Engine",
                options = ENGINE_CHOICES.map { (pref, label, detail) ->
                    SheetOption(
                        label = label,
                        detail = detail,
                        selected = enginePreference == pref,
                        isChoice = true,
                        dismissOnPick = false,
                        onPick = { onSelectEnginePreference(pref) },
                    )
                },
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.NONE -> Unit
        }

        // Buffering / connecting indicator: a centered spinner whenever the engine reports no data
        // flowing -- the initial open (both engines publish isBuffering=true from load until the first
        // frame), an mpv `paused-for-cache` mid-stream stall, an ExoPlayer rebuffer. Before this, an
        // opening stream showed a bare black frame with a Pause glyph and an empty scrubber, which read
        // as a hang. Suppressed under the terminal overlays: an error must show the error, not a spinner.
        // The "Connecting" label is only added before a duration is known (nothing demuxed yet); a
        // mid-stream rebuffer keeps the plain spinner.
        if (state.isBuffering && !state.hasError && !state.hasEnded) {
            Column(
                modifier = Modifier.align(Alignment.Center),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                CircularProgressIndicator(color = emberAccent, modifier = Modifier.size(44.dp))
                if (state.durationMs <= 0L) {
                    Text(
                        text = "Connecting...",
                        color = Color.White.copy(alpha = 0.85f),
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                    )
                }
            }
        }

        // Error-to-sources fallback: a failed source lands here instead of a dead black frame.
        if (state.hasError && openSheet != ControlSheet.SOURCES && openSheet != ControlSheet.QUALITY) {
            PlayerErrorOverlay(
                emberAccent = emberAccent,
                onRetry = if (sourceChoices.size > 1) {
                    { openSheet = ControlSheet.SOURCES }
                } else {
                    onErrorRetry
                },
                onBack = onBack,
            )
        }
    }
}

/// The selection sheets the chrome can open.
private enum class ControlSheet {
    NONE,
    SOURCES,
    QUALITY,
    EPISODES,
    VIDEO,
    AUDIO,
    SUBTITLE,
    SECOND_SUBTITLE,
    SUBTITLE_SETTINGS,
    AUDIO_SETTINGS,
    SPEED,
    CHAPTERS,
    PLAYER_SETTINGS,
    SLEEP,
    INFO,
    ENGINE,
}

/// Aspect-ratio choices for the VIDEO sheet, mirroring the Apple Aspect Ratio panel
/// (original / fill / stretch): Fit keeps the whole frame, Fill crops to screen, Stretch distorts to fill.
private val VIDEO_SCALE_MODES: List<Triple<VideoScaleMode, String, String>> = listOf(
    Triple(VideoScaleMode.FIT, "Fit", "default"),
    Triple(VideoScaleMode.ZOOM, "Fill", "crop to screen"),
    Triple(VideoScaleMode.STRETCH, "Stretch", "fill, distort"),
)

/// Sleep-timer minute presets, matching the Apple player's set.
private val SLEEP_TIMER_MINUTES: List<Int> = listOf(15, 30, 45, 60, 90)

/// Engine-picker choices for the ENGINE sheet (tri-state auto / mpv / ExoPlayer). "Dolby Vision Player" is
/// the user-facing name for the ExoPlayer engine, matching the chrome's other mpv-only "unavailable on the
/// Dolby Vision player" copy.
private val ENGINE_CHOICES: List<Triple<PlayerEngineRouter.Override, String, String>> = listOf(
    Triple(PlayerEngineRouter.Override.AUTO, "Automatic", "recommended"),
    Triple(PlayerEngineRouter.Override.MPV, "VortX Player", "all formats, styled subtitles"),
    Triple(PlayerEngineRouter.Override.EXOPLAYER, "Dolby Vision Player", "Dolby Vision, HLS"),
)

/// The playback-speed presets offered in the speed sheet.
private val SPEED_PRESETS = listOf(0.5f, 0.75f, 1.0f, 1.25f, 1.5f, 2.0f)

/// The relative-seek step (ms) for the transport's Replay10/Forward10 buttons. 10s matches the icon
/// glyphs and the host's double-tap gesture step.
private const val SEEK_STEP_MS = 10_000L

private data class SheetOption(
    val label: String,
    val selected: Boolean,
    val detail: String = "",
    val enabled: Boolean = true,
    val isHeader: Boolean = false,
    val isStatus: Boolean = false,
    val isChoice: Boolean = false,
    val dismissOnPick: Boolean = true,
    val onPick: () -> Unit = {},
)

private fun chapterOptions(
    chapters: List<PlayerChapter>,
    positionMs: Long,
    onSeek: (Long) -> Unit,
): List<SheetOption> {
    val ordered = normalizePlayerChapters(chapters)
    val selected = currentChapterIndex(ordered, positionMs)
    return ordered.mapIndexed { index, chapter ->
        SheetOption(
            label = chapter.title,
            selected = index == selected,
            detail = formatTime(chapter.startMs),
            isChoice = true,
            onPick = { onSeek(chapter.startMs) },
        )
    }
}

/** One shared production normalization path for engine markers, chrome rows, and their tests. */
internal fun normalizePlayerChapters(chapters: List<PlayerChapter>): List<PlayerChapter> =
    chapters.sortedBy(PlayerChapter::startMs)

internal fun currentChapterIndex(chapters: List<PlayerChapter>, positionMs: Long): Int =
    chapters.indexOfLast { it.startMs <= positionMs }

/// The Second Subtitle drill-in label, with the current second track's language appended when one is set.
private fun secondSubtitleLabel(tracks: List<PlayerTrack>, secondaryId: Int): String {
    val current = tracks.firstOrNull { it.id == secondaryId } ?: return "Second subtitle"
    val lang = current.lang?.takeIf { it.isNotBlank() } ?: current.title.takeIf { it.isNotBlank() }
    return if (lang != null) "Second subtitle · $lang" else "Second subtitle"
}

/// The Sleep Timer row's right-aligned status shown in the Player Settings sheet.
private fun sleepStatusDetail(minutes: Int?, atEpisodeEnd: Boolean): String = when {
    atEpisodeEnd -> "End of episode"
    minutes != null -> "$minutes min"
    else -> "Off"
}

/// Build the Playback Info sheet rows: the title, the current source (release / add-on / size), and the
/// live engine stats. Every row is informational (non-interactive). Mirrors the Apple Playback Info panel.
private fun playbackInfoOptions(
    playable: Playable,
    currentSource: StreamSource?,
    stats: List<Pair<String, String>>,
): List<SheetOption> = buildList {
    add(SheetOption("Now Playing", false, enabled = false, isHeader = true))
    add(SheetOption(playable.title, false, enabled = false))
    currentSource?.let { src ->
        add(SheetOption("Source", false, enabled = false, isHeader = true))
        val release = src.title.lineSequence().firstOrNull()?.trim().orEmpty().ifBlank { src.addon }
        if (release.isNotBlank()) add(SheetOption("Release", false, detail = release.take(80), enabled = false))
        if (src.addon.isNotBlank()) add(SheetOption("Add-on", false, detail = src.addon, enabled = false))
        StreamRanking.sizeText(src)?.let { add(SheetOption("Size", false, detail = it, enabled = false)) }
    }
    if (stats.isNotEmpty()) {
        add(SheetOption("Playback", false, enabled = false, isHeader = true))
        stats.forEach { (label, value) -> add(SheetOption(label, false, detail = value, enabled = false)) }
    }
}

private data class SubtitleSettingsCopy(
    val unavailable: String,
    val sync: String,
    val earlierHalf: String,
    val laterHalf: String,
    val earlierFine: String,
    val laterFine: String,
    val reset: String,
    val style: String,
    val size: String,
    val smaller: String,
    val larger: String,
    val color: String,
    val brightness: String,
    val background: String,
)

private fun subtitleSettingsOptions(
    available: Boolean,
    delaySeconds: Double,
    onAdjust: (Double) -> Unit,
    style: SubtitleStyle,
    onChangeStyle: (SubtitleStyle) -> Unit,
    copy: SubtitleSettingsCopy,
): List<SheetOption> = buildList {
    if (available) {
        val now = formatDelay(delaySeconds)
        add(SheetOption(copy.sync, false, enabled = false, isHeader = true))
        add(SheetOption(copy.earlierHalf, false, detail = now, dismissOnPick = false) { onAdjust(-0.5) })
        add(SheetOption(copy.laterHalf, false, detail = now, dismissOnPick = false) { onAdjust(0.5) })
        add(SheetOption(copy.earlierFine, false, detail = now, dismissOnPick = false) { onAdjust(-0.1) })
        add(SheetOption(copy.laterFine, false, detail = now, dismissOnPick = false) { onAdjust(0.1) })
        if (delaySeconds != 0.0) {
            add(SheetOption(copy.reset, false, dismissOnPick = false) { onAdjust(-delaySeconds) })
        }
    } else {
        add(
            SheetOption(
                label = copy.unavailable,
                selected = false,
                enabled = false,
                isHeader = true,
            ),
        )
    }

    add(SheetOption(copy.style, false, enabled = false, isHeader = true))
    SubtitleStyle.fonts.forEach { (id, label) ->
        add(
            SheetOption(
                label = label,
                selected = style.fontId == id,
                isChoice = true,
                dismissOnPick = false,
                onPick = { onChangeStyle(style.copy(fontId = id)) },
            ),
        )
    }

    add(SheetOption(copy.size, false, enabled = false, isHeader = true))
    SubtitleStyle.sizes.forEach { (id, label) ->
        add(
            SheetOption(
                label = label,
                selected = style.sizeId == id,
                isChoice = true,
                dismissOnPick = false,
                onPick = { onChangeStyle(style.copy(sizeId = id)) },
            ),
        )
    }
    val scalePercent = "${(style.sizeScale * 100).roundToInt()}%"
    add(
        SheetOption(
            label = copy.smaller,
            selected = false,
            detail = scalePercent,
            enabled = style.sizeScale > SubtitleStyle.SIZE_SCALE_RANGE.start,
            dismissOnPick = false,
            onPick = { onChangeStyle(style.copy(sizeScale = style.sizeScale - SubtitleStyle.SIZE_SCALE_STEP)) },
        ),
    )
    add(
        SheetOption(
            label = copy.larger,
            selected = false,
            detail = scalePercent,
            enabled = style.sizeScale < SubtitleStyle.SIZE_SCALE_RANGE.endInclusive,
            dismissOnPick = false,
            onPick = { onChangeStyle(style.copy(sizeScale = style.sizeScale + SubtitleStyle.SIZE_SCALE_STEP)) },
        ),
    )

    add(SheetOption(copy.color, false, enabled = false, isHeader = true))
    SubtitleStyle.colors.forEach { (id, label) ->
        add(
            SheetOption(
                label = label,
                selected = style.colorId == id,
                isChoice = true,
                dismissOnPick = false,
                onPick = { onChangeStyle(style.copy(colorId = id)) },
            ),
        )
    }

    add(SheetOption(copy.brightness, false, enabled = false, isHeader = true))
    SubtitleStyle.brightnessLevels.forEach { level ->
        add(
            SheetOption(
                label = level.label,
                selected = style.brightnessId == level.id,
                isChoice = true,
                dismissOnPick = false,
                onPick = { onChangeStyle(style.copy(brightnessId = level.id)) },
            ),
        )
    }

    add(SheetOption(copy.background, false, enabled = false, isHeader = true))
    SubtitleStyle.backgrounds.forEach { (id, label) ->
        add(
            SheetOption(
                label = label,
                selected = style.backgroundId == id,
                isChoice = true,
                dismissOnPick = false,
                onPick = { onChangeStyle(style.copy(backgroundId = id)) },
            ),
        )
    }
}

private fun audioSyncOptions(
    available: Boolean,
    delaySeconds: Double,
    outputAvailable: Boolean,
    outputMode: AudioOutputMode,
    onAdjust: (Double) -> Unit,
    onSelectOutput: (AudioOutputMode) -> Unit,
): List<SheetOption> = buildList {
    if (available) {
        val now = formatDelay(delaySeconds)
        add(SheetOption("Sync", false, enabled = false, isHeader = true))
        add(SheetOption("Earlier  -0.1s", false, detail = now, dismissOnPick = false) { onAdjust(-0.1) })
        add(SheetOption("Later  +0.1s", false, detail = now, dismissOnPick = false) { onAdjust(0.1) })
        if (delaySeconds != 0.0) {
            add(SheetOption("Reset sync", false, dismissOnPick = false) { onAdjust(-delaySeconds) })
        }
    } else {
        add(
            SheetOption(
                label = "Audio sync isn't available on the Dolby Vision player",
                selected = false,
                enabled = false,
                isHeader = true,
            ),
        )
    }
    val outputModes = visibleAudioOutputModes(outputAvailable)
    if (outputModes.isNotEmpty()) {
        add(SheetOption("Output", false, enabled = false, isHeader = true))
        outputModes.forEach { mode ->
            add(
                SheetOption(
                    label = mode.label,
                    selected = mode == outputMode,
                    onPick = { onSelectOutput(mode) },
                    detail = mode.detail,
                    isChoice = true,
                    dismissOnPick = false,
                ),
            )
        }
    }
}

internal fun visibleAudioOutputModes(available: Boolean): List<AudioOutputMode> =
    if (available) AudioOutputMode.entries else emptyList()

private fun formatDelay(seconds: Double): String = "%+.1fs".format(java.util.Locale.ROOT, seconds)

/// A bottom selection panel (scrim + card of rows). Deliberately a lightweight custom overlay rather than
/// a ModalBottomSheet: it renders over full-screen video, needs no experimental sheet-state plumbing, and
/// the scrim tap dismisses. The picked row invokes its action and closes the sheet.
@Composable
private fun ControlSelectionSheet(
    title: String,
    options: List<SheetOption>,
    emberAccent: Color,
    onDismiss: () -> Unit,
) {
    val firstEnabledIndex = options.indexOfFirst(SheetOption::enabled)
    val firstOptionFocus = remember(title) { FocusRequester() }
    LaunchedEffect(title, firstEnabledIndex, options.size) {
        if (firstEnabledIndex >= 0) {
            withFrameNanos { }
            runCatching { firstOptionFocus.requestFocus() }
        }
    }
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.4f))
            .clickable(onClick = onDismiss),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .align(Alignment.BottomCenter)
                .heightIn(max = 560.dp)
                .verticalScroll(rememberScrollState())
                // The selection sheet is a VortX glass panel (was a flat near-black fill): high-alpha warm
                // glass so track labels stay legible over bright video. Top-rounded, flush to the bottom.
                .vortxGlassPanel(RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp))
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(text = title, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 15.sp, modifier = Modifier.padding(bottom = 4.dp))
            if (options.isEmpty()) {
                Text(text = "None available", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp, modifier = Modifier.padding(vertical = 8.dp))
            }
            options.forEachIndexed { index, option ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .then(if (index == firstEnabledIndex) Modifier.focusRequester(firstOptionFocus) else Modifier)
                        .then(
                            if (option.isStatus) {
                                Modifier.semantics { liveRegion = LiveRegionMode.Polite }
                            } else {
                                Modifier
                            },
                        )
                        .then(
                            if (option.enabled && option.isChoice) {
                                Modifier.selectable(
                                    selected = option.selected,
                                    role = Role.RadioButton,
                                ) {
                                    option.onPick()
                                    if (option.dismissOnPick) onDismiss()
                                }
                            } else if (option.enabled) {
                                Modifier.clickable(role = Role.Button) {
                                    option.onPick()
                                    if (option.dismissOnPick) onDismiss()
                                }
                            } else {
                                Modifier
                            },
                        )
                        .padding(vertical = 10.dp, horizontal = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    val longDetail = option.detail.length > 24
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = option.label,
                            color = when {
                                option.selected -> emberAccent
                                option.enabled -> Color.White
                                else -> Color.White.copy(alpha = 0.65f)
                            },
                            fontWeight = when {
                                option.selected || option.isHeader -> FontWeight.SemiBold
                                else -> FontWeight.Normal
                            },
                            fontSize = if (option.isHeader) 13.sp else 15.sp,
                        )
                        if (longDetail) {
                            Text(
                                text = option.detail,
                                color = Color.White.copy(alpha = 0.65f),
                                fontSize = 12.sp,
                                maxLines = 2,
                            )
                        }
                    }
                    if (option.detail.isNotEmpty() && !longDetail) {
                        Text(text = option.detail, color = Color.White.copy(alpha = 0.7f), fontSize = 13.sp)
                    }
                    if (option.selected) {
                        Icon(
                            imageVector = Icons.Filled.Check,
                            contentDescription = stringResource(R.string.player_current_selection),
                            tint = emberAccent,
                            modifier = Modifier.size(20.dp),
                        )
                    }
                }
            }
        }
    }
}

/// The error fallback overlay: a centered message + a "Choose another source" action that returns to the
/// ranked source list, plus a plain back. Shown when [PlayerState.hasError] is set.
@Composable
private fun PlayerErrorOverlay(emberAccent: Color, onRetry: () -> Unit, onBack: () -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.85f)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.padding(24.dp),
        ) {
            Text("This source didn't play", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp)
            Text(
                "It may be offline or unsupported. Pick another source to keep watching.",
                color = Color.White.copy(alpha = 0.75f),
                fontSize = 14.sp,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    text = "Choose another source",
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 15.sp,
                    // Primary recovery action as ember glass (was a solid accent slab).
                    modifier = Modifier
                        .vortxGlassProminent(shape = RoundedCornerShape(8.dp), tint = emberAccent)
                        .clickable(onClick = onRetry)
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                )
                Text(
                    text = "Back",
                    color = Color.White,
                    fontSize = 15.sp,
                    // Secondary action as neutral VortX glass (was a flat white 12% fill).
                    modifier = Modifier
                        .vortxGlass(
                            shape = RoundedCornerShape(8.dp),
                            fillAlpha = VortXGlass.fieldFillAlpha,
                            shadow = VortXGlass.Shadow.flat,
                        )
                        .clickable(onClick = onBack)
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                )
            }
        }
    }
}

/// The bottom play/pause + scrubber row. Reflects [PlayerState] and reports scrubs back via [onSeek].
/// While the user is dragging, the slider follows the finger locally; on release it seeks the engine, so
/// a mid-drag position update from the engine does not fight the gesture.
@Composable
private fun TransportBar(
    state: PlayerState,
    emberAccent: Color,
    onTogglePause: () -> Unit,
    onSeek: (Long) -> Unit,
    onSeekBy: (Long) -> Unit,
    /// Reported on every scrub drag frame so the host's auto-hide timer cannot expire mid-gesture and
    /// yank the slider out from under the finger. No-op by default.
    onInteraction: () -> Unit = {},
    scrubPreview: (Double) -> Bitmap? = { null },
    modifier: Modifier = Modifier,
) {
    var scrubbing by remember { mutableStateOf(false) }
    var scrubValue by remember { mutableStateOf(0f) }

    val duration = state.durationMs.coerceAtLeast(0L)
    val position = state.positionMs.coerceIn(0L, if (duration > 0L) duration else Long.MAX_VALUE)
    val sliderValue = when {
        scrubbing -> scrubValue
        duration > 0L -> position.toFloat() / duration.toFloat()
        else -> 0f
    }

    // The community scrub thumbnail for wherever the finger currently is. Recomputed only when the
    // scrubbed SECOND changes, not on every pixel of drag: `crop` allocates a bitmap, so keying on the raw
    // float would allocate on every frame of the gesture and make scrubbing the jankiest thing in the
    // player. One crop per second of scrubbed time is exactly the tile granularity anyway (tiles are 10s
    // apart), so nothing visible is lost. This mirrors the SkipButton's per-second recompute key.
    val scrubSeconds = if (duration > 0L) (scrubValue * duration / 1000.0) else 0.0
    val previewBitmap = remember(scrubbing, scrubSeconds.toLong()) {
        if (scrubbing && duration > 0L) scrubPreview(scrubSeconds) else null
    }

    Column(
        modifier = modifier
            .background(
                Brush.verticalGradient(
                    listOf(Color.Transparent, Color.Black.copy(alpha = 0.6f))
                )
            )
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        // Scrub preview, drawn ABOVE the transport row so it never covers the slider the finger is on.
        // Present only while dragging a title that actually has a community sheet; otherwise the row is
        // simply absent and the transport looks exactly as it does today.
        previewBitmap?.let { bmp ->
            Image(
                bitmap = bmp.asImageBitmap(),
                contentDescription = null,
                modifier = Modifier
                    .padding(start = 64.dp, bottom = 8.dp)
                    .size(width = 160.dp, height = 90.dp)
                    .clip(RoundedCornerShape(8.dp)),
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onTogglePause) {
                Icon(
                    imageVector = if (state.isPaused) Icons.Filled.PlayArrow else Icons.Filled.Pause,
                    contentDescription = if (state.isPaused) "Play" else "Pause",
                    tint = Color.White,
                )
            }
            // The +/-10s jump controls (the relative seek the scrubber physically cannot do: 10s of a
            // 2h film is under a pixel of slider travel). Gated like the slider on a known duration.
            IconButton(onClick = { onSeekBy(-SEEK_STEP_MS) }, enabled = duration > 0L) {
                Icon(
                    imageVector = Icons.Filled.Replay10,
                    contentDescription = "Back 10 seconds",
                    tint = if (duration > 0L) Color.White else Color.White.copy(alpha = 0.4f),
                )
            }
            IconButton(onClick = { onSeekBy(SEEK_STEP_MS) }, enabled = duration > 0L) {
                Icon(
                    imageVector = Icons.Filled.Forward10,
                    contentDescription = "Forward 10 seconds",
                    tint = if (duration > 0L) Color.White else Color.White.copy(alpha = 0.4f),
                )
            }
            Text(
                text = formatTime(if (scrubbing && duration > 0L) (scrubValue * duration).toLong() else position),
                color = Color.White,
                fontSize = 12.sp,
                modifier = Modifier.width(52.dp),
            )
            Slider(
                value = sliderValue,
                onValueChange = {
                    onInteraction()
                    scrubbing = true
                    scrubValue = it
                },
                onValueChangeFinished = {
                    if (duration > 0L) onSeek((scrubValue * duration).toLong())
                    scrubbing = false
                },
                enabled = duration > 0L,
                colors = SliderDefaults.colors(
                    thumbColor = emberAccent,
                    activeTrackColor = emberAccent,
                ),
                modifier = Modifier.weight(1f),
            )
            Text(
                text = formatTime(duration),
                color = Color.White,
                fontSize = 12.sp,
                modifier = Modifier.width(52.dp),
            )
        }
    }
}

/// One control-cluster icon button (white, or [tint]-highlighted when its state is active).
@Composable
private fun ChromeIcon(icon: ImageVector, description: String, tint: Color = Color.White, onClick: () -> Unit) {
    IconButton(onClick = onClick) {
        Icon(imageVector = icon, contentDescription = description, tint = tint)
    }
}

/// A track label: prefer the add-on/embed title, append the language when both are present and differ.
private fun trackLabel(title: String, lang: String?): String {
    if (lang.isNullOrBlank() || title.contains(lang, ignoreCase = true)) return title.ifBlank { lang ?: "Track" }
    return "$title ($lang)"
}

/// Trim a speed multiplier for display: "1.5" not "1.5x1.0", "0.75" not "0.750000".
private fun trimSpeed(speed: Float): String {
    val s = "%.2f".format(speed).trimEnd('0').trimEnd('.')
    return s.ifEmpty { "1" }
}

/// Milliseconds -> H:MM:SS / M:SS. No dependency on any engine. Internal (was private): the gesture
/// seek HUD (PlayerGestures.kt) renders the same H:MM:SS shape, and one formatter keeps the two
/// surfaces from ever drifting.
internal fun formatTime(ms: Long): String {
    val totalSeconds = (ms / 1000).coerceAtLeast(0L)
    val hours = totalSeconds / 3600
    val minutes = (totalSeconds % 3600) / 60
    val seconds = totalSeconds % 60
    return if (hours > 0) {
        "%d:%02d:%02d".format(hours, minutes, seconds)
    } else {
        "%d:%02d".format(minutes, seconds)
    }
}

@Composable
private fun ChromeBadge(text: String, accent: Color) {
    Text(
        text = text,
        color = Color.White,
        fontSize = 10.sp,
        fontWeight = FontWeight.Bold,
        // The SOURCE / DOLBY VISION / speed badges as ember glass (was a near-opaque accent fill): the
        // prominent glass keeps the ember color but reads as tinted glass over the video frame.
        modifier = Modifier
            .vortxGlassProminent(shape = RoundedCornerShape(6.dp), tint = accent)
            .padding(horizontal = 8.dp, vertical = 3.dp),
    )
}

/// True when the device's default display advertises Dolby Vision in its HDR capabilities. This gates
/// the DV badge only; it does not influence decoding (the ExoPlayer engine's DefaultRenderersFactory
/// handles the codec fallback). Uses the modern Display API on R+ and reports false on older releases
/// where the capability query is unavailable.
fun displaySupportsDolbyVision(context: Context): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
    val display: Display? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        context.display
    } else {
        @Suppress("DEPRECATION")
        (context.getSystemService(Context.WINDOW_SERVICE) as? android.view.WindowManager)?.defaultDisplay
    }
    @Suppress("DEPRECATION")
    val hdr = display?.hdrCapabilities ?: return false
    return hdr.supportedHdrTypes.contains(Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION)
}
