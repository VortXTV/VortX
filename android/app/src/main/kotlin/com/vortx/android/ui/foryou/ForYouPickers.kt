package com.vortx.android.ui.foryou

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.vortx.android.R
import com.vortx.android.foryou.ForYouEra
import com.vortx.android.foryou.ForYouExtra
import com.vortx.android.foryou.ForYouGenre
import com.vortx.android.foryou.ForYouInterests
import com.vortx.android.foryou.ForYouPerson
import com.vortx.android.foryou.ForYouRowsModel
import com.vortx.android.foryou.ForYouStore
import com.vortx.android.foryou.ForYouText
import com.vortx.android.foryou.SmartCollection
import com.vortx.android.foryou.SmartCollectionRules
import com.vortx.android.model.MetaItem
import com.vortx.android.person.TMDBPersonClient
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** The platform chip: the phone `Chip` or the TV `TvFilterChip`, which share this exact shape. */
typealias ForYouChip = @Composable (label: String, selected: Boolean, onClick: () -> Unit, icon: ImageVector?) -> Unit

/**
 * The interests picker (Apple `ForYouInterestsView`): genres, scenes, eras and followed people. The
 * first run offers Done / Skip for now, and both record a decision so no device asks again; editing
 * from Tune offers Save / Cancel.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ForYouInterestsPicker(initial: ForYouInterests?, firstRun: Boolean, chip: ForYouChip, edge: Dp, onFinish: () -> Unit) {
    val context = LocalContext.current
    val text = remember(context) { ForYouText(context) }
    val scope = rememberCoroutineScope()
    var draft by remember { mutableStateOf(initial ?: ForYouInterests()) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val failed = stringResource(R.string.for_you_save_failed)
    fun save(value: ForYouInterests) {
        if (saving) return
        saving = true; error = null
        scope.launch {
            val result = ForYouStore.shared(context).save(value.copy(decided = true))
            saving = false
            if (result.isSuccess) onFinish() else error = failed
        }
    }
    Column(
        modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = edge, vertical = VortXTheme.spacing.xl),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
            Text(stringResource(R.string.for_you_picker_title), style = VortXTheme.type.screenTitle)
            Text(stringResource(R.string.for_you_picker_subtitle), style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary))
        }
        ChipGroup(stringResource(R.string.for_you_genres)) {
            ForYouGenre.PICKER.forEach { genre ->
                chip(text.genre(genre), genre.key in draft.genres, { draft = draft.copy(genres = draft.genres.toggle(genre.key)) }, null)
            }
        }
        ChipGroup(stringResource(R.string.for_you_also_into)) {
            ForYouExtra.entries.forEach { extra ->
                chip(text.extra(extra), extra.key in draft.extras, { draft = draft.copy(extras = draft.extras.toggle(extra.key)) }, null)
            }
        }
        ChipGroup(stringResource(R.string.for_you_eras)) {
            ForYouEra.entries.forEach { era ->
                chip(text.era(era), era.key in draft.eras, { draft = draft.copy(eras = draft.eras.toggle(era.key)) }, null)
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
            Eyebrow(stringResource(R.string.for_you_people))
            ForYouPeoplePicker(draft.people, { draft = draft.copy(people = it) }, chip)
        }
        error?.let { Text(it, style = VortXTheme.type.label.copy(color = VortXTheme.colors.danger)) }
        Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
            chip(stringResource(if (firstRun) R.string.for_you_done else R.string.for_you_save), true, { save(draft) }, null)
            chip(stringResource(if (firstRun) R.string.for_you_skip else R.string.for_you_cancel), false,
                { if (firstRun) save(ForYouInterests()) else onFinish() }, null)
        }
    }
}

/** Search TMDB for people and keep a short list of them; debounced so a name issues one search. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ForYouPeoplePicker(people: List<ForYouPerson>, onChange: (List<ForYouPerson>) -> Unit, chip: ForYouChip, maxPeople: Int = 10) {
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<ForYouPerson>>(emptyList()) }
    LaunchedEffect(query) {
        val trimmed = query.trim()
        if (trimmed.length < 2) { results = emptyList(); return@LaunchedEffect }
        delay(350)
        results = TMDBPersonClient.searchPeople(trimmed, limit = 8)
            .map { ForYouPerson(it.id, it.name, it.character) }
            .filter { result -> people.none { it.id == result.id } }
    }
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        if (people.isNotEmpty()) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm), verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                people.forEach { person -> chip(person.name, true, { onChange(people.filterNot { it.id == person.id }) }, Icons.Filled.Close) }
            }
        }
        if (people.size < maxPeople) {
            OutlinedTextField(
                value = query, onValueChange = { query = it }, singleLine = true,
                label = { Text(stringResource(R.string.for_you_add_person)) },
                modifier = Modifier.widthIn(max = 520.dp).fillMaxWidth(),
            )
        }
        if (results.isNotEmpty()) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm), verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                results.forEach { person ->
                    chip(person.name, false, {
                        if (people.size < maxPeople && people.none { it.id == person.id }) onChange(people + person)
                        query = ""; results = emptyList()
                    }, Icons.Filled.Add)
                }
            }
        }
    }
}

/**
 * Builds or edits one smart collection with a live preview (Apple `SmartCollectionEditor`). The
 * platform supplies the preview row so its cards match that platform's Home.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SmartCollectionEditor(
    existing: SmartCollection?,
    watched: Set<String>,
    chip: ForYouChip,
    edge: Dp,
    onFinish: () -> Unit,
    preview: @Composable (items: List<MetaItem>, loading: Boolean) -> Unit,
) {
    val context = LocalContext.current
    val text = remember(context) { ForYouText(context) }
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(existing?.name.orEmpty()) }
    var rules by remember { mutableStateOf(existing?.rules ?: SmartCollectionRules()) }
    var home by remember { mutableStateOf(existing?.home ?: true) }
    var items by remember { mutableStateOf<List<MetaItem>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    val nameFirst = stringResource(R.string.smart_collections_name_first)
    val yearOrder = stringResource(R.string.smart_collections_year_order)
    val failed = stringResource(R.string.smart_collections_save_failed)
    LaunchedEffect(rules) {
        loading = true
        if (items.isNotEmpty()) delay(500) // debounce chip bursts; the first preview runs at once
        items = ForYouRowsModel.titles(rules)
        loading = false
    }
    fun persist(operation: suspend () -> Result<Unit>) {
        if (saving) return
        saving = true; error = null
        scope.launch {
            val result = operation()
            saving = false
            if (result.isSuccess) onFinish() else error = failed
        }
    }
    val shown = if (rules.hideWatched) items.filterNot { it.id in watched } else items
    Column(
        modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = edge, vertical = VortXTheme.spacing.xl),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
    ) {
        Text(stringResource(if (existing == null) R.string.smart_collections_editor_new else R.string.smart_collections_editor_edit),
            style = VortXTheme.type.screenTitle)
        OutlinedTextField(value = name, onValueChange = { name = it.take(80) }, singleLine = true,
            label = { Text(stringResource(R.string.smart_collections_name)) }, modifier = Modifier.widthIn(max = 520.dp).fillMaxWidth())
        ChipGroup(stringResource(R.string.smart_collections_genres)) {
            ForYouGenre.entries.forEach { genre ->
                chip(text.genre(genre), genre.key in rules.genres, { rules = rules.copy(genres = rules.genres.toggle(genre.key)) }, null)
            }
        }
        ChipGroup(stringResource(R.string.smart_collections_scene)) {
            ForYouExtra.entries.forEach { extra ->
                val selected = rules.extras.firstOrNull() == extra.key
                chip(text.extra(extra), selected, { rules = rules.copy(extras = if (selected) emptyList() else listOf(extra.key)) }, null)
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
            Eyebrow(stringResource(R.string.smart_collections_with))
            ForYouPeoplePicker(rules.people, { rules = rules.copy(people = it) }, chip, maxPeople = 5)
            if (rules.people.isNotEmpty() && rules.type != SmartCollectionRules.Kind.MOVIE) {
                Text(stringResource(R.string.smart_collections_people_note), style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary))
            }
        }
        val any = stringResource(R.string.smart_collections_any)
        ChipGroup(stringResource(R.string.smart_collections_year_from)) {
            listOf(null, 1970, 1980, 1990, 2000, 2010, 2020).forEach { year ->
                chip(year?.toString() ?: any, rules.yearFrom == year, { rules = rules.copy(yearFrom = year) }, null)
            }
        }
        val now = stringResource(R.string.smart_collections_now)
        ChipGroup(stringResource(R.string.smart_collections_year_to)) {
            listOf(null, 1979, 1989, 1999, 2009, 2019).forEach { year ->
                chip(year?.toString() ?: now, rules.yearTo == year, { rules = rules.copy(yearTo = year) }, null)
            }
        }
        ChipGroup(stringResource(R.string.smart_collections_rating)) {
            listOf(null, 6.0, 7.0, 8.0).forEach { rating ->
                chip(rating?.let { "%.0f+".format(it) } ?: any, rules.minRating == rating, { rules = rules.copy(minRating = rating) }, null)
            }
        }
        ChipGroup(stringResource(R.string.smart_collections_type)) {
            listOf(SmartCollectionRules.Kind.ALL to R.string.smart_collections_type_all, SmartCollectionRules.Kind.MOVIE to R.string.smart_collections_type_movies,
                SmartCollectionRules.Kind.SERIES to R.string.smart_collections_type_shows).forEach { (kind, label) ->
                chip(stringResource(label), rules.type == kind, { rules = rules.copy(type = kind) }, null)
            }
        }
        ChipGroup(stringResource(R.string.smart_collections_sort)) {
            listOf(SmartCollectionRules.Sort.POPULAR to R.string.smart_collections_sort_popular, SmartCollectionRules.Sort.RATING to R.string.smart_collections_sort_rating,
                SmartCollectionRules.Sort.NEWEST to R.string.smart_collections_sort_newest).forEach { (sort, label) ->
                chip(stringResource(label), rules.sort == sort, { rules = rules.copy(sort = sort) }, null)
            }
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm), verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
            chip(stringResource(R.string.smart_collections_hide_watched), rules.hideWatched, { rules = rules.copy(hideWatched = !rules.hideWatched) }, null)
            chip(stringResource(R.string.smart_collections_show_on_home), home, { home = !home }, null)
        }
        Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
            Eyebrow(when {
                loading -> stringResource(R.string.smart_collections_finding)
                shown.isEmpty() -> stringResource(R.string.smart_collections_preview_none)
                else -> stringResource(R.string.smart_collections_preview_count, shown.size)
            })
            preview(shown, loading)
        }
        error?.let { Text(it, style = VortXTheme.type.label.copy(color = VortXTheme.colors.danger)) }
        Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
            chip(stringResource(R.string.for_you_save), true, {
                val trimmed = name.trim()
                val from = rules.yearFrom; val to = rules.yearTo
                when {
                    trimmed.isEmpty() -> error = nameFirst
                    from != null && to != null && from > to -> error = yearOrder
                    else -> {
                        val collection = existing?.copy(name = trimmed, rules = rules, home = home)
                            ?: SmartCollection.make(trimmed, rules, home)
                        persist { ForYouStore.shared(context).save(collection) }
                    }
                }
            }, null)
            chip(stringResource(R.string.for_you_cancel), false, onFinish, null)
            if (existing != null) {
                chip(stringResource(if (confirmDelete) R.string.smart_collections_delete_confirm else R.string.smart_collections_delete), confirmDelete, {
                    if (confirmDelete) persist { ForYouStore.shared(context).delete(existing) } else confirmDelete = true
                }, null)
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ChipGroup(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        Eyebrow(title)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm), verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
            content()
        }
    }
}

@Composable
private fun Eyebrow(text: String) {
    Text(text.uppercase(), style = VortXTheme.type.eyebrow)
}

private fun List<String>.toggle(key: String): List<String> = if (key in this) this - key else this + key
