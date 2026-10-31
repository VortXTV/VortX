package com.vortx.android.foryou

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.profile.ProfileStore
import com.vortx.android.sync.LocalLibraryMutationAuthority
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import org.json.JSONArray
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** Actual editor-owned members, shared with raw conservation. Receive validation remains lenient;
 * these sets confer neither account authority nor permission to replace unknown objects/arrays. */
internal object ForYouEditFields {
    val interests = setOf("genres", "extras", "eras", "people", "decided")
    val collection = setOf("id", "name", "rules", "home", "createdAt")
    val rules = setOf("genres", "extras", "people", "yearFrom", "yearTo", "minRating", "type", "hideWatched", "sort")
    val person = setOf("id", "name", "department")
    fun numeric(field: String, path: List<String>): Boolean = ForYouSync.isCollectionField(field) &&
        (path == listOf("createdAt") || path.size == 2 && path[0] == "rules" && path[1] in setOf("yearFrom", "yearTo", "minRating"))
    fun people(field: String, path: List<String>): Boolean =
        field == ForYouInterests.FIELD && path == listOf("people") ||
            ForYouSync.isCollectionField(field) && path == listOf("rules", "people")
    fun representedId(value: Any?): Int? {
        val row = value as? JSONObject ?: return null
        val person = ForYouPerson.fromJson(row) ?: return null
        val number = row.opt("id") as? Number ?: return null
        return person.id.takeIf { number.toDouble() == it.toDouble() }
    }
    /** Reservation only. A rounded/truncated projection is NEVER original row edit authority. */
    fun reservedId(value: Any?): Int? = ((value as? JSONObject)?.opt("id") as? Number)?.toInt()?.takeIf { it > 0 }
}

/** The account's native `forYou.` host fields for the active profile, installed by the application. */
interface ForYouNativeGateway {
    interface Owner { val profileId: String; val scopeIdentity: Any }
    class Snapshot(val owner: Owner, fields: JSONObject, private val admission: (() -> Unit) -> Boolean) {
        private val accepted = fields.toString()
        val profileId get() = owner.profileId
        val fields get() = JSONObject(accepted)
        fun publishIfCurrent(action: () -> Unit): Boolean = admission(action)
    }
    val changes: Flow<Unit>
    fun capture(): Result<Snapshot>
    /** Command authority is distinct from read-only publication and was captured by the opening load. */
    suspend fun write(owner: Owner, field: String, observed: ForYouObservedField, value: Any,
                      isCurrent: () -> Boolean): Result<Unit>
}

/** Immutable observation of one register: absent differs from a retained null/tombstone. */
class ForYouObservedField private constructor(private val present: Boolean, private val register: String?) {
    internal fun value(): JSONObject? = register?.let(::JSONObject)?.optJSONObject("value")
    fun matches(fields: JSONObject, field: String): Boolean = present == fields.has(field) &&
        (!present || forYouJsonEqual(register?.let(::JSONObject), fields.opt(field)))
    override fun equals(other: Any?): Boolean = other is ForYouObservedField && present == other.present && register == other.register
    override fun hashCode(): Int = 31 * present.hashCode() + (register?.hashCode() ?: 0)
    companion object {
        fun capture(fields: JSONObject, field: String): ForYouObservedField =
            ForYouObservedField(fields.has(field), fields.optJSONObject(field)?.let(::forYouCanonical))
        internal fun absent() = ForYouObservedField(false, null)
    }
}

/** Identity only, safe to compare on Main without native/auth reads. */
internal class ForYouIdentityRef(private val value: Any) {
    override fun equals(other: Any?): Boolean = other is ForYouIdentityRef && value === other.value
    override fun hashCode(): Int = System.identityHashCode(value)
}

/** Key order is irrelevant, while all raw members and array positions remain part of the basis. */
internal fun forYouCanonical(value: Any?): String = when (value) {
    is JSONObject -> value.keys().asSequence().sorted().joinToString(prefix = "{", postfix = "}") {
        JSONObject.quote(it) + ":" + forYouCanonical(value.get(it))
    }
    is JSONArray -> (0 until value.length()).joinToString(prefix = "[", postfix = "]") { forYouCanonical(value.get(it)) }
    null, JSONObject.NULL -> "null"
    else -> JSONArray().put(value).toString().let { it.substring(1, it.length - 1) }
}

