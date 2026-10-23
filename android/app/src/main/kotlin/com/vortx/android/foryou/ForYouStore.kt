package com.vortx.android.foryou

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.profile.ProfileStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** The account's native `forYou.` host fields for the active profile, installed by the application. */
interface ForYouNativeGateway {
    val changes: Flow<Unit>
    /** The native active profile id and its `forYou.` registers; failure until the account is mounted. */
    fun read(): Result<Pair<String, JSONObject>>
    suspend fun write(profileId: String, field: String, value: Any): Result<Unit>
}

data class ForYouState(
    val profileId: String? = null,
    val interests: ForYouInterests? = null,
    val collections: List<SmartCollection> = emptyList(),
    /** The profile's saved choices are known (the account's native state loaded, or signed out). The
     * interests picker is only offered when ready, so a device that has not yet received another
     * device's answer never asks again. */
    val ready: Boolean = false,
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
) {
    private val _state = MutableStateFlow(ForYouState())
    val state: StateFlow<ForYouState> = _state.asStateFlow()

    @Volatile private var gateway: ForYouNativeGateway? = null
    private var changesJob: Job? = null

    init {
        registerProfileSwitch { reload() }
        reload()
    }

    /** Application wiring: the native account gateway, observed for remote and local host changes. */
    internal fun installNativeGateway(native: ForYouNativeGateway?) {
        changesJob?.cancel()
        gateway = native
        changesJob = native?.let { scope.launch { it.changes.collect { reload() } } }
        reload()
    }

    fun reload() {
        val profile = activeProfileId()
        _state.value = if (!signedIn()) {
            val (interests, collections) = ForYouSync.read(localFields(profile))
            ForYouState(profile, interests, collections, ready = profile != null)
        } else {
            // Signed in: only the account's native state is authority; until it is mounted, not ready.
            val read = gateway?.read()?.getOrNull()
            if (read != null && profile != null && read.first.equals(profile, ignoreCase = true)) {
                val (interests, collections) = ForYouSync.read(read.second)
                ForYouState(profile, interests, collections, ready = true)
            } else ForYouState(profile)
        }
    }

    suspend fun save(interests: ForYouInterests): Result<Unit> = write(ForYouInterests.FIELD, interests.toJson())
    suspend fun save(collection: SmartCollection): Result<Unit> = write(collection.field, collection.toJson())
    suspend fun delete(collection: SmartCollection): Result<Unit> = write(collection.field, JSONObject.NULL)

    private suspend fun write(field: String, value: Any): Result<Unit> {
        val profile = activeProfileId() ?: return Result.failure(IllegalStateException("No active profile"))
        val validated = runCatching { ForYouSync.validate(field, value) }
        if (validated.isFailure) return validated
        val result = if (signedIn()) {
            gateway?.write(profile, field, value) ?: Result.failure(IllegalStateException("Account not loaded yet"))
        } else withContext(Dispatchers.IO) { runCatching { writeLocal(profile, field, value) } }
        reload()
        return result
    }

    /** Signed-out copy: one object of `forYou.` registers per profile, so both paths share [ForYouSync.read]. */
    private fun localFields(profile: String?): JSONObject? {
        profile ?: return null
        val stored = localAll().optJSONObject(profile) ?: return null
        return JSONObject().also { fields -> stored.keys().forEach { fields.put(it, JSONObject().put("value", stored.get(it))) } }
    }

    private fun writeLocal(profile: String, field: String, value: Any) {
        val all = localAll()
        val fields = all.optJSONObject(profile) ?: JSONObject()
        if (value == JSONObject.NULL) fields.remove(field) else fields.put(field, value)
        all.put(profile, fields)
        check(prefs.edit().putString(LOCAL_KEY, all.toString()).commit()) { "Couldn't save For You locally" }
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
                    registerProfileSwitch = { ProfileStore.shared.addSwitchListener(it) },
                ).also { instance = it }
            }
        }
    }
}
