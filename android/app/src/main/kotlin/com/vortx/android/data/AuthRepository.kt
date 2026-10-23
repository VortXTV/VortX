package com.vortx.android.data

import com.vortx.android.model.AuthState
import com.vortx.android.profile.ProfileSelectionRequest
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class AuthManagement(val canManage: Boolean = true, val message: String? = null, val revision: String? = null)
private val unrestrictedAuthManagement = MutableStateFlow(AuthManagement()).asStateFlow()

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
    val management: StateFlow<AuthManagement> get() = unrestrictedAuthManagement

    /// Email/password sign-in against the account API, through the engine (mirrors Apple
    /// `StremioAccount.signIn`/`CoreBridge`'s `Authenticate`). Success is reflected via [authState]
    /// (the caller doesn't need the returned [Unit] for anything but the up/down signal); failure
    /// carries the engine/API's own message so the UI shows the real reason (bad password, no
    /// network, ...), never a generic string.
    suspend fun signIn(email: String, password: String): Result<Unit>
    suspend fun signInForRevision(email: String, password: String, revision: String?): Result<Unit> = signIn(email, password)

    /** Legacy account handoff only; native profile authority never calls this optional auth seam. */
    suspend fun completeProfileSelection(request: ProfileSelectionRequest): Result<Boolean> =
        Result.failure(IllegalStateException("This account connection is unavailable. Choose the profile again."))
    suspend fun signInForProfileSelection(request: ProfileSelectionRequest, email: String, password: String): Result<Unit> =
        Result.failure(IllegalStateException("This account connection is unavailable. Choose the profile again."))

    /// Sign out. Always succeeds locally (clears the account state) even if the network round-trip to
    /// invalidate the server-side session fails -- the user's device should never get "stuck" signed
    /// in because of a network blip.
    suspend fun signOut()
    suspend fun signOutForRevision(revision: String?) = signOut()
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
