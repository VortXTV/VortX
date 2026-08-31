package com.vortx.android.player

import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.view.Display
import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.layout.height
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
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.Audiotrack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Forward10
import androidx.compose.material.icons.filled.Forward30
import androidx.compose.material.icons.filled.Replay30
import androidx.compose.material.icons.filled.HighQuality
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PictureInPictureAlt
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay10
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
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
import androidx.compose.runtime.rememberCoroutineScope
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.vortx.android.R
import com.vortx.android.VortXApplication
import com.vortx.android.engine.StreamRanking
import com.vortx.android.player.extras.AutoLandscapeSetting
import com.vortx.android.player.extras.HdrToneMapSetting
import com.vortx.android.player.extras.KeepPlayingBackgroundSetting
import com.vortx.android.player.extras.PlayerHandoff
import com.vortx.android.player.extras.SeekBarStyle
import com.vortx.android.player.extras.SkipBand
import com.vortx.android.player.extras.StyledScrubber
import com.vortx.android.player.subtitles.SubtitlePoolClient
import com.vortx.android.model.Episode
import com.vortx.android.model.LanguagePriority
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamSource
import com.vortx.android.model.TrackPreferences
import com.vortx.android.model.TrackPreferencesStore
import com.vortx.android.ui.components.qrBitmap
import com.vortx.android.ui.theme.VortXGlass
import com.vortx.android.ui.theme.vortxGlass
import com.vortx.android.ui.theme.vortxGlassPanel
import com.vortx.android.ui.theme.vortxGlassProminent
import java.net.URI
import kotlinx.coroutines.launch
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
    /// The honest dynamic-range line for the Playback Info sheet ("Dolby Vision" on the DV lane, "HDR10
    /// (tone-mapped from Dolby Vision)" for a DV source on the libmpv lane). Null omits the row.
    dynamicRange: String? = null,
    /// The relative-seek step (ms + whole seconds) for the transport +/- buttons, from the viewer's Skip
    /// step setting (Apple `stremiox.seekStep`). Defaults keep the chrome usable in isolation at 10s.
    seekStepMs: Long = 10_000L,
    seekStepSeconds: Int = 10,
    /// In-player volume (0..100) + mute, driving the engine at [onSetVolume] / [onToggleMute] (Apple
    /// `stremiox.playerVolume` / `stremiox.playerMuted`). The same value the right-half swipe moves.
    playerVolume: Double = 100.0,
    playerMuted: Boolean = false,
    onSetVolume: (Double) -> Unit = {},
    onToggleMute: () -> Unit = {},
    emberAccent: Color,
    speed: Float,
    scaleMode: VideoScaleMode,
    chapters: List<PlayerChapter>,
    /// Skippable intro/recap/credits/preview segments for THIS title, drawn as coloured bands on the
    /// scrubber (the host maps its [com.vortx.android.skip.SkipSegment] list to a colour per kind). Empty
    /// leaves the scrubber unbanded. See [StyledScrubber].
    skipBands: List<SkipBand> = emptyList(),
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
    /// Google Cast control slot (the CAST lane), supplied by the host and rendered in the top control
    /// cluster next to Picture-in-Picture. Null (the default) draws nothing, keeping the chrome usable in
    /// isolation and on hosts/devices with no Cast subsystem. The host gates the slot on the stream being
    /// castable (a direct/HLS/debrid URL, never a loopback torrent) AND the Cast framework being available;
    /// the composable it passes self-hides further when no receivers are on the network. This is the
    /// Android analogue of the Apple in-player AirPlay route-picker button.
    castButton: (@Composable () -> Unit)? = null,
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
    /// HDR tone-map control (mpv-only; hidden on the Dolby Vision player, whose HDR/DV is hardware). The
    /// chrome persists the mode itself (Apple `stremiox.hdrToneMapMode`) and calls [onApplyHdrToneMap] so the
    /// host re-applies it to the live engine.
    hdrToneMapAvailable: Boolean = false,
    onApplyHdrToneMap: () -> Unit = {},
    /// Opens the "contribute a skip time" editor. Non-null only for a submittable title (an IMDb id, not
    /// live), gated by the host with [com.vortx.android.player.extras.SkipEditPolicy]; null hides the row.
    onSubmitSkipTime: (() -> Unit)? = null,
    /// TV-ONLY additions (the phone host leaves both at their defaults, so its chrome is byte-for-byte
    /// unchanged). [shareLink] is the raw usable link this stream can be shared as -- a direct/debrid URL, or a
    /// magnet URI rebuilt from a torrent's info-hash -- and, when non-null, adds a "QR for your phone" row to
    /// the Player Settings sheet that opens a full-screen QR (the 10-foot analogue of Apple's in-player
    /// StreamLinkQR). [isTvPlayer], when true, adds a preferred-audio-language picker to the Audio
    /// sheet and a subtitle-language + forced/always policy picker to the Subtitles sheet, both writing through
    /// the SAME [TrackPreferencesStore] the phone Playback Settings and the auto-picker read, so a couch change
    /// moves the same cross-platform keys. The in-player per-track pick (embedded audio/subtitle tracks) is the
    /// shared chrome above and already works on TV; these add the persistent LANGUAGE preference that the phone
    /// edits in Settings, which the TV has no keyboard-driven Settings equivalent for.
    shareLink: String? = null,
    isTvPlayer: Boolean = false,
    modifier: Modifier = Modifier,
) {
    // Which selection sheet (if any) is open. Local to the chrome; the engine never sees it.
    var openSheet by remember(playable.url, playbackSessionRevision) { mutableStateOf(ControlSheet.NONE) }
    // Session-only source hint, deliberately separate from [trackPrefs]. It reorders release-name metadata in
    // Sources but never writes the user's preferred audio language or selects an engine track. The live engine's
    // [PlayerState.audioTracks] remains the authority once a source mounts.
    var sourceAudioLanguageHint by remember { mutableStateOf<String?>(null) }
    val sourceChoices = remember(sourceOptions, currentSource, sourceAudioLanguageHint) {
        playerSourceChoices(sourceOptions, currentSource, sourceAudioLanguageHint)
    }
    val qualityChoices = remember(qualityOptions, currentSource) { playerQualityChoices(qualityOptions, currentSource) }
    val episodeChoices = remember(episodeOptions, playable.mediaRef) {
        playerEpisodeChoices(episodeOptions, playable.mediaRef)
    }
    val overflowPlacement = playerChromeActionPlacement(
        hasQualityChoices = qualityChoices.size > 1,
        hasEpisodes = episodeChoices.size > 1,
        hasChapters = chapters.isNotEmpty(),
        canShare = PlayerHandoff.canRouteExternally(playable),
        hasPip = onEnterPip != null,
        hasLock = onLock != null,
        hasCastSlot = castButton != null,
    )
    val sourcesTitle = stringResource(R.string.player_sources)
    val sourcesDescription = stringResource(R.string.player_sources_action_description)
    val qualityTitle = stringResource(R.string.player_quality)
    val qualityDescription = stringResource(R.string.player_quality_action_description)
    val switchingSource = stringResource(R.string.player_switching_source)
    val switchFailed = stringResource(R.string.player_source_switch_failed)
    // The player opens above a previously focused detail screen. Explicitly park the TV remote on the
    // Back affordance rather than depending on Compose focus search to discover this newly composed layer.
    val tvChromeFocus = remember { FocusRequester() }
    val tvSourcesFocus = remember { FocusRequester() }
    val tvAudioFocus = remember { FocusRequester() }
    val tvSubtitleFocus = remember { FocusRequester() }
    val tvMoreFocus = remember { FocusRequester() }
    // A sheet returns to the control that opened it. This must be per-open rather than a sticky boolean:
    // after a More drill-in closes, a later Sources sheet must return to Sources, not stale More.
    var focusReturnTarget by remember { mutableStateOf<FocusRequester?>(null) }
    fun openSheetFromControl(sheet: ControlSheet, invoker: FocusRequester) {
        focusReturnTarget = invoker
        openSheet = sheet
    }
    fun openMoreSubsheet(sheet: ControlSheet) = openSheetFromControl(sheet, tvMoreFocus)
    LaunchedEffect(isTvPlayer, controlsVisible, openSheet) {
        if (isTvPlayer && controlsVisible && openSheet == ControlSheet.NONE) {
            val focusTarget = focusReturnTarget ?: tvChromeFocus
            focusReturnTarget = null
            withFrameNanos { }
            runCatching { focusTarget.requestFocus() }
        }
    }
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

    // TV-only preferred-language state. The store handle is cheap (a SharedPreferences reference) and is only
    // ever read/written from the TV language sheets below, so constructing it unconditionally leaves the phone
    // chrome untouched. [trackPrefs] mirrors the persisted value so the sheets show the current pick and a
    // change round-trips to disk immediately.
    val context = LocalContext.current
    val trackStore = remember(context) {
        TrackPreferencesStore(context.applicationContext, PerformanceMode.isConstrainedDevice(context))
    }
    var trackPrefs by remember { mutableStateOf(trackStore.current) }
    val engineChoices = remember { PlayerLaunchPolicy.choices(MpvEngineFactory.isBundled) }

    // WHY audit 07.5: only query the community pool when embedded + add-on choices are thin. IMDb is the
    // authority; the visible title/year and URL filename are soft release hints for fingerprint matching.
    val subtitleScope = rememberCoroutineScope()
    val poolSignedIn = (context.applicationContext as? VortXApplication)?.syncManager?.isSignedIn == true
    val poolThin = state.subtitleTracks.size + addonSubtitles.size < 2
    var pooledSubtitles by remember(playable.url, playbackSessionRevision) {
        mutableStateOf(emptyList<SubtitlePoolClient.PooledSubtitle>())
    }
    var poolLoadingId by remember(playable.url, playbackSessionRevision) { mutableStateOf<Int?>(null) }
    var poolGeneration by remember { mutableStateOf(0L) }
    LaunchedEffect(playable.url, playbackSessionRevision, poolThin, poolSignedIn) {
        val generation = ++poolGeneration
        pooledSubtitles = emptyList()
        poolLoadingId = null
        if (!poolThin || !poolSignedIn) return@LaunchedEffect
        val filename = runCatching { URI(playable.url).path.substringAfterLast('/') }.getOrNull()
        val ref = playable.mediaRef
        val result = SubtitlePoolClient.fetchForPlayback(
            ref = ref,
            title = ref?.title ?: playable.title,
            year = ref?.year,
            filename = filename,
            durationSecs = state.durationMs.takeIf { it > 0L }?.div(1000.0),
            isSignedIn = true,
        )
        if (poolGeneration == generation) pooledSubtitles = result.subs
    }

    // The persisted seek-bar style, read once and updatable live by the in-player Seek Bar Style sheet. A
    // change writes Apple's key immediately (so it rides the cross-device settings blob) and redraws the
    // scrubber on the next frame. Mirrors Apple `SeekBarStyle.current`.
    var seekBarStyle by remember { mutableStateOf(SeekBarStyle.current(context)) }

    // The persisted HDR tone-map mode (mpv-only), read once and updated live by its sheet.
    var hdrToneMapMode by remember { mutableStateOf(HdrToneMapSetting.currentMode(context)) }

    // "Keep playing in background" toggle state (device-scoped), shown in the Player Settings sheet.
    var keepPlayingBackground by remember { mutableStateOf(KeepPlayingBackgroundSetting.isEnabled(context)) }

    // "Auto-rotate to landscape" toggle state (phone-only), shown in the Player Settings sheet.
    var autoLandscape by remember { mutableStateOf(AutoLandscapeSetting.isEnabled(context)) }
    // Persist a new preference and apply it to the LIVE engine so the couch pick takes effect now, not just on
    // the next load. The subtitle apply keys off TrackSelector exactly as the auto-picker does (a -1 result is
    // "off"). Audio is left alone when neither the chain nor the English fallback matched (null id).
    fun applyPreferredAudioLanguage(code: String) {
        val next = trackPrefs.copy(audioLanguages = LanguagePriority.normalized(listOf(code) + trackPrefs.audioLanguages))
        trackPrefs = next
        trackStore.save(next)
        TrackSelector.select(state.audioTracks, state.subtitleTracks, next, trackStore.matchAudioSub)
            .audioId?.let { onSelectAudio(it) }
    }
    fun selectManualAudioTrack(track: PlayerTrack) {
        // WHY audit 08.2: a manual per-title pick promotes its clean language globally, matching Apple.
        val raw = track.lang?.trim()?.lowercase().orEmpty()
        val base = raw.substringBefore('-')
        val code = if (base.matches(Regex("[a-z]{2,3}")) && base !in setOf("und", "unknown", "zxx", "mul")) {
            TrackSelector.canonical(raw).takeIf { it.length == 2 && it.all(Char::isLetter) }
        } else {
            null
        }
        if (code != null) {
            val next = trackPrefs.copy(
                audioLanguages = LanguagePriority.normalized(listOf(code) + trackPrefs.audioLanguages),
            )
            trackPrefs = next
            trackStore.save(next)
        }
        onSelectAudio(track.id)
    }
    fun applySubtitlePreferences(next: TrackPreferences) {
        trackPrefs = next
        trackStore.save(next)
        val subtitleId = TrackSelector
            .select(state.audioTracks, state.subtitleTracks, next, trackStore.matchAudioSub)
            .subtitleId
        onSelectSubtitle(if (subtitleId == null || subtitleId < 0) null else subtitleId)
    }

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
                IconButton(onClick = onBack, modifier = Modifier.focusRequester(tvChromeFocus)) {
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
                // Keep the frequent source / track controls reachable in one remote move. Everything else
                // lives behind More so the title does not collapse into an unclickable icon strip on narrow
                // landscape phones or TV overscan layouts.
                ChromeIcon(Icons.Filled.Tune, sourcesDescription, modifier = Modifier.focusRequester(tvSourcesFocus)) {
                    onInteraction()
                    openSheetFromControl(ControlSheet.SOURCES, tvSourcesFocus)
                }
                ChromeIcon(Icons.Filled.Audiotrack, "Audio and output settings", modifier = Modifier.focusRequester(tvAudioFocus)) {
                    onInteraction()
                    openSheetFromControl(ControlSheet.AUDIO, tvAudioFocus)
                }
                ChromeIcon(Icons.Filled.Subtitles, "Subtitles", modifier = Modifier.focusRequester(tvSubtitleFocus)) {
                    onInteraction()
                    openSheetFromControl(ControlSheet.SUBTITLE, tvSubtitleFocus)
                }
                ChromeIcon(
                    Icons.Filled.MoreHoriz,
                    "More player controls",
                    modifier = Modifier.focusRequester(tvMoreFocus),
                ) {
                    onInteraction()
                    openSheetFromControl(ControlSheet.MORE, tvMoreFocus)
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
            seekStepMs = seekStepMs,
            seekStepSeconds = seekStepSeconds,
            onInteraction = onInteraction,
            scrubPreview = scrubPreview,
            seekBarStyle = seekBarStyle,
            chapters = chapters,
            skipBands = skipBands,
            modifier = Modifier
                .fillMaxWidth()
                .align(Alignment.BottomCenter),
        )

        // Selection sheets (audio / subtitle / speed) as a bottom overlay panel.
        when (openSheet) {
            ControlSheet.SOURCES -> ControlSelectionSheet(
                title = sourcesTitle,
                options = buildList {
                    // Apple TV parity: Sources starts with the Quality drill-in, then the session-only
                    // release-metadata audio hint, then the matching/re-ranked source rows.
                    add(
                        SheetOption(
                            label = qualityTitle,
                            selected = false,
                            detail = when (qualityChoices.size) {
                                0 -> "Unavailable"
                                1 -> "${qualityChoices.first().label} only"
                                else -> "${qualityChoices.size} options ›"
                            },
                            enabled = !sourceSwitching && qualityChoices.isNotEmpty(),
                            dismissOnPick = false,
                            onPick = { openSheet = ControlSheet.QUALITY },
                        ),
                    )
                    add(
                        SheetOption(
                            label = "Audio language",
                            selected = sourceAudioLanguageHint != null,
                            detail = sourceAudioLanguageHint?.let(::sourceLanguageLabel)?.plus(" ›") ?: "Auto ›",
                            enabled = !sourceSwitching,
                            dismissOnPick = false,
                            onPick = { openSheet = ControlSheet.SOURCE_AUDIO },
                        ),
                    )
                    add(SheetOption(sourcesTitle, false, enabled = false, isHeader = true))
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
            ControlSheet.SOURCE_AUDIO -> ControlSelectionSheet(
                title = "Source audio language",
                options = buildList {
                    add(
                        SheetOption(
                            label = "Auto",
                            detail = "Use normal source ranking",
                            selected = sourceAudioLanguageHint == null,
                            isChoice = true,
                            dismissOnPick = false,
                            onPick = {
                                sourceAudioLanguageHint = null
                                openSheet = ControlSheet.SOURCES
                            },
                        ),
                    )
                    TrackPreferences.commonLanguages.forEach { (code, label) ->
                        add(
                            SheetOption(
                                label = label,
                                detail = "Release-name hint",
                                selected = sourceAudioLanguageHint == code,
                                isChoice = true,
                                dismissOnPick = false,
                                onPick = {
                                    sourceAudioLanguageHint = code
                                    openSheet = ControlSheet.SOURCES
                                },
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
                                onPick = { selectManualAudioTrack(track) },
                            ),
                        )
                    }
                    // TV: the persistent preferred-audio-language pick (phone edits this in Settings).
                    if (isTvPlayer) {
                        add(
                            SheetOption(
                                label = "Preferred audio language",
                                selected = false,
                                detail = preferredLanguageDetail(trackPrefs.audioLanguages),
                                onPick = { openSheet = ControlSheet.AUDIO_LANGUAGE },
                                dismissOnPick = false,
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
            ControlSheet.VOLUME -> VolumeSheet(
                volume = playerVolume,
                muted = playerMuted,
                emberAccent = emberAccent,
                onSetVolume = onSetVolume,
                onToggleMute = onToggleMute,
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
                    pooledSubtitles.forEach { sub ->
                        add(
                            SheetOption(
                                label = "${sub.lang} · Community",
                                selected = false,
                                enabled = poolLoadingId == null,
                                isChoice = true,
                                onPick = {
                                    val generation = poolGeneration
                                    poolLoadingId = sub.id
                                    subtitleScope.launch {
                                        val local = SubtitlePoolClient.download(context, sub, isSignedIn = poolSignedIn)
                                        if (poolGeneration == generation) {
                                            poolLoadingId = null
                                            if (local != null) {
                                                onSelectAddonSubtitle(
                                                    AddonSubtitle("pool:${sub.id}", local, sub.lang, "Community"),
                                                )
                                            }
                                        }
                                    }
                                },
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
                    // TV: preferred subtitle language + the Off / Forced only / Always on policy.
                    if (isTvPlayer) {
                        add(
                            SheetOption(
                                label = "Subtitle language & forced",
                                selected = false,
                                detail = trackPrefs.forcedPolicy.label,
                                onPick = { openSheet = ControlSheet.SUBTITLE_LANGUAGE },
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
            ControlSheet.MORE -> ControlSelectionSheet(
                title = "More player controls",
                options = buildList {
                    if (PlayerChromeOverflowAction.QUALITY in overflowPlacement.overflow) {
                        add(SheetOption(qualityTitle, false, detail = "${qualityChoices.size} options ›", onPick = {
                            openMoreSubsheet(ControlSheet.QUALITY)
                        }, dismissOnPick = false))
                    }
                    if (PlayerChromeOverflowAction.EPISODES in overflowPlacement.overflow) {
                        add(SheetOption("Episodes", false, detail = "${episodeChoices.size} episodes ›", onPick = {
                            openMoreSubsheet(ControlSheet.EPISODES)
                        }, dismissOnPick = false))
                    }
                    add(
                        SheetOption(
                            label = "Volume",
                            selected = false,
                            detail = if (playerMuted || playerVolume <= 0.0) "Muted" else "${playerVolume.roundToInt()}%",
                            onPick = { openMoreSubsheet(ControlSheet.VOLUME) },
                            dismissOnPick = false,
                        ),
                    )
                    add(SheetOption("Playback speed", false, detail = "${trimSpeed(speed)}x", onPick = {
                        openMoreSubsheet(ControlSheet.SPEED)
                    }, dismissOnPick = false))
                    if (PlayerChromeOverflowAction.CHAPTERS in overflowPlacement.overflow) {
                        add(SheetOption(chaptersTitle, false, detail = "${chapters.size} chapters ›", onPick = {
                            openMoreSubsheet(ControlSheet.CHAPTERS)
                        }, dismissOnPick = false))
                    }
                    add(SheetOption("Aspect ratio", false, detail = videoScaleModeLabel(scaleMode), onPick = {
                        openMoreSubsheet(ControlSheet.VIDEO)
                    }, dismissOnPick = false))
                    if (PlayerChromeOverflowAction.SHARE in overflowPlacement.overflow) {
                        add(SheetOption("Share or open in another app", false, detail = "›", onPick = {
                            openMoreSubsheet(ControlSheet.SHARE)
                        }, dismissOnPick = false))
                    }
                    onEnterPip?.takeIf { PlayerChromeOverflowAction.PIP in overflowPlacement.overflow }?.let { pip ->
                        add(SheetOption("Picture in picture", false, onPick = { pip() }))
                    }
                    onLock?.takeIf { PlayerChromeOverflowAction.LOCK in overflowPlacement.overflow }?.let { lock ->
                        add(SheetOption("Lock player controls", false, onPick = { lock() }))
                    }
                    add(SheetOption("Player settings", false, detail = "›", onPick = {
                        openMoreSubsheet(ControlSheet.PLAYER_SETTINGS)
                    }, dismissOnPick = false))
                },
                emberAccent = emberAccent,
                accessory = castButton,
                onDismiss = {
                    restoreMoreFocus = true
                    openSheet = ControlSheet.NONE
                },
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
                            label = "Keep playing in background",
                            selected = keepPlayingBackground,
                            detail = "Audio continues with the screen off",
                            isChoice = true,
                            dismissOnPick = false,
                            onPick = {
                                keepPlayingBackground = !keepPlayingBackground
                                KeepPlayingBackgroundSetting.setEnabled(context, keepPlayingBackground)
                            },
                        ),
                    )
                    // Phone-only: the TV is always landscape, so the toggle is meaningless there.
                    if (!isTvPlayer) {
                        add(
                            SheetOption(
                                label = "Auto-rotate to landscape",
                                selected = autoLandscape,
                                detail = "Turn to landscape when a video opens",
                                isChoice = true,
                                dismissOnPick = false,
                                onPick = {
                                    autoLandscape = !autoLandscape
                                    AutoLandscapeSetting.setEnabled(context, autoLandscape)
                                },
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
                    // Contribute a skip time: only for a submittable title (host-gated on an IMDb id + not
                    // live). Opens the editor overlay the host draws above the chrome.
                    onSubmitSkipTime?.let { submit ->
                        add(
                            SheetOption(
                                label = "Contribute a skip time",
                                selected = false,
                                detail = "›",
                                onPick = { submit() },
                            ),
                        )
                    }
                    add(
                        SheetOption(
                            label = "Seek Bar Style",
                            selected = false,
                            detail = seekBarStyle.displayName,
                            onPick = { openSheet = ControlSheet.SEEK_BAR_STYLE },
                            dismissOnPick = false,
                        ),
                    )
                    // HDR tone mapping is mpv-only: the Dolby Vision player passes HDR through in hardware,
                    // so the row is hidden there rather than shown as a dead control.
                    if (hdrToneMapAvailable) {
                        add(
                            SheetOption(
                                label = "HDR Tone Mapping",
                                selected = false,
                                detail = hdrToneMapMode.label,
                                onPick = { openSheet = ControlSheet.HDR_TONE_MAP },
                                dismissOnPick = false,
                            ),
                        )
                    }
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
                    // TV: share THIS stream to a phone as a QR (a magnet for a torrent, else the raw URL). The
                    // host only supplies [shareLink] on TV, so the row never appears on the phone chrome.
                    if (shareLink != null) {
                        add(
                            SheetOption(
                                label = if (playable.isTorrent) "Magnet link · QR for your phone" else "Stream link · QR for your phone",
                                selected = false,
                                detail = "›",
                                onPick = { openSheet = ControlSheet.SHARE_QR },
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
            ControlSheet.SEEK_BAR_STYLE -> ControlSelectionSheet(
                title = "Seek Bar Style",
                options = SeekBarStyle.choices.map { candidate ->
                    SheetOption(
                        label = candidate.displayName,
                        selected = seekBarStyle == candidate,
                        isChoice = true,
                        dismissOnPick = false,
                        onPick = {
                            seekBarStyle = candidate
                            SeekBarStyle.setCurrent(context, candidate)
                        },
                    )
                },
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.SHARE -> ControlSelectionSheet(
                title = "Share",
                options = listOf(
                    SheetOption(
                        label = "Share link",
                        selected = false,
                        detail = "Send this stream's link",
                        onPick = { PlayerHandoff.shareStream(context, playable) },
                    ),
                    SheetOption(
                        label = "Open in another player",
                        selected = false,
                        detail = "Hand off to an installed video app",
                        onPick = { PlayerHandoff.openInExternalPlayer(context, playable) },
                    ),
                ),
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.HDR_TONE_MAP -> ControlSelectionSheet(
                title = "HDR Tone Mapping",
                options = HdrToneMapSetting.Mode.entries.map { mode ->
                    SheetOption(
                        label = mode.label,
                        detail = mode.detail,
                        selected = hdrToneMapMode == mode,
                        isChoice = true,
                        dismissOnPick = false,
                        onPick = {
                            hdrToneMapMode = mode
                            HdrToneMapSetting.setMode(context, mode)
                            onApplyHdrToneMap()
                        },
                    )
                },
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.INFO -> ControlSelectionSheet(
                title = "Playback Info",
                options = playbackInfoOptions(playable, currentSource, dynamicRange, playbackInfo()),
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.ENGINE -> ControlSelectionSheet(
                title = "Player Engine",
                options = engineChoices.map { choice ->
                    SheetOption(
                        label = choice.label,
                        detail = choice.detail,
                        selected = enginePreference == choice.preference,
                        isChoice = true,
                        dismissOnPick = false,
                        onPick = { onSelectEnginePreference(choice.preference) },
                    )
                },
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.AUDIO_LANGUAGE -> ControlSelectionSheet(
                title = "Preferred audio language",
                options = TrackPreferences.commonLanguages.map { (code, label) ->
                    SheetOption(
                        label = label,
                        selected = TrackSelector.matches(trackPrefs.audioLanguages.firstOrNull(), code),
                        isChoice = true,
                        dismissOnPick = false,
                        onPick = { applyPreferredAudioLanguage(code) },
                    )
                },
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.SUBTITLE_LANGUAGE -> ControlSelectionSheet(
                title = "Subtitles",
                options = buildList {
                    add(SheetOption("When you have your audio language", false, enabled = false, isHeader = true))
                    TrackPreferences.ForcedPolicy.entries.forEach { policy ->
                        add(
                            SheetOption(
                                label = policy.label,
                                selected = trackPrefs.forcedPolicy == policy,
                                isChoice = true,
                                dismissOnPick = false,
                                onPick = { applySubtitlePreferences(trackPrefs.copy(forcedPolicy = policy)) },
                            ),
                        )
                    }
                    add(SheetOption("Preferred subtitle language", false, enabled = false, isHeader = true))
                    TrackPreferences.commonLanguages.forEach { (code, label) ->
                        add(
                            SheetOption(
                                label = label,
                                selected = TrackSelector.matches(trackPrefs.subtitleLanguages.firstOrNull(), code),
                                isChoice = true,
                                dismissOnPick = false,
                                onPick = {
                                    applySubtitlePreferences(
                                        trackPrefs.copy(
                                            subtitleLanguages = LanguagePriority.normalized(
                                                listOf(code) + trackPrefs.subtitleLanguages,
                                            ),
                                        ),
                                    )
                                },
                            ),
                        )
                    }
                },
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.SHARE_QR -> shareLink?.let { link ->
                StreamLinkQrOverlay(
                    link = link,
                    title = if (playable.isTorrent) "Magnet link" else "Stream link",
                    onDismiss = { openSheet = ControlSheet.NONE },
                )
            }
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
/// The seek target (ms) for a Previous-chapter press, or null when the playhead is already at the start of
/// the first chapter. Jumps to the START of the CURRENT chapter when more than 3s into it (the universal
/// "prev restarts this chapter first" behaviour), otherwise to the previous chapter's start.
private fun prevChapterTargetMs(chapters: List<PlayerChapter>, positionMs: Long): Long? {
    val starts = chapters.map { it.startMs }.sorted()
    val threshold = positionMs - 3_000L
    return starts.lastOrNull { it <= threshold }
        ?: starts.firstOrNull()?.takeIf { positionMs > it + 500L }
}

/// The seek target (ms) for a Next-chapter press: the first chapter boundary ahead of the playhead, or null
/// when the playhead is already in the last chapter.
private fun nextChapterTargetMs(chapters: List<PlayerChapter>, positionMs: Long): Long? =
    chapters.map { it.startMs }.sorted().firstOrNull { it > positionMs + 500L }

private enum class ControlSheet {
    NONE,
    SOURCES,
    SOURCE_AUDIO,
    QUALITY,
    EPISODES,
    VIDEO,
    AUDIO,
    VOLUME,
    SUBTITLE,
    SECOND_SUBTITLE,
    SUBTITLE_SETTINGS,
    AUDIO_SETTINGS,
    SPEED,
    CHAPTERS,
    MORE,
    PLAYER_SETTINGS,
    SLEEP,
    SEEK_BAR_STYLE,
    HDR_TONE_MAP,
    SHARE,
    INFO,
    ENGINE,
    // TV-only sheets (reached only when the host opts in via shareLink / isTvPlayer).
    AUDIO_LANGUAGE,
    SUBTITLE_LANGUAGE,
    SHARE_QR,
}

/**
 * The compact chrome contract deliberately does not vary with available width: the same four controls
 * fit a narrow landscape phone and an overscanned TV, and every optional control remains in [overflow].
 */
internal enum class PlayerChromeHeaderAction { SOURCES, AUDIO, SUBTITLES, MORE }

internal enum class PlayerChromeOverflowAction {
    QUALITY,
    EPISODES,
    VOLUME,
    SPEED,
    CHAPTERS,
    ASPECT_RATIO,
    SHARE,
    PIP,
    LOCK,
    SETTINGS,
    CAST,
}

internal data class PlayerChromeActionPlacement(
    val header: List<PlayerChromeHeaderAction>,
    val overflow: List<PlayerChromeOverflowAction>,
)

internal fun playerChromeActionPlacement(
    hasQualityChoices: Boolean,
    hasEpisodes: Boolean,
    hasChapters: Boolean,
    canShare: Boolean,
    hasPip: Boolean,
    hasLock: Boolean,
    hasCastSlot: Boolean,
): PlayerChromeActionPlacement = PlayerChromeActionPlacement(
    header = PlayerChromeHeaderAction.entries,
    overflow = buildList {
        if (hasQualityChoices) add(PlayerChromeOverflowAction.QUALITY)
        if (hasEpisodes) add(PlayerChromeOverflowAction.EPISODES)
        add(PlayerChromeOverflowAction.VOLUME)
        add(PlayerChromeOverflowAction.SPEED)
        if (hasChapters) add(PlayerChromeOverflowAction.CHAPTERS)
        add(PlayerChromeOverflowAction.ASPECT_RATIO)
        if (canShare) add(PlayerChromeOverflowAction.SHARE)
        if (hasPip) add(PlayerChromeOverflowAction.PIP)
        if (hasLock) add(PlayerChromeOverflowAction.LOCK)
        add(PlayerChromeOverflowAction.SETTINGS)
        if (hasCastSlot) add(PlayerChromeOverflowAction.CAST)
    },
)

internal fun videoScaleModeLabel(mode: VideoScaleMode): String = when (mode) {
    VideoScaleMode.FIT -> "Fit"
    VideoScaleMode.ZOOM -> "Fill"
    VideoScaleMode.STRETCH -> "Stretch"
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

/// The playback-speed presets offered in the speed sheet.
private val SPEED_PRESETS = listOf(0.5f, 0.75f, 1.0f, 1.25f, 1.5f, 2.0f)

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

/// The right-aligned human label of the top preferred language (TV language rows), e.g. "English".
private fun preferredLanguageDetail(languages: List<String>): String {
    val code = languages.firstOrNull() ?: return ""
    return TrackPreferences.commonLanguages.firstOrNull { it.first == code }?.second ?: code.uppercase()
}

private fun sourceLanguageLabel(code: String): String =
    TrackPreferences.commonLanguages.firstOrNull { it.first == code }?.second ?: code.uppercase()

/// The TV per-stream share overlay: a full-screen QR of [link] (a magnet for a torrent, else the raw stream
/// URL) so a viewer can hand the exact stream to their phone. The 10-foot analogue of Apple's `StreamLinkQR`.
/// D-pad Back and Select both dismiss it. Renders nothing over the video except while open.
@Composable
private fun StreamLinkQrOverlay(link: String, title: String, onDismiss: () -> Unit) {
    BackHandler { onDismiss() }
    val bitmap = remember(link) { qrBitmap(link, 512) }
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.94f))
            .clickable(onClick = onDismiss),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(title, color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 22.sp)
            if (bitmap != null) {
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(16.dp))
                        .background(Color.White)
                        .padding(20.dp),
                ) {
                    Image(
                        bitmap = bitmap.asImageBitmap(),
                        contentDescription = "QR code for $title",
                        modifier = Modifier.size(360.dp),
                    )
                }
            } else {
                Text("Could not build a code for this link.", color = Color.White, fontSize = 14.sp)
            }
            Text(
                text = link,
                color = Color.White.copy(alpha = 0.75f),
                fontSize = 13.sp,
                maxLines = 2,
            )
            Text(
                text = "Scan with your phone to open this stream there · Press Back to dismiss.",
                color = Color.White.copy(alpha = 0.75f),
                fontSize = 13.sp,
            )
        }
    }
}

/// Build the Playback Info sheet rows: the title, the current source (release / add-on / size), and the
/// live engine stats. Every row is informational (non-interactive). Mirrors the Apple Playback Info panel.
private fun playbackInfoOptions(
    playable: Playable,
    currentSource: StreamSource?,
    dynamicRange: String?,
    stats: List<Pair<String, String>>,
): List<SheetOption> = buildList {
    add(SheetOption("Now Playing", false, enabled = false, isHeader = true))
    add(SheetOption(playable.title, false, enabled = false))
    // The honest dynamic-range line: true Dolby Vision on the DV lane, or "HDR10 (tone-mapped from Dolby
    // Vision)" for a DV source on the libmpv lane, so the app never claims DV over tone-mapped pixels.
    dynamicRange?.let { add(SheetOption("Dynamic range", false, detail = it, enabled = false)) }
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
    accessory: (@Composable () -> Unit)? = null,
    onDismiss: () -> Unit,
) {
    // The active overlay owns Remote Back/Escape. Letting it fall through would exit the player instead
    // of closing the topmost sheet and restoring the compact chrome's expected focus target.
    BackHandler { onDismiss() }
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
                        .heightIn(min = 48.dp)
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
            // Cast is supplied as a host-owned composable because it owns discovery and connection state.
            // Keeping that slot in More preserves its self-hiding availability contract without returning it
            // to the constrained top row.
            accessory?.let { content ->
                Box(modifier = Modifier.fillMaxWidth()) { content() }
            }
        }
    }
}

/// The in-player Volume sheet: a horizontal level slider (0..100) plus a Mute toggle, driving the engine
/// through [onSetVolume] / [onToggleMute] (the same value the right-half swipe moves). A lightweight glass
/// panel matching the other control sheets. Mirrors the Apple in-player volume slider + mute.
@Composable
private fun VolumeSheet(
    volume: Double,
    muted: Boolean,
    emberAccent: Color,
    onSetVolume: (Double) -> Unit,
    onToggleMute: () -> Unit,
    onDismiss: () -> Unit,
) {
    // Unlike a phone touch target, a TV remote needs an explicit entry point when the overlay appears.
    // Start on the labeled mute control rather than relying on focus search to discover the slider.
    val muteFocus = remember { FocusRequester() }
    BackHandler { onDismiss() }
    LaunchedEffect(Unit) {
        withFrameNanos { }
        runCatching { muteFocus.requestFocus() }
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
                .vortxGlassPanel(RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp))
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = "Volume",
                color = Color.White,
                fontWeight = FontWeight.Bold,
                fontSize = 15.sp,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = if (muted || volume <= 0.0) {
                        Icons.AutoMirrored.Filled.VolumeOff
                    } else {
                        Icons.AutoMirrored.Filled.VolumeUp
                    },
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(28.dp),
                )
                Slider(
                    value = (volume / 100.0).toFloat().coerceIn(0f, 1f),
                    onValueChange = { onSetVolume((it * 100.0)) },
                    colors = SliderDefaults.colors(
                        thumbColor = emberAccent,
                        activeTrackColor = emberAccent,
                    ),
                    modifier = Modifier
                        .weight(1f)
                        .padding(horizontal = 12.dp),
                )
                Text(
                    text = "${(volume).roundToInt()}%",
                    color = Color.White,
                    fontSize = 13.sp,
                    modifier = Modifier.width(44.dp),
                )
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(8.dp))
                    .focusRequester(muteFocus)
                    .clickable(role = Role.Button, onClick = onToggleMute)
                    .heightIn(min = 48.dp)
                    .padding(vertical = 10.dp, horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = if (muted) "Unmute" else "Mute",
                    color = if (muted) emberAccent else Color.White,
                    fontWeight = if (muted) FontWeight.SemiBold else FontWeight.Normal,
                    fontSize = 15.sp,
                    modifier = Modifier.weight(1f),
                )
                if (muted) {
                    Icon(
                        imageVector = Icons.Filled.Check,
                        contentDescription = null,
                        tint = emberAccent,
                        modifier = Modifier.size(20.dp),
                    )
                }
            }
        }
    }
}

/// The error fallback overlay: a centered message + a "Choose another source" action that returns to the
/// ranked source list, plus a plain back. Shown when [PlayerState.hasError] is set.
@Composable
private fun PlayerErrorOverlay(emberAccent: Color, onRetry: () -> Unit, onBack: () -> Unit) {
    val recoveryFocus = remember { FocusRequester() }
    LaunchedEffect(Unit) {
        withFrameNanos { }
        runCatching { recoveryFocus.requestFocus() }
    }
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
                        .focusRequester(recoveryFocus)
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
    seekStepMs: Long = 10_000L,
    seekStepSeconds: Int = 10,
    /// Reported on every scrub drag frame so the host's auto-hide timer cannot expire mid-gesture and
    /// yank the slider out from under the finger. No-op by default.
    onInteraction: () -> Unit = {},
    scrubPreview: (Double) -> Bitmap? = { null },
    seekBarStyle: SeekBarStyle = SeekBarStyle.CLASSIC,
    chapters: List<PlayerChapter> = emptyList(),
    skipBands: List<SkipBand> = emptyList(),
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
        Row(
            verticalAlignment = Alignment.CenterVertically,
            // AUDIT 12 a11y: one TalkBack focus point exposes the whole transport instead of forcing a
            // hunt through individually-labelled icon buttons.
            modifier = Modifier.semantics {
                customActions = listOf(
                    CustomAccessibilityAction("Play or pause") { onTogglePause(); true },
                    CustomAccessibilityAction("Back $seekStepSeconds seconds") {
                        if (duration > 0L) onSeekBy(-seekStepMs)
                        true
                    },
                    CustomAccessibilityAction("Forward $seekStepSeconds seconds") {
                        if (duration > 0L) onSeekBy(seekStepMs)
                        true
                    },
                )
            },
        ) {
            IconButton(
                onClick = onTogglePause,
                modifier = Modifier.semantics {
                    stateDescription = if (state.isPaused) "Paused" else "Playing"
                },
            ) {
                Icon(
                    imageVector = if (state.isPaused) Icons.Filled.PlayArrow else Icons.Filled.Pause,
                    contentDescription = if (state.isPaused) "Play" else "Pause",
                    tint = Color.White,
                )
            }
            // The +/-N jump controls (the relative seek the scrubber physically cannot do: 10s of a 2h film
            // is under a pixel of slider travel). The step follows the viewer's Skip step (Apple
            // `stremiox.seekStep`); the glyph picks the nearest available Replay/Forward icon. Gated like the
            // slider on a known duration.
            val backIcon = if (seekStepSeconds >= 30) Icons.Filled.Replay30 else Icons.Filled.Replay10
            val forwardIcon = if (seekStepSeconds >= 30) Icons.Filled.Forward30 else Icons.Filled.Forward10
            IconButton(onClick = { onSeekBy(-seekStepMs) }, enabled = duration > 0L) {
                Icon(
                    imageVector = backIcon,
                    contentDescription = "Back $seekStepSeconds seconds",
                    tint = if (duration > 0L) Color.White else Color.White.copy(alpha = 0.4f),
                )
            }
            IconButton(onClick = { onSeekBy(seekStepMs) }, enabled = duration > 0L) {
                Icon(
                    imageVector = forwardIcon,
                    contentDescription = "Forward $seekStepSeconds seconds",
                    tint = if (duration > 0L) Color.White else Color.White.copy(alpha = 0.4f),
                )
            }
            // Previous / next CHAPTER jumps: shown only for a title that actually carries chapters (the
            // mpv engine reads `chapter-list`; a title with none leaves the pair absent, so the transport
            // is byte-for-byte unchanged for the common case). Each is disabled when there is no boundary
            // in that direction. Mirrors the Apple player's prev/next chapter controls.
            if (chapters.size >= 2) {
                val prevTarget = prevChapterTargetMs(chapters, position)
                val nextTarget = nextChapterTargetMs(chapters, position)
                IconButton(onClick = { prevTarget?.let(onSeek) }, enabled = prevTarget != null) {
                    Icon(
                        imageVector = Icons.Filled.SkipPrevious,
                        contentDescription = "Previous chapter",
                        tint = if (prevTarget != null) Color.White else Color.White.copy(alpha = 0.4f),
                    )
                }
                IconButton(onClick = { nextTarget?.let(onSeek) }, enabled = nextTarget != null) {
                    Icon(
                        imageVector = Icons.Filled.SkipNext,
                        contentDescription = "Next chapter",
                        tint = if (nextTarget != null) Color.White else Color.White.copy(alpha = 0.4f),
                    )
                }
            }
            Text(
                text = formatTime(if (scrubbing && duration > 0L) (scrubValue * duration).toLong() else position),
                color = Color.White,
                fontSize = 12.sp,
                modifier = Modifier.width(52.dp),
            )
            StyledScrubber(
                displayProgress = sliderValue,
                bufferedFraction = if (duration > 0L) {
                    (state.bufferedPositionMs.toFloat() / duration.toFloat())
                } else {
                    0f
                },
                durationSeconds = duration / 1000.0,
                accent = emberAccent,
                style = seekBarStyle,
                // Freeze the per-frame motion while paused (Apple's `animated: !paused`): the played fill
                // and knob still show, only the animation stops, which saves power on a paused player.
                animated = !state.isPaused,
                chapterStartsSeconds = chapters.map { it.startMs / 1000.0 },
                skipBands = skipBands,
                enabled = duration > 0L,
                onScrubStart = {
                    onInteraction()
                    scrubbing = true
                },
                onScrub = {
                    onInteraction()
                    scrubbing = true
                    scrubValue = it
                },
                onScrubEnd = {
                    if (duration > 0L) onSeek((it * duration).toLong())
                    scrubbing = false
                },
                modifier = Modifier
                    .weight(1f)
                    .height(30.dp),
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
private fun ChromeIcon(
    icon: ImageVector,
    description: String,
    tint: Color = Color.White,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    IconButton(onClick = onClick, modifier = modifier) {
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
