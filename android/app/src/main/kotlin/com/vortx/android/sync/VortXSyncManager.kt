package com.vortx.android.sync

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.vortx.android.profile.ProfileStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * The VortX end-to-end-encrypted account on Android: create (register), sign in, and recover, plus the
 * on-device session (token + account + data key). Kotlin port of the AUTH portion of the Apple
 * `app/SourcesShared/VortXSyncManager.swift`, using [VortXCrypto] for the byte-for-byte crypto contract
 * shared with the website (`webapp/src/lib/vault.ts`) and the Cloudflare Worker. Every request body and
 * every derived value matches Apple + web + the worker, so an account created on ANY surface signs in here
 * and vice-versa.
 *
 * SCOPE: the auth surface (`register` / `signIn` / `recover`, session persistence, `adopt` / `signOut`)
 * AND the sync engine (`syncUp` / `syncDown`, the [VortXSyncDoc] `vortx` doc-merge, tombstone folds, and
 * the never-shrink / never-zero / decrypt-miss / version guards), built on [VortXCrypto]'s
 * `sealDocument` / `openDocument`. The sync engine covers the PROFILE + WATCH-OVERLAY + PROFILE-TOMBSTONE
 * legs; the realtime WebSocket channel and the add-on / library / apiKeys / searches legs (which depend on
 * stores not yet ported) are later rounds — this engine PRESERVES those foreign doc keys on the
 * read-merge-write so it never drops what another surface wrote. VortX works fully signed out; this only
 * adds cross-device sync, backup, and recovery, so nothing here is on the critical launch path.
 *
 * The session (token, account, and the sensitive 32-byte data key) is persisted in
 * EncryptedSharedPreferences — the Android analogue of the Keychain the Apple session lives in
 * ([SecureTokenStore] / [com.vortx.android.auth.AuthIdentityStore] use the same fail-soft pattern). The
 * data key decrypts the WHOLE account, so it never sits in plain SharedPreferences.
 */
class VortXSyncManager(context: Context) {

    /** The account fields the server returns (mirrors Apple `VortXSyncManager.Account`). */
    data class Account(
        val id: String,
        val email: String,
        val username: String,
        val twoFactorEnabled: Boolean,
    )

    /** Result of an auth flow. `TotpRequired` asks the UI to reveal the 6-digit field and retry with a code. */
    sealed interface AuthResult {
        data object Ok : AuthResult
        data object TotpRequired : AuthResult
        data class Failed(val message: String) : AuthResult
    }

    /** [result] plus the one-time [recoveryCode] to show once on a successful `register` (null otherwise). */
    data class RegisterResult(val result: AuthResult, val recoveryCode: String?)

    /** A live signed-in session: bearer token + account + the decrypted 32-byte data key. */
    data class Session(val token: String, val account: Account, val dataKey: ByteArray) {
        override fun equals(other: Any?): Boolean =
            other is Session && token == other.token && account == other.account && dataKey.contentEquals(other.dataKey)
        override fun hashCode(): Int = 31 * (31 * token.hashCode() + account.hashCode()) + dataKey.contentHashCode()
    }

    private val store = SessionStore(context.applicationContext)

    /**
     * Per-account version + downgrade-ratchet state for the sync engine (the analogue of Apple's
     * UserDefaults `lastSyncedVersion` / `sawDocV2`). Plain SharedPreferences on purpose: a version int and
     * a bool are NOT sensitive (only the data key is), and Apple keeps them in UserDefaults, not the Keychain.
     */
    private val syncState = SyncStateStore(context.applicationContext)

    /** IO scope for the debounced auto-push (requestSyncSoon) and background catch-up pulls. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** The roster/overlay store the sync engine reads + folds into. Set by [attachSyncSeams]. */
    @Volatile private var profileStore: ProfileStore? = null

    /** A debounced syncUp is queued; syncDown defers to it so a fresh local edit is never clobbered. */
    @Volatile private var pendingSync: Job? = null
    @Volatile private var hasPendingPush = false

    /**
     * Set while syncDown is applying a remote pull. The writes it makes (roster fold, overlay hydrate) must
     * NOT arm an auto-push, or the receiving device re-pushes the peer values and starves its own pull guard
     * (Apple's Beta 8/9 settings-sync self-echo). The Android foundation already avoids most self-echo by
     * folding through `persist(touch = false)` and a non-scheduling `applyRemoteOverlay`, but the seams could
     * still fire, so [requestSyncSoon] hard-gates on this flag exactly like Apple's `isApplyingRemote`.
     */
    @Volatile private var applyingRemote = false

    @Volatile private var session: Session? = null

    private val _account = MutableStateFlow<Account?>(null)
    /** The signed-in account, or null when signed out. Observed by Settings' Account row. */
    val account: StateFlow<Account?> = _account.asStateFlow()

