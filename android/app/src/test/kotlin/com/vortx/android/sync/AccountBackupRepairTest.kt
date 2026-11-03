package com.vortx.android.sync

import com.vortx.android.backup.SettingsBackup
import com.vortx.android.engine.OHJson
import com.vortx.android.engine.VortxRuntimeBindings
import java.util.Date
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

/** Synthetic account fixture only. Production admission, material, crypto, framing and converter
 * execute unchanged; Bindings below deliberately fake the kernel and prove no JNI semantics. */
internal object AccountBackupRepairFixture {
    const val account = "7db1d430-7d3e-446b-9b16-16e45251c829"
    const val owner = "00000000-0000-0000-0000-00000000A11C"
    const val child = "10000000-0000-0000-0000-000000000001"
    const val version = 1720000000042L
    fun key() = ByteArray(32) { (it + 1).toByte() }
    fun context(dataKey: ByteArray = key(), accountID: String = account, ownerID: String = owner,
        witness: String = "a".repeat(64)) = AccountBackupRepair.Context(accountID, dataKey, ownerID, witness, 7, 11)
    fun source(settings: Boolean = true): ByteArray {
        val fixture = OHJson.Obj(requireNotNull(javaClass.classLoader?.getResourceAsStream("account-file-profile-material.json")).use { it.readBytes() })
        val raw = OHJson.Obj(OHJson.Obj(OHJson.array(fixture.raw("cases")).first()).raw("source"))
        raw.set("future", OHJson.literal("{ \"number\":1.2300,\"precise\":9007199254740991,\"text\":\" retained \" }"))
        raw.set("apiKeys", OHJson.literal("{\"metadata\":{\"synthetic\":\"fixture-only-not-a-secret\"}}"))
        if (settings) {
            val domain = linkedMapOf<String, Any>("stremiox.profiles" to raw.obj("vortx").raw("roster"),
                "stremiox.profiles.modified" to 1720000000.25, "future.setting" to "kept")
            val envelope = requireNotNull(SettingsBackup.encode(domain, "fixture.bundle", "fixture-app", Date(0)))
            raw.set("settings", OHJson.quote(OHJson.b64(envelope)))
        }
        return raw.encoded()
    }
    fun file(plaintext: ByteArray = source(), v2: Boolean = true): ByteArray = OHJson.Obj()
        .set("vortxBackup", OHJson.literal("1")).set("version", OHJson.literal(version.toString()))
        .set("username", OHJson.quote("synthetic-fixture")).set("exportedAt", OHJson.literal("1700000000000"))
        .set("futureEnvelope", OHJson.literal("{ \"n\":1.2300,\"array\":[3,2,1] }"))
        .set("document", OHJson.quote(requireNotNull(VortXCrypto.sealDocument(key(), plaintext, account, version, v2)))).encoded()
    fun plaintext(file: ByteArray): ByteArray = AccountBackupFile.inspect(file).let {
        requireNotNull(VortXCrypto.openDocument(key(), it.document, account, it.version))
    }
    fun replaceCandidate(file: ByteArray, change: (OHJson.Obj) -> Unit): ByteArray {
        val envelope = OHJson.Obj(file); val plain = OHJson.Obj(plaintext(file)); change(plain)
        val next = plain.encoded()
        envelope.set("document", OHJson.quote(requireNotNull(VortXCrypto.sealDocument(key(), next, account, version, true))))
        envelope.set(AccountBackupRepair.REPAIR_KEY, envelope.obj(AccountBackupRepair.REPAIR_KEY)
            .set("candidatePlaintextSHA256", OHJson.quote(OHJson.sha(next))).encoded())
        return envelope.encoded()
    }

