package com.vortx.android.ui.prefs

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import java.lang.reflect.Proxy
import org.junit.Assert.*
import org.junit.Test

/** Real preference getter/setter with inert storage; no profile, account, or provider operations. */
class HomeDiscoverQuickViewPreferenceTest {
    @Test fun `new installation defaults Quick View on without writing a migration choice`() {
        val fixture = fixture()
        assertTrue(fixture.first.cinemaQuickView)
        assertTrue(fixture.second.isEmpty())
    }
    @Test fun `explicit legacy false survives default change and unrelated reads`() {
        val fixture = fixture(false)
        assertFalse(fixture.first.cinemaQuickView)
        fixture.first.mergeHomeDiscover
        assertEquals(mapOf(HomeDiscoverPreferences.KEY_CINEMA_QUICK_VIEW to false), fixture.second)
    }
    @Test fun `explicit true and future toggles keep exact same stored key`() {
        val fixture = fixture(true)
        assertTrue(fixture.first.cinemaQuickView)
        fixture.first.cinemaQuickView = false
        assertFalse(fixture.first.cinemaQuickView)
        fixture.first.cinemaQuickView = true
        assertTrue(fixture.first.cinemaQuickView)
        assertEquals(mapOf(HomeDiscoverPreferences.KEY_CINEMA_QUICK_VIEW to true), fixture.second)
    }
    @Test fun `fresh poster preference reads wide without persisting a migration override`() {
        val fixture = fixture(bindPosterStyle = true)
        assertTrue(PosterStylePreferences.state.value.landscape)
        assertTrue(fixture.second.isEmpty())
    }
    @Test fun `stored portrait remains authoritative and explicit later wide choice persists`() {
        val fixture = fixture(initialLandscape = false, bindPosterStyle = true)
        assertFalse(PosterStylePreferences.state.value.landscape)
        assertEquals(false, fixture.second[PosterStylePreferences.LANDSCAPE_KEY])
        PosterStylePreferences.setLandscape(true)
        assertTrue(PosterStylePreferences.state.value.landscape)
        assertEquals(true, fixture.second[PosterStylePreferences.LANDSCAPE_KEY])
    }
    private fun fixture(initial: Boolean? = null, initialLandscape: Boolean? = null,
                        bindPosterStyle: Boolean = false): Pair<HomeDiscoverPreferences, MutableMap<String, Any>> {
        val values = mutableMapOf<String, Any>()
        initial?.let { values[HomeDiscoverPreferences.KEY_CINEMA_QUICK_VIEW] = it }
        initialLandscape?.let { values[PosterStylePreferences.LANDSCAPE_KEY] = it }
        lateinit var editor: SharedPreferences.Editor
        editor = Proxy.newProxyInstance(SharedPreferences.Editor::class.java.classLoader, arrayOf(SharedPreferences.Editor::class.java)) { _, method, args ->
            when (method.name) {
                "putBoolean" -> { values[args!![0] as String] = args[1]; editor }
                "apply" -> Unit
                else -> error("Unexpected editor call ${method.name}")
            }
        } as SharedPreferences.Editor
        val prefs = Proxy.newProxyInstance(SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java)) { _, method, args ->
            when (method.name) {
                "getBoolean", "getString" -> values[args!![0]] ?: args[1]
                "edit" -> editor
                else -> error("Unexpected preference call ${method.name}")
            }
        } as SharedPreferences
        val context = object : ContextWrapper(null) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences = prefs
        }
        if (bindPosterStyle) PosterStylePreferences.init(context)
        return HomeDiscoverPreferences(context) to values
    }
}
