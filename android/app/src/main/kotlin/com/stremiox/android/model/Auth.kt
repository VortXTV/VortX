package com.stremiox.android.model

/// The signed-in/out state of the account, mirroring `ctx.profile.auth` in the shared engine (present
/// = signed in, absent = signed out -- the same test Apple `CoreBridge.isLoggedIn` uses). The account
/// screen and Settings' Account row render off this; the real engine implementation derives it live
/// from `ctx`, the preview implementation fakes it locally.
sealed interface AuthState {
    data object SignedOut : AuthState

    /// [email]/[uid] are nullable because a still-hydrating ctx or an unusual account record can omit
    /// either -- the UI shows what it has (falls back to "Signed in" with no email) rather than
    /// crashing on a missing field.
    data class SignedIn(val email: String?, val uid: String?) : AuthState
}
