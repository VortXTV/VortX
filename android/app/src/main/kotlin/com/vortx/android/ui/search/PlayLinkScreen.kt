package com.vortx.android.ui.search

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
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import com.vortx.android.data.CatalogRepository
import com.vortx.android.model.Playable
import com.vortx.android.player.PlaybackBehaviorSettings
import com.vortx.android.search.PlayLinkTarget
import com.vortx.android.search.SavedLinksStore
import com.vortx.android.search.classifyPlayLink
import com.vortx.android.search.parseMagnet
import com.vortx.android.ui.components.PrimaryButton
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.launch

/// The "Play a link / magnet" screen (SD-1), the Android port of Apple `iOSOpenLinkView`
/// (iOSRootView.swift:3510-3607). A single input accepts a direct/debrid/usenet http(s) link or a magnet;
/// Play classifies it ([classifyPlayLink]) and resolves through the repository (a direct link plays as-is;
/// a magnet resolves through the existing torrent/debrid path). Save keeps the link in the per-profile
/// [SavedLinksStore]; the Saved rail lists them with per-row play + remove. After a magnet plays, the exact
/// file is bound onto its saved entry (#81) so a season pack reopens the same episode.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlayLinkScreen(
    repo: CatalogRepository,
    onPlay: (Playable) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current.applicationContext
    val savedLinks = remember { SavedLinksStore(context) }
    val directLinksOnly = remember { PlaybackBehaviorSettings.directLinksOnly(context) }
    val scope = rememberCoroutineScope()
    val focusManager = LocalFocusManager.current
    val colors = VortXTheme.colors

    var input by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }
    var isError by remember { mutableStateOf(false) }
    var saved by remember { mutableStateOf(savedLinks.all()) }

    fun resolveAndPlay(magnetLink: String?, resolve: suspend () -> Result<Playable>) {
        focusManager.clearFocus()
        working = true
        status = if (magnetLink != null) "Fetching torrent info. This can take up to a minute." else null
        isError = false
        scope.launch {
            val result = resolve()
            working = false
            result.onSuccess { playable ->
                // #81: bind the exact played file onto an ALREADY-saved magnet (update-only, so a one-off
                // play never clutters the Saved list).
                if (magnetLink != null) savedLinks.bindPlayedFile(magnetLink, playable.url)
                onPlay(playable)
            }.onFailure {
                isError = true
                status = it.message ?: "Could not play that link."
            }
        }
    }

    fun play() {
        when (val target = classifyPlayLink(input, directLinksOnly)) {
            is PlayLinkTarget.Invalid -> {
                isError = true
                status = target.reason
            }
            is PlayLinkTarget.Direct -> resolveAndPlay(magnetLink = null) {
                repo.resolveDirectLink(target.url, target.title)
            }
            is PlayLinkTarget.Magnet -> resolveAndPlay(magnetLink = target.link) {
                repo.resolveMagnet(target.infoHash, target.name ?: "Magnet link")
            }
        }
    }

    fun playSaved(entry: SavedLinksStore.Entry) {
        if (entry.isMagnet && entry.infoHash != null && entry.fileIdx != null) {
            // A magnet with a bound file (#81): replay the exact same file, skipping re-classification.
            resolveAndPlay(magnetLink = entry.link) {
                repo.resolveMagnet(entry.infoHash, entry.name, entry.fileIdx)
            }
        } else {
            input = entry.link
            play()
        }
    }

    fun saveCurrent() {
        val text = input.trim()
        if (text.isEmpty()) return
        val isMagnet = text.startsWith("magnet:", ignoreCase = true)
        val name = if (isMagnet) {
            parseMagnet(text)?.name ?: "Magnet link"
        } else {
            text.substringAfterLast('/').ifBlank { text }
        }
        savedLinks.save(
            SavedLinksStore.Entry(
                id = text,
                link = text,
                name = name,
                isMagnet = isMagnet,
                savedAt = System.currentTimeMillis(),
            ),
        )
        saved = savedLinks.all()
        isError = false
        status = "Saved."
    }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            androidx.compose.material3.TopAppBar(
                title = { Text("Play a link", style = VortXTheme.type.cardTitle) },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(VortXIcons.back, contentDescription = "Back") }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(VortXTheme.spacing.edge),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text(
                text = if (directLinksOnly) {
                    "Paste a direct link, or a debrid or usenet link your service resolved to http(s)."
                } else {
                    "Paste a direct link, a debrid or usenet http(s) link, or a magnet link."
                },
                style = VortXTheme.type.body.copy(color = colors.textSecondary),
            )
            OutlinedTextField(
                value = input,
                onValueChange = { input = it; status = null },
                singleLine = true,
                placeholder = {
                    Text(
                        if (directLinksOnly) "https://..." else "https://...  or  magnet:?xt=...",
                        style = VortXTheme.type.body,
                    )
                },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { play() }),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.accent,
                    unfocusedBorderColor = colors.hairline,
                    cursorColor = colors.accent,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                PrimaryButton(
                    text = "Play",
                    onClick = { play() },
                    enabled = !working && input.isNotBlank(),
                    loading = working,
                    leadingIcon = VortXIcons.playFill,
                    modifier = Modifier.weight(1f),
                )
                com.vortx.android.ui.components.Chip(
                    label = "Save",
                    selected = false,
                    enabled = !working && input.isNotBlank(),
                    leadingIcon = VortXIcons.bookmark,
                    onClick = { saveCurrent() },
                )
            }
            status?.let {
                Text(
                    text = it,
                    style = VortXTheme.type.label.copy(
                        color = if (isError) colors.danger else colors.textSecondary,
                    ),
                )
            }
            if (saved.isNotEmpty()) {
                Text("Saved", style = VortXTheme.type.sectionTitle)
                LazyColumn(
                    modifier = Modifier.fillMaxWidth().heightIn(max = 320.dp),
                    verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                ) {
                    items(saved, key = { it.id }) { entry ->
                        SavedLinkRow(
                            entry = entry,
                            enabled = !working,
                            onPlay = { playSaved(entry) },
                            onRemove = {
                                savedLinks.remove(entry.id)
                                saved = savedLinks.all()
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SavedLinkRow(
    entry: SavedLinksStore.Entry,
    enabled: Boolean,
    onPlay: () -> Unit,
    onRemove: () -> Unit,
) {
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(VortXTheme.spacing.md),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            Icon(
                if (entry.isMagnet) VortXIcons.link else VortXIcons.playRectangle,
                contentDescription = null,
                tint = VortXTheme.colors.accent,
            )
            Text(
                text = entry.name,
                style = VortXTheme.type.cardTitle,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = onPlay, enabled = enabled) {
                Icon(VortXIcons.playFill, contentDescription = "Play ${entry.name}")
            }
            IconButton(onClick = onRemove, enabled = enabled) {
                Icon(VortXIcons.delete, contentDescription = "Remove ${entry.name}")
            }
        }
    }
}

/// The "Play a link" entry chip at the top of the Search tab (SD-1, Apple's `iOSSearchView` link chip).
/// The label follows `PlaybackBehaviorSettings.directLinksOnly`, exactly like Apple's
/// `directLinksOnly ? "Play a direct link" : "Play a link or magnet"`.
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun PlayLinkEntry(
    onClick: () -> Unit,
    onDebridLibraryClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current.applicationContext
    val directLinksOnly = remember { PlaybackBehaviorSettings.directLinksOnly(context) }
    FlowRow(
        modifier = modifier.padding(horizontal = VortXTheme.spacing.edge, vertical = VortXTheme.spacing.xs),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
    ) {
        com.vortx.android.ui.components.Chip(
            label = if (directLinksOnly) "Play a direct link" else "Play a link or magnet",
            selected = false,
            leadingIcon = VortXIcons.link,
            onClick = onClick,
        )
        com.vortx.android.ui.components.Chip(
            label = "Your cloud",
            selected = false,
            leadingIcon = VortXIcons.playCircle,
            onClick = onDebridLibraryClick,
        )
    }
}
