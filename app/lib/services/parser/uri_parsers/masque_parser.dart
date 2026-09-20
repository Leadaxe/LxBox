import '../../../models/node_spec.dart';
import '../mappers/uri_pipeline.dart';

// ════════════════════════════════════════════════════════════════════════════
// MASQUE (URI form) — §130
// ════════════════════════════════════════════════════════════════════════════

/// §472 шаг 7 — masque разбирается КОНВЕЙЕРОМ: маппер переводит ссылку в
/// сырую карту sing-box, санитайзер реестра судит значения,
/// `parseSingboxEntry` строит модель (`mappers/uri_pipeline.dart`).
///
/// Снятое рукописное правило одно — и оно было последним:
///
/// | Было рукописным | Стало правилом реестра | Код |
/// |---|---|---|
/// | форс `vhttp` вне `h3|h2|auto` в `h3` + `MasqueVhttpInvalidWarning` | `protocols/masque.json` → `body.fields.vhttp`, enum + `on_invalid: coerce h3` | `masque_vhttp_invalid` (был без пути и значения) |
///
/// Рукописным остался ПЕРЕВОД написания — работа маппера по определению:
/// приватный ключ в userinfo с фолбэком из query, `address=` списком в пару
/// `ip`/`ipv6`, `keep_alive` → `keep_alive_period`, дефолты ССЫЛКИ
/// (`vhttp: h3`, `profile: cloudflare`, `mtu: 1280`), снятые legacy-имена
/// `network=`/`server_name=` (контракт 0.8.0, D-078).
///
/// §469 — запрещённые на QUIC блоки `tls.utls`/`tls.reality` диалект ссылки
/// не знает вовсе (в `uri.query` реестра их нет), поэтому и рукописного
/// прохода здесь не было. На входе ТЕЛА они приходят, и там их с шага 1
/// снимает санитайзер правилом `forbidden_for` — `forbiddenTlsBlockWarnings`
/// после этого шага не осталось вызывающих ни на одном пути.
MasqueSpec? parseMasqueUri(String uri) =>
    parseUriViaPipeline(uri, 'masque') as MasqueSpec?;
