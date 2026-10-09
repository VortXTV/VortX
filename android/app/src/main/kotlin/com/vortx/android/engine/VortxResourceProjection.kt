package com.vortx.android.engine

import org.json.JSONArray
import org.json.JSONObject

/** Presentation-wire projection consumed by EngineState. Does not call or initialize Stremio. */
internal object VortxResourceProjection {
    private fun validate(snapshot: VortxResourceSnapshot, registry: List<VortxResourceAddon>) {
        require(registry.map { it.id }.toSet().size == registry.size)
        require(snapshot.groups.all { group -> registry.find { it.id == group.addonId }?.transportUrl == snapshot.sourceUrls[group.addonId] })
    }
    fun entry(group: VortxResourceGroup, request: VortxResourceRequest, registry: List<VortxResourceAddon>): JSONObject {
        val addon = requireNotNull(registry.find { it.id == group.addonId }) { "Unknown source identity" }
        val content = if (group.status == "ready") {
            val items = group.items(request.resource)
            val payload = when (request.resource) {
                VortxResourceRequest.Resource.META, VortxResourceRequest.Resource.MANIFEST -> items.firstOrNull() ?: JSONObject.NULL
                else -> JSONArray(items)
            }
            if (request.resource == VortxResourceRequest.Resource.META && items.isEmpty())
                JSONObject().put("type", "Err").put("content", JSONObject().put("code", "empty_resource"))
            else JSONObject().put("type", "Ready").put("content", payload)
        } else JSONObject().put("type", "Err").put("content", JSONObject().put("code", group.errorCode ?: group.status))
        return JSONObject().put("request", JSONObject().put("base", addon.transportUrl).put("path", request.json())).put("content", content)
    }

    fun board(pages: List<VortxResourceSnapshot>, registry: List<VortxResourceAddon>): String {
        val rows = linkedMapOf<List<String>, JSONArray>()
        val seen = mutableSetOf<Pair<List<String>, List<Pair<String, String>>>>()
        pages.forEach { page ->
            validate(page, registry)
            require(page.request.resource == VortxResourceRequest.Resource.CATALOG && page.ownerId == pages.first().ownerId)
            page.groups.forEach { group ->
                val key = listOf(group.addonId, page.request.type, page.request.id)
                require(seen.add(key to page.request.extra)) { "Duplicate catalog page" }
                rows.getOrPut(key) { JSONArray() }.put(entry(group, page.request, registry))
            }
        }
        return JSONObject().put("selected", if (pages.isEmpty()) JSONObject.NULL else JSONObject())
            .put("catalogs", JSONArray(rows.values.toList())).toString()
    }

    fun metaDetails(meta: VortxResourceSnapshot, streams: VortxResourceSnapshot?, expectedStream: VortxResourceRequest?,
                    registry: List<VortxResourceAddon>): String {
        require(meta.request.resource == VortxResourceRequest.Resource.META)
        validate(meta, registry)
        if (streams != null) validate(streams, registry)
        if (streams != null) require(streams.ownerId == meta.ownerId && streams.request == expectedStream &&
            streams.request.resource == VortxResourceRequest.Resource.STREAM && streams.request.type == meta.request.type)
        val embedded = JSONArray()
        meta.groups.filter { it.status == "ready" }.forEach { group ->
            val value = group.items(meta.request.resource).firstOrNull() ?: return@forEach
            val target = expectedStream ?: VortxResourceRequest(VortxResourceRequest.Resource.STREAM, meta.request.type, meta.request.id)
            val videos = value.optJSONArray("videos") ?: JSONArray()
            val video = (0 until videos.length()).mapNotNull(videos::optJSONObject).find { it.optString("id") == target.id }
            val items = video?.optJSONArray("streams") ?: if (target.id == meta.request.id) value.optJSONArray("streams") else null
            if (items != null) embedded.put(entry(VortxResourceGroup(group.addonId, "ready", JSONObject().put("streams", items).toString(), null), target, registry))
        }
        return JSONObject().put("selected", JSONObject().put("metaPath", meta.request.json()).put("streamPath", expectedStream?.json() ?: JSONObject.NULL))
            .put("metaItems", JSONArray(meta.groups.map { entry(it, meta.request, registry) }))
            .put("streams", JSONArray(streams?.groups?.map { entry(it, streams.request, registry) } ?: emptyList<JSONObject>()))
            .put("metaStreams", embedded).toString()
    }

    fun subtitles(snapshot: VortxResourceSnapshot, registry: List<VortxResourceAddon>): String {
        require(snapshot.request.resource == VortxResourceRequest.Resource.SUBTITLES)
        validate(snapshot, registry)
        return JSONArray(snapshot.groups.map { entry(it, snapshot.request, registry) }).toString()
    }
}
