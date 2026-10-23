package com.vortx.android.engine

import com.vortx.android.foryou.ForYouNativeGateway
import com.vortx.android.foryou.ForYouSync
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * The active native profile's `forYou.` host fields (interests and smart collections). Writes go through
 * the same Session -> authenticated account -> mounted lifecycle fence as [NativeWatchlistAccess], so an
 * edit lands only on the profile and account it was made for, and syncs like the watchlist.
 */
internal class NativeForYouAccess(private val accounts: NativeAccountCoordinator) : ForYouNativeGateway {
    override val changes: Flow<Unit> = channelFlow {
        accounts.changes.collectLatest {
            send(Unit)
            runCatching { accounts.session() }.getOrNull()?.updates?.collect { send(Unit) }
        }
    }

    override fun read(): Result<Pair<String, JSONObject>> = runCatching {
        val read = accounts.session().read()
        val all = read.state.getJSONObject("nativeHostPreferenceState").getJSONObject("document")
            .getJSONObject("profiles").optJSONObject(read.owner.profileID)?.getJSONObject("fields") ?: JSONObject()
        read.owner.profileID to JSONObject().also { fields ->
            all.keys().asSequence().filter { it.startsWith(ForYouSync.PREFIX) }.forEach { fields.put(it, all.getJSONObject(it)) }
        }
    }

    override suspend fun write(profileId: String, field: String, value: Any): Result<Unit> {
        val operation = currentCoroutineContext()
        return withContext(Dispatchers.IO) { runCatching {
            ForYouSync.validate(field, value)
            val session = accounts.session()
            val read = session.read()
            check(read.owner.profileID.equals(profileId, ignoreCase = true)) { "Profile changed before this edit committed" }
            session.owned(read.owner) {
                val account = checkNotNull(accounts.accountFor(session))
                check(accounts.withProfileMutation(session, account) {
                    operation.ensureActive()
                    session.dispatch(emptyList(), read.owner, profileFieldChanges = JSONObject().put(field, value),
                        beforeCommit = { operation.ensureActive() })
                    true
                }) { "For You account changed" }
            }
        } }
    }
}
