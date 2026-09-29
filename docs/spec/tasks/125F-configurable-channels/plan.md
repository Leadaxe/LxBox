# §125 — План реализации (configurable-channels)

> Переход из [`spec.md`](spec.md) (DRAFT, open questions закрыты 27.06.2026) в
> исполнимый план. Все file_path:line проверены по коду на 27.06.2026 (ветка
> `feat/configurable-channels-125`). Числа строк могут дрейфовать при правках —
> сверять перед каждой фазой.

## Принцип фазовки

Спека рекомендует **F0 → F1 → F4 → F2 → F3** (regex-фильтр последним — самый
рискованный для билдера, проще верифицировать когда CRUD уже даёт каналы).

Ключевая страховка: **до F1 билдер продолжает читать `template.presetGroups`**.
F0 добавляет модель+storage+миграцию параллельно, ничего не ломая в рантайме.
Переключение билдера на `channels[]` — только в F1. Это значит F0 можно
смержить и device-проверить (Debug API) изолированно, без риска для конфига.

Каждая фаза = отдельный коммит (атомарно, по [feedback_commit_push_immediately]).
Device-тест после F0 (storage через Debug API), после F1 (виден результат в
конфиге), далее по готовности.

---

## F0 — Модель + storage + миграция + API

**Цель:** `Channel`/`ChannelAuto` модели, `channels[]` в storage, миграция из
`enabled_groups[]`, CRUD-API. Билдер НЕ трогаем — он пока на template.

### F0.1 — Модель `Channel` / `ChannelAuto`

**Новый файл:** `app/lib/models/channel.dart`

Не storage-part (как `Channel` в отчёте предлагал), а отдельная модель в
`models/` — по образцу `parser_config.dart` (`PresetGroup`) и `custom_rule.dart`.
Storage-part только сериализует. Контракт из spec.md §«Модель данных»:

```dart
class Channel {
  final String tag;          // 'vpn-1'..'vpn-10' — системный immutable id
  final String label;
  final bool enabled;
  final bool includeDirect;
  final String nodeFilter;        // regex по итоговому tag (§048-style)
  final String defaultFilter;     // regex; первая matched → default
  final bool interruptExistConnections;
  final ChannelAuto? auto;        // null = галка auto ВЫКЛ

  String get autoTag => '$tag-auto';   // производный, в storage НЕ хранится

  const Channel({...});
  Channel copyWith({...});             // для редактора (immutable edit)
  factory Channel.fromJson(Map<String, dynamic>);
  Map<String, dynamic> toJson();
}

class ChannelAuto {
  final String url;
  final String interval;       // duration "5m"
  final int tolerance;         // ms, uint16 (§161 — clamp 0..65535)
  final String idleTimeout;    // duration "30m"
  final bool interruptExistConnections;

  const ChannelAuto({...});
  ChannelAuto copyWith({...});
  factory ChannelAuto.fromJson(Map<String, dynamic>);
  Map<String, dynamic> toJson();
}
```

Дефолты `fromJson` (для forward-compat и кривого импорта):
`enabled=true`, `includeDirect=false`, `nodeFilter=''`, `defaultFilter=''`,
`interruptExistConnections=true`, `auto=null`. `ChannelAuto`:
`interval='5m'`, `tolerance` clamp `0..65535` (§161 — вне диапазона роняет ядро),
`idleTimeout='30m'`, `interruptExistConnections=false`.

Тесты: `app/test/models/channel_test.dart` — round-trip fromJson/toJson,
дефолты, tolerance-clamp, autoTag-производный, auto=null↔object.

### F0.2 — Storage-part `channels.dart`

**Новый файл:** `app/lib/services/settings_storage/channels.dart`
**Подключить** в `settings_storage.dart` строкой `part`:
- импорт модели: `app/lib/services/settings_storage.dart` уже импортит модели
  через основной файл — добавить `import '../models/channel.dart';`.
- `part 'settings_storage/channels.dart';` рядом с прочими (после `sources_rules`).

Top-level приватные функции (по эталону `network.dart:98 _setGroupPing` — read
весь объект → mutate copy → rewrite atomically через `_save`):

