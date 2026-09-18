import '../../../models/node_spec.dart';
import '../mappers/uri_pipeline.dart';

// ════════════════════════════════════════════════════════════════════════════
// AnyTLS — see task 269.
// ════════════════════════════════════════════════════════════════════════════

/// §472 шаг 6 — anytls разбирается КОНВЕЙЕРОМ: маппер переводит ссылку в сырую
/// карту sing-box, санитайзер реестра судит значения, `parseSingboxEntry`
/// строит модель (`mappers/uri_pipeline.dart`).
///
/// Своего разбора у этой функции больше нет — осталось имя, под которым её
/// зовут `parseUri` и тесты. Что уехало из неё в реестр:
///
/// | было рукописным | стало правилом реестра |
/// |---|---|
/// | `AnyTlsMinIdleInvalidWarning` — `min_idle_session` не неотрицательное целое | `protocols/anytls.json` → `min_idle_session`, `min: 0` + `on_invalid: drop`, код `anytls_min_idle_invalid` с путём и значением |
/// | `normalizeTlsFingerprint` — мусорный `fp` → `chrome` + предупреждение | `tls.json` → `utls.fingerprint`, enum + `on_invalid: coerce chrome`, код `utls_fp_unknown` |
/// | `InsecureTlsWarning` при `insecure` | `tls.json` → `insecure`, `advisory` (§474) |
/// | `isValidRealityPublicKey` — гейт REALITY по §169 | `tls.json` → `reality.public_key`, `format: base64_32`, код `reality_pbk_invalid` |
/// | `realityShortIdWouldDegrade` + `normalizeRealityShortId` | `tls.json` → `reality.short_id`, `format: hex`, `normalize: hex_only`, `max: 16`, `len_parity: even` |
/// | `_keyShareFromQuery` — enum `hybrid`/`classical` | `tls.json` → `reality.key_share`, enum + `normalize: trim_lower` |
/// | `alpnFromQuery` — drop элемента, не похожего на ALPN-id | `tls.json` → `alpn`, `listable_string` |
///
/// Рукописным остался ПЕРЕВОД написания: пароль целиком из userinfo, снятие
/// `security` перед чтением TLS (AnyTLS живёт только поверх TLS), голое число
/// duration-полей как секунды и эвристика SNI — см. `mappers/anytls_mapper.dart`.
AnyTlsSpec? parseAnyTls(String uri) =>
    parseUriViaPipeline(uri, 'anytls') as AnyTlsSpec?;
