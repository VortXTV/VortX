package com.vortx.android.player

import java.io.File
import org.junit.Assert.*
import org.junit.Test

/** Actual source joins only: no Android/Media3/native execution is implied. */
class PlaybackOwnerWiringTest {
    @Test fun mountedPhoneAndTvPlayerCaptureOnceUnderOriginalAccountAndProfileBeforeAsyncBuild() {
        val screen = appSource("main", "player/PlayerScreen.kt")
        val capture = screen.substringAfter("val originalPlaybackOwner = remember {")
            .substringBefore("val currentSubtitleSessionKey")
        assertTrue(capture.contains("capturePlaybackOwner("))
        assertTrue(capture.contains("val original = originalOwnerCandidate"))
        assertTrue(screen.indexOf("val originalOwnerCandidate = remember { PlaybackOwnerEpoch.capture() }") <
            screen.indexOf("val subtitleApplication ="))
        assertTrue(capture.contains("accountAdmission = subtitleAccountAdmission"))
        val profile = appSource("main", "profile/ProfileStore.kt")
        val original = profile.substringAfter("internal fun capturePlaybackOwner(")
            .substringBefore("val activeKeychainAccount")
        assertTrue(original.contains("ContinueWatchingOwnerGate.serialized"))
        assertTrue(original.contains("revision != expectedRevision"))
        assertTrue(original.contains("accountAdmission?.invoke(captureOnly)"))
        assertTrue(original.contains("original.takeIf { com.vortx.android.player.PlaybackOwnerEpoch.isCurrent(it) }"))
        assertFalse(original.contains("PlaybackOwnerEpoch.capture()"))
        assertTrue(original.contains("profiles != projection.profiles || activeID != projection.activeID"))
        assertTrue(original.contains("gateway.withProjection(projection) { captureAccount() }"))
        assertFalse(screen.contains("remember(playbackSessionKey) { PlaybackOwnerEpoch.capture()"))
        assertEquals(3, Regex("bindPlaybackOwner\\(original\\)").findAll(screen).count())
        assertTrue(screen.contains("while (originalPlaybackOwner?.isActive == true) delay(100L)"))
        val cleanupEffect = screen.indexOf("LaunchedEffect(originalPlaybackOwner, engineHolder)")
        val originalDeclaration = screen.indexOf("val originalPlaybackOwner = remember {")
        val releaseDeclaration = screen.indexOf("fun releaseBoundEngine()")
        val buildEffect = screen.indexOf("LaunchedEffect(playbackSessionKey, forceExoPlayer, enginePreference)")
        assertTrue(originalDeclaration >= 0 && releaseDeclaration > originalDeclaration)
        assertTrue(cleanupEffect > releaseDeclaration && buildEffect > cleanupEffect)
        assertTrue(screen.contains("if (original.isActive) {"))
        assertTrue(screen.contains("if (!isActive || !original.isActive)"))
        assertTrue(screen.contains("resourceReleaseGate.decoderReleased()"))
    }

    @Test fun mpvActualFinalReceiptAndWholeNativeHandleAdmissionRetainThatSameOriginalLifetime() {
        val mpv = appSource("full", "player/mpv/MpvPlayer.kt")
        val bind = mpv.substringAfter("override fun bindPlaybackOwner(").substringBefore("// Metadata only")
        assertTrue(bind.contains("originalPlaybackOwner != null"))
        assertTrue(bind.contains("mpv.bindOriginalOwner(original.nativeLiveness)"))
        val finalCheck = mpv.substringAfter("private fun isSubtitleSelectionCurrentLocked(")
            .substringBefore("override fun selectSubtitleTrack(id: Int?, request:")
        assertTrue(finalCheck.contains("originalPlaybackOwner?.isActive == true"))
        assertTrue(finalCheck.contains("subtitleSelections.isCurrent(request)"))
        val gate = seamSource("MpvNativeHandleGate.kt")
        assertTrue(gate.contains("originalOwnerLiveness != null"))
        assertTrue(gate.contains("originalOwnerLiveness?.get() == false"))
        assertFalse(gate.contains("PlaybackOwnerEpoch.capture"))
        assertTrue(appSource("full", "player/mpv/MPVLib.kt").contains("delegate.bindOriginalOwner(liveness)"))
        assertTrue(seamSource("MpvSeam.kt").contains("handleGate?.bindOriginalOwner(liveness) == true"))
    }

