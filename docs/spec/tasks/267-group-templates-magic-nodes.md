# 267 — `preset_groups` → `group_templates` + `magic_nodes`

## Проблема

Секция `preset_groups` в `wizard_template.json` сваливает в один плоский массив
**три разнородные сущности** и держит фейковую переменную:

```jsonc
"preset_groups": [
  { "tag": "@auto_proxy_tag", "type": "urltest",  "label": "Include Auto", "add_outbounds": [] },       // НЕ канал — шаблон auto-подгруппы
  { "tag": "vpn-1",           "type": "selector", "label": "VPN ①", "add_outbounds": ["direct-out","@auto_proxy_tag"] },
  { "tag": "vpn-2",           "type": "selector", "label": "VPN ②", "add_outbounds": ["direct-out","@auto_proxy_tag"] }
]
```

Что не так:

1. **`[0]` не канал.** Это шаблон auto-подгруппы (urltest), вкладываемой *внутрь*
   канала. Оба потребителя явно скипают его костылём
   `if (p.tag == kAutoOutboundTag) continue;`
   ([channels.dart:188](../../../app/lib/services/settings_storage/channels.dart),
   [build_config.dart:733](../../../app/lib/services/builder/build_config.dart)).

2. **`@auto_proxy_tag` — фейковая переменная.** Объявлена в `sections.General.vars`
   как `wizard_ui:"hidden"`, `default_value:"✨auto"`, read-only. У неё нет ни
   одного свойства переменной (не видна, не редактируется, одно значение). Это
   литерал `✨auto`, замаскированный под `@var`. Порождает спец-проход пре-резолва
   в [template_loader.dart:20-27](../../../app/lib/services/template_loader.dart)
   и третье ручное зеркало значения (`kAutoOutboundTag`,
   [consts.dart:15](../../../app/lib/config/consts.dart)).

3. **`add_outbounds` — список-как-флаги.** Читается только как три булевых
   (`∋ direct-out?` / `∋ ✨auto?` / `∋ block?`), а не как список тегов
   ([channel.dart:344-345](../../../app/lib/models/channel.dart)).

4. **`preset_groups` наполовину мёртв.** С §125 рантайм работает на `channels[]`
   в `lxbox_settings.json`; `Channel` заменил `PresetGroup` как source-of-truth
   ([channel.dart:3-6](../../../app/lib/models/channel.dart)). Массив читается
   **только как seed первой миграции** + fallback-синтез для тестов без storage.
   После первого запуска не читается вообще.

`title`/`type`/иконка трёх служебных нод (auto/direct/block) при этом
захардкожены отдельно, через `switch` по outbound-type в
[special_node_display.dart:23-36](../../../app/lib/screens/home/special_node_display.dart).

## Решение

Разбить плоский `preset_groups` на **реестр служебных нод** + **два шаблона
сборки** + **список сида**:

```jsonc
"group_templates": {
  // Реестр служебных нод. Ключ = role (auto/direct/block) — стабильный id, по
  // нему навешивается Dart-поведение (иконка + связь с kAuto/Direct/BlockOutboundTag).
  "magic_nodes": {
    // generate: билдер синтезирует ноду per-channel. Статического tag нет —
    // тег собирается по tpl из tag родительского канала.
    "auto":   { "title": "Auto",   "source": "generate", "tpl": "{parent_tag}-auto" },
    // preset: готовый объект уже лежит в config.outbounds; tag — ссылка на него.
    "direct": { "title": "Direct", "source": "preset",   "tag": "direct-out" },
    "block":  { "title": "Block",  "source": "preset",   "tag": "block" }
  },

  // Шаблон обычного канала (selector) — из чего собирается каждый vpn-N.
  "channel": {
    "type": "selector",
    "include": ["direct", "auto"],   // ссылки на magic_nodes по role-ключу.
                                     // block НЕ включён по умолчанию (= текущее
                                     // includeBlock=false); он зарегистрирован в
                                     // magic_nodes как роль (fallback-билдера +
                                     // special_node_display + будущий тумблер),
                                     // но в selector канала не кладётся.
    "options": { "interrupt_exist_connections": true }
  },

  // Шаблон auto-подгруппы (urltest) — параметры генерации generate-ноды.
  "auto": {
    "type": "urltest",
    "options": {
      "url":       "@urltest_url",
      "interval":  "@urltest_interval",
      "tolerance": "@urltest_tolerance",
      "interrupt_exist_connections": true
    }
  }
},

"default_channels": [
  { "tag": "vpn-1", "label": "VPN ①", "default_enabled": true  },
  { "tag": "vpn-2", "label": "VPN ②", "default_enabled": false }
]
```

