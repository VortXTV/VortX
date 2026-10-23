package com.vortx.android.engine

import java.math.BigDecimal
import java.net.URI
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.util.UUID
import org.json.JSONObject

/** This authority is supplied by the real Session/account admission, never by archive data. */
internal interface NativeOwnerHistoryAuthority { fun <T> withActive(block: () -> T): T }

/** Complete immutable source journal and unresolved ORIGINAL-binding records. No network or clocks. */
internal class NativeOwnerHistorySources private constructor(val scope: VortxAccountScope,
    private val journal: OHJson.Obj, private val pending: OHJson.Obj) {
    private val entries = journal.obj("sources")
    fun local(): ByteArray = OHJson.Obj().set("kind", OHJson.quote(LOCAL))
        .set("journalBase64", OHJson.quote(OHJson.b64(journal.encoded()))).set("pending", pending.encoded()).encoded()
    fun joining(peer: NativeOwnerHistorySources): NativeOwnerHistorySources {
        require(scope == peer.scope); val joined = OHJson.Obj(entries.encoded()); val held = OHJson.Obj(pending.encoded())
        peer.entries.keys.forEach { key ->
            val old = joined[key]; val next = peer.entries.raw(key)
            if (old != null) require(OHJson.equal(old, next)) { "Conflicting immutable source" } else joined.set(key, next)
        }
        peer.pending.keys.forEach { key ->
            val old = held[key]; val next = peer.pending.raw(key)
            if (old != null) require(OHJson.equal(old, next)) { "Conflicting original pending binding" } else held.set(key, next)
        }
        require(joined.keys.size <= 128)
        return fromLocal(scope, OHJson.Obj().set("kind", OHJson.quote(LOCAL))
            .set("journalBase64", OHJson.quote(OHJson.b64(OHJson.Obj(journal.encoded()).set("sources", joined.encoded()).encoded())))
            .set("pending", held.encoded()).encoded())
    }
    fun validate(snapshot: ByteArray, bindings: NativeOwnerHistoryBindings, authority: NativeOwnerHistoryAuthority) {
        authority.withActive { }; val native = OHJson.Obj(snapshot).obj("nativeSync")
        require(native.text("scope") == scope.accountID && native.text("ownerProfileId") == scope.ownerProfileID)
        val schema = OHJson.integer(native.raw("schemaVersion")); val history = native["ownerHistory"]
        if (history == null) { require(schema in 1..5 && entries.keys.isEmpty()); authority.withActive { }; return }
        require(schema == 6L)
        val h = OHJson.Obj(history)
        require(h.keys == setOf("schemaVersion", "capability", "sources", "attestations") &&
            OHJson.integer(h.raw("schemaVersion")) == 1L && h.text("capability") == "vortx.owner-history-fallback/1")
        val outer = h.obj("sources"); require(outer.keys == setOf("sources")); val sources = outer.obj("sources"); val proofs = h.obj("attestations")
        require(sources.keys.isNotEmpty() && sources.keys == proofs.keys && sources.keys == entries.keys)
        for (id in entries.keys.sorted()) {
            authority.withActive { }; val entry = entries.obj(id)
            val replay = replay(OHJson.un64(entry.text("archiveBase64")), scope, entry.text("profileId"), entry.text("verifiedStreamingUid"), authority)
            fun nativeCanonical(bytes: ByteArray): OHJson.Obj {
                val result = OHJson.Obj(requireNotNull(bindings.canonicalize(bytes)))
                require(result.keys == setOf("kind", "evidence", "receipt") && result.text("kind") == "owner_history_evidence")
                return result
            }
            val interpreted = nativeCanonical(replay); val retained = nativeCanonical(sources.raw(id)); val proof = proofs.obj(id)
            require(proof.keys == setOf("binding", "receipt"))
            require(interpreted.raw("evidence").contentEquals(retained.raw("evidence")) &&
                interpreted.raw("receipt").contentEquals(retained.raw("receipt"))) { "Source interpretation differs" }
            require(interpreted.obj("receipt").text("sourceId") == id &&
                OHJson.equal(proof.raw("receipt"), interpreted.raw("receipt")) &&
                OHJson.equal(entry.raw("receipt"), interpreted.raw("receipt")) &&
                OHJson.equal(proof.raw("binding"), entry.raw("capturedBinding"))) { "Source attestation differs" }
        }
        authority.withActive { }
    }
    companion object {
        const val LOCAL = "vortx.owner-history.local/1"
        const val JOURNAL = "vortx.owner-history.journal/1"
        fun empty(scope: VortxAccountScope): NativeOwnerHistorySources = NativeOwnerHistorySources(scope,
            OHJson.Obj().set("kind", OHJson.quote(JOURNAL)).set("schemaVersion", OHJson.literal("1"))
                .set("scope", OHJson.quote(scope.accountID)).set("ownerProfileId", OHJson.quote(scope.ownerProfileID))
                .set("sources", OHJson.literal("{}")), OHJson.Obj())
        fun fromLocal(scope: VortxAccountScope, bytes: ByteArray?): NativeOwnerHistorySources {
            if (bytes == null) return empty(scope)
            val local = OHJson.Obj(bytes)
            require(local.keys == setOf("kind", "journalBase64", "pending") && local.text("kind") == LOCAL)
            val journal = OHJson.Obj(OHJson.un64(local.text("journalBase64"))); val pending = local.obj("pending")
            require(journal.keys == setOf("kind", "schemaVersion", "scope", "ownerProfileId", "sources") &&
                journal.text("kind") == JOURNAL && OHJson.integer(journal.raw("schemaVersion")) == 1L &&
                journal.text("scope") == scope.accountID && journal.text("ownerProfileId") == scope.ownerProfileID)
            val entries = journal.obj("sources"); require(entries.keys.size <= 128)
            var bytesTotal = 0L
            entries.keys.forEach { id ->
                require(digest(id)); val entry = entries.obj(id)
                require(entry.keys == setOf("archiveBase64", "receipt", "capturedBinding", "profileId", "verifiedStreamingUid"))
                uuid(entry.text("profileId")); OHJson.uid(entry.text("verifiedStreamingUid")); entry.obj("capturedBinding")
                val archive = OHJson.un64(entry.text("archiveBase64")); bytesTotal += archive.size; require(bytesTotal <= OHJson.MAX)
                val receipt = entry.obj("receipt")
                require(receipt.keys == setOf("sourceId", "sourceDocumentSha256", "sourceArchiveSha256", "typedCarrierFingerprint") &&
                    receipt.text("sourceId") == id && receipt.text("sourceArchiveSha256") == OHJson.sha(archive) &&
                    digest(receipt.text("sourceDocumentSha256")) && digest(receipt.text("typedCarrierFingerprint")))
            }
            pending.keys.forEach { id ->
                require(digest(id)); val record = pending.obj(id)
                require(record.keys == setOf("archiveBase64", "capturedBinding")); record.obj("capturedBinding")
                val archive = OHJson.un64(record.text("archiveBase64")); require(OHJson.sha(archive) == id)
                val candidate = OHJson.Obj(archive)
                require(candidate.keys == setOf("schemaVersion", "kind", "sourceDocumentBase64", "metadataEvidenceBase64", "metadataPendingBase64", "heldProjectionKinds") &&
                    candidate.text("kind") == "vortx.owner-history.pending/1" && OHJson.integer(candidate.raw("schemaVersion")) == 1L)
                val source = OHJson.un64(candidate.text("sourceDocumentBase64")); val sourceFrame = OHJson.Obj(source)
                frame(source, scope, sourceFrame.text("profileId"), sourceFrame.text("verifiedStreamingUid"))
                for (key in listOf("metadataEvidenceBase64", "metadataPendingBase64")) {
                    val rows = OHJson.array(candidate.raw(key)); require(rows.size <= 10000)
                    rows.forEach { OHJson.Obj(OHJson.un64(OHJson.text(it))) }
                }
                OHJson.array(candidate.raw("heldProjectionKinds")).forEach { OHJson.text(it) }
            }
            return NativeOwnerHistorySources(scope, journal, pending)
        }
        fun carrier(local: ByteArray, scope: VortxAccountScope, readOwnerUID: String): ByteArray {
            val sources = fromLocal(scope, local); OHJson.uid(readOwnerUID)
            return OHJson.Obj().set("schemaVersion", OHJson.literal("1"))
                .set("capability", OHJson.quote("vortx.owner-history-complete-archive/1"))
                .set("journal", sources.journal.encoded()).set("pending", sources.pending.encoded())
                .set("readOwnerUID", OHJson.quote(readOwnerUID)).encoded()
        }
        fun fromCarrier(scope: VortxAccountScope, bytes: ByteArray): NativeOwnerHistorySources {
            val c = OHJson.Obj(bytes)
            require(c.keys == setOf("schemaVersion", "capability", "journal", "pending", "readOwnerUID") &&
                OHJson.integer(c.raw("schemaVersion")) == 1L && c.text("capability") == "vortx.owner-history-complete-archive/1")
            OHJson.uid(c.text("readOwnerUID"))
            return fromLocal(scope, OHJson.Obj().set("kind", OHJson.quote(LOCAL))
                .set("journalBase64", OHJson.quote(OHJson.b64(c.raw("journal")))).set("pending", c.raw("pending")).encoded())
        }
        fun readOwnerUID(scope: VortxAccountScope, carrier: ByteArray): String { fromCarrier(scope, carrier); return OHJson.Obj(carrier).text("readOwnerUID") }
        private fun digest(s: String) = Regex("[0-9a-f]{64}").matches(s)
        private fun uuid(s: String) { require(UUID.fromString(s).toString().uppercase() == s) }
        private fun optional(o: OHJson.Obj, k: String): ByteArray? = o[k]?.takeUnless { it.contentEquals(OHJson.literal("null")) }
        private fun string(o: OHJson.Obj, k: String): String? = optional(o, k)?.let(OHJson::text)
        private fun number(o: OHJson.Obj, k: String, maximum: Long = 9007199254740990L): Long? = optional(o, k)?.let {
            val n = BigDecimal(OHJson.utf8(it)); require(n >= BigDecimal.ZERO && n <= BigDecimal.valueOf(maximum)); n.longValueExact()
        }
        private fun bool(o: OHJson.Obj, k: String): Boolean? = optional(o, k)?.let { require(OHJson.utf8(it) in setOf("true", "false")); OHJson.utf8(it) == "true" }
        /** Privacy inspection does not supply rewritten persistence/source bytes. */
        private fun privacy(bytes: ByteArray, depth: Int = 0) {
            require(depth <= 64 && bytes.size <= 16 * 1024 * 1024)
            // Invoke the ACTUAL recursive host privacy inspector, including ambiguous key,
            // malformed structured/base64 and nested carrier policy. Its output is never stored.
            if (depth == 0) NativeHostDocument.requireCredentialFree(JSONObject(OHJson.utf8(bytes)),
                maximumNodes = maxOf(100_000, bytes.size * 4))
            val raw = OHJson.canonical(bytes)
            when (raw.first().toInt().toChar()) {
                '{' -> {
                    val o = OHJson.Obj(raw)
                    o.keys.forEach { key ->
                        privacy(OHJson.quote(key), depth + 1); privacy(o.raw(key), depth + 1)
                    }
                }
                '[' -> OHJson.array(raw).forEach { privacy(it, depth + 1) }
                '"' -> {
                    val s = OHJson.text(raw)
                    if (s.contains("://")) {
                        val u = URI(s); require(u.scheme == "https" && !u.host.isNullOrEmpty() && u.host.contains('.') &&
                            u.userInfo == null && u.query == null && u.fragment == null && u.port in setOf(-1, 443) &&
                            !u.host.endsWith(".local") && !u.host.endsWith(".internal") && !u.host.all { it.isDigit() || it == '.' })
                    }
                    listOf(s.toByteArray(), runCatching { OHJson.un64(s) }.getOrNull()).filterNotNull().forEach { nested ->
                        val value = runCatching { OHJson.canonical(nested) }.getOrNull()
                        if (value != null && value.first().toInt().toChar() in setOf('{', '[', '"')) privacy(value, depth + 1)
                        // Plist is not accepted as an opaque escape on this Android boundary.
                        else if (nested.take(6).toByteArray().contentEquals("bplist".toByteArray()) || runCatching { OHJson.utf8(nested).trimStart().startsWith("<?xml") }.getOrDefault(false))
                            error("Unsupported encoded privacy carrier")
                    }
                }
            }
        }
        private fun frame(bytes: ByteArray, scope: VortxAccountScope, profile: String, uid: String): Pair<List<ByteArray>, List<ByteArray>> {
            uuid(profile); OHJson.uid(uid); val f = OHJson.Obj(bytes)
            require(f.keys == setOf("schemaVersion", "kind", "scope", "ownerProfileId", "profileId", "verifiedStreamingUid", "libraryResponseBase64", "addonsResponseBase64") &&
                OHJson.integer(f.raw("schemaVersion")) == 1L && f.text("kind") == "vortx.owner-history.source/1" &&
                f.text("scope") == scope.accountID && f.text("ownerProfileId") == scope.ownerProfileID && f.text("profileId") == profile && f.text("verifiedStreamingUid") == uid)
            val lb = OHJson.un64(f.text("libraryResponseBase64")); val ab = OHJson.un64(f.text("addonsResponseBase64")); privacy(lb); privacy(ab)
            val l = OHJson.Obj(lb); val a = OHJson.Obj(ab); require(optional(l, "error") == null && optional(a, "error") == null)
            val rows = OHJson.array(l.raw("result")); val addons = OHJson.array(a.obj("result").raw("addons")); require(rows.size <= 100000 && addons.size <= 10000)
            rows.forEach { OHJson.Obj(it) }; addons.forEach { OHJson.Obj(it) }; return rows to addons
        }
        /** Full replay of actual Swift archive format. No trusting archived decoded IDs/hashes alone. */
        fun replay(archive: ByteArray, scope: VortxAccountScope, profile: String, uid: String,
                   authority: NativeOwnerHistoryAuthority): ByteArray {
            authority.withActive { }; val a = OHJson.Obj(archive)
            require(a.keys == setOf("schemaVersion", "kind", "sourceDocumentBase64", "metadataEvidenceBase64") &&
                OHJson.integer(a.raw("schemaVersion")) == 1L && a.text("kind") == "vortx.owner-history.archive/1")
            val source = OHJson.un64(a.text("sourceDocumentBase64")); val (rows, addons) = frame(source, scope, profile, uid)
            val records = OHJson.array(a.raw("metadataEvidenceBase64")).map { OHJson.un64(OHJson.text(it)) }
            require(records.size <= 10000 && records.zipWithNext().all { (x, y) -> compareBytes(x, y) < 0 })
            val byIndex = linkedMapOf<Int, List<String>>()
            records.forEach { bytes ->
                val r = OHJson.Obj(bytes)
                require(r.keys == setOf("schemaVersion", "accountId", "profileId", "ownerProfileId", "sourceDocumentBase64", "sourceDocumentSha256", "row", "addon", "metadataResponseBase64", "metadataResponseSha256", "verifiedStreamingUid") &&
                    OHJson.integer(r.raw("schemaVersion")) == 1L && r.text("accountId") == scope.accountID && r.text("ownerProfileId") == scope.ownerProfileID &&
                    r.text("profileId") == profile && r.text("verifiedStreamingUid") == uid && OHJson.un64(r.text("sourceDocumentBase64")).contentEquals(source) && r.text("sourceDocumentSha256") == OHJson.sha(source))
                val loc = r.obj("row"); require(loc.keys == setOf("kind", "index") && loc.text("kind") == "owner_account_library")
                val index = OHJson.integer(loc.raw("index")).also { require(it < rows.size) }.toInt(); require(index !in byIndex)
                val row = OHJson.Obj(rows[index]); require(row.text("type") == "series"); val bitmap = row.obj("state").text("watched"); require(bitmap.isNotEmpty())
                val descriptor = r.obj("addon"); require(descriptor.keys == setOf("transportUrl", "manifestBase64"))
                val manifest = OHJson.un64(descriptor.text("manifestBase64")); val url = descriptor.text("transportUrl")
                require(addons.any { raw -> val d = OHJson.Obj(raw); d.text("transportUrl") == url && OHJson.equal(d.raw("manifest"), manifest) })
                val m = OHJson.Obj(manifest); m.text("id"); m.text("name")
                val metadata = OHJson.un64(r.text("metadataResponseBase64")); require(OHJson.sha(metadata) == r.text("metadataResponseSha256")); privacy(metadata)
                val meta = OHJson.Obj(metadata).obj("meta"); require(meta.text("id") == row.text("_id") && meta.text("type") == "series")
                val videos = OHJson.array(meta.raw("videos")); require(videos.size in 1..10000)
                val inventory = videos.map { raw ->
                    val v = OHJson.Obj(raw)
                    LegacyWatchedBitfieldEpisode(v.text("id"), OHJson.integer(v.raw("season")).also { require(it <= Int.MAX_VALUE) }.toInt(),
                        OHJson.integer(v.raw("episode")).also { require(it <= Int.MAX_VALUE) }.toInt(), string(v, "released")?.let(::released))
                }.sortedWith(compareBy<LegacyWatchedBitfieldEpisode> { it.season }.thenBy { it.episode }.thenBy { it.releasedMs })
                byIndex[index] = LegacyWatchedBitfieldDecoder.decode(bitmap, inventory)
                authority.withActive { }
            }
            val required = rows.indices.filter { i -> val r = OHJson.Obj(rows[i]); val state = optional(r, "state")?.let(OHJson::Obj)
                string(r, "type") == "series" && !string(r, "_id").isNullOrEmpty() && state != null && !string(state, "watched").isNullOrEmpty() }.toSet()
            require(required == byIndex.keys)
            val library = mutableListOf<ByteArray>(); val fragments = mutableListOf<OHJson.Obj>(); val identities = hashSetOf<String>(); val titleTypes = hashMapOf<String, String>()
            rows.forEachIndexed { i, bytes ->
                authority.withActive { }; val row = OHJson.Obj(bytes); val id = row.text("_id"); val type = row.text("type")
                require(id.isNotBlank() && id.none { Character.isISOControl(it) } && type in setOf("movie", "series"))
                require(identities.add(java.text.Normalizer.normalize("$type:$id", java.text.Normalizer.Form.NFC)))
                require(titleTypes.put(id, type).let { it == null || it == type })
                val name = string(row, "name"); val poster = string(row, "poster")
                fun context() = OHJson.Obj().set("metaId", OHJson.quote(id)).set("type", OHJson.quote(type)).also {
                    if (!name.isNullOrEmpty()) it.set("name", OHJson.quote(name)); if (!poster.isNullOrEmpty()) it.set("poster", OHJson.quote(poster)) }
                if (bool(row, "removed") != true && bool(row, "temp") != true) library += OHJson.Obj().set("kind", OHJson.quote("standard"))
                    .set("id", OHJson.quote(id)).set("type", OHJson.quote(type)).set("name", OHJson.quote(name ?: ""))
                    .also { if (!poster.isNullOrEmpty()) it.set("poster", OHJson.quote(poster)) }.encoded()
                val state = optional(row, "state")?.let(OHJson::Obj) ?: OHJson.Obj()
                val position = number(state, "timeOffset"); val duration = number(state, "duration"); val count = number(state, "timesWatched", 0xffffffffL)
                val flag = number(state, "flaggedWatched", 1L) == 1L; val video = string(state, "video_id")?.takeIf { it.isNotEmpty() }
                val played = string(state, "lastWatched")?.takeIf { it.isNotEmpty() }?.let { text ->
                    val match = requireNotNull(Regex("^(\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})(?:\\.(\\d+))?(Z|[+-]\\d{2}:\\d{2})$").matchEntire(text))
                    val whole = Instant.parse(match.groupValues[1] + match.groupValues[3]).epochSecond.toDouble() * 1000
                    val fraction = match.groupValues[2].takeIf { it.isNotEmpty() }?.let { "0.$it".toDouble() } ?: 0.0
                    val millis = whole + fraction * 1000 // Same derived typed-clock operation as Swift; source bytes remain untouched.
                    require(millis.isFinite() && millis >= 0 && millis <= 9007199254740990.0)
                    BigDecimal.valueOf(millis).takeIf { it > BigDecimal.ZERO }
                }
                string(state, "watched")?.takeIf { it.isNotEmpty() }?.let { require(type == "series" && i in byIndex) }
                byIndex[i].orEmpty().forEach { fragments += context().set("videoId", OHJson.quote(it)).set("watched", OHJson.literal("true")) }
                val progress = (position ?: 0) > 0
                if (progress || flag || count != null) {
                    require(type != "series" || (!progress && !flag) || (video != null && (!flag || video != id)))
                    if (progress) require(played != null && played > BigDecimal.ZERO && played <= BigDecimal("9007199254740990"))
                    fragments += context().also { out ->
                        if (video != null) out.set("videoId", OHJson.quote(video))
                        if (progress) out.set("positionMs", OHJson.literal(position.toString())).set("lastPlayedAtMs", OHJson.literal(played!!.stripTrailingZeros().toPlainString()))
                        if (duration != null) out.set("durationMs", OHJson.literal(duration.toString()))
                        if (count != null) out.set("timesWatched", OHJson.literal(count.toString()))
                        if (flag) out.set("watched", OHJson.literal("true"))
                    }
                }
            }
            // Fold exactly one unit per opaque video ID, rejecting contradictory title/position.
            val units = linkedMapOf<String, OHJson.Obj>()
            fun played(o: OHJson.Obj) = o["lastPlayedAtMs"]?.let { BigDecimal(OHJson.utf8(it)) } ?: BigDecimal.ZERO
            fragments.sortedWith { x, y -> played(x).compareTo(played(y)).takeIf { it != 0 } ?: compareBytes(x.encoded(), y.encoded()) }.forEach { row ->
                val key = string(row, "videoId") ?: row.text("metaId"); val old = units[key]
                if (old == null) units[key] = row else {
                    require(old.text("metaId") == row.text("metaId") && old.text("type") == row.text("type"))
                    val before = played(old); val after = played(row)
                    if (before == after && old["positionMs"] != null && row["positionMs"] != null) require(OHJson.equal(old.raw("positionMs"), row.raw("positionMs")))
                    if (old["durationMs"] == null) row["durationMs"]?.let { old.set("durationMs", it) }
                    if (after > before || old["positionMs"] == null) for (key2 in listOf("lastPlayedAtMs", "positionMs", "durationMs")) row[key2]?.let { old.set(key2, it) }
                    for (key2 in listOf("name", "type", "poster", "videoId")) string(row, key2)?.takeIf { it.isNotEmpty() }?.let { s ->
                        val prior = string(old, key2); if (prior.isNullOrEmpty() || after > before || (after == before && s < prior)) old.set(key2, OHJson.quote(s)) }
                    number(row, "timesWatched", 0xffffffffL)?.let { old.set("timesWatched", OHJson.literal(maxOf(it, number(old, "timesWatched", 0xffffffffL) ?: 0).toString())) }
                    if (bool(row, "watched") == true) old.set("watched", OHJson.literal("true"))
                }
            }
            authority.withActive { }
            return OHJson.Obj().set("schemaVersion", OHJson.literal("1")).set("scope", OHJson.quote(scope.accountID))
                .set("ownerProfileId", OHJson.quote(scope.ownerProfileID)).set("profileId", OHJson.quote(profile)).set("verifiedStreamingUid", OHJson.quote(uid))
                .set("sourceDocumentSha256", OHJson.quote(OHJson.sha(source))).set("sourceArchiveSha256", OHJson.quote(OHJson.sha(archive)))
                .set("library", OHJson.Obj().set("items", OHJson.array(library)).set("intents", OHJson.literal("[]")).encoded())
                .set("watches", OHJson.array(units.keys.sorted().map { units.getValue(it).encoded() })).set("identityLinks", OHJson.literal("[]")).encoded()
        }
        private fun compareBytes(x: ByteArray, y: ByteArray): Int {
            for (i in 0 until minOf(x.size, y.size)) { val c = (x[i].toInt() and 255).compareTo(y[i].toInt() and 255); if (c != 0) return c }
            return x.size.compareTo(y.size)
        }
        /** Same strict millisecond release grammar as the existing migration evidence parser. */
        private fun released(text: String): Long {
            val m = requireNotNull(Regex("^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})(?:\\.(\\d{1,3}))?(Z|[+-]\\d{2}:\\d{2})$").matchEntire(text))
            fun n(i: Int) = m.groupValues[i].toInt()
            require(n(1) >= 1)
            val base = LocalDateTime.of(n(1), n(2), n(3), n(4), n(5), n(6)).toEpochSecond(ZoneOffset.UTC) * 1000
            val fraction = m.groupValues[7].takeIf { it.isNotEmpty() }?.padEnd(3, '0')?.toLong() ?: 0
            val zone = m.groupValues[8]
            val offset = if (zone == "Z") 0 else {
                val h = zone.substring(1, 3).toInt(); val minutes = zone.substring(4, 6).toInt(); require(h <= 23 && minutes < 60)
                (h * 60 + minutes) * if (zone[0] == '+') 1 else -1
            }
            return Math.subtractExact(Math.addExact(base, fraction), offset * 60000L)
        }
    }
}
