# 704 — Mixins: пользовательские вставки в итоговый конфиг ядра

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата начала | 2026-11-01 |
| Источник | чат «L×Box & singbox launcher» 01.11.2026: пользователь zomg поднял DNS-слушатель sing-box для Rethink через Config Editor + Lock config; «проще всего давать инжектить в конфиг всякую арбитрарь, никакого гуя и обоснований для его ввода не напасёшься»; решение владельца — миксины со своим упрощённым синтаксисом пути |
| Коммиты | 013d8380 (модель, путь, глаголы, предпросмотр, автодополнение), 7b16ba0e (хранилище, сборка), 0d56bd9d (LX Backup), 134ef0c6 (Debug API), 8cd0f913 (UI §5: вкладка Mixins, форма, l10n, widget-тесты), 91ff2d75 (значок вкл/выкл подсказок Target, настройка `mixin_target_suggestions`); эмулятор 01.11 (сборка CI 41326404404, AVD arm64 API 34) — ОК: оба миксина через Debug API собрали `dns-in` и правило перед `hijack-dns`, `dig +tcp` через слушатель вернул A-записи example.com, выключение миксина (API и тумблер) убирает inbound из вкладки Config; порт 5353 на Android занят системным mDNS (uid mdnsr) — проверено на 5354; после перезапуска Activity форма до первой сборки пишет «No config built yet» без Preview |
| Связанные | фича [019-CONFIG_EDITOR](../features/019-CONFIG_EDITOR/FEATURE.ru.md) (ручная правка и закрепление), §037 (лок конфига), §225 (Raw JSON правило), §691 (поле с подсказками), §660/§624 (редактор sora), §653 (`CoreConfigTags`, индекс → тег при отказе ядра), §302 (Import Rules, путь через точку) |

## Проблема

Пользователю нужен элемент конфига, которого шаблон не даёт: inbound типа
`direct` на `127.0.0.1:5354` с правилом `hijack-dns`, чтобы отдать DNS-движок
sing-box внешнему приложению (Rethink). Сегодня это делается только ручной
правкой в Config Editor с закреплением конфига (§037): после лока любое
действие в интерфейсе в ядро не попадает, для повседневного пользования
это не годится. Формы на каждый тип inbound/outbound — не вариант: их не
напасёшься, и они не нужны тем, кто умеет писать JSON ядра.

Миксин — хранимая операция над итоговым конфигом: цель (путь), глагол и
JSON-значение. Применяется в самом конце сборки, переживает пересборки,
едет в LX Backup, доступна через Debug API, редактируется на вкладке
Mixins экрана Config.

## Решение

### 1. Модель и хранилище

Запись `Mixin` (`lib/models/mixin.dart`):

```json
{
  "id": "uuid",
  "name": "Hijack DNS from dns-in",
  "enabled": true,
  "target": "route.rules[action=hijack-dns]",
  "op": "before",
  "value": {"inbound": ["dns-in"], "action": "hijack-dns"}
}
```

- `id` — UUID v4 из конструктора (`newUuidV4`, `lib/services/parser/uri_utils.dart:216`), как у `CustomRule`.
- `name` — строка, пустая допустима; в списке пустое имя показывается как `target → op`.
- `enabled` — bool, выключенный миксин при сборке пропускается.
- `target` — строка пути (§3).
- `op` — один из `append`, `prepend`, `before`, `after`, `set`, `merge`, `remove`.
- `value` — любой JSON; у `remove` это `true` (узел целиком) или список строк (ключи).

Один миксин = одна операция. Группировка — порядок в списке и имя.

Ключ `mixins` в `lxbox_settings.json`: `kMixinsKey` в
`lib/services/settings_storage_keys.dart`; добавить в
`SettingsStorage.allowedTopLevelKeys` (`settings_storage.dart:205`),
`_topLevelRoutingKeys` (`backup_service.dart:~34`), `backup_merge.dart`
(`:40`, `:156` — как `kRulesKey`). Фасад `getMixins`/`setMixins` по образцу
`directions` (`settings_storage/directions.dart:36,42`); запись вызывает
`markConfigDirty()` (§113, config-significant). `docs/STORAGE.md` — новый
ключ с семантикой.

`BuildSettings` (`build_config.dart:106`) получает `mixins`;
`readStoredBuildSettings` (`direction_pool_preview.dart:30`) и тестовый
харнесс (`test/storage_migration/golden_harness.dart:211`) его читают.
Фикстуру `rich_v0.json` не трогать: без ключа `mixins` golden не меняется.

