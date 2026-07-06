# 247 — resolve-action у пользовательских правил (inline/srs)

## Контекст

§246 научил **пресеты** эмитить пару `[resolve ipv4_only, route]` (rule-массив).
Та же потребность есть у **пользовательских правил**: юзер хочет форсить
семейство адресов (ipv4_only) для своего матча, оставаясь на обычном
`outbound`. Плюс продвинутый режим «только резолв» (нетерминальное правило,
fall-through к следующим).

Все поля route-action `resolve` в sing-box 1.14 **не deprecated**
(проверено по доке): `server`, `strategy`, `disable_cache`,
`disable_optimistic_cache`, `rewrite_ttl`, `timeout`, `client_subnet`.

## Решения (согласовано)

| Вопрос | Решение |
|---|---|
| Режимы | `route` (как сейчас) / `route + resolve` (**флагман**) / `resolve only` (advanced) |
| UI-вход | Шестерёнка ⚙ рядом с Action-пикером **в редакторе правила** (не в списке) |
| Окно | Большой modal bottom sheet «Action & Resolve»: radio-режимы сверху, **единая** панель Resolve options внизу (видна когда resolve активен) |
| Resolve options | strategy + server на виду; «Advanced DNS options» (свёрнуто): disable_cache / disable_optimistic_cache / rewrite_ttl / timeout / client_subnet |
| Маркер в списке | Просто значок ✳ (не кликабельный) в нижней Row строки — паттерн DNS-чипа §231 |
| resolve-only warning | Оранжевый inline-текст в окне («resolves but doesn't route → Final»). `emitWarnings` билдера НЕ трогаем — выбор осознанный |
| Правило без домена | inline без domain/suffix/keyword → ⚙ скрыта; при опустении доменных полей активный resolve **сбрасывается** на простой outbound. srs → ⚙ всегда видна (содержимое .srs неизвестно) |
| Отложено | `sniff`, `route-options` (в т.ч. `tls_fragment`/`tls_spoof` — отдельная анти-DPI тема) |

## Модель (`app/lib/models/custom_rule.dart`)

Новый вложенный класс по образцу `RuleDns` (строки 240-264 — enabled/serverTag,
null-safe `fromJson(dynamic)`, `copyWith`):

```dart
/// §247 — resolve-опция правила. null = обычный outbound (все старые записи).
class RuleResolve {
  const RuleResolve({
    this.only = false,          // false = resolve перед route (флагман);
                                // true = resolve-only (нетерминальное, advanced)
    this.strategy = '',         // '' = inherit dns.strategy
    this.serverTag = '',        // '' = auto (DNS-роутинг)
    this.disableCache = false,
    this.disableOptimisticCache = false,
    this.rewriteTtl,            // int? — null = не эмитить
    this.timeout = '',          // duration '5s'; '' = не эмитить
    this.clientSubnet = '',     // CIDR/IP; '' = не эмитить
  });
  // toJson / fromJson(dynamic j) → null при j is! Map / copyWith — как RuleDns
}
```

- `CustomRuleInline` / `CustomRuleSrs`: поле `RuleResolve? resolve` (null у
  старых записей — миграция не нужна, паттерн `dns`).
- `outbound` при `only=true` в модели **сохраняется** (переключение
  режимов туда-обратно не теряет выбор), но билдер/UI его игнорируют.
- Гейт применимости — getter на модели:
  `bool get resolveEligible` — inline: domain-группа непуста
  (`domains+domainSuffixes+domainKeywords`); srs: всегда true.
- `bool get resolveActive => resolve != null && resolveEligible` — для ✳ и билдера.

## Билдер (`app/lib/services/builder/post_steps/custom_rules.dart`)

Хелпер эмиссии resolve-правила (рядом с `_outboundToRoute`, ~519):

```dart
Map<String, dynamic> _resolveToRoute(String tag, RuleResolve r, {…AND-поля…}) {
  // {rule_set: tag?, action: 'resolve'} + strategy/server/… только непустые
  // + те же routing-level AND-поля (protocol/inbound/…), что у _outboundToRoute
}
```

- `_applyInlineSingle`: после `registry.addRuleSet(headless)` — если
  `cr.resolveActive`: эмитить `_resolveToRoute(tag, …)` **перед**
  `_outboundToRoute(tag, …)`; при `resolve.only` — route-правило НЕ эмитится.
  Ветка `match.isEmpty` (routing-level-only, домена нет) — resolve не эмитится
  (гейт `resolveEligible` уже false).
- `_applySrsSingle`: то же — resolve-правило с тем же srs-tag перед route.
- `kOutboundReject` + resolve: reject остаётся терминальным правилом, resolve
  перед ним (валидная пара: резолв, затем reject — практической пользы мало,
  но не ломаем).

## UI

### Редактор (`custom_rule_edit/`)

- `tabs/params_tab.dart:72-80` — рядом с `OutboundPicker(label: 'Action')`
  IconButton ⚙ (`Icons.settings`, dense). Видимость: `kind == srs ||`
  domain-группа непуста (контроллер уже нотифицирует на каждый keystroke —
  `_onTextChanged`, edit_controller:190-195).
- Под пикером inline-статус, когда resolve активен:
  `✳ Resolve first · ipv4_only` / `✳ Resolve only · ipv4_only`.
- **Сброс:** в `edit_controller` при notify — если `!eligible && _resolve != null`
  → `_resolve = null` (тихо; ⚙ и статус исчезают). Реализация в геттере
  состояния, не в snapshot() — чтобы UI сразу отразил.
- Окно «Action & Resolve» — `showModalBottomSheet(isScrollControlled: true)`
  (паттерн live_events_tab:104-133):
  - radio `Route to outbound` (внутри: OutboundPicker + чекбокс
    `Resolve first (force address family)`) / radio `Resolve only` (⚠ оранжевый
    inline-warning);
  - панель `Resolve options` (одна на оба режима): Strategy dropdown
    (`(inherit)`/prefer_ipv4/prefer_ipv6/ipv4_only/ipv6_only), DNS server
    dropdown (`(auto — route DNS)` + tags из DNS-настроек), раскрывашка
    Advanced (5 полей);
  - Preview `route.rules` (те же 1-2 записи, что уедут в конфиг — мини-версия
    ViewTab-механики: `applyCustomRules(reg, [snapshot()], skipDisabled: false)`);
  - Cancel / Done.
- `tabs/view_tab.dart` — правок не требует (preview идёт через
  `applyCustomRules`, который уже эмитит новые правила).

### Список (`routing_screen/widgets/custom_rule_tile.dart`)

- В нижней Row рядом с DNS-чипом (116-120): `if (resolveActive)` → значок ✳
  (компактный Text/Icon, стиль как `_dnsChip`, без текста и без тапа).
- `routing_screen.dart:_effectiveOutboundOf` — для resolve-only `rule.outbound`
  не используется билдером, но insertion-sort безопасен: пустой/любой outbound
  падает в хвост (639-669) — правок не требуется, зафиксировать тестом не надо
  (UI-сортировка).

## Debug API

- `serializers/rules.dart` (24-66): у inline/srs добавить
  `if (r.resolve != null) 'resolve': {only, strategy, server_tag,
  disable_cache, disable_optimistic_cache, rewrite_ttl, timeout,
  client_subnet}` — снейк-кейс как у `dns`.
- `handlers/rules.dart` (75-150): POST `_ruleFromJsonStrict` + PATCH
  `setIfPresent` — парсинг `resolve` (объект → RuleResolve, `null` → снять).
- `/help` — описание поля.

## Валидатор / heal

`validator.dart:31-40` проверяет только `outbound`-ссылки — resolve-only
правило (без `outbound`) проходит.

**`healDanglingResolveServers`** (post-step, паттерн §172 detour-heal) —
итог ревью: route-правило `{action: resolve, server: <tag>}` со ссылкой на
сервер, отсутствующий в `dns.servers`, ядро НЕ ловит на старте — валит
каждое сматчившееся соединение лениво («DNS server not found»,
route/route.go actionResolve). Источники dangling: пресет ru-direct
(server эмитится route-аспектом, сервер — DNS-аспектом; выключенная
DNS-галка / first-build → повис), юзер-`serverTag` §247 (сервер
выключили/удалили в DNS Settings), raw-JSON. Heal снимает `server` +
warning → резолв деградирует в DNS-роутинг, трафик жив. Вызов — в
`build_config` перед `validateConfig`, рядом с `healDanglingDetours`.

Валидация форматов: UI-окно (rewrite_ttl uint32, timeout duration-паттерн,
client_subnet IP/CIDR — Done блокируется) + Debug API strict (BadRequest на
битое значение, включая нечисловую строку rewrite_ttl и не-bool флаги).

## Сброс resolve при исчезновении доменного матча

Итог ревью: live-сброс на keystroke — UX-ловушка (юзер стирает домен,
чтобы вписать новый → настройка потеряна безвозвратно). Итоговая семантика:
- состояние контроллера resolve НЕ сбрасывает;
- `snapshot()` гейтит: Save правила без доменной группы → `resolve: null`
  (сохранённое правило без доменов опцию не тащит — требование задачи);
- билдер гейтит эмиссию через `resolveActive`;
- UI прячет ⚙/статус через `resolveEligible` (live по форме).

## Тесты

- `test/builder/custom_rules_test.dart`:
  - inline + resolve(беforeRoute) → ДВА правила, resolve первым, оба с одним tag;
  - inline + resolve(only) → ОДНО нетерминальное, без outbound;
  - srs + resolve → пара с srs-tag;
  - inline без доменных полей + resolve в модели → resolve НЕ эмитится
    (гейт eligible);
  - reject + resolve → resolve + `{action: reject}`;
  - advanced-поля: пустые не эмитятся, заданные эмитятся.
- Модель: `RuleResolve` roundtrip toJson/fromJson, null у старых записей,
  copyWith.
- Debug API: serializer отдаёт `resolve`, POST/PATCH принимают/снимают.

## Верификация

`flutter analyze` (весь проект) + `flutter test` + device: правило с
resolve ipv4_only на свой домен → core-лог dial IPv4; resolve-only → трафик
уходит в следующий матч/final.
