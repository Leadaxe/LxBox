package com.leadaxe.lxbox.vpn

/**
 * §740 — запросы «что открыть в UI» от тапа по уведомлению. Пишет
 * `MainActivity` (разбор интента), забирает `VpnPlugin` (метод Dart) — обе
 * стороны UI, к сервису VPN не относятся.
 *
 * До §740 поля лежали в `BoxVpnService.companion`; перенесены без изменений.
 */
object UiLaunchRequests {
    /// §654 C — тап по уведомлению «Sign-in required»: тег узла, чей
    /// челлендж показать. Dart забирает его на старте и при возврате.
    @Volatile
    var openConnectOpenRequest: String? = null

    /// §707 — тап по уведомлению Taildrop: тег узла, чью вкладку Network
    /// открыть. Dart забирает его на старте и при возврате.
    @Volatile
    var taildropOpenRequest: String? = null
}
