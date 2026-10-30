package com.vortx.android.engine

import com.vortx.android.foryou.ForYouNativeGateway
import com.vortx.android.foryou.ForYouObservedField
import com.vortx.android.foryou.ForYouSync
import com.vortx.android.foryou.ForYouIdentityRef
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** Original command capture uses Session -> authenticated account -> exact mounted installation.
 * Store publication monitors never enter native calls. Generic Session.dispatch remains unchanged. */
internal class NativeForYouAccess(
    private val accounts: NativeAccountCoordinator,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : ForYouNativeGateway {
    private class Captured(
        val session: VortxNativeSession,
        val native: VortxNativeOwner,
        val admission: NativeAccountCoordinator.ForYouMutationAdmission,
    ) : ForYouNativeGateway.Owner {
        override val profileId get() = native.profileID
        override val scopeIdentity = listOf(ForYouIdentityRef(session), native, admission.identity)
    }

    override val changes: Flow<Unit> = channelFlow {
        accounts.changes.collectLatest {
            send(Unit)
            runCatching { accounts.session() }.getOrNull()?.updates?.collect { send(Unit) }
        }
    }

    private fun fields(read: VortxNativeRead): JSONObject {
        val all = read.state.getJSONObject("nativeHostPreferenceState").getJSONObject("document")
            .getJSONObject("profiles").optJSONObject(read.owner.profileID)?.getJSONObject("fields") ?: JSONObject()
        return JSONObject().also { result ->
            all.keys().asSequence().filter { it.startsWith(ForYouSync.PREFIX) }.forEach { result.put(it, all.getJSONObject(it)) }
        }
    }

    override fun capture(): Result<ForYouNativeGateway.Snapshot> = runCatching {
        val session = accounts.session()
        session.withCurrentRead { read ->
            val admission = accounts.captureForYouMutationAdmission(session)
            val publication = accounts.captureProfilePresentation(session)
            var result: ForYouNativeGateway.Snapshot? = null
            check(admission.admit {
                result = ForYouNativeGateway.Snapshot(Captured(session, read.owner, admission), fields(read), publication::publishIfCurrent)
                true
            }) { "For You account changed" }
            checkNotNull(result)
        }
    }

    override suspend fun write(owner: ForYouNativeGateway.Owner, field: String, observed: ForYouObservedField,
                               value: Any, isCurrent: () -> Boolean): Result<Unit> {
        val captured = owner as? Captured ?: return Result.failure(IllegalArgumentException("Invalid For You authority"))
        val detached = runCatching {
            ForYouSync.validate(field, value)
            if (value === JSONObject.NULL) JSONObject.NULL else JSONObject((value as JSONObject).toString())
        }.getOrElse { return Result.failure(it) }
        val operation = currentCoroutineContext()
        return withContext(ioDispatcher) { try {
            operation.ensureActive()
            captured.session.owned(captured.native) {
                check(captured.admission.admit {
                    operation.ensureActive()
                    check(isCurrent()) { "For You opening changed" }
                    check(observed.matches(fields(captured.session.read()), field)) { "For You field changed; draft preserved" }
                    captured.session.dispatch(emptyList(), captured.native,
                        profileFieldChanges = JSONObject().put(field, detached),
                        beforeCommit = { operation.ensureActive(); check(isCurrent()) { "For You opening changed" } })
                    true
                }) { "For You account or mount changed" }
            }
            Result.success(Unit)
        } catch (failure: Throwable) {
            if (failure is kotlinx.coroutines.CancellationException) throw failure
            Result.failure(failure)
        } }
    }
}
