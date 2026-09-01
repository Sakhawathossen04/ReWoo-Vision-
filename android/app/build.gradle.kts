import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")

    // Flutter Gradle Plugin must be applied after
    // the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ============================================================================
// RELEASE SIGNING
// ============================================================================
//
// Reads key.properties when available.
//
// If key.properties does not exist, the project falls back to the debug
// signing key so development/test builds still work.
//

val keystoreProperties = Properties()

val keystorePropertiesFile =
    rootProject.file("key.properties")

if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use {
        keystoreProperties.load(it)
    }
}

// ============================================================================
// ANDROID CONFIGURATION
// ============================================================================

android {
    namespace = "com.tommasogiovannini.gemma"

    // =========================================================================
    // COMPILE SDK
    // =========================================================================
    //
    // background_downloader requires Android SDK 36.
    //
    // IMPORTANT:
    // compileSdk controls which Android APIs the project can compile against.
    // It does NOT change the minimum Android version that can install the app.
    //
    // Android 9 support remains controlled by:
    //
    //     minSdk = 28
    //
    compileSdk = 36

    // ------------------------------------------------------------------------
    // NDK
    // ------------------------------------------------------------------------
    //
    // The project currently relies on prebuilt native libraries supplied by
    // dependencies such as flutter_gemma / MediaPipe.
    //
    // Do not force an NDK version here unless a dependency/build error later
    // specifically requires one.
    //
    // ndkVersion = flutter.ndkVersion

    // ------------------------------------------------------------------------
    // JAVA
    // ------------------------------------------------------------------------

    compileOptions {
        sourceCompatibility =
            JavaVersion.VERSION_11

        targetCompatibility =
            JavaVersion.VERSION_11
    }

    // ------------------------------------------------------------------------
    // KOTLIN
    // ------------------------------------------------------------------------

    kotlinOptions {
        jvmTarget =
            JavaVersion.VERSION_11.toString()
    }

    // ------------------------------------------------------------------------
    // DEFAULT APP CONFIG
    // ------------------------------------------------------------------------

    defaultConfig {
        applicationId =
            "com.tommasogiovannini.gemma"

        // ====================================================================
        // ANDROID 9 MINIMUM SUPPORT
        // ====================================================================
        //
        // Android 9 = API level 28.
        //
        // Android 8 / 8.1 and lower
        // -> APK will NOT install.
        //
        // Android 9 and newer
        // -> APK is allowed to install.
        //
        minSdk = 28

        // ====================================================================
        // TARGET SDK
        // ====================================================================
        //
        // Keep targetSdk controlled by Flutter.
        //
        // targetSdk and minSdk are separate:
        //
        // compileSdk = 36
        // -> build against Android SDK 36
        //
        // minSdk = 28
        // -> Android 9 minimum installation support
        //
        targetSdk =
            flutter.targetSdkVersion

        versionCode =
            flutter.versionCode

        versionName =
            flutter.versionName
    }

    // ------------------------------------------------------------------------
    // SIGNING
    // ------------------------------------------------------------------------

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias =
                    keystoreProperties["keyAlias"]
                        as String

                keyPassword =
                    keystoreProperties["keyPassword"]
                        as String

                storeFile =
                    rootProject.file(
                        keystoreProperties["storeFile"]
                            as String
                    )

                storePassword =
                    keystoreProperties["storePassword"]
                        as String
            }
        }
    }

    // ------------------------------------------------------------------------
    // NATIVE LIBRARY PACKAGING
    // ------------------------------------------------------------------------
    //
    // flutter_gemma / MediaPipe ship prebuilt native .so libraries.
    //
    // Keep them as shipped and avoid requiring llvm-strip during packaging.
    //

    packaging {
        jniLibs {
            keepDebugSymbols +=
                "**/*.so"
        }
    }

    // ------------------------------------------------------------------------
    // BUILD TYPES
    // ------------------------------------------------------------------------

    buildTypes {
        release {
            // Shrink unused Java/Kotlin code.
            isMinifyEnabled = true

            // Remove unused Android resources.
            isShrinkResources = true

            // Use real release key when key.properties exists.
            //
            // Otherwise use debug signing for local/testing builds.
            signingConfig =
                if (keystorePropertiesFile.exists()) {
                    signingConfigs
                        .getByName("release")
                } else {
                    signingConfigs
                        .getByName("debug")
                }

            proguardFiles(
                getDefaultProguardFile(
                    "proguard-android-optimize.txt"
                ),
                "proguard-rules.pro"
            )
        }
    }
}

// ============================================================================
// FLUTTER
// ============================================================================

flutter {
    source = "../.."
}
