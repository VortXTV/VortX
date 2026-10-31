package com.vortx.android.engine

import org.json.JSONObject

/** Raw persistence material only. These observations confer no account, profile or write authority.
 * JSONObject is a disposable reducer projection; no re-encoded projection becomes an original. */
internal object NativeRawHostPreferences {
    private const val IMPORT_PREFIX = "xperience.import."
    /** Exact schema-clock semantics for raw domain admission, before any Number projection.
     * Reuses the bounded digit/exponent scanner; no arbitrary-size decimal/integer allocation. */
    internal fun exactClock(raw: ByteArray): Long = NumberTokens.clock(raw)

    fun captureLocal(scope: VortxAccountScope, original: ByteArray): ByteArray {
        val stable = original.copyOf()
        OHJson.Obj(stable)
        NativeHostPreferences.local(scope, JSONObject(OHJson.utf8(stable)))
        return stable
    }

    fun document(local: ByteArray): ByteArray = OHJson.Obj(local).raw("document")

    /** Legacy/fake exporters may omit raw data only while no opaque import is present. */
    fun requireRawExport(projected: JSONObject?, raw: ByteArray?) {
        if (projected == null) { require(raw == null); return }
        if (raw != null) {
            OHJson.Obj(raw)
            require(sameHostProjection(JSONObject(OHJson.utf8(raw)), projected)) {
                "Raw host export does not match presentation"
            }
        } else {
            // Legacy deterministic fake exporters may contain only a globals bucket. Production
            // inputs were already fully host-validated; do not expand old fake-gateway authority.
            val profiles = projected.optJSONObject("profiles") ?: return
            require(profiles.keys().asSequence().none { id -> profiles.getJSONObject(id).getJSONObject("fields")
                .keys().asSequence().any { it.startsWith(IMPORT_PREFIX) } }) { "Original raw import export required" }
        }
    }

    /** A JSONObject-only adapter cannot attest to opaque imports' original numeric tokens. */
    fun requireIncomingObservation(scope: VortxAccountScope, projected: JSONObject?, raw: ByteArray?) {
        if (projected == null) { require(raw == null); return }
        NativeHostPreferences.validate(scope, projected)
        if (raw != null) {
            OHJson.Obj(raw)
            val decoded = JSONObject(OHJson.utf8(raw))
            NativeHostPreferences.validate(scope, decoded)
            require(sameHostProjection(decoded, projected)) { "Raw host observation does not match reducer input" }
        } else requireRawExport(projected, null)
    }

    /** Comparison of disposable projections, not original raw event equality. Avoids reparsing
     * user-sized opaque Number strings with BigDecimal. Only existing UUID profile-key aliases
     * are normalized; original raw keys/values are never rewritten by this readonly pairing. */
    private fun sameHostProjection(a: JSONObject, b: JSONObject): Boolean {
        val keys = a.keys().asSequence().toSet()
        if (keys != b.keys().asSequence().toSet()) return false
        return keys.all { key ->
            val first = a.get(key); val second = b.get(key)
            if (key == "profiles" && first is JSONObject && second is JSONObject) {
                val left = NativeHostPreferences.profileKeyIndex(first); val right = NativeHostPreferences.profileKeyIndex(second)
                left.keys == right.keys && left.keys.all { projectionEqual(first.get(left.getValue(it)), second.get(right.getValue(it))) }
            } else projectionEqual(first, second)
        }
    }

    private fun projectionEqual(a: Any?, b: Any?): Boolean = when {
        (a == null || a == JSONObject.NULL) && (b == null || b == JSONObject.NULL) -> true
        a is JSONObject && b is JSONObject -> a.keys().asSequence().toSet().let { keys ->
            keys == b.keys().asSequence().toSet() && keys.all { projectionEqual(a.get(it), b.get(it)) }
        }
        a is org.json.JSONArray && b is org.json.JSONArray -> a.length() == b.length() &&
            (0 until a.length()).all { projectionEqual(a.get(it), b.get(it)) }
        a is Number && b is Number -> NumberTokens.same(a.toString().toByteArray(Charsets.UTF_8), b.toString().toByteArray(Charsets.UTF_8))
        else -> a == b
    }