    class Bindings : VortxRuntimeBindings {
        var created = 0; var freed = 0
        val live = linkedMapOf<Long, OHJson.Obj>()
        val actions = arrayListOf<String>()
        var onAction: ((String) -> Unit)? = null
        var hiddenStateSource = false
        var rejectImport = false
        override fun create(ownerId: String, ownerName: String): Long {
            val id = (++created).toLong()
            val profile = OHJson.Obj().set("id", OHJson.quote(ownerId)).set("name", OHJson.quote(ownerName))
                .set("owner", OHJson.literal("true")).set("deleted", OHJson.literal("false"))
            val native = OHJson.Obj().set("schemaVersion", OHJson.literal("1")).set("scope", OHJson.quote("account.$account"))
                .set("ownerProfileId", OHJson.quote(ownerId)).set("profiles", OHJson.literal("{}"))
                .set("addons", OHJson.literal("{}")).set("libraries", OHJson.literal("{}")).set("watches", OHJson.literal("{}"))
            live[id] = OHJson.Obj().set("nativeSync", native.encoded()).set("activeProfileId", OHJson.quote(ownerId))
                .set("roster", OHJson.Obj().set("profiles", OHJson.Obj().set(ownerId, profile.encoded()).encoded()).encoded())
                .set("libraries", OHJson.Obj().set(ownerId, OHJson.literal("{}")).encoded())
            return id
        }
        override fun dispatch(handle: Long, action: String): String {
            val input = OHJson.Obj(action.toByteArray()); val type = input.text("type")
            actions += type; onAction?.invoke(type)
            if (rejectImport && type in setOf("import_legacy_sync", "reconcile_legacy_sync")) return "{\"ok\":false}"
            val state = requireNotNull(live[handle]); var native = state.obj("nativeSync")
            when (type) {
                "bind_sync_scope" -> native.set("scope", input.raw("scope"))
                "merge_native_sync" -> native = input.obj("document")
                "import_legacy_sync", "reconcile_legacy_sync" -> {
                    val material = input.obj("material")
                    native.set("legacyImport", OHJson.Obj().set("schemaVersion", material.raw("schemaVersion"))
                        .set("baseline", material.encoded()).encoded())
                    val profiles = OHJson.Obj()
                    OHJson.array(material.raw("roster")).forEach { row ->
                        profiles.set(OHJson.Obj(row).text("id"), OHJson.Obj().set("profile", row).encoded())
                    }
                    native.set("profiles", profiles.encoded())
                }
                else -> error("Unexpected synthetic cold action")
            }
            state.set("nativeSync", native.encoded())
            if (native.obj("profiles").keys.isNotEmpty()) {
                val profiles = OHJson.Obj(); val libraries = OHJson.Obj()
                for (id in native.obj("profiles").keys) {
                    val profile = native.obj("profiles").obj(id).obj("profile").set("deleted", OHJson.literal("false"))
                    profiles.set(id, profile.encoded()); libraries.set(id, OHJson.literal("{}"))
                }
                state.set("roster", OHJson.Obj().set("profiles", profiles.encoded()).encoded()).set("libraries", libraries.encoded())
            }
            return "{\"ok\":true}"
        }
        override fun state(handle: Long): String {
            val state = requireNotNull(live[handle]).copy()
            if (hiddenStateSource) state.set("future", OHJson.literal("{\"nativeProviderCredentials\":null}"))
            return " \n" + OHJson.utf8(state.encoded()) // Must not bypass source traversal.
        }
        override fun free(handle: Long) { check(live.remove(handle) != null); freed++ }
        override fun hydrate(snapshot: String): Long = error("No mounted session/checkpoint")
        override fun resolve(handle: Long, request: String): String? = error("No NativeRead/ACK")
        override fun delta(handle: Long): String? = error("No delta drain/floor")
    }
}

class AccountBackupRepairTest {
    private val f = AccountBackupRepairFixture
    private fun refuses(block: () -> Unit) { assertTrue(runCatching(block).exceptionOrNull() is AccountBackupRepair.Failure) }

