package com.vortx.android.pairing

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

/// The TV-side QR pairing wire contract, the Kotlin port of Apple `AddonPairingProtocol.swift`. Every
/// route and JSON key lives here so the app and the canonical relay reconcile at one boundary. Protocol
/// v2 uses only fixed routes: the bearer session token is carried in the BODY, never in a request path,
/// query, redirect target, or diagnostic label. Bodies are signed (body-included) by
/// [com.vortx.android.net.VortXEdgeAuth.signingHeadersIncludingBody] so a valid signature cannot be
/// replayed with a changed body.
object AddonPairingProtocol {
    const val VERSION = 2
    const val MIN_TOKEN_LENGTH = 22
    const val MAX_TOKEN_LENGTH = 64
    const val MAX_MANIFESTS = 30
    const val MAX_MANIFEST_URL_BYTES = 2048
    const val MAX_RESPONSE_BYTES = 128 * 1024

    const val RELAY_BASE_URL = "https://add.vortx.tv"

    fun canAcceptResponse(currentBytes: Int, incomingBytes: Int): Boolean {
        if (currentBytes < 0 || incomingBytes < 0 || currentBytes > MAX_RESPONSE_BYTES) return false
        return incomingBytes <= MAX_RESPONSE_BYTES - currentBytes
    }

    fun canAcceptManifestCount(count: Int): Boolean = count in 0..MAX_MANIFESTS

    enum class Route(val rawValue: String) {
        NEW("new"),
        POLL("poll"),
        CLAIM("claim"),
        ACK("ack"),
        REOPEN("reopen"),
        RELEASE("release"),
        REVOKE("revoke");

        val path: String get() = "/pair/$rawValue"
        val url: String get() = "$RELAY_BASE_URL$path"
    }

    /// Wire keys (Apple `AddonPairingProtocol.Field`). `nonce` is the per-mutation id the relay burns
    /// durably; a new mutation gets a fresh value, an ambiguous retry reuses the same pair for idempotency.
    object Field {
        const val OK = "ok"
        const val DUPLICATE = "duplicate"
        const val PROTOCOL_VERSION = "proto"
        const val TOKEN = "token"
        const val PAGE_URL = "pageUrl"
        const val NONCE = "nonce"
        const val MUTATION_ID = "mutationId"
        const val AUTHORITY_SESSION = "session"
        const val AUTHORITY_GENERATION = "generation"
        const val DELIVERY_IDS = "deliveries"
        const val ACKNOWLEDGEMENTS = "acks"
        const val DELIVERY_ID = "id"
        const val DELIVERY_REVISION = "deliveryRev"
        const val URL = "url"
        const val ADDED_AT = "addedAt"
        const val STATUS = "status"
        const val RETRYABLE = "retryable"
        const val ATTEMPT = "attempt"
        const val MANIFESTS = "manifests"
        const val REVISION = "rev"
        const val EXPIRES_AT = "expiresAt"
        const val CLOSED = "closed"
        const val TERMINAL = "terminal"
        const val RELEASED = "released"
        const val SESSION_GENERATION = "sessionGeneration"
        const val REPORT = "report"
        const val CLAIMED = "claimed"
        const val ACCEPTED = "accepted"
        const val STALE = "stale"
        const val REPLAYED = "replayed"
        const val ERROR = "error"
    }

    data class Authority(val id: String, val generation: Int) {
        companion object {
            fun of(id: String, generation: Int) = Authority(id, generation.coerceAtLeast(0))
        }
    }

    data class WireAcknowledgement(
        val deliveryId: String,
        val status: String,
        val attempt: Int,
        val deliveryRevision: Int,
        val retryable: Boolean,
    )

    data class DeliveryReference(val deliveryId: String, val deliveryRevision: Int)

    fun isStrictToken(token: String): Boolean {
        if (token.length !in MIN_TOKEN_LENGTH..MAX_TOKEN_LENGTH) return false
        return token.all { it.isAsciiIdentifierChar() }
    }

    fun isOpaqueIdentifier(value: String, maxLength: Int = 512): Boolean {
        if (value.length !in 1..maxLength) return false
        return value.all { it.isAsciiIdentifierChar() }
    }