    /** Preserve the original local slices, then adopt original incoming register slices ONLY for
     * the reducer's actual Lamport winner. Full equal-event raw contradictions reject before CAS.
     * An unsupported register remains subject to the existing host validator, never made editable. */
    fun reconcile(scope: VortxAccountScope, originalLocal: ByteArray?, reduced: JSONObject,
                  incoming: JSONObject? = null, originalIncoming: ByteArray? = null): ByteArray {
        requireIncomingObservation(scope, incoming, originalIncoming)
        NativeHostPreferences.local(scope, reduced)
        val next = reduced.toString().toByteArray(Charsets.UTF_8)
        if (originalLocal == null) {
            // Only freshly minted local actor/counter/state has no persisted beforeimage.
            val created = OHJson.Obj(next)
            if (originalIncoming != null) adoptIncoming(null, created, originalIncoming)
            return captureLocal(scope, created.encoded())
        }
        val raw = captureLocal(scope, originalLocal)
        val before = NativeHostPreferences.local(scope, JSONObject(OHJson.utf8(raw)))
            .toString().toByteArray(Charsets.UTF_8)
        val original = OHJson.Obj(raw)
        val previous = spellProfilesLike(original, OHJson.Obj(before))
        val prospective = spellProfilesLike(original, OHJson.Obj(next))
        val remoteWinners = mutableSetOf<List<String>>()
        if (originalIncoming != null) adoptIncoming(original, prospective, originalIncoming, remoteWinners)
        val result = OHJson.Obj(patch(raw, previous.encoded(), prospective.encoded(), emptyList(), remoteWinners))
        return captureLocal(scope, result.encoded())
    }

    /** Persist an exact captured/derived host slice beside disposable native presentation JSON. */
    fun snapshot(projection: String, host: ByteArray): String = OHJson.utf8(OHJson.Obj(
        projection.toByteArray(Charsets.UTF_8)).set("nativeHostPreferenceState", host).encoded())

    private fun spellProfilesLike(originalLocal: OHJson.Obj, local: OHJson.Obj): OHJson.Obj {
        val original = originalLocal.obj("document").obj("profiles")
        val names = uniqueNames(original)
        val document = local.obj("document")
        val profiles = document.obj("profiles")
        uniqueNames(profiles)
        val renamed = OHJson.Obj()
        profiles.keys.forEach { key -> renamed.set(names[NativeHostPreferences.canonicalProfileID(key)] ?: key, profiles.raw(key)) }
        return local.copy().set("document", document.set("profiles", renamed.encoded()).encoded())
    }

    private fun uniqueNames(profiles: OHJson.Obj): Map<String, String> = linkedMapOf<String, String>().also { names ->
        profiles.keys.forEach { name -> require(names.put(NativeHostPreferences.canonicalProfileID(name), name) == null) {
            "Duplicate canonical raw host profile identity"
        } }
    }

    private fun eventComparison(left: OHJson.Obj, right: OHJson.Obj) = compareValuesBy(left, right,
        { NumberTokens.clock(it.raw("clock")) }, { it.text("actor") })

    /** Equality of an already structurally admitted event. Only existing schema-owned numbers
     * use mathematical equality; opaque/future values retain their conservative raw policy. */
    internal fun requireEqualEvent(field: String, profile: Boolean, original: ByteArray, incoming: ByteArray) {
        val a = OHJson.Obj(original); val b = OHJson.Obj(incoming)
        require(a.keys == setOf("clock", "actor", "value") && b.keys == a.keys &&
            NumberTokens.same(a.raw("clock"), b.raw("clock")) &&
            OHJson.equal(a.raw("actor"), b.raw("actor")) &&
            equalValue(a.raw("value"), b.raw("value"), profile, field, emptyList())) {
            "Conflicting full raw host preference event"
        }
    }

    private fun equalValue(a: ByteArray, b: ByteArray, profile: Boolean, field: String, path: List<String>): Boolean {
        if (OHJson.equal(a, b)) return true
        if (profile && com.vortx.android.foryou.ForYouEditFields.people(field, path)) return equalPeople(a, b)
        return when (NativeHostPreferences.numericValueKind(profile, field, path)) {
            NativeHostPreferences.NumericValueKind.SCALAR -> NumberTokens.same(a, b)
            NativeHostPreferences.NumericValueKind.INTEGER_ARRAY -> equalNumberArray(a, b)
            null -> if (a.firstOrNull() == '{'.code.toByte() && b.firstOrNull() == '{'.code.toByte()) {
                val left = OHJson.Obj(a); val right = OHJson.Obj(b)
                left.keys == right.keys && left.keys.all { equalValue(left.raw(it), right.raw(it), profile, field, path + it) }
            } else false
        }
    }

