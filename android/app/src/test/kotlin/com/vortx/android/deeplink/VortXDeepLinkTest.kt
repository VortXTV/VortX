package com.vortx.android.deeplink

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.Playable
import com.vortx.android.ui.UiState
import com.vortx.android.ui.detailViewModelKey
import com.vortx.android.ui.screens.resolvedDetailPlayback
import com.vortx.android.ui.viewmodel.Playback
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class VortXDeepLinkTest {
    @Test
    fun `lowercase movie and series links decode identifiers`() {
        assertEquals(
            VortXDeepLink(MediaType.MOVIE, "tt123"),
            VortXDeepLinks.parse("vortx://open?type=movie&id=%20tt123%20"),
        )
        assertEquals(
            VortXDeepLink(MediaType.SERIES, "series:id/1"),
            VortXDeepLinks.parse("vortx://open?type=series&id=series%3Aid%2F1"),
        )
    }

    @Test
    fun `percent decoding preserves plus and rejects malformed utf8`() {
        assertEquals(
            VortXDeepLink(MediaType.MOVIE, "a+b+c"),
            VortXDeepLinks.parse("vortx://open?type=movie&id=a+b%2Bc"),
        )
        assertEquals(
            VortXDeepLink(MediaType.SERIES, "show-€"),
            VortXDeepLinks.parse("vortx://open?type=series&id=show-%E2%82%AC"),
        )
        assertNull(VortXDeepLinks.parse("vortx://open?type=movie&id=%C3%28"))
        assertNull(VortXDeepLinks.parse("vortx://open?type=movie&id=%E2%82"))
    }

    @Test
    fun `first duplicate query value wins`() {
        assertEquals(
            VortXDeepLink(MediaType.MOVIE, "first"),
            VortXDeepLinks.parse("vortx://open?type=movie&type=series&id=first&id=second"),
        )
    }

    @Test
    fun `malformed unsupported and oversized links fail closed`() {
        val oversized = "x".repeat(257)
        listOf(
            null,
            "",
            "VORTX://open?type=movie&id=tt1",
            "vortx://OPEN?type=movie&id=tt1",
            "vortx://open?type=Movie&id=tt1",
            "https://open?type=movie&id=tt1",
            "vortx://closed?type=movie&id=tt1",
            "vortx://open?type=channel&id=tt1",
            "vortx://open?type=movie&id=",
            "vortx://open?type=movie&id=$oversized",
            "vortx://open?type=movie&id=%ZZ",
        ).forEach { assertNull(it, VortXDeepLinks.parse(it)) }
    }

    @Test
    fun `accepted delivery is not replayed after recreation but a new intent is accepted`() {
        val raw = "vortx://open?type=movie&id=tt123"
        val firstActivity = DeepLinkDeliveryState()
        val accepted = firstActivity.consume("delivery-a", raw)

        assertNotNull(accepted)
        assertEquals("delivery-a", firstActivity.consumedDeliveryId)
        assertNull(firstActivity.consume("delivery-a", raw))

        val recreatedActivity = DeepLinkDeliveryState(firstActivity.consumedDeliveryId)
        assertNull(recreatedActivity.consume("delivery-a", raw))

        assertEquals(accepted?.target, recreatedActivity.consume("delivery-b", raw)?.target)
    }

    @Test
    fun `restored delivery rejects replay a but accepts genuinely new cold delivery b`() {
        val oldUrl = "vortx://open?type=movie&id=tt-old"
        val newUrl = "vortx://open?type=series&id=tt-new"
        val state = DeepLinkDeliveryState(restoredConsumedDeliveryId = "delivery-a")

        assertNull(state.consume("delivery-a", oldUrl))
        assertEquals(
            VortXDeepLink(MediaType.SERIES, "tt-new"),
            state.consume("delivery-b", newUrl)?.target,
        )
    }

    @Test
    fun `phone and tv activities persist and clear accepted intent data`() {
        listOf(
            readProjectFile("src/main/kotlin/com/vortx/android/MainActivity.kt"),
            readProjectFile("src/main/kotlin/com/vortx/android/ui/tv/TvActivity.kt"),
        ).forEach { source ->
            assertTrue(source.contains("deepLinks.restore(savedInstanceState)"))
            assertTrue(source.contains("deepLinks.route(intent, forceNewDelivery = true)"))
            assertTrue(source.contains("deepLinks.save(outState)"))
            assertTrue(source.contains("deepLinkEvent = deepLinks.pendingEvent"))
            assertTrue(source.contains("onDeepLinkHandled = deepLinks::acknowledge"))
        }
        val adapter = readProjectFile("src/main/kotlin/com/vortx/android/deeplink/ActivityDeepLinkDelivery.kt")
        assertTrue(adapter.contains("restoredConsumedDeliveryId = saved?.getString(STATE_DELIVERY_ID)"))
        assertTrue(adapter.contains("source.data = null"))
        val saved = adapter.substringAfter("fun save(outState: Bundle)").substringBefore("private companion object")
        val savedKeys = Regex("""outState\.put\w+\((STATE_[A-Z_]+),""").findAll(saved)
            .map { it.groupValues[1] }.toList()
        assertEquals(listOf("STATE_DELIVERY_ID", "STATE_LAUNCH_FINGERPRINT", "STATE_LATEST_FINGERPRINT",
            "STATE_TITLE_TYPE", "STATE_TITLE_ID", "STATE_TITLE_SEQUENCE"), savedKeys)
    }

    @Test
    fun `unhandled plain title survives recreation and retained intent still cannot replay`() {
        val raw = "vortx://open?type=movie&id=tt123"
        val original = DeepLinkDeliveryState()
        val a = checkNotNull(original.consume("delivery-a", raw))

        val recreated = DeepLinkDeliveryState("delivery-a", a.target.type.id, a.target.id, a.sequence)
        val restored = checkNotNull(recreated.pendingEvent)
        assertEquals(a, restored)
        assertFalse(recreated.acknowledge(a))
        assertNull(recreated.consume("delivery-a", raw))
        assertSame(restored, recreated.pendingEvent)
        assertTrue(recreated.acknowledge(restored))
        assertNull(recreated.pendingEvent)

        val afterAcknowledgement = DeepLinkDeliveryState(recreated.consumedDeliveryId)
        assertNull(afterAcknowledgement.pendingEvent)
        assertNull(afterAcknowledgement.consume("delivery-a", raw))
        assertNotNull(afterAcknowledgement.consume("delivery-b", raw))
    }

    @Test
    fun `invalid warm intent preserves pending and an old acknowledgement cannot discard a newer intent`() {
        val state = DeepLinkDeliveryState("delivery-a", "series", "same-id", 41L)
        val a = checkNotNull(state.pendingEvent)
        assertNull(state.consume("invalid-delivery", "vortx://open?type=channel&id=bad"))
        assertSame(a, state.pendingEvent)
        assertEquals("delivery-a", state.consumedDeliveryId)

        val b = checkNotNull(state.consume("delivery-b", "vortx://open?type=series&id=same-id"))
        assertEquals(a.target, b.target)
        assertEquals(42L, b.sequence)
        assertFalse(state.acknowledge(a))
        assertFalse(state.acknowledge(b.copy()))
        assertSame(b, state.pendingEvent)
        assertTrue(state.acknowledge(b))
    }

    @Test
    fun `malformed restored title is discarded without resetting intent replay protection`() {
        val invalid = listOf(
            DeepLinkDeliveryState("delivery-a", "channel", "tt123", 1L),
            DeepLinkDeliveryState("delivery-a", "movie", "", 1L),
            DeepLinkDeliveryState("delivery-a", "movie", " tt123 ", 1L),
            DeepLinkDeliveryState("delivery-a", "movie", "x".repeat(257), 1L),
            DeepLinkDeliveryState("delivery-a", "movie", "tt123", 0L),
            DeepLinkDeliveryState("delivery-a", "movie", "tt123", -1L),
            DeepLinkDeliveryState(null, "movie", "tt123", 1L),
        )
        assertTrue(invalid.all { it.pendingEvent == null })
        assertNull(invalid.first().consume("delivery-a", "vortx://open?type=movie&id=tt123"))
        assertNotNull(invalid.first().consume("delivery-b", "vortx://open?type=movie&id=tt123"))
    }

    @Test
    fun `unmarked original launch cannot replace a newer pending or acknowledged title after recreation`() {
        val launchUrl = "vortx://open?type=movie&id=tt-original"
        val warmUrl = "vortx://open?type=series&id=tt-newer"
        val original = DeepLinkDeliveryState()
        assertTrue(original.route("delivery-a", launchUrl, coldLaunch = true) is DeepLinkDeliveryState.IntentAdmission.Accepted)
        val warm = checkNotNull(original.consume("delivery-b", warmUrl))
        assertEquals(64, original.launchFingerprint?.length)
        assertEquals(64, original.latestFingerprint?.length)
        assertNotEquals(original.launchFingerprint, original.latestFingerprint)

        fun recreate(pending: VortXDeepLinkEvent?) = DeepLinkDeliveryState(
            original.consumedDeliveryId, pending?.target?.type?.id, pending?.target?.id, pending?.sequence ?: 0L,
            original.launchFingerprint, original.latestFingerprint,
        )
        val pending = recreate(warm)
        val retained = pending.pendingEvent
        assertEquals(DeepLinkDeliveryState.IntentAdmission.Replay,
            pending.route("unmarked-original", "vortx://open?id=%74t-original&type=movie", coldLaunch = true))
        assertEquals(DeepLinkDeliveryState.IntentAdmission.Replay,
            pending.route("unmarked-warm", warmUrl, coldLaunch = true))
        assertSame(retained, pending.pendingEvent)
        assertEquals("delivery-b", pending.consumedDeliveryId)

        assertTrue(original.acknowledge(warm))
        val acknowledged = recreate(original.pendingEvent)
        assertEquals(DeepLinkDeliveryState.IntentAdmission.Replay,
            acknowledged.route("unmarked-original", launchUrl, coldLaunch = true))
        assertNull(acknowledged.pendingEvent)
        assertNotNull(acknowledged.consume("genuine-new-warm", launchUrl))
    }

    @Test
    fun `a distinct valid cold title can replace a restored pending title`() {
        val original = DeepLinkDeliveryState()
        val url = "vortx://open?type=movie&id=old"
        val a = (original.route("delivery-a", url, coldLaunch = true) as DeepLinkDeliveryState.IntentAdmission.Accepted).event
        val recreated = DeepLinkDeliveryState("delivery-a", a.target.type.id, a.target.id, a.sequence,
            original.launchFingerprint, original.latestFingerprint)
        val replacement = recreated.route("delivery-c", "vortx://open?type=movie&id=new", coldLaunch = true)
        assertTrue(replacement is DeepLinkDeliveryState.IntentAdmission.Accepted)
        assertEquals("new", recreated.pendingEvent?.target?.id)
        assertFalse(recreated.acknowledge(a))
    }

    @Test
    fun `legacy consumed state suppresses unmarked recreation without blocking a warm link`() {
        val restored = DeepLinkDeliveryState(restoredConsumedDeliveryId = "legacy-delivery")
        val raw = "vortx://open?type=movie&id=old"
        assertEquals(DeepLinkDeliveryState.IntentAdmission.Replay, restored.route("recreated", raw, coldLaunch = true))
        assertNull(restored.pendingEvent)
        assertNotNull(restored.consume("genuine-new-warm", raw))
    }

    private fun DeepLinkDeliveryState.consume(deliveryId: String, rawUrl: String?): VortXDeepLinkEvent? =
        (route(deliveryId, rawUrl) as? DeepLinkDeliveryState.IntentAdmission.Accepted)?.event

    @Test
    fun `phone and tv activities forward pre-S home presses to the shared PiP bridge`() {
        listOf(
            readProjectFile("src/main/kotlin/com/vortx/android/MainActivity.kt"),
            readProjectFile("src/main/kotlin/com/vortx/android/ui/tv/TvActivity.kt"),
        ).forEach { source ->
            assertTrue(source.contains("override fun onUserLeaveHint()"))
            assertTrue(source.contains("PlayerPipBridge.onUserLeaveHint()"))
        }
    }

    @Test
    fun `detail teardown releases every auxiliary source owner`() {
        val source = readProjectFile("src/main/kotlin/com/vortx/android/ui/viewmodel/DetailViewModel.kt")
        val onCleared = source.substring(source.indexOf("override fun onCleared()"))

        assertTrue(onCleared.contains("torbox.close()"))
        assertTrue(onCleared.contains("singularity.close()"))
        assertTrue(onCleared.contains("communityJs.close()"))
    }

    @Test
    fun `invalid delivery does not block the next valid intent`() {
        val state = DeepLinkDeliveryState()
        assertNull(state.consume("delivery-a", "vortx://open?type=channel&id=bad"))
        assertNull(state.consumedDeliveryId)
        assertEquals(
            VortXDeepLink(MediaType.SERIES, "tt456"),
            state.consume("delivery-b", "vortx://open?type=series&id=tt456")?.target,
        )
    }

    @Test
    fun `deep link playback carries loaded detail metadata into auto add`() {
        val provisional = VortXDeepLink(MediaType.MOVIE, "tt123").toMetaItem()
        val loaded = MetaDetail(
            id = "tt123",
            type = MediaType.MOVIE,
            name = "Real title",
            poster = "https://images.example/poster.jpg",
        )
        val playable = Playable(url = "https://video.example/movie.mkv", title = loaded.name)
        val resolved = resolvedDetailPlayback(Playback.Ready(playable), UiState.Success(loaded))

        assertNotNull(resolved)
        assertSame(loaded, resolved?.metadata)
        assertEquals("Real title", resolved?.metadata?.name)
        assertEquals("https://images.example/poster.jpg", resolved?.metadata?.poster)
        assertNotEquals(provisional.name, resolved?.metadata?.name)
        assertNull(resolvedDetailPlayback(Playback.Ready(playable), UiState.Loading))
    }

    @Test
    fun `one lowercase browsable router forwards to two single task launchers`() {
        val manifest = readProjectFile("src/main/AndroidManifest.xml")

        assertEquals(2, Regex("android:launchMode=\"singleTask\"").findAll(manifest).count())
        assertEquals(1, Regex("android:name=\"android.intent.action.VIEW\"").findAll(manifest).count())
        assertEquals(1, Regex("android:scheme=\"vortx\" android:host=\"open\"").findAll(manifest).count())
        assertTrue(manifest.contains("android:name=\".MainActivity\""))
        assertTrue(manifest.contains("android:name=\".ui.tv.TvActivity\""))
        assertTrue(manifest.contains("android:name=\".deeplink.DeepLinkActivity\""))
    }

    @Test
    fun `navigation keys include media type and repeated events reset only local detail state`() {
        val phone = readProjectFile("src/main/kotlin/com/vortx/android/ui/VortXApp.kt")
        val tv = readProjectFile("src/main/kotlin/com/vortx/android/ui/tv/TvApp.kt")
        val detail = readProjectFile("src/main/kotlin/com/vortx/android/ui/screens/DetailScreen.kt")

        assertTrue(phone.contains("typeId = showForNext.type.id"))
        assertTrue(phone.contains("mediaId = showForNext.id"))
        assertTrue(phone.contains("typeId = current.type.id"))
        assertTrue(phone.contains("mediaId = current.id"))
        assertTrue(tv.contains("prefix = \"tv-detail\""))
        assertTrue(tv.contains("typeId = current.type.id"))
        assertTrue(detail.contains("detail-nested-${'$'}{target.type.id}-${'$'}{target.id}"))
        assertTrue(phone.contains("key(current.type, current.id, detailGeneration)"))
        assertTrue(tv.contains("key(current.type, current.id, detailGeneration)"))
        assertTrue(phone.contains("detailGeneration += 1"))
        assertTrue(tv.contains("detailGeneration += 1"))
        assertFalse(Regex("viewModel\\([\\s\\S]{0,240}detailGeneration").containsMatchIn(phone))
        assertFalse(Regex("viewModel\\([\\s\\S]{0,240}detailGeneration").containsMatchIn(tv))
        assertTrue(phone.contains("showWhatsNew = false"))
    }

    @Test
    fun `repeat navigation to one target reuses one view model instance key`() {
        val store = ViewModelStore()
        var created = 0
        val provider = ViewModelProvider(
            store,
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T {
                    created += 1
                    return CountingViewModel() as T
                }
            },
        )
        fun navigate(generation: Long): CountingViewModel {
            assertTrue(generation > 0)
            val key = detailViewModelKey("detail", "movie", "tt123", "owner:7")
            return provider[key, CountingViewModel::class.java]
        }

        try {
            val first = navigate(generation = 1)
            val repeated = navigate(generation = 2)

            assertSame(first, repeated)
            assertEquals(1, created)
            assertNotEquals(
                detailViewModelKey("detail", "movie", "tt123", "owner:7"),
                detailViewModelKey("detail", "series", "tt123", "owner:7"),
            )
        } finally {
            store.clear()
        }
    }

    private class CountingViewModel : ViewModel()

    private fun readProjectFile(relativePath: String): String {
        val candidates = listOf(File(relativePath), File("app/$relativePath"), File("android/app/$relativePath"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relativePath from ${File(".").absolutePath}")
    }
}