Что уходит: запись `@auto_proxy_tag`, переменная `auto_proxy_tag` из
`sections.General.vars`, спец-проход пре-резолва в `template_loader`, скип-костыль
`if (tag == kAutoOutboundTag) continue` (auto больше не «канал со скипом»).

### `magic_nodes` — семантика полей

| поле | у кого | смысл |
|---|---|---|
| `title` | все | как показывается юзеру (`Auto`/`Direct`/`Block`). Читает `special_node_display`. |
| `source` | все | `generate` — синтезируется билдером; `preset` — готовый объект в `config.outbounds`. |
| `tag` | только `preset` | ссылка на существующий outbound. У `generate` нет — тег из `tpl`. |
| `tpl` | только `generate` | шаблон тега синтезируемой ноды. `{parent_tag}` → tag родительского канала. Формализует нынешний `Channel.autoTag => '$tag-auto'` ([channel.dart:258](../../../app/lib/models/channel.dart)). |

**Иконка НЕ в шаблоне.** `IconData` — Flutter-константа, не сериализуется; при
`--tree-shake-icons` иконка, вызванная только через строку-резолвер, выпадает из
шрифта. Три вечных ноды не стоят резолвера+whitelist. Иконка остаётся в
`special_node_display`, но ветвится по **role-ключу** (`auto`/`direct`/`block`),
а не по outbound-type. Граница «строки/данные → шаблон, IconData → код» — та же,
что [consts.dart:3-6](../../../app/lib/config/consts.dart) проводит для тегов.

### Что маппится на существующий код 1:1

| новое поле шаблона | нынешний код |
|---|---|
| `magic_nodes.auto.source: "generate"` | синтез urltest в [build_config.dart:631-663](../../../app/lib/services/builder/build_config.dart) |
| `magic_nodes.auto.tpl: "{parent_tag}-auto"` | `Channel.autoTag => '$tag-auto'` ([channel.dart:258](../../../app/lib/models/channel.dart)) — **разделитель дефис** |
| `magic_nodes.{direct,block}.source: "preset"` | `config.outbounds` → `{type:direct,tag:direct-out}`, `{type:block,tag:block}` |
| `magic_nodes.*.tag` | `kAuto/Direct/BlockOutboundTag` ([consts.dart](../../../app/lib/config/consts.dart)) |
| `magic_nodes.*.title` | `switch` в [special_node_display.dart:23-36](../../../app/lib/screens/home/special_node_display.dart) |
| `channel.include ∋ "direct"` | `add_outbounds ∋ "direct-out"` → `Channel.includeDirect` |
| `channel.include ∋ "auto"` | `add_outbounds ∋ "✨auto"` → есть auto-подгруппа |
| `channel.options.interrupt_exist_connections` | `Channel.interruptExistConnections` |
| `auto.options.{url,interval,tolerance}` | `ChannelAuto` seed ([channels.dart:210-234](../../../app/lib/services/settings_storage/channels.dart)) |
| `default_channels[i].{tag,label,default_enabled}` | `Channel.{tag,label,enabled}` seed |

### Границы (что НЕ делаем)

- **const-зеркала тегов остаются `const`, но становятся проверяемыми.**
  `kAuto/Direct/BlockOutboundTag` в [consts.dart](../../../app/lib/config/consts.dart)
  остаются compile-time константами (нужны case-меткам, const-спискам, тестам —
  runtime-значение из `magic_nodes` туда не подставить). Но их синхронность с
  шаблоном больше не «на честном слове»: `magic_nodes` = source of truth, const =
  зеркало, а **runtime-инвариант на загрузке** ловит расхождение (см. ниже
  «Source of truth + инвариант»). Делать `kAutoOutboundTag` **не-const** (читать
  из шаблона в рантайме) — вне scope: ломает case-метки/const-контексты, выгоды
  ноль (значение всё равно фиксировано).
