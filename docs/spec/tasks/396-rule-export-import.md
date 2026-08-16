# §396 — экспорт/импорт правил роутинга файлом

**Статус:** СПЕКА (реализация в этой же таске)
**Тип:** обмен правилами между устройствами/пользователями. Сервис + UI, storage-схема не меняется.
**Зависит от:** §030 (Custom Rules), §370 (ось `num`), §372/§383 (импорт файла), §374 (экспорт файла), §266 (preset on_change)

---

## 0. Контекст

Правила вкладки Rules живут только в `custom_rules` storage. Поделиться настроенным
правилом (список доменов, srs-подборка, настроенный пресет) можно единственным путём —
полным бэкапом (§221), который тащит все категории сразу и работает в режиме
merge/replace целых списков. Поштучного обмена нет.

Запрос владельца: «выбираю правило — экспортирую в файл; выбираю файл — загружаю
правило к себе». Плюс: выбор **нескольких** правил в одном окне, вход через меню
**⋮ сверху на вкладке Rules** (не long-press и не вторая кнопка).

## 1. Цели

- Экспорт выбранных правил (1..N) в JSON-файл через существующий шит §374
  (Save to file / Save to Downloads / Share).
- Импорт правил из такого файла с превью-выбором (галочки) и лечением ссылок,
  которых у получателя нет.
- Вход в оба сценария — меню ⋮ в шапке вкладки Rules.

## 2. Нецели

- Deep-link-шаринг (`lxbox://`) — правило с длинными списками в URL не влезает.
- «Export all» как отдельный пункт — мультивыбор с дефолтом «все отмечены» это уже
  покрывает.
- Debug API ручки — §238 CRUD (`GET/POST /rules`) достаточно для тестов.
- Изменение формата storage / бэкапа.

## 3. Wire-format

Симметрично конверту бэкапа (`backup_service.dart`):

```json
{
  "app": "lxbox",
  "kind": "rules",
  "format": 1,
  "created_at": "2026-08-16T12:00:00.000Z",
  "source_app_version": "2.20.10+22010",
  "rules": [ { ...CustomRule.toJson()... } ]
}
```

- `kind: "rules"` — отличает от `kind: "backup"`; импорт бэкапа этот файл отвергает
  и наоборот (взаимно понятные ошибки).
- `format: 1` — версия схемы конверта. Читатель отвергает `format > 1`
  («файл из более новой версии приложения»).
- `rules[]` — сырые `toJson()` правил, включая `id`/`enabled`/`num` (санация — забота
  импорта, не экспорта).
- Имя файла: `lxbox-rules-{YYYYMMDD-HHMM}.json` (образец — `suggestedBackupFilename`).

## 4. UI

### 4.1 Вход — меню ⋮ в AppBar, видно только на табе Rules

`RulesMenuButton` (`routing_tabs.dart`) в `AppBar.actions` экрана Routing —
решение владельца после первой итерации на эмуляторе: «⋮ на самом верху,
напротив Routing» (первый вариант — в интро-строке таба — откатан). AppBar
общий на 4 таба, поэтому кнопка гейтится по активному табу:
`AnimatedBuilder` на `DefaultTabController.animation` (не `index` — чтобы
кнопка появлялась уже во время свайпа), `value.round() == 2`.

| Пункт | Условие |
|---|---|
| Export rules... | правил > 0, иначе disabled (не прячем: discoverability) |
| Import rules... | всегда |

### 4.2 Экспорт

1. **Полноэкранный** экран выбора (`MaterialPageRoute(fullscreenDialog:
   true)` — решение владельца: попап для списка правил тесен): чекбокс-список
   всех правил (display-имена через `ruleDisplayName` — live-label'ы пресетов,
   суффиксы копий §279), subtitle — `summary()`. **По умолчанию ничего не
   выбрано**; над списком тумблер Select all / Deselect all. Кнопка
   `Export (N)` внизу, disabled при пустом выборе.
