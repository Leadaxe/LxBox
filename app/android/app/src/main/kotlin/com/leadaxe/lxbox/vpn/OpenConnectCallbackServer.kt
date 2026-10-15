package com.leadaxe.lxbox.vpn

import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.net.URI
import java.util.concurrent.atomic.AtomicBoolean

/// §654 C — временный loopback-слушатель для SSO openconnect в callback-режиме
/// (FortiGate SAML): шлюз после входа в браузере редиректит на
/// `http://127.0.0.1:<port>/…`, слушатель отдаёт короткую страницу и передаёт
/// полный URL в [onUrl] (один раз). Паритет с лаунчером
/// (`core/openconnect_sso_callback.go`).
///
/// Живёт в нативе, а не в Dart: пока человек в браузере, приложение в фоне, и
/// Flutter-движок может быть уже снят — слушатель и ответ ядру от него не
/// зависят. Слушает только 127.0.0.1 (наружу порт не открывается); loopback
/// идёт мимо tun.
class OpenConnectCallbackServer(
    val tag: String,
    val challengeId: String,
    private val port: Int,
    private val prefixes: List<String>,
    private val onUrl: (String) -> Unit,
) {
    companion object {
        private const val TAG = "OpenConnectSso"
        private const val READ_TIMEOUT_MS = 5_000

        private const val PAGE = "<!doctype html><html><head><meta charset=\"utf-8\">" +
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" +
            "<title>Sign-in complete</title></head>" +
            "<body style=\"font-family:sans-serif;text-align:center;margin-top:20vh\">" +
            "<h2>Sign-in complete</h2><p>You can return to the app.</p></body></html>"

        /// Полный URL запроса в форме, которую ждёт ядро: по умолчанию
        /// `http://127.0.0.1:<port><requestUri>`; префикс через `localhost` —
        /// URL строится его хостом. Пустой список — любой запрос, кроме favicon.
        fun match(port: Int, prefixes: List<String>, requestUri: String): String? {
            val def = "http://127.0.0.1:$port$requestUri"
            if (prefixes.isEmpty()) {
                return if (requestUri.startsWith("/favicon.ico")) null else def
            }
            for (raw in prefixes) {
                val p = raw.trim()
                if (def.startsWith(p)) return def
                val host = runCatching { URI(p).host }.getOrNull()
                    ?: p.removePrefix("http://").substringBefore(':').substringBefore('/')
                if (host.isEmpty()) continue
                val full = "http://$host:$port$requestUri"
                if (full.startsWith(p)) return full
            }
            return null
        }
    }

    private val closed = AtomicBoolean(false)
    private val delivered = AtomicBoolean(false)
    @Volatile private var socket: ServerSocket? = null

    /// Поднять слушатель. `null` — слушает; иначе текст ошибки (порт занят
    /// или запрещён).
    fun start(): String? {
        val ss = try {
            ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), port), 8)
            }
        } catch (e: Exception) {
            Log.w(TAG, "listen on 127.0.0.1:$port failed: ${e.javaClass.simpleName}")
            return e.message ?: e.javaClass.simpleName
        }
        socket = ss
        Thread({ acceptLoop(ss) }, "oc-sso-$port").apply { isDaemon = true }.start()
        Log.i(TAG, "callback listener on 127.0.0.1:$port")
        return null
    }

    private fun acceptLoop(ss: ServerSocket) {
        while (!closed.get()) {
            val s = try {
                ss.accept()
            } catch (_: SocketException) {
                break
            } catch (e: Exception) {
                Log.w(TAG, "accept failed: ${e.javaClass.simpleName}")
                break
            }
            runCatching { handle(s) }
                .onFailure { Log.w(TAG, "request failed: ${it.javaClass.simpleName}") }
            runCatching { s.close() }
        }
    }

    private fun handle(s: Socket) {
        s.soTimeout = READ_TIMEOUT_MS
        val reader = BufferedReader(InputStreamReader(s.getInputStream(), Charsets.ISO_8859_1))
        val requestLine = reader.readLine() ?: return
        // Заголовки дочитываем, чтобы браузер не получил RST до ответа.
        while (true) {
            val line = reader.readLine() ?: break
            if (line.isEmpty()) break
        }
        val parts = requestLine.split(' ')
        val uri = if (parts.size >= 2) parts[1] else ""
        val full = if (uri.startsWith("/")) match(port, prefixes, uri) else null
        val out = s.getOutputStream()
        if (full == null) {
            out.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
            out.flush()
            return
        }
        val body = PAGE.toByteArray(Charsets.UTF_8)
        out.write(
            ("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" +
                "Cache-Control: no-store\r\nContent-Length: ${body.size}\r\n" +
                "Connection: close\r\n\r\n").toByteArray(),
        )
        out.write(body)
        out.flush()
        // Первый URL уходит ядру; повторный запрос (обновление вкладки)
        // получает ту же страницу.
        if (delivered.compareAndSet(false, true)) {
            Log.i(TAG, "callback received on port $port")
            onUrl(full)
        }
    }

    /// Погасить слушатель. Идемпотентен.
    fun close() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { socket?.close() }
        socket = null
        Log.i(TAG, "callback listener on port $port closed")
    }
}