    /** True whenever a session is present (a token + data key were adopted and persisted). */
    val isSignedIn: Boolean get() = session != null

    init {
        restore()
    }

    // MARK: - Flows

    /**
     * Create an account. Generates the kdf salt, derives the master key, mints a random data key + a
     * recovery code, wraps the data key under BOTH the master key and the recovery key, and posts the
     * verifiers + wrapped keys. On success adopts the session and returns the one-time recovery code (the
     * UI must show it once and tell the user to store it offline). Mirrors Apple `register`.
     */
    suspend fun register(email: String, username: String, password: String): RegisterResult {
        val kdfSalt = VortXCrypto.randomBytes(16)
        val iters = VortXCrypto.DEFAULT_ITERS
        val masterKey = VortXCrypto.masterKey(password, kdfSalt, iters)
        val dataKey = VortXCrypto.randomBytes(32)
        val recoveryCode = VortXCrypto.makeRecoveryCode()
        val recoveryKey = VortXCrypto.recoveryKey(recoveryCode, kdfSalt, iters)
        val wrappedPw = VortXCrypto.seal(masterKey, dataKey)
        val wrappedRec = VortXCrypto.seal(recoveryKey, dataKey)
        if (wrappedPw == null || wrappedRec == null) {
            return RegisterResult(AuthResult.Failed("Could not set up encryption."), null)
        }
        val body = JSONObject().apply {
            put("email", email)
            put("username", username)
            put("kdfSalt", VortXCrypto.b64(kdfSalt))
            put("kdfIters", iters)
            put("authVerifier", VortXCrypto.authVerifier(masterKey, password))
            put("wrappedKeyPassword", wrappedPw)
            put("wrappedKeyRecovery", wrappedRec)
            put("recVerifier", VortXCrypto.recVerifier(recoveryKey, recoveryCode))
            // Sent ONLY so the worker can put it in the welcome email; it is never stored server-side (the
            // worker marks it "NEVER written to the DB"), matching Apple's register body. Without it the
            // welcome email falls back to a generic "save your code" note.
            put("recoveryCode", recoveryCode)
        }
        val (code, json) = request("POST", "/v1/auth/register", body)
        val token = json?.optString("token").takeUnless { it.isNullOrEmpty() }
        val acct = json?.optJSONObject("account")
        if (code == 200 && token != null && acct != null) {
            adopt(token, acct, dataKey)
            return RegisterResult(AuthResult.Ok, recoveryCode)
        }
        val message = when (json?.optString("error")) {
            "email_taken" -> "That email is already registered."
            "username_taken" -> "That username is taken."
            else -> "Could not create the account."
        }
        return RegisterResult(AuthResult.Failed(message), null)
    }

    /**
     * Sign in with email-or-username + password (+ optional TOTP). Pre-login fetches the account's kdf salt
     * + iterations; the master key is derived locally and only the auth verifier crosses the wire. On
     * success the password-wrapped data key is unwrapped on-device. Mirrors Apple `signIn`.
     */
    suspend fun signIn(login: String, password: String, totp: String? = null): AuthResult {
        val (_, pre) = request("POST", "/v1/auth/prelogin", JSONObject().put("login", login))
        val salt = pre?.optString("kdfSalt").takeUnless { it.isNullOrEmpty() }?.let { VortXCrypto.unb64(it) }
        val iters = pre?.optInt("kdfIters", -1)?.takeIf { it > 0 }
        if (salt == null || iters == null) return AuthResult.Failed("Could not reach VortX. Try again.")
        // Reject a downgraded work factor from the UNAUTHENTICATED prelogin response before deriving the key.
        if (iters < VortXCrypto.MIN_ITERS) return AuthResult.Failed("Could not verify VortX security parameters. Try again.")

        val masterKey = VortXCrypto.masterKey(password, salt, iters)
        val body = JSONObject().apply {
            put("login", login)
            put("authVerifier", VortXCrypto.authVerifier(masterKey, password))
            if (!totp.isNullOrEmpty()) put("totp", totp)
        }
        val (code, json) = request("POST", "/v1/auth/login", body)
        if (code == 401 && json?.optString("error") == "totp_required") return AuthResult.TotpRequired

        val token = json?.optString("token").takeUnless { it.isNullOrEmpty() }
        val acct = json?.optJSONObject("account")
        val wrappedPw = json?.optString("wrappedKeyPassword").takeUnless { it.isNullOrEmpty() }
        val dataKey = wrappedPw?.let { VortXCrypto.open(masterKey, it) }
        if (code == 200 && token != null && acct != null && dataKey != null) {
            adopt(token, acct, dataKey)
            return AuthResult.Ok
        }
        return AuthResult.Failed(if (code == 401) "Wrong login or password." else "Could not sign in.")
    }

