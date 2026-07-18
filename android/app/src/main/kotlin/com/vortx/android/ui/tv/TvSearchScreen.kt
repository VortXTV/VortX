package com.vortx.android.ui.tv

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
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
fun TvSearchScreen(viewModel: SearchViewModel, onItem: (MetaItem) -> Unit, modifier: Modifier = Modifier) {
    val query by viewModel.query.collectAsStateWithLifecycle()
    val state by viewModel.state.collectAsStateWithLifecycle()
    val history by viewModel.history.collectAsStateWithLifecycle()
    val colors = VortXTheme.colors

    // Open-to-record, like the phone: history is written when a result is actually opened, not on keystrokes.
    val openItem: (MetaItem) -> Unit = {
        viewModel.recordHistory()
        onItem(it)
    }

    Column(modifier = modifier.fillMaxSize().padding(top = TvDimens.edge)) {
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

        when (val s = state) {
            is UiState.Loading -> TvEmpty("Searching your add-ons…")
            // No retry affordance: the flow re-runs on the next query change, so a bare message (not a Retry
            // card) is the honest state, matching the phone's ErrorState(message) here.
            is UiState.Error -> TvEmpty(s.message)
            is UiState.Success -> TvPosterGrid(
                items = s.data,
                onItem = openItem,
                emptyHint = if (query.isBlank()) "Type to search across your add-ons." else "No matches.",
            )
        }
    }
}
