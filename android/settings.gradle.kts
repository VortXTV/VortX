pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "VortX"
include(":app")
// Source-built libmpv JNI seam (audit W1-B / AND-PLY-01): forked + patched glue from
// jarnedemeulemeester/libmpv-android v1.0.0 (MIT) exposing mpv_event_end_file reason/error to
// Kotlin. Consumed by :app as a fullImplementation (sideloaded `full` flavor only, like the AAR
// whose prebuilt .so set it links against). See mpv-seam/README.md.
include(":mpv-seam")
