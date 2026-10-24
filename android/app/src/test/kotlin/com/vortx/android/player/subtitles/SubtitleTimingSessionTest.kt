package com.vortx.android.player.subtitles

import java.io.File
import java.util.Locale
import org.junit.Assert.*
import org.junit.Test

class SubtitleTimingSessionTest {
    private val admit: ((() -> Boolean) -> Boolean) = { it() }

    @Test fun manualZeroWinsAndInvalidManualCannotPoisonSeeding() {
        val zero = SubtitleAutoResync.resolve(0.0, 900, false)
        assertEquals(0.0, zero.seconds, 0.0)
        assertTrue(zero.seeded)
        assertEquals(SubtitleAutoResync.OffsetSource.MANUAL, zero.source)
        assertFalse(SubtitleAutoResync.resolve(Double.NaN, null, false).seeded)
        assertFalse(SubtitleAutoResync.resolve(121.0, null, false).seeded)
        assertEquals(0.9, SubtitleAutoResync.resolve(Double.NaN, 900, false).seconds, 0.0)
    }

    @Test fun validatesOriginalBoundsBeforeRounding() {
        for (offset in listOf(120001, -120001, Int.MIN_VALUE, Int.MAX_VALUE)) {
            assertEquals(SubtitleAutoResync.OffsetSource.NONE, SubtitleAutoResync.resolve(null, offset, false).source)
        }
        for (offset in listOf(120000, -120000)) {
            assertEquals(offset / 1000.0, SubtitleAutoResync.resolve(null, offset, false).seconds, 0.0)
        }
        assertFalse(SubtitleAutoResync.captureIsValid(120.04))
        assertFalse(SubtitleAutoResync.captureIsValid(-120.04))
    }

    @Test fun oneAutoApplyPerScopeAndManualZeroBlocksLatePool() {
        val applied = mutableListOf<Double>()
        val session = SubtitleTimingSession(null)
        assertTrue(session.applyCommunity(900, true, admit, applied::add))
        assertFalse(session.applyCommunity(1500, true, admit, applied::add))
        assertTrue(session.applyManual(0.0, true, admit, applied::add))
        assertFalse(session.applyCommunity(2200, true, admit, applied::add))
        assertEquals(listOf(0.9, 0.0), applied)
        val resetFirst = SubtitleTimingSession(null)
        assertTrue(resetFirst.applyManual(0.0, true, admit, applied::add))
        assertFalse(resetFirst.applyCommunity(2000, true, admit, applied::add))
    }

    @Test fun savedManualPreventsCommunityAndUnsupportedMedia3DoesNotPretendToApply() {
        val applied = mutableListOf<Double>()
        assertFalse(SubtitleTimingSession(-0.7).applyCommunity(900, true, admit, applied::add))
        val session = SubtitleTimingSession(null)
        assertFalse(session.applyCommunity(900, false, admit, applied::add))
        assertFalse(session.applyManual(1.0, false, admit, applied::add))
        assertTrue(applied.isEmpty())
        assertTrue(session.applyCommunity(900, true, admit, applied::add))
    }

    @Test fun sourceRetirementAndOwnerGenerationDenialsRejectLatePoolWithoutConsumingNewScope() {
        val applied = mutableListOf<Double>()
        var accountEpoch = 4L
        var profileRevision = 8L
        val accountAtRequest = accountEpoch
        val profileAtRequest = profileRevision
        val owner: ((() -> Boolean) -> Boolean) = { action ->
            accountEpoch == accountAtRequest && profileRevision == profileAtRequest && action()
        }
        val old = SubtitleTimingSession(null)
        profileRevision++
        assertFalse(old.applyCommunity(900, true, owner, applied::add))
        profileRevision = profileAtRequest
        accountEpoch++
        assertFalse(old.applyCommunity(900, true, owner, applied::add))
        assertFalse(old.applyManual(0.0, true, owner, applied::add))
        old.retire()
        assertFalse(old.applyCommunity(900, true, admit, applied::add))
        assertTrue(applied.isEmpty())
        assertTrue(SubtitleTimingSession(null).applyCommunity(-300, true, admit, applied::add))
        assertEquals(listOf(-0.3), applied)
    }

