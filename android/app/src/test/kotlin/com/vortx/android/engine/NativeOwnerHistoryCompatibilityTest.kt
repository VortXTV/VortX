package com.vortx.android.engine

import org.junit.Assert.*
import org.junit.Test

/** Authored, UNRUN. Protocol fixture tests exercise the production coordinator, not a native substitute proof. */
class NativeOwnerHistoryCompatibilityTest {
    private val scope = VortxAccountScope("account-test", "11111111-1111-4111-8111-111111111111")
    private val target get() = NativeOwnerHistoryCoordinator.Target(scope.ownerProfileID, "owner-uid")
    private fun b(s: String) = s.toByteArray(Charsets.UTF_8)
    private fun fails(block: () -> Unit) { try { block(); fail("Expected refusal") } catch (failure: AssertionError) { throw failure } catch (_: Exception) { } }
    private class Authority : NativeOwnerHistoryAuthority {
        var active = true; var checks = 0
        override fun <T> withActive(block: () -> T): T { check(active); checks++; val result = block(); check(active); return result }
    }

    @Test fun rawUnknownNumbersAndNegativeZeroSurviveOwnedReplacement() {
        val source = b("{\"future\":{\"wide\":18446744073709551615,\"zero\":-0.0},\"nativeSync\":{\"schemaVersion\":5}}")
        val account = NativeOwnerHistoryAccount(source)
        val replaced = account.replacingOwned(mapOf("nativeProviderCredentials" to b("{}")))
        assertArrayEquals(account.raw("future"), replaced.raw("future"))
        fails { account.replacingOwned(mapOf("future" to b("{}"))) }
    }
    @Test fun strictRawAdmissionRejectsDuplicateUnicodeAndMalformedNumbers() {
        fails { OHJson.Obj(b("{\"a\":1,\"\\u0061\":2}")) }
        fails { OHJson.Obj(b("{\"é\":1,\"é\":2}")) }
        fails { OHJson.Obj(b("{\"n\":01}")) }
        fails { OHJson.Obj(byteArrayOf(123, 34, -1, 34, 58, 48, 125)) }
        assertFalse(OHJson.equal(b("-0.0"), b("0.0")))
    }
    @Test fun schemaFivePendingCarrierIsLocalOnly() {
        val local = NativeOwnerHistorySources.empty(scope).local()
        val carrier = NativeOwnerHistorySources.carrier(local, scope, "owner-uid")
        val account = NativeOwnerHistoryAccount(OHJson.Obj().set("nativeSync", b("{\"schemaVersion\":5}"))
            .set(NativeOwnerHistoryAccount.ARCHIVE, carrier).set("future", b("-0")).encoded())
        assertNotNull(account.raw(NativeOwnerHistoryAccount.ARCHIVE))
        assertNull(NativeOwnerHistoryAccount(account.cloudPlaintext(true)).raw(NativeOwnerHistoryAccount.ARCHIVE))
        assertArrayEquals(b("-0"), NativeOwnerHistoryAccount(account.cloudPlaintext(true)).raw("future"))
        fails { NativeOwnerHistoryAccount(b("{\"nativeSync\":{\"schemaVersion\":6,\"ownerHistory\":{}}}")).cloudPlaintext(true) }
    }
    @Test fun presentationNeverExposesOrNormalizesUnknownRoots() {
        val initial = snapshot().set("future", b("{\"n\":18446744073709551615,\"z\":-0.0}"))
            .set("hostDocument", b("{\"future\":-0.0}"))
        val state = OHState(initial.encoded(), fence("one"))
        val view = OHJson.Obj(state.presentation()); assertNull(view["future"]); assertNull(view["hostDocument"])
        val changed = state.localState(view.set("hostProfileSyncPending", b("true")).encoded())
        assertArrayEquals(initial.raw("future"), OHJson.Obj(changed.bytes()).raw("future"))
        assertArrayEquals(initial.raw("hostDocument"), OHJson.Obj(changed.bytes()).raw("hostDocument"))
        fails { state.localState(OHJson.Obj(state.presentation()).set("future", b("0")).encoded()) }
        fails { state.localState(OHJson.Obj(state.presentation()).set("hostDocument", b("{\"future\":0.0}")).encoded()) }
    }
    @Test fun witnessBoundDeltaRetainsExactSourceAndUnknowns() {
        val initial = snapshot(); val n = initial.obj("nativeSync").set("future", b("18446744073709551615")).set("ownerHistory", b("{\"z\":-0.0}"))
        initial.set("nativeSync", n.encoded()); val parent = fence("one")
        val state = OHState(initial.encoded(), parent)
        val delta = OHJson.Obj().set("kind", OHJson.quote("checkpoint_delta")).set("durableAck", b("false"))
            .set("requiresCompleteArchiveEnvelope", b("true")).set("preparedAgainst", parent).set("fence", parent)
            .set("reuseExactOwnerHistoryFromWitness", OHJson.quote("witness")).set("delta", b("{\"nativeSync\":{\"schemaVersion\":6}}"))
        val next = OHJson.Obj(state.delta(delta.encoded(), parent).native())
        assertArrayEquals(n.raw("ownerHistory"), next.raw("ownerHistory")); assertArrayEquals(n.raw("future"), next.raw("future"))
        fails { state.delta(delta.set("reuseExactOwnerHistoryFromWitness", OHJson.quote("other")).encoded(), parent) }
    }
    @Test fun coldNativeNormalizationRetainsOmittedUnknownsAndRejectsKnownOrSourceDrift() {
        val original = snapshot(); val raw = original.obj("nativeSync")
            .set("future", b("{\"wide\":18446744073709551615,\"zero\":-0.0}"))
            .set("ownerHistory", b("{\"retainedProof\":-0.0}"))
        original.set("nativeSync", raw.encoded())
        val normalized = snapshot(); val native = normalized.obj("nativeSync").set("ownerHistory", raw.raw("ownerHistory"))
        normalized.set("nativeSync", native.encoded())
        OHState.requireColdNativeConservation(raw.encoded(), native.encoded())
        val complete = OHState(original.encoded(), fence("one")).full(normalized.encoded(), fence("one"))
        assertArrayEquals(raw.raw("future"), OHJson.Obj(complete.native()).raw("future"))
        assertArrayEquals(raw.raw("ownerHistory"), OHJson.Obj(complete.native()).raw("ownerHistory"))
        fails { OHState.requireColdNativeConservation(raw.encoded(), native.copy().set("schemaVersion", b("6")).encoded()) }
        fails { OHState.requireColdNativeConservation(raw.encoded(), native.copy().set("ownerHistory", b("{\"retainedProof\":0.0}")).encoded()) }
        fails { OHState.requireColdNativeConservation(raw.encoded(), native.copy().set("future", b("{}")).encoded()) }
    }
    @Test fun warmPeerUnknownSiblingsSurviveNormalizationAndCollisionsRefuseBeforeFork() {
        val localUnknown = b("{\"localOnly\":-0.0,\"sharedFuture\":18446744073709551615}")
        val fixture = Fixture(localUnknown)
        val incoming = snapshot().obj("nativeSync").set("peerOnly", b("{\"zero\":-0,\"wide\":18446744073709551615}"))
            .set("sharedFuture", b("18446744073709551615"))
        val peer = NativeOwnerHistoryAccount(OHJson.Obj().set("nativeSync", incoming.encoded()).encoded())
        val capture = fixture.owner.capture(target, fixture.authority)
        val candidate = fixture.owner.peerCandidate(peer, capture,
            NativeOwnerHistoryCoordinator.Transaction(peer, fixture.authority) { })
        val accepted = fixture.owner.commit(candidate, b("{}"))
        val retained = NativeOwnerHistoryAccount(accepted.accountBase).raw("nativeSync")!!
        val after = OHJson.Obj(retained)
        assertArrayEquals(b("-0.0"), after.raw("localOnly"))
        assertArrayEquals(incoming.raw("peerOnly"), after.raw("peerOnly"))
        assertArrayEquals(incoming.raw("sharedFuture"), after.raw("sharedFuture"))
        val nextCapture = fixture.owner.capture(target, fixture.authority)
        val beforeFork = fixture.native.next
        val conflict = NativeOwnerHistoryAccount(OHJson.Obj().set("nativeSync",
            incoming.copy().set("sharedFuture", b("18446744073709551614")).encoded()).encoded())
        fails { fixture.owner.peerCandidate(conflict, nextCapture, fixture.transaction) }
        assertEquals(beforeFork, fixture.native.next)
        assertArrayEquals(retained, NativeOwnerHistoryAccount(fixture.owner.checkpoint(nextCapture).accountBase).raw("nativeSync"))
        assertTrue(fixture.owner.close())
    }
    @Test fun fullAccountUnknownCarrierDoesNotInheritOverlayNodeBudget() {
        val large = "[" + List(100_001) { "0" }.joinToString(",") + "]"
        val raw = b("{\"future\":$large,\"number\":18446744073709551615,\"vortx\":{\"byProfile\":{}}}")
        val parsed = NativeProfileOverlayWitness.parseAccountDocument(raw)
        assertEquals(100_001, parsed.getJSONArray("future").length())
        assertEquals("18446744073709551615", parsed.get("number").toString())
        fails { NativeProfileOverlayWitness.parseDocument(raw) }
        fails { NativeProfileOverlayWitness.parseAccountDocument(b("{\"vortx\":{\"byProfile\":{\"${scope.ownerProfileID}\":{\"future\":$large}}}}")) }
    }
    @Test fun sourceReplayDerivesMovieMembershipAndProgressFromOriginalBytes() {
        val raw = source("[{\"_id\":\"opaque\",\"type\":\"movie\",\"name\":\"Film\",\"state\":{\"timeOffset\":1234,\"duration\":5000,\"lastWatched\":\"2026-01-01T00:00:00.125Z\",\"flaggedWatched\":1}}]")
        val archive = archive(raw); val authority = Authority()
        val evidence = OHJson.Obj(NativeOwnerHistorySources.replay(archive, scope, scope.ownerProfileID, "owner-uid", authority))
        assertEquals(OHJson.sha(raw), evidence.text("sourceDocumentSha256")); assertEquals(OHJson.sha(archive), evidence.text("sourceArchiveSha256"))
        val watch = OHJson.Obj(OHJson.array(evidence.raw("watches")).single())
        assertEquals("opaque", watch.text("metaId")); assertEquals(1234L, OHJson.integer(watch.raw("positionMs")))
        assertEquals("true", OHJson.utf8(watch.raw("watched"))); assertTrue(authority.checks > 2)
    }
    @Test fun removedSourceDoesNotInventMembershipTombstone() {
        val evidence = OHJson.Obj(NativeOwnerHistorySources.replay(archive(source("[{\"_id\":\"saved\",\"type\":\"movie\",\"removed\":true}]")), scope, scope.ownerProfileID, "owner-uid", Authority()))
        assertTrue(OHJson.array(evidence.obj("library").raw("items")).isEmpty())
        assertTrue(OHJson.array(evidence.obj("library").raw("intents")).isEmpty())
    }
    @Test fun sourcePrivacyAndRetirementCannotBecomeReceipt() {
        for (extra in listOf("\"secretKey\":\"x\"", "\"futureCredentials\":{}", "\"nativeProviderCredentials\":{}", "\"nested\":\"{bad\"")) {
            fails { NativeOwnerHistorySources.replay(archive(source("[{\"_id\":\"x\",\"type\":\"movie\",$extra}]")), scope, scope.ownerProfileID, "owner-uid", Authority()) }
        }
        val authority = Authority().also { it.active = false }
        fails { NativeOwnerHistorySources.replay(archive(source("[]")), scope, scope.ownerProfileID, "owner-uid", authority) }
    }
    @Test fun pendingRecordCannotAcquireNewBindingOnUnion() {
        fun local(binding: Int): ByteArray {
            val pending = OHJson.Obj().set("schemaVersion", b("1")).set("kind", OHJson.quote("vortx.owner-history.pending/1"))
                .set("sourceDocumentBase64", OHJson.quote(OHJson.b64(source("[]")))).set("metadataEvidenceBase64", b("[]"))
                .set("metadataPendingBase64", b("[]")).set("heldProjectionKinds", b("[]")).encoded()
            val record = OHJson.Obj().set("archiveBase64", OHJson.quote(OHJson.b64(pending))).set("capturedBinding", b("{\"revision\":$binding}")).encoded()
            return OHJson.Obj(NativeOwnerHistorySources.empty(scope).local()).set("pending", OHJson.Obj().set(OHJson.sha(pending), record).encoded()).encoded()
        }
        val first = NativeOwnerHistorySources.fromLocal(scope, local(1)); val second = NativeOwnerHistorySources.fromLocal(scope, local(2))
        fails { first.joining(second) }
        assertArrayEquals(first.local(), first.joining(NativeOwnerHistorySources.empty(scope)).local())
    }
    @Test fun exactDurableReadbackPrecedesNativeAcceptance() {
        val fixture = Fixture(); val c = fixture.owner.capture(target, fixture.authority)
        val candidate = fixture.owner.candidate(c, fixture.transaction)
        fixture.owner.commit(candidate, b("{}"))
        assertEquals(listOf("persist", "accept"), fixture.native.order)
        assertFalse(fixture.owner.requiresAuthenticatedReopen); assertTrue(fixture.owner.close())
    }
    @Test fun persistenceFailureHasNoNativeAcceptAndPoisonsOwner() {
        val fixture = Fixture(); fixture.failPersist = true
        val c = fixture.owner.capture(target, fixture.authority); val candidate = fixture.owner.candidate(c, fixture.transaction)
        fails { fixture.owner.commit(candidate, b("{}")) }
        assertEquals(listOf("persist"), fixture.native.order); assertTrue(fixture.owner.requiresAuthenticatedReopen)
        candidate.close(); fixture.owner.close()
    }
    @Test fun staleOriginalReadRefusesBeforePersistence() {
        val fixture = Fixture(); val capture = fixture.owner.capture(target, fixture.authority)
        fixture.authority.active = false
        fails { fixture.owner.candidate(capture, fixture.transaction) }
        assertTrue(fixture.native.order.isEmpty()); fixture.owner.close()
    }
    @Test fun explicitActionRejectionDoesNotCheckpointOrAcknowledge() {
        val fixture = Fixture(); val c = fixture.owner.capture(target, fixture.authority); val candidate = fixture.owner.candidate(c, fixture.transaction)
        assertEquals("false", OHJson.utf8(OHJson.Obj(candidate.dispatch(b("{\"type\":\"invalid\"}"), 1)).raw("ok")))
        assertTrue(fixture.native.order.isEmpty()); assertTrue(candidate.close()); assertTrue(fixture.owner.close())
    }
    @Test fun failedForkRetirementRemainsStickyAfterCurrentCloseSucceeds() {
        val fixture = Fixture(); val c = fixture.owner.capture(target, fixture.authority); val candidate = fixture.owner.candidate(c, fixture.transaction)
        fixture.native.failCloseHandle = 2
        assertFalse(candidate.close()); assertTrue(fixture.owner.requiresAuthenticatedReopen)
        assertFalse(fixture.owner.close()) // Current handle success cannot erase orphaned child.
    }
    @Test fun stagedPlaybackProofIsSameTargetAndNeverPublished() {
        val fixture = Fixture(); val c = fixture.owner.capture(target, fixture.authority)
        val candidate = fixture.owner.candidate(c, fixture.transaction)
        val query = OHJson.Obj().set("kind", OHJson.quote("profile_playback")).set("profileId", OHJson.quote(scope.ownerProfileID))
        assertEquals(scope.ownerProfileID, OHJson.Obj(candidate.resolve(query.encoded())).text("profileId"))
        fails { candidate.resolve(query.set("profileId", OHJson.quote("22222222-2222-4222-8222-222222222222")).encoded()) }
        assertTrue(fixture.native.order.isEmpty()); assertTrue(candidate.close()); assertTrue(fixture.owner.close())
    }

