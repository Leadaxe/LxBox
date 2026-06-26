# §125 — Настраиваемые каналы (Configurable Channels)

> **СТАТУС: DRAFT / ИДЕЯ.** Это предварительный черновик-фантазия, согласованный как
> «нафантазируй на своё усмотрение». Не реализовано. Open questions внизу —
> по ним нужно решение юзера до перехода к `plan.md`. Числа/имена ключей storage
> здесь — proposal, не финал.

## Контекст

Сейчас «каналы» роутинга (`vpn-1..vpn-4` + `@auto_proxy_tag`) — это `preset_groups[]`
из [`wizard_template.json`](../../../app/assets/wizard_template.json). Они **статичны**:
юзер может только **включить/выключить** канал тоглом в Routing → таб Channels.
Всё остальное (label, default-выбор, набор нод) зашито в template и не редактируется.

Модель: [`PresetGroup`](../../../app/lib/models/parser_config.dart) (`tag`, `type`,
`label`, `defaultEnabled`, `options`, `addOutbounds`). Runtime-снимок от ядра —
[`CcGroup`](../../../app/lib/vpn/cc_channel.dart) (`selected`, `items`).

Что **уже** персистится per-channel:
- `enabled_groups[]` — какие каналы включены (см. [STORAGE.md](../../STORAGE.md)).
- `ping_options.groups[tag]` — per-group ping url/timeout (§008).

Что **НЕ** персистится и зашито в template:
- `label` (отображаемое имя канала).
- `options.default` (что выбрано в селекторе по умолчанию).
- набор нод канала — сейчас фильтр **глобальный** ([`node_filter_screen.dart`](../../../app/lib/screens/node_filter_screen.dart),
  `excluded_nodes`, фича [§048 home-node-filters](../048%20home-node-filters/spec.md)),
  привязан к `@auto_proxy_tag`/`vpn-1`, один на всех.

## Цель

Дать юзеру настраивать каждый канал индивидуально:
1. **Тайтл** — менять отображаемое имя канала.
2. **Дефолт** — выбирать исходящий по умолчанию (нода / `direct-out` / `@auto_proxy_tag`).
3. **Фильтр нод** — у каждого канала свой набор нод (а не один глобальный фильтр).

## Нецели (для этого черновика)

- Создание/удаление произвольных каналов (CRUD сверх vpn-1..vpn-4) — вынесено в
  «будущее расширение», см. ниже. Черновик целит в **редактирование фиксированных** каналов.
- Смена `type` канала (selector ↔ urltest) юзером.
- Фильтр по критериям (страна/протокол/тег с авто-набором) — отдельная большая тема,
  здесь только ручной набор нод чекбоксами (как сейчас в node_filter, но per-channel).

---

## UX (proposal)

Идиома проекта для редактирования сложных сущностей — **полноэкранный редактор**
по `Navigator.push(MaterialPageRoute)` с back-guard `PopScope` (как
[`custom_rule_edit_screen.dart`](../../../app/lib/screens/custom_rule_edit_screen.dart),
[`dns_server_edit_screen.dart`](../../../app/lib/screens/dns_server_edit_screen.dart)).
Закладываем тот же паттерн.

### Routing → таб Channels (сейчас)
```
┌─ Channels ─────────────────────────────┐
│ ▣ VPN ①   selector · vpn-1 · required  │   ← только тогл вкл/выкл
│ ☐ VPN ②   selector · vpn-2             │
│ ☐ VPN ③   selector · vpn-3             │
│ ☐ VPN ④   selector · vpn-4             │
│ ▣ Include Auto  urltest · @auto…       │
└────────────────────────────────────────┘
```

### Routing → таб Channels (proposal)
Тогл остаётся слева; добавляется **affordance входа в редактор** (тап по телу тайла
или иконка-карандаш справа). `@auto_proxy_tag` и `vpn-1`-required-семантику сохраняем.
```
┌─ Channels ─────────────────────────────┐
│ ▣ Моя Германия  selector · vpn-1   ✎ ▸ │   ← кастомный label, тап → редактор
│ ☐ Стриминг      selector · vpn-2   ✎ ▸ │
│ ☐ VPN ③         selector · vpn-3   ✎ ▸ │   ← label не менялся → fallback template
│ ☐ VPN ④         selector · vpn-4   ✎ ▸ │
│ ▣ Include Auto  urltest · @auto…       │   ← urltest: редактор только фильтра нод
└────────────────────────────────────────┘
```

