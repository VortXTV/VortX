package com.vortx.android.tv

import java.nio.ByteBuffer
import java.util.Base64
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

// Package-private inputs from the validated mounted account. Only opaque stamps cross into TvProvider.
internal class WatchNextOwnerIdentity(
    val accountId: String,
    val nativeScope: String,
    val profileId: String,
    val accountKind: String,
    val accountValue: String?,
    val bindingRevision: Long,
    val bindingTransactionId: String?,
)

internal data class WatchNextAccountStamp(val installation: String, val account: String)
internal data class WatchNextOwnerStamp(val account: WatchNextAccountStamp, val binding: String)

internal object WatchNextRowIdentity {
    const val PREFIX = "vortx-cw:"
    private const val VERSIONED_PREFIX = "${PREFIX}v1:"
    private val stampFormat = Regex("[A-Za-z0-9_-]{22}")

    fun account(key: ByteArray, accountId: String): WatchNextAccountStamp = WatchNextAccountStamp(
        stamp(key, "installation"),
        stamp(key, "account", UUID.fromString(accountId).toString()),
    )

    fun owner(key: ByteArray, identity: WatchNextOwnerIdentity): WatchNextOwnerStamp {
        val account = account(key, identity.accountId)
        val binding = stamp(key, "binding", account.account, identity.nativeScope, identity.profileId,
            identity.accountKind, identity.accountValue.orEmpty(), identity.bindingRevision.toString(),
            identity.bindingTransactionId.orEmpty())
        return WatchNextOwnerStamp(account, binding)
    }

    fun providerId(owner: WatchNextOwnerStamp, type: String, id: String): String =
        "$VERSIONED_PREFIX${owner.account.installation}:${owner.account.account}:${owner.binding}:$type:$id"

    /** Account-only retirement is possible only when this installation can interpret the row's stamp. */
    fun belongsToOtherAccount(providerId: String, current: WatchNextAccountStamp): Boolean {
        val stored = ownerOf(providerId)?.account ?: return false
        return stored.installation == current.installation && stored.account != current.account
    }

    /** Legacy/invalid v1 rows have no account evidence. Only a completed mount may retire them. */
    fun belongsOutsideMount(providerId: String, current: WatchNextOwnerStamp?): Boolean =
        when {
            providerId.startsWith(VERSIONED_PREFIX) -> current == null || ownerOf(providerId) != current
            providerId.startsWith("${PREFIX}movie:") || providerId.startsWith("${PREFIX}series:") -> true
            else -> false
        }

    fun belongsToMount(providerId: String, current: WatchNextOwnerStamp): Boolean =
        ownerOf(providerId) == current

    private fun ownerOf(providerId: String): WatchNextOwnerStamp? {
        if (!providerId.startsWith(VERSIONED_PREFIX)) return null
        val parts = providerId.removePrefix(VERSIONED_PREFIX).split(':', limit = 5)
        if (parts.size != 5 || !parts.take(3).all(stampFormat::matches) ||
            parts[3] !in setOf("movie", "series") || parts[4].isBlank()
        ) return null
        return WatchNextOwnerStamp(WatchNextAccountStamp(parts[0], parts[1]), parts[2])
    }

    private fun stamp(key: ByteArray, domain: String, vararg fields: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        for (field in listOf("vortx-watch-next-v1", domain) + fields) {
            val bytes = field.toByteArray(Charsets.UTF_8)
            mac.update(ByteBuffer.allocate(Int.SIZE_BYTES).putInt(bytes.size).array())
            mac.update(bytes)
        }
        return Base64.getUrlEncoder().withoutPadding().encodeToString(mac.doFinal().copyOf(16))
    }
}