    @Test fun queryWaitsForRealDurationAndFreezesContentAndRelease() {
        assertNull(subtitlePoolPlaybackQuery("imdb:tt12345:1:2", 0L, "Episode.WEB-DL.1080p"))
        assertNull(subtitlePoolPlaybackQuery(null, 2400000L, "Episode.WEB-DL.1080p"))
        val first = requireNotNull(subtitlePoolPlaybackQuery("imdb:tt12345:1:2", 2400000L, "Episode.WEB-DL.1080p"))
        val next = requireNotNull(subtitlePoolPlaybackQuery("imdb:tt12345:1:3", 2400000L, "Episode.REMUX.2160p"))
        assertEquals("imdb:tt12345:1:2", first.contentKey)
        assertNotEquals(first, next)
        assertEquals(SubtitleReleaseFingerprint.releaseFingerprint(durationSecs = 2400.0,
            releaseName = "Episode.WEB-DL.1080p"), first.fingerprint)
    }

    @Test fun fingerprintIsIdenticalAcrossDeviceLocales() {
        val original = Locale.getDefault()
        try {
            Locale.setDefault(Locale.US)
            val english = SubtitleReleaseFingerprint.releaseFingerprint(23.976, 2400.0, "Episode.WEB-DL.1080p")
            Locale.setDefault(Locale.GERMANY)
            assertEquals(english, SubtitleReleaseFingerprint.releaseFingerprint(23.976, 2400.0, "Episode.WEB-DL.1080p"))
        } finally { Locale.setDefault(original) }
    }

    @Test fun realPhoneAndTvPlayerCallersKeepTheTimingAndOwnershipChokePoints() {
        val screen = source("PlayerScreen.kt")
        val chrome = source("PlayerChrome.kt")
        val required = listOf(
            "SubtitleTimingSession(savedSubtitleDelay)",
            "onDispose { subtitleTiming.retire() }",
            "captureLocalLibraryMutationAdmission()",
            "ContinueWatchingOwnerGate.serialized",
            "val original = originalPlaybackOwner ?: return false",
            "currentSubtitleSessionKey == playbackSessionKey &&",
            "!playerExitRequested && original.isActive && action()",
            "subtitleAccountAdmission?.invoke(validateAndMutateState)",
            "latestSubtitleEngine === engine && action()",
            "subtitlePoolPlaybackQuery(subtitleContentKey, playerState.durationMs, releaseName)",
            "contentKey = query.contentKey",
            "fingerprint = query.fingerprint",
            "currentCoroutineContext().ensureActive()",
            "subtitleTiming.applyCommunityAccepted(result.offsetMs, engine.subtitleDelayAvailable",
            "subtitleTiming.applyManualAccepted(adjustedPlayerDelay(subtitleDelaySeconds, delta)",
            "onSelectPooledSubtitle = ::selectPooledSubtitle",
            "admitCurrentSubtitleEngine {",
            "showControls()\n        trackSelectionPhases = trackSelectionPhases.holdSubtitle()\n        poolLoadingId = sub.id",
            "var poolLoadingId by remember(playbackSessionKey, engine)",
        )
        fun wired(value: String) = required.all(value::contains)
        assertTrue(wired(screen))
        assertFalse(screen.contains("revision == subtitleProfileRevision && currentSubtitleSessionKey == playbackSessionKey"))
        required.forEach { needle -> assertFalse("Removal must break actual caller contract: $needle",
            wired(screen.replace(needle, "REMOVED"))) }
        assertFalse(chrome.contains("SubtitlePoolClient.fetch"))
        assertFalse(chrome.contains("SubtitlePoolClient.download"))
        assertTrue(chrome.contains("onPick = { onSelectPooledSubtitle(sub) }"))
        assertTrue(source("PlayerEngine.kt").contains("val subtitleDelayAvailable: Boolean get() = false"))
    }

    private fun source(name: String): String {
        val relative = "src/main/kotlin/com/vortx/android/player/$name"
        return listOf(File(relative), File("app/$relative"), File("android/app/$relative"))
            .firstOrNull(File::isFile)?.readText() ?: error("Could not find actual $relative")
    }
}
