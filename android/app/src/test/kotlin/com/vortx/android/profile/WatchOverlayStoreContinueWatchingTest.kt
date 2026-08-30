package com.vortx.android.profile

import android.content.SharedPreferences
import java.lang.reflect.Proxy
import kotlinx.coroutines.test.TestScope
import org.junit.Assert.assertEquals
import org.junit.Test

class WatchOverlayStoreContinueWatchingTest {
    @Test
    fun aliasBridgeUsesSourceOrderForBadClocksAndAcceptsNewerRewatch() {
        val prefs = preferences()
        val profileId = "overlay"
        prefs.edit().putString(
            WatchOverlayStore.cacheKey(UserProfile.normalizeId(profileId)),
            WatchEntry.encodeMap(
                linkedMapOf(
                    "tmdb:1396" to WatchEntry(
                        videoId = "tt0903747:5:16",
                        timeOffsetMs = 1_000,
                        durationMs = 10_000,
                        lastWatched = "not-a-timestamp",
                        name = "Source-order winner",
                        type = "series",
                    ),
                    "imdb:tt0903747" to WatchEntry(
                        videoId = "tt0903747:5:15",
                        timeOffsetMs = 2_000,
                        durationMs = 10_000,
                        lastWatched = "",
                        name = "Missing clock",
                        type = "series",
                    ),
                ),
            ),
        ).commit()

        val store = WatchOverlayStore(prefs, scope = TestScope())
        store.activate(profileId, usesEngineHistory = false)
        assertEquals(listOf("tmdb:1396"), store.continueWatching().map { it.id })

        store.applyRemoteOverlay(
            profileId,
            mapOf(
                "imdb:tt0903747" to WatchEntry(
                    videoId = "tt0903747:5:17",
                    timeOffsetMs = 3_000,
                    durationMs = 10_000,
                    lastWatched = "2026-08-30T20:00:00.000Z",
                    name = "Newer rewatch",
                    type = "series",
                ),
            ),
            isEngineBacked = false,
        )
        assertEquals(listOf("imdb:tt0903747"), store.continueWatching().map { it.id })
    }

    @Suppress("UNCHECKED_CAST")
    private fun preferences(): SharedPreferences {
        val values = linkedMapOf<String, Any?>()
        lateinit var prefs: SharedPreferences
        prefs = Proxy.newProxyInstance(
            SharedPreferences::class.java.classLoader,
            arrayOf(SharedPreferences::class.java),
        ) { _, method, args ->
            when (method.name) {
                "getString" -> values[args!![0]] as? String ?: args[1]
                "getAll" -> values.toMap()
                "contains" -> values.containsKey(args!![0])
                "edit" -> editor(values)
                "registerOnSharedPreferenceChangeListener", "unregisterOnSharedPreferenceChangeListener" -> Unit
                "toString" -> "WatchOverlayTestPreferences"
                "hashCode" -> System.identityHashCode(prefs)
                "equals" -> prefs === args?.firstOrNull()
                else -> error("Unexpected SharedPreferences call: ${method.name}")
            }
        } as SharedPreferences
        return prefs
    }

    @Suppress("UNCHECKED_CAST")
    private fun editor(values: MutableMap<String, Any?>): SharedPreferences.Editor {
        lateinit var editor: SharedPreferences.Editor
        val updates = linkedMapOf<String, Any?>()
        val removals = linkedSetOf<String>()
        editor = Proxy.newProxyInstance(
            SharedPreferences.Editor::class.java.classLoader,
            arrayOf(SharedPreferences.Editor::class.java),
        ) { _, method, args ->
            when (method.name) {
                "putString" -> { updates[args!![0] as String] = args[1]; editor }
                "remove" -> { removals += args!![0] as String; editor }
                "clear" -> { removals += values.keys; editor }
                "apply" -> { removals.forEach(values::remove); values.putAll(updates); Unit }
                "commit" -> { removals.forEach(values::remove); values.putAll(updates); true }
                "toString" -> "WatchOverlayTestEditor"
                "hashCode" -> System.identityHashCode(editor)
                "equals" -> editor === args?.firstOrNull()
                else -> error("Unexpected Editor call: ${method.name}")
            }
        } as SharedPreferences.Editor
        return editor
    }
}