    /**
     * Forgot-password recovery (DATA-PRESERVING): the user still has the recovery code. Unwrap the data key
     * with the recovery key, then re-derive a new master key from the SAME kdf salt the account already uses
     * (so the recovery key stays valid afterwards) and re-wrap the data key under it. Mirrors Apple `recover`.
     */
    suspend fun recover(email: String, recoveryCode: String, newPassword: String): AuthResult {
        val trimmed = recoveryCode.trim()
        val (_, start) = request("POST", "/v1/auth/recover-start", JSONObject().put("email", email))
        val salt = start?.optString("kdfSalt").takeUnless { it.isNullOrEmpty() }?.let { VortXCrypto.unb64(it) }
        val iters = start?.optInt("kdfIters", -1)?.takeIf { it > 0 }
        val wrappedRec = start?.optString("wrappedKeyRecovery").takeUnless { it.isNullOrEmpty() }
        if (salt == null || iters == null || wrappedRec == null) {
            return AuthResult.Failed("No recovery is set up for that email.")
        }
        // Same downgrade guard as signIn: recover-start is unauthenticated too.
        if (iters < VortXCrypto.MIN_ITERS) return AuthResult.Failed("Could not verify VortX security parameters. Try again.")

        val recoveryKey = VortXCrypto.recoveryKey(trimmed, salt, iters)
        val dataKey = VortXCrypto.open(recoveryKey, wrappedRec) ?: return AuthResult.Failed("That recovery code is not correct.")
        // Keep the existing kdfSalt (it also derives the recovery key); derive the new master from it.
        val newMaster = VortXCrypto.masterKey(newPassword, salt, iters)
        val wrappedPw = VortXCrypto.seal(newMaster, dataKey) ?: return AuthResult.Failed("Could not re-encrypt.")
        val body = JSONObject().apply {
            put("email", email)
            put("recVerifier", VortXCrypto.recVerifier(recoveryKey, trimmed))
            put("newAuthVerifier", VortXCrypto.authVerifier(newMaster, newPassword))
            put("newWrappedKeyPassword", wrappedPw)
        }
        val (code, json) = request("POST", "/v1/auth/recover-complete", body)
        val token = json?.optString("token").takeUnless { it.isNullOrEmpty() }
        val acct = json?.optJSONObject("account")
        if (code == 200 && token != null && acct != null) {
            adopt(token, acct, dataKey)
            return AuthResult.Ok
        }
        return AuthResult.Failed("Recovery failed.")
    }

    /** Sign out: drop the pending push, drop and clear the persisted session. */
    fun signOut() {
        pendingSync?.cancel()
        pendingSync = null
        hasPendingPush = false
        session = null
        _account.value = null
        store.clear()
        // The per-account version / sawDocV2 keys are deliberately NOT reset (they are keyed by account id,
        // so a re-login for the SAME account keeps its high-water mark), mirroring Apple's signOut.
    }

    /**
     * The current session snapshot (token + account + data key), or null when signed out. `internal` so the
     * next-wave sync engine (same package) can seal/pull the encrypted document under the data key; not part
     * of the public API (the data key never leaves this package).
     */
    internal fun currentSession(): Session? = session

    // MARK: - Encrypted sync document: the engine (syncUp / syncDown)
    //
    // Kotlin port of the sync-engine half of Apple `VortXSyncManager` (`syncUp` / `syncDown`, the
    // `vortxSummary` doc-merge, tombstone folds, and the never-shrink / never-zero / decrypt-miss / version
    // guards). The document seal/open crypto lives in [VortXCrypto]; the roster<->doc.vortx codec in
    // [VortXSyncDoc]; this class owns the transport, the guards, and the optimistic-concurrency loop.
    //
    // ANDROID SCOPE (this round): the PROFILE + WATCH-OVERLAY + PROFILE-TOMBSTONE legs. The add-on /
    // library / apiKeys / searches legs Apple also merges depend on stores not yet ported (AddonTombstones,
    // LibraryTombstones, the CoreBridge library, ApiKeys), so this engine PRESERVES those foreign keys on
    // the read-merge-write (never dropping what another surface wrote) and merges only what it owns.

    /**
     * MIGRATION flip for the version-bound sync-document format (see [VortXCrypto.sealDocument]). STAYS
     * FALSE until dual-read is broadly adopted on EVERY client — a v2 doc is unreadable by any client that
     * predates `openDocument`, so writing v2 before then breaks sync for a user whose other device/surface
     * is on an older build. `openDocument` always reads BOTH formats regardless of this flag; only WRITE is
     * gated. Named to match Apple `VortXSyncManager.writeSyncDocV2` and web `vault.ts` WRITE_SYNC_DOC_V2. DO
     * NOT flip to true until all clients ship dual-read (see the Apple doc-comment's hard gates H-1 / H-2).
     */
    private val writeSyncDocV2 = WRITE_SYNC_DOC_V2

