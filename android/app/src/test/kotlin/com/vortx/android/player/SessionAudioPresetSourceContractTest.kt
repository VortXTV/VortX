package com.vortx.android.player

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Source-bound regression fences complement the actual native synthetic-mpv transaction harness. */
class SessionAudioPresetSourceContractTest {
    @Test fun `enum only JNI bridge serializes transaction and competing AF load output mutators`() {
        val seam = source("mpv-seam/src/main/kotlin/com/vortx/android/player/mpv/seam/MpvSeam.kt")
        val bridge = seam.substringAfter("fun setSessionAudioPreset(").substringBefore("fun setOptionString(")
        assertTrue(bridge.contains("preset: Int, expectedEntryID: Long"))
        assertTrue(bridge.contains("preset !in 0..2 || expectedEntryID < 0L"))
        assertTrue(bridge.contains("withSerializedHandle(audioFilterLock"))
        assertTrue(bridge.contains("catch (_: UnsatisfiedLinkError)"))
        assertFalse(bridge.contains("filter: String"))
        assertTrue(seam.contains("withSerializedHandle(audioFilterLock, Unit) { instance -> nativeCommand"))
        assertTrue(seam.contains("withSerializedHandle(audioFilterLock, -1L)"))
        assertTrue(seam.contains("withSerializedHandle(audioFilterLock, NATIVE_CALL_UNAVAILABLE)"))
        val stringSetter = seam.substringAfter("fun setPropertyString(property: String, value: String)")
            .substringBefore("private external fun nativeSetPropertyString")
        assertTrue(stringSetter.contains("withSerializedHandle(audioFilterLock, Unit)"))
        assertFalse(stringSetter.contains("withHandle(Unit)"))
    }

    @Test fun `load identity and release admission surround native call and checked publication`() {
        val player = source("app/src/full/kotlin/com/vortx/android/player/mpv/MpvPlayer.kt")
        val setter = player.substringAfter("override fun setSessionAudioPreset(")
            .substringBefore("private fun applySessionAudioPresetLocked(")
        assertTrue(setter.contains("synchronized(subtitleGenerationGate)"))
        val transaction = player.substringAfter("private fun applySessionAudioPresetLocked(")
            .substringBefore("private fun reconcileSessionAudioPresetLocked()")
        assertOrdered(transaction, "metadataLoadIdentity.capture", "mpv.setSessionAudioPreset",
            "metadataLoadIdentity.accepts", "sessionAudioPreset.receive")
        val release = player.substringAfter("override fun release()")
            .substringBefore("private fun refreshTracks(")
        assertOrdered(release, "synchronized(subtitleGenerationGate)", "released.compareAndSet",
            "sessionAudioPreset.reset()", "mpv.destroy()")
        assertTrue(player.contains("if (audioPresetReconciledRead == read) return false"))
        assertTrue(player.contains("return applySessionAudioPresetLocked(sessionAudioPreset.wanted)"))
        val fileLoaded = player.substringAfter("MPVLib.Event.FILE_LOADED ->")
            .substringBefore("MPVLib.Event.VIDEO_RECONFIG")
        assertTrue(fileLoaded.contains("metadataLoadIdentity.loaded()"))
        assertTrue(fileLoaded.contains("reconcileSessionAudioPresetLocked()"))
        val commandReturn = player.substringAfter("val metadataEntryID = mpv.loadFileWithEntryID")
            .substringBefore("refreshTracks(rearmHealth = false, metadataOnly = true)")
        assertTrue(commandReturn.contains("metadataLoadIdentity.commandReturned"))
        assertTrue(commandReturn.contains("reconcileSessionAudioPresetLocked()"))
    }

    @Test fun `passthrough cleanup precedes output writes and preference commit`() {
        val player = source("app/src/full/kotlin/com/vortx/android/player/mpv/MpvPlayer.kt")
        val output = player.substringAfter("override fun trySetAudioOutputMode(")
            .substringBefore("override fun setSessionAudioPreset(")
        assertOrdered(output, "applySessionAudioPresetLocked(SessionAudioPreset.NORMAL)",
            "for ((name, value) in properties)", "audioPresetReconciledRead = null",
            "if (!reconcileSessionAudioPresetLocked()) return false")
        assertTrue(output.contains("return false"))
        val screen = source("app/src/main/kotlin/com/vortx/android/player/PlayerScreen.kt")
        val selection = screen.substringAfter("onSelectAudioOutputMode = { mode ->").substringBefore("controlsVisible =")
        assertOrdered(selection, "engine.trySetAudioOutputMode(mode)", "AudioOutputMode.setCurrent(context, mode)")
        assertFalse(selection.contains("engine.setAudioOutputMode(mode)"))
        val automatic = player.substringAfter("override fun setAudioOutputMode(")
            .substringBefore("override fun trySetAudioOutputMode(")
        assertOrdered(automatic, "metadataLoadIdentity.capture", "pendingAudioOutputMode.defer(mode)",
            "applyAudioOutputModeLocked(mode)")
        assertOrdered(output, "for ((name, value) in properties)", "pendingAudioOutputMode.clear()",
            "reconcileSessionAudioPresetLocked()")
        val reconcile = player.substringAfter("private fun reconcileSessionAudioPresetLocked()")
            .substringBefore("private fun publishSessionAudioPresetLocked()")
        assertOrdered(reconcile, "metadataLoadIdentity.capture", "pendingAudioOutputMode.take()",
            "audioPresetReconciledRead == read", "applySessionAudioPresetLocked(sessionAudioPreset.wanted)")
        val release = player.substringAfter("override fun release()").substringBefore("private fun refreshTracks(")
        assertOrdered(release, "released.compareAndSet", "pendingAudioOutputMode.clear()", "mpv.destroy()")
    }

