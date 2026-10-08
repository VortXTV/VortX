package com.vortx.android.engine

import com.vortx.android.sync.SessionOwnerSnapshot
import org.json.JSONObject
import java.util.UUID

/** Captures native ownership before any credential/network suspension. The journal candidate is
 * immutable and inactive until this exact native binding transaction durably commits. */
internal class NativeStreamingAccountLink(
    private val credentials: NativeOwnAccountCredentials,
    private val producer: NativeOwnAccountProducer = NativeOwnAccountProducer(),
) {
    suspend fun signIn(session: VortxNativeSession, account: SessionOwnerSnapshot.Account, profileID: String,
                       email: String, password: String, accountAdmission: (() -> Boolean) -> Boolean,
                       mountedAdmission: (() -> Boolean) -> Boolean, expectedOwner: VortxNativeOwner? = null) {
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
        session.owned(read.owner) {
            source.withActive {
                check(mountedAdmission {
                    val current = session.read()
                    check(binding.matches(NativeAccountBinding.read(current.state, profileID))) { "Profile account changed" }
                    val currentDocument = current.state.optJSONObject("hostDocument") ?: JSONObject()
                    check(capturedOverlay == NativeProfileOverlayWitness.digest(nativeOwnAccountOverlay(currentDocument, profileID))) {
                        "Historical account overlay changed during sign-in"
                    }
                    val carrier = nativeOwnAccountCarrier(source, profile, JSONObject())
                    val archived = JSONObject(currentDocument.toString())
                    val sources = archived.optJSONObject("authenticatedOwnAccountSources") ?: JSONObject().also {
                        archived.put("authenticatedOwnAccountSources", it)
                    }
                    sources.put(profileID, JSONObject().put("verifiedStreamingUid", source.verifiedUID)
                        .put("sourceDocumentBase64", source.archiveBase64()))
                    val archive = NativeHostDocument.archive(archived)
                    session.dispatch(listOf(action(read.owner.scope, profileID, binding, transaction,
                        JSONObject().put("kind", "own").put("carrier", carrier))), read.owner, hostArchive = archive,
                        verifyCandidate = { candidate ->
                            val state = JSONObject(candidate.stateJson())
                            val selected = NativeAccountBinding.read(state, profileID)
                            check(selected.kind == "own" && selected.streamingUID == capture.verifiedUID &&
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
