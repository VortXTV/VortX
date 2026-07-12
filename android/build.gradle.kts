// Root build file. Plugin versions declared here, applied per-module. Kotlin 2.0+ is required for
// the standalone Compose compiler plugin (org.jetbrains.kotlin.plugin.compose); Kotlin 2.2+ is
// required to read dev.jdtech.mpv:libmpv:1.0.0, whose .kotlin_module metadata is 2.2.0 (a 2.0.x
// compiler can only read metadata up to 2.1 and fails :app:compileFullDebugKotlin on it).
plugins {
    id("com.android.application") version "8.5.2" apply false
    id("org.jetbrains.kotlin.android") version "2.2.10" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.10" apply false
}
