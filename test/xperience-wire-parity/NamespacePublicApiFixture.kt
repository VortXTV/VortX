@file:JvmName("NamespacePublicApiFixture")
package com.vortx.android.xperience

import com.vortx.android.engine.OHJson
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** Proposed dependency-free JVM assertions. Production model/OHJson bodies are separate real inputs.
 * All data is synthetic; no persistence/account/native/UI operation exists in this fixture. */
private object Checks {
    var count = 0
    fun that(value: Boolean, message: String) { count++; check(value) { message } }
    fun rejected(expected: XperienceCollections.Failure, action: () -> Unit) {
        count++
        try { action(); error("Expected model refusal $expected") }
        catch (failure: XperienceCollections.Rejected) { check(failure.reason == expected) { "Wrong model refusal" } }
    }
}
private const val MAX_SYNTHETIC_BYTES = 16 * 1024
private val namespace = UUID.fromString("00000000-0000-0000-0000-000000000101")
private const val actor = "00000000-0000-0000-0000-000000000202"
private const val otherActor = "00000000-0000-0000-0000-000000000203"
private fun bounded(bytes: ByteArray): ByteArray {
    check(bytes.size <= MAX_SYNTHETIC_BYTES) { "Fixture input grew beyond its small-input contract" }
    return bytes
}
private fun text(value: String): ByteArray = bounded(value.toByteArray(Charsets.UTF_8))
private fun fixture(extra: String = ""): ByteArray = text("""
    [{"id":"collection.one","title":"One","folders":[{"id":"folder.one","title":"Folder",
      "sources":[{"provider":"addon","addonId":"example.catalogs","type":"movie","catalogId":"genre.example","genre":"None"}]}]$extra}]
""".trimIndent())
private fun document(extra: String = "") = XperienceCollections.parse(fixture(extra))
private fun register(value: ByteArray, clock: Long = 1, who: String = actor): ByteArray = bounded(
    OHJson.Obj().set("clock", OHJson.literal(clock.toString())).set("actor", OHJson.quote(who)).set("value", value).encoded())
// Literal construction is necessary for malformed/depth test inputs; it is not a canonicalizer.
private fun literalRegister(value: String): ByteArray = text("""{"clock":1,"actor":"$actor","value":$value}""")
private fun extraValue(value: ByteArray, member: String): String = value.toString(Charsets.UTF_8).dropLast(1) + "," + member + "}"
private fun created(): XperienceImportNamespace.Edit = XperienceImportNamespace.append(document(), "Imported", namespace,
    mapOf(document().collections.single().folders.single().sources.single().semanticDigest to
        XperienceImportNamespace.Binding("example.catalogs", "a".repeat(64))))
private fun runCase(name: String, action: () -> Unit) { action(); println("PASS namespace-public-api $name") }

/** Adapted from the retained namespace round-trip test; unknown raw tokens stay production slices. */
private fun roundTripReplaceUnknown() {
    val initial = created()
    val future = text("""{ "exact":9007199254740993.0,"empty":[],"escaped":"e\u0301","nested":{"keep":true} }""")
    val value = OHJson.Obj(initial.value()).set("futureEnvelope", future).encoded()
    val original = register(value)
    val saved = XperienceImportNamespace.read(initial.field, original)
    Checks.that(saved.namespace == namespace && saved.document.fingerprint == document().fingerprint, "read keeps the bound namespace/document")
    val editedDoc = document(",\"newUnknown\":true")
    val replacement = saved.replacement(editedDoc, "Renamed", saved.bindings)
    Checks.that(replacement.field == initial.field && replacement.namespace == namespace, "replacement never changes namespace")
    Checks.that(replacement.baselineMatches(original), "replacement retains its original register")
    Checks.that(!replacement.value().contentEquals(initial.value()), "replacement changes intended owned members")
    Checks.that(OHJson.Obj(replacement.value()).raw("futureEnvelope").contentEquals(future), "unknown envelope raw token bytes survive replace")
    val committed = register(replacement.value(), 2)
    val reread = XperienceImportNamespace.read(initial.field, committed)
    Checks.that(reread.label == "Renamed" && reread.document.fingerprint == editedDoc.fingerprint, "public read-replace-read contract")
    Checks.that(OHJson.Obj(OHJson.Obj(reread.register()).raw("value")).raw("futureEnvelope").contentEquals(future), "reread keeps every unknown token")
    Checks.that(!replacement.baselineMatches(committed), "old observation is stale after replacement")
}

