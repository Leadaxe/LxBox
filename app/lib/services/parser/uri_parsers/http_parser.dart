import '../../../models/node_spec.dart';
import '../mappers/uri_pipeline.dart';

// ════════════════════════════════════════════════════════════════════════════
// HTTP(S) CONNECT proxy — see task 222.
// ════════════════════════════════════════════════════════════════════════════

/// §472 шаг 6 — http(s)-прокси разбирается КОНВЕЙЕРОМ: маппер переводит ссылку
/// в сырую карту sing-box, санитайзер реестра судит значения,
/// `parseSingboxEntry` строит модель (`mappers/uri_pipeline.dart`).
///
/// Обе схемы: `proxy-http://` (plain) и `proxy-https://` (TLS). Кастомная
/// схема вместо голых `http(s)://` — те перехватываются `isSubscriptionUrl`
/// раньше `isDirectLink`, а в телах подписок промо-ссылки стали бы «нодами».
/// §268 — плюс-формы `proxy+http://` / `proxy+https://` эквивалентны.
///
/// Что уехало из этой функции в реестр:
///
/// | было рукописным | стало правилом реестра |
/// |---|---|
/// | `normalizeTlsFingerprint` — мусорный `fp` → `chrome` + предупреждение | `tls.json` → `utls.fingerprint`, enum + `on_invalid: coerce chrome`, код `utls_fp_unknown` |
/// | `InsecureTlsWarning` при `insecure` | `tls.json` → `insecure`, `advisory` (§474) |
/// | `alpnFromQuery` — drop элемента, не похожего на ALPN-id | `tls.json` → `alpn`, `listable_string` |
/// | `TlsSpec.disabled` → пустой блок в эмиссии | маппер блока не кладёт вовсе (`security_none_no_tls`) |
///
/// Рукописным остался ПЕРЕВОД написания: суффикс схемы как TLS-дискриминатор,
/// userinfo в трёх формах, `headers` строкой — см. `mappers/http_mapper.dart`.
HttpSpec? parseHttpProxy(String uri) {
  // Схема выбирает запись таблицы конвейера: у `-http` и `-https` РАЗНОЕ
  // тело (блок TLS есть или его нет), и это не алиас написания.
  final scheme = uri.split('://').first.toLowerCase();
  return parseUriViaPipeline(uri, scheme) as HttpSpec?;
}
