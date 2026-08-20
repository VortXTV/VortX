package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.MaterialTheme as TvMaterialTheme
import androidx.tv.material3.darkColorScheme as tvDarkColorScheme
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.PlaybackSessionLifecycle
import com.vortx.android.data.PreviewAuthRepository
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.deeplink.VortXDeepLinkEvent
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.MetaItem
import com.vortx.android.model.Episode
import com.vortx.android.model.Playable
import com.vortx.android.player.BadSourceAutoRetrySetting
import com.vortx.android.player.EpisodeProgressionPolicy
import com.vortx.android.player.NextEpisodePreloadPolicy
import com.vortx.android.player.PlayerEpisodeHistoryIdentity
import com.vortx.android.player.PlayerScreen
import com.vortx.android.player.advancePlayerEpisodeHistory
import com.vortx.android.profile.ProfileStore
import com.vortx.android.sources.SourceSettingsRevision
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.update.UpdatePromptHost
import com.vortx.android.ui.detailViewModelKey
import com.vortx.android.ui.theme.VortXAccents
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.DetailViewModel
import com.vortx.android.ui.viewmodel.Playback
import com.vortx.android.ui.viewmodel.StremioXViewModelFactory
import com.vortx.android.ui.viewmodel.rememberReplacingViewModelStoreOwner
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay

