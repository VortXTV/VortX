// The VortX source-built libmpv JNI seam (:mpv-seam). Forked + patched glue from
// jarnedemeulemeester/libmpv-android v1.0.0 (MIT; see README.md / LICENSE here). This module owns
// ONLY the thin JNI bridge: it compiles libvortx_mpv_seam.so from source and links it against the
// prebuilt libmpv.so / libavcodec.so extracted at build time from the dev.jdtech.mpv:libmpv AAR --
// the SAME artifact the app already consumes for the runtime .so set, so no binary is rebuilt,
// vendored, or added to any repository by this module.
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "com.vortx.android.player.mpv.seam"
    compileSdk = 36
    // Same NDK as the app's own pin (android/app/build.gradle.kts). Without this, AGP falls back to
    // its default NDK on machines with several installed -- the seam would then be built by a
    // different toolchain than everything else in the app.
    ndkVersion = "27.2.12479018"

    defaultConfig {
        minSdk = 26
        consumerProguardFiles("consumer-rules.pro")
        externalNativeBuild {
            cmake {
                // c++_static: this glue is self-contained C++ (no C++ objects cross its .so boundary
                // -- every call in/out is JNI primitives or mpv's C API), so it must not add another
                // libc++_shared.so copy to the APK's pickFirsts merge. The AAR's own libs keep theirs.
                // MPV_AAR_JNI_DIR points at the extraction output of extractMpvAarJniLibs below (path
                // is known at configuration time; contents materialize before CMake configure runs).
                arguments += listOf(
                    "-DANDROID_STL=c++_static",
                    "-DMPV_AAR_JNI_DIR=" +
                        layout.buildDirectory.dir("mpvAarJniLibs").get().asFile.absolutePath + "/jni",
                )
                cFlags += "-Werror"
                cppFlags += "-std=c++11"
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    testImplementation(libs.junit)
}

// -------------------------------------------------------------------------------------------------
// Native link inputs: resolve the dev.jdtech.mpv:libmpv AAR (the pinned catalog version) and extract
// its per-ABI prebuilt libmpv.so + libavcodec.so into build/mpvAarJniLibs/jni/<abi>/ so CMake can link
// against exactly what the app packages at runtime. NOTHING is copied into the repository and nothing
// is repackaged: these files are build-time linker inputs only; the runtime copies still come from the
// app's fullImplementation of the same AAR.
//
// libavcodec is linked because prepare_environment() calls av_jni_set_java_vm /
// av_jni_set_android_app_ctx (declared in <libavcodec/jni.h>, defined in this FFmpeg build's
// libavcodec.so), mirroring upstream's target_link_libraries(player mpv avcodec log).
// -------------------------------------------------------------------------------------------------
val mpvLinkAar by configurations.creating {
    // Resolvable but not consumable: this is a private build-time input of THIS module only (the
    // linker's symbol source), never propagated to consumers. Resolution itself is deferred to the
    // extraction task's execution time.
    isCanBeConsumed = false
    isCanBeResolved = true
    isVisible = false
    description = "Resolves the dev.jdtech.mpv:libmpv AAR whose prebuilt .so files the seam links against."
}

dependencies {
    mpvLinkAar(libs.mpv.libmpv)
}

val mpvAarJniLibsDir = layout.buildDirectory.dir("mpvAarJniLibs")

val extractMpvAarJniLibs by tasks.registering(Sync::class) {
    group = "build"
    description = "Extracts per-ABI libmpv.so/libavcodec.so from the dev.jdtech.mpv:libmpv AAR as native link inputs."
    from({ mpvLinkAar.incoming.files.files.map { zipTree(it) } }) {
        include("jni/*/libmpv.so", "jni/*/libavcodec.so")
    }
    into(mpvAarJniLibsDir)
    // Fail closed if a changed/empty AAR ever stops shipping the libs the linker needs.
    doLast {
        val jniRoot = mpvAarJniLibsDir.get().asFile.resolve("jni")
        val abis = jniRoot.listFiles()?.filter { it.isDirectory }.orEmpty()
        check(abis.isNotEmpty()) { "dev.jdtech.mpv:libmpv AAR carried no jni/<abi> libs; cannot link the seam." }
        for (abi in abis) {
            for (lib in listOf("libmpv.so", "libavcodec.so")) {
                val f = abi.resolve(lib)
                check(f.isFile && f.length() > 0L) { "AAR extraction missing ${abi.name}/$lib." }
            }
        }
    }
}

// CMake needs the extracted libs to exist before configure (existence is asserted there) and before
// any build/link step. Sync is incremental, so depending on it from both task families is cheap.
tasks.matching { task ->
    task.name.startsWith("configureCMake") || task.name.startsWith("buildCMake")
}.configureEach {
    dependsOn(extractMpvAarJniLibs)
}
