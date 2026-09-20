import '../../../models/node_spec.dart';
import '../mappers/uri_pipeline.dart';

// ════════════════════════════════════════════════════════════════════════════
// VLESS
// ════════════════════════════════════════════════════════════════════════════

/// §472 шаг 3 — vless разбирается КОНВЕЙЕРОМ: маппер переводит ссылку в сырую
/// карту sing-box, санитайзер реестра судит значения, `parseSingboxEntry`
/// строит модель (`mappers/uri_pipeline.dart`, движок по секции реестра).
///
/// Своего разбора у этой функции больше нет — осталось имя, под которым её
/// зовут `parseUri` и тесты. Что уехало из неё в реестр:
///
/// | было рукописным | стало правилом реестра | код |
/// |---|---|---|
/// | `normalizePacketEncoding` — мусор вне набора ядра снимался вручную | `protocols/vless.json` → `packet_encoding`, enum + `on_invalid: drop` | `packet_encoding_unknown` (был `PacketEncodingUnknownWarning` без адреса) |
/// | `DeprecatedFlowWarning` — `flow` вне пары `""`/`vision` | `protocols/vless.json` → `flow`, enum + `on_invalid: drop` | `flow_deprecated` (тот же код, теперь с путём) |
/// | `isValidRealityPublicKey` — гейт REALITY-блока по §169 | `tls.json` → `reality.public_key`, `format: base64_32` | `reality_pbk_invalid` (был рукописный `RegistryWarning` в `transport.dart`) |
/// | `realityShortIdWouldDegrade` + `normalizeRealityShortId` | `tls.json` → `reality.short_id`, `format: hex`, `normalize: hex_only` | `reality_short_id_invalid` (был `RealityShortIdInvalidWarning`) |
/// | `realityKeyShareFromQuery` — enum `hybrid`/`classical` | `tls.json` → `reality.key_share`, enum + `normalize: trim_lower` | `reality_key_share_invalid` |
/// | `normalizeTlsFingerprint` — мусорный `fp` → `chrome` | `tls.json` → `utls.fingerprint`, enum + `on_invalid: coerce chrome` | `utls_fp_unknown` (был `UnknownFingerprintWarning` без адреса) |
/// | `RealityFingerprintWarning` — отпечаток без гибридного key share | `tls.json` → `utls.fingerprint`, `advisory` с `except` | `reality_fp_not_chrome` (тот же код, теперь с путём) |
/// | `InsecureTlsWarning` при `insecure` | `tls.json` → `insecure`, `advisory` | `tls_insecure` |
/// | `_guardUrlPath` — битый percent-путь транспорта | `transports.json` → `path`, `format: url_path` | `type_invalid` |
/// | `_normalizeAlpn` — drop элемента, не похожего на ALPN-id | `tls.json` → `alpn`, `listable_string` | — (значение проходит) |
/// | `TlsSpec.disabled` → `tls:{enabled:false}` в эмиссии | маппер блока не кладёт вовсе | — (`security_none_no_tls`, SPEC 045) |
///
/// | `VisionWithTransportWarning` — гашение `flow` при живом транспорте | `protocols/vless.json` → `flow`, `conflicts` со своим кодом | `vision_with_transport` (§474, контракт 1.1.6) |
///
/// Правил значения рукописными у схемы не осталось: последнее — гашение
/// vision — уехало в реестр вместе с прочтением `conflicts` (снимается
/// ДЕКЛАРАНТ, а не младшее по `body.order`, §474). Рукописным остаётся только
/// ПЕРЕВОД написания: он по определению работа маппера, и реестр описывает
/// его секцией `mapper`, а не правилами значений.
VlessSpec? parseVless(String uri) =>
    parseUriViaPipeline(uri, 'vless') as VlessSpec?;
