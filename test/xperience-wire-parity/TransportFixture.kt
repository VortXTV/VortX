package com.vortx.android.xperience

import com.vortx.android.engine.OHJson
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardOpenOption

/** Observes the pinned public synthetic corpus; expected admission/bytes/relations stay outside this collector. */
internal object TransportFixture {
    private const val CORPUS_SHA256 = "de132e69bd605de930fdbc552534b31216232463e4900de93e4646ec74c1e296"
    private const val MANIFEST_ID = "fixture.xperience.synthetic"
    private data class Case(val id: String, val input: String, val inputHash: String)

    private fun isSHA256(value: String): Boolean =
        value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }

    fun collect(corpusPath: String, outputPath: String) {
        val bytes = Files.newInputStream(Path.of(corpusPath)).use { it.readNBytes(128 * 1024 + 1) }
        require(bytes.isNotEmpty() && bytes.size <= 128 * 1024 && OHJson.sha(bytes) == CORPUS_SHA256) {
            "Invalid transport corpus"
        }
        val corpus = OHJson.Obj(bytes)
        val descriptor = corpus.obj("fixtureDescriptor")
        val catalog = descriptor.obj("catalog")
        require(OHJson.integer(corpus.raw("schema")) == 1L && descriptor.text("manifestID") == MANIFEST_ID &&
            catalog.text("type") == "movie" && catalog.text("id") == "fixture-popular" &&
            catalog.raw("acceptsGenre").contentEquals(OHJson.literal("true")) &&
            catalog.raw("requiresGenre").contentEquals(OHJson.literal("false")) &&
            catalog.raw("supportsSkip").contentEquals(OHJson.literal("true"))) { "Invalid transport corpus" }
        val rawCases = OHJson.array(corpus.raw("cases"))
        require(rawCases.size == 52 && rawCases.size <= 64) { "Invalid transport corpus" }
        val seen = hashSetOf<String>()
        val cases = rawCases.map { raw ->
            val item = OHJson.Obj(raw)
            val id = item.text("id")
            val input = item.text("input")
            val inputBytes = input.toByteArray(Charsets.UTF_8)
            val inputHash = item.text("inputUTF8SHA256")
            require(id.isNotEmpty() && id.length <= 128 &&
                id.all { it in 'a'..'z' || it in '0'..'9' || it == '-' } && seen.add(id) &&
                inputBytes.isNotEmpty() && inputBytes.size <= 4096 &&
                isSHA256(inputHash) && OHJson.sha(inputBytes) == inputHash) { "Invalid transport corpus" }
            Case(id, input, inputHash)
        }

        val output = Files.createDirectory(Path.of(outputPath))
        FileChannel.open(output.resolve("results.tsv"), StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE).use { results ->
            var metadataBytes = 0
            for (item in cases) {
                // Only a validated fixed-corpus ASCII ID is emitted; never emit the configured transport.
                System.err.println("transport-case-start\t${item.id}")
                val candidate = try {
                    XperienceAddonBinding.Candidate.fromInstalled(XperienceAddonBinding.InstalledDescriptor(
                        manifestID = MANIFEST_ID, transportURL = item.input,
                        catalogs = listOf(XperienceAddonBinding.Catalog(
                            type = "movie", id = "fixture-popular", acceptsGenre = true,
                            requiresGenre = false, supportsSkip = true))))
                } catch (failure: IllegalArgumentException) {
                    if (failure.javaClass != IllegalArgumentException::class.java ||
                        failure.message != "Invalid installed registry" || failure.cause != null) {
                        throw IllegalStateException("Unexpected Candidate failure")
                    }
                    null
                } catch (_: Exception) {
                    throw IllegalStateException("Unexpected Candidate failure")
                }
                val fields = if (candidate != null) {
                    val canonical = candidate.canonicalTransport.toByteArray(Charsets.UTF_8)
                    check(canonical.isNotEmpty() && canonical.size <= 16 * 1024 &&
                        isSHA256(candidate.transportFingerprint)) { "Invalid transport observation" }
                    Files.write(output.resolve("${item.id}.canonical"), canonical, StandardOpenOption.CREATE_NEW)
                    listOf(item.id, "ACCEPTED", canonical.size.toString(), OHJson.sha(canonical),
                        candidate.transportFingerprint, item.inputHash)
                } else {
                    listOf(item.id, "INVALID_REGISTRY", "0", "-", "-", item.inputHash)
                }
                val row = (fields.joinToString("\t") + "\n").toByteArray(Charsets.UTF_8)
                metadataBytes += row.size
                check(metadataBytes <= 32 * 1024) { "Invalid transport observation" }
                val buffer = java.nio.ByteBuffer.wrap(row)
                while (buffer.hasRemaining()) results.write(buffer)
                results.force(true)
            }
        }
    }
}
