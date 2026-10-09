package com.vortx.android.home

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.ContinueWatchingOwnerGate
import com.vortx.android.integrations.ConnectedIntegrationAccess
import com.vortx.android.integrations.ExternalIntegrationOwner
import com.vortx.android.integrations.TraktAuth
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.util.Base64

internal const val IMPORTED_CATALOG_PREFIX = "vortx.home.importedLists:"

internal enum class ImportedListProvider(val wire: String) {
    LETTERBOXD("letterboxd"),
    MDBLIST("mdblist"),
    TRAKT("trakt");

    companion object {
        fun fromWire(raw: String?): ImportedListProvider? = entries.firstOrNull { it.wire == raw?.lowercase() }
    }
}

internal data class ImportedListCatalog(
    val id: String,
    val title: String,
    val provider: ImportedListProvider,
    val sourceUrl: String,
    val items: List<MetaItem>,
    val requiresConnection: Boolean = false,
    val connectionOwner: ExternalIntegrationOwner? = null,
)

/** Process-live registry for public imported lists written under Apple's exact settings key. */
internal class ImportedCatalogs private constructor(context: Context) {
    private val prefs = context.applicationContext
        .getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE)
    private val _catalogs = MutableStateFlow(read())
    private val privateCatalogs = ImportedPrivateRows { ConnectedIntegrationAccess.current(it) }
    val catalogs: StateFlow<List<ImportedListCatalog>> = _catalogs.asStateFlow()

    // Keep a strong reference for the process lifetime. Android otherwise weakly retains preference listeners.
    private val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == KEY) reconcilePrivate()
    }

    init {
        prefs.registerOnSharedPreferenceChangeListener(listener)
        val durable = _catalogs.value
        val raw = prefs.all[KEY] as? String
        if (raw != null && raw.trim() != ImportedCatalogCodec.encode(durable))
            ContinueWatchingOwnerGate.serialized { persist(durable) }
        ProfileStore.sharedOrNull()?.addHomeTransitionListener { reconcilePrivate() }
        ProfileStore.sharedOrNull()?.addSwitchListener { reconcilePrivate() }
        CoroutineScope(SupervisorJob() + Dispatchers.Default).launch {
            TraktAuth.sessionBoundary.collect { reconcilePrivate() }
        }
    }

    fun register(catalog: ImportedListCatalog): Boolean = ContinueWatchingOwnerGate.serialized {
        val validated = ImportedCatalogCodec.validate(catalog) ?: return@serialized false
        if (validated.items.isEmpty()) return@serialized false
        if (validated.requiresConnection) {
            if (!privateCatalogs.register(validated)) return@serialized false
            persist(listOf(validated) + _catalogs.value.filterNot { it.id == validated.id || it.sourceUrl == validated.sourceUrl })
            return@serialized true
        }
        privateCatalogs.remove(validated.id)
        val next = _catalogs.value
            .filterNot { it.id == validated.id || it.sourceUrl == validated.sourceUrl }
            .toMutableList()
            .apply { add(0, validated) }
            .take(MAX_CATALOGS)
        persist(next)
        true
    }

    fun remove(id: String) = ContinueWatchingOwnerGate.serialized {
        privateCatalogs.remove(id)
        persist(_catalogs.value.filterNot { it.id == id })
    }

    fun reorder(ids: List<String>) = ContinueWatchingOwnerGate.serialized {
        val current = _catalogs.value
        val byId = current.associateBy(ImportedListCatalog::id)
        val ordered = ids.distinct().mapNotNull(byId::get)
        persist((ordered + current.filterNot { it.id in ids }).take(MAX_CATALOGS))
    }

    private fun read(): List<ImportedListCatalog> =
        (prefs.all[KEY] as? String)?.let(ImportedCatalogCodec::decode).orEmpty()

    private fun persist(catalogs: List<ImportedListCatalog>) {
        val durable = catalogs.mapNotNull(ImportedCatalogCodec::validate)
            .filterNot(ImportedListCatalog::requiresConnection)
            .take(MAX_CATALOGS)
        val private = privateCatalogs.visible().associateBy { it.id }
        _catalogs.value = catalogs.mapNotNull { if (it.requiresConnection) private[it.id] else it }
            .distinctBy { it.id }.take(MAX_CATALOGS)
        prefs.edit().putString(KEY, ImportedCatalogCodec.encode(durable)).apply()
    }

    private fun reconcilePrivate() = ContinueWatchingOwnerGate.serialized {
        val available = (privateCatalogs.visible() + read()).associateBy { it.id }.toMutableMap()
        val retained = _catalogs.value.mapNotNull { available.remove(it.id) }
        _catalogs.value = (retained + available.values).take(MAX_CATALOGS)
    }

    fun publicationSnapshot(): ImportedCatalogPublication = ContinueWatchingOwnerGate.serialized {
        reconcilePrivate()
        ImportedCatalogPublication(_catalogs.value.toList())
    }

    /** Lock order: profile/account gate, then provider admission, held through the Home assignment.
     * The async registry collector is only a repaint trigger; it is never the privacy boundary.
     */
    fun publishSnapshot(snapshot: ImportedCatalogPublication, rows: List<Catalog>, publish: (List<Catalog>) -> Unit) =
        ContinueWatchingOwnerGate.serialized {
            val current = publicationSnapshot()
            val owner = snapshot.catalogs.firstOrNull { it.requiresConnection }?.connectionOwner
            val admitted = owner?.let { ConnectedIntegrationAccess.publish(it) {
                publish(admitImportedCatalogPublication(snapshot, current, rows) { captured -> captured == it })
                true
            } } == true
            if (!admitted) publish(admitImportedCatalogPublication(snapshot, current, rows) { false })
        }

    companion object {
        const val KEY = "vortx.catalog.importedLists"
        const val MAX_CATALOGS = 50

        @Volatile private var instance: ImportedCatalogs? = null
        fun reconcileConnection() { instance?.reconcilePrivate() }
        fun shared(context: Context): ImportedCatalogs = instance ?: ContinueWatchingOwnerGate.serialized {
            synchronized(this) { instance ?: ImportedCatalogs(context.applicationContext).also { instance = it } }
        }
    }
}

