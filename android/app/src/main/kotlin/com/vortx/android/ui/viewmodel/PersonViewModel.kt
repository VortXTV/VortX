package com.vortx.android.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.vortx.android.model.MetaItem
import com.vortx.android.person.PersonDetail
import com.vortx.android.person.TMDBPersonClient
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/// Backs the Person page ([com.vortx.android.ui.screens.PersonScreen]), ported from the Apple
/// `PersonView`'s `load()`: it fetches the person's biographical [PersonDetail] and their combined-credits
/// filmography from TMDB through VortX's keyless, signed catalog edge ([TMDBPersonClient]). The bio and
/// the filmography load INDEPENDENTLY (two `viewModelScope` launches) so each lands as soon as it
/// resolves and one being slow/absent never blocks the other, exactly like the Swift `load()` gates.
///
/// The screen paints its header instantly from the tapped-cast seed (name + headshot); this ViewModel only
/// ENRICHES that -- so [PersonUiState.detail] stays null until the fuller record arrives, and the
/// [loadedCredits] flag lets the grid distinguish "still loading" from "no filmography". Owns none of the
/// engine/detail state (the media-servers wave owns `DetailViewModel`); it only touches the edge client.
class PersonViewModel(private val personId: Int) : ViewModel() {

    private val _state = MutableStateFlow(PersonUiState())
    val state: StateFlow<PersonUiState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            val detail = TMDBPersonClient.person(personId)
            // A null result (no match / edge down) leaves the header on its seed; mark detail loaded
            // either way so the header stops implying a pending fetch.
            _state.value = _state.value.copy(detail = detail, loadedDetail = true)
        }
        viewModelScope.launch {
            val credits = TMDBPersonClient.personCredits(personId)
            _state.value = _state.value.copy(credits = credits, loadedCredits = true)
        }
    }

    /// A tiny factory so the screen can build this ViewModel with just the TMDB person id, without
    /// touching the shared [StremioXViewModelFactory] (which the app shell and the media-servers wave
    /// both build against). Keyed per person id at the call site so navigating actor -> co-star gets a
    /// fresh instance.
    class Factory(private val personId: Int) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            require(modelClass.isAssignableFrom(PersonViewModel::class.java)) {
                "PersonViewModel.Factory only builds PersonViewModel, got ${modelClass.name}"
            }
            return PersonViewModel(personId) as T
        }
    }
}

/// The Person page's render state: the enriched [detail] (null until it lands -- the header falls back to
/// the tapped seed), the filmography [credits], and the two "has this stream answered yet" flags the
/// screen uses to show a spinner vs. an empty-state for the grid.
data class PersonUiState(
    val detail: PersonDetail? = null,
    val credits: List<MetaItem> = emptyList(),
    val loadedDetail: Boolean = false,
    val loadedCredits: Boolean = false,
)
