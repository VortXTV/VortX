package com.vortx.android.home

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.model.Catalog
import com.vortx.android.model.MetaItem
import com.vortx.android.profile.ProfileStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.time.Instant

internal const val CONTINUE_WATCHING_SOURCE_KEY = "vortx.home.continueWatching.source"
internal const val CONTINUE_WATCHING_WINDOW_KEY = "vortx.home.continueWatching.window"

enum class ContinueWatchingSource(val raw: String, val label: String) {
    LOCAL("local", "VortX"), TRAKT("trakt", "Trakt"), SIMKL("simkl", "SIMKL"), UNKNOWN("unknown", "Unavailable");
    companion object {
        fun fromRaw(raw: String?): ContinueWatchingSource = if (raw == null) LOCAL else entries.firstOrNull { it.raw == raw } ?: UNKNOWN
    }
}

enum class ContinueWatchingWindow(val raw: String, val label: String, val cap: Int?) {
    LAST_90_DAYS("last90Days", "Last 90 days", null), ITEMS_20("20", "20 items", 20),
    ITEMS_40("40", "40 items", 40), ITEMS_60("60", "60 items", 60),
    ITEMS_80("80", "80 items", 80), ITEMS_100("100", "100 items", 100);
    companion object { fun fromRaw(raw: String?) = entries.firstOrNull { it.raw == raw } ?: ITEMS_20 }
}

internal data class ContinueWatchingSelection(
    val source: ContinueWatchingSource = ContinueWatchingSource.LOCAL,
    val window: ContinueWatchingWindow = ContinueWatchingWindow.ITEMS_20,
    val revision: Long = 0,
)

/** Writers retire captured capabilities before SharedPreferences can defer its main-thread callback. */
internal object ContinueWatchingSelectionRevision {
    private val value = java.util.concurrent.atomic.AtomicLong(0)
    fun current(): Long = value.get()
    fun changed(): Long = value.incrementAndGet()
}

/** Flat keys are only the active profile projection; capture puts every edit in the portable roster. */
internal class ContinueWatchingPreferences(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE)
    private val _state = MutableStateFlow(read())
    val state = _state.asStateFlow()
    private val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == CONTINUE_WATCHING_SOURCE_KEY || key == CONTINUE_WATCHING_WINDOW_KEY) {
            ContinueWatchingSelectionRevision.changed()
            _state.value = read()
        }
    }
    init { prefs.registerOnSharedPreferenceChangeListener(listener) }
    private fun read() = ContinueWatchingSelection(
        ContinueWatchingSource.fromRaw(prefs.getString(CONTINUE_WATCHING_SOURCE_KEY, null)),
        ContinueWatchingWindow.fromRaw(prefs.getString(CONTINUE_WATCHING_WINDOW_KEY, null)), ContinueWatchingSelectionRevision.current(),
    )
    fun current(): ContinueWatchingSelection = read()
    fun close() = prefs.unregisterOnSharedPreferenceChangeListener(listener)
}

internal data class ContinueWatchingPermit(
    val owner: ContinueWatchingOwner,
    val profileId: String,
    val accountId: String,
    val selection: ContinueWatchingSelection,
    val sessionEpoch: Long?,
)

/** Process-only capability. Never serialized; its immutable capture cannot adopt a newer route owner. */
class ContinueWatchingAdmission internal constructor(private val acceptsCapture: () -> Boolean) {
    fun isCurrent(): Boolean = runCatching(acceptsCapture).getOrDefault(false)
}

/** Both local and remote published cards carry their immutable, process-only route authority. */
internal fun continueWatchingItemWithAdmission(item: MetaItem, token: String?, admission: ContinueWatchingAdmission?): MetaItem =
    item.copy(continueWatchingPermit = token, continueWatchingAdmission = admission)

internal suspend fun <T> continueWatchingAdmittedResult(admission: ContinueWatchingAdmission?,
    discard: (T) -> Unit = {}, resolve: suspend () -> Result<T>): Result<T> {
    if (admission?.isCurrent() == false) return Result.failure(IllegalStateException("Continue Watching request expired"))
    val result = resolve()
    if (admission?.isCurrent() == false) {
        result.getOrNull()?.let(discard)
        return Result.failure(IllegalStateException("Continue Watching request expired"))
    }
    return result
}

internal fun saveableContinueWatchingEpisode(hint: com.vortx.android.model.PreferredEpisode?, admission: ContinueWatchingAdmission?): com.vortx.android.model.PreferredEpisode? =
    hint.takeIf { admission == null }

