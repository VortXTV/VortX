package com.vortx.android.player

import android.view.KeyEvent
import com.vortx.android.model.Episode
import com.vortx.android.model.MediaRef

internal enum class PlayerKeyboardShortcut(val repeats: Boolean = false) {
    TOGGLE_PLAYBACK,
    SEEK_BACK(repeats = true),
    SEEK_FORWARD(repeats = true),
    SEEK_PERCENT,
    VOLUME_UP(repeats = true),
    VOLUME_DOWN(repeats = true),
    TOGGLE_MUTE,
    PREFERRED_SUBTITLE,
    AUDIO_MENU,
    SUBTITLE_MENU,
    SLOWER,
    FASTER,
    NEXT_ASPECT,
    PLAYBACK_INFO,
    PICTURE_IN_PICTURE,
    SKIP_SEGMENT,
    PREVIOUS_EPISODE,
    NEXT_EPISODE,
}

/** Only an unambiguous neighbour from the in-player season picker may be opened. */
internal fun adjacentKeyboardEpisode(episodes: List<Episode>, current: MediaRef?, next: Boolean): Episode? {
    val choices = playerEpisodeChoices(episodes, current)
    val selected = choices.indices.singleOrNull { choices[it].selected } ?: return null
    val index = selected + if (next) 1 else -1
    val neighbour = choices.getOrNull(index)?.episode ?: return null
    return neighbour.takeIf { target -> choices.count { it.episode.episode == target.episode } == 1 }
}

/** Android TV reserves its directional keys for focus, including when an actual keyboard sends them. */
internal fun playerKeyboardShortcut(
    keyCode: Int,
    fromKeyboard: Boolean,
    unmodified: Boolean,
    alphabeticKeyboard: Boolean,
    isTvPlayer: Boolean,
): PlayerKeyboardShortcut? {
    if (!fromKeyboard || !unmodified || !alphabeticKeyboard) return null
    return when (keyCode) {
        KeyEvent.KEYCODE_SPACE, KeyEvent.KEYCODE_K -> PlayerKeyboardShortcut.TOGGLE_PLAYBACK
        KeyEvent.KEYCODE_J -> PlayerKeyboardShortcut.SEEK_BACK
        KeyEvent.KEYCODE_L -> PlayerKeyboardShortcut.SEEK_FORWARD
        KeyEvent.KEYCODE_DPAD_LEFT -> PlayerKeyboardShortcut.SEEK_BACK.takeUnless { isTvPlayer }
        KeyEvent.KEYCODE_DPAD_RIGHT -> PlayerKeyboardShortcut.SEEK_FORWARD.takeUnless { isTvPlayer }
        in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9 -> PlayerKeyboardShortcut.SEEK_PERCENT
        KeyEvent.KEYCODE_DPAD_UP -> PlayerKeyboardShortcut.VOLUME_UP.takeUnless { isTvPlayer }
        KeyEvent.KEYCODE_DPAD_DOWN -> PlayerKeyboardShortcut.VOLUME_DOWN.takeUnless { isTvPlayer }
        KeyEvent.KEYCODE_M -> PlayerKeyboardShortcut.TOGGLE_MUTE
        KeyEvent.KEYCODE_C -> PlayerKeyboardShortcut.PREFERRED_SUBTITLE
        KeyEvent.KEYCODE_A -> PlayerKeyboardShortcut.AUDIO_MENU
        KeyEvent.KEYCODE_T -> PlayerKeyboardShortcut.SUBTITLE_MENU
        KeyEvent.KEYCODE_LEFT_BRACKET -> PlayerKeyboardShortcut.SLOWER
        KeyEvent.KEYCODE_RIGHT_BRACKET -> PlayerKeyboardShortcut.FASTER
        KeyEvent.KEYCODE_V -> PlayerKeyboardShortcut.NEXT_ASPECT
        KeyEvent.KEYCODE_I -> PlayerKeyboardShortcut.PLAYBACK_INFO
        KeyEvent.KEYCODE_O -> PlayerKeyboardShortcut.PICTURE_IN_PICTURE
        KeyEvent.KEYCODE_S -> PlayerKeyboardShortcut.SKIP_SEGMENT
        KeyEvent.KEYCODE_P -> PlayerKeyboardShortcut.PREVIOUS_EPISODE
        KeyEvent.KEYCODE_N -> PlayerKeyboardShortcut.NEXT_EPISODE
        else -> null
    }
}

internal fun playerKeyboardShortcutHints(
    isTvPlayer: Boolean,
    episodeShortcutsAvailable: Boolean,
    pictureInPictureAvailable: Boolean,
): List<Pair<String, String>> = buildList {
    add("Play or pause" to "Space / K")
    add("Seek back or forward" to if (isTvPlayer) "J / L" else "J / L or ← / →")
    add("Jump to 0–90%" to "0–9")
    if (!isTvPlayer) add("Adjust volume" to "↑ / ↓")
    add("Mute or unmute" to "M")
    add("Toggle preferred subtitles" to "C")
    add("Open subtitle controls" to "T")
    add("Open audio tracks" to "A")
    add("Skip intro, recap or credits" to "S")
    if (episodeShortcutsAvailable) add("Previous or next episode in this season" to "P / N")
    add("Decrease or increase speed" to "[ / ]")
    add("Cycle aspect ratio" to "V")
    add("Open playback info" to "I")
    if (pictureInPictureAvailable) add("Enter picture in picture" to "O")
}
