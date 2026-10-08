package com.vortx.android.engine

import com.vortx.android.sync.SessionOwnerSnapshot
import com.vortx.android.profile.UserProfile
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import org.json.JSONObject
import java.util.UUID

/** Captures native ownership before any credential/network suspension. The journal candidate is
 * immutable and inactive until this exact native binding transaction durably commits. */
internal class NativeStreamingAccountLink(
    private val credentials: NativeOwnAccountCredentials,
    private val producer: NativeOwnAccountProducer = NativeOwnAccountProducer(),
    private val watchedProducer: NativeWatchedMigrationProducer = NativeWatchedMigrationProducer(),
) {
    suspend fun signIn(session: VortxNativeSession, account: SessionOwnerSnapshot.Account, profileID: String,
                       email: String, password: String, accountAdmission: (() -> Boolean) -> Boolean,
                       mountedAdmission: (() -> Boolean) -> Boolean, expectedOwner: VortxNativeOwner? = null): Boolean {
        val read = if (expectedOwner == null) session.read() else session.owned(expectedOwner) { session.read() }
        check(!session.requiresRecovery()) { "Native account must reopen before signing in" }
        require(read.owner.scope.accountID == "account.${UUID.fromString(account.id).toString().lowercase()}")
        require(profileID != read.owner.scope.ownerProfileID) { "The native owner cannot be relabelled as a streaming account" }
        val profile = NativeProfileAccess.projection(read).profiles.single { it.id == profileID }
        val binding = NativeAccountBinding.read(read.state, profileID)
        val transaction = UUID.randomUUID().toString()
        val document = read.state.optJSONObject("hostDocument") ?: JSONObject()
        val capturedOverlay = NativeProfileOverlayWitness.digest(nativeOwnAccountOverlay(document, profileID))
        val capture = producer.signIn(credentials, account, profileID, email, password, accountAdmission, transaction)
        // A profile UUID does not attribute its historical cloud overlay to the newly signed-in
        // UID. Explicit relinks consume the independent network source only. Schema1 truthfully
        // retains an empty consumed slice without claiming a witness for the untouched root slice.
        val source = producer.fetch(capture, JSONObject(), witnessedOverlay = false)
        return complete(session, read.owner, profile, binding, transaction, capturedOverlay, source, mountedAdmission)
    }

    suspend fun retry(session: VortxNativeSession, account: SessionOwnerSnapshot.Account, owner: VortxNativeOwner,
                      accountAdmission: (() -> Boolean) -> Boolean, mountedAdmission: (() -> Boolean) -> Boolean): Boolean {
        val read = session.owned(owner) { session.read() }
        val profile = NativeProfileAccess.projection(read).profiles.single { it.id == owner.profileID }
        require(!profile.isOwner)
        val record = checkNotNull(read.state.optJSONObject("hostDocument")?.optJSONObject("nativeOwnAccountCandidates")?.optJSONObject(profile.id))
        val expected = NativeAccountBinding.parse(record.getJSONObject("expectedBinding"))
        check(expected.matches(NativeAccountBinding.read(read.state, profile.id)) &&
            NativeHostPreferences.equal(record.getJSONObject("profile"), profile.encode())) { "Pending account link no longer matches this profile" }
        val transaction = record.getString("transactionId")
        val capture = checkNotNull(credentials.capture(account, profile.id, record.getString("verifiedStreamingUid"), transaction, accountAdmission)) {
            "Sign in again to recover this exact pending account credential"
        }
        val source = NativeOwnAccountSource.fromRetained(capture, java.util.Base64.getDecoder().decode(record.getString("sourceDocumentBase64")))
        return complete(session, owner, profile, expected, transaction, record.getString("historicalOverlayDigest"), source, mountedAdmission)
    }

    private suspend fun complete(session: VortxNativeSession, owner: VortxNativeOwner, profile: UserProfile,
                                 binding: NativeAccountBinding, transaction: String, capturedOverlay: String,
                                 source: NativeOwnAccountSource, mountedAdmission: (() -> Boolean) -> Boolean): Boolean {
        val profileID = profile.id
        val operationJob = currentCoroutineContext()[Job]
        val prior = session.owned(owner) { session.read().state.optJSONObject("hostDocument") ?: JSONObject() }
        // The pending target is Own even when the captured current binding is Shared. Keep the
        // original profile/binding for CAS and retry identity; only the independent-source
        // preparation describes the intended new Own target.
        val watched = watchedProducer.prepareOwn(owner.scope, profile.copy(usesOwnAccount = true), source, prior.optJSONArray("nativeWatchedMigrationEvidence")) {
            operationJob?.isActive != false && runCatching { session.owned(owner) { source.withActive { true } } }.getOrDefault(false)
        }
        return session.owned(owner) {
            source.withActive {
                check(mountedAdmission admission@{
                    operationJob?.ensureActive()
                    val current = session.read()
                    check(binding.matches(NativeAccountBinding.read(current.state, profileID))) { "Profile account changed" }
                    val currentDocument = current.state.optJSONObject("hostDocument") ?: JSONObject()
                    check(capturedOverlay == NativeProfileOverlayWitness.digest(nativeOwnAccountOverlay(currentDocument, profileID))) {
                        "Historical account overlay changed during sign-in"
                    }
                    val archived = NativeProfileOverlayWitness.parseDocument(nativeWatchedDocumentSnapshot(currentDocument))
                    mergeNativeWatchedArchive(owner.scope, currentDocument, archived, watched.archive(), watched.pending())
                    val candidates = archived.optJSONObject("nativeOwnAccountCandidates") ?: JSONObject().also { archived.put("nativeOwnAccountCandidates", it) }
                    if (!watched.isComplete) {
                        candidates.put(profileID, JSONObject().put("verifiedStreamingUid", source.verifiedUID)
                            .put("transactionId", transaction).put("sourceDocumentBase64", source.archiveBase64())
                            .put("expectedBinding", binding.json()).put("profile", profile.encode()).put("historicalOverlayDigest", capturedOverlay))
                        session.dispatch(emptyList(), owner, hostArchive = NativeHostDocument.archive(archived),
                            beforeCommit = { operationJob?.ensureActive() })
                        return@admission true
                    }
                    val carrier = nativeOwnAccountCarrier(source, profile, JSONObject(), watchedMigration = watched)
                    candidates.remove(profileID)
                    val sources = archived.optJSONObject("authenticatedOwnAccountSources") ?: JSONObject().also {
                        archived.put("authenticatedOwnAccountSources", it)
                    }
                    sources.put(profileID, JSONObject().put("verifiedStreamingUid", source.verifiedUID)
                        .put("sourceDocumentBase64", source.archiveBase64()))
                    val archive = NativeHostDocument.archive(archived)
                    session.dispatch(listOf(action(owner.scope, profileID, binding, transaction,
                        JSONObject().put("kind", "own").put("carrier", carrier))), owner, hostArchive = archive,
                        beforeCommit = { operationJob?.ensureActive() }, verifyCandidate = { candidate ->
                            operationJob?.ensureActive()
                            val state = JSONObject(candidate.stateJson())
                            val selected = NativeAccountBinding.read(state, profileID)
                            check(selected.kind == "own" && selected.streamingUID == source.verifiedUID &&
                                selected.revision == binding.revision + 1 && selected.transactionID == transaction) { "Native account binding readback failed" }
                            val sync = state.getJSONObject("nativeSync")
                            val slots = sync.getJSONObject("accountSlots").getJSONObject(profileID).getJSONObject("slots")
                            val active = slots.keys().asSequence().map { slots.getJSONObject(it) }.single {
                                NativeHostPreferences.equal(it.getJSONObject("account"), selected.json().getJSONObject("account"))
                            }
                            check(NativeHostPreferences.equal(active.getJSONObject("sourceBaseline").getJSONObject("source"), source.proof())) {
                                "Native source proof readback failed"
                            }
                        })
                    true
                }) { "Native account changed" }
                watched.isComplete
            }
        }
    }

    companion object {
        internal fun action(scope: VortxAccountScope, id: String, expected: NativeAccountBinding, transaction: String,
                            target: JSONObject): JSONObject = JSONObject().put("type", "rebind_profile_account")
            .put("scope", scope.accountID).put("ownerProfileId", scope.ownerProfileID).put("profileId", id)
            .put("transactionId", transaction).put("expectedBinding", expected.json()).put("target", target)
    }
}
