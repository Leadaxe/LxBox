import '../../../models/node_spec.dart';
import '../mappers/uri_pipeline.dart';

// ════════════════════════════════════════════════════════════════════════════
// Trojan
// ════════════════════════════════════════════════════════════════════════════

/// §472 шаг 2 — trojan разбирается КОНВЕЙЕРОМ: маппер переводит ссылку в сырую
/// карту sing-box, санитайзер реестра судит значения, `parseSingboxEntry`
/// строит модель (`mappers/uri_pipeline.dart`).
///
/// Своего разбора у этой функции больше нет — осталось имя, под которым её
/// зовут `parseUri` и тесты. Что уехало из неё в реестр:
///
/// | было рукописным | стало правилом реестра |
/// |---|---|
/// | `_guardUrlPath` — битый percent-путь снимался с `type_invalid` | `transports.json` → `path`, `format: url_path` |
/// | `normalizeTlsFingerprint` — мусорный `fp` → `chrome` + предупреждение | `tls.json` → `utls.fingerprint`, enum + `on_invalid: coerce chrome`, код `utls_fp_unknown` |
/// | `InsecureTlsWarning` при `insecure` | `tls.json` → `insecure`, `advisory` |
/// | `_normalizeAlpn` — drop элемента, не похожего на ALPN-id | `tls.json` → `alpn`, `listable_string` |
/// | `TlsSpec.disabled` → `tls:{enabled:false}` в эмиссии | маппер не кладёт блок вовсе (`security_none_no_tls`) |
///
/// Рукописным осталось то, что судить нечем: ПЕРЕВОД написания (алиасы
/// параметров, uTLS-псевдонимы, `?ed=N` хвостом пути) — он по определению
/// работа маппера, и реестр описывает его секцией `mapper`, а не правилами
/// значений.
TrojanSpec? parseTrojan(String uri) =>
    parseUriViaPipeline(uri, 'trojan') as TrojanSpec?;
