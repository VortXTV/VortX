package com.vortx.android.communityjs

/**
 * Conservative UTF-16 string limits for every AIDL hop. Binder's transaction limit is shared
 * with parcel metadata, so these are intentionally substantially below one MiB.
 */
internal object CommunityJsBinderPayloads {
    const val MAX_TOKEN_CHARS = 128
    const val MAX_EXECUTE_CODE_CHARS = 192 * 1024
    const val MAX_EXECUTE_SETTINGS_CHARS = 64 * 1024
    const val MAX_MEDIA_ID_CHARS = 64
    const val MAX_MEDIA_TYPE_CHARS = 8
    const val MAX_FETCH_URL_CHARS = 16 * 1024
    const val MAX_FETCH_OPTIONS_CHARS = 64 * 1024
    const val MAX_FETCH_RESPONSE_CHARS = 192 * 1024

    fun isExecuteRequestSafe(
        token: String,
        code: String,
        tmdbId: String,
        mediaType: String,
        settingsJson: String,
    ): Boolean =
        token.length <= MAX_TOKEN_CHARS &&
            code.length <= MAX_EXECUTE_CODE_CHARS &&
            tmdbId.length <= MAX_MEDIA_ID_CHARS &&
            mediaType.length <= MAX_MEDIA_TYPE_CHARS &&
            settingsJson.length <= MAX_EXECUTE_SETTINGS_CHARS

    fun isFetchRequestSafe(token: String, url: String, optionsJson: String): Boolean =
        token.length <= MAX_TOKEN_CHARS &&
            url.length <= MAX_FETCH_URL_CHARS &&
            optionsJson.length <= MAX_FETCH_OPTIONS_CHARS

    fun boundedFetchResponse(response: String): String =
        if (response.length <= MAX_FETCH_RESPONSE_CHARS) response else COMMUNITY_JS_EMPTY_FETCH_RESPONSE
}

/** Calls the remote callback only after its outbound Binder payload has passed the local budget. */
internal fun communityJsFetchOverBinder(
    token: String,
    url: String,
    optionsJson: String,
    remainingTimeoutMs: Long,
    invoke: (String, String, String, Long) -> String,
): String {
    if (!CommunityJsBinderPayloads.isFetchRequestSafe(token, url, optionsJson)) {
        return COMMUNITY_JS_EMPTY_FETCH_RESPONSE
    }
    return CommunityJsBinderPayloads.boundedFetchResponse(
        runCatching { invoke(token, url, optionsJson, remainingTimeoutMs) }
            .getOrDefault(COMMUNITY_JS_EMPTY_FETCH_RESPONSE),
    )
}

/** Starts the broker Binder call only after every outbound string is within its parcel budget. */
internal fun communityJsExecuteOverBinder(
    token: String,
    code: String,
    tmdbId: String,
    mediaType: String,
    settingsJson: String,
    invoke: () -> Unit,
): Boolean {
    if (!CommunityJsBinderPayloads.isExecuteRequestSafe(token, code, tmdbId, mediaType, settingsJson)) {
        return false
    }
    invoke()
    return true
}

internal const val COMMUNITY_JS_EMPTY_FETCH_RESPONSE =
    "{\"status\":0,\"statusText\":\"Unavailable\",\"body\":\"\",\"headers\":{}}"