```dart
part of '../settings_storage.dart';

Future<List<Channel>> _getChannels() async {
  final data = await _load();
  final raw = data['channels'] as List<dynamic>? ?? const [];
  return raw.whereType<Map<String, dynamic>>().map(Channel.fromJson).toList();
}

Future<void> _setChannels(List<Channel> channels, {bool flush = true}) async {
  final data = await _load();
  data['channels'] = channels.map((c) => c.toJson()).toList();
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty();   // §113 — config-significant
  if (flush) await _save();
}

Future<Channel> _addChannel({String? label}) async {   // throws при 10
  final channels = (await _getChannels()).toList();
  if (channels.length >= 10) throw StateError('channel limit (10) reached');
  final used = channels.map((c) => c.tag).toSet();
  final tag = [for (var i = 2; i <= 10; i++) 'vpn-$i']
      .firstWhere((t) => !used.contains(t));   // N∈2..10; vpn-1 всегда есть
  final ch = Channel(tag: tag, label: label ?? tag, enabled: true,
      includeDirect: false, nodeFilter: '', defaultFilter: '',
      interruptExistConnections: true, auto: null);
  channels.add(ch);
  await _setChannels(channels);
  return ch;
}

Future<void> _updateChannel(Channel channel) async {
  final channels = (await _getChannels()).toList();
  final i = channels.indexWhere((c) => c.tag == channel.tag);
  if (i < 0) throw StateError('channel not found: ${channel.tag}');
  channels[i] = channel;
  await _setChannels(channels);
}

Future<void> _deleteChannel(String tag) async {       // throws для vpn-1
  if (tag == 'vpn-1') throw StateError('vpn-1 is not deletable');
  final channels = (await _getChannels()).toList()
    ..removeWhere((c) => c.tag == tag);
  await _setChannels(channels, flush: false);    // один flush в конце
  await _healChannelRefs(tag);                   // route_final + custom-rules → vpn-1
}
```

`_healChannelRefs(deletedTag)` — немедленная правка storage для UI-консистентности
(билдер тоже схлопывает dangling, но UI должен видеть результат сразу):
- `route_final == deletedTag` → `saveRouteFinal('vpn-1', flush:false)`.
- custom-rules `outbound == deletedTag` (кроме reject/direct-out) → `'vpn-1'`,
  `saveCustomRules(..., flush:false)`.
- финальный `_save()`.
- Home-pin/detour — нормализуются билдером (см. F4), в storage напрямую не лежат
  как отдельный ключ (detour внутри custom-rule/template).

**Публичные обёртки** в `SettingsStorage` (рядом с getEnabledGroups,
`settings_storage.dart`):
```dart
static Future<List<Channel>> getChannels() => _getChannels();
static Future<void> setChannels(List<Channel> c, {bool flush = true}) => _setChannels(c, flush: flush);
static Future<Channel> addChannel({String? label}) => _addChannel(label: label);
static Future<void> updateChannel(Channel c) => _updateChannel(c);
static Future<void> deleteChannel(String tag) => _deleteChannel(tag);
```

**Allowlist:** добавить `'channels'` и `'channels_migrated'` в
`allowedTopLevelKeys` (`settings_storage.dart:105`). `'enabled_groups'`
**оставить** (legacy backward-compat, §159 default-deny не должен его дропать
до полного отказа).

### F0.3 — Миграция `enabled_groups[]` → `channels[]`

One-shot, guard-ключ `channels_migrated` (по эталону `_hasDefaultsSeeded` /
`_markDefaultsSeeded`, `sources_rules.dart:136`).

Где вызвать: lazy в `_getChannels()` — если `channels` отсутствует И не
`channels_migrated`, seed из template. Template доступен? `_getChannels` storage-
слой не знает про template. **Решение:** миграция принимает `List<PresetGroup>`
параметром — `migrateChannelsIfNeeded(template.presetGroups)`, вызывается из
`main()` init рядом с `bootstrapAndSyncNativePrefs` (§189-паттерн), ДО первого
билда. Не lazy в getter (нет template в storage-слое).

```dart
Future<void> _migrateChannelsIfNeeded(List<PresetGroup> presets) async {
  final data = await _load();
  if (data['channels'] is List) return;          // уже есть
  if (data['channels_migrated'] == true) return; // мигрировано, но пусто — не пересеивать
  final enabled = await SettingsStorage.getEnabledGroups();  // legacy set
  final channels = <Channel>[];
  for (final p in presets) {
    if (p.tag == kAutoOutboundTag) continue;     // глобальный ✨auto НЕ канал
    final isEnabled = p.tag == 'vpn-1'
        ? true
        : (enabled.isEmpty ? p.defaultEnabled : enabled.contains(p.tag));
    final includeDirect = p.addOutbounds.contains('direct-out');
    final hasAuto = p.addOutbounds.contains(kAutoOutboundTag);
    channels.add(Channel(
      tag: p.tag, label: p.label.isEmpty ? p.tag : p.label,
      enabled: isEnabled, includeDirect: includeDirect,
      nodeFilter: '', defaultFilter: '',                  // Решение 6 — пусто
      interruptExistConnections:
          p.options['interrupt_exist_connections'] as bool? ?? true,
      auto: hasAuto ? _seedAutoFromTemplate(p) : null,
    ));
  }
  data['channels'] = channels.map((c) => c.toJson()).toList();
  data['channels_migrated'] = true;
  SettingsStorage._cache = data;
  await _save();
}
```

