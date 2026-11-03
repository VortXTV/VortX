package com.vortx.android.sync

import android.content.Context
import android.content.SharedPreferences
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.attribute.BasicFileAttributes
import java.nio.file.attribute.FileTime
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
    @Volatile private var settingsOpened = false
    private var originalRestoreBacking: Fenced? = null
    private const val SETTINGS = "vortx_settings"

    /** The Application calls this before the platform can load or normalize the first settings file.
     * Only the exact initial settings open performs a bounded number of no-follow metadata reads.
     * Ordinary later opens and the platform open/result retain their existing behavior. */
    fun open(context: Context, name: String, mode: Int, platformOpen: () -> SharedPreferences): SharedPreferences {
        if (name != SETTINGS || settingsOpened) return wrap(name, platformOpen())
        return synchronized(lock) {
            if (settingsOpened) return@synchronized wrap(name, platformOpen())
            try {
                val pristine = try {
                    if (context.isDeviceProtectedStorage || mode != Context.MODE_PRIVATE) null
                    else PristineBacking.beforeOpen(context.dataDir.toPath())
                } catch (_: Exception) { null }
                val backing = platformOpen()
                val wasAlreadyWrapped = backing is Fenced || wrappers.containsKey(backing)
                val wrapper = wrap(name, backing)
                val bound = if (!wasAlreadyWrapped) try { pristine?.finishOpen() } catch (_: Exception) { null } else null
                if (bound != null && wrapper is Fenced && originalRestoreBacking == null) {
                    wrapper.pristine = bound
                    originalRestoreBacking = wrapper
                }
                wrapper
            } finally {
                settingsOpened = true
            }
        }
    }

    /** Actual retained wrapper only. No getter opens a store, touches keys or updates backing.
     * The returned closure reads a volatile identity and is suitable for final worker currency. */
    fun capturePristineRestoreBacking(existing: SharedPreferences): (() -> Boolean)? {
        val wrapper = existing as? Fenced ?: return null
        val original = wrapper.pristine ?: return null
        val before = original.observeMissing() ?: return null
        val current = synchronized(lock) { wrapper.pristine === original && wrapper.backing.all.isEmpty() }
        if (!current || original.observeMissing() != before || wrapper.pristine !== original) return null
        return { wrapper.pristine === original }
    }

    private class PristineBacking(private val root: Path, private val appIdentity: Any, private val directoryIdentity: Any?) {
        data class Directory(val identity: Any, val modified: FileTime)
        private val directory = root.resolve("shared_prefs")

        fun finishOpen(): PristineBacking? {
            val now = directoryAttributes(directory) ?: return null
            if (directoryAttributes(root)?.identity != appIdentity ||
                directoryIdentity != null && now.identity != directoryIdentity || !primaryAndRollbackMissing(directory) ||
                directoryAttributes(directory) != now) return null
            return PristineBacking(root, appIdentity, now.identity)
        }

        fun observeMissing(): Directory? {
            if (directoryAttributes(root)?.identity != appIdentity) return null
            val before = directoryAttributes(directory)?.takeIf { it.identity == directoryIdentity } ?: return null
            // This bounded inventory runs only on the explicit Restore worker.
            Files.newDirectoryStream(directory).use { entries ->
                var count = 0
                for (entry in entries) {
                    val name = entry.fileName.toString()
                    if (++count > 4096 || name == "$SETTINGS.xml" || name.startsWith("$SETTINGS.xml.")) return null
                }
            }
            return before.takeIf { directoryAttributes(directory) == it && directoryAttributes(root)?.identity == appIdentity }
        }

        companion object {
            private fun attributes(path: Path): BasicFileAttributes? = try {
                Files.readAttributes(path, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
            } catch (_: NoSuchFileException) { null }

            private fun directoryAttributes(path: Path): Directory? {
                val attrs = attributes(path) ?: return null
                check(attrs.isDirectory)
                return Directory(checkNotNull(attrs.fileKey()), attrs.lastModifiedTime())
            }

            private fun primaryAndRollbackMissing(directory: Path): Boolean =
                attributes(directory.resolve("$SETTINGS.xml")) == null &&
                    attributes(directory.resolve("$SETTINGS.xml.bak")) == null

            fun beforeOpen(root: Path): PristineBacking? {
                val app = directoryAttributes(root) ?: return null
                val directory = root.resolve("shared_prefs")
                val before = directoryAttributes(directory)
                if (!primaryAndRollbackMissing(directory) ||
                    directoryAttributes(directory) != before || directoryAttributes(root) != app) return null
                return PristineBacking(root, app.identity, before?.identity)
            }
        }
    }
    /** Deterministic queued-notification tests. No arbitrary scheduler callback runs under the fence. */
    internal var queuedNotificationsForTest: MutableList<() -> Unit>? = null
    class Observation internal constructor(internal val revision: Long)

    fun wrap(name: String, backing: SharedPreferences): SharedPreferences {
        if (name != "vortx_settings" && name != "vortx_sync_dirty") return backing
        return synchronized(lock) {
            val wrapper = if (backing is Fenced) backing else
                wrappers[backing] ?: Fenced(backing).also { wrappers[backing] = it }
            if (name == SETTINGS && wrapper !== originalRestoreBacking) originalRestoreBacking?.pristine = null
            wrapper
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
        @Volatile var pristine: PristineBacking? = null
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
                    pristine = null // Retire before any platform mutation, even failure or ABA.
                    check(revision < Long.MAX_VALUE) { "Settings revision exhausted" }
                    revision += 1 // Every attempted replacement retires observations, including ABA/failure.
                    if (commit) editor.commit() else { editor.apply(); true }
            }
            override fun commit() = replace(true)
            override fun apply() { replace(false) }
        }
    }
}
