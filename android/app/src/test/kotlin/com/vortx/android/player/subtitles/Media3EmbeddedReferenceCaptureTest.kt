package com.vortx.android.player.subtitles

import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

class Media3EmbeddedReferenceCaptureTest {
    private class Fixture {
        val load = Any()
        val extractor = Any()
        val live = AtomicBoolean(true)
        val capture = Media3EmbeddedReferenceCapture(load, live)
        val response = Any()
        val track: Media3EmbeddedReferenceCapture.Track
        init {
            capture.dataSourceCreationStarted()
            capture.dataSourceCreated(response)
            capture.responseOpened(response, 0, Media3EmbeddedReferenceCapture.UNBOUNDED_LENGTH)
            capture.responseOpenSucceeded(response)
            check(capture.initialize(extractor))
            track = requireNotNull(capture.track(extractor, 42))
            capture.format(track, "real-container-track-id", "en", "application/x-subrip")
        }
        fun begin(position: Long = 0) = capture.beginRead(extractor, position)
        fun cues(count: Int = 8, startUs: Long = 1_000_000, durationUs: Long = 500_000) =
            capture.sample(track, startUs, durationUs, count)
        fun end(position: Long = 20, result: Media3EmbeddedReferenceCapture.ReadResult =
            Media3EmbeddedReferenceCapture.ReadResult.END_OF_INPUT) = capture.endRead(extractor, position, result)
        fun snapshot() = capture.snapshot(load, "real-container-track-id")
    }

    @Test fun lateTimestampAndPartialReadCannotMasqueradeAsCompletePrefix() {
        val f = Fixture()
        f.begin()
        f.cues(startUs = 1_079_000_000)
        assertNull(f.snapshot())
        f.end(result = Media3EmbeddedReferenceCapture.ReadResult.CONTINUE)
        assertNull(f.snapshot())
        f.begin(20)
        f.end(20)
        assertNotNull(f.snapshot())
    }

    @Test fun snapshotBindsOriginalLoadObjectAndRealExtractorTrackId() {
        val f = Fixture()
        f.begin(); f.cues(); f.end()
        val snapshot = requireNotNull(f.snapshot())
        assertSame(f.load, snapshot.loadIdentity)
        assertEquals(42, snapshot.track.track.extractorTrackId)
        assertEquals("real-container-track-id", snapshot.track.formatId)
        assertEquals("en", snapshot.track.language)
        assertNull(f.capture.snapshot(Any(), "real-container-track-id"))
        assertNull(f.capture.snapshot(f.load, "42")) // Do not invent a format ID from a menu ordinal.
    }

    @Test fun normalContiguousReadsIncludingZeroLengthReadCanComplete() {
        val f = Fixture()
        f.capture.seek(f.extractor, 0, 0)
        f.begin(); f.cues(4); f.end(10, Media3EmbeddedReferenceCapture.ReadResult.CONTINUE)
        f.begin(10); f.end(10, Media3EmbeddedReferenceCapture.ReadResult.CONTINUE)
        f.begin(10); f.cues(4, 2_000_000); f.end(100)
        assertEquals(8, requireNotNull(f.snapshot()).occurrences.size)
    }

    @Test fun nonzeroInitialInputDoesNotCertifyTheMissingPrefix() {
        val f = Fixture()
        f.begin(12); f.cues(); f.end()
        assertNull(f.snapshot())
    }

    @Test fun seekRequiredAndEvenZeroRestartAfterReadLoseCompleteness() {
        val seekRequired = Fixture()
        seekRequired.begin(); seekRequired.cues()
        seekRequired.end(20, Media3EmbeddedReferenceCapture.ReadResult.SEEK_REQUIRED)
        assertNull(seekRequired.snapshot())
        val restart = Fixture()
        restart.begin(); restart.cues(); restart.end(20, Media3EmbeddedReferenceCapture.ReadResult.CONTINUE)
        restart.capture.seek(restart.extractor, 0, 0)
        restart.begin(); restart.end()
        assertNull(restart.snapshot())
    }

    @Test fun nonzeroInitialSeekAndUnannouncedInputGapAreRejected() {
        val resume = Fixture()
        resume.capture.seek(resume.extractor, 0, 60_000_000)
        resume.begin(); resume.cues(); resume.end()
        assertNull(resume.snapshot())
        val gap = Fixture()
        gap.begin(); gap.cues(); gap.end(10, Media3EmbeddedReferenceCapture.ReadResult.CONTINUE)
        gap.begin(11); gap.end(20)
        assertNull(gap.snapshot())
    }