- **Все каналы одинаковы** (как сейчас). `default_channels[i]` = только
  `tag`/`label`/`default_enabled`; структура сборки — общий `channel`-шаблон.
  Per-channel override шаблона — вне scope (новая гибкость, не запрошена).
- **Обратное чтение `preset_groups` не сохраняем.** Ключ мёртв после первого
  запуска; у существующих юзеров `channels[]` давно засеян и этот массив не
  читается. Переименование затрагивает только чистую установку + тесты + доки.
  Риск data-loss нулевой.

## Source of truth + инвариант (переименование в шаблоне «просто работает»)

Цель: переименовал tag в `magic_nodes` (напр. `block` → `drop`) — приложение
подхватывает автоматически, а промах ловится немедленно, не молча ломает роутинг.

Сегодня этого нет ни для кого: тег `block`/`direct-out`/`✨auto` пишется голым
литералом в ~15 местах мимо констант, а сами `k*OutboundTag` — ручные зеркала
без сторожа. Переименование = ручная правка в десятке файлов.

Делаем три вещи:

1. **`magic_nodes.*.tag` — единственный источник истины в шаблоне.**
2. **Голые литералы-теги → `k*OutboundTag`** (только там, где это реально
   outbound-**tag**, см. классификацию).
3. **Runtime-инвариант на `TemplateLoader.load()`** — сверяет const-зеркала
   против шаблона и **бросает** при расхождении:

```dart
// В TemplateLoader.load(), после parse group_templates.
void _assertMagicNodeMirrors(GroupTemplates gt) {
  final direct = gt.magicNodes['direct']?.tag;
  final block  = gt.magicNodes['block']?.tag;
  final autoTpl = gt.magicNodes['auto']?.tpl; // '{parent_tag}-auto'
  if (direct != kDirectOutboundTag || block != kBlockOutboundTag) {
    throw StateError('magic_nodes tag ≠ consts.dart mirror — update consts.dart');
  }
  // auto: kAutoOutboundTag — имя-заготовка; tpl задаёт per-channel tag.
  // Инвариант tpl проверяется в тесте (resolveTpl('{parent_tag}-auto','vpn-1')).
}
```

Битый bundled-шаблон = баг разработчика → бросаем на load (тот же принцип, что
`validateIfConstructs` в [template_loader.dart:37](../../../app/lib/services/template_loader.dart)).
После этого переименование в шаблоне без апдейта consts.dart роняет приложение
на старте с ясной ошибкой, а не тихо ломает маршрутизацию.

### Классификация ~42 литералов — что мигрирует, а что НЕ трогать

Слепая замена всех `'block'`/`'direct-out'` на const — **баг**: половина совпадений
это outbound-**type** или UI-**label**, случайно совпавшие строкой с тегом. Мигрирует
только категория A (реальный tag).

**A. Реальный outbound-tag → заменить на `k*OutboundTag` (~15):**
- [custom_rule.dart:466,679,1011](../../../app/lib/models/custom_rule.dart) — дефолт `outbound='direct-out'`
- [build_config.dart:372,463,577,580,593,615](../../../app/lib/services/builder/build_config.dart) — тег в selector/route/taken-set
- [probe_config.dart:35,40](../../../app/lib/services/probe/probe_config.dart), [preset_expand.dart:511](../../../app/lib/services/builder/preset_expand.dart), [rules.dart:233](../../../app/lib/services/debug/handlers/rules.dart), [edit_controller.dart:125,243](../../../app/lib/screens/dns_server_edit/edit_controller.dart), [routing_screen.dart:816](../../../app/lib/screens/routing_screen.dart), [routing_screen_helpers.dart:57(tag),139,151](../../../app/lib/screens/routing_screen/routing_screen_helpers.dart)
- ([channel.dart:344,345](../../../app/lib/models/channel.dart) — уходят целиком: переписываются под `channel.include`)

