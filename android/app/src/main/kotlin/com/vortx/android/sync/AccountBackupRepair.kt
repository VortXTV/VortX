package com.vortx.android.sync

import com.vortx.android.engine.DetachedAccountFileKernel
import com.vortx.android.engine.NativeOwnerHistoryAccount
import com.vortx.android.engine.NativeProfileOverlayWitness
import com.vortx.android.engine.OHJson
import com.vortx.android.engine.VortxAccountScope
import com.vortx.android.engine.VortxRuntimeBindings
import com.vortx.android.engine.nativeMigrationSidecars
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CancellationException

/** Pure file conversion/reimport core. No manager, transport, store, file access, credentials,
 * checkpoint, ACK, floor or live runtime. Context is INPUT, never an authentication capability.
 * A dedicated adapter must independently establish current account/key/epoch and owner evidence.
 * CoreCandidate is NOT export/restore admission: the common complete host/source admission gate
 * must additionally accept these exact bytes before any service releases them to the user. */
internal object AccountBackupRepair {
    const val MAXIMUM_FILE_BYTES = AccountBackupFile.MAXIMUM_FILE_BYTES
    const val MAXIMUM_PLAINTEXT_BYTES = AccountFileLegacyAdmission.MAX_PLAINTEXT_BYTES
    const val REPAIR_KEY = "vortxFileRepair"
    const val SOURCE_ARCHIVE_DOMAIN = "vortx/file-repair-original/1\n"
    private val forbiddenNativeSources = setOf("ownerHistory", "nativeOwnerHistorySources", "nativeProviderCredentials",
        "authenticatedSourceArchive", "verifiedStreamingUid", "sourceDocumentBase64",
        "ownAccountOverlayPending", "ownAccountOverlayQuarantine") + nativeMigrationSidecars

    enum class Reason {
        TOO_LARGE, INVALID_ENVELOPE, UNSUPPORTED_FORMAT, MATCHING_ACCOUNT_REQUIRED,
        OWNER_WITNESS_REQUIRED, CANNOT_AUTHENTICATE, EXISTING_NATIVE_REQUIRES_VALIDATION,
        SOURCE_REQUIRES_RECONCILIATION, NATIVE_REJECTED, UNSUPPORTED_ACCOUNT_SOURCE,
        PRESERVATION_FAILED, REPAIRED_COPY_CHANGED, ENCRYPTION_FAILED
    }
    class Failure(val reason: Reason) : Exception("Account backup repair refused: ${reason.name}")
    sealed interface Format {
        data class EncryptedAccount(val version: Long, val versionBound: Boolean) : Format
        data object SettingsOnly : Format
        data object Unsupported : Format
    }

    /** The adapter copies these from its ORIGINAL lease and independent authenticated owner read.
     * A UUID/hash copied from the selected file does not establish authority. */
    class Context(val accountID: String, dataKey: ByteArray, val expectedOwnerProfileID: String,
        val ownerWitnessSHA256: String, val operationGeneration: Long, val ownerEpoch: Long) : AutoCloseable {
        init { if (dataKey.size != 32) AccountBackupRepair.fail(Reason.MATCHING_ACCOUNT_REQUIRED) }
        private val lock = Any()
        private val immutableKey = dataKey.copyOf()
        private var closed = false
        internal fun checkOpen() {
            synchronized(lock) { if (closed) throw CancellationException("File preparation context closed") }
        }
        internal fun keyCopy(): ByteArray = synchronized(lock) { checkOpen(); immutableKey.copyOf() }
        override fun close() {
            synchronized(lock) { if (!closed) { immutableKey.fill(0); closed = true } }
        }
        override fun toString() = "AccountBackupRepair.Context"
    }

    /** Immutable result of this core only. Fresh conversions and validated reimports retain the
     * selected original, native and unknown field slices; getters return independent copies. */
    class CoreCandidate internal constructor(file: ByteArray, val sourceSHA256: String,
        val candidatePlaintextSHA256: String, val ownerWitnessSHA256: String,
        val originalVersion: Long, val profileCount: Int, val nativeSchema: Int,
        val disposition: Disposition) : AutoCloseable {
        private val lock = Any()
        private val bytes = file.copyOf()
        private var closed = false
        val fileSHA256: String = OHJson.sha(bytes)
        fun fileBytes(): ByteArray = synchronized(lock) {
            if (closed) throw CancellationException("File candidate closed")
            bytes.copyOf()
        }
        override fun close() {
            synchronized(lock) { if (!closed) { bytes.fill(0); closed = true } }
        }
        override fun toString() = "AccountBackupRepair.CoreCandidate"
    }
    enum class Disposition { CONVERTED_LEGACY, VALIDATED_EXISTING_CANDIDATE }
    private class Source(val envelope: OHJson.Obj, val version: Long, val plaintext: ByteArray,
        val admitted: AccountFileLegacyAdmission.Admitted, val material: ByteArray)

