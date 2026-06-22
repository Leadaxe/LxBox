# 159 — Backup: строгий allowlist-фильтр (default-deny) для импорта настроек

| Поле | Значение |
|------|----------|
| Статус | **Done** (2026-06-22) — реализовано: allowlist в `replaceRaw`, экспорт расфильтрован, droppedKeys→applog+снэкбар, DENY/миграции удалены, seed распутан, ping_options strip. `flutter analyze` чисто, все 1186 тестов прошли (+ новые §159 allowlist-тесты). On-device проверено: импорт чужого файла → неизвестные ключи отброшены, снэкбар «N неизвестных ключей пропущено», `debug_token` сохранён. Вошло в v2.4.0. |
| Дата | 2026-06-22 |
| Тип | feature spec (изменение поведения импорта/экспорта бэкапа) + sec-hardening |
| Повод | В `lxbox_settings.json` накапливаются «мёртвые» ключи (остатки снятых настроек); текущий фильтр бэкапа пропускает неизвестные ключи через `else`-ветку → мусор и **чужеродные ключи** (бэкап от другого приложения / агента) попадают в storage. |
| Связано | §031 (Debug API — denylist-сериализатор, противоположная философия — НЕ путать), STORAGE.md (реестр ключей), §100 (node_sort — был не задокументирован, починено этой же сессией) |

---

## TL;DR

Сегодня импорт бэкапа фильтруется через whitelist категорий, но с
«прощающей» `else`-веткой: **неизвестный top-level ключ сваливается в App
settings и пишется в файл**, а `vars` заливаются почти целиком. Это нормально,
пока бэкап — наш собственный. Но если файл собран другим приложением/агентом,
чужеродные ключи пролезают в `lxbox_settings.json` и живут там как настоящие.

Меняем на **строгий default-deny allowlist**, двухуровневый:

- **top-level** → статический allowlist из 17 актуальных ключей. Чего нет —
  **отбрасывается** (не «в App settings»).
- **vars** → рантайм-allowlist `(23 кодовых флага) ∪ (vars текущего template)`.
  Чего нет — отбрасывается.

Отброшенные ключи: **drop + лог в applog + исчезающий UI-попап** при импорте
(«N неизвестных ключей пропущено»).

Фильтр ставим в **единую точку входа** `SettingsStorage.replaceRaw` — она же
обслуживает Debug API `POST /backup/import`, где сейчас вообще нет валидации (и
через неё обходится блокировка `debug_token`). Экспорт НЕ фильтруем — чистим
только на входе.

---

## Проблема (детально)

### Где копится мусор

Настройки лежат в `lxbox_settings.json` (`SettingsStorage`, Dart). Ключи
разбросаны по коду как литералы в getter/setter'ах — **единого реестра нет**.
При снятии настройки её значение остаётся в файле, пока кто-то явно не удалит.

### Что есть сейчас

| Механизм | Где | Что делает |
|---|---|---|
| Хардкод-очистка | `settings_storage/io.dart:160-164` | На каждом `_save()` режет ровно 3 ключа: `node_overrides`, `show_detour_servers`, `vars.auto_rebuild`. **Это чёрный список из 3 строк, не правило.** |
| One-shot миграции | `settings_storage/sources_rules.dart` | `proxy_sources`/`app_rules`/`enabled_rules`/`rule_outbounds` конвертируются и удаляются. |
| Whitelist-фильтр бэкапа | `backup_service.dart:440-479` `_filterStorageForImport` | Раскладывает ключи по категориям. **Дыра — `else`-ветка (строки 473-475).** |

### Две дыры в `_filterStorageForImport`

```dart
// backup_service.dart:473-475
} else {
  // Unknown / future key — graceful default: bundle into App settings.
  if (wantApp) out[key] = deepCloneJson(value);
}
```

1. **Дыра 1 — top-level `else`.** Неизвестный top-level ключ не отбрасывается,
   а кладётся в App settings → пишется в `lxbox_settings.json`. Чужеродный
   top-level ключ пролезает.
2. **Дыра 2 — vars берутся целиком.** Внутри `vars` нет allowlist по подключам:
   фильтр (строки 455-468) пропускает **все** vars, кроме `_varDebugKeys`. Любые
   чужие vars заливаются.

