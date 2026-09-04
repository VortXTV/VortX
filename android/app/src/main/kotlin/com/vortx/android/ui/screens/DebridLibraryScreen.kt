package com.vortx.android.ui.screens

import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.compose.foundation.clickable
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.foundation.focusGroup
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.draw.scale
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.vortx.android.debrid.DebridCoordinator
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.debrid.DebridResolver
import com.vortx.android.debrid.DebridService
import com.vortx.android.model.Playable
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.launch

/// Settings > Debrid > Your cloud: the Android port of Apple `app/SourcesiOS/DebridLibraryView.swift`.
///
/// Browse-your-debrid-cloud: lists what is ALREADY sitting in the user's configured debrid accounts (finished
/// torrents / stored files on Real-Debrid, AllDebrid, Premiumize, TorBox) and plays a chosen item straight
/// through the normal player, with NO add-on and NO re-download. Self-contained like the other settings
/// overlays: it reads the existing [DebridKeys] for configured providers, lists + resolves through a
/// [DebridCoordinator] built off those keys, and hands the resolved DIRECT url up as a [Playable] to the same
/// player slot the Downloads screen uses ([onPlay]).
///
/// CREDENTIALS: the debrid keys are read ONLY through [DebridKeys] (EncryptedSharedPreferences); this screen
/// never sees or logs a raw key, and no key is ever placed in a URL path (the resolver puts auth in the
/// Bearer header / query the same way the Apple client does).
///
/// Fail-soft throughout: a provider with no key is simply absent; a provider that errors or returns nothing
/// hides its section; a resolve that fails shows an inline notice, never a crash.
@OptIn(ExperimentalMaterial3Api::class, ExperimentalComposeUiApi::class)
@Composable
fun DebridLibraryScreen(
    keys: DebridKeys,
    onPlay: (Playable) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    initialFocusRequester: FocusRequester? = null,
    tvMode: Boolean = false,
) {
    val context = LocalContext.current.applicationContext
    val coordinator = remember(keys) { DebridCoordinator(DebridResolver(keys), keys) }
    val scope = rememberCoroutineScope()

    var phase by remember { mutableStateOf(LibraryPhase.IDLE) }
    var sections by remember { mutableStateOf<List<DebridLibrarySectionUi>>(emptyList()) }
    var resolvingId by remember { mutableStateOf<String?>(null) }
    var resolveError by remember { mutableStateOf<String?>(null) }
    val hasAnyKey = keys.hasAnyKey()

    suspend fun reload() {
        if (!hasAnyKey) {
            sections = emptyList()
            phase = LibraryPhase.LOADED
            return
        }
        phase = LibraryPhase.LOADING
        val library = coordinator.cloudLibrary()
        // DebridService.entries order keeps the sections stable (Real-Debrid first, TorBox last), matching the
        // Apple DebridService.allCases ordering.
        sections = DebridService.entries.mapNotNull { service ->
            library[service]?.takeIf { it.isNotEmpty() }?.let { DebridLibrarySectionUi(service, it) }
        }
        phase = LibraryPhase.LOADED
    }

    // First-appearance load, guarded so re-entry does not re-hit every provider (Apple's loadIfNeeded).
    LaunchedEffect(Unit) { reload() }

    fun play(item: DebridResolver.DebridLibraryItem) {
        if (resolvingId != null) return
        resolvingId = item.id
        resolveError = null
        scope.launch {
            try {
                val url = coordinator.resolveLibraryItem(item)
                // Paste-a-link style launch: a direct URL with no library item to record progress against.
                onPlay(Playable(url = url, title = item.name, viaStreamingServer = false, isTorrent = false))
            } catch (error: Exception) {
                resolveError = "Could not start \"${item.name}\". The file may have expired from your cloud."
            } finally {
                resolvingId = null
            }
        }
    }

    Scaffold(
        modifier = if (tvMode) {
            modifier.focusGroup().focusProperties { exit = { FocusRequester.Cancel } }
        } else {
            modifier
        },
        topBar = {
            TopAppBar(
                title = { Text("Your cloud", style = VortXTheme.type.cardTitle) },
                navigationIcon = {
                    IconButton(
                        onClick = onBack,
                        modifier = if (initialFocusRequester != null) {
                            Modifier.focusRequester(initialFocusRequester)
                        } else {
                            Modifier
                        },
                    ) {
                        Icon(VortXIcons.back, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(
                        onClick = { scope.launch { reload() } },
                        enabled = phase != LibraryPhase.LOADING && hasAnyKey,
                    ) {
                        Icon(Icons.Filled.Refresh, contentDescription = "Refresh library")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(VortXTheme.spacing.edge)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text(
                "Play what is already in your debrid account. Finished torrents and stored files stream " +
                    "instantly, straight from the cloud, no add-on needed.",
                style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
            )

            when {
                !hasAnyKey -> Placeholder(
                    title = "No debrid service connected",
                    message = "Add a Real-Debrid, AllDebrid, Premiumize, or TorBox API key in Settings to " +
                        "browse and play your cloud.",
                )
                phase == LibraryPhase.IDLE || phase == LibraryPhase.LOADING -> LoadingState()
                sections.isEmpty() -> Placeholder(
                    title = "Nothing here yet",
                    message = "When you add torrents or files to your debrid account, they show up here to play.",
                )
                else -> {
                    resolveError?.let { InlineNotice(it) }
                    sections.forEach { section ->
                        ProviderSection(section = section, resolvingId = resolvingId, onPlay = ::play, tvMode = tvMode)
                    }
                }
            }
        }
    }
}

/// Loading phase, mirroring Apple's DebridLibraryModel.Phase.
private enum class LibraryPhase { IDLE, LOADING, LOADED }

/// One provider's slice of the browsable library, grouped for the sectioned list.
private data class DebridLibrarySectionUi(
    val service: DebridService,
    val items: List<DebridResolver.DebridLibraryItem>,
)

@Composable
private fun ProviderSection(
    section: DebridLibrarySectionUi,
    resolvingId: String?,
    onPlay: (DebridResolver.DebridLibraryItem) -> Unit,
    tvMode: Boolean,
) {
    val colors = VortXTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(start = VortXTheme.spacing.xs),
        ) {
            Text(
                section.service.displayName.uppercase(),
                style = VortXTheme.type.eyebrow.copy(color = colors.textTertiary),
            )
            Text("${section.items.size}", style = VortXTheme.type.eyebrow.copy(color = colors.textTertiary))
        }
        section.items.forEach { item ->
            LibraryRow(item = item, resolvingId = resolvingId, onPlay = onPlay, tvMode = tvMode)
        }
    }
}

@Composable
private fun LibraryRow(
    item: DebridResolver.DebridLibraryItem,
    resolvingId: String?,
    onPlay: (DebridResolver.DebridLibraryItem) -> Unit,
    tvMode: Boolean,
) {
    val colors = VortXTheme.colors
    val context = LocalContext.current
    val busy = resolvingId != null
    val meta = metaLine(context, item)
    var focused by remember { mutableStateOf(false) }
    SurfaceCard(
        modifier = Modifier
            .fillMaxWidth()
            .onFocusChanged { focused = it.isFocused }
            .scale(if (tvMode && focused) 1.03f else 1f)
            .then(if (tvMode && focused) Modifier.border(BorderStroke(2.dp, colors.accentBright), VortXShapes.control) else Modifier)
            .clickable(enabled = !busy) { onPlay(item) },
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(VortXTheme.spacing.md),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(modifier = Modifier.size(28.dp), contentAlignment = Alignment.Center) {
                if (resolvingId == item.id) {
                    CircularProgressIndicator(modifier = Modifier.size(20.dp), color = colors.accent)
                } else {
                    Icon(VortXIcons.playFill, contentDescription = null, tint = colors.accent)
                }
            }
            Column(modifier = Modifier.fillMaxWidth()) {
                Text(
                    item.name,
                    style = VortXTheme.type.body.copy(color = colors.textPrimary),
                    maxLines = 2,
                )
                if (meta != null) {
                    Text(meta, style = VortXTheme.type.label.copy(color = colors.textTertiary))
                }
            }
        }
    }
}

@Composable
private fun LoadingState() {
    val colors = VortXTheme.colors
    Row(
        modifier = Modifier.padding(vertical = VortXTheme.spacing.lg),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CircularProgressIndicator(modifier = Modifier.size(20.dp), color = colors.accent)
        Text(
            "Reading your debrid cloud...",
            style = VortXTheme.type.body.copy(color = colors.textSecondary),
        )
    }
}

@Composable
private fun Placeholder(title: String, message: String) {
    val colors = VortXTheme.colors
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(VortXTheme.spacing.lg),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
        ) {
            Text(title, style = VortXTheme.type.cardTitle.copy(color = colors.textPrimary))
            Text(message, style = VortXTheme.type.body.copy(color = colors.textSecondary))
        }
    }
}

@Composable
private fun InlineNotice(text: String) {
    val colors = VortXTheme.colors
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(VortXTheme.spacing.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(text, style = VortXTheme.type.label.copy(color = colors.textSecondary))
            Spacer(modifier = Modifier.width(VortXTheme.spacing.sm))
        }
    }
}

/// The row's secondary line: file size then relative added-time, both omitted when the provider gave neither.
/// Mirrors Apple's `metaLine`.
private fun metaLine(context: android.content.Context, item: DebridResolver.DebridLibraryItem): String? {
    val parts = mutableListOf<String>()
    if (item.size > 0) parts.add(Formatter.formatShortFileSize(context, item.size))
    item.addedEpochMillis?.let { millis ->
        parts.add(
            DateUtils.getRelativeTimeSpanString(
                millis,
                System.currentTimeMillis(),
                DateUtils.MINUTE_IN_MILLIS,
            ).toString(),
        )
    }
    return if (parts.isEmpty()) null else parts.joinToString("  ·  ")
}