    fun inspect(file: ByteArray): Format {
        bounded(file, MAXIMUM_FILE_BYTES)
        val raw = checked(Reason.INVALID_ENVELOPE) { OHJson.Obj(file) }
        // Only this exact typed marker selects the settings format. Other outer values are
        // unknown account-file metadata and must reach the existing full-account framing gate.
        val format = raw["format"]
        if (format != null && format.firstOrNull() == '\"'.code.toByte() &&
            checked(Reason.INVALID_ENVELOPE) { OHJson.text(format) } == "vortx-backup") {
            val schema = checked(Reason.INVALID_ENVELOPE) { raw.raw("schema") }
            if (!schema.contentEquals(OHJson.literal("1"))) fail(Reason.UNSUPPORTED_FORMAT)
            return Format.SettingsOnly
        }
        if (raw["vortxBackup"] == null) return Format.Unsupported
        val inspection = envelope(file, allowRepair = true)
        return Format.EncryptedAccount(inspection.version, inspection.document.startsWith(VortXCrypto.DOC_V2_PREFIX))
    }

    /** Caller runs this off the UI thread. checkCurrent must throw CancellationException when
     * its original account/key/owner epoch/operation is retired. No new generation is minted. */
    fun convert(original: ByteArray, context: Context, bindings: VortxRuntimeBindings,
        checkCurrent: () -> Unit): CoreCandidate {
        bounded(original, MAXIMUM_FILE_BYTES)
        val active = { context.checkOpen(); checkCurrent() }
        current(active); val scope = scope(context)
        val selected = original.copyOf(); val key = context.keyCopy()
        try {
            val source = source(selected, context, scope, key, active)
            val native = importSource(source, scope, bindings, active)
            admitCoreNative(native, scope, bindings, active)
            val next = checked(Reason.PRESERVATION_FAILED) { source.admitted.addingNativeSync(native) }
            requireConservation(source.plaintext, next)
            current(active)
            val sealed = seal(key, next, context.accountID, source.version)
            current(active)
            // Different AEAD purpose domain. This is the ENTIRE original selected FILE, not an
            // authenticatedSourceArchive, a cloud observation receipt or a new server revision.
            val originalArchive = seal(key, selected, SOURCE_ARCHIVE_DOMAIN + context.accountID, source.version)
            current(active)
            val schema = nativeSchema(native, scope)
            val manifest = OHJson.Obj().set("schemaVersion", OHJson.literal("1"))
                .set("sourceKind", OHJson.quote("user_selected_file"))
                .set("conversion", OHJson.quote("legacy_to_native_cold_v1"))
                .set("sourceSHA256", OHJson.quote(OHJson.sha(selected)))
                .set("candidatePlaintextSHA256", OHJson.quote(OHJson.sha(next)))
                .set("originalFileDocument", OHJson.quote(originalArchive))
                .set("nativeSchema", OHJson.literal(schema.toString()))
            val file = source.envelope.copy().set("document", OHJson.quote(sealed)).set(REPAIR_KEY, manifest.encoded()).encoded()
            bounded(file, MAXIMUM_FILE_BYTES)
            envelope(file, allowRepair = true)
            requireOuterConservation(source.envelope, OHJson.Obj(file))
            current(active)
            return finish(candidate(file, selected, next, source, schema, context, Disposition.CONVERTED_LEGACY), active)
        } finally { key.fill(0) }
    }