private fun semanticBaselineAndStaleCut() {
    val initial = created(); val original = register(initial.value())
    val saved = XperienceImportNamespace.read(initial.field, original)
    val edit = saved.replacement(document(), "Edited", saved.bindings)
    val reordered = text("""{ "value" : ${initial.value().toString(Charsets.UTF_8)}, "clock" : 1, "actor" : "$actor" }""")
    Checks.that(!original.contentEquals(reordered) && edit.baselineMatches(reordered), "actual canonical full-register CAS accepts key/whitespace reorder")
    Checks.that(!edit.baselineMatches(register(initial.value(), 2)), "clock change is stale")
    Checks.that(!edit.baselineMatches(register(initial.value(), who = otherActor)), "actor change is stale")
    val changed = OHJson.Obj(initial.value()).set("newConcurrentUnknown", OHJson.literal("true")).encoded()
    Checks.that(!edit.baselineMatches(register(changed)), "unknown value change is stale")
    Checks.that(!edit.baselineMatches(register(OHJson.literal("null"))) && !edit.baselineMatches(null), "tombstone and absence do not equal observed live register")
    Checks.that(initial.baselineMatches(null) && !initial.baselineMatches(original), "append observation only owns absence")
}

private fun detachedOwnership() {
    val initial = created(); val caller = register(initial.value()); val original = caller.copyOf()
    val saved = XperienceImportNamespace.read(initial.field, caller)
    caller.fill(32)
    Checks.that(saved.register().contentEquals(original), "Saved does not retain mutable caller bytes")
    val copy = saved.register(); copy.fill(32)
    val edit = saved.replacement(document(), "Detached", saved.bindings)
    val expectedCopy = checkNotNull(edit.expectedRegister()); expectedCopy.fill(32)
    val valueCopy = edit.value(); valueCopy.fill(32)
    Checks.that(saved.register().contentEquals(original) && edit.baselineMatches(original), "returned snapshots cannot rewrite admitted baseline")
    Checks.that(edit.value().first() == '{'.code.toByte(), "returned proposed value is detached")
}

private fun duplicateKeysPrecisionAndInvalidShortcut() {
    val initial = created(); val original = register(initial.value())
    val duplicate = text(original.toString(Charsets.UTF_8).replaceFirst("\"clock\":1", "\"clock\":1,\"cl\\u006fck\":1"))
    Checks.rejected(XperienceCollections.Failure.DUPLICATE_MEMBER) { XperienceImportNamespace.read(initial.field, duplicate) }
    val nfc = literalRegister(extraValue(initial.value(), "\"futureEnvelope\":{\"e\\u0301\":1,\"\\u00e9\":2}"))
    Checks.rejected(XperienceCollections.Failure.DUPLICATE_MEMBER) { XperienceImportNamespace.read(initial.field, nfc) }
    val imprecise = literalRegister(extraValue(initial.value(), "\"futureEnvelope\":0.123456789012345678901"))
    Checks.rejected(XperienceCollections.Failure.UNPRESERVABLE_NUMBER) { XperienceImportNamespace.read(initial.field, imprecise) }
    val malformed = bounded(original + text("null"))
    Checks.rejected(XperienceCollections.Failure.INVALID_JSON) { XperienceImportNamespace.read(initial.field, malformed) }
    val saved = XperienceImportNamespace.read(initial.field, original)
    val edit = saved.replacement(document(), "Next", saved.bindings)
    Checks.that(!edit.baselineMatches(malformed) && !edit.baselineMatches(duplicate), "malformed identical-to-itself bytes never become an admitted baseline")
    Checks.that(edit.baselineMatches(original), "rejected candidates leave original observation intact")
}

