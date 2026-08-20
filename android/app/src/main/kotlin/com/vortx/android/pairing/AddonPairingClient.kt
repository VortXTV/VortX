package com.vortx.android.pairing

import com.vortx.android.net.VortXEdgeAuth
import com.vortx.android.pairing.AddonPairingProtocol.Authority
import com.vortx.android.pairing.AddonPairingProtocol.DeliveryReference
import com.vortx.android.pairing.AddonPairingProtocol.Field
import com.vortx.android.pairing.AddonPairingProtocol.WireAcknowledgement
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.net.URL
import java.util.concurrent.TimeUnit

/// One manifest the phone posted to the relay for this device to install (Apple pairing "delivery").
data class PairingDelivery(
    val deliveryId: String,
    val deliveryRevision: Int,
    val url: String,
    val addedAt: Long,
)

/// The relay's poll snapshot (Apple pairing poll response). Carries the current authority + the pending
/// manifest deliveries, plus the lifecycle flags that end the session.
data class PairingPoll(
    val authority: Authority?,
    val deliveries: List<PairingDelivery>,
    val revision: Int,
    val expiresAtEpochSeconds: Long?,
    val closed: Boolean,
    val terminal: Boolean,
    val released: Boolean,
)

/// A freshly minted pairing session (Apple pairing `new` response): the bearer token, the QR page URL the
/// phone opens, and the initial authority.
data class PairingSession(
    val token: String,
    val pageUrl: String,
    val authority: Authority?,
)

/// The relay's response to a mutation (claim / ack / reopen / release). [ok] is the relay's accept flag;
/// [stale] means the authority/generation moved on and the caller should re-poll before retrying.
data class PairingMutationResult(
    val ok: Boolean,
    val duplicate: Boolean,
    val stale: Boolean,
)