    /** Reimports never replace selected native history with a new conversion. Original-file
     * admission is rerun and a disposable real kernel supplies its canonical legacy baseline.
     * Both that baseline and actual cold replay of the selected native carrier must agree.
     * Later compatible selected native history is retained; exclusivity is not asserted. */
    fun validateReimport(file: ByteArray, context: Context, bindings: VortxRuntimeBindings,
        checkCurrent: () -> Unit): CoreCandidate {
        bounded(file, MAXIMUM_FILE_BYTES)
        val active = { context.checkOpen(); checkCurrent() }
        current(active); val scope = scope(context)
        val selected = file.copyOf(); val key = context.keyCopy()
        try {
            val inspection = envelope(selected, allowRepair = true)
            val raw = checked(Reason.REPAIRED_COPY_CHANGED) { OHJson.Obj(selected) }
            val manifest = checked(Reason.REPAIRED_COPY_CHANGED) { raw.obj(REPAIR_KEY) }
            val archiveDocument = checked(Reason.REPAIRED_COPY_CHANGED) { manifest.text("originalFileDocument") }
            checked(Reason.REPAIRED_COPY_CHANGED) {
                require(inspection.document.startsWith(VortXCrypto.DOC_V2_PREFIX) && archiveDocument.startsWith(VortXCrypto.DOC_V2_PREFIX))
                require(manifest.raw("schemaVersion").contentEquals(OHJson.literal("1")) &&
                    manifest.text("sourceKind") == "user_selected_file" && manifest.text("conversion") == "legacy_to_native_cold_v1")
            }
            val original = open(key, archiveDocument, SOURCE_ARCHIVE_DOMAIN + context.accountID,
                inspection.version, MAXIMUM_FILE_BYTES, Reason.REPAIRED_COPY_CHANGED)
            checked(Reason.REPAIRED_COPY_CHANGED) { require(manifest.text("sourceSHA256") == OHJson.sha(original)) }
            current(active)
            val source = source(original, context, scope, key, active)
            if (source.version != inspection.version) fail(Reason.REPAIRED_COPY_CHANGED)
            requireOuterConservation(source.envelope, raw)
            val plaintext = open(key, inspection.document, context.accountID, inspection.version,
                MAXIMUM_PLAINTEXT_BYTES, Reason.REPAIRED_COPY_CHANGED)
            checked(Reason.REPAIRED_COPY_CHANGED) { require(manifest.text("candidatePlaintextSHA256") == OHJson.sha(plaintext)) }
            requireConservation(source.plaintext, plaintext)
            checked(Reason.REPAIRED_COPY_CHANGED) { NativeProfileOverlayWitness.parseAccountDocument(plaintext) }
            val native = checked(Reason.REPAIRED_COPY_CHANGED) { OHJson.Obj(plaintext).raw("nativeSync") }
            val schema = nativeSchema(native, scope)
            checked(Reason.REPAIRED_COPY_CHANGED) {
                require(manifest.raw("nativeSchema").contentEquals(OHJson.Obj(native).raw("schemaVersion")))
            }
            current(active)
            val regeneratedNative = importSource(source, scope, bindings, active)
            val baseline = checked(Reason.NATIVE_REJECTED) { OHJson.Obj(regeneratedNative).obj("legacyImport").raw("baseline") }
            checked(Reason.REPAIRED_COPY_CHANGED) {
                require(OHJson.equal(OHJson.Obj(native).obj("legacyImport").raw("baseline"), baseline))
            }
            admitCoreNative(native, scope, bindings, active)
            checked(Reason.NATIVE_REJECTED) {
                DetachedAccountFileKernel.requireLegacyReplay(scope, source.admitted.ownerName, native, baseline, bindings) { current(active) }
            }
            checked(Reason.PRESERVATION_FAILED) { NativeOwnerHistoryAccount(plaintext).validateBudget(writeV2 = true) }
            current(active)
            return finish(candidate(selected, original, plaintext, source, schema, context, Disposition.VALIDATED_EXISTING_CANDIDATE), active)
        } finally { key.fill(0) }
    }

    private fun candidate(file: ByteArray, original: ByteArray, plaintext: ByteArray, source: Source,
        schema: Int, context: Context, disposition: Disposition) = CoreCandidate(file, OHJson.sha(original),
        OHJson.sha(plaintext), context.ownerWitnessSHA256, source.version, source.admitted.profileCount, schema, disposition)
    private fun finish(candidate: CoreCandidate, checkCurrent: () -> Unit): CoreCandidate {
        try { current(checkCurrent); return candidate }
        catch (failure: Throwable) { candidate.close(); throw failure }
    }

