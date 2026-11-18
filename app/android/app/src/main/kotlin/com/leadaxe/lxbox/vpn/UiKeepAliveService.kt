package com.leadaxe.lxbox.vpn

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import com.leadaxe.lxbox.MainActivity

/// §747 — пустой сервис процесса окна (`:ui`), не экспортируется. Нужен только
/// как цель привязки из `:bg` (`UiHold`): пока туннель работает и окно
/// подключено, процесс с foreground-сервисом VPN привязан сюда, и процесс окна
/// получает его важность — система не замораживает и не выгружает свёрнутое
/// окно, Dart продолжает работать (таймеры обновления, автоматизация), как
/// было в одном процессе. Логики нет: ни команд, ни данных через эту привязку
/// не идёт.
class UiKeepAliveService : Service() {
    private val binder = Binder()

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onDestroy() {
        super.onDestroy()
        // Привязку сняли. Если окна в этом процессе нет (система пересоздала
        // процесс ради привязки уже после закрытия окна), процессу незачем жить.
        MainActivity.exitIfWindowless()
    }
}
