package com.vortx.android.engine

import com.vortx.android.model.AddonOrder
import com.vortx.android.profile.UserProfile
import org.json.JSONArray
import org.json.JSONObject
import java.math.BigDecimal
import java.net.URI
import java.time.Instant
import java.util.UUID
import kotlin.math.roundToLong

/**
 * Pure adapter for the kernel's one-time, authenticated `import_legacy_sync` action. The caller must
 * resolve the FULL account roster first and retain the encrypted original document and full profile
 * preferences beside the native projection. This is not a decoder for an unscoped device cache.
 *
 * Unsupported/ambiguous evidence fails closed: no wall-clock reads, guessed account bindings, guessed
 * library types, opaque-bitfield decoding, or treating a saved-only overlay row as a viewing event.
 */
internal fun nativeLegacyMaterial(
    document: JSONObject,
    roster: List<UserProfile>,
    rosterModifiedSeconds: Double?,
): JSONObject = LegacyMaterialAdapter(document, roster, rosterModifiedSeconds).build()

private class LegacyMaterialAdapter(
    private val document: JSONObject,
    private val roster: List<UserProfile>,
    private val modified: Double?,
) {
    private val vortx = objectField(document, "vortx") ?: JSONObject()
    private val owner = roster.singleOrNull { it.isOwner }
        ?: fail("A unique authenticated owner profile is required")
    private val profiles = roster.associateBy { it.id }
    private val watchRows = linkedMapOf<String, MutableList<JSONObject>>()
    private val knownTitles = linkedMapOf<String, MutableMap<String, String>>()
    private val links = linkedMapOf<String, MutableList<List<String>>>()

    fun build(): JSONObject {
        // Website patches have not been reconciled into the full legacy carrier. This check must
        // run on every authenticated pull, including native-carrier and existing-checkpoint paths.
        if (document.has("profileEdits") && !document.isNull("profileEdits")) {
            val edits = document.optJSONObject("profileEdits")
            requireMaterial(edits != null && edits.length() == 0, "Pending profile edits require reconciliation")
        }
        requireMaterial(roster.isNotEmpty() && profiles.size == roster.size, "Duplicate or empty profile roster")
        roster.forEach {
            requireMaterial(runCatching { UUID.fromString(it.id).toString().equals(it.id, true) }.getOrDefault(false), "Invalid profile identity")
            requireMaterial(!it.usesOwnAccount, "Own-account profile requires an authenticated streaming-account identity")
            watchRows[it.id] = mutableListOf(); knownTitles[it.id] = linkedMapOf(); links[it.id] = mutableListOf()
        }
        modified?.let { validClock(it, "rosterModifiedSeconds") }
        val deleted = strings(arrayField(vortx, "deletedProfiles"), "deletedProfiles").map { raw ->
            profiles.keys.singleOrNull { it.equals(raw, true) }
                ?: runCatching { UUID.fromString(raw).toString().uppercase() }.getOrElse { fail("Invalid deleted profile identity") }
        }.distinct()
        requireMaterial(owner.id !in deleted, "Owner profile is tombstoned")
        val nativeRoster = JSONArray(roster.map(::profile))
        val addons = JSONObject().put(owner.id, addonBucket())
        val libraries = JSONObject().put(owner.id, ownerLibrary())
        importOverlays()
        importOwnerIntents()
        val output = JSONObject().put("schemaVersion", 1).put("roster", nativeRoster)
            .put("deletedProfileIds", JSONArray(deleted)).put("addons", addons).put("libraries", libraries)
            .put("watches", JSONObject().also { out -> watchRows.forEach { (id, rows) -> out.put(id, JSONArray(resolveWatchRows(rows))) } })
            .put("identityLinks", JSONObject().also { out -> links.forEach { (id, groups) -> out.put(id, JSONArray(groups.map(::JSONArray))) } })
        modified?.let { output.put("rosterModifiedSeconds", it) }
        requireNoCredentials(output)
        return output
    }

    private fun profile(profile: UserProfile): JSONObject {
        requireMaterial(profile.textScale.isFinite() && profile.textScale > 0 && profile.textScale <= 100, "Invalid profile text scale")
        val settings = JSONObject().put("accent", profile.accentID).put("oled", profile.oled)
            .put("textScale", (profile.textScale * 1000).roundToLong())
            .put("languages", JSONArray(listOfNotNull(profile.playback?.audioLang?.takeIf(String::isNotBlank), profile.playback?.subtitleLang?.takeIf(String::isNotBlank)).distinct()))
            .put("disabledAddons", JSONArray(profile.disabledAddons.orEmpty()))
        val account = if (profile.isOwner) JSONObject().put("kind", "local_only")
            else JSONObject().put("kind", "shared").put("value", owner.id)
        return JSONObject().put("id", profile.id).put("name", profile.name).put("owner", profile.isOwner)
            .put("account", account).put("addons", "share_primary").put("settings", settings)
            .put("parental", JSONObject().put("kids", profile.isKids).put("familyEdit", profile.familyEdit))
            .also { out -> profile.pin?.takeIf(String::isNotEmpty)?.let { pin ->
                requireMaterial(Regex("sha256:[0-9a-fA-F]{64}").matches(pin), "Legacy plaintext or malformed PIN requires explicit reconciliation")
                out.put("pin", pin)
            } }
    }

    private fun addonBucket(): JSONObject {
        val descriptors = linkedMapOf<String, JSONObject>()
        for (rows in listOf(arrayField(vortx, "addons"), arrayField(document, "addons"))) {
            objects(rows, "addons").forEach { row ->
                val url = string(row, "transportUrl")
                val uri = runCatching { URI(url) }.getOrNull()
                requireMaterial(uri != null && uri.scheme?.lowercase() in setOf("http", "https") && !uri.host.isNullOrBlank() && uri.rawUserInfo == null && uri.rawFragment == null,
                    "Unsupported add-on transport URL")
                PublicAddressPolicy.requireLiteralPublicOrHostname(uri!!.host)
                val manifest = objectField(row, "manifest") ?: fail("URL-only add-on requires manifest reconciliation")
                string(manifest, "id"); string(manifest, "name")
                val identity = AddonOrder.normalize(url)
                descriptors.putIfAbsent(identity, JSONObject(row.toString()).put("transportUrl", identity))
            }
        }
        fun resolve(raw: String): String {
            val normalized = AddonOrder.normalize(raw)
            // Old tombstone writers lowercased the entire URL. Match only a UNIQUE actual descriptor;
            // never lowercase configured paths or percent-encoded secrets in the native identity.
            val matches = descriptors.keys.filter { it.lowercase() == normalized.lowercase() }
            requireMaterial(normalized != normalized.lowercase() || matches.size <= 1, "Ambiguous legacy add-on URL identity")
            if (normalized in descriptors) return normalized
            requireMaterial(matches.size <= 1, "Ambiguous legacy add-on URL identity")
            return matches.singleOrNull() ?: normalized
        }
        val intents = linkedMapOf<String, JSONObject>()
        objectField(vortx, "deletedAddonsTs")?.let { stamps -> for (raw in stamps.keys()) {
            val entry = stamps.optJSONObject(raw) ?: fail("Malformed add-on intent")
            val url = resolve(raw)
            val target = intents.getOrPut(url) { JSONObject().put("transportUrl", url) }
            mergeClock(entry, target, "addedAt", "addedAtMs"); mergeClock(entry, target, "removedAt", "removedAtMs")
        } }
        for (raw in strings(arrayField(vortx, "deletedAddons"), "deletedAddons")) {
            val url = resolve(raw)
            // Exact shipping AddonTombstones.MIGRATION_EPOCH_MS, not a fabricated viewing/now clock.
            if (!hasPositiveIntent(intents[url])) intents.getOrPut(url) { JSONObject().put("transportUrl", url) }.put("removedAtMs", 1.0)
        }
        for (raw in strings(arrayField(document, "webAddonRemovals"), "webAddonRemovals")) {
            // Shipping code mints a local clock for an unseen web removal. Migration is pure: a real
            // timestamp must be reconciled by the account layer rather than fabricated here.
            requireMaterial(hasPositiveIntent(intents[resolve(raw)]), "Unclocked web add-on removal requires reconciliation")
        }
        val order = strings(arrayField(document, "addonOrder"), "addonOrder").map(::resolve).distinct()
        return JSONObject().put("items", JSONArray(descriptors.values)).put("order", JSONArray(order)).put("intents", JSONArray(intents.values))
    }

    private fun ownerLibrary(): JSONObject {
        val rows = objects(arrayField(vortx, "library") ?: arrayField(document, "library"), "owner library")
        val items = linkedMapOf<String, JSONObject>()
        val intents = linkedMapOf<String, JSONObject>()
        val seen = hashSetOf<String>()
        val declaredRemoved = hashSetOf<String>()
        for (row in rows) {
            val id = string(row, "id"); val type = contentType(row)
            known(owner.id, id, type)
            val key = "$type:$id"
            requireMaterial(seen.add(key), "Duplicate owner library identity")
            val item = JSONObject().put("kind", "standard").put("id", id).put("type", type).put("name", optionalString(row, "name").orEmpty())
            optionalString(row, "poster")?.takeIf(String::isNotEmpty)?.let { item.put("poster", it) }
            // Keep the descriptor as payload; membership clocks below decide visibility. A viewing
            // clock is never evidence for a library deletion, even if this snapshot says removed.
            items[key] = item
            if (optionalBoolean(row, "removed") == true) declaredRemoved += key
            importWatch(owner.id, id, row, ownerRow = true)
        }
        val historyBucket = objectField(vortx, "byProfile")?.let { objectField(it, UserProfile.OWNER_ID) }
        for (row in objects(historyBucket?.let { arrayField(it, "ownerHistory") }, "owner history")) {
            val id = string(row, "id"); known(owner.id, id, contentType(row))
            importWatch(owner.id, id, row, ownerRow = true, historyOnly = true)
        }
        fun keyFor(raw: String): String {
            val known = knownTitles.getValue(owner.id)
            val matched = known.entries.filter { it.key.equals(raw, true) || "${it.value}:${it.key}".equals(raw, true) }
            requireMaterial(matched.size == 1, "Untyped library removal requires title-type reconciliation")
            return "${matched.single().value}:${matched.single().key}"
        }
        objectField(vortx, "deletedLibraryTs")?.let { stamps -> for (raw in stamps.keys()) {
            val entry = stamps.optJSONObject(raw) ?: fail("Malformed library intent")
            val key = keyFor(raw); val target = intents.getOrPut(key) { JSONObject().put("key", key) }
            mergeClock(entry, target, "addedAt", "addedAtMs"); mergeClock(entry, target, "removedAt", "removedAtMs")
        } }
        for (raw in strings(arrayField(vortx, "deletedLibrary"), "deletedLibrary")) {
            val key = keyFor(raw)
            // Exact shipping LibraryTombstones.MIGRATION_EPOCH_MS, not a fabricated viewing/now clock.
            if (!hasPositiveIntent(intents[key])) intents.getOrPut(key) { JSONObject().put("key", key) }.put("removedAtMs", 1.0)
        }
        requireMaterial(declaredRemoved.all { (intents[it]?.opt("removedAtMs") as? Number)?.toDouble()?.let { at -> at > 0 } == true },
            "Owner removed row requires explicit library removal intent; viewing clocks are not removal clocks")
        return JSONObject().put("items", JSONArray(items.values)).put("intents", JSONArray(intents.values))
    }

    private fun importOverlays() {
        val byProfile = objectField(vortx, "byProfile") ?: JSONObject()
        val webRemoved = objectField(document, "webProgress")?.let { objectField(it, "removed") }?.let { objectField(it, "byProfile") } ?: JSONObject()
        for (rawID in (byProfile.keys().asSequence().toList() + webRemoved.keys().asSequence().toList()).distinct()) {
            val bucket = objectField(byProfile, rawID) ?: JSONObject()
            // The fixed historical owner-history bucket is a carrier, not a second profile identity.
            if (rawID == UserProfile.OWNER_ID && rawID !in profiles) {
                requireMaterial(bucket.keys().asSequence().none { it in setOf("library", "watched", "removed") }, "Ambiguous historical owner overlay")
                continue
            }
            val id = profiles.keys.singleOrNull { it.equals(rawID, true) } ?: fail("Watch carrier references an unknown profile")
            val rows = objects(arrayField(bucket, "library"), "overlay library")
            val railTitles = rows.map { string(it, "id") }.toSet()
            for (row in rows) {
                val metaId = string(row, "id"); known(id, metaId, contentType(row))
                importWatch(id, metaId, row, ownerRow = false)
                importMarks(id, metaId, row)
            }
            objectField(bucket, "watched")?.let { map -> for (metaId in map.keys()) {
                requireMaterial(metaId.isNotBlank(), "Empty durable watch identity")
                // Account-document ingress uses this ENTIRE carrier only beyond the library rail.
                // A stale overlapping durable row must not override the current full snapshot.
                if (metaId !in railTitles) importMarks(id, metaId, map.optJSONObject(metaId) ?: fail("Malformed durable watched row"))
            } }
            val removals = objects(arrayField(bucket, "removed"), "overlay removals") + objects(arrayField(webRemoved, rawID), "web overlay removals")
            for (removal in removals) {
                val keys = strings(arrayField(removal, "keys"), "removal identity keys")
                requireMaterial(keys.isNotEmpty(), "Empty watch removal identity")
                val at = clockField(removal, "removedAt") ?: fail("Unclocked watch removal")
                val matches = knownTitles.getValue(id).filter { (metaId, type) -> keys.any { key -> removalMatches(key, metaId, type) } }
                requireMaterial(matches.size == 1 && keys.all { key -> matches.any { (metaId, type) -> removalMatches(key, metaId, type) } }, "Watch removal requires verified title reconciliation")
                matches.forEach { (metaId, type) -> watchRows.getValue(id).add(JSONObject().put("metaId", metaId).put("type", type).put("removedAtMs", at)) }
            }
        }
    }

    private fun importWatch(profile: String, metaId: String, raw: JSONObject, ownerRow: Boolean, historyOnly: Boolean = false) {
        val position = secondsToMillis(raw, "t"); val duration = secondsToMillis(raw, "d")
        val played = lastWatched(raw)
        val video = optionalString(raw, "v")?.takeIf(String::isNotBlank)
        val bits = optionalString(raw, "watched")
        requireMaterial(bits.isNullOrEmpty(), "Opaque owner watched bitfield requires episode reconciliation")
        val watched = optionalBoolean(raw, "currentVideoWatched")
        val whole = optionalBoolean(raw, "wholeTitleWatched")
        val timesWatched = optionalUnsigned(raw, "timesWatched", 0xffff_ffffL)
        val type = contentType(raw)
        requireMaterial(type != "series" || whole != true, "Whole-series watch intent requires episode reconciliation")
        val hasMarks = strings(arrayField(raw, "w"), "watched IDs").isNotEmpty() || (objectField(raw, "ma")?.length() ?: 0) > 0 || (objectField(raw, "ua")?.length() ?: 0) > 0
        if (!ownerRow && position == 0L && !hasMarks && watched != true && whole != true && (timesWatched ?: 0) == 0L) {
            fail("Saved-only overlay membership requires explicit reconciliation")
        }
        // Membership writers manufacture lastWatched for zero-offset saves. It is not viewing proof.
        val hasProgress = position > 0 || historyOnly && raw.has("t") && played != null && played > 0
        if (!hasProgress && watched != true && whole != true && (timesWatched ?: 0) == 0L) return
        requireMaterial(!hasProgress || played != null && played > 0, "Progress lacks a genuine viewing clock")
        requireMaterial(type != "series" || video != null, "Series progress requires an exact video identity")
        val row = JSONObject().put("metaId", metaId).put("type", type).put("name", optionalString(raw, "name").orEmpty())
        video?.let { row.put("videoId", it) }
        optionalString(raw, "poster")?.takeIf(String::isNotBlank)?.let { row.put("poster", it) }
        if (hasProgress) {
            row.put("positionMs", position).put("lastPlayedAtMs", played)
            if (raw.has("d") && !raw.isNull("d")) row.put("durationMs", duration)
        }
        if (watched == true || whole == true) row.put("watched", true)
        timesWatched?.let { row.put("timesWatched", it) }
        watchRows.getValue(profile).add(row)
    }

    /** Kernel import takes one resolved row per unit. Preserve independent clocks, not arrival order. */
    private fun resolveWatchRows(source: List<JSONObject>): List<JSONObject> {
        val units = sortedMapOf<String, JSONObject>()
        for (incoming in source) {
            val metaId = incoming.getString("metaId")
            val key = optionalString(incoming, "videoId") ?: metaId
            val previous = units[key]
            if (previous == null) { units[key] = JSONObject(incoming.toString()); continue }
            requireMaterial(previous.getString("metaId") == metaId, "Watch unit belongs to conflicting title identities")
            val oldType = optionalString(previous, "type"); val newType = optionalString(incoming, "type")
            requireMaterial(oldType == null || newType == null || oldType == newType, "Watch unit belongs to conflicting content types")
            val incomingClock = clockField(incoming, "lastPlayedAtMs") ?: 0.0
            val priorClock = clockField(previous, "lastPlayedAtMs") ?: 0.0
            requireMaterial(incomingClock <= 0 || incomingClock != priorClock ||
                !incoming.has("positionMs") || !previous.has("positionMs") || incoming.getLong("positionMs") == previous.getLong("positionMs"),
                "Conflicting equal-clock progress requires reconciliation")
            if (incomingClock > priorClock) {
                for (field in listOf("lastPlayedAtMs", "positionMs")) {
                    if (incoming.has(field)) previous.put(field, incoming.get(field)) else previous.remove(field)
                }
                if (incoming.has("durationMs")) previous.put("durationMs", incoming.get("durationMs"))
            }
            for (field in listOf("videoId", "name", "type", "poster")) {
                val text = optionalString(incoming, field)
                if (!text.isNullOrEmpty() && (incomingClock > priorClock || optionalString(previous, field).isNullOrEmpty())) previous.put(field, text)
            }
            for (field in listOf("markedAtMs", "resetAtMs", "removedAtMs", "timesWatched")) {
                (incoming.opt(field) as? Number)?.let { number ->
                    if (!previous.has(field) || number.toDouble() > (previous.get(field) as Number).toDouble()) previous.put(field, number)
                }
            }
            if (incoming.opt("watched") == true) previous.put("watched", true)
        }
        units.values.forEach { row ->
            // Any explicit mark/unmark clock is more authoritative than a legacy clock-less set.
            if (row.has("markedAtMs") || row.has("resetAtMs")) row.remove("watched")
        }
        return units.values.toList()
    }

    private fun importMarks(profile: String, metaId: String, raw: JSONObject) {
        val watched = strings(arrayField(raw, "w"), "watched IDs").toSet()
        fun positiveClocks(key: String): Map<String, Double> {
            val values = objectField(raw, key) ?: return emptyMap()
            return values.keys().asSequence().mapNotNull { video -> clockField(values, video)?.takeIf { it > 0 }?.let { video to it } }.toMap()
        }
        // Document ingress discards nonpositive clocks before the reducer; zero is absence, not an
        // explicit unwatch capable of suppressing legacy bare w membership.
        val marked = positiveClocks("ma"); val reset = positiveClocks("ua")
        val videos = watched + marked.keys + reset.keys
        for (video in videos.sorted()) {
            requireMaterial(video.isNotBlank(), "Empty watched video identity")
            val row = JSONObject().put("metaId", metaId).put("videoId", video)
            knownTitles.getValue(profile)[metaId]?.let { row.put("type", it) }
            marked[video]?.let { row.put("markedAtMs", it) }
            reset[video]?.let { row.put("resetAtMs", it) }
            if (video !in marked && video !in reset && video in watched) row.put("watched", true)
            watchRows.getValue(profile).add(row)
        }
    }

    private fun importOwnerIntents() {
        val raw = objectField(vortx, "ownerWatched") ?: return
        data class Intent(val title: String, val video: String, val watched: Boolean, val at: Double, val actor: String)
        val winners = linkedMapOf<Pair<String, String>, Intent>()
        for (key in raw.keys()) {
            val row = raw.optJSONObject(key) ?: fail("Malformed owner watched intent")
            val intent = Intent(string(row, "t"), string(row, "v"), optionalBoolean(row, "w") ?: fail("Missing watched intent"),
                clockField(row, "u") ?: fail("Unclocked owner watched intent"), string(row, "a"))
            val identity = intent.title to intent.video; val prior = winners[identity]
            requireMaterial(prior == null || intent.at != prior.at || intent.actor != prior.actor || intent.watched == prior.watched,
                "Contradictory equal-clock owner intent requires reconciliation")
            if (prior == null || intent.at > prior.at || intent.at == prior.at && intent.actor > prior.actor) winners[identity] = intent
        }
        for (intent in winners.values) {
            val type = knownTitles.getValue(owner.id)[intent.title]
            requireMaterial(intent.title != intent.video || type == "movie", "Whole-title owner intent requires verified movie or episode reconciliation")
            val row = JSONObject().put("metaId", intent.title).put("videoId", intent.video)
                .put(if (intent.watched) "markedAtMs" else "resetAtMs", intent.at)
            type?.let { row.put("type", it) }; watchRows.getValue(owner.id).add(row)
        }
    }

    private fun known(profile: String, metaId: String, type: String) {
        val previous = knownTitles.getValue(profile).putIfAbsent(metaId, type)
        requireMaterial(previous == null || previous == type, "Same media ID has conflicting movie/series ownership")
    }

    private fun removalMatches(key: String, metaId: String, type: String): Boolean {
        if (!key.startsWith("$type\u001f")) return false
        val provider = key.substringAfter('\u001f')
        if (provider == metaId.lowercase()) return true
        if (metaId.matches(Regex("tt[0-9]+"))) return provider == "imdb:${metaId.lowercase()}"
        if (metaId.matches(Regex("tmdb:[0-9]+"))) return provider == "tmdb:$type:${metaId.substringAfter(':')}"
        return false
    }
}

