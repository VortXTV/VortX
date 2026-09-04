package com.vortx.android.ui.tv

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import com.vortx.android.ui.search.searchEmptyMessage
import com.vortx.android.ui.search.textResourceId
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.SearchViewModel

/// TV Search: the 10-foot analogue of the phone [com.vortx.android.ui.screens.SearchScreen], driven by the
/// SAME [SearchViewModel]. The query field is D-pad focusable; activating it (center) raises the platform
/// on-screen keyboard, and each keystroke feeds [SearchViewModel.onQueryChange] -- the same debounced,
/// every-add-on search the phone runs. Recent searches surface as focusable chips when the box is empty; a
/// result records history (mirroring the phone's open-to-record rule) and opens the shared [TvDetailScreen].
///
/// Because it is the same ViewModel/engine, the active profile's Kids source guard applies to a played result
/// for free. Scope note: this uses the platform IME rather than a bespoke on-screen keypad; on-device focus /
/// IME tuning is a later 10-foot polish item (see the session report).
@Composable
fun TvSearchScreen(
    viewModel: SearchViewModel,
    onItem: (MetaItem) -> Unit,
    onPlayLinkClick: () -> Unit,
    onDebridLibraryClick: () -> Unit,
    modifier: Modifier = Modifier,
    signedIn: Boolean = true,
    restoreQuickActionsFocusSignal: Int = 0,
) {
    val searchState by viewModel.screenState.collectAsStateWithLifecycle()
    val history by viewModel.history.collectAsStateWithLifecycle()
    val suggestions by viewModel.suggestions.collectAsStateWithLifecycle()
    val query = searchState.query
    val state = searchState.content
    val colors = VortXTheme.colors

    // SD-8: a signed-out set sees a sign-in prompt, not empty add-on results.
    if (!signedIn) {
        Column(modifier = modifier.fillMaxSize().padding(top = TvDimens.edge)) {
            TvSearchQuickActions(onPlayLinkClick, onDebridLibraryClick, restoreQuickActionsFocusSignal)
            TvSignedOut(modifier = Modifier.fillMaxSize())
        }
        return
    }

    // Open-to-record, like the phone: history is written when a result is actually opened, not on keystrokes.
    val openItem: (MetaItem) -> Unit = {
        viewModel.recordHistory()
        onItem(it)
    }

    Column(modifier = modifier.fillMaxSize().padding(top = TvDimens.edge)) {
        TvSearchQuickActions(onPlayLinkClick, onDebridLibraryClick, restoreQuickActionsFocusSignal)
        OutlinedTextField(
            value = query,
            onValueChange = viewModel::onQueryChange,
            leadingIcon = { Icon(VortXIcons.search, contentDescription = null, tint = colors.textSecondary) },
            placeholder = { Text("Search movies, series, channels", style = VortXTheme.type.body) },
            singleLine = true,
            textStyle = VortXTheme.type.body,
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = colors.accent,
                unfocusedBorderColor = colors.hairline,
                cursorColor = colors.accent,
            ),
            modifier = Modifier.fillMaxWidth().padding(horizontal = TvDimens.edge),
        )

        if (query.isBlank() && history.isNotEmpty()) {
            // A trailing "Clear" chip (empty value) alongside the recents, matching the phone's recents row.
            val chips = history.map { TvChipModel(it, false, it) } + TvChipModel("Clear", false, "")
            TvChipRow(
                chips = chips,
                onChipClick = { chip -> if (chip.value.isEmpty()) viewModel.clearHistory() else viewModel.onQueryChange(chip.value) },
                modifier = Modifier.padding(top = VortXTheme.spacing.md),
            )
        }

        // SD-4: as-you-type suggestions as focusable chips. Selecting one runs that query. Cleared below
        // two characters by the ViewModel, so this row is absent for a single-character query.
        if (suggestions.isNotEmpty()) {
            TvChipRow(
                chips = suggestions.map { TvChipModel(it, false, it) },
                onChipClick = { chip -> viewModel.onQueryChange(chip.value) },
                modifier = Modifier.padding(top = VortXTheme.spacing.sm),
            )
        }

        when (val s = state) {
            is UiState.Loading -> TvEmpty("Searching your add-ons…")
            // No retry affordance: the flow re-runs on the next query change, so a bare message (not a Retry
            // card) is the honest state, matching the phone's ErrorState(message) here.
            is UiState.Error -> TvEmpty(s.message)
            is UiState.Success -> TvPosterGrid(
                items = s.data,
                onItem = openItem,
                emptyHint = when (val message = searchEmptyMessage(query, s)) {
                    null -> ""
                    else -> stringResource(message.textResourceId)
                },
                sectioned = true,
            )
        }
    }
}

/// Adjacent and ordered remote targets: Play a link -> Your cloud -> Search field. They stay available even
/// while catalog search is gated behind sign-in because both routes are independent of add-on discovery.
@Composable
private fun TvSearchQuickActions(
    onPlayLinkClick: () -> Unit,
    onDebridLibraryClick: () -> Unit,
    restoreFocusSignal: Int,
) {
    val playLinkFocus = androidx.compose.runtime.remember { FocusRequester() }
    LaunchedEffect(restoreFocusSignal) {
        if (restoreFocusSignal > 0) runCatching { playLinkFocus.requestFocus() }
    }
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = TvDimens.edge),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        TvFilterChip(
            label = "Play a link",
            selected = false,
            onClick = onPlayLinkClick,
            modifier = Modifier.focusRequester(playLinkFocus),
        )
        TvFilterChip(label = "Your cloud", selected = false, onClick = onDebridLibraryClick)
    }
}
