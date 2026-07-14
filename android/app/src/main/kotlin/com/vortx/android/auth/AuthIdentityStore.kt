package com.vortx.android.auth

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

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
    private val prefs: SharedPreferences = openPrefs(context.applicationContext)

    /// The last-known signed-in email, or null if the cache says signed-out (or was never written).
    fun cachedEmail(): String? = prefs.getString(KEY_EMAIL, null)

    /// Record a signed-in identity (called whenever [AuthState] becomes `SignedIn`).
    fun rememberSignedIn(email: String?) {
        prefs.edit().putString(KEY_EMAIL, email).apply()
    }

    /// Clear the cache (called on sign-out).
    fun forget() {
        prefs.edit().remove(KEY_EMAIL).apply()
    }

    private companion object {
        const val TAG = "AuthIdentityStore"
        const val ENCRYPTED_FILE = "vortx_auth_identity"
        const val PLAIN_FALLBACK_FILE = "vortx_auth_identity_plain"
        const val KEY_EMAIL = "email"

        /// Same fail-soft pattern as [com.vortx.android.debrid.DebridKeys.openPrefs]: prefer the
        /// AES-encrypted store, fall back to a plain file only if Keystore/security-crypto itself is
        /// unavailable, so a storage-layer problem degrades the UI (a slower first paint of the account
        /// row) instead of crashing the app.
        fun openPrefs(appContext: Context): SharedPreferences = runCatching {
            val masterKey = MasterKey.Builder(appContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            EncryptedSharedPreferences.create(
                appContext,
                ENCRYPTED_FILE,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        }.getOrElse { error ->
            Log.w(TAG, "EncryptedSharedPreferences unavailable; falling back to plain prefs", error)
            appContext.getSharedPreferences(PLAIN_FALLBACK_FILE, Context.MODE_PRIVATE)
        }
    }
}