/** Structural register equality includes every clock/actor/value member and unknown siblings. */
internal fun forYouJsonEqual(a: Any?, b: Any?): Boolean = when {
    a === JSONObject.NULL || b === JSONObject.NULL -> a === JSONObject.NULL && b === JSONObject.NULL
    a is JSONObject && b is JSONObject -> a.keys().asSequence().toSet().let { keys ->
        keys == b.keys().asSequence().toSet() && keys.all { forYouJsonEqual(a.get(it), b.get(it)) }
    }
    a is JSONArray && b is JSONArray -> a.length() == b.length() &&
        (0 until a.length()).all { forYouJsonEqual(a.get(it), b.get(it)) }
    a is Number && b is Number -> runCatching {
        java.math.BigDecimal(a.toString()).compareTo(java.math.BigDecimal(b.toString())) == 0
    }.getOrDefault(false)
    else -> a == b
}

/** Opaque original Store load. Neither its source route nor its detached registers can be replaced. */
class ForYouOrigin internal constructor(
    internal val store: ForYouStore,
    internal val epoch: Long,
    internal val native: ForYouNativeGateway?,
    internal val owner: ForYouNativeGateway.Owner?,
    internal val localAuthority: LocalLibraryMutationAuthority?,
    fields: JSONObject,
) {
    // Build detached observations during refresh; prepare parses only its one bounded register.
    private val registers = fields.keys().asSequence().filter { it.startsWith(ForYouSync.PREFIX) }
        .associateWith { ForYouObservedField.capture(fields, it) }
    internal fun observed(field: String) = registers[field] ?: ForYouObservedField.absent()
    private val scope = owner?.scopeIdentity ?: localAuthority?.identity
    override fun equals(other: Any?): Boolean = other is ForYouOrigin && store === other.store && epoch == other.epoch &&
        native === other.native && scope == other.scope && registers == other.registers
    override fun hashCode(): Int = (((System.identityHashCode(store) * 31 + epoch.hashCode()) * 31 +
        System.identityHashCode(native)) * 31 + (scope?.hashCode() ?: 0)) * 31 + registers.hashCode()
}

/** One visible dialog lifetime. Revocation is atomic and safe under native command admission. */
class ForYouEditSession(val state: ForYouState) {
    private val active = AtomicBoolean(true)
    fun close() { active.set(false) }
    fun isActive(): Boolean = active.get()
    fun finishIfActive(action: () -> Unit) { if (active.compareAndSet(true, false)) action() }
}

class PreparedForYouWrite internal constructor(
    internal val edit: ForYouEditSession,
    internal val origin: ForYouOrigin,
    internal val profile: String,
    internal val field: String,
    internal val observed: ForYouObservedField,
    internal val encoded: String?,
)

data class ForYouState(
    val profileId: String? = null,
    val interests: ForYouInterests? = null,
    val collections: List<SmartCollection> = emptyList(),
    /** A load and its original command target have both been admitted. */
    val ready: Boolean = false,
    val origin: ForYouOrigin? = null,
) {
    val homeCollections: List<SmartCollection> get() = collections.filter { it.home }
}

/**
 * The active profile's For You interests and smart collections. Signed in, the source is the account's
 * native state (synced to every device); signed out, a local per-profile copy in the same field shape.
 * Mirrors Apple `ForYouStore`.
 */