private fun fail(message: String): Nothing = throw IllegalArgumentException("Native migration reconciliation required: $message")
private fun requireMaterial(condition: Boolean, message: String) { if (!condition) fail(message) }
private fun objectField(root: JSONObject, key: String): JSONObject? {
    if (!root.has(key) || root.isNull(key)) return null
    return root.optJSONObject(key) ?: fail("Malformed object carrier $key")
}
private fun arrayField(root: JSONObject, key: String): JSONArray? {
    if (!root.has(key) || root.isNull(key)) return null
    return root.optJSONArray(key) ?: fail("Malformed array carrier $key")
}
private fun objects(rows: JSONArray?, label: String): List<JSONObject> =
    (0 until (rows?.length() ?: 0)).map { rows!!.optJSONObject(it) ?: fail("Malformed $label row") }
private fun strings(rows: JSONArray?, label: String): List<String> =
    (0 until (rows?.length() ?: 0)).map { (rows!!.opt(it) as? String)?.takeIf(String::isNotBlank) ?: fail("Malformed $label identity") }
private fun string(root: JSONObject, key: String): String = optionalString(root, key)?.takeIf(String::isNotBlank) ?: fail("Missing $key")
private fun optionalString(root: JSONObject, key: String): String? {
    if (!root.has(key) || root.isNull(key)) return null
    return root.opt(key) as? String ?: fail("Malformed string $key")
}
private fun optionalBoolean(root: JSONObject, key: String): Boolean? {
    if (!root.has(key) || root.isNull(key)) return null
    return root.opt(key) as? Boolean ?: fail("Malformed boolean $key")
}
private fun contentType(root: JSONObject): String = string(root, "type").also {
    requireMaterial(it in setOf("movie", "series"), "Unsupported catalog content type")
}
private fun validClock(value: Double, label: String): Double = value.also {
    requireMaterial(it.isFinite() && it >= 0 && it <= 9_007_199_254_740_990.0, "Invalid clock $label")
}
private fun clockField(root: JSONObject, key: String): Double? {
    if (!root.has(key) || root.isNull(key)) return null
    return validClock((root.opt(key) as? Number)?.toDouble() ?: fail("Malformed clock $key"), key)
}
private fun mergeClock(source: JSONObject, target: JSONObject, oldKey: String, newKey: String) {
    clockField(source, oldKey)?.let { target.put(newKey, maxOf(it, (target.opt(newKey) as? Number)?.toDouble() ?: 0.0)) }
}
private fun hasPositiveIntent(intent: JSONObject?): Boolean = intent != null &&
    listOf("addedAtMs", "removedAtMs").any { (intent.opt(it) as? Number)?.toDouble()?.let { at -> at > 0 } == true }
