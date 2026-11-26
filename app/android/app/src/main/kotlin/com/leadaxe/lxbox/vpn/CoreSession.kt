package com.leadaxe.lxbox.vpn

/// §742 — держатель активного клиента ядра сервисной роли (раньше — поле
/// `BoxService.commandClient`).
///
/// §745 — здесь [ServiceCommandClient]: openconnect, подпись узла в шторке,
/// Taildrop из уведомлений и активити; по [isUp] Taildrop и `ProbeSession`
/// узнают, поднято ли ядро. Клиент экрана (`BoxCommandClient`) держит
/// `ScreenCoreSession` — с §747 тоже в `:bg`. Окно ходит сюда вызовом
/// (`BgMethods`) только за openconnect ([OpenConnectControl]). `@Volatile`:
/// пишется из потока сервиса, читается из потоков вызовов.
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
}
