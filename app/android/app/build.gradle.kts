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

        // ABI filter (build-size optimization). Flutter `--target-platform`
        // влияет только на свой engine + Dart AOT; нативные .so из Maven
        // (libbox 1.13 — 55-66 MB per ABI) gradle подтягивает для всех
        // ABI, и APK раздувается до ~76MB.
        //
        // Сужаем через переменную окружения `LXBOX_ABI_FILTER` (выставляется
        // в scripts/build-local-apk.sh). `-P` props из flutter build не
        // пробрасываются стабильно, env-var универсально срабатывает.
        // Если var не задан — поведение не меняется (CI-сборка по
        // умолчанию остаётся универсальной, как раньше).
    }

    // ABI filter (build-size optimization). Flutter gradle plugin по
    // умолчанию выставляет `ndk.abiFilters` для всех 3 ABI
    // (armeabi-v7a, arm64-v8a, x86_64) — даже если передан
    // `--target-platform android-arm64` это влияет только на flutter engine
    // и Dart AOT, native libs из Maven AAR (libbox 55-66 MB / ABI)
    // подтягиваются под все 3.
    //
    // Очищаем `ndk.abiFilters` и задаём только нужный ABI через env-var
    // `LXBOX_ABI_FILTER` (выставляется в scripts/build-local-apk.sh).
    // Если var не задан — поведение не меняется (CI-сборка остаётся
    // универсальной для всех 3 ABI).
    val abiFilterEnv: String? = System.getenv("LXBOX_ABI_FILTER")
    if (!abiFilterEnv.isNullOrBlank()) {
        val keepAbis = abiFilterEnv.split(",").map { it.trim() }.toSet()
        defaultConfig.ndk.abiFilters.clear()
        defaultConfig.ndk.abiFilters.addAll(keepAbis)
        // Дополнительно: исключаем JNI-libs других ABI из AAR (libbox).
        // `ndk.abiFilters` контролирует только локально-собранные .so;
        // AAR-вложенные .so отфильтровываются именно `packaging.jniLibs.excludes`.
        val allAbis = setOf("armeabi-v7a", "arm64-v8a", "x86_64", "x86")
        val excludeAbis = allAbis - keepAbis
        packaging {
            for (abi in excludeAbis) {
                jniLibs.excludes += "lib/$abi/**"
            }
        }
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
    implementation("com.github.singbox-android:libbox:1.13.11")
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
}

flutter {
    source = "../.."
}
