plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.getcircuitbent.mabu.theremin"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.getcircuitbent.mabu.theremin"

        // See Sample App 1 for the full reasoning on these four. Briefly:
        // the Mabu is API 27 so nothing above that installs; targetSdk 28
        // keeps plain File access to /sdcard/theremin/; compileSdk 34 is what
        // current AndroidX and ML Kit need; and the RK3288 is 32-bit ARM only.
        minSdk = 24
        targetSdk = 28
        versionCode = 1
        versionName = "1.0"

        ndk {
            abiFilters += listOf("armeabi-v7a")
        }
        externalNativeBuild {
            cmake { cFlags("-O2", "-Wall") }
        }
    }

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
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")

    // ------------------------------------------------------------------
    // ML Kit face detection, BUNDLED and PINNED. Do not float this version.
    //
    // Bundled: the model ships in the APK. The Play-Services-backed variant
    // would download it at runtime, and a liberated Mabu has no Play
    // Services at all, so it would never work.
    //
    // Pinned: 16.1.7 is verified to ship armeabi-v7a and to run on this
    // device. A future release dropping armv7 is exactly how this app would
    // break, and it would break at runtime on the robot rather than at build
    // time on your laptop. MediaPipe already did this, which is why this app
    // has no real hand tracking - see HandTracker.kt.
    // ------------------------------------------------------------------
    implementation("com.google.mlkit:face-detection:16.1.7")
}
