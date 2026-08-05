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

// §380 — build-id нативных .so трогать НЕ нужно.
//
// NDK сам передаёт `-Wl,--build-id=sha1` всем CMake-сборкам
// (`build/cmake/flags.cmake:72`, безусловно — обход старого LLDB в Android
// Studio). Отпечаток считается от содержимого, поэтому при одинаковом входе
// он одинаков: `libdartjni.so` несёт один и тот же build-id начиная с
// v2.19.7, задолго до появления этой заметки.
//
// Здесь был хук, дублировавший этот дефолт. Он ничего не менял и снят;
// если расхождение build-id всплывёт снова, причина будет во ВХОДЕ
// линковки (пути сборки, версия хостового clang), а не в алгоритме.

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