    /**
     * Wire the profile + overlay push seams to a debounced [syncUp], and keep the [store] the engine folds
     * into. Called once after [ProfileStore.init] (e.g. from `VortXApplication.onCreate`). A genuine roster
     * edit (`touch = true`) or a debounced overlay write fires [onRosterPush] / [onRequestSync] /
     * [onPushWatch]; a syncDown fold uses `touch = false` + a non-scheduling `applyRemoteOverlay`, so it
     * never self-arms a push (and [requestSyncSoon] hard-gates on [applyingRemote] as a belt-and-braces).
     */
    fun attachSyncSeams(store: ProfileStore) {
        profileStore = store
        store.onRosterPush = { requestSyncSoon() }
        store.watchOverlay.onRequestSync = { requestSyncSoon() }
        store.watchOverlay.onPushWatch = { _, _ -> requestSyncSoon() }
    }

    private fun resolveStore(): ProfileStore? = profileStore ?: ProfileStore.sharedOrNull()

    // ---- Per-account version guards (H-1 downgrade ratchet, H-2 high-water floor) ----

    /**
     * Newest doc version this device has pushed or applied FOR THE SIGNED-IN ACCOUNT (epoch-ms, a 64-bit
     * value — always a [Long]). Per-account so an account switch (out of A at v1000, into B at v5) never
     * treats B's pulls as stale. A fresh account key starts at 0, so the first pull is applied once.
     */
    private fun lastSyncedVersion(): Long = session?.account?.id?.let { syncState.lastVersion(it) } ?: 0L

    private fun advanceVersion(version: Long) {
        val id = session?.account?.id ?: return
        syncState.setLastVersion(id, maxOf(version, syncState.lastVersion(id)))
    }

    // H-1 downgrade ratchet (per account): once this account's doc has opened as v2, a bare-legacy blob is
    // treated as tamper and never opened (a legacy blob authenticates at ANY version, so a backend could
    // replay an archived pre-flip ciphertext under a forged higher version). Dormant until v2 docs exist.
    private fun sawDocV2(accountId: String): Boolean = accountId.isNotEmpty() && syncState.sawV2(accountId)
    private fun markSawDocV2(accountId: String) { if (accountId.isNotEmpty()) syncState.setSawV2(accountId) }

    /**
     * Open a pulled sync document, enforcing the H-1 ratchet. Returns null (tamper / undecryptable / refused)
     * rather than ever surfacing an empty doc, so a caller never clobbers the account from a refused open.
     * [version] is a 64-bit epoch-ms value threaded as a [Long] straight into [VortXCrypto.openDocument]'s
     * AAD — reading it as an Int would truncate it and fail GCM auth on every Apple/web-authored v2 document.
     */
    private fun openSyncDocument(stored: String, version: Long): ByteArray? {
        val dataKey = session?.dataKey ?: return null
        val accountId = session?.account?.id ?: ""
        val isV2 = stored.startsWith(VortXCrypto.DOC_V2_PREFIX)
        if (!isV2 && sawDocV2(accountId)) return null             // legacy after v2 seen -> tamper
        val plaintext = VortXCrypto.openDocument(dataKey, stored, accountId, version)
        if (plaintext != null && isV2) markSawDocV2(accountId)    // this account is now on v2
        return plaintext
    }

    // ---- Tri-state pull (never conflate "no backup yet" with "the pull failed") ----

    private sealed interface SyncDocPull {
        data class Doc(val doc: JSONObject, val version: Long) : SyncDocPull
        data object Empty : SyncDocPull
        data object Failed : SyncDocPull
    }

    /**
     * Pull the account doc, distinguishing "no backup yet" (safe to seed) from "the pull failed" (must NOT
     * push, or it clobbers the account's existing doc). A non-200/non-404, an undecryptable doc, or a
     * version older than this account's high-water mark (H-2 rollback replay) is a FAILURE. A DECRYPT-MISS
     * throws no exception and yields Failed, never an empty `{}` that would wipe state.
     */
    private suspend fun pullSyncDocResult(): SyncDocPull {
        if (session?.dataKey == null) return SyncDocPull.Failed
        val (code, json) = request("GET", "/v1/backup", null, auth = true)
        if (code == 404) return SyncDocPull.Empty                 // no backup yet
        if (code != 200) return SyncDocPull.Failed                // network/server error: do not clobber
        val body = json ?: return SyncDocPull.Empty               // 200 with no readable body: no backup
        val docStr = body.optString("document", "").takeUnless { it.isEmpty() } ?: return SyncDocPull.Empty
        // Version is a 64-bit epoch-ms value: read as LONG (optLong), NEVER optInt (which truncates it).
        val pulledVersion = body.optLong("version", 0L)
        // H-2: refuse an honest-label replay of a doc OLDER than what this account already applied. A real
        // server only returns a version >= our high-water mark, so this fires only on a rollback/replay.
        if (pulledVersion < lastSyncedVersion()) return SyncDocPull.Failed
        val plaintext = openSyncDocument(docStr, pulledVersion) ?: return SyncDocPull.Failed
        val obj = runCatching { JSONObject(String(plaintext, Charsets.UTF_8)) }.getOrNull()
            ?: return SyncDocPull.Failed                          // undecodable plaintext: do not clobber
        return SyncDocPull.Doc(obj, pulledVersion)
    }

