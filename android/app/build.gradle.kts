import java.nio.file.Files
import java.util.Base64
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

val generatedChangelogAssets = layout.buildDirectory.dir("generated/changelogAssets")
@Suppress("UNCHECKED_CAST")
val androidAbis = rootProject.extra["vortxAndroidAbis"] as List<String>
val copyChangelogAsset = tasks.register<Copy>("copyChangelogAsset") {
    from(rootProject.file("../CHANGELOG.md"))
    into(generatedChangelogAssets)
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

// The VortX engine is the only engine. The two retired selection switches stay readable so an
// explicit request for the removed legacy build fails instead of being silently ignored. Gradle
// properties are authoritative when present; the environment variables are the fallback.
fun nativeBooleanFlag(propertyName: String, environmentName: String, defaultValue: Boolean): Boolean {
    val property = project.findProperty(propertyName) as? String
    val raw = property?.trim() ?: System.getenv(environmentName)?.trim()
    return when (raw?.lowercase()) {
        null -> defaultValue
        "", "false", "0" -> false
        "true", "1" -> true
        else -> throw GradleException(
            "$propertyName / $environmentName must be true/false or 1/0 (got '$raw')",
        )
    }
}

for ((propertyName, environmentName) in listOf(
    "vortx.nativeEngine" to "VORTX_NATIVE_ENGINE",
    "vortx.nativeResourceHost" to "VORTX_NATIVE_RESOURCE_HOST",
)) {
    if (!nativeBooleanFlag(propertyName, environmentName, defaultValue = true)) {
        throw GradleException(
            "$propertyName / $environmentName=false selected the removed legacy engine build; " +
                "every build uses the VortX engine with its resource host.",
        )
    }
}

// Release signing credentials stay outside the public repository. VORTX_KEYSTORE_PATH may be an
// existing local path or the base64 keystore value used by CI. Base64 input is decoded into an OS
// temporary file and removed when the Gradle process exits.
fun signingSecret(name: String): String? =
    System.getenv(name)?.trim()?.takeIf { it.isNotEmpty() }

val releaseSigningInputs = mapOf(
    "VORTX_KEYSTORE_PATH" to signingSecret("VORTX_KEYSTORE_PATH"),
    "VORTX_KEYSTORE_PASSWORD" to signingSecret("VORTX_KEYSTORE_PASSWORD"),
    "VORTX_KEY_ALIAS" to signingSecret("VORTX_KEY_ALIAS"),
    "VORTX_KEY_PASSWORD" to signingSecret("VORTX_KEY_PASSWORD"),
)
val missingReleaseSigningInputs = releaseSigningInputs.filterValues { it == null }.keys.sorted()
fun requireReleaseSigningInputs() {
    if (missingReleaseSigningInputs.isNotEmpty()) {
        throw GradleException(
            "Release signing inputs are required before configuring a release build. Missing: " +
                missingReleaseSigningInputs.joinToString(", "),
        )
    }
}

val releaseSelectingLifecycleTasks = setOf("assemble", "build", "bundle")
val releaseSigningRequested = gradle.startParameter.taskNames.any { requestedTask ->
    val taskName = requestedTask.substringAfterLast(':')
    taskName.contains("Release", ignoreCase = true) || taskName.lowercase() in releaseSelectingLifecycleTasks
}
if (releaseSigningRequested) {
    requireReleaseSigningInputs()
}
gradle.taskGraph.whenReady {
    if (allTasks.any { task -> task.name.contains("Release", ignoreCase = true) }) {
        requireReleaseSigningInputs()
    }
}

val releaseSigningReady = missingReleaseSigningInputs.isEmpty()
val releaseKeystoreValue = releaseSigningInputs.getValue("VORTX_KEYSTORE_PATH")
val releaseStorePassword = releaseSigningInputs.getValue("VORTX_KEYSTORE_PASSWORD")
val releaseKeyAlias = releaseSigningInputs.getValue("VORTX_KEY_ALIAS")
val releaseKeyPassword = releaseSigningInputs.getValue("VORTX_KEY_PASSWORD")
val releaseStoreFile: File? = if (releaseSigningReady) {
    val directFile = rootProject.file(releaseKeystoreValue!!)
    if (directFile.isFile) {
        directFile
    } else {
        Files.createTempFile("vortx-release-", ".jks").toFile().apply {
            writeBytes(Base64.getMimeDecoder().decode(releaseKeystoreValue))
            deleteOnExit()
            require(length() > 0L) { "VORTX_KEYSTORE_PATH decoded to an empty keystore" }
        }
    }
} else {
    null
}

android {
    namespace = "com.vortx.android"
    // Core 1.19.1 and Lifecycle 2.11.0 require API 37 / AGP >= 9.1 in AAR metadata.
    // Compile against stable API 37.0 without opting into Android 17 target behavior.
    // targetSdk remains 36 and minSdk remains 26 for phones and Android TV.
    compileSdk = 37
    // Resolve the native toolchain before defaultConfig/flavor configuration. Keep the pin
    // synchronized with :mpv-seam and the explicit SDK installation in CI.
    ndkVersion = "30.0.16248370"

    defaultConfig {
        applicationId = "com.vortx.android"
        minSdk = 26          // Android 8.0; covers phones and Android TV (Fire TV / Google TV)
        targetSdk = 36
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        versionCode = 280
        versionName = "0.5.6"

        // External sync credentials -> BuildConfig (read by com.vortx.android.integrations.TraktAuth /
        // SIMKLAuth). Empty default keeps the feature dormant on a public/unprovisioned build; see the
        // externalSyncSecret() helper above. buildConfig = true is set in buildFeatures {} below.
        buildConfigField("String", "TRAKT_CLIENT_ID", "\"${externalSyncSecret("TRAKT_CLIENT_ID")}\"")
        buildConfigField("String", "TRAKT_CLIENT_SECRET", "\"${externalSyncSecret("TRAKT_CLIENT_SECRET")}\"")
        buildConfigField("String", "SIMKL_CLIENT_ID", "\"${externalSyncSecret("SIMKL_CLIENT_ID")}\"")
        buildConfigField("String", "SIMKL_CLIENT_SECRET", "\"${externalSyncSecret("SIMKL_CLIENT_SECRET")}\"")

        // Package ONLY the ABIs the Rust engines and source-built mpv seam are cross-compiled for.
        // The root-project androidAbis contract includes armeabi-v7a for 32-bit Fire TV hardware
        // and deliberately excludes the libmpv AAR's unsupported x86 slice.
        ndk {
            abiFilters += androidAbis
        }
    }

    signingConfigs {
        create("release") {
            if (releaseSigningReady) {
                storeFile = releaseStoreFile
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
                enableV1Signing = true
                enableV2Signing = true
            }
        }
    }

    buildTypes {
        release {
            // Both fullRelease and playRelease always use the dedicated release signing configuration.
            // Missing credentials fail release task configuration above and can never select the debug key.
            signingConfig = signingConfigs.getByName("release")
            // The native engine JNI has no proven release keep rules in this repository. Keep beta builds
            // unminified and unshrunk to prioritize playback stability over download size.
            isMinifyEnabled = false
            isShrinkResources = false
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
        aidl = true
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

    testOptions {
        // Local JVM tests exercise pure source-index seams that still share files with fail-soft Android logs.
        unitTests.isReturnDefaultValues = true
    }

    sourceSets.named("main") {
        assets.directories.add(generatedChangelogAssets.get().asFile.path)
    }
}

tasks.matching { it.name.startsWith("merge") && it.name.endsWith("Assets") }.configureEach {
    dependsOn(copyChangelogAsset)
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
    // settings.gradle.kts) and pulls Tink transitively. If Keystore cannot open, credential stores remain
    // memory-only for that process and never fall back to disk plaintext.
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

    // QR generation for VortX account device sign-in. Core is Apache-2.0 and contains no camera UI;
    // Android only encodes the approval URL already handled by the VortX account site.
    implementation(libs.zxing.core)

    // ViewModel + collectAsStateWithLifecycle, so screens consume one-way state instead of calling
    // the repository inline. The real engine plugs in behind the repository with no ViewModel churn.
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.kotlinx.coroutines.android)

    // AndroidX Media3 (ExoPlayer): the player core. All media3 modules MUST share one version
    // (libs.versions.toml's single `media3` version).
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

    // androidx.tvprovider (TV-2): TvContractCompat + WatchNextProgram, the bridge that publishes profile-aware
    // Continue Watching onto the Android TV home "Play Next" row (the Top Shelf equivalent). No GPL native
    // code, so both flavors carry it; on a non-TV device the system TvProvider is simply absent and the
    // publisher fail-softs (every ContentResolver call is guarded).
    implementation(libs.tv.provider)

    // libmpv (PRIMARY player, sideloaded `full` flavor ONLY). The maven artifact ships the libmpv +
    // ffmpeg + player native .so set built from the mpv-android buildscripts: mpv 0.41.0 (the SAME
    // 0.41.0 line the Apple MPVKit-GPL build runs), ffmpeg 8.1 (--enable-gpl --enable-version3,
    // mediacodec + jni hwaccel), libplacebo 7.360.1 (the gpu-next renderer), dav1d 1.5.3.
    //
    // Since W1-B (AND-PLY-01) this artifact is consumed for its PREBUILT NATIVE SET ONLY: the
    // source-built :mpv-seam module (fullImplementation below) replaces the artifact's JNI glue
    // class + libplayer.so with an auditable fork that carries mpv_event_end_file reason/error to
    // Kotlin, so dev.jdtech.mpv classes are no longer referenced by app code and libplayer.so is
    // excluded from packaging further down (packaging {}).
    //
    // LICENSING: the mpv/ffmpeg native code is GPLv3 (ffmpeg built --enable-gpl --enable-version3),
    // so this dependency is confined to the `full` (sideload) flavor via `fullImplementation` and is
    // NEVER pulled into the `play` (Play-Store) flavor. This mirrors the Apple sideloaded MPVKit-GPL
    // distribution model. Coordinate resolves from mavenCentral() (already in settings.gradle.kts).
    // Shared root selection: original Maven baseline OR one SHA-pinned component AAR.
    // Local component bytes never impersonate dev.jdtech.mpv:libmpv:1.0.0.
    "fullImplementation"(checkNotNull(rootProject.extra["vortxMpvAarDependency"]))

    // The W1-B terminal seam itself: the source-built fork of the upstream JNI glue that exposes
    // mpv_event_end_file.reason/error to Kotlin (MpvTerminalEvent.fromNative). MIT-licensed glue,
    // built in-tree (:mpv-seam); it links against the AAR's prebuilt libmpv/avcodec .so files and is
    // therefore bound to the same GPL full-flavor boundary as the artifact above.
    "fullImplementation"(project(":mpv-seam"))

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

    // smbj (network shares): browses SMB shares and feeds the loopback relay the player opens, since Android's
    // libmpv has no SMB protocol. Both flavors; pure Java, Apache-2.0.
    implementation(libs.smbj)

    // WorkManager (Round 5): the offline-downloads transport. com.vortx.android.downloads.DownloadWorker runs one
    // download as a foreground-service worker, which is what gives the Android port the two properties Apple gets
    // from its two URLSessions at once: the transfer survives process death (WorkManager persists the work and
    // re-runs it in a fresh process, where Apple's in-memory resumeData would be gone), and the app process stays
    // alive while it runs (so a loopback torrent transfer keeps the in-process streaming server up, which is what
    // Apple needs its foreground session + beginBackgroundTask assertion for). Both flavors need it -- downloads are
    // not a licensing-boundary feature -- so this is a plain `implementation`, not flavor-scoped.
    implementation(libs.work.runtime.ktx)

    // Google Cast (the CAST lane, com.vortx.android.cast.*): send the current direct/HLS/debrid stream to a
    // Cast receiver, Android's equivalent of the Apple AirPlay route. play-services-cast-framework wraps the
    // CastContext/SessionManager/RemoteMediaClient; androidx.mediarouter supplies the device-discovery API the
    // Compose route chooser uses. Both are plain Google/AndroidX libraries with NO GPL native code (unlike
    // libmpv, which is fullImplementation-only), so they are LICENSING-BOUNDARY-SAFE plain `implementation`
    // dependencies compiled into BOTH the `full` and `play` flavors: the Play build stays GPL-clean and gains
    // casting without any libmpv. Torrents are gated out of casting as loopback URLs (CastEligibility), so a
    // remote receiver is only ever handed a stream it can actually reach.
    implementation(libs.play.services.cast.framework)
    implementation(libs.androidx.mediarouter)

    testImplementation(libs.junit)
    testImplementation(libs.json.jvm)
    testImplementation(libs.kotlinx.coroutines.test)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    // The TV profile route fixtures exercise the real Compose focus/Enter/Back surfaces.
    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

// =====================================================================================================
// Engine build switches shared by the vortx-ffi cargo-ndk task below.
// =====================================================================================================

// Fail-closed switch for release-intent builds. When VORTX_REQUIRE_ENGINE=1 (env) or
// -Pvortx.requireEngine=true is set, a missing engine checkout, a missing cargo toolchain, or a
// missing/empty .so output is a HARD build failure (GradleException) instead of the dev-machine
// warn-and-skip. Release workflows require freshly built VortX output.
val engineRequired: Boolean =
    System.getenv("VORTX_REQUIRE_ENGINE") == "1" ||
        (project.findProperty("vortx.requireEngine") as? String)?.toBoolean() == true

// minSdk must match the android {} block above; passed to cargo-ndk as the platform level (-p 26).
val nativeApiLevel = 26

android {
    // The bounded community-provider host is a separate C library. It deliberately does not share
    // symbols or build output with the Rust engine JNI library below.
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/community_js/CMakeLists.txt")
            version = "4.1.2"
        }
    }

    // In the `full` flavor two native-lib sources coexist: the cargo-ndk Rust output
    // (libvortx_ffi.so) and the libmpv AAR (libmpv.so + libplayer.so + libavcodec.so +
    // libc++_shared.so). Both can ship a libc++_shared.so for the same ABI, which makes AGP's jniLibs
    // merge fail with "More than one file with OS independent path 'lib/<abi>/libc++_shared.so'". Take
    // the first; the C++ runtime is ABI-stable, so either copy is interchangeable. This is additive
    // and no-ops in the `play` flavor (no libmpv AAR, so no duplicate).
    packaging {
        jniLibs {
            pickFirsts += "**/libc++_shared.so"
            // W1-B: the AAR's own JNI glue is dead weight now -- :mpv-seam's source-built
            // libvortx_mpv_seam.so replaces it (MpvSeam loads "mpv" + "vortx_mpv_seam", never
            // "player"), so exclude libplayer.so instead of packaging an opaque binary nothing can
            // reach. The dev.jdtech.mpv classes.jar still ships inside the APK but is unreferenced.
            excludes += "**/libplayer.so"
        }
        resources {
            // smbj's BouncyCastle (bcprov) and jspecify both ship this multi-release OSGi manifest, which
            // only the release Java-resource merge rejects as a duplicate. Android never reads it.
            excludes += "META-INF/versions/9/OSGI-INF/MANIFEST.MF"
        }
    }
}

// =====================================================================================================
// vortx-core JNI (the engine): build libvortx_ffi.so (features jni + server + resource-host) into
// src/main/jniLibs and package it. The source is the ENGINE branch's vortx-core workspace (crates/ffi), which is
// not vendored in this tree (the vortx-core/ dir here carries the kernel crates only, no ffi/
// streaming-server), so the checkout path comes from the environment:
//
//   VORTX_ENGINE_CORE_DIR=/path/to/engine-checkout/vortx-core   (env var), or
//   -Pvortx.engine.coreDir=/path/to/engine-checkout/vortx-core  (gradle property)
//
// When neither is set (or cargo is absent) the task warn-skips and the build packages whatever
// libvortx_ffi.so is already staged in src/main/jniLibs (the manual build documented in
// src/main/jniLibs/README.md) -- the .so binaries stay gitignored either way. `--features
// jni,server,resource-host` carries every JNI surface in the one .so: the VortxCore kernel bridge,
// the VortxServer in-process streaming server (raw-torrent playback) and the add-on resource host.
// It must never compile a server-only artifact.
// CARGO_TARGET_DIR is pinned to a task-owned scratch dir (target-andx) inside the engine checkout
// so this cross-build never dirties that checkout's own target/ build cache.
// =====================================================================================================

val vortxEngineCoreDir: File? = (
    System.getenv("VORTX_ENGINE_CORE_DIR")
        ?: (project.findProperty("vortx.engine.coreDir") as? String)
    )?.let(::File) ?: run {
        // The same canonical/private-workspace resolver as Apple, including registered app worktrees.
        // Missing local sources retain the existing development warn-skip/release fail-closed policy.
        val resolver = rootProject.file("../scripts/resolve-native-engine.sh")
        val result = providers.exec {
            commandLine("bash", resolver.absolutePath, rootProject.file("..").canonicalPath, "ffi")
            isIgnoreExitValue = true
        }
        if (result.result.get().exitValue == 0) result.standardOutput.asText.get().trim().takeIf { it.isNotEmpty() }?.let(::File) else null
    }

// Explicit integration build only. Release workflows keep their frozen private-core pins until the
// parent updates pins, feature sets and required ABI symbols together after review.
val vortxJniLibsDir = layout.projectDirectory.dir("src/main/jniLibs")

val cargoNdkBuildVortxFfi = tasks.register<Exec>("cargoNdkBuildVortxFfi") {
    group = "rust"
    description = "Cross-compile the engine branch's vortx-ffi (jni,server,resource-host) to libvortx_ffi.so via cargo-ndk."
    workingDir = vortxEngineCoreDir ?: projectDir // placeholder wd when unset; onlyIf gates the run

    val targetFlags = androidAbis.flatMap { listOf("-t", it) }
    // --locked: the engine workspace tracks Cargo.lock, so a drifted dependency resolution FAILS the
    // build instead of silently linking a different graph than the CI-proven runs.
    commandLine(
        buildList {
            add("cargo")
            add("ndk")
            addAll(targetFlags)
            add("-p"); add(nativeApiLevel.toString())
            add("-o"); add(vortxJniLibsDir.asFile.absolutePath)
            add("build"); add("-p"); add("vortx-ffi")
            add("--no-default-features"); add("--features"); add("jni,server,resource-host")
            add("--release"); add("--locked")
        },
    )
    vortxEngineCoreDir?.let { environment("CARGO_TARGET_DIR", File(it, "target-andx").absolutePath) }

    val cargoOnPath = System.getenv("PATH").orEmpty().split(File.pathSeparator).any { dir ->
        File(dir, "cargo").exists() || File(dir, "cargo.exe").exists()
    }
    onlyIf {
        val manifestOk = vortxEngineCoreDir?.let { File(it, "Cargo.toml").isFile } == true
        if (engineRequired && !(cargoOnPath && manifestOk)) {
            val why = if (!manifestOk) {
                "no engine workspace manifest at ${vortxEngineCoreDir?.path ?: "<unset VORTX_ENGINE_CORE_DIR / vortx.engine.coreDir>"}/Cargo.toml"
            } else {
                "cargo is not on PATH"
            }
            throw GradleException(
                "[vortx-ffi] engine build REQUIRED (VORTX_REQUIRE_ENGINE / vortx.requireEngine) but $why; " +
                    "refusing to package an APK without a freshly built libvortx_ffi.so.",
            )
        }
        if (!manifestOk) {
            logger.warn("[vortx-ffi] VORTX_ENGINE_CORE_DIR / -Pvortx.engine.coreDir not set (or no Cargo.toml there); skipping libvortx_ffi.so build. The APK packages whatever .so is already staged in src/main/jniLibs.")
        } else if (!cargoOnPath) {
            logger.warn("[vortx-ffi] cargo not on PATH; skipping libvortx_ffi.so build. The APK packages whatever .so is already staged in src/main/jniLibs.")
        }
        manifestOk && cargoOnPath
    }
    isIgnoreExitValue = false
    // Fail-closed output proof (release-intent only): cargo-ndk exiting 0 is not enough. Every shipped
    // ABI must have a non-empty libvortx_ffi.so staged for the jniLibs merge, or the build fails.
    doLast {
        if (engineRequired) {
            androidAbis.forEach { abi ->
                val so = vortxJniLibsDir.file("$abi/libvortx_ffi.so").asFile
                if (!so.isFile || so.length() == 0L) {
                    throw GradleException(
                        "[vortx-ffi] engine build REQUIRED but no usable $abi/libvortx_ffi.so at ${so.path} (missing or 0 bytes).",
                    )
                }
            }
        }
    }
}

tasks.matching { it.name.startsWith("merge") && it.name.endsWith("JniLibFolders") }.configureEach {
    dependsOn(cargoNdkBuildVortxFfi)
}
