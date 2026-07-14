package com.vortx.android.data

import com.vortx.android.model.AuthState
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/// The account seam: the Compose account screen and Settings' Account row depend only on this, same
/// pattern as [CatalogRepository]. Separate interface (not folded into [CatalogRepository]) because
/// auth is account-level state every screen may want to *observe* (a live [StateFlow], not a one-shot
/// suspend call), and because keeping it apart means the existing [CatalogRepository] contract -- and
/// every ViewModel built against it -- is untouched by this session.
interface AuthRepository {
    /// The current signed-in/out state, live: emits again whenever the engine's `ctx.profile.auth`
    /// changes (sign-in, sign-out, or -- on first launch -- a persisted sign-in restored from the
    /// engine's own storage before this is ever read).
    val authState: StateFlow<AuthState>

    /// Email/password sign-in against the account API, through the engine (mirrors Apple
    /// `StremioAccount.signIn`/`CoreBridge`'s `Authenticate`). Success is reflected via [authState]
    /// (the caller doesn't need the returned [Unit] for anything but the up/down signal); failure
    /// carries the engine/API's own message so the UI shows the real reason (bad password, no
    /// network, ...), never a generic string.
    suspend fun signIn(email: String, password: String): Result<Unit>

    /// Sign out. Always succeeds locally (clears the account state) even if the network round-trip to
    /// invalidate the server-side session fails -- the user's device should never get "stuck" signed
    /// in because of a network blip.
    suspend fun signOut()
}

/// Offline preview/local-testing implementation: a small in-memory state machine so the sign-in
/// screen builds, runs, and is previewable before the engine is wired to it here. Any non-blank
/// email/password combination succeeds, matching the offline-preview convention already established
/// by [PreviewCatalogRepository] (looks intentional, never a hard error, until the real engine lands
/// behind the same seam).
class PreviewAuthRepository(private val latencyMs: Long = 300L) : AuthRepository {
    private val _authState = MutableStateFlow<AuthState>(AuthState.SignedOut)
    override val authState: StateFlow<AuthState> = _authState.asStateFlow()

    override suspend fun signIn(email: String, password: String): Result<Unit> {
        delay(latencyMs)
        if (email.isBlank() || password.isBlank()) {
            return Result.failure(IllegalArgumentException("Enter your email and password."))
        }
        _authState.value = AuthState.SignedIn(email = email.trim(), uid = "preview-uid")
        return Result.success(Unit)
    }

    override suspend fun signOut() {
        delay(latencyMs)
        _authState.value = AuthState.SignedOut
    }
}
