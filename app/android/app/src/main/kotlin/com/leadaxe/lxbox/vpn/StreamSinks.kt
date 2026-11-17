package com.leadaxe.lxbox.vpn

import io.flutter.plugin.common.EventChannel

/**
 * §747 — приёмники потоков данных окна на сервисной стороне (`:bg`).
 *
 * Клиенты ядра (`BoxCommandClient`, `ServiceCommandClient`) пишут снимки и
 * события в поле своего потока, как раньше писали в `EventSink` Flutter-движка
 * (до §747 — `UiSinks`). Движка в `:bg` нет: приёмник — [BgEventPipe.Sink], он
 * кладёт значение кадром в канал событий, а окно отдаёт его в свой
 * `EventChannel` того же имени.
 *
 * Поле не null, только пока Dart слушает поток: подписка и отписка
 * `EventChannel` приходят из окна вызовами `streamListen` / `streamCancel`.
 * Гейт «никто не слушает — не собирать» у эмиттеров клиентов прежний
 * (`sinkProvider() ?: return`).
 */
object StreamSinks {
    /// §122 Фаза 0 — потоки CommandClient-канала (`BoxCommandClient`).
    @Volatile
    var ccStatusSink: EventChannel.EventSink? = null

    @Volatile
    var ccOutboundsSink: EventChannel.EventSink? = null

    @Volatile
    var ccGroupsSink: EventChannel.EventSink? = null

    @Volatile
    var ccConnectionsSink: EventChannel.EventSink? = null

    /// §180 — DNS-журнал из ядра (SPEC 018). Батч-доставка списком CcDnsQuery.
    @Volatile
    var ccDnsQueriesSink: EventChannel.EventSink? = null

    /// §579 — состояние узлов Tailscale (`SubscribeTailscaleStatus`): снапшот
    /// списком `{tag, backend_state, state_text}` на каждое обновление ядра.
    @Volatile
    var ccTailscaleSink: EventChannel.EventSink? = null

    /// §581 — ответы проверки устройства Tailscale (`StartTailscalePing`).
    @Volatile
    var ccTailscalePingSink: EventChannel.EventSink? = null

    /// §687 — события теста соединения (`StartConnectionTest`): батчи
    /// `{event: stage|result|error, …}`.
    @Volatile
    var ccConnectionTestSink: EventChannel.EventSink? = null

    /// §654 C — состояние endpoint'ов openconnect (`SubscribeOpenConnectStatus`):
    /// снапшот `{endpoints: [...], callback: {...}?}` на каждое обновление.
    /// Пишет сервисный клиент ядра.
    @Volatile
    var ccOpenConnectSink: EventChannel.EventSink? = null

    /// §707 — снапшот входящих Taildrop узла (`SubscribeTaildropInbox`).
    @Volatile
    var ccTaildropInboxSink: EventChannel.EventSink? = null

    /// Поток: снимки (последний побеждает) или события (очередь) и его поле.
    private class Slot(val coalesce: Boolean, val set: (EventChannel.EventSink?) -> Unit)

    /// Имя потока — имя `EventChannel` в Dart (`platform_channels.dart`).
    private val slots: Map<String, Slot> = mapOf(
        "lxbox/cc/status" to Slot(true) { ccStatusSink = it },
        "lxbox/cc/outbounds" to Slot(true) { ccOutboundsSink = it },
        "lxbox/cc/groups" to Slot(true) { ccGroupsSink = it },
        "lxbox/cc/connections" to Slot(true) { ccConnectionsSink = it },
        "lxbox/cc/dns" to Slot(false) { ccDnsQueriesSink = it },
        "lxbox/cc/tailscale" to Slot(true) { ccTailscaleSink = it },
        "lxbox/cc/tailscale_ping" to Slot(true) { ccTailscalePingSink = it },
        "lxbox/cc/connection_test" to Slot(false) { ccConnectionTestSink = it },
        "lxbox/cc/openconnect" to Slot(true) { ccOpenConnectSink = it },
        "lxbox/cc/taildrop_inbox" to Slot(true) { ccTaildropInboxSink = it },
    )

    /// Dart подписался на поток [stream]. `false` — такого потока нет.
    fun listen(stream: String): Boolean {
        if (stream == BgEventPipe.STREAM_LOG) {
            BgEventPipe.setLogListening(true)
            return true
        }
        val slot = slots[stream] ?: return false
        slot.set(BgEventPipe.Sink(stream, slot.coalesce))
        if (stream == "lxbox/cc/connections") {
            // §193 — connections single-shot: ядро шлёт reset-снапшот РОВНО
            // один раз при подписке screenClient (pull в libbox нет). Новый
            // подписчик (открытие Stats при уже живом screenClient) не получает
            // нового reset → пусто. Переэмитим накопленный аккумулятор сразу.
            ScreenCoreSession.client?.reEmitScreenConnections()
        }
        return true
    }

    /// Dart отписался от потока [stream].
    fun cancel(stream: String) {
        if (stream == BgEventPipe.STREAM_LOG) {
            BgEventPipe.setLogListening(false)
            return
        }
        slots[stream]?.set?.invoke(null)
        BgEventPipe.forget(stream)
    }

    /// Окна больше нет: слушать некому.
    fun cancelAll() {
        for (slot in slots.values) slot.set(null)
        BgEventPipe.setLogListening(false)
    }
}