/// Signed relay client for add-on QR pairing, the Kotlin port of Apple `AddonPairingClient.swift`. Every
/// request is a fixed-path POST whose token-bearing body is signed body-included (add.vortx.tv is a gated
/// host), so a valid signature can never be replayed with a changed body. All calls are fail-soft: a
/// network/parse/oversize error returns null (or a not-ok result) rather than throwing, so the reducer
/// treats it as "retry next tick".
class AddonPairingClient(
    private val client: OkHttpClient = defaultClient,
) {
    /// POST [route] with a fresh session (no token). Returns the minted session, or null on any failure.
    suspend fun createSession(): PairingSession? {
        val json = post(AddonPairingProtocol.Route.NEW, AddonPairingProtocol.bodyForNew()) ?: return null
        if (!json.optBoolean(Field.OK, true)) return null
        val token = json.optString(Field.TOKEN).takeIf { AddonPairingProtocol.isStrictToken(it) } ?: return null
        val pageUrl = json.optString(Field.PAGE_URL).takeIf { AddonPairingProtocol.isStrictManifestUrl(it) || it.startsWith("https://") } ?: return null
        return PairingSession(token = token, pageUrl = pageUrl, authority = parseAuthority(json))
    }

    /// Poll for pending manifest deliveries. Returns null on any transport failure (retry next tick).
    suspend fun poll(token: String, authority: Authority?): PairingPoll? {
        val json = post(AddonPairingProtocol.Route.POLL, AddonPairingProtocol.bodyForPoll(token, authority)) ?: return null
        if (!json.optBoolean(Field.OK, true)) return null
        return PairingPoll(
            authority = parseAuthority(json),
            deliveries = parseDeliveries(json),
            revision = json.optInt(Field.REVISION, 0),
            expiresAtEpochSeconds = json.optLongOrNull(Field.EXPIRES_AT),
            closed = json.optBoolean(Field.CLOSED, false),
            terminal = json.optBoolean(Field.TERMINAL, false),
            released = json.optBoolean(Field.RELEASED, false),
        )
    }

    /// Claim a batch of deliveries so the relay marks them in-flight for this device (idempotent by
    /// [mutationId]). Returns null on transport failure.
    suspend fun claim(
        token: String,
        authority: Authority,
        deliveries: List<DeliveryReference>,
        mutationId: String,
    ): PairingMutationResult? {
        if (deliveries.isEmpty()) return PairingMutationResult(ok = true, duplicate = false, stale = false)
        val json = post(
            AddonPairingProtocol.Route.CLAIM,
            AddonPairingProtocol.bodyForClaim(token, authority, deliveries, mutationId),
        ) ?: return null
        return parseMutation(json)
    }

    /// Acknowledge install outcomes for a batch of deliveries (idempotent by [mutationId]). Returns null on
    /// transport failure.
    suspend fun ack(
        token: String,
        authority: Authority,
        acknowledgements: List<WireAcknowledgement>,
        mutationId: String,
    ): PairingMutationResult? {
        if (acknowledgements.isEmpty()) return PairingMutationResult(ok = true, duplicate = false, stale = false)
        val json = post(
            AddonPairingProtocol.Route.ACK,
            AddonPairingProtocol.bodyForAck(token, authority, acknowledgements, mutationId),
        ) ?: return null
        return parseMutation(json)
    }

    /// Release the session on teardown so the relay can retire the token promptly (idempotent by
    /// [mutationId]). Best-effort: a failure just leaves the session to expire on its own.
    suspend fun release(token: String, authority: Authority, mutationId: String): Boolean {
        val json = post(
            AddonPairingProtocol.Route.RELEASE,
            AddonPairingProtocol.bodyForRelease(token, authority, mutationId),
        ) ?: return false
        return json.optBoolean(Field.OK, false)
    }

    private fun parseMutation(json: JSONObject) = PairingMutationResult(
        ok = json.optBoolean(Field.OK, false) || json.optBoolean(Field.ACCEPTED, false) || json.optBoolean(Field.CLAIMED, false),
        duplicate = json.optBoolean(Field.DUPLICATE, false) || json.optBoolean(Field.REPLAYED, false),
        stale = json.optBoolean(Field.STALE, false),
    )

    private fun parseAuthority(json: JSONObject): Authority? {
        val id = json.optString(Field.AUTHORITY_SESSION).takeIf { it.isNotBlank() } ?: return null
        val generation = json.optInt(Field.AUTHORITY_GENERATION, json.optInt(Field.SESSION_GENERATION, 0))
        return Authority.of(id, generation)
    }

    private fun parseDeliveries(json: JSONObject): List<PairingDelivery> {
        val array: JSONArray = json.optJSONArray(Field.MANIFESTS) ?: json.optJSONArray(Field.DELIVERY_IDS) ?: return emptyList()
        if (!AddonPairingProtocol.canAcceptManifestCount(array.length())) return emptyList()
        val out = mutableListOf<PairingDelivery>()
        for (i in 0 until array.length()) {
            val entry = array.optJSONObject(i) ?: continue
            val id = entry.optString(Field.DELIVERY_ID).takeIf { AddonPairingProtocol.isOpaqueIdentifier(it) } ?: continue
            val url = entry.optString(Field.URL).takeIf { AddonPairingProtocol.isStrictManifestUrl(it) } ?: continue
            out += PairingDelivery(
                deliveryId = id,
                deliveryRevision = entry.optInt(Field.DELIVERY_REVISION, 0),
                url = url,
                addedAt = entry.optLongOrNull(Field.ADDED_AT) ?: 0L,
            )
        }
        return out
    }

    /// Sign + POST [body] to [route], returning the parsed JSON response, or null on any transport / status
    /// / size / parse failure. add.vortx.tv is a gated host, so the body-included signer stamps all four
    /// `X-VX-*` headers; an unprovisioned build still stamps the observe-mode (empty-key) signature.
    private suspend fun post(route: AddonPairingProtocol.Route, body: JSONObject): JSONObject? =
        withContext(Dispatchers.IO) {
            runCatching {
                val bytes = body.toString().toByteArray(Charsets.UTF_8)
                val url = URL(route.url)
                val builder = Request.Builder()
                    .url(route.url)
                    .header("content-type", "application/json")
                    .header("accept", "application/json")
                    .header("User-Agent", "VortX-Android/1.0")
                    .post(bytes.toRequestBody(JSON_MEDIA_TYPE))
                VortXEdgeAuth.signingHeadersIncludingBody("POST", url, bytes)?.let { h ->
                    builder.header(VortXEdgeAuth.tsHeaderName(), h.ts)
                    builder.header(VortXEdgeAuth.kidHeaderName(), h.kid)
                    builder.header(VortXEdgeAuth.bodyHeaderName(), h.bodyHash)
                    builder.header(VortXEdgeAuth.sigHeaderName(), h.sig)
                }
                client.newCall(builder.build()).execute().use { response ->
                    if (!response.isSuccessful) return@use null
                    val responseBody = response.body ?: return@use null
                    val declared = responseBody.contentLength()
                    if (declared > AddonPairingProtocol.MAX_RESPONSE_BYTES) return@use null
                    val text = responseBody.string()
                    if (text.toByteArray(Charsets.UTF_8).size > AddonPairingProtocol.MAX_RESPONSE_BYTES) return@use null
                    runCatching { JSONObject(text) }.getOrNull()
                }
            }.getOrNull()
        }

    private fun JSONObject.optLongOrNull(key: String): Long? = if (has(key) && !isNull(key)) optLong(key) else null

    companion object {
        private val JSON_MEDIA_TYPE = "application/json".toMediaType()

        private val defaultClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(12, TimeUnit.SECONDS)
                .readTimeout(12, TimeUnit.SECONDS)
                .callTimeout(12, TimeUnit.SECONDS)
                .build()
        }
    }
}