### ChannelEditScreen (новый, proposal)
```
┌─ Edit channel · vpn-1 ──────── [↺] [✓] ─┐   ↺ = reset to template, ✓ = save (dirty)
│ Title        [ Моя Германия            ]│   ← TextField, override label
│ Default out  [ @auto_proxy_tag      ▼  ]│   ← Dropdown: ноды канала + direct-out + auto
│                                          │
│ Nodes (filter)               12 / 30  ▸ │   ← открывает per-channel node-filter
│   тап → ChannelNodeFilterScreen          │     (тот же UI что §048, но scope=канал)
│                                          │
│ Ping (§008)        url / timeout      ▸ │   ← опц.: свернуть сюда существующий per-group ping
└──────────────────────────────────────────┘
```
- **Reset** (↺): снести все override'ы канала → вернуться к template-значениям.
- **Back-guard**: при dirty — диалог Save / Keep editing / Discard (как CustomRuleEditScreen).
- Для `type==urltest` (`@auto_proxy_tag`): скрыть Title/Default (urltest не selectable),
  оставить только Nodes-filter. Либо вообще не давать редактор, а оставить как §048.

### Home dropdown
Заодно чиним давний баг: dropdown канала на Home
([`home_controls.dart`](../../../app/lib/screens/home/widgets/home_controls.dart) ~118-148)
показывает **`tag`** («vpn-1»), а должен — `label` (кастомный, иначе template). После
фичи юзер видит «Моя Германия», а не «vpn-1».

---

## Модель данных (proposal)

Новая сущность — **override** поверх template-канала. Template остаётся source of
truth для дефолтов; storage хранит только дельту.

```dart
/// Пользовательский override поверх PresetGroup из template.
/// Хранится в storage по ключу channel_overrides[tag]. Любое поле = null → fallback на template.
class ChannelOverride {
  final String tag;            // ключ, совпадает с PresetGroup.tag (vpn-1..vpn-4)
  final String? label;         // null → PresetGroup.label
  final String? defaultOut;    // null → options.default из template
  final List<String>? excludedNodes; // null → нет per-channel фильтра (берётся всё)
  // ping уже живёт в ping_options.groups[tag] — не дублируем
}
```

Резолюция отображаемого канала на build/UI:
```
effectiveLabel   = override.label   ?? presetGroup.label   ?? tag
effectiveDefault = override.defaultOut ?? presetGroup.options['default']
effectiveNodes   = allNodes − (override.excludedNodes ?? globalExcluded ?? ∅)
```

## Storage (proposal)

Новый top-level ключ в `lxbox_settings.json` (см. [STORAGE.md](../../STORAGE.md)):
```json
"channel_overrides": {
  "vpn-1": { "label": "Моя Германия", "default": "@auto_proxy_tag", "excluded_nodes": ["node-slow"] },
  "vpn-2": { "label": "Стриминг" }
}
```
- Отсутствие ключа канала → канал полностью template-managed (текущее поведение).
- API в `settings_storage/` (по образцу `network.dart` setGroupPing/clearGroupPing):
  `getChannelOverride(tag)`, `setChannelOverride(...)`, `clearChannelOverride(tag)`.
- **Миграция**: новый ключ, дефолт `{}` — старые конфиги читаются без изменений.
  Глобальный `excluded_nodes` (§048) **остаётся** для `@auto_proxy_tag`; per-channel
  `excluded_nodes` — независимый слой (open question 3 — как они взаимодействуют).

## Билдер (proposal)

[`build_config.dart → _buildPresetGroups`](../../../app/lib/services/builder/build_config.dart):
1. `label` в config sing-box не уходит — это чисто UI-поле (sing-box не знает про label),
   так что override label трогает только Dart-слой/UI, не конфиг. ✔ дёшево.
2. `options.default` — сейчас читается из template + §141-валидация (default ∈ outbounds).
   Добавить: перед валидацией подменить на `override.defaultOut`, если задан.
