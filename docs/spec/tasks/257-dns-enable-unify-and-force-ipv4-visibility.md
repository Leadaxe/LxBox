# §257 — `dns_enable`-var пресета + Force IPv4 виден в DNS Settings

> **СТАТУС: В РАБОТЕ** (07.07.2026). Следствие §256 (Force IPv4 у
> пользовательского правила, в релизе v2.14.0): галку Force IPv4 без
> dedicated-сервера юзер ставит, но правило **не появляется** в списке
> DNS Settings — гейт видимости требовал `serverTag`. Плюс у пресета
> ru-direct нет явной галки «DNS вкл/выкл» (тумблер спрятан в
> `dns_options.rules`, дублирует смысл).
>
> **Решения владельца (диалог 07.07):** `RuleDns.enabled` НЕ трогаем;
> геттеры `dnsMirror*` НЕ переименовываем; миграций НЕТ; `isPresetDnsEnabled`
> **удаляем** (не «игнорируем») — единственный источник тумблера пресета =
> var `dns_enable` (default true, «кто надо — сам вырубит»).

## Проблема

1. **Force IPv4-правило невидимо в DNS Settings.** `_buildMirrorGroupChildren`
   (dns_settings_screen) показывает строку правила по `cr.dnsMirrorEligible`,
   а тот требует `dns?.serverTag.isNotEmpty` (custom_rule.dart:150-155).
   Правило с ОДНОЙ галкой Force IPv4 (без сервера) через гейт не проходит →
   не рисуется. Билдер эмитит его корректно — видимость сломана, не эмиссия.
2. **Жаргон «mirror».** `dnsMirrorActive`/`dnsMirrorEligible` — внутреннее
   слово, читается плохо. Владелец хочет единый словарь `dns_enable`.
3. **Тумблер DNS-аспекта пресета** живёт в `dns_options.rules`
   (`kind:preset`, `enabled`), тогглится свитчем в DNS Settings — у самого
   пресета (ru-direct) явной галки «DNS вкл/выкл» НЕТ. Владелец: сделать
   магической var `dns_enable` (как `dns_server`/`outbound`).
4. **Правило с двумя DNS-аспектами** (сервер + Force IPv4) показывалось бы
   одной строкой с одним свитчем — непонятно, что тумблится.

## Решение (согласовано с владельцем, по шагам диалога)

### A. НЕ трогаем (осознанные отказы владельца)

- `RuleDns.enabled` — поле и JSON-ключ остаются как есть.
- Геттеры `CustomRule.dnsMirrorActive`/`dnsMirrorEligible` — не переименовываем
  (жаргон «mirror» владельца не смущает).
- Миграций storage НЕТ (ни RuleDns, ни dns_options.rules).

### B. `dns_enable` — магическая var пресета (УДАЛЯЕТ `isPresetDnsEnabled`)

- Пресет объявляет var `dns_enable` (type `bool`, default `true`) → это
  **единственный** тумблер его DNS-блока. Билдер смотрит по имени (как
  `dns_server`/`outbound`, docs/TEMPLATE.md «Магические переменные»).
- **`isPresetDnsEnabled` УДАЛЯЕТСЯ** (не «игнорируется»): дублирующий механизм
  чтения `dns_options.rules[kind:preset].enabled` — источник багов «поставил,
  а не сработало». Билдер гейтит DNS-аспект пресета по
  `varsValues['dns_enable']` (default true когда var объявлена).
- **Миграции НЕТ:** старый `enabled` у `kind:preset`-записи просто перестаёт
  читаться; `dns_enable` default `true` повторяет прежнее «включено по
  умолчанию». У кого пресет был выключен старым свитчем — получит DNS
  включённым (владелец: «кто надо — сам вырубит»).
- **`kind:preset`-запись в `dns_options.rules` ОСТАЁТСЯ** — но только как
  позиционный якорь mirror-группы (§117: определяет место правил пресета в
  `dns.rules`). Её поле `enabled` — мёртвое, билдер не читает.
- **ru-direct И fakeip** (все пресеты с DNS-аспектом) получают var
  `dns_enable` (bool, default `true`), title «DNS». Рисуется движком vars
  в редакторе пресета БЕСПЛАТНО (как `force_ipv4`/`geoip_enabled`).
  Для fakeip (DNS-only) тумблер выключает FakeIP-обработку, не удаляя
  пресет — единообразие со строкой в DNS Settings (свитч, не иконка).

⚠ **Проверить перед удалением `isPresetDnsEnabled`:** не завязаны ли на него
orphan-cleanup / order-compaction `kind:preset`-записей (resolveDnsRulesList,
§117 решение №6). Если да — сохранить эти инварианты, убрав только
тумблер-семантику.