**B. `type == 'block'` — это outbound-TYPE, НЕ тег → НЕ трогать (~6):**
[home_state.dart:219,225](../../../app/lib/models/home_state.dart),
[ping_orchestration.dart:25,220](../../../app/lib/controllers/home_controller/ping_orchestration.dart),
[node_row.dart:193](../../../app/lib/widgets/node_row.dart),
[special_node_display.dart:31(case)](../../../app/lib/screens/home/special_node_display.dart).
Здесь `'block'` = тип sing-box outbound'а. Замена на `kBlockOutboundTag`
семантически неверна (переименуешь tag → сломаешь проверку типа, к тегу
отношения не имеющую). Это разные оси: sing-box outbound-`type` (что за нода) vs
`magic_nodes.source` (как рождается) vs `tag` (идентификатор). В этих местах нужен
именно outbound-`type` — `magic_nodes` их разводит по именам (`source`≠`type`).

**C. UI-label `'direct'`/`'block'` (подпись, не тег) → НЕ трогать label (~5):**
[dns_settings_screen.dart:147](../../../app/lib/screens/dns_settings_screen.dart),
[routing_screen_helpers.dart:47,57(label)](../../../app/lib/screens/routing_screen/routing_screen_helpers.dart),
[outbound_picker.dart:8,9(коммент)](../../../app/lib/widgets/outbound_picker.dart).
Рядом стоящий `tag:` — категория A (заменить); `label:` остаётся строкой.

**D. enum допустимых типов / служебные строки → НЕ трогать (~3):**
[config_node.dart:159](../../../app/lib/models/config_node.dart) (список валидных
sing-box типов), [diag.dart:110](../../../app/lib/services/debug/handlers/diag.dart),
[help.dart:381](../../../app/lib/services/debug/handlers/help.dart) (bash в help-строке).

## Модель данных (Dart)

`PresetGroup` ([parser_config.dart:113-145](../../../app/lib/models/parser_config.dart))
заменяется на структуры под новую схему. Предлагаемая форма:

```dart
/// Реестр служебных нод из `group_templates.magic_nodes`. Ключ = role.
class MagicNode {
  final String role;   // 'auto' | 'direct' | 'block' (ключ)
  final String title;  // human label для UI
  final String source; // 'generate' | 'preset' (НЕ sing-box outbound-type)
  final String? tag;    // preset: ссылка на config.outbounds; generate: null
  final String? tpl;    // generate: шаблон тега ('{parent_tag}-auto'); preset: null
}

/// Шаблон обычного канала из `group_templates.channel`.
class ChannelTemplate {
  final String type;              // 'selector'
  final List<String> include;     // role-ключи magic_nodes ('direct','auto')
  final Map<String, dynamic> options;
}

/// Шаблон auto-подгруппы из `group_templates.auto`.
class AutoTemplate {
  final Map<String, dynamic> options; // url/interval/tolerance (@var, сырые)
}

/// Один канал для сида из `default_channels[i]`.
class DefaultChannel {
  final String tag;
  final String label;
  final bool defaultEnabled;
}

/// Верхнеуровневый блок.
class GroupTemplates {
  final Map<String, MagicNode> magicNodes; // role → node
  final ChannelTemplate channel;
  final AutoTemplate auto;
  final List<DefaultChannel> defaultChannels;
}
```

`WizardTemplate` теряет `presetGroups`, получает `groupTemplates` +
`defaultChannels`.

`tpl` резолвится хелпером (заменяет `Channel.autoTag`-геттер на использование
шаблона):

```dart
String resolveTpl(String tpl, String parentTag) =>
    tpl.replaceAll('{parent_tag}', parentTag);
```

`Channel.autoTag` остаётся геттером, но его формула сверяется с
`magic_nodes.auto.tpl` (не расходиться: тест на равенство).

## Файлы

