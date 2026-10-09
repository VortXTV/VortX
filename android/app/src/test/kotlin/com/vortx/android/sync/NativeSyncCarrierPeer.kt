package com.vortx.android.sync

import com.vortx.android.engine.NativeHostPreferences
import com.vortx.android.engine.VortxAccountScope
import com.vortx.android.engine.VortxCore
import com.vortx.android.engine.VortxEncryptedCheckpointStore
import com.vortx.android.engine.VortxNativeSession
import com.vortx.android.engine.VortxResourceCancellation
import com.vortx.android.engine.VortxResourceTransport
import com.vortx.android.engine.VortxRuntimeBindings
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.util.UUID
import javax.crypto.spec.SecretKeySpec
import org.json.JSONArray
import org.json.JSONObject
import kotlin.system.exitProcess

/**
 * A small process-per-invocation Android peer for the native sync acceptance harness.
 *
 * The peer deliberately mounts the same production session and encrypted checkpoint store used by
 * the app.  The only test seam is the JNI library path supplied by the runner; no fake kernel or
 * host-preference implementation is used here.  Keeping this as a CLI makes every invocation a
 * cold restart, which is useful for checking checkpoint durability and stale prepared envelopes.
 */
object NativeSyncCarrierPeer {
    private const val ACCOUNT_ID = "account.sync-fixture"
    private const val OWNER_PROFILE_ID = "10000000-0000-0000-0000-000000000001"
    private const val FIXTURE_BEARER = "fixture-only"
    private const val BACKUP_PATH = "/v1/backup"
    private const val PREPARED_NAME = "prepared.json"

    private val dataKey = ByteArray(32) { 1 }

    private data class RemoteDocument(
        val status: Int,
        val version: Long,
        val encrypted: String?,
        val response: JSONObject?,
        val accepted: Boolean? = null,
    )

    private data class OpenDocument(
        val status: Int,
        val version: Long,
        val document: JSONObject?,
        val encrypted: String?,
        val response: JSONObject?,
    )

    private data class PeerResult(
        val accepted: Boolean? = null,
        val version: Long? = null,
        val baseVersion: Long? = null,
        val state: JSONObject,
        val nativeHostPreferences: JSONObject,
        val playback: JSONObject,
        val installedAddons: JSONArray,
        val document: JSONObject? = null,
    ) {
        fun json(): JSONObject = JSONObject().also { out ->
            accepted?.let { out.put("accepted", it) }
            version?.let { out.put("version", it) }
            baseVersion?.let { out.put("baseVersion", it) }
            // All inputs are synthetic fixture data. Preserve the public projections exactly so
            // the acceptance harness can detect a kernel or host-schema mutation; credentials are
            // never supplied to this peer and the fixture account/key are not user secrets.
            out.put("state", JSONObject(state.toString()))
            out.put("nativeHostPreferences", JSONObject(nativeHostPreferences.toString()))
            out.put("playback", JSONObject(playback.toString()))
            out.put("installedAddons", JSONArray(installedAddons.toString()))
            document?.let { out.put("document", JSONObject(it.toString())) }
        }
    }

    @JvmStatic
    fun main(args: Array<String>) {
        if (args.size != 1) {
            println(JSONObject().put("accepted", false).put("error", "expected one JSON input path"))
            exitProcess(2)
        }
        try {
            val inputPath = File(args[0]).canonicalFile
            val config = JSONObject(inputPath.readText(Charsets.UTF_8))
            val result = execute(config)
            println(result.json().toString())
        } catch (error: Throwable) {
            // Keep stdout machine-readable. The shell wrapper propagates a non-zero exit status so
            // a malformed fixture cannot be confused with a normal optimistic-concurrency reject.
            val message = if (System.getenv("VORTX_NATIVE_SYNC_DEBUG") == "1") {
                error.stackTraceToString().take(4_000)
            } else {
                error.message?.take(500) ?: error::class.java.simpleName
            }
            println(JSONObject().put("accepted", false).put("error", message).toString())
            exitProcess(1)
        }
    }

