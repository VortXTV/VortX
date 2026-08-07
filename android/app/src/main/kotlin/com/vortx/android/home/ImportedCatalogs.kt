package com.vortx.android.home

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.profile.ProfileStore
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
)

/** Process-live registry for public imported lists written under Apple's exact settings key. */
internal class ImportedCatalogs private constructor(context: Context) {
    private val prefs = context.applicationContext
        .getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE)
    private val _catalogs = MutableStateFlow(read())
    val catalogs: StateFlow<List<ImportedListCatalog>> = _catalogs.asStateFlow()

    // Keep a strong reference for the process lifetime. Android otherwise weakly retains preference listeners.
    private val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == KEY) _catalogs.value = read()
    }

    init {
        prefs.registerOnSharedPreferenceChangeListener(listener)
        val durable = _catalogs.value
        val raw = prefs.all[KEY] as? String
        if (raw != null && raw.trim() != ImportedCatalogCodec.encode(durable)) persist(durable)
    }

    @Synchronized
    fun register(catalog: ImportedListCatalog): Boolean {
        val validated = ImportedCatalogCodec.validate(catalog) ?: return false
        if (validated.requiresConnection || validated.items.isEmpty()) return false
        val next = _catalogs.value
            .filterNot { it.id == validated.id || it.sourceUrl == validated.sourceUrl }
            .toMutableList()
            .apply { add(0, validated) }
            .take(MAX_CATALOGS)
        persist(next)
        return true
    }

    @Synchronized
    fun remove(id: String) = persist(_catalogs.value.filterNot { it.id == id })

    @Synchronized
    fun reorder(ids: List<String>) {
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
        _catalogs.value = durable
        prefs.edit().putString(KEY, ImportedCatalogCodec.encode(durable)).apply()
    }

    companion object {
        const val KEY = "vortx.catalog.importedLists"
        const val MAX_CATALOGS = 50

        @Volatile private var instance: ImportedCatalogs? = null
        fun shared(context: Context): ImportedCatalogs = instance ?: synchronized(this) {
            instance ?: ImportedCatalogs(context.applicationContext).also { instance = it }
        }
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
    catalog.takeIf { !it.requiresConnection && it.items.isNotEmpty() }?.let {
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