    // ---- Push with optimistic concurrency ----

    private sealed interface PushOutcome {
        data class Accepted(val version: Long) : PushOutcome
        data class Rejected(val storedVersion: Long?) : PushOutcome
        data object Error : PushOutcome
    }

    /**
     * Seal + PUT the doc at an explicit [version] (epoch-ms, a [Long]). Advances the per-account
     * high-water mark ONLY on accepted == true — advancing it on a rejected write would suppress the
     * recovery pull and silently drop a write that LOST the race. `accepted` defaults true so an older
     * worker without the field (which stored the write) still advances, matching the web's `accepted !== false`.
     */
    private suspend fun pushSyncDocAt(obj: JSONObject, version: Long): PushOutcome {
        val dataKey = session?.dataKey ?: return PushOutcome.Error
        val accountId = session?.account?.id ?: ""
        val plaintext = obj.toString().toByteArray(Charsets.UTF_8)
        val ciphertext = VortXCrypto.sealDocument(dataKey, plaintext, accountId, version, writeSyncDocV2)
            ?: return PushOutcome.Error
        val body = JSONObject().put("document", ciphertext).put("version", version)  // Long: no truncation
        val (code, json) = request("PUT", "/v1/backup", body, auth = true)
        if (code != 200) return PushOutcome.Error
        val accepted = if (json != null && json.has("accepted")) json.optBoolean("accepted", true) else true
        if (accepted) {
            advanceVersion(version)
            if (writeSyncDocV2) markSawDocV2(accountId)           // H-1: this account's stored doc is now v2
            return PushOutcome.Accepted(version)
        }
        // Rejected (a concurrent write won). The worker echoes the current stored version (a Long) so we can
        // retry deterministically at stored+1 instead of racing epoch-ms again. Do NOT advance the version.
        val stored = json?.takeIf { it.has("version") }?.optLong("version")
        return PushOutcome.Rejected(stored)
    }

    /**
     * Push a doc DERIVED from a pulled base, with optimistic-concurrency recovery. On a lost race, [rebuild]
     * re-runs the caller's exact merge onto a freshly pulled base and retries strictly above the winner
     * (`max(stored + 1, epochMs)`, so a backward wall-clock can never lock the device out). On exhaustion or
     * a failed rebuild, the version is left unadvanced so the next natural pull reconciles. Mirrors Apple
     * `pushDerivedDoc`.
     */
    private suspend fun pushDerivedDoc(initial: JSONObject, rebuild: suspend () -> JSONObject?): Boolean {
        var doc = initial
        var version = System.currentTimeMillis()
        repeat(PUSH_MAX_RETRIES) { attempt ->
            when (val outcome = pushSyncDocAt(doc, version)) {
                is PushOutcome.Accepted -> return true
                is PushOutcome.Error -> return false              // network/server/encode failure: reconcile later
                is PushOutcome.Rejected -> {
                    if (attempt >= PUSH_MAX_RETRIES - 1) return false
                    val rebuilt = rebuild() ?: return false       // rebuild's pull now fails: abort, do not clobber
                    doc = rebuilt
                    version = outcome.storedVersion?.let { maxOf(it + 1, System.currentTimeMillis()) }
                        ?: System.currentTimeMillis()
                }
            }
        }
        return false
    }

    // ---- syncUp / syncDown ----

    /**
     * Push this device's roster + overlays + tombstones to the account. MERGES into the freshly-pulled doc
     * (preserving foreign keys other surfaces wrote) instead of replacing it, then pushes with
     * optimistic-concurrency recovery. Mirrors Apple `syncUp`.
     */
    suspend fun syncUp(): Boolean {
        if (!isSignedIn) return false
        val initial = mergeLocalIntoDoc() ?: return false        // failed pull: never overwrite the account doc
        return pushDerivedDoc(initial) { mergeLocalIntoDoc() }
    }

