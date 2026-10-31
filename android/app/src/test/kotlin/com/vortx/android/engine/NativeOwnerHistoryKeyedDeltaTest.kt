package com.vortx.android.engine

import org.junit.Assert.*
import org.junit.Test

/** Public wire-contract/raw-slice regression. Scripted deltas are not native/JNI acceptance. */
class NativeOwnerHistoryKeyedDeltaTest {
    private val id = "11111111-1111-4111-8111-111111111111"
    private fun b(s: String) = s.toByteArray(Charsets.UTF_8)
    private fun fails(block: () -> Unit) { try { block(); fail("Expected refusal") } catch (failure: AssertionError) { throw failure } catch (_: Exception) { } }
    private fun fence(instance: String = "parent", generation: String = "0") = OHJson.Obj()
        .set("scope", OHJson.quote("test-scope")).set("ownerProfileId", OHJson.quote(id))
        .set("profileId", OHJson.quote(id)).set("verifiedStreamingUid", OHJson.quote("test-uid"))
        .set("binding", b("{\"account\":{\"kind\":\"shared\"},\"revision\":0}"))
        .set("instanceId", OHJson.quote(instance)).set("mutationGeneration", OHJson.quote(generation))
        .set("sourceSetWitnessId", OHJson.quote("witness")).encoded()
    private fun seed(): OHState {
        val library = OHJson.Obj().set("futureLibrary", b("{\"wide\":18446744073709551615,\"zero\":-0.0}"))
        for (key in listOf("resume", "watched", "watchLog", "watchContexts")) library.set(key, b("{\"old\":1}"))
        for (key in listOf("items", "history", "continueWatching", "searchHistory", "cwBoard")) library.set(key, b("[\"old\",\"tail\"]"))
        library.set("resumeVault", b("{\"aliases\":{\"old\":1},\"entries\":{\"old\":1},\"futureVault\":-0.0}"))
        val watch = b("{\"log\":{\"old\":1},\"contexts\":{\"old\":1},\"identityLinks\":[\"old\",\"tail\"],\"futureWatch\":-0}")
        val native = OHJson.Obj().set("ownerHistory", b("{\"retainedSource\":18446744073709551615,\"zero\":-0.0}"))
            .set("futureNative", b("{\"zero\":-0.0}"))
            .set("watches", OHJson.Obj().set(id, watch).encoded())
            .set("accountSlots", OHJson.Obj().set(id, OHJson.Obj().set("activeBinding", b("{\"retained\":-0.0}"))
                .set("slots", OHJson.Obj().set("slot-a", OHJson.Obj().set("watch", watch).set("futureSlot", b("18446744073709551615")).encoded()).encoded()).encoded()).encoded())
        val root = OHJson.Obj().set("roster", b("{\"profiles\":{}}"))
            .set("libraries", OHJson.Obj().set(id, library.encoded()).set("unaffected", b("{\"future\":-0.0}")).encoded())
            .set("activeProfileId", OHJson.quote(id)).set("nativeSync", native.encoded())
            .set("futureRoot", b("{\"wide\":18446744073709551615,\"zero\":-0.0}"))
            .set("hostDocument", b("{\"raw\":-0.0}"))
        return OHState(root.encoded(), fence())
    }
    private fun edits(): ByteArray {
        val map = b("{\"old\":{\"op\":\"remove\"},\"new\":{\"op\":\"put\",\"value\":18446744073709551615}}")
        val span = b("{\"at\":0,\"remove\":1,\"insert\":[\"new\"]}")
        val library = OHJson.Obj()
        for (key in listOf("resume", "watched", "watchLog", "watchContexts", "aliases", "entries")) library.set(key, map)
        for (key in listOf("items", "history", "continueWatching", "searchHistory", "cwBoard")) library.set(key, span)
        val watch = OHJson.Obj().set("log", map).set("contexts", map).set("identityLinks", span).encoded()
        return OHJson.Obj().set("libraries", OHJson.Obj().set(id, library.encoded()).encoded())
            .set("nativeWatches", OHJson.Obj().set(id, watch).encoded())
            .set("slotWatches", OHJson.Obj().set(id, OHJson.Obj().set("slot-a", watch).encoded()).encoded()).encoded()
    }
    private fun reply(edits: ByteArray = edits(), base: String = "0", revision: String = "1", end: ByteArray = fence("candidate", "1")): OHJson.Obj {
        val step = OHJson.Obj().set("baseGeneration", OHJson.quote(base)).set("revision", OHJson.quote(revision)).set("edits", edits)
        return OHJson.Obj().set("kind", OHJson.quote("checkpoint_delta")).set("fence", end).set("preparedAgainst", fence())
            .set("deltaEncoding", OHJson.quote("keyed_rows/1")).set("keyedStateSteps", OHJson.array(listOf(step.encoded())))
            .set("reuseExactOwnerHistoryFromWitness", OHJson.quote("witness"))
            .set("requiresCompleteArchiveEnvelope", b("true")).set("durableAck", b("false"))
    }
    @Test fun allMutableEditFormsPreserveSourceUnknownsAndOriginalBase() {
        val initial = seed(); val before = initial.bytes(); val wire = reply().encoded()
        val applied = initial.delta(wire, fence(), true, fence("candidate", "1"))
        assertArrayEquals(applied.bytes(), initial.delta(wire, fence(), true, fence("candidate", "1")).bytes())
        assertArrayEquals(before, initial.bytes())
        val old = OHJson.Obj(before); val next = OHJson.Obj(applied.bytes())
        for (key in listOf("futureRoot", "hostDocument", "roster", "activeProfileId")) assertArrayEquals(old.raw(key), next.raw(key))
        assertArrayEquals(old.obj("libraries").raw("unaffected"), next.obj("libraries").raw("unaffected"))
        val library = next.obj("libraries").obj(id)
        assertArrayEquals(old.obj("libraries").obj(id).raw("futureLibrary"), library.raw("futureLibrary"))
        for (key in listOf("resume", "watched", "watchLog", "watchContexts")) assertTrue(OHJson.equal(b("{\"new\":18446744073709551615}"), library.raw(key)))
        for (key in listOf("items", "history", "continueWatching", "searchHistory", "cwBoard")) assertArrayEquals(b("[\"new\",\"tail\"]"), library.raw(key))
        for (key in listOf("aliases", "entries")) assertTrue(OHJson.equal(b("{\"new\":18446744073709551615}"), library.obj("resumeVault").raw(key)))
        assertArrayEquals(b("-0.0"), library.obj("resumeVault").raw("futureVault"))
        for (key in listOf("ownerHistory", "futureNative")) assertArrayEquals(old.obj("nativeSync").raw(key), next.obj("nativeSync").raw(key))
        val slots = next.obj("nativeSync").obj("accountSlots").obj(id)
        assertArrayEquals(b("{\"retained\":-0.0}"), slots.raw("activeBinding"))
        val slot = slots.obj("slots").obj("slot-a"); assertArrayEquals(b("18446744073709551615"), slot.raw("futureSlot"))
        for (watch in listOf(next.obj("nativeSync").obj("watches").obj(id), slot.obj("watch"))) {
            assertArrayEquals(b("-0"), watch.raw("futureWatch"))
            for (key in listOf("log", "contexts")) assertTrue(OHJson.equal(b("{\"new\":18446744073709551615}"), watch.raw(key)))
            assertArrayEquals(b("[\"new\",\"tail\"]"), watch.raw("identityLinks"))
        }
        fails { applied.delta(wire, fence(), true, fence("candidate", "1")) }
    }
    @Test fun negotiationAuthorityGenerationAndStrictShapeCannotBeBypassed() {
        val state = seed(); val before = state.bytes(); val correct = reply()
        fails { state.delta(correct.encoded(), fence()) }
        fails { state.delta(correct.encoded(), fence(), true, fence("other", "1")) }
        for (bad in listOf(
            reply(base = "1"), reply(revision = "2"), reply(end = fence("candidate", "2")),
            reply().set("preparedAgainst", fence("different-parent")), reply().set("durableAck", b("true")),
            reply().set("requiresCompleteArchiveEnvelope", b("false")), reply().set("reuseExactOwnerHistoryFromWitness", OHJson.quote("other")),
            reply().set("deltaEncoding", OHJson.quote("future/2")), reply().set("unexpected", b("1")),
            reply().set("fence", OHJson.Obj(fence("candidate", "1")).set("verifiedStreamingUid", OHJson.quote("other")).encoded()),
            reply().set("fence", OHJson.Obj(fence("candidate", "1")).set("profileId", OHJson.quote("other")).encoded()),
            reply().set("fence", OHJson.Obj(fence("candidate", "1")).set("binding", b("{}")).encoded()),
            reply().set("fence", OHJson.Obj(fence("candidate", "1")).set("scope", OHJson.quote("other")).encoded()),
            reply().set("fence", OHJson.Obj(fence("candidate", "1")).set("sourceSetWitnessId", OHJson.quote("other")).encoded())
        )) fails { state.delta(bad.encoded(), fence(), true) }
        assertArrayEquals(before, state.bytes())
    }
    @Test fun invalidOperationsTopologySpansAndUnicodeIdentityRefuseWithoutChangingBase() {
        val state = seed(); val before = state.bytes()
        fun badLibrary(raw: String) = reply(OHJson.Obj().set("libraries", OHJson.Obj().set(id, b(raw)).encoded())
            .set("nativeWatches", b("{}")).set("slotWatches", b("{}")).encoded()).encoded()
        for (bad in listOf("{\"unknown\":{}}", "{\"resume\":{\"missing\":{\"op\":\"remove\"}}}",
            "{\"resume\":{\"old\":{\"op\":\"put\"}}}", "{\"resume\":{\"old\":{\"op\":\"remove\",\"value\":1}}}",
            "{\"resume\":{\"old\":{\"op\":\"clear\"}}}", "{\"items\":{\"at\":3,\"remove\":0,\"insert\":[]}}",
            "{\"items\":{\"at\":1,\"remove\":2,\"insert\":[]}}", "{\"items\":{\"at\":-1,\"remove\":0,\"insert\":[]}}")) {
            fails { state.delta(badLibrary(bad), fence(), true) }
        }
        val unknownRow = OHJson.Obj().set("libraries", b("{\"absent\":{}}"))
            .set("nativeWatches", b("{}")).set("slotWatches", b("{}"))
        fails { state.delta(reply(unknownRow.encoded()).encoded(), fence(), true) }
        val root = OHJson.Obj(before); val library = root.obj("libraries").obj(id)
        library.set("resume", b("{\"é\":1,\"value\":2}")); root.set("libraries", OHJson.Obj().set(id, library.encoded()).encoded())
        val unicode = OHState(root.encoded(), fence())
        fails { unicode.delta(badLibrary("{\"resume\":{\"é\":{\"op\":\"put\",\"value\":3}}}"), fence(), true) }
        val valuePut = unicode.delta(badLibrary("{\"resume\":{\"other\":{\"op\":\"put\",\"value\":3}}}"), fence(), true)
        assertArrayEquals(b("2"), OHJson.Obj(valuePut.bytes()).obj("libraries").obj(id).obj("resume").raw("value"))
        assertArrayEquals(before, state.bytes())
    }
    @Test fun emptyJournalAndUnsignedCounterLimitsKeepExactEligibility() {
        val state = seed(); val empty = reply(end = fence("candidate", "0")).set("keyedStateSteps", b("[]"))
        assertTrue(OHJson.equal(state.bytes(), state.delta(empty.encoded(), fence(), true).bytes()))
        val emptyEdits = b("{\"libraries\":{},\"nativeWatches\":{},\"slotWatches\":{}}")
        val max = "18446744073709551615"; val previous = "18446744073709551614"
        val parent = fence(generation = previous); val maxState = OHState(state.bytes(), parent)
        val next = reply(emptyEdits, previous, max, fence("candidate", max)).set("preparedAgainst", parent)
        assertTrue(OHJson.equal(maxState.bytes(), maxState.delta(next.encoded(), parent, true).bytes()))
        for (bad in listOf("01", "-1", "18446744073709551616")) fails { state.delta(reply(base = bad).encoded(), fence(), true) }
        val tooMany = reply(emptyEdits).set("keyedStateSteps", OHJson.array(List(513) { OHJson.Obj().set("baseGeneration", OHJson.quote("0"))
            .set("revision", OHJson.quote("1")).set("edits", emptyEdits).encoded() }))
        fails { state.delta(tooMany.encoded(), fence(), true) }
    }
}
