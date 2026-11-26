package com.leadaxe.lxbox.vpn

/// §747 — в каком из двух процессов приложения исполняется код.
///
/// Процессов два, оба именованные (манифест, `android:process`): `:ui` — окно
/// (`MainActivity`, Flutter-движок, `VpnPlugin`), `:bg` — всё сервисное
/// (`BoxVpnService`, ядро, плитка, приёмники, нативные окна Taildrop и
/// автоматизации, `BgControlProvider`). Процесса без имени быть не должно:
/// компонент без `android:process` — ошибка сборки (проверка собранного
/// манифеста), а запуск в таком процессе — ошибка в лог (`BoxApplication`).
object ProcessRole {
    const val UI_SUFFIX = ":ui"
    const val BG_SUFFIX = ":bg"

    enum class Role { Ui, Bg, Unnamed }

    /// Роль по имени процесса (`com.leadaxe.lxbox:ui`). Чистая функция — для теста.
    fun roleOf(processName: String?): Role = when {
        processName == null -> Role.Unnamed
        processName.endsWith(UI_SUFFIX) -> Role.Ui
        processName.endsWith(BG_SUFFIX) -> Role.Bg
        else -> Role.Unnamed
    }

    /// Имя процесса; пусто, если узнать не удалось (JVM-тест).
    val name: String by lazy { readName() }

    val role: Role by lazy { roleOf(name) }

    /// Сторона окна (`:ui`).
    val isUi: Boolean get() = role == Role.Ui

    /// Сервисная сторона (`:bg`). Процесс без имени не исполняет ни одной роли.
    val isBg: Boolean get() = role == Role.Bg

    private fun readName(): String {
        runCatching {
            if (android.os.Build.VERSION.SDK_INT >= 28) {
                return android.app.Application.getProcessName() ?: ""
            }
        }
        // API 24–27 и JVM: имя — первая NUL-строка /proc/self/cmdline.
        return runCatching {
            java.io.File("/proc/self/cmdline").readBytes()
                .takeWhile { it != 0.toByte() }.toByteArray().toString(Charsets.UTF_8).trim()
        }.getOrDefault("")
    }
}