    @Test fun conversionPreservesBothFullCarriersCredentialsUnknownSlicesAndEntireOriginalFile() {
        for (versionBound in listOf(false, true)) {
            val plaintext = f.source(); val original = f.file(plaintext, versionBound); val before = original.copyOf()
            val bindings = AccountBackupRepairFixture.Bindings()
            f.context().use { context -> AccountBackupRepair.convert(original, context, bindings) {}.use { candidate ->
                assertEquals(AccountBackupRepair.Disposition.CONVERTED_LEGACY, candidate.disposition)
                assertEquals(2, candidate.profileCount); assertEquals(f.version, candidate.originalVersion)
                assertEquals(OHJson.sha(original), candidate.sourceSHA256)
                val bytes = candidate.fileBytes(); val envelope = OHJson.Obj(bytes); val sourceEnvelope = OHJson.Obj(original)
                sourceEnvelope.keys.filter { it != "document" }.forEach { assertArrayEquals(sourceEnvelope.raw(it), envelope.raw(it)) }
                val next = OHJson.Obj(f.plaintext(bytes)); val source = OHJson.Obj(plaintext)
                assertEquals(source.keys + "nativeSync", next.keys)
                source.keys.forEach { assertArrayEquals(source.raw(it), next.raw(it)) }
                assertEquals(OHJson.sha(f.plaintext(bytes)), candidate.candidatePlaintextSHA256)
                val manifest = envelope.obj(AccountBackupRepair.REPAIR_KEY)
                val archived = manifest.text("originalFileDocument")
                assertArrayEquals(original, VortXCrypto.openDocument(f.key(), archived, AccountBackupRepair.SOURCE_ARCHIVE_DOMAIN + f.account, f.version))
                assertNull(VortXCrypto.openDocument(f.key(), archived, f.account, f.version))
                assertNull(VortXCrypto.openDocument(f.key(), archived, AccountBackupRepair.SOURCE_ARCHIVE_DOMAIN + f.account, f.version + 1))
                val baseline = next.obj("nativeSync").obj("legacyImport").obj("baseline")
                val kid = OHJson.array(baseline.raw("roster")).map { OHJson.Obj(it) }.single { it.text("id") == f.child }
                assertEquals(f.owner, kid.obj("account").text("value")); assertEquals("shared", kid.obj("account").text("kind"))
                assertEquals("true", OHJson.utf8(kid.obj("parental").raw("kids")))
                assertEquals("true", OHJson.utf8(kid.obj("parental").raw("familyEdit")))
                assertEquals("sha256:" + "a".repeat(64), kid.text("pin"))
                bytes.fill(0); assertEquals(candidate.fileSHA256, OHJson.sha(candidate.fileBytes()))
            } }
            assertArrayEquals(before, original); assertEquals(3, bindings.created); assertEquals(bindings.created, bindings.freed)
            assertTrue(bindings.live.isEmpty())
        }
    }

    @Test fun validatedReimportRetainsSelectedCiphertextNativeUnknownHistoryAndManifest() {
        f.context().use { context ->
            val selected = AccountBackupRepair.convert(f.file(), context, AccountBackupRepairFixture.Bindings()) {}.use { it.fileBytes() }
            val withUnknown = f.replaceCandidate(selected) { raw -> raw.set("nativeSync", raw.obj("nativeSync")
                .set("futureNative", OHJson.literal("{ \"lexeme\":1.2300,\"syntheticLaterState\":true }")).encoded()) }
            val before = withUnknown.copyOf(); val nativeBefore = OHJson.Obj(f.plaintext(before)).raw("nativeSync")
            val bindings = AccountBackupRepairFixture.Bindings()
            AccountBackupRepair.validateReimport(withUnknown, context, bindings) {}.use { result ->
                assertEquals(AccountBackupRepair.Disposition.VALIDATED_EXISTING_CANDIDATE, result.disposition)
                assertArrayEquals(before, result.fileBytes()); assertArrayEquals(nativeBefore, OHJson.Obj(f.plaintext(result.fileBytes())).raw("nativeSync"))
            }
            assertArrayEquals(before, withUnknown); assertEquals(4, bindings.created); assertEquals(4, bindings.freed)
            // The fake kernel proves conservation/orchestration only, not actual later causal history.
            refuses { AccountBackupRepair.convert(withUnknown, context, bindings) {} }
        }
    }

    @Test fun eachSupportedFullLegacyRosterCarrierRemainsAConvertibleSource() {
        val both = f.source()
        for (source in listOf(both, OHJson.Obj(both).remove("settings").encoded(), OHJson.Obj(both).remove("vortx").encoded())) {
            val original = f.file(source)
            f.context().use { context -> AccountBackupRepair.convert(original, context,
                AccountBackupRepairFixture.Bindings()) {}.use { result ->
                assertEquals(2, result.profileCount)
                val next = OHJson.Obj(f.plaintext(result.fileBytes())); val before = OHJson.Obj(source)
                before.keys.forEach { assertArrayEquals(before.raw(it), next.raw(it)) }
                assertEquals(before.keys + "nativeSync", next.keys)
            } }
        }
    }

