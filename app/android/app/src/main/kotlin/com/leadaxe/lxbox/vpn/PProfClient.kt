package com.leadaxe.lxbox.vpn

import android.util.Log
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.PProfServer
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL

/// §207 — снимаем диагностические pprof-слепки через встроенный в libbox
/// `PProfServer` (Go `net/http/pprof`). Сервер поднимается **по требованию**
/// на loopback, обслуживает ОДИН GET и сразу гасится — в проде http-listener
/// не висит (нулевая постоянная поверхность атаки).
///
/// Один сервер бесплатно отдаёт весь набор `/debug/pprof/*`: goroutine,
/// profile (CPU), heap, allocs, block, mutex, threadcreate. Поэтому ядро
/// этого класса — обобщённый [fetch]; high-level врапперы лишь подставляют
/// path. Для §207-бага (нагрев) нужны [cpuProfile] + [goroutineDump];
/// остальное доступно тем же кодом через Debug API `/diag/pprof`.
///
/// Почему фиксированный порт, а не `:0`: `PProfServer` API (`start()`/
/// `close()`) **не отдаёт фактический порт**, поэтому эфемерный `:0`
/// бесполезен — мы бы не знали, куда стучаться. Берём первый свободный из
/// узкого диапазона: `start()` бросает на занятом порту → пробуем следующий.
///
/// Ограничение: при рантайм-дедлоке ядра http-горутина не ответит (GET
/// повиснет → timeout). Для busy-spin / 100% CPU (ядро активно крутит)
/// сервер жив и отвечает — это целевой кейс §207.
object PProfClient {
    private const val TAG = "PProfClient"

    /// Кандидаты-порты на loopback. 6060 — конвенция Go pprof.
    private val PORT_CANDIDATES = intArrayOf(6060, 6061, 6062, 6063, 6064, 6065)

    /// Время на собственно соединение (не включает «полезную» работу профиля).
    private const val CONNECT_TIMEOUT_MS = 2000

    /// Полный goroutine-дамп со стеками всех горутин (`?debug=2` → текст).
    fun goroutineDump(): String =
        String(fetch("goroutine?debug=2", readTimeoutMs = 5000), Charsets.UTF_8)

    /// CPU-профиль за `seconds` секунд → pprof `.pb` (protobuf). Сервер сам
    /// держит соединение `seconds` секунд, поэтому read-timeout должен быть
    /// БОЛЬШЕ длительности профиля, иначе SocketTimeout оборвёт сбор. Запас
    /// = `headroomMs`.
    fun cpuProfile(seconds: Int, headroomMs: Int = 5000): ByteArray =
        fetch("profile?seconds=$seconds", readTimeoutMs = seconds * 1000 + headroomMs)

    /// Обобщённый GET к `/debug/pprof/<pathAndQuery>` на эфемерно-поднятом
    /// сервере. Возвращает сырые байты (текст для `?debug=2`, иначе .pb).
    /// Бросает на сетевой/серверной ошибке — caller решает что делать.
    ///
    /// ВНИМАНИЕ: для `profile?seconds=N` read-timeout ОБЯЗАН быть > N*1000,
    /// иначе соединение оборвётся до конца записи. [cpuProfile] это уже
    /// учитывает; при прямом вызове — следить самому.
    fun fetch(pathAndQuery: String, readTimeoutMs: Int): ByteArray =
        withServer { port ->
            httpGet("http://127.0.0.1:$port/debug/pprof/$pathAndQuery", readTimeoutMs)
        }

    /// Поднимает `PProfServer` на первом свободном порту, выполняет [block],
    /// гарантированно гасит сервер. `start()` на занятом порту бросает →
    /// пробуем следующий кандидат.
    private fun <T> withServer(block: (port: Int) -> T): T {
        var server: PProfServer? = null
        var boundPort = -1
        var lastErr: Throwable? = null
        for (port in PORT_CANDIDATES) {
            try {
                val s = Libbox.newPProfServer(port.toLong())
                s.start()
                server = s
                boundPort = port
                break
            } catch (t: Throwable) {
                lastErr = t
                Log.d(TAG, "pprof start on :$port failed: ${t.message}")
            }
        }
        if (server == null) {
            throw IllegalStateException(
                "pprof server: no free port in ${PORT_CANDIDATES.first()}..${PORT_CANDIDATES.last()}",
                lastErr,
            )
        }
        try {
            return block(boundPort)
        } finally {
            try {
                server.close()
            } catch (t: Throwable) {
                Log.w(TAG, "pprof close failed", t)
            }
        }
    }

    private fun httpGet(url: String, readTimeoutMs: Int): ByteArray {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = readTimeoutMs
        }
        try {
            val code = conn.responseCode
            if (code != 200) {
                throw IllegalStateException("pprof GET $url → HTTP $code")
            }
            val out = ByteArrayOutputStream()
            conn.inputStream.use { it.copyTo(out) }
            return out.toByteArray()
        } finally {
            conn.disconnect()
        }
    }
}
