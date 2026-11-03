package com.vortx.android.sync

import com.vortx.android.backup.AccountFilePlist
import com.vortx.android.engine.NativeOwnerHistoryAccount
import com.vortx.android.engine.NativeProfileOverlayWitness
import com.vortx.android.engine.OHJson
import com.vortx.android.engine.VortxAccountScope
import com.vortx.android.engine.nativeMigrationSidecars
import com.vortx.android.engine.prepareNativeLegacyMaterial
import com.vortx.android.profile.PlaybackPrefs
import com.vortx.android.profile.UserProfile
import java.math.BigDecimal
import java.math.BigInteger
import java.util.Base64
import java.util.UUID

/** Pure interpretation, NOT authenticated account/owner authority. The future manager must supply
 * the independent real GET owner under its original session/key. No live stores or crypto here.
 * Known Apple/Android fields are checked before any tolerant DTO is used. Raw unknown values remain
 * in the original account/roster; JSONObject is used only by the existing material projector. */
internal object AccountFileLegacyAdmission {
    const val MAX_PLAINTEXT_BYTES = 5 * 1024 * 1024
    private val unsupported = setOf("nativeSync", "nativeHostPreferences", "nativeProviderCredentials",
        "nativeOwnerHistorySources", "profileEditResults", "ownAccountSources", "ownAccountOverlayPending",
        "ownAccountOverlayQuarantine", "nativeLegacyMembershipPending", "nativeWatchedMigrationEvidence",
        "nativeWatchedMigrationPending", "nativeWatchedMigrationSources", "hostDocument", "legacyImportMaterial",
        "authenticatedSourceArchive", "excludedCredentialPaths", "ownAccountSourceHistory",
        "hostProfilePreferences", "hostProfileSyncPending", "nativeHostPreferenceState",
        "websiteProfileEditPending", "websiteProfileEditCertificates", "websiteAddonEditPending",
        "legacyWebsiteBootstrap") + nativeMigrationSidecars
    private val queued = setOf("profileEdits", "profileEditEvents", "webAddonEdits")

    class Admitted internal constructor(source: ByteArray, roster: List<ByteArray>, known: List<ByteArray>,
        val modifiedSeconds: Double?, val ownerProfileID: String) {
        private val source = source.copyOf()
        private val roster = roster.map { it.copyOf() }
        private val known = known.map { it.copyOf() }
        val profileCount: Int get() = roster.size
        val ownerName: String get() = known.map { AccountFileLegacyAdmission.materialProfile(it) }.single { it.isOwner }.name
        fun originalPlaintext(): ByteArray = source.copyOf()
        fun originalRoster(): ByteArray = OHJson.array(roster)

        /** Only the fields consumed by LegacyMaterialAdapter become UserProfile inputs. The full
         * typed known record (including 64-bit Apple preferences) and raw bytes remain separate;
         * this projection is not a profile restore or a serializer for the original account.
         * File-only profile projection below supplies the compatible ranking and disabled-list
         * inheritance from these exact records. This still is not full candidate/host admission
         * or permission to export/restore an account file. */
        fun prepareMaterial(scope: VortxAccountScope): ByteArray {
            require(scope.ownerProfileID == ownerProfileID) { "Account file owner mismatch" }
            val profiles = known.map { AccountFileLegacyAdmission.materialProfile(it) }
            require(profiles.none { it.usesOwnAccount }) { "Independent account file source unsupported" }
            val raw = OHJson.Obj(source)
            require(raw.keys.intersect(AccountFileLegacyAdmission.queued).isEmpty()) { "Queued account file edits require reconciliation" }
            val document = NativeProfileOverlayWitness.parseAccountDocument(source)
            val prepared = prepareNativeLegacyMaterial(document, profiles, modifiedSeconds, accountScope = scope)
            require(prepared.held.isEmpty()) { "Account file contains held source units" }
            require(prepared.pendingMembershipReceipts.length() == 0) { "Account file contains pending source evidence" }
            // This is newly produced typed material, never a reserialization of the source account.
            val material = prepared.material.toString().toByteArray(Charsets.UTF_8)
            return AccountFileProfileMaterial.project(material, known, ownerProfileID)
        }

        /** Add exactly one genuinely cold-produced native carrier; every original VALUE slice
         * survives verbatim. This is byte conservation, not native or restore authorization. */
        fun addingNativeSync(native: ByteArray): ByteArray {
            OHJson.Obj(native)
            val original = OHJson.Obj(source)
            require(original["nativeSync"] == null)
            val next = NativeOwnerHistoryAccount(source).replacingOwned(mapOf("nativeSync" to native)).validateBudget(true)
            val candidate = OHJson.Obj(next)
            require(candidate.keys == original.keys + "nativeSync" &&
                original.keys.all { candidate.raw(it).contentEquals(original.raw(it)) }) { "Account file preservation failed" }
            return next
        }
    }