    @Test fun forgedMetadataChangedRawSourceAndWrongBaselineNeverBecomeReimportAuthority() {
        f.context().use { context ->
            val selected = AccountBackupRepair.convert(f.file(), context, AccountBackupRepairFixture.Bindings()) {}.use { it.fileBytes() }
            val changes = listOf<(OHJson.Obj) -> Unit>(
                { it.set("future", OHJson.literal("{\"number\":1.23,\"precise\":9007199254740991,\"text\":\" retained \"}")) },
                { it.set("apiKeys", OHJson.literal("{}")) },
                { it.set("nativeSync", it.obj("nativeSync").set("schemaVersion", OHJson.literal("6")).encoded()) },
                { it.set("nativeSync", it.obj("nativeSync").set("ownerHistory", OHJson.literal("null")).encoded()) },
                { it.set("nativeSync", it.obj("nativeSync").set("scope", OHJson.quote("account.other")).encoded()) },
                { raw -> val native = raw.obj("nativeSync"); native.set("legacyImport", native.obj("legacyImport")
                    .set("baseline", native.obj("legacyImport").obj("baseline").set("futureWrongSource", OHJson.literal("true")).encoded()).encoded())
                    raw.set("nativeSync", native.encoded()) },
                { it.set("nativeSync", it.obj("nativeSync").set("dormant", OHJson.literal("{\"ownAccountSourceHistory\":{\"unproven\":1}} ")).encoded()) })
            for (change in changes) {
                val altered = f.replaceCandidate(selected, change); val before = altered.copyOf()
                refuses { AccountBackupRepair.validateReimport(altered, context, AccountBackupRepairFixture.Bindings()) {} }
                assertArrayEquals(before, altered)
            }
            for ((key, value) in listOf("sourceSHA256" to "b".repeat(64), "candidatePlaintextSHA256" to "b".repeat(64),
                "sourceKind" to "authenticated_cloud_read", "conversion" to "other")) {
                val raw = OHJson.Obj(selected); raw.set(AccountBackupRepair.REPAIR_KEY,
                    raw.obj(AccountBackupRepair.REPAIR_KEY).set(key, OHJson.quote(value)).encoded())
                refuses { AccountBackupRepair.validateReimport(raw.encoded(), context, AccountBackupRepairFixture.Bindings()) {} }
            }
            val outer = OHJson.Obj(selected).set("exportedAt", OHJson.literal("1")).encoded()
            refuses { AccountBackupRepair.validateReimport(outer, context, AccountBackupRepairFixture.Bindings()) {} }
            val wrongPurpose = OHJson.Obj(selected)
            val original = requireNotNull(VortXCrypto.openDocument(f.key(), wrongPurpose.obj(AccountBackupRepair.REPAIR_KEY)
                .text("originalFileDocument"), AccountBackupRepair.SOURCE_ARCHIVE_DOMAIN + f.account, f.version))
            wrongPurpose.set(AccountBackupRepair.REPAIR_KEY, wrongPurpose.obj(AccountBackupRepair.REPAIR_KEY)
                .set("originalFileDocument", OHJson.quote(requireNotNull(VortXCrypto.sealDocument(f.key(), original,
                    f.account, f.version, true)))).encoded())
            val noDispatch = AccountBackupRepairFixture.Bindings()
            refuses { AccountBackupRepair.validateReimport(wrongPurpose.encoded(), context, noDispatch) {} }
            assertEquals(0, noDispatch.created)
        }
    }

