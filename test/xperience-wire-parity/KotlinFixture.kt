package com.vortx.android.xperience

import com.vortx.android.engine.OHJson
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardOpenOption

fun main(args: Array<String>) {
    require(args.size == 2)
    val corpus = Files.readAllBytes(Path.of(args[0]))
    require(corpus.size <= 128 * 1024)
    val lines = OHJson.utf8(corpus).split('\n').filter { it.isNotEmpty() && !it.startsWith('#') }
    require(lines.size in 1..64)
    val output = Files.createDirectory(Path.of(args[1]))
    val seen = hashSetOf<String>()
    val results = lines.map { line ->
        val fields = line.split('\t', limit = 3)
        require(fields.size == 3)
        val id = fields[0]
        require(id.isNotEmpty() && id.all { it in 'a'..'z' || it in '0'..'9' || it == '-' } && seen.add(id))
        val input = fields[2].toByteArray(Charsets.UTF_8)
        require(input.isNotEmpty() && input.size <= 4096)
        val inputHash = OHJson.sha(input)
        try {
            val document = XperienceCollections.parse(input)
            val canonical = XperienceCollections.canonicalData(document.raw())
            val registerCanonical = try {
                XperienceCollections.canonicalRegisterData(document.raw())
            } catch (failure: XperienceCollections.Rejected) {
                throw AssertionError("Register canonicalization rejected an accepted document: $id", failure)
            }
            check(registerCanonical.contentEquals(canonical)) {
                "Register canonical bytes differ for an accepted document: $id"
            }
            val hash = OHJson.sha(canonical)
            Files.write(output.resolve("$id.canonical"), canonical, StandardOpenOption.CREATE_NEW)
            listOf(id, "ACCEPTED", canonical.size.toString(), hash, document.fingerprint, inputHash).joinToString("\t")
        } catch (failure: XperienceCollections.Rejected) {
            listOf(id, failure.reason.name, "0", "-", "-", inputHash).joinToString("\t")
        }
    }
    Files.write(output.resolve("results.tsv"), (results.joinToString("\n") + "\n").toByteArray(Charsets.UTF_8), StandardOpenOption.CREATE_NEW)
}