internal data class ImportedCatalogPublication(val catalogs: List<ImportedListCatalog>) {
    val rails: List<Catalog> get() = importedCatalogRails(catalogs)
}

/** Preserve native admission on each row; only remove stale imports, never recertify replacement items. */
internal fun admitImportedCatalogPublication(
    captured: ImportedCatalogPublication, current: ImportedCatalogPublication, rows: List<Catalog>,
    ownerCurrent: (ExternalIntegrationOwner) -> Boolean,
): List<Catalog> {
    val allowed = captured.catalogs.filter { catalog ->
        current.catalogs.any { it == catalog } && (!catalog.requiresConnection ||
            catalog.connectionOwner?.let(ownerCurrent) == true)
    }.mapTo(hashSetOf()) { "$IMPORTED_CATALOG_PREFIX${it.id}" }
    return rows.filter { !it.id.startsWith(IMPORTED_CATALOG_PREFIX) || it.id in allowed }
}

/** Caller serializes against the profile/account boundary. No private metadata has a disk codec. */
internal class ImportedPrivateRows(private val current: (ExternalIntegrationOwner) -> Boolean) {
    private val rows = mutableListOf<ImportedListCatalog>()
    fun register(catalog: ImportedListCatalog): Boolean {
        val owner = catalog.connectionOwner ?: return false
        if (!catalog.requiresConnection || catalog.provider != ImportedListProvider.TRAKT || !current(owner)) return false
        rows.removeAll { it.id == catalog.id || it.sourceUrl == catalog.sourceUrl }
        rows.add(0, catalog)
        while (rows.size > ImportedCatalogs.MAX_CATALOGS) rows.removeAt(rows.lastIndex)
        return true
    }
    fun remove(id: String) { rows.removeAll { it.id == id } }
    fun visible(): List<ImportedListCatalog> {
        rows.removeAll { it.connectionOwner?.let(current) != true }
        return rows.toList()
    }
}

internal object ImportedCatalogCodec {
    private const val MAX_RAW_BYTES = 2 * 1024 * 1024
    private const val MAX_ITEMS = 150

    fun decode(stored: String): List<ImportedListCatalog> {
        val json = decodePayload(stored) ?: return emptyList()
        val array = runCatching { JSONArray(json) }.getOrNull() ?: return emptyList()
        return buildList {
            for (index in 0 until array.length()) {
                val decoded = array.optJSONObject(index)?.let(::decodeCatalog) ?: continue
                validate(decoded)?.takeUnless(ImportedListCatalog::requiresConnection)?.let(::add)
                if (size == ImportedCatalogs.MAX_CATALOGS) break
            }
        }
    }

    fun encode(catalogs: List<ImportedListCatalog>): String = JSONArray().apply {
        catalogs.mapNotNull(::validate)
            .filterNot(ImportedListCatalog::requiresConnection)
            .take(ImportedCatalogs.MAX_CATALOGS)
            .forEach { catalog ->
                put(JSONObject().apply {
                    put("id", catalog.id)
                    put("title", catalog.title)
                    put("provider", catalog.provider.wire)
                    put("sourceURL", catalog.sourceUrl)
                    put("requiresConnection", false)
                    put("items", JSONArray().apply {
                        catalog.items.take(MAX_ITEMS).forEach { item ->
                            put(JSONObject().apply {
                                put("id", item.id)
                                put("type", item.type.id)
                                put("name", item.name)
                                item.poster?.let { put("poster", it) }
                            })
                        }
                    })
                })
            }
    }.toString()

