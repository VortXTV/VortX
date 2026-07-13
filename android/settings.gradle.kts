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

// The version catalog at gradle/libs.versions.toml is auto-discovered by Gradle as `libs`.
rootProject.name = "VortX"
include(":app")
