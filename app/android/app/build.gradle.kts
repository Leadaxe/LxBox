plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.io.FileInputStream
import java.util.Properties

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

fun hasReleaseKeystore(): Boolean =
    keystorePropertiesFile.exists() &&
        !keystoreProperties.getProperty("storeFile").isNullOrBlank()

android {
    namespace = "com.leadaxe.lxbox"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.leadaxe.lxbox"
        // Android 8.0 (API 26) minimum — historical claim из release notes
        // 1.3.x / 1.4.0. Не закрываем дверь пользователям Android 8-10, хотя
        // приоритет тестирования и поддержки — 11+ (primary target window).
        //
        // Tiers:
        //   - Primary (11+, API 30+)  — все фичи, тестируется.
        //   - Best-effort (8-10, API 26-29) — compile/install OK, фичи API 30+
        //     деградируют. Например, silent-kill detection
        //     (getHistoricalProcessExitReasons) обёрнута в SDK_INT check.
        //   - Unsupported (<8, API <26) — install blocked.
        //
        // Если всплывут жалобы с 8-10, возможно придётся понизить до 24
        // (Flutter default). См. ARCHITECTURE.md → Supported platforms.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")!!
                keyPassword = keystoreProperties.getProperty("keyPassword")!!
                storePassword = keystoreProperties.getProperty("storePassword")!!
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile")!!)
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                if (hasReleaseKeystore()) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
        }
    }

    packaging {
        jniLibs { useLegacyPackaging = true }
    }
}

dependencies {
    implementation("com.github.singbox-android:libbox:1.12.12")
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
}

flutter {
    source = "../.."
}
