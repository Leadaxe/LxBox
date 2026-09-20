import '../../../models/node_spec.dart';
import '../mappers/uri_pipeline.dart';

// ════════════════════════════════════════════════════════════════════════════
// Shadowsocks (SIP002 + legacy base64 + SS2022)
// ════════════════════════════════════════════════════════════════════════════

/// §472 шаг 4 — shadowsocks разбирается КОНВЕЙЕРОМ: маппер переводит все три
/// формы записи в сырую карту sing-box, санитайзер реестра судит значения,
/// `parseSingboxEntry` строит модель (`mappers/uri_pipeline.dart`,
/// `mappers/shadowsocks_mapper.dart`).
///
/// Своего разбора у этой функции больше нет — осталось имя, под которым её
/// зовут `parseUri` и тесты. Что уехало из неё в реестр:
///
/// | было рукописным | стало правилом реестра | код |
/// |---|---|---|
/// | `isValidShadowsocksMethod` — гейт метода, узел молча отбрасывался | `protocols/shadowsocks.json` → `method`, enum из 18 + `on_invalid: drop_node` | `ss_method_invalid` (был БЕЗ кода вовсе: узел просто исчезал) |
/// | `isLegacyShadowsocksMethod` + рукописный `RegistryWarning` | `protocols/shadowsocks.json` → `method`, `advisory` (D-122) | `ss_method_legacy` (тот же код, теперь из реестра и с `params`) |
///
/// Рукописных правил ЗНАЧЕНИЯ у схемы не осталось ни одного — она первая
/// такая. Рукописным остался только ПЕРЕВОД: выбор формы записи (SIP002
/// против legacy), снятие percent-кодирования с userinfo перед base64,
/// пароль как ВСЁ после первого `:` (у SS2022 он составной, `k1:k2`),
/// раскладка `plugin=name;opts` на два поля тела, адрес IPv6 в скобках.
ShadowsocksSpec? parseShadowsocks(String uri) =>
    parseUriViaPipeline(uri, 'ss') as ShadowsocksSpec?;
