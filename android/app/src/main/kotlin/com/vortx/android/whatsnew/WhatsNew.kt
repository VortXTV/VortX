package com.vortx.android.whatsnew

import android.content.Context
import com.vortx.android.BuildConfig

object WhatsNew {
    val version: String get() = BuildConfig.VERSION_NAME

    val highlights: List<String> = listOf(
        "Playback controls now expose subtitle and audio timing without leaving the player.",
        "VortX account sign-in can be approved from another device with a QR code.",
        "Android phone and TV share the same profile, source, playback, and sync settings.",
        "Detail heroes now show title logos supplied by installed add-ons.",
    )

    fun load(context: Context): List<ChangelogBlock> {
        val parsed = runCatching {
            context.assets.open("CHANGELOG.md").bufferedReader().use { ChangelogParser.parse(it.readText()) }
        }.getOrDefault(emptyList())
        return parsed.ifEmpty(::fallbackBlocks)
    }

    internal fun fallbackBlocks(): List<ChangelogBlock> = buildList {
        add(ChangelogBlock(ChangelogBlockKind.VERSION, "VortX $version"))
        highlights.forEach { add(ChangelogBlock(ChangelogBlockKind.BULLET, it)) }
    }
}
