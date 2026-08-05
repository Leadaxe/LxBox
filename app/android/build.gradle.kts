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

// §380 — build-id нативных .so отключён ради воспроизводимости.
//
// NDK по умолчанию передаёт `-Wl,--build-id=sha1` всем CMake-сборкам
// (`build/cmake/flags.cmake:72` — обход старого LLDB в Android Studio).
// Название вводит в заблуждение: LLD хэширует ВХОД линковки, а не итоговый
// файл. Поэтому два прогона одного кода в разных окружениях дают разный
// отпечаток, хотя `.so` совпадают.
//
// Измерено на `libdartjni.so` (v2.20.1, F-Droid против GitHub): файлы
// различаются РОВНО на 20 байт — сам build-id по смещению 0x2e0. Таблицы
// секций, `.text`, `.rodata`, всё остальное — идентичны побайтово.
//
// Такой build-id бесполезен и для отладки: он меняется без изменения кода,
// значит по нему всё равно не найти нужные символы. `none` убирает секцию
// целиком — так делают и приложения каталога F-Droid, собирающие ZXing.
//
// Задано здесь, а не в метаданных F-Droid: их сборка использует этот же
// файл, поэтому один источник работает на обе стороны.
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.api.dsl.LibraryExtension>("android") {
            defaultConfig {
                externalNativeBuild {
                    cmake {
                        arguments += "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--build-id=none"
                    }
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