    fun isMutationId(value: String): Boolean = isOpaqueIdentifier(value, maxLength = 128)

    /// The relay accepts only its canonical HTTPS manifest syntax. DNS/private-address checks and redirect
    /// revalidation happen at the install path (AddonManifestFetcher / PublicAddressPolicy); this lighter
    /// gate rejects malformed or oversized poll entries before they enter the reducer or are shown as work.
    fun isStrictManifestUrl(value: String): Boolean {
        if (value.isEmpty()) return false
        if (value.toByteArray(Charsets.UTF_8).size > MAX_MANIFEST_URL_BYTES) return false
        if (value != value.trim()) return false
        val uri = runCatching { URI(value) }.getOrNull() ?: return false
        if (uri.scheme?.lowercase() != "https") return false
        if (uri.host.isNullOrEmpty()) return false
        if (uri.userInfo != null) return false
        if (uri.fragment != null) return false
        return true
    }

    private fun Char.isAsciiIdentifierChar(): Boolean =
        this.code < 128 && (isLetterOrDigit() || this == '-' || this == '_')

    // ---- body builders (mirror Apple `bodyFor*`) ----

    fun bodyForNew(): JSONObject = JSONObject().put(Field.PROTOCOL_VERSION, VERSION)

    fun bodyForPoll(token: String, authority: Authority? = null): JSONObject {
        val body = JSONObject().put(Field.PROTOCOL_VERSION, VERSION).put(Field.TOKEN, token)
        if (authority != null) {
            body.put(Field.AUTHORITY_SESSION, authority.id)
            body.put(Field.AUTHORITY_GENERATION, authority.generation)
        }
        return body
    }

    fun bodyForClaim(
        token: String,
        authority: Authority,
        deliveries: List<DeliveryReference>,
        mutationId: String,
    ): JSONObject = JSONObject()
        .put(Field.PROTOCOL_VERSION, VERSION)
        .put(Field.TOKEN, token)
        .put(Field.NONCE, mutationId)
        .put(Field.MUTATION_ID, mutationId)
        .put(Field.AUTHORITY_SESSION, authority.id)
        .put(Field.AUTHORITY_GENERATION, authority.generation)
        .put(
            Field.DELIVERY_IDS,
            JSONArray().apply {
                deliveries.forEach {
                    put(JSONObject().put(Field.DELIVERY_ID, it.deliveryId).put(Field.DELIVERY_REVISION, it.deliveryRevision))
                }
            },
        )

    fun bodyForAck(
        token: String,
        authority: Authority,
        acknowledgements: List<WireAcknowledgement>,
        mutationId: String,
    ): JSONObject = JSONObject()
        .put(Field.PROTOCOL_VERSION, VERSION)
        .put(Field.TOKEN, token)
        .put(Field.NONCE, mutationId)
        .put(Field.MUTATION_ID, mutationId)
        .put(Field.AUTHORITY_SESSION, authority.id)
        .put(Field.AUTHORITY_GENERATION, authority.generation)
        .put(
            Field.ACKNOWLEDGEMENTS,
            JSONArray().apply {
                acknowledgements.forEach {
                    put(
                        JSONObject()
                            .put(Field.DELIVERY_ID, it.deliveryId)
                            .put(Field.STATUS, it.status)
                            .put(Field.ATTEMPT, it.attempt)
                            .put(Field.DELIVERY_REVISION, it.deliveryRevision)
                            .put(Field.RETRYABLE, it.retryable),
                    )
                }
            },
        )

    fun bodyForReopen(token: String, authority: Authority, mutationId: String): JSONObject = JSONObject()
        .put(Field.PROTOCOL_VERSION, VERSION)
        .put(Field.TOKEN, token)
        .put(Field.AUTHORITY_SESSION, authority.id)
        .put(Field.AUTHORITY_GENERATION, authority.generation)
        .put(Field.NONCE, mutationId)
        .put(Field.MUTATION_ID, mutationId)

    fun bodyForRelease(token: String, authority: Authority, mutationId: String): JSONObject =
        bodyForReopen(token, authority, mutationId)
}
