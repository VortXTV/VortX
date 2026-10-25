package com.vortx.android.player.queue

/** UI-dispatcher owner for the exact outgoing Detail resolver; old disposal cannot detach a successor. */
internal class PlaybackQueueRouteRetirement {
    private var current: (() -> Unit)? = null

    fun attach(retire: () -> Unit): () -> Unit {
        current = retire
        return { if (current === retire) current = null }
    }

    fun retire() {
        current?.invoke()
    }
}