    private fun execute(config: JSONObject): PeerResult {
        val mode = config.getString("mode")
        require(mode in setOf("inspect", "edit", "prepare", "push", "pull")) { "Unsupported mode: $mode" }
        val directory = File(config.getString("directory")).canonicalFile
        Files.createDirectories(directory.toPath())
        val scope = VortxAccountScope(ACCOUNT_ID, OWNER_PROFILE_ID)
        // Validate the command actor so malformed fixture input fails before mounting the
        // checkpoint. The production host-preference wrapper owns its actor locally; passing the
        // command's actor as the public document would violate NativeHostPreferences' schema.
        UUID.fromString(config.getString("actor"))
        val baseUrl = config.optString("baseURL", "").trim()
        require(mode == "inspect" || mode == "edit" || baseUrl.isNotEmpty()) { "baseURL is required for $mode" }

        loadJni()
        val store = VortxEncryptedCheckpointStore(directory) { SecretKeySpec(dataKey, "AES") }
        val session = openSession(scope, store)
        try {
            return when (mode) {
                "inspect" -> result(session, accepted = true)
                "edit" -> {
                    applyLocalInput(session, config)
                    result(session, accepted = true)
                }
                "pull" -> pull(session, scope, baseUrl)
                "prepare" -> prepare(session, scope, config, baseUrl)
                "push" -> push(session, scope, config, baseUrl)
                else -> error("Unsupported mode: $mode")
            }
        } finally {
            session.close()
        }
    }

    private fun loadJni() {
        val path = System.getenv("VORTX_JNI_LIBRARY")
            ?: error("VORTX_JNI_LIBRARY must name the reviewed native fixture")
        val library = File(path).canonicalFile
        require(library.isFile) { "JNI fixture does not exist: ${library.path}" }
        // The runner verifies the immutable digest before starting this process. Loading the exact
        // path also avoids the platform library search path selecting a different libvortx_ffi.so.
        System.load(library.path)
    }

    private fun openSession(
        scope: VortxAccountScope,
        store: VortxEncryptedCheckpointStore,
    ): VortxNativeSession {
        return VortxNativeSession.open(
            scope = scope,
            ownerName = "Sync Fixture",
            bindings = JNI_BINDINGS,
            store = store,
            transport = NO_NETWORK,
            allowNewAccount = true,
            initialHostPreferences = NativeHostPreferences.empty(scope),
        )
    }

    private fun applyLocalInput(session: VortxNativeSession, config: JSONObject) {
        val actions = jsonObjects(config.optJSONArray("actions"))
        val edits = jsonObjects(config.optJSONArray("hostEdits"))
        if (edits.isEmpty()) {
            if (actions.isNotEmpty()) session.dispatch(actions)
            return
        }
        // NativeHostPreferences exposes one profile edit or one global edit per transaction. Keep
        // each supplied edit in its own production transaction; clocks and durable pending state
        // therefore have exactly the same behavior as separate app mutations.
        var first = true
        for (edit in edits) {
            val profileID = if (edit.has("profileID") && !edit.isNull("profileID")) edit.getString("profileID") else null
            val fields = edit.optJSONObject("fields") ?: JSONObject()
            if (profileID != null) {
                val activeProfileID = session.read().state.getString("activeProfileId")
                require(profileID == activeProfileID) {
                    "Host profile edit target $profileID is not the active profile $activeProfileID"
                }
            }
            session.dispatch(
                actions = if (first) actions else emptyList(),
                profileFieldChanges = profileID?.let { fields },
                globalChanges = if (profileID == null) fields else null,
            )
            first = false
        }
    }

    private fun pull(session: VortxNativeSession, scope: VortxAccountScope, baseUrl: String): PeerResult {
        val remote = decodeRemote(fetch(baseUrl), scope)
        if (remote.document != null) mergeRemote(session, remote.document)
        return result(
            session,
            accepted = true,
            version = remote.version.takeIf { remote.status == HttpURLConnection.HTTP_OK },
            baseVersion = remote.version,
            document = remote.document?.let { exportDocument(it, session) },
        )
    }