    /**
     * Build the doc to push by MERGING this device's state onto a freshly pulled base. Returns null on a
     * FAILED pull (network / undecryptable): a failed pull must NEVER overwrite the account's doc, or it
     * wipes keys other surfaces wrote. UNIONs the cloud roster into the local one BEFORE building the vortx
     * block, so a device with FEWER profiles never shrinks the cloud's set. Mirrors Apple `mergeLocalIntoDoc`.
     */
    private suspend fun mergeLocalIntoDoc(): JSONObject? {
        val store = resolveStore() ?: return null
        val doc: JSONObject = when (val pull = pullSyncDocResult()) {
            is SyncDocPull.Failed -> return null
            is SyncDocPull.Empty -> JSONObject()
            is SyncDocPull.Doc -> pull.doc
        }
        val parsed = VortXSyncDoc.parse(doc)
        // ProfileStore is a main-thread store (mirroring Apple's @MainActor); fold + build on Main.
        withContext(Dispatchers.Main) {
            // UNION the cloud roster into the local one first (never shrinks local), so the block we push
            // already carries both sides — a cloud-only profile survives the round-trip. Fold under the
            // remote-apply flag so this union does not self-arm a push.
            applyingRemote = true
            try {
                parsed.roster?.let { if (it.isNotEmpty()) store.mergeInRoster(it, parsed.rosterModifiedSeconds) }
            } finally {
                applyingRemote = false
            }
            doc.put("vortx", VortXSyncDoc.buildVortx(store, doc.optJSONObject("vortx")))
        }
        return doc
    }

    /**
     * Pull the account doc and apply what is NEWER than this device holds. Deferred while a local push is
     * queued (so it never re-applies the account's pre-edit value over a fresh local edit) and version-gated
     * (applies only a strictly-newer remote). `force` ignores both guards (manual "Sync now" / sign-in
     * reconciliation). A `.failed` / `.empty` pull applies NOTHING (never wipes local). Mirrors Apple `syncDown`.
     */
    suspend fun syncDown(force: Boolean = false): Boolean {
        if (!isSignedIn) return false
        // PENDING-EDIT GUARD: defer while a genuine local edit's debounced push is queued.
        if (!force && hasPendingPush) return false
        val pull = pullSyncDocResult()
        val doc: JSONObject
        val version: Long
        when (pull) {
            is SyncDocPull.Doc -> { doc = pull.doc; version = pull.version }
            else -> return false                                 // .empty / .failed: never wipe local
        }
        // VERSION-WINS: apply only a STRICTLY-NEWER remote; a stale or equal pull is a no-op.
        if (!force && version <= lastSyncedVersion()) return false
        val parsed = VortXSyncDoc.parse(doc)
        var restored = false
        withContext(Dispatchers.Main) {
            val store = resolveStore() ?: return@withContext
            applyingRemote = true                                // the whole apply must not arm a self-echo push
            try {
                // TOMBSTONES FIRST so the roster union below can never resurrect a deleted profile
                // (tombstone-vs-resurrection precedence). mergeDeletedTombstones also prunes the live roster.
                if (parsed.deletedProfiles.isNotEmpty() &&
                    store.mergeDeletedTombstones(parsed.deletedProfiles)
                ) restored = true
                // Roster UNION (never shrinks local; newest-wins by epoch-SECONDS; subtracts tombstones).
                parsed.roster?.let { remote ->
                    if (remote.isNotEmpty()) {
                        store.mergeInRoster(remote, parsed.rosterModifiedSeconds)
                        restored = true
                    }
                }
                // Per-profile watch overlays: union + LWW by lastWatched, never touching owner/engine history.
                if (parsed.overlays.isNotEmpty()) {
                    for ((profileId, entries) in parsed.overlays) {
                        store.applyRemoteOverlay(profileId, entries)
                    }
                    restored = true
                }
                // Re-assert this session's local deletes after the fold: a profile deleted this session stays
                // gone even if the pulled doc predates its tombstone (the resurrect window).
                store.applyLocalTombstones()
            } finally {
                applyingRemote = false
            }
        }
        // Stamp the applied version so the version-wins guard holds across relaunches (per account).
        advanceVersion(version)
        return restored
    }

    /**
     * Auto-sync: a debounced push, armed whenever the roster or an overlay changes. Coalesces a burst of
     * edits into ONE push a couple of seconds later. Hard-gated on [applyingRemote] so a remote apply's own
     * writes never arm a push (the self-echo starvation). Mirrors Apple `requestSyncSoon`.
     */
    fun requestSyncSoon() {
        if (!isSignedIn || applyingRemote) return
        hasPendingPush = true
        pendingSync?.cancel()
        pendingSync = scope.launch {
            delay(SYNC_DEBOUNCE_MS)
            if (!isActive) return@launch
            syncUp()
            // A newer edit that arrived while syncUp ran cancelled this task and queued its own push; clearing
            // the flag on a cancelled task would open the pull guard while that newer push is still pending.
            if (!isActive) return@launch
            hasPendingPush = false
        }
    }

