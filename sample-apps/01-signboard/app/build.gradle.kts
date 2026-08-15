plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

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

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
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
