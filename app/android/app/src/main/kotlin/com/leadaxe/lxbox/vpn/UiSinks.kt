package com.leadaxe.lxbox.vpn

/**
 * §740 — sink'и EventChannel'ов Flutter-движка: объекты Flutter-движка, живут
 * на стороне UI. Ставит и снимает их `VpnPlugin` (onListen / onCancel /
 * onDetachedFromEngine), пишут в них `BoxCommandClient` (эмиттеры клиента
 * UI) и сам `VpnPlugin`.
 *
 * §747 — сервис живёт в другом процессе и сюда не пишет: лог ядра приходит
 * потоком через pipe (`UiLogPipeReader` → `coreLogSink`), состояние
 * openconnect — событием и вызовом (`ccOpenConnectSink`); см.
 * docs/ARCHITECTURE.md, раздел о границе процессов.
 *
 * До §740 поля лежали в `BoxVpnService.companion`; перенесены без изменений.
 */
object UiSinks {
    /// §043: Sink для core logs от sing-box → Flutter EventChannel.
    @Volatile
    var coreLogSink: io.flutter.plugin.common.EventChannel.EventSink? = null

    /// §122 Фаза 0 — sink'и нового CommandClient-канала (`BoxCommandClient`).
    /// Инвариант §2.1: эмиттер живёт во Flutter-процессе (как `coreLogSink`).
    @Volatile
    var ccStatusSink: io.flutter.plugin.common.EventChannel.EventSink? = null
    @Volatile
    var ccOutboundsSink: io.flutter.plugin.common.EventChannel.EventSink? = null
    @Volatile
    var ccGroupsSink: io.flutter.plugin.common.EventChannel.EventSink? = null
    @Volatile
    var ccConnectionsSink: io.flutter.plugin.common.EventChannel.EventSink? = null
    /// §180 — DNS-журнал из ядра (SPEC 018). Батч-доставка списком CcDnsQuery.
    @Volatile
    var ccDnsQueriesSink: io.flutter.plugin.common.EventChannel.EventSink? = null
    /// §579 — состояние узлов Tailscale (`SubscribeTailscaleStatus`): снапшот
    /// списком `{tag, backend_state, state_text}` на каждое обновление ядра.
    @Volatile
    var ccTailscaleSink: io.flutter.plugin.common.EventChannel.EventSink? = null
    /// §581 — ответы проверки устройства Tailscale (`StartTailscalePing`).
    @Volatile
    var ccTailscalePingSink: io.flutter.plugin.common.EventChannel.EventSink? = null
    /// §687 — события теста соединения (`StartConnectionTest`): батчи
    /// `{event: stage|result|error, …}`.
    @Volatile
    var ccConnectionTestSink: io.flutter.plugin.common.EventChannel.EventSink? = null
    /// §654 C — состояние endpoint'ов openconnect (`SubscribeOpenConnectStatus`):
    /// снапшот `{endpoints: [...], callback: {...}?}` на каждое обновление.
    @Volatile
    var ccOpenConnectSink: io.flutter.plugin.common.EventChannel.EventSink? = null
    /// §707 — снапшот входящих Taildrop узла (`SubscribeTaildropInbox`).
    @Volatile
    var ccTaildropInboxSink: io.flutter.plugin.common.EventChannel.EventSink? = null

    private val main = android.os.Handler(android.os.Looper.getMainLooper())

    /// §747 — WARN-строка журнала приложения от самой стороны окна (клиент
    /// ядра роли UI, полоса `lxbox-cc` процесса окна): пишется прямо в
    /// [coreLogSink], тем же видом, что строки сервиса (`WARN …`). Никто не
    /// слушает — строка только в logcat у вызывающего.
    fun appLogWarning(text: String) {
        main.post { runCatching { coreLogSink?.success(listOf("WARN $text")) } }
    }
}