    private fun prepare(
        session: VortxNativeSession,
        scope: VortxAccountScope,
        config: JSONObject,
        baseUrl: String,
    ): PeerResult {
        applyLocalInput(session, config)
        val remote = decodeRemote(fetch(baseUrl), scope)
        val base = remote.document ?: JSONObject()
        mergeRemote(session, base)
        val exported = exportDocument(base, session)
        val version = requestedVersion(config, remote.version)
        val encrypted = VortXCrypto.sealDocument(
            dataKey = dataKey,
            plaintext = exported.toString().toByteArray(Charsets.UTF_8),
            accountId = ACCOUNT_ID,
            version = version,
            writeV2 = true,
        ) ?: error("Could not seal prepared sync document")
        val prepared = JSONObject().put("document", encrypted).put("version", version)
        writePrepared(File(config.getString("directory")).canonicalFile, prepared)
        return result(session, accepted = true, version = version, baseVersion = remote.version, document = exported)
    }

    private fun push(
        session: VortxNativeSession,
        scope: VortxAccountScope,
        config: JSONObject,
        baseUrl: String,
    ): PeerResult {
        val prepared = readPrepared(File(config.getString("directory")).canonicalFile)
        val preparedVersion = prepared.getLong("version")
        val plain = openPrepared(prepared, preparedVersion)
        val requested = config.optLong("wireVersion", preparedVersion)
        require(requested > 0) { "wireVersion must be positive" }
        val body = if (requested == preparedVersion) {
            JSONObject(prepared.toString())
        } else {
            val resealed = VortXCrypto.sealDocument(
                dataKey = dataKey,
                plaintext = plain.toString().toByteArray(Charsets.UTF_8),
                accountId = ACCOUNT_ID,
                version = requested,
                writeV2 = true,
            ) ?: error("Could not reseal prepared sync document")
            JSONObject().put("document", resealed).put("version", requested)
        }
        val response = put(baseUrl, body)
        val responseVersion = response.version.takeIf { it >= 0 } ?: requested
        return result(
            session,
            accepted = response.accepted,
            version = responseVersion,
            document = plain,
        )
    }

    private fun result(
        session: VortxNativeSession,
        accepted: Boolean? = null,
        version: Long? = null,
        baseVersion: Long? = null,
        document: JSONObject? = null,
    ): PeerResult {
        val read = session.read()
        val state = JSONObject(read.state.toString())
        val native = state.getJSONObject("nativeSync")
        require(!native.has("activeProfileId")) { "Native state leaked activeProfileId" }
        val host = JSONObject(state.getJSONObject("nativeHostPreferenceState").getJSONObject("document").toString())
        val active = state.getString("activeProfileId")
        val playback = session.resolveCommitted(
            JSONObject().put("kind", "profile_playback").put("profileId", active), read.owner,
        )
        val profiles = state.getJSONObject("roster").getJSONObject("profiles")
        val activeProfile = profiles.getJSONObject(active)
        val addonOwner = if (activeProfile.optString("addons") == "share_primary") read.owner.scope.ownerProfileID else active
        val installed = session.resolveCommitted(
            JSONObject().put("kind", "installed_addons").put("profileId", addonOwner), read.owner,
        )
        val installedUrls = JSONArray().also { urls ->
            val addons = installed.getJSONArray("addons")
            for (index in 0 until addons.length()) urls.put(addons.getJSONObject(index).getString("transportUrl"))
        }
        return PeerResult(accepted, version, baseVersion, state, host, playback, installedUrls, document)
    }

    /** Export only the carriers this peer owns while retaining every unrelated cloud sibling. */
    private fun exportDocument(base: JSONObject, session: VortxNativeSession): JSONObject {
        val state = session.read().state
        require(!base.has("activeProfileId")) { "Cloud document leaked activeProfileId" }
        val result = JSONObject(base.toString())
        val native = JSONObject(state.getJSONObject("nativeSync").toString())
        require(!native.has("activeProfileId")) { "Native state leaked activeProfileId" }
        result.put("nativeSync", native)
        result.put("nativeHostPreferences", JSONObject(state.getJSONObject("nativeHostPreferenceState").getJSONObject("document").toString()))
        return result
    }

