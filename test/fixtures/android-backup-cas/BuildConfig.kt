package com.vortx.android

/** Harness-only route selection. This file is outside Android source sets and contains no secrets. */
object BuildConfig {
    @JvmField val NATIVE_ENGINE_ENABLED = System.getProperty("vortx.test.native", "true").toBoolean()
    @JvmField val DEBUG = false
    @JvmField val APPLICATION_ID = "com.vortx.backup.fixture"
    @JvmField val BUILD_TYPE = "fixture"
    @JvmField val FLAVOR = "fixture"
    @JvmField val VERSION_CODE = 0
    @JvmField val VERSION_NAME = "fixture"
    @JvmField val SIMKL_CLIENT_ID = ""
    @JvmField val SIMKL_CLIENT_SECRET = ""
    @JvmField val TRAKT_CLIENT_ID = ""
    @JvmField val TRAKT_CLIENT_SECRET = ""
}
