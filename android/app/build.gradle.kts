plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.vortx.android"
    // compileSdk 36 (Android 16) requires AGP >= 8.10.0 (root build.gradle.kts / the version catalog
    // carry that pin). targetSdk now tracks compileSdk (S01: Android-16-baseline session) -- both at
    // 36. minSdk stays 26 (already above Media3 1.9's floor of 23; covers phones and Android TV).
    compileSdk = 36

    defaultConfig {
        applicationId = "com.vortx.android"
        minSdk = 26          // Android 8.0; covers phones and Android TV (Fire TV / Google TV)
        targetSdk = 36
        versionCode = 1
        versionName = "0.3.0"

        // Package ONLY the ABIs the Rust engine is cross-compiled for (the cargoNdkBuild task's
        // androidAbis list below). Without this, the libmpv AAR's extra armeabi-v7a/x86 slices made
        // AGP emit those ABIs too (verified by S03 APK inspection) -- and a 32-bit device would then
        // install a slice that has mpv but NO libstremiox_core.so, silently degrading the whole app
        // to preview data. One list, one truth: extend androidAbis + this together if 32-bit support
        // lands (S15 schedules armeabi-v7a via per-ABI splits for old Fire TV sticks).
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    // Product flavors split by DISTRIBUTION + LICENSING boundary, per the Android plan §1.3 / §3.
    //   - `full`  = the sideloaded VortX release. Carries libmpv (the GPLv3 mpv/ffmpeg native .so via
    //               dev.jdtech.mpv:libmpv, scoped to `fullImplementation` in dependencies {}), so
    //               libmpv is the PRIMARY player with Media3/ExoPlayer as the DV/Atmos fallback. This
    //               is the flavor we ship FIRST (mirrors the Apple sideload-IPA model).
    //   - `play`  = a lean Play-Store/Google-TV-bound build with NO GPL native libs (ExoPlayer only).
    //               It exists so a future Play listing stays clean of GPL/LGPL codec bits; it is NOT
    //               "the real player" -- libmpv-primary `full` is the product.
    // The flavor split is the licensing boundary ONLY. Keep the applicationId identical so sideload
    // update continuity + account migration are unaffected (the com.vortx.android namespace is a
    // hard invariant); flavors differ only by which player native libs are packaged.
    flavorDimensions += "distribution"
    productFlavors {
        create("full") {
            dimension = "distribution"
            // No applicationIdSuffix: the sideloaded `full` build keeps the canonical
            // com.vortx.android id so it updates existing sideloads in place.
        }
        create("play") {
            dimension = "distribution"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        // BuildConfig.DEBUG gates the design-system gallery screen (S02: ui/gallery/GalleryScreen.kt)
        // behind debug builds only, via a Settings row -- no separate launcher activity/manifest entry.
        buildConfig = true
    }

    // Baseline lint config (S01 gradle hygiene): keep real errors failing CI, but silence checks that
    // are structurally noisy for this skeleton rather than actual bugs. Extend this list as new
    // spurious checks show up; don't reach for abortOnError = false, that would hide real problems too.
    lint {
        disable += setOf(
            "MissingTranslation", // localeConfig ships English only for now (S01); see res/xml/locales_config.xml
            "ExtraTranslation",
            // The LEANBACK_LAUNCHER intent-filter (AndroidManifest.xml, pre-S01) makes lint want a TV
            // banner now. ANDROID-PLAN.md §0 "Form factors & packaging" explicitly schedules the TV
            // banner + the rest of the TV manifest work for S13, not S01 -- don't fail every PR in the
            // meantime for a deferred, already-planned requirement. Re-enable when S13 adds the banner.
            "MissingTvBanner",
        )
        checkReleaseBuilds = false // CI builds debug only today; release lint gating is an S15 concern.
        abortOnError = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    // Every version below is pinned once, in gradle/libs.versions.toml (S01: version catalog
    // migration) -- see that file's header for why each was chosen. compose-bom pins the whole
    // androidx.compose.* family, so ui/material3/material-icons-extended below take no version.
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons.extended)
    implementation(libs.activity.compose)
    implementation(libs.core.ktx)

    // AndroidX SplashScreen API (S01): backs Theme.VortX.Splash (res/values/themes.xml) so the cold
    // start shows the brand gold mark on warm obsidian instead of a blank window, uniformly from
    // minSdk 26 up (framework-owned on 31+, compat-drawn identically below it). See MainActivity.
    implementation(libs.core.splashscreen)

    // EncryptedSharedPreferences, so debrid API keys (credentials) are stored AES-encrypted at rest,
    // never in plain SharedPreferences. This is the Android analogue of the Apple Keychain the debrid
    // keys live in (app/SourcesShared/DebridKeys.swift). It resolves from mavenCentral() (already in
    // settings.gradle.kts) and pulls Tink transitively. DebridKeys reads it reflectively and falls
    // back to plain prefs if the artifact is ever absent, so the boundary never hard-fails the build.
    // NOTE: Google deprecated this artifact's APIs in 1.1.0 in favor of using Android Keystore
    // directly; we're staying on it for S01 (out of scope to migrate DebridKeys here), flagged for a
    // future session.
    implementation(libs.security.crypto)

    // ViewModel + collectAsStateWithLifecycle, so screens consume one-way state instead of calling
    // the repository inline. The real engine plugs in behind the repository with no ViewModel churn.
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.kotlinx.coroutines.android)

    // AndroidX Media3 (ExoPlayer): the player core. All media3 modules MUST share one version
    // (libs.versions.toml's single `media3` version, unchanged in S01).
    //   - exoplayer:      the player + DefaultRenderersFactory (its built-in DV -> HEVC/AVC/AV1
    //                     fallback is what we rely on; no hand-rolled codec selection).
    //   - exoplayer-hls:  HLS support, the format the in-process streaming server emits for torrents.
    //   - ui:             PlayerView (we drive it as a SurfaceView, never TextureView).
    //   - session:        MediaSession so background/notification/remote transport controls work.
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.exoplayer.hls)
    implementation(libs.media3.ui)
    implementation(libs.media3.session)

    // libmpv (PRIMARY player, sideloaded `full` flavor ONLY). The maven artifact ships the libmpv +
    // ffmpeg + player native .so set built from the mpv-android buildscripts: mpv 0.41.0 (the SAME
    // 0.41.0 line the Apple MPVKit-GPL build runs), ffmpeg 8.1 (--enable-gpl --enable-version3,
    // mediacodec + jni hwaccel), libplacebo 7.360.1 (the gpu-next renderer), dav1d 1.5.3. It also
    // ships a `dev.jdtech.mpv.MPVLib` JNI class that loads "mpv" + "player" via System.loadLibrary;
    // our thin com.vortx.android.player.mpv.MPVLib wraps it to the VortX contract, and MpvConfig
    // holds the option set ported from the Apple player.
    //
    // LICENSING: the mpv/ffmpeg native code is GPLv3 (ffmpeg built --enable-gpl --enable-version3),
    // so this dependency is confined to the `full` (sideload) flavor via `fullImplementation` and is
    // NEVER pulled into the `play` (Play-Store) flavor. This mirrors the Apple sideloaded MPVKit-GPL
    // distribution model. Coordinate resolves from mavenCentral() (already in settings.gradle.kts).
    "fullImplementation"(libs.mpv.libmpv)

    debugImplementation(libs.compose.ui.tooling)

    // kotlinx-coroutines-android (already pulled above for ViewModel/Flow) backs the engine seam's
    // event->coroutine bridge in com.vortx.android.engine. org.json (the engine JSON parser used
    // by EngineState/EngineActions) ships with the Android platform, so no extra JSON dependency.

    // Coil (S03): real poster/backdrop art in PosterCard's `art` slot. coil-compose ships the
    // AsyncImage composable + a default ImageLoader; coil-network-okhttp is Coil3's separated HTTP
    // engine (required since 3.0 split fetching out of coil-compose). Both flavors need it (posters
    // aren't GPL-licensed), so this is a plain `implementation`, not flavor-scoped.
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)
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
// StremioCoreNative.System.loadLibrary("stremiox_core").
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

    // In the `full` flavor two native-lib sources coexist: the cargo-ndk Rust output
    // (libstremiox_core.so) and the libmpv AAR (libmpv.so + libplayer.so + libavcodec.so +
    // libc++_shared.so). Both can ship a libc++_shared.so for the same ABI, which makes AGP's jniLibs
    // merge fail with "More than one file with OS independent path 'lib/<abi>/libc++_shared.so'". Take
    // the first; the C++ runtime is ABI-stable, so either copy is interchangeable. This is additive
    // and no-ops in the `play` flavor (no libmpv AAR, so no duplicate).
    packaging {
        jniLibs {
            pickFirsts += "**/libc++_shared.so"
        }
    }
}

// Make the native library exist before it is merged into the APK. merge*JniLibFolders is AGP's task
// that collects jniLibs; depending on it for every variant covers debug + release.
tasks.matching { it.name.startsWith("merge") && it.name.endsWith("JniLibFolders") }.configureEach {
    dependsOn(cargoNdkBuild)
}
