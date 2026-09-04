package com.vortx.android.player

import com.vortx.android.model.Playable
import com.vortx.android.model.StreamSource

/** One truthful, session-only player choice shown before a detail-page launch. */
internal data class PlayerLaunchChoice(
    val preference: PlayerEngineRouter.Override,
    val label: String,
    val detail: String,
)

/**
 * Keeps detail-page player choices aligned with the installed flavor and resolves compatibility before the
 * player mounts. This policy never persists a choice: the shell carries its result only for the active title
 * launch, leaving device/global playback defaults untouched.
 */
internal object PlayerLaunchPolicy {
    fun choices(mpvAvailable: Boolean): List<PlayerLaunchChoice> = buildList {
        if (mpvAvailable) {
            add(
                PlayerLaunchChoice(
                    preference = PlayerEngineRouter.Override.AUTO,
                    label = "Automatic",
                    detail = "VortX by default; Media3 for Dolby Vision, Atmos, or safe fallback",
                ),
            )
            add(
                PlayerLaunchChoice(
                    preference = PlayerEngineRouter.Override.MPV,
                    label = "VortX Player",
                    detail = "Built-in mpv; falls back to Media3 only if VortX cannot start",
                ),
            )
        }
        add(
            PlayerLaunchChoice(
                preference = PlayerEngineRouter.Override.EXOPLAYER,
                label = "Media3",
                detail = if (mpvAvailable) {
                    "Android codec player; torrent launches use the compatible VortX route"
                } else {
                    "Android codec player included in this edition"
                },
            ),
        )
    }

    /**
     * Explicit engines a viewer may request for one already-selected source. The main detail selector owns
     * Automatic; a source-row action must name a concrete player. Full-flavor torrents stay mpv-only because
     * their loopback warm-up contract cannot be handed to Media3. The resolved [Playable] is still checked by
     * [effectivePreference] at the shell boundary, so this is an honest early menu gate rather than a second
     * routing authority.
     */
    fun sourceChoices(source: StreamSource, mpvAvailable: Boolean): List<PlayerLaunchChoice> =
        choices(mpvAvailable).filter { choice ->
            choice.preference != PlayerEngineRouter.Override.AUTO &&
                !(mpvAvailable && source.isTorrent && choice.preference == PlayerEngineRouter.Override.EXOPLAYER)
        }

    fun defaultPreference(mpvAvailable: Boolean): PlayerEngineRouter.Override =
        if (mpvAvailable) PlayerEngineRouter.Override.AUTO else PlayerEngineRouter.Override.EXOPLAYER

    /**
     * Resolve a requested detail choice to an engine route the installed flavor and source can actually use.
     * The Play flavor has no mpv, so every stale/automatic request becomes Media3. In Full, a Media3 request
     * for a torrent uses VortX because the torrent warm-up contract is mpv-only. Every other explicit choice
     * remains explicit; runtime mpv initialization still has PlayerScreen's existing Media3 safety fallback.
     */
    fun effectivePreference(
        requested: PlayerEngineRouter.Override,
        playable: Playable,
        mpvAvailable: Boolean,
    ): PlayerEngineRouter.Override = when {
        !mpvAvailable -> PlayerEngineRouter.Override.EXOPLAYER
        requested == PlayerEngineRouter.Override.EXOPLAYER && playable.isTorrent ->
            PlayerEngineRouter.Override.MPV
        else -> requested
    }

    fun labelFor(
        preference: PlayerEngineRouter.Override,
        mpvAvailable: Boolean,
    ): String = choices(mpvAvailable)
        .firstOrNull { it.preference == preference }
        ?.label
        ?: choices(mpvAvailable).first().label
}
