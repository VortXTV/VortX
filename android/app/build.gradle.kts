plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.stremiox.android"
    // Media3 1.7+ must be built against SDK 35, so compileSdk moves 34 -> 35. AGP 8.5.2 supports it.
    // targetSdk stays at 34: bumping the runtime target is a separate behavioral change, not needed
    // to adopt the player. minSdk stays 26 (already above Media3 1.9's floor of 23).
    compileSdk = 35

    defaultConfig {
        applicationId = "com.stremiox.android"
        minSdk = 26          // Android 8.0; covers phones and Android TV (Fire TV / Google TV)
        targetSdk = 34
        versionCode = 1
        versionName = "0.3.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2024.09.02"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.core:core-ktx:1.13.1")

    // ViewModel + collectAsStateWithLifecycle, so screens consume one-way state instead of calling
    // the repository inline. The real engine plugs in behind the repository with no ViewModel churn.
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // AndroidX Media3 (ExoPlayer): the player core. All media3 modules MUST share one version.
    // 1.9.4 is the current stable line (released after 1.8.x); minSdk 23, built against compileSdk 35.
    //   - exoplayer:      the player + DefaultRenderersFactory (its built-in DV -> HEVC/AVC/AV1
    //                     fallback is what we rely on; no hand-rolled codec selection).
    //   - exoplayer-hls:  HLS support, the format the in-process streaming server emits for torrents.
    //   - ui:             PlayerView (we drive it as a SurfaceView, never TextureView).
    //   - session:        MediaSession so background/notification/remote transport controls work.
    val media3 = "1.9.4"
    implementation("androidx.media3:media3-exoplayer:$media3")
    implementation("androidx.media3:media3-exoplayer-hls:$media3")
    implementation("androidx.media3:media3-ui:$media3")
    implementation("androidx.media3:media3-session:$media3")

    debugImplementation("androidx.compose.ui:ui-tooling")

    // kotlinx-coroutines-android (already pulled above for ViewModel/Flow) backs the engine seam's
    // event->coroutine bridge in com.stremiox.android.engine. org.json (the engine JSON parser used
    // by EngineState/EngineActions) ships with the Android platform, so no extra JSON dependency.
}

// =====================================================================================================
// stremio-core JNI: build libstremiox_core.so from ../../core (Rust cdylib) and package it into the APK.
//
// APPENDED block, owned by the engine/JNI scope. It does NOT modify the android {} or dependencies {}
// blocks above (the gradle owner owns those). It only: (1) points jniLibs at a build-output dir, and
// (2) registers a cargo-ndk cross-compile task that the native-dependent variants depend on.
//
// The native library is produced by `cargo ndk` (https://github.com/bbqsrc/cargo-ndk, v3.x). The Rust
// side lives in core/ with crate-type = ["staticlib", "cdylib"]; the cdylib + the
// #[cfg(target_os = "android")] JNI surface (core/src/android_jni.rs) compile to the .so loaded by
// StremioXCore.System.loadLibrary("stremiox_core").
//
// Honest status: this is the build wiring (scaffold). It runs cargo-ndk when the Rust + NDK toolchain
// is present (CI installs it: rustup target add aarch64-linux-android..., cargo install cargo-ndk).
// On a machine without the toolchain the task is skipped with a warning so the Kotlin/Compose build
// still configures; the resulting APK simply won't contain the .so until built where cargo-ndk exists.
// =====================================================================================================

val coreCrateDir = rootProject.file("../core")
val jniLibsOutDir = layout.buildDirectory.dir("rustJniLibs/android")

// ABIs to ship. arm64 + x86_64 cover real devices (phones, Android TV, Fire TV) and the emulator.
// Add "armeabi-v7a" / "x86" only if 32-bit support becomes a requirement (it doubles build time).
val androidAbis = listOf("arm64-v8a", "x86_64")

// minSdk must match the android {} block above; passed to cargo-ndk as the platform level (-p 26).
val nativeApiLevel = 26

val cargoNdkBuild by tasks.registering(Exec::class) {
    group = "rust"
    description = "Cross-compile core/ to libstremiox_core.so for Android via cargo-ndk."
    workingDir = coreCrateDir

    val targetFlags = androidAbis.flatMap { listOf("-t", it) }
    // -o writes per-ABI subdirs (arm64-v8a/, x86_64/, ...) of .so files, the jniLibs layout.
    commandLine(
        buildList {
            add("cargo")
            add("ndk")
            addAll(targetFlags)
            add("-p"); add(nativeApiLevel.toString())
            add("-o"); add(jniLibsOutDir.get().asFile.absolutePath)
            add("build"); add("--release")
        },
    )

    // Skip gracefully when the toolchain is absent so non-Rust dev machines can still build the
    // Kotlin/Compose app. CI (android.yml) installs cargo-ndk + the Android Rust targets, so there the
    // task runs and the .so is packaged.
    val cargoOnPath = System.getenv("PATH").orEmpty().split(File.pathSeparator).any { dir ->
        File(dir, "cargo").exists() || File(dir, "cargo.exe").exists()
    }
    onlyIf {
        if (!cargoOnPath) {
            logger.warn("[stremiox-core] cargo not on PATH; skipping native build. APK will lack libstremiox_core.so until built with the Rust + cargo-ndk toolchain installed.")
        }
        cargoOnPath
    }
    // Don't fail the whole build if cargo-ndk errors during early scaffolding; surface it instead.
    isIgnoreExitValue = false
}

android {
    // Package the cargo-ndk output. Additive: srcDirs accumulates, so this coexists with any default
    // src/main/jniLibs the gradle owner may add.
    sourceSets.named("main") {
        jniLibs.srcDir(jniLibsOutDir)
    }
    // ndkVersion pins the NDK the cargo-ndk linker uses. Keep in sync with the NDK CI installs.
    ndkVersion = "27.2.12479018"
}

// Make the native library exist before it is merged into the APK. merge*JniLibFolders is AGP's task
// that collects jniLibs; depending on it for every variant covers debug + release.
tasks.matching { it.name.startsWith("merge") && it.name.endsWith("JniLibFolders") }.configureEach {
    dependsOn(cargoNdkBuild)
}