При **replace**-импорте (`merge:false`) мусор, не попавший в выбранные
категории, не переносится. Но всё, что попало под App settings (включая Дыру 1
и Дыру 2), переносится. Три «мёртвых» ключа из хардкод-очистки добиваются
первым `_save()`; **любой другой устаревший/чужой ключ переживает.**

---

## Реестр ключей (источник истины для allowlist)

> Числа выверены сверкой кода ↔ `wizard_template.json` ↔ STORAGE.md (2026-06-22).
> Раньше в обсуждении фигурировали неточные «18/41» — здесь точные значения.

### A) TOP-LEVEL — 17 актуальных (статический allowlist)

| Ключ | Тип | §/раздел |
|---|---|---|
| `vars` | object | (вложенный уровень — см. B) |
| `server_lists` | list | §033 |
| `custom_rules` | list | §030 |
| `dns_options` | object | §061/§043/§044 |
| `ping_options` | object | §040 |
| `route_final` | string | — |
| `excluded_nodes` | list | — |
| `enabled_groups` | list | — |
| `tun_apps` | object | §046 |
| `vpn_mode` | object | §119 |
| `warp_account` | object | §025 (секреты — см. ниже) |
| `last_global_update` | string | §027 |
| `presets_migrated` | bool | one-shot guard |
| `interrupt_connections_on_switch` | bool | §143 |
| `node_sort_mode` | string | §100 |
| `node_manual_order` | list | §100 |

(`vars` — это сам контейнер; считается top-level ключом, его содержимое
фильтруется на уровне B.)

### B) VARS — 29 в template + 23 в коде (рантайм allowlist)

**B1 — объявлены в template** (`wizard_template.json`, 4 источника):
`sections[].vars[]` (7 секций), `dns_options.servers[].vars[]`,
`selectable_rules[].vars[]`, `preset_groups[].tag` как `@var`. **Набор
динамический** — зависит от загруженного template (пресеты/DNS-серверы добавляют
свои vars: `dns_ip`, `outbound`, `safe_profile`, `dom_resolver`…). Поэтому
зашивать имена нельзя — собирать из `template.vars` в рантайме.

**B2 — только в коде (23 флага, в template ИХ НЕТ → обязаны быть в хардкоде):**

| Группа | Ключи | § |
|---|---|---|
| Debug API | `debug_enabled`, `debug_token`, `debug_port`, `config_locked_for_debug` | §031/§037 |
| App updates | `auto_check_updates`, `last_update_check_at`, `last_known_version`, `dismissed_update_version` | §036 |
| Automation | `automation_receive_enabled`, `automation_emit_lifecycle`, `automation_emit_state`, `automation_emit_subs`, `automation_emit_health`, `automation_explainer_shown_v1` | §047 |
| Subscription identity | `subscription_user_agent`, `subscription_send_hwid`, `subscription_hwid`, `subscription_device_os`, `subscription_ver_os`, `subscription_device_model` | — |
| Wi-Fi / subs | `wifi_history`, `auto_record_wifi_history`, `auto_update_subs` | §051/§027 |

### C) LEGACY / DENY — упраздняется (решение 2026-06-22)

**DENY-механика и миграции больше не поддерживаются.** Allowlist — единственная
машинерия чистки: «не в списке → выброшено», где бы ключ ни появился (вход извне
ИЛИ файл на диске через allowlist-прогон на `_load`). Хардкод-`.remove()` и
конверсионный код удаляются.

**Обоснование (юзер):** всё, что могло, давно смигрировало (миграции с v1.3.x,
сейчас сер. 2026). Кто застрял на доисторической версии — смигрирует через
экспорт/импорт или заново проставит галки. Держать конверсионный код ради
гипотетического трёхлетнего файла не стоит.