    fun validate(catalog: ImportedListCatalog): ImportedListCatalog? {
        val id = catalog.id.trim().takeIf { it.startsWith("imported:") && it.length <= 240 } ?: return null
        val title = catalog.title.trim().takeIf { it.isNotEmpty() && it.length <= 200 } ?: return null
        val sourceUrl = normalizedWebUrl(catalog.sourceUrl) ?: return null
        val seen = hashSetOf<String>()
        val items = catalog.items.asSequence().mapNotNull(::validateItem)
            .filter { seen.add("${it.type.id}:${it.id}") }
            .take(MAX_ITEMS)
            .toList()
        if (items.isEmpty()) return null
        return catalog.copy(id = id, title = title, sourceUrl = sourceUrl, items = items)
    }

    private fun decodePayload(stored: String): String? {
        val trimmed = stored.trim()
        if (trimmed.toByteArray().size > MAX_RAW_BYTES) return null
        if (trimmed.startsWith("[")) return trimmed
        val bytes = runCatching { Base64.getDecoder().decode(trimmed) }.getOrNull() ?: return null
        if (bytes.size > MAX_RAW_BYTES) return null
        return bytes.toString(Charsets.UTF_8).takeIf { it.trimStart().startsWith("[") }
    }

    private fun decodeCatalog(json: JSONObject): ImportedListCatalog? {
        val provider = ImportedListProvider.fromWire(json.optString("provider")) ?: return null
        val itemsJson = json.optJSONArray("items") ?: return null
        val items = buildList {
            for (index in 0 until itemsJson.length()) {
                val item = itemsJson.optJSONObject(index) ?: continue
                val type = MediaType.fromId(item.optString("type"))
                add(
                    MetaItem(
                        id = item.optString("id"),
                        type = type,
                        name = item.optString("name"),
                        poster = item.optString("poster").takeIf(String::isNotBlank),
                    ),
                )
                if (size == MAX_ITEMS) break
            }
        }
        return ImportedListCatalog(
            id = json.optString("id"),
            title = json.optString("title"),
            provider = provider,
            sourceUrl = json.optString("sourceURL"),
            items = items,
            requiresConnection = json.optBoolean("requiresConnection", false),
        )
    }

    private fun validateItem(item: MetaItem): MetaItem? {
        val id = item.id.trim().takeIf(::isEngineId) ?: return null
        if (item.type != MediaType.MOVIE && item.type != MediaType.SERIES) return null
        val name = item.name.trim().takeIf { it.isNotEmpty() && it.length <= 300 } ?: return null
        val poster = item.poster?.let(::normalizedWebUrl)
        return item.copy(id = id, name = name, poster = poster)
    }

    private fun normalizedWebUrl(raw: String): String? = runCatching {
        URI(raw.trim()).takeIf { uri ->
            (uri.scheme.equals("https", true) || uri.scheme.equals("http", true)) &&
                !uri.host.isNullOrBlank() && uri.userInfo == null
        }?.normalize()?.toString()
    }.getOrNull()

    private fun isEngineId(value: String): Boolean =
        (value.startsWith("tt") && value.length > 2 && value.drop(2).all(Char::isDigit)) ||
            (value.startsWith("tmdb:") && value.removePrefix("tmdb:").let { it.isNotEmpty() && it.all(Char::isDigit) })
}

internal fun importedCatalogRails(catalogs: List<ImportedListCatalog>): List<Catalog> = catalogs.mapNotNull { catalog ->
    catalog.takeIf { it.items.isNotEmpty() && (!it.requiresConnection ||
        it.connectionOwner?.let { owner -> ConnectedIntegrationAccess.current(owner) } == true) }?.let {
        Catalog("$IMPORTED_CATALOG_PREFIX${it.id}", it.title, it.items)
    }
}

internal fun withImportedCatalogRails(rows: List<Catalog>, rails: List<Catalog>): List<Catalog> {
    val base = rows.filterNot { it.id.startsWith(IMPORTED_CATALOG_PREFIX) }
    if (rails.isEmpty()) return base
    val anchor = base.indexOfLast { it.id.startsWith("vortx.home.mediaServers:") }
        .takeIf { it >= 0 }
        ?: base.indexOfFirst { it.id == "vortx.home.simklWatchlist" }.takeIf { it >= 0 }
        ?: base.indexOfFirst { it.id == "vortx.home.traktWatchlist" }.takeIf { it >= 0 }
        ?: base.indexOfFirst { it.id == "vortx.home.becauseYouWatched" }.takeIf { it >= 0 }
        ?: -1
    return base.toMutableList().apply { addAll(anchor + 1, rails.filter { it.items.isNotEmpty() }) }
}