    private fun equalNumberArray(a: ByteArray, b: ByteArray): Boolean {
        if (a.firstOrNull() != '['.code.toByte() || b.firstOrNull() != '['.code.toByte()) return false
        val left = OHJson.array(a); val right = OHJson.array(b)
        return left.size == right.size && left.indices.all { NumberTokens.same(left[it], right[it]) }
    }

    private fun adoptIncoming(originalLocal: OHJson.Obj?, resultLocal: OHJson.Obj, incomingBytes: ByteArray,
                              winners: MutableSet<List<String>>? = null) {
        val source = OHJson.Obj(incomingBytes)
        val prior = originalLocal?.obj("document")
        val result = resultLocal.obj("document")
        fun fields(old: OHJson.Obj?, next: OHJson.Obj, remote: OHJson.Obj, path: List<String>): ByteArray {
            for (field in remote.keys) {
                val incoming = remote.obj(field)
                val previous = old?.get(field)?.let { OHJson.Obj(it) }
                val comparison = if (previous == null) 1 else eventComparison(incoming, previous)
                if (comparison == 0) requireEqualEvent(field, path.getOrNull(1) == "profiles",
                    previous!!.encoded(), incoming.encoded())
                if (comparison > 0) {
                    val accepted = next[field] ?: error("Raw host winner was not reduced")
                    if (eventComparison(OHJson.Obj(accepted), incoming) > 0) continue // A genuine newer local reducer event.
                    require(projectionEqual(JSONObject(OHJson.utf8(accepted)), JSONObject(OHJson.utf8(incoming.encoded())))) {
                        "Raw host winner differs from reducer"
                    }
                    next.set(field, remote.raw(field)); winners?.add(path + field)
                }
            }
            return next.encoded()
        }
        val globals = result.obj("globals")
        globals.set("fields", fields(prior?.obj("globals")?.obj("fields"), globals.obj("fields"), source.obj("globals").obj("fields"),
            listOf("document", "globals", "fields")))
        result.set("globals", globals.encoded())
        val remoteProfiles = source.obj("profiles"); val nextProfiles = result.obj("profiles")
        val priorProfiles = prior?.obj("profiles")
        val oldNames = priorProfiles?.let(::uniqueNames).orEmpty()
        val nextNames = uniqueNames(nextProfiles)
        uniqueNames(remoteProfiles)
        for (remoteName in remoteProfiles.keys) {
            val id = NativeHostPreferences.canonicalProfileID(remoteName)
            val nextName = nextNames[id] ?: error("Raw host profile winner was not reduced")
            val nextBucket = nextProfiles.obj(nextName)
            val oldFields = oldNames[id]?.let { priorProfiles!!.obj(it).obj("fields") }
            nextBucket.set("fields", fields(oldFields, nextBucket.obj("fields"), remoteProfiles.obj(remoteName).obj("fields"),
                listOf("document", "profiles", nextName, "fields")))
            nextProfiles.set(nextName, nextBucket.encoded())
        }
        result.set("profiles", nextProfiles.encoded())
        resultLocal.set("document", result.encoded())
    }

    /** A changed opaque scalar/array must have a lossless baseline. Unchanged slices never decode. */
    internal fun patch(raw: ByteArray, before: ByteArray, after: ByteArray): ByteArray = patch(raw, before, after, emptyList(), emptySet())

    /** Same owned-register clock rules for a cloud host document without the local actor/counter. */
    internal fun patchDocument(raw: ByteArray, before: ByteArray, after: ByteArray): ByteArray = OHJson.Obj(patch(
        OHJson.Obj().set("document", raw).encoded(), OHJson.Obj().set("document", before).encoded(),
        OHJson.Obj().set("document", after).encoded())).raw("document")