3. Per-channel node-set — selector.outbounds канала строится с учётом
   `override.excludedNodes` (вычесть из полного списка нод). Сейчас полный список
   общий; нужно научить билдер давать разный набор нод разным selector-каналам.
   ⚠ Это самый нетривиальный кусок — затрагивает как формируются outbounds на канал.

---

## Объём / фазовка (proposal)

| Фаза | Что | Риск |
|---|---|---|
| **F1 — Title** | override label + резолюция в UI + фикс Home-dropdown (label вместо tag) | низкий (чистый UI, конфиг не трогаем) |
| **F2 — Default** | override default-out + подмена в билдере + §141-валидация | средний (билдер) |
| **F3 — Per-channel nodes** | per-channel node-filter экран + override.excludedNodes + билдер раздаёт разные наборы нод | высокий (билдер, пересборка selector.outbounds) |
| **Edit-экран** | ChannelEditScreen каркас + навигация из таба Channels + back-guard | средний (новый экран по идиоме custom_rule) |

Рекомендация: резать по фазам, F1 первой (виден результат, нулевой риск конфига),
F3 последней (самый тяжёлый, нужен аккуратный билдер).

## Будущее расширение (вне черновика)

- **CRUD каналов**: добавлять/удалять собственные каналы (vpn-5…, произвольные tag).
  Потребует: динамический `preset_groups` не только из template, генерация уникальных
  tag, снятие хардкодов `'vpn-1'` (required / route_final default / forced-add в
  [`routing_srs_cache.dart`](../../../app/lib/screens/routing_screen/routing_srs_cache.dart)),
  ревизия [`node_filter_screen.dart:104`](../../../app/lib/screens/node_filter_screen.dart)
  groupTags-set (сейчас захардкожен). Большой объём — отдельная фича.
- **Фильтр по критериям** (страна/протокол/тег → авто-набор нод) вместо ручных чекбоксов.
- **Иконка/цвет канала** в дополнение к label.

## Связанные спеки

- [§048 home-node-filters](../048%20home-node-filters/spec.md) — текущий глобальный node-filter,
  от которого «отпочковывается» per-channel вариант.
- [§008 ping and node management](../008%20ping%20and%20node%20management/spec.md) — per-group
  ping (`ping_options.groups[tag]`) — образец per-channel storage и место, куда логично
  свернуть ping-настройки в ChannelEditScreen.
- §184 (таска) — добавление 4-го канала vpn-4 (показала, что каналы динамичны из template).
- [§122 commandclient-migration](../122%20commandclient-migration/spec.md) — CcGroup runtime-модель.

## Docs to update — [deferred till release]

Черновик-идея, вне скопа релиза. При реализации обновить:
- `docs/STORAGE.md` — ключ `channel_overrides`.
- `docs/TEMPLATE.md` — пометить, что `label`/`options.default` теперь override-able.
- `CHANGELOG.md` — user-visible.
- `docs/ARCHITECTURE.md` — если F3 меняет data-flow билдера по нодам.

## Open questions (нужно решение юзера)

1. **«Фильтры» — какой смысл?** Черновик заложил вариант **(а): у каждого канала свой
   набор нод** (ручные чекбоксы, как §048 но per-channel). Альтернативы: (б) фильтр по
   критериям с авто-набором; (в) просто перенести существующий глобальный фильтр в карточку
   канала без per-channel-разделения. → выбрать.
2. **Объём настраиваемости.** Черновик = **редактировать фиксированные** vpn-1..vpn-4.
   Нужен ли сразу CRUD (добавлять свои каналы)? Если да — объём резко растёт (см. «Будущее»).
3. **Глобальный vs per-channel node-filter.** Сейчас §048 — один глобальный `excluded_nodes`
   на `@auto_proxy_tag`. Как сосуществуют: per-channel перекрывает глобальный? глобальный
   остаётся только для auto-канала, а selector-каналы получают свой? → определить слои.
4. **urltest-канал (`@auto_proxy_tag`).** Даём ли ему редактор (только node-filter, без
   label/default)? Или оставляем как §048 и редактор только для selector-каналов?
5. **Где affordance входа в редактор** — тап по всему тайлу (тогда тоглу нужно отдельное
   касание) или отдельная иконка-карандаш? Тап-по-тайлу конфликтует с привычкой «тогл = тап».
