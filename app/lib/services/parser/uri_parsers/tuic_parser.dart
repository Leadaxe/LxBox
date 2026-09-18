import '../../../models/node_spec.dart';
import '../mappers/uri_pipeline.dart';

// ════════════════════════════════════════════════════════════════════════════
// TUIC v5
// ════════════════════════════════════════════════════════════════════════════

/// §472 шаг 5 — tuic разбирается КОНВЕЙЕРОМ: маппер переводит ссылку в сырую
/// карту sing-box, санитайзер реестра судит значения, `parseSingboxEntry`
/// строит модель (`mappers/uri_pipeline.dart`).
///
/// Что уехало из этой функции в реестр:
///
/// | было рукописным | стало правилом реестра | код |
/// |---|---|---|
/// | `forbiddenTlsBlockWarnings` — рукописный проход по `tls.utls` (§469) | `tls.json` → `forbidden_for` + `forbidden_codes`, исполняет САНИТАЙЗЕР | `tls_not_applicable_quic` |
/// | `_normalizeCongestion` — значение вне `{cubic, new_reno, bbr}` | `tuic.json` → `congestion_control`, enum + `on_invalid: drop` | `tuic_congestion_invalid` (был `TuicCongestionInvalidWarning` без пути) |
/// | `_normalizeUdpRelayMode` — значение вне `{native, quic}` | `tuic.json` → `udp_relay_mode`, enum + `on_invalid: drop` | `tuic_udp_relay_mode_invalid` (§463; путь и значение были и раньше) |
/// | `InsecureTlsWarning` при `insecure` | `tls.json` → `insecure`, `advisory` (§474) | `tls_insecure` с путём и значением |
/// | чтение `fp` «ради кода» (§469) | блок `utls` доезжает до судьи обычным порядком | `tls_not_applicable_quic` |
///
/// Рукописным остался ПЕРЕВОД написания — работа маппера по определению:
/// `uuid:password` в userinfo, три написания 0-RTT, `heartbeat` голым числом,
/// `disable_sni=1` как отсутствие имени сервера в теле.
///
/// **Одно поведение изменилось намеренно** — `uuid` не в форме UUID. Реестр
/// объявляет у поля `format: uuid` с `on_invalid: drop`, и санитайзер такое
/// значение снимает; узел остаётся без обязательного поля и отбраковывается.
/// Прежде он строился и уезжал в ядро, где «invalid uuid» роняет ВЕСЬ конфиг.
/// Корпус эту границу уже провёл сам (SPEC 131 W2c): заглушки `u` в его
/// кейсах заменены настоящими UUID с пометкой «ядро отвергает их фаталом на
/// весь конфиг, то есть кейс нормировал тело, которое не запускается».
TuicSpec? parseTuic(String uri) =>
    parseUriViaPipeline(uri, 'tuic') as TuicSpec?;