    private fun patch(raw: ByteArray, before: ByteArray, after: ByteArray, path: List<String>,
                      remoteWinners: Set<List<String>>): ByteArray {
        if (path in remoteWinners) return after.copyOf() // Exact admitted whole-register Lamport replacement.
        if (OHJson.equal(before, after) || OHJson.equal(raw, after)) return raw.copyOf()
        if (peopleAt(path)) return patchPeople(raw, before, after)
        val previous = JSONObject("{\"v\":" + OHJson.utf8(before) + "}").get("v")
        val next = JSONObject("{\"v\":" + OHJson.utf8(after) + "}").get("v")
        if (next == JSONObject.NULL && previous is JSONObject && path.size == 6 && path[0] == "document" &&
            path[1] == "profiles" && path[3] == "fields" && path[5] == "value" && raw.firstOrNull() == '{'.code.toByte() &&
            NativeHostPreferences.explicitRecordTombstone(path[4], previous)) {
            val original = OHJson.Obj(raw)
            val field = path[4]
            val exactIdentity = if (com.vortx.android.foryou.ForYouSync.isCollectionField(field)) {
                original["id"]?.let { runCatching { com.vortx.android.foryou.SmartCollection.FIELD_PREFIX + OHJson.text(it) == field }.getOrDefault(false) } == true
            } else {
                val identity = com.vortx.android.library.NativeWatchlistCodec.identity(field)
                original["id"]?.let { runCatching { OHJson.text(it) == identity.id }.getOrDefault(false) } == true &&
                    original["type"]?.let { runCatching { OHJson.text(it) == identity.type }.getOrDefault(false) } == true
            }
            require(exactIdentity) { "Original record deletion identity changed" }
            return after.copyOf()
        }
        if (previous is JSONObject && next is JSONObject) {
            val result = OHJson.Obj(raw); val a = OHJson.Obj(before); val b = OHJson.Obj(after)
            for (key in a.keys + b.keys) {
                val old = a[key]; val value = b[key]
                if (value == null) result.remove(key)
                else if (old == null) {
                    val unobserved = result[key]
                    require(unobserved == null || OHJson.equal(unobserved, value)) { "Unobserved raw host sibling collision" }
                    if (peopleAt(path + key)) requireNewPeople(value)
                    result.set(key, value)
                } else result.set(key, patch(result[key] ?: old, old, value, path + key, remoteWinners))
            }
            return result.encoded()
        }
        // Known numeric settings reuse the host validator's schema ownership. Future numbers
        // and arbitrary opaque arrays never acquire these mutation semantics.
        val ownedClock = path == listOf("counter") ||
            (path.size == 5 && path.take(3) == listOf("document", "globals", "fields") && path.last() == "clock") ||
            (path.size == 6 && path[0] == "document" && path[1] == "profiles" && path[3] == "fields" && path.last() == "clock")
        val numeric = numericKindAt(path)
        val supportedClock = ownedClock && next is Number && NumberTokens.same(raw, before)
        // A validated setting operation owns the whole known number, including precision that
        // its disposable Double view cannot retain. Replacing it must not require the old exact
        // number to equal that rounded view. This permission never applies to opaque members.
        val supportedNumeric = numeric == NativeHostPreferences.NumericValueKind.SCALAR && previous is Number &&
            (next is Number || next == JSONObject.NULL) && NumberTokens.valid(raw)
        val supportedArray = numeric == NativeHostPreferences.NumericValueKind.INTEGER_ARRAY &&
            previous is org.json.JSONArray && (next is org.json.JSONArray || next == JSONObject.NULL) &&
            numberArray(raw) && numberArray(before) && (next == JSONObject.NULL || numberArray(after))
        require(supportedClock || supportedNumeric || supportedArray || OHJson.equal(raw, before)) { "Opaque host value requires lossless mutation support" }
        return after.copyOf()
    }

    private fun numericKindAt(path: List<String>): NativeHostPreferences.NumericValueKind? {
        if (path.size >= 5 && path.take(3) == listOf("document", "globals", "fields") && path[4] == "value")
            return NativeHostPreferences.numericValueKind(false, path[3], path.drop(5))
        if (path.size >= 6 && path[0] == "document" && path[1] == "profiles" && path[3] == "fields" && path[5] == "value")
            return NativeHostPreferences.numericValueKind(true, path[4], path.drop(6))
        return null
    }

    private fun peopleAt(path: List<String>): Boolean = path.size >= 6 && path[0] == "document" &&
        path[1] == "profiles" && path[3] == "fields" && path[5] == "value" &&
        com.vortx.android.foryou.ForYouEditFields.people(path[4], path.drop(6))