/// The Android TV shell: a three-state D-pad flow (Home browse -> Detail -> Player) that is the 10-foot
/// analogue of the phone [com.vortx.android.ui.VortXApp], reusing the exact same seams underneath.
///
/// This is the FIRST TV slice. It deliberately covers Home + Detail + Play only; the phone shell's Discover
/// / Library / Search / Settings tabs, the source long-press / pin menu, the episode+season browser, and
/// the in-player overlay are NOT reproduced here yet (see the honest gap list in the session report). What
/// IS here is real: the rows come from the same engine repository, the detail + play come from the same
/// [DetailViewModel], and playback runs on the same [PlayerScreen].
///
/// [repo]/[auth] default to the offline preview so a Compose @Preview / test can drive the TV shell without
/// the engine, exactly like [com.vortx.android.ui.VortXApp].
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
fun TvApp(
    repo: CatalogRepository = PreviewCatalogRepository(),
    auth: AuthRepository = PreviewAuthRepository(),
    syncManager: VortXSyncManager? = null,
    deepLinkEvent: VortXDeepLinkEvent? = null,
) {
    val profileStore = ProfileStore.sharedOrNull()
    val activeProfile by (profileStore?.activeProfile?.collectAsStateWithLifecycle()
        ?: remember { mutableStateOf(null) })

    VortXTheme(
        accentId = activeProfile?.accentID ?: VortXAccents.default.id,
        oled = activeProfile?.oled ?: false,
    ) {
        // WHO'S WATCHING launch gate (the 10-foot mirror of VortXApp's): with more than one profile and no
        // pick yet this cold launch, cover everything with the picker until a profile settles, so no title's
        // Home wall leaks before the viewer is known. Back keeps the current profile (re-selects it, which
        // marks the launch picked) and dismisses. A single-profile install and a pick already made this launch
        // skip it by construction, because ProfileStore.needsPicker is false in both cases.
        var showPicker by remember { mutableStateOf(profileStore?.needsPicker == true) }
        if (showPicker) {
            BackHandler {
                val store = profileStore
                if (store != null) store.active?.let { store.select(it) }
                showPicker = false
            }
            TvWhosWatching(onDone = { showPicker = false })
            return@VortXTheme
        }

        // The title currently open in Detail; null = the Home browse wall.
        var detail by remember { mutableStateOf<MetaItem?>(null) }
        var detailGeneration by remember { mutableStateOf(0L) }
        // The resolved source currently playing; null = not in the player. The DETAIL page resolves a
        // chosen source into this [Playable] (through [DetailViewModel]); the shell then covers everything
        // with the player, exactly as the phone shell keys [PlayerScreen] off its own `playing` slot.
        var playing by remember { mutableStateOf<Playable?>(null) }
        var playingMeta by remember { mutableStateOf<MetaDetail?>(null) }

        LaunchedEffect(deepLinkEvent) {
            val event = deepLinkEvent ?: return@LaunchedEffect
            val target = event.target
            playing = null
            playingMeta = null
            detailGeneration += 1
            detail = target.toMetaItem()
        }

        val appContext = LocalContext.current.applicationContext
        val debridKeys = remember(appContext) { DebridKeys(appContext) }
        // Collect session truth so an account-generation transition recreates the title ViewModel and drops
        // account-derived cache badges/resume refs on TV just as it does in the phone shell.
        val sessionUiState by (
            syncManager?.sessionUiState?.collectAsStateWithLifecycle()
                ?: remember { mutableStateOf<VortXSyncManager.SessionUiState?>(null) }
        )
        val debridOwnerEpoch = remember(sessionUiState) {
            debridKeys.ownerToken()?.let { "${it.identity}:${it.generation}" } ?: "unknown"
        }
        val debridCredentialRevision by DebridKeys.credentialRevision.collectAsStateWithLifecycle()
        val sourceSettingsRevision by SourceSettingsRevision.observe(appContext).collectAsStateWithLifecycle()
        val detailSourceEpoch = "$debridOwnerEpoch:$debridCredentialRevision:$sourceSettingsRevision"
        val detailVmOwner = rememberReplacingViewModelStoreOwner(
            detail?.let { "${it.type}:${it.id}:$detailSourceEpoch" } ?: "no-detail:$detailSourceEpoch",
        )
        // A scope tied to the whole shell (not the player layer), so the end-of-playback engine write (final
        // progress tick + Player unload) still completes after the player leaves composition -- the same
        // reason the phone shell uses an app-scoped coroutine for this.
        val appScope = rememberCoroutineScope()
        val playbackSessions = remember(repo, appScope) { PlaybackSessionLifecycle(repo, appScope) }

        // Player is the topmost layer. When a source resolves to a [Playable] it covers Home/Detail and back
        // returns to the detail page underneath. The begin/report/end-playback-session calls mirror
        // VortXApp exactly, so Continue Watching + resume track on TV the same way they do on the phone.
        val playable = playing
        val playerDetail = detail
        val playerVm: DetailViewModel? = if (playable != null && playerDetail != null && !playable.isTrailer) {
            viewModel(
                viewModelStoreOwner = detailVmOwner,
                key = detailViewModelKey(
                    prefix = "tv-detail",
                    typeId = playerDetail.type.id,
                    mediaId = playerDetail.id,
                    ownerEpoch = detailSourceEpoch,
                ),
                factory = StremioXViewModelFactory(
                    repo = repo,
                    detailArgs = StremioXViewModelFactory.DetailArgs(playerDetail.type, playerDetail.id),
                    appContext = appContext,
                ),
            )
        } else {
            null
        }
        if (playable != null) {
            // History identity for the engine playback session; an in-player episode switch advances it so
            // the finished episode's history session ends and the new episode's begins.
            var historyIdentity by remember(playable) {
                mutableStateOf(PlayerEpisodeHistoryIdentity(playable))
            }
            val playbackHistory = remember(historyIdentity) {
                TvPlaybackHistorySession(historyIdentity, playbackSessions)
            }
            val playerSourceState = if (playerVm != null) {
                playerVm.streams.collectAsStateWithLifecycle().value
            } else {
                null
            }
            val playerSourceOptions = remember(playerVm, playerSourceState) {
                playerVm?.playerSourceOptions().orEmpty()
            }
            val playerQualityOptions = remember(playerVm, playerSourceState) {
                playerVm?.playerQualityOptions().orEmpty()
            }
            val playerEpisodeOptions = remember(playerVm, playerSourceState) {
                playerVm?.playerEpisodeOptions().orEmpty()
            }
            val preloadPolicy = remember(historyIdentity) { NextEpisodePreloadPolicy() }
            val episodeProgression = remember(historyIdentity) { EpisodeProgressionPolicy() }
            DisposableEffect(historyIdentity) {
                onDispose {
                    preloadPolicy.invalidate()
                    episodeProgression.invalidate()
                }
            }
            val autoAdvanceStreak = remember { intArrayOf(0) }
            var upNext by remember(playable) { mutableStateOf<Episode?>(null) }
            var upNextTarget by remember(playable) { mutableStateOf<EpisodeProgressionPolicy.Target?>(null) }
            var retryingSource by remember(playable) { mutableStateOf(false) }
            var retryResumePositionMs by remember(playable) { mutableStateOf(playable.startPositionMs) }
            val retryPlayback = if (playerVm != null) {
                playerVm.playback.collectAsStateWithLifecycle().value
            } else {
                Playback.Idle
            }
            LaunchedEffect(retryingSource, retryPlayback) {
                if (!retryingSource || playerVm == null) return@LaunchedEffect
                when (val state = retryPlayback) {
                    is Playback.Ready -> {
                        playerVm.clearPlayback()
                        retryingSource = false
                        playing = state.playable
                    }
                    is Playback.Failed -> {
                        playerVm.clearPlayback()
                        if (!playerVm.retryNextSource(retryResumePositionMs)) retryingSource = false
                    }
                    else -> Unit
                }
            }
            // D-pad Back pops the player back to the detail page rather than exiting the app.
            BackHandler { playing = null }
            DisposableEffect(historyIdentity) {
                playbackHistory.begin()
                onDispose {
                    playbackHistory.end()
                }
            }
            Box(Modifier.fillMaxSize()) {
            PlayerScreen(
                playable = playable,
                autoAdvanceCount = autoAdvanceStreak[0],
                onBingePrompted = { autoAdvanceStreak[0] = 0 },
                sourceOptions = playerSourceOptions,
                qualityOptions = playerQualityOptions,
                episodeOptions = playerEpisodeOptions,
                currentSource = playerVm?.currentPlayerSource(),
                onSwitchSource = playerVm?.let { vm ->
                    { source -> vm.resolveSourceSwitch(source) }
                },
                onSwitchEpisode = playerVm?.let { vm ->
                    { episodeId -> vm.resolveEpisodeSwitch(episodeId) }
                },
                onEpisodeSwitched = { replacement, acceptedRevision ->
                    historyIdentity = advancePlayerEpisodeHistory(
                        current = historyIdentity,
                        replacement = replacement,
                        acceptedRevision = acceptedRevision,
                    )
                },
                onWarmNext = onWarmNext@{ pos, dur ->
                    val vm = playerVm ?: return@onWarmNext
                    val next = vm.nextEpisode() ?: return@onWarmNext
                    val target = NextEpisodePreloadPolicy.Target(next.id, historyIdentity.acceptedRevision)
                    val attempt = preloadPolicy.evaluate(target, pos, dur, android.os.SystemClock.elapsedRealtime())
                        ?: return@onWarmNext
                    appScope.launch {
                        val prepared = vm.warmNextEpisode(next.id)
                        preloadPolicy.complete(attempt, prepared, android.os.SystemClock.elapsedRealtime())
                    }
                },
                onUpNextWindow = onUpNextWindow@{ pos, dur ->
                    val next = playerVm?.nextEpisode() ?: return@onUpNextWindow
                    val target = EpisodeProgressionPolicy.Target(next.id, historyIdentity.acceptedRevision)
                    if (episodeProgression.offer(target, pos, dur, ended = false) != null) {
                        upNext = next
                        upNextTarget = target
                    }
                },
                onBack = { playing = null },
                onError = { playing = null },
                onEnded = {
                    val next = playerVm?.nextEpisode()
                    if (next == null) {
                        playing = null
                    } else {
                        val target = EpisodeProgressionPolicy.Target(next.id, historyIdentity.acceptedRevision)
                        if (episodeProgression.offer(target, 0L, 0L, ended = true) != null) {
                            upNext = next
                            upNextTarget = target
                        } else if (upNext == null) {
                            playing = null
                        }
                    }
                },
                onSourceFailed = if (playerVm != null && BadSourceAutoRetrySetting.isEnabled(appContext)) {
                    { positionMs ->
                        retryResumePositionMs = positionMs
                        retryingSource = playerVm.retryNextSource(positionMs)
                    }
                } else {
                    null
                },
                onProgress = { pos, dur ->
                    playbackHistory.report(pos, dur)
                },
                // TV player additions: the per-stream Share QR (a magnet for a torrent, else the raw URL) and
                // the 10-foot audio/subtitle language + forced-policy sheets and hidden-chrome D-pad skip pill.
                shareLink = tvStreamShareLink(playable),
                isTvPlayer = true,
            )
            val next = upNext
            if (next != null && playerVm != null) {
                val nextPlayback by playerVm.playback.collectAsStateWithLifecycle()
                LaunchedEffect(nextPlayback) {
                    when (val result = nextPlayback) {
                        is Playback.Ready -> {
                            playerVm.clearPlayback()
                            playing = result.playable
                        }
                        is Playback.Failed -> {
                            playerVm.clearPlayback()
                            playing = null
                        }
                        else -> Unit
                    }
                }
                TvUpNextOverlay(
                    episode = next,
                    resolving = nextPlayback is Playback.Resolving,
                    onAutoAdvance = {
                        if (upNextTarget?.let { episodeProgression.decide(it, EpisodeProgressionPolicy.Intent.AUTO_ADVANCE) } == EpisodeProgressionPolicy.Decision.ADVANCE) {
                            autoAdvanceStreak[0]++
                            playerVm.playNextEpisode()
                        }
                    },
                    onPlayNow = {
                        if (upNextTarget?.let { episodeProgression.decide(it, EpisodeProgressionPolicy.Intent.PLAY_NOW) } == EpisodeProgressionPolicy.Decision.ADVANCE) {
                            autoAdvanceStreak[0] = 0
                            playerVm.playNextEpisode()
                        }
                    },
                    onWatchCredits = {
                        upNextTarget?.let { episodeProgression.decide(it, EpisodeProgressionPolicy.Intent.WATCH_CREDITS) }
                        upNext = null
                    },
                    onCancel = {
                        upNextTarget?.let { episodeProgression.decide(it, EpisodeProgressionPolicy.Intent.CANCEL) }
                        autoAdvanceStreak[0] = 0
                        playing = null
                    },
                )
            }
            }
            return@VortXTheme
        }

        // Home + Detail live under androidx.tv's own MaterialTheme so the focus-first tv-material `Surface`
        // tiles resolve their CompositionLocals (its ClickableSurfaceDefaults read the tv color scheme for
        // any default not passed explicitly). VortXTheme still supplies every VortX design token the content
        // reads (colors/type/spacing); the two themes coexist -- one owns tv-component defaults, the other
        // owns the brand tokens.
        TvMaterialTheme(colorScheme = tvDarkColorScheme()) {
            // The launch update prompt (sideload channel): floated over the browse/detail shell but never the
            // player (this block only composes when nothing is playing -- the player branch returns above).
            // Reads the SAME process-wide UpdateChecker the phone shell reads (armed in VortXApplication).
            UpdatePromptHost()
            val current = detail
            if (current != null) {
                key(current.type, current.id, detailGeneration) {
                    // The Compose generation resets the local screen tree, while this Activity-scoped
                    // ViewModel key remains bounded by target and owner so repeat visits do not leak VMs.
                    val detailVm: DetailViewModel = viewModel(
                        viewModelStoreOwner = detailVmOwner,
                        key = detailViewModelKey(
                            prefix = "tv-detail",
                            typeId = current.type.id,
                            mediaId = current.id,
                            ownerEpoch = detailSourceEpoch,
                        ),
                        factory = StremioXViewModelFactory(
                            repo = repo,
                            detailArgs = StremioXViewModelFactory.DetailArgs(current.type, current.id),
                            appContext = appContext,
                        ),
                    )
                    TvDetailScreen(
                        viewModel = detailVm,
                        title = current.name,
                        onBack = { detail = null },
                        onPlay = { resolved, loadedMeta ->
                            playingMeta = loadedMeta
                            playing = resolved
                        },
                        // A Person-page filmography tile (opened from the detail's cast rail) resolves a
                        // title and opens it as a fresh detail, reusing the SAME detail slot the browse wall
                        // uses -- the couch analogue of the phone actor -> film walk.
                        onOpenTitle = {
                            detailGeneration += 1
                            detail = it
                        },
                    )
                }
            } else {
                // The browse layer: the left-rail shell over the five top-level surfaces (Home / Discover /
                // Library / Search / Settings). It sits UNDER this detail/player block, so opening a title
                // from ANY surface routes through the same `detail` slot and the existing Home -> Detail ->
                // Play flow is unchanged.
                TvShell(
                    repo = repo,
                    auth = auth,
                    onItem = {
                        detailGeneration += 1
                        detail = it
                    },
                    // A finished download plays straight into the shared player slot (no detail page), the same
                    // slot a streamed source resolves into. Clears any stale detail meta so the player reads the
                    // local file, not a previous title's badges.
                    onPlayLocal = {
                        playingMeta = null
                        playing = it
                    },
                    syncManager = syncManager,
                )
            }
        }
    }
}

