package com.vortx.android.integrations

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderCredentialRaceSourceContractTest {

    @Test
    fun providerFlowsCarryOneCapturedGenerationThroughEveryPublication() {
        val trakt = readSource("TraktAuth.kt")
        val simkl = readSource("SIMKLAuth.kt")

        assertTrue(
            providerRaceViolations(trakt, simkl).joinToString(separator = "\n"),
            providerRaceViolations(trakt, simkl).isEmpty(),
        )
    }

    @Test
    fun generationAndPublicationBypassMutationsTurnTheContractRed() {
        val trakt = readSource("TraktAuth.kt")
        val simkl = readSource("SIMKLAuth.kt")
        val mutations = listOf(
            trakt.replaceFirst(
                "val operation = tokenMutations.operation()",
                "val operation = CredentialMutationCoordinator().operation()",
            ) to simkl,
            trakt.replace(
                "tokenMutations.snapshot(::currentStoredToken)",
                "CredentialMutationCoordinator().snapshot(::currentStoredToken)",
            ) to simkl,
            trakt.replace(
                "refresh(snapshot.operation)",
                "refresh(tokenMutations.operation())",
            ) to simkl,
            trakt.replace(
                "performRefresh(operation, current)",
                "performRefresh(tokenMutations.operation(), current)",
            ) to simkl,
            trakt.replace("operation.publishAfter(", "operation.awaitWithoutFence(") to simkl,
            trakt.replace("tokenMutations.invalidate", "tokenMutations.mutateWithoutInvalidation") to simkl,
            trakt to simkl.replaceFirst(
                "val operation = tokenMutations.operation()",
                "val operation = CredentialMutationCoordinator().operation()",
            ),
            trakt to simkl.replace("operation.publishAfter(", "operation.awaitWithoutFence("),
            trakt to simkl.replace("tokenMutations.invalidate", "tokenMutations.mutateWithoutInvalidation"),
        )

        mutations.forEachIndexed { index, (mutatedTrakt, mutatedSimkl) ->
            assertTrue(
                "Credential race mutation $index escaped the source contract",
                providerRaceViolations(mutatedTrakt, mutatedSimkl).isNotEmpty(),
            )
        }
    }

    private fun providerRaceViolations(trakt: String, simkl: String): List<String> = buildList {
        if (Regex("""val operation = tokenMutations\.operation\(\)""").findAll(trakt).count() < 2) {
            add("Trakt one-shot and loop polling must each capture an operation")
        }
        if (!trakt.contains("tokenMutations.snapshot(::currentStoredToken)")) {
            add("Trakt validToken must atomically snapshot token plus generation")
        }
        if (!trakt.contains("refresh(snapshot.operation)")) {
            add("Trakt must carry validToken's captured generation through refresh")
        }
        if (!trakt.contains("performRefresh(operation, current)")) {
            add("Trakt must carry the same generation from refreshMutex into the network path")
        }
        if (Regex("""poll\(deviceCode, operation\)""").findAll(trakt).count() < 2) {
            add("Trakt must carry one polling operation into the private network path")
        }
        if (Regex("""operation\.publishAfter\(""").findAll(trakt).count() < 2) {
            add("Trakt device and refresh responses must publish through the fence")
        }
        if (!trakt.contains("tokenMutations.invalidate")) {
            add("Trakt signOut must advance the generation")
        }

        if (Regex("""val operation = tokenMutations\.operation\(\)""").findAll(simkl).count() < 2) {
            add("SIMKL one-shot and loop polling must each capture an operation")
        }
        if (Regex("""poll\(userCode, operation\)""").findAll(simkl).count() < 2) {
            add("SIMKL must carry one polling operation into the private network path")
        }
        if (!simkl.contains("operation.publishAfter(")) {
            add("SIMKL authorized responses must publish through the fence")
        }
        if (!simkl.contains("tokenMutations.invalidate")) {
            add("SIMKL signOut must advance the generation")
        }
    }

    private fun readSource(fileName: String): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/integrations/$fileName"),
            File("app/src/main/kotlin/com/vortx/android/integrations/$fileName"),
            File("android/app/src/main/kotlin/com/vortx/android/integrations/$fileName"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $fileName from ${File(".").absolutePath}")
    }
}