2. **Второй экран «DNS»** (решение владельца, кейс правила Gemini:
   `dns.serverTag` тянет сервер, которого у получателя нет): две секции
   с чекбоксами.
   - **DNS servers** — `dns_options.servers` юзера БЕЗ `kind: preset`
     (preset-refs авто-порождаются/чистятся резолвером §294 при
     включении routing-пресета — самостоятельной ценности не несут).
     Предотмечены серверы, на которые ссылаются выбранные правила
     (`dns.serverTag`/`resolve.serverTag`) и которых нет в шаблоне
     получателя-автора (= inline'ы; шаблонные у получателя есть всегда).
   - **DNS rules** — `dns_options.rules` юзера, только `inline`/`srs`
     (preset/template — из каталога, у получателя есть). По умолчанию
     сняты.
   Кнопка Export внизу; back возвращает к выбору правил без потери
   выбора.
3. `showExportActionSheet` §374 as is (переезд файла в `lib/widgets/`, см. §7).
4. `buildRulesExport(selected, dnsServers, dnsRules)` → сохранение/шаринг
   через `file_export.dart`. Снекбары исходов — те же, что у бэкапа (§374
   таблица).

Конверт получает опциональные ключи `dns_servers[]` / `dns_rules[]` — сырые
элементы storage as is. `format` остаётся 1: фича не зарелижена, читатель
выходит тем же релизом.

### 4.3 Импорт

1. `pickFileSafely` (§372) → декод текста (`utf8_decode.dart`, как бэкап).
2. `parseRulesImport` → конверт + список правил; ошибки формата — снекбар с
   `FormatException.message`.
3. Санация каждого правила (§5) → превью-диалог: шапка `Created` /
   `App version` (как у бэкапа), чекбокс на правило (display-имя + kind + итог
   санации мелким шрифтом под названием). Неимпортируемые (§5.3) — чекбокс
   disabled + причина. По умолчанию отмечены все импортируемые.
4. Добавление выбранных: `sortRulesByNum` + `markDirty` (LazyPersistMixin — тот же
   путь, что `_addCustomRule`/`_copyPreset`); для пресетов — `applyPresetOnChange`
   (§266, q2-инвариант `resolve_enabled`).
5. Снекбар `Imported %d rules`; если среди добавленных есть требующие `.srs` —
   вариант с хвостом «tap ☁ to download, then enable» (паттерн `_copyPreset`).

## 5. Санация при импорте

Правило приезжает с ссылками на сущности автора, которых у получателя нет.
Лечим по образцу существующих механик (§202-дефолт, §370-разметка, `_copyPreset`).

### 5.1 Идентичность и порядок

| Поле | Действие |
|---|---|
| `id` | всегда новый UUID — повторный импорт того же файла не коллизирует |
| `name` | inline/srs/json → `uniqueCustomRuleName` (суффикс копии); preset → не трогаем (display-слой §279 сам даёт live-label + суффикс) |
| `num` | **из файла не берём** (чужая ось): preset → `num` из шаблона получателя (как `_copyPreset`); остальные → `nextUserRuleNum` последовательно |

### 5.2 Ссылки

Валидные outbound-теги получателя: теги всех `_channels` (включая выключенные —
их лечит существующая механика §274/§277) + `direct-out` + `block` + `reject` +
пустая строка (preset: «как в шаблоне»).

| Ссылка | Нет у получателя → | Warning в превью |
|---|---|---|
| `outbound` (inline/srs) / `varsValues['outbound']` (preset) | `vpn-1` (дефолт лечения §202) **+ правило выключается** | да: `Channel "%s" not found — set to %s, rule disabled` |
| `dns.serverTag` | `serverTag: ''`, `dns.enabled: false`; `forceIpv4` **сохраняем** (глушилке §256 сервер не нужен) | да: `DNS server "%s" not found — DNS option disabled` |
| `resolve.serverTag` | `''` (= auto, §247) | да: `DNS server "%s" not found — resolver set to auto` |

Выключение правила при подмене outbound — осознанное: включённое правило сразу
погнало бы трафик не туда, куда задумал автор. Немых мутаций нет — причина
названа в превью (инвариант §261 «кнопки не мутируют молча»).

Список валидных DNS-тегов — union storage-refs ∪ template
(`SettingsStorage.getDnsServers` + `template.dnsOptionsModel.servers`, тот же
источник, что дропдаун §117 в `edit_controller._loadDnsServerTags`).

### 5.3 Неимпортируемое

| Случай | Поведение |
|---|---|
| элемент `rules[]` не объект / `kind` не из enum | строка в превью «Unsupported entry» с disabled-чекбоксом (файл от более новой версии с новым kind — остальное импортируемо) |
| preset: `presetId` нет в шаблоне получателя | disabled-чекбокс + `Unknown preset (newer app version?)` — НЕ импортируем broken-card |
| `format > 1` / не-`lxbox` / `kind != rules` | отказ всего файла (FormatException) |

Замечание: `CustomRule.fromJson` без `kind` молча падает в inline
(backward-compat storage) — для импорта это неприемлемо (мусор станет пустым
inline-правилом), поэтому парсер конверта проверяет `kind` **до** вызова
`fromJson`.

### 5.3a DNS-секции файла (`dns_servers[]` / `dns_rules[]`)

Санация перед превью; вставка — `DnsServerRef.fromJsonStrict` /
`DnsRuleRef.fromJsonStrict` → append → `saveDnsServers` /
`saveDnsRulesList` (валидация та же, что у Debug write-пути §294;
orphan-cleanup остаётся за резолвером).

| Случай | Поведение |
|---|---|
| элемент не парсится (`DnsServerRef.fromJson`/`DnsRuleRef.fromJson` → null) | «Unsupported entry» (disabled) |
| сервер: `tag` уже есть у получателя | «Already on this device» (disabled) — настройки получателя НЕ перезаписываются |
| сервер `kind: template`: `tag` нет в шаблоне получателя | «Not available in this app version» (disabled) |
| сервер `kind: preset` | «Managed by presets» (disabled) — см. §4.2 п.2 |
| dns-правило `preset`/`template`: уже есть / нет в шаблоне | skip «already» / «not available» |
| dns-правило `inline`/`srs`: точный дубль у получателя | «Already on this device» (disabled) |
| dns-правило `srs` | `id` перегенерируется (кэш-файл `.srs` у получателя свой) |

Теги серверов, отмеченных на импорт, добавляются в `validDnsServerTags`
санации routing-правил (§5.2) — правило и его сервер, приехавшие одним
файлом, связываются без лечения.

### 5.4 Прочее

| Поле | Действие |
|---|---|
| `enabled` | из файла, НО: `needsSrs` (CustomRuleSrs или preset с remote rule_set'ами — предикат `_copyPreset`) → `false`; подменённый outbound (§5.2) → `false` |
| `wifiSsids`/`wifiBssids`, `packages` | как есть — это содержимое правила; что шарить, решает автор при выборе правил |
| json-правило | тело как есть — оно и сейчас вне dangling-механик (`custom_rule.dart` §225) |

## 6. Сервис

Новый `app/lib/services/rule_transfer.dart` (симметрично `BackupService`, чистый
Dart без BuildContext):

```dart
String buildRulesExport(List<CustomRule> rules, {String? appVersion});

class RulesImportContents {           // parseRulesImport(String) — throws FormatException
  DateTime? createdAt;
  String? sourceAppVersion;
  List<Map<String, dynamic>> rawRules;  // элементы rules[] как есть
}

class SanitizedImportRule {           // sanitizeImportedRule(raw, ctx) — per-element
  CustomRule? rule;                   // null = неимпортируемо
  List<ImportRuleWarning> warnings;   // typed; текст рендерит UI (l10n §285)
  bool get importable;
}
```

`ImportRuleWarning` — enum + payload (имя пропавшего тега), локализация на
стороне UI через `getLocalText` (сервис строк не трогает — паттерн ErrKey §285).

## 7. Файлы

| Файл | Изменение |
|---|---|
| `app/lib/services/rule_transfer.dart` | **новый** — конверт, парс, санация |
| `app/lib/widgets/export_action_sheet.dart` | **переезд** из `screens/backup_screen/` (шит §374 теперь общий) |
| `app/lib/screens/backup_screen.dart` | импорт шита с нового пути |
| `app/lib/screens/routing_screen/rule_transfer_dialogs.dart` | **новый** — полноэкранный выбор на экспорт + превью импорта (чистая презентация, стиль `routing_screen_menus.dart`) |
| `app/lib/screens/routing_screen/widgets/routing_tabs.dart` | **новый виджет** `RulesMenuButton` (⋮ для AppBar) |
| `app/lib/screens/routing_screen.dart` | `_exportRules()` / `_importRules()` — сбор контекста санации, шит, снекбары |
| `app/assets/l10n/ru/ui.json` | переводы новых строк |
| `test/services/rule_transfer_test.dart` | **новый** |

## 8. Тесты

- round-trip всех четырёх kind (inline/srs/preset/json) — export → parse →
  sanitize при полном наличии ссылок = эквивалентное правило, новый `id`;
- конверт: `app`/`kind`/`format` пишутся; парс отвергает не-JSON, чужой `app`,
  `kind: backup`, `format: 2`;
- элемент без `kind` / с неизвестным `kind` → неимпортируем, остальные элементы
  файла живы;
- outbound-лечение: незнакомый тег → `vpn-1` + `enabled: false` + warning;
  `reject`/`block`/`direct-out`/пустой — без изменений; preset-override в
  `varsValues['outbound']` лечится так же;
- dns-лечение: незнакомый `serverTag` → `enabled: false`, тег пуст, `forceIpv4`
  выжил; resolve-лечение → `serverTag: ''`;
- srs → `enabled: false` независимо от файла;
- preset: неизвестный `presetId` → неимпортируем; известный → `num` из шаблона;
- name-дедуп: импорт при существующем правиле с тем же именем → суффикс копии;
- `nextUserRuleNum`-последовательность при мульти-импорте.

## 9. Критерии приёмки

1. ⋮ на вкладке Rules: Export disabled при пустом списке; Import работает всегда.
2. Экспорт двух из трёх правил → файл содержит ровно два; шит §374 работает
   (Save to file / Downloads / Share), снекбары как у бэкапа.
3. Импорт того же файла на этом же устройстве → правила добавились копиями
   (суффикс имени), не задев оригиналы; повторный импорт не конфликтует по id.
4. Импорт файла с outbound-тегом несуществующего канала → правило появилось
   выключенным с outbound `vpn-1`, в превью было предупреждение.
5. Импорт srs-правила → выключено, ☁ качает, enable работает.
6. Импорт preset-правила → садится на шаблонный `num`, on_change применён;
   неизвестный `presetId` — отвергнут с внятной причиной.
7. Бэкап-файл в импорте правил (и наоборот) отвергается с понятной ошибкой.

## 10. Device-verification

Эмулятор: экспорт в Downloads → `adb pull` → проверка JSON; импорт через
файл-пикер; проверка порядка/enabled/лечения по `GET /rules` Debug API.

## Docs to update

- `CHANGELOG.md` — entry в `Unreleased` (user-visible).
- `docs/STORAGE.md` — НЕ требуется (схема storage не меняется).
- `docs/spec/tasks/374-backup-export-save-to-file.md` — перекрёстная ссылка:
  шит переехал в `lib/widgets/` и стал общим.
