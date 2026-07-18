# 279 — Локализация приложения (l10n)

## Контекст

Всё пользовательское текстовое наполнение приложения — hardcoded английские литералы:
~670 вхождений `Text(` в ~100 файлах, display-поля `wizard_template.json`
(title/tooltip/description/label), интерполированные warnings/ошибки
(`node_warning.dart`, `error_format.dart`), Kotlin-литералы нативных поверхностей
(шторка, QS-тайл, shortcuts, Tasker-активити). Инфраструктуры локализации нет:
ни `flutter_localizations`, ни ARB, ни настройки языка.

## Цели

- Полная локализация UI: **en (базовый) + ru** в первой версии; архитектура
  масштабируется на новые языки добавлением одного ARB + одного overlay +
  одного `values-<lang>/` без структурных изменений.
- Runtime-переключение языка без рестарта приложения (включая нативные
  поверхности при живом VPN-сервисе).
- Guard-rails в CI: новые hardcoded-строки не проходят, протухшие переводы видны.

## Нецели

- Логи, Debug API, automation-payload'ы, wire-значения, user data — английские
  навсегда (см. §8 архитектуры).
- RTL-локали — вне скоупа (зафиксированы пререквизиты).
- Ретроактивная миграция уже сохранённых пользовательских снапшотов
  (channel labels, name-fallback'и).

## Реализация

Первый цикл реализации — [задача 280](../../tasks/280-l10n-first-version.md)
(фазы 0–7 плана миграции, §10). **Статус: фазы 0–7 выполнены** (Phase 6 —
device-verify отложен, DEVICE-PENDING-матрица в задаче 280).

## Docs to update

Выполнено в Phase 7:

- [x] `docs/STORAGE.md` — var `app_language` (system|en|ru), место относительно §189 native_prefs (derived cache, не `NativePrefsKeys`).
- [x] `docs/TEMPLATE.md` — per-language overlay-файлы `assets/l10n/<tag>/template.json`, схема адресов (раздел «Локализация display-текста»). Базовый английский display-текст живёт в самом `wizard_template.json`; отдельного en-файла нет.
- [x] `docs/api/debug-api-reference.md` — side-effect роут `PUT /settings/vars/app_language` (+ DELETE, bash-примеры).
- [x] `docs/ARCHITECTURE.md` — подсистема l10n (LocaleController-пайплайн, TemplateOverlay, UiMsg, checkers, L10n.kt) + `lib/services/l10n/` в дереве исходников.
- [x] `CHANGELOG.md` — Unreleased: выбор языка, русская локализация, runtime-переключение.
- [x] `docs/BUILD.md` — gen_l10n в сборке (генерация при pub get), tool/l10n checkers в CI.
- [x] `docs/l10n.md` — новый translator-guide (язык end-to-end, hotfix baseline, l10n-exempt). (Исходно включал `src`-hash-accept workflow — позже упразднён, см. §3.1.)

---

# Архитектура

## 1. Обзор и принципы

- **Шаблон — сердце системы**: `app/assets/wizard_template.json` — единственный bundled-ассет с display-текстом. Локализация — pre-parse overlay поверх декодированного JSON, ноль изменений call-site'ов у downstream-потребителей.
- **Хранимых отрендеренных строк нет**: warnings/errors — типизированные объекты (`NodeWarning.message(l)`, sealed `UiMsg`), рендер в момент показа.
- **Fallback тихий, дрейф громкий**: отсутствующий перевод отдельного ключа → английское значение, runtime-не-событие; неизвестный/протухший ключ, сломанный overlay-файл, конфликт адресов — ошибки CI или громкий лог.
- **Wire-поверхности английские навсегда**: логи, Debug API-ответы, automation-броадкасты, `emitWarnings`, wire-теги, имена файлов. Для них существует явный механизм `renderEn()` (§4.4) — не запрет без выхода.
- **Смена локали — полный пайплайн, один владелец**: любой путь изменения `app_language` (picker, Debug API, restore, смена системного языка при `setting == system`) проходит через `LocaleController` (§7). Обходных записей нет by construction — прецедент §275 (мутации только через владеющий сервис).
- **Разрешённые синтезом конфликты** (без изменений после ревью): rebuild-only без remount и подъёма контроллеров; sealed `UiMsg` вместо closure; Kotlin-контекст оборачивается в момент рендера без кэша; `StopReason` парсится Dart-side, native wire не трогается; суффиксы длительности `d/h/m/s` латиницей в первом релизе; оценки в днях из плана убраны.

---

## 2. Слой Dart: каталог строк (`gen_l10n`)

### 2.1. Технология и файлы

`gen_l10n` (`flutter_localizations` + `intl` + ARB). Ноль сторонних runtime-зависимостей; первопартийные ICU-плюралы (русскому нужны `one/few/many/other`); на пиненном Flutter 3.41.6 `flutter pub get` авто-генерирует при `flutter: generate: true` — ноль новых CI-шагов кодгена (`ci.yml:106–113` уже гоняет pub get до analyze). Отсутствующий ключ = ошибка `flutter analyze`. slang/easy_localization отклонены.

```
app/l10n.yaml
app/lib/l10n/app_en.arb            # template (источник истины)
app/lib/l10n/app_ru.arb
app/lib/l10n/gen/                  # генерируется, в .gitignore
app/lib/services/l10n/l10n.dart    # рукописный holder (§2.3)
```

`app/l10n.yaml`:

```yaml
arb-dir: lib/l10n
template-arb-file: app_en.arb
output-dir: lib/l10n/gen
output-localization-file: app_localizations.dart
nullable-getter: false
required-resource-attributes: true
untranslated-messages-file: build/l10n_untranslated.json
```

`app/pubspec.yaml`: `flutter_localizations: {sdk: flutter}`, `intl: any`, `generate: true`. `lib/l10n/gen/` — в `.gitignore` и в `analyzer: exclude`.

**Миграционный инвариант: значения en-ARB = сегодняшние литералы дословно.** Все `find.text('…')`-матчеры в widget-тестах переживают sweep без изменений.

### 2.2. Конвенция ключей

camelCase, `<scope><Element>`: `common*`, `home*`, `sub*`, `routing*`, `dns*`, `folder*`, `speed*`, `stats*`, `backup*`, `settings*`, `appSettings*`, `warn*` (тела NodeWarning/ValidationIssue), `err*` (префиксы и humanized-фреймы), `fmt*` (атомы форматирования). Плюралы всегда ICU, плейсхолдер всегда `count`:

```json
"folderDisabledSlow": "{count, plural, one{Disabled {count} server slower than {ms} ms} other{Disabled {count} servers slower than {ms} ms}}"
```

Ликвидирует все `'(s)'`- и `== 1 ? '' : 's'`-хаки из fact base.

### 2.3. Доступ без BuildContext

Dart-изолятов нет, всё на main isolate → глобальный accessor безопасен. Eager-инициализация (error boundary и `_FallbackErrorWidget` ставятся в `main.dart:36–47` до инициализации стораджа — `late`-поле дало бы `LateInitializationError` внутри crash-handler'а):

```dart
// app/lib/services/l10n/l10n.dart
class L10n {
  static AppLocalizations current = lookupAppLocalizations(const Locale('en'));
  /// Пиненный английский инстанс для machine-поверхностей (§4.4). Никогда не переприсваивается.
  static final AppLocalizations en = lookupAppLocalizations(const Locale('en'));
}
```

Политика: виджеты — `AppLocalizations.of(context)` (alias `context.l`); сервисы/контроллеры/парсеры — lazy-рендеринг (типизированные объекты, §4) там, где сообщение хранится; `L10n.current` — только немедленное потребление; `L10n.en` / `renderEn()` — machine-поверхности. `L10n.current` выставляется из персистентной настройки до `runApp` — первый кадр локализован.

---

## 3. Шаблонная подсистема

### 3.1. Один структурный шаблон + плоские overlay

`wizard_template.json` остаётся единственным структурным шаблоном (machine-конфиг, `@var`-плейсхолдеры, id, английский display-текст) — и он же источник базового английского display-текста. Переводы не форкают структуру:

```
app/assets/l10n/ru/template.json   # ручной перевод (per-language overlay)
```

Английский — базовый язык, живёт в коде (в `wizard_template.json`): отдельного en-overlay-файла нет.

**Формат locale-файлов — объектный, записи адресуются английским текстом-ключом** (english-text keys):

```json
"preset.ru-direct.var.dns_server.title": { "value": "DNS-сервер" }
```

`template_check` не сравнивает записи с коммитнутым en-файлом (его нет): базовый английский источник живёт в `wizard_template.json`, и на каждом прогоне чекер извлекает английские ключи вживую через `TemplateOverlay.extract()`, затем валидирует каждый locale-overlay против этой экстракции. Отдельного durable `src`-hash на записи нет.

### 3.2. Схема адресов

Ключевое изменение после ревью (P0): **rule-локальные vars скоупятся по `preset_id`** — в shipped-шаблоне одноимённые vars разных пресетов несут разный английский текст (`dns_server` = "DNS server" в ru-direct и "FakeIP server" в fakeip; `outbound`, `dns_ip`, `dns_enable`, `force_ipv4` — то же), плоский неймспейс молча схлопывал их last-wins.

| Узел шаблона | Адрес | Источник id |
|---|---|---|
| `sections[]` name/description | `section.<id>.name` / `.description` | **новое поле `id`** у 8 секций |
| `sections[].vars[]` (глобальные/секционные) | `var.<name>.title` / `.tooltip` / `.option.<value>` | `name`; `ref`-vars резолвятся против этого скоупа |
| `selectable_rules[].vars[]` (rule-локальные) | `preset.<preset_id>.var.<name>.title` / `.tooltip` / `.option.<value>` | `preset_id` + `name` |
| `selectable_rules[].ui` | `preset.<preset_id>.label` / `.description` | `preset_id` |
| `selectable_rules[].dns_servers[].description` | `preset.<preset_id>.dns_server.<tag>.description` | `preset_id` + `tag` |
| `group_templates.magic_nodes` | `magic.<role>.title` | `auto`/`direct`/`block` |
| `default_channels[]` | `channel.<tag>.label` | `tag` |
| `dns_options.servers[]` | `dns_server.<tag>.description`, `dns_server.<tag>.var.<name>.title` / `.tooltip` / `.option.<value>` | `server.tag` |
| `ping_options.presets[]` | `ping.<id>.name` | **новое поле `id`** (5) |
| `speed_test_options.servers[]` | `speed.<id>.name` | **новое поле `id`** (10) |

Две строки таблицы добавлены ревью (P1 «нет адреса вовсе»): `dns_servers[].description` внутри тела пресета (потребляется `dns_server_resolver.dart:54,64` как `canonicalDescription`) и object-form enum-титулы dns-server-vars ("Quad9 · anti-malware", "8.8.8.8 · Primary v4").

**Экстрактор hard-fail'ит дубликат адреса с конфликтующими значениями** — last-wins запрещён; коллизия видна в момент внесения, а не после отгрузки ru.json. Скоупированная схема обязана лечь в Phase 1, до первой строки ru.json (иначе — полный re-key перевода).

Попутный фикс: runtime-выбор speed-test-сервера переводится с индекса (`speed_test_screen.dart:182`) на `id`.

**Не адресуемо** (whitelist applier'а): всё под `config` и `parser_config`; `name`/`tag`/`value`/`default_value`/`preset_id`; bare-string enum-опции; `dns_options.rules[].name` — латентный identity-ключ (`dns_rules.dart:26–38`), никогда не локализуется. Секции сохраняют `name` как внутренний join-ключ (`parser_config.dart:64–75`, `settings_screen.dart:558–560`): обе стороны читают одно мутированное дерево, патч до парсинга сохраняет join консистентным.

**Порядок применения — контрактный**: overlay патчит декодированную map **до** того, как `preset_expand` снапшотит тела пресетов, т.е. переведённый `dns_servers[].description` попадает в scope `substituteVars`. Отсюда запрет checker'а на `@`-в-начале-значения — **load-bearing**, не гигиена: переведённая строка, начинающаяся с `@`, была бы интерпретирована как var-ссылка. Проверяется в `template_check` безусловно.

### 3.3. Applier

`app/lib/services/l10n/template_overlay.dart`:

```dart
/// Schema-driven: жёсткий список (jsonPath-паттерн, idField(s), displayFields).
class TemplateOverlay {
  static void apply(Map<String, dynamic> templateJson, Map<String, String> overlay);
  static Map<String, String> extract(Map<String, dynamic> templateJson); // fail на дубль-конфликте
}
```

Pre-parse-мутация — весь фокус: каждый downstream-потребитель локализуется бесплатно — парсенные модели (`WizardVar.title/tooltip`, `SelectableRule.label/description`, `VarSection`, `MagicNode`, `DefaultChannel`) и три raw-map (`dns_options`, `ping_options`, `speed_test_options`), читаемые экранами напрямую. `ref`-vars работают без правок: `globalVar()` резолвится против уже пропатченной декларации. Overlay не касается machine-полей → `markConfigDirty()` не нужен.

**Hardening (Phase 2)**: три raw-секции получают тонкие typed-модели (`DnsOptionsModel`, `PingOptionsModel`, `SpeedTestOptionsModel`), парсящиеся из уже-оверлеенного JSON — новое display-поле нельзя потребить мимо choke point.

### 3.4. TemplateLoader: кэш по локали, громкий отказ файла

Два дефекта ревью закрываются переделкой loader'а, а не конвенцией:

**(a) Гонка инвалидации** (текущий `_cached` без in-flight-guard: pre-switch `load()` завершается после инвалидации и перезаписывает кэш старой локалью навсегда). Фикс — **кэш ключуется тегом локали**:

```dart
class TemplateLoader {
  static final Map<String, WizardTemplate> _cache = {};   // tag -> template
  static WizardTemplate? cachedOrNull([String? tag]) => _cache[tag ?? LocaleController.I.effectiveTag];
  static Future<WizardTemplate> load()      // читает effectiveTag В НАЧАЛЕ, кладёт результат ПОД СВОЙ тег
  static Future<void> reload(String tag)    // прогрев: загрузить+распарсить под tag, положить в кэш
  static void invalidate()                  // полный сброс (только для смены самого ассета в dev)
}
```

Старый in-flight `load()` кладёт результат под свой (старый) тег — новый язык не затирается по построению. Unit-тест: старт `load()`, смена локали mid-flight, ассерт что `cachedOrNull` нового тега — новая локаль.

**(b) Silent fallback не должен маскировать packaging-сбой**: per-key fallback (нет ключа в overlay) — тихий, by design; **отказ целого файла — громкий**: для любого тега из `supportedLocales`, кроме `en`, ошибка `rootBundle.loadString` или парсинга `assets/l10n/<tag>/template.json` → `AppLog.error` + `assert(false)` в debug. Плюс flutter-тест, который rootBundle-загружает и JSON-парсит каждый заявленный overlay: `flutter test` бандлит pubspec-ассеты, поэтому забытая per-file запись в `app/pubspec.yaml` красит CI.

### 3.5. Персистентные снапшоты шаблонного текста

1. **`custom_rules[].name` у preset-правил** — английский снапшот label (`selectable_to_custom.dart:22`; «билдер обновляет» из doc-комментария — мёртвая ложь). Персистентный `name` — только fallback; display-сайты для `kind: preset` (`custom_rule_tile.dart:87`, `preset_params_tab.dart:186–198`) резолвят label вживую из локализованного шаблона.
   **Дизамбигуация дубликатов** (ревью): live-резолюция схлопывала бы " (2)"-суффикс `uniqueCustomRuleName` — все копии одного пресета выглядели бы идентично. Правило рендера: если у правила есть sibling с тем же `presetId`, к live-label прикрепляется порядковый номер копии — `<liveLabel> (N)` для N-й копии в порядке списка (первая без суффикса). Widget-тест: две копии одного пресета рендерятся различимо под обеими локалями.
   **Дедуп** (ревью): `uniqueCustomRuleName` сравнивает новые/переименованные имена с **display-резолвнутыми** именами (live label для preset-строк, хранимое имя для остальных) — иначе inline-правило можно назвать ровно как видимый label пресета и получить визуальный дубль.
2. **`channels[].label`** — user CRUD-данные после one-shot seed; seed читает локализованный шаблон (бесплатно через overlay); ретроактивно не мигрируется.
3. **`magic_nodes.*.title`** — потреблять `MagicNode.title` из `TemplateLoader.cachedOrNull`, удалить хардкод-зеркало в `special_node_display.dart:43–56`. Прогрев кэша до `notifyListeners()` (§7.2) гарантирует, что в момент rebuild кэш нового языка тёплый — деградации в fallback при переключении нет.
4. **`RuleNameResolver` / `labelByPresetId`** (ревью): display-зеркала, снапшотящиеся при `buildConfig` (`custom_rules.dart:210,232`) и мемоизируемые синглтоном, пережили бы смену локали — config по дизайну не ребилдится. Фикс: `RuleNameResolver.I.relocalize(template)` — пере-дерайв preset-label-части зеркал из `custom_rules` + свежелокализованного шаблона + сброс мемоизации; вызывается из `LocaleController._applyLocale()` после прогрева шаблона, **без** касания конфига. Live-экраны (connections/stats) — ровно то, куда юзер смотрит сразу после переключения.

**Правило seed-time-локализации — на все first-run seed'ы**: `_migrateChannelsIfNeeded`, `normalize_pinned_presets`, `selectableRuleToCustom`, inline-DNS-seed `'My DNS'` (`dns_settings_screen.dart:374` → ARB) резолвят метки через активную локаль в момент создания.

---

## 4. Warnings / errors / snackbars

### 4.1. NodeWarning и ValidationIssue: lazy-рендеринг

Warnings memory-only, регенерируются на каждый parse, не сериализуются (`node_spec.dart:20–22`) — переход stored-English → render-at-display безопасен и тотален:

```dart
sealed class NodeWarning {
  String message(AppLocalizations l);          // было: String get message
  WarningSeverity get severity;
  // Равенство: runtimeType + поля данных (не отрендеренная строка — иначе dedup ломается при смене локали).
}
```

`XhttpParamResetWarning.reason` (free-text в 4 точках `transport_spec.dart`) → `enum XhttpResetReason` + поля данных. То же для всех `ValidationIssue`; `FatalValidationException` несёт список issue, рендерится в catch-сайте. Интерполируемые значения (scheme, transport, tag) — wire-идентификаторы, не переводятся.

### 4.2. Хранимое состояние: sealed `UiMsg`

```dart
sealed class UiMsg {
  const UiMsg();
  String render(AppLocalizations l);
  /// Фиксированный английский рендер для machine-поверхностей (Tasker, AppLog,
  /// notification-label push). Единственный санкционированный путь UiMsg → String вне build.
  String renderEn() => render(L10n.en);
}
class TimeoutError extends UiMsg { final int seconds; ... }
class PrefixedMsg  extends UiMsg { final ErrPrefix prefix; final String detail; ... }
class RawMsg       extends UiMsg { final String detail; ... }   // passthrough OS/kernel-английского
```

Объекты equatable, pattern-matchable. `lastError`/`status` становятся `UiMsg?`; экраны рендерят в build — смена локали мгновенно перерендеривает хранимые ошибки. `SubscriptionEntry.subtitle(AppLocalizations l)` компонует `status.render(l)` в момент показа — функция принимает `l` параметром, что делает её render-path по построению (и распознаётся checker'ом как таковая, §9.4).

### 4.3. Два форматтера

`formatUserError` / `humanizeError` возвращают `UiMsg`. **Вызов форматтера в контроллере для конструирования хранимого `UiMsg` — санкционированный паттерн** (это и есть целевой data flow: `lastError = formatUserError(e)`), не нарушение — CI-правило §9.4 переписано соответственно. Собственные фразы форматтеров → ARB; payload исключений (`osError.message`, kernel-строки) → passthrough в `RawMsg.detail`, не переводится.

### 4.4. Machine-поверхности: `renderEn()`

Три класса потребителей нуждаются в String вне widget-дерева и обязаны остаться английскими (Решение 19): automation-броадкаст `emitSubRefreshFailed(shortUrl, humanizeError(e).renderEn())` (`subscription_controller.dart:1606`), AppLog-интерполяции (`:198`, `:1523`), Dart-push notification-labels (`home_controller._pushNotificationLabels`). Все три мигрируют на `renderEn()` в Phase 4 (входят в её скоуп явно). `renderEn()` разрешён checker'ом только в allowlist-файлах.

### 4.5. Load-bearing строковые протоколы (Phase 0)

- `home_screen.dart:284–291` матчит `'alert:permission_location:'` / срезает `'Stopped: '` → Dart парсит в типизированный `StopReason { revoked, permissionLocation(perms), error(detail) }` при ingestion (`home_controller.dart:331–333`); Kotlin-wire не трогается; структурный `errorCode`-broadcast — опциональный поздний натив-коммит.
- `TunnelStatus.fromNative`-литералы — wire; `TunnelStatus.label` → ARB.

### 4.6. Snackbar-паттерны

`(s)`/ternary → ICU-plural-ключи (~15); `.join()`-джойнеры `' · '`, `'; '` остаются (пунктуация); StringBuffer-отчёт `backup_screen.dart` → по ARB-сообщению на клаузу.

---

## 5. Форматирование и политика единиц

- **Даты/время: `intl`.** `formatTime` → `DateFormat.Hms(localeTag)`; композиции `yyyy-MM-dd HH:mm:ss` — ISO-порядок в обеих локалях сознательно. Locale-данные ru грузятся при старте внутри существующего best-effort try в `main()`. Имя файла бэкапа — locale-invariant.
- **Байтовые/скоростные единицы: латиница** (`B/KB/MB/GB`, `Mbps`, `ms`), десятичная точка. Обоснование: ru-техноаудитория читает латиницу нативно; «МБ/Мб» вносит байт/бит-двусмысленность; паритет с логами ядра/Debug API; golden-тесты `format_utils_test.dart` не трогаются.
- **Суффиксы длительности `d/h/m/s`: латиница в первом релизе**; перевод — дешёвый follow-up.
- **Слова переводятся**: `relativeTime()` — полный ICU-переписыш; `'used'`, `'days left'`, `'Unlimited'`, `'Expired'`, `statusLabel`, `intervalHuman`, существительные `CustomRule.summary` → ARB с плюралами.
- Попутно: слить дубликат `_formatDuration` (`connections_screen.dart:419–423`) в `format_utils`.
- RTL вне скоупа (обе локали LTR); 32 physical-direction-использования зафиксированы как пререквизит будущей RTL-локали.

---

## 6. Android native

### 6.1. Экстракция ресурсов

Каждый литерал fact-инвентаря → `values/strings.xml` + `values-ru/strings.xml`: имя/описание notification-канала, статусные строки, `Stop`/`Reconnect`, тайл, shortcuts, три automation-activity, `app_name`. Manifest: `android:label` → `@string/…`. Payload-несущие фреймы — `%1$s`, payload verbatim. FGS-subtype-property английский.

### 6.2. Резолвер локали (работает при мёртвом Flutter)

```kotlin
object L10n {
    // читает boxvpn_boot.app_language: "system" | "en" | "ru"
    // контекст оборачивается В МОМЕНТ РЕНДЕРА, никогда не кэшируется
    fun ctx(base: Context): Context { ... createConfigurationContext ... }
    fun str(base: Context, id: Int, vararg args: Any): String = ctx(base).getString(id, *args)
}
```

Все нативные поверхности (`ServiceNotification`, `BoxService.stopAndAlert`, `LxBoxTileService`, `QuickShortcuts`, automation-activity, тосты) — через `L10n.str(...)`. Работает в сервис-процессе без Flutter: выбор лежит в `boxvpn_boot` SharedPreferences.

### 6.3. Распространение изменений

MethodChannel-вызов `setAppLanguage(tag)` в `VpnPlugin` → `BootReceiver.setAppLanguage` пишет pref, затем handler немедленно:

1. Пересабмитит notification-канал (`createNotificationChannel` — идемпотентный rename).
2. `ServiceNotification.relabel(ctx)` — реконструирует cached-builder целиком (`addAction` не идемпотентен), затем redraw через существующий `updateNotification`-broadcast.
3. **Shortcuts — через `updateShortcuts()`, оба ярлыка сразу** (ревью): `updateShortcuts` — документированный API для label-refresh, обновляющий и **pinned**-копии, которых нет в текущем status-зависимом наборе `doRefresh` (Stopped публикует только Connect — pinned Disconnect иначе не обновился бы никогда). При `IllegalStateException`/`isRateLimited` (locale-change-путь исполняется в background — юзер в системных Settings, а следующий `setStatus` у always-on-VPN может быть через дни) — **гарантированный retry из `MainActivity.onResume`** (foreground, rate-limit не применяется).
4. `LxBoxTileService.requestListeningState`.
5. **`Libbox.setLocale(resolvedTag)`** (ревью): сегодня зовётся только в `BoxApplication.onCreate` (BoxApplication.kt:48–54) — строки ядра и `typeName`-имена каналов §036-нотификаций оставались бы на старом языке до смерти процесса. Вызов добавляется в `setAppLanguage`-handler и в `ACTION_LOCALE_CHANGED`-receiver. Пререквизит Phase 6 — верифицировать, что libbox принимает mid-run `setLocale`; если нет — в §6.3-доке и release notes фиксируется окно «строки ядра переключаются при следующем рестарте VPN» (известное, объявленное, не обнаруживаемое через баг-репорт).

Manifest-receiver на `ACTION_LOCALE_CHANGED` повторяет шаги 1–5 (Dart-сторона той же смены системной локали — §7.2, observer). `MainActivity` сохраняет `configChanges=locale`.

### 6.4. Android 13+ per-app language

- `android:localeConfig="@xml/locales_config"` (`en`, `ru`); на API 33+ выбор языка в приложении → `LocaleManager.setApplicationLocales(...)`; AppCompat не добавляется.
- **Выбор `System default` обязан чистить per-app-локали** (ревью, P1): `setApplicationLocales(LocaleList.getEmptyLocaleList())` на 33+. Без этого `PlatformDispatcher.instance.locale` навсегда возвращал бы последний явный выбор («System» — мёртвая опция), а reconciliation на следующем старте молча перезаписывал бы `system` обратно в `ru`. С этим фиксом инвариант чист: непустой `getApplicationLocales` может происходить либо из нашего же push'а, либо из системных Settings.
- **Reconciliation — трёхсторонний, с зеркалом last-push** (ревью, P1; одностороннее «система побеждает» молча уничтожало `app_language`, восстановленный из бэкапа или записанный через Debug API при мёртвом приложении). Приложение хранит `boxvpn_boot.last_pushed_locale` — последнее значение, которое **само** запушило в `LocaleManager` (включая пустой список для `system`). На Dart-старте:
  1. `getApplicationLocales() != last_pushed_locale` → менял юзер в системных Settings → **система побеждает**, значение пишется в `app_language`, зеркало обновляется.
  2. `getApplicationLocales() == last_pushed_locale`, но `!= app_language` из стораджа → сторадж изменился под ногами (restore, Debug API, hand-edit) → **сторадж побеждает**, значение пушится в `LocaleManager`, зеркало обновляется.
  3. Совпадает всё → no-op.
- Device-матрица Phase 6: `ru → System default → restart` показывает язык устройства и сохраняет `app_language='system'`; restore бэкапа с `app_language` при пред-выставленном `LocaleManager` переживает рестарт.

### 6.5. Место `app_language` относительно §189 native_prefs — явное

`app_language` **не член `NativePrefsKeys`** (ревью: членство автоматически экспортировало бы его в `vpn_settings`-блок бэкапа — два представления одной настройки с неопределённым precedence на import). Его `boxvpn_boot`-копия (вместе с `last_pushed_locale`) — **derived cache**: единственный источник истины — var в `lxbox_settings.json`; кэш пере-пушится `setAppLanguage` и `bootstrapAndSyncNativePrefs`. Это — документированное исключение из правила §189 «прямые native-записи эфемерны», фиксируется в doc-комментарии `native_prefs.dart`. Guard-тест рядом с §221-сьютом: `assert('app_language' ∉ NativePrefsKeys.all)` — convention-following-рефакторинг падает громко.

---

## 7. Настройка языка и runtime-переключение

### 7.1. Хранение

Значения: `system` (default) | `en` | `ru`. Var `app_language` в `vars` `lxbox_settings.json`:

1. `'app_language'` в `_appFeatureFlagVars` (`settings_storage.dart:144–183`) — иначе var не переживает restore (import дропает неизвестные vars). Export не требует правок (vars экспортируются нефильтрованно) → §221 в обе стороны одной записью.
2. **Не** в `_configVarKeys` — язык не грязнит sing-box-конфиг.
3. Typed-аксессоры `getAppLanguage`/`setAppLanguage`; setter стреляет MethodChannel-зеркало и вызывается из `bootstrapAndSyncNativePrefs()`.
4. Валидация: неизвестное значение → `system`.
5. Тесты: membership `app_language ∈ _appFeatureFlagVars`; полный export→import round-trip **с ассертом эффекта, не только стораджа** — на API-33-кодпути с пред-выставленным `LocaleManager` (§6.4-reconciliation, ветка 2).

### 7.2. LocaleController — единственный владелец пайплайна

```dart
// app/lib/services/l10n/locale_controller.dart
class LocaleController extends ChangeNotifier with WidgetsBindingObserver {
  static final I = LocaleController();
  String setting = 'system';
  Locale? _lastApplied;
  Locale get effective => setting == 'system'
      ? _resolve(PlatformDispatcher.instance.locale) : Locale(setting);
  String get effectiveTag => effective.languageCode;

  /// Регистрируется в main(): WidgetsBinding.instance.addObserver(LocaleController.I).
  /// Закрывает split-brain: при setting=='system' смена языка устройства (или per-app
  /// смена в системных Settings на 13+) без этого перештамповывала native-поверхности
  /// (receiver §6.3), но не Flutter-UI — configChanges=locale не пересоздаёт activity,
  /// а MaterialApp.locale перечитывается только в build, которого не случалось.
  @override
  void didChangeLocales(List<Locale>? _) {
    if (setting != 'system') return;
    final now = effective;
    if (now != _lastApplied) _applyLocale(now);        // тот же пайплайн минус персист
  }

  Future<void> set(String v) async {
    setting = v;
    await SettingsStorage.setAppLanguage(v);           // JSON + native-зеркало + resubmit + LocaleManager
    await _applyLocale(effective);
  }

  /// Вызывается также после backup-import'а, прочитав app_language из стораджа.
  Future<void> reloadFromStorage() async { ... set(storedValue), идемпотентно ... }

  Future<void> _applyLocale(Locale loc) async {
    _lastApplied = loc;
    L10n.current = lookupAppLocalizations(loc);
    await TemplateLoader.reload(loc.languageCode);     // ПРОГРЕВ ДО notify: кэш нового языка тёплый,
                                                       // cachedOrNull не null ни в один момент переключения
    RuleNameResolver.I.relocalize(TemplateLoader.cachedOrNull());  // §3.5.4, без markConfigDirty
    LazyPersistFlush.flushAll();                       // слить staged-правки VarValuesModel/LazyPersistMixin
    notifyListeners();                                 // → полный rebuild MaterialApp
  }
}
```

Два изменения относительно исходного дизайна — не косметика:

- **Прогрев вместо invalidate-и-надежды**: `invalidate()` + rebuild находил бы `cachedOrNull == null` ровно в момент переключения (magic-node-титулы деградировали бы в fallback без последующего rebuild — async-reload никого не нотифицирует). `await reload()` до `notifyListeners()` гарантирует: каждый build видит тёплый локализованный кэш.
- **`initState`-захваченные `_template`-поля — механизм, не конвенция**: заявленное «MaterialApp rebuild заставляет экраны заново await'ить шаблон» ложно — rebuild сохраняет Element tree и State, `initState` не перезапускается; pop-back тоже; корневой HomeScreen не пересоздаётся никогда. Экраны с `WizardTemplate? _template` (settings_screen.dart:39, speed_test_screen.dart:55–66, dns_settings, home_menus) переносят fetch в `didChangeDependencies`, ключуясь на `Localizations.localeOf(context)` — срабатывает на смене локали для каждого Material-экрана, включая сидящие в глубине стека. Паттерн «поле типа `WizardTemplate?`, заполняемое в initState» добавляется в детекцию `hardcoded_check` (rendering-locality-правила) — регресс к старому паттерну ловится CI.

`main.dart`: загрузка `app_language` после `bootstrapAndSyncNativePrefs()`, `L10n.current` до `runApp`, регистрация observer'а. `LxBoxApp.build`: `AnimatedBuilder(animation: Listenable.merge([themeNotifier, LocaleController.I]), …)` вокруг единственного `MaterialApp` (`locale:`, `supportedLocales: [en, ru]`, delegates). Remount'а и подъёма контроллеров нет.

### 7.3. Debug API — через тот же пайплайн

Generic-роут `PUT /settings/vars/*` — raw `setVar` (`handlers/settings.dart:120–129, 264`), что для `app_language` означало бы расхождение стораджа и всего живого состояния до следующего полного старта. Фикс: **per-key side-effect-registry в vars-handler'е** — таблица `key → hook`; `app_language` диспатчится в `await LocaleController.I.set(value)` (невалидное значение → 400), `DELETE` → `set('system')`. Generic-путь остаётся generic для остальных ключей; прецедент §275 соблюдён. `POST /backup/import` и UI-restore по завершении вызывают `LocaleController.I.reloadFromStorage()`. Тест: Debug-API-запись `app_language` оставляет `LocaleController`, `boxvpn_boot`-зеркало и (на 33+) `LocaleManager` консистентными.

### 7.4. UX

App Settings → General → "Appearance", `RadioGroup` под theme-picker'ом: `System default` / `English` / `Русский` — эндонимы, каждая метка на своём языке (сознательно не из ARB текущей локали).

---

## 8. Backup и границы локализации

- **Backup**: единственный дом `app_language` — `vars` (см. §6.5: не `NativePrefsKeys`, не `vpn_settings`-блок). §221-симметрия закрыта membership-тестом + round-trip-тестом с ассертом эффекта на 33+ (§7.1).
- **Английские навсегда** (документированная граница): логи, Debug API-ответы, automation/Tasker-payload'ы (`emitSubRefreshFailed` и др. — через `renderEn()`), `emitWarnings`-wire, wire-значения (вкл. `TagResolver.displayTag` — display == config-identity), имена файлов, user data, WARP `/reg` locale-поле, `dns_options.rules[].name`, FGS-subtype-property.
- **Payload OS/library/kernel не переводится** — диагностический passthrough (`RawMsg.detail`).
- **User data не мигрируется ретроактивно** — channel labels и preset-`name`-fallback'и существующих юзеров остаются как есть; live-резолюция закрывает основные поверхности.

---

## 9. Guard-rails / CI

Один шаг в `checks`-джобе. Миграционный период (Phases 1–6) жил в
двухступенчатом режиме — warnings на PR, `--strict` только на tag-билдах
(`startsWith(github.ref, 'refs/tags/')`). **С Phase 7 условие удалено — все
четыре checker'а идут с `--strict` на каждом push/PR** (baseline пуст, ru
100%, orphan'ов нет — warnings фатальны):

```yaml
- name: L10n checks
  if: ${{ github.event.inputs.test_path == '' }}
  working-directory: app
  run: |
    dart run tool/l10n/template_check.dart --strict
    dart run tool/l10n/arb_check.dart --strict
    dart run tool/l10n/hardcoded_check.dart --strict
    dart run tool/l10n/kotlin_check.dart --strict
```

Checkers пишут отчёт (missing/stale/untranslated-счётчики) в `$GITHUB_STEP_SUMMARY` — виден в каждом PR, не требует `pull-requests: write` (у workflow только `contents: read`).

### 9.1. `template_check.dart`

- Английские ключи извлекаются вживую из `wizard_template.json` через `TemplateOverlay.extract()` (коммитнутого en-файла нет); каждый locale-overlay валидируется против этой свежей экстракции. **Экстрактор fail'ит дубликат адреса с конфликтом значений** (§3.2).
- Locale-файлы: неизвестный ключ → fail; пустой `value` → fail; `value`, начинающийся с `@`, или содержащий `{` → fail (load-bearing, §3.2).
- Missing-ключи → warning / `--strict`-fail.
- Self-check: whitelist applier'а покрывает каждое display-поле экстрактора.

### 9.2. `arb_check.dart`

- **Orphan-детекция — AST, не substring** (ревью: текстовый скан `.<key>` false-live на любом ключе, коллидирующем с обычным member-именем, и false-orphan на mid-wave-состояниях). Инструмент уже стоит на `package:analyzer` для `hardcoded_check` — тот же pass резолвит property-доступы, чей receiver статически типизирован `AppLocalizations` (включая `context.l` и `L10n.current`/`L10n.en`), и сравнивает множество с ключами ARB. `lib/l10n/gen/` исключён из скана. Orphan = **warning в Phases 1–6, fail в Phase 7** — зеркально ru-гейту.
- Непереведённые ru-ключи из `build/l10n_untranslated.json`: отчёт в summary + fail под `--strict`; **после Phase 7 — hard-fail на каждом PR**.
- Равенство placeholder-наборов en↔ru по каждому ключу.

### 9.3. `hardcoded_check.dart` — ratchet

AST-visitor по `app/lib`. **Display-позиции = прямые виджет-аргументы + конфигурируемый helper-список** (ревью: канонический snackbar-путь репо после §219 — `showSnack('...')`, где единственный `Text(` внутри `ui_helpers.dart` с переменной; чистый виджет-скан слеп к ~130 helper-вызовам — самому идиоматичному пути входа новых строк):

- Виджет-позиции: `Text(`, `SnackBar(content:`, `AlertDialog(title:/content:`, `tooltip:`, `labelText:/hintText:`, `SnackBarAction(label:`, `Tab(text:`, `PopupMenuItem`-/`TextSpan`-/`Chip`-label-позиции.
- Helper-лист в конфиге checker'а рядом с baseline: `showSnack`, `_snack`, `_diagSnack`, `_showError`, `showDeleteConfirmDialog(title:/message:)`, helpers `SnackHelper`-наследников — литерал-аргумент → сайт. Новый snack-helper обязан регистрироваться; self-check-эвристика: функция со String-параметром, из которой достижим `ScaffoldMessenger.showSnackBar` → кандидат в helper-лист → warning, пока не зарегистрирован.
- Литерал-присваивания в известные UiMsg-смежные поля (`lastError`, `_status`, `SubscriptionEntry.status`) — сайты до Phase 4, после — поля типизированы и литерал туда не компилируется.

**Baseline** `app/tool/l10n/hardcoded_baseline.json` = file + hash каждого grandfathered-сайта. Реальный объём ~**1000** сайтов (~670 `Text('` + 69 `tooltip:` + 72 `labelText/hintText` + helper-аргументы + диалоги), не 670. Два правила против hotfix-ловушки (ревью: «baseline только сужается» + content-hash делали любую правку grandfathered-литерала — опечатка, rename переменной в интерполяции — выбором между миграцией в чужом PR и `l10n-exempt`-гниением):

- **Hash канонизируется**: каждая `${...}`-интерполяция заменяется позиционным плейсхолдером до хеширования — rename идентификатора не меняет hash.
- **Same-file hash-replacement разрешён**: для каждого файла — размер нового множества ≤ старого и ни одной записи в файле, которого не было в baseline. Правка формулировки внутри hotfix = замена hash'а, счётчик не растёт. Путь документируется в `docs/l10n.md`.
- `// l10n-exempt: <причина>` — точечно (wire-теги, `'—'`, unit-виджет `'ms'`).

### 9.4. Rendering-locality — переспецифицировано

Исходное правило («`formatUserError(`/`humanizeError(`/`.render(` вне `lib/screens|widgets` → fail») противоречило целевому data flow самой архитектуры (контроллеры обязаны звать форматтеры для конструирования `UiMsg`; `subscription_entry.subtitle` компонует вне screens; Tasker/AppLog обязаны рендерить en вне widget-дерева) и падало бы на 20 существующих сайтах в день включения. Финальное правило бьёт по **String-стокам, а не по вызовам форматтеров**:

- `formatUserError`/`humanizeError` возвращают `UiMsg` → их вызов где угодно легален (String из них больше не выходит).
- `.render(` легален: (a) в `lib/screens|widgets`; (b) в любой функции, принимающей `AppLocalizations` параметром (render-path по построению — покрывает `subscription_entry.dart` без ad-hoc-allowlist).
- `renderEn(` легален только в allowlist-файлах: `lib/services/automation/`, AppLog-сайты, `home_controller`-notification-push.
- `L10n.current` вне allowlist → fail; `L10n.en` напрямую → fail (только через `renderEn()`).
- Паттерн «поле `WizardTemplate?` + заполнение в `initState`» → fail (§7.2).

Правило включается в Phase 4 (когда форматтеры возвращают `UiMsg`); до того — warning-режим.

### 9.5. Kotlin literal guard

Grep-tier (набор файлов мал и закрыт): `"`-литерал внутри аргументов `setContentTitle|setContentText|addAction|tile.subtitle|tile.label|setShortLabel|setLongLabel|Toast.makeText|NotificationChannel(` → fail; `android:label="` без `@string` в манифесте → fail.

---

## 10. План миграции

| Фаза | Состав | Объём |
|---|---|---|
| **0. Развязка протоколов** | `StopReason`-парсинг (Kotlin нетронут); равенство NodeWarning/ValidationIssue → поля данных; `XhttpResetReason`; поля `id` в sections/ping/speed + speed-выбор по id; **механический prep-коммит: `NodeWarning.message` getter → метод `message()` (пока без параметра, делегирует в текущий текст)** — сжимает атомарный diff Phase 4 до signature-only где возможно | ~10 файлов + шаблон |
| **1. Инфраструктура** | l10n.yaml/`app_en.arb` (seed `common*` + пилот), `L10n` (eager, + пиненный `en`), `LocaleController` **с WidgetsBindingObserver-регистрацией**, wiring MaterialApp, `TemplateOverlay` applier+extractor **со скоупированной схемой адресов (§3.2 — до первой строки ru.json)** и дубль-fail'ом, `TemplateLoader` с кэшом-по-локали + тест mid-flight-инвалидации, три checker'а (hardcoded в ratchet-режиме, rendering-locality в warning-режиме) + канонизированный hash-baseline (~1000 сайтов) + `GITHUB_STEP_SUMMARY`-отчёт + tag-`--strict`-wiring, `app_language`-var + side-effect-registry Debug API + `_appFeatureFlagVars` + §221-тесты + `NativePrefsKeys`-guard-тест + MethodChannel-зеркало + `last_pushed_locale`, LazyPersist-flush, picker (System/English). Ships inert. Release note: `GlobalMaterialLocalizations` немедленно переводит встроенные Material-тексты для system-ru — окно смешанных языков объявляется | ~18 файлов + tool/ |
| **2. Сердце — шаблон** | `assets/l10n/ru/template.json` (объектный формат, english-text keys `{"value": ...}`; исходно проектировался с `src`-hash — позже упразднён, см. §3.1); live-резолюция preset-имён + ordinal-дизамбигуация + display-dedup (§3.5.1); magic-nodes из шаблона; `RuleNameResolver.relocalize`; typed-модели трёх raw-секций; **перенос `_template`-fetch в `didChangeDependencies` на 4 экранах** (settings, dns_settings, speed_test, home_menus); flutter-тест rootBundle-загрузки всех overlay | шаблон + ~12 файлов + перевод |
| **3. Sweep UI-chrome** | ~1000 сайтов / ~100 файлов, независимо шипуемые волны (home → subscriptions → routing/folders → stats/profiler → хвост); ICU-плюралы; baseline сужается поволново | самая большая, механическая, параллелизуемая |
| **4. Warnings/errors — атомарная** | **Не waveable** (ревью): смена сигнатур sealed-иерархии + возврат `UiMsg` у форматтеров — compile-wide break при CI-analyze на весь проект включая test/. Полный closure одной короткой веткой, merge между релизами: `lib/services/parser/*`, `transport_spec.dart`, `validation.dart`, оба форматтера, контроллеры (`home_controller` + `config_io` + `ping_orchestration`, `subscription_controller`), render-сайты, **`renderEn()`-миграция Tasker/AppLog/notification-push (§4.4)**, 4+ test-файла (12 `.message`-ссылок, 14 форматтер-ссылок в `error_format_test.dart`, 9 `NodeWarning`); включение rendering-locality-правила в fail-режим | одна ветка, ~25 файлов + тесты |
| **5. Форматирование** | intl-даты, relativeTime-плюралы, unit-смежные слова, дедуп `_formatDuration`; суффиксы `d/h/m/s` не трогаются | ~10 файлов |
| **6. Android native** | strings.xml + values-ru, manifest `@string`, `L10n.kt` (wrap-no-cache), `relabel()`, `ACTION_LOCALE_CHANGED`-receiver (+ `Libbox.setLocale`), `updateShortcuts` + onResume-retry, localeConfig + `LocaleManager` **(empty-list на `system`)** + трёхсторонний reconciliation + `last_pushed_locale`, `Libbox.setLocale` в setAppLanguage-handler (верификация mid-run; иначе — документированное окно), Kotlin-guard. Включить `Русский` → **релиз**. Device-матрица: QS-тайл cold-start на ru; Stop/Reconnect после смены языка при видимой нотификации; **смена языка устройства при `app_language=system` с приложением в foreground и background** (UI и натив переключаются согласованно); **`ru → System default → restart` на 33+**; **restore бэкапа с `app_language` на 33+ при выставленном LocaleManager**; **pinned-shortcut-лейблы после смены**; имя канала в системных настройках; boot-start; Tasker-строки. Release notes: Tasker-блёрбы меняют язык (display-only, матчинг по extras); окно kernel-строк, если mid-run `setLocale` не поддержан | ~12 Kotlin-файлов, ~40 ресурсов |
| **7. Lock down** — ✅ | Baseline → ноль (выполнено; попутно `hardcoded_check` научен рекурсии в ternary/switch-ветки display-позиций — вскрытая сотня литералов домигрирована в ARB, скан вынесен в `tool/l10n/src/hardcoded_scan.dart` + self-тест `test/tool/`); ru-гейт и orphan-гейт → hard-fail на каждый PR (`--strict` безусловно — CI-условие удалено); доки (STORAGE.md, TEMPLATE.md, BUILD.md, ARCHITECTURE.md, debug-api-reference **с описанием side-effect-роута `app_language`**, CHANGELOG, translator-guide `docs/l10n.md` вкл. hotfix-путь baseline; `src`-hash-workflow исходно был описан, позже упразднён — см. §3.1) | скрипты/конфиг/доки |

**Тесты**: ~1768 существующих — подавляющее большинство проходит как есть (en = source, «en-ARB = литералы дословно», латинские единицы); исключение — Phase-4-closure, перечисленный выше. 5 `pumpWidget`-файлов получают `test/helpers/pump_app.dart`. Новые: applier (адреса, whitelist, fallback, дубль-fail), детерминизм экстрактора, checkers self-tested, mid-flight-инвалидация loader'а, rootBundle-загрузка overlay, LocaleController (персистентность + didChangeLocales-пайплайн), §221 (membership + round-trip-с-эффектом на 33+), Debug-API-консистентность, дизамбигуация дублей пресета под обеими локалями, рендеры NodeWarning под обеими локалями, `StopReason`, equatable `UiMsg`, `NativePrefsKeys`-guard.

---

## 11. Решения

| # | Решение |
|---|---|
| 1 | Overlay применяется к декодированному JSON шаблона **до парсинга и до preset_expand-снапшотов**; запрет `@`-в-начале значений — load-bearing |
| 2 | Один структурный шаблон; базовый английский display-текст живёт в самом `wizard_template.json` (отдельного en-файла нет), overlay-файлы — per-language (`assets/l10n/ru/template.json`), `ru`-overlay — единственный рукописный артефакт; записи адресуются английским текстом-ключом (`{"value": ...}`), durable `src`-hash нет — `template_check` валидирует каждый overlay против живой экстракции из шаблона |
| 3 | Все overlay-ключи из machine-id; **rule-локальные vars и preset-body dns_servers скоупятся по `preset_id`; dns-server-vars получают `.option.<value>`**; три узла получают `id`; экстрактор fail'ит дубль-конфликт |
| 4 | Отсутствующий перевод ключа = тихий en-fallback; **отказ целого overlay-файла = громкий (AppLog.error + debug-assert + flutter-тест бандла)**; неизвестный ключ = ошибка CI |
| 5 | gen_l10n/ARB, `nullable-getter: false`, `required-resource-attributes: true`; генерируемый вывод в .gitignore |
| 6 | Инвариант миграции: значения en-ARB = сегодняшние литералы дословно |
| 7 | Lazy-рендеринг: `message(l)` у warnings, sealed `UiMsg` у хранимых ошибок; равенство по полям данных; **`UiMsg.renderEn()` (пиненный `L10n.en`) — единственный путь UiMsg→String вне build, allowlist: automation/AppLog/notification-push** |
| 8 | Wire-протоколы английские, парсятся в типы до рендера (`StopReason` Dart-side, Kotlin нетронут); payload OS/kernel не переводится |
| 9 | Единицы и суффиксы длительности — латиница, десятичная точка; локализуются слова |
| 10 | `app_language` = var в `_appFeatureFlagVars`; **явно НЕ `NativePrefsKeys`; boxvpn_boot-копия — derived cache (guard-тест)**; единственный backup-дом — `vars` |
| 11 | **Все пути записи `app_language` сходятся в `LocaleController`: picker, Debug API (per-key side-effect-registry), restore (`reloadFromStorage`), системная смена (observer)** |
| 12 | **`LocaleController` — `WidgetsBindingObserver`: `didChangeLocales` при `setting=='system'` гоняет полный пайплайн минус персист** — UI и натив переключаются согласованно |
| 13 | Переключение = механизм themeNotifier (merged Listenable, единственный MaterialApp), без remount; **прогрев `TemplateLoader.reload()` + `RuleNameResolver.relocalize()` ДО `notifyListeners()`** |
| 14 | **`TemplateLoader`-кэш ключуется тегом локали** — mid-flight-load кладёт результат под свой тег, гонка инвалидации невозможна |
| 15 | **`_template`-поля экранов перечитываются в `didChangeDependencies` по `Localizations.localeOf`** — механизм, охраняемый checker'ом, не конвенция |
| 16 | `L10n.current` eager-инициализируется en |
| 17 | Натив: `createConfigurationContext` wrap-at-render-time без кэша (24–32); `LocaleManager`+`localeConfig` (33+), **`system` → `setApplicationLocales(emptyLocaleList)`**; AppCompat не добавляется |
| 18 | **Reconciliation 33+ — трёхсторонний через `last_pushed_locale`**: системная смена побеждает; смена стораджа (restore/Debug API) пушится в LocaleManager, а не затирается |
| 19 | Канал — идемпотентный resubmit; `ServiceNotification.relabel(ctx)` реконструирует builder целиком; **shortcuts — `updateShortcuts()` (оба + pinned) с retry из `MainActivity.onResume`**; **`Libbox.setLocale` — также в setAppLanguage-handler и locale-receiver** |
| 20 | Preset-правила: live-label из шаблона, персистентный `name` — fallback; **дизамбигуация копий ordinal'ом, dedup по display-резолвнутым именам**; все first-run seed'ы — через активную локаль |
| 21 | **Display-зеркала билдера (`RuleNameResolver`/`labelByPresetId`) пере-дерайвятся на смене локали без ребилда конфига** |
| 22 | CI: AST-ratchet с канонизированным hash-baseline (**same-file replacement разрешён, счётчик не растёт**) + helper-лист + **AST-orphan-скан** + rendering-locality **по String-стокам** + Kotlin-guard + **двухступенчатость, зашитая в `startsWith(github.ref, 'refs/tags/')` и `$GITHUB_STEP_SUMMARY`** |
| 23 | Логи, Debug API, automation, `emitWarnings`, wire-значения, имена файлов, user data, WARP `/reg` — английские навсегда; машинные потребители — `renderEn()`, никогда `render(l)` |
| 24 | Окна смешанных языков, смена языка Tasker-блёрбов и (при необходимости) окно kernel-строк объявляются в release notes |

---

## 12. Риски

1. **Schema-drift applier'а**: новое display-поле без обновления экстрактора/whitelist тихо шипится английским. Митигация: self-check экстрактор↔whitelist + typed-модели raw-секций + review-чеклист. Остаток: поле, добавленное в шаблон и модель, но не в экстрактор, — ловится только ревью.
2. **Смена равенства NodeWarning** меняет dedup-гранулярность — целевой тест на warning-списки.
3. **Churn sweep'а** (~1000 сайтов, ~100 файлов) конфликтует с параллельными сессиями — волны короткие, baseline-конфликты после канонизации hash'ей тривиальны; hotfix-путь (same-file replacement) документирован.
4. **Staleness ru в миграционный период** — окно смешанных экранов на develop; missing-ключи видны в каждом summary; hard-fail в Phase 7. (Исходно предполагался `src`-hash для durable stale-детекции — позже упразднён, см. §3.1.)
5. **Phase 4 атомарна** — единственная неразрезаемая фаза, наиболее подвержена коллизиям с параллельными сессиями; митигация: prep-rename в Phase 0 + короткая ветка между релизами; риск остаётся расписанным, а не сюрпризом.
6. **Реконструкция notification-builder'а** — territory неидемпотентного `addAction`; обязательный device-тест в матрице Phase 6.
7. **`Libbox.setLocale` mid-run может быть не поддержан** — тогда kernel-строки и `typeName`-каналы переключаются на следующем рестарте VPN; окно документируется, не маскируется.
8. **Русские строки на ~30–40% длиннее** — ru-smoke-pass на маленьких экранах в Phase 6; subtitle QS-тайла молча обрезается.
9. **Инициализация intl-locale-данных** — best-effort в `main()`, сбой не блокирует boot.
10. **Hand-edited бэкап** — валидация `system|en|ru`, неизвестное → `system`.
11. **Замороженные снапшоты существующих юзеров** (channel labels, name-fallback'и) — косметика; live-резолюция закрывает основные поверхности.
12. **`updateShortcuts` под rate-limit** — onResume-retry гарантирован только при следующем открытии приложения; между сменой языка в системных Settings и открытием приложения pinned-ярлыки могут висеть на старом языке.
13. **RTL не поддерживается** — будущая RTL-локаль = отдельный проект; зафиксировано явно.
14. **Helper-лист checker'а — ручной реестр**: новый snack-helper, не зарегистрированный несмотря на self-check-эвристику, открывает щель в ratchet до первого ревью.

---

## 13. Проверено adversarial-ревью

22 находки, дубликаты слиты (16 уникальных). Каждая закрыта изменением дизайна:

| Дефект (severity) | Резолюция |
|---|---|
| Плоский `var.<name>.*` коллидирует между пресетами, last-wins + CI-laundering (**P0**) | §3.2: rule-локальные vars скоупятся `preset.<preset_id>.var.<name>.*`; экстрактор fail'ит дубль-конфликт; обязателен в Phase 1 до ru.json |
| Rendering-locality-правило противоречит собственному data flow + нет en-render-механизма для automation/логов (**P0**, ×2 находки) | §9.4: правило переписано на String-стоки (вызовы форматтеров легальны — возвращают `UiMsg`; `.render(l)` легален в функциях с `AppLocalizations`-параметром); §4.4: `renderEn()` + allowlist; включение в fail-режим только в Phase 4; `renderEn`-миграция — в скоупе Phase 4 |
| Нет Dart-слушателя системной смены локали при `setting=system` — split-brain UI/натив (**P1**, ×2 находки) | §7.2: `LocaleController` — `WidgetsBindingObserver.didChangeLocales` → полный пайплайн минус персист; кейсы в device-матрице Phase 6 |
| «System default» не чистит `LocaleManager`; reconciliation молча откатывает выбор (**P1**) | §6.4: `setApplicationLocales(emptyLocaleList)` на выборе `system`; тест `ru → System → restart` |
| Reconciliation уничтожает `app_language` из restore/Debug API (**P1**) | §6.4: трёхсторонняя логика через `boxvpn_boot.last_pushed_locale`; round-trip-тест с эффектом на 33+ |
| Прогрева шаблона нет: rebuild видит null-кэш, «re-await в initState» не существует (**P1**) | §7.2: `await TemplateLoader.reload()` до `notifyListeners()`; `_template`-fetch в `didChangeDependencies` по локали; паттерн охраняется checker'ом |
| Гонка `invalidate()`: in-flight load кэширует старую локаль (**P1**) | §3.4: кэш ключуется тегом локали; unit-тест mid-flight |
| Два класса display-полей без адреса (preset-body `dns_servers[].description`, option-титулы dns-server-vars) (**P1**) | §3.2: два новых адрес-класса; порядок overlay-до-preset_expand контрактный; `@`-запрет объявлен load-bearing |
| Stale-детекция эфемерна — гейт сертифицирует наличие ключа, не свежесть (**P1**) | §3.1/§9.1: исходно `src`-hash у каждой ru-записи (durable per-key fail) — позже упразднён; актуально: `template_check` валидирует overlay против живой экстракции из `wizard_template.json` |
| `hardcoded_check` слеп к helper-идиомам (`showSnack` и др.) (**P1**) | §9.3: конфигурируемый helper-лист + литерал-присваивания в UiMsg-смежные поля + self-check-эвристика новых helpers |
| Hash-baseline + «только сужается» = hotfix-ловушка или exempt-гниение (**P1**) | §9.3: канонизация интерполяций в hash'е + same-file replacement с неубывающим-запретом; путь в `docs/l10n.md`; объём честно ~1000 |
| Debug API `PUT /settings/vars/app_language` обходит весь пайплайн (**P1**+P2, ×2 находки) | §7.3: per-key side-effect-registry → `LocaleController.set()`; `DELETE` → `set('system')`; backup-import → `reloadFromStorage()`; тест консистентности |
| `Libbox.setLocale` только на старте процесса (P2) | §6.3 шаг 5: вызов в handler'е и receiver'е; при неподдержке mid-run — документированное окно |
| Shortcut-relabel rate-limited в background, pinned не обновляются (P2) | §6.3 шаг 3: `updateShortcuts()` для обоих + retry из `onResume`; pinned-кейс в device-матрице |
| Снапшоты `RuleNameResolver`/`labelByPresetId` переживают смену локали (P2) | §3.5.4: `relocalize()` в `_applyLocale()` без ребилда конфига |
| Live-label схлопывает « (2)»-дизамбигуацию и ломает видимую уникальность (P2, ×2 находки) | §3.5.1: ordinal по sibling'ам с тем же `presetId` + dedup по display-резолвнутым именам; widget-тест |
| Orphan-скан ARB по substring несостоятелен (P2, ×2 находки) | §9.2: AST-резолюция доступов к `AppLocalizations`; gen/ исключён; warning до Phase 7 |
| Silent fallback маскирует packaging-сбой ru.json (P2) | §3.4: per-key тихо / whole-file громко; flutter-тест rootBundle-загрузки всех overlay |
| Двухступенчатый гейт существует только в прозе (P2) | §9: `--strict` через `startsWith(github.ref, 'refs/tags/')`; отчёт в `$GITHUB_STEP_SUMMARY` (без доп. permissions) |
| Phase 4 не waveable вопреки заявленному (P2) | §10: фаза переспецифицирована как атомарная короткая ветка с перечисленным closure; prep-rename в Phase 0 |
| `app_language` vs §189 `NativePrefsKeys` — неопределённость с двумя backup-представлениями (P2) | §6.5: явно не член; derived cache; doc-комментарий; guard-тест `'app_language' ∉ NativePrefsKeys.all` |