    @Test fun wrongExtractorAndNestedReadsFailClosed() {
        val wrong = Fixture()
        wrong.capture.beginRead(Any(), 0)
        wrong.begin(); wrong.cues(); wrong.end()
        assertNull(wrong.snapshot())
        val nested = Fixture()
        nested.begin(); nested.begin(); nested.cues(); nested.end()
        assertNull(nested.snapshot())
    }

    @Test fun reversedInputPositionIsNotCompletion() {
        val f = Fixture()
        f.begin(); f.cues(); f.end(-1)
        assertNull(f.snapshot())
    }

    @Test fun loadFailureRetirementAndOriginalOwnerRetirementDenyReadyEvidence() {
        val failed = Fixture()
        failed.begin(); failed.cues(); failed.end(); failed.capture.fail()
        assertNull(failed.snapshot())
        val retired = Fixture()
        retired.begin(); retired.cues(); retired.end(); retired.capture.retire()
        assertNull(retired.snapshot())
        val owner = Fixture()
        owner.begin(); owner.cues(); owner.end(); owner.live.set(false)
        assertNull(owner.snapshot())
    }

    @Test fun duplicateAndEqualStartOccurrencesAreRetainedAndSortedWithoutDeduplication() {
        val f = Fixture()
        f.begin()
        f.cues(2, 3_000_000, 1_000_000)
        f.cues(4, 1_000_000, 1_000_000)
        f.cues(2, 1_000_000, 500_000)
        f.end()
        val cues = requireNotNull(f.snapshot()).occurrences
        assertEquals(8, cues.size)
        assertEquals(2, cues.count { it.startUs == 1_000_000L && it.endUs == 1_500_000L })
        assertEquals(4, cues.count { it.startUs == 1_000_000L && it.endUs == 2_000_000L })
        assertEquals(2, cues.count { it.startUs == 3_000_000L })
        assertEquals(listOf(2_000_000L, 2_000_000L, 2_000_000L, 2_000_000L, 1_500_000L, 1_500_000L),
            cues.take(6).map { it.endUs })
    }

    @Test fun prefixBoundaryKeepsWholeActualOccurrencesAndDoesNotClipOrInventEvidence() {
        val f = Fixture()
        f.begin()
        f.cues(8, Media3EmbeddedReferenceCapture.PREFIX_END_US - 10, 10)
        f.cues(1, Media3EmbeddedReferenceCapture.PREFIX_END_US - 10, 20)
        f.cues(1, Media3EmbeddedReferenceCapture.PREFIX_END_US, 20)
        f.end()
        val snapshot = requireNotNull(f.snapshot())
        assertEquals(8, snapshot.occurrences.size)
        assertTrue(snapshot.occurrences.all { it.endUs == Media3EmbeddedReferenceCapture.PREFIX_END_US })
    }

    @Test fun oversizeOccurrenceSetIsRejectedRatherThanSilentlyTruncated() {
        val exact = Fixture()
        exact.begin(); exact.cues(1024); exact.end()
        assertEquals(1024, requireNotNull(exact.snapshot()).occurrences.size)
        val excess = Fixture()
        excess.begin(); excess.cues(1024); excess.cues(1); excess.end()
        assertNull(excess.snapshot())
    }

    @Test fun insufficientOccurrencesAndEmptySetsAreNotAnAlignmentWitness() {
        val f = Fixture()
        f.begin(); f.cues(0, Long.MIN_VALUE, Long.MIN_VALUE); f.cues(7); f.end()
        assertNull(f.snapshot())
    }

    @Test fun invalidTimingAndOverflowInvalidateTheTrack() {
        for ((start, duration) in listOf(-1L to 1L, 0L to 0L, 0L to -1L, Long.MAX_VALUE to 1L)) {
            val f = Fixture()
            f.begin(); f.cues(); f.cues(1, start, duration); f.end()
            assertNull(f.snapshot())
        }
    }

    @Test fun exactFormatIdentityMustRemainUniqueAndUnchanged() {
        val duplicate = Fixture()
        val other = requireNotNull(duplicate.capture.track(duplicate.extractor, 99))
        duplicate.capture.format(other, "real-container-track-id", "fr", "application/x-subrip")
        duplicate.begin(); duplicate.cues(); duplicate.end()
        assertNull(duplicate.snapshot())
        val changed = Fixture()
        changed.begin(); changed.cues()
        changed.capture.format(changed.track, "real-container-track-id", "fr", "application/x-subrip")
        changed.end()
        assertNull(changed.snapshot())
    }

