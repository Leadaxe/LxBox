package com.leadaxe.lxbox.vpn

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.util.Log

/// §747 — нужно ли держать процесс окна живым: окно подключено (движок жив,
/// окно не закрыто) **и** туннель не `Stopped` либо идёт вызов `:bg` → Dart,
/// ждущий ответа окна ([pendingCalls], §750). Чистая функция — для теста.
fun uiHoldWanted(status: VpnStatus, uiAttached: Boolean, pendingCalls: Int = 0): Boolean =
    uiAttached && (status != VpnStatus.Stopped || pendingCalls > 0)

/// §747 — удержание процесса окна (`:ui`) на время работы туннеля.
///
/// В одном процессе foreground-сервис VPN держал живым и Dart: свёрнутое окно
/// продолжало обновлять подписки и rule-set по таймерам, принимать команды
/// автоматизации и слать её события. В двух процессах `:ui` без этого через
/// пару минут после Home замораживается системой.
///
/// Механизм — привязка из `:bg` к пустому сервису окна
/// ([UiKeepAliveService]): процесс, к сервису которого привязан процесс с
/// foreground-сервисом, получает его важность — не кэшируется, не
/// замораживается и не выгружается. Логики у привязки нет, это только
/// приоритет.
///
/// Привязка есть ровно пока выполняется [uiHoldWanted]; пересчитывается на
/// каждой смене статуса туннеля и при подключении, отключении и гибели окна
/// ([sync]). Туннель остановлен или окно закрыто — удержания нет, дальше
/// действует обычный жизненный цикл: `:ui` завершается сам после закрытия
/// окна, `:bg` завершается или перезапускается (`BgLifecycle`).
///
/// **Привязка не поднимает и не воскрешает `:ui`.** Она ставится только при
/// подключённом окне (процесс уже жив) и снимается внутри вызова `uiDetached`
/// — до того, как окно завершит свой процесс. Если процесс окна умер сам,
/// система собралась бы пересоздать сервис в новом процессе
/// (`BIND_AUTO_CREATE`): `onServiceDisconnected` / `onBindingDied` и
/// метка окна (`UiPresence`) снимают привязку сразу, раньше отложенного
/// системой перезапуска.
object UiHold {
    private const val TAG = "UiHold"

    private var connection: ServiceConnection? = null

    /// Идущие вызовы `:bg` → Dart с ответом (`UiCalls`): на их время окно
    /// удерживается и при остановленном туннеле — свёрнутое окно иначе могло
    /// бы быть заморожено и не ответить.
    private val calls = java.util.concurrent.atomic.AtomicInteger(0)

    fun callStarted(ctx: Context) {
        calls.incrementAndGet()
        sync(ctx)
    }

    fun callFinished(ctx: Context) {
        calls.decrementAndGet()
        sync(ctx)
    }

    /// Привести привязку к текущему состоянию. Зовётся из любого потока.
    fun sync(ctx: Context) {
        apply(ctx, uiHoldWanted(TunnelState.status, UiPresence.isAttached, calls.get()))
    }

    @Synchronized
    private fun apply(ctx: Context, wanted: Boolean) {
        val app = ctx.applicationContext ?: ctx
        val current = connection
        if (wanted == (current != null)) return
        if (!wanted) {
            connection = null
            runCatching { app.unbindService(current!!) }
            Log.i(TAG, "window process released")
            return
        }
        val conn = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: IBinder?) {}

            // Процесс окна умер: привязку снять сразу, иначе система
            // пересоздаст сервис — и процесс `:ui` без окна.
            override fun onServiceDisconnected(name: ComponentName?) = drop(app, this)
            override fun onBindingDied(name: ComponentName?) = drop(app, this)
            override fun onNullBinding(name: ComponentName?) = drop(app, this)
        }
        val ok = runCatching {
            app.bindService(Intent(app, UiKeepAliveService::class.java), conn, Context.BIND_AUTO_CREATE)
        }.getOrDefault(false)
        if (ok) {
            connection = conn
            Log.i(TAG, "window process held while the tunnel is up")
        } else {
            // По контракту bindService привязку надо снять и при отказе.
            runCatching { app.unbindService(conn) }
            Log.w(TAG, "cannot hold the window process")
        }
    }

    @Synchronized
    private fun drop(app: Context, conn: ServiceConnection) {
        if (connection !== conn) return
        connection = null
        runCatching { app.unbindService(conn) }
        Log.i(TAG, "window process is gone — hold dropped")
    }
}