    private fun source(file: ByteArray, context: Context, scope: VortxAccountScope, key: ByteArray,
        checkCurrent: () -> Unit): Source {
        current(checkCurrent)
        val inspection = envelope(file, allowRepair = false)
        val plaintext = open(key, inspection.document, context.accountID, inspection.version,
            MAXIMUM_PLAINTEXT_BYTES, Reason.CANNOT_AUTHENTICATE)
        current(checkCurrent)
        val raw = checked(Reason.SOURCE_REQUIRES_RECONCILIATION) { OHJson.Obj(plaintext) }
        if (raw.keys.any { it in setOf("nativeSync", "nativeHostPreferences", "nativeProviderCredentials", "nativeOwnerHistorySources") })
            fail(Reason.EXISTING_NATIVE_REQUIRES_VALIDATION)
        val admitted = checked(Reason.SOURCE_REQUIRES_RECONCILIATION) {
            AccountFileLegacyAdmission.admitLegacy(plaintext, context.expectedOwnerProfileID)
        }
        val material = checked(Reason.SOURCE_REQUIRES_RECONCILIATION) { admitted.prepareMaterial(scope) }
        current(checkCurrent)
        return Source(OHJson.Obj(file), inspection.version, plaintext, admitted, material)
    }
    private fun importSource(source: Source, scope: VortxAccountScope, bindings: VortxRuntimeBindings,
        checkCurrent: () -> Unit): ByteArray = checked(Reason.NATIVE_REJECTED) {
        val native = DetachedAccountFileKernel.legacySync(scope, source.admitted.ownerName, source.material, bindings) { current(checkCurrent) }
        DetachedAccountFileKernel.requireLegacyReplay(scope, source.admitted.ownerName, native, source.material, bindings) { current(checkCurrent) }
        nativeSchema(native, scope)
        // Require the actual import baseline now; reimport compares this real kernel-produced
        // source receipt, never a hash manufactured from a profile ID or a file label.
        OHJson.Obj(OHJson.Obj(native).obj("legacyImport").raw("baseline"))
        current(checkCurrent); native
    }
    private fun admitCoreNative(native: ByteArray, scope: VortxAccountScope,
        bindings: VortxRuntimeBindings, checkCurrent: () -> Unit) {
        nativeSchema(native, scope)
        requireSharedSources(native, scope.ownerProfileID)
        val state = checked(Reason.NATIVE_REJECTED) {
            DetachedAccountFileKernel.fileRestoreState(scope, native, bindings) { current(checkCurrent) }
        }
        requireSharedSources(state, scope.ownerProfileID)
        current(checkCurrent)
    }

    private fun scope(context: Context): VortxAccountScope {
        checked(Reason.MATCHING_ACCOUNT_REQUIRED) {
            require(UUID.fromString(context.accountID).toString() == context.accountID &&
                UUID.fromString(context.expectedOwnerProfileID).toString().uppercase(Locale.ROOT) == context.expectedOwnerProfileID)
            require(context.operationGeneration >= 0 && context.ownerEpoch >= 0)
        }
        if (!Regex("[0-9a-f]{64}").matches(context.ownerWitnessSHA256)) fail(Reason.OWNER_WITNESS_REQUIRED)
        return VortxAccountScope("account.${context.accountID}", context.expectedOwnerProfileID)
    }
    private fun nativeSchema(native: ByteArray, scope: VortxAccountScope): Int = checked(Reason.NATIVE_REJECTED) {
        bounded(native, MAXIMUM_PLAINTEXT_BYTES)
        val raw = OHJson.Obj(native); val schema = OHJson.integer(raw.raw("schemaVersion"))
        require(schema in 1L..5L && raw["ownerHistory"] == null && raw.text("scope") == scope.accountID &&
            raw.text("ownerProfileId") == scope.ownerProfileID)
        schema.toInt()
    }
    private fun envelope(file: ByteArray, allowRepair: Boolean): AccountBackupFile.Inspection {
        bounded(file, MAXIMUM_FILE_BYTES)
        val inspection = checked(Reason.INVALID_ENVELOPE) { AccountBackupFile.inspect(file) }
        if (!allowRepair && OHJson.Obj(file)[REPAIR_KEY] != null) fail(Reason.EXISTING_NATIVE_REQUIRES_VALIDATION)
        return inspection
    }
    private fun open(key: ByteArray, document: String, account: String, version: Long,
        limit: Int, reason: Reason): ByteArray {
        // Bound the ciphertext before the crypto helper allocates decoded/copy buffers.
        val encoded = if (document.startsWith(VortXCrypto.DOC_V2_PREFIX)) document.drop(3) else document
        if (encoded.length.toLong() > 4L * ((limit.toLong() + 28 + 2) / 3)) fail(Reason.TOO_LARGE)
        checked(reason) { OHJson.un64(encoded) }
        val plaintext = VortXCrypto.openDocument(key, document, account, version) ?: fail(reason)
        bounded(plaintext, limit); return plaintext
    }
    private fun seal(key: ByteArray, plaintext: ByteArray, account: String, version: Long): String {
        val sealed = VortXCrypto.sealDocument(key, plaintext, account, version, writeV2 = true) ?: fail(Reason.ENCRYPTION_FAILED)
        if (VortXCrypto.openDocument(key, sealed, account, version)?.contentEquals(plaintext) != true) fail(Reason.ENCRYPTION_FAILED)
        return sealed
    }
    private fun requireConservation(original: ByteArray, candidate: ByteArray) = checked(Reason.PRESERVATION_FAILED) {
        bounded(original, MAXIMUM_PLAINTEXT_BYTES); bounded(candidate, MAXIMUM_PLAINTEXT_BYTES)
        val before = OHJson.Obj(original); val after = OHJson.Obj(candidate)
        require(before["nativeSync"] == null && after.keys == before.keys + "nativeSync" &&
            before.keys.all { after.raw(it).contentEquals(before.raw(it)) })
    }
    private fun requireOuterConservation(before: OHJson.Obj, after: OHJson.Obj) = checked(Reason.PRESERVATION_FAILED) {
        require(before[REPAIR_KEY] == null && after.keys == before.keys + REPAIR_KEY &&
            before.keys.all { it == "document" || after.raw(it).contentEquals(before.raw(it)) })
    }