| Ключ | Было | Станет |
|---|---|---|
| `node_overrides` | режется в `_save()` | **не в allowlist** → выброшен |
| `show_detour_servers` | режется в `_save()` | **не в allowlist** → выброшен |
| `auto_rebuild` (vars) | режется в `_save()` (§107) | **не в allowlist** → выброшен |
| `proxy_sources` | one-shot → `server_lists` | миграция удалена, ключ выброшен |
| `app_rules` | one-shot → `custom_rules` | миграция удалена, ключ выброшен |
| `enabled_rules` | one-shot → `custom_rules` | миграция удалена, ключ выброшен — **уходит из allowlist** |
| `rule_outbounds` | one-shot → `custom_rules` | миграция удалена, ключ выброшен — **уходит из allowlist** |
| `dns_options.rules_json` | deprecated, для downgrade | остаётся (вложенный в `dns_options`, не отдельный ключ; downgrade-friendly) |

**Следствие:** `enabled_rules` и `rule_outbounds` — **чисто миграционные**, живых
потребителей нет (grep подтвердил: единственное использование — сам one-shot в
`routing_srs_cache.dart`). После удаления миграции они уходят и из top-level
allowlist → **ALLOWED_TOP_LEVEL = 15**, не 17. Аналогично `presets_migrated`
(guard миграции) и `proxy_sources`/`app_rules` — выпадают.

### ⚠️ Ловушка: `_migrateLegacyPresets` делает ДВЕ вещи

`routing_srs_cache.dart:146-175` — это **не только миграция**:

```dart
final labels = legacyEnabled.isNotEmpty
    ? legacyEnabled                          // ветка МИГРАЦИИ (legacy юзер)
    : { for (r in template.selectableRules)  // ветка SEED (fresh install!)
          if (r.defaultEnabled) r.label };
```

Для **fresh install** (legacy-ключей нет) она **сидит дефолтные routing-правила**
из template. **Нельзя удалять функцию целиком** — иначе новый юзер останется без
дефолтных правил. Распутать: убрать legacy-ветку
(`getEnabledRules`/`getRuleOutbounds`/`legacyEnabled`/`legacyOutbounds`/
`overrideOutbound`), **сохранить** seed-ветку для fresh install. Guard
`presets_migrated` → переосмыслить: seed по-прежнему должен быть one-shot, но без
привязки к снятым legacy-ключам (например, гейтить по «`custom_rules` пуст +
не сидили раньше»).

---

## Формула фильтра

```
известный top-level ключ  =  ∈ ALLOWED_TOP_LEVEL (17, статический)

известный vars-ключ       =  ∈ APP_FEATURE_FLAGS (23, хардкод)
                             ∪ { v.name | v ∈ template.vars }   (рантайм)
```

Всё, что не подошло → **отбрасывается** (default-deny).

---

## Точки доступа (карта для реализации)

| Операция | Файл:строка | Заметка |
|---|---|---|
| чтение var | `settings_storage/vars.dart:8` `_getVar` | `vars[name] ?? default` |
| запись var | `settings_storage/vars.dart:14` `_setVar` | валидации имени **нет** |
| все vars | `settings_storage/vars.dart:28` `_getAllVars` | весь Map |
| template vars | `parser_config.dart` `WizardTemplate.vars` / `varsFor()` | готовый источник для «∪ template» |
| экспорт | `settings_storage/backup_tun.dart:9` `_dumpCache` | deep-copy всего `_cache` |
| импорт | `settings_storage/backup_tun.dart:14` `_replaceRaw` | replace / merge (vars upsert) |
| фильтр бэкапа | `backup_service.dart:440` `_filterStorageForImport` | **точка изменения** |
| хардкод-очистка | `settings_storage/io.dart:160` `_save` | 3 ключа |

---

## Решения (согласовано с юзером 2026-06-22)

1. **Forward-compat жертвуем:** строгий default-deny **всегда**, независимо от
   источника бэкапа. Неизвестный ключ всегда отбрасывается. Потерю полей при
   откате на старую версию закрывает само правило «не знаю ключ — не пишу».
2. **vars НЕ хардкодим списком:** источник истины для template-vars — сам
   `wizard_template.json` (управляется нами, не юзером, зашит в APK). Хардкод —
   только 23 флага группы B2, которых в template нет. Резолвим против
   **локального** template (template в бэкап не входит — см. раздел ниже).
   `template из бэкапа` как опция **отвергнута**: template там физически
   отсутствует.
