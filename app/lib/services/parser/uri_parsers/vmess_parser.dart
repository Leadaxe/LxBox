import '../../../models/node_spec.dart';
import '../mappers/uri_pipeline.dart';

// ════════════════════════════════════════════════════════════════════════════
// VMess (base64-JSON v2rayN + legacy cleartext)
// ════════════════════════════════════════════════════════════════════════════

/// §472 шаг 4 — vmess разбирается КОНВЕЙЕРОМ: маппер переводит ОБА диалекта
/// ссылки в одну сырую карту sing-box, санитайзер реестра судит значения,
/// `parseSingboxEntry` строит модель (`mappers/uri_pipeline.dart`,
/// `mappers/vmess_mapper.dart`).
///
/// Своего разбора у этой функции больше нет — осталось имя, под которым её
/// зовут `parseUri` и тесты. Что уехало из неё в реестр:
///
/// | было рукописным | стало правилом реестра | код |
/// |---|---|---|
/// | `normalizeTlsFingerprint` — мусорный `fp` → `chrome` | `tls.json` → `utls.fingerprint`, enum + `on_invalid: coerce chrome` | `utls_fp_unknown` (был `UnknownFingerprintWarning` без адреса и значения) |
/// | `InsecureTlsWarning` при `insecure` | `tls.json` → `insecure` | код реестра с путём `tls.insecure` |
/// | `_guardUrlPath` — битый percent-путь транспорта | `transports.json` → `path`, `format: url_path` | `type_invalid` |
/// | `_normalizeAlpn` — drop элемента, не похожего на ALPN-id | `tls.json` → `alpn`, `listable_string` | — (значение проходит) |
/// | `TlsSpec.disabled` → `tls:{enabled:false}` в эмиссии | маппер блока не кладёт вовсе | — (`security_none_no_tls`, SPEC 045) |
///
/// Рукописным остался ПЕРЕВОД написания — работа маппера по определению:
/// выбор диалекта (JSON против cleartext, правило
/// `legacy_cleartext_fallback`), имена ключей контейнера (`add`/`id`/`aid`),
/// цепочка SNI `sni`→`host` вместо `sni`→`peer`, `net=h2` как «TLS включён»,
/// `chacha20-ietf-poly1305` как имя того же шифра в диалекте Xray.
///
/// Плюс ОДНО рукописное суждение, которое снять сегодня нельзя: сведение
/// мусорного `scy` к `auto`. Реестр правило знает, но корпус ждёт от этой
/// подмены молчания — разбор доводов и просьба к лаунчеру в
/// `vmess_mapper.dart`, `_securitySpelling`.
VmessSpec? parseVmess(String uri) =>
    parseUriViaPipeline(uri, 'vmess') as VmessSpec?;
