import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// ---------------------------------------------------------------------------
// Release signing.
//
// Every sample app is signed with ONE shared key, so a user can update any of
// them without uninstalling first. The debug key will not do: it is generated
// per machine, so an APK built here and an APK built on the next PC are
// mutually un-upgradeable, and the user sees INSTALL_FAILED_UPDATE_INCOMPATIBLE
// with no way out except uninstalling by hand.
//
// The keystore and its passwords are NOT in this repo and must never be. They
// are looked for in three places, first hit wins:
//
//   1. keystore.properties in this sample's root      (gitignored)
//   2. MABU_KEYSTORE / MABU_KEYSTORE_PASSWORD /
//      MABU_KEY_ALIAS / MABU_KEY_PASSWORD             (CI)
//   3. ~/.mabu-keys/keystore.properties               (per-developer default)
//
// Without any of them, debug builds still work; assembleRelease fails with an
// explanation rather than quietly emitting an unsigned APK.
// ---------------------------------------------------------------------------
val signingProps = Properties().apply {
    val candidates = listOf(
        rootProject.file("keystore.properties"),
        File(System.getProperty("user.home"), ".mabu-keys/keystore.properties"),
    )
    candidates.firstOrNull { it.exists() }?.inputStream()?.use { load(it) }
}

fun signingValue(key: String, env: String): String? =
    signingProps.getProperty(key) ?: System.getenv(env)

val keystorePath = signingValue("storeFile", "MABU_KEYSTORE")
val keystoreFile = keystorePath?.let { path ->
    File(path).takeIf { it.isAbsolute } ?: rootProject.file(path)
}
val canSignRelease = keystoreFile?.exists() == true

android {
    namespace = "com.getcircuitbent.mabu.signboard"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.getcircuitbent.mabu.signboard"

        // ---------------------------------------------------------------
        // These four values are not arbitrary. Each one is here because of
        // something specific about the Mabu, and changing them will break
        // the app on the device in ways that are annoying to diagnose.
        // ---------------------------------------------------------------

        // The Mabu runs Android 8.1 = API 27. An APK with minSdk above 27
        // will simply refuse to install ("INSTALL_FAILED_OLDER_SDK").
        minSdk = 24

        // Staying at 28 keeps us out of the API 29+ scoped-storage rules.
        // We want plain File access to /sdcard/signboard/ so that dropping
        // a new sign onto the device with `adb push` just works, with no
        // SAF picker and no MediaStore ceremony.
        targetSdk = 28

        versionCode = 1
        versionName = "1.0"

        ndk {
            // RK3288 is 32-bit ARMv7 only. An arm64 .so will not load, and
            // shipping both just doubles the APK for no reason.
            abiFilters += listOf("armeabi-v7a")
        }
        externalNativeBuild {
            cmake { cFlags("-O2", "-Wall") }
        }
    }

    // The native serial shim. See app/src/main/cpp/serial.c for WHY the
    // serial port has to be opened from C rather than from Kotlin.
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    signingConfigs {
        if (canSignRelease) {
            create("release") {
                storeFile = keystoreFile
                storePassword = signingValue("storePassword", "MABU_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "MABU_KEY_ALIAS") ?: "mabu-samples"
                keyPassword = signingValue("keyPassword", "MABU_KEY_PASSWORD")

                // v2 is what actually gets used here, and it is enough: the
                // Mabu is API 27 and v2 verification landed in 24. AGP skips
                // v1 (JAR signing) entirely once minSdk is 24 or above, so
                // `apksigner verify` reporting "v1 scheme: false" on this APK
                // is expected, not a problem. Left enabled so that dropping
                // minSdk below 24 would still produce an installable APK.
                enableV1Signing = true
                enableV2Signing = true
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            if (canSignRelease) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    lint {
        // Lint fails a release build on this by default. It is a Google Play
        // store-listing requirement, and this app is never going near Play: it
        // is installed with `adb install` onto an API 27 device that has no Play
        // Store on it. targetSdk 28 is deliberate and is explained above.
        disable += "ExpiredTargetSdkVersion"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    // Deliberately minimal. Everything this sample does is either plain
    // Android framework or our own code, so there is nothing to untangle
    // when you lift a file out of here into your own project.
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
}

// Fail loudly rather than shipping an unsigned APK. An unsigned release build
// lands at app-release-unsigned.apk, which no device will install, and the only
// symptom is a confusing failure much later.
tasks.matching { it.name == "assembleRelease" }.configureEach {
    doFirst {
        if (!canSignRelease) {
            throw GradleException(
                "No release keystore. Expected keystore.properties in the sample root, " +
                    "or MABU_KEYSTORE and friends in the environment, or " +
                    "~/.mabu-keys/keystore.properties. See 'Shipping a Sample App' in " +
                    "sample-apps/SAMPLE-APP-FUNCTION-INDEX.md."
            )
        }
    }
}