    @Test fun media3RejectsRenewalAndOldOwnerOnBothInitialAndPrivateRemount() {
        val exo = appSource("main", "player/ExoPlayerEngine.kt")
        val bind = exo.substringAfter("override fun bindPlaybackOwner(").substringBefore("private val listener")
        assertTrue(bind.contains("originalPlaybackOwner != null"))
        assertTrue(bind.contains("originalPlaybackOwner = original"))
        assertTrue(bind.contains("return original.isActive"))
        val load = exo.substringAfter("override fun load(playable: Playable)")
            .substringBefore("// yt-direct")
        assertTrue(Regex("originalPlaybackOwner\\?\\.isActive != true").findAll(load).count() >= 2)
        val finalCheck = exo.substringAfter("override fun isSubtitleSelectionCurrent(")
            .substringBefore("override fun selectSubtitleTrack(id: Int?, request:")
        assertTrue(finalCheck.contains("originalPlaybackOwner?.isActive == true"))
        assertTrue(finalCheck.contains("subtitleSelections.isCurrent(request)"))
    }

    @Test fun actualAccountGenerationPersistenceRestoreAndUnknownPublicationRevokePlayback() {
        val sync = appSource("main", "sync/VortXSyncManager.kt")
        val durable = sync.substringAfter("internal class DurableSessionState<").substringBefore("internal sealed interface SessionOwnerSnapshot")
        assertTrue(Regex("PlaybackOwnerEpoch.transition").findAll(durable).count() == 2)
        assertFalse(durable.substringAfter("fun restore(").substringBefore("/**").contains("PlaybackOwnerEpoch"))
        val coordinator = sync.substringAfter("internal class SessionOperationCoordinator")
            .substringBefore("internal class SyncSessionLease")
        assertTrue(Regex("PlaybackOwnerEpoch.transition").findAll(coordinator).count() == 2)
        val restore = sync.substringAfter("internal fun sessionOwnerSnapshot()").substringBefore("fun retrySessionRestore")
        assertTrue(Regex("PlaybackOwnerEpoch.transition").findAll(restore).count() == 3)
        assertTrue(restore.contains("if (_sessionUiState.value != SessionUiState.UnknownOrUnavailable)"))
        assertTrue(restore.contains("!sessionTruthMatches(live, persisted) || sessionState.ownerEpoch != persistedOwnerEpoch"))
        assertTrue(sync.contains("if (!persist(candidate, nextOwnerEpoch))"))
        assertTrue(sync.contains("if (!clearDurably(nextOwnerEpoch))"))
    }

    @Test fun actualProfileAndNativeAuthorityCallbacksOnlyRevokeNotCallPlayerOrWaitForIt() {
        val gate = appSource("main", "profile/ContinueWatchingOwnerGate.kt")
        assertFalse(gate.contains("PlaybackOwnerEpoch"))
        val app = appSource("main", "VortXApplication.kt")
        val callback = app.substringAfter("onAuthorityChanged =").substringBefore("onProgressMutation =")
        assertFalse(callback.contains("PlaybackOwnerEpoch"))
        assertFalse(callback.contains("releaseBoundEngine"))
        assertFalse(callback.contains("mpv."))
        assertTrue(app.contains("if (field !== value) com.vortx.android.player.PlaybackOwnerEpoch.transition { field = value }"))
        val session = appSource("main", "engine/VortxNativeSession.kt")
        val uncertain = session.substringAfter("private fun commitCheckpoint(").substringBefore("private fun checkpoint(")
        assertTrue(uncertain.contains("PlaybackOwnerEpoch.invalidate()"))
        val profile = appSource("main", "profile/ProfileStore.kt")
        val setters = profile.substringAfter("var profiles: List<UserProfile>").substringBefore("private val _activeProfile")
        assertTrue(setters.contains("captureActiveProfileBinding(field, activeID) != captureActiveProfileBinding(value, activeID)"))
        assertTrue(setters.contains("if (field != value) com.vortx.android.player.PlaybackOwnerEpoch.transition"))
        val auth = appSource("main", "engine/ContinueWatchingAuthTransition.kt")
        assertTrue(auth.substringAfter("fun begin()").substringBefore("fun finish(").contains("PlaybackOwnerEpoch.invalidate()"))
    }

