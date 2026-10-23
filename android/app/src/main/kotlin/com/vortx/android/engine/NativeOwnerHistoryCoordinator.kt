package com.vortx.android.engine

import java.util.UUID
import org.json.JSONObject

/** Owned exclusively by the existing Session serialization lane. No queue, fetch or fallback. */
internal class NativeOwnerHistoryCoordinator private constructor(
    val scope: VortxAccountScope, private val bindings: NativeOwnerHistoryBindings,
    private var runtime: NativeOwnerHistoryRuntime, private var state: OHState,
    private var installed: NativeCheckpointRead, private var current: Checkpoint,
    private var sources: NativeOwnerHistorySources,
    private val requireCurrent: (NativeCheckpointRead) -> Unit,
    private val persist: (NativeCheckpointRead, ByteArray) -> NativeCheckpointRead,
    private val hostProjection: (ByteArray) -> HostProjection,
) {
    class Uncertain(cause: Throwable? = null) : IllegalStateException("Owner history checkpoint or retirement uncertain", cause)
    data class Target(val profileID: String, val verifiedUID: String) {
        init { require(UUID.fromString(profileID).toString().uppercase() == profileID); OHJson.uid(verifiedUID) }
    }
    class HostProjection(document: ByteArray, profileEditResults: ByteArray) {
        private val doc = document.copyOf(); private val results = profileEditResults.copyOf()
        val document get() = doc.copyOf(); val profileEditResults get() = results.copyOf()
        init { OHJson.Obj(doc); OHJson.Obj(results) }
    }
    class Checkpoint(val scope: VortxAccountScope, snapshot: ByteArray, hostPreferences: ByteArray,
                     localArchive: ByteArray, accountBase: ByteArray, val readOwnerUID: String) {
        private val rawSnapshot = snapshot.copyOf(); private val host = hostPreferences.copyOf()
        private val local = localArchive.copyOf(); private val account = accountBase.copyOf()
        val snapshot get() = rawSnapshot.copyOf(); val hostPreferences get() = host.copyOf()
        val localArchive get() = local.copyOf(); val accountBase get() = account.copyOf()
        init { OHJson.Obj(rawSnapshot); OHJson.Obj(host); NativeOwnerHistorySources.fromLocal(scope, local); NativeOwnerHistoryAccount(account); OHJson.uid(readOwnerUID) }
        fun envelope(): ByteArray = OHJson.Obj().set("kind", OHJson.quote(ENVELOPE)).set("schemaVersion", OHJson.literal("1"))
            .set("scope", OHJson.quote(scope.accountID)).set("ownerProfileId", OHJson.quote(scope.ownerProfileID))
            .set("snapshotBase64", OHJson.quote(OHJson.b64(rawSnapshot))).set("hostPreferencesBase64", OHJson.quote(OHJson.b64(host)))
            .set("localArchiveBase64", OHJson.quote(OHJson.b64(local))).set("accountBaseBase64", OHJson.quote(OHJson.b64(account)))
            .set("readOwnerUID", OHJson.quote(readOwnerUID)).encoded()
    }
    class Transaction(val account: NativeOwnerHistoryAccount, val authority: NativeOwnerHistoryAuthority,
                      val budget: (ByteArray) -> Unit)
    class Capture private constructor(internal val owner: NativeOwnerHistoryCoordinator, internal val runtime: NativeOwnerHistoryRuntime,
        internal val fence: ByteArray, internal val target: Target, internal val authority: NativeOwnerHistoryAuthority) {
        companion object { internal fun create(owner: NativeOwnerHistoryCoordinator, runtime: NativeOwnerHistoryRuntime,
            fence: ByteArray, target: Target, authority: NativeOwnerHistoryAuthority) = Capture(owner, runtime, fence.copyOf(), target, authority) }
    }
    private var closed = false; private var uncertain = false; private var unconfirmedRetirement = false
    private var retirementResult: Boolean? = null
    val requiresAuthenticatedReopen get() = closed || uncertain || unconfirmedRetirement
    private fun usable() { check(!requiresAuthenticatedReopen) { "Owner history requires authenticated reopen" }; check(!Thread.currentThread().isInterrupted) }
    private fun check(c: Capture) {
        usable(); require(c.owner === this && c.runtime === runtime && OHState.sameGeneration(c.fence, state.fence)) { "Original owner read retired" }
    }
    private fun requireCapture(c: Capture) { check(c); c.authority.withActive { requireCurrent(installed) } }
    private fun retire(r: NativeOwnerHistoryRuntime): Boolean {
        val result = r.close()
        if (!result) { unconfirmedRetirement = true; uncertain = true; synchronized(RETAINED) { RETAINED.add(r) } }
        return result
    }
    fun close(): Boolean {
        retirementResult?.let { return it && !unconfirmedRetirement }
        closed = true; val result = retire(runtime) && !unconfirmedRetirement; retirementResult = result; return result
    }
    fun capture(target: Target, originalAuthority: NativeOwnerHistoryAuthority): Capture {
        usable(); originalAuthority.withActive { requireCurrent(installed) }
        val verifier = Verify(scope, target, current.readOwnerUID, originalAuthority, bindings, sources,
            Mode.RETARGET, expected = state.fence)
        val fence = captureNative(runtime, verifier)
        state = state.retarget(fence)
        originalAuthority.withActive { requireCurrent(installed) }
        return Capture.create(this, runtime, fence, verifier.target, originalAuthority)
    }
    fun checkpoint(capture: Capture): Checkpoint { requireCapture(capture); return current }
    fun stateForPresentation(capture: Capture): ByteArray { requireCapture(capture); return state.presentation() }
    fun validatePresentation(capture: Capture): ByteArray = stateForPresentation(capture)
    fun read(kind: String, capture: Capture, extra: Map<String, ByteArray> = emptyMap()): ByteArray {
        requireCapture(capture); require(kind in setOf("lookup", "view", "resolve"))
        val v = Verify(scope, capture.target, current.readOwnerUID, capture.authority, bindings, sources, Mode.FIXED, capture.fence)
        val reply = response(runtime.request(request(kind, capture.fence, extra), 0, v.callback))
        require(reply.text("kind") == if (kind == "resolve") "resolved" else kind)
        require(OHJson.equal(reply.raw("fence"), capture.fence)); requireCapture(capture); return reply.encoded()
    }
    fun candidate(capture: Capture, transaction: Transaction): Candidate = makeCandidate(capture, transaction, sources, null)
    fun peerCandidate(peerAccount: NativeOwnerHistoryAccount, capture: Capture, transaction: Transaction): Candidate {
        requireCapture(capture); val peer = peer(peerAccount, scope)
        val authority = pair(capture.authority, transaction.authority)
        peer.sources.validate(OHJson.Obj().set("nativeSync", peer.native).encoded(), bindings, authority)
        val next = makeCandidate(capture, transaction, sources.joining(peer.sources), peer)
        try { next.merge(); return next } catch (failure: Throwable) { next.close(); throw failure }
    }
    private fun makeCandidate(c: Capture, tx: Transaction, nextSources: NativeOwnerHistorySources, peer: Peer?): Candidate {
        requireCapture(c); val authority = pair(c.authority, tx.authority)
        // Reject raw unknown-field collisions before allocating or publishing a native fork.
        val base = state.retarget(c.fence).let { if (peer == null) it else it.preservingPeerNative(peer.native) }
        val parent = Verify(scope, c.target, current.readOwnerUID, authority, bindings, sources, Mode.FIXED, c.fence)
        val fork = runtime.fork(c.fence, parent.callback)
        try {
            val v = Verify(scope, c.target, current.readOwnerUID, authority, bindings, nextSources, Mode.FORK, c.fence, peer = peer)
            val f = captureNative(fork, v)
            return Candidate(this, c, tx, nextSources, peer, fork, v, base, f)
        } catch (failure: Throwable) { if (!retire(fork)) throw Uncertain(failure); throw failure }
    }
    class Candidate internal constructor(private val owner: NativeOwnerHistoryCoordinator, internal val capture: Capture,
        internal val transaction: Transaction, internal val nextSources: NativeOwnerHistorySources,
        internal val peer: Peer?, internal val native: NativeOwnerHistoryRuntime, internal val verifier: Verify,
        private val base: OHState, internal var fence: ByteArray) {
        internal var state = base
        internal var accepted = false
        private var retirement: Boolean? = null
        private var sourceChanged = false
        private val actions = mutableListOf<Pair<ByteArray, Long>>()
        private var localReplacement: ByteArray? = null
        private val retainedReplacement = linkedMapOf<String, ByteArray>()
        private fun usable() { check(!accepted && retirement == null); owner.requireCapture(capture) }
        fun close(): Boolean {
            if (accepted) return true
            retirement?.let { return it }
            val result = owner.retire(native); retirement = result; return result
        }
        fun copy(): Candidate {
            usable()
            val copy = if (peer == null) owner.candidate(capture, transaction)
                else owner.peerCandidate(peer.account, capture, transaction)
            try { actions.forEach { (a, now) -> copy.dispatch(a, now) }
                localReplacement?.let { copy.state = copy.state.localOverlay(it); copy.localReplacement = it.copyOf() }
                if (retainedReplacement.isNotEmpty()) copy.replaceHostArchive(retainedReplacement); return copy }
            catch (failure: Throwable) { copy.close(); throw failure }
        }
        fun stateForPresentation(): ByteArray { usable(); return state.presentation() }
        fun replaceLocalState(bytes: ByteArray) {
            usable(); state = state.localState(bytes)
            val overlay = OHJson.Obj(bytes); (OHState.ROOT + OHState.RETAINED).forEach(overlay::remove); localReplacement = overlay.encoded()
        }
        /** Explicit source/legacy host updates only; omitted adjacent/unknown fields remain raw. */
        fun replaceHostArchive(fields: Map<String, ByteArray>) {
            usable(); require(fields.keys.all { it in OHState.RETAINED })
            val wrapper = OHJson.Obj(); fields.forEach { (key, value) -> wrapper.set(key, value) }
            NativeHostDocument.requireCredentialFree(JSONObject(OHJson.utf8(wrapper.encoded())))
            transaction.authority.withActive { capture.authority.withActive {
                owner.check(capture); state = state.retained(fields)
                fields.forEach { (key, value) -> retainedReplacement[key] = value.copyOf() }
            } }
        }
        internal fun merge() {
            usable(); val p = requireNotNull(peer)
            val reply = response(native.request(request("merge", fence, mapOf("document" to p.native, "peer" to p.capabilities)), 0, verifier.callback))
            require(reply.text("kind") == "source_candidate"); verifier.advance(reply, fence, true)
            fence = captureNative(native, verifier); sourceChanged = true; refresh(true)
        }
        fun dispatch(action: ByteArray, now: Long): ByteArray {
            usable(); require(now >= 0); OHJson.Obj(action)
            require(actions.isEmpty() || verifier.target.profileID == capture.target.profileID)
            val before = verifier.fullCount
            val reply = response(native.request(request("dispatch", fence, mapOf("actions" to OHJson.array(listOf(action)))), now, verifier.callback))
            if (reply.text("kind") == "action_rejected") {
                require(reply.keys == setOf("kind", "fence", "preparedAgainst", "reason", "durableAck", "advertise") &&
                    reply.text("reason") == "native_action_rejected" && OHJson.equal(reply.raw("fence"), fence) &&
                    OHJson.equal(reply.raw("preparedAgainst"), capture.fence) && isFalse(reply, "durableAck") && isFalse(reply, "advertise") && verifier.fullCount == before)
                owner.requireCapture(capture)
                return OHJson.literal("{\"ok\":false,\"error\":\"native action rejected\"}")
            }
            require(reply.text("kind") == "dispatched" && isFalse(reply, "durableAck"))
            val full = verifier.fullCount != before; verifier.advance(reply, fence, full)
            fence = captureNative(native, verifier); sourceChanged = sourceChanged || full; refresh(full)
            actions.add(action.copyOf() to now)
            return OHJson.Obj().set("ok", OHJson.literal("true")).set("events", reply.raw("events")).encoded()
        }
        private fun refresh(fullThisCall: Boolean) {
            if (sourceChanged) {
                val reply = response(native.request(request("checkpoint", fence), 0, verifier.callback))
                require(reply.text("kind") == "checkpoint" && OHJson.equal(reply.raw("fence"), fence) && isFalse(reply, "durableAck") && isTrue(reply, "requiresCompleteArchiveEnvelope"))
                val validated = requireNotNull(verifier.full)
                if (fullThisCall) require(OHJson.equal(validated, reply.raw("state")))
                else {
                    val old = OHJson.Obj(validated).obj("nativeSync")["ownerHistory"]; val next = OHJson.Obj(reply.raw("state")).obj("nativeSync")["ownerHistory"]
                    require(if (old == null || next == null) old == null && next == null else old.contentEquals(next))
                }
                state = base.full(reply.raw("state"), fence)
            } else state = base.delta(native.request(request("checkpoint_delta", fence), 0, verifier.callback), capture.fence)
            localReplacement?.let { state = state.localOverlay(it) }
            if (retainedReplacement.isNotEmpty()) state = state.retained(retainedReplacement)
        }
        /** Staged inventory or own mutation verification, never an advertised playback read. */
        fun resolve(query: ByteArray): ByteArray {
            usable(); val input = OHJson.Obj(query); val kind = input.text("kind")
            require(kind in setOf("installed_addons", "profile_playback"))
            if (kind == "profile_playback") require(input.text("profileId") == OHJson.Obj(fence).text("profileId"))
            val reply = response(native.request(request("resolve_candidate", fence, mapOf("request" to query)), 0, verifier.callback))
            require(reply.text("kind") == "resolved_candidate" && OHJson.equal(reply.raw("fence"), fence) && isFalse(reply, "durableAck") && isFalse(reply, "advertise"))
            val result = reply.obj("result"); require(result.text("kind") == kind)
            if (kind == "profile_playback") require(result.text("profileId") == OHJson.Obj(fence).text("profileId"))
            return result.encoded()
        }
    }
    fun commit(candidate: Candidate, hostPreferences: ByteArray): Checkpoint {
        val c = candidate.capture; requireCapture(c); check(!candidate.accepted)
        // Even a host-only transaction must obtain a native checkpoint before accept.
        if (candidate.state === state || !OHJson.equal(candidate.state.fence, candidate.fence)) {
            candidate.state = candidate.state.retarget(c.fence).delta(candidate.native.request(request("checkpoint_delta", candidate.fence), 0, candidate.verifier.callback), c.fence)
        }
        val tx = candidate.transaction; val projection = hostProjection(hostPreferences)
        var next = Checkpoint(scope, candidate.state.bytes(), hostPreferences, candidate.nextSources.local(), tx.account.encoded(), current.readOwnerUID)
        val account = tx.account.projected(next, projection).encoded(); tx.budget(account)
        next = Checkpoint(scope, next.snapshot, next.hostPreferences, next.localArchive, account, current.readOwnerUID)
        var started = false; var old: NativeOwnerHistoryRuntime? = null
        try {
            tx.authority.withActive {
                c.authority.withActive {
                    check(c); requireCurrent(installed); tx.budget(next.accountBase)
                    started = true
                    val readback = persist(installed, next.envelope())
                    // The store promises authenticated exact readback; also verify returned raw body.
                    require(readback.plaintext?.toByteArray(Charsets.UTF_8)?.contentEquals(next.envelope()) == true)
                    val accept = NativeOwnerHistoryVerifier { bytes -> runCatching {
                        val wrapper = OHJson.Obj(bytes); val check = wrapper.obj("check")
                        require(wrapper.text("kind") == "lease" && check.text("contract") == "vortx.owner-history-session-lease/1" &&
                            check.text("purpose") == "checkpoint_accepted" && OHJson.equal(check.raw("fence"), candidate.fence) &&
                            OHJson.equal(check.raw("preparedAgainst"), c.fence)); true
                    }.getOrDefault(false) }
                    val reply = response(candidate.native.request(request("accept", candidate.fence), 0, accept))
                    require(reply.text("kind") == "accepted" && OHJson.equal(reply.raw("fence"), candidate.fence) && isFalse(reply, "durableAck"))
                    old = runtime; runtime = candidate.native; state = candidate.state; current = next
                    sources = candidate.nextSources; installed = readback; candidate.accepted = true
                }
            }
            val previous = old; old = null
            if (previous != null && !retire(previous)) throw Uncertain()
            c.authority.withActive { }; return next
        } catch (failure: Throwable) {
            old?.let(::retire)
            if (started) { uncertain = true; throw Uncertain(failure) }
            throw failure
        }
    }
    internal class Peer(val account: NativeOwnerHistoryAccount, val native: ByteArray,
                        val sources: NativeOwnerHistorySources, val capabilities: ByteArray, val readUID: String?)
    internal enum class Mode { OPEN, FIXED, FORK, RETARGET }
    internal class Verify(private val scope: VortxAccountScope, var target: Target,
        private val ownerUID: String, private val authority: NativeOwnerHistoryAuthority,
        private val bindings: NativeOwnerHistoryBindings, private val sources: NativeOwnerHistorySources,
        private val mode: Mode, private val expected: ByteArray? = null,
        private val parent: ByteArray? = if (mode == Mode.FORK) expected else null,
        private val peer: Peer? = null, private val openingNative: ByteArray? = null) {
        var fence: ByteArray? = if (mode == Mode.FIXED) expected?.copyOf() else null
        var full: ByteArray? = null; var fullCount = 0
        val callback = NativeOwnerHistoryVerifier { bytes -> runCatching { verify(bytes); true }.getOrDefault(false) }
        private fun verify(bytes: ByteArray) {
            authority.withActive { }; val wrapper = OHJson.Obj(bytes); val check = wrapper.obj("check")
            when (wrapper.text("kind")) {
                "full" -> {
                    val purpose = check.text("purpose")
                    require(check.text("contract") == "vortx.owner-history-complete-archive/1")
                    require(if (mode == Mode.OPEN) purpose in setOf("session_open_input", "session_open_normalized")
                        else purpose == "session_source_transition" || (peer != null && purpose in setOf("session_merge_peer", "session_merge")))
                    if (purpose == "session_merge_peer") {
                        val p = requireNotNull(peer); require(OHJson.equal(check.raw("peer"), p.capabilities) && OHJson.equal(check.raw("incomingNative"), p.native))
                    }
                    val candidate = check.raw("candidateState")
                    if (openingNative != null) OHState.requireColdNativeConservation(openingNative, OHJson.Obj(candidate).raw("nativeSync"))
                    sources.validate(candidate, bindings, authority); full = candidate; fullCount++
                }
                "lease" -> {
                    require(check.text("contract") == "vortx.owner-history-session-lease/1" && check.text("purpose") != "checkpoint_accepted")
                    val raw = check.raw("fence"); val f = OHJson.Obj(raw)
                    require(f.text("scope") == scope.accountID && f.text("ownerProfileId") == scope.ownerProfileID &&
                        f.text("profileId") == target.profileID && f.text("verifiedStreamingUid") == target.verifiedUID)
                    if (parent == null) require(OHJson.utf8(check.raw("preparedAgainst")) == "null")
                    else require(OHJson.equal(check.raw("preparedAgainst"), parent))
                    if (fence != null) require(OHJson.equal(requireNotNull(fence), raw))
                    else {
                        require(check.text("purpose") == "capture")
                        when (mode) {
                            Mode.OPEN -> require(fullCount == 2)
                            Mode.FORK -> {
                                val old = OHJson.Obj(requireNotNull(expected)); val next = OHJson.Obj(raw)
                                require(old.text("instanceId") != next.text("instanceId")); old.remove("instanceId"); next.remove("instanceId")
                                require(OHJson.equal(old.encoded(), next.encoded()))
                            }
                            Mode.RETARGET -> require(OHState.sameGeneration(requireNotNull(expected), raw))
                            Mode.FIXED -> error("Missing original fence")
                        }
                        fence = raw
                    }
                }
                else -> error("Invalid native owner check")
            }
            authority.withActive { }
        }
        fun advance(reply: OHJson.Obj, previous: ByteArray, fullRequired: Boolean) {
            require(OHJson.equal(requireNotNull(fence), previous) && (!fullRequired || fullCount > 0))
            val next = OHJson.Obj(previous); require(reply.text("instanceId") == next.text("instanceId"))
            if (!fullRequired) require(reply.text("sourceSetWitnessId") == next.text("sourceSetWitnessId"))
            val active = reply.obj("activeTarget"); require(active.keys == setOf("profileId", "binding"))
            val profile = active.text("profileId"); val binding = active.raw("binding"); val account = OHJson.Obj(binding).obj("account")
            val uid = if (account.text("kind") == "own") account.text("value") else {
                val oldAccount = next.obj("binding").obj("account")
                if (profile == target.profileID && oldAccount.text("kind") != "own") target.verifiedUID else ownerUID
            }
            target = Target(profile, uid)
            next.set("profileId", OHJson.quote(profile)).set("verifiedStreamingUid", OHJson.quote(uid)).set("binding", binding)
                .set("mutationGeneration", reply.raw("mutationGeneration")).set("sourceSetWitnessId", reply.raw("sourceSetWitnessId"))
            fence = next.encoded()
        }
    }
    companion object {
        const val ENVELOPE = "vortx.owner-history.checkpoint/1"
        private val RETAINED = mutableListOf<NativeOwnerHistoryRuntime>()
        fun decodeEnvelope(bytes: ByteArray, scope: VortxAccountScope): Checkpoint {
            val o = OHJson.Obj(bytes)
            require(o.keys == setOf("kind", "schemaVersion", "scope", "ownerProfileId", "snapshotBase64", "hostPreferencesBase64", "localArchiveBase64", "accountBaseBase64", "readOwnerUID") &&
                o.text("kind") == ENVELOPE && OHJson.integer(o.raw("schemaVersion")) == 1L && o.text("scope") == scope.accountID && o.text("ownerProfileId") == scope.ownerProfileID)
            val checkpoint = Checkpoint(scope, OHJson.un64(o.text("snapshotBase64")), OHJson.un64(o.text("hostPreferencesBase64")),
                OHJson.un64(o.text("localArchiveBase64")), OHJson.un64(o.text("accountBaseBase64")), o.text("readOwnerUID"))
            val n = OHJson.Obj(checkpoint.snapshot).obj("nativeSync")
            require(n.text("scope") == scope.accountID && n.text("ownerProfileId") == scope.ownerProfileID && OHJson.integer(n.raw("schemaVersion")) in 1..6)
            return checkpoint
        }
        fun open(scope: VortxAccountScope, target: Target, checkpoint: Checkpoint, originalRead: NativeCheckpointRead,
            bindings: NativeOwnerHistoryBindings, authority: NativeOwnerHistoryAuthority,
            requireCurrent: (NativeCheckpointRead) -> Unit,
            commit: (NativeCheckpointRead, ByteArray) -> NativeCheckpointRead,
            hostProjection: (ByteArray) -> HostProjection): NativeOwnerHistoryCoordinator {
            require(checkpoint.scope == scope); authority.withActive { requireCurrent(originalRead) }
            val original = requireNotNull(originalRead.plaintext).toByteArray(Charsets.UTF_8)
            val stored = OHJson.Obj(original)
            if (stored["kind"]?.let(OHJson::text) == ENVELOPE) require(OHJson.equal(original, checkpoint.envelope()))
            else require(OHJson.equal(original, checkpoint.snapshot)) { "Checkpoint belongs to another original read" }
            hostProjection(checkpoint.hostPreferences)
            val sources = NativeOwnerHistorySources.fromLocal(scope, checkpoint.localArchive)
            val v = Verify(scope, target, checkpoint.readOwnerUID, authority, bindings, sources, Mode.OPEN)
            val native = NativeOwnerHistoryRuntime.open(bindings, checkpoint.snapshot, v.callback)
            try {
                val fence = captureNative(native, v); val normalized = requireNotNull(v.full)
                val originalState = OHState(checkpoint.snapshot, fence); val complete = originalState.full(normalized, fence)
                require(OHJson.equal(complete.bytes(), checkpoint.snapshot)) { "Uncheckpointed cold normalization" }
                authority.withActive { requireCurrent(originalRead) }
                return NativeOwnerHistoryCoordinator(scope, bindings, native, complete, originalRead, checkpoint, sources, requireCurrent, commit, hostProjection)
            } catch (failure: Throwable) {
                if (!native.close()) { synchronized(RETAINED) { RETAINED.add(native) }; throw Uncertain(failure) }
                throw failure
            }
        }
        /** First remote only. Root performs original-absence CAS before opening the returned checkpoint. */
        fun prepareColdPeer(scope: VortxAccountScope, target: Target, account: NativeOwnerHistoryAccount,
            hostPreferences: ByteArray, bindings: NativeOwnerHistoryBindings, authority: NativeOwnerHistoryAuthority,
            budget: (ByteArray) -> Unit, hostProjection: (ByteArray) -> HostProjection,
            localState: ByteArray = OHJson.literal("{}")): Checkpoint {
            val peer = peer(account, scope); val uid = requireNotNull(peer.readUID)
            require(target.profileID == scope.ownerProfileID && target.verifiedUID == uid)
            val n = OHJson.Obj(peer.native); val profiles = n.obj("profiles"); val roster = OHJson.Obj()
            profiles.keys.forEach { id -> val p = profiles.obj(id).raw("profile"); require(OHJson.Obj(p).text("id") == id); roster.set(id, p) }
            val owner = roster.obj(scope.ownerProfileID); require(isTrue(owner, "owner") && (owner["deleted"] == null || isFalse(owner, "deleted")))
            val input = OHJson.Obj().set("roster", OHJson.Obj().set("profiles", roster.encoded()).encoded())
                .set("activeProfileId", OHJson.quote(target.profileID)).set("nativeSync", peer.native).encoded()
            peer.sources.validate(input, bindings, authority)
            val v = Verify(scope, target, uid, authority, bindings, peer.sources, Mode.OPEN, openingNative = peer.native)
            val native = NativeOwnerHistoryRuntime.open(bindings, input, v.callback); var attempted = false
            try {
                val fence = captureNative(native, v); val normalized = requireNotNull(v.full)
                // Keep exact peer-native unknown siblings; serde's omission is not a deletion.
                val complete = OHState(input, fence).full(normalized, fence)
                val merged = OHJson.Obj(localState); val full = OHJson.Obj(complete.bytes())
                OHState.ROOT.forEach { k -> full[k]?.let { merged.set(k, it) } ?: merged.remove(k) }
                var result = Checkpoint(scope, merged.encoded(), hostPreferences, peer.sources.local(), account.encoded(), uid)
                result = Checkpoint(scope, result.snapshot, result.hostPreferences, result.localArchive,
                    account.projected(result, hostProjection(hostPreferences)).encoded(), uid)
                authority.withActive { budget(result.accountBase) }
                attempted = true
                if (!native.close()) { synchronized(RETAINED) { RETAINED.add(native) }; throw Uncertain() }
                authority.withActive { }; return result
            } catch (failure: Throwable) {
                if (!attempted && !native.close()) { synchronized(RETAINED) { RETAINED.add(native) }; throw Uncertain(failure) }
                throw failure
            }
        }
        private fun peer(account: NativeOwnerHistoryAccount, scope: VortxAccountScope): Peer {
            val raw = requireNotNull(account.raw("nativeSync")); val n = OHJson.Obj(raw)
            require(n.text("scope") == scope.accountID && n.text("ownerProfileId") == scope.ownerProfileID)
            val schema = OHJson.integer(n.raw("schemaVersion")); require(schema in 1..6)
            val carrier = account.raw(NativeOwnerHistoryAccount.ARCHIVE)
            val sources: NativeOwnerHistorySources; val uid: String?; val capabilities: List<ByteArray>
            if (n["ownerHistory"] != null) {
                require(schema == 6L); val c = requireNotNull(carrier); sources = NativeOwnerHistorySources.fromCarrier(scope, c)
                uid = NativeOwnerHistorySources.readOwnerUID(scope, c); capabilities = listOf(OHJson.quote("vortx.owner-history-fallback/1"))
            } else { require(schema <= 5 && carrier == null); sources = NativeOwnerHistorySources.empty(scope); uid = null; capabilities = emptyList() }
            return Peer(account, raw, sources, OHJson.Obj().set("schemas", OHJson.array(listOf(n.raw("schemaVersion"))))
                .set("capabilities", OHJson.array(capabilities)).encoded(), uid)
        }
        private fun pair(first: NativeOwnerHistoryAuthority, second: NativeOwnerHistoryAuthority) = object : NativeOwnerHistoryAuthority {
            override fun <T> withActive(block: () -> T): T { first.withActive { }; val result = second.withActive(block); first.withActive { }; return result }
        }
        private fun request(kind: String, fence: ByteArray? = null, extra: Map<String, ByteArray> = emptyMap()): ByteArray {
            require(extra.keys.none { it == "kind" || it == "fence" }); val o = OHJson.Obj().set("kind", OHJson.quote(kind))
            if (fence != null) o.set("fence", fence); extra.forEach { (k, v) -> o.set(k, v) }; return o.encoded()
        }
        private fun response(bytes: ByteArray): OHJson.Obj = OHJson.Obj(bytes).also { require(it.text("kind") != "error") { "Native owner operation rejected" } }
        private fun captureNative(runtime: NativeOwnerHistoryRuntime, verifier: Verify): ByteArray {
            val reply = response(runtime.request(request("capture", extra = mapOf("profileId" to OHJson.quote(verifier.target.profileID),
                "authenticatedUid" to OHJson.quote(verifier.target.verifiedUID))), 0, verifier.callback))
            require(reply.text("kind") == "capture" && isFalse(reply, "advertise") && OHJson.equal(reply.raw("fence"), requireNotNull(verifier.fence)))
            return reply.raw("fence")
        }
        private fun isFalse(o: OHJson.Obj, k: String) = OHJson.utf8(o.raw(k)) == "false"
        private fun isTrue(o: OHJson.Obj, k: String) = OHJson.utf8(o.raw(k)) == "true"
    }
}
