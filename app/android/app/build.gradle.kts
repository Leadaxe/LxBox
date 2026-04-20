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
        // Android 11 (API 30) minimum — явно фиксируем support window.
        // Причины:
        //   - ActivityManager.getHistoricalProcessExitReasons (API 30+) — нужен
        //     для silent-kill detection (см. docs/spec/tasks/007).
        //   - Современные VpnService API (metered flag, setMetered) — API 29+.
        //   - RECEIVER_NOT_EXPORTED явный флаг — требуется на API 33+, но мы
        //     используем его уже сейчас (ContextCompat делает fallback для <33).
        //   - Стабильные FGS-constraint'ы (Android 11 зачищает lifecycle).
        // Старые версии (API <30) — вне поддержки проекта. См. ARCHITECTURE.md.
        minSdk = 30
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