    private fun mergeRemote(session: VortxNativeSession, document: JSONObject) {
        require(!document.has("activeProfileId")) { "Cloud document leaked activeProfileId" }
        val native = document.optJSONObject("nativeSync")
        require(native?.has("activeProfileId") != true) { "Native document leaked activeProfileId" }
        val host = document.optJSONObject("nativeHostPreferences")
        if (native == null && host == null) return
        val actions = native?.let { listOf(JSONObject().put("type", "merge_native_sync").put("document", JSONObject(it.toString()))) }
            ?: emptyList()
        session.dispatch(actions, notifyMutation = false, remoteHostPreferences = host?.let { JSONObject(it.toString()) })
    }

    private fun fetch(baseUrl: String): RemoteDocument {
        val connection = openConnection(baseUrl, "GET")
        val status = connection.responseCode
        val parsed = readJson(connection, status)
        connection.disconnect()
        val version = parsed?.optLong("version", 0L) ?: 0L
        val encrypted = parsed?.optString("document", "")?.takeIf { it.isNotEmpty() }
        return RemoteDocument(status, version, encrypted, parsed)
    }

    private fun put(baseUrl: String, body: JSONObject): RemoteDocument {
        val connection = openConnection(baseUrl, "PUT")
        connection.doOutput = true
        val bytes = body.toString().toByteArray(Charsets.UTF_8)
        connection.outputStream.use { it.write(bytes) }
        val status = connection.responseCode
        val parsed = readJson(connection, status)
        connection.disconnect()
        val version = parsed?.optLong("version", -1L) ?: -1L
        val accepted = parsed?.let { if (it.has("accepted")) it.optBoolean("accepted") else status in 200..299 }
            ?: (status in 200..299)
        return RemoteDocument(
            status = status,
            version = version,
            encrypted = body.optString("document", ""),
            response = parsed?.put("accepted", accepted),
            accepted = accepted,
        )
    }

    private fun openConnection(baseUrl: String, method: String): HttpURLConnection {
        val endpoint = backupUrl(baseUrl)
        val connection = URI(endpoint).toURL().openConnection() as HttpURLConnection
        connection.requestMethod = method
        connection.connectTimeout = 10_000
        connection.readTimeout = 20_000
        connection.setRequestProperty("Accept", "application/json")
        connection.setRequestProperty("Authorization", "Bearer $FIXTURE_BEARER")
        if (method == "PUT") connection.setRequestProperty("Content-Type", "application/json")
        return connection
    }

    private fun backupUrl(baseUrl: String): String {
        val uri = URI(baseUrl.trimEnd('/'))
        require(uri.scheme == "http" && uri.host == "127.0.0.1" && uri.userInfo == null && uri.query == null && uri.fragment == null) {
            "Sync fixture endpoint must be an http://127.0.0.1 URL"
        }
        require(uri.path.isEmpty() || uri.path == "/" || uri.path == BACKUP_PATH) {
            "Sync fixture endpoint path is invalid"
        }
        val trimmed = uri.toString().trimEnd('/')
        return if (trimmed.endsWith(BACKUP_PATH)) trimmed else trimmed + BACKUP_PATH
    }