private fun lastWatched(root: JSONObject): Double? = optionalString(root, "lastWatched")?.takeIf(String::isNotBlank)?.let { raw ->
    val instant = runCatching { Instant.parse(raw) }.getOrNull() ?: fail("Invalid lastWatched clock")
    validClock(instant.epochSecond * 1000.0 + instant.nano / 1_000_000.0, "lastWatched")
}
private fun secondsToMillis(root: JSONObject, key: String): Long {
    clockField(root, key) ?: return 0
    // Decimal JSON seconds such as 2.001 must not fail because binary multiplication yields
    // 2001.0000000000002. Conversely, do not truncate genuine sub-millisecond source progress.
    val ms = runCatching { BigDecimal(root.get(key).toString()).multiply(BigDecimal(1000)).longValueExact() }
        .getOrElse { fail("Sub-millisecond or excessive progress cannot be represented") }
    requireMaterial(ms in 0..9_007_199_254_740_990L, "Excessive progress cannot be represented")
    return ms
}
private fun optionalUnsigned(root: JSONObject, key: String, maximum: Long): Long? {
    val value = clockField(root, key) ?: return null
    requireMaterial(value <= maximum && value == value.toLong().toDouble(), "Invalid count $key")
    return value.toLong()
}
private fun requireNoCredentials(value: Any?) {
    when (value) {
        is JSONObject -> for (key in value.keys()) {
            val normalized = key.lowercase().filter(Char::isLetterOrDigit)
            requireMaterial(normalized !in setOf("token", "accesstoken", "refreshtoken", "authkey", "password", "authorization", "bearer", "datakey", "apikey", "clientsecret"), "Credential-bearing material is not native state")
            requireNoCredentials(value.opt(key))
        }
        is JSONArray -> for (index in 0 until value.length()) requireNoCredentials(value.opt(index))
    }
}