`_seedAutoFromTemplate(p)` — `ChannelAuto` из `@urltest_*` vars (url/interval/
tolerance), `idleTimeout='30m'`, `interruptExistConnections=false`. Источник
значений — глобальный `✨auto` preset_group options. Если их нет — разумные
дефолты (`url=cp.cloudflare.com/generate_204`, `interval='5m'`, `tolerance=50`).

**Решение 6:** `default_filter=''` для всех (старый `options.default` — фикс. tag,
не regex; не мигрируем). Юзер задаёт regex заново.

Тест: `app/test/migration/channels_migration_test.dart` — seed из template с
vpn-1..vpn-4 + ✨auto; проверить vpn-1 forced-enabled, ✨auto не попал в channels,
direct/auto из add_outbounds, идемпотентность (повторный вызов = no-op).

### F0.4 — Backup-симметрия

`channels[]` едет внутри `storage`-блока backup (это top-level ключ
`lxbox_settings.json`, экспортится через `exportRaw`/`replaceRaw`) —
**отдельной обработки не нужно**, в отличие от native_prefs (§189). Проверить:
`backup.dart:_export` берёт `SettingsStorage.exportRaw()` → channels внутри.
Достаточно allowlist-записи (F0.2). Подтвердить device-тестом.

### F0 — Verification
Debug API (`/storage` GET/PUT через `debug/handlers/settings.dart`):
- свежий старт → `channels[]` с vpn-1..vpn-4 (миграция), vpn-1 enabled+неудаляем.
- PUT канал → читается обратно.
- import backup с channels → применяется.
Скрипт `/tmp/lxbox_verify_125_f0.sh` (по образцу §189-верификации).

---

## F1 — Билдер на channels + title + галки (direct/auto/interrupt)

**Цель:** билдер читает `channels[]` вместо `template.presetGroups`. Членство
direct/auto/interrupt — из галок канала. Эмит auto-двойника. **Без regex-фильтра**
(node-set пока общий — F2). Это переключает source-of-truth.

### F1.1 — `_buildPresetGroups` → `_buildChannelGroups`

`build_config.dart:412-482`. Сигнатура меняется:
```dart
// было: presets: List<PresetGroup>, enabledGroupTags: Set<String>
// стало: channels: List<Channel>
List<Map<String, dynamic>> _buildChannelGroups({
  required List<Channel> channels,
  required List<String> selectorTags,    // F1: ещё общий набор
  required Set<String> excludedNodes,
  required VarResolver resolve,
}) { ... }
```

Логика F1 (node-set ещё общий `selectorTags`, regex в F2):
- активные = `channels.where((c) => c.enabled)` (vpn-1 enabled инвариантом модели —
  снимает хардкод `build_config.dart:421`).
- для каждого `C`: `nodesC = selectorTags` (F1 — общий; F2 заменит на regex-фильтр).
- selector `C.tag`: `outbounds = [...nodesC, if(C.includeDirect)'direct-out',
  if(C.auto!=null)C.autoTag]`; `interrupt_exist_connections = C.interruptExistConnections`.
- пустой `nodesC` → fallback `direct-out` (как `build_config.dart:458`).
- если `C.auto != null` И `nodesC` непуст → эмит urltest `C.autoTag`:
  `outbounds = nodesC` (БЕЗ direct/auto), url/interval/tolerance/idle_timeout/
  interrupt из `C.auto`. Пустой `nodesC` → двойник НЕ эмитим, selector не получает
  `C.autoTag` опцией.
- `default` — F1: не выставляем (`defaultFilter` пуст после миграции; F3 включит).
  §141-гейт (`build_config.dart:466`) остаётся как защита.

**Вызов сверху** (`build_config.dart:190`): `template.presetGroups` →
`settings.channels` (новый getter в settings-снимке билдера, см. F1.2).

### F1.2 — Проброс channels в билдер
Билдер получает settings-снимок. Найти где собирается `settings.enabledGroups`
(`build_config.dart:191`) и добавить `channels: await SettingsStorage.getChannels()`
рядом. Точное место — структура `BuildSettings`/аргументов `buildConfig`
(проверить при реализации; `enabledGroups` там же).

