package com.vortx.android.integrations

import com.vortx.android.security.PersistentCredentialAvailability
import com.vortx.android.security.PersistentCredentialSnapshot

internal class FakeCredentialStore(
    initialDurableValues: Map<String, String> = emptyMap(),
) : CredentialStoreAccess {
    private val durableValues = initialDurableValues.toMutableMap()
    private val memoryValues = initialDurableValues.toMutableMap()
    var rejectWrites = false
    var persistentAvailable = true
    var snapshotCalls = 0
        private set
    var lastSnapshotKeys: Set<String> = emptySet()
        private set

    @Synchronized
    override fun string(key: String): String? = memoryValues[key]

    @Synchronized
    override fun confirmedSnapshot(vararg keys: String): PersistentCredentialSnapshot {
        snapshotCalls += 1
        lastSnapshotKeys = keys.toSet()
        val values = keys.associateWith(durableValues::get)
        val availability = if (persistentAvailable) {
            PersistentCredentialAvailability.AVAILABLE
        } else {
            PersistentCredentialAvailability.UNAVAILABLE
        }
        return PersistentCredentialSnapshot(availability, values)
    }

    @Synchronized
    override fun set(key: String, value: String?): Boolean = set(mapOf(key to value))

    @Synchronized
    override fun set(values: Map<String, String?>): Boolean {
        if (!persistentAvailable) {
            apply(memoryValues, values)
            return false
        }
        if (rejectWrites) return false
        apply(memoryValues, values)
        apply(durableValues, values)
        return true
    }

    @Synchronized
    override fun clear(vararg keys: String): Boolean = set(keys.associateWith { null })

    @Synchronized
    fun reopen(): FakeCredentialStore = FakeCredentialStore(durableValues)

    private fun apply(target: MutableMap<String, String>, values: Map<String, String?>) {
        values.forEach { (key, value) ->
            if (value == null) target.remove(key) else target[key] = value
        }
    }
}
