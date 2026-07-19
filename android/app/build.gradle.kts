import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// External sync provider credentials (Trakt device-code OAuth, SIMKL PIN flow). Injected into BuildConfig
// from a GITIGNORED gradle property (local.properties) or a CI env var of the same name -- mirroring the
// Apple release CI, which feeds $(TRAKT_CLIENT_ID)/$(TRAKT_CLIENT_SECRET)/$(SIMKL_CLIENT_ID) into the
// Info.plist from GitHub Actions secrets (see .github/workflows/release-tvos.yml). The real values NEVER
// live in this file (the repo is public); they sit only in the gitignored local.properties on a dev box,
// and come from `secrets.*` in CI. An absent value resolves to "" so a fresh/public clone ships the
// feature DORMANT: TraktAuth.isConfigured / SIMKLAuth.isConfigured stay false and nothing makes a network
// call, exactly like the Apple side. local.properties precedes the env var so a dev override wins locally.
val externalSyncProps = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
fun externalSyncSecret(name: String): String =
    (externalSyncProps.getProperty(name) ?: System.getenv(name) ?: "").trim()

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

        // External sync credentials -> BuildConfig (read by com.vortx.android.integrations.TraktAuth /
        // SIMKLAuth). Empty default keeps the feature dormant on a public/unprovisioned build; see the
        // externalSyncSecret() helper above. buildConfig = true is set in buildFeatures {} below.
        buildConfigField("String", "TRAKT_CLIENT_ID", "\"${externalSyncSecret("TRAKT_CLIENT_ID")}\"")
        buildConfigField("String", "TRAKT_CLIENT_SECRET", "\"${externalSyncSecret("TRAKT_CLIENT_SECRET")}\"")
        buildConfigField("String", "SIMKL_CLIENT_ID", "\"${externalSyncSecret("SIMKL_CLIENT_ID")}\"")
        buildConfigField("String", "SIMKL_CLIENT_SECRET", "\"${externalSyncSecret("SIMKL_CLIENT_SECRET")}\"")

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
            // MissingTvBanner is no longer suppressed: S13 landed the LEANBACK entry (TvActivity) with a
            // real `android:banner` (res/drawable/tv_banner.xml) on both <application> and the TV activity,
            // so the check now passes on its own merits rather than being silenced.
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

    // Tink, for `com.google.crypto.tink.subtle.X25519` ONLY -- the raw RFC 7748 X25519 scalar mult used by
    // the VortX E2E-account device-pairing crypto (com.vortx.android.sync.VortXPairingCrypto). Its shared
    // secret is byte-identical to the Apple app's CryptoKit Curve25519 and the webapp's WebCrypto X25519,
    // which is what lets a pairing handoff cross platforms. Pinned (libs.versions.toml) to the SAME version
    // security-crypto already pulls transitively, so this is an explicit re-declaration (self-documenting +
    // stable), not a new artifact. All other account crypto (PBKDF2 / AES-GCM / HKDF) is hand-rolled over
    // the JDK's javax.crypto in VortXCrypto, so Tink is the sole crypto dependency the account layer needs.
    implementation(libs.tink.android)

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

    // androidx.tv Compose-for-TV (S13): the Android TV 10-foot surface (com.vortx.android.ui.tv.*).
    // Provides the focus-first `androidx.tv.material3.Surface`/`Text`/`MaterialTheme` the D-pad browse +
    // detail tiles are built on. NOT flavor-scoped (no GPL native code), so both `full` and `play` carry
    // it. Version + forward-metadata-compat rationale in gradle/libs.versions.toml (tvMaterial). The TV
    // surface reuses the SAME repositories/ViewModels as the phone shell (HomeViewModel / DetailViewModel
    // via StremioXViewModelFactory) -- this dependency only supplies the 10-foot presentation layer, never
    // a parallel data path.
    implementation(libs.tv.material)

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

    // OkHttp (account realtime sync): the WebSocket client behind com.vortx.android.sync.VortXSyncRealtime
    // (the SyncRoom wss channel). Already on the runtime classpath transitively via coil-network-okhttp at
    // this exact version (see the catalog note), made explicit because sync code now imports okhttp3.*
    // directly -- first-party code never leans on a transitive coordinate it doesn't declare. Both flavors
    // (sync is not a licensing-boundary feature), so a plain `implementation`.
    implementation(libs.okhttp)

    // WorkManager (Round 5): the offline-downloads transport. com.vortx.android.downloads.DownloadWorker runs one
    // download as a foreground-service worker, which is what gives the Android port the two properties Apple gets
    // from its two URLSessions at once: the transfer survives process death (WorkManager persists the work and
    // re-runs it in a fresh process, where Apple's in-memory resumeData would be gone), and the app process stays
    // alive while it runs (so a loopback torrent transfer keeps the in-process streaming server up, which is what
    // Apple needs its foreground session + beginBackgroundTask assertion for). Both flavors need it -- downloads are
    // not a licensing-boundary feature -- so this is a plain `implementation`, not flavor-scoped.
    implementation(libs.work.runtime.ktx)
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

