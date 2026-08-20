package com.vortx.android.communityjs

/** Narrow JNI contract. All calls run from [CommunityJsRuntime] on a worker dispatcher. */
internal object CommunityJsNative {
    init {
        System.loadLibrary("vortx_community_js")
    }

    external fun evaluate(
        host: CommunityJsRuntime.NativeFetch,
        code: String,
        tmdbId: String,
        mediaType: String,
        settingsJson: String,
        season: Int,
        episode: Int,
        timeoutMs: Long,
        memoryLimitBytes: Long,
    ): String
}
