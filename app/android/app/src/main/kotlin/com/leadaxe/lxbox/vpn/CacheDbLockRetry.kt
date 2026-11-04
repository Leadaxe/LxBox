package com.leadaxe.lxbox.vpn

import android.util.Log

/**
 * §703 — страховка от «initialize cache-file: timeout» на старте ядра.
 *
 * ЗАЧЕМ. `cache.db` (bbolt) открывается ядром под flock. Закрытие Box идёт
 * в обратном порядке регистрации, и cache-file закрывается ПОСЛЕДНИМ — за
 * endpoint'ами. Когда закрытие виснет на них (класс sing-box-lx#50), наш
 * ограниченный stop (§668 — 2 с у VPN, §669 — 3 с у пробы) отпускает
 * остановку, а старый Box остаётся держать файл. Следующий старт — новый
 * `CommandServer` в том же процессе — ждёт блокировку 10×1 с
 * (`cachefile.start`) и падает с `initialize cache-file: timeout`.
 * Пользователи лечат это force stop или «сбросом DNS-кэша» (§263).
 *
 * ЧТО ДЕЛАЕМ. Основной путь без потерь — в ядре (sing-box-lx#61: файл
 * отпускается первым шагом закрытия, новый Box забирает его у старого).
 * Здесь только дежурная страховка, и триггер у неё — сама ошибка старта,
 * а не тайм-аут закрытия: кэш теряется только когда основной путь не
 * сработал. По ошибке удаляем `cache.db` (зависший Box остаётся с
 * дескриптором на снятый inode и файл не портит) и повторяем старт один
 * раз. Цена срабатывания — FakeIP-выдачи, выбор узла в группах, кэш
 * удалённых rule-set и история urltest; туннель в этот момент лежит.
 *
 * ПОЧЕМУ НЕ СНЯТЬ БЛОКИРОВКУ СНАРУЖИ. Дескриптор — у Go, Kotlin его не
 * видит; снятие flock через `/proc/self/fd` оставило бы два bbolt на одном
 * файле — зависший продолжит писать, когда отвиснет (таймер метаданных
 * FakeIP, обновление rule-set). Это гарантированная порча.
 */
object CacheDbLockRetry {
    private const val TAG = "LxBox/CacheDb"

    /// Текст ядра: `start or reload service: initialize cache-file: timeout`
    /// (`E.Cause(err, "initialize cache-file")` + `bbolt.ErrTimeout`).
    /// Другие отказы cache-file (битый файл, права) сюда не попадают — их
    /// лечит самолечение ядра или §334.
    fun isLockTimeout(t: Throwable): Boolean {
        val m = t.message ?: return false
        return m.contains("initialize cache-file") && m.contains("timeout")
    }

    /// Выполнить [start]; на [isLockTimeout] — удалить `cache.db` и повторить
    /// ровно один раз. Любая другая ошибка и ошибка повтора уходят вызывающему
    /// как есть — его обработка отказа старта не меняется.
    inline fun <T> startOrRetry(where: String, start: () -> T): T {
        return try {
            start()
        } catch (t: Throwable) {
            if (!isLockTimeout(t)) throw t
            onLockTimeout(where, t)
            start()
        }
    }

    @PublishedApi
    internal fun onLockTimeout(where: String, t: Throwable) {
        Log.w(TAG, "[$where] start failed on cache.db lock (${t.message}) → delete cache.db, retry once")
        BoxVpnService.deleteCacheDbFile()
    }
}