/** The old multi-MiB deep-sibling case is kept small here; the production depth route is unchanged. */
private fun boundedDepthAndUnknownRawCas() {
    val initial = created()
    var deep = "\"payload\":\"small-synthetic\""
    repeat(48) { index -> deep = "\"level$index\":{$deep}" }
    val unknown = "{$deep}"
    val value = extraValue(initial.value(), "\"futureEnvelope\":$unknown")
    val original = literalRegister(value)
    val saved = XperienceImportNamespace.read(initial.field, original)
    val edit = saved.replacement(document(), "Deep", saved.bindings)
    val reordered = text("""{ "value" : $value, "actor" : "$actor", "clock" : 1 }""")
    Checks.that(edit.baselineMatches(reordered), "generic register unknown depth above collection32 remains comparable")
    Checks.that(OHJson.Obj(edit.value()).raw("futureEnvelope").contentEquals(text(unknown)), "deep unknown bytes survive replacement")
    var tooDeep = "null"; repeat(130) { tooDeep = "{\"x\":$tooDeep}" }
    val invalid = literalRegister(extraValue(initial.value(), "\"futureEnvelope\":$tooDeep"))
    Checks.rejected(XperienceCollections.Failure.INVALID_JSON) { XperienceImportNamespace.read(initial.field, invalid) }
    Checks.that(!edit.baselineMatches(invalid) && edit.baselineMatches(original), "depth refusal does not weaken original CAS")
    var collectionDeep = "null"; repeat(33) { collectionDeep = "{\"x\":$collectionDeep}" }
    Checks.rejected(XperienceCollections.Failure.TOO_LARGE) { document(",\"future\":$collectionDeep") }
}

private fun exactIntegerRawConservation() {
    val initial = created()
    val unknown = text("""{"wide":18446744073709551615,"precise":9007199254740993.0,"signed":-9223372036854775808.0}""")
    val value = OHJson.Obj(initial.value()).set("futureEnvelope", unknown).encoded()
    val original = register(value)
    val saved = XperienceImportNamespace.read(initial.field, original)
    val edit = saved.replacement(document(), "Exact", saved.bindings)
    Checks.that(OHJson.Obj(edit.value()).raw("futureEnvelope").contentEquals(unknown), "bounded exact integer spellings are retained as raw unknown slices")
    val alternate = text(value.toString(Charsets.UTF_8).replace("9007199254740993.0", "9007199254740993").replace("-9223372036854775808.0", "-9223372036854775808"))
    Checks.that(edit.baselineMatches(register(alternate)), "real semantic canonicalizer compares equivalent exact integer spellings")
}

/** Adapted from the existing actual-expansion quota test; both inputs remain only a few KiB. */
private fun actualExpansionQuota() {
    val doc = document()
    val values = listOf(
        "00000000-0000-0000-0000-000000000601" to "00000000-0000-0000-0000-000000000611",
        "00000000-0000-0000-0000-000000000602" to "00000000-0000-0000-0000-000000000612",
    ).associate { (namespaceText, who) ->
        val id = UUID.fromString(namespaceText)
        val base = XperienceImportNamespace.append(doc, "Expanded", id).value()
        val numberArray = List(64) { "1e6" }.joinToString(prefix = "[", postfix = "]", separator = ",")
        val value = OHJson.Obj(base).set("futureExpansion", OHJson.literal(numberArray)).encoded()
        XperienceImportNamespace.field(id) to register(value, who = who)
    }
    val before = values.mapValues { it.value.copyOf() }
    val originalBytes = values.values.sumOf { it.size.toLong() }
    val oldTwoTimesRawCharge = 2L * originalBytes
    val actualRawAndCanonical = values.values.sumOf { raw -> raw.size.toLong() + XperienceCollections.canonicalRegisterData(raw).size }
    Checks.that(actualRawAndCanonical > oldTwoTimesRawCharge, "actual canonical expansion is charged, not a local JSON size guess")
    Checks.that(XperienceImportNamespace.readAll(values).size == 2, "small default-budget batch reads")
    val strict = XperienceImportNamespace.RetainedBudget(registerLimit = oldTwoTimesRawCharge)
    Checks.rejected(XperienceCollections.Failure.TOO_LARGE) { XperienceImportNamespace.readAll(values, strict) }
    Checks.that(values.all { (key, raw) -> raw.contentEquals(checkNotNull(before[key])) }, "quota failure does not mutate caller register bytes")
}