    /** Catch-up PULL entry point (foreground / manual "Sync now"). The realtime WS channel is a later round. */
    fun syncDownSoon() {
        if (isSignedIn) scope.launch { syncDown() }
    }

    // ---- Sign-in reconciliation (no blind last-writer-wins) ----

    /** Does the account already hold synced data (so a sign-in is a merge), is it empty, or unreachable? */
    enum class AccountDataProbe { HAS_DATA, EMPTY, UNREACHABLE }

    suspend fun accountHasSyncData(): AccountDataProbe = when (val pull = pullSyncDocResult()) {
        is SyncDocPull.Doc ->
            if (pull.doc.has("vortx") || pull.doc.has("settings") || pull.doc.has("apiKeys"))
                AccountDataProbe.HAS_DATA else AccountDataProbe.EMPTY
        is SyncDocPull.Empty -> AccountDataProbe.EMPTY           // genuinely no backup yet: safe to seed
        is SyncDocPull.Failed -> AccountDataProbe.UNREACHABLE    // blip / refused doc: retry, NEVER seed
    }

    enum class SignInReconcile { SEEDED_FROM_DEVICE, HAS_ACCOUNT_DATA, UNREACHABLE }

    /**
     * Call right after a successful sign-in. A fresh (empty) account is seeded from this device; an account
     * with data returns [SignInReconcile.HAS_ACCOUNT_DATA] (the UI asks which side to keep); an unreachable
     * doc returns [SignInReconcile.UNREACHABLE] and pushes NOTHING (a blip is never treated as a fresh account).
     */
    suspend fun reconcileAfterSignIn(): SignInReconcile = when (accountHasSyncData()) {
        AccountDataProbe.HAS_DATA -> SignInReconcile.HAS_ACCOUNT_DATA
        AccountDataProbe.UNREACHABLE -> SignInReconcile.UNREACHABLE
        AccountDataProbe.EMPTY -> { syncUp(); SignInReconcile.SEEDED_FROM_DEVICE }
    }

    /** Conflict resolution: adopt the account's roster (forced). Still UNIONs, so no local-only profile is lost. */
    suspend fun useAccountData() { syncDown(force = true) }

    /** Conflict resolution / "Sync now": push this device's roster + overlays to the account. */
    suspend fun pushThisDevice(): Boolean = syncUp()

    /** "Sync now" recommended path: union both ways so EVERY profile from both sides survives, then push. */
    suspend fun mergeBoth(): Boolean {
        syncDown(force = true)
        return syncUp()
    }

    // MARK: - Session adoption + persistence

    private fun adopt(token: String, acct: JSONObject, dataKey: ByteArray) {
        val account = Account(
            id = acct.optString("id"),
            email = acct.optString("email"),
            username = acct.optString("username"),
            twoFactorEnabled = acct.optBoolean("twoFactorEnabled", false),
        )
        val s = Session(token, account, dataKey)
        session = s
        _account.value = account
        store.persist(s)
    }

    private fun restore() {
        val s = store.load() ?: return
        session = s
        _account.value = s.account
    }

    // MARK: - HTTP (tiny JSON-over-HttpURLConnection helper, same shape as IntegrationsHttp)

    /**
     * POST [body] to `api.vortx.tv` + [path], returning (status, parsed JSON or null). A transport failure
     * surfaces as (0, null) rather than throwing, so the auth flows stay fail-soft. `api.vortx.tv` is the
     * account-authed host and is deliberately NOT edge-signed (it is excluded from [VortXEdgeAuth]'s gate).
     */
    private suspend fun request(method: String, path: String, body: JSONObject?, auth: Boolean = false): Pair<Int, JSONObject?> =
        withContext(Dispatchers.IO) {
            var connection: HttpURLConnection? = null
            try {
                connection = (URL(BASE + path).openConnection() as HttpURLConnection).apply {
                    requestMethod = method.uppercase()
                    connectTimeout = TIMEOUT_MS
                    readTimeout = TIMEOUT_MS
                    useCaches = false
                    // The session bearer for the backup/sync endpoints. `api.vortx.tv` is the account-authed
                    // host and is deliberately NOT edge-signed (excluded from VortXEdgeAuth's gate).
                    if (auth) session?.token?.let { setRequestProperty("authorization", "Bearer $it") }
                    if (body != null) {
                        doOutput = true
                        setRequestProperty("content-type", "application/json")
                        outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
                    }
                }
                val status = connection.responseCode
                val stream = if (status in 200..399) connection.inputStream else connection.errorStream
                val text = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
                val json = runCatching { if (text.isNotEmpty()) JSONObject(text) else null }.getOrNull()
                status to json
            } catch (_: IOException) {
                0 to null
            } finally {
                connection?.disconnect()
            }
        }