    private fun jsonValue(raw: ByteArray): Any = JSONObject("{\"v\":" + OHJson.utf8(raw) + "}").get("v")
    private fun objectRow(raw: ByteArray): OHJson.Obj? = if (raw.firstOrNull() == '{'.code.toByte()) OHJson.Obj(raw) else null
    private fun exactPerson(raw: ByteArray): Int? {
        val row = objectRow(raw) ?: return null
        val id = row["id"]?.let(NumberTokens::positiveInt) ?: return null
        val name = row["name"]?.let { runCatching { OHJson.text(it) }.getOrNull() } ?: return null
        if (name.isBlank()) return null
        row["department"]?.let { value ->
            if (!OHJson.equal(value, OHJson.literal("null")) && runCatching { OHJson.text(value) }.isFailure) return null
        }
        return id
    }
    private fun reservation(raw: ByteArray): Int? = com.vortx.android.foryou.ForYouEditFields.reservedId(jsonValue(raw))
    private fun reservations(rows: List<ByteArray>): Map<Int, Int> = rows.mapNotNull(::reservation).groupingBy { it }.eachCount()
    private fun requireNewPeople(raw: ByteArray) {
        require(raw.firstOrNull() == '['.code.toByte()) { "Unsupported For You people shape" }
        val rows = OHJson.array(raw); val seen = mutableSetOf<Int>()
        for (row in rows) {
            val id = requireNotNull(exactPerson(row)) { "Unsupported new For You person" }
            require(seen.add(id) && objectRow(row)!!.keys.all { it in com.vortx.android.foryou.ForYouEditFields.person }) {
                "Ambiguous or unsupported new For You person"
            }
        }
    }

    /** This is the existing editor's retention/order contract, applied to ORIGINAL raw slices.
     * A projected numeric ID reserves collisions but cannot identify an editable raw person. */
    private fun patchPeople(raw: ByteArray, before: ByteArray, after: ByteArray): ByteArray {
        require(listOf(raw, before, after).all { it.firstOrNull() == '['.code.toByte() }) { "Unsupported For You people shape" }
        val originals = OHJson.array(raw); val observed = OHJson.array(before); val proposed = OHJson.array(after)
        require(originals.size == observed.size && originals.indices.all { projectionEqual(jsonValue(originals[it]), jsonValue(observed[it])) }) {
            "Original For You people observation changed"
        }
        val reserved = reservations(observed)
        val represented = observed.mapNotNull { com.vortx.android.foryou.ForYouEditFields.representedId(jsonValue(it)) }.groupingBy { it }.eachCount()
        val candidates = proposed.mapIndexedNotNull { index, row -> exactPerson(row)?.let { it to index } }.groupBy({ it.first }, { it.second })
        val result = ArrayList<ByteArray>(); var cursor = 0
        for (index in originals.indices) {
            val original = originals[index]; val baseline = observed[index]
            val id = exactPerson(original)
            val beforeId = objectRow(baseline)?.get("id")
            val eligible = id != null && beforeId != null && NumberTokens.same(objectRow(original)!!.raw("id"), beforeId) &&
                reserved[id] == 1 && represented[id] == 1
            if (!eligible) {
                require(cursor < proposed.size && projectionEqual(jsonValue(baseline), jsonValue(proposed[cursor]))) {
                    "Unknown or ambiguous For You person changed"
                }
                result.add(original); cursor++
                continue
            }
            checkNotNull(id)
            val positions = candidates[id].orEmpty()
            require(positions.size <= 1) { "Ambiguous proposed For You person" }
            if (positions.isEmpty()) continue // Explicit removal of one exact, unique represented ID.
            require(positions.single() == cursor) { "For You people order or identity changed" }
            val updated = objectRow(proposed[cursor])!!; val oldView = objectRow(baseline)!!; val retained = objectRow(original)!!
            require(NumberTokens.same(retained.raw("id"), updated.raw("id"))) { "For You person identity changed" }
            val owned = com.vortx.android.foryou.ForYouEditFields.person
            for (key in (oldView.keys + updated.keys) - owned) {
                val a = oldView[key]; val b = updated[key]
                require(if (a == null || b == null) a == null && b == null else projectionEqual(jsonValue(a), jsonValue(b))) {
                    "Unknown For You person member changed"
                }
            }
            var changed = false
            for (key in owned - "id") {
                val a = oldView[key]; val b = updated[key]
                if (a != null && b != null && projectionEqual(jsonValue(a), jsonValue(b)) || a == null && b == null) continue
                if (b == null) retained.remove(key) else retained.set(key, b)
                changed = true
            }
            result.add(if (changed) retained.encoded() else original); cursor++
        }
        val appended = mutableSetOf<Int>()
        while (cursor < proposed.size) {
            val row = proposed[cursor++]; val id = requireNotNull(exactPerson(row)) { "Unsupported appended For You person" }
            require(id !in reserved && appended.add(id) && candidates[id]?.size == 1 &&
                objectRow(row)!!.keys.all { it in com.vortx.android.foryou.ForYouEditFields.person }) {
                "Reserved or ambiguous appended For You person"
            }
            result.add(row)
        }
        return OHJson.array(result)
    }