### 2. Применение при сборке

Место: `_buildConfig` после `sanitizeOutboundGraph` (`build_config.dart:1051`)
и до `validateConfig` (`:1095`). Миксины — сырой обход: санитайзер реестра
и автоснятия их не видят (как Raw JSON у правил), валидатор видит результат.

`applyMixins(Map<String, dynamic> config, List<Mixin> mixins) → MixinApplyResult`
(`lib/services/mixins/mixin_apply.dart`): включённые миксины по порядку
списка, каждый видит результат предыдущих. Ошибки собираются, не бросаются:
`MixinIssue {mixinId, name, target, message}`. После применения — проверка
уникальности тегов в `inbounds`, `outbounds`, `endpoints`, `dns.servers`:
дубль = issue с именем миксина, который его внёс.

Любая issue — fatal: новый вид в `lib/models/validation.dart`, попадает в
`FatalValidationException` (`:392`) и дальше по существующему пути
(`generateConfig` → `_lastError`/`_lastFatalIssues`, SnackBar на главной,
`home_screen.dart:361`). Текст: `Mixin "<name>": <target>: no match`,
`Mixin "<name>": duplicate tag "x" in outbounds`. Конфиг не собирается,
миксин остаётся включённым — пользователь правит его, а не ищет.

### 3. Язык пути

Свой, не JSONPath. Грамматика:

```
путь     = "" | сегмент ("." сегмент)*
сегмент  = имя | имя "[" N "]" | имя "[" условия "]"
условия  = условие ("," условие)*
условие  = поле "=" значение
поле     = имя ("." имя)*
```

- Пустой путь — корень документа.
- `имя` — ключ объекта; числовой сегмент после точки (`outbounds.0`) читается как индекс, ради одной нормы с Import Rules.
- `имя[N]` — элемент списка по индексу.
- `имя[условия]` — элементы списка `имя`, у которых все условия верны. `поле` — скаляр элемента или путь вглубь него (`tls.enabled`).
- `значение` — всё до запятой или `]`, пробелы внутри допустимы (`[tag=S2 Fastest]`), запятая и `]` в значении в v1 не поддерживаются.
- Сравнение: число с числом, bool с bool (`true`/`false`), иначе строки с учётом регистра. Если поле элемента — список скаляров, равенство означает «содержит».
- Регулярок, `!=`, `or` нет. Путь, начинающийся с `$`, зарезервирован (JSONPath на будущее), в v1 — синтаксическая ошибка.

Путь обозначает **набор узлов**. Разбор и разрешение —
`lib/services/mixins/mixin_path.dart`: `parseMixinPath(String) → MixinPath | MixinPathError{offset, message}`,
`resolve(root) → List<PathMatch{parent, key|index, value}>`. Движок разбора
(`jsonPathValue`, `interpreter.dart:1274`) не трогать: у него селектор
«первый, без учёта регистра» по норме контракта 1.1.83.

### 4. Семантика глаголов

| Глагол | Цель | Действие |
|---|---|---|
| `append` | один узел, список | значение в конец; если значение само список — каждый элемент по очереди |
| `prepend` | один узел, список | то же в начало, порядок значения сохраняется |
| `before` | элементы списка | значение (или каждый элемент значения-списка, в его порядке) на тот же уровень перед **первым** совпавшим |
| `after` | элементы списка | то же после **последним** совпавшим |
| `set` | любой узел | заменить значение целиком: скаляр, список, объект |
| `merge` | объект(ы) | слить вглубь: ключи значения дописываются или заменяют свои, чужие не трогаются; объект в объект рекурсивно; список внутри значения заменяет список цели целиком |
| `remove: true` | любой узел | узел удаляется: элемент списка выбывает, ключ объекта исчезает |
| `remove: [ключи]` | объект(ы) | удаляются только названные ключи, путь внутри элемента через точку; отсутствующий ключ — не ошибка |

По количеству совпадений:

| Глагол | 0 | 1 | несколько |
|---|---|---|---|
| `set`, `merge`, `remove` | ошибка | применить | к каждому, одно и то же значение |
| `before` | ошибка | перед ним | перед первым |
| `after` | ошибка | после него | после последнего |
| `append`, `prepend` | ошибка | в этот список | ошибка |