`kAutoOutboundTag`-ветка (`build_config.dart:426-427 autoProxyEnabled`,
`tagsFor urltest`) — удаляется: глобального ✨auto больше нет, каждый канал
делает свой двойник.

### F1 — Verification
- device: rebuild config, проверить outbounds — selector каналы с правильным
  direct/auto членством, urltest-двойники `<tag>-auto` присутствуют для каналов
  с auto, отсутствуют без.
- регресс: туннель поднимается, переключение каналов работает.

---

## F4 — CRUD + UX-редактор + снятие хардкодов

**Цель:** Add/Delete каналов, `ChannelEditScreen`, кнопка Add в табе Channels,
снятие хардкодов набора каналов. Regex-поля в UI присутствуют, но билдер их пока
игнорирует (F2). Home-dropdown label-fix.

### F4.1 — `ChannelEditScreen`
**Новый файл:** `app/lib/screens/channel_edit_screen.dart` по эталону
`custom_rule_edit_screen.dart:34-456`:
- StatefulWidget + controller-pattern (initState/dispose).
- `openChannelEditor(context, {required Channel initial, required bool canDelete})`
  → `Navigator.push<ChannelEditResult>` (saved/deleted wrapper).
- `PopScope(canPop:false)` + `_handleBack` диалог Save/Keep/Discard
  (`custom_rule_edit_screen.dart:150-197`).
- AppBar: title `Edit channel · <tag>`, actions `[delete (если canDelete), save]`,
  `_SaveIconButton` dirty-highlight (`custom_rule_edit_screen.dart:392`).
- Поля (spec.md §ChannelEditScreen): tag read-only, label TextField,
  includeDirect+interrupt CheckboxListTile, nodeFilter regex-поле (live-превью
  count — по `RegexFilterField` `home/filter_widgets.dart:47`), defaultFilter
  regex-поле, auto-секция (CheckboxListTile + раскрывающиеся поля по
  `dns_section.dart:57` spread-паттерну: url/interval/tolerance/idle/interrupt).
- delete: confirm-диалог → `Navigator.pop(deleted)`. save: собрать `Channel`
  через `copyWith`, `Navigator.pop(saved)`.
- Live-превью regex использует снимок нод от ядра (`CcGroup.items` /
  `home_state.nodes`) — count матчей `nodeFilter` + первая matched для defaultFilter.

### F4.2 — Таб Channels: тап→редактор + Add
`routing_screen.dart:206 _buildGroupTile` + `routing_group_tile.dart`:
- источник тайлов: `template.presetGroups` → `SettingsStorage.getChannels()`.
- тогл слева (как сейчас), тап по телу → `openChannelEditor` → save/delete
  применить через `updateChannel`/`deleteChannel`.
- кнопка `＋ Add channel (N/10)` внизу (disabled при 10) → `addChannel` →
  сразу открыть редактор. По образцу Rules-таба Add (`routing_tabs.dart`).
- subtitle: count нод после фильтра + наличие auto (spec.md mock).

### F4.3 — Снятие хардкодов
| Место | Правка |
|---|---|
| `build_config.dart:421` | удалено в F1 (vpn-1 enabled инвариантом) |
| `node_filter_screen.dart:104` | `groupTags` строить из `channels[].tag` + autoTag + system (direct-out) динамически |
| `routing_srs_cache.dart:40,42` | required vpn-1 из channels; `_routeFinal` fallback vpn-1 (остаётся — продуктовый инвариант) |
| `routing_group_tile.dart:26` | `isRequired = tag=='vpn-1'` — ОСТАВИТЬ (vpn-1 неудаляем, продуктовое) |
| `dns_settings_screen.dart:144` | `activeGroupTags` из `getChannels().where(enabled)` вместо template+enabled_groups |

### F4.4 — Home-dropdown label-fix
`home_controls.dart:136` — `DropdownMenuItem(value:g, child:Text(g))` показывает
tag. Нужно `Text(label)`. `state.groups` остаётся `List<String>` (tag — для API),
добавить `state.groupLabels: Map<String,String>` (tag→label) в `HomeState`,
заполнять из `getChannels()` при загрузке. Dropdown: `Text(groupLabels[g] ?? g)`.

### F4.5 — Деградация dangling-ссылок в билдере (§172-паттерн)
Одна точка нормализации в билдере перед сборкой: резолвит валидные channel-tag'и,
схлопывает route_final/custom-rule outbound/detour на несуществующий канал → vpn-1.
Переиспользует `healDanglingDetours` (`post_steps/heal_dangling_detours.dart:18`)
для detour; для route_final/custom-rule — отдельная нормализация по аналогии.
`✨auto`-ссылки попадают под то же правило автоматически (Решение 3).