    private fun equalPeople(a: ByteArray, b: ByteArray): Boolean {
        if (a.firstOrNull() != '['.code.toByte() || b.firstOrNull() != '['.code.toByte()) return false
        val left = OHJson.array(a); val right = OHJson.array(b)
        if (left.size != right.size) return false
        val leftReserved = reservations(left); val rightReserved = reservations(right)
        return left.indices.all { index ->
            val first = left[index]; val second = right[index]
            if (OHJson.equal(first, second)) true else {
                val id = exactPerson(first); val other = exactPerson(second)
                if (id == null || id != other || leftReserved[id] != 1 || rightReserved[id] != 1) false else {
                    val x = objectRow(first)!!; val y = objectRow(second)!!
                    x.keys == y.keys && x.keys.all { key ->
                        if (key == "id") NumberTokens.same(x.raw(key), y.raw(key)) else OHJson.equal(x.raw(key), y.raw(key))
                    }
                }
            }
        }
    }

    private fun numberArray(raw: ByteArray): Boolean = raw.firstOrNull() == '['.code.toByte() &&
        OHJson.array(raw).all(NumberTokens::valid)

    /** Exact decimal-token comparison in linear time/space under OHJson.MAX. No user-sized
     * BigDecimal/BigInteger or exponent expansion. The significant digit span stays in the input;
     * only the decimal exponent's digits are adjusted by a bounded mantissa-length offset. */
    private object NumberTokens {
        private class Power(val negative: Boolean, val digits: ByteArray) {
            fun smallNonnegative(maximum: Int): Int? {
                if (negative || digits.size > 2) return null
                var value = 0
                for (digit in digits) value = value * 10 + digit.toInt() - '0'.code
                return value.takeIf { it <= maximum }
            }
        }
        private class Token(val raw: ByteArray, val negative: Boolean, val first: Int, val last: Int,
                            val dot: Int, val fractionDigits: Int, val trailingZeros: Int,
                            val exponentStart: Int, val exponentEnd: Int, val exponentNegative: Boolean) {
            val zero get() = first < 0
            val significantLength get() = if (zero) 0 else last - first + 1 - (if (dot in first..last) 1 else 0)
            fun power(): Power {
                var start = exponentStart
                while (start < exponentEnd && raw[start] == '0'.code.toByte()) start++
                val size = exponentEnd - start
                val offset = trailingZeros - fractionDigits
                // At most 18 exponent digits fit safely with the <= OHJson.MAX offset in Long.
                // Longer exponents take digit-wise addition/subtraction; this is not a format cap.
                if (size <= 18) {
                    var value = 0L
                    for (index in start until exponentEnd) value = value * 10 + raw[index].toInt() - '0'.code
                    value = (if (exponentNegative) -value else value) + offset
                    return Power(value < 0, kotlin.math.abs(value).toString().toByteArray(Charsets.US_ASCII))
                }
                val digits = ByteArray(size + 1) { '0'.code.toByte() }
                raw.copyInto(digits, 1, start, exponentEnd)
                val delta = if (exponentNegative) -offset else offset
                var carry = kotlin.math.abs(delta.toLong())
                var index = digits.lastIndex
                while (carry > 0 && index >= 0) {
                    val part = (carry % 10).toInt(); carry /= 10
                    var digit = digits[index].toInt() - '0'.code
                    if (delta >= 0) {
                        digit += part
                        if (digit >= 10) { digit -= 10; carry++ }
                    } else {
                        digit -= part
                        if (digit < 0) { digit += 10; carry++ }
                    }
                    digits[index--] = (digit + '0'.code).toByte()
                }
                check(carry == 0L) // A >18-digit magnitude cannot change sign with this offset.
                var significant = 0
                while (significant < digits.lastIndex && digits[significant] == '0'.code.toByte()) significant++
                return Power(exponentNegative, if (significant > 0) digits.copyOfRange(significant, digits.size) else digits)
            }
        }
        private fun digit(byte: Byte) = byte.toInt() in '0'.code..'9'.code
        private fun parse(raw: ByteArray): Token? {
            if (raw.isEmpty() || raw.size > OHJson.MAX) return null
            var at = 0; val negative = raw[at] == '-'.code.toByte()
            if (negative && ++at == raw.size) return null
            var first = -1; var last = -1; var trailing = 0
            fun mark(index: Int) {
                if (raw[index] == '0'.code.toByte()) trailing++
                else { if (first < 0) first = index; last = index; trailing = 0 }
            }
            if (raw[at] == '0'.code.toByte()) {
                mark(at++)
                if (at < raw.size && digit(raw[at])) return null
            } else {
                if (raw[at].toInt() !in '1'.code..'9'.code) return null
                while (at < raw.size && digit(raw[at])) mark(at++)
            }
            var dot = -1; var fraction = 0
            if (at < raw.size && raw[at] == '.'.code.toByte()) {
                dot = at++
                val start = at
                while (at < raw.size && digit(raw[at])) { mark(at++); fraction++ }
                if (at == start) return null
            }
            var exponentNegative = false; var exponentStart = raw.size; var exponentEnd = raw.size
            if (at < raw.size && (raw[at] == 'e'.code.toByte() || raw[at] == 'E'.code.toByte())) {
                at++
                if (at < raw.size && (raw[at] == '-'.code.toByte() || raw[at] == '+'.code.toByte()))
                    exponentNegative = raw[at++] == '-'.code.toByte()
                exponentStart = at
                while (at < raw.size && digit(raw[at])) at++
                exponentEnd = at
                if (at == exponentStart) return null
            }
            if (at != raw.size) return null
            return Token(raw, negative, first, last, dot, fraction, trailing, exponentStart, exponentEnd, exponentNegative)
        }

