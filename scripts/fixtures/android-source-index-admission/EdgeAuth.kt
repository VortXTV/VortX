package com.vortx.android.net

/** A mistaken network-path invocation must fail, never silently sign or perform a request. */
object VortXEdgeAuth {
    fun sign(connection: java.net.HttpURLConnection): Unit = error("Network signing is outside this source-only fixture")
}
