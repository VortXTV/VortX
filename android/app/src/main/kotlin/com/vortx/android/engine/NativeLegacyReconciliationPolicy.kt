package com.vortx.android.engine

import org.json.JSONObject

/**
 * A rejected old-format (legacy) delta is held, never fatal. The kernel's reconcile is atomic, so a
 * rejection leaves native state untouched; the same legacy carriers are offered again on the next sync
 * while native merges keep landing. Only reconciliation is holdable: every other rejected action still
 * fails its whole batch. Mirrors Apple `VortxNativeSession.LegacyReconciliation` (0.5.0 Beta 6).
 */
internal object NativeLegacyReconciliationPolicy {
    const val ACTION = "reconcile_legacy_sync"
    private val kernelPhrase = Regex("^[a-z][a-z0-9 /_-]*$")

    fun holdable(action: JSONObject): Boolean = action.optString("type") == ACTION

    /**
     * Kernel rejections are fixed lowercase phrases. Anything else (for example a serde message quoting
     * material bytes) is reduced to a constant so no account data reaches a log.
     */
    fun rejectionCode(response: String): String {
        val text = runCatching { JSONObject(response).opt("error") }.getOrNull() as? String ?: return "unclassified"
        if (text.length > 120 || !kernelPhrase.matches(text)) return "unclassified"
        return text.replace(' ', '_')
    }
}
