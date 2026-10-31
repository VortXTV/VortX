package com.vortx.android.engine

import android.content.Context

/** Separate device preferences: no account/profile sync or settings backup can enroll another server. */
class StreamingServerSelectionStore private constructor(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
    private val selection = StreamingServerSelection(preferences.getString(BASE_KEY, null)) { value ->
        val editor = preferences.edit()
        if (value == null) editor.remove(BASE_KEY) else editor.putString(BASE_KEY, value)
        editor.commit()
    }

    fun currentBase(): String? = selection.currentBase()
    fun save(raw: String): Boolean = selection.save(raw)
    fun useEmbedded(): Boolean = selection.useEmbedded()
    internal fun capture(): ChosenStreamingServer? = selection.capture()

    companion object {
        private const val PREFS_FILE = "vortx_streaming_server_device"
        private const val BASE_KEY = "selected_base"
        @Volatile private var instance: StreamingServerSelectionStore? = null
        fun instance(context: Context): StreamingServerSelectionStore = instance ?: synchronized(this) {
            instance ?: StreamingServerSelectionStore(context).also { instance = it }
        }
    }
}