    /** Works for a full authenticated legacy head as well as a file. Its return value alone is
     * never an owner capability. Summary-only, malformed-present and conflicting carriers refuse. */
    fun legacyOwnerID(plaintext: ByteArray): String = resolve(plaintext, null).ownerProfileID
    fun admitLegacy(plaintext: ByteArray, expectedOwnerProfileID: String): Admitted = resolve(plaintext, expectedOwnerProfileID)

    private data class Roster(val raw: List<ByteArray>, val known: List<ByteArray>, val clock: Double?)
    private fun legacyKeys(keys: Set<String>) {
        require(keys.intersect(unsupported).isEmpty()) { "Existing native or recovery carrier requires dedicated validation" }
    }
    private fun resolve(plaintext: ByteArray, expectedOwner: String?): Admitted {
        require(plaintext.size <= MAX_PLAINTEXT_BYTES) { "Account plaintext exceeds limit" }
        val source = OHJson.Obj(plaintext); legacyKeys(source.keys)
        NativeProfileOverlayWitness.parseAccountDocument(plaintext) // Exact raw overlay validation before projection.
        var settings: Roster? = null
        source["settings"]?.let { encoded ->
            val envelope = OHJson.Obj(base64(OHJson.text(encoded)))
            require(envelope.text("format") == "vortx-backup" && OHJson.integer(envelope.raw("schema")) == 1L)
            val domain = AccountFilePlist.decode(base64(envelope.text("payloadBase64")))
            legacyKeys(domain.keys)
            val clock = domain["stremiox.profiles.modified"]?.let { value ->
                when (value) {
                    is BigInteger -> clock(OHJson.literal(value.toString()))
                    is Double -> { require(value.isFinite()); clock(OHJson.literal(value.toString())) }
                    else -> error("Malformed account roster clock")
                }
            }
            if (domain.containsKey("stremiox.profiles")) {
                val bytes = domain["stremiox.profiles"] as? ByteArray ?: error("Malformed account roster carrier")
                settings = roster(bytes, clock)
            } else require(clock == null) { "Account roster clock has no roster" }
        }
        var full: Roster? = null
        source["vortx"]?.let { bytes ->
            val vortx = OHJson.Obj(bytes); legacyKeys(vortx.keys)
            val clock = vortx["rosterModified"]?.let(::clock)
            if (vortx["roster"] != null) full = roster(vortx.raw("roster"), clock)
            else require(clock == null) { "Account roster clock has no roster" }
            // vortx.profiles is a lossy dashboard summary, never full roster authority.
        }
        if (settings != null && full != null) {
            val a = requireNotNull(settings); val b = requireNotNull(full)
            require(a.clock == b.clock && a.known.size == b.known.size &&
                a.known.zip(b.known).all { (left, right) -> left.contentEquals(right) }) { "Conflicting account roster carriers" }
        }
        val accepted = full ?: settings ?: error("Full account roster unavailable")
        val owners = accepted.known.map { OHJson.Obj(it) }.filter { it.textBoolean("isOwner") }
        require(owners.size == 1) { "Account roster owner is ambiguous" }
        val owner = owners.single().text("id")
        require(expectedOwner == null || expectedOwner == owner) { "Account file owner mismatch" }
        return Admitted(plaintext, accepted.raw, accepted.known, accepted.clock, owner)
    }
    private fun roster(bytes: ByteArray, clock: Double?): Roster {
        require(bytes.size <= MAX_PLAINTEXT_BYTES)
        val rows = OHJson.array(bytes); require(rows.isNotEmpty()) { "Empty account roster" }
        val ids = hashSetOf<String>()
        val known = rows.map { row ->
            val record = validateRecord(OHJson.Obj(row), profile)
            val id = record.text("id")
            require(UUID.fromString(id).toString().uppercase(java.util.Locale.ROOT) == id && ids.add(id)) { "Invalid account roster identity" }
            require(record.text("name").isNotBlank() && record.text("avatar").isNotEmpty() && record.text("accentID").isNotEmpty())
            val scale = OHJson.utf8(record.raw("textScale")).toDouble()
            require(scale > 0 && scale <= 100)
            record["pin"]?.let { require(OHJson.text(it).let { pin -> pin.isEmpty() || Regex("sha256:[0-9a-fA-F]{64}").matches(pin) }) }
            record.encoded()
        }
        return Roster(rows, known, clock)
    }