### F4 — Verification
- Add → новый vpn-N, редактор открыт. Delete → канал ушёл, route_final на него
  → vpn-1. Лимит 10 (Add disabled). vpn-1 без delete-кнопки. Home-dropdown
  показывает label. DNS-dropdown/node-filter видят актуальный набор каналов.

---

## F2 — Regex node-filter (per-channel node-set) ⚠ ВЫСОКИЙ РИСК

**Цель:** снять «общий набор нод на все selector». Каждый канал фильтрует
`selectorTags` по своей `nodeFilter` (regex по итоговому tag, §048-style).

`build_config.dart` `_buildChannelGroups`:
```dart
List<String> nodesFor(Channel c) {
  if (c.nodeFilter.isEmpty) return selectorTags;       // все ноды
  final re = _tryCompile(c.nodeFilter);
  if (re == null) return selectorTags;                  // невалидно → все (spec.md)
  return selectorTags.where((t) => re.hasMatch(t)).toList();
}
```
- regex по **финальному tag как есть** (member-tag), один-в-один §048
  (`n.tag.contains` → здесь `RegExp.hasMatch`; эмодзи-флаги/префиксы — часть tag).
- невалидная/пустая regex → все ноды (текущее поведение).
- auto-двойник: `outbounds = nodesFor(c)` (тот же фильтр, без direct/auto).
- live-превью в редакторе (F4.1) уже считает по этой же логике — вынести
  `channelNodeMatches(filter, tags)` в общий helper (билдер + редактор).

Тест: `build_config` фильтрует per-channel; пустой/невалидный → все;
два канала с разными regex → разные наборы.

### F2 — Verification
device: канал с `nodeFilter='🇩🇪'` → только DE-ноды в группе; пустой → все;
битый regex → все (не падает).

---

## F3 — Default-regex

**Цель:** `options.default` = первая нода `nodesC`, чей tag матчит `defaultFilter`.

`build_config.dart` после сбора `nodesC`:
```dart
if (c.defaultFilter.isNotEmpty) {
  final re = _tryCompile(c.defaultFilter);
  final def = re == null ? null : nodesC.firstWhereOrNull(re.hasMatch);
  if (def != null) selectorMap['default'] = def;   // §141-гейт остаётся защитой
}
```
- не матчит/пусто → default не выставляется (sing-box берёт первую опцию).
- только для selector (у urltest нет `default`).
- live-превью в редакторе: показать какая нода выбрана.

### F3 — Verification
device: `defaultFilter='Premium'` → default = первая Premium-нода; не матчит →
нет default; превью в редакторе совпадает с конфигом.

---

## Docs (при релизе — deferred)
- `STORAGE.md` — ключ `channels[]`, депрекейт `enabled_groups`.
- `TEMPLATE.md` — `preset_groups[]` = seed, не source-of-truth.
- `ARCHITECTURE.md` — data-flow билдера по нодам (F2 меняет «общий набор»).
- `CHANGELOG.md` — user-visible.

## Реестр новых/изменённых файлов

| Файл | Фаза | Действие |
|---|---|---|
| `app/lib/models/channel.dart` | F0 | new — Channel/ChannelAuto |
| `app/lib/services/settings_storage/channels.dart` | F0 | new — storage-part |
| `app/lib/services/settings_storage.dart` | F0 | part+import+обёртки+allowlist |
| `app/test/models/channel_test.dart` | F0 | new |
| `app/test/migration/channels_migration_test.dart` | F0 | new |
| `app/lib/main.dart` (init) | F0 | вызов migrateChannelsIfNeeded |
| `app/lib/services/builder/build_config.dart` | F1/F2/F3 | _buildChannelGroups |
| `app/lib/screens/channel_edit_screen.dart` | F4 | new — редактор |
| `app/lib/screens/routing_screen.dart` + `routing_group_tile.dart` | F4 | тап→редактор+Add |
| `app/lib/screens/home/widgets/home_controls.dart` | F4 | label-fix |
| `app/lib/screens/node_filter_screen.dart` | F4 | хардкод groupTags |
| `app/lib/screens/routing_screen/routing_srs_cache.dart` | F4 | хардкод vpn-1 |
| `app/lib/screens/dns_settings_screen.dart` | F4 | хардкод vpn-1 |
| `app/lib/controllers/home_controller.dart` + `home_state` | F4 | groupLabels |