class ForYouStore internal constructor(
    private val prefs: SharedPreferences,
    private val activeProfileId: () -> String?,
    private val signedIn: () -> Boolean,
    registerProfileSwitch: ((() -> Unit) -> Unit),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val mainDispatcher: CoroutineDispatcher = Dispatchers.Main,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val captureLocalAuthority: () -> LocalLibraryMutationAuthority? = { null },
) {
    private val _state = MutableStateFlow(ForYouState())
    val state: StateFlow<ForYouState> = _state.asStateFlow()

    @Volatile private var gateway: ForYouNativeGateway? = null
    private var changesJob: Job? = null
    private val publicationLock = Any()
    private var reloadGeneration = 0L
    private var reloadJob: Job? = null
    private val reloadMutex = Mutex()
    private val localMutex = Mutex()
    private val authorityEpoch = AtomicLong()

    init {
        registerProfileSwitch { reload(invalidate = true) }
        reload(invalidate = true)
    }

    /** Application wiring: the native account gateway, observed for remote and local host changes. */
    internal fun installNativeGateway(native: ForYouNativeGateway?) {
        changesJob?.cancel()
        gateway = native
        changesJob = native?.let { scope.launch { it.changes.collect { reload() } } }
        reload(invalidate = true)
    }

    /** May run under native lifecycle admission: only retire local publication, never capture here. */
    internal fun invalidateNativeAuthority() {
        val old = synchronized(publicationLock) {
            reloadGeneration++
            authorityEpoch.incrementAndGet()
            _state.value = ForYouState()
            reloadJob.also { reloadJob = null }
        }
        old?.cancel()
    }

    /** Synchronous profile listeners only clear/schedule. Native reads and parsing belong to IO. */
    fun reload(invalidate: Boolean = false) {
        val old: Job?
        val job: Job
        synchronized(publicationLock) {
            val generation = ++reloadGeneration
            val native = gateway
            if (invalidate) { authorityEpoch.incrementAndGet(); _state.value = ForYouState() }
            old = reloadJob
            job = scope.launch(start = CoroutineStart.LAZY) { reload(generation, native) }
            reloadJob = job
        }
        old?.cancel()
        job.start()
    }

    private suspend fun reload(generation: Long, native: ForYouNativeGateway?) {
        val profile = withContext(mainDispatcher) { activeProfileId() }
        val authenticated = withContext(ioDispatcher) { signedIn() }
        val epoch = authorityEpoch.get()
        try {
            val captured = withContext(ioDispatcher) {
                reloadMutex.withLock {
                    currentCoroutineContext().ensureActive()
                    synchronized(publicationLock) {
                        check(generation == reloadGeneration && gateway === native) { "For You reload was superseded" }
                    }
                    if (authenticated) checkNotNull(native) { "Account not loaded yet" }.capture().getOrThrow() else null
                }
            }
            val localAuthority = if (authenticated) null else withContext(ioDispatcher) {
                checkNotNull(captureLocalAuthority()) { "Signed-out authority unavailable" }
            }
            val fields = withContext(ioDispatcher) {
                if (authenticated) checkNotNull(captured).fields else localMutex.withLock {
                    var result: JSONObject? = null
                    check(checkNotNull(localAuthority).admit { result = localFields(profile) ?: JSONObject(); true }) {
                        "Signed-out authority changed"
                    }
                    checkNotNull(result)
                }
            }
            val (interests, collections) = withContext(ioDispatcher) { ForYouSync.read(fields) }
            val origin = withContext(ioDispatcher) {
                ForYouOrigin(this@ForYouStore, epoch, if (authenticated) native else null, captured?.owner, localAuthority, fields)
            }
            withContext(mainDispatcher) {
                // Read plain ProfileStore state only on Main and outside authenticated admission.
                if (activeProfileId() != profile || signedIn() != authenticated) return@withContext
                val publication = {
                    synchronized(publicationLock) {
                        if (generation == reloadGeneration && gateway === native && epoch == authorityEpoch.get()) {
                            _state.value = ForYouState(profile, interests, collections,
                                ready = profile != null && (!authenticated || captured?.profileId.equals(profile, ignoreCase = true)),
                                origin = origin)
                        }
                    }
                    Unit
                }
                if (authenticated) {
                    if (profile != null && captured?.profileId.equals(profile, ignoreCase = true)) captured?.publishIfCurrent(publication)
                } else checkNotNull(localAuthority).admit { publication(); true }
            }
        } catch (failure: Exception) {
            if (failure is kotlinx.coroutines.CancellationException) throw failure
            clearFailedReload(generation, native, profile)
        } catch (_: LinkageError) {
            clearFailedReload(generation, native, profile)
        }
    }

    private fun clearFailedReload(generation: Long, native: ForYouNativeGateway?, profile: String?) = synchronized(publicationLock) {
        if (generation == reloadGeneration && gateway === native) _state.value = ForYouState(profile)
    }

    /** Prepare synchronously from what the dialog rendered, before launching any coroutine. */
    fun prepare(edit: ForYouEditSession, interests: ForYouInterests): Result<PreparedForYouWrite> =
        prepare(edit, ForYouInterests.FIELD, interests.toJson(), ForYouEditFields.interests)

    fun prepare(edit: ForYouEditSession, collection: SmartCollection): Result<PreparedForYouWrite> =
        prepare(edit, collection.field, collection.toJson(), ForYouEditFields.collection)

    fun prepareDelete(edit: ForYouEditSession, collection: SmartCollection): Result<PreparedForYouWrite> =
        prepare(edit, collection.field, JSONObject.NULL, emptySet())

    private fun prepare(edit: ForYouEditSession, field: String, value: Any, keys: Set<String>): Result<PreparedForYouWrite> = runCatching {
        val original = edit.state
        val origin = checkNotNull(original.origin) { "For You is not ready" }
        check(original.ready && origin.store === this && origin.epoch == authorityEpoch.get() && edit.isActive()) {
            "For You opening changed; keep this draft and reopen on the intended profile"
        }
        val observed = origin.observed(field)
        // Overlay only DTO-owned keys; safe unknown value/rules members survive an older editor.
        val merged = if (value is JSONObject) {
            val previous = observed.value()
            val result = previous?.let { JSONObject(it.toString()) } ?: JSONObject()
            val baseline = if (field == ForYouInterests.FIELD) ForYouInterests.fromJson(previous)?.toJson()
                else SmartCollection.fromJson(previous)?.toJson()
            fun overlay(target: JSONObject, before: JSONObject?, after: JSONObject, owned: Set<String>) {
                owned.forEach { key ->
                    // An unchanged fallback DTO value must not erase a newer app's enum/representation.
                    if (before == null || before.has(key) != after.has(key) || !forYouJsonEqual(before.opt(key), after.opt(key))) {
                        if (after.has(key)) target.put(key, after.get(key)) else target.remove(key)
                    }
                }
                if ("people" in owned && (before == null || before.has("people") != after.has("people") ||
                        !forYouJsonEqual(before.opt("people"), after.opt("people")))) {
                    val raw = previous?.let { if (target === result) it else it.optJSONObject("rules") }?.optJSONArray("people")
                    val represented = before?.optJSONArray("people") ?: JSONArray()
                    val edited = after.optJSONArray("people") ?: JSONArray()
                    fun recognized(array: JSONArray): Map<Int, List<JSONObject>> = (0 until array.length()).mapNotNull { index ->
                        val objectValue = array.optJSONObject(index) ?: return@mapNotNull null
                        val id = ForYouEditFields.representedId(objectValue) ?: return@mapNotNull null
                        id to objectValue
                    }.groupBy({ it.first }, { it.second })
                    val originals = raw?.let(::recognized).orEmpty()
                    // A future record with a numeric ID but an unknown shape still reserves its ID.
                    val rawIDs = raw?.let { array -> (0 until array.length()).mapNotNull { index ->
                        ForYouEditFields.reservedId(array.opt(index))
                    }.groupingBy { it }.eachCount() }.orEmpty()
                    val decoded = recognized(represented)
                    val proposed = recognized(edited)
                    val resolved = mutableSetOf<Int>()
                    val merged = JSONArray()
                    // Unknown/unrepresented/ambiguous raw entries have no DTO deletion authority.
                    raw?.let { array -> for (index in 0 until array.length()) {
                        val entry = array.get(index)
                        val person = ForYouPerson.fromJson(entry)
                        val id = person?.id
                        val unique = id != null && rawIDs[id] == 1 && originals[id]?.size == 1 && decoded[id]?.size == 1
                        if (!unique) { merged.put(entry); continue }
                        checkNotNull(id)
                        val replacement = proposed[id]
                        if (replacement == null) { resolved.add(id); continue } // intentional removal of one recognized ID
                        if (replacement.size != 1) { merged.put(entry); resolved.add(id); continue }
                        val resultPerson = JSONObject((entry as JSONObject).toString())
                        val known = replacement.single()
                        val baselinePerson = decoded.getValue(id).single()
                        ForYouEditFields.person.forEach { key ->
                            if (baselinePerson.has(key) != known.has(key) || !forYouJsonEqual(baselinePerson.opt(key), known.opt(key))) {
                                if (known.has(key)) resultPerson.put(key, known.get(key)) else resultPerson.remove(key)
                            }
                        }
                        merged.put(resultPerson); resolved.add(id)
                    } }
                    for (index in 0 until edited.length()) {
                        val entry = edited.get(index)
                        val person = ForYouPerson.fromJson(entry) ?: continue
                        // Never borrow or append against an ambiguous existing/raw/proposed identity.
                        if (person.id !in resolved && rawIDs[person.id] == null && proposed[person.id]?.size == 1) {
                            merged.put(entry); resolved.add(person.id)
                        }
                    }
                    target.put("people", merged)
                }
            }

            overlay(result, baseline, value, keys - "rules")
            if (field.startsWith(SmartCollection.FIELD_PREFIX)) {
                val rules = previous?.optJSONObject("rules")?.let { JSONObject(it.toString()) } ?: JSONObject()
                val updated = value.getJSONObject("rules")
                overlay(rules, baseline?.optJSONObject("rules"), updated,
                    ForYouEditFields.rules)
                result.put("rules", rules)
            }
            result
        } else JSONObject.NULL
        ForYouSync.validate(field, merged)
        PreparedForYouWrite(edit, origin, checkNotNull(original.profileId), field, observed,
            if (merged === JSONObject.NULL) null else merged.toString())
    }

    /** No fresh route, Session, profile or account selection is permitted after preparation. */
    suspend fun execute(intent: PreparedForYouWrite): Result<Unit> {
        val operation = currentCoroutineContext()
        val origin = intent.origin
        val current = { origin.store === this && origin.epoch == authorityEpoch.get() && intent.edit.isActive() }
        val result = try {
            operation.ensureActive()
            check(current()) { "For You opening changed" }
            val value = intent.encoded?.let(::JSONObject) ?: JSONObject.NULL
            val native = origin.native
            if (native != null) native.write(checkNotNull(origin.owner), intent.field, intent.observed, value, current)
            else withContext(ioDispatcher) { try {
                localMutex.withLock {
                    check(checkNotNull(origin.localAuthority).admit {
                        operation.ensureActive()
                        check(current()) { "For You opening changed" }
                        val all = localAll()
                        val fields = localFields(intent.profile, all) ?: JSONObject()
                        check(intent.observed.matches(fields, intent.field)) { "For You field changed; draft preserved" }
                        val local = all.optJSONObject(intent.profile) ?: JSONObject()
                        local.put(intent.field, value)
                        all.put(intent.profile, local)
                        operation.ensureActive()
                        check(current()) { "For You opening changed" }
                        check(prefs.edit().putString(LOCAL_KEY, all.toString()).commit()) { "Couldn't save For You locally" }
                        true
                    }) { "Signed-out authority changed" }
                }
                Result.success(Unit)
            } catch (failure: Throwable) {
                if (failure is kotlinx.coroutines.CancellationException) throw failure
                Result.failure(failure)
            } }
        } catch (failure: Exception) {
            if (failure is kotlinx.coroutines.CancellationException) throw failure
            Result.failure(failure)
        }
        // An old completion has no right to clear or reload a successor Store view.
        if (current()) reload()
        return result
    }

    /** Signed-out copy: one object of `forYou.` registers per profile, so both paths share [ForYouSync.read]. */
    private fun localFields(profile: String?, all: JSONObject = localAll()): JSONObject? {
        profile ?: return null
        val stored = all.optJSONObject(profile) ?: return null
        return JSONObject().also { fields -> stored.keys().forEach { fields.put(it, JSONObject().put("value", stored.get(it))) } }
    }

    private fun localAll(): JSONObject = runCatching { JSONObject(prefs.getString(LOCAL_KEY, null) ?: "{}") }.getOrDefault(JSONObject())

    companion object {
        internal const val LOCAL_KEY = "vortx.forYou.local"

        @Volatile private var instance: ForYouStore? = null

        fun shared(context: Context): ForYouStore = instance ?: synchronized(this) {
            instance ?: run {
                val app = context.applicationContext
                ForYouStore(
                    prefs = app.getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE),
                    activeProfileId = { ProfileStore.shared.activeProfileId },
                    signedIn = { (app as? com.vortx.android.VortXApplication)?.syncManager?.isSignedIn == true },
                    registerProfileSwitch = { invalidate ->
                        ProfileStore.shared.addPlaylistScopeTransitionListener { transition ->
                            if (transition == com.vortx.android.profile.PlaylistScopeTransition.AUTHORITY_BOUNDARY) invalidate()
                        }
                    },
                    captureLocalAuthority = {
                        (app as? com.vortx.android.VortXApplication)?.syncManager?.let { manager ->
                            val authority = manager.captureLocalLibraryMutationAuthority()
                            if (manager.sessionOwnerSnapshot() !is com.vortx.android.sync.SessionOwnerSnapshot.SignedOutLocal) null
                            else authority?.let { captured ->
                                val gate: (() -> Boolean) -> Boolean = { action -> captured.admit {
                                    (app as? com.vortx.android.VortXApplication)?.syncManager === manager &&
                                        manager.sessionUiState.value == com.vortx.android.sync.VortXSyncManager.SessionUiState.SignedOut && action()
                                } }
                                LocalLibraryMutationAuthority(captured.identity, gate)
                            }
                        }
                    },
                ).also { instance = it }
            }
        }
    }
}
