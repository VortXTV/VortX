package com.vortx.android.engine

import com.vortx.android.backup.SettingsBackup
import com.vortx.android.library.NativeWatchlistCodec
import com.vortx.android.library.NativeWatchlistGateway
import com.vortx.android.library.WatchlistEntry
import com.vortx.android.sync.SessionOwnerSnapshot
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64

/** Store callbacks acquire only their own publication monitor. Never enter this gateway while
 * holding that monitor: all operations use Session -> authenticated account -> mounted lifecycle. */
internal class NativeWatchlistAccess(private val accounts: NativeAccountCoordinator) : NativeWatchlistGateway {
    private data class Captured(val session: VortxNativeSession, val native: VortxNativeOwner,
                                val account: SessionOwnerSnapshot.Account, val fields: String) : NativeWatchlistGateway.Owner {
        override val accountId get() = native.scope.accountID
        override val profileId get() = native.profileID
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
        return JSONObject().also { result -> all.keys().asSequence().filter { it.startsWith(NativeWatchlistCodec.PREFIX) }.forEach {
            result.put(it, all.getJSONObject(it))
        } }
    }
    private fun snapshot(session: VortxNativeSession, account: SessionOwnerSnapshot.Account): NativeWatchlistGateway.Snapshot {
        val read = session.read()
        val fields = fields(read)
        val canonical = nativeWatchedDocumentSnapshot(fields).toString(Charsets.UTF_8)
        return NativeWatchlistGateway.Snapshot(Captured(session, read.owner, account, canonical),
            NativeProfileOverlayWitness.parseDocument(canonical.toByteArray(Charsets.UTF_8)))
    }
    override fun capture(): Result<NativeWatchlistGateway.Snapshot> = runCatching {
        val session = accounts.session(); val read = session.read()
        session.owned(read.owner) {
            val account = checkNotNull(accounts.accountFor(session))
            var result: NativeWatchlistGateway.Snapshot? = null
            check(accounts.withProfileMutation(session, account) { result = snapshot(session, account); true }) { "Watchlist account changed" }
            checkNotNull(result)
        }
    }
    override fun publishIfCurrent(expected: NativeWatchlistGateway.Owner, publication: () -> Unit): Boolean {
        val captured = expected as? Captured ?: return false
        return runCatching { captured.session.owned(captured.native) {
            accounts.withProfileMutation(captured.session, captured.account) {
                if (snapshot(captured.session, captured.account).owner != captured) false else { publication(); true }
            }
        } }.getOrDefault(false)
    }
    override suspend fun mutate(expected: NativeWatchlistGateway.Owner, changes: JSONObject): Result<NativeWatchlistGateway.Snapshot> {
        val captured = expected as? Captured ?: return Result.failure(IllegalArgumentException("Invalid Watchlist authority"))
        val detached = runCatching { NativeProfileOverlayWitness.parseDocument(nativeWatchedDocumentSnapshot(changes)) }
            .getOrElse { return Result.failure(it) }
        val operation = currentCoroutineContext()
        return withContext(Dispatchers.IO) { runCatching {
            operation.ensureActive()
            require(detached.length() in 1..NativeWatchlistCodec.MAX_ENTRIES)
            detached.keys().forEach { NativeWatchlistCodec.validate(it, detached.get(it)) }
            captured.session.owned(captured.native) {
                var result: NativeWatchlistGateway.Snapshot? = null
                check(accounts.withProfileMutation(captured.session, captured.account) {
                    check(snapshot(captured.session, captured.account).owner == captured) { "Watchlist changed before this action committed" }
                    val live = NativeWatchlistCodec.entries(fields(captured.session.read())).map { NativeWatchlistCodec.field(it.id, it.type) }.toMutableSet()
                    detached.keys().asSequence().filter { detached.isNull(it) }.forEach(live::remove)
                    detached.keys().asSequence().filterNot { detached.isNull(it) }.forEach { field ->
                        if (field !in live) require(live.size < NativeWatchlistCodec.MAX_ENTRIES) { "Watchlist is full; existing titles were preserved" }
                        live.add(field)
                    }
                    captured.session.dispatch(emptyList(), captured.native, profileFieldChanges = detached,
                        beforeCommit = { operation.ensureActive() })
                    result = snapshot(captured.session, captured.account)
                    true
                }) { "Watchlist account changed" }
                checkNotNull(result)
            }
        } }
    }
}

/** Only UUID-qualified Data in the authenticated SettingsBackup is legacy Watchlist authority.
 * Unqualified, foreign-profile, malformed or ambiguous inputs remain explicit preserved pending. */
internal data class NativeLegacyWatchlists(val profiles: Map<String, List<WatchlistEntry>>, val pending: JSONArray)
internal fun nativeLegacyWatchlists(document: JSONObject, profileIDs: Set<String>): NativeLegacyWatchlists {
    val pending = JSONArray(); val profiles = linkedMapOf<String, List<WatchlistEntry>>()
    val blob = document.opt("settings") ?: return NativeLegacyWatchlists(profiles, pending)
    if (blob == JSONObject.NULL) return NativeLegacyWatchlists(profiles, pending)
    val domain = runCatching { SettingsBackup.decodeDomain(Base64.getDecoder().decode(blob as String)) }.getOrNull()
        ?: return NativeLegacyWatchlists(profiles, pending.put(JSONObject().put("key", "settings").put("reason", "unreadable-settings")))
    for ((key, raw) in domain) {
        if (key != "vortx.watchlist" && !key.startsWith("vortx.watchlist.")) continue
        val id = key.removePrefix("vortx.watchlist.")
        val reason = if (id !in profileIDs || key != "vortx.watchlist.$id") "profile-attribution-required" else null
        val entries = if (reason == null) runCatching {
            require(raw is ByteArray)
            val value = NativeProfileOverlayWitness.parse(raw) as? JSONArray ?: error("Watchlist is not an array")
            NativeWatchlistCodec.legacyEntries(value).also { items -> items.forEach { entry ->
                NativeHostDocument.requireCredentialFree(JSONObject().put(NativeWatchlistCodec.field(entry.id, entry.type), NativeWatchlistCodec.value(entry)))
            } }
        }.getOrNull() else null
        if (entries == null) pending.put(JSONObject().put("key", key).put("reason", reason ?: "malformed-watchlist"))
        else profiles[id] = entries
    }
    return NativeLegacyWatchlists(profiles, pending)
}
