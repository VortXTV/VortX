package com.vortx.android.player

import android.media.AudioManager
import org.junit.Assert.assertEquals
import org.junit.Test

/// The audio-focus decision core (AudioFocusPolicy.kt). Pure JVM: the AudioManager AUDIOFOCUS_*
/// values are compile-time-inlined int constants, so no Android runtime is touched.
///
/// NOTE (test toolchain): the module has no unit-test infrastructure yet; these tests need the
/// standard `testImplementation` JUnit line in app/build.gradle.kts (owned by the build lane) before
/// `./gradlew testFullDebugUnitTest` can compile them. They do not affect assemble* tasks.
class AudioFocusPolicyTest {

    @Test
    fun `transient loss while playing pauses then gain resumes`() {
        val policy = AudioFocusPolicy()
        assertEquals(
            AudioFocusPolicy.Action.PAUSE,
            policy.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, isPaused = false),
        )
        assertEquals(
            AudioFocusPolicy.Action.RESUME,
            policy.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, isPaused = true),
        )
    }

    @Test
    fun `duck-class transient loss behaves as pause then resume`() {
        val policy = AudioFocusPolicy()
        assertEquals(
            AudioFocusPolicy.Action.PAUSE,
            policy.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK, isPaused = false),
        )
        assertEquals(
            AudioFocusPolicy.Action.RESUME,
            policy.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, isPaused = true),
        )
    }

    @Test
    fun `gain never resumes a viewer-paused film`() {
        val policy = AudioFocusPolicy()
        // Viewer paused first; the interruption then lands over an already-paused engine.
        assertEquals(
            AudioFocusPolicy.Action.NONE,
            policy.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, isPaused = true),
        )
        // The interruption ends: the viewer's pause must hold.
        assertEquals(
            AudioFocusPolicy.Action.NONE,
            policy.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, isPaused = true),
        )
    }

    @Test
    fun `permanent loss pauses and never auto-resumes`() {
        val policy = AudioFocusPolicy()
        assertEquals(
            AudioFocusPolicy.Action.PAUSE,
            policy.onFocusChange(AudioManager.AUDIOFOCUS_LOSS, isPaused = false),
        )
        assertEquals(
            AudioFocusPolicy.Action.NONE,
            policy.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, isPaused = true),
        )
    }

    @Test
    fun `permanent loss clears an armed transient resume`() {
        val policy = AudioFocusPolicy()
        // Transient arms the resume latch...
        policy.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, isPaused = false)
        // ...but a permanent handover before the gain revokes it.
        assertEquals(
            AudioFocusPolicy.Action.NONE,
            policy.onFocusChange(AudioManager.AUDIOFOCUS_LOSS, isPaused = true),
        )
        assertEquals(
            AudioFocusPolicy.Action.NONE,
            policy.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, isPaused = true),
        )
    }

    @Test
    fun `gain without any prior loss does nothing`() {
        val policy = AudioFocusPolicy()
        assertEquals(
            AudioFocusPolicy.Action.NONE,
            policy.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, isPaused = false),
        )
    }

    @Test
    fun `unknown focus code does nothing`() {
        val policy = AudioFocusPolicy()
        assertEquals(AudioFocusPolicy.Action.NONE, policy.onFocusChange(Int.MIN_VALUE, isPaused = false))
    }

    @Test
    fun `resume latch is consumed by the gain that used it`() {
        val policy = AudioFocusPolicy()
        policy.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, isPaused = false)
        assertEquals(
            AudioFocusPolicy.Action.RESUME,
            policy.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, isPaused = true),
        )
        // A second gain (focus flapping) must not double-fire.
        assertEquals(
            AudioFocusPolicy.Action.NONE,
            policy.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, isPaused = false),
        )
    }
}
