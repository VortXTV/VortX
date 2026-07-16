package com.vortx.android.mediaserver

/// Emby AUTH. Emby shares Jellyfin's REST surface for everything EXCEPT the sign-in header: Emby reads the
/// MediaBrowser value from `X-Emby-Authorization`, Jellyfin from `Authorization`. So Emby's connect flow is
/// just [JellyfinClient.authenticateByName] with that header field, and its RESOLUTION reuses
/// [JellyfinProvider] unchanged (the coordinator builds it for `.emby` too). Kotlin port of the Emby half of
/// `app/SourcesShared/MediaServerAuth.swift`.
///
/// Emby has no Quick Connect device flow here (matching Apple), so it is username + password only. The
/// password is used for the one exchange and never stored; only the returned token is persisted (Keychain).
object EmbyClient {

    suspend fun authByPassword(base: String, username: String, password: String, deviceId: String): MediaServerAuthResult =
        JellyfinClient.authenticateByName(
            base = base,
            username = username,
            password = password,
            headerField = "X-Emby-Authorization",
            deviceId = deviceId,
        )
}