Ошибки типа цели: `before`/`after` на узле, который не элемент списка
(`inbounds`, `log.level`); `append`/`prepend` на не-списке; `merge` на
не-объекте; `remove` с ключами на не-объекте. Все — issue с именем миксина.

Примеры — на golden `test/fixtures/storage/golden/rich_v0.config.json`:

```json
{"target": "inbounds", "op": "append", "value": {"type": "direct", "tag": "dns-in", "listen": "127.0.0.1", "listen_port": 5354, "override_address": "1.1.1.1", "override_port": 53}}
{"target": "route.rules[action=hijack-dns]", "op": "before", "value": {"inbound": ["dns-in"], "action": "hijack-dns"}}
{"target": "route.rules[action=resolve,strategy=prefer_ipv4]", "op": "after", "value": {"domain_suffix": [".nas.home"], "outbound": "direct-out"}}
{"target": "outbounds[type=vless]", "op": "merge", "value": {"tcp_fast_open": true}}
{"target": "outbounds[tag=PR DE-1]", "op": "remove", "value": ["tcp_fast_open", "tls.utls"]}
{"target": "route.rules[rule_set=Ads]", "op": "remove", "value": true}
{"target": "log.level", "op": "set", "value": "warn"}
{"target": "", "op": "merge", "value": {"services": []}}
```

### 5. UI

**Экран Config** (`lib/screens/config_screen.dart`) получает `TabBar` по
образцу `routing_screen.dart:174–409`: вкладки **Config** | **Mixins**.
Вкладка Config — всё как сейчас, показывает конфиг уже с применёнными
миксинами. Подсказка после Save про лок остаётся.

**Вкладка Mixins** — список (`ReorderableListView`): ручка перетаскивания
(порядок = порядок применения), имя, под ним `target → op` вторичным
текстом, тумблер справа. Под строкой `⚠ <message>`, если последняя сборка
дала issue этого миксина (из `_lastFatalIssues`, по `mixinId`). Долгий тап —
Duplicate, Delete. Кнопка (+). Вкладка видна всегда, от Debug API не
зависит. Тумблер, порядок, удаление — сохранение сразу, с пересборкой.

```
┌──────────────────────────────────────────┐
│ ←  Config                            ⋮   │
├──────────────────────────────────────────┤
│      Config      │     Mixins            │
├──────────────────────────────────────────┤
│ ≡  DNS listener for Rethink         (●)  │
│    inbounds → append                     │
│ ≡  Hijack DNS from dns-in           (●)  │
│    route.rules[action=hijack-dns] → before│
│ ≡  Drop Ads rule                    (●)  │
│    route.rules[rule_set=Ads] → remove    │
│    ⚠ no match                            │
│                                     (+)  │
└──────────────────────────────────────────┘
```

**Форма миксина** (`lib/screens/mixin_edit_screen.dart`), Save в AppBar:

1. **Name** — текстовое поле.
2. **Target** — текстовое поле с автодополнением по курсору и живым статусом под полем. Без кнопки ▾ (набор зависит от позиции курсора). Источник подсказок и статуса — текущий собранный конфиг (тот же текст, что на вкладке Config).
   - после начала строки или `.` — ключи объекта на этом уровне; если на уровне список — `[`;
   - после `[` — поля, встречающиеся у элементов списка (объединение по всем элементам, только скаляры и списки скаляров), плюс индексы;
   - после `=` — значения этого поля у элементов (уникальные, в порядке появления);
   - после `,` внутри скобок — поля, кроме уже использованных;
   - после `]` — `.`.
   Список под полем фильтруется по набранному фрагменту, тап подставляет и ставит курсор дальше. Если префикс до курсора не разбирается — подсказок нет. Значок справа в поле (лампочка, tooltip Suggestions) включает и выключает подсказки; выключенные не показываются и не считаются, живой статус работает как прежде. Состояние — одна настройка приложения `mixin_target_suggestions` (по умолчанию включено), запоминается между открытиями формы, config dirty не поднимает (решение владельца 01.11).
   Статус: `✓ 1 match`, `✓ 3 matches → before first` / `→ after last`, `✗ no match`, `✗ syntax: <message>`. Для `append`/`prepend` при нескольких совпадениях или цели-не-списке — `✗ needs a single list`.
