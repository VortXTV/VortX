package com.vortx.android.sync

import com.vortx.android.engine.NativeProfileOverlayWitness
import java.math.BigDecimal
import org.json.JSONObject

/** A witnessed worker write requires the candidate's exact GET base and its successor revision.
 * A candidate derived from base N uses N+1; authenticated absence uses create-only revision zero.
 * Wall time, local high-water marks, and a rejected PUT's echo are never candidate authority. */
internal object BackupRevisionPolicy {
    const val MAX_VERSION = 9_007_199_254_740_991L

    fun parse(value: Any?): Long? {
        if (value !is Number) return null
        return runCatching { BigDecimal(value.toString()).longValueExact() }
            .getOrNull()?.takeIf { it in 0..MAX_VERSION }
    }

    /** Null is reserved for an authenticated missing row; zero is its create-only revision. */
    fun next(baseVersion: Long?): Long? = when {
        baseVersion == null -> 0L
        baseVersion in 0 until MAX_VERSION -> baseVersion + 1
        else -> null
    }

    /** Preserve original number lexemes before Android org.json can round a fractional MAX value.
     * Uses the existing strict duplicate-rejecting JSON ingress; no new parser or crypto format. */
    fun decodeResponse(text: String): JSONObject? = runCatching {
        NativeProfileOverlayWitness.parseDocument(text.toByteArray(Charsets.UTF_8))
    }.getOrNull()
}