private fun concurrentOriginalObservations() {
    val initial = created(); val original = register(initial.value())
    val saved = XperienceImportNamespace.read(initial.field, original)
    val edits = listOf(saved.replacement(document(), "First", saved.bindings), saved.replacement(document(), "Second", saved.bindings))
    val host = AtomicReference(original)
    val wins = AtomicInteger(); val failure = AtomicReference<Throwable?>()
    val ready = CountDownLatch(2); val go = CountDownLatch(1)
    val workers = edits.map { edit -> Thread {
        try {
            ready.countDown(); check(go.await(3, TimeUnit.SECONDS))
            val observed = host.get()
            // This in-memory host seam uses the actual full-register baselineMatches, never a
            // shallow or alternate comparator. No retry recaptures a successor observation.
            if (edit.baselineMatches(observed)) {
                val proposed = register(edit.value(), 2)
                if (host.compareAndSet(observed, proposed)) wins.incrementAndGet()
            }
        } catch (problem: Throwable) { failure.compareAndSet(null, problem) }
    }.apply { isDaemon = true; start() } }
    try {
        check(ready.await(3, TimeUnit.SECONDS)); go.countDown()
        workers.forEach { it.join(3000); check(!it.isAlive) }
        Checks.that(failure.get() == null && wins.get() == 1, "two same-baseline edits have exactly one synthetic host CAS winner")
        Checks.that(edits.none { it.baselineMatches(host.get()) }, "both old observations are stale after winning field replacement")
        val reread = XperienceImportNamespace.read(initial.field, host.get())
        Checks.that(reread.label in setOf("First", "Second"), "winner is one intended replacement")
    } finally { go.countDown(); workers.forEach { it.interrupt(); it.join(250) } }
}

/** Future-format rejection is model evidence only; stored-format retention remains an external gate. */
private fun tombstonesNamespacesAndUnsupported() {
    val initial = created(); val original = register(initial.value())
    val tombstone = register(OHJson.literal("null"))
    val other = UUID.fromString("00000000-0000-0000-0000-000000000909")
    val fields = linkedMapOf(initial.field to original, XperienceImportNamespace.field(other) to tombstone,
        "unrelated.field" to OHJson.literal("true"))
    Checks.that(XperienceImportNamespace.readAll(fields).map { it.namespace } == listOf(namespace), "readAll skips admitted tombstones and unrelated field family")
    Checks.rejected(XperienceCollections.Failure.INVALID_NAMESPACE) { XperienceImportNamespace.read(XperienceImportNamespace.field(other), original) }
    Checks.rejected(XperienceCollections.Failure.INVALID_NAMESPACE) { XperienceImportNamespace.read(initial.field, tombstone) }
    val future = register(OHJson.Obj(initial.value()).set("schemaVersion", OHJson.literal("2")).encoded())
    val futureCopy = future.copyOf()
    Checks.rejected(XperienceCollections.Failure.UNSUPPORTED_SAVED_FORMAT) { XperienceImportNamespace.read(initial.field, future) }
    Checks.that(future.contentEquals(futureCopy), "pure future-format refusal leaves caller input unchanged")
    val missing = register(OHJson.Obj(initial.value()).remove("schemaVersion").encoded())
    Checks.rejected(XperienceCollections.Failure.INVALID_NAMESPACE) { XperienceImportNamespace.read(initial.field, missing) }
    Checks.rejected(XperienceCollections.Failure.INVALID_NAMESPACE) { XperienceImportNamespace.append(document(), " ", namespace) }
    Checks.rejected(XperienceCollections.Failure.INVALID_NAMESPACE) { XperienceImportNamespace.append(document(), "é".repeat(129), namespace) }
}

fun main() {
    runCase("read-replace-unknown-raw", ::roundTripReplaceUnknown)
    runCase("semantic-full-register-stale", ::semanticBaselineAndStaleCut)
    runCase("detached-observation-bytes", ::detachedOwnership)
    runCase("duplicate-precision-invalid-shortcut", ::duplicateKeysPrecisionAndInvalidShortcut)
    runCase("small-depth-unknown-cas", ::boundedDepthAndUnknownRawCas)
    runCase("exact-integer-unknown-conservation", ::exactIntegerRawConservation)
    runCase("actual-canonical-expansion-quota", ::actualExpansionQuota)
    runCase("concurrent-original-observations", ::concurrentOriginalObservations)
    runCase("tombstone-namespace-future-format", ::tombstonesNamespacesAndUnsupported)
    println("PASS namespace-public-api assertions=${Checks.count} cases=9 maxInputBytes=$MAX_SYNTHETIC_BYTES")
}
