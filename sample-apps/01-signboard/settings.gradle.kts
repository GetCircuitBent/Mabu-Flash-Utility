// Standalone Gradle project. Open THIS directory in Android Studio (not the
// repo root) and press Run. Nothing here depends on anything outside
// sample-apps/01-signboard/, so you can copy the whole folder out of the repo
// and it still builds.

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

rootProject.name = "MabuSignboard"
include(":app")