    @Test fun ordinaryProgressAndTypedReceiveUseExactBindingClassificationNotGenericResourceNotification() {
        val app = appSource("main", "VortXApplication.kt")
        assertTrue(app.contains("onProgressMutation = { origin ->"))
        assertTrue(app.contains("onLocalNativeMutation(origin, progressOnly = true)"))
        val sync = appSource("main", "sync/VortXSyncManager.kt")
        assertTrue(sync.contains("gateway.applyRawDocument(account, originalRaw)"))
        val native = appSource("main", "engine/VortxNativeSession.kt")
        val receive = native.substringAfter("fun receiveOwnerHistory(").substringBefore("@Synchronized", "")
        assertTrue(receive.contains("changesPlaybackOwner = nativePlaybackOwnerChanged(originalPlaybackState, state)"))
        assertTrue(receive.contains("if (changesPlaybackOwner) com.vortx.android.player.PlaybackOwnerEpoch.invalidate()"))
        assertTrue(receive.contains("invalidate(); changes.value += 1")) // Existing resource invalidation stays.
        val stateGate = appSource("main", "player/PlayerScreen.kt")
            .substringAfter("fun withCurrentSubtitleOwnerState(").substringBefore("fun withCurrentSubtitleOwner(")
        assertFalse(stateGate.contains("revision == subtitleProfileRevision"))
        assertTrue(stateGate.contains("original.isActive && action()"))
        assertTrue(stateGate.contains("subtitleAccountAdmission?.invoke(validateAndMutateState)"))
        assertFalse(stateGate.contains("PlaybackOwnerEpoch.capture"))
    }

    @Test fun actualMountAndCertifiedMainCredentialTransactionsRevokeBeforePublicationWithoutPlayerCallbacks() {
        val coordinator = appSource("main", "engine/NativeAccountCoordinator.kt")
        val retire = coordinator.substringAfter("override fun retire()").substringBefore("override fun currentMountToken")
        val retireRevoke = retire.indexOf("PlaybackOwnerEpoch.invalidate()")
        assertTrue(retireRevoke >= 0 && retire.indexOf("mounted.getAndSet(null)") > retireRevoke)
        val publish = coordinator.substringAfter("private suspend fun publish(").substringBefore("override suspend fun applyDocument(")
        val publishRevoke = publish.indexOf("PlaybackOwnerEpoch.invalidate()")
        assertTrue(publishRevoke >= 0 && publish.indexOf("mounted.compareAndSet(null, next)") > publishRevoke)
        val credentials = appSource("main", "engine/NativeOwnAccountCredentials.kt")
        val commit = credentials.substringAfter("private fun commitOwnerSelection(").substringBefore("fun selectOwner(")
        val credentialRevoke = commit.indexOf("PlaybackOwnerEpoch.invalidate()")
        assertTrue(credentialRevoke >= 0 && commit.indexOf("write(selector, raw)") > credentialRevoke)
        assertFalse(commit.contains("release("))
        assertFalse(commit.contains("mpv."))
    }

    @Test fun constructionIsReservedBeforeDispatchAndAllCleanupEffectsExistWhileConnecting() {
        val screen = appSource("main", "player/PlayerScreen.kt")
        val build = screen.substringAfter("LaunchedEffect(playbackSessionKey, forceExoPlayer, enginePreference) {")
            .substringBefore("DisposableEffect(playbackSessionKey, forceExoPlayer, enginePreference)")
        assertTrue(build.indexOf("resourceReleaseGate.beginConstruction()") < build.indexOf("withContext(Dispatchers.Default + NonCancellable)"))
        assertTrue(build.contains("finally {\n                resourceReleaseGate.endConstruction()"))
        assertFalse(build.contains("Handler("))
        assertEquals(3, Regex("if \\(!resourceReleaseGate.decoderBound\\(\\)\\)").findAll(build).count())
        assertEquals(3, Regex("engineHolder.set\\(it\\)").findAll(build).count())
        val expose = build.split("engineHolder.set(it)")
        assertTrue(expose.take(3).all { it.substringAfterLast("MpvEngineFactory.create").contains("if (!resourceReleaseGate.decoderBound())") })
        val connecting = screen.indexOf("if (engine == null)")
        assertTrue(connecting >= 0)
        assertTrue(screen.indexOf("onDispose { resourceReleaseGate.sessionDisposed() }") in 0 until connecting)
        assertTrue(screen.indexOf("DisposableEffect(currentPlayable.playbackLease)") in 0 until connecting)
        assertEquals(1, Regex("onDispose \\{ resourceReleaseGate.sessionDisposed\\(\\) \\}").findAll(screen).count())
    }