    /**
     * Keystore-encrypted persistence for the session (token + account JSON + base64 data key), fail-soft
     * exactly like [SecureTokenStore] / [com.vortx.android.auth.AuthIdentityStore]: prefer the AES-encrypted
     * store, fall back to a plain file only if security-crypto itself is unavailable, so a storage-layer
     * problem degrades to "signed out" instead of crashing.
     */
    private class SessionStore(appContext: Context) {
        private val prefs: SharedPreferences = runCatching {
            val masterKey = MasterKey.Builder(appContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            EncryptedSharedPreferences.create(
                appContext, ENCRYPTED_FILE, masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        }.getOrElse { error ->
            Log.w(TAG, "EncryptedSharedPreferences unavailable; falling back to plain prefs", error)
            appContext.getSharedPreferences(PLAIN_FALLBACK_FILE, Context.MODE_PRIVATE)
        }

        fun persist(s: Session) {
            val acct = JSONObject().apply {
                put("id", s.account.id)
                put("email", s.account.email)
                put("username", s.account.username)
                put("twoFactorEnabled", s.account.twoFactorEnabled)
            }
            prefs.edit()
                .putString(KEY_TOKEN, s.token)
                .putString(KEY_ACCOUNT, acct.toString())
                .putString(KEY_DATA_KEY, VortXCrypto.b64(s.dataKey))
                .apply()
        }

        fun load(): Session? {
            val token = prefs.getString(KEY_TOKEN, null)?.takeIf { it.isNotEmpty() } ?: return null
            val acctStr = prefs.getString(KEY_ACCOUNT, null) ?: return null
            val dkStr = prefs.getString(KEY_DATA_KEY, null) ?: return null
            val dataKey = VortXCrypto.unb64(dkStr) ?: return null
            val acct = runCatching { JSONObject(acctStr) }.getOrNull() ?: return null
            val account = Account(
                id = acct.optString("id"),
                email = acct.optString("email"),
                username = acct.optString("username"),
                twoFactorEnabled = acct.optBoolean("twoFactorEnabled", false),
            )
            return Session(token, account, dataKey)
        }

        fun clear() {
            prefs.edit().remove(KEY_TOKEN).remove(KEY_ACCOUNT).remove(KEY_DATA_KEY).apply()
        }

        private companion object {
            const val TAG = "VortXSyncSession"
            const val ENCRYPTED_FILE = "vortx_sync_session"
            const val PLAIN_FALLBACK_FILE = "vortx_sync_session_plain"
            const val KEY_TOKEN = "token"
            const val KEY_ACCOUNT = "account"
            const val KEY_DATA_KEY = "dataKey"
        }
    }

    /**
     * Per-account version + downgrade-ratchet persistence for the sync engine. Plain SharedPreferences (the
     * UserDefaults analogue Apple uses for these): the version high-water mark and the `sawDocV2` bool are
     * not sensitive, so they never need the encrypted store the session lives in.
     */
    private class SyncStateStore(appContext: Context) {
        private val prefs: SharedPreferences =
            appContext.getSharedPreferences(STATE_FILE, Context.MODE_PRIVATE)

        fun lastVersion(accountId: String): Long = prefs.getLong(KEY_VERSION + accountId, 0L)
        fun setLastVersion(accountId: String, version: Long) {
            prefs.edit().putLong(KEY_VERSION + accountId, version).apply()
        }

        fun sawV2(accountId: String): Boolean = prefs.getBoolean(KEY_SAW_V2 + accountId, false)
        fun setSawV2(accountId: String) {
            prefs.edit().putBoolean(KEY_SAW_V2 + accountId, true).apply()
        }

        private companion object {
            const val STATE_FILE = "vortx_sync_state"
            const val KEY_VERSION = "lastSyncedVersion."
            const val KEY_SAW_V2 = "sawDocV2."
        }
    }

    private companion object {
        const val BASE = "https://api.vortx.tv"
        const val TIMEOUT_MS = 20_000

        /**
         * The v2 sync-document WRITE gate, held FALSE. Matches Apple `VortXSyncManager.writeSyncDocV2`
         * (VortXSyncManager.swift:73) and web `vault.ts` WRITE_SYNC_DOC_V2. A v2 doc is unreadable by any
         * client that predates `openDocument`, so v2 writes stay off until every client ships dual-read.
         * `openDocument` reads BOTH formats regardless; only WRITE is gated. DO NOT flip.
         */
        const val WRITE_SYNC_DOC_V2 = false

        /** Debounce for the coalesced auto-push (Apple `requestSyncSoon`: 2.5s). */
        const val SYNC_DEBOUNCE_MS = 2_500L

        /** Bounded optimistic-concurrency retries for a derived push (Apple `pushDerivedDoc`: 3). */
        const val PUSH_MAX_RETRIES = 3
    }
}