    @Test fun missingOrUnsupportedFormatIsNotGuessedFromTrackNumberOrLanguage() {
        for ((id, mime) in listOf(null to "application/x-subrip", "" to "application/x-subrip",
            "x" to "application/pgs", "x" to "text/vtt", "x" to "text/x-ssa", "x" to "application/ttml+xml")) {
            val f = Fixture()
            val unsupported = requireNotNull(f.capture.track(f.extractor, 99))
            f.capture.format(unsupported, id, "en", mime)
            assertFalse(f.capture.acceptsSamples(unsupported))
        }
    }

    @Test fun trackBudgetFailsClosedAndForeignTrackCannotInjectTimings() {
        val bounded = Fixture()
        for (id in 100 until 100 + Media3EmbeddedReferenceCapture.MAX_TEXT_TRACKS) bounded.capture.track(bounded.extractor, id)
        bounded.begin(); bounded.cues(); bounded.end()
        assertNull(bounded.snapshot())
        val original = Fixture()
        val foreign = Fixture()
        original.begin()
        original.capture.sample(foreign.track, 1_000_000, 500_000, 8)
        original.end()
        assertNull(original.snapshot())
    }

    @Test fun explicitSampleRejectionCannotBeRehabilitatedByMoreData() {
        val f = Fixture()
        f.begin(); f.cues(); f.capture.reject(f.track); f.cues(); f.end()
        assertNull(f.snapshot())
    }

    @Test fun scalarCompletionIsOnlyRealEosAndSnapshotIsCopiedAndSortedOnlyOnce() {
        val f = Fixture()
        assertFalse(f.capture.isComplete)
        f.begin(); f.cues()
        assertFalse(f.capture.isComplete)
        f.end()
        assertTrue(f.capture.isComplete)
        val original = requireNotNull(f.snapshot())
        assertSame(original, f.snapshot())
        assertTrue(f.capture.isCurrent(original))
    }

    @Test fun lookalikeAndForeignSnapshotsAreNotIssuedWitnesses() {
        val f = Fixture()
        f.begin(); f.cues(); f.end()
        val original = requireNotNull(f.snapshot())
        val lookalike = Media3EmbeddedReferenceCapture.Snapshot(f.load, original.track, original.occurrences, original.responseIdentity)
        assertFalse(f.capture.isCurrent(lookalike))
        val foreign = Fixture()
        foreign.begin(); foreign.cues(); foreign.end()
        assertFalse(f.capture.isCurrent(requireNotNull(foreign.snapshot())))
        assertTrue(f.capture.isCurrent(original))
    }

    @Test fun finalScalarWitnessDiesOnRetirementOrPostEosFormatChange() {
        val retired = Fixture()
        retired.begin(); retired.cues(); retired.end()
        val first = requireNotNull(retired.snapshot())
        retired.capture.retire()
        assertFalse(retired.capture.isComplete)
        assertFalse(retired.capture.isCurrent(first))
        val changed = Fixture()
        changed.begin(); changed.cues(); changed.end()
        val second = requireNotNull(changed.snapshot())
        changed.capture.format(changed.track, "real-container-track-id", "en", "application/x-subrip")
        assertFalse(changed.capture.isCurrent(second))
    }

    @Test fun completeExtractionIsNotAFabricatedSufficientTrackOrOwnerAdmission() {
        val f = Fixture()
        f.begin(); f.cues(7); f.end()
        assertTrue(f.capture.isComplete)
        assertNull(f.snapshot())
        f.live.set(false)
        assertFalse(f.capture.isComplete)
    }

    @Test fun noOriginalResponseOrUnfinishedOpenCanCertifyAReference() {
        val missing = Media3EmbeddedReferenceCapture(Any(), AtomicBoolean(true))
        val extractor = Any()
        assertTrue(missing.initialize(extractor))
        val track = requireNotNull(missing.track(extractor, 7))
        missing.format(track, "actual", "en", "application/x-subrip")
        missing.beginRead(extractor, 0)
        missing.sample(track, 1_000_000, 500_000, 8)
        missing.endRead(extractor, 10, Media3EmbeddedReferenceCapture.ReadResult.END_OF_INPUT)
        assertFalse(missing.isComplete)

        val pending = Media3EmbeddedReferenceCapture(Any(), AtomicBoolean(true))
        val source = Any()
        pending.dataSourceCreationStarted(); pending.dataSourceCreated(source)
        pending.responseOpened(source, 0, Media3EmbeddedReferenceCapture.UNBOUNDED_LENGTH)
        assertTrue(pending.initialize(extractor))
        pending.beginRead(extractor, 0)
        pending.endRead(extractor, 10, Media3EmbeddedReferenceCapture.ReadResult.END_OF_INPUT)
        assertFalse(pending.isComplete)
    }