3. **Фильтр только на ВХОДЕ, не на выходе.**
   - **Экспорт** → выгружаем storage как есть, БЕЗ фильтра («что записали, то и
     отдаём»). Текущий общий `_filterStorageForImport`, используемый и для
     экспорта, по этой задаче **разводится**: экспорт перестаёт фильтровать.
   - **Импорт** → строгий allowlist (см. п.1).
   - Это распространяется на **любой вход данных в storage**, не только UI-импорт
     (см. «Единая точка входа» ниже).
4. **`warp_account` — импортируем и экспортируем как обычный ключ.** Юзер
   отвечает за источник файла (как с любым бэкапом); захочет — перерегистрирует
   через «Get WARP». Никакого scrub/opt-in — `warp_account` просто валидный ключ
   в allowlist. (Вопрос про секреты снят.)
5. **Drop-политика:** отброшенный ключ →
   - **drop** (не пишется в storage);
   - **лог** в applog: `dropped N unknown keys on import: [...]`;
   - **исчезающий UI-попап** (снэкбар/тост) на backup-экране: «N неизвестных
     ключей пропущено».

## Единая точка входа: фильтр в `replaceRaw`, не в UI-слое

И UI-импорт (`backup_service.applyImport`), и Debug API `POST /backup/import`
(`debug/handlers/backup.dart`) сходятся в **одной** функции:
`SettingsStorage.replaceRaw` → `_replaceRaw` (`settings_storage/backup_tun.dart:14`).

**Решение:** allowlist-фильтр встроить **в `replaceRaw`** (точка входа в storage),
а не в `backup_service.dart`. Один фильтр закрывает все входы разом:

- UI-импорт бэкапа (Дыра 1 + Дыра 2);
- Debug API `POST /backup/import` (см. ниже — сейчас идёт мимо всякой валидации);
- обход блокировки `debug_token` (см. ниже).

`replaceRaw` фильтрует и `merge=false` (replace целиком), и `merge=true` (vars-upsert).

## Debug API: тот же вектор (выяснено 2026-06-22)

Большинство write-эндпоинтов Debug API **строго типизированы** (каждый пишет одно
известное поле: `route_final`, `tun_apps`, `vars/{key}`, dns servers…) → фильтр
не нужен. Но есть массовые входы без валидации:

| Эндпоинт | Проблема | Закрывается |
|---|---|---|
| `POST /backup/import` | зовёт `replaceRaw` напрямую — **никакого** allowlist (`debug/handlers/backup.dart`, `replaceRaw`) | фильтром в `replaceRaw` ✓ |
| `merge=true` на `vars` | vars-upsert без проверки имён (`backup_tun.dart:28-31`) | фильтром в `replaceRaw` ✓ |
| `PUT /settings/ping_options` | валидирует только `url`/`timeout_ms`/`groups`; прочие ключи тела пишет в `ping_options` как есть (`settings.dart:337-360`) | отдельная мелкая правка (strip unknown subkeys) |

**Баг в существующей защите:** `PUT /settings/vars/debug_token` **заблокирован**
через `_varBlocklist` (`settings.dart:171-175`), НО `POST /backup/import` пишет
`debug_token` спокойно — идёт мимо блок-листа через `replaceRaw`. Фильтр в
`replaceRaw` (с учётом, что `debug_token` валиден как ключ, но защищён от
перезаписи извне) должен закрыть и это. **Уточнить:** `debug_token` — валидный
var (в allowlist B2), но через import-вход его перезапись = lockout. Нужен ли он
в импорте вообще, или import должен сохранять текущий `debug_token`?

`GET /state/storage` (`serializers/storage.dart`) — фильтр НЕ нужен: это **выход**
(чтение), там denylist-scrubber по делу. «Конфликт философий» снят — это разные
задачи (вход vs выход), а не противоречие.

---

## Template живёт в приложении, НЕ в бэкапе (выяснено 2026-06-22)

Проверка кода однозначна:

- `wizard_template.json` — **статический asset в APK**, грузится через
  `rootBundle.loadString('assets/wizard_template.json')`
  (`template_loader.dart:16`). Юзер заменить не может, на диск не персистится,
  парсится заново при каждом запуске.