    private fun snapshot() = OHJson.Obj().set("roster", OHJson.Obj().set("profiles", OHJson.Obj().set(scope.ownerProfileID,
        b("{\"id\":\"${scope.ownerProfileID}\",\"owner\":true,\"deleted\":false,\"account\":{\"kind\":\"shared\"}}")).encoded()).encoded())
        .set("libraries", b("{}")).set("activeProfileId", OHJson.quote(scope.ownerProfileID))
        .set("nativeSync", b("{\"schemaVersion\":5,\"scope\":\"${scope.accountID}\",\"ownerProfileId\":\"${scope.ownerProfileID}\",\"profiles\":{},\"addons\":{},\"libraries\":{},\"watches\":{}}"))
    private fun fence(instance: String) = OHJson.Obj().set("scope", OHJson.quote(scope.accountID)).set("ownerProfileId", OHJson.quote(scope.ownerProfileID))
        .set("profileId", OHJson.quote(scope.ownerProfileID)).set("verifiedStreamingUid", OHJson.quote("owner-uid"))
        .set("binding", b("{\"account\":{\"kind\":\"shared\"},\"revision\":0,\"transactionId\":null}"))
        .set("instanceId", OHJson.quote(instance)).set("mutationGeneration", OHJson.quote("0")).set("sourceSetWitnessId", OHJson.quote("witness")).encoded()
    private fun source(rows: String) = OHJson.Obj().set("schemaVersion", b("1")).set("kind", OHJson.quote("vortx.owner-history.source/1"))
        .set("scope", OHJson.quote(scope.accountID)).set("ownerProfileId", OHJson.quote(scope.ownerProfileID)).set("profileId", OHJson.quote(scope.ownerProfileID))
        .set("verifiedStreamingUid", OHJson.quote("owner-uid")).set("libraryResponseBase64", OHJson.quote(OHJson.b64(b("{\"result\":$rows}"))))
        .set("addonsResponseBase64", OHJson.quote(OHJson.b64(b("{\"result\":{\"addons\":[]}}")))).encoded()
    private fun archive(source: ByteArray) = OHJson.Obj().set("schemaVersion", b("1")).set("kind", OHJson.quote("vortx.owner-history.archive/1"))
        .set("sourceDocumentBase64", OHJson.quote(OHJson.b64(source))).set("metadataEvidenceBase64", b("[]")).encoded()

