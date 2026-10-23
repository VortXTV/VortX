// Plugin versions are centralized in gradle/libs.versions.toml.
// AGP 9 supplies built-in Kotlin; the separately versioned Compose plugin matches Kotlin 2.4.21.
// Do not also apply org.jetbrains.kotlin.android to either Android module.
plugins {
    alias(libs.plugins.android.application) apply false
    // :mpv-seam (the W1-B source-built libmpv JNI seam) is an Android library module; same AGP pin.
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.compose) apply false
}

// One native ABI contract for every Android module. The app, Rust cargo-ndk tasks, source-built
// libmpv seam, CI toolchain installer, and APK verification gates must all carry this same set.
// armeabi-v7a is required by 32-bit Fire TV hardware; x86 stays intentionally unsupported.
extra["vortxAndroidAbis"] = listOf("arm64-v8a", "armeabi-v7a", "x86_64")

// One selection for BOTH the Full app and the seam's native linker inputs. An empty pair
// preserves the declared Maven baseline; a selected component is never relabeled as that GAV.
// Acquisition is explicit (scripts/acquire-android-mpv-component.py), never a Gradle download.
val mpvDescriptor = file("mpv-component.properties")
val mpvComponent = java.util.Properties().apply { mpvDescriptor.inputStream().use { load(it) } }
check(mpvComponent.stringPropertyNames() == setOf("url", "sha256")) { "Invalid mpv component descriptor" }
val mpvComponentUrl = mpvComponent.getProperty("url").trim()
val mpvComponentSha = mpvComponent.getProperty("sha256").trim()
val mpvComponentSelected = mpvComponentUrl.isNotEmpty() || mpvComponentSha.isNotEmpty()
extra["vortxMpvComponentSelected"] = mpvComponentSelected
if (mpvComponentSelected) {
    check(Regex("https://github\\.com/VortXTV/VortX/releases/download/vendor-[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\\.aar").matches(mpvComponentUrl)
        && Regex("[0-9a-f]{64}").matches(mpvComponentSha)) { "Both exact mpv component URL and SHA-256 are required" }
    val aar = file(".gradle/vortx-mpv-components/$mpvComponentSha/libmpv.aar")
    val verifyMpvComponent = tasks.register("verifyMpvComponent") {
        inputs.files(mpvDescriptor, aar)
        // No outputs/up-to-date bypass: re-hash the selected bytes on every consuming build.
        doLast {
            check(aar.isFile && aar.canonicalFile == aar.absoluteFile) {
                "Acquire the reviewed mpv component first; no Maven fallback is permitted"
            }
            val hash = java.security.MessageDigest.getInstance("SHA-256")
            aar.inputStream().use { input ->
                val buffer = ByteArray(1024 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    hash.update(buffer, 0, count)
                }
            }
            check(hash.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) } == mpvComponentSha) {
                "Selected mpv component bytes changed; refusing app/seam mismatch"
            }
        }
    }
    extra["vortxMpvAarDependency"] = files(aar).builtBy(verifyMpvComponent)
} else {
    extra["vortxMpvAarDependency"] = libs.mpv.libmpv
}