    @Test fun hotCheckpointClassificationReusesTheExactOriginalRuntimeAndValidatedCandidate() {
        val native = appSource("main", "engine/VortxNativeSession.kt")
        assertEquals(3, Regex("PlaybackCheckpointState\\(originalRuntime, originalRevision, candidate, updated, prior, state\\)").findAll(native).count())
        val dispatch = native.substringAfter("fun dispatch(actions:").substringBefore("/** Same-UID")
        assertTrue(dispatch.contains("val before = originalRuntime.stateJson()"))
        assertTrue(dispatch.contains("val candidate = originalRuntime.fork()"))
        assertEquals(1, Regex("JSONObject\\(before\\)").findAll(dispatch).count())
        assertTrue(dispatch.indexOf("val prior = JSONObject(before)") < dispatch.indexOf("beforeCommit()"))
        assertTrue(dispatch.contains("commitCheckpoint(updated, candidate, hostArchive, playbackState)"))
        val commit = native.substringAfter("private fun commitCheckpoint(").substringBefore("private fun checkpoint(")
        val fast = commit.substringAfter("} else {").substringBefore("if (changesPlaybackOwner)")
        assertTrue(fast.contains("playbackState.originalRuntime === runtime"))
        assertTrue(fast.contains("playbackState.originalRevision == revision"))
        assertTrue(fast.contains("playbackState.candidate === candidate"))
        assertTrue(fast.contains("playbackState.serialized === snapshot"))
        assertTrue(fast.contains("nativePlaybackOwnerChanged(playbackState.original, playbackState.validated)"))
        assertFalse(fast.contains("JSONObject("))
        assertFalse(fast.contains("stateJson("))
        assertTrue(commit.substringBefore("} else {").contains("nativePlaybackOwnerChanged(JSONObject(runtime.stateJson()), JSONObject(snapshot))"))
    }

    @Test fun typedReceiveRetainsItsOriginalAlreadyReadStateRatherThanReSerializingItForClassification() {
        val native = appSource("main", "engine/VortxNativeSession.kt")
        val receive = native.substringAfter("fun receiveOwnerHistory(").substringBefore("fun resolve(")
        assertTrue(receive.contains("val originalPlaybackRead = read()"))
        assertTrue(receive.contains("owned(originalPlaybackRead.owner)"))
        assertTrue(receive.contains("val originalPlaybackState = originalPlaybackRead.state"))
        assertFalse(receive.contains("JSONObject(oldRuntime.stateJson())"))
        assertTrue(receive.contains("changesPlaybackOwner = nativePlaybackOwnerChanged(originalPlaybackState, state)"))
    }

    private fun appSource(flavor: String, name: String): String = locate(
        "android/app/src/$flavor/kotlin/com/vortx/android/$name",
        "app/src/$flavor/kotlin/com/vortx/android/$name",
        "src/$flavor/kotlin/com/vortx/android/$name",
    )
    private fun seamSource(name: String): String = locate(
        "android/mpv-seam/src/main/kotlin/com/vortx/android/player/mpv/seam/$name",
        "mpv-seam/src/main/kotlin/com/vortx/android/player/mpv/seam/$name",
        "../mpv-seam/src/main/kotlin/com/vortx/android/player/mpv/seam/$name",
    )
    private fun locate(vararg paths: String): String = paths.map(::File).firstOrNull(File::isFile)?.readText()
        ?: error("Actual maintained source missing")
}