    @Test fun invalidContextsUnsupportedSourceAndNativeRefusalNeverReleaseCandidate() {
        val file = f.file()
        for (context in listOf(f.context(ByteArray(32)), f.context(ownerID = f.child),
            f.context(accountID = "7db1d430-7d3e-446b-9b16-16e45251c828"),
            f.context(accountID = f.account.uppercase()), f.context(witness = "file-owner-is-not-a-receipt"))) {
            context.use { val bindings = AccountBackupRepairFixture.Bindings()
                refuses { AccountBackupRepair.convert(file, it, bindings) {} }; assertEquals(0, bindings.created) }
        }
        f.context().use { context ->
            for (key in listOf("nativeSync", "nativeHostPreferences", "profileEdits", "ownAccountOverlayPending", "nativeOwnAccountPending")) {
                val invalid = f.file(OHJson.Obj(f.source()).set(key, OHJson.literal("null")).encoded())
                val bindings = AccountBackupRepairFixture.Bindings()
                refuses { AccountBackupRepair.convert(invalid, context, bindings) {} }; assertEquals(0, bindings.created)
            }
            for (bindings in listOf(AccountBackupRepairFixture.Bindings().apply { rejectImport = true },
                AccountBackupRepairFixture.Bindings().apply { hiddenStateSource = true })) {
                refuses { AccountBackupRepair.convert(file, context, bindings) {} }
                assertEquals(bindings.created, bindings.freed); assertTrue(bindings.live.isEmpty())
            }
            val huge = ByteArray(AccountBackupRepair.MAXIMUM_FILE_BYTES + 1)
            val bindings = AccountBackupRepairFixture.Bindings()
            refuses { AccountBackupRepair.convert(huge, context, bindings) {} }; assertEquals(0, bindings.created)
        }
    }

    @Test fun originalOperationCancellationAtEveryConversionFenceClosesAllHandles() {
        val file = f.file(); var count = 0
        f.context().use { context -> AccountBackupRepair.convert(file, context, AccountBackupRepairFixture.Bindings()) { count++ }.close() }
        assertTrue(count > 20)
        for (stop in 1..count) {
            val bindings = AccountBackupRepairFixture.Bindings(); val calls = AtomicInteger()
            f.context().use { context ->
                val result = runCatching { AccountBackupRepair.convert(file, context, bindings) {
                    if (calls.incrementAndGet() == stop) throw CancellationException("Synthetic original owner/operation retired")
                } }
                assertTrue("Fence $stop", result.exceptionOrNull() is CancellationException)
            }
            assertEquals("Fence $stop", bindings.created, bindings.freed); assertTrue(bindings.live.isEmpty())
        }
        val context = f.context(); val bindings = AccountBackupRepairFixture.Bindings()
        bindings.onAction = { if (it == "import_legacy_sync") context.close() }
        assertTrue(runCatching { AccountBackupRepair.convert(file, context, bindings) {} }.exceptionOrNull() is CancellationException)
        assertEquals(bindings.created, bindings.freed); context.close()
    }

    @Test fun contextAndCandidateOwnershipAreCopiedClosedAndRedacted() {
        val key = f.key(); val context = f.context(key); key.fill(0)
        val candidate = AccountBackupRepair.convert(f.file(), context, AccountBackupRepairFixture.Bindings()) {}
        assertEquals("AccountBackupRepair.Context", context.toString())
        assertEquals("AccountBackupRepair.CoreCandidate", candidate.toString())
        context.close(); context.close()
        assertTrue(runCatching { context.keyCopy() }.exceptionOrNull() is CancellationException)
        val bytes = candidate.fileBytes(); candidate.close(); candidate.close()
        assertTrue(runCatching { candidate.fileBytes() }.exceptionOrNull() is CancellationException)
        assertTrue(bytes.isNotEmpty()) // Caller owns this returned copy and its later cleanup.
    }

    @Test fun reimportCancellationAtEveryFenceNeverReleasesSelectedBytes() {
        val selected = f.context().use { context ->
            AccountBackupRepair.convert(f.file(), context, AccountBackupRepairFixture.Bindings()) {}.use { it.fileBytes() }
        }
        val before = selected.copyOf(); var count = 0
        f.context().use { context -> AccountBackupRepair.validateReimport(selected, context,
            AccountBackupRepairFixture.Bindings()) { count++ }.close() }
        assertTrue(count > 20)
        for (stop in 1..count) {
            val bindings = AccountBackupRepairFixture.Bindings(); val checks = AtomicInteger()
            f.context().use { context ->
                val attempt = runCatching { AccountBackupRepair.validateReimport(selected, context, bindings) {
                    if (checks.incrementAndGet() == stop) throw CancellationException("Synthetic original reimport retired")
                } }
                assertTrue("Reimport fence $stop", attempt.exceptionOrNull() is CancellationException)
            }
            assertEquals(bindings.created, bindings.freed); assertTrue(bindings.live.isEmpty())
            assertArrayEquals(before, selected)
        }
    }

