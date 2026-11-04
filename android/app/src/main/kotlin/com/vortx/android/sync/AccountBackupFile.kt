package com.vortx.android.sync

import com.vortx.android.engine.OHJson
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.charset.CharacterCodingException

/** Website-compatible full encrypted account file. It grants no restore, repair or sync authority. */
internal object AccountBackupFile {
    const val MAXIMUM_RESPONSE_BYTES = 8 * 1024 * 1024
    const val MAXIMUM_FILE_BYTES = 10 * 1024 * 1024
    private const val MAXIMUM_INTEGER = 9_007_199_254_740_991L

    enum class Reason { TOO_LARGE, WRONG_FORMAT, UNSUPPORTED_FORMAT, DAMAGED, NO_BACKUP, SESSION_CHANGED, UNAVAILABLE }
    class Failure(val reason: Reason) : Exception(when (reason) {
        Reason.TOO_LARGE -> "This backup exceeds the account file limit."
        Reason.WRONG_FORMAT -> "Choose a VortX account backup."
        Reason.UNSUPPORTED_FORMAT -> "This backup uses an unsupported format."
        Reason.DAMAGED -> "This backup could not be read safely."
        Reason.NO_BACKUP -> "This account does not have a cloud backup to download yet."
        Reason.SESSION_CHANGED -> "Your account changed. Open Tools again before continuing."
        Reason.UNAVAILABLE -> "The backup could not be downloaded. Try again when your connection and sign-in are working."
    })

    /** Exact input bytes, including future metadata and numeric spelling, remain recoverable. */
    class Inspection internal constructor(source: ByteArray, val document: String, val version: Long) {
        private val original = source.copyOf()
        fun originalBytes(): ByteArray = original.copyOf()
        override fun toString() = "AccountBackupFile.Inspection"
    }

    private fun fail(reason: Reason): Nothing = throw Failure(reason)
    private inline fun <T> damaged(action: () -> T): T = try { action() }
        catch (failure: Failure) { throw failure }
        catch (_: CharacterCodingException) { fail(Reason.DAMAGED) }
        catch (_: IllegalArgumentException) { fail(Reason.DAMAGED) }
        catch (_: IllegalStateException) { fail(Reason.DAMAGED) }

    private fun revision(bytes: ByteArray): Long = damaged {
        OHJson.integer(bytes).also { if (it !in 0..MAXIMUM_INTEGER) fail(Reason.DAMAGED) }
    }
    private fun checkedDocument(raw: ByteArray): String = damaged {
        val document = OHJson.text(raw)
        val versionBound = document.startsWith("v2.")
        if (!versionBound && Regex("^v[0-9]+\\.").containsMatchIn(document)) fail(Reason.UNSUPPORTED_FORMAT)
        val sealed = OHJson.un64(if (versionBound) document.drop(3) else document)
        if (sealed.size < 28) fail(Reason.DAMAGED) // nonce + tag; never opens or exports plaintext/key.
        document
    }

    fun inspect(source: ByteArray): Inspection {
        if (source.size > MAXIMUM_FILE_BYTES) fail(Reason.TOO_LARGE)
        val root = damaged { OHJson.Obj(source) }
        if (root["vortxBackup"] == null) fail(Reason.WRONG_FORMAT)
        if (!root.raw("vortxBackup").contentEquals(OHJson.literal("1"))) fail(Reason.UNSUPPORTED_FORMAT)
        val document = checkedDocument(root["document"] ?: fail(Reason.WRONG_FORMAT))
        val version = revision(root["version"] ?: fail(Reason.WRONG_FORMAT))
        // Older files may omit display metadata; present known fields must keep their actual types.
        root["username"]?.let { damaged { OHJson.text(it) } }
        root["exportedAt"]?.let(::revision)
        return Inspection(source, document, version)
    }

    /** Parse the original HTTP bytes before org.json can collapse duplicates or round revisions. */
    fun encodeServerResponse(source: ByteArray, username: String, exportedAtMillis: Long = System.currentTimeMillis()): ByteArray {
        if (source.size > MAXIMUM_RESPONSE_BYTES) fail(Reason.TOO_LARGE)
        if (exportedAtMillis !in 0..MAXIMUM_INTEGER) fail(Reason.DAMAGED)
        val body = damaged { OHJson.Obj(source) }
        val document = body["document"] ?: fail(Reason.DAMAGED)
        checkedDocument(document)
        val version = body["version"] ?: fail(Reason.DAMAGED)
        revision(version)
        val file = damaged { OHJson.Obj()
            .setValidated("vortxBackup", OHJson.literal("1"))
            .setValidated("username", OHJson.quote(username))
            .setValidated("exportedAt", OHJson.literal(exportedAtMillis.toString()))
            .setValidated("document", document)
            .setValidated("version", version).encoded() }
        inspect(file)
        return file
    }

    /** Download-mode only; stop at limit+1 even when Content-Length is absent or dishonest. */
    fun readBoundedResponse(input: InputStream): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val count = input.read(buffer, 0, minOf(buffer.size, MAXIMUM_RESPONSE_BYTES + 1 - output.size()))
            if (count < 0) return output.toByteArray()
            if (count == 0) continue
            output.write(buffer, 0, count)
            if (output.size() > MAXIMUM_RESPONSE_BYTES) fail(Reason.TOO_LARGE)
        }
    }
}