    private enum class Kind { STRING, BOOL, DOUBLE, INT64, STRINGS, INTS64, DATA, PLAYBACK, DISCOVERY, ADDONS, RANKING }
    private data class Contract(val required: Map<String, Kind>, val optional: Map<String, Kind>)
    private fun fields(kind: Kind, vararg names: String) = names.associateWith { kind }
    private val playback = Contract(fields(Kind.STRING, "audioLang", "subtitleLang", "forcedPolicy", "subFont", "subSize", "subColor", "subBackground"),
        fields(Kind.STRING, "subBrightness", "safetyMode", "excludeKeywords", "includeKeywords", "preferKeywords", "avoidBehavior") +
        fields(Kind.BOOL, "useAddonOrder", "instantOnly", "hideDeadTorrents", "hdrOnly", "excludeAV1", "keywordsAreRegex", "hideUnknownResolution", "preferredAudioOnly", "autoPickBest") +
        fields(Kind.DOUBLE, "subSizeScale", "maxFileSizeGB") + fields(Kind.INT64, "maxResolution", "minResolution", "titleMatchThreshold") +
        fields(Kind.STRINGS, "sourceTypeOrder"))
    private val discovery = Contract(emptyMap(), fields(Kind.STRINGS, "hiddenCatalogs", "catalogOrder", "hiddenHubCategories") +
        fields(Kind.STRING, "regionOverride", "continueWatchingSource", "continueWatchingWindow") + fields(Kind.DATA, "filtersData") +
        fields(Kind.INTS64, "selectedProviders", "providerOrder") + fields(Kind.BOOL, "regionOverrideCaptured", "filtersCaptured", "tabVisibilityCaptured",
            "hideLiveTab", "hideDiscoverTab", "hideLibraryTab", "hideSearchTab", "showCollectionsHome", "showCollectionsDiscover"))
    private val ranking = Contract(fields(Kind.STRINGS, "sourceTypeOrder") + fields(Kind.BOOL, "useAddonOrder"), fields(Kind.STRINGS, "addonOrder"))
    private val addons = Contract(emptyMap(), fields(Kind.STRINGS, "disabledAddonURLsOverride") + fields(Kind.RANKING, "rankingOverride"))
    private val profile = Contract(fields(Kind.STRING, "id", "name", "avatar", "accentID") + fields(Kind.DOUBLE, "textScale") +
        fields(Kind.BOOL, "oled", "usesOwnAccount", "isOwner", "familyEdit", "isKids"), fields(Kind.STRING, "pin", "email") +
        fields(Kind.PLAYBACK, "playback") + fields(Kind.DISCOVERY, "discovery") + fields(Kind.STRINGS, "disabledAddons") + fields(Kind.ADDONS, "addonPreferences"))
    private fun validateRecord(raw: OHJson.Obj, contract: Contract): OHJson.Obj {
        require(raw.keys.containsAll(contract.required.keys)) { "Required account profile field missing" }
        val result = OHJson.Obj()
        for ((key, kind) in contract.required + contract.optional) {
            val value = raw[key] ?: continue
            if (value.contentEquals(OHJson.literal("null"))) {
                require(key in contract.optional) { "Required account profile field is null" }; continue
            }
            result.setValidated(key, typed(value, kind))
        }
        return result // Unknown fields stay only in the unchanged raw source; they confer no authority.
    }
    private fun typed(value: ByteArray, kind: Kind): ByteArray = when (kind) {
        Kind.STRING -> OHJson.quote(OHJson.text(value))
        Kind.BOOL -> { require(OHJson.utf8(value) in setOf("true", "false")); value.copyOf() }
        Kind.DOUBLE -> OHJson.literal(decimalDouble(value).toBigDecimal().stripTrailingZeros().toString())
        Kind.INT64 -> OHJson.literal(decimal(value).longValueExact().toString())
        Kind.STRINGS -> OHJson.array(OHJson.array(value).map { typed(it, Kind.STRING) })
        Kind.INTS64 -> OHJson.array(OHJson.array(value).map { typed(it, Kind.INT64) })
        Kind.DATA -> OHJson.quote(Base64.getEncoder().encodeToString(base64(OHJson.text(value))))
        Kind.PLAYBACK, Kind.DISCOVERY, Kind.ADDONS, Kind.RANKING -> validateRecord(OHJson.Obj(value), when (kind) {
            Kind.PLAYBACK -> playback; Kind.DISCOVERY -> discovery; Kind.ADDONS -> addons; else -> ranking
        }).encoded()
    }
    private fun decimal(bytes: ByteArray): BigDecimal {
        require(bytes.size in 1..128)
        val text = OHJson.utf8(bytes)
        require(Regex("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?").matches(text))
        return BigDecimal(text).also { require(it.scale() in -10_000..10_000) }
    }
    private fun decimalDouble(bytes: ByteArray): Double {
        val original = decimal(bytes); val projected = original.toDouble()
        require(projected.isFinite() && original.compareTo(BigDecimal(projected.toString())) == 0) { "Known account number cannot round-trip" }
        return projected
    }
    private fun clock(bytes: ByteArray): Double = decimalDouble(bytes).let {
        require(it >= 0) { "Invalid account roster clock" }; if (it == 0.0) 0.0 else it
    }
    private fun base64(value: String): ByteArray {
        require(value.length <= (MAX_PLAINTEXT_BYTES.toLong() + 2) / 3 * 4)
        val bytes = Base64.getDecoder().decode(value)
        require(bytes.size <= MAX_PLAINTEXT_BYTES && Base64.getEncoder().encodeToString(bytes) == value) { "Malformed account base64" }
        return bytes
    }
    private fun OHJson.Obj.textBoolean(key: String): Boolean = when (OHJson.utf8(raw(key))) {
        "true" -> true; "false" -> false; else -> error("Malformed account profile boolean")
    }
    private fun materialProfile(known: ByteArray): UserProfile {
        val profile = OHJson.Obj(known)
        val playback = profile["playback"]?.let { raw -> OHJson.Obj(raw).let {
            PlaybackPrefs(audioLang = it.text("audioLang"), subtitleLang = it.text("subtitleLang"), forcedPolicy = it.text("forcedPolicy"),
                subFont = it.text("subFont"), subSize = it.text("subSize"), subColor = it.text("subColor"), subBackground = it.text("subBackground"))
        } }
        return UserProfile(id = profile.text("id"), name = profile.text("name"), avatar = profile.text("avatar"),
            accentID = profile.text("accentID"), oled = profile.textBoolean("oled"), textScale = OHJson.utf8(profile.raw("textScale")).toDouble(),
            pin = profile["pin"]?.let(OHJson::text), usesOwnAccount = profile.textBoolean("usesOwnAccount"), email = profile["email"]?.let(OHJson::text),
            isOwner = profile.textBoolean("isOwner"), familyEdit = profile.textBoolean("familyEdit"), playback = playback, discovery = null,
            disabledAddons = profile["disabledAddons"]?.let { OHJson.array(it).map(OHJson::text) }, isKids = profile.textBoolean("isKids"))
    }
}
