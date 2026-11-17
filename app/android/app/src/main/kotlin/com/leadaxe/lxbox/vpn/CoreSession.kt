package com.leadaxe.lxbox.vpn

/// §742 — держатель активного [BoxCommandClient] (раньше — поле
/// `BoxService.commandClient`).
///
/// §122 Фаза 0: статическая ссылка на клиента, чтобы `VpnPlugin` дёргал
/// императивы (urlTestOutbound/getRules/selectOutbound/closeConnection) и
/// lifecycle (screen/profiler connect/disconnect), а Taildrop и `ProbeSession`
/// узнавали, поднято ли ядро. `@Volatile`: пишется из потока сервиса, читается
/// из потока MethodChannel и других.
///
/// Открывает и закрывает сессию `BoxService` в прежних точках (после
/// `startCommandServer()` и Started / в `closeCommandServerAtomic`);
/// `shutdownAll()` клиента зовёт тоже он — [close] только обнуляет ссылку.
object CoreSession {

    @Volatile
    var client: BoxCommandClient? = null
        private set

    /// Ядро поднято: командный клиент открыт (прежняя проверка
    /// `commandClient != null`).
    val isUp: Boolean get() = client != null

    internal fun open(cc: BoxCommandClient) {
        client = cc
    }

    internal fun close() {
        client = null
    }
}
