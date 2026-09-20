import '../../../models/node_spec.dart';
import '../mappers/uri_pipeline.dart';

// ════════════════════════════════════════════════════════════════════════════
// Hysteria2
// ════════════════════════════════════════════════════════════════════════════

/// §472 шаг 5 — hysteria2 разбирается КОНВЕЙЕРОМ: маппер переводит ссылку в
/// сырую карту sing-box, санитайзер реестра судит значения,
/// `parseSingboxEntry` строит модель (`mappers/uri_pipeline.dart`).
///
/// Первая QUIC-схема на конвейере. Что уехало из неё в реестр:
///
/// | было рукописным | стало правилом реестра | код |
/// |---|---|---|
/// | `forbiddenTlsBlockWarnings` — рукописный проход по `tls.utls`/`tls.reality` (§469) | `tls.json` → `forbidden_for` + `forbidden_codes`, исполняет САНИТАЙЗЕР | `tls_not_applicable_quic`, по одному на блок |
/// | `normalizeHysteria2Obfs` — тип вне `salamander|gecko` | `hysteria2.json` → `obfs.type`, enum + `on_invalid: drop` | `obfs_unknown` (теперь с путём и значением) |
/// | `normalizeHysteria2Obfs` — obfs без пароля | `hysteria2.json` → `obfs.password`, `required` + собственный `code` | `obfs_password_missing` |
/// | рукописная пара `field_requires` на размерах пакетов не-gecko | `hysteria2.json` → `obfs.{min,max}_packet_size`, `requires` с `equals: gecko` | `field_requires` |
/// | `normalizeTlsFingerprint` — мусорный `fp` → `chrome` | `tls.json` → `utls.fingerprint` (блок всё равно снимает `forbidden_for`) | — |
/// | `InsecureTlsWarning` при `insecure` | `tls.json` → `insecure`, `advisory` (§474) | `tls_insecure` с путём и значением |
/// | `isValidRealityPublicKey` — гейт REALITY ради `value` кода | `tls.json` → `reality`, `forbidden_for` судит блок целиком | `tls_not_applicable_quic` |
///
/// Рукописным остался ПЕРЕВОД написания — работа маппера по определению:
/// алиас схемы `hy2://`, base64-обёртка тела ссылки, multi-port в authority,
/// раскладка плоских `obfs-*` во вложенный объект, оба написания полосы
/// (`upmbps`/`up_mbps`) и эвристика SNI.
Hysteria2Spec? parseHysteria2(String uri) =>
    parseUriViaPipeline(uri, 'hysteria2') as Hysteria2Spec?;
