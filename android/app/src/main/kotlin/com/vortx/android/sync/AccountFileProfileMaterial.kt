package com.vortx.android.sync

import com.vortx.android.engine.OHJson
import java.text.Normalizer
import java.util.Locale

/** File-only profile preference projection. The caller supplies records already checked by strict
 * AccountFileLegacyAdmission, never tolerant UI DTOs/defaults. Changes only generated material's
 * profile settings; the selected account and every original raw value remain with the caller.
 * Source contract: Apple VortxLegacyBootstrapMaterial.projectProfile/normalizeURL/unique/terms.
 * A preference Apple holds becomes a whole-file refusal here, never silent repair by omission. */
internal object AccountFileProfileMaterial {
    private val rankingKeys = setOf("preferred_languages", "max_resolution", "max_filesize_gb", "keyword_include", "keyword_exclude")

    fun project(material: ByteArray, knownRoster: List<ByteArray>, ownerProfileID: String): ByteArray {
        require(material.size <= AccountFileLegacyAdmission.MAX_PLAINTEXT_BYTES &&
            knownRoster.sumOf { it.size.toLong() } <= AccountFileLegacyAdmission.MAX_PLAINTEXT_BYTES) { "Account material exceeds limit" }
        val root = OHJson.Obj(material)
        require(OHJson.integer(root.raw("schemaVersion")) == 1L && root["ownAccountSources"] == null) { "Shared legacy material required" }
        val records = knownRoster.map { OHJson.Obj(it) }
        require(records.isNotEmpty() && records.none { it.bool("usesOwnAccount") }) { "Independent file profile unsupported" }
        val ids = records.map { it.text("id") }
        require(ids.size == ids.toSet().size)
        val owner = records.single { it.bool("isOwner") }
        require(owner.text("id") == ownerProfileID)
        val materialRows = OHJson.array(root.raw("roster"))
        require(materialRows.map { OHJson.Obj(it).text("id") } == ids) { "Material roster changed" }
        val inherited = owner.optionalObject("addonPreferences")?.strings("disabledAddonURLsOverride")
            ?: owner.strings("disabledAddons") ?: emptyList()
        val next = materialRows.zip(records).map { (bytes, record) ->
            val row = OHJson.Obj(bytes)
            require(row.text("name") == record.text("name") && row.bool("owner") == record.bool("isOwner") &&
                row.text("addons") == "share_primary") { "Material profile identity changed" }
            val account = row.obj("account")
            require(if (record.bool("isOwner")) account.text("kind") == "local_only"
                else account.text("kind") == "shared" && account.text("value") == ownerProfileID)
            require(row.obj("parental").bool("kids") == record.bool("isKids") &&
                row.obj("parental").bool("familyEdit") == record.bool("familyEdit")) { "Material parental policy changed" }
            require(row.optionalText("pin") == record.optionalText("pin")?.takeIf { it.isNotEmpty() }) { "Material PIN changed" }
            val settings = row.obj("settings")
            val addon = record.optionalObject("addonPreferences")
            val disabled = addon?.strings("disabledAddonURLsOverride")
                ?: (if (addon == null) record.strings("disabledAddons") else null)
                ?: (if (record.bool("isOwner")) record.strings("disabledAddons") ?: emptyList() else inherited)
            settings.set("disabledAddons", strings(unique(disabled.map(::normalizeURL))))
            val playback = record.optionalObject("playback")
            settings.set("languages", strings(unique(listOfNotNull(playback?.optionalText("audioLang"),
                playback?.optionalText("subtitleLang")).filter { it.isNotEmpty() })))
            // Retain unrelated generated material fields, including future ranking siblings.
            val ranking = settings.optionalObject("ranking") ?: OHJson.Obj()
            rankingKeys.forEach(ranking::remove)
            if (playback != null) {
                ranking.set("preferred_languages", strings(unique(terms(playback.optionalText("audioLang"))).sortedWith(Comparator { left, right -> compareScalars(left, right) })))
                playback.optionalLong("maxResolution")?.takeIf { it != 0L }?.let { resolution ->
                    val value = when (resolution) { 480L -> "480p"; 720L -> "720p"; 1080L -> "1080p"; 2160L, 4000L -> "2160p"
                        else -> error("Account profile resolution requires reconciliation") }
                    ranking.set("max_resolution", OHJson.quote(value))
                }
                playback.optional("maxFileSizeGB")?.let { raw ->
                    val number = OHJson.utf8(raw).toDouble()
                    require(number.isFinite() && number >= 0) { "Account profile file-size cap requires reconciliation" }
                    if (number > 0) ranking.set("max_filesize_gb", raw)
                }
                if (playback.optionalBool("keywordsAreRegex") != true) {
                    ranking.set("keyword_include", strings(terms(playback.optionalText("includeKeywords"))))
                    if (playback.optionalText("avoidBehavior") != "rank")
                        ranking.set("keyword_exclude", strings(terms(playback.optionalText("excludeKeywords"))))
                }
                // Source transport order, UI filter overrides and subtitle language do not
                // become native quality classes or preferred audio languages.
            }
            if (ranking.keys.isEmpty()) settings.remove("ranking") else settings.set("ranking", ranking.encoded())
            row.set("settings", settings.encoded()).encoded()
        }
        return root.set("roster", OHJson.array(next)).encoded().also {
            require(it.size <= AccountFileLegacyAdmission.MAX_PLAINTEXT_BYTES) { "Account material exceeds limit" }
        }
    }

    private fun OHJson.Obj.optional(key: String) = get(key)?.takeUnless { it.contentEquals(OHJson.literal("null")) }
    private fun OHJson.Obj.optionalText(key: String) = optional(key)?.let(OHJson::text)
    private fun OHJson.Obj.optionalObject(key: String) = optional(key)?.let { OHJson.Obj(it) }
    private fun OHJson.Obj.strings(key: String) = optional(key)?.let { OHJson.array(it).map(OHJson::text) }
    private fun OHJson.Obj.optionalBool(key: String) = optional(key)?.let { boolean(it) }
    private fun OHJson.Obj.bool(key: String) = boolean(raw(key))
    private fun boolean(raw: ByteArray): Boolean = when (OHJson.utf8(raw)) {
        "true" -> true; "false" -> false; else -> error("Malformed account profile boolean")
    }
    private fun OHJson.Obj.optionalLong(key: String): Long? = optional(key)?.let {
        val value = OHJson.utf8(it); require(Regex("-?(0|[1-9][0-9]*)").matches(value)); value.toLong()
    }
    private fun strings(values: List<String>) = OHJson.array(values.map(OHJson::quote))
    private fun nfc(value: String) = Normalizer.normalize(value, Normalizer.Form.NFC)
    /** Swift String equality treats canonical Unicode spellings as equal; retain first spelling. */
    private fun unique(values: List<String>): List<String> {
        val seen = hashSetOf<String>(); return values.filter { seen.add(nfc(it)) }
    }
    private fun whitespace(char: Char) = char == '\t' || Character.getType(char) == Character.SPACE_SEPARATOR.toInt()
    private fun terms(value: String?): List<String> = value.orEmpty().split(',')
        .map { it.trim(::whitespace).lowercase(Locale.ROOT) }.filter { it.isNotEmpty() }
    private fun compareScalars(left: String, right: String): Int {
        val a = nfc(left).codePoints().toArray(); val b = nfc(right).codePoints().toArray()
        for (index in 0 until minOf(a.size, b.size)) if (a[index] != b[index]) return a[index].compareTo(b[index])
        return a.size.compareTo(b.size)
    }
    private fun normalizeURL(raw: String): String = AccountFileAddonURL.normalize(raw)
}
