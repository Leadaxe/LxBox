package com.leadaxe.lxbox.vpn

import java.util.concurrent.CopyOnWriteArrayList

/// §742 — держатель активного клиента ядра сервисной роли (раньше — поле
/// `BoxService.commandClient`).
///
/// §745 — здесь [ServiceCommandClient]: openconnect, подпись узла в шторке,
/// Taildrop из уведомлений и активити; по [isUp] Taildrop и `ProbeSession`
/// узнают, поднято ли ядро. Клиент роли UI (`BoxCommandClient`) держит сторона
/// UI в `UiCoreSession`. `VpnPlugin` ходит сюда только за openconnect
/// ([OpenConnectControl]). `@Volatile`: пишется из потока сервиса, читается из
/// потока MethodChannel и других.
///
/// Открывает и закрывает сессию `BoxService` в прежних точках (после
/// `startCommandServer()` и Started / в `closeCommandServerAtomic`);
/// `shutdownAll()` клиента зовёт тоже он — [close] только обнуляет ссылку.
object CoreSession {

    @Volatile
    var client: ServiceCommandClient? = null
        private set

    /// Ядро поднято: командный клиент открыт (прежняя проверка
    /// `commandClient != null`).
    val isUp: Boolean get() = client != null

    internal fun open(cc: ServiceCommandClient) {
        client = cc
    }

    internal fun close() {
        client = null
    }

    /// §745 — слушатели «перед закрытием»: сервис зовёт их в
    /// `closeCommandServerAtomic` до `shutdownAll()` своего клиента и до
    /// закрытия командного сервера, чтобы чужие клиенты `command.sock` (клиент
    /// UI) успели отключиться. Сервис не знает, кто слушает; регистрирует
    /// `BoxApplication`. Список потокобезопасен: регистрация — с главного
    /// потока, вызов — из потока остановки.
    private val beforeCloseListeners = CopyOnWriteArrayList<() -> Unit>()

    fun addBeforeCloseListener(listener: () -> Unit) {
        beforeCloseListeners.add(listener)
    }

    /// Позвать слушателей по порядку регистрации. Сбой одного не мешает
    /// остальным и не выходит наружу: остановка туннеля идёт дальше.
    internal fun notifyBeforeClose() {
        for (l in beforeCloseListeners) runCatching { l() }
    }

    /// Только для unit-тестов.
    internal fun clearBeforeCloseListenersForTest() {
        beforeCloseListeners.clear()
    }
}
