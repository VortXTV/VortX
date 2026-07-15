package com.vortx.android.net

import java.net.HttpURLConnection
import java.net.URL
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Client-side request signing for the hardened VortX edge workers. Kotlin port of the Apple
 * `app/SourcesShared/VortXEdgeAuth.swift`, matched BYTE-FOR-BYTE so an Android-signed request verifies
 * against the SAME Cloudflare Workers (skip / trickplay / ratings / poster / erdb / trailer / catalogs /
 * config / subtitles / add-pair) as an Apple- or web-signed one.
 *
 * VortX's first-party edge services are fronted by workers that verify an HMAC signature so a request can
 * be attributed to a real VortX build rather than a scraper leeching the keyless endpoints. [sign] is the
 * one place that stamps a request; every HTTP call site that targets one of OUR gated hosts runs the
 * outgoing request through it right before it is sent. [signedUrl] is the header-less variant for image
 * GETs (Coil / `<img>`), which cannot attach `X-VX-*` headers.
 *
 * THREAT MODEL (be honest, same as Apple): a secret embedded in a CLIENT is never truly non-extractable.
 * This is DETERRENCE + REVOCATION, not a wall:
 *   1. OBFUSCATION: the secret is NEVER stored or shipped as a contiguous plaintext string. The build
 *      injects only a MASKED (XOR + base64) blob (read below from `BuildConfig.VORTX_EDGE_SECRET`, the
 *      Android build-config channel that parallels the Apple Info.plist key), and the mask is assembled at
 *      runtime from two scattered byte fragments, so a casual `strings`/`unzip` of the APK yields nothing
 *      usable. Pulling the real key requires actually reverse-engineering the de-mask path. The plaintext
 *      key is NEVER a literal in this source, exactly as on Apple.
 *   2. KEY VERSIONING + ROTATION: every request carries a key id ([KEY_ID], `X-VX-Kid`). The workers hold
 *      a MAP of id -> secret and can REVOKE an id and roll to a new id WITHOUT breaking already-installed
 *      builds still signing with a still-valid id.
 *   3. OBSERVE -> ENFORCE: with an absent/empty secret this is a safe no-op the workers allow, so the app
 *      keeps working until every shipping client signs and we flip enforce. An unprovisioned Android build
 *      (no `VORTX_EDGE_SECRET` BuildConfig field) resolves the secret to "" and behaves exactly this way.
 *
 * THE SIGNING CONTRACT (must match the workers AND Apple byte-for-byte):
 *   - Header `X-VX-Ts`:  current unix time in SECONDS, integer string.
 *   - Header `X-VX-Kid`: the key id the signature was made with.
 *   - Header `X-VX-Sig`: lowercase hex of HMAC-SHA256(key, message).
 *   - key     = UTF-8 bytes of the 64-char hex secret STRING (NOT hex-decoded): `secret.toByteArray(UTF_8)`.
 *   - message = METHOD (uppercase) + "\n" + percent-encoded path + "\n" + ts (matches the workers'
 *     `url.pathname`, which is percent-encoded; `java.net.URL.getPath()` returns the path UNDECODED, so it
 *     lines up with Apple's `URLComponents.percentEncodedPath`).
 *
 * PROVISIONING (kept identical to Apple): compute the masked value once with [maskedValue] over the raw
 * 64-hex secret, then ship it via `buildConfigField("String", "VORTX_EDGE_SECRET", "\"<masked>\"")` paired
 * with a matching [KEY_ID] and the id -> secret entry on the workers, BEFORE the build ships. The mask
 * fragments below are the SAME bytes as Apple, so a masked blob provisioned on either platform de-masks
 * identically.
 */
object VortXEdgeAuth {
    private const val TS_HEADER = "X-VX-Ts"
    private const val SIG_HEADER = "X-VX-Sig"
    private const val KID_HEADER = "X-VX-Kid"

    /**
     * Query-param names for the header-less signing variant ([signedUrl]). These MUST match the workers'
     * shared `edge_auth.ts` (`SIG_QUERY_TS` / `SIG_QUERY_SIG` / `SIG_QUERY_KID`) and the Apple client.
     */
    private const val TS_QUERY = "vts"
    private const val SIG_QUERY = "vsig"
    private const val KID_QUERY = "vkid"

    /**
     * Current signing key id. Rotation is a TWO-part change provisioned together: a NEW masked
     * `VORTX_EDGE_SECRET` AND this new kid, plus the matching new id -> secret entry on the workers BEFORE
     * the build ships; revoke the old id after a grace window. Matches the Apple `keyId`.
     */
    private const val KEY_ID = "k1"

    /** SHA-256 HMAC block size, used to build the standard empty-key HMAC in observe mode (see [hexSignature]). */
    private const val HMAC_BLOCK_SIZE = 64

    /** Reuse an already-signed URL for this long before re-signing (half the 300s worker skew window). */
    private const val SIGNED_URL_REUSE_MS = 150_000L

    /** Bound the [signedUrl] memo cache across a long browse session. */
    private const val SIGNED_URL_CACHE_CAP = 512

    /**
     * Hosts WE operate behind the signing gate. `api.vortx.tv` is deliberately EXCLUDED (account-authed).
     * Identical to the Apple `gatedHosts`.
     */
    private val GATED_HOSTS: Set<String> = setOf(
        "skip.vortx.tv", "trickplay.vortx.tv", "ratings.vortx.tv", "poster.vortx.tv", "erdb.vortx.tv",
        "trailer.vortx.tv", "catalogs.vortx.tv", "config.vortx.tv", "subtitles.vortx.tv", "add.vortx.tv",
        "sources.vortx.tv", "watch.vortx.tv", "iptv.vortx.tv",
    )

    /**
     * The runtime de-mask key, assembled from two scattered fragments so it is not a single findable
     * literal. XORing these two equal-length byte runs yields the actual 32-byte mask applied to the
     * secret. These are the SAME bytes as the Apple `maskFragmentA` / `maskFragmentB`.
     */
    private val MASK_FRAGMENT_A = intArrayOf(
        0x9e, 0x41, 0xb7, 0x2c, 0xd5, 0x6a, 0x03, 0xf8, 0x11, 0xae, 0x77, 0x50, 0xc9, 0x34, 0x8b, 0x22,
        0x5f, 0xe0, 0x19, 0xa6, 0x7d, 0xc2, 0x3b, 0x94, 0x08, 0xbf, 0x66, 0xd1, 0x4a, 0xe7, 0x2d, 0x80,
    )
    private val MASK_FRAGMENT_B = intArrayOf(
        0x37, 0xdc, 0x61, 0x8a, 0x1f, 0xb4, 0x49, 0xe2, 0x7b, 0x06, 0x95, 0x28, 0xc3, 0x5e, 0xf1, 0x40,
        0xa9, 0x12, 0x8f, 0x64, 0xd3, 0x38, 0xad, 0x02, 0x71, 0xce, 0x1b, 0x84, 0x39, 0x96, 0x4f, 0xba,
    )
    private val MASK: ByteArray =
        ByteArray(MASK_FRAGMENT_A.size) { i -> (MASK_FRAGMENT_A[i] xor MASK_FRAGMENT_B[i]).toByte() }

    /**
     * The real secret (64-hex STRING), de-masked at runtime. `BuildConfig.VORTX_EDGE_SECRET` holds
     * base64( XOR(secretUTF8, mask-repeated) ). Absent/empty/malformed => "" (no-op signing, observe-safe),
     * matching the Apple `secret`. Read once (lazy), never crashes. Never stored as plaintext in source.
     */
    private val secret: String by lazy { resolveSecret() }

    /** Cache guard for [signedUrl] (`signedUrl` may be called from many image-load threads). */
    private val cacheLock = Any()
    private val signedUrlCache = HashMap<String, CachedSignedUrl>()

    private data class CachedSignedUrl(val signed: String, val atMs: Long)

    /**
     * Sign [connection] IFF its URL host is one of our gated services. No-op otherwise. Sets the three
     * `X-VX-*` request headers. Never throws. With an empty (unprovisioned) secret it still stamps the
     * (empty-key) signature so the wire shape is identical in observe and enforce modes, matching Apple.
     *
     * CONTRACT: call this AFTER setting the request method + URL and BEFORE `connect()` / reading streams,
     * mirroring the Apple "stamp right before send". Uses the connection's current `requestMethod`.
     */
    fun sign(connection: HttpURLConnection) {
        val headers = signingHeaders(connection.requestMethod ?: "GET", connection.url) ?: return
        connection.setRequestProperty(TS_HEADER, headers.ts)
        connection.setRequestProperty(KID_HEADER, headers.kid)
        connection.setRequestProperty(SIG_HEADER, headers.sig)
    }

    /** The three signing header values for a gated ([method], [url]) pair, or null for a non-gated host. */
    data class SigningHeaders(val ts: String, val kid: String, val sig: String)

    /**
     * Compute the `X-VX-Ts` / `X-VX-Kid` / `X-VX-Sig` values for a gated host, or null when [url]'s host is
     * not one of ours. Framework-agnostic core so any HTTP stack (HttpURLConnection, OkHttp, Ktor) can
     * stamp the same headers. Never throws.
     */
    fun signingHeaders(method: String, url: URL): SigningHeaders? {
        val host = url.host ?: return null
        if (host !in GATED_HOSTS) return null
        val m = method.uppercase()
        val ts = (System.currentTimeMillis() / 1000L).toString()
        val sig = hexSignature(m, signedPath(url), ts)
        return SigningHeaders(ts = ts, kid = KEY_ID, sig = sig)
    }

    /**
     * Return a QUERY-signed copy of [url] for header-less asset loads (Coil `AsyncImage` / `<img>` GETs
     * that cannot attach `X-VX-*` headers). Appends `vts` / `vkid` / `vsig`, where `vsig` is the SAME
     * `HMAC-SHA256(key, METHOD\npath\nts)` the header path computes, so a worker verifies a query-signed
     * image GET exactly as it verifies a header-signed API call.
     *
     * FAIL-OPEN by contract, matching Apple: returns [url] UNCHANGED for a non-gated host, an unprovisioned
     * build (empty secret), or any URL that cannot be parsed. Prefer [sign] whenever the caller controls a
     * request (headers are not part of an image cache key, whereas a per-second `vts` in the URL is).
     */
    fun signedUrl(url: String, method: String = "GET"): String {
        val parsed = runCatching { URL(url) }.getOrNull() ?: return url
        val host = parsed.host ?: return url
        if (host !in GATED_HOSTS || secret.isEmpty()) return url

        val m = method.uppercase()
        val now = System.currentTimeMillis()
        // MEMO: reuse the previously-signed URL for this (method, raw URL) while it is still well inside the
        // worker skew window, so repeated image loads get a STABLE URL (no cache bust). Key on the RAW URL;
        // the idempotent strip below keeps a raw URL free of our signing params so the key is stable.
        val cacheKey = "$m\n$url"
        synchronized(cacheLock) {
            signedUrlCache[cacheKey]?.let { hit ->
                if (now - hit.atMs < SIGNED_URL_REUSE_MS) return hit.signed
            }
        }

        val ts = (now / 1000L).toString()
        val sig = hexSignature(m, signedPath(parsed), ts)
        val signed = appendSigningParams(url, ts, sig)

        synchronized(cacheLock) {
            if (signedUrlCache.size >= SIGNED_URL_CACHE_CAP) {
                // Drop entries already past the reuse horizon (they would re-sign anyway).
                val expiredKeys = signedUrlCache.filterValues { now - it.atMs >= SIGNED_URL_REUSE_MS }.keys.toList()
                for (k in expiredKeys) signedUrlCache.remove(k)
            }
            signedUrlCache[cacheKey] = CachedSignedUrl(signed, now)
        }
        return signed
    }

    /** [signedUrl] overload for callers holding a [URL]. Returns a [URL] (or the input on any parse issue). */
    fun signedUrl(url: URL, method: String = "GET"): URL {
        val signed = signedUrl(url.toString(), method)
        return runCatching { URL(signed) }.getOrDefault(url)
    }

    /**
     * The canonical signed path: the PERCENT-ENCODED path so it matches the workers, which verify against
     * `url.pathname` (percent-encoded in the Workers runtime). `java.net.URL.getPath()` returns the path
     * UNDECODED (unlike `URI.getPath()`), so a gated route with an encodable char signs the encoded path
     * and matches the worker's encoded one. ASCII paths are unaffected. Empty path signs as "" (rare).
     */
    private fun signedPath(url: URL): String = url.path ?: ""

    /**
     * Idempotently append `vts` / `vkid` / `vsig` to [rawUrl]: strip any prior signing params first (so
     * re-signing never accumulates duplicates), preserving the rest of the query and any fragment. The
     * three appended params sit OUTSIDE the signed message (METHOD + path + ts), so they never invalidate
     * the signature.
     */
    private fun appendSigningParams(rawUrl: String, ts: String, sig: String): String {
        val hashIdx = rawUrl.indexOf('#')
        val fragment = if (hashIdx >= 0) rawUrl.substring(hashIdx) else ""
        val beforeFragment = if (hashIdx >= 0) rawUrl.substring(0, hashIdx) else rawUrl
        val qIdx = beforeFragment.indexOf('?')
        val base = if (qIdx >= 0) beforeFragment.substring(0, qIdx) else beforeFragment
        val query = if (qIdx >= 0) beforeFragment.substring(qIdx + 1) else ""

        val kept = query.split('&')
            .filter { pair ->
                if (pair.isEmpty()) return@filter false
                val name = pair.substringBefore('=')
                name != TS_QUERY && name != SIG_QUERY && name != KID_QUERY
            }
        // vts / vkid / vsig values are integer / "k1" / lowercase-hex, all URL-safe, so no encoding needed
        // (Apple's URLQueryItem likewise leaves them intact).
        val rebuilt = (kept + listOf("$TS_QUERY=$ts", "$KID_QUERY=$KEY_ID", "$SIG_QUERY=$sig")).joinToString("&")
        return "$base?$rebuilt$fragment"
    }

    /**
     * Lowercase-hex `HMAC-SHA256(key, METHOD\npath\nts)`. `key` = UTF-8 bytes of the 64-char hex secret
     * STRING (NOT hex-decoded), matching the workers and Apple. With an empty (unprovisioned) secret this
     * computes the STANDARD empty-key HMAC: JCE rejects a zero-length key, but HMAC zero-pads a short key to
     * the block size, so a 64-byte all-zero key yields the identical MAC as Apple's `SymmetricKey(data:
     * Data())`. The header path stamps it regardless (identical wire shape in observe + enforce), while
     * [signedUrl] fails open before ever reaching here.
     */
    private fun hexSignature(method: String, signedPath: String, ts: String): String {
        val message = "$method\n$signedPath\n$ts"
        val keyBytes = if (secret.isEmpty()) ByteArray(HMAC_BLOCK_SIZE) else secret.toByteArray(Charsets.UTF_8)
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(keyBytes, "HmacSHA256"))
        val digest = mac.doFinal(message.toByteArray(Charsets.UTF_8))
        val sb = StringBuilder(digest.size * 2)
        for (b in digest) sb.append("%02x".format(b.toInt() and 0xFF))
        return sb.toString()
    }

    /**
     * De-mask the build-injected masked blob into the real 64-hex secret. Mirrors the Apple `secret`
     * computed property: read the masked value, base64-decode it, XOR by the repeated [MASK], and require a
     * 64-char hex result; anything else (absent field, bad base64, placeholder config) => "" (no-op,
     * observe-safe). Never throws.
     */
    private fun resolveSecret(): String {
        val masked = readMaskedSecret()?.trim()?.takeIf { it.isNotEmpty() } ?: return ""
        val blob = runCatching { Base64.getDecoder().decode(masked) }.getOrNull()
        if (blob == null || blob.isEmpty() || MASK.isEmpty()) return ""
        val out = ByteArray(blob.size) { i -> (blob[i].toInt() xor MASK[i % MASK.size].toInt()).toByte() }
        val s = out.toString(Charsets.UTF_8)
        return if (s.length == 64 && s.all { it.isHexDigitChar() }) s else ""
    }

    /**
     * Read the masked secret from `com.vortx.android.BuildConfig.VORTX_EDGE_SECRET`, the Android
     * build-config channel that parallels the Apple Info.plist `VortXEdgeSecret` key. Read REFLECTIVELY so
     * this class compiles + runs as an observe-safe no-op even before the field is provisioned in gradle
     * (an absent field simply resolves the secret to ""); once `buildConfigField("String",
     * "VORTX_EDGE_SECRET", ...)` is added the signer picks it up with no code change. Never throws.
     */
    private fun readMaskedSecret(): String? = runCatching {
        val clazz = Class.forName("com.vortx.android.BuildConfig")
        clazz.getField("VORTX_EDGE_SECRET").get(null) as? String
    }.getOrNull()

    private fun Char.isHexDigitChar(): Boolean =
        this in '0'..'9' || this in 'a'..'f' || this in 'A'..'F'

    /**
     * One-off provisioning helper: compute the MASKED `VORTX_EDGE_SECRET` value from a raw 64-hex secret,
     * so provisioning never puts the plaintext key in gradle/BuildConfig. Not called at runtime; kept here
     * so the mask stays the single source of truth. Produces the SAME blob as the Apple `maskedValue(for:)`
     * (same fragments, same standard base64), so a value provisioned on either platform de-masks on both.
     */
    fun maskedValue(rawHexSecret: String): String {
        if (MASK.isEmpty()) return ""
        val bytes = rawHexSecret.toByteArray(Charsets.UTF_8)
        val out = ByteArray(bytes.size) { i -> (bytes[i].toInt() xor MASK[i % MASK.size].toInt()).toByte() }
        return Base64.getEncoder().encodeToString(out)
    }
}
