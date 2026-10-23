package com.vortx.android.engine

import org.json.JSONObject

/** Same Session monitor and encrypted file as the generic runtime. No autonomous writer. */
internal class NativeOwnerHistorySessionAdapter private constructor(
    private val scope: VortxAccountScope,
    private val coordinator: NativeOwnerHistoryCoordinator,
    private val authority: NativeOwnerHistoryAuthority,
    private var accepted: NativeOwnerHistoryCoordinator.Checkpoint,
) {
    private var selected = selectedTarget(accepted)
    private fun target(): NativeOwnerHistoryCoordinator.Target = selected
    private fun acceptSelection(fence: ByteArray) {
        val value = OHJson.Obj(fence)
        selected = NativeOwnerHistoryCoordinator.Target(value.text("profileId"), value.text("verifiedStreamingUid"))
    }
    private fun capture() = coordinator.capture(target(), authority)
    private fun transaction(account: NativeOwnerHistoryAccount = NativeOwnerHistoryAccount(accepted.accountBase),
                            original: NativeOwnerHistoryAuthority = authority) =
        NativeOwnerHistoryCoordinator.Transaction(account, original) { NativeOwnerHistoryAccount(it).validateBudget(true) }
    fun checkpoint(): NativeOwnerHistoryCoordinator.Checkpoint = coordinator.checkpoint(capture())
    fun presentation(): ByteArray = coordinator.validatePresentation(capture())
    fun cloudAccount(): ByteArray = NativeOwnerHistoryAccount(checkpoint().accountBase).cloudPlaintext(true)
    fun requiresRecovery() = coordinator.requiresAuthenticatedReopen
    fun close() { if (!coordinator.close()) throw NativeOwnerHistoryCoordinator.Uncertain() }
    fun view(): VortxNativeRuntime = VortxNativeRuntime.delegated(View(null))
    fun hostArchiveChanges(archive: JSONObject): Map<String, ByteArray> {
        NativeHostDocument.requireCredentialFree(archive.getJSONObject("document"))
        val retained = OHJson.Obj(checkpoint().snapshot)
        val old = retained["hostDocument"]?.let { OHJson.Obj(it) } ?: OHJson.Obj()
        val supplied = archive.getJSONObject("document")
        // The source producer owns these bounded carriers, not every legacy/unknown sibling in
        // the UI's JSONObject copy. Unchanged raw fields never round-trip through that DTO.
        val owned = NativeWatchedMigrationStorage.KEYS + setOf("authenticatedOwnAccountSources", "nativeOwnAccountCandidates",
            "nativeOwnAccountPending", "nativeLegacyMembershipPending", "nativeWatchlistMigrationPending")
        owned.forEach { key ->
            if (supplied.has(key)) old.set(key, supplied.get(key).toString().toByteArray(Charsets.UTF_8)) else old.remove(key)
        }
        val excluded = linkedSetOf<String>()
        retained["excludedCredentialPaths"]?.let { OHJson.array(it).forEach { value -> excluded.add(OHJson.text(value)) } }
        val incoming = archive.getJSONArray("excludedCredentialPaths")
        (0 until incoming.length()).forEach { excluded.add(incoming.getString(it)) }
        return mapOf("hostDocument" to old.encoded(),
            "excludedCredentialPaths" to OHJson.array(excluded.sorted().map(OHJson::quote)))
    }

    /** Incoming sources are checked before union by peerCandidate. Caller owns original GET lease. */
    fun receive(account: NativeOwnerHistoryAccount, original: NativeOwnerHistoryAuthority,
                hostPreferences: ByteArray, local: (ByteArray) -> ByteArray,
                beforePersist: () -> Unit = {}): NativeOwnerHistoryCoordinator.Checkpoint {
        val c = capture()
        val candidate = coordinator.peerCandidate(account, c, transaction(account, original))
        var installed = false
        try {
            candidate.replaceLocalState(local(candidate.stateForPresentation()))
            beforePersist()
            val next = coordinator.commit(candidate, hostPreferences)
            accepted = next; acceptSelection(candidate.fence); installed = true
            return next
        } finally {
            if (!installed && !candidate.close()) throw NativeOwnerHistoryCoordinator.Uncertain()
        }
    }

    private inner class View(private var staged: NativeOwnerHistoryCoordinator.Candidate?) : VortxRuntimeDelegate {
        private var closed = false
        private fun usable() { check(!closed && !requiresRecovery()) { "Owner history Session unavailable" } }
        override fun fork(): VortxRuntimeDelegate {
            usable()
            return View(staged?.copy() ?: coordinator.candidate(capture(), transaction()))
        }
        override fun dispatch(action: String): String {
            usable()
            return OHJson.utf8(requireNotNull(staged) { "Owner history edits require a staged transaction" }
                .dispatch(action.toByteArray(Charsets.UTF_8), System.currentTimeMillis() / 1000))
        }
        override fun resolve(request: String): String {
            usable(); val query = request.toByteArray(Charsets.UTF_8)
            staged?.let { return OHJson.utf8(it.resolve(query)) }
            val c = capture()
            val input = OHJson.Obj(query)
            val bucket = if (input.text("kind") == "installed_addons") input.text("profileId") else null
            val actual = if (bucket != null) OHJson.Obj().set("kind", OHJson.quote("profile_addons"))
                .set("profileId", OHJson.quote(c.target.profileID)).set("bucketProfileId", OHJson.quote(bucket)).encoded() else query
            val result = OHJson.Obj(OHJson.Obj(coordinator.read("resolve", c, mapOf("request" to actual))).raw("result"))
            if (bucket != null) {
                require(result.text("kind") == "profile_addons" && result.text("profileId") == c.target.profileID && result.text("bucketProfileId") == bucket)
                return OHJson.utf8(OHJson.Obj().set("kind", OHJson.quote("installed_addons"))
                    .set("profileId", OHJson.quote(bucket)).set("addons", result.raw("addons")).encoded())
            }
            return OHJson.utf8(result.encoded())
        }
        override fun stateJson(): String {
            usable()
            return OHJson.utf8(staged?.stateForPresentation() ?: coordinator.validatePresentation(capture()))
        }
        override fun commitCheckpoint(snapshot: String, archiveChanges: Map<String, ByteArray>) {
            usable()
            val candidate = staged ?: coordinator.candidate(capture(), transaction())
            var installed = false
            try {
                val raw = OHJson.Obj(snapshot.toByteArray(Charsets.UTF_8))
                // Retained immutable/raw adjacent fields already live in the typed state.
                // Their presentation copies cannot silently replace them on an ordinary edit.
                listOf("hostDocument", "excludedCredentialPaths", "legacyImportMaterial", "legacyWebsiteBootstrap").forEach(raw::remove)
                candidate.replaceLocalState(raw.encoded())
                if (archiveChanges.isNotEmpty()) candidate.replaceHostArchive(archiveChanges)
                val host = raw.raw("nativeHostPreferenceState")
                accepted = coordinator.commit(candidate, host)
                acceptSelection(candidate.fence)
                staged = null; installed = true
            } finally {
                if (!installed && !candidate.close()) throw NativeOwnerHistoryCoordinator.Uncertain()
            }
        }
        override fun close() {
            if (closed) return
            staged?.let { if (!it.close()) throw NativeOwnerHistoryCoordinator.Uncertain() }
            staged = null; closed = true
            // A view never owns/freezes the mounted coordinator. Session.close owns retirement.
        }
    }

    companion object {
        private fun selectedTarget(checkpoint: NativeOwnerHistoryCoordinator.Checkpoint): NativeOwnerHistoryCoordinator.Target {
            val state = OHJson.Obj(checkpoint.snapshot); val active = state.text("activeProfileId")
            val profile = state.obj("roster").obj("profiles").obj(active)
            val selected = state.obj("nativeSync")["accountSlots"]?.let { OHJson.Obj(it)[active] }
                ?.let { OHJson.Obj(it).raw("activeBinding") }
            val account = if (selected != null) {
                val binding = OHJson.Obj(selected)
                require(OHJson.equal(binding.raw("account"), profile.raw("account")))
                binding.obj("account")
            } else profile.obj("account")
            val uid = if (account.text("kind") == "own") account.text("value") else checkpoint.readOwnerUID
            return NativeOwnerHistoryCoordinator.Target(active, uid)
        }
        fun isEnvelope(raw: String): Boolean = OHJson.Obj(raw.toByteArray(Charsets.UTF_8))["kind"]?.let {
            OHJson.text(it) == NativeOwnerHistoryCoordinator.ENVELOPE
        } == true
        fun projection(scope: VortxAccountScope, raw: ByteArray): NativeOwnerHistoryCoordinator.HostProjection {
            NativeHostPreferences.local(scope, JSONObject(OHJson.utf8(raw)))
            val host = OHJson.Obj(raw)
            return NativeOwnerHistoryCoordinator.HostProjection(host.raw("document"), OHJson.Obj()
                .set("conflicts", host["websiteConflicts"] ?: OHJson.literal("[]"))
                .set("addonConflicts", host["websiteAddonConflicts"] ?: OHJson.literal("[]")).encoded())
        }
        fun open(scope: VortxAccountScope, checkpoint: NativeOwnerHistoryCoordinator.Checkpoint,
                 original: NativeCheckpointRead, bindings: NativeOwnerHistoryBindings,
                 store: VortxCheckpointStore, authority: NativeOwnerHistoryAuthority,
                 openingAuthority: NativeOwnerHistoryAuthority = authority): NativeOwnerHistorySessionAdapter {
            val target = selectedTarget(checkpoint)
            val owner = NativeOwnerHistoryCoordinator.open(scope, target, checkpoint, original, bindings, openingAuthority,
                requireCurrent = { store.requireCurrentCheckpoint(scope, it) },
                commit = { read, raw -> store.compareAndCommitCheckpoint(scope, read, OHJson.utf8(raw)) },
                hostProjection = { projection(scope, it) })
            return NativeOwnerHistorySessionAdapter(scope, owner, authority, checkpoint)
        }
    }
}