    /** Same restricted shared-source scope as Apple, applied before and after cold normalization.
     * This does not replace full encoded host/archive inspection and confers no source authority. */
    private fun requireSharedSources(bytes: ByteArray, owner: String) = checked(Reason.UNSUPPORTED_ACCOUNT_SOURCE) {
        var nodes = 0
        fun walk(raw: ByteArray, profileID: String?, depth: Int) {
            require(depth <= 64 && ++nodes <= 100_000)
            when (raw.firstOrNull()?.toInt()?.toChar()) {
                '{' -> {
                    val value = OHJson.Obj(raw)
                    require(value.keys.intersect(forbiddenNativeSources).isEmpty())
                    for (key in listOf("ownAccountSources", "ownAccountSourceHistory")) value[key]?.let { require(OHJson.Obj(it).keys.isEmpty()) }
                    value["account"]?.let { account ->
                        if (account.firstOrNull() == '{'.code.toByte()) {
                            val binding = OHJson.Obj(account)
                            binding["kind"]?.let {
                                val kind = OHJson.text(it)
                                val ownerRecord = profileID == owner || value["id"]?.let { id ->
                                    id.firstOrNull() == '"'.code.toByte() && OHJson.text(id) == owner
                                } == true &&
                                    value["owner"]?.contentEquals(OHJson.literal("true")) == true
                                require(kind == "shared" && (binding["value"] == null || binding.text("value") == owner) ||
                                    ownerRecord && kind == "local_only" && binding["value"] == null)
                            }
                        } else if (account.firstOrNull() == '"'.code.toByte()) {
                            val kind = OHJson.text(account)
                            require(kind !in setOf("own", "pending_own") && !(kind == "local_only" && profileID != owner))
                        }
                    }
                    for (key in value.keys) {
                        val nextProfile = if (runCatching { UUID.fromString(key).toString().uppercase(Locale.ROOT) == key }.getOrDefault(false)) key else profileID
                        walk(value.raw(key), nextProfile, depth + 1)
                    }
                }
                '[' -> OHJson.array(raw).forEach { walk(it, profileID, depth + 1) }
            }
        }
        // Runtime STATE may have leading JSON whitespace. Parse the whole root so it cannot
        // bypass traversal; this ephemeral encoding never replaces selected/native bytes.
        walk(OHJson.Obj(bytes).encoded(), null, 0)
    }
    private fun current(checkCurrent: () -> Unit) {
        if (Thread.currentThread().isInterrupted) throw CancellationException("File preparation cancelled")
        checkCurrent()
    }
    private fun bounded(bytes: ByteArray, limit: Int) { if (bytes.size > limit) fail(Reason.TOO_LARGE) }
    private fun fail(reason: Reason): Nothing = throw Failure(reason)
    private inline fun <T> checked(reason: Reason, block: () -> T): T = try { block() }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Failure) { throw failure }
        catch (_: Exception) { fail(reason) }
}