    @Test fun inspectDoesNotNeedAKeyAndCiphertextBudgetsFailBeforeNativeCalls() {
        val file = f.file(v2 = false)
        assertEquals(AccountBackupRepair.Format.EncryptedAccount(f.version, false), AccountBackupRepair.inspect(file))
        assertEquals(AccountBackupRepair.Format.SettingsOnly, AccountBackupRepair.inspect(OHJson.literal("{\"format\":\"vortx-backup\",\"schema\":1}")))
        assertEquals(AccountBackupRepair.Format.Unsupported, AccountBackupRepair.inspect(OHJson.literal("{}")))
        refuses { AccountBackupRepair.inspect(OHJson.literal("{\"vortxBackup\":1,\"vortxBackup\":1}")) }
        refuses { AccountBackupRepair.inspect(OHJson.literal("{\"format\":\"vortx-backup\",\"schema\":2}")) }
        val tooLargePlaintext = ByteArray(AccountBackupRepair.MAXIMUM_PLAINTEXT_BYTES + 1) { ' '.code.toByte() }
        val oversized = f.file(tooLargePlaintext)
        val bindings = AccountBackupRepairFixture.Bindings()
        f.context().use { context -> refuses { AccountBackupRepair.convert(oversized, context, bindings) {} } }
        assertEquals(0, bindings.created)
    }

    @Test fun unknownOuterFormatMetadataDoesNotOverrideAuthenticatedAccountFraming() {
        val plaintext = f.source(); val base = f.file(plaintext)
        val shapes = listOf("null", "{ \"future\":1.2300,\"array\":[3,2,1] }", "1.2300",
            "[1, {\"future\":true}]", "true", "\"future-account-v2\"")
        for (shape in shapes) {
            val format = OHJson.literal(shape)
            val original = OHJson.Obj(base).set("format", format).encoded()
            val originalBefore = original.copyOf()
            assertEquals(AccountBackupRepair.Format.EncryptedAccount(f.version, true), AccountBackupRepair.inspect(original))
            assertArrayEquals(plaintext, f.plaintext(original)) // Genuine crypto framing, not a fake envelope.
            f.context().use { context ->
                AccountBackupRepair.convert(original, context, AccountBackupRepairFixture.Bindings()) {}.use { converted ->
                    val repaired = converted.fileBytes(); val repairedRoot = OHJson.Obj(repaired)
                    assertArrayEquals(format, repairedRoot.raw("format"))
                    val sourceRoot = OHJson.Obj(originalBefore)
                    sourceRoot.keys.filter { it != "document" }.forEach { key ->
                        assertArrayEquals(sourceRoot.raw(key), repairedRoot.raw(key))
                    }
                    val archived = repairedRoot.obj(AccountBackupRepair.REPAIR_KEY).text("originalFileDocument")
                    assertArrayEquals(originalBefore, VortXCrypto.openDocument(f.key(), archived,
                        AccountBackupRepair.SOURCE_ARCHIVE_DOMAIN + f.account, f.version))
                    assertEquals(AccountBackupRepair.Format.EncryptedAccount(f.version, true), AccountBackupRepair.inspect(repaired))
                    AccountBackupRepair.validateReimport(repaired, context, AccountBackupRepairFixture.Bindings()) {}.use { admitted ->
                        assertArrayEquals(repaired, admitted.fileBytes())
                        assertArrayEquals(format, OHJson.Obj(admitted.fileBytes()).raw("format"))
                    }
                }
            }
            assertArrayEquals(originalBefore, original)
            val invalidAccount = OHJson.Obj(original).set("vortxBackup", OHJson.literal("2")).encoded()
            refuses { AccountBackupRepair.inspect(invalidAccount) }
        }
        // Keep the exact recognized marker's existing precedence, including a JSON-escaped string.
        val settings = OHJson.Obj(base).set("format", OHJson.literal("\"\\u0076ortx-backup\""))
            .set("schema", OHJson.literal("1")).encoded()
        assertEquals(AccountBackupRepair.Format.SettingsOnly, AccountBackupRepair.inspect(settings))
        refuses { AccountBackupRepair.inspect(OHJson.Obj(settings).set("schema", OHJson.literal("2")).encoded()) }
    }
}