// stremiox-core is proprietary + lives in a PRIVATE repo. Resolve its checkout from (in order):
// STREMIOX_CORE_DIR env, the `stremiox.core.dir` gradle property, a sibling `../../stremiox-core`
// clone, else the legacy in-repo `../core` (removed from the public app repo). If none exist the
// task's onlyIf skips the native build (APK ships without libstremiox_core.so), same as no-cargo.
val coreCrateDir: File =
    (System.getenv("STREMIOX_CORE_DIR") ?: (project.findProperty("stremiox.core.dir") as? String))?.let(::File)
        ?: rootProject.file("../../stremiox-core").takeIf { it.exists() }
        ?: rootProject.file("../core")
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
        if (!coreCrateDir.exists()) {
            logger.warn("[stremiox-core] engine crate not found at ${coreCrateDir.path} (proprietary, private repo). Set STREMIOX_CORE_DIR or clone VortXTV/stremiox-core to ../../stremiox-core. APK will lack libstremiox_core.so.")
        }
        cargoOnPath && coreCrateDir.exists()
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

// =====================================================================================================
// vortx-core JNI (the OWN engine): build libvortx_ffi.so (features jni + server) into
// src/main/jniLibs and package it. Sibling of the cargoNdkBuild block above, same pattern,
// different crate: the source is the ENGINE branch's vortx-core workspace (crates/ffi), which is
// not vendored in this tree (the vortx-core/ dir here carries the kernel crates only, no ffi/
// streaming-server), so the checkout path comes from the environment:
//
//   VORTX_ENGINE_CORE_DIR=/path/to/engine-checkout/vortx-core   (env var), or
//   -Pvortx.engine.coreDir=/path/to/engine-checkout/vortx-core  (gradle property)
//
// When neither is set (or cargo is absent) the task warn-skips and the build packages whatever
// libvortx_ffi.so is already staged in src/main/jniLibs (the manual build documented in
// src/main/jniLibs/README.md) -- the .so binaries stay gitignored either way. `--features
// jni,server` carries BOTH JNI surfaces in the one .so: the VortxCore kernel bridge (shadow
// ranking) and the VortxServer in-process streaming server (raw-torrent playback).
// CARGO_TARGET_DIR is pinned to a task-owned scratch dir (target-andx) inside the engine checkout
// so this cross-build never dirties that checkout's own target/ build cache.
// =====================================================================================================

val vortxEngineCoreDir: File? = (
    System.getenv("VORTX_ENGINE_CORE_DIR")
        ?: (project.findProperty("vortx.engine.coreDir") as? String)
    )?.let(::File)

val vortxJniLibsDir = layout.projectDirectory.dir("src/main/jniLibs")

val cargoNdkBuildVortxFfi by tasks.registering(Exec::class) {
    group = "rust"
    description = "Cross-compile the engine branch's vortx-ffi (features jni,server) to libvortx_ffi.so via cargo-ndk."
    workingDir = vortxEngineCoreDir ?: coreCrateDir // placeholder wd when unset; onlyIf gates the run

    val targetFlags = androidAbis.flatMap { listOf("-t", it) }
    commandLine(
        buildList {
            add("cargo")
            add("ndk")
            addAll(targetFlags)
            add("-p"); add(nativeApiLevel.toString())
            add("-o"); add(vortxJniLibsDir.asFile.absolutePath)
            add("build"); add("-p"); add("vortx-ffi")
            add("--no-default-features"); add("--features"); add("jni,server")
            add("--release")
        },
    )
    vortxEngineCoreDir?.let { environment("CARGO_TARGET_DIR", File(it, "target-andx").absolutePath) }

    val cargoOnPath = System.getenv("PATH").orEmpty().split(File.pathSeparator).any { dir ->
        File(dir, "cargo").exists() || File(dir, "cargo.exe").exists()
    }
    onlyIf {
        val engineDirOk = vortxEngineCoreDir?.isDirectory == true
        if (!engineDirOk) {
            logger.warn("[vortx-ffi] VORTX_ENGINE_CORE_DIR / -Pvortx.engine.coreDir not set (or not a directory); skipping libvortx_ffi.so build. The APK packages whatever .so is already staged in src/main/jniLibs.")
        } else if (!cargoOnPath) {
            logger.warn("[vortx-ffi] cargo not on PATH; skipping libvortx_ffi.so build. The APK packages whatever .so is already staged in src/main/jniLibs.")
        }
        engineDirOk && cargoOnPath
    }
    isIgnoreExitValue = false
}

tasks.matching { it.name.startsWith("merge") && it.name.endsWith("JniLibFolders") }.configureEach {
    dependsOn(cargoNdkBuildVortxFfi)
}
