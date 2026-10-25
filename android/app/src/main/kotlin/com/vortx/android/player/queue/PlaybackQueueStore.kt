package com.vortx.android.player.queue

import android.content.Context
import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

internal interface PlaybackQueuePersistence {
    fun read(key: String): String?
    fun write(key: String, value: String): Boolean
}

/** Process-owned local queue. Accepted writes retain their original namespace and drain in order. */
internal class PlaybackQueueStore internal constructor(
    private val persistence: PlaybackQueuePersistence,
    private val scope: CoroutineScope,
    private val currentOwner: () -> ContinueWatchingOwner,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {
    constructor(context: Context, scope: CoroutineScope, currentOwner: () -> ContinueWatchingOwner) : this(
        object : PlaybackQueuePersistence {
            private val prefs = context.applicationContext.getSharedPreferences("vortx_playback_queue", Context.MODE_PRIVATE)
            override fun read(key: String): String? = prefs.getString(key, null)
            override fun write(key: String, value: String): Boolean = prefs.edit().putString(key, value).commit()
        }, scope, currentOwner,
    )

    private val monitor = Any()
    private val _state = MutableStateFlow(PlaybackQueueState())
    val state: StateFlow<PlaybackQueueState> = _state.asStateFlow()
    private var writeTail: Job? = null
    private var loadJob: Job? = null
    private var pendingWrites = 0
    private fun ownerNow(): ContinueWatchingOwner? = runCatching(currentOwner).getOrNull()

    /** Local-only invalidation is safe inside the existing account authority's retirement monitor. */
    fun invalidate() {
        val previous = synchronized(monitor) {
            _state.value = PlaybackQueueState(revision = Math.incrementExact(_state.value.revision))
            loadJob.also { loadJob = null }
        }
        previous?.cancel()
    }

    fun retryLoad(owner: ContinueWatchingOwner) {
        if (ownerNow() != owner) return
        invalidate()
        bindOwner(owner)
    }

    fun bindOwner(owner: ContinueWatchingOwner) {
        if (ownerNow() != owner) return
        val load = synchronized(monitor) {
            if (_state.value.owner == owner) return
            val next = PlaybackQueueState(owner = owner, revision = Math.incrementExact(_state.value.revision))
            _state.value = next
            Triple(next, writeTail, loadJob)
        }
        load.third?.cancel()
        val job = scope.launch(io, start = CoroutineStart.LAZY) {
            // This includes accepted outgoing-owner writes; a rapid A→B→A cannot load older disk state
            // ahead of the already-admitted A write. Never retarget that write to B's storage key.
            load.second?.join()
            val entries = runCatching { PlaybackQueueCodec.decode(persistence.read(PlaybackQueueModel.storageKey(owner))) }
            if (ownerNow() != owner) return@launch
            synchronized(monitor) {
                if (_state.value.owner != owner || _state.value.revision != load.first.revision) return@synchronized
                _state.value = load.first.copy(
                    ready = entries.isSuccess,
                    entries = entries.getOrDefault(emptyList()),
                    error = if (entries.isFailure) "Saved queue is unavailable. Its data was not changed." else null,
                )
            }
        }
        synchronized(monitor) {
            if (_state.value.owner == owner && _state.value.revision == load.first.revision) loadJob = job
            else job.cancel()
        }
        job.start()
    }

    fun add(owner: ContinueWatchingOwner, item: MetaItem, playNext: Boolean = false): Boolean =
        mutate(owner) { PlaybackQueueModel.add(it, owner, item, playNext) }
    fun move(owner: ContinueWatchingOwner, id: String, delta: Int): Boolean =
        mutate(owner) { PlaybackQueueModel.move(it, owner, id, delta) }
    fun remove(owner: ContinueWatchingOwner, id: String): Boolean =
        mutate(owner) { PlaybackQueueModel.remove(it, owner, id) }

    fun capture(owner: ContinueWatchingOwner, id: String): PlaybackQueueToken? {
        if (ownerNow() != owner) return null
        val token = synchronized(monitor) { PlaybackQueueModel.capture(_state.value, owner, id) }
        return token?.takeIf { ownerNow() == owner }
    }
    fun first(owner: ContinueWatchingOwner): PlaybackQueueToken? {
        if (ownerNow() != owner) return null
        val id = synchronized(monitor) { _state.value.takeIf { it.owner == owner && it.ready }?.entries?.firstOrNull()?.id }
        return id?.let { capture(owner, it) }
    }
    fun accepts(token: PlaybackQueueToken): Boolean {
        val owner = ownerNow() ?: return false
        val accepted = synchronized(monitor) { PlaybackQueueModel.accepts(_state.value, owner, token) }
        return accepted && ownerNow() == token.owner
    }
    /** Call only AFTER the existing resolved-playback onPlay admission accepted this exact request. */
    fun consumeAfterAccepted(token: PlaybackQueueToken): Boolean =
        mutate(token.owner) { PlaybackQueueModel.consumeAfterAccepted(it, token.owner, token) }

    private fun mutate(owner: ContinueWatchingOwner, transform: (PlaybackQueueState) -> PlaybackQueueState?): Boolean {
        if (ownerNow() != owner) return false
        val write = synchronized(monitor) {
            val before = _state.value
            if (!before.ready || before.owner != owner) return false
            if (pendingWrites >= 32) {
                _state.value = before.copy(error = "Queue is saving. Try again in a moment.")
                return false
            }
            val next = runCatching { transform(before) }.getOrNull() ?: return false
            val key = runCatching { PlaybackQueueModel.storageKey(owner) }.getOrNull() ?: return false
            val json = runCatching { PlaybackQueueCodec.encode(next.entries) }.getOrNull() ?: return false
            val predecessor = writeTail
            pendingWrites += 1
            val job = scope.launch(io, start = CoroutineStart.LAZY) {
                predecessor?.join()
                val stored = runCatching { persistence.write(key, json) }.getOrDefault(false)
                if (!stored) synchronized(monitor) {
                    if (_state.value.owner == owner && _state.value.revision == next.revision) {
                        _state.value = next.copy(ready = false, error = "Queue could not be saved. Retry the saved queue before editing again.")
                    }
                }
            }
            job.invokeOnCompletion {
                synchronized(monitor) {
                    pendingWrites -= 1
                    if (pendingWrites < 32 && _state.value.error == "Queue is saving. Try again in a moment.") {
                        _state.value = _state.value.copy(error = null)
                    }
                }
            }
            // This is an accepted local intent for this immutable owner namespace. Its IO never calls
            // a provider/native gateway while monitor is held and cannot publish into a successor owner.
            _state.value = next
            writeTail = job
            job
        }
        write.start()
        return true
    }
}
