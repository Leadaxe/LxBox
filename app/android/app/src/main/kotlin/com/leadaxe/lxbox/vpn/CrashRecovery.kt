package com.leadaxe.lxbox.vpn

import android.util.Log
import java.io.File

/**
 * §334 — «прошлый запуск упал» как событие, с независимыми подписчиками.
 *
 * ЗАЧЕМ. Повреждённый `cache.db` (bbolt) роняет ядро паникой ещё в `preStart`
 * (`invalid page type` в `cachefile.(*CacheFile).start`), то есть ДО применения
 * конфига. Паника Go убивает процесс через abort — ни `try/catch` в Kotlin, ни
 * `recover()` в Go её не перехватят. Пользователь получает петлю без выхода:
 * каждый «старт» даёт ту же панику, а удаление `cache.db` спрятано в
 * DNS-настройках (§263) и с крашем старта никак не связано.
 *
 * ОТКУДА ЗНАЕМ О КРАШЕ. Ядро само ведёт файловый учёт: libbox редиректит
 * Go-stderr в `workingPath/CrashReport-<source>.log` (`crashReportSource`,
 * см. [BoxApplication.initializeLibbox]). Обычный файл — переживает смерть
 * процесса. Пустой = паник не было, непустой = прошлая сессия упала. Тот же
 * критерий использует само ядро: `archiveCrashReport` выходит на
 * `len(content) == 0` (`experimental/libbox/log.go:29`).
 *
 * `ApplicationExitInfo` (§038) для этого не годится: `REASON_CRASH_NATIVE`
 * доступен с API 30, а `minSdk = 24`. Файловый канал работает на всех.
 *
 * ПОЧЕМУ СТРОГО ДО `Libbox.setup()`. `redirectStderr` (`log.go:69-77`) сначала
 * архивирует репорт в `crash_reports/`, потом `os.Create` затирает файл под
 * новую сессию. То есть `setup` — точка невозврата: до неё улика на месте и
 * `cache.db` никем не открыт (удаление тривиально безопасно), после неё репорт
 * уехал в архив, а БД занята ядром.
 *
 * Отсюда же ДЕДУП ДАРОМ: `setup` затирает файл, на следующем запуске он пуст —
 * событие не выстрелит второй раз. Ни stamp'а, ни счётчика попыток, ни
 * sentinel-файла держать не нужно, состояние уже есть в файловой системе.
 *
 * `.old`-файл НЕ проверяем намеренно: `redirectStderr` его архивирует
 * (`log.go:72`), но во всём форке это единственное упоминание — никто его не
 * создаёт. Похоже на страховку под старое поведение `debug.SetCrashOutput`.
 * Добавлять в детект — мёртвая ветка.
 *
 * ДВА ПОДПИСЧИКА, РАЗНЫЕ СЛОИ. Здесь — чистка кэшей (Kotlin, синхронно до
 * `setup`, от текущего репорта). Отдельно — баннер «ядро падало» (Dart,
 * `CrashBannerState` §316, после старта Flutter, от архива `crash_reports/` и
 * собственного stamp'а). Читают разные файлы в разные моменты, не конкурируют.
 * Детектор про подписчиков не знает: третий потребитель не потребует трогать ни
 * детект, ни существующие ветки.
 */
internal object CrashRecovery {

    private const val TAG = "CrashRecovery"

    /** Базовое имя crash-репорта ядра. Зеркало `kCrashReportBaseName` (Dart). */
    private const val CRASH_REPORT_NAME = "CrashReport-lxbox.log"

    /**
     * Прошлая сессия упала? Непустой crash-репорт = была паника.
     *
     * Вызывать ТОЛЬКО до `Libbox.setup()` — после него файл затёрт и ответ
     * всегда `false`.
     *
     * Best-effort: любая ошибка чтения → `false`. Диагностика не должна мешать
     * старту — потерянная чистка лечится следующим запуском, сорванный старт
     * не лечится ничем.
     */
    fun crashedOnPreviousLaunch(workingDir: File): Boolean {
        val report = File(workingDir, CRASH_REPORT_NAME)
        return runCatching { report.isFile && report.length() > 0 }
            .getOrElse {
                Log.w(TAG, "crash report probe failed: ${it.message}")
                false
            }
    }

    /**
     * Подписчик: сбросить кэши ядра.
     *
     * Чистим `cache.db` (FakeIP-аллокации, DNS RDRC, urltest, выбор в
     * селекторах) и `tempPath`. Всё восстановимо: ядро пересоздаст. `cacheDir`
     * система и сама сносит под давлением памяти, так что ядро обязано
     * переживать его отсутствие.
     *
     * НЕ трогаем `config.json` (конфиг, а не кэш — без него нечего запускать),
     * `CrashReport-lxbox.log` и `crash_reports/` (предмет диагностики; репорт
     * нужен ядру для архивации, архив — баннеру §316 — своей же чисткой снесли
     * бы то, по чему детектим), гео-базы и rule-set (десятки МБ по сети, а
     * после краша сеть может не работать), пользовательские данные.
     *
     * Чистим на ЛЮБОМ краше ядра, без разбора трейса: прицельный парсинг
     * (`bbolt` / `invalid page type` / `cachefile`) пропускал бы редкие формы
     * порчи, а цена лишней чистки низкая.
     */
    fun resetKernelCaches(tempDir: File) {
        Log.i(TAG, "[§334] previous launch crashed — resetting kernel caches")
        BoxVpnService.deleteCacheDbFile()
        clearTempDir(tempDir)
    }

    /**
     * Вычистить содержимое `tempPath`, сохранив сам каталог: ядро получает его
     * путь в `SetupOptions` и ожидает существующим.
     */
    private fun clearTempDir(tempDir: File) {
        val entries = runCatching { tempDir.listFiles() }.getOrNull()
        if (entries == null) {
            Log.i(TAG, "[§334] temp dir unreadable or absent — nothing to clear")
            return
        }
        var removed = 0
        for (entry in entries) {
            if (runCatching { entry.deleteRecursively() }.getOrDefault(false)) removed++
        }
        Log.i(TAG, "[§334] temp dir cleared: $removed/${entries.size} (${tempDir.absolutePath})")
    }
}