3. **Action** — выпадающий список семи глаголов. У `remove` — переключатель Whole node / Keys; при Keys — поле ключей через запятую, поле Value скрыто.
4. **Value** — `LxTextCodeField` (`lx_code_editor.dart:1473`) с `format: true`, JSON5; при Save — `canonicalJsonForSingbox` (`lib/config/config_parse.dart:12`) и `jsonDecode`. Ошибка разбора — под полем, как в `JsonSection`.
5. **Preview** — фрагмент результата: родитель цели после применения. Это **не sora**: обычный список строк моноширинным шрифтом, один элемент = одна свёрнутая строка (компактный JSON, обрезан по ширине), в гаттере `+` вставленный, `~` изменённый, `-` удалённый, с подкраской фона. Тап по строке — полный JSON элемента в `LxJsonView`. Для цели-скаляра — одна строка `было → стало`.

Save неактивна, пока статус Target не ✓ или Value не разбирается. Save —
общий путь сохранения сущности: запись в хранилище, `markConfigDirty`,
пересборка и воронка автоприменения §667.

```
┌──────────────────────────────────────────┐
│ ←  Mixin                           Save  │
├──────────────────────────────────────────┤
│ Name   [Hijack DNS from dns-in        ]  │
│ Target [route.rules[action=hijack-dns ]  │
│        ✓ 1 match                         │
│ Action [before                      ▾ ]  │
│ Value                            Format  │
│ ┌──────────────────────────────────────┐ │
│ │ {"inbound": ["dns-in"],              │ │
│ │  "action": "hijack-dns"}             │ │
│ └──────────────────────────────────────┘ │
│ Preview   route.rules                    │
│   {"action":"sniff","inbound":[…]}       │
│ + {"inbound":["dns-in"],"action":"hij…}  │
│   {"protocol":"dns","action":"hijack-…}  │
└──────────────────────────────────────────┘
```

Все строки UI — английские, через `getLocalText.s`, переводы в
`assets/l10n/ru/ui.json` и `assets/l10n/zh/ui.json`; чекеры
`tool/l10n/ui_check.dart --strict`, `hardcoded_check.dart --strict`.

### 6. LX Backup

Секция корня `mixins` — список записей §1 без `id` (id при импорте новый).
Экспорт в `buildLxBackup` (`lx_backup.dart:863`, после `warp`), разбор в
`parseLxBackup` (`:~1290`), план/применение (`lx_backup_import.dart:211,494,543`),
белые списки корня (`lx_backup.dart:~1530`, `:~3455`, обходы `:1777`, `:3635`).
Импорт — добавление в конец списка; совпадение по телу
(`target`+`op`+`value`) — пропуск, не дубль. Контракт: `mixins` — наша
секция, лаунчеру — запрос объявить ключ в `backup.schema.json` как
терпимый (у него предупреждение `backup_unknown_field` до тех пор);
правка схемы только через `tool/sync_contract.sh`, здесь не делается.

### 7. Debug API

`/mixins` CRUD + `POST /mixins/reorder` по образцу `handlers/directions.dart:35`;
`rebuild=true` через `maybeRebuild`. Регистрация в `transport/server.dart:~224`,
таблица `/help` (`handlers/help.dart`), документ `docs/api/debug-api-reference.md`
(раздел `## Mixins CRUD — /mixins/*` после Directions, пункт в Index),
паритет `test/services/debug/help_json_test.dart`.
`GET /mixins/:id/preview` — результат применения одного миксина к текущему
собранному конфигу: `{matches: N, issue: ..., fragment: ...}` — то же, что
показывает форма.

## Риски и края

- Миксин, который ломает ядро на старте (неизвестное поле, неверный тип): автоснятия нет, `CoreConfigTags` (§653) привязывает отказ к тегу, если элемент тегирован; для правил — только индекс в тексте ошибки. Принято.
- Дубль тега ловится до ядра (§2), остальное — ядром.
- Порядок ключей объекта при `merge` — новые в конец; ядру безразлично.
- Миксин на `route.rules` с `prepend` встаёт перед Traffic Processing (sniff/hijack). Это осознанно: пользователь выбирает цель сам.
- Ручная правка в Config Editor и миксины независимы: пересборка перетирает ручную правку и применяет миксины заново.

## Проверка