    @Test fun reopenAfterEosInvalidatesIssuedWitnessEvenWhenOriginalCloseWasSafe() {
        val f = Fixture()
        f.begin(); f.cues(); f.end()
        val snapshot = requireNotNull(f.snapshot())
        f.capture.responseClosed(f.response)
        assertTrue(f.capture.isCurrent(snapshot))
        f.capture.responseOpened(f.response, 0, Media3EmbeddedReferenceCapture.UNBOUNDED_LENGTH)
        assertFalse(f.capture.isCurrent(snapshot))
        assertNull(f.snapshot())
    }

    @Test fun newCreationInvalidatesBeforeFactoryCanCallBackOrBindAnotherSource() {
        val f = Fixture()
        f.begin(); f.cues(); f.end()
        val snapshot = requireNotNull(f.snapshot())
        f.capture.dataSourceCreationStarted()
        assertFalse(f.capture.isCurrent(snapshot)) // Before any second factory callout or new source binding.
        f.capture.dataSourceCreated(Any())
        assertNull(f.snapshot())
    }

    @Test fun anotherBindingCannotReuseTheOriginalObjectAsANewResponse() {
        val f = Fixture()
        f.begin(); f.cues(); f.end()
        val snapshot = requireNotNull(f.snapshot())
        f.capture.dataSourceCreated(f.response)
        assertFalse(f.capture.isCurrent(snapshot))
    }

    @Test fun nonzeroAndBoundedResponseRequestsNeverEstablishWholeResourceEvidence() {
        for ((position, length) in listOf(1L to -1L, 0L to 1L, 0L to 0L, 0L to -2L)) {
            val load = Any()
            val capture = Media3EmbeddedReferenceCapture(load, AtomicBoolean(true))
            val source = Any()
            capture.dataSourceCreationStarted(); capture.dataSourceCreated(source)
            capture.responseOpened(source, position, length)
            capture.responseOpenSucceeded(source)
            val extractor = Any()
            assertFalse(capture.initialize(extractor))
            assertFalse(capture.isComplete)
        }
    }

    @Test fun closingPartialInputCannotBeRehabilitatedByLateEos() {
        val f = Fixture()
        f.begin(); f.cues(); f.end(20, Media3EmbeddedReferenceCapture.ReadResult.CONTINUE)
        f.capture.responseClosed(f.response)
        f.begin(20); f.end(20)
        assertNull(f.snapshot())
    }

    @Test fun completedOriginalResponseCanBeClosedIdempotentlyWithoutLosingExactWitness() {
        val f = Fixture()
        f.begin(); f.cues(); f.end()
        val snapshot = requireNotNull(f.snapshot())
        f.capture.responseClosed(f.response)
        f.capture.responseClosed(f.response)
        assertTrue(f.capture.isComplete)
        assertSame(f.response, snapshot.responseIdentity)
        assertTrue(f.capture.isCurrent(snapshot))
    }

    @Test fun foreignOpenOrCloseCannotCertifyOrPreserveTheOriginalResponse() {
        val opened = Fixture()
        opened.capture.responseOpened(Any(), 0, Media3EmbeddedReferenceCapture.UNBOUNDED_LENGTH)
        opened.begin(); opened.cues(); opened.end()
        assertNull(opened.snapshot())
        val closed = Fixture()
        closed.begin(); closed.cues(); closed.end()
        val snapshot = requireNotNull(closed.snapshot())
        closed.capture.responseClosed(Any())
        assertFalse(closed.capture.isCurrent(snapshot))
    }

    @Test fun scalarUnavailableDistinguishesPendingFromPermanentOptionalDenial() {
        val pending = Media3EmbeddedReferenceCapture(Any(), AtomicBoolean(true))
        assertFalse(pending.isComplete)
        assertFalse(pending.isUnavailable)
        pending.dataSourceCreationStarted()
        pending.dataSourceCreated(Any())
        assertFalse(pending.isUnavailable)
        pending.fail()
        assertTrue(pending.isUnavailable)
        assertFalse(pending.isComplete)
        val owner = Fixture()
        assertFalse(owner.capture.isUnavailable)
        owner.live.set(false)
        assertTrue(owner.capture.isUnavailable)
    }
}