### C. DNS Settings — объединённый блок с 2 тумблерами (правило)

Правило с DNS-аспектами → **ОДИН блок-карточка** [`DnsRuleAspectsTile`]:
- общий заголовок = имя правила + бейдж `rule`;
- под-строка «Server» — **свитч** (`RuleDns.enabled`) + превью server-mirror
  + note. Видна при выбранном serverTag (`dnsMirrorEligible`), НЕЗАВИСИМО
  от `enabled` → **выключенный свитч оставляет строку видимой** (сервер
  помнится, включить обратно тут же). **Удаление сервера — в редакторе
  правила:** снятие галки «Send DNS to dedicated server» стирает serverTag
  (`setDnsEnabled(false)` → serverTag='', dns=null если Force тоже нет).
  Крестика у Server в DNS Settings НЕТ — двухступенчатость через редактор;
- под-строка «Force IPv4 (drop AAAA)» — **крестик** (не свитч): видна
  только когда галка стоит (`forceIpv4Active`, вариант A), крестик удаляет
  Force (`forceIpv4=false`). Помнить нечего → снял = убрал.

Правило **исчезает из DNS-секции**, когда нет ни serverTag, ни forceIpv4.

Пресет — как §253: один блок, все DNS-тела в превью; свитч → var
`dns_enable` (пишет `varsValues` через `saveCustomRules`); пресет без var —
строка с нейтральной иконкой вместо свитча.

**Свитч у Force IPv4:** снятие → `forceIpv4=false`; если у правила больше
нет DNS-аспектов (enabled=false, serverTag='') → `dns` обнуляется
(`copyWith(clearDns: true)` — не копим мёртвый RuleDns, §256-инвариант).

### D. Гейт видимости (следствие C)

Блок правила виден при `dnsMirrorEligible || (forceIpv4Eligible &&
dns.forceIpv4)` — был только `dnsMirrorEligible` (требовал serverTag).
**Force IPv4-only правило теперь появляется** — исходная жалоба закрыта.

Превью-mirror'ы: `_dnsMirrorsByRuleId` стала `Map<String, List>` — правило
несёт ДВА mirror'а (server + serverless), Map→entry молча терял второй
(латентный баг §256-превью).

## Файлы (фактические)

| Файл | Изменение |
|---|---|
| `models/custom_rule.dart` | `copyWith(clearDns:)` у Inline/Srs (обнуление dns; паттерн clearRewriteTtl) |
| `services/builder/post_steps/custom_rules.dart` | `presetDnsEnableVar` (public, единая точка истины) + гейт в _applyPresetSingle; параметр isPresetDnsEnabled удалён из applyPresetBundles/applyAllCustomRules |
| `services/builder/build_config.dart` | map isPresetDnsEnabled удалён |
| `services/builder/post_steps/dns_rules.dart` | комментарий якоря (enabled мёртв) |
| `screens/dns_settings_screen.dart` | `_presetDnsEnable`, `_dnsMirrorsByRuleId: Map<String,List>`, блок DnsRuleAspectsTile, `_toggleRuleForceIpv4`, `_togglePresetDnsEnable` |
| `screens/dns_settings_screen/widgets/dns_mirror_group_card.dart` | `DnsRuleAspectsTile`+`DnsAspectRow`; DnsMirrorTile.onToggle nullable (иконка вместо свитча) |
| `assets/wizard_template.json` | ru-direct var `dns_enable` (bool, default true, перед dns_server) |
| `docs/TEMPLATE.md`, `docs/STORAGE.md` | magic-var dns_enable; мёртвый enabled у kind:preset |
| тесты | isPresetDnsEnabled-вызовы убраны; §257-кейсы var-гейта (default true / false / без var) |

## Что НЕ делаем

- Не трогаем эмиссию §253/§256 (фикс видимости и тумблеров, не логики).
- `RuleDns.enabled`, `dnsMirrorActive/Eligible`, `forceIpv4*` — НЕ
  переименовываем (решение владельца).
- Debug API НЕ меняем: dns_enable — обычная var в vars_values.
- Шестерёнку-навигацию НЕ делаем (владелец отказался — свитчи остаются).
- Не убираем `dns_options.rules[kind:preset]` запись (якорь mirror-группы;
  её `enabled` — мёртвое поле, без миграции).

## Связанные

- §256 (Force IPv4 правила — источник бага видимости), §253 (Force IPv4
  пресета + previewBodies), §117 (DNS-rule группа), §033 (magic-vars,
  isPresetDnsEnabled), §121 (routing = король над DNS).