- `test/services/mixins/mixin_path_test.dart` — грамматика (ошибки с offset), разрешение на golden `rich_v0.config.json`: все примеры §3/§4, пробелы в теге, вложенное поле условия, «содержит» для списка, индекс, пустой путь.
- `test/services/mixins/mixin_apply_test.dart` — каждый глагол × (0/1/много), значение-список у `before`/`after`/`append`, `merge` вглубь и замена списка, `remove` ключами с вложенным путём, порядок двух миксинов, дубль тега, ошибки типа цели.
- `test/services/builder/build_mixins_test.dart` — `BuildSettings.mixins` доходит до конфига, выключенный пропускается, issue становится fatal.
- Хранилище: roundtrip `mixins`, `markConfigDirty` при записи.
- LX Backup: экспорт/импорт секции, совпадение по телу.
- Debug API: CRUD, reorder, preview.
- Widget: вкладки Config/Mixins, список с тумблером, форма — статус Target на фикстурном конфиге, Save неактивна при `no match`.
- Эмулятор: сценарий zomg — миксины inbound `dns-in` + правило `hijack-dns`, `dig +tcp @127.0.0.1 -p 5354` через `adb forward` отвечает; выключение миксина убирает inbound из вкладки Config.

## Открытое

- Группировка миксинов (папка с общим тумблером) — по запросу.
- JSONPath за `$` — если понадобятся регулярки и `or`.
- Объявление `mixins` в схеме бэкапа лаунчера.
- Решено исполнителем: база предпросмотра и подсказок — не собранный конфиг (в нём миксин уже применён), а `BuildResult.configBeforeMixins` / `SubscriptionController.lastConfigBeforeMixins` + включённые миксины выше (`mixinPreviewBase`); `GET /mixins/{id}/preview` без сборки в сессии — 409.
- Решено исполнителем: дубль тега проверяется в `outbounds`+`endpoints` одним пространством имён (у ядра оно общее), отдельно `inbounds` и `dns.servers`.
- Решено исполнителем: битая запись секции `mixins` LX Backup (нет строковых `target`/`op`) — пропуск с `backup_field_type_mismatch`, нового кода реестра нет; экспорт берёт список в `backup_screen.dart` (одна строка передачи).
- Решено исполнителем: Debug API при записи проверяет синтаксис пути и глагол (400), совпадение — нет; `set` корня — только объект, `remove` корня — отказ.
- Решено исполнителем (UI): форма Save возвращает миксин, запись и пересборку делает вкладка Mixins (`generateConfig` → `saveParsedConfig` → `applyIfAutoReload`, как `regenerateSourcesConfig` §558); пересборки идут по одной, правка во время сборки — один повтор.
- Решено исполнителем (UI): статус Target считается в форме по базе предпросмотра, без значения; сверх макета — `✗ not a list element` для `before`/`after`. Отказы, зависящие от значения (`merge` без объекта, дубль тега), — строкой `⚠` над Preview, Save не блокируют (по §5 блокируют только статус и разбор Value). У `remove` с Keys пустой список ключей Save не даёт.
- Решено исполнителем (UI): Save и ⋮ вкладки Config на вкладке Mixins скрыты; после пересборки от миксинов вкладка Config перечитывает конфиг, если в редакторе нет несохранённой правки; вкладка Config держится живой (keep-alive). Тумблер справа, как в макете §5 (у правил он слева).
- Решено исполнителем (UI): `ConfigScreen.subController` необязателен — без него запись поднимает dirty без пересборки, подсказок и предпросмотра нет (старый тест экрана его не передаёт).
- Проверено на эмуляторе 01.11 (см. «Статус»). Порт 5353 на Android может держать системный mDNS — в примерах порт 5354; у zomg на телефоне 5353 встал.
- Решено владельцем 03.11: база предпросмотра (`lastConfigBeforeMixins`) живёт только в памяти, на диск не пишется. Если её нет (процесс перезапущен, сборки в нём не было), вход на вкладку Mixins собирает конфиг в память — один `generateConfig()`, без `saveParsedConfig` и без `applyIfAutoReload`; правка списка во время этой сборки ждёт её и идёт повтором. Форма, открытая во время сборки, пишет под Target «Building config...» и подхватывает базу, когда сборка кончится. «No config built yet» остаётся, если сборка не дала базы (Lock config, отказ до разбора миксинов). Debug API `GET /mixins/{id}/preview` без сборки в сессии по-прежнему 409.
- Debug API: правка одного миксина — `PATCH /mixins/{id}` (в «Проверке» было написано `PUT`).
