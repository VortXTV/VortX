package com.vortx.android.sync

import com.vortx.android.engine.AccountFileLocalPresence
import com.vortx.android.engine.VortxAccountScope
import com.vortx.android.engine.VortxEncryptedCheckpointStore
import com.vortx.android.engine.boundedCompleteRestoreAliases
import com.vortx.android.engine.readVettedNamedCheckpointKey
import com.vortx.android.engine.supportsCompleteRestoreAliasInventory
import com.vortx.android.profile.UserProfile
import com.vortx.android.security.CredentialBackend
import com.vortx.android.security.FailClosedCredentialState
import com.vortx.android.security.RestoreCredentialBacking
import com.vortx.android.security.RestoreCredentialOpenGate
import com.vortx.android.security.RestoreCredentialReceipt
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.Base64
import java.util.Collections
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AccountFileRestoreAbsenceTest {
    private val target = VortxAccountScope(
        "account.11111111-1111-1111-1111-111111111111", "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
    )
    private val foreign = VortxAccountScope(
        "account.22222222-2222-2222-2222-222222222222", "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
    )
    private val key = SecretKeySpec(ByteArray(32) { 42 }, "AES")

    @Test fun missingInventoryUsesTwoCompleteAliasReadsWithoutCreatingStorage() = withDirectory { parent ->
        val path = File(parent, "native-state")
        val store = store(path)
        var aliasReads = 0
        assertEquals(AccountFileLocalPresence.ABSENT, store.inspectRestoreAbsence(target, {
            aliasReads++
            appAliases
        }) { throw AssertionError("No native descriptor can use a key") })
        assertEquals(2, aliasReads)
        assertEquals(AccountFileLocalPresence.UNAVAILABLE, store.inspectRestoreAbsence(target, {
            error("synthetic incomplete inventory")
        }) { null })
        assertFalse(path.exists())
    }

    @Test fun aliasOnlyEarlierOwnersCaseVariantsAndUnknownNativeEntriesRefuse() = withDirectory { directory ->
        val store = store(directory)
        val previousOwners = listOf(target, target.copy(ownerProfileID = target.ownerProfileID.lowercase()),
            target.copy(ownerProfileID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"),
            target.copy(ownerProfileID = UserProfile.OWNER_ID),
            locatorDomain(target), preflightDomain(target), foreign)
        for (unbound in previousOwners.map(::alias) + "VORTX.NATIVE.STATE.V1.unindexed") {
            assertEquals(AccountFileLocalPresence.UNAVAILABLE,
                store.inspectRestoreAbsence(target, { appAliases + unbound }) { null })
        }
        var reads = 0
        assertEquals(AccountFileLocalPresence.UNAVAILABLE, store.inspectRestoreAbsence(target, {
            if (++reads == 1) appAliases else appAliases + alias(foreign)
        }) { null })
        assertEquals(2, reads)
    }

    @Test fun aLegacyStableTruncatedInventoryHasNoCompletenessAuthority() {
        val provider = "android.security.keystore2.AndroidKeyStoreProvider"
        val service = "android.security.keystore2.AndroidKeyStoreSpi"
        val truncated = listOf("unrelated-app-key")
        assertEquals(truncated.toSet(), boundedCompleteRestoreAliases({ 1 }) { Collections.enumeration(truncated) })
        assertFalse(supportsCompleteRestoreAliasInventory(33, provider, service))
        assertFalse(supportsCompleteRestoreAliasInventory(34, "unverified.Provider", service))
        assertFalse(supportsCompleteRestoreAliasInventory(34, provider, "unverified.Spi"))
        assertTrue(supportsCompleteRestoreAliasInventory(34, provider, service))
        assertTrue(runCatching {
            boundedCompleteRestoreAliases({ 2 }) { Collections.enumeration(truncated) }
        }.isFailure)
        assertTrue(runCatching {
            boundedCompleteRestoreAliases({ 0 }) { error("Zero count must refuse before enumeration") }
        }.isFailure)
        assertTrue(runCatching {
            boundedCompleteRestoreAliases({ 2 }) { Collections.enumeration(truncated + truncated) }
        }.isFailure)
        var countReads = 0
        assertTrue(runCatching {
            boundedCompleteRestoreAliases({ ++countReads }) { Collections.enumeration(truncated) }
        }.isFailure)
    }

    @Test fun targetScopeLocatorPreflightAndDigestSiblingAlwaysRefuse() = withDirectory { directory ->
        val store = store(directory)
        val paths = listOf(
            stateFile(target), locatorFile(target), preflightFile(target), "unknown-${target.digest}.old",
        )
        for (name in paths) {
            val occupied = File(directory, name).apply { writeBytes(byteArrayOf(0)) }
            assertEquals(AccountFileLocalPresence.PRESENT, store.inspectRestoreAbsence(target, {
                throw AssertionError("Target path must refuse before inventorying keys")
            }) { throw AssertionError("Target path must refuse before opening keys") })
            assertEquals(listOf<Byte>(0), occupied.readBytes().toList())
            assertTrue(occupied.delete())
        }
    }

    @Test fun onlyAnAuthenticatedForeignLocatorCoversAForeignCheckpointAndItsAliases() = withDirectory { directory ->
        val store = store(directory)
        val checkpoint = File(directory, stateFile(foreign)).apply { writeBytes(ByteArray(28)) }
        val locator = File(directory, locatorFile(foreign))
        val domain = locatorDomain(foreign)
        val aliases = appAliases + alias(foreign) + alias(domain)
        val lookup: (VortxAccountScope) -> SecretKey? = { if (it == domain || it == foreign) key else null }
        assertEquals(AccountFileLocalPresence.UNAVAILABLE, store.inspectRestoreAbsence(target, { aliases }, lookup))
        locator.writeBytes(seal(domain, descriptor(foreign), key))
        assertEquals(AccountFileLocalPresence.ABSENT, store.inspectRestoreAbsence(target, { aliases }, lookup))
        assertEquals(AccountFileLocalPresence.UNAVAILABLE,
            store.inspectRestoreAbsence(target, { aliases + alias(target) }, lookup))
        assertEquals(AccountFileLocalPresence.UNAVAILABLE,
            store.inspectRestoreAbsence(target, { aliases - alias(foreign) }, lookup))
        assertEquals(AccountFileLocalPresence.UNAVAILABLE,
            store.inspectRestoreAbsence(target, { aliases }) { if (it == domain) key else null })
        locator.writeBytes(seal(domain, descriptor(target), key))
        assertEquals(AccountFileLocalPresence.UNAVAILABLE, store.inspectRestoreAbsence(target, { aliases }, lookup))
        assertEquals(28L, checkpoint.length())
    }

    @Test fun foreignPreflightRequiresAuthenticatedExactOwnerAndInterruptedStateRefuses() = withDirectory { directory ->
        val store = store(directory)
        val pending = File(directory, preflightFile(foreign))
        val domain = preflightDomain(foreign)
        val aliases = appAliases + alias(foreign) + alias(domain)
        val lookup: (VortxAccountScope) -> SecretKey? = { if (it == domain || it == foreign) key else null }
        val payload = Base64.getEncoder().encodeToString(ByteArray(28))
        pending.writeBytes(seal(domain, descriptor(foreign).dropLast(1) + ",\"sealedPayload\":\"$payload\"}", key))
        assertEquals(AccountFileLocalPresence.ABSENT, store.inspectRestoreAbsence(target, { aliases }, lookup))
        pending.writeBytes(seal(domain, descriptor(foreign).dropLast(1) + ",\"sealedPayload\":null}", key))
        assertEquals(AccountFileLocalPresence.UNAVAILABLE, store.inspectRestoreAbsence(target, { aliases }, lookup))
        assertTrue(pending.delete())
        val uncertain = File(directory, "native-checkpoint-staged.pending").apply { writeBytes(ByteArray(28)) }
        assertEquals(AccountFileLocalPresence.UNAVAILABLE, store.inspectRestoreAbsence(target, { appAliases }) { null })
        assertTrue(uncertain.isFile)
    }

    @Test fun websiteRosterNamedKeyProbeRejectsUnknownProvidersAndLookupErrors() = withDirectory { directory ->
        val store = store(directory)
        val provider = "android.security.keystore2.AndroidKeyStoreProvider"
        val service = "android.security.keystore2.AndroidKeyStoreSpi"
        var directReads = 0
        var metadataReads = 0
        fun inspect(sdk: Int, providerClass: String?, spi: String?,
                    direct: () -> java.security.Key?, metadata: () -> Boolean = { false }) =
            store.inspectWebsiteRosterAbsence(target) {
                readVettedNamedCheckpointKey(sdk, providerClass, spi,
                    directGetKey = { directReads++; direct() }, aliasPresent = { metadataReads++; metadata() })
            }
        for ((sdk, providerClass, spi) in listOf(
            Triple(30, provider, service),
            Triple(31, "android.security.keystore.AndroidKeyStoreProvider", service),
            Triple(34, provider, "unverified.KeyStoreSpi"),
            Triple(34, null, null),
        )) {
            assertEquals(AccountFileLocalPresence.UNAVAILABLE, inspect(sdk, providerClass, spi, { null }))
        }
        assertEquals(0, directReads)
        assertEquals(0, metadataReads)
        val unavailable = java.security.UnrecoverableKeyException("synthetic service failure")
        assertEquals(AccountFileLocalPresence.UNAVAILABLE, inspect(31, provider, service, { throw unavailable }))
        assertEquals(1, directReads)
        assertEquals(0, metadataReads)
        assertEquals(AccountFileLocalPresence.UNAVAILABLE, inspect(31, provider, service, { null }, { true }))
        assertEquals(1, metadataReads)
        assertEquals(AccountFileLocalPresence.UNAVAILABLE,
            inspect(31, provider, service, { SecretKeySpec(ByteArray(32), "HmacSHA256") }))
        assertEquals(AccountFileLocalPresence.PRESENT, inspect(31, provider, service, { key }))
        assertEquals(AccountFileLocalPresence.ABSENT, inspect(31, provider, service, { null }))
        assertTrue(directory.listFiles()!!.isEmpty())
    }

    @Test fun websiteRosterChecksKnownTargetKeysTwiceWithoutCreatingStorage() = withDirectory { parent ->
        val path = File(parent, "website-native-state")
        val store = store(path)
        val expected = setOf(target, target.copy(ownerProfileID = target.ownerProfileID.lowercase()),
            locatorDomain(target), preflightDomain(target))
        val lookups = mutableListOf<VortxAccountScope>()
        assertEquals(AccountFileLocalPresence.ABSENT, store.inspectWebsiteRosterAbsence(target) {
            lookups += it
            null
        })
        assertEquals(expected, lookups.toSet())
        assertEquals(expected.size * 2, lookups.size)
        assertTrue(expected.all { scope -> lookups.count { it == scope } == 2 })
        assertFalse(path.exists())
        for (occupied in expected) {
            assertEquals(AccountFileLocalPresence.PRESENT,
                store.inspectWebsiteRosterAbsence(target) { if (it == occupied) key else null })
        }
        assertEquals(AccountFileLocalPresence.UNAVAILABLE,
            store.inspectWebsiteRosterAbsence(target) { error("synthetic key unavailable") })
        var reads = 0
        assertEquals(AccountFileLocalPresence.PRESENT, store.inspectWebsiteRosterAbsence(target) {
            if (it == target && ++reads == 2) key else null
        })
        assertFalse(path.exists())
    }

    @Test fun websiteRosterRefusesTargetFilesInterruptedStorageAndSymlinks() = withDirectory { directory ->
        val store = store(directory)
        for (name in listOf(stateFile(target), locatorFile(target), preflightFile(target), "unknown-${target.digest}.old")) {
            val file = File(directory, name).apply { writeBytes(byteArrayOf(1)) }
            assertEquals(AccountFileLocalPresence.PRESENT, store.inspectWebsiteRosterAbsence(target) {
                throw AssertionError("Target file must refuse before key lookup")
            })
            assertTrue(file.delete())
        }
        for (name in listOf("native-checkpoint-incomplete.pending", "unknown-entry", stateFile(foreign))) {
            val file = File(directory, name).apply { writeBytes(ByteArray(28)) }
            assertEquals(AccountFileLocalPresence.UNAVAILABLE, store.inspectWebsiteRosterAbsence(target) { null })
            assertTrue(file.delete())
        }
        val link = File(directory, locatorFile(foreign)).toPath()
        Files.createSymbolicLink(link, File(directory, "missing-file").toPath())
        assertEquals(AccountFileLocalPresence.UNAVAILABLE, store.inspectWebsiteRosterAbsence(target) { null })
        assertTrue(Files.deleteIfExists(link))
    }

    @Test fun websiteRosterAuthenticatesForeignFilesAndRefusesAChangedInventory() = withDirectory { directory ->
        val store = store(directory)
        val checkpoint = File(directory, stateFile(foreign))
        val locator = File(directory, locatorFile(foreign))
        val preflight = File(directory, preflightFile(foreign))
        val locatorScope = locatorDomain(foreign)
        val preflightScope = preflightDomain(foreign)
        val lookup: (VortxAccountScope) -> SecretKey? = { if (it in setOf(foreign, locatorScope, preflightScope)) key else null }
        val owner = foreign.ownerProfileID
        val state = """{"roster":{"profiles":{"$owner":{"id":"$owner","owner":true,"deleted":false}}},"activeProfileId":"$owner","libraries":{"$owner":{}},"nativeSync":{"schemaVersion":1,"scope":"${foreign.accountID}","ownerProfileId":"$owner","profiles":{},"addons":{},"libraries":{},"watches":{}}}"""
        val inner = """{"format":"vortx-native-preflight-v1","id":"44444444-4444-4444-4444-444444444444","scope":"${foreign.accountID}","ownerProfileId":"$owner","hostArchive":{"document":{},"excludedCredentialPaths":[]},"ownCandidates":[]}"""
        fun preflightEnvelope(raw: ByteArray): ByteArray {
            val payload = Base64.getEncoder().encodeToString(raw)
            return seal(preflightScope, descriptor(foreign).dropLast(1) + ""","sealedPayload":"$payload"}""", key)
        }
        locator.writeBytes(seal(locatorScope, descriptor(foreign), key))
        checkpoint.writeBytes(seal(foreign, state, key))
        preflight.writeBytes(preflightEnvelope(seal(foreign, inner, key)))
        assertEquals(AccountFileLocalPresence.ABSENT, store.inspectWebsiteRosterAbsence(target, lookup))
        assertEquals(AccountFileLocalPresence.UNAVAILABLE,
            store.inspectWebsiteRosterAbsence(target) { if (it == foreign) null else lookup(it) })
        checkpoint.writeBytes(seal(foreign, "{}", key))
        assertEquals(AccountFileLocalPresence.UNAVAILABLE, store.inspectWebsiteRosterAbsence(target, lookup))
        checkpoint.writeBytes(seal(foreign, state, key))
        preflight.writeBytes(preflightEnvelope(ByteArray(28)))
        assertEquals(AccountFileLocalPresence.UNAVAILABLE, store.inspectWebsiteRosterAbsence(target, lookup))
        preflight.writeBytes(preflightEnvelope(seal(foreign, inner, key)))
        val intervening = File(directory, "native-checkpoint-intervening.pending")
        assertEquals(AccountFileLocalPresence.UNAVAILABLE, store.inspectWebsiteRosterAbsence(target) {
            if (it == foreign) intervening.writeBytes(ByteArray(28))
            lookup(it)
        })
        assertTrue(intervening.isFile)
    }

    @Test fun securePresenceOnlyWaivesInertRecordsThatMatchObservedBacking() {
        var reopen = 0
        var reads = 0
        var value: String? = null
        val backend = object : CredentialBackend {
            override fun string(key: String): String? = value
            override fun readExistingForRestore(keys: List<String>): Map<String, String?> {
                reads++
                return keys.associateWith { value }
            }
            override fun write(values: Map<String, String?>): Boolean =
                throw AssertionError("Restore probe must not write")
        }
        val unavailable = FailClosedCredentialState(null, reopenBackend = { reopen++; null })
        assertEquals(AccountFileLocalPresence.UNAVAILABLE, unavailable.inspectExisting("account-slot"))
        assertEquals(0, reopen)
        assertFalse(unavailable.write(mapOf("account-slot" to "memory-only")))
        assertEquals(1, reopen)
        assertEquals(AccountFileLocalPresence.PRESENT, unavailable.inspectExisting("account-slot"))
        assertEquals(1, reopen)

        val ready = FailClosedCredentialState(backend)
        assertEquals(AccountFileLocalPresence.ABSENT, ready.inspectExisting("account-slot"))
        value = ""
        assertEquals(AccountFileLocalPresence.PRESENT, ready.inspectExisting("account-slot"))
        value = "{}"
        assertEquals("{}", ready.string("account-slot"))
        assertEquals(AccountFileLocalPresence.ABSENT, ready.inspectExisting("account-slot") { it == "{}" })
        value = null
        assertEquals(AccountFileLocalPresence.UNAVAILABLE, ready.inspectExisting("account-slot") { it == "{}" })
        assertEquals(4, reads)
        for (failure in listOf(false, true)) {
            val unreadable = FailClosedCredentialState(object : CredentialBackend {
                override fun string(key: String): String? = null
                override fun readExistingForRestore(keys: List<String>): Map<String, String?>? =
                    if (failure) error("synthetic malformed backing") else null
                override fun write(values: Map<String, String?>): Boolean = error("Restore probe must not write")
            })
            assertEquals(AccountFileLocalPresence.UNAVAILABLE, unreadable.inspectExisting("account-slot"))
        }
    }

    @Test fun unconfirmedInertOrNullShadowStillVetoesAfterBackendReopens() {
        val durable = mutableMapOf<String, String?>()
        val backend = object : CredentialBackend {
            override fun string(key: String): String? = durable[key]
            override fun readExistingForRestore(keys: List<String>): Map<String, String?> =
                keys.associateWith(durable::get)
            override fun write(values: Map<String, String?>): Boolean {
                durable.putAll(values)
                return true
            }
        }
        for (fallback in listOf("{}", null)) {
            var open = false
            val state = FailClosedCredentialState(null, reopenBackend = { if (open) backend else null })
            durable.clear()
            assertFalse(state.write(mapOf("account-slot" to fallback)))
            open = true
            assertEquals(null, state.string("unrelated-slot"))
            assertEquals(AccountFileLocalPresence.PRESENT, state.inspectExisting("account-slot") { it == "{}" })
            durable["account-slot"] = fallback
            assertEquals(fallback, state.string("account-slot"))
            assertEquals(AccountFileLocalPresence.PRESENT, state.inspectExisting("account-slot") { it == "{}" })
            assertTrue(state.write(mapOf("account-slot" to fallback)))
            assertEquals(AccountFileLocalPresence.ABSENT, state.inspectExisting("account-slot") { it == "{}" })
        }
    }

    @Test fun physicalCredentialBackingRequiresExactCurrentEncryptedStringMap() = withDirectory { directory ->
        val file = File(directory, "secure.xml")
        val keyKeyset = "__androidx_security_crypto_encrypted_prefs_key_keyset__"
        val valueKeyset = "__androidx_security_crypto_encrypted_prefs_value_keyset__"
        val entries = """<string name="$keyKeyset">00</string><string name="$valueKeyset">11</string>"""
        val valid = """<?xml version="1.0" encoding="utf-8" standalone="yes"?>
            <map>$entries<string name="encoded">A&amp;B</string></map>""".trimIndent()
        assertTrue(runCatching { RestoreCredentialBacking.read(file) }.isFailure)
        file.writeText(valid)
        assertEquals(mapOf(keyKeyset to "00", valueKeyset to "11", "encoded" to "A&B"),
            RestoreCredentialBacking.read(file))
        val backup = File(directory, "secure.xml.bak").apply { writeText("synthetic incomplete commit") }
        assertTrue(runCatching { RestoreCredentialBacking.read(file) }.isFailure)
        assertEquals("synthetic incomplete commit", backup.readText())
        assertTrue(backup.delete())
        for (invalid in listOf("<map/>", "<!DOCTYPE map><map>$entries</map>", "<map>$entries$entries</map>",
                "<map>$entries<int name=\"unexpected\" value=\"0\" /></map>")) {
            file.writeText(invalid)
            assertTrue(runCatching { RestoreCredentialBacking.read(file) }.isFailure)
            assertEquals(invalid, file.readText())
        }
    }

    @Test fun ordinaryRecoveryNeverEnrollsUnknownOrTransferredExistingBackings() {
        for (shape in listOf("malformed", "rollback", "one-keyset", "healthy-legacy", "oversized")) {
            withDirectory { directory ->
                val file = File(directory, "secure.xml")
                val backup = File(directory, "secure.xml.bak")
                val receipt = receiptFile(directory)
                when (shape) {
                    "malformed" -> file.writeText("<map")
                    "rollback" -> backup.writeText(backingDocument(keysets))
                    "one-keyset" -> file.writeText(backingDocument(keysets.entries.take(1).associate { it.toPair() }))
                    "healthy-legacy" -> file.writeText(backingDocument(keysets))
                    "oversized" -> writeOversizedBacking(file)
                }
                val first = restoreGate(file, receipt)
                val noPreflight: () -> Map<String, String> = { error("Existing carrier needs no raw-cache preflight") }
                val noProof: (Map<String, String>) -> Unit = { error("Existing carrier cannot be enrolled") }
                assertEquals("normal", first.open(noPreflight, noProof) {
                    if (shape == "rollback") assertTrue(backup.delete())
                    if (shape != "oversized") file.writeText(backingDocument(keysets))
                    "normal"
                })
                assertFalse(receipt.exists())
                assertEquals(null, first.inspect(noPreflight, noProof) { it })
                val reopened = restoreGate(file, receipt)
                assertEquals("reopened", reopened.open(noPreflight, noProof) { "reopened" })
                assertTrue(reopened.write(noPreflight, { error("No proof generation readback") }) { true })
                assertEquals(null, reopened.inspect(noPreflight, noProof) { it })
            }
        }
    }

    @Test fun freshEncryptedBackingAndConfirmedGenerationKeepExactEvidenceWithoutReopenScans() = withDirectory { directory ->
        val file = File(directory, "shared_prefs/secure.xml")
        val receipt = receiptFile(directory)
        val gate = restoreGate(file, receipt)
        var raw = emptyMap<String, String>()
        var authenticated = 0
        val authenticate: (Map<String, String>) -> Unit = { authenticated++ }
        assertEquals("fresh", gate.open({ raw }, authenticate) {
            assertTrue(requireNotNull(file.parentFile).mkdir())
            raw = keysets
            file.writeText(backingDocument(raw))
            "fresh"
        })
        assertTrue(receipt.isFile)
        assertEquals(1, authenticated)
        repeat(20) {
            assertEquals("sibling", gate.open({ error("Repeated open must skip Restore XML/cache evidence") },
                { error("Repeated open must skip Restore keysets") }) { "sibling" })
        }
        assertEquals(keysets, gate.inspect({ raw }, authenticate) { it })

        var token: String? = null
        assertTrue(gate.write({ raw }, { token }) { generation ->
            token = generation
            raw = keysets + mapOf("encoded" to "stored", "source-generation" to generation)
            file.writeText(backingDocument(raw))
            true
        })
        assertEquals(raw, restoreGate(file, receipt).inspect({ raw }, authenticate) { it })
        assertEquals(3, authenticated)
    }

    @Test fun falseCommitWithUnavailableReceiptCannotQualifyAfterRestartOrEmptyMapABA() = withDirectory { directory ->
        val file = File(directory, "secure.xml")
        val receipt = receiptFile(directory)
        val gate = restoreGate(file, receipt)
        var raw = emptyMap<String, String>()
        gate.open({ raw }, {}) {
            raw = keysets
            file.writeText(backingDocument(raw))
        }
        val oldProof = receipt.readText()
        val hiddenProofDirectory = File(directory, "temporarily-inaccessible-proof")
        val receiptDirectory = requireNotNull(receipt.parentFile)
        assertTrue(receiptDirectory.renameTo(hiddenProofDirectory))
        receiptDirectory.writeText("synthetic metadata storage fault")

        var oldGeneration: String? = null
        assertTrue(gate.write({ raw }, { oldGeneration }) { generation ->
            oldGeneration = generation
            raw = keysets + mapOf("encoded" to "stored", "source-generation" to generation)
            file.writeText(backingDocument(raw))
            true
        })
        var deletedGeneration: String? = null
        assertFalse(gate.write({ raw }, { deletedGeneration }) { generation ->
            deletedGeneration = generation
            // Model the Android disk write completing despite the interrupted commit wait.
            raw = keysets + ("source-generation" to generation)
            file.writeText(backingDocument(raw))
            false
        })
        assertTrue(oldGeneration != deletedGeneration)
        assertEquals(keysets, raw - "source-generation")
        assertTrue(receiptDirectory.delete())
        assertTrue(hiddenProofDirectory.renameTo(receiptDirectory))
        assertEquals(oldProof, receipt.readText())
        assertEquals(null, restoreGate(file, receipt).inspect({ raw }, {}) { it })
    }

    @Test fun plaintextKeysetFallbackAndLargeCommitsKeepOrdinaryOutcomeWithoutRestoreProof() {
        for (fallback in listOf(false, true)) withDirectory { directory ->
            val file = File(directory, "secure.xml")
            val receipt = receiptFile(directory)
            val gate = restoreGate(file, receipt)
            var raw = emptyMap<String, String>()
            assertEquals("ordinary", gate.open({ raw }, {
                if (fallback) error("synthetic keysets cannot authenticate under existing Android key")
            }) {
                raw = keysets
                file.writeText(backingDocument(raw))
                "ordinary"
            })
            assertEquals(!fallback, receipt.exists())
            assertTrue(gate.write({ raw }, { error("Oversized commit cannot read generation") }) {
                writeOversizedBacking(file)
                true
            })
            assertTrue(file.length() > 16_777_216)
            assertEquals(null, runCatching { restoreGate(file, receipt).inspect({ raw }, {}) { it } }.getOrNull())
        }
    }

    private fun receiptFile(directory: File) = File(directory, "no_backup/restore-receipt")
    private fun restoreGate(file: File, receipt: File) =
        RestoreCredentialOpenGate(file, RestoreCredentialReceipt(receipt))

    private fun writeOversizedBacking(file: File) {
        val chunk = "A".repeat(1024)
        file.bufferedWriter().use { output ->
            output.append(backingDocument(keysets).removeSuffix("</map>"))
            output.append("<string name=\"encoded\">")
            repeat(16_384) { output.append(chunk) }
            output.append("</string></map>")
        }
    }

    private val keysets = mapOf(
        "__androidx_security_crypto_encrypted_prefs_key_keyset__" to "00",
        "__androidx_security_crypto_encrypted_prefs_value_keyset__" to "11",
    )

    private fun backingDocument(entries: Map<String, String>): String =
        entries.entries.joinToString(separator = "", prefix = "<map>", postfix = "</map>") { (name, value) ->
            """<string name="$name">$value</string>"""
        }

    @Test fun combinedWitnessesRefuseUnknownAndDoNotRecaptureAfterCancellation() = runBlocking {
        val visited = mutableListOf<AccountFileRestoreAbsence.Area>()
        var current = true
        fun observe(area: AccountFileRestoreAbsence.Area): suspend (VortxAccountScope) -> AccountFileLocalPresence = {
            assertEquals(target, it)
            visited += area
            if (area == AccountFileRestoreAbsence.Area.WATCHED_INTENTS) AccountFileLocalPresence.UNAVAILABLE
            else AccountFileLocalPresence.ABSENT
        }
        val area = AccountFileRestoreAbsence.Area.entries
        val witnesses = AccountFileRestoreAbsence.Witnesses(
            observe(area[0]), observe(area[1]), observe(area[2]), observe(area[3]), observe(area[4]), observe(area[5]),
            observe(area[6]), observe(area[7]), observe(area[8]), observe(area[9]), observe(area[10]), observe(area[11]),
        )
        assertEquals(
            AccountFileRestoreAbsence.Refusal(AccountFileRestoreAbsence.Area.WATCHED_INTENTS,
                AccountFileLocalPresence.UNAVAILABLE),
            AccountFileRestoreAbsence.firstRefusal(target, witnesses) { check(current) },
        )
        assertEquals(area.take(9), visited)
        visited.clear()
        current = false
        val cancelled = try {
            AccountFileRestoreAbsence.firstRefusal(target, witnesses) {
                if (!current) throw CancellationException("synthetic owner retired")
            }
            null
        } catch (failure: CancellationException) { failure }
        assertTrue(cancelled != null)
        assertTrue(visited.isEmpty())
    }

    private fun store(directory: File) = VortxEncryptedCheckpointStore(directory) {
        throw AssertionError("Restore absence must not call the ordinary key loader")
    }

    private inline fun withDirectory(block: (File) -> Unit) {
        val directory = Files.createTempDirectory("restore-absence-fixture").toFile()
        try { block(directory) } finally { assertTrue(directory.deleteRecursively()) }
    }

    private fun accountDigest(scope: VortxAccountScope) = MessageDigest.getInstance("SHA-256")
        .digest(scope.accountID.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    private fun locatorDomain(scope: VortxAccountScope) =
        VortxAccountScope(accountDigest(scope), "native-account-locator-v1")
    private fun preflightDomain(scope: VortxAccountScope) =
        VortxAccountScope(accountDigest(scope), "native-migration-preflight-v1")

    private val appAliases = setOf("unrelated-app-key")

    private fun alias(scope: VortxAccountScope) = "vortx.native.state.v1.${scope.digest}"

    private fun stateFile(scope: VortxAccountScope) = "native-state-v1-${scope.digest}.sealed"
    private fun locatorFile(scope: VortxAccountScope) = "native-account-v1-${accountDigest(scope)}.sealed"
    private fun preflightFile(scope: VortxAccountScope) = "native-preflight-v1-${accountDigest(scope)}.sealed"

    private fun descriptor(scope: VortxAccountScope) =
        """{"schemaVersion":1,"accountID":"${scope.accountID}","ownerProfileID":"${scope.ownerProfileID}"}"""

    private fun seal(scope: VortxAccountScope, plaintext: String, key: SecretKey): ByteArray {
        val nonce = ByteArray(12) { 3 }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, nonce))
        cipher.updateAAD(scope.authenticatedData)
        return nonce + cipher.doFinal(plaintext.toByteArray(Charsets.UTF_8))
    }
}