@Composable
private fun TvUpNextOverlay(
    episode: Episode,
    resolving: Boolean,
    onPlayNow: () -> Unit,
    onWatchCredits: () -> Unit,
    onCancel: () -> Unit,
    onAutoAdvance: () -> Unit,
) {
    var secondsLeft by remember(episode.id) { mutableStateOf(10) }
    var fired by remember(episode.id) { mutableStateOf(false) }
    LaunchedEffect(episode.id) {
        while (secondsLeft > 0) {
            delay(1_000L)
            secondsLeft--
        }
        if (!fired) {
            fired = true
            onAutoAdvance()
        }
    }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomEnd) {
        Column(
            modifier = Modifier
                .padding(40.dp)
                .background(Color(0xE61A1A1A), RoundedCornerShape(16.dp))
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            androidx.compose.material3.Text("Up Next", color = Color.White.copy(alpha = 0.72f), fontSize = 16.sp, fontWeight = FontWeight.Bold)
            androidx.compose.material3.Text("S${episode.season} E${episode.episode} · ${episode.title}", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
            Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                TvUpNextAction(if (resolving || fired) "Starting…" else "Play now · ${secondsLeft}s", enabled = !resolving && !fired, onClick = { fired = true; onPlayNow() })
                TvUpNextAction("Watch credits", enabled = !resolving && !fired, onClick = onWatchCredits)
                TvUpNextAction("Cancel", enabled = true, onClick = onCancel)
            }
        }
    }
}

