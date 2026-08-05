allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// §380 — детерминизм нативных .so (reproducible builds).
//
// Линкер по умолчанию штампует в каждую .so секцию `.note.gnu.build-id` —
// уникальный отпечаток прогона. Два прогона одного исходника дают разные
// байты, и побайтовая верификация F-Droid падает на ровном месте.
//
// Затрагивает пакеты, которые собирают native-часть через CMake:
// `flutter_zxing` (ZXing-C++, §382) и `jni` (libdartjni.so).
//
// `sha1`, а не `none`: отпечаток считается из содержимого файла, поэтому
// одинаковый вход даёт одинаковый build-id, а само поле остаётся на месте.
// Оно системное — по нему символизируются тумбстоуны, работают crash-
// репортеры и `debuginfod`; выбрасывать его ради верификации не стоит.
//
// Метаданные F-Droid должны задавать ту же схему (там сейчас `none`),
// иначе стороны разойдутся уже на длине секции.
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.api.dsl.LibraryExtension>("android") {
            defaultConfig {
                externalNativeBuild {
                    cmake {
                        arguments += "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--build-id=sha1"
                    }
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
