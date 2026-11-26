package com.leadaxe.lxbox.vpn

/**
 * Конфиг ядра и подписи уведомления на сервисной стороне (`:bg`).
 *
 * §747 — файл пишет сторона окна ([ConfigFile], атомарно) и сообщает об этом
 * вызовом «конфиг сохранён» ([invalidate]); здесь — кэш прочитанного текста
 * для читателей сервиса (`BoxService`, Taildrop, AppFunctions). Подписи
 * уведомления живут в памяти `:bg`: окно шлёт их вызовом, сервис читает.
 */
object ConfigManager {
    @Volatile
    var notificationTitle: String = "L×Box"
        private set

    // §123 — подтекст уведомления (тег активной ноды / route.final). Пустая
    // строка = native сам подставит статусный fallback ("Connected").
    @Volatile
    var notificationText: String = ""
        private set

    @Volatile
    private var cachedConfig: String? = null

    fun load(): String {
        cachedConfig?.let { return it }
        val content = ConfigFile.read(BoxApplication.application) ?: return "{}"
        cachedConfig = content
        return content
    }

    /// Файл переписан стороной окна — следующий [load] читает с диска.
    fun invalidate() {
        cachedConfig = null
    }

    fun setNotificationTitle(title: String) {
        notificationTitle = title
    }

    fun setNotificationText(text: String) {
        notificationText = text
    }
}
