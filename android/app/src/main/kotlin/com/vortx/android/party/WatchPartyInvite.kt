package com.vortx.android.party

import java.net.URI

/** Intentionally not Parcelable, Serializable, persisted, or included in diagnostic output. */
internal class WatchPartyInvite(val roomId: String, val inviteCode: String, key: ByteArray) {
    private val secret = key.copyOf()
    fun copyKey() = secret.copyOf()
    fun link() = "https://vortx.tv/watch-party#v=1&room=$roomId&invite=$inviteCode&key=${WatchPartyWire.encodeUrl(secret)}"
    fun erase() { secret.fill(0) }
    override fun toString() = "WatchPartyInvite(redacted)"
    companion object {
        fun make(roomId: String, inviteCode: String, key: ByteArray): WatchPartyInvite {
            require(WatchPartyWire.opaque(roomId) && WatchPartyWire.opaque(inviteCode) && key.size == 32)
            return WatchPartyInvite(roomId, inviteCode, key)
        }
        fun parse(raw: String?): WatchPartyInvite? = runCatching {
            require(raw != null && raw.toByteArray(Charsets.UTF_8).size <= 1024)
            val uri = URI(raw)
            require(uri.scheme.equals("https", true) && uri.host.equals("vortx.tv", true) &&
                uri.rawPath == "/watch-party" && uri.rawQuery == null && uri.rawUserInfo == null && uri.port == -1)
            val fields = uri.rawFragment?.split('&') ?: error("Invalid invite")
            require(fields.size == 4 && fields[0] == "v=1")
            require(fields[1].startsWith("room=") && fields[2].startsWith("invite=") && fields[3].startsWith("key="))
            val room = fields[1].removePrefix("room="); val invite = fields[2].removePrefix("invite=")
            val keyText = fields[3].removePrefix("key=")
            require(keyText.length == 43)
            val key = WatchPartyWire.decodeUrl(keyText) ?: error("Invalid invite")
            try { make(room, invite, key) } finally { key.fill(0) }
        }.getOrNull()
    }
}

