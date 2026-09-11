package com.vortx.android.ui.components

/** Preserve add-on-authored text; parsed badges are supplementary, not a replacement formatter. */
internal fun sourceAuthoredText(title: String, description: String?): String =
    listOfNotNull(title, description).filter { it.isNotBlank() }.distinct().joinToString("\n")