@Composable
private fun TvUpNextAction(label: String, enabled: Boolean, onClick: () -> Unit) {
    androidx.compose.material3.Text(
        text = label,
        color = if (enabled) Color.White else Color.White.copy(alpha = 0.5f),
        fontSize = 17.sp,
        fontWeight = FontWeight.Medium,
        modifier = Modifier.clickable(enabled = enabled, onClick = onClick).padding(vertical = 8.dp),
    )
}

/**
 * Owns the TV shell's history callbacks for one [Playable]. Trailers receive no history handle, so
 * periodic progress, the player's final progress callback, and composition disposal cannot reach the
 * resident feature's history session. Ordinary playables retain the existing ordered lifecycle.
 */
internal class TvPlaybackHistorySession(
    historyIdentity: PlayerEpisodeHistoryIdentity,
    private val playbackSessions: PlaybackSessionLifecycle,
) {
    private val handle = if (historyIdentity.playable.isTrailer) null else playbackSessions.newHandle()
    private var lastPositionMs = 0L
    private var lastDurationMs = 0L

    fun begin() {
        val activeHandle = handle ?: return
        playbackSessions.begin(activeHandle)
    }

    fun report(positionMs: Long, durationMs: Long) {
        val activeHandle = handle ?: return
        lastPositionMs = positionMs
        lastDurationMs = durationMs
        playbackSessions.report(activeHandle, positionMs, durationMs)
    }

    fun end() {
        val activeHandle = handle ?: return
        playbackSessions.end(activeHandle, lastPositionMs, lastDurationMs)
    }
}

/// The raw usable link this stream can be shared to a phone as, or null when there is nothing shareable. A
/// torrent's loopback URL (`127.0.0.1:PORT/...`) is meaningless on another device, so a magnet URI is rebuilt
/// from its 40-hex info-hash; a direct or resolved-debrid HTTP(S) stream shares its own URL; a local offline
/// download (a `file://` URL) and a loopback with no extractable hash share nothing. Mirrors Apple's in-player
/// `shareLink`, which is what the TV player's QR row encodes.
private fun tvStreamShareLink(playable: Playable): String? {
    val url = playable.url
    if (playable.isTorrent) {
        val hash = TV_INFO_HASH_REGEX.find(url)?.value ?: return null
        return "magnet:?xt=urn:btih:${hash.lowercase()}"
    }
    return if (url.startsWith("http://", ignoreCase = true) || url.startsWith("https://", ignoreCase = true)) {
        url
    } else {
        null
    }
}

private val TV_INFO_HASH_REGEX = Regex("[0-9a-fA-F]{40}")
