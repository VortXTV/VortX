package com.vortx.android.model

import java.util.Locale
import org.json.JSONArray

/** Only the public optional genre-string array is read. Empty/default-empty remains Unknown. */
internal object LibraryGenreFacts {
    fun key(label: String): String = label.trim().lowercase(Locale.ROOT)
    fun normalized(values: List<String>): List<String> = values.map(String::trim)
        .filter(String::isNotEmpty).distinctBy(::key)
    fun publicArray(value: Any?): List<String> {
        val array = value as? JSONArray ?: return emptyList()
        val values = ArrayList<String>(array.length())
        for (index in 0 until array.length()) {
            val label = array.opt(index) as? String ?: return emptyList()
            values += label
        }
        return normalized(values)
    }
}