    @Test fun `shared Audio Settings contains presets without changing fixed controls or Media3 DSP`() {
        val chrome = source("app/src/main/kotlin/com/vortx/android/player/PlayerChrome.kt")
        val audioSettings = chrome.substringAfter("ControlSheet.AUDIO_SETTINGS ->")
            .substringBefore("ControlSheet.SPEED ->")
        assertTrue(audioSettings.contains("sessionAudioPresetOptions(sessionAudioPreset, onSelectSessionAudioPreset)"))
        assertTrue(chrome.contains("R.string.player_audio_preset_media3_unavailable"))
        assertTrue(chrome.contains("enabled = state.canSelect(preset)"))
        assertTrue(chrome.contains("state.selected == preset"))
        val media3 = source("app/src/main/kotlin/com/vortx/android/player/ExoPlayerEngine.kt")
        assertFalse(media3.contains("override fun setSessionAudioPreset"))
        assertFalse(media3.contains("SessionAudioPreset.NORMAL"))
    }

    @Test fun `option JNI acquisitions refuse invalid input and release first chars on second failure`() {
        val cpp = source("mpv-seam/src/main/cpp/property.cpp")
        val setter = cpp.substringAfter("jni_func(jint, nativeSetOptionString, jlong instance, jstring joption, jstring jvalue) {")
            .substringBefore("static int common_get_property")
        assertTrue(setter.contains("if (!mpv_instance || !mpv_instance->mpv)"))
        assertTrue(setter.contains("return MPV_ERROR_UNINITIALIZED;"))
        assertFalse(setter.contains("return 0;"))
        assertOrdered(setter, "if (!joption || !jvalue)", "return MPV_ERROR_INVALID_PARAMETER;",
            "GetStringUTFChars(joption, nullptr)", "if (!option || env->ExceptionCheck()) {",
            "GetStringUTFChars(jvalue, nullptr)", "if (!value || env->ExceptionCheck()) {")
        val firstFailure = setter.substringAfter("if (!option || env->ExceptionCheck()) {").substringBefore("}")
        assertOrdered(firstFailure, "if (option)", "ReleaseStringUTFChars(joption, option)", "return MPV_ERROR_NOMEM;")
        assertFalse(firstFailure.contains("GetStringUTFChars(jvalue"))
        val secondFailure = setter.substringAfter("if (!value || env->ExceptionCheck()) {").substringBefore("}")
        assertOrdered(secondFailure, "if (value)", "ReleaseStringUTFChars(jvalue, value)",
            "ReleaseStringUTFChars(joption, option)", "return MPV_ERROR_NOMEM;")
        assertTrue(secondFailure.contains("return MPV_ERROR_NOMEM;"))
        assertFalse(secondFailure.contains("mpv_set_option_string"))
        assertFalse(secondFailure.contains("strcmp"))
        assertFalse(secondFailure.contains("return 0"))
        assertOrdered(setter, "GetStringUTFChars(jvalue, nullptr)", "if (!value || env->ExceptionCheck()) {",
            "int result = mpv_set_option_string", "std::strcmp(option, \"af\")")
        assertFalse(setter.contains("ExceptionClear"))
    }

    @Test fun `command JNI stops before native use on failed lookup or chars and cleans only acquired resources`() {
        val cpp = source("mpv-seam/src/main/cpp/main.cpp")
        val command = cpp.substringAfter("jni_func(void, nativeCommand, jlong instance, jobjectArray jarray) {")
        assertTrue(command.contains("if (!mpv_instance || !mpv_instance->mpv)"))
        assertOrdered(command, "if (!jarray || env->ExceptionCheck())", "GetArrayLength(jarray)",
            "if (len >= ARRAYLEN(arguments))", "const auto releaseArguments", "GetObjectArrayElement(jarray, i)",
            "if (env->ExceptionCheck() || !stringRefs[i])", "GetStringUTFChars(stringRefs[i], nullptr)",
            "if (env->ExceptionCheck() || !arguments[i])", "const int status = mpv_command",
            "command_may_replace_af(arguments, len)")
        val cleanup = command.substringAfter("const auto releaseArguments = [&]() {").substringBefore("};")
        assertOrdered(cleanup, "if (arguments[i])", "ReleaseStringUTFChars(stringRefs[i], arguments[i])",
            "if (stringRefs[i])", "DeleteLocalRef(stringRefs[i])")
        listOf("if (env->ExceptionCheck() || !stringRefs[i]) {",
            "if (env->ExceptionCheck() || !arguments[i]) {").forEach { guard ->
            val branch = command.substringAfter(guard).substringBefore("}")
            assertOrdered(branch, "releaseArguments();", "return;")
            assertFalse(branch.contains("mpv_command"))
            assertFalse(branch.contains("strcmp"))
        }
        assertFalse(command.contains("ExceptionClear"))
        assertTrue(command.contains("const char *arguments[128] = { nullptr };"))
    }

    private fun assertOrdered(text: String, vararg anchors: String) {
        var after = -1
        anchors.forEach { anchor ->
            val index = text.indexOf(anchor)
            assertTrue("Missing production anchor: $anchor", index >= 0)
            assertTrue("Out-of-order production anchor: $anchor", index > after)
            after = index
        }
    }

    private fun source(path: String): String = listOf(File(path), File("../$path"), File("android/$path"))
        .firstOrNull { it.isFile }?.readText() ?: error("Required production source is missing: $path")
}