| Файл | Изменение |
|---|---|
| `app/assets/wizard_template.json` | `preset_groups` → `group_templates` + `default_channels`; удалить var `auto_proxy_tag` из `sections.General.vars` |
| `app/lib/models/parser_config.dart` | `PresetGroup` → `MagicNode`/`ChannelTemplate`/`AutoTemplate`/`DefaultChannel`/`GroupTemplates`; `WizardTemplate.fromJson` парсит новую схему; убрать парс `preset_groups` |
| `app/lib/models/channel.dart` | `seedFromPreset(PresetGroup)` → seed из `DefaultChannel` + `ChannelTemplate` + `AutoTemplate`; `autoTag`-формула сверяется с `tpl` |
| `app/lib/services/settings_storage/channels.dart` | `_migrateChannelsIfNeeded`/`_seedAutoFromTemplate` под новую схему; убрать `if (tag == kAutoOutboundTag) continue` (auto больше не в списке каналов) |
| `app/lib/services/builder/build_config.dart` | `_channelsFromTemplate` fallback под новую схему; убрать скип-костыль |
| `app/lib/services/template_loader.dart` | удалить спец-проход `_substituteInPlace(preset_groups)` + коммент про `@auto_proxy_tag`; **добавить `_assertMagicNodeMirrors` (инвариант, Вариант 2)** |
| `app/lib/screens/home/special_node_display.dart` | `title` читать из `magic_nodes`; иконку ветвить по role. Вызов идёт по outbound-`type` ([node_row.dart:189,366](../../../app/lib/widgets/node_row.dart)) → мапить type→role (`urltest`→auto, `direct`→direct, `block`→block) |
| `app/lib/config/consts.dart` | коммент-указатель source-of-truth: var `auto_proxy_tag` → `group_templates.magic_nodes.*.tag`; отметить, что синхронность стережёт `_assertMagicNodeMirrors` |
| `app/scripts/format_wizard_template.py` | форматтер [285-299](../../../app/scripts/format_wizard_template.py) переписать: `preset_groups`-блок → `group_templates` + `default_channels` |
| **(Вариант 2) миграция литералов категории A → `k*OutboundTag`** | `custom_rule.dart`, `build_config.dart`, `probe_config.dart`, `preset_expand.dart`, `debug/handlers/rules.dart`, `dns_server_edit/edit_controller.dart`, `routing_screen.dart`, `routing_screen/routing_screen_helpers.dart` (только `tag`-позиции; см. классификацию) |
| `docs/TEMPLATE.md` | секцию `preset_groups` (строки ~68, ~350-374, ~762) переписать под `group_templates`/`magic_nodes`/`default_channels`; убрать `@auto_proxy_tag` из примеров |
| `docs/spec/features/125 configurable-channels/spec.md` | update: source-of-truth сида = `default_channels`, служебные ноды = `magic_nodes` |

## Тесты

- `test/models/` — парсинг `group_templates`/`magic_nodes`/`default_channels`;
  `generate`-нода без `tag`, `preset`-нода без `tpl`.
- `test/migration/` — first-run seed из `default_channels`: `vpn-1` enabled форс,
  `vpn-2` по `default_enabled`; auto-подгруппа заведена когда `channel.include ∋ auto`.
- `test/builder/` — fallback-синтез `_channelsFromTemplate` эквивалентен старому
  (same `channels[]` на выходе); `autoTag` канала == `resolveTpl(tpl, channel.tag)`.
- `special_node_display` — `title` для трёх ролей приходит из `magic_nodes`;
  иконка по role корректна; type→role мапинг (`urltest`→auto).
- **(Вариант 2) инвариант зеркал** — `_assertMagicNodeMirrors` бросает, если
  `magic_nodes.direct.tag != kDirectOutboundTag` (и block); негативный тест на
  подмену tag в fixture-шаблоне → ожидаем `StateError` на load.
- **(Вариант 2) миграция литералов** — существующие builder/routing/probe-тесты
  остаются зелёными после замены категории A (эквивалентность выхода: тег не
  изменился, только источник строки). Не должно быть diff в собранном конфиге.
- `resolveTpl('{parent_tag}-auto','vpn-1') == 'vpn-1-auto'`; `autoTag`-геттер ==
  `resolveTpl(magic_nodes.auto.tpl, tag)`.

## Риски

- **Форматтер хрупкий** — `format_wizard_template.py` хардкодит ключи
  (`for k in ("tag","type","label","default_enabled")`). Забыть его = кривой
  ассет при следующем прогоне. Переписать в этом же проходе.
- **Разделитель `tpl`.** Реально `'$tag-auto'` (дефис,
  [channel.dart:258](../../../app/lib/models/channel.dart)). Подчёркивание сломает
  матч auto-двойников в фильтрах/сортировке. `{parent_tag}-auto` — дефис, тест на
  `vpn-1-auto`.
- **UI-строки английские** — `title` в `magic_nodes` (`Auto`/`Direct`/`Block`)
  видны юзеру → только английский (правило проекта).