    private inner class Fixture(unknownNative: ByteArray? = null) {
        private val initial = snapshot().also { root -> unknownNative?.let { raw ->
            val native = root.obj("nativeSync"); val unknown = OHJson.Obj(raw)
            unknown.keys.forEach { native.setFrom(unknown, it) }; root.set("nativeSync", native.encoded())
        } }
        val authority = Authority(); val issuer = Any(); val native = ProtocolFixture(); var failPersist = false
        var read = NativeCheckpointRead(OHJson.utf8(initial.encoded()), issuer, scope, 0, byteArrayOf(0))
        val account = NativeOwnerHistoryAccount(OHJson.Obj().set("nativeSync", initial.raw("nativeSync")).set("future", b("-0.0")).encoded())
        val transaction = NativeOwnerHistoryCoordinator.Transaction(account, authority) { NativeOwnerHistoryAccount(it).validateBudget(true) }
        val owner = NativeOwnerHistoryCoordinator.open(scope, target,
            NativeOwnerHistoryCoordinator.Checkpoint(scope, initial.encoded(), b("{}"), NativeOwnerHistorySources.empty(scope).local(), account.encoded(), "owner-uid"),
            read, native, authority, { require(it === read) }, { expected, bytes ->
                require(expected === read); native.order += "persist"; check(!failPersist)
                NativeCheckpointRead(OHJson.utf8(bytes), issuer, scope, 1, byteArrayOf(1)).also { read = it }
            }, { NativeOwnerHistoryCoordinator.HostProjection(b("{}"), b("{}")) })
    }
    /** Scripted protocol receipts only; no copied kernel reducer or archive interpretation. */
    private inner class ProtocolFixture : NativeOwnerHistoryBindings {
        var next = 1L; var failCloseHandle = -1L; val parents = mutableMapOf<Long, ByteArray?>(); val order = mutableListOf<String>()
        override fun canonicalize(evidence: ByteArray): ByteArray? = error("Unexpected canonicalizer in source-free fixture")
        override fun open(snapshot: ByteArray, verifier: NativeOwnerHistoryVerifier): Long {
            for (purpose in listOf("session_open_input", "session_open_normalized")) check(verifier.verify(OHJson.Obj().set("kind", OHJson.quote("full"))
                .set("check", OHJson.Obj().set("contract", OHJson.quote("vortx.owner-history-complete-archive/1")).set("purpose", OHJson.quote(purpose)).set("candidateState", snapshot).encoded()).encoded()))
            val handle = next++; parents[handle] = null; return handle
        }
        private fun lease(handle: Long, f: ByteArray, purpose: String) = OHJson.Obj().set("kind", OHJson.quote("lease"))
            .set("check", OHJson.Obj().set("contract", OHJson.quote("vortx.owner-history-session-lease/1")).set("purpose", OHJson.quote(purpose))
                .set("fence", f).set("preparedAgainst", parents[handle] ?: b("null")).encoded()).encoded()
        override fun fork(handle: Long, fence: ByteArray, verifier: NativeOwnerHistoryVerifier): Long {
            check(verifier.verify(lease(handle, fence, "fork")))
            val child = next++; parents[child] = fence.copyOf(); return child
        }
        override fun request(handle: Long, json: ByteArray, now: Long, verifier: NativeOwnerHistoryVerifier): ByteArray {
            val r = OHJson.Obj(json); val f = fence(handle.toString()); val kind = r.text("kind")
            check(verifier.verify(lease(handle, f, if (kind == "accept") "checkpoint_accepted" else kind)))
            return when (kind) {
                "merge" -> {
                    val full = OHJson.Obj().set("kind", OHJson.quote("full")).set("check", OHJson.Obj()
                        .set("contract", OHJson.quote("vortx.owner-history-complete-archive/1"))
                        .set("purpose", OHJson.quote("session_merge_peer")).set("peer", r.raw("peer"))
                        .set("incomingNative", r.raw("document")).set("candidateState", snapshot().encoded()).encoded())
                    check(verifier.verify(full.encoded()))
                    OHJson.Obj().set("kind", OHJson.quote("source_candidate")).set("instanceId", OHJson.quote(handle.toString()))
                        .set("mutationGeneration", OHJson.quote("0")).set("sourceSetWitnessId", OHJson.quote("witness"))
                        .set("activeTarget", OHJson.Obj().set("profileId", OHJson.quote(scope.ownerProfileID))
                            .set("binding", OHJson.Obj(f).raw("binding")).encoded()).encoded()
                }
                "checkpoint" -> OHJson.Obj().set("kind", OHJson.quote("checkpoint")).set("fence", f)
                    .set("state", snapshot().encoded()).set("durableAck", b("false"))
                    .set("requiresCompleteArchiveEnvelope", b("true")).encoded()
                "capture" -> OHJson.Obj().set("kind", OHJson.quote("capture")).set("fence", f).set("advertise", b("false")).encoded()
                "checkpoint_delta" -> OHJson.Obj().set("kind", OHJson.quote(kind)).set("fence", f).set("preparedAgainst", requireNotNull(parents[handle]))
                    .set("reuseExactOwnerHistoryFromWitness", OHJson.quote("witness")).set("delta", b("{}"))
                    .set("durableAck", b("false")).set("requiresCompleteArchiveEnvelope", b("true")).encoded()
                "accept" -> { order += "accept"; parents[handle] = null; OHJson.Obj().set("kind", OHJson.quote("accepted")).set("fence", f).set("durableAck", b("false")).encoded() }
                "dispatch" -> OHJson.Obj().set("kind", OHJson.quote("action_rejected")).set("fence", f).set("preparedAgainst", requireNotNull(parents[handle]))
                    .set("reason", OHJson.quote("native_action_rejected")).set("durableAck", b("false")).set("advertise", b("false")).encoded()
                "resolve_candidate" -> OHJson.Obj().set("kind", OHJson.quote("resolved_candidate")).set("fence", f)
                    .set("result", r.raw("request")).set("durableAck", b("false")).set("advertise", b("false")).encoded()
                else -> error("Unexpected scripted request")
            }
        }
        override fun close(handle: Long) = handle != failCloseHandle
    }
}
