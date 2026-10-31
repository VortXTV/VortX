package com.vortx.android.foryou
import org.json.JSONObject
// Payload decoding collaborators only; production ForYouModel parser is tested separately.
data class ForYouInterests(val marker:String)
data class SmartCollection(val home:Boolean=false)
object ForYouSync {
    fun read(fields:JSONObject?):Pair<ForYouInterests?,List<SmartCollection>> = fields?.let { ForYouInterests(it.marker) } to emptyList()
}