internal suspend fun continueWatchingFocusDwell(admission: ContinueWatchingAdmission, dwell: suspend () -> Unit): Boolean {
    if (!admission.isCurrent()) return false
    dwell()
    return admission.isCurrent()
}

internal fun continueWatchingPermitIsCurrent(captured: ContinueWatchingPermit?, current: ContinueWatchingPermit,
    renderedOwner: ContinueWatchingOwner?, capturedToken: String?, acceptedToken: String?): Boolean =
    captured != null && captured == current && capturedToken != null && capturedToken == acceptedToken &&
        (current.sessionEpoch != null || current.selection.source == ContinueWatchingSource.LOCAL) &&
        current.selection.source != ContinueWatchingSource.UNKNOWN &&
        continueWatchingOwnerIsKnown(current.owner, current.profileId) && renderedOwner == current.owner

internal fun continueWatchingHeroCatalogs(rows: List<Catalog>): List<Catalog> =
    rows.filterNot { it.id == HomeRail.CONTINUE_CATALOG_ID && it.readOnly }

/** Generic metadata enrichment has no CW owner lease; use the captured CW presentation unchanged. */
internal fun continueWatchingMayUseGenericEnrichment(item: MetaItem): Boolean = item.continueWatchingPermit == null

internal fun continueWatchingOwnerIsKnown(owner: ContinueWatchingOwner, profileId: String): Boolean =
    owner.profileId == profileId && owner.accountSlot.isNotBlank() && owner.principal.isNotBlank() &&
        !owner.principal.contains("unavailable", ignoreCase = true) &&
        !owner.principal.contains("unknown", ignoreCase = true)

/** Unknown activity clocks survive capped views but cannot claim to be within the last 90 days. */
internal fun boundContinueWatching(items: List<MetaItem>, window: ContinueWatchingWindow, nowMillis: Long): List<MetaItem> {
    val ordered = items.sortedWith(compareByDescending<MetaItem> { it.continueWatchingActivityAtMillis }.thenBy { "${it.type.id}|${it.id}" })
    return if (window.cap != null) ordered.take(window.cap) else {
        val boundary = nowMillis - 90L * 24 * 60 * 60 * 1000
        ordered.filter { it.continueWatchingActivityAtMillis?.let { at -> at in boundary..nowMillis } == true }
    }
}

internal fun parseContinueWatchingActivity(raw: String?): Long? = raw?.let {
    runCatching { Instant.parse(it).toEpochMilli() }.getOrNull()
}

/** Union aliases transitively before choosing a winner, including rows bridging IMDB and TMDB ids. */
internal fun <T> dedupeContinueWatchingSeeds(seeds: List<T>, aliases: (T) -> Set<String>, comparator: Comparator<T>): List<T> {
    val groups = mutableListOf<Pair<MutableSet<String>, MutableList<T>>>()
    seeds.forEach { seed ->
        val keys = aliases(seed)
        val matches = groups.filter { (known, _) -> known.any(keys::contains) }
        if (matches.isEmpty()) groups += keys.toMutableSet() to mutableListOf(seed) else {
            val target = matches.first()
            target.first.addAll(keys); target.second.add(seed)
            matches.drop(1).forEach { target.first.addAll(it.first); target.second.addAll(it.second); groups.remove(it) }
        }
    }
    return groups.map { it.second.sortedWith(comparator).first() }.sortedWith(comparator)
}

/** Exactly one primary row; selecting a disconnected remote never publishes local progress as that service. */
internal fun withSelectedContinueWatchingRail(
    rows: List<Catalog>, selection: ContinueWatchingSelection, remoteItems: List<MetaItem>,
    status: String?, nowMillis: Long,
): List<Catalog> {
    val local = rows.firstOrNull { it.id == HomeRail.CONTINUE_CATALOG_ID }
    val base = rows.filterNot { it.id == HomeRail.CONTINUE_CATALOG_ID || it.id == TRAKT_CONTINUE_WATCHING_CATALOG_ID }
    val items = boundContinueWatching(if (selection.source == ContinueWatchingSource.LOCAL) local?.items.orEmpty() else remoteItems,
        selection.window, nowMillis)
    if (selection.source == ContinueWatchingSource.LOCAL && items.isEmpty()) return base
    return listOf(Catalog(HomeRail.CONTINUE_CATALOG_ID,
        if (selection.source == ContinueWatchingSource.LOCAL) "Continue Watching" else "Continue Watching from ${selection.source.label}",
        items, readOnly = selection.source != ContinueWatchingSource.LOCAL, statusMessage = status)) + base
}