    private fun readJson(connection: HttpURLConnection, status: Int): JSONObject? {
        val stream = if (status >= 400) connection.errorStream else connection.inputStream
        val text = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() } ?: return null
        return text.takeIf { it.isNotBlank() }?.let(::JSONObject)
    }

    private fun decodeRemote(remote: RemoteDocument, scope: VortxAccountScope): OpenDocument {
        if (remote.status == HttpURLConnection.HTTP_NOT_FOUND) return OpenDocument(remote.status, 0, null, null, remote.response)
        require(remote.status == HttpURLConnection.HTTP_OK) { "Sync GET failed with HTTP ${remote.status}" }
        if (remote.encrypted == null && remote.version == 0L) return OpenDocument(remote.status, 0, null, null, remote.response)
        val encrypted = requireNotNull(remote.encrypted) { "Sync response has no document" }
        require(remote.version >= 0) { "Sync response has invalid version" }
        val plain = VortXCrypto.openDocument(dataKey, encrypted, ACCOUNT_ID, remote.version)
            ?: error("Sync document could not be decrypted")
        val document = JSONObject(String(plain, Charsets.UTF_8))
        return OpenDocument(remote.status, remote.version, document, encrypted, remote.response)
    }

    private fun readPrepared(directory: File): JSONObject {
        val path = File(directory, PREPARED_NAME)
        require(path.isFile) { "Prepared sync envelope is missing: ${path.path}" }
        return JSONObject(path.readText(Charsets.UTF_8)).also {
            require(it.getString("document").isNotEmpty()) { "Prepared document is empty" }
            require(it.getLong("version") > 0) { "Prepared version is invalid" }
        }
    }

    private fun openPrepared(prepared: JSONObject, version: Long): JSONObject {
        val plain = VortXCrypto.openDocument(dataKey, prepared.getString("document"), ACCOUNT_ID, version)
            ?: error("Prepared sync document could not be decrypted")
        return JSONObject(String(plain, Charsets.UTF_8)).also { document ->
            require(!document.has("activeProfileId")) { "Prepared document leaked activeProfileId" }
            require(document.optJSONObject("nativeSync")?.has("activeProfileId") != true) {
                "Prepared native document leaked activeProfileId"
            }
        }
    }

    private fun writePrepared(directory: File, body: JSONObject) {
        Files.createDirectories(directory.toPath())
        val target = File(directory, PREPARED_NAME).toPath()
        val pending = Files.createTempFile(directory.toPath(), "prepared-", ".pending")
        try {
            Files.write(pending, body.toString().toByteArray(Charsets.UTF_8), StandardOpenOption.TRUNCATE_EXISTING)
            Files.move(pending, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally {
            Files.deleteIfExists(pending)
        }
    }

    private fun requestedVersion(config: JSONObject, baseVersion: Long): Long {
        val explicit = config.optLong("wireVersion", Long.MIN_VALUE)
        if (explicit != Long.MIN_VALUE) {
            require(explicit > 0) { "wireVersion must be positive" }
            return explicit
        }
        val base = config.optLong("baseVersion", baseVersion)
        require(base >= 0) { "baseVersion must be non-negative" }
        return base + 1
    }

    private fun jsonObjects(array: JSONArray?): List<JSONObject> = array?.let {
        (0 until it.length()).map { index -> it.getJSONObject(index) }
    } ?: emptyList()

    private fun error(message: String): Nothing = throw IllegalArgumentException(message)

    private val NO_NETWORK = object : VortxResourceTransport {
        override fun makeCancellation(): VortxResourceCancellation = object : VortxResourceCancellation {
            override fun cancel() = Unit
            override fun close() = Unit
        }

        override fun load(requestJson: String, cancellation: VortxResourceCancellation): String =
            error("Provider resource access is outside the sync fixture")
    }

    private val JNI_BINDINGS = object : VortxRuntimeBindings {
        override fun create(ownerId: String, ownerName: String): Long =
            VortxCore.nativeInitRuntime(JSONObject().put("ownerId", ownerId).put("ownerName", ownerName).toString())

        override fun hydrate(snapshot: String): Long = VortxCore.nativeInitFromStateJson(snapshot)
        override fun dispatch(handle: Long, action: String): String? = VortxCore.nativeDispatchJson(handle, action)
        override fun resolve(handle: Long, request: String): String? = VortxCore.nativeResolveJson(handle, request)
        override fun state(handle: Long): String? = VortxCore.nativeGetStateJson(handle)
        override fun delta(handle: Long): String? = VortxCore.nativeGetStateDeltaJson(handle)
        override fun free(handle: Long) = VortxCore.nativeEngineFree(handle)
    }
}
