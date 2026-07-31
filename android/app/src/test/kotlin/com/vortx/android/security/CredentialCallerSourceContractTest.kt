package com.vortx.android.security

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class CredentialCallerSourceContractTest {

    @Test
    fun `production callers publish recovery truth before credential side effects`() {
        val sources = Sources.read()
        assertTrue(
            callerViolations(sources).joinToString(separator = "\n"),
            callerViolations(sources).isEmpty(),
        )
    }

    @Test
    fun `recovery ordering concurrency and ui truth mutations turn the contract red`() {
        val source = Sources.read()
        val mutations = listOf(
            source.copy(
                mediaRepository = source.mediaRepository.replace(
                    ".putString(PENDING_ADDS_KEY, encodePendingAdds(snapshot.pendingAdds))",
                    ".remove(PENDING_ADDS_KEY)",
                ),
            ),
            source.copy(
                mediaRepository = source.mediaRepository.replace(
                    "if (!persistRepositoryState(rollbackSnapshot))",
                    "if (false)",
                ),
            ),
            source.copy(
                mediaRecovery = source.mediaRecovery.replace(
                    "poisoned = true",
                    "poisoned = false",
                ),
            ),
            source.copy(
                application = source.application.replace(
                    "CoroutineScope(SupervisorJob() + Dispatchers.IO)",
                    "CoroutineScope(Dispatchers.Main)",
                ),
            ),
            source.copy(
                iptvStore = source.iptvStore.replace(
                    "private val lock = Any()",
                    "private val unlocked = Any()",
                ),
            ),
            source.copy(
                mediaScreen = source.mediaScreen.replace(
                    "MediaServerAddResult.RECOVERY_PENDING",
                    "MediaServerAddResult.NOT_CONNECTED",
                ),
            ),
            source.copy(
                iptvStore = source.iptvStore.replace(
                    "persistence.writeCredentialIfConfirmedAbsent(slug, it)",
                    "persistence.writeCredential(slug, it)",
                ),
            ),
            source.copy(
                iptvScreen = source.iptvScreen.replace(
                    "if (!IPTVPlaylists.beginCleanup(pending))",
                    "if (false)",
                ),
            ),
        )

        mutations.forEachIndexed { index, mutation ->
            assertTrue(
                "Credential caller mutation $index escaped the source contract",
                callerViolations(mutation).isNotEmpty(),
            )
        }
    }

    private fun callerViolations(source: Sources): List<String> = buildList {
        if (!source.mediaRepository.contains(
                ".putString(PENDING_ADDS_KEY, encodePendingAdds(snapshot.pendingAdds))",
            ) ||
            !source.mediaRepository.contains("PENDING_REMOVALS_KEY,") ||
            !source.mediaRepository.contains(".commit()")
        ) {
            add("Media server records and both recovery journals must publish in one synchronous commit")
        }
        val rollbackPublished = source.mediaRepository.indexOf(
            "if (!persistRepositoryState(rollbackSnapshot))",
        )
        val credentialsMutated = source.mediaRepository.indexOf("if (!store.set(values))")
        if (rollbackPublished < 0 || credentialsMutated < 0 || rollbackPublished > credentialsMutated) {
            add("Media server add must publish its rollback journal before credential mutation")
        }
        if (!source.mediaRepository.contains("resumePendingAdds()") ||
            !source.mediaRecovery.contains("MediaServerAddDisposition.ROLLBACK") ||
            !source.mediaRecovery.contains("MediaServerAddDisposition.COMMITTED") ||
            !source.mediaRecovery.contains("backupKey to encodePriorMediaServerToken")
        ) {
            add("Media server add recovery must retain prior token state and replay both dispositions")
        }
        if (!source.mediaRecovery.contains("if (poisoned ||") ||
            !source.mediaRecovery.contains("poisoned = true") ||
            !source.mediaRecovery.contains("confirmed = MediaServerMetadataRead.Available(next)")
        ) {
            add("Rejected media metadata commits must poison writes while retaining confirmed process truth")
        }
        if (!source.mediaRepository.contains(
                "if (!publishRemoval()) return MediaServerRemovalResult.UNCHANGED",
            ) ||
            !source.mediaRepository.contains("resumePendingRemovals()")
        ) {
            add("Media server removal must journal before clear and replay at init")
        }
        if (!source.mediaRepository.contains("if (startGeneration != currentGeneration) return emptyList()")) {
            add("Media server lookup results must be fenced by provider generation")
        }
        if (!source.mediaRepository.contains("store?.confirmedString(tokenKey(r.id))")) {
            add("Media server providers must use only confirmed credentials")
        }

        if (Regex("""MediaServerAddResult\.CONNECTED""").findAll(source.mediaScreen).count() != 3 ||
            Regex("""MediaServerAddResult\.RECOVERY_PENDING""").findAll(source.mediaScreen).count() != 3
        ) {
            add("Every media server add flow must branch on connected and uncertain recovery truth")
        }
        if (Regex("Could not confirm the server connection\\.")
                .findAll(source.mediaScreen).count() != 3
        ) {
            add("Every media server add flow must display a distinct uncertain recovery result")
        }
        if (Regex("Could not connect this server\\. It is not connected\\. Try again\\.")
                .findAll(source.mediaScreen).count() != 3
        ) {
            add("Every confirmed media server add rejection must describe unpublished metadata truthfully")
        }
        if (!source.mediaScreen.contains("MediaServerRemovalResult.CLEANUP_PENDING")) {
            add("Media server UI must distinguish disconnected cleanup-pending truth")
        }
        if (Regex("Retry saving server").findAll(source.mediaScreen).count() != 2) {
            add("Jellyfin and Emby must retain authenticated results for confirmed save retries")
        }

        if (!source.application.contains(
                "CoroutineScope(SupervisorJob() + Dispatchers.IO)",
            ) ||
            !source.application.contains("launchIPTVStartupCleanup(") ||
            !source.application.contains("iptvCleanupActions(repo)")
        ) {
            add("Application start must replay IPTV cleanup in its supervised IO scope using existing actions")
        }
        if (!source.iptvCoordinator.contains("internal fun launchIPTVStartupCleanup(")) {
            add("IPTV application-start replay must remain testable through its startup seam")
        }
        if (!source.iptvStore.contains("private val lock = Any()") ||
            !source.iptvStore.contains(
                "private inline fun <T> withLock(block: () -> T): T = synchronized(lock, block)",
            ) ||
            !source.iptvStore.contains(
                "fun applySyncBlob(json: String): Boolean = withLock {",
            ) ||
            !source.iptvStore.contains(
                "fun beginCleanup(cleanup: IPTVPendingCleanup): Boolean = withLock {",
            )
        ) {
            add("IPTV compound metadata and cleanup-journal RMW operations must share one private lock")
        }
        if (!source.iptvStore.contains("internal interface IPTVPersistence") ||
            !source.iptvStore.contains("internal class SharedPreferencesIPTVPersistence")
        ) {
            add("IPTV persistence internals must not expose credential security result types")
        }
        if (!source.iptvStore.contains("sealed interface IPTVCredentialRead") ||
            !source.iptvStore.contains("data object Unavailable : IPTVCredentialRead")
        ) {
            add("IPTV credential reads must distinguish persistent unavailability from absence")
        }
        if (!source.iptvStore.contains("persistence.writeCredentialIfConfirmedAbsent(slug, it)")) {
            add("IPTV sync adoption must use atomic confirmed-absence writes")
        }
        if (!source.iptvStore.contains(
                "override fun writeMetadata(playlistsJson: String, removedJson: String): Boolean",
            ) ||
            !source.iptvStore.contains(".commit()")
        ) {
            add("IPTV playlist and tombstone metadata must expose synchronous commit truth")
        }
        if (!source.iptvStore.contains("KEY_PENDING_CLEANUP") ||
            !source.iptvStore.contains("UnavailableOrCorrupt")
        ) {
            add("IPTV external cleanup must have a durable fail-closed journal")
        }
        if (!source.iptvScreen.contains("if (!IPTVPlaylists.beginCleanup(pending))")) {
            add("IPTV remove must stage its cleanup journal before any removal side effect")
        }
    }

    private data class Sources(
        val mediaRepository: String,
        val mediaRecovery: String,
        val mediaScreen: String,
        val application: String,
        val iptvStore: String,
        val iptvCoordinator: String,
        val iptvScreen: String,
    ) {
        companion object {
            fun read(): Sources = Sources(
                mediaRepository = readSource(
                    "src/main/kotlin/com/vortx/android/mediaserver/MediaServerRepository.kt",
                ),
                mediaRecovery = readSource(
                    "src/main/kotlin/com/vortx/android/mediaserver/MediaServerRecovery.kt",
                ),
                mediaScreen = readSource(
                    "src/main/kotlin/com/vortx/android/ui/screens/MediaServersScreen.kt",
                ),
                application = readSource(
                    "src/main/kotlin/com/vortx/android/VortXApplication.kt",
                ),
                iptvStore = readSource(
                    "src/main/kotlin/com/vortx/android/iptv/IPTVPlaylistStore.kt",
                ),
                iptvCoordinator = readSource(
                    "src/main/kotlin/com/vortx/android/iptv/IPTVCleanupCoordinator.kt",
                ),
                iptvScreen = readSource(
                    "src/main/kotlin/com/vortx/android/iptv/IPTVSettingsScreen.kt",
                ),
            )

            private fun readSource(relative: String): String {
                val candidates = listOf(
                    File(relative),
                    File("app/$relative"),
                    File("android/app/$relative"),
                )
                return candidates.firstOrNull(File::isFile)?.readText()
                    ?: error("Could not locate $relative from ${File(".").absolutePath}")
            }
        }
    }
}
