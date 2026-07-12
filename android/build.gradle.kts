// Root build file. Plugin versions live in gradle/libs.versions.toml (the version catalog); this file
// only declares them (apply false) so each module applies what it needs. See the catalog header for
// the Kotlin-floor / Compose-BOM coupling rules. Kotlin 2.2+ is required both for the standalone
// Compose compiler plugin and to read dev.jdtech.mpv:libmpv:1.0.0's Kotlin 2.2.0 module metadata.
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
}
