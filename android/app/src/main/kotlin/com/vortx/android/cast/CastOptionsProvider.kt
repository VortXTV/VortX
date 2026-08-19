package com.vortx.android.cast

import android.content.Context
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionProvider

/// The Cast framework's required entry point. `CastContext.getSharedInstance(context)` reads the
/// fully-qualified name of THIS class from the `OPTIONS_PROVIDER_CLASS_NAME` manifest meta-data and calls
/// [getCastOptions] to configure itself; without it the framework throws on first use. It is referenced
/// only by the manifest (never constructed by first-party code), so it must be public with a no-arg
/// constructor.
///
/// FLAVOR SAFETY: the Cast framework (`play-services-cast-framework`) is a plain Google/AndroidX library
/// with no GPL native code, so this file lives in `src/main` and is compiled into BOTH the `full` and
/// `play` flavors. It pulls in no libmpv and keeps the `play` flavor GPL-clean.
class CastOptionsProvider : OptionsProvider {
    override fun getCastOptions(context: Context): CastOptions =
        CastOptions.Builder()
            .setReceiverApplicationId(CastConfig.RECEIVER_APP_ID)
            .build()

    /// No custom session providers: the default `CastSession` from the media receiver is all VortX needs.
    override fun getAdditionalSessionProviders(context: Context): MutableList<SessionProvider>? = null
}