        fun same(a: ByteArray, b: ByteArray): Boolean {
            val left = parse(a) ?: return false; val right = parse(b) ?: return false
            if (left.zero || right.zero) return left.zero && right.zero // Existing Number(BigDecimal) zero semantics.
            if (left.negative != right.negative || left.significantLength != right.significantLength) return false
            var x = left.first; var y = right.first
            while (x <= left.last && y <= right.last) {
                if (x == left.dot) x++
                if (y == right.dot) y++
                if (left.raw[x++] != right.raw[y++]) return false
            }
            val firstPower = left.power(); val secondPower = right.power()
            return firstPower.negative == secondPower.negative && firstPower.digits.contentEquals(secondPower.digits)
        }

        fun valid(raw: ByteArray): Boolean = parse(raw) != null
        fun positiveInt(raw: ByteArray): Int? = runCatching { clock(raw).takeIf { it in 1..Int.MAX_VALUE.toLong() }?.toInt() }.getOrNull()

        fun clock(raw: ByteArray): Long {
            val token = requireNotNull(parse(raw)) { "Invalid raw host clock" }
            if (token.zero) return 0L
            require(!token.negative && token.significantLength <= 16) { "Invalid exact raw host clock" }
            val power = requireNotNull(token.power().smallNonnegative(16)) { "Invalid exact raw host clock" }
            require(token.significantLength + power <= 16) { "Raw host clock exceeds limit" }
            var value = 0L
            for (index in token.first..token.last) if (index != token.dot)
                value = value * 10 + token.raw[index].toInt() - '0'.code
            repeat(power) { value *= 10 }
            require(value <= NativeHostPreferences.MAX_CLOCK) { "Raw host clock exceeds limit" }
            return value
        }
    }
}

/** Called synchronously under the original typed candidate/authority/file observation. A copied
 * account is read-only budget input; the once-only callback is the ONLY persistence capability. */
internal fun interface NativePreparedAccountAdmission {
    fun withCandidate(account: ByteArray, persist: () -> Unit)
}

/** Additive app delegate capability; no JNI/private-engine ABI and no change to the old method. */
internal interface VortxPreparedAccountDelegate : VortxRuntimeDelegate {
    fun commitPreparedCheckpoint(snapshot: String, archiveChanges: Map<String, ByteArray>,
                                 admission: NativePreparedAccountAdmission)
}
