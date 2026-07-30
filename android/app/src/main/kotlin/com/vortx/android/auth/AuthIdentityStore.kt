package com.vortx.android.auth

import android.content.Context
import com.vortx.android.security.FailClosedCredentialStore

/// A tiny, Keystore-encrypted cache of "who was last signed in", for instant UI display (Settings'
/// Account row, the account screen) before the engine's own `ctx` read has had a chance to land.
///
/// The engine is the actual source of truth for the account (invariant: "the engine is the truth" --
/// ANDROID-PLAN.md §0.3): [com.vortx.android.engine.EngineStremioRepository] hydrates its
/// `AuthState` from `ctx.profile.auth`, which the native side persists itself (its own storage under
/// the app's files dir), and that is what every sign-in/sign-out actually reads and writes. This store
/// holds nothing the engine needs back -- no auth token, no session key, just the display email/uid --
/// so a user could clear it entirely and lose nothing but a momentary "Not signed in" flash on next
/// launch. It exists only because the app must not cache ANY account identifier in plain
/// SharedPreferences (ANDROID-PLAN.md §0 invariant #5); this is the Keystore-backed home for that
/// display cache, the same pattern [com.vortx.android.debrid.DebridKeys] uses for debrid API keys.
class AuthIdentityStore(context: Context) {
    private val store = FailClosedCredentialStore(
        context = context,
        encryptedFileName = ENCRYPTED_FILE,
        legacyPlainFileName = PLAIN_FALLBACK_FILE,
        tag = TAG,
    )

    /// The last-known signed-in email, or null if the cache says signed-out (or was never written).
    fun cachedEmail(): String? = store.string(KEY_EMAIL)

    /// Record a signed-in identity (called whenever [AuthState] becomes `SignedIn`).
    fun rememberSignedIn(email: String?) {
        store.set(KEY_EMAIL, email)
    }

    /// Clear the cache (called on sign-out).
    fun forget() {
        store.clear(KEY_EMAIL)
    }

    private companion object {
        const val TAG = "AuthIdentityStore"
        const val ENCRYPTED_FILE = "vortx_auth_identity"
        const val PLAIN_FALLBACK_FILE = "vortx_auth_identity_plain"
        const val KEY_EMAIL = "email"

    }
}
