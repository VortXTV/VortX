// Root build file. Plugin versions come from gradle/libs.versions.toml (the S01 version catalog)
// instead of being hardcoded here -- see that file's header comment for why each version was
// chosen (AGP 8.10.0 is the floor for compileSdk/targetSdk 36; Kotlin stays 2.2.10, unchanged).
// Kotlin 2.0+ is required for the standalone Compose compiler plugin
// (org.jetbrains.kotlin.plugin.compose); Kotlin 2.2+ is required to read dev.jdtech.mpv:libmpv:1.0.0,
// whose .kotlin_module metadata is 2.2.0 (a 2.0.x compiler can only read metadata up to 2.1 and fails
// :app:compileFullDebugKotlin on it).
plugins {
    alias(libs.plugins.android.application) apply false
    // :mpv-seam (the W1-B source-built libmpv JNI seam) is an Android library module; same AGP pin.
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
}

// One native ABI contract for every Android module. The app, Rust cargo-ndk tasks, source-built
// libmpv seam, CI toolchain installer, and APK verification gates must all carry this same set.
// armeabi-v7a is required by 32-bit Fire TV hardware; x86 stays intentionally unsupported.
extra["vortxAndroidAbis"] = listOf("arm64-v8a", "armeabi-v7a", "x86_64")