- **В бэкап template НЕ попадает.** Wire-format = `storage` (содержимое
  `lxbox_settings.json`) + `vpn_settings`. Каталога vars / `template` /
  `template_version` там нет (`backup_service.dart:216`).
- Бэкап хранит только **значения** vars, без привязки к тому, из какого template
  они взяты. Маркера активного template в storage нет.

**Следствие для фильтра:** vars резолвятся против **локального (текущего)
template** — другого варианта физически нет. Template один на версию приложения
(у всех юзеров одной версии одинаковый), поэтому «импорт под другой template»
как класс отсутствует — разные template бывают только между версиями
*приложения* (вопрос миграции при апгрейде, не импорта бэкапа).

**Единственный реальный кейс:** старый бэкап → новая версия app с изменившимся
template (var переименован/убран). Старое имя var отфильтруется как неизвестное —
это **корректное** поведение строгого allowlist (мёртвый var не должен пролезать),
покрывается drop + лог.

## Открытые вопросы / риски (закрыты 2026-06-22)

- [x] **`debug_token` в импорте.** Решено: импорт **сохраняет текущий**
      `debug_token` (как `_varBlocklist`) — перезапись извне через `replaceRaw`
      больше не lockout'ит Debug API. Покрыто тестом + on-device.
- [x] **Разведение экспорта и импорта.** Сделано: экспорт перестал звать
      `_filterStorageForImport` (выгружает storage как есть), импорт фильтрует в
      `replaceRaw`. Wire-формат не изменился — чтение существующих бэкапов не
      сломано (проверено тестами round-trip + on-device).

---

## План реализации (предварительный, после согласования)

1. Вынести `ALLOWED_TOP_LEVEL` (17) и `APP_FEATURE_FLAGS` (23) в именованные
   константы в `SettingsStorage` (рядом с `_configVarKeys`) — чтобы фильтр в
   `replaceRaw` имел к ним доступ.
2. **Фильтр в `_replaceRaw`** (`settings_storage/backup_tun.dart:14`) — единая
   точка входа:
   - собрать `allowedVars = APP_FEATURE_FLAGS ∪ template.vars.map(name)`
     (через `TemplateLoader.load()`);
   - top-level: пропускать только `∈ ALLOWED_TOP_LEVEL`, прочее → drop + накопить
     в `droppedKeys`;
   - `vars`: пропускать только `∈ allowedVars`, прочее → drop + накопить;
   - `debug_token`: сохранить текущее значение (не дать перезаписать из входа —
     см. открытый вопрос);
   - применить и к `merge=false`, и к `merge=true` ветке.
3. **Экспорт расфильтровать** — `buildExport`/`filterStorageForExport` перестаёт
   звать `_filterStorageForImport`; экспортирует `dumpCache` как есть (с учётом
   категорий, выбранных юзером, — категории остаются, но «unknown→App settings»
   уходит вместе с самим понятием фильтра на выходе).
4. Прокинуть `droppedKeys` из `replaceRaw` наверх → applog
   (`dropped N unknown keys on import: [...]`) + снэкбар на backup-экране.
5. **`PUT /settings/ping_options`** — strip неизвестных subkeys (мелкая правка в
   `debug/handlers/settings.dart:337-360`).
6. Обновить STORAGE.md (раздел про backup-фильтр / Debug API exposure) и
   doc-комментарии в `backup_tun.dart` + `backup_service.dart`.
7. Тесты: `test/services/` — фикстуры с чужеродным top-level ключом, чужим var,
   попыткой перезаписать `debug_token` через import; проверить drop + `droppedKeys`
   + сохранность `debug_token`. Покрыть оба пути (`merge` true/false) и вход через
   Debug API `POST /backup/import`.

---

## Документация, поправленная этой сессией (вне scope фильтра)

- STORAGE.md: добавлены `node_sort_mode` / `node_manual_order` (§100) — были не
  задокументированы в full-tree и в таблице «Прочие top-level ключи».
- STORAGE.md: таблица «Прочие» дополнена `interrupt_connections_on_switch` и
  ссылками на разделы `tun_apps`/`vpn_mode`/`warp_account` → теперь это
  исчерпывающий список актуальных top-level ключей.
