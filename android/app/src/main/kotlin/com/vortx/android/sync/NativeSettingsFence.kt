package com.vortx.android.sync

import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import java.util.WeakHashMap

/** Process settings writer owner. No account or credential data is stored in its witness.
 * Application supplies this wrapper to every vortx_settings/vortx_sync_dirty caller.
 * Lock order: Session -> account admission -> provider -> this fence -> checkpoint store.
 * Preference notifications are posted after replacement, never invoked while holding this fence.
 */
internal object NativeSettingsFence {
    private val lock = Any()
    private val wrappers = java.util.IdentityHashMap<SharedPreferences, Fenced>()
    private var revision = 0L
    /** Deterministic queued-notification tests. No arbitrary scheduler callback runs under the fence. */
    internal var queuedNotificationsForTest: MutableList<() -> Unit>? = null
    class Observation internal constructor(internal val revision: Long)

    fun wrap(name: String, backing: SharedPreferences): SharedPreferences {
        if (name != "vortx_settings" && name != "vortx_sync_dirty") return backing
        return synchronized(lock) {
            if (backing is Fenced) return@synchronized backing
            wrappers[backing] ?: Fenced(backing).also { wrappers[backing] = it }
        }
    }
    fun <T> capture(read: () -> T): Pair<Observation, T> = synchronized(lock) {
        Observation(revision) to read()
    }
    /** Shadow/dirty bookkeeping is part of the same prospective-family witness as editor writes. */
    fun <T> mutateBookkeeping(action: () -> T): T = synchronized(lock) {
        check(revision < Long.MAX_VALUE) { "Settings revision exhausted" }
        revision += 1
        action()
    }
    fun <T> withCurrent(observation: Observation, action: () -> T): T = synchronized(lock) {
        check(observation.revision == revision) { "Pending settings changed" }
        action()
    }

    private class Fenced(val backing: SharedPreferences) : SharedPreferences by backing {
        private val listeners = WeakHashMap<SharedPreferences.OnSharedPreferenceChangeListener,
            SharedPreferences.OnSharedPreferenceChangeListener>()
        override fun getAll(): MutableMap<String, *> = synchronized(lock) {
            backing.all.mapValuesTo(linkedMapOf()) { (_, value) ->
                if (value is Set<*>) value.toSet() else value
            }
        }
        override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
            synchronized(lock) { backing.getStringSet(key, defValues)?.toMutableSet() }
        override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
            synchronized(lock) {
                if (listeners.containsKey(listener)) return
                val weak = java.lang.ref.WeakReference(listener)
                val bridge = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
                    // Keep the platform's exact keys, including null clear callbacks and any
                    // same-value notifications. Never retain a UI listener strongly in a queue.
                    val notify = { weak.get()?.onSharedPreferenceChanged(this@Fenced, key); Unit }
                    val queue = queuedNotificationsForTest
                    if (queue != null) queue.add(notify) else Handler(Looper.getMainLooper()).post { notify() }
                }
                listeners[listener] = bridge
                backing.registerOnSharedPreferenceChangeListener(bridge)
            }
        }
        override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
            synchronized(lock) { listeners.remove(listener)?.let(backing::unregisterOnSharedPreferenceChangeListener) }
        }
        override fun edit(): SharedPreferences.Editor = Editor(backing.edit())
        private inner class Editor(private val editor: SharedPreferences.Editor) : SharedPreferences.Editor {
            override fun putString(key: String?, value: String?) = apply { editor.putString(key, value) }
            override fun putStringSet(key: String?, values: MutableSet<String>?) = apply { editor.putStringSet(key, values?.toMutableSet()) }
            override fun putInt(key: String?, value: Int) = apply { editor.putInt(key, value) }
            override fun putLong(key: String?, value: Long) = apply { editor.putLong(key, value) }
            override fun putFloat(key: String?, value: Float) = apply { editor.putFloat(key, value) }
            override fun putBoolean(key: String?, value: Boolean) = apply { editor.putBoolean(key, value) }
            override fun remove(key: String?) = apply { editor.remove(key) }
            override fun clear() = apply { editor.clear() }
            private fun replace(commit: Boolean): Boolean = synchronized(lock) {
                    check(revision < Long.MAX_VALUE) { "Settings revision exhausted" }
                    revision += 1 // Every attempted replacement retires observations, including ABA/failure.
                    if (commit) editor.commit() else { editor.apply(); true }
            }
            override fun commit() = replace(true)
            override fun apply() { replace(false) }
        }
    }
}